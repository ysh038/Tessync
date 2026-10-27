# 작업 인계 (2026-10-28)

다른 PC에서 이어서 작업할 때 이 문서와 `CLAUDE.md`를 먼저 읽는다. 터치 조작의 실측값과 판단 근거는 `docs/design/02-touch-control.md` 맨 아래 "실측" 절에 있다.

## 지금까지 된 것

### 미러링 (차에서 동작 확인)

- iOS 앱 + 방송 익스텐션 + 테슬라 웹 플레이어. 무료 Personal Team으로 빌드, 실기기 실행.
- 테슬라 접속 주소는 `http://192.0.0.2:8080`(아이폰 셀룰러 464XLAT 주소). 핫스팟 주소 `172.20.10.1`은 사설 IP라 테슬라 브라우저가 막는다. 앱이 `192.0.0.x`를 찾아 안내한다.
- 주행 중에도 동작: D 기어에서 `<video>`는 멈추지만 canvas는 계속 그린다. 테슬라의 "주행 중 Wi-Fi 끄기" 설정은 꺼야 한다.
- 화면이 멈추기 직전 프레임을 건너뛰면 영영 안 가던 버그를 고쳤다(`FramePipeline.trailing`).

### 터치 조작 (집에서 동작 확인, 차에서는 아직)

```
테슬라 화면 클릭 → 플레이어가 {"t":"tap","u","v"}(프레임 기준 0~1) 전송
→ 방송 익스텐션 TouchController: 프레임에서 포인터 찾기 → 이동 명령 → 다시 확인(폐루프) → 클릭
→ Wi-Fi TCP 8082 (ESP32가 아이폰으로 연결해 옴) → ESP32 BLE 마우스 → AssistiveTouch 포인터
```

- ESP32 DevKitC V4 펌웨어 `firmware/tessync-touch`: BLE HID 마우스, USB 시리얼과 Wi-Fi(TCP 8082) 명령, Wi-Fi 설정 페이지.
- 익스텐션: `Broadcast/TouchLink.swift`(보드 연결), `PointerFinder.swift`(포인터 검출), `TouchController.swift`(폐루프 이동, 클릭).
- 플레이어: 캔버스 클릭 → tap 전송, 누른 자리에 원 표시, 디버그에 "터치 장치" 상태.
- 아이폰 안에서 끝까지 동작 확인: 빈 곳 목표에 정확히 도착해 클릭, 앱의 "복사" 버튼 클릭 성공(알림 뜸). **4~8초 걸린다.**

## 바로 다음 할 일

1. **터치 속도 개선 (목표 1~2초).** 지금 한 번 누르는 데 4~8초.
   - 먼저 `TouchController`에 단계별 시간(검출, 명령 왕복, 대기, 비켜놓기)을 로그로 남겨 어디서 시간이 드는지 본다.
   - 의심: 이동마다 고정 대기(최소 0.45초 + 조용한 0.2초), 비켜놓기 한 번에 약 1.3초, 디버그 빌드의 느린 Swift 배열 연산(`PointerFinder`는 전체 프레임을 훑는다 → 예상 위치 주변만 보도록 줄이기), 보정 3회.
   - Release 빌드로 실행해 비교(Xcode Scheme > Run > Build Configuration).
2. **차에서 터치 시험.** ESP32 설정 모드에서 Wi-Fi를 아이폰 핫스팟(호환성 최대화 켜기)으로, 서버 주소는 비운다. 테슬라 화면을 눌러 플레이어의 좌표 변환(`canvasToFrame`)이 맞는지 확인한다. 맥 앱 내장 브라우저는 로컬 WebSocket을 막아서 이 부분은 아직 실제로 확인하지 못했다.
3. **가로 화면 지원.** 지금은 세로(orientation 1)만 처리하고 가로는 무시한다. 가로에서 마우스 축과 프레임 축의 관계를 실기기로 확인해야 한다.
4. 앱 홈에 터치 장치 상태 표시, ESP32 설정 안내.
5. 미러링 1~2시간 연속 안정성 시험.

## 다른 PC에서 개발 환경 준비

### iOS 앱 (맥 필요)

```bash
brew install xcodegen
xcodegen generate
open Tessync.xcodeproj
```

