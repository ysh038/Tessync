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

1. `brew install xcodegen`
2. `project.yml`에서 `BUNDLE_ID_PREFIX`(예: `com.내이름`)와 `DEVELOPMENT_TEAM`(Xcode > Settings > Accounts의 Team ID)을 바꾼다.
3. `xcodegen generate` 후 `Tessync.xcodeproj`를 연다.
4. 아이폰을 연결하고 `Tessync` 스킴으로 실행한다. 아이폰에서 설정 > 일반 > VPN 및 기기 관리에서 개발자를 신뢰해야 할 수 있다.

참고:
- **App Group**은 진단 로그 공유에만 쓴다. 무료 Apple 계정에서 App Group 서명이 안 되면 `project.yml`의 `entitlements` 두 군데를 지우고 다시 생성한다(로그만 비활성화됨). 무료 계정은 7일마다 다시 설치해야 한다.
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
6. 끊김이 생기면 앱 > 진단 로그를 공유해 준다

## iPhone 없이 플레이어 테스트

ffmpeg가 필요하다(`brew install ffmpeg`, 테스트 프레임 생성용).

```sh
node tools/mock-server.mjs          # http://localhost:8080 을 브라우저로 열기
npx playwright install chromium     # 처음 한 번
npm i -D playwright && node tools/player-test.mjs
```

`player-test.mjs`는 강제 끊김, 멈춘 연결, 방송 종료, 화면 회전, 40초 메모리 증가를 확인한다.

## 프로토콜

- 바이너리: `[0]=1(JPEG) [1]=EXIF orientation(1/3/6/8) [2...]=JPEG`
- 텍스트(서버 → 브라우저): `{"t":"hb","seq",...,"lvl","fps","mem"}` 1초마다, `{"t":"bye"}` 방송 종료 시
- 텍스트(브라우저 → 서버): `{"t":"hello","ua","w","h","dpr"}` 접속 시
- 브라우저는 3초 동안 아무 메시지도 없으면 연결을 버리고 재접속한다
