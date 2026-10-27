#!/usr/bin/env python3
"""폐루프 포인터 이동 시험: 방송 프레임에서 포인터를 찾아 목표 좌표와의 차이만큼 다시 보낸다.

나중에 방송 익스텐션 안으로 옮길 알고리즘을 맥에서 먼저 검증하는 용도다.
tools/touch-bridge.py가 떠 있고, 아이폰이 같은 Wi-Fi에서 방송 중이어야 한다.

  python3 tools/touch-seek.py <아이폰 IP> x,y [x,y ...] [--click]

좌표는 방송 프레임 픽셀(590x1280 기준). 필요: pip install websocket-client pillow numpy scipy
"""
import io
import socket
import sys
import threading
import time

import numpy as np
import websocket
from PIL import Image
from scipy import ndimage

# 추적 속도 최저에서 실측한 이동량 1당 픽셀(590x1280 프레임). 작게 움직일수록 iOS 가속 곡선 때문에 덜 간다.
# 정확할 필요는 없다(폐루프가 보정한다).
PX_PER_UNIT = [(10, 0.76), (30, 0.86), (float("inf"), 0.95)]
TOLERANCE_PX = 4
MAX_ROUNDS = 6
# iOS는 포인터 이동을 부드럽게 보여주고, 프레임도 늦게 온다. 보낸 직후 위치는 아직 움직이는 중이다.
# 실측: 이동 후 프레임에 반영되기까지 0.3~0.4초 걸린다.
MIN_SETTLE_S = 0.45
# 이 시간 동안 새 프레임이 없으면 화면(포인터)이 멈춘 것으로 본다.
QUIET_S = 0.2
SETTLE_TIMEOUT_S = 1.2

latest = {"frame": None, "at": 0.0}
VERBOSE = "-v" in sys.argv


def receive_frames(host):
    ws = websocket.create_connection(f"ws://{host}:8081/")
    ws.send('{"t":"hello","ua":"touch-seek","w":0,"h":0,"dpr":1}')
    while True:
        opcode, data = ws.recv_data()
        if opcode == websocket.ABNF.OPCODE_BINARY:
            latest["frame"] = data[2:]
            latest["at"] = time.time()


def find_pointer(jpeg, near=None):
    """회색 원(RGB 약 149, 지름 약 27px)을 찾는다. 글자 위에 겹치면 못 찾는다.

    AssistiveTouch 버튼 같은 비슷한 회색 원도 걸리므로, near(예상 위치)가 있으면 그에 가장 가까운 후보를 고른다.
    """
    im = np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"), dtype=int)
    gray = im.mean(axis=2)
    sat = im.max(axis=2) - im.min(axis=2)
    labels, _ = ndimage.label((abs(gray - 149) < 12) & (sat < 10))
    candidates = []
    for i, sl in enumerate(ndimage.find_objects(labels), 1):
        h = sl[0].stop - sl[0].start
        w = sl[1].stop - sl[1].start
        if 18 <= w <= 34 and 18 <= h <= 34 and (labels[sl] == i).sum() > 0.6 * w * h:
            cy, cx = ndimage.center_of_mass(labels == i)
            candidates.append((cx, cy))
    if not candidates:
        return None
    if near is None:
        return candidates[0]
    return min(candidates, key=lambda c: (c[0] - near[0]) ** 2 + (c[1] - near[1]) ** 2)


# 비켜놓기: 같은 걸음으로 갔다가 되돌아오면 정확히 제자리로 온다(실측). 이동량 120을 20씩 보내면 약 73px.
WIGGLE_UNITS = 120
WIGGLE_STEP = 20
POINTER_RADIUS_PX = 13


def frame_array(jpeg):
    return np.asarray(Image.open(io.BytesIO(jpeg)).convert("RGB"), dtype=np.int16)


def disc_kernel(radius):
    y, x = np.mgrid[-radius:radius + 1, -radius:radius + 1]
    return (x * x + y * y <= radius * radius).astype(float)


