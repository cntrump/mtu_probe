import Darwin
import Foundation

/// 通过 getifaddrs 读取本机所有活跃接口（排除回环）的最大 MTU，
/// 作为二分搜索的默认上限 —— 本机发不出去的报文大小没有必要探测。
/// macOS / iOS 均可用。
public func detectLocalMaxMTU() -> Int? {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    defer { freeifaddrs(ifap) }

    var best = 0
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
        let ifa = node.pointee
        defer { cursor = ifa.ifa_next }

        guard let addr = ifa.ifa_addr,
              addr.pointee.sa_family == UInt8(AF_LINK),
              let dataPtr = ifa.ifa_data else { continue }

        let name = String(cString: ifa.ifa_name)
        if name.hasPrefix("lo") { continue }

        let flags = Int32(bitPattern: ifa.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }

        let mtu = Int(dataPtr.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
        best = max(best, mtu)
    }
    return best > 0 ? best : nil
}

public struct EgressInterface: Sendable {
    public let name: String
    public let mtu: Int
}

/// 探测「到指定目标」的出口接口及其 MTU，作为搜索上限。
/// 相比 detectLocalMaxMTU() 取所有接口的最大值，这里只看出路经过的接口：
/// 无关接口（如其他 VPN 的 utun、巨帧桥接）不会抬高上限，
/// 避免对发不出去/必然被丢弃的尺寸做无谓的超时探测。
///
/// 实现：UDP socket connect（不发送任何报文）让内核完成选路，
/// getsockname 取本地地址，再在 getifaddrs 中按地址反查接口名与 MTU。
/// macOS / iOS 均可用，无需 root。
public func detectEgressInterface(host: String, family: IPFamily) -> EgressInterface? {
    var hints = addrinfo()
    hints.ai_family = family == .v4 ? AF_INET : AF_INET6
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_protocol = 0
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let ai = result else { return nil }
    defer { freeaddrinfo(result) }
    let info = ai.pointee

    // service 传 nil 时 getaddrinfo 返回端口 0，macOS 的 UDP connect 拒绝目的端口 0
    // （EADDRNOTAVAIL）。connect 仅用于让内核选路、不发送任何报文，端口任取非零值即可。
    if info.ai_family == AF_INET {
        UnsafeMutableRawPointer(info.ai_addr).assumingMemoryBound(to: sockaddr_in.self)
            .pointee.sin_port = UInt16(9).bigEndian
    } else if info.ai_family == AF_INET6 {
        UnsafeMutableRawPointer(info.ai_addr).assumingMemoryBound(to: sockaddr_in6.self)
            .pointee.sin6_port = UInt16(9).bigEndian
    }

    let sock = socket(info.ai_family, SOCK_DGRAM, IPPROTO_UDP)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    guard connect(sock, info.ai_addr, info.ai_addrlen) == 0 else { return nil }

    var local = sockaddr_storage()
    var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let nameRC = withUnsafeMutableBytes(of: &local) { ptr in
        getsockname(sock, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &localLen)
    }
    guard nameRC == 0 else { return nil }

    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }
    defer { freeifaddrs(ifap) }

    // 第一遍：按本地地址找到接口名
    var egressName: String?
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
        let ifa = node.pointee
        defer { cursor = ifa.ifa_next }
        guard let addr = ifa.ifa_addr,
              addr.pointee.sa_family == local.ss_family else { continue }
        let name = String(cString: ifa.ifa_name)
        if local.ss_family == UInt8(AF_INET) {
            let a = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let b = withUnsafeBytes(of: &local) { $0.load(as: sockaddr_in.self) }.sin_addr
            if a.s_addr == b.s_addr { egressName = name; break }
        } else if local.ss_family == UInt8(AF_INET6) {
            var a = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee
            var b = withUnsafeBytes(of: &local) { $0.load(as: sockaddr_in6.self) }
            let sameAddr = withUnsafeBytes(of: &a.sin6_addr) { pa in
                withUnsafeBytes(of: &b.sin6_addr) { pb in
                    memcmp(pa.baseAddress!, pb.baseAddress!, MemoryLayout<in6_addr>.size) == 0
                }
            }
            if sameAddr && a.sin6_scope_id == b.sin6_scope_id { egressName = name; break }
        }
    }
    guard let egressName else { return nil }

    // 第二遍：按接口名在 AF_LINK 条目上读 MTU
    cursor = first
    while let node = cursor {
        let ifa = node.pointee
        defer { cursor = ifa.ifa_next }
        guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
              String(cString: ifa.ifa_name) == egressName,
              let dataPtr = ifa.ifa_data else { continue }
        let mtu = Int(dataPtr.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
        if mtu > 0 { return EgressInterface(name: egressName, mtu: mtu) }
    }
    return nil
}
