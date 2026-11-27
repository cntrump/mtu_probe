import Foundation
import MTUProbeCore

@main
struct MTUProbe {
  static func main() async {
    // 1. 解析命令行
    let opts: CLIOptions

    do {
      opts = try CLIOptions.parse(Array(CommandLine.arguments.dropFirst()))
    } catch let error as CLIOptions.ParseError {
      if !error.message.isEmpty { fputs(error.message + "\n", stderr) }

      exit(2)
    } catch {
      fputs("错误：\(error)\n", stderr)
      exit(2)
    }

    if opts.helpRequested {
      printHelp()
      return
    }

    // 2. 环境发现：每族解析默认搜索上限（出口接口 MTU，回退活跃接口最大 MTU）
    let fallbackMax = detectLocalMaxMTU()
    var plans: [(family: IPFamily, host: String, maxMTU: Int?)] = []

    if !opts.onlyV6 {
      plans.append(
        (.v4, opts.v4Host, resolveMax(host: opts.v4Host, family: .v4, fallback: fallbackMax, quiet: opts.quiet))
      )
    }

    if !opts.onlyV4 {
      plans.append(
        (.v6, opts.v6Host, resolveMax(host: opts.v6Host, family: .v6, fallback: fallbackMax, quiet: opts.quiet))
      )
    }

    let effectiveConcurrency = opts.concurrency ?? ProcessInfo.processInfo.activeProcessorCount
    info("并发度: \(effectiveConcurrency)\(opts.concurrency == nil ? "（CPU 核心数）" : "")", quiet: opts.quiet)
    info(
      "目标: IPv4 \(opts.v4Host)\(opts.onlyV6 ? "（跳过）" : "") / IPv6 \(opts.v6Host)\(opts.onlyV4 ? "（跳过）" : "")",
      quiet: opts.quiet
    )
    info(String(repeating: "-", count: 60), quiet: opts.quiet)

    // 3. 编排：各族并行探测（按族循环，消除 v4/v6 对称复制）
    var tasks: [Task<ProbeResult, Never>] = []

    for plan in plans {
      let family = plan.family
      let host = plan.host
      let maxMTU = plan.maxMTU
      let quiet = opts.quiet
      let probeOpts = ProbeOptions(
        host: host,
        family: family,
        minMTU: opts.minMTU,
        maxMTU: opts.maxMTU,
        timeoutMillis: opts.timeoutMillis,
        retries: opts.retries,
        concurrency: opts.concurrency
      )

      tasks.append(
        Task {
          await probeMTU(
            probeOpts,
            localMaxMTU: maxMTU,
            log: { message in
              if !quiet { fputs("[\(family.rawValue)] \(message)\n", stderr) }
            }
          )
        }
      )
    }

    var results: [ProbeResult] = []

    for task in tasks { results.append(await task.value) }

    // 4. 渲染结果
    ResultRenderer.render(results, format: opts.format)

    // 5. 退出码：0 全部成功 / 1 任一失败 / 2 参数错误
    let allSuccess = results.allSatisfy { $0.bestMTU != nil }

    exit(allSuccess ? 0 : 1)
  }

  /// 解析某族的默认搜索上限：优先「到目标的出口接口」MTU（内核选路），
  /// 避免无关接口（其他 VPN 的 utun、巨帧桥接等）抬高上限造成大量无谓超时；
  /// 未能定位出口接口时回退活跃接口最大 MTU。
  private static func resolveMax(host: String, family: IPFamily, fallback: Int?, quiet: Bool) -> Int? {
    if let egress = detectEgressInterface(host: host, family: family) {
      info("\(family.rawValue) 出口接口: \(egress.name)（MTU \(egress.mtu)，作为默认搜索上限）", quiet: quiet)
      return egress.mtu
    }

    if let fallback {
      info("\(family.rawValue) 默认搜索上限: \(fallback)（未能定位出口接口，取活跃接口最大 MTU）", quiet: quiet)
    }

    return fallback
  }

  /// 进度信息 → stderr，保证 stdout 只有结果数据，可安全管道/重定向。
  private static func info(_ message: String, quiet: Bool) {
    if !quiet { fputs(message + "\n", stderr) }
  }

  static func printHelp() {
    print(
      """
      mtu-probe — 自动探测当前网络 IPv4/IPv6 路径的最佳 MTU

      原理：发送禁止分片（IPv4 DF / IPv6 天然不分片）的 ICMP 探测包，
      先以 MTU 1400 为二分分割基准点收缩区间，再按 CPU 核心数并发多点探测（Task 并行），
      逐轮收敛到能完整通过路径的最大报文尺寸。
      MTU = ICMP payload + 头部开销（IPv4: 28 字节，IPv6: 48 字节）。

      用法: swift run mtu-probe [选项]
            .build/release/mtu-probe [选项]

      选项:
        --v4 <addr>      IPv4 探测目标（默认 223.5.5.5）
        --v6 <addr>      IPv6 探测目标（默认 2400:3200::1）
        --only-v4        仅探测 IPv4
        --only-v6        仅探测 IPv6
        --min <mtu>      搜索下限（默认 IPv4 576 / IPv6 1280）
        --max <mtu>      搜索上限（默认取到目标的出口接口 MTU）
        --timeout <ms>   单次探测超时上限毫秒数（默认 1000；实际按已测 RTT 自适应收紧）
        --retries <n>    超时重试次数（默认 2）
        --concurrency <n> 每轮并发探测点数（默认 CPU 核心数；1 = 顺序二分）
        --format <fmt>   结果格式（stdout）：
                           human  人类可读摘要（默认）
                           json   每行一个紧凑 JSON 对象（NDJSON，便于 jq 逐行处理）
                           tsv    制表符分隔，无表头，列序固定：
                                  family host bestMTU payload probeCount cappedAtMax error elapsedMillis
                           value  仅最佳 MTU 数值，每族一行（v4 → v6），失败为空行
        --json           等价于 --format json
        --quiet, -q      关闭进度日志
        --help, -h       显示本帮助

      输出流: 进度日志 → stderr；结果数据 → stdout。
              脚本中可直接管道/重定向 stdout，无需 --quiet。
      退出码: 0 全部成功 / 1 任一目标探测失败 / 2 参数错误

      脚本示例:
        MTU=$(mtu-probe --only-v4 --format value)
        mtu-probe --format tsv | awk -F'\\t' '$3 != "" {print $1, $3}'
        mtu-probe --format json | jq -r 'select(.family=="IPv4") | .bestMTU'
      """
    )
  }
}
