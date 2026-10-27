#!/usr/bin/env python3
"""ESP32(Tessync Touch)의 USB 시리얼을 붙잡고 있다가, localhost:9100으로 들어온 명령을 보드에 전달한다.

포트를 열 때마다 ESP32가 리셋되어 아이폰 블루투스 연결이 끊기므로, 포트는 한 번만 열고 계속 유지한다.

  python3 tools/touch-bridge.py [/dev/cu.usbserial-XXXX]
  echo "m 100 0" | nc -w 2 127.0.0.1 9100

보드 출력은 이 프로그램의 표준 출력에도 그대로 찍힌다. pyserial 필요: pip install pyserial
"""
import glob
import socket
import sys
import threading
import time

import serial

PORT_PATTERNS = ["/dev/cu.usbserial-*", "/dev/cu.SLAB_USBtoUART*", "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*"]


def find_port():
    for pattern in PORT_PATTERNS:
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    sys.exit("ESP32 시리얼 포트를 찾지 못했습니다. 데이터 케이블로 연결했는지 확인하세요.")


port = sys.argv[1] if len(sys.argv) > 1 else find_port()
# DTR/RTS가 켜진 채로 열면 DevKitC의 자동 리셋 회로가 보드를 리셋 상태로 붙잡는다. 끈 채로 연다.
board = serial.Serial()
board.port = port
board.baudrate = 115200
board.timeout = 0.1
board.dtr = False
board.rts = False
board.open()
print(f"bridge: {port} 연결, 127.0.0.1:9100 대기", flush=True)

lines = []
lines_lock = threading.Condition()


def read_board():
    buffer = b""
    while True:
        # 포트를 열고 닫을 때 0xFF 쓰레기 바이트가 섞여 들어와 응답 줄 앞에 붙는다. 걸러낸다.
        buffer += board.read(256).replace(b"\xff", b"")
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            text = raw.decode(errors="replace").rstrip("\r")
            print(f"board: {text}", flush=True)
            with lines_lock:
                lines.append(text)
                lines_lock.notify_all()


def wait_reply(start_index, timeout):
    """명령을 보낸 뒤 ok/error/status 줄이 올 때까지 보드 출력을 모은다."""
    deadline = time.time() + timeout
    with lines_lock:
        while True:
            replies = lines[start_index:]
            if any(r.startswith(("ok", "error", "status")) for r in replies):
                return replies
            remaining = deadline - time.time()
            if remaining <= 0:
                return replies + ["(응답 시간 초과)"]
            lines_lock.wait(remaining)


def serve(client):
    with client:
        for command in client.makefile("r"):
            command = command.strip()
            if not command:
                continue
            with lines_lock:
                start = len(lines)
            board.write((command + "\n").encode())
            # 큰 이동(h)은 보고서를 수십 개 보내므로 넉넉히 기다린다.
            for reply in wait_reply(start, 10):
                client.sendall((reply + "\n").encode())


threading.Thread(target=read_board, daemon=True).start()
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 9100))
server.listen()
while True:
    connection, _ = server.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
