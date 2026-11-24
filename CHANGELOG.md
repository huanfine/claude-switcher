# 变更记录

本文件按时间倒序记录核心脚本（`core/claude-switch.sh`）与界面（`app/main.swift`）的行为变化。
每条都注明**触发条件 / 影响组件 / 根因**，方便日后判断「这条改动到底动了什么」。
更细的工程依据（代码位置、实测命令、负例对照）在 [AGENTS.md](AGENTS.md)。

## 未发布（自 v1.8.12-dev）

### 变更

- **第 16 项「更优节点」换成「DNS泄露」检测**
  触发条件：用户判定节点比较功能价值不足，而 DNS 上游泄露是真实威胁
  （2026-11-23 实测泄露而全项绿）。
  影响组件：`checkdetail` 第 16 项、`set-check-config` 白名单（`OPTIONAL`/
  `ALL_CHECKS`）、报告契约（`better_node` → `dns_leak`，旧 ID 未知项保留不丢）、
  App 检查行/设置开关/健康分身份维度（权重 4 不变）、`nodeBoundNames`（DNS
  泄露是配置层问题，不是换节点能解决的，移出该集合）。
  新检查项两层合一：(a) 上游架构审计（复用 `dns_audit`：fallback 并发 / 明文
  上游 / 无海外加密上游）；(b) 内核解析活性（`/dns/query` 必须真应答，证明海外
  加密 DoH 可达）。结论：ok「上游架构审计通过 · 内核加密解析可达」/ fail 带
  具体问题并指向一键修复 / warn「架构干净但解析未应答」/ 非 clash-verge skip。
  原 DNS 项回归纯「走隧道」检查，职责不再重叠。
  节点扫描子系统（`node-scan`/`node-apply` 命令、报告面板、换槽位静默链路）
  全部保留，只撤下检查行与行级点击入口；App `applyNodeScan` 无落行目标时
  安全空转。菜单栏测试夹具同步（ID 表、软硬项表、收据落行改面板承载）。
  提交：见 git log。

### 修复

- **DNS 上游体检：泄露架构不再「全绿放行」，一键修复直接治好**
  触发条件：订阅原生 DNS 架构（`nameserver` 为国内 DoH + `fallback` 并发查询，或
  含明文 UDP 上游）。2026-11-23 实测：海外域名的解析被并发送进国内递归，
  权威侧看到国内解析器（泄露测试页标红），而旧 DNS 项只验「走隧道」照样 ok。
  影响组件：`dns_audit`（新增）、`write_dns_merge`（新增）、检查器 DNS 项、`fix`。
  根因：fake-ip 走隧道检查只能证明查询被 TUN 劫持，证明不了上游解析器是谁 ——
  加密防嗅探不防「国内递归看到了查询」。审计三条硬规则（全部机械可判）：
  fallback 非空 → fail；nameserver 含明文 UDP → fail；nameserver 无海外加密
  上游 → fail。fix 命中后把托管修复块写进 Merge.yaml（全局 merge，订阅更新
  覆盖后仍生效；块外内容保留、块外顶层 `dns:` 键移除防重复键拒载、写前备份、
  幂等），随规则流程一并重启内核，重启后再审一次确认真正生效。
  回归护栏：`tests/test_dns_audit.py`（11 例：老架构双报 / 明文上游 / 修复架构
  通过 / 非 clash-verge 跳过 / 缺配置不编造 / Merge 块外科目保留与 dns 去重 /
  幂等 / 旧托管块替换 / check-fix 挂接 / 内联数组老架构点名 / 内联干净不误报）。
  交付后复审（六形态端到端 + 修复闭环，见
  `docs/superpowers/plans/2026-11-23-dns-leak-detection-audit.md`）发现内联
  数组写法（`fallback: [8.8.4.4]`）被误判「nameserver 为空」—— 不漏放行但
  原因错、干净内联配置误报；已修（`dns_list_entries` 块+内联通吃）。
  提交：见 git log。

- **代理组消失后「一键修复」不再死循环（组名自愈）**
  触发条件：订阅更新整份覆盖客户端配置，env.json 里记的老组名在内核里已不存在
  （实机案例：老订阅组 `🤖 OpenAi` 被上游改写，新配置只剩 `🧠 固定IP` 等组）。
  影响组件：`fix`（一键修复）、`rule_fix_hint`（检查项失败文案）、`ensure_proxy_group`（新增）。
  根因：规则脚本把置顶规则钉死在 env.json 的组名上，组不存在时内核拒绝加载整份规则，
  校验必失败；而 fix 重新生成规则用的还是 env.json 里的旧组名 —— 修完仍是坏状态，
  用户点多少次修复都停在原地。
  现在 fix 在写规则前先核对内核 `/proxies`：组名仍存在则无条件保留（订阅正常时不乱换）；
  组名消失则按「固定IP > AI/干净 > 稳定型组（select/fallback）」打分自动换到现存最优组
  并写回 env.json，用户无感恢复。组内全是 DIRECT/REJECT 的假组、内核接口不可用时
  不编造组名，照实报错。检查项失败文案同步改为「点『一键修复』会自动切换到可用组」。
  回归护栏：`tests/test_group_reselect.py`（7 例，含现组保留/固定IP优先/直连组排除/
  空响应不编造/fix 调用顺序/文案钉住）。
  提交：见 git log。

