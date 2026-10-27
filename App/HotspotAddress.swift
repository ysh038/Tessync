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

    struct InterfaceAddress: Hashable {
        let interface: String
        let address: String
    }

    /// 핫스팟/Wi-Fi 쪽 인터페이스의 모든 주소(IPv4, IPv6). 테슬라가 어떤 주소로 이 iPhone에 닿을 수 있는지 진단용.
    static func allAddresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let address = interface.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("bridge") || name == "en0" || name.hasPrefix("ap") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let value = InterfaceAddress(interface: name, address: String(cString: host))
                if !result.contains(value) { result.append(value) }
            }
        }
        return result
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
