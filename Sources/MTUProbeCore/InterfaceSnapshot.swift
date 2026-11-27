import Darwin
import Foundation

/// 本机接口快照：一次性读取 getifaddrs，后续查询均为纯函数。
///
/// 将 unsafe 指针操作与 C 链表遍历关在此类型内；
/// 「什么是可用接口」（IFF_UP | IFF_RUNNING）的策略在此单点定义，
/// 供最大 MTU 查询与出口接口查询共用，避免两处策略不一致。
struct InterfaceSnapshot {
  struct Entry {
    let name: String
    let flags: Int32
    let addressFamily: Int32  // ifa_addr 的 sa_family（AF_INET / AF_INET6 / AF_LINK）
    let address: sockaddr_storage?  // 拷贝的地址（AF_LINK 条目可能无地址）
    let mtu: Int?  // 仅 AF_LINK 条目携带

    var isActive: Bool { flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 }

    var isLoopback: Bool { name.hasPrefix("lo") }
  }

  let entries: [Entry]

  /// 读取失败返回 nil。
  init?() {
    var ifap: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifap) == 0, let first = ifap else { return nil }

    defer { freeifaddrs(ifap) }

    var entries: [Entry] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first

    while let node = cursor {
      let ifa = node.pointee
      cursor = ifa.ifa_next

      let name = String(cString: ifa.ifa_name)
      let flags = Int32(bitPattern: ifa.ifa_flags)

      var family: Int32 = 0
      var address: sockaddr_storage?

      if let addr = ifa.ifa_addr {
        family = Int32(addr.pointee.sa_family)
        var storage = sockaddr_storage()
        let len = min(Int(addr.pointee.sa_len), MemoryLayout<sockaddr_storage>.size)

        withUnsafeMutableBytes(of: &storage) { dst in
          _ = memcpy(dst.baseAddress!, addr, len)
        }

        address = storage
      }

      var mtu: Int?

      if family == AF_LINK, let dataPtr = ifa.ifa_data {
        mtu = Int(dataPtr.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu)
      }

      entries.append(
        Entry(
          name: name,
          flags: flags,
          addressFamily: family,
          address: address,
          mtu: mtu
        )
      )
    }

    self.entries = entries
  }

  /// 所有活跃接口（排除回环）的最大 MTU。
  func maxActiveMTU() -> Int? {
    let best = entries.filter { $0.isActive && !$0.isLoopback }.compactMap { $0.mtu }.max() ?? 0
    return best > 0 ? best : nil
  }

  /// 按本地地址反查接口名（出口接口定位第一步）。
  func interfaceName(matching local: sockaddr_storage) -> String? {
    let localFamily = Int32(local.ss_family)

    for entry in entries where entry.addressFamily == localFamily {
      guard let addr = entry.address else { continue }

      if localFamily == AF_INET {
        let a = withUnsafeBytes(of: addr) { $0.loadUnaligned(as: sockaddr_in.self) }.sin_addr
        let b = withUnsafeBytes(of: local) { $0.loadUnaligned(as: sockaddr_in.self) }.sin_addr

        if a.s_addr == b.s_addr { return entry.name }
      } else if localFamily == AF_INET6 {
        let a = withUnsafeBytes(of: addr) { $0.loadUnaligned(as: sockaddr_in6.self) }

        let b = withUnsafeBytes(of: local) { $0.loadUnaligned(as: sockaddr_in6.self) }

        let sameAddr = withUnsafeBytes(of: a.sin6_addr) { pa in
          withUnsafeBytes(of: b.sin6_addr) { pb in
            memcmp(pa.baseAddress!, pb.baseAddress!, MemoryLayout<in6_addr>.size) == 0
          }
        }

        if sameAddr && a.sin6_scope_id == b.sin6_scope_id { return entry.name }
      }
    }

    return nil
  }

  /// 按接口名读取活跃接口的 MTU（出口接口定位第二步）。
  func activeMTU(named name: String) -> Int? {
    for entry in entries where entry.name == name && entry.isActive {
      if let mtu = entry.mtu, mtu > 0 { return mtu }
    }

    return nil
  }
}
