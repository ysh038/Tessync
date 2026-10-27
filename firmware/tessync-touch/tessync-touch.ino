// Tessync Touch: ESP32를 BLE 마우스로 만들고, 명령을 받아 아이폰 포인터를 움직인다.
// 아이폰은 설정 > 손쉬운 사용 > 터치 > AssistiveTouch를 켜야 마우스 포인터가 생긴다.
// 설계: docs/design/02-touch-control.md
//
// 명령 통로
//   - USB 시리얼 (115200)
//   - Wi-Fi: 저장된 Wi-Fi(차에서는 아이폰 핫스팟)에 붙은 뒤 서버의 8082 포트로 TCP 연결을 건다.
//     서버 주소를 비워두면 게이트웨이(핫스팟이면 아이폰)로 건다. 1초마다 "hb" 줄을 보낸다(핫스팟 90초 무통신 끊김 방지).
//   - Wi-Fi 설정: 저장된 Wi-Fi가 없거나 BOOT 버튼을 3초 누르면 "Tessync-Touch-Setup" Wi-Fi를 띄운다.
//     (BOOT를 누른 채 전원을 넣으면 펌웨어 업로드 모드로 켜지므로, 켜진 뒤에 누른다.)
//     거기 접속해 http://192.168.4.1 에서 Wi-Fi 이름, 비밀번호, 서버 주소를 입력한다. ESP32는 2.4GHz만 된다.
//
// 명령 (줄 단위)
//   m dx dy   상대 이동 (픽셀이 아니라 마우스 이동량. 한 번에 ±127씩 나눠 보낸다)
//   g dx dy s 걸음 이동: x축, y축을 따로, 크기 s짜리 보고서로 나눠 보낸다(마지막은 나머지).
//             iOS 포인터 가속은 보고서 하나의 크기에 따라 달라지므로, 걸음 크기를 고정하면 이동 거리가 일정하다.
//   c         클릭
//   d / u     버튼 누르기 / 떼기 (드래그, 길게 누르기)
//   w n       스크롤
//   h         왼쪽 위 모서리로 보내기 (좌표 원점 맞추기)
//   s         연결 상태
//   H host    서버 주소만 바꾸기(빈 값이면 게이트웨이). 개발 중 맥 주소가 바뀌었을 때 쓴다.
//
// 시리얼 없이 시험하기: 보드의 BOOT 버튼을 짧게 누르면 포인터를 왼쪽 위로 보낸 뒤 사각형을 그린다(클릭은 안 함).

#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>

static const char* DEVICE_NAME = "Tessync Touch";
static const uint8_t REPORT_ID = 1;
// 보고서 사이 간격. BLE 연결 간격(iOS 최소 15ms)보다 빨리 보내면 전송 버퍼가 차서 일부가 버려진다.
static const int REPORT_GAP_MS = 15;
static const int NOTIFY_RETRIES = 10;
// DevKitC의 BOOT 버튼. 누르면 LOW.
static const int BOOT_BUTTON_PIN = 0;

// 3버튼 + X/Y + 휠, 각 1바이트 부호 있는 상대값.
static uint8_t reportMap[] = {
  0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, REPORT_ID,
  0x09, 0x01, 0xA1, 0x00,
  0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
  0x95, 0x01, 0x75, 0x05, 0x81, 0x03,
  0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06,
  0xC0, 0xC0
};

static NimBLEHIDDevice* hid = nullptr;
static NimBLECharacteristic* input = nullptr;
static volatile bool connected = false;
static uint8_t buttons = 0;
// 재시도까지 실패해 버려진 보고서 수. 명령 응답(ok)에 붙여 알린다.
static int droppedReports = 0;

static const char* SETUP_AP_NAME = "Tessync-Touch-Setup";
static const uint16_t CONTROL_PORT = 8082;
static Preferences prefs;
static String wifiName, wifiPassword, serverHost;
static WebServer* setupServer = nullptr;
static WiFiClient control;
static unsigned long lastConnectAttempt = 0;
static unsigned long lastHeartbeat = 0;
// 명령 응답을 보낼 곳. 명령이 들어온 통로로 답한다.
static Print* out = &Serial;

class ServerCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    Serial.printf("ble connected %s\n", info.getAddress().toString().c_str());
  }
  void onAuthenticationComplete(NimBLEConnInfo& info) override {
    connected = info.isEncrypted();
    Serial.printf("ble paired encrypted=%d\n", connected);
  }
  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& info, int reason) override {
    connected = false;
    Serial.printf("ble disconnected reason=%d\n", reason);
  }
};

static void sendReport(int8_t dx, int8_t dy, int8_t wheel) {
  if (!connected) return;
  uint8_t report[4] = { buttons, (uint8_t)dx, (uint8_t)dy, (uint8_t)wheel };
  bool sent = false;
  for (int attempt = 0; attempt < NOTIFY_RETRIES && !sent; attempt++) {
    sent = input->notify(report, sizeof(report));
    if (!sent) delay(5);
  }
  if (!sent) droppedReports++;
  delay(REPORT_GAP_MS);
}

