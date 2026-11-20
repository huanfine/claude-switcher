# ARCHITECTURE.md —— 架构与功能分析

> 这份文件回答「这个系统是怎么搭起来的、每一项功能实际测了什么、哪里还有缺口」。
> 操作纪律与踩坑清单在 [AGENTS.md](AGENTS.md)，用法在 [README.md](README.md)，本文不重复它们。
> 文中结论以代码为准，标注了出处；口径变更时请同步本文，不要让它退化成过期快照。

---

## 1. 系统定性

名义上是「账号切换器」，实质是**以出口身份一致性为核心的 fail-closed 门禁系统**：
让同一个 Claude 账号在任何时刻都只从同一个可信出口身份出现。切换账号只是门禁放行后的一个动作。

规模（不含测试与构建产物）：

| 组成 | 文件 | 行数 |
|---|---|---|
| 核心（macOS） | `core/claude-switch.sh` | 6273（bash 115 个函数） |
| ├ 内嵌 Python | 同文件 4 段 heredoc | 1911 |
| 界面（macOS） | `app/main.swift` | 5654（VM ≈1780 / Views ≈3460） |
| Windows | `windows/*.ps1` | 3691 |
| Linux | `linux/*.sh` | 1129 |
| Web 检测页 | `docs/app.js` | 1225 |

内嵌 Python 的四段各自独立、互不依赖：`PY_SUPPORT`(869) 结构化判定与报告、
`PY_CLASH_RULES`(710) 内核规则、`PY_FLCLASH_REPAIR`(195)、`PY_PROXY_DIAGNOSE`(130)。

## 2. 执行域与权限边界

```
┌── 用户态 GUI（SwiftUI，ad-hoc 签名）───────────────────────┐
│  app/main.swift：编排 + 聚合展示，不内置任何判型            │
└──────────────┬─────────────────────────────────────────────┘
               │ 子进程调用；文本 16 行 / JSON 报告 / 租约
┌──────────────▼─────────────────────────────────────────────┐
│  核心 ~/.local/bin/claude-switch.sh                        │
│  bash：探测、系统调用、进程与文件事务                        │
│  Python：结构化判定、报告序列化、内核规则                     │
└──────────────┬─────────────────────────────────────────────┘
               │ env.json · checks.json · last-report.json · lease.json
┌──────────────▼─────────────────────────────────────────────┐
│  root 守护 /Library/Application Support/claude-switcher/   │
│  bodyguard 10s · tz-watchdog 300s（root:wheel 755）         │
└──────────────┬─────────────────────────────────────────────┘
               │ TUN 网卡 + 置顶规则
┌──────────────▼─────────────────────────────────────────────┐
│  mihomo 内核 / Clash Verge Script.js                       │
└────────────────────────────────────────────────────────────┘
```

分域的理由是攻击面而不是分层洁癖：判定逻辑在用户态可被篡改，所以「代理死了就杀 Claude」
这条兜底必须放在用户不可写的 root 目录，日志也必须落在 root 所有的 `/var/log/claude-switcher/`
（否则用户可以把日志换成符号链接，让 root 跟着写别处）。守护周期见 `daemons/*.plist`。

## 3. 三层分离：功能 / 数据 / 环境

| 层 | 载体 | 约束换来的能力 |
|---|---|---|
| 功能 | `core/` `app/` `daemons/` | 不含环境值 → **发布产物 = 安装产物** → SHA256 可整份比对 |
| 数据 | `data/claude-rules.json` | 域名与端口单一来源，4 平台清单块由 `scripts/sync-rules.py` 生成，`--check` 做漂移守卫 |
| 环境 | `~/.claude-switcher/env.json` | 安装器写、运行期读；损坏即 fail，不静默兜底 |

这一层最关键的收益是供应链：历史上安装器用 sed 回写脚本头部变量，导致安装产物 ≠ 发布产物、
校验要剔行、升级要回注。拆除之后 `SHA256SUMS` 才能作为自动更新的完整性依据。

## 4. 契约：文本 → 报告 → 租约

```
checkdetail          → 16 行文本（人读；旧 App 的唯一入口）
checkdetail --json   → claude-switcher-report/2
                       稳定 ID + critical + evidence/remedy + config_fingerprint
                       TTL 30 分钟
lease                → claude-switcher-lease/1
                       绑定 report_id + config_fingerprint + core_sha256
                       TTL min(120 秒, 报告剩余)，一次性：拉起后立即撤销
```

**报告 ≠ 授权**：检查是快照，启动是许可。任何改环境、改配置、切节点、修复的动作都撤销旧租约，
所以「检查过了但环境变了」不能蒙混启动。判定入口见 `core` 的 `lease_document()` / `lease_check()`。

跨版本降级是显式设计：只有「退出码 2 + 老 usage」才判定核心过旧，普通失败不误判；
旧核心忽略 `--json` 继续输出文本时，复用同一份输出走文本解析，不重复探测。

