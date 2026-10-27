# 테슬라 화면 미러링 앱 사전조사

조사일: 2026-10-27. 웹 검색 결과(스토어 설명, 커뮤니티 글 요약) 기준이며, 커뮤니티/스토어 페이지 본문은 직접 열람하지 못했다. 가격·기능은 설치 전 스토어에서 재확인 필요.

## 공통 동작 방식

모든 앱이 같은 구조다.

1. 폰 핫스팟에 테슬라를 Wi-Fi로 연결
2. 폰 안에서 로컬 웹서버 실행, 화면을 인코딩해서 스트리밍
3. 테슬라 내장 브라우저로 폰의 로컬 주소에 접속해서 영상 표시

트래픽이 폰-차 사이 로컬 네트워크에서만 오가므로 모바일 데이터를 추가로 쓰지 않는다. 코덱은 차량 하드웨어에 따라 MCU3는 H.265, MCU2는 MJPEG/H.264를 쓰는 경우가 많다.

## 안드로이드 앱

| 앱 | 가격 | 특징 |
|---|---|---|
| **Tesor (테서)** | 1회 구매 약 15,000원 (USD 14.99) | 가상 세컨드 디스플레이: 폰과 차 화면을 따로 사용 (차에는 티맵/네이버지도 전체화면, 폰은 다른 앱). 핫스팟 자동 연결, 자동 미러링. Shizuku 권한 필요. 국내 블로그에서 "필수 앱"으로 소개됨 |
| Tesla Mirror & HUD (MOMEE HUD) | 월 2,500원 | 국내 개발자. HEVC 하드웨어 가속, 동적 비트레이트. 터치 제어, HUD 오버레이. 폰 화면이 꺼지면 미러링 불가 |
| TesMirror (puppytiger) | 미확인 | 미러링과 내비게이션 |
| Tesla Display (오픈소스) | 무료/인앱 | `io.github.blackpill.tesladisplay`. 접근성 서비스로 테슬라 화면에서 폰 터치 제어 |
| TeslaMirror (hustmobile) | 유료 | iOS판 TslaMirror와 같은 개발사 |
| TeslaAA | 유료 | Android Auto 화면을 테슬라 브라우저로 미러링 |
| Tesla Android Project | 오픈소스 + 하드웨어 | 라즈베리파이에 안드로이드를 올려서 브라우저로 표시. 폰 앱이 아님 |

"엄청 좋은 앱"은 **Tesor** 가능성이 가장 높다. 단순 미러링이 아니라 **가상 디스플레이**로 차량 전용 화면을 따로 만들어 주는 것이 다른 앱과의 핵심 차별점이다.

## iOS 앱

| 앱 | 가격 | 메모 |
|---|---|---|
| FluxCast (PlanetX Soft) | 무료 + 인앱 (사용자 경험상 유료) | 300ms 미만 지연 주장. MCU3는 H.265, MCU2는 MJPEG. 차량 데이터 대시보드(FluxMate) |
| TslaMirror | 무료 + 인앱, 1주 체험 | 가장 오래된 앱. 지연이 가장 적다는 리뷰 있음. 평점 3.7 |
| TesDisplay | 인앱 | 평점 2.4. 지연·끊김 리뷰, 과금 관련 불만 |
| Car Cast - Screen Mirror | 무료 플랜 있음 (구독 없음) | Model S/3/X/Y 지원 |
| TesMirror (iOS) | $5.99 | D 기어 진입 후 핫스팟 재연결 필요 |
| AirTesla | 무료 | 평점 2.4 |
| EnMirror | 무료 분량 + Pro 구독 | QR 코드 연결 |

## iOS가 어려운 이유 (앱 개발 관점)

안드로이드 개발자도 "아이폰은 워낙 힘들다"고 언급했다. 주요 제약:

- **화면 캡처 수단이 ReplayKit Broadcast Upload Extension 하나뿐.** 메인 앱은 백그라운드에서 중단되므로 캡처, 인코딩, 웹서버를 모두 익스텐션 프로세스 안에서 돌려야 한다.
- **익스텐션 메모리 한도가 약 50MB.** 인코더와 서버를 가볍게 유지해야 한다. (Apple 개발자 포럼 기준 알려진 수치, 버전별 재확인 필요)
- **화면 잠금 시 방송 중단.** 잠그면 다시 방송을 시작해야 한다 (TslaMirror 스토어 설명에 명시).
- **터치 주입 API가 없음.** 테슬라 화면에서 아이폰을 조작할 수 없어서 보기 전용이 된다. 안드로이드는 접근성 서비스로 가능.
- **가상 세컨드 디스플레이 불가.** Tesor 방식(차 화면과 폰 화면 분리)은 iOS에서 구현할 수 없다. 항상 폰 화면 그대로 미러링.
- **DRM 앱(넷플릭스 등)은 검은 화면.** 모든 앱 공통.
- **오디오:** ReplayKit은 앱 오디오를 함께 주지만, MJPEG 모드 앱들은 오디오를 블루투스로 따로 보낸다.

## 참고할 오픈소스 (iOS)

- [fortres/tesla-mirror](https://github.com/fortres/tesla-mirror): 핫스팟 + 로컬 서버, H.264를 WebSocket으로 전송, 브라우저에서 MSE로 재생. 초기 단계
- [isotech07/yolcu-tv](https://github.com/isotech07/yolcu-tv): ReplayKit 익스텐션 안에서 H.264 하드웨어 인코딩, 8090 포트 서버, jmuxer로 재생
- [Skirozik/tesycast](https://github.com/Skirozik/tesycast): 로컬 서버 대신 LiveKit(WebRTC) 서버 경유. 핫스팟 불필요
- [P9SOFT/P9iOSAppScreenMirroring](https://github.com/P9SOFT/P9iOSAppScreenMirroring): iOS 화면을 WebSocket으로 브라우저에 전송
- [TheTorchicken/SI-DEMON-TV-Source](https://github.com/TheTorchicken/SI-DEMON-TV-Source): ReplayKit + H.264, JPEG 폴백 (비상업 라이선스)

## 출처

- [FluxCast App Store](https://apps.apple.com/py/app/fluxcast-car-screen-mirror/id6762375547)
- [TslaMirror App Store](https://apps.apple.com/us/app/tslamirror/id1542447409), [TslaMirror FAQ](https://teslamirror.com/faq-ios)
- [TesDisplay App Store](https://apps.apple.com/us/app/tesdisplay-screen-mirror/id6469987744)
- [Car Cast App Store](https://apps.apple.com/us/app/car-cast-screen-mirror/id6474124223)
- [Tesla Display Google Play](https://play.google.com/store/apps/details?id=io.github.blackpill.tesladisplay&hl=en_US)
- [TesMirror Google Play](https://play.google.com/store/apps/details?id=com.puppytiger.tesmirror&hl=ko)
- [Tesor 사용 후기 (블로그)](https://www.bblogggg.com/2026/03/tesla-android-tesor-app-guide.html?m=1)
- [Tesor 구입 후기 (클리앙)](https://www.clien.net/service/board/cm_car/19200045)
- [Tesor - APPDOVO](https://appdovo.com/apps/tesor/)
- [테슬라 미러링 앱 개발 글 (다모앙)](https://damoang.net/car/124864), [근황 글](https://damoang.net/car/132640)
- [테슬라 미러링 앱 개발 글 (클리앙)](https://www.clien.net/service/board/cm_car/19165450)
- [Raspberry Pi CarPlay hack (Tesla Android Project)](https://www.raspberrypi.com/news/raspberry-pi-carplay-hack-works-in-any-tesla/)
