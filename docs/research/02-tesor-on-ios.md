# iOS에서 Tesor 방식이 가능한가

조사일: 2026-10-27. 목표는 Tesor처럼 **차 화면에는 티맵/네이버지도, 폰은 다른 앱을 따로 사용**하는 것이다.

## Tesor가 안드로이드에서 되는 이유

- Shizuku로 안드로이드의 숨김 API(`DisplayManager`)를 호출해서 **가상 디스플레이**를 만든다.
- 다른 앱(티맵 등)을 그 가상 디스플레이에 띄운다.
- 그 가상 디스플레이를 인코딩해서 5GHz 핫스팟으로 테슬라 브라우저에 전송한다.
- 루팅은 필요 없지만 Shizuku(adb 권한) 설정은 필요하다.

## 결론

**iPhone 앱 하나로 Tesor와 똑같이 만드는 것은 불가능하다.** 다만 **CarPlay를 경유하면 같은 경험을 얻을 수 있고**, 이건 이미 상용 제품이 있다.

## 방안별 검토

### 1. iOS 앱만으로 가상 디스플레이 만들기: 불가능

- iOS에는 가상 디스플레이를 만드는 공개 API가 없다.
- 외부 디스플레이(`windowExternalDisplayNonInteractive` 씬)는 실제 디스플레이가 연결됐을 때(유선 또는 AirPlay) 시스템이 주는 것이고, 앱이 만들 수 없다.
- 설령 외부 디스플레이가 있어도 **각 앱이 직접 지원해야** 별도 화면이 나온다. 지원하지 않는 앱은 그냥 미러링된다. 다른 앱을 강제로 그 화면에 띄울 방법도 없다.
- Shizuku 같은 우회 수단이 없다. 샌드박스 때문에 다른 앱 제어가 불가능하다.

### 2. 탈옥 / TrollStore: 기술적으로는 일부 가능, 배포는 불가능

- 탈옥 트윅(예: CarBridge)으로 비공개 API를 쓰면 가능성은 있다.
- 최신 iOS는 탈옥이 사실상 불가능하고 앱스토어 배포도 안 되므로 제품으로는 의미가 없다.

### 3. CarPlay 박스 (상용, 지금 구매 가능): 사실상 iPhone판 Tesor

CarPlay 자체가 "폰이 별도 화면을 렌더링해서 차에 보내는" 구조라서 Tesor와 같은 경험이 된다. 티맵, 카카오내비, 네이버지도가 CarPlay를 지원한다(앱별 지원 여부는 확인 필요).

- 제품: Carlinkit T2C, Tesery($76.99), SpaceBox($139.99) 등
- 구조: 박스를 테슬라 USB에 꽂고, 아이폰과 무선 CarPlay로 연결, 테슬라가 박스 Wi-Fi에 붙어 브라우저로 CarPlay 화면을 연다.
- 단점: 지연, 재연결 문제, 핫스팟 의존, 판매처 지원이 약하다는 사용자 평. 독립 리뷰가 부족하다.
- 필요한 이유: CarPlay 수신측은 Apple 인증칩(MFi)이 필수라서 별도 장치가 꼭 있어야 한다.

### 4. DIY CarPlay 수신기: 가능, 단 취미용

