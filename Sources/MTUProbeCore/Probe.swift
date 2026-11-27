import Darwin
import Dispatch
import Foundation

public struct ProbeOptions: Sendable {
  public var host: String
  public var family: IPFamily
  public var minMTU: Int?
  public var maxMTU: Int?
  public var timeoutMillis: Int  // 单次探测超时上限；实际按已测 RTT 自适应收紧（5×RTT+100ms，下限 200ms）
  public var retries: Int  // 超时后的重试次数（“需要分片”是确定性错误，不重试）
  public var concurrency: Int?  // 每轮并发探测点数；nil → CPU 核心数（activeProcessorCount）

  public init(
    host: String,
    family: IPFamily,
    minMTU: Int? = nil,
    maxMTU: Int? = nil,
    timeoutMillis: Int = 1000,
    retries: Int = 2,
    concurrency: Int? = nil
  ) {
    self.host = host
    self.family = family
    self.minMTU = minMTU
    self.maxMTU = maxMTU
    self.timeoutMillis = timeoutMillis
    self.retries = retries
    self.concurrency = concurrency
  }
}

public struct ProbeResult: Codable, Sendable {
  public var family: IPFamily
  public var host: String
  public var bestMTU: Int?
  public var payload: Int?
  public var probeCount: Int
  public var elapsedMillis: Double  // 本次探测总耗时（毫秒，单调时钟）
  public var cappedAtMax: Bool
  public var error: String?

  public init(
    family: IPFamily,
    host: String,
    bestMTU: Int?,
    payload: Int?,
    probeCount: Int,
    elapsedMillis: Double = 0,
    cappedAtMax: Bool = false,
    error: String? = nil
  ) {
    self.family = family
    self.host = host
    self.bestMTU = bestMTU
    self.payload = payload
    self.probeCount = probeCount
    self.elapsedMillis = elapsedMillis
    self.cappedAtMax = cappedAtMax
    self.error = error
  }
}

private enum Attempt: Sendable {
  case ok(Double?)  // 回包 RTT（ms），用于自适应超时
  case fail(Int?)  // ICMP 差错通告的 MTU 上界（如有），用于收缩搜索区间
  case fatal(String)
}

/// 二分探测的分割基准点：现实路径 MTU 绝大多数落在 1400 及以上
/// （以太网 1500、PPPoE 1492、常见隧道 1400+）。先探 1400 可一步丢弃大段无效区间：
/// 通过则下方整段无需再探，失败则上方整段无需再探。
private let pivotMTU = 1400

