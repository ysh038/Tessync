#!/usr/bin/env python3
"""ESP32(Tessync Touch)와의 연결을 붙잡고 있다가, localhost:9100으로 들어온 명령을 보드에 전달한다.

USB 시리얼: 포트를 열 때마다 ESP32가 리셋되어 아이폰 블루투스 연결이 끊기므로, 포트는 한 번만 열고 계속 유지한다.
Wi-Fi(--tcp): 보드가 8082 포트로 연결해 오기를 기다린다. 차에서는 이 역할을 아이폰 방송 익스텐션이 맡는다.

  python3 tools/touch-bridge.py [/dev/cu.usbserial-XXXX]
  python3 tools/touch-bridge.py --tcp
  echo "m 100 0" | nc -w 2 127.0.0.1 9100

보드 출력은 이 프로그램의 표준 출력에도 그대로 찍힌다. pyserial 필요: pip install pyserial
"""
import glob
import socket
import sys
import threading
import time

PORT_PATTERNS = ["/dev/cu.usbserial-*", "/dev/cu.SLAB_USBtoUART*", "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*"]
CONTROL_PORT = 8082

lines = []
lines_lock = threading.Condition()


def find_port():
    for pattern in PORT_PATTERNS:
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    sys.exit("ESP32 시리얼 포트를 찾지 못했습니다. 데이터 케이블로 연결했는지 확인하세요.")


def add_line(text):
    print(f"board: {text}", flush=True)
    # 하트비트는 명령 응답이 아니므로 모으지 않는다.
    if text.startswith("hb "):
        return
    with lines_lock:
        lines.append(text)
        lines_lock.notify_all()


def feed(read):
    """read()가 주는 바이트를 줄로 나눠 add_line에 넘긴다. read()가 b""를 주면 끝낸다."""
    buffer = b""
    while True:
        chunk = read()
        if chunk is None:
            return
        # 시리얼 포트를 열고 닫을 때 0xFF 쓰레기 바이트가 섞여 들어와 응답 줄 앞에 붙는다. 걸러낸다.
        buffer += chunk.replace(b"\xff", b"")
        while b"\n" in buffer:
            raw, buffer = buffer.split(b"\n", 1)
            add_line(raw.decode(errors="replace").rstrip("\r"))


class SerialBoard:
    def __init__(self, port):
        import serial

        # DTR/RTS가 켜진 채로 열면 DevKitC의 자동 리셋 회로가 보드를 리셋 상태로 붙잡는다. 끈 채로 연다.
        self.port = serial.Serial()
        self.port.port = port
        self.port.baudrate = 115200
        self.port.timeout = 0.1
        self.port.dtr = False
        self.port.rts = False
        self.port.open()
        threading.Thread(target=feed, args=(lambda: self.port.read(256),), daemon=True).start()
        print(f"bridge: {port} 연결", flush=True)

    def write(self, data):
        self.port.write(data)


class TcpBoard:
    """보드가 Wi-Fi로 연결해 온다. 다시 연결하면 새 연결로 바꾼다."""

    def __init__(self):
        self.connection = None
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", CONTROL_PORT))
        listener.listen()
        threading.Thread(target=self.accept, args=(listener,), daemon=True).start()
        print(f"bridge: 보드 Wi-Fi 연결 대기 :{CONTROL_PORT}", flush=True)

    def accept(self, listener):
        while True:
            connection, address = listener.accept()
            connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            print(f"bridge: 보드 연결됨 {address[0]}", flush=True)
            self.connection = connection
            threading.Thread(target=feed, args=(lambda c=connection: c.recv(256) or None,), daemon=True).start()

    def write(self, data):
        if self.connection is None:
            add_line("error board not connected over Wi-Fi")
            return
        self.connection.sendall(data)


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


def serve(client, board):
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


def main():
    if "--tcp" in sys.argv:
        board = TcpBoard()
    else:
        args = [a for a in sys.argv[1:] if not a.startswith("--")]
        board = SerialBoard(args[0] if args else find_port())
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 9100))
    server.listen()
    print("bridge: 명령 대기 127.0.0.1:9100", flush=True)
    while True:
        connection, _ = server.accept()
        threading.Thread(target=serve, args=(connection, board), daemon=True).start()


if __name__ == "__main__":
    main()
