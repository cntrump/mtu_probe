/// 二分搜索区间，由类型维护不变量：`lo` 已知可通，`hi` 为排他上界（PMTU < hi）。
///
/// 区间收缩逻辑（含 ICMP 差错通告 hint 的处理）单点内聚于此，
/// 取代原先散落在 probeMTU 三处的近似复制。
struct SearchInterval {
  private(set) var lo: Int
  private(set) var hi: Int

  init(lo: Int, hi: Int) {
    self.lo = lo
    self.hi = hi
  }

  /// 区间收敛：lo 与 hi 相邻，lo 即最佳 MTU。
  var isConverged: Bool { hi - lo <= 1 }

  /// 开区间 (lo, hi) 内的整数候选个数。
  var interiorCount: Int { hi - lo - 1 }

  /// 抬升下界到已知可通点。
  mutating func applyPass(_ point: Int) {
    lo = max(lo, point)
  }

  /// 压低排他上界。
  ///
  /// ICMP 差错通告的 MTU 上界 hint 满足 PMTU ≤ hint，
  /// 故上界可进一步收缩到 hint+1；`max(lo + 1, …)` 保证 hi 始终严格大于 lo。
  mutating func applyFail(_ point: Int, hint: Int?) {
    hi = min(hi, point)

    if let hint, hint > 0 {
      hi = max(lo + 1, min(hi, hint + 1))
    }
  }

  /// k 个等分点：严格递增且均在 (lo, hi) 内；k == interiorCount 时恰好覆盖全部内部整数。
  func divisionPoints(_ k: Int) -> [Int] {
    (1...k).map { lo + (hi - lo) * $0 / (k + 1) }
  }
}
