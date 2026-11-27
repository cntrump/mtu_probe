import Darwin
import Dispatch
import XCTest

@testable import MTUProbeCore

// MARK: - 搜索算法（注入模拟路径，无需真实网络）

final class ProbeTests: XCTestCase {
  /// 模拟一条路径：PMTU = pathMTU。
  /// - silentDrop：落在该区间的 MTU 静默丢包（noReply），模拟非单调结果。
  /// - hint：tooBig 时 ICMP 通告的 MTU 上界。
  /// - fatalAt：命中该 MTU 返回致命错误。
  private func simulatedSend(
    pathMTU: Int,
    rtt: Double = 10,
    silentDrop: ClosedRange<Int>? = nil,
    hint: Int? = nil,
    fatalAt: Int? = nil
  ) -> @Sendable (Int, Int) async -> PingOutcome {
    { mtu, _ in
      if let fatalAt, mtu == fatalAt {
        return PingOutcome(kind: .error, rttMillis: nil, message: "模拟致命错误")
      }

      if let silentDrop, silentDrop.contains(mtu) {
        return PingOutcome(kind: .noReply, rttMillis: nil, message: "超时无响应")
      }

      if mtu <= pathMTU {
        return PingOutcome(kind: .ok, rttMillis: rtt, message: "收到回包")
      }

      return PingOutcome(kind: .tooBig, rttMillis: nil, message: "报文过大", reportedMTU: hint)
    }
  }

  private func options(
    family: IPFamily = .v4,
    min: Int,
    max: Int,
    concurrency: Int,
    retries: Int = 0
  ) -> ProbeOptions {
    ProbeOptions(
      host: "simulated",
      family: family,
      minMTU: min,
      maxMTU: max,
      timeoutMillis: 1000,
      retries: retries,
      concurrency: concurrency
    )
  }

  func testConvergesToPathMTU() async {
    let opts = options(min: 576, max: 1500, concurrency: 4)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 1400))
    XCTAssertEqual(result.bestMTU, 1400)
    XCTAssertEqual(result.payload, 1400 - 28)
    XCTAssertFalse(result.cappedAtMax)
    XCTAssertNil(result.error)
  }

  func testCappedAtMax() async {
    let opts = options(min: 576, max: 1500, concurrency: 4)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 1500))
    XCTAssertEqual(result.bestMTU, 1500)
    XCTAssertTrue(result.cappedAtMax)
  }

  func testHintShrinksUpperBound() async {
    let opts = options(min: 576, max: 1500, concurrency: 4)
    let result = await probeMTU(
      opts,
      localMaxMTU: nil,
      send: simulatedSend(pathMTU: 1400, hint: 1400)
    )
    XCTAssertEqual(result.bestMTU, 1400)
    XCTAssertNil(result.error)
  }

  func testConservativeAggregationToleratesSilentDrop() async {
    // 1133/1177 等分点落在丢包区间，但更高通过点把 lo 抬过丢包点，低于 lo 的失败被忽略
    let opts = options(min: 1000, max: 1399, concurrency: 8, retries: 0)
    let result = await probeMTU(
      opts,
      localMaxMTU: nil,
      send: simulatedSend(pathMTU: 1390, silentDrop: 1100...1200)
    )
    XCTAssertEqual(result.bestMTU, 1390)
    XCTAssertNil(result.error)
  }

  func testSequentialBinaryConvergence() async {
    let opts = options(min: 576, max: 1500, concurrency: 1)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 1492))
    XCTAssertEqual(result.bestMTU, 1492)
  }

  func testIPv6Convergence() async {
    let opts = options(family: .v6, min: 1280, max: 1500, concurrency: 4)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 1400))
    XCTAssertEqual(result.bestMTU, 1400)
    XCTAssertEqual(result.payload, 1400 - 48)
  }

  func testFatalErrorAborts() async {
    let opts = options(min: 576, max: 1500, concurrency: 4)
    let result = await probeMTU(
      opts,
      localMaxMTU: nil,
      send: simulatedSend(pathMTU: 1400, fatalAt: 576)
    )
    XCTAssertNil(result.bestMTU)
    XCTAssertEqual(result.error, "模拟致命错误")
  }

  func testMinUnreachable() async {
    let opts = options(min: 576, max: 1500, concurrency: 4)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 500))
    XCTAssertNil(result.bestMTU)
    XCTAssertNotNil(result.error)
  }

  func testInvalidInterval() async {
    let opts = options(min: 1500, max: 1000, concurrency: 4)
    let result = await probeMTU(opts, localMaxMTU: nil, send: simulatedSend(pathMTU: 1400))
    XCTAssertNil(result.bestMTU)
    XCTAssertNotNil(result.error)
  }

  func testRetriesIncreaseProbeCount() async {
    // 上限静默丢包，retries=2 → 上限尝试发包 3 次
    let opts = options(min: 576, max: 1500, concurrency: 4, retries: 2)
    let result = await probeMTU(
      opts,
      localMaxMTU: nil,
      send: simulatedSend(pathMTU: 1400, silentDrop: 1500...1500)
    )
    XCTAssertEqual(result.bestMTU, 1400)
    XCTAssertGreaterThanOrEqual(result.probeCount, 3)
  }
}

