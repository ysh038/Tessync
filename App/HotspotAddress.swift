import Foundation

enum HotspotAddress {
    /// 개인용 핫스팟에 기기가 붙어 있으면 bridge 인터페이스에 172.20.10.x 주소가 잡힌다.
    static func current() -> String? {
        ipv4Address(interfacePrefix: "bridge")
    }

    /// 집 Wi-Fi 같은 일반 Wi-Fi 주소. 같은 Wi-Fi의 컴퓨터 브라우저로 테스트할 때 쓴다.
    static func wifi() -> String? {
        ipv4Address(interfacePrefix: "en0")
    }

    private static func ipv4Address(interfacePrefix: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            guard String(cString: interface.ifa_name).hasPrefix(interfacePrefix) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
