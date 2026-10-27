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

    /// App Group이 있으면 앱과 익스텐션이 같이 보는 위치, 없으면(무료 계정) 각자의 캐시 폴더.
    static var logURL: URL? {
        let directory = sharedContainer ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return directory?.appendingPathComponent("broadcast.log")
    }
}
