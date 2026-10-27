import SwiftUI

struct ContentView: View {
    @StateObject private var picker = BroadcastPicker()
    @State private var hotspotAddress: String?
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var playerURL: String {
        "http://\(hotspotAddress ?? Tessync.fallbackHotspotAddress):\(Tessync.httpPort)"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("테슬라 브라우저에서 이 주소를 여세요")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(playerURL)
                            .font(.title2.monospaced().bold())
                            .textSelection(.enabled)
                        if hotspotAddress == nil {
                            Text("핫스팟에 연결된 기기가 아직 없습니다. 테슬라 Wi-Fi를 이 iPhone 핫스팟에 연결하세요.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        picker.present()
                    } label: {
                        Label("화면 방송 시작", systemImage: "record.circle")
                            .font(.headline)
                    }
                    .background(BroadcastPickerHost(picker: picker).frame(width: 1, height: 1))
                }

                if lowPowerMode {
                    Section {
                        Label("저전력 모드가 켜져 있습니다. 끊김을 줄이려면 꺼주세요.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Section("끊김 없이 쓰려면") {
                    ChecklistRow(text: "설정 > 디스플레이 및 밝기 > 자동 잠금: 안 함", detail: "화면이 잠기면 iOS가 방송을 강제로 끝냅니다.")
                    ChecklistRow(text: "설정 > 개인용 핫스팟 > 다른 사람의 연결 허용: 켬", detail: "셀룰러 데이터도 켜두세요. 인터넷이 없으면 테슬라가 Wi-Fi를 버릴 수 있습니다.")
                    ChecklistRow(text: "호환성 최대화: 끔 (5GHz)", detail: "대역폭이 넉넉해집니다. ESP32 터치 보드를 쓸 때만 켜세요.")
                    ChecklistRow(text: "테슬라에 저장된 다른 Wi-Fi 삭제", detail: "집이나 회사 Wi-Fi로 자동 전환되는 것을 막습니다.")
                    ChecklistRow(text: "소리는 블루투스로", detail: "영상만 미러링합니다. 소리는 평소처럼 테슬라 블루투스로 나옵니다.")
                }

                Section("도구") {
                    NavigationLink("진단 로그") { LogView() }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("테슬라 브라우저 점검 페이지")
                        Text("\(playerURL)/probe")
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Text("운전 중 영상 시청은 도로교통법 위반입니다. 내비게이션 용도로만 사용하세요.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Tessync")
        }
        .onAppear(perform: update)
        .onReceive(refresh) { _ in update() }
    }

    private func update() {
        hotspotAddress = HotspotAddress.current()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

private struct ChecklistRow: View {
    let text: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
