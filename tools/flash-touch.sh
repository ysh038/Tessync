#!/bin/bash
# Tessync Touch 펌웨어를 빌드해 연결된 보드에 넣는다. 칩(ESP32-C5, 오리지널 ESP32)을 알아내 알맞은 옵션을 고른다.
#
#   tools/flash-touch.sh                 보드 자동 감지, 빌드, 업로드
#   tools/flash-touch.sh --build-only [esp32c5|esp32]   보드 없이 빌드만
#   tools/flash-touch.sh --port /dev/cu.xxx             포트 직접 지정
#
# 업로드해도 저장된 Wi-Fi 설정은 지워지지 않는다. 포트를 다른 프로그램이 잡고 있으면(touch-bridge.py) 먼저 끈다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKETCH="$ROOT/firmware/tessync-touch"
PORT=""
BUILD_ONLY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --build-only) BUILD_ONLY="${2:-esp32c5}"; shift ;;
    --port) PORT="$2"; shift ;;
    *) echo "모르는 옵션: $1" >&2; exit 2 ;;
  esac
  shift
done

# BLE + Wi-Fi + 웹서버가 기본 파티션(1.2MB)을 넘으므로 huge_app을 쓴다.
fqbn() {
  case "$1" in
    esp32c5)
      # 칩의 USB 단자(usbmodem)에 꽂았으면 시리얼 로그도 그쪽으로 나가게 한다. UART 변환 칩 단자면 기본값.
      local cdc="default"
      case "$PORT" in *usbmodem*) cdc="cdc" ;; esac
      echo "esp32:esp32:esp32c5:PartitionScheme=huge_app,CDCOnBoot=$cdc" ;;
    esp32) echo "esp32:esp32:esp32:PartitionScheme=huge_app" ;;
    *) echo "지원하지 않는 칩: $1" >&2; exit 1 ;;
  esac
}

compile() {
  arduino-cli compile --fqbn "$(fqbn "$1")" --output-dir "$SKETCH/bin/$1" "$SKETCH"
}

if [ -n "$BUILD_ONLY" ]; then
  compile "$BUILD_ONLY"
  exit 0
fi

if [ -z "$PORT" ]; then
  # 블루투스 등 다른 장치를 고르지 않도록 USB 시리얼 이름만 본다.
  PORT="$(ls /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART* /dev/cu.wchusbserial* /dev/cu.usbmodem* 2>/dev/null | head -1 || true)"
fi
if [ -z "$PORT" ]; then
  echo "보드를 찾지 못했습니다. 데이터 케이블인지 확인하세요(충전 전용 케이블은 전원만 들어옵니다)." >&2
  exit 1
fi

ESPTOOL="$(ls -d "$HOME"/Library/Arduino15/packages/esp32/tools/esptool_py/*/esptool | sort -V | tail -1)"
INFO="$("$ESPTOOL" --port "$PORT" flash-id 2>&1 || true)"
if echo "$INFO" | grep -q "ESP32-C5"; then
  CHIP=esp32c5
elif echo "$INFO" | grep -qE "ESP32-D0WD|ESP32-D2WD|ESP32-PICO|ESP32-U4WDH|Connected to ESP32 on|Chip type: *ESP32 "; then
  CHIP=esp32
else
  echo "칩을 알아내지 못했습니다. BOOT 버튼을 누른 채 RST를 눌러 업로드 모드로 만들고 다시 실행하세요." >&2
  echo "$INFO" >&2
  exit 1
fi
echo "포트 $PORT, 칩 $CHIP"
echo "$INFO" | grep -iE "flash size|Chip type|Connected to" || true

compile "$CHIP"
arduino-cli upload --fqbn "$(fqbn "$CHIP")" --port "$PORT" --input-dir "$SKETCH/bin/$CHIP" "$SKETCH"
echo "완료. 처음 켜면 Wi-Fi 설정 모드입니다: 아이폰에서 Tessync-Touch-Setup에 접속해 http://192.168.4.1"