- 라즈베리파이 + Carlinkit 동글(CPC200-CCPA) + [react-carplay](https://github.com/rhysmorgan134/react-carplay) / [pi-carplay](https://github.com/RGreeneRI/pi-carplay)로 CarPlay를 받아서 테슬라 브라우저로 보낸다. Tesla Android Project가 이 방식으로 시연했다.
- 동글 없는 소프트웨어 수신기도 있다: [DiPlay](https://github.com/shihabal3amri/DiPlay/wiki)(안드로이드), [PlayPort](https://github.com/youcci/playport/wiki)(맥에서 CarPlay를 받아 브라우저로 서빙). 둘 다 **Carlinkit 펌웨어에서 추출한 인증 정보를 빌려 쓰는 방식**이라 iOS 업데이트로 막힐 수 있고, 상용 배포는 법적 위험이 크다.
- 아이폰 자신이 CarPlay 수신기가 될 수는 없다. CarPlay는 다른 장치와 연결해야 하고, iOS 앱은 USB 동글에도 접근할 수 없다.
- 테슬라 브라우저가 WebUSB로 테슬라 USB에 꽂은 동글을 직접 읽는 방안도 생각해 봤지만, 지원 여부를 확인한 자료가 없다. 가능성은 낮다.

### 5. 테슬라 순정 CarPlay: 대기 중

- 2026년 10월 기준 미출시. 공식 일정도 없다.
- 보도상으로는 창 모드로, 신형 AMD 라이젠 차량 위주로 나올 가능성이 있다.
- 나오면 위의 모든 방안이 의미가 줄어든다.

### 6. AirPlay 수신기 경유: 효과 제한적

- 라즈베리파이에 UxPlay(AirPlay 수신기)를 올리고 테슬라 브라우저로 재전송할 수 있다.
- 화면 미러링은 결국 폰 화면 그대로다. 유튜브 같은 영상의 AirPlay 전송만 폰과 분리된다.

### 7. 자체 콘텐츠 컴패니언 앱: 부분적으로 가능, 앱스토어 배포 가능

다른 앱의 화면은 못 보내지만, **우리 앱이 직접 만든 화면**은 폰과 독립적으로 차에 띄울 수 있다.

- 폰 앱이 백그라운드 위치 모드로 계속 실행되면서 로컬 웹서버를 운영한다(백그라운드 소켓 유지는 검증 필요).
- 테슬라 브라우저에는 우리 웹 UI를 띄운다. 예를 들어 TMAP API로 길 안내, 단속카메라, 현재 재생 곡 정보, 알림 등.
- 폰은 잠그거나 다른 앱을 써도 된다. 화면 녹화(ReplayKit)를 안 쓰므로 잠금 문제가 없다.
- 한계: 티맵 앱 그 자체가 아니라 API로 다시 만든 화면이다. API 비용과 이용약관을 확인해야 한다.

## 정리

| 방안 | Tesor 같은 분리 화면 | 다른 앱(티맵 등) | 추가 장치 | 지금 가능 |
|---|---|---|---|---|
| iOS 앱 단독 가상 디스플레이 | X | X | 없음 | 불가능 |
| 탈옥 | 일부 | 일부 | 없음 | 사실상 불가능 |
| **CarPlay 박스** | O | O (CarPlay 지원 앱) | 박스 | **가능** |
| DIY CarPlay 수신기 | O | O | 파이 + 동글 | 가능 (취미용) |
| 테슬라 순정 CarPlay | O | O | 없음 | 미출시 |
| AirPlay 수신기 | X (영상만) | X | 파이 | 가능 |
| 자체 컴패니언 앱 | O | X (자체 화면만) | 없음 | 가능 |
| 미러링 (FluxCast 류) | X | O (폰 화면 그대로) | 없음 | 가능 |

## 출처

- [Tesor Google Play](https://play.google.com/store/apps/details?id=com.arter97.tesor&hl=en_IN)
- [Tesor 소개 기사 (tparts)](https://www.tparts.com/blogs/tesla-knowledge-blogs/android-screen-mirroring-breakthrough-for-tesla-korean-developer-creates-tesor-app)
- [omnilink Shizuku 가상 디스플레이 이슈](https://github.com/manideepanasuri/omnilink/issues/9), [android-display-extend](https://github.com/jqssun/android-display-extend)
- [Apple 포럼: 외부 디스플레이 씬](https://developer.apple.com/forums/thread/719762), [useyourloaf: 외부 화면](https://useyourloaf.com/blog/ios-scene-delegates-and-external-screens/)
- [Tesery CarPlay 어댑터](https://www.tesery.com/products/tesla-wireless-apple-carplay-adapter), [Carlinkit T2C](https://carlinkitcarplay.com/de/products/carlinkit-t2c-tesla-wireless-apple-carplay-adapter), [어댑터 비교 (teslahubs)](https://teslahubs.com/pages/best-tesla-carplay-adapters-2026), [GIGA 가이드](https://www.giga.de/tech/carplay-im-tesla-nutzen-so-funktioniert-es-mit-dem-richtigen-adapter--01K5DQZTNJ76TNRK79PRYVCQDS)
- [react-carplay](https://github.com/rhysmorgan134/react-carplay), [pi-carplay](https://github.com/RGreeneRI/pi-carplay)
- [DiPlay](https://github.com/shihabal3amri/DiPlay/wiki), [PlayPort](https://github.com/youcci/playport/wiki), [9to5Mac: CarPlay 보안 구조](https://9to5mac.com/2024/11/07/security-bite-mechanics-of-apple-carplay/)
- [Raspberry Pi CarPlay hack](https://www.raspberrypi.com/news/raspberry-pi-carplay-hack-works-in-any-tesla/)
- [Not a Tesla App: CarPlay still in the works](https://www.notateslaapp.com/news/3559/tesla-carplay-support-still-in-the-works), [autoevolution: 2026 봄 업데이트에 CarPlay 없음](https://www.autoevolution.com/news/tesla-launches-2026-spring-update-with-self-driving-app-and-revamped-grok-but-no-apple-carplay-268535.html)
