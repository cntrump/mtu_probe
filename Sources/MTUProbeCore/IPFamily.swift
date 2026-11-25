import Foundation

public enum IPFamily: String, Codable, Sendable {
    case v4 = "IPv4"
    case v6 = "IPv6"

    /// IP 头 + ICMP 头开销：IPv4 = 20 + 8，IPv6 = 40 + 8
    public var headerOverhead: Int { self == .v4 ? 28 : 48 }

    /// 协议要求的最小 MTU：IPv4 实际常用下限 576，IPv6 为 1280
    public var defaultMinMTU: Int { self == .v4 ? 576 : 1280 }
}