static void move(long dx, long dy) {
  while (dx != 0 || dy != 0) {
    int8_t stepX = (int8_t)constrain(dx, -127, 127);
    int8_t stepY = (int8_t)constrain(dy, -127, 127);
    sendReport(stepX, stepY, 0);
    dx -= stepX;
    dy -= stepY;
  }
}

static void stepAxis(long amount, long stepSize, bool horizontal) {
  long sign = amount < 0 ? -1 : 1;
  long remaining = labs(amount);
  while (remaining > 0) {
    long step = min(remaining, stepSize);
    sendReport(horizontal ? (int8_t)(sign * step) : 0, horizontal ? 0 : (int8_t)(sign * step), 0);
    remaining -= step;
  }
}

static void setButtons(uint8_t value) {
  buttons = value;
  sendReport(0, 0, 0);
}

static void handleCommand(String line) {
  line.trim();
  if (line.length() == 0) return;
  char command = line.charAt(0);
  long a = 0, b = 0, c = 0;
  sscanf(line.c_str() + 1, "%ld %ld %ld", &a, &b, &c);

  if (command == 'H') {
    serverHost = line.substring(1);
    serverHost.trim();
    prefs.putString("host", serverHost);
    control.stop();
    lastConnectAttempt = 0;
    out->printf("ok host=%s\n", serverHost.length() ? serverHost.c_str() : "(gateway)");
    return;
  }
  if (command == 's') {
    out->printf("status connected=%d wifi=%d control=%d\n", connected, WiFi.status() == WL_CONNECTED, control.connected());
    return;
  }
  if (!connected) {
    out->println("error not connected");
    return;
  }
  switch (command) {
    case 'm': move(a, b); break;
    case 'g': {
      long stepSize = constrain(c, 1, 127);
      stepAxis(a, stepSize, true);
      stepAxis(b, stepSize, false);
      break;
    }
    case 'c': setButtons(1); delay(40); setButtons(0); break;
    case 'd': setButtons(1); break;
    case 'u': setButtons(0); break;
    case 'w': sendReport(0, 0, (int8_t)constrain(a, -127, 127)); break;
    case 'h': move(-5000, -5000); break;
    default: out->println("error unknown command"); return;
  }
  out->printf("ok dropped=%d\n", droppedReports);
  droppedReports = 0;
}

// BOOT 버튼 시험: 포인터가 왼쪽 위 모서리로 간 뒤 사각형을 그리면 BLE 마우스가 동작하는 것.
static void runDemo() {
  if (!connected) {
    Serial.println("demo: not connected");
    return;
  }
  Serial.println("demo: start");
  move(-5000, -5000);
  delay(500);
  const long side = 300;
  const long path[][2] = { { side, side }, { side, 0 }, { 0, side }, { -side, 0 }, { 0, -side } };
  for (auto& step : path) {
    move(step[0], step[1]);
    delay(400);
  }
  Serial.println("demo: done");
}

// MARK: Wi-Fi 설정 모드

static String htmlEscape(const String& text) {
  String result = text;
  result.replace("&", "&amp;");
  result.replace("\"", "&quot;");
  result.replace("<", "&lt;");
  return result;
}

static void startSetupMode() {
  WiFi.mode(WIFI_AP);
  WiFi.softAP(SETUP_AP_NAME);
  setupServer = new WebServer(80);
  setupServer->on("/", HTTP_GET, [] {
    String page =
      "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
      "<title>Tessync Touch</title><body style='font-family:-apple-system;padding:20px;max-width:420px'>"
      "<h2>Tessync Touch Wi-Fi 설정</h2>"
      "<p>차에서는 아이폰 핫스팟 이름과 비밀번호를 넣고 서버 주소는 비워두세요. "
      "공유기는 2.4GHz 이름을 넣으세요(이름에 5G가 붙은 것은 안 됩니다). "
      "아이폰 핫스팟은 '호환성 최대화'를 켜야 보입니다(ESP32는 2.4GHz만 지원).</p>"
      "<form method=post action=/save>"
      "<p>Wi-Fi 이름<br><input name=ssid style='width:100%;font-size:17px' value=\"" + htmlEscape(wifiName) + "\"></p>"
      "<p>비밀번호 (비우면 기존 비밀번호)<br><input name=pass type=password style='width:100%;font-size:17px'></p>"
      "<p>서버 주소 (비우면 핫스팟 아이폰)<br><input name=host style='width:100%;font-size:17px' value=\"" + htmlEscape(serverHost) + "\"></p>"
      "<p><button style='font-size:17px;padding:10px 20px'>저장하고 재시작</button></p></form>";
    setupServer->send(200, "text/html; charset=utf-8", page);
  });
  setupServer->on("/save", HTTP_POST, [] {
    prefs.putString("ssid", setupServer->arg("ssid"));
    // 비밀번호를 비워두면 기존 값을 쓴다(Wi-Fi 이름만 바꿀 때).
    if (setupServer->arg("pass").length() > 0) prefs.putString("pass", setupServer->arg("pass"));
    prefs.putString("host", setupServer->arg("host"));
    prefs.putBool("setup", false);
    setupServer->send(200, "text/html; charset=utf-8",
                      "<meta charset=utf-8><body style='font-family:-apple-system;padding:20px'>저장했어요. 재시작합니다.");
    delay(500);
    ESP.restart();
  });
  setupServer->begin();
  Serial.printf("setup mode: join Wi-Fi \"%s\" and open http://192.168.4.1\n", SETUP_AP_NAME);
}