/// 对单个目标执行 MTU 并发探测。
///
/// 思路：先确认下限可通、上限不通，再以 MTU 1400 为分割基准点一刀收缩区间，
/// 然后每轮并发探测 (lo, hi) 区间内的 k 个等分点（k = CPU 核心数，可用 concurrency 覆盖），
/// 按结果保守收缩区间直至收敛。区间不变量与收缩逻辑由 `SearchInterval` 维护。
///
/// 依赖注入（低耦合 / 可测试）：
/// - `send`：探测能力抽象，默认走真实 ICMP（`Ping.send`）；测试可注入模拟路径。
/// - `log`：进度日志抽象，默认无操作；表示层（stderr / 安静模式）由调用方决定，
///   Core 不再绑定终端。
public func probeMTU(
  _ opts: ProbeOptions,
  localMaxMTU: Int?,
  send: (@Sendable (Int, Int) async -> PingOutcome)? = nil,
  log: @escaping @Sendable (String) -> Void = { _ in }
) async -> ProbeResult {
  let overhead = opts.family.headerOverhead
  let minMTU = opts.minMTU ?? opts.family.defaultMinMTU
  let maxMTU = opts.maxMTU ?? localMaxMTU ?? 1500
  var probeCount = 0
  let start = DispatchTime.now()  // 单调时钟，不受系统时间调整影响

  // 探测能力：未注入时走真实 ICMP。默认闭包在函数体内构造（可安全捕获 opts）。
  let probe: @Sendable (Int, Int) async -> PingOutcome =
    send ?? { mtu, timeout in
      await Ping.send(
        family: opts.family,
        host: opts.host,
        payload: mtu - overhead,
        timeoutMillis: timeout
      )
    }

  func finish(best: Int?, capped: Bool = false, error: String? = nil) -> ProbeResult {
    let elapsedMillis = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

    return ProbeResult(
      family: opts.family,
      host: opts.host,
      bestMTU: best,
      payload: best.map { $0 - overhead },
      probeCount: probeCount,
      elapsedMillis: elapsedMillis,
      cappedAtMax: capped,
      error: error
    )
  }

  guard maxMTU >= minMTU else {
    return finish(best: nil, error: "搜索区间非法：min \(minMTU) > max \(maxMTU)")
  }

  log("开始探测 \(opts.host)，搜索区间 [\(minMTU), \(maxMTU)]")

  // 1. 基线：确认下限可通，否则目标不可达（或存在更严重的连通性问题）
  let (minResult, minProbes) = await attemptProbe(
    mtu: minMTU,
    opts: opts,
    timeoutMillis: opts.timeoutMillis,
    send: probe,
    log: log
  )
  probeCount += minProbes

  var maxRTT: Double = 0

  switch minResult {
  case .fatal(let message): return finish(best: nil, error: message)
  case .fail:
    return finish(best: nil, error: "最小 MTU \(minMTU) 都无法通过，目标不可达或路径异常")
  case .ok(let rtt): maxRTT = rtt ?? 0
  }

  var probeTimeout = adaptiveTimeout(maxRTT: maxRTT, ceiling: opts.timeoutMillis)

  if probeTimeout < opts.timeoutMillis {
    log(
      String(
        format: "基准 RTT %.2f ms → 单次探测超时自适应为 %d ms（上限 %d ms）",
        maxRTT,
        probeTimeout,
        opts.timeoutMillis
      )
    )
  }

  var interval = SearchInterval(lo: minMTU, hi: maxMTU)

  // 2. 上限直接可通：说明最佳 MTU 不低于上限
  let (maxResult, maxProbes) = await attemptProbe(
    mtu: maxMTU,
    opts: opts,
    timeoutMillis: probeTimeout,
    send: probe,
    log: log
  )
  probeCount += maxProbes

  switch maxResult {
  case .fatal(let message): return finish(best: nil, error: message)
  case .ok:
    return finish(best: maxMTU, capped: true)
  case .fail(let hint):
    // ICMP 差错通告 MTU 上界 hint：PMTU ≤ hint，排他上界收缩到 hint+1
    interval.applyFail(maxMTU, hint: hint)

    if let hint, hint > 0, interval.hi < maxMTU {
      log("ICMP 差错通告 MTU ≤ \(hint)，搜索上限收缩至 \(interval.hi - 1)")
    }
  }

  let concurrency = max(1, opts.concurrency ?? ProcessInfo.processInfo.activeProcessorCount)

  // 3. 分割基准点：先探 1400，把区间一刀切成「≥1400」与「<1400」两段。
  //    仅当 1400 严格位于区间内部、且内部候选多于并发度时才单独探：
  //    否则一轮并发即可覆盖全部候选（含 1400），单独探反而多一次串行等待。
  if interval.lo < pivotMTU, pivotMTU < interval.hi, interval.interiorCount > concurrency {
    let (pivotResult, pivotProbes) = await attemptProbe(
      mtu: pivotMTU,
      opts: opts,
      timeoutMillis: probeTimeout,
      send: probe,
      log: log
    )
    probeCount += pivotProbes

    switch pivotResult {
    case .fatal(let message): return finish(best: nil, error: message)
    case .ok(let rtt):
      interval.applyPass(pivotMTU)

      if let rtt { maxRTT = max(maxRTT, rtt) }

    case .fail(let hint):
      interval.applyFail(pivotMTU, hint: hint)

      if let hint, hint > 0, interval.hi < pivotMTU {
        log("ICMP 差错通告 MTU ≤ \(hint)，搜索上限收缩至 \(interval.hi - 1)")
      }
    }

    probeTimeout = adaptiveTimeout(maxRTT: maxRTT, ceiling: opts.timeoutMillis)
  }

  // 4. 并发 k 点探测：每轮在 (lo, hi) 内取 k 个等分点并发探测，剩余候选不超过 k 时一轮探完。
  while !interval.isConverged {
    let k = min(concurrency, interval.interiorCount)
    let points = interval.divisionPoints(k)

    let tasks = points.map { point in
      Task { await attemptProbe(mtu: point, opts: opts, timeoutMillis: probeTimeout, send: probe, log: log) }
    }

    var outcomes: [(Attempt, Int)] = []

    for task in tasks { outcomes.append(await task.value) }  // 全部等完；Ping 不响应取消

    for (_, n) in outcomes { probeCount += n }

    // 任一致命错误即终止
    for (r, _) in outcomes {
      if case .fatal(let message) = r { return finish(best: nil, error: message) }
    }

    // 保守聚合（容忍偶发丢包导致的非单调结果）：
    // 先取最大通过点抬 lo，再取严格大于它的最小失败点压 hi；
    // 低于 lo 的失败视为抖动忽略。每轮至少一个边界严格移动，保证收敛。
    for (point, (r, _)) in zip(points, outcomes) {
      if case .ok(let rtt) = r {
        interval.applyPass(point)

        if let rtt { maxRTT = max(maxRTT, rtt) }
      }
    }

    for (point, (r, _)) in zip(points, outcomes) {
      if case .fail(let hint) = r, point > interval.lo {
        interval.applyFail(point, hint: hint)
      }
    }

    probeTimeout = adaptiveTimeout(maxRTT: maxRTT, ceiling: opts.timeoutMillis)
  }

  return finish(best: interval.lo)
}

