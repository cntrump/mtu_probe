import Darwin
import Foundation

/// 解析后的目标地址（值语义）。
///
/// 内部拷贝 sockaddr 到 `sockaddr_storage`，调用方无需管理 addrinfo 生命周期，
/// 通过 `withAddr` / `withMutableAddr` 安全访问。
struct ResolvedAddress {
  let family: Int32
  let length: socklen_t
  fileprivate var storage: sockaddr_storage

  /// 以只读 sockaddr 指针访问地址（用于 sendto / connect）。
  func withAddr<R>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafeBytes(of: storage) { raw in
      body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), length)
    }
  }

  /// 以可写 sockaddr 指针访问地址（用于修改端口等）。
  mutating func withMutableAddr<R>(_ body: (UnsafeMutablePointer<sockaddr>, socklen_t) -> R) -> R {
    withUnsafeMutableBytes(of: &storage) { raw in
      body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), length)
    }
  }
}

/// 共享的地址解析入口，集中维护平台陷阱知识。
enum AddressResolver {
  struct Failure: Error {
    let message: String
  }

  /// 解析 host 为指定协议族的地址。
  ///
  /// 平台注意（macOS）：getaddrinfo 拒绝 SOCK_DGRAM + IPPROTO_ICMP 组合（EAI_BADHINTS），
  /// 故 ai_protocol 置 0，由调用方在建套接字时显式指定协议。
  static func resolve(_ host: String, family: IPFamily) throws -> ResolvedAddress {
    var hints = addrinfo()
    hints.ai_family = family.addressFamily
    hints.ai_socktype = SOCK_DGRAM
    hints.ai_protocol = 0

    var result: UnsafeMutablePointer<addrinfo>?
    let rc = getaddrinfo(host, nil, &hints, &result)

    guard rc == 0, let ai = result else {
      throw Failure(message: "无法解析 \(host): \(String(cString: gai_strerror(rc)))")
    }

    defer { freeaddrinfo(result) }

    let info = ai.pointee
    var storage = sockaddr_storage()

    withUnsafeMutableBytes(of: &storage) { dst in
      _ = memcpy(dst.baseAddress!, info.ai_addr, Int(info.ai_addrlen))
    }

    return ResolvedAddress(family: info.ai_family, length: info.ai_addrlen, storage: storage)
  }
}
