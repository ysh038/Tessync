import Foundation

enum Tessync {
    static let httpPort: UInt16 = 8080
    static let streamPort: UInt16 = 8081
    static let fallbackHotspotAddress = "172.20.10.1"

    /// project.yml에서 Info.plist에 넣어준 App Group ID.
    static var appGroupID: String {
        Bundle.main.object(forInfoDictionaryKey: "TessyncAppGroup") as? String ?? "group.com.example.tessync"
    }

    static var sharedContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var logURL: URL? {
        sharedContainer?.appendingPathComponent("broadcast.log")
    }
}