- `Tessync`, `TessyncBroadcast` 두 타깃 모두 Signing & Capabilities > Team을 고른다. `xcodegen generate`를 다시 하면(파일 추가 시 필요) Team이 풀리니 다시 고른다.
- 아이폰은 개발자 모드를 켜야 하고, 무료 계정이라 7일마다 다시 설치한다.
- 새 익스텐션 코드는 아이폰에서 방송을 껐다 다시 켜야 돈다.

### ESP32 펌웨어

```bash
brew install arduino-cli
arduino-cli config init
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32
arduino-cli lib install NimBLE-Arduino
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --output-dir firmware/tessync-touch/bin firmware/tessync-touch
arduino-cli upload --fqbn esp32:esp32:esp32:PartitionScheme=huge_app -p /dev/cu.usbserial-0001 --input-dir firmware/tessync-touch/bin firmware/tessync-touch
```

- 확인한 버전: esp32 core 3.3.12, NimBLE-Arduino 2.5.2. 파티션은 `huge_app` 필수(BLE + Wi-Fi + 웹서버가 기본 1.2MB를 넘는다).
- **충전 전용 마이크로 USB 케이블로는 보드가 인식되지 않는다.** 데이터 케이블을 쓴다(맥에 `CP2102 USB to UART Bridge Controller`가 보이면 된다).
- 맥에서 시리얼 포트를 새로 열면 보드가 재시작해 BLE가 끊긴다. 포트는 DTR/RTS를 끈 채 연다(`tools/touch-bridge.py` 참고).
- 업로드해도 Wi-Fi 설정(NVS)은 지워지지 않는다.
- 윈도우 PC라면 arduino-cli 윈도우판으로 같은 명령을 쓰거나, 빌드한 `firmware/tessync-touch/bin/tessync-touch.ino.merged.bin`을 https://espressif.github.io/esptool-js/ 에서 주소 `0x0`으로 굽는다.

### ESP32 Wi-Fi 설정

- 저장된 Wi-Fi가 없거나 BOOT 버튼을 3초 누르면 설정 모드: 아이폰에서 Wi-Fi "Tessync-Touch-Setup"에 붙고 http://192.168.4.1 에서 Wi-Fi 이름, 비밀번호, 서버 주소 입력. 비밀번호 칸을 비우면 기존 값 유지.
- ESP32는 2.4GHz만 된다. 공유기는 `_5G`가 안 붙은 이름, 아이폰 핫스팟은 "호환성 최대화"를 켠다.
- **서버 주소**: 차에서는 비운다(게이트웨이 = 아이폰). 집에서 아이폰 익스텐션을 시험할 때는 아이폰의 집 Wi-Fi 주소, 맥 도구로 시험할 때는 맥 주소. USB 시리얼로 `H 주소`(비우면 게이트웨이)를 보내 바꿀 수 있다.
- 지금 보드에 저장된 값: 집 2.4GHz Wi-Fi, 서버 주소 `192.168.45.108`(아이폰 집 Wi-Fi 주소). 차에서 쓰려면 바꿔야 한다.
- 아이폰: AssistiveTouch 켜기, 추적 속도 최저, 마우스 키 끄기, 설정 > 블루투스에서 "Tessync Touch" 페어링.

### 맥 시험 도구

```bash
pip install pyserial websocket-client pillow numpy scipy
python3 tools/touch-tap.py <아이폰 IP> 0.81 0.12          # 아이폰 익스텐션의 터치 조작 시험(결과 로그 줄 출력)
python3 tools/touch-bridge.py [--tcp]                      # 보드와 직접 대화(USB 또는 Wi-Fi), 127.0.0.1:9100
python3 tools/touch-seek.py <아이폰 IP> x,y --click -v     # 맥에서 폐루프 프로토타입(브리지 필요)
```

- 아이폰 진단 로그: 방송 중 `http://<아이폰 IP>:8080/log`. 터치 관련 줄은 `touch device ...`, `tap ...`.
- 맥 Wi-Fi 주소는 가끔 바뀐다(`ipconfig getifaddr en0`).
- 웹 플레이어를 고치면 `npm i --no-save playwright && npx playwright install chromium`, `brew install ffmpeg` 후 `node tools/mock-server.mjs` + `node tools/player-test.mjs`.
