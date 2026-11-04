# 작업 인계 (2026-11-02)

다른 PC에서 이어서 작업할 때 이 문서와 `CLAUDE.md`를 먼저 읽는다. 터치 조작의 실측값과 판단 근거는 `docs/design/02-touch-control.md` 맨 아래 "실측" 절에 있다.

## 보류 (2026-11-04)

터치 조작은 동작하지만 너무 느려서(차에서 세로 약 12초, 집에서 4~7초) 개발을 보류했다. 아이폰에는 터치가 없는 `release`(`5d81776`)를 다시 설치했다. 이 브랜치(`feature/touch-control`)가 터치 작업의 최신이다.

차에서 마지막으로 본 것:
- 다크 모드에서는 포인터 색이 달라 매번 느린 비켜놓기로 찾다가 시간 초과. 색 배우기를 넣은 뒤 세로는 클릭까지 됐다.
- 가로(유튜브, orientation 6)는 영상 때문에 축을 틀리게 익혀 시간 초과. 색으로 축 익히기, 이동 거리 검사, 화면 방향 추정을 넣었지만 차에서 다시 해보지 않았다.

재개한다면 속도부터 본다. 지금 구조(이동마다 프레임 확인, 반영까지 0.3~0.4초 대기, 비켜놓기 1초 이상)로는 1~2초가 어렵다. 이동량 예측을 더 정확히 해서 확인 횟수를 줄이거나, 포인터가 어디 있는지 늘 추적해 두는 방식을 검토한다.

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

## 지금 위치: ESP32-C5 집에서 동작 확인, 차 시험 전 (2026-11-02)

오리지널 ESP32는 2.4GHz만 되어 핫스팟 호환성 최대화가 필요했고, 차에서 영상 밀림과 연결 불안정을 겪었다. 5GHz가 되는 ESP32-C5(플래시 4MB, USB 변환 칩 CH340, `/dev/cu.usbserial-210`)로 바꿨다.

집에서 확인한 것: 호환성 최대화를 끈 핫스팟에 5GHz(149번 채널, 신호 -39)로 접속, 블루투스 마우스 동시 연결, 아이폰 익스텐션 연결(8082), `touch-tap.py`로 빈 곳, 글자, 아이콘, 복사 버튼 터치 6/6 클릭(4~7초). 빠르게 4번 누르면 첫 번째와 마지막만 실행. 전송이 100% 밀린 상태에서도 포인터를 잃지 않고 클릭. 글자, 아이콘 위 정확도는 앱 판단(로그의 clicked)만 봤고 화면으로 확인한 것은 빈 곳 1건과 앱의 주소 표시다.

브랜치:

| 브랜치 | 내용 |
|---|---|
| `feature/esp32-c5` | **지금 작업할 곳.** `master` + 터치 안전장치, 가로 지원, BLE 간격 조절, C5 펌웨어 |
| `master` | 터치 연동까지(`6d5343d`). 차에서 포인터가 혼자 움직인 문제가 아직 있는 버전 |
| `release` | 터치 연동 전(`5d81776`). 건드리지 않았다 |

**아직 실기기에서 돌려보지 않은 것**: 가로 화면 터치, 테슬라 화면에서 직접 누르기, 차 안 안정성, 블루투스 음악과 동시 사용. 저장소 맨 위의 `AGENTS.md`는 커밋되지 않은 파일이고 사용자 쪽에서 만든 것으로 보여 건드리지 않았다.

### C5 다시 설정할 때

1. 데이터 케이블로 꽂고 `tools/flash-touch.sh`. 921600에서 실패하면 460800으로 자동 재시도한다(이 보드는 460800에서 된다).
2. 호환성 최대화를 끄고 개인용 핫스팟 **화면을 열어둔 채** 보드 RST(켤 때 Wi-Fi 목록을 찾는다).
3. `Tessync-Touch-Setup`에 접속, http://192.168.4.1 에서 핫스팟(5GHz 표시)을 고르고 비밀번호 입력, 서버 주소는 비움.
4. 핫스팟 화면을 벗어나고 붙은 기기가 없으면 보드가 핫스팟을 못 찾는다(`reason=201`). 테슬라가 붙어 있거나 화면을 열어두면 찾는다.
5. 블루투스 페어링, AssistiveTouch 켜기, 추적 속도 최저. 앱 방송 시작 후 로그에 `chip=ESP32-C5 band=5GHz`가 찍힌다.
6. 맥으로 시험: 맥을 핫스팟에 붙이고 IPv6를 링크-로컬 전용으로 두면 `python3 tools/touch-tap.py 172.20.10.1 0.81 0.12`.

막히면 볼 곳: 보드 시리얼 로그의 `wifi disconnected reason=N`(201 못 찾음, 15 비밀번호 등), `setup scan` 목록.

### 그 다음