// MARK: - ICMP 报文构造 / 解析（纯函数）

final class ICMPMessageTests: XCTestCase {
  private var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

  func testBuildEchoRequestV4() {
    let packet = Ping.buildEchoRequest(family: .v4, id: 0x1234, seq: 1, payload: 4)
    XCTAssertEqual(packet.count, 12)
    XCTAssertEqual(packet[0], 8)  // echo request
    XCTAssertEqual(packet[1], 0)  // code 必须为 0
    XCTAssertEqual(packet[4], 0x12)
    XCTAssertEqual(packet[5], 0x34)
    XCTAssertEqual(packet[6], 0)
    XCTAssertEqual(packet[7], 1)
    // 校验和正确：整包（含校验和字段）再次求和应为 0
    XCTAssertEqual(Ping.checksum(packet), 0)
  }

  func testBuildEchoRequestV6ZeroChecksum() {
    let packet = Ping.buildEchoRequest(family: .v6, id: 0xABCD, seq: 2, payload: 0)
    XCTAssertEqual(packet[0], 128)
    XCTAssertEqual(packet[2], 0)  // IPv6 校验和交由内核计算
    XCTAssertEqual(packet[3], 0)
    XCTAssertEqual(packet[4], 0xAB)
    XCTAssertEqual(packet[5], 0xCD)
  }

  func testClassifyV4EchoReply() {
    var buf = [UInt8](repeating: 0, count: 8)
    buf[0] = 0
    buf[4] = 0x12; buf[5] = 0x34; buf[6] = 0; buf[7] = 1
    let o = Ping.classify(buffer: buf, count: 8, family: .v4, id: 0x1234, seq: 1, start: now)
    XCTAssertEqual(o?.kind, .ok)
  }

  func testClassifyV4FragNeeded() {
    var buf = [UInt8](repeating: 0, count: 40)
    buf[0] = 3; buf[1] = 4
    buf[6] = 0x05; buf[7] = 0x78  // 下一跳 MTU 1400
    buf[8] = 0x45  // 内嵌 IP 头 ihl=5 → 20 字节
    buf[32] = 0x12; buf[33] = 0x34; buf[34] = 0; buf[35] = 1  // 内嵌 ICMP id/seq @ base+8+20
    let o = Ping.classify(buffer: buf, count: 40, family: .v4, id: 0x1234, seq: 1, start: now)
    XCTAssertEqual(o?.kind, .tooBig)
    XCTAssertEqual(o?.reportedMTU, 1400)
  }

  func testClassifyV6PacketTooBig() {
    var buf = [UInt8](repeating: 0, count: 60)
    buf[0] = 2
    buf[6] = 0x05; buf[7] = 0x78  // 路径 MTU 1400（u32 @ base+4）
    buf[52] = 0x12; buf[53] = 0x34; buf[54] = 0; buf[55] = 1  // 内嵌 ICMPv6 id/seq @ base+8+40
    let o = Ping.classify(buffer: buf, count: 60, family: .v6, id: 0x1234, seq: 1, start: now)
    XCTAssertEqual(o?.kind, .tooBig)
    XCTAssertEqual(o?.reportedMTU, 1400)
  }

