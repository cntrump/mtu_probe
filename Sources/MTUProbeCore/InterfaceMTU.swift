import Darwin
import Foundation

/// 本机所有活跃接口（排除回环）的最大 MTU，作为搜索的默认上限
/// —— 本机发不出去的报文大小没有必要探测。macOS / iOS 均可用。
public func detectLocalMaxMTU() -> Int? {
  InterfaceSnapshot()?.maxActiveMTU()
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
/// 职责分离：选路（`resolveLocalAddress`，UDP connect 让内核选路）与
/// 接口属性查询（`InterfaceSnapshot`）各自独立。macOS / iOS 均可用，无需 root。
public func detectEgressInterface(host: String, family: IPFamily) -> EgressInterface? {
  guard let local = resolveLocalAddress(host: host, family: family) else { return nil }

  guard let snapshot = InterfaceSnapshot() else { return nil }

  guard let name = snapshot.interfaceName(matching: local) else { return nil }

  guard let mtu = snapshot.activeMTU(named: name) else { return nil }

  return EgressInterface(name: name, mtu: mtu)
}

/// 让内核完成选路，返回本地地址（不发送任何报文）。
///
/// UDP socket connect 后 getsockname 取本地地址。connect 仅用于选路，
/// 不产生任何网络流量。
private func resolveLocalAddress(host: String, family: IPFamily) -> sockaddr_storage? {
  guard var resolved = try? AddressResolver.resolve(host, family: family) else { return nil }

  // service 传 nil 时 getaddrinfo 返回端口 0，macOS 的 UDP connect 拒绝目的端口 0
  // （EADDRNOTAVAIL）。connect 仅用于让内核选路，端口任取非零值即可。
  let addrFamily = resolved.family

  resolved.withMutableAddr { addr, _ in
    if addrFamily == AF_INET {
      addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_port = UInt16(9).bigEndian
      }
    } else if addrFamily == AF_INET6 {
      addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        $0.pointee.sin6_port = UInt16(9).bigEndian
      }
    }
  }

  let sock = socket(resolved.family, SOCK_DGRAM, IPPROTO_UDP)

  guard sock >= 0 else { return nil }

  defer { close(sock) }

  let connected = resolved.withAddr { addr, len in connect(sock, addr, len) }

  guard connected == 0 else { return nil }

  var local = sockaddr_storage()
  var localLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

  let rc = withUnsafeMutableBytes(of: &local) { ptr in
    getsockname(sock, ptr.baseAddress!.assumingMemoryBound(to: sockaddr.self), &localLen)
  }

  guard rc == 0 else { return nil }

  return local
}
