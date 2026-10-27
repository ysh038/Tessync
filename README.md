# Tessync

아이폰 화면을 핫스팟으로 연결한 테슬라 내장 브라우저에 미러링하는 iOS 앱. 목표는 장시간 끊기지 않는 것이다.

- 설계: [docs/design/01-architecture.md](docs/design/01-architecture.md)
- 터치 조작(ESP32): [docs/design/02-touch-control.md](docs/design/02-touch-control.md)
- 사전조사: [docs/research](docs/research)

## 구조

| 경로 | 내용 |
|---|---|
| `App/` | 메인 앱 (SwiftUI). 방송 시작 버튼, 접속 주소, 체크리스트, 진단 로그 |
| `Broadcast/` | 방송 익스텐션. 화면 캡처 → 다운스케일 → 하드웨어 JPEG → WebSocket 전송, HTTP 서버 |
| `Shared/` | 두 타깃 공용 상수 |
| `web/` | 테슬라 브라우저용 플레이어(`index.html`, `player.js`)와 점검 페이지(`probe.html`). 익스텐션 번들에 포함됨 |
| `tools/` | iPhone 없이 플레이어를 테스트하는 가짜 서버와 자동 테스트 |

포트: 8080(HTTP), 8081(WebSocket). 핫스팟 주소는 보통 `172.20.10.1`.

## 맥에서 빌드

0. 저장소 받기: `git clone https://github.com/ysh038/Tessync.git && cd Tessync`
1. `brew install xcodegen`
2. `project.yml`에서 `BUNDLE_ID_PREFIX`를 겹치지 않는 값으로 바꾼다(예: `com.ysh038`). `DEVELOPMENT_TEAM`은 빈칸으로 둬도 된다.
3. `xcodegen generate` 후 `Tessync.xcodeproj`를 연다.
4. 두 타깃(`Tessync`, `TessyncBroadcast`) 모두 Signing & Capabilities > Team에서 본인 팀(예: "상훈 유 (Personal Team)")을 고른다. `xcodegen generate`를 다시 하면 초기화되므로, 매번 고르기 싫으면 Build Settings에서 `DEVELOPMENT_TEAM` 값(10자리)을 확인해 yml에 적는다.
5. 아이폰: 설정 > 개인정보 보호 및 보안 > **개발자 모드** 켜기(재부팅됨).
6. 아이폰을 연결하고 `Tessync` 스킴으로 실행한다. 처음에는 설정 > 일반 > VPN 및 기기 관리에서 개발자를 신뢰해야 한다.

참고:
- **무료 계정(Personal Team)**: App Group을 못 써서 기본 설정은 App Group 없이 빌드한다. 진단 로그는 방송 중에 아이폰 Safari에서 `http://localhost:8080/log`(또는 테슬라 브라우저에서 `http://172.20.10.1:8080/log`)로 본다. 무료 계정으로 설치한 앱은 7일 뒤 만료되어 다시 설치해야 한다.
- 유료 계정이면 `project.yml` 맨 위 주석대로 App Group을 추가하면 앱 안에서 로그를 볼 수 있다.
- **이 코드는 리눅스에서 작성되어 아직 Xcode로 빌드해 보지 않았다.** 컴파일 오류가 나면 오류 메시지를 그대로 알려주면 된다.
- 첫 접속 때 로컬 네트워크 권한 창이 뜨면 허용한다.

## 차에서 테스트하는 순서

1. 아이폰: 개인용 핫스팟 켜기, 자동 잠금 "안 함", 저전력 모드 끄기
2. 테슬라: Wi-Fi에서 아이폰 핫스팟에 연결
3. 앱: "화면 방송 시작" → Tessync 선택 → 방송 시작
4. 테슬라 브라우저: `http://172.20.10.1:8080/probe` 열기
   - 표를 사진으로 찍고 "결과 보내기"를 누른다(앱의 진단 로그에 저장됨)
   - "테스트 시작"을 누르고 주행해 본다. 주행 중에 canvas와 video가 멈추는지 확인
5. 테슬라 브라우저: `http://172.20.10.1:8080` 열기 → 미러링 확인
   - 오른쪽 위 모서리를 누르면 디버그 정보(수신 fps, 재연결 횟수, 폰 메모리)가 보인다
6. 끊김이 생기면 진단 로그(`/log`)를 저장해 둔다

## iPhone 없이 플레이어 테스트

ffmpeg가 필요하다(`brew install ffmpeg`, 테스트 프레임 생성용).

```sh
node tools/mock-server.mjs          # http://localhost:8080 을 브라우저로 열기
npx playwright install chromium     # 처음 한 번
npm i -D playwright && node tools/player-test.mjs
```

`player-test.mjs`는 강제 끊김, 멈춘 연결, 방송 종료, 화면 회전, 40초 메모리 증가를 확인한다.

## 현재 상태와 다음 할 일

- [x] 사전조사, 설계, 터치 조작 조사
- [x] MVP 코드 작성 (iOS 앱 + 방송 익스텐션 + 웹 플레이어)
- [x] 웹 플레이어 끊김 복구 자동 테스트 통과 (리눅스 Chromium)
- [ ] **맥에서 첫 빌드** (아직 Xcode로 빌드해 본 적 없음)
- [ ] 아이폰 실기기에서 방송 시작, 하드웨어 JPEG 인코더 동작 확인
- [ ] 차에서 점검 페이지 실행 (Chromium 버전, 주행 중 재생 여부, D 기어 전환 시 Wi-Fi 유지)
- [ ] 차에서 미러링 2시간 연속 테스트, 진단 로그 확인
- [ ] 화질 개선 (H.264/H.265, HTTPS 인증서) 또는 ESP32 터치 조작

## 프로토콜

- 바이너리: `[0]=1(JPEG) [1]=EXIF orientation(1/3/6/8) [2...]=JPEG`
- 텍스트(서버 → 브라우저): `{"t":"hb","seq",...,"lvl","fps","mem"}` 1초마다, `{"t":"bye"}` 방송 종료 시
- 텍스트(브라우저 → 서버): `{"t":"hello","ua","w","h","dpr"}` 접속 시
- 브라우저는 3초 동안 아무 메시지도 없으면 연결을 버리고 재접속한다
