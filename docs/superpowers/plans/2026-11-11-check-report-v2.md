# 检查报告 v2：从文本行到可追溯契约

- 日期：2026-11-11
- 状态：三批已完成（报告契约、探测口径、跨平台入口与发布门禁）
- 范围：`core/claude-switch.sh`、检查协议、核心测试、README/AGENTS
- 首批不包含：App 全面改用 JSON、启动租约、出口策略对象、代理专用探测通道（后续批次已补齐前两项与探测口径）

## 1. 为什么现在做

当前 `checkdetail` 输出的是：

```text
代理内核=ok:Clash Verge 运行中
TUN网卡=ok
出口IP=ok:203.0.113.10/US
...
```

这套文本协议有三个结构性问题：

1. **没有版本号。** App、Windows、Linux、自动化脚本都在解析同一份文本，但没有任何字段能说明“这是哪一版协议”。
2. **没有稳定 ID。** 协议 key 是中文显示名，改一个文案就可能让界面丢行；新增检查项也无法区分“未知项”和“缺失项”。
3. **没有报告身份。** `last-check.txt` 可以被任意次读取，无法回答“这份结论是什么时候、基于哪份环境配置产生的”。

Claude-Cage 的 `SafetyReport` 给出了正确方向：检查项有稳定 ID、关键性、证据、时间；报告有版本、配置指纹、过期时间。我们不引入它的 VM/网关，只引入这份契约。

## 2. 本阶段目标

新增 `claude-switcher-report/2`，并保持旧接口完全兼容：

- `checkdetail`：仍然逐行输出，仍然写 `last-check.txt`。
- `checkdetail --json`：执行同一轮检查，额外写 `last-report.json`，stdout 只输出一个 JSON 对象。
- `report [报告]`：离线把一份文本报告转成 JSON，不重新探测。
- `verdict` / `evidence`：行为不变，避免破坏现有 App、脚本和测试。

### 非目标

- 不把 `checkdetail` 的 16 个分支重写成插件系统。
- 不让 JSON 报告自动授权启动 Claude；授权租约是下一阶段。
- 不改变检查项判定口径，不把 `warn` / `skip` 提升成通过。
- 不修改真实 `$HOME` 下的配置；测试全部使用临时 HOME。

## 3. 报告 schema

```json
{
  "schema": "claude-switcher-report/2",
  "protocol": 2,
  "report_id": "…",
  "run_id": "…",
  "created_at": "2026-11-11T12:00:00+08:00",
  "expires_at": "2026-11-11T12:30:00+08:00",
  "config_fingerprint": "…",
  "core_sha256": "…",
  "core_version": "1.8.12-dev",
  "host": "…",
  "platform": "Darwin",
  "verdict": "established",
  "environment": {
    "proxy_mode": "clash-verge",
    "proxy_group": "…",
    "country": "US",
    "timezone": "America/New_York",
    "locale": "en_US"
  },
  "checks": [
    {
      "id": "proxy_core",
      "name": "代理内核",
      "critical": true,
      "state": "ok",
      "evidence": "Clash Verge 运行中",
      "remedy": "",
      "detail": "Clash Verge 运行中",
      "checked_at": "2026-11-11T12:00:00+08:00",
      "known": true
    }
  ],
  "summary": {
    "expected": 16,
    "total": 16,
    "passed": 14,
    "warning": 1,
    "failed": 0,
    "config": 0,
    "skipped": 1,
    "blockers": [],
    "critical_blockers": [],
    "advisories": [],
    "skipped_names": ["更优节点"],
    "missing": [],
    "missing_critical": [],
    "evidence_missing": [],
    "duplicates": [],
    "unknown": []
  }
}
```

### 状态值

沿用现有五种，避免 UI 与脚本同时改口径：

| 状态 | 含义 | 是否拦启动 |
|---|---|---|
| `ok` | 已验证通过 | 否 |
| `warn` | 非关键项不达标 | 否 |
| `skip` | 用户显式关闭或本轮未比较 | 否，但不算通过 |
| `config` | 环境层未就绪，系统无从判定 | 是 |
| `fail` | 已配置但实测不达标 | 是 |

`verdict` 规则与现有 `verdict` 命令一致，并新增一条“缺失关键项”规则：

- 任一 `fail` / `config` → `violated`
- 没有 `ok` / `warn` → `incomplete`
- 任一关键检查项缺失 → `incomplete`
- 否则 `established`

### 稳定 ID

