import Foundation
import MTUProbeCore

/// 结果渲染：每种格式一个方法。
///
/// TSV 列序契约与 ProbeResult 模型在此一起维护，而非散落在 main 的 switch 中。
/// 结果数据 → stdout；失败原因等诊断 → stderr。
enum ResultRenderer {
  static func render(_ results: [ProbeResult], format: OutputFormat) {
    switch format {
    case .human: human(results)
    case .json: json(results)
    case .tsv: tsv(results)
    case .value: value(results)
    }
  }

  /// 耗时的人类可读格式：≥1s 显示秒（2 位小数），否则显示毫秒
  static func formatElapsed(_ millis: Double) -> String {
    millis >= 1000
      ? String(format: "%.2f s", millis / 1000)
      : String(format: "%.0f ms", millis)
  }

  private static func human(_ results: [ProbeResult]) {
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

  private static func json(_ results: [ProbeResult]) {
    // NDJSON：每行一个紧凑对象，jq / grep / while read 均可逐行处理
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    for result in results {
      if let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) {
        print(line)
      }
    }
  }

  private static func tsv(_ results: [ProbeResult]) {
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
  }

  private static func value(_ results: [ProbeResult]) {
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
}
