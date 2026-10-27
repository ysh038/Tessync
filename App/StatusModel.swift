import Foundation

/// 홈 화면에 보여줄 현재 상태. 1.5초마다 핫스팟 주소와 방송 서버 상태를 확인한다.
@MainActor
final class StatusModel: ObservableObject {
    /// 방송 익스텐션 서버의 /status 응답.
    struct ServerStatus: Decodable {
        let clients: Int
        let fps: Double?
        let mem: Double?
        let lvl: Int?
    }

    enum Stage: Int {
        case connectHotspot
        case startBroadcast
        case openBrowser
        case mirroring
    }

    @Published private(set) var hotspotAddress: String?
    @Published private(set) var wifiAddress: String?
    @Published private(set) var lowPowerMode = false
    @Published private(set) var server: ServerStatus?

    private var timer: Timer?

    var isBroadcasting: Bool { server != nil }
    var viewerCount: Int { server?.clients ?? 0 }

    /// 테슬라에서 열 주소. 핫스팟에 기기가 없으면 집 Wi-Fi 주소, 그것도 없으면 기본 핫스팟 주소.
    var playerAddress: String {
        "\(hotspotAddress ?? wifiAddress ?? Tessync.fallbackHotspotAddress):\(Tessync.httpPort)"
    }

    var playerURL: String { "http://\(playerAddress)" }

    var stage: Stage {
        if viewerCount > 0 { return .mirroring }
        if isBroadcasting { return .openBrowser }
        if hotspotAddress != nil || wifiAddress != nil { return .startBroadcast }
        return .connectHotspot
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        hotspotAddress = HotspotAddress.current()
        wifiAddress = HotspotAddress.wifi()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        Task {
            server = await Self.fetchServerStatus()
        }
    }

    /// 방송 중이면 익스텐션 서버가 응답한다. 응답이 없으면 방송이 꺼져 있는 것.
    private static func fetchServerStatus() async -> ServerStatus? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Tessync.httpPort)/status")!)
        request.timeoutInterval = 1
        guard let result = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode(ServerStatus.self, from: result.0)
    }
}
