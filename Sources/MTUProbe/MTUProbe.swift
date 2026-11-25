import Foundation
import MTUProbeCore

@main
struct MTUProbe {
    /// 结果输出格式（stdout）。进度日志一律走 stderr，与格式无关。
    enum OutputFormat: String {
        case human   // 人类可读摘要块
        case json    // NDJSON：每行一个紧凑 JSON 对象（ProbeResult）
        case tsv     // 制表符分隔：family host bestMTU payload probeCount cappedAtMax error elapsedMillis
        case value   // 仅最佳 MTU 数值，每族一行（失败为空行）
    }

    static func main() async {
        var v4Host = "223.5.5.5"
        var v6Host = "2400:3200::1"
        var onlyV4 = false
        var onlyV6 = false
        var minMTU: Int?
        var maxMTU: Int?
        var timeoutMillis = 1000
        var retries = 2
        var concurrency: Int?
        var quiet = false
        var format: OutputFormat = .human

        var args = Array(CommandLine.arguments.dropFirst())

        func nextValue(_ flag: String) -> String {
            guard !args.isEmpty else {
                fputs("错误：\(flag) 缺少参数值\n", stderr)
                exit(2)
            }
            return args.removeFirst()
        }

        func nextInt(_ flag: String) -> Int {
            let raw = nextValue(flag)
            guard let value = Int(raw) else {
                fputs("错误：\(flag) 需要整数，收到 \"\(raw)\"\n", stderr)
                exit(2)
            }
            return value
        }

        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--v4": v4Host = nextValue(arg)
            case "--v6": v6Host = nextValue(arg)
            case "--only-v4": onlyV4 = true
            case "--only-v6": onlyV6 = true
            case "--min": minMTU = nextInt(arg)
            case "--max": maxMTU = nextInt(arg)
            case "--timeout": timeoutMillis = nextInt(arg)
            case "--retries": retries = nextInt(arg)
            case "--concurrency": concurrency = max(1, nextInt(arg))
            case "--quiet", "-q": quiet = true
            case "--json": format = .json
            case "--format":
                let raw = nextValue(arg)
                guard let f = OutputFormat(rawValue: raw) else {
                    fputs("错误：--format 支持 human/json/tsv/value，收到 \"\(raw)\"\n", stderr)
                    exit(2)
                }
                format = f
            case "--help", "-h":
                printHelp()
                return
            default:
                fputs("错误：未知参数 \(arg)（--help 查看用法）\n", stderr)
                exit(2)
            }
        }

        if onlyV4 && onlyV6 {
            fputs("错误：--only-v4 与 --only-v6 不能同时使用\n", stderr)
            exit(2)
        }

        // 允许用户以 [addr] 形式书写 IPv6 地址
        v6Host = v6Host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        retries = max(0, retries)
        timeoutMillis = max(100, timeoutMillis)

        // 默认搜索上限取「到目标的出口接口」MTU（内核选路），
        // 避免无关接口（其他 VPN 的 utun、巨帧桥接等）抬高上限造成大量无谓超时。
        let fallbackMax = detectLocalMaxMTU()
        let v4Egress = onlyV6 ? nil : detectEgressInterface(host: v4Host, family: .v4)
        let v6Egress = onlyV4 ? nil : detectEgressInterface(host: v6Host, family: .v6)
        let v4Max = v4Egress?.mtu ?? fallbackMax
        let v6Max = v6Egress?.mtu ?? fallbackMax

        // 进度信息 → stderr，保证 stdout 只有结果数据，可安全管道/重定向。
        func info(_ message: String) {
            if !quiet { fputs(message + "\n", stderr) }
        }
        if let e = v4Egress { info("IPv4 出口接口: \(e.name)（MTU \(e.mtu)，作为默认搜索上限）") }
        if let e = v6Egress { info("IPv6 出口接口: \(e.name)（MTU \(e.mtu)，作为默认搜索上限）") }
        if v4Egress == nil && !onlyV6, let fallbackMax {
            info("IPv4 默认搜索上限: \(fallbackMax)（未能定位出口接口，取活跃接口最大 MTU）")
        }
        if v6Egress == nil && !onlyV4, let fallbackMax {
            info("IPv6 默认搜索上限: \(fallbackMax)（未能定位出口接口，取活跃接口最大 MTU）")
        }
        let effectiveConcurrency = concurrency ?? ProcessInfo.processInfo.activeProcessorCount
        info("并发度: \(effectiveConcurrency)\(concurrency == nil ? "（CPU 核心数）" : "")")
        info("目标: IPv4 \(v4Host)\(onlyV6 ? "（跳过）" : "") / IPv6 \(v6Host)\(onlyV4 ? "（跳过）" : "")")
        info(String(repeating: "-", count: 60))

        // 两个地址族并行探测
        var tasks: [Task<ProbeResult, Never>] = []
        if !onlyV6 {
            tasks.append(Task {
                await probeMTU(ProbeOptions(
                    host: v4Host, family: .v4, minMTU: minMTU, maxMTU: maxMTU,
                    timeoutMillis: timeoutMillis, retries: retries, quiet: quiet,
                    concurrency: concurrency
                ), localMaxMTU: v4Max)
            })
        }
        if !onlyV4 {
            tasks.append(Task {
                await probeMTU(ProbeOptions(
                    host: v6Host, family: .v6, minMTU: minMTU, maxMTU: maxMTU,
                    timeoutMillis: timeoutMillis, retries: retries, quiet: quiet,
                    concurrency: concurrency
                ), localMaxMTU: v6Max)
            })
        }

        var results: [ProbeResult] = []
        for task in tasks { results.append(await task.value) }

        switch format {
        case .human:
            printSummary(results)
        case .json:
            // NDJSON：每行一个紧凑对象，jq / grep / while read 均可逐行处理
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for result in results {
                if let data = try? encoder.encode(result),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }
        case .tsv:
            // 固定列序：family host bestMTU payload probeCount cappedAtMax error elapsedMillis
            // 数值缺失为空字段，cappedAtMax 为 0/1，elapsedMillis 保留 1 位小数，无表头
            // （elapsedMillis 追加在末列，既有列索引不变，兼容旧脚本）
            for result in results {
                let fields = [
                    result.family.rawValue,
                    result.host,
                    result.bestMTU.map(String.init) ?? "",
                    result.payload.map(String.init) ?? "",
                    String(result.probeCount),
                    result.cappedAtMax ? "1" : "0",
                    result.error ?? "",
                    String(format: "%.1f", result.elapsedMillis),
                ]
                print(fields.joined(separator: "\t"))
            }
        case .value:
            // 每个请求的族一行（顺序固定 v4 → v6），失败输出空行占位，原因走 stderr
            for result in results {
                if let best = result.bestMTU {
                    print(best)
                } else {
                    print("")
                    fputs("\(result.family.rawValue) 探测失败: \(result.error ?? "未知错误")\n", stderr)
                }
            }
        }

        // 0 = 全部请求的族探测成功；1 = 任一失败；2 = 参数错误
        let allSuccess = results.allSatisfy { $0.bestMTU != nil }
        exit(allSuccess ? 0 : 1)
    }

    /// 耗时的人类可读格式：≥1s 显示秒（2 位小数），否则显示毫秒
    static func formatElapsed(_ millis: Double) -> String {
        millis >= 1000
            ? String(format: "%.2f s", millis / 1000)
            : String(format: "%.0f ms", millis)
    }

    static func printSummary(_ results: [ProbeResult]) {
        print(String(repeating: "=", count: 60))
        print("探测结果")
        print(String(repeating: "=", count: 60))
        for result in results {
            let stats = "共 \(result.probeCount) 次探测，耗时 \(formatElapsed(result.elapsedMillis))"
            if let best = result.bestMTU, let payload = result.payload {
                var line = "\(result.family.rawValue)  \(result.host)  →  最佳 MTU: \(best)（ICMP payload \(payload)，\(stats)）"
                if result.cappedAtMax {
                    line += "\n     注：已达搜索上限，实际可能更大，可用 --max 提高上限"
                }
                print(line)
            } else {
                print("\(result.family.rawValue)  \(result.host)  →  探测失败: \(result.error ?? "未知错误")（\(stats)）")
            }
        }
    }

    static func printHelp() {
        print("""
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
        """)
    }
}