| ID | 显示名 | 关键 |
|---|---|---|
| `proxy_core` | 代理内核 | 是 |
| `tun` | TUN网卡 | 是 |
| `egress_ip` | 出口IP | 是 |
| `ip_stability` | IP一致 | 否 |
| `timezone` | 时区 | 是 |
| `locale` | 地区 | 是 |
| `ipv6` | IPv6 | 是 |
| `dns` | DNS | 否 |
| `webrtc` | WebRTC | 否 |
| `bodyguard` | 保镖 | 是 |
| `rules` | 规则置顶 | 是 |
| `client_language` | 客户端语言 | 否 |
| `asn` | ASN属性 | 否 |
| `ip_purity` | IP纯净度 | 否 |
| `ecosystem` | 生态可达性 | 否 |
| `better_node` | 更优节点 | 否 |

未知检查项不丢弃：保留原始显示名，生成 `unknown-<sha256 前 12 位>` 的 ID，`known=false`、`critical=false`，并列入 `summary.unknown`。旧 App 可以继续只看文本；新 App 可以安全忽略未知项。

## 4. 配置指纹

`config_fingerprint` 由以下内容规范化后计算 SHA-256：

```text
env.json 白名单值 + checks.json 的 disabled/allowOptionalFailures + 核心脚本 SHA-256
```

它不包含时间、主机名、账号内容或 IP，只回答“这份报告是否基于当前环境配置与当前核心”。

用途：

- 报告落盘后，环境层被改过 → 指纹不同，旧报告不能代表现在。
- 核心脚本被升级 → 指纹不同，旧报告不能代表新判据。
- 下一阶段的启动租约会直接复用它。

## 5. 时效

- `created_at`：报告生成时间。
- `expires_at`：默认 30 分钟后。
- 报告是“检查快照”，不是永久授权；30 分钟只是本阶段的报告时效，不是启动许可租约。

## 6. 实施步骤

### 第一批（本次）

1. 在 `_support` 中定义 `CHECK_SPECS`、`REPORT_SCHEMA`、报告构建函数。
2. 增加 `_support report [报告] [核心脚本]`。
3. `checkdetail --json` 复用同一轮文本输出，写 `last-report.json`，stdout 输出 JSON。
4. 文本 `checkdetail`、`verdict`、`evidence` 不变。
5. 增加 `tests/test_check_report.py`：
   - schema / protocol / 稳定 ID 顺序
   - 关键项缺失 → `incomplete`
   - `config`、`fail` → `violated`
   - 全 `skip` → `incomplete`
   - 环境变化 → 指纹变化
   - 未知检查项保留
   - `checkdetail --json` 产出可解析 JSON，并写 `last-report.json`
6. 更新 `help`、README、AGENTS。
7. 更新 `SHA256SUMS`，跑针对性测试与全量测试。

### 第二批（已完成）

- ✅ App 优先读 JSON，文本解析保留为回退；旧核心拒绝参数时补跑文本。
- ✅ 启动租约：`lease` + `lease-check`，绑定 `report_id` / `config_fingerprint` / TTL。
- ✅ `switch` 在 `open -a Claude` 前校验租约，拉起后撤销；App 通过 JSON 检查后签发租约。
- ✅ 开关、节点、代理客户端、槽位与账号变化时撤销租约。
- 关键项 `evidence` 缺失已在报告的 `summary.evidence_missing` 中保留；App 暂不额外弹告警，避免每次检查都出现橙色横幅。

### 第三批（已完成）

- ✅ 代理专用探测通道：报告新增可选 `probes.proxy`（`status` / `http_code` / `latency_ms`）与 `probes.direct`。直连在 TUN 开启时无法有效测量，固定为 `unknown` + `reason=not_measured_while_tun_up`，不伪造 0。
- ✅ `drill` 输出并写 `drill-counters.json`：TCP/DNS/WebRTC 各有 `status` / `success` / `failure` / `elapsed_ms`；命令或探针不可用时整项 `unknown`，三个数值为 `null`。
- ✅ Linux 原生 `report` / `checkdetail --json`：14 项检查映射到同一套稳定 ID，缺少的 IP纯净度 / 更优节点 留在 `summary.missing`。
- ✅ Windows 原生 `report` / `checkdetail --json`：同一契约，指纹包含 checks.json 与核心脚本哈希；缺失项不伪造。
- ✅ Windows 真实 PowerShell 集成测试：`tests/windows-report-integration.ps1` 用临时 HOME 跑真实 `report` 命令，覆盖 14/16 缺失项、指纹稳定/变化、重复项、全 skip、缺关键项与未知项；已接入 Windows CI 的 PS 5.1 与 pwsh 7。
- 本地已用 pwsh 7.7 跑通该集成脚本（41 项断言）；PS 5.1 的实机执行仍由 Windows CI 覆盖。
- ✅ Linux/Windows 发布产物门禁：`scripts/release-check-platforms.sh` 校验 zip/tar 顶层结构、必需文件、包内脚本与仓库逐字节一致，以及 `report` / `checkdetail --json` 入口；已接入 release workflow 的打包后、生成校验和之前。