1. **차에서 시험.** 앱에 나온 주소에 `/?debug=1`을 붙여 테슬라에서 연다. "터치 장치 준비됨"을 보고 세로 터치, 가로 터치, 좌표 변환(`canvasToFrame`), 블루투스 음악 동시 사용을 본다. 한 번 누르고 끝날 때까지 기다린다.
2. 터치 속도 개선(목표 1~2초, 지금 4~8초). `TouchController`에 단계별 시간을 남겨 원인부터 본다. 의심: 이동마다 고정 대기(0.45초 + 0.2초), 비켜놓기 약 1.3초, 디버그 빌드의 느린 배열 연산, 전체 프레임 탐색. Release 빌드로도 비교한다.
3. 가로 터치: 유튜브 전체화면처럼 실제로 돌아가는 앱에서. 첫 터치에 `touch axis for orientation N` 로그가 찍힌다.
4. 펌웨어 Wi-Fi 재시도가 한 번 걸러 거절된다(`sta is connecting, cannot set config`, 실제 30초 간격). 연결은 된다. 재시도 전에 연결 시도를 끊도록 고칠 것.
5. 부팅 때 `MSPI Timing: Failed to allocate dummy cacheline for PSRAM` 한 줄이 찍힌다. 동작에 문제는 없어 보이나 원인은 안 봤다.
6. 앱 홈에 터치 장치 상태 표시, ESP32 설정 안내.
7. 미러링 1~2시간 연속 안정성 시험.

### 테슬라 주소가 192.0.0.3으로 나온 날

2026-11-02 로그와 앱이 `192.0.0.3`을 보여줬다(재부팅 뒤 달라졌는지는 모른다). 핫스팟의 맥에서 `192.0.0.2`, `192.0.0.3`, `172.20.10.1` 모두 응답하고 `192.0.0.1`은 응답하지 않았다. 테슬라에서 두 주소를 직접 열어보지는 않았다. "192.0.0.2로 고정"이라고 보면 안 된다.

### 음악이 안 나오던 문제 (차에서)

방송을 켜면 음악이 안 나왔다. 방송을 끄면 나오고, 유튜브 소리는 방송 중에도 나온다. 보드 제거, AssistiveTouch 끄기, 아이폰과 테슬라 재시작, 이전 버전 앱(`c779d2e`)으로는 해결되지 않았다. **추정:** 음악 앱이 화면 녹화를 감지해 소리를 막는다. 어떤 앱인지, 정말 그 앱이 막는지는 확인하지 못했다. 앱 안내 카드에 넣어 두었다.

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
tools/flash-touch.sh                        # 칩 감지, 빌드, 업로드
tools/flash-touch.sh --build-only esp32c5   # 보드 없이 빌드만 (esp32도 가능)
```

- 확인한 버전: esp32 core 3.3.12, NimBLE-Arduino 2.5.2. 파티션은 `huge_app` 필수(BLE + Wi-Fi + 웹서버가 기본 1.2MB를 넘는다). 스크립트가 알아서 고른다.
- **충전 전용 케이블로는 보드가 인식되지 않는다.** 데이터 케이블을 쓴다(`ls /dev/cu.*`에 usbserial, wchusbserial, usbmodem 중 하나가 보이면 된다).
- 칩을 못 알아내면 BOOT를 누른 채 RST를 눌러 업로드 모드로 만들고 다시 실행한다.
- 맥에서 시리얼 포트를 새로 열면 보드가 재시작해 BLE가 끊긴다. 포트는 DTR/RTS를 끈 채 연다(`tools/touch-bridge.py` 참고).
- 업로드해도 Wi-Fi 설정(NVS)은 지워지지 않는다.
- 윈도우 PC라면 arduino-cli 윈도우판으로 같은 명령을 쓰거나, 빌드한 `firmware/tessync-touch/bin/<칩>/tessync-touch.ino.merged.bin`을 https://espressif.github.io/esptool-js/ 에서 주소 `0x0`으로 굽는다.

### ESP32 Wi-Fi 설정

- 저장된 Wi-Fi가 없거나 BOOT 버튼을 3초 누르면 설정 모드: 아이폰에서 Wi-Fi "Tessync-Touch-Setup"에 붙고 http://192.168.4.1 에서 주변 Wi-Fi 목록에서 고르고 비밀번호, 서버 주소 입력. 목록은 켤 때 한 번 찾으므로, 없으면 RST로 다시 켠다. 비밀번호 칸을 비우면 기존 값 유지.
- C5는 5GHz 핫스팟에 바로 붙는다. 오리지널 ESP32는 2.4GHz만 되어 호환성 최대화를 켜야 한다.
- **서버 주소**: 차에서는 비운다(게이트웨이 = 아이폰). 집에서 아이폰 익스텐션을 시험할 때는 아이폰의 집 Wi-Fi 주소, 맥 도구로 시험할 때는 맥 주소. USB 시리얼로 `H 주소`(비우면 게이트웨이)를 보내 바꿀 수 있다.
- 설정은 보드마다 따로 저장된다. 새 C5는 비어 있어 처음 켜면 설정 모드다.
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
