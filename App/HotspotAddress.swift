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

        /// 테슬라 브라우저가 막는다고 알려진 사설 IPv4 대역(10/8, 172.16/12, 192.168/16)인지.
        var isPrivateIPv4: Bool {
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4 else { return false }
            return parts[0] == 10
                || (parts[0] == 172 && (16...31).contains(parts[1]))
                || (parts[0] == 192 && parts[1] == 168)
        }

        var isIPv6: Bool { address.contains(":") }
    }

    /// 이 iPhone의 모든 주소(핫스팟, Wi-Fi, 셀룰러 포함). 테슬라가 어떤 주소로 이 iPhone에 닿을 수 있는지 진단용.
    /// 셀룰러(pdp_ip) 주소도 넣는다: 핫스팟 기기가 iPhone 자신의 셀룰러 주소로 보내도 iPhone이 받아줄 수 있다.
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
            guard name != "lo0", !name.hasPrefix("utun"), !name.hasPrefix("llw"), !name.hasPrefix("awdl") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                // 링크 로컬 IPv6(fe80::)는 브라우저 주소로 쓸 수 없어서 뺀다.
                if text.lowercased().hasPrefix("fe80") { continue }
                let value = InterfaceAddress(interface: name, address: text)
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