def find_pointer_by_wiggle(near, window=110):
    """포인터를 오른쪽으로 비켜놓았다가 되돌리며 전후 프레임 차이로 찾는다. 글자나 아이콘 위에서도 된다.

    차이 영상에는 원래 위치(P)와 비켜놓은 위치(P + 약 73px) 두 곳에 원이 나타난다. 왼쪽 것이 P다.
    """
    before = frame_array(latest["frame"])
    sent = time.time()
    board(f"g {WIGGLE_UNITS} 0 {WIGGLE_STEP}")
    settled_position(sent)
    moved = frame_array(latest["frame"])
    sent = time.time()
    board(f"g {-WIGGLE_UNITS} 0 {WIGGLE_STEP}")
    settled_position(sent)

    height, width = before.shape[:2]
    x0, x1 = max(0, int(near[0]) - window), min(width, int(near[0]) + window)
    y0, y1 = max(0, int(near[1]) - window), min(height, int(near[1]) + window)
    diff = np.abs(before[y0:y1, x0:x1] - moved[y0:y1, x0:x1]).sum(axis=2).astype(float)
    response = ndimage.convolve(diff, disc_kernel(POINTER_RADIUS_PX), mode="constant")
    peaks = []
    for _ in range(2):
        y, x = np.unravel_index(np.argmax(response), response.shape)
        if response[y, x] <= 0:
            break
        peaks.append((x + x0, y + y0, response[y, x]))
        response[max(0, y - 2 * POINTER_RADIUS_PX):y + 2 * POINTER_RADIUS_PX,
                 max(0, x - 2 * POINTER_RADIUS_PX):x + 2 * POINTER_RADIUS_PX] = 0
    if not peaks:
        return None
    # 두 번째 원이 약하면(창 밖으로 나감) 하나뿐이다. 그때는 예상 위치에 가까운 쪽을 믿는다.
    if len(peaks) == 2 and peaks[1][2] > 0.4 * peaks[0][2]:
        left = min(peaks[:2], key=lambda p: p[0])
        return float(left[0]), float(left[1])
    return float(peaks[0][0]), float(peaks[0][1])


def board(command):
    with socket.create_connection(("127.0.0.1", 9100)) as s:
        s.sendall((command + "\n").encode())
        s.shutdown(socket.SHUT_WR)
        return s.makefile().read().strip()


def settled_position(after, near=None):
    """이동 명령 후 화면이 멈출 때까지(새 프레임이 QUIET_S 동안 없을 때까지) 기다렸다가 포인터를 찾는다."""
    time.sleep(max(0.0, after + MIN_SETTLE_S - time.time()))
    deadline = time.time() + SETTLE_TIMEOUT_S
    while time.time() < deadline and time.time() - latest["at"] < QUIET_S:
        time.sleep(0.03)
    return find_pointer(latest["frame"], near) if latest["frame"] else None


def units(px):
    scale = next(value for limit, value in PX_PER_UNIT if abs(px) < limit)
    return round(px / scale)


def seek(target):
    started = time.time()
    pos = settled_position(0)
    if pos is None:
        # 포인터가 안 보이면 모서리로 보낸 뒤 화면 안쪽으로 꺼낸다.
        board("h")
        board("m 40 40")
        pos = settled_position(time.time() - 0.05, near=(30, 30))
    for round_ in range(1, MAX_ROUNDS + 1):
        if pos is None:
            return False, f"포인터를 못 찾음 (round {round_})"
        dx, dy = target[0] - pos[0], target[1] - pos[1]
        if abs(dx) <= TOLERANCE_PX and abs(dy) <= TOLERANCE_PX:
            return True, f"도착 {pos[0]:.0f},{pos[1]:.0f} 오차 {dx:+.1f},{dy:+.1f} round={round_ - 1} {time.time() - started:.2f}s"
        sent = time.time()
        board(f"m {units(dx)} {units(dy)}")
        expected = (pos[0] + dx, pos[1] + dy)
        if VERBOSE:
            print(f"    {pos[0]:.1f},{pos[1]:.1f} 오차 {dx:+.1f},{dy:+.1f} -> m {units(dx)} {units(dy)}", flush=True)
        pos = settled_position(sent, near=expected)
        if pos is None or abs(pos[0] - expected[0]) > 120 or abs(pos[1] - expected[1]) > 120:
            # 글자나 아이콘 위라 색으로 못 찾으면(또는 엉뚱한 회색 원을 잡으면) 비켜놓기로 찾는다.
            pos = find_pointer_by_wiggle(expected)
    if pos and abs(target[0] - pos[0]) <= TOLERANCE_PX and abs(target[1] - pos[1]) <= TOLERANCE_PX:
        return True, f"도착 {pos[0]:.0f},{pos[1]:.0f} round={MAX_ROUNDS} {time.time() - started:.2f}s"
    return False, f"수렴 실패 {pos} {time.time() - started:.2f}s"


def main():
    host = sys.argv[1]
    click = "--click" in sys.argv
    targets = [tuple(float(v) for v in arg.split(",")) for arg in sys.argv[2:] if "," in arg]
    threading.Thread(target=receive_frames, args=(host,), daemon=True).start()
    while latest["frame"] is None:
        time.sleep(0.05)
    for target in targets:
        arrived, message = seek(target)
        print(f"목표 {target[0]:.0f},{target[1]:.0f}: {message}", flush=True)
        # 엉뚱한 곳을 누르지 않도록 도착했을 때만 클릭한다.
        if click and arrived:
            print("  클릭:", board("c"))


if __name__ == "__main__":
    main()