/// 单次 MTU 探测（含超时重试），返回 (搜索判定, 实际发包数)。
///
/// 显式接收全部依赖（opts / send / log），不捕获共享可变状态——
/// 并发 Task 调用它时彼此隔离，发包计数以返回值汇总，避免数据竞争。
private func attemptProbe(
  mtu: Int,
  opts: ProbeOptions,
  timeoutMillis: Int,
  send: @Sendable (Int, Int) async -> PingOutcome,
  log: @Sendable (String) -> Void
) async -> (Attempt, Int) {
  let payload = mtu - opts.family.headerOverhead

  guard payload >= 0 else { return (.fail(nil), 0) }

  var used = 0

  for round in 0...opts.retries {
    used += 1
    let outcome = await send(mtu, timeoutMillis)

    switch outcome.kind {
    case .ok:
      let rtt = outcome.rttMillis.map { String(format: "%.2f ms", $0) } ?? "?"
      log("MTU \(mtu) (payload \(payload)) ✓ 通过, RTT \(rtt)")
      return (.ok(outcome.rttMillis), used)
    case .tooBig:
      log("MTU \(mtu) (payload \(payload)) ✗ 报文过大，禁止分片")
      return (.fail(outcome.reportedMTU), used)
    case .noReply:
      if round < opts.retries {
        log("MTU \(mtu) (payload \(payload)) … 超时，重试 (\(round + 1)/\(opts.retries))")
        continue
      }

      log("MTU \(mtu) (payload \(payload)) ✗ 超时无响应")
      return (.fail(nil), used)
    case .error:
      return (.fatal(outcome.message), used)
    }
  }

  return (.fail(nil), used)
}

/// 自适应单次超时：静默丢包路径上，失败点的主要代价是「超时 × (retries+1)」。
/// 基线已测得 RTT，单次等待收紧为 5×最大已见 RTT + 100ms（下限 200ms），
/// 用户 --timeout 作为上限。偶发抖动由重试兜底。
private func adaptiveTimeout(maxRTT: Double, ceiling: Int) -> Int {
  min(ceiling, max(200, Int(maxRTT * 5) + 100))
}