  func testClassifyIgnoresMismatchedID() {
    var buf = [UInt8](repeating: 0, count: 8)
    buf[0] = 0
    buf[4] = 0x99; buf[5] = 0x99  // 不同 id（别的进程的 ICMP）
    let o = Ping.classify(buffer: buf, count: 8, family: .v4, id: 0x1234, seq: 1, start: now)
    XCTAssertNil(o)
  }
}

// MARK: - 搜索区间不变量

final class SearchIntervalTests: XCTestCase {
  func testApplyPassRaisesLo() {
    var i = SearchInterval(lo: 576, hi: 1500)
    i.applyPass(1400)
    XCTAssertEqual(i.lo, 1400)
    XCTAssertEqual(i.hi, 1500)
  }

  func testApplyFailLowersHi() {
    var i = SearchInterval(lo: 576, hi: 1500)
    i.applyFail(1400, hint: nil)
    XCTAssertEqual(i.hi, 1400)
  }

  func testHintShrinksHi() {
    var i = SearchInterval(lo: 576, hi: 1500)
    i.applyFail(1492, hint: 1400)
    XCTAssertEqual(i.hi, 1401)  // hint + 1
  }

  func testHiAlwaysGreaterThanLo() {
    var i = SearchInterval(lo: 1400, hi: 1500)
    i.applyFail(1450, hint: 1000)  // hint+1=1001 < lo+1 → 钳制到 lo+1
    XCTAssertEqual(i.hi, 1401)
  }

  func testConvergence() {
    XCTAssertTrue(SearchInterval(lo: 1400, hi: 1401).isConverged)
    XCTAssertFalse(SearchInterval(lo: 1400, hi: 1402).isConverged)
  }

  func testDivisionPointsCoverInterior() {
    let i = SearchInterval(lo: 1000, hi: 1010)  // 内部 9 个候选
    XCTAssertEqual(i.divisionPoints(9), Array(1001...1009))
  }

  func testDivisionPointsStrictlyIncreasingWithinBounds() {
    let i = SearchInterval(lo: 576, hi: 1500)
    let pts = i.divisionPoints(4)
    XCTAssertEqual(pts, pts.sorted())
    XCTAssertEqual(Set(pts).count, pts.count)
    XCTAssertTrue(pts.allSatisfy { $0 > 576 && $0 < 1500 })
  }
}

// MARK: - 协议族常量

final class IPFamilyTests: XCTestCase {
  func testOverhead() {
    XCTAssertEqual(IPFamily.v4.headerOverhead, 28)
    XCTAssertEqual(IPFamily.v6.headerOverhead, 48)
  }

  func testIPHeaderSize() {
    XCTAssertEqual(IPFamily.v4.ipHeaderSize, 20)
    XCTAssertEqual(IPFamily.v6.ipHeaderSize, 40)
  }

  func testAddressFamily() {
    XCTAssertEqual(IPFamily.v4.addressFamily, AF_INET)
    XCTAssertEqual(IPFamily.v6.addressFamily, AF_INET6)
  }

  func testEchoTypes() {
    XCTAssertEqual(IPFamily.v4.echoRequestType, 8)
    XCTAssertEqual(IPFamily.v6.echoRequestType, 128)
    XCTAssertEqual(IPFamily.v4.echoReplyType, 0)
    XCTAssertEqual(IPFamily.v6.echoReplyType, 129)
  }

  func testChecksumResponsibility() {
    XCTAssertFalse(IPFamily.v4.kernelComputesChecksum)
    XCTAssertTrue(IPFamily.v6.kernelComputesChecksum)
  }

  func testDefaultMinMTU() {
    XCTAssertEqual(IPFamily.v4.defaultMinMTU, 576)
    XCTAssertEqual(IPFamily.v6.defaultMinMTU, 1280)
  }
}
