import Darwin
import Foundation

public struct PingOutcome {
  public enum Kind: Equatable {
    case ok  // 收到回包
    case tooBig  // 明确收到“需要分片 / 报文过大”错误
    case noReply  // 超时（路径上可能被静默丢弃）
    case error  // 无法解析地址、无路由等致命错误
  }

  public let kind: Kind
  public let rttMillis: Double?
  public let message: String

  /// ICMP 差错报文通告的 MTU（frag needed 的下一跳 MTU / PTB 的路径 MTU），
  /// 是路径 MTU 的上界，可直接用于收缩搜索区间。0/缺失时为 nil。
  public let reportedMTU: Int?

  public init(kind: Kind, rttMillis: Double?, message: String, reportedMTU: Int? = nil) {
    self.kind = kind
    self.rttMillis = rttMillis
    self.message = message
    self.reportedMTU = reportedMTU
  }
}

/// 自主实现的 ICMP 探测（macOS / iOS 通用，无需 root）。
///
/// 使用非特权 ICMP datagram 套接字（`SOCK_DGRAM` + `IPPROTO_ICMP` / `IPPROTO_ICMPV6`，
/// 与 Apple SimplePing 在 iOS 上的机制相同），不依赖系统 ping 工具。
///
/// 已验证的平台行为（xnu）：
/// - IPv4：`IP_DONTFRAG` 非 root 可设；超接口 MTU 时 sendto 返回 EMSGSIZE。
///   校验和须用户态计算（计算前字段清零）；设 `IP_STRIPHDR` 后收包为纯 ICMP。
/// - IPv6：内核计算校验和（发送时置 0）；收包为纯 ICMPv6。
///   `IPV6_DONTFRAG` 需 root，非 root 下忽略失败——路由器天然不分片，
///   且默认搜索上限为接口 MTU，范围内不会触发本机源端分片。
/// - 路径 MTU 不足时，recv 会直接收到 ICMP 差错报文：
///   IPv4 type=3 code=4（frag needed，6-7 字节为下一跳 MTU），
///   IPv6 type=2（Packet Too Big，4-7 字节为路径 MTU），
///   两者均内嵌原始报文头，可核对 id/seq 确定性判定 tooBig。
/// - ICMP code 必须为 0，否则 xnu 拒绝发送（EINVAL）。
enum Ping {
  // 部分常量未导入 Swift Darwin overlay，用字面值（见 SDK netinet/in.h、netinet6/in6.h、sys/socket.h）
  private static let ipv6DontFrag: Int32 = 62  // IPV6_DONTFRAG
  private static let soRecvAnyIF: Int32 = 0x1104  // SO_RECV_ANYIF