## 5. 检查项的实际测量口径

`CHECK_SPECS`（`core/claude-switch.sh`）定义 16 项，8 硬 8 软；软的 8 项恰好是允许关闭的 8 项。

| ID | 显示名 | 怎么测 | 关键性 |
|---|---|---|---|
| `proxy_core` | 代理内核 | 按客户端分派 pgrep / scutil | 硬 |
| `tun` | TUN网卡 | `ifconfig` 含 fake-ip 前缀（前缀取自 env.json） | 硬 |
| `egress_ip` | 出口IP | 同域名连采 3 次 / 10 秒预算；不一致=fail，全空=unknown 仅警告 | 硬 |
| `ip_stability` | IP一致 | v4 原样、v6 取 /64 归一后比对；48h 变化按类型分档 | 软 |
| `timezone` / `locale` | 时区 / 地区 | `readlink /etc/localtime`、`AppleLocale` 对 env 目标 | 硬 |
| `ipv6` | IPv6 | 遍历所有网络服务，不是只查 Wi-Fi | 硬 |
| `dns` | DNS | `dig claude.ai` 是否落在 fake-ip 段 | 软 |
| `webrtc` | WebRTC | 纯 Python STUN 探针，只走 v4 | 软 |
| `bodyguard` | 保镖 | 服务注册 + 脚本归属与权限 | 硬 |
| `rules` | 规则置顶 | 读运行内核 `/rules` 按索引逐条比对，不是比对磁盘文件 | 硬 |
| `client_language` / `asn` | 客户端语言 / ASN属性 | defaults 读取 / ASN 归属 | 软 |
| `ip_purity` | IP纯净度 | 4 源并行 + PTR，类型基线 − 连续扣分；类型只看结构证据 | 软 |
| `ecosystem` | 生态可达性 | claude.ai 与 api.anthropic.com 各一次 | 软 |
| `better_node` | 更优节点 | 只读扫描报告文件，检查预算内零网络请求 | 软 |

结论五态 `ok / warn / config / fail / skip`。`config`（环境层没就绪）与 `fail`（实测不达标）
分开是有意为之：两者的修复动作不同，混为一谈会把用户支去改错误的东西。`skip` 不算通过。

## 6. 三道防线与一次实证

```
启动前   checkdetail → established → lease → open -a Claude → 立即撤销租约
运行中   App watch（10 秒采样 / 每 6 轮整轮审计）  ← 基线只取放行那一刻
         root bodyguard（10 秒）                   ← TUN/内核消失即 pkill
         root tz-watchdog（300 秒）                ← 时区漂移即回滚
网络层   规则顺序固定：端口 → 域名 → IP CIDR(no-resolve)；IPv6 全服务关闭
实证     drill：关掉 TUN，域名与裸 IP 各探 3 次，任何一条能出去 = violated
```

前两道防线都是「检测到异常再杀进程」的事后补救。**只有 `drill` 能证明 fail-closed 成立**，
平时 16 项全绿只证明「流量此刻走了代理」。

## 7. 账号隔离与节点治理

一个槽位 = 两棵树：桌面版 `accounts/<A-H>/`，Claude Code `cli/<A-H>/home{,.json}`。
归档是移动语义；载入先写 `.new` 成功后才提交；目标槽位没存档时 `restore_cli` 会清空现场
（否则新槽位继承上一个账号登录态，等于没隔离）；`.new` / `.previous` 残留一律拒绝覆盖。

节点治理是**只读优先**：扫描不切节点（逐节点实测会污染 iphistory 并触发巡检），
硬门槛先于评分（国家、Tor/代理、UDP），差距不足 10 分不出 BEST，应用时重新实时判门禁、
切后复查国家不达标自动回滚。槽位绑定优先于本次最优。

## 8. 测试与交付

- 568 项隔离回归：44 个 Python 测试文件中 31 个真执行代码，13 个是静态断言（其中 11 个针对 Windows）。
- 跨语言编排：`tests/test_menu_bar_model.py` 现场用 `swiftc` 编译 `tests/MenuBarModelTests.swift`（1127 行）再逐场景驱动。
- Windows 在 PS 5.1 与 pwsh 7 双壳跑真集成脚本（切换、快照、报告、语言与 ASN）。
- CI：`checks.yml`（语法 / 回归 / Swift 严格编译 / 哈希 / JS 语法 + Windows 双壳），`release.yml`（打包 + 跨平台门禁）。
- 抽取式测试：多数用例从真实脚本里切出函数体执行，绝不抄副本。代价是锚点隐式，改名/改注释可能让用例找不到段落。

## 9. 已知缺口（按严重度）

### P0 · fail-closed 是设计意图，尚不是已证明的事实

