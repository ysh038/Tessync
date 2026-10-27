// Tessync Touch 1단계: ESP32를 BLE 마우스로 만들고, USB 시리얼 명령으로 아이폰 포인터를 움직인다.
// 아이폰은 설정 > 손쉬운 사용 > 터치 > AssistiveTouch를 켜야 마우스 포인터가 생긴다.
// 설계: docs/design/02-touch-control.md
//
// 시리얼 명령 (115200, 줄 단위)
//   m dx dy   상대 이동 (픽셀이 아니라 마우스 이동량. 한 번에 ±127씩 나눠 보낸다)
//   c         클릭
//   d / u     버튼 누르기 / 떼기 (드래그, 길게 누르기)
//   w n       스크롤
//   h         왼쪽 위 모서리로 보내기 (좌표 원점 맞추기)
//   s         연결 상태
//
// 시리얼 없이 시험하기: 보드의 BOOT 버튼을 누르면 포인터를 왼쪽 위로 보낸 뒤 사각형을 그린다(클릭은 안 함).

#include <NimBLEDevice.h>
#include <NimBLEHIDDevice.h>

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

static void setButtons(uint8_t value) {
  buttons = value;
  sendReport(0, 0, 0);
}

static void handleCommand(String line) {
  line.trim();
  if (line.length() == 0) return;
  char command = line.charAt(0);
  long a = 0, b = 0;
  sscanf(line.c_str() + 1, "%ld %ld", &a, &b);

  if (command == 's') {
    Serial.printf("status connected=%d\n", connected);
    return;
  }
  if (!connected) {
    Serial.println("error not connected");
    return;
  }
  switch (command) {
    case 'm': move(a, b); break;
    case 'c': setButtons(1); delay(40); setButtons(0); break;
    case 'd': setButtons(1); break;
    case 'u': setButtons(0); break;
    case 'w': sendReport(0, 0, (int8_t)constrain(a, -127, 127)); break;
    case 'h': move(-5000, -5000); break;
    default: Serial.println("error unknown command"); return;
  }
  Serial.printf("ok dropped=%d\n", droppedReports);
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

void setup() {
  Serial.begin(115200);
  pinMode(BOOT_BUTTON_PIN, INPUT_PULLUP);
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
}

void loop() {
  static bool wasPressed = false;
  bool pressed = digitalRead(BOOT_BUTTON_PIN) == LOW;
  if (pressed && !wasPressed) runDemo();
  wasPressed = pressed;

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
