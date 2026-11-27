import Darwin
import Foundation

/// IP 协议族。
///
/// 作为协议族知识的「信息专家」：v4/v6 的常量与行为差异单点维护于此，
/// 其余模块通过计算属性取用，不再散落 `family == .v4 ? …` 三元判断。
public enum IPFamily: String, Codable, Sendable {
  case v4 = "IPv4"
  case v6 = "IPv6"
}

extension IPFamily {
  /// IP 头 + ICMP 头开销：IPv4 = 20 + 8，IPv6 = 40 + 8
  public var headerOverhead: Int { ipHeaderSize + 8 }

  /// 协议要求的最小 MTU：IPv4 实际常用下限 576，IPv6 为 1280
  public var defaultMinMTU: Int { self == .v4 ? 576 : 1280 }

  // MARK: - 协议族常量与行为

  /// 地址族：AF_INET / AF_INET6
  public var addressFamily: Int32 { self == .v4 ? AF_INET : AF_INET6 }

  /// ICMP 协议号：IPPROTO_ICMP / IPPROTO_ICMPV6
  public var icmpProtocol: Int32 { self == .v4 ? IPPROTO_ICMP : IPPROTO_ICMPV6 }

  /// IP 头长度：IPv4 基本头 20（不含选项），IPv6 固定 40
  public var ipHeaderSize: Int { self == .v4 ? 20 : 40 }

  /// Echo Request 类型：ICMP_ECHO = 8 / ICMP6_ECHO_REQUEST = 128
  public var echoRequestType: UInt8 { self == .v4 ? 8 : 128 }

  /// Echo Reply 类型：ICMP_ECHOREPLY = 0 / ICMP6_ECHO_REPLY = 129
  public var echoReplyType: UInt8 { self == .v4 ? 0 : 129 }

  /// 校验和是否由内核计算：IPv4 须用户态计算，IPv6 内核计算（发送时置 0）
  public var kernelComputesChecksum: Bool { self == .v6 }
}