2026-11-01 本机 `drill` 结论为 `violated`：关掉 TUN 后域名探测直接从中国移动出口出去。
即「代理挂了不会裸连」这条核心承诺在该配置下不成立，而它会被「16 项全绿」掩盖。

已落地的缓解：**drill 证据持续可见**——从未演练、演练未通过或证据过期时，
门禁输出、报告 v2 与界面都会明确标注 fail-closed 未证明（口径见 §10）。

尚未落地、需要维护者决策的部分：

- **PF anchor 兜底**：只允许 TUN 出口，代理消失时由防火墙保证断网而不是靠杀进程。
  这是唯一能把 fail-closed 从「检测后补救」变成「结构上成立」的做法，但会改系统网络状态，
  必须真机验证并准备可靠的卸载路径，不能盲改。
- **把 drill 纳入安装后强制验收**：会在安装过程中真的断一次网，需权衡用户体验与恢复可靠性。

### P1 · 平台能力断层

命令面 macOS 35 / Windows 21 / Linux 7。租约、drill、verdict/evidence、node-scan/apply、watch
在 Windows 缺失；Linux 只有 checkdetail/report/status/fix/switch/menu。
跨平台一致的是**报告格式**，不是**防护能力**。矩阵见 README，不要用「Beta」一词掩盖差异。

### P1 · 测试证据强度不均

13/44 是纯静态字符串断言（11 个针对 Windows），钉的是「代码里有这句话」而不是「这段代码做对事」。
Windows 的 WPF、FlClash、隔离浏览器、加密快照、安装更新仍无真机验收。

### P2 · 时间预算与外部依赖

App 检查硬超时 45 秒；出口采样 10 秒、纯净度四源并行 6 秒、生态可达性 2×8 秒，最坏路径接近上限，
而分项耗时目前不可观测。纯净度依赖四个第三方免费源（ipinfo 429 已实测），
三级运营商兜底 + 降级判型 + 5 分钟短 TTL 是缓解，但评分本质是外部信誉的函数，不可复现。

### P3 · 其余结构性风险

- App 直读盘（`loadSlotNodes` / `probeSlotLogin`）与核心写端各自拼同一路径，属两处实现同一契约。
- 更新信任根是 GitHub + TLS，无独立签名：防传输篡改，不防仓库接管。
- 快照 macOS DMG 与 Windows `.csnap` 不互通，跨平台迁移无路径。
- 可选字段的判空与取值要对齐同一个对象：`build_report` 曾在 `if probes or drill` 条件下取
  `probes.get(...)`，于是「跑过一次 drill 但没有本轮 sidecar」的两条路（离线 `report`、sidecar 失败）
  直接崩掉整份 JSON 报告。已修为 `(probes or {}).get(...)` 并加回归。

## 10. fail-closed 证据的判定口径

来源是演练留下的证据，不重跑演练、不发网络请求：优先读 `drill-counters.json` 的
`result` / `checked_at`，老安装件没有计数器文件时倒序解析 `drill.log` 的 `<epoch> … result=` 行。
有效期 `DRILL_EVIDENCE_TTL_SECONDS` 为 7 天。

| 情形 | 状态 | 表现 |
|---|---|---|
| 没有演练记录 / 记录读不懂 | `unverified` | 持续标注「未验证」，不算通过 |
| 最后一条 `violated` | `violated` | 持续标注「演练未通过」，点名直连风险；**不看时间**，放久了也不会变成通过 |
| 最后一条 `established` 且在 7 天内 | `established` | 不额外提示 |
| 最后一条 `established` 但已过期或时间读不出来 | `stale` | 标注「证据已过期」，需重跑 |

四条纪律：

1. **不新增第 17 项检查。** 16 项是稳定契约，报告 ID 与界面行数都被测试钉住；
   fail-closed 证据是与 `probes` 同级的报告附加字段，旧报告缺该字段仍按原语义解析。
2. **不改判定门禁。** 它是软信号：不拦启动、不进 blockers，也不参与 `config_fingerprint`。
   把网络抖动或用户没跑演练升级成硬失败，等于拿我们自己的证据缺口去堵用户。
3. **不能只在界面可见。** 命令行、日志、自动化看不到界面，`check` 输出必须同样带标记，
   与「防护降级」用的是同一条纪律。
4. **未验证 ≠ 通过。** 空记录必须显式说「未验证」，不能沉默，也不能写成 ok。

## 11. 演进顺序

1. fail-closed 证据可见化（已落地）→ 评估 PF anchor 兜底 → 决定是否把 drill 纳入安装验收。
2. 平台能力矩阵显式化（已落地）→ 按矩阵补齐 Windows/Linux 的防护能力，而不是只补报告格式。
3. 给报告加分项耗时，让 45 秒预算可观测，再谈优化。
4. 给被抽取的代码段加显式锚点注释，把隐式契约变显式。
5. 中期：Windows 静态断言升级为执行式；更新加独立签名；统一快照容器格式。