# mtu-probe

> 用 Swift 实现的命令行工具：自动探测当前网络到指定目标的 **IPv4 / IPv6 路径最佳 MTU**。

![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)
![Platform](https://img.shields.io/badge/platform-macOS%2013+%20%7C%20iOS%2013+-blue)
![Dependencies](https://img.shields.io/badge/dependencies-0-success)

无需 root、不调用系统 `ping`、零第三方依赖——自主实现 ICMP 协议，通过**混合二分 + 并发探测**在 1–2 轮内收敛到路径 MTU。默认测试阿里公共 DNS（`223.5.5.5` / `2400:3200::1`），双栈一次测完。

```
$ mtu-probe
IPv4  223.5.5.5      →  最佳 MTU: 1492（ICMP payload 1464，共 12 次探测，耗时 1.23 s）
IPv6  2400:3200::1   →  最佳 MTU: 1500（ICMP payload 1452，共 9 次探测，耗时 0.98 s）
```

## ✨ 技术亮点

| 亮点 | 说明 |
|---|---|
| 🔓 **非特权 ICMP** | `SOCK_DGRAM + IPPROTO_ICMP/ICMPV6` 数据报套接字（与 Apple SimplePing 在 iOS 上的机制相同），无需 root、无需特殊 entitlement，macOS / iOS 通用 |
| ⚡ **混合二分 + 并发探测** | 以 MTU 1400 为基准点一步砍掉大半区间，随后每轮用 Swift `Task` 并发探测至多 CPU 核心数个等分点，约 1–2 轮收敛 |
| ⏱ **自适应超时** | 基线 RTT 测得后，单次等待收紧为 `5×已见最大 RTT + 100ms`，静默丢包路径上每次失败代价从秒级降到百毫秒级 |
| 📨 **ICMP 差错直接收敛** | 收到 frag needed / Packet Too Big 时，直接按报文携带的下一跳 MTU 收缩上界，有差错回包的路径一步逼近答案 |
| 🎯 **出口接口 MTU 自动定位** | UDP `connect`（不发包）让内核选路，`getsockname` + `getifaddrs` 反查出口接口，无关 VPN utun / 巨帧桥接不会抬高搜索上限 |
| 🌐 **IPv4 / IPv6 双栈** | 两族并发探测（`Task`），正确处理 DF 位、IPv6 天然不分片、源端分片等协议细节 |
| 📦 **库 / CLI 分层** | 核心逻辑在 `MTUProbeCore` 库 target（macOS 13+ / iOS 13+），CLI 只是薄壳；`ProbeResult` 为 `Codable & Sendable`，`probeMTU` 的探测 / 日志依赖可注入，无需真实网络即可单测 |
| 🔧 **脚本友好** | 进度走 stderr、结果走 stdout；`human` / `json`(NDJSON) / `tsv` / `value` 四种输出格式 + 明确退出码 |

全部实现约 **1300 行 Swift**（另有约 300 行单元测试），仅依赖系统框架（Darwin / Dispatch / Foundation）。

## 快速开始

```bash
git clone https://github.com/cntrump/mtu_probe.git
cd mtu_probe
swift build -c release
.build/release/mtu-probe            # 探测默认目标
swift test                          # 单元测试（注入模拟路径，无需真实网络）
```

## 常用选项

```bash
mtu-probe --v4 8.8.8.8 --v6 2001:4860:4860::8888   # 自定义目标
mtu-probe --only-v4                                 # 仅 IPv4
mtu-probe --max 9000                                # 提高搜索上限（如测试巨帧）
mtu-probe --timeout 2000 --retries 3                # 高丢包网络下放宽超时上限/重试
mtu-probe --concurrency 4                           # 指定每轮并发探测点数（默认 CPU 核心数）
mtu-probe --format value                            # 只输出 MTU 数值，便于脚本消费
mtu-probe --json                                    # 等价于 --format json
mtu-probe --help                                    # 完整帮助
```

## 输出示例

```
[IPv4] MTU 1492 (payload 1464) ✓ 通过, RTT 12.30 ms
[IPv4] MTU 1493 (payload 1465) ✗ 报文过大，禁止分片
============================================================
探测结果
============================================================
IPv4  223.5.5.5      →  最佳 MTU: 1492（ICMP payload 1464，共 12 次探测，耗时 1.23 s）
IPv6  2400:3200::1   →  最佳 MTU: 1500（ICMP payload 1452，共 9 次探测，耗时 0.98 s）
```

每族结果均附带**探测次数**（实际发出的 ICMP 包数，含重试）与**耗时**（单调时钟测得的总耗时）；探测失败的行同样输出这两项。

## 工作原理

### 搜索策略：基准点 + 并发二分

基本关系：`MTU = ICMP payload + 头部开销`（IPv4：20 字节 IP 头 + 8 字节 ICMP 头 = 28；IPv6：40 + 8 = 48）。探测包一律**禁止分片**（IPv4 设置 DF 位；IPv6 路由器天然不分片），通过 / 失败即单调判定。

1. 先确认搜索下限可通、上限不通。
2. 以 **MTU 1400 为二分分割基准点**探测一次：通过则丢弃下方整段区间，失败则丢弃上方整段。现实路径 MTU 绝大多数 ≥ 1400，常见场景一步把范围压到百字节内。
3. 随后每轮用 Swift `Task` **并发探测**至多 `activeProcessorCount`（CPU 核心数）个等分点，按结果保守收缩区间：最大通过点抬下限、其上方最小失败点压上限，约 1–2 轮收敛。
4. 剩余候选不超过并发度时一轮探完（此时跳过基准点单独探测，避免多余串行等待）。

`--concurrency 1` 退化为顺序二分。总包数多于顺序二分，但串行轮次大幅减少；ICMP 限速路径上偶发假超时可用 `--retries 3` 放宽。

### 自主实现 ICMP，不调用系统 ping

使用非特权 ICMP datagram 套接字（`SOCK_DGRAM` + `IPPROTO_ICMP` / `IPPROTO_ICMPV6`），与 Apple SimplePing 在 iOS 上的机制相同，macOS / iOS 通用，无需 root、无需特殊 entitlement。

- **IPv4**：`IP_DONTFRAG` 设置 DF 位，超尺寸时 `sendto` 直接返回 `EMSGSIZE`；路径上收到 ICMP「frag needed」差错报文时确定性判定过大（可读出下一跳 MTU）。
- **IPv6**：`IPV6_DONTFRAG` 需要 root，非 root 下不使用——路由器天然不分片，路径 MTU 不足会收到 ICMPv6 Packet Too Big；默认搜索上限为出口接口 MTU，探测包不会超出口尺寸，避免本机源端分片。
- 超时由 `SO_RCVTIMEO` 实现；每次探测使用独立套接字，按 ICMP id/seq 匹配回包与差错报文。

### 三项加速手段

- **出口接口 MTU 作为搜索上限**：UDP `connect`（不发包）让内核选路，`getsockname` 取本地地址后在 `getifaddrs` 中反查接口。无关接口（其他 VPN 的 utun、巨帧桥接等）不会抬高上限，避免对必然被丢弃的尺寸做无谓超时探测；定位失败时回退为活跃接口最大 MTU。
- **自适应超时**：基线探测测得 RTT 后，单次等待收紧为 `5×已见最大 RTT + 100ms`（下限 200ms，`--timeout` 为上限）。静默丢包路径上失败点的主要代价是超时等待，收紧后每次失败代价从秒级降到百毫秒级。
- **利用 ICMP 差错通告的 MTU**：收到 frag needed / Packet Too Big 时，直接按报文携带的下一跳 MTU 收缩搜索上界，有差错回包的路径可一步逼近答案。

### 抗丢包

超时自动重试（默认 2 次）以抵抗偶发丢包；「报文过大」是确定性错误，不重试。

## 脚本集成

**输出流分离**：进度日志一律走 **stderr**，结果数据走 **stdout**。脚本中可直接管道/重定向 stdout，无需 `--quiet`（`--quiet` 仅用于同时关掉 stderr 日志）。

**结果格式**（`--format`，默认 `human`）：

| 格式 | stdout 内容 | 适用工具 |
|---|---|---|
| `human` | 人类可读摘要块 | 终端直接阅读 |
| `json` | 每行一个紧凑 JSON 对象（NDJSON），字段同 `ProbeResult`（缺失值省略键） | `jq`、`grep`、`while read` |
| `tsv` | 制表符分隔，无表头，列序固定：`family host bestMTU payload probeCount cappedAtMax error elapsedMillis`（缺失为空字段，`cappedAtMax` 为 0/1，`elapsedMillis` 为毫秒保留 1 位小数；末列追加，既有列索引不变） | `awk`、`cut` |
| `value` | 仅最佳 MTU 数值，每族一行（顺序固定 v4 → v6），失败为空行占位 | `$(…)` 直接取值 |

**退出码**：`0` 全部请求的族探测成功；`1` 任一失败；`2` 参数错误。

```bash
# 取单个数值
MTU=$(mtu-probe --only-v4 --format value) || { echo "探测失败" >&2; exit 1; }

# awk：输出各族最佳 MTU
mtu-probe --format tsv | awk -F'\t' '$3 != "" {print $1, $3}'

# jq：取 IPv4 的最佳 MTU
mtu-probe --format json | jq -r 'select(.family=="IPv4") | .bestMTU'

# jq：汇总为 {IPv4: …, IPv6: …}
mtu-probe --format json | jq -s 'map({(.family): .bestMTU}) | add'

# 条件判断：两个族都通才继续
if mtu-probe --quiet --format value >/dev/null; then echo "双栈可达"; fi
```

## 作为 Swift 库使用（macOS / iOS）

核心逻辑位于库 target **`MTUProbeCore`**（platforms：macOS 13+ / iOS 13+），不依赖任何 macOS 专属 API（无 `Process`、无系统 ping）。以 SPM 本地包依赖引入后：

```swift
import MTUProbeCore

// 默认上限取到目标的出口接口 MTU；定位失败时回退为活跃接口最大 MTU
let v4Max = detectEgressInterface(host: "223.5.5.5", family: .v4)?.mtu ?? detectLocalMaxMTU()
let v6Max = detectEgressInterface(host: "2400:3200::1", family: .v6)?.mtu ?? detectLocalMaxMTU()
async let v4 = probeMTU(ProbeOptions(host: "223.5.5.5", family: .v4), localMaxMTU: v4Max)
async let v6 = probeMTU(ProbeOptions(host: "2400:3200::1", family: .v6), localMaxMTU: v6Max)
let results = await [v4, v6]   // ProbeResult: Codable，含 bestMTU / payload / probeCount / elapsedMillis / error 等
```

命令行 CLI（`mtu-probe`）仅是 Core 之上的 macOS 薄壳。

## 项目结构

```
Sources/
├── MTUProbeCore/               # 核心库（macOS 13+ / iOS 13+）
│   ├── Probe.swift             # 搜索策略：基准点 + 并发二分、自适应超时、重试（send / log 可注入）
│   ├── SearchInterval.swift    # 搜索区间不变量与收缩逻辑（含 ICMP 差错通告 hint）
│   ├── ICMPSocket.swift        # 非特权 ICMP 套接字、DF 位；报文构造 / 解析 / 校验和为纯函数
│   ├── AddressResolver.swift   # 共享地址解析入口（getaddrinfo 平台陷阱单点维护）
│   ├── InterfaceMTU.swift      # 出口接口定位（UDP connect 让内核选路）
│   ├── InterfaceSnapshot.swift # getifaddrs 接口快照，活跃接口策略单点定义
│   └── IPFamily.swift          # IPv4 / IPv6 协议族常量与行为的单点来源
└── MTUProbe/                   # CLI 薄壳
    ├── MTUProbe.swift          # 编排：环境发现、两族并发探测、退出码
    ├── CLIOptions.swift        # 参数解析与校验
    └── ResultRenderer.swift    # human / json / tsv / value 输出
Tests/
└── MTUProbeCoreTests/          # 29 个单元测试：搜索算法、报文构造 / 解析、区间不变量、协议族常量
```

## 注意事项

- 探测结果是**本机视角的路径 MTU**。若开启了 TUN 模式的代理/VPN，ICMP 可能被虚拟网卡本地应答（RTT 极低），此时测得的是虚拟网卡 MTU 而非真实物理路径 MTU；如需测真实路径，请暂时关闭代理或绑定物理接口。
- 结果达到搜索上限时会提示 `cappedAtMax`，可用 `--max` 提高上限继续探测。
- 核心库支持 macOS 与 iOS；命令行可执行文件面向 macOS。
