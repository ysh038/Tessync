#!/usr/bin/env python3
"""테슬라 플레이어처럼 방송 서버에 tap 메시지를 보낸다. 아이폰 안의 터치 조작(TouchController)을 맥에서 시험하는 용도.

아이폰이 방송 중이고, ESP32가 아이폰 8082 포트에 붙어 있어야 한다(플레이어 디버그의 "터치 장치 준비됨").
결과는 아이폰 진단 로그의 "tap ..." 줄로 확인한다.

  python3 tools/touch-tap.py <아이폰 IP> <u> <v> [저장할 프레임.jpg]

u, v는 방송 프레임 기준 0~1 좌표(세로 화면, 왼쪽 위가 0,0). 필요: pip install websocket-client
"""
import sys
import threading
import time
import urllib.request

import websocket

WAIT_S = 10


def main():
    host, u, v = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) > 4 else None
    ws = websocket.create_connection(f"ws://{host}:8081/")
    ws.send('{"t":"hello","ua":"touch-tap","w":0,"h":0,"dpr":1}')
    latest = {}

    def receive():
        while True:
            opcode, data = ws.recv_data()
            if opcode == websocket.ABNF.OPCODE_BINARY:
                latest["frame"] = data[2:]

    threading.Thread(target=receive, daemon=True).start()
    time.sleep(1)
    ws.send('{"t":"tap","u":%f,"v":%f}' % (u, v))
    sent = time.time()
    # 결과 줄이 로그에 찍힐 때까지 기다린다.
    while time.time() - sent < WAIT_S:
        time.sleep(0.5)
        log = urllib.request.urlopen(f"http://{host}:8080/log", timeout=3).read().decode()
        result = next((line for line in log.splitlines() if " tap " in line or "tap failed" in line or "tap ignored" in line), None)
        if result and result[:24] > time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(sent - 1)):
            print(result)
            break
    else:
        print("결과 없음(시간 초과)")
    if out and "frame" in latest:
        open(out, "wb").write(latest["frame"])


if __name__ == "__main__":
    main()
