import Foundation

/// 结果输出格式（stdout）。进度日志一律走 stderr，与格式无关。
enum OutputFormat: String {
  case human  // 人类可读摘要块
  case json  // NDJSON：每行一个紧凑 JSON 对象（ProbeResult）
  case tsv  // 制表符分隔：family host bestMTU payload probeCount cappedAtMax error elapsedMillis
  case value  // 仅最佳 MTU 数值，每族一行（失败为空行）
}

/// 解析并校验后的命令行选项。
///
/// 参数解析与校验（互斥、钳制、IPv6 方括号剥离）内聚于此，
/// `main` 不再处理原始字符串。
struct CLIOptions {
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
  var helpRequested = false

  struct ParseError: Error {
    let message: String
  }

  static func parse(_ arguments: [String]) throws -> CLIOptions {
    var opts = CLIOptions()
    var args = arguments

    func nextValue(_ flag: String) throws -> String {
      guard !args.isEmpty else {
        throw ParseError(message: "错误：\(flag) 缺少参数值")
      }

      return args.removeFirst()
    }

    func nextInt(_ flag: String) throws -> Int {
      let raw = try nextValue(flag)

      guard let value = Int(raw) else {
        throw ParseError(message: "错误：\(flag) 需要整数，收到 \"\(raw)\"")
      }

      return value
    }

    while !args.isEmpty {
      let arg = args.removeFirst()

      switch arg {
      case "--v4": opts.v4Host = try nextValue(arg)
      case "--v6": opts.v6Host = try nextValue(arg)
      case "--only-v4": opts.onlyV4 = true
      case "--only-v6": opts.onlyV6 = true
      case "--min": opts.minMTU = try nextInt(arg)
      case "--max": opts.maxMTU = try nextInt(arg)
      case "--timeout": opts.timeoutMillis = try nextInt(arg)
      case "--retries": opts.retries = try nextInt(arg)
      case "--concurrency": opts.concurrency = max(1, try nextInt(arg))
      case "--quiet", "-q": opts.quiet = true
      case "--json": opts.format = .json
      case "--format":
        let raw = try nextValue(arg)

        guard let f = OutputFormat(rawValue: raw) else {
          throw ParseError(message: "错误：--format 支持 human/json/tsv/value，收到 \"\(raw)\"")
        }

        opts.format = f
      case "--help", "-h":
        opts.helpRequested = true
        return opts
      default:
        throw ParseError(message: "错误：未知参数 \(arg)（--help 查看用法）")
      }
    }

    if opts.onlyV4 && opts.onlyV6 {
      throw ParseError(message: "错误：--only-v4 与 --only-v6 不能同时使用")
    }

    // 允许用户以 [addr] 形式书写 IPv6 地址
    opts.v6Host = opts.v6Host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    opts.retries = max(0, opts.retries)
    opts.timeoutMillis = max(100, opts.timeoutMillis)

    return opts
  }
}