- **节点扫描在自动选路链上不再报失败**
  触发条件：控制链是 `Selector → Fallback`（或 `URLTest`），组内成员由内核自己挑。
  影响组件：`node-scan`、界面第 16 项「更优节点」。
  根因：这类结构没有「可手动选择的目标」，旧实现一律 `FAIL`，界面显示
  「扫描失败（退出码 1）」并催用户去点一个必然失败的按钮。
  现在 `node-scan` 输出结构型报告（`NOCHOICE=1`、组名、类型、成员、链路），退出码 0；
  第 16 项给 **ok**：「由内核自动选路，没有可手动比较的候选 · 保持现状」。
  超过 24 小时仍会提示复核（用户可能换了订阅）。组不存在、链路断在非自动组、
  `/proxies` 格式异常仍然 `FAIL`。
  提交：`4efc729`。

- **一次网络超时不再被写成「仅一家风险源可达」**
  触发条件：ip-api（明文 HTTP）经隧道偶发挂满 4 秒；ipinfo 两个端点在共享出口上长期 429。
  影响组件：IP 纯净度评分与文案。
  根因：`src_n`（能答话的风险源计数）的上限本来就是 2，一次超时直接掉到 1，
  触发封顶 85 分 + 「仅一家风险源可达」—— 把我们的取数抖动写成了对用户线路的怀疑。
  实测证据：插桩抓到 `curl: (28) Operation timed out after 4004 milliseconds`，
  同一时刻单发只要 0.12 秒。
  现在等待放宽到 6 秒，ipquery / ip-api 在并行批次结束后各重试一次（仅空响应触发）；
  仍然空才按单源处理。
  提交：`f3253c9`。

- **`type-cache` 里空字段读不回来**
  触发条件：ipinfo widget 只给了 `asn.type`、没有 `company.type`。
  影响组件：类型证据缓存（`~/.claude-switcher/type-cache`）。
  根因：空字段按 `ip<TAB>isp<TAB><TAB>ts` 落盘，tab 属于 IFS 空白，`read` 把连续空白
  当成一个分隔符 —— 读回来时间戳落进 company 位、`tts` 为空，整行按无效记录跳过。
  也就是说 `asn.type=isp` 这条最硬的正面证据**写了等于没写**，而它恰好是 ipinfo
  限流时唯一的兜底。
  现在空字段落成 `-`，读回时把 `-` 当空。
  提交：`f3253c9`。

- **单一源被限流不再拖垮整轮结论**
  触发条件：ipinfo `/json` 与 `widget/demo` 共用免注册额度，共享出口上常年限流（429）。
  影响组件：ASN 属性、IP 纯净度、整轮通过数（曾从 16 掉到 13）。
  根因：运营商名与类型证据原先只依赖 ipinfo 一家。现在运营商名依次问
  ipinfo → ipquery → ip-api（`ip_org` 内部自己走同一条链），三个源全挂时用过期缓存兜底；
  `asn.type` / `company.type` 按 IP 缓存 24 小时；被限流时文案写「未评级(ipinfo 限流)」
  并标「·类型源限流」，**不再**劝人换节点。
  提交：`271e95d`、`c2d17a7`。

### 新增

- **「住宅拨号线路」单独成一档**
  触发条件：类型库说 `asn.type=isp`，而 ipquery / ip-api 的机房布尔说机房。
  影响组件：类型判定、评分、动作建议。
  行为：判「住宅拨号线路」75 分、只提示不拦，并标「机房标志(与类型库冲突)」。
  反证仍然有效：PTR 自曝 `cloud/vps`、ipinfo 隐私库说 hosting、运营商名命中机房词 ——
  任一成立仍判机房（逐 IP 的实测比通用布尔硬）。
  提交：`1caba70`。

### 升级与核对

```bash
# 安装/升级核心（下载 → 校验 SHA256 → 备份 → 迁移 → 自检 → 失败回滚）
bash scripts/upgrade-core.sh

# 核对安装件与仓库是否一致（两行哈希应相同）
shasum -a 256 core/claude-switch.sh ~/.local/bin/claude-switch.sh

# 看当前结论
~/.local/bin/claude-switch.sh checkdetail
```

测试基线：`634` 项全绿
（`env -i HOME="$HOME" PATH=/usr/bin:/bin:/opt/homebrew/bin TMPDIR=/tmp PYTHONUTF8=1 /usr/bin/python3 -m unittest discover -s tests`）。
