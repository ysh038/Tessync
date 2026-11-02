#!/usr/bin/env python3
"""ESP32(Tessync Touch)의 시리얼 로그를 계속 찍는다. USB가 잠깐 끊겨도 다시 연다.

포트를 새로 열면 보드가 재시작할 수 있으므로 한 번만 띄워 둔다. touch-bridge.py, flash-touch.sh와 같이 쓸 수 없다.

  python3 tools/touch-log.py [/dev/cu.usbserial-XXXX]

필요: pip install pyserial
"""
import glob
import sys
import time

import serial

PORT_PATTERNS = ["/dev/cu.usbserial-*", "/dev/cu.SLAB_USBtoUART*", "/dev/cu.wchusbserial*", "/dev/cu.usbmodem*"]


def find_port():
    for pattern in PORT_PATTERNS:
        found = sorted(glob.glob(pattern))
        if found:
            return found[0]
    return None


def main():
    fixed = sys.argv[1] if len(sys.argv) > 1 else None
    while True:
        port = fixed or find_port()
        try:
            if port is None:
                raise OSError("보드 없음")
            # DTR/RTS가 켜진 채로 열면 자동 리셋 회로가 보드를 리셋 상태로 붙잡는다. 끈 채로 연다.
            board = serial.Serial()
            board.port = port
            board.baudrate = 115200
            board.timeout = 0.2
            board.dtr = False
            board.rts = False
            board.open()
            print(f"[{port} 열림]", flush=True)
            while True:
                data = board.read(512).replace(b"\xff", b"")
                if data:
                    sys.stdout.write(data.decode(errors="replace"))
                    sys.stdout.flush()
        except (OSError, serial.SerialException) as error:
            print(f"[연결 끊김: {error}]", flush=True)
            time.sleep(1)


if __name__ == "__main__":
    main()