## 7. 验收标准

- `bash -n core/claude-switch.sh` 通过。
- `python3 -m unittest tests.test_check_report -v` 通过。
- 现有 `tests.test_check_semantics`、`tests.test_egress_probe`、`tests.test_help` 通过。
- `checkdetail --json` 输出单行合法 JSON，且 `last-check.txt` / `last-report.json` 都写入。
- 全 `skip` 报告是 `incomplete`，不是 `established`。
- 缺少关键项的报告是 `incomplete`，不是 `established`。
- 旧 `verdict` / `evidence` 测试保持通过。

## 8. 风险与回滚

| 风险 | 处理 |
|---|---|
| 中文显示名被误当成稳定 ID | JSON 只把 `name` 当展示字段，判定与映射只认 `id` |
| 旧 App 只认文本 | `checkdetail` 默认路径完全不变 |
| `checkdetail --json` 吃掉流式输出 | JSON 模式本来就是请求机器可读结果；逐行模式仍保留 |
| 配置指纹把无关字段算进去 | 只列白名单，不含 logging / 时间 / 主机 |
| 报告看起来“通过”但证据为空 | `summary.evidence_missing` 明示；下一阶段再决定是否升级为告警 |
| 旧核心不认 `report` | 新 App 先探测命令；未知命令安全回退到文本 |

回滚只需要移除 JSON 分支与 `report` 命令；文本协议没有被替换，旧客户端不受影响。

## 9. 验证记录

- `bash -n core/claude-switch.sh`：通过
- `python3 -m unittest tests.test_probes -v`：6 项通过（代理 probe / sidecar 绑定 / drill 计数器 / 旧报告无 probes）
- `python3 -m unittest tests.test_probes tests.test_check_report tests.test_lease -v`：21 项通过（含 checkdetail --json 的 proxy/direct 字段）
- `python3 -m unittest tests.test_linux_report -v`：6 项通过（Linux 原生 report / checkdetail --json / 缺失项显式）
- `python3 -m unittest tests.test_windows_report_static -v`：6 项通过（Windows report 接线 / 16 ID / 静态契约 / CI 接线）
- `python3 -m unittest tests.test_release_platforms -v`：6 项通过（跨平台门禁成功/篡改/缺文件/入口不可执行/版本错误/发布接线）
- 按 release workflow 用真实 `ditto` / `tar` 生成 Windows/Linux 包并跑跨平台门禁：通过
- `tests/windows-report-integration.ps1`（pwsh 7.7，临时 HOME）：41 项断言通过
- Windows 静态套件（report/update/switch/rules/region/snapshot）：59 项通过
- `python3 -m unittest tests.test_menu_bar_model -v`：59 项通过（含 JSON 优先 / 旧核心回退 / 全 skip 拦截 / 租约签发）
- `python3 -m unittest discover -s tests -v`：562 项通过（270.714s）
- `shasum -a 256 -c SHA256SUMS`：通过
- `python3 scripts/sync-rules.py --check`：通过
- `git diff --check`：通过

## 10. 第三批状态

报告 v2 的探测口径、跨平台入口与发布产物验证都已完成：`probes.proxy` / `probes.direct`、`drill` 的 TCP/DNS/WebRTC 计数器，Linux/Windows 原生 `report` / `checkdetail --json`，以及发布 zip/tar 的脚本哈希、报告入口与 Linux 入口可执行位门禁均已落地。`probes` 不参与 `config_fingerprint`，旧报告没有该字段时仍按原语义解析、校验和签发租约；跨平台报告同样保留 16 个稳定 ID，缺少的 IP纯净度 / 更优节点 明确写进 `summary.missing`。Windows 报告已不再只有静态断言：真实集成脚本在 pwsh 7.7 本地跑通，并接入 Windows CI 的 PS 5.1 / pwsh 7；期间修复了 PowerShell 7.7 对 `[pscustomobject]` 内 `@($List[object])` 抛 `Argument types do not match` 的真实崩溃。最终验证为 562 项全量通过（270.714s），`bash -n`、`shasum -c`、`sync-rules --check`、`git diff --check` 均通过。PS 5.1 的实机结果以 Windows CI 为准。