// MARK: Wi-Fi 명령 통로

static void serviceControl() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (!control.connected()) {
    if (millis() - lastConnectAttempt < 2000) return;
    lastConnectAttempt = millis();
    IPAddress target = WiFi.gatewayIP();
    if (serverHost.length() > 0 && !target.fromString(serverHost)) {
      WiFi.hostByName(serverHost.c_str(), target);
    }
    if (control.connect(target, CONTROL_PORT, 1000)) {
      control.setNoDelay(true);
      control.printf("hello tessync-touch ble=%d\n", connected);
      Serial.printf("control connected %s:%d\n", target.toString().c_str(), CONTROL_PORT);
    }
    return;
  }
  static String controlLine;
  while (control.available()) {
    char ch = (char)control.read();
    if (ch == '\n') {
      out = &control;
      handleCommand(controlLine);
      out = &Serial;
      controlLine = "";
    } else {
      controlLine += ch;
    }
  }
  if (millis() - lastHeartbeat >= 1000) {
    lastHeartbeat = millis();
    control.printf("hb ble=%d\n", connected);
  }
}

static void loadSettings() {
  prefs.begin("tessync", false);
  wifiName = prefs.getString("ssid", "");
  wifiPassword = prefs.getString("pass", "");
  serverHost = prefs.getString("host", "");
}

// 설정 모드는 저장할 때까지 유지한다(도중에 재시작해도 다시 설정 모드로 켜진다).
static bool needsSetup() {
  return wifiName.length() == 0 || prefs.getBool("setup", false);
}

static void startWiFi() {
  // BLE와 Wi-Fi를 같이 쓰면 ESP32는 Wi-Fi 절전(modem sleep)을 켜둬야 한다.
  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(wifiName.c_str(), wifiPassword.c_str());
  Serial.printf("wifi joining \"%s\", server %s\n", wifiName.c_str(), serverHost.length() ? serverHost.c_str() : "(gateway)");
}

void setup() {
  Serial.begin(115200);
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
  loadSettings();
  if (needsSetup()) {
    // 설정 모드에서는 BLE를 켜지 않는다. BLE와 Wi-Fi AP를 같이 켜면 아이폰이 AP에 붙는 순간 재시작했다.
    startSetupMode();
    return;
  }
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);

  hid = new NimBLEHIDDevice(server);
  input = hid->getInputReport(REPORT_ID);
  hid->setManufacturer("Tessync");
  hid->setPnp(0x02, 0xe502, 0xa111, 0x0210);
  hid->setHidInfo(0x00, 0x01);
  hid->setReportMap(reportMap, sizeof(reportMap));
  hid->setBatteryLevel(100);
  server->start();

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->setName(DEVICE_NAME);
  advertising->setAppearance(0x03C2);  // HID 마우스
  advertising->addServiceUUID(hid->getHidService()->getUUID());
  advertising->enableScanResponse(true);
  advertising->start();
  Serial.println("ready (advertising as Tessync Touch)");
  startWiFi();
}

void loop() {
  if (setupServer) setupServer->handleClient();
  serviceControl();
  static wl_status_t lastWiFi = WL_IDLE_STATUS;
  if (WiFi.status() != lastWiFi) {
    lastWiFi = WiFi.status();
    if (lastWiFi == WL_CONNECTED) Serial.printf("wifi connected %s gateway %s\n", WiFi.localIP().toString().c_str(), WiFi.gatewayIP().toString().c_str());
  }

  // BOOT 버튼: 짧게 누르면 사각형 시험, 3초 누르면 Wi-Fi 설정 모드로 재시작.
  static unsigned long pressedAt = 0;
  bool pressed = digitalRead(BOOT_BUTTON_PIN) == LOW;
  if (pressed && pressedAt == 0) {
    pressedAt = millis();
  } else if (pressed && millis() - pressedAt > 3000) {
    Serial.println("restarting into Wi-Fi setup");
    prefs.putBool("setup", true);
    delay(200);
    ESP.restart();
  } else if (!pressed && pressedAt != 0) {
    if (millis() - pressedAt < 1000) runDemo();
    pressedAt = 0;
  }

  static String line;
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\n') {
      handleCommand(line);
      line = "";
    } else {
      line += ch;
    }
  }
}