  /// 发送一个禁止分片的 ICMP 探测包并等待结果。
  /// 每次探测使用独立套接字，隔离并行任务与重试之间的串包。
  static func send(family: IPFamily, host: String, payload: Int, timeoutMillis: Int) async -> PingOutcome {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(
          returning: sendSync(
            family: family,
            host: host,
            payload: payload,
            timeoutMillis: timeoutMillis
          )
        )
      }
    }
  }

  private static func sendSync(family: IPFamily, host: String, payload: Int, timeoutMillis: Int) -> PingOutcome {
    // 1. 解析目标地址
    let resolved: ResolvedAddress

    do {
      resolved = try AddressResolver.resolve(host, family: family)
    } catch {
      let message = (error as? AddressResolver.Failure)?.message ?? "无法解析 \(host)"
      return PingOutcome(kind: .error, rttMillis: nil, message: message)
    }

    // 2. 建套接字并设置选项
    let sock = socket(resolved.family, SOCK_DGRAM, family.icmpProtocol)

    guard sock >= 0 else {
      return PingOutcome(
        kind: .error,
        rttMillis: nil,
        message: "无法创建 ICMP 套接字: \(String(cString: strerror(errno)))"
      )
    }

    defer { close(sock) }

    var on: Int32 = 1
    let optLen = socklen_t(MemoryLayout<Int32>.size)
    setsockopt(sock, SOL_SOCKET, soRecvAnyIF, &on, optLen)

    if family == .v4 {
      guard setsockopt(sock, IPPROTO_IP, IP_DONTFRAG, &on, optLen) == 0 else {
        return PingOutcome(
          kind: .error,
          rttMillis: nil,
          message: "设置 IP_DONTFRAG 失败: \(String(cString: strerror(errno)))"
        )
      }

      setsockopt(sock, IPPROTO_IP, IP_STRIPHDR, &on, optLen)
    } else {
      // 需要 root；失败（EPERM）时忽略，依赖路由器不分片 + 接口 MTU 上限
      setsockopt(sock, IPPROTO_IPV6, ipv6DontFrag, &on, optLen)
    }

    // 3. 构造 ICMP Echo Request
    let id = UInt16.random(in: 0...UInt16.max)
    let seq: UInt16 = 1
    let packet = buildEchoRequest(family: family, id: id, seq: seq, payload: payload)

    // 4. 发送
    let start = DispatchTime.now().uptimeNanoseconds

    let sent = packet.withUnsafeBytes { ptr in
      resolved.withAddr { addr, len in
        sendto(sock, ptr.baseAddress, packet.count, 0, addr, len)
      }
    }

    if sent < 0 {
      let e = errno

      switch e {
      case EMSGSIZE:
        return PingOutcome(
          kind: .tooBig,
          rttMillis: nil,
          message: "报文过大，本机接口 MTU 不足（EMSGSIZE）"
        )
      case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL:
        return PingOutcome(
          kind: .error,
          rttMillis: nil,
          message: "网络不可达: \(String(cString: strerror(e)))"
        )
      default:
        return PingOutcome(
          kind: .error,
          rttMillis: nil,
          message: "发送失败: \(String(cString: strerror(e)))"
        )
      }
    }

    // 5. 收包循环，直到命中回包/差错或超时
    let deadline = start + UInt64(timeoutMillis) * 1_000_000
    var buffer = [UInt8](repeating: 0, count: 65536)

    while true {
      let now = DispatchTime.now().uptimeNanoseconds

      guard now < deadline else {
        return PingOutcome(kind: .noReply, rttMillis: nil, message: "超时无响应")
      }

      let remaining = deadline - now
      var tv = timeval(
        tv_sec: Int(remaining / 1_000_000_000),
        tv_usec: Int32((remaining % 1_000_000_000) / 1_000)
      )
      setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

      let n = recv(sock, &buffer, buffer.count, 0)

      if n < 0 {
        let e = errno

        if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }

        if e == EMSGSIZE {
          // 内核已缓存路径 MTU 时的后续发送错误
          return PingOutcome(kind: .tooBig, rttMillis: nil, message: "报文过大（路径 MTU 不足）")
        }

        return PingOutcome(
          kind: .noReply,
          rttMillis: nil,
          message: "接收失败: \(String(cString: strerror(e)))"
        )
      }

      guard n >= 8 else { continue }

      if let outcome = classify(
        buffer: buffer,
        count: n,
        family: family,
        id: id,
        seq: seq,
        start: start
      ) {
        return outcome
      }

      // 其他报文（如别的进程的 ICMP）忽略，继续等
    }
  }

  /// 构造 ICMP Echo Request 报文（纯函数，无需网络即可单测）。
  ///
  /// 8 字节 ICMP 头 + payload 字节填充（0x61）。code 必须为 0；
  /// IPv4 校验和由用户态计算，IPv6 保持 0 交由内核计算。
  static func buildEchoRequest(family: IPFamily, id: UInt16, seq: UInt16, payload: Int) -> [UInt8] {
    var packet = [UInt8](repeating: 0x61, count: 8 + payload)
    packet[0] = family.echoRequestType
    packet[1] = 0  // code 必须为 0
    packet[2] = 0; packet[3] = 0  // 校验和字段先清零
    packet[4] = UInt8(id >> 8); packet[5] = UInt8(id & 0xff)
    packet[6] = UInt8(seq >> 8); packet[7] = UInt8(seq & 0xff)

    if !family.kernelComputesChecksum {
      let ck = checksum(packet)
      packet[2] = UInt8(ck >> 8); packet[3] = UInt8(ck & 0xff)
    }

    return packet
  }

  /// 解析收到的 ICMP 报文；命中本次探测的回包或差错时返回结果，否则返回 nil。
  /// 所有偏移均相对 buffer 起点，base 为 ICMP 头位置。
  ///
  /// v4/v6 统一处理：回包类型由 `family.echoReplyType` 给出；
  /// 差错报文内嵌的原始 IP 头长度 v4 可变（ihl）、v6 固定（`family.ipHeaderSize`）。
  static func classify(
    buffer: [UInt8],
    count: Int,
    family: IPFamily,
    id: UInt16,
    seq: UInt16,
    start: UInt64
  ) -> PingOutcome? {
    var base = 0

    // 防御：若 IP_STRIPHDR 未生效，IPv4 收包会带 IP 头，按 ihl 跳过
    if family == .v4, buffer[0] >> 4 == 4 {
      base = Int(buffer[0] & 0x0f) * 4

      guard count >= base + 8 else { return nil }
    }

    let type = buffer[base]

    func matchesIDSeq(at off: Int) -> Bool {
      off + 8 <= count
        && UInt16(buffer[off + 4]) << 8 | UInt16(buffer[off + 5]) == id
        && UInt16(buffer[off + 6]) << 8 | UInt16(buffer[off + 7]) == seq
    }

    func rttMillis() -> Double {
      Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // Echo Reply
    if type == family.echoReplyType, matchesIDSeq(at: base) {
      return PingOutcome(kind: .ok, rttMillis: rttMillis(), message: "收到回包")
    }

    // 差错报文：v4 type=3 code=4（frag needed），v6 type=2（Packet Too Big）
    let isTooBig = family == .v4 ? (type == 3 && buffer[base + 1] == 4) : (type == 2)

    guard isTooBig else { return nil }

    // 内嵌原始 IP 头长度：v4 可变 ihl，v6 固定 40
    let embeddedHeaderSize: Int

    if family == .v4 {
      guard count >= base + 8 + 20 + 8 else { return nil }

      embeddedHeaderSize = Int(buffer[base + 8] & 0x0f) * 4
    } else {
      embeddedHeaderSize = family.ipHeaderSize
    }

    guard count >= base + 8 + embeddedHeaderSize + 8,
      matchesIDSeq(at: base + 8 + embeddedHeaderSize)
    else { return nil }

    // 通告 MTU：v4 为 2 字节（base+6），v6 为 4 字节（base+4）
    let reportedMTU: Int
    let message: String

    if family == .v4 {
      let mtu = UInt16(buffer[base + 6]) << 8 | UInt16(buffer[base + 7])
      reportedMTU = Int(mtu)
      message = "报文过大，需要分片（下一跳 MTU \(mtu)）"
    } else {
      let mtu =
        UInt32(buffer[base + 4]) << 24 | UInt32(buffer[base + 5]) << 16
        | UInt32(buffer[base + 6]) << 8 | UInt32(buffer[base + 7])
      reportedMTU = Int(mtu)
      message = "报文过大（路径 MTU \(mtu)）"
    }

    return PingOutcome(
      kind: .tooBig,
      rttMillis: nil,
      message: message,
      reportedMTU: reportedMTU > 0 ? reportedMTU : nil
    )
  }

  /// 标准 Internet 校验和（RFC 1071）。调用前校验和字段必须为 0。
  static func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var i = 0

    while i + 1 < bytes.count {
      sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
      i += 2
    }

    if i < bytes.count { sum += UInt32(bytes[i]) << 8 }

    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }

    return ~UInt16(sum)
  }
}
