<div align="center">

# Claude 环境检查器

**Fail-Closed 账号环境管理器 —— 把真实 IP 泄漏拦截在启动之前**

[English](README.en.md) · [GitHub](https://github.com/huanfine/claude-switcher)

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-blue.svg)]()
[![Windows](https://img.shields.io/badge/Windows-Beta-lightgrey.svg)](windows/)
[![Linux](https://img.shields.io/badge/Linux-Beta-lightgrey.svg)](linux/)
[![UI](https://img.shields.io/badge/UI-SwiftUI-orange.svg)]()

<img src="assets/icon-256.png" width="128" alt="Claude 环境检查器">

</div>

---

## 这是什么

启动 Claude 之前跑完 **16 项环境审计**，硬性项不过就不拉起应用；放行之后由运行期巡检守着出口，一变就停 Claude。账号切换用整目录快照（A–H 八个独立档案），而不是反复登录登出。

桌面窗口标题为「Claude 环境检查器」，命令行入口 `~/.local/bin/claude-switch.sh`。界面是单文件 SwiftUI，无 Xcode 工程、无第三方依赖；图标由 `assets/icon-gen.swift` 生成。

## 用途声明

本项目用于在合规地区管理多个 Claude 账号的本地环境与登录态，面向因出差、旅居等原因身处支持地区的用户。请遵守 Anthropic 服务条款；禁止用于账号转售、共享、代注册或规避地区限制。本地环境检查只影响本机配置，不改变服务端记录，也不构成账号不被限制的保证。

## 界面

![Screenshot](docs/screenshot.png)

浅色 / 深色两态另见 [docs/images/](docs/images/)。

## 16 项检查

| # | 检查项 | 防什么 |
|---|---|---|
| 01 | 代理内核 | 代理没在跑就启动 |
| 02 | TUN 网卡 | 系统代理开着但流量没被接管 |
| 03 | 出口 IP | 出口国家 / 地区异常 |
| 04 | IP 一致性 | 出口 IP 漂移（对固定基线比对 + 按出口类型分级，同一实例一周内不应换出口） |
| 05 | 时区 | 系统时区与 IP 归属地冲突、巡检守着旧目标 |
| 06 | 地区 Locale | 系统区域设置不符 |
| 07 | IPv6 | 双栈旁路直连 |
| 08 | DNS 隧道 | Fake-IP 校验 + 上游解析器地域 |
| 09 | WebRTC | 纯标准库 STUN 多节点交叉探测 |
| 10 | 保镖守护进程 | Kill-Switch 是否在线 |
| 11 | 置顶路由规则 | Claude 生态域名是否被强制走代理 |
| 12 | 客户端语言 | 语言与目标地区不符 |
| 13 | ASN 属性 | 网络类型不符（ISP 分类不等于住宅认证） |
| 14 | IP 纯净度 | 六源交叉 + PTR 的可解释 0–100 评分 |
| 15 | 生态可达性 | claude.ai / api.anthropic.com 连通性 |
| 16 | 更优节点 | 本地候选节点里是否存在更干净的出口 |

结论只有五种：`ok` 通过 / `fail` 实测不达标 / `config` 环境层没配好无从判定 / `warn` 提示 / `skip` 用户主动关闭。**`fail` 与 `config` 都拦启动，`skip` 永远不算通过**。

界面上这是一份清单、不分组，默认全部拦启动。设置页「降级防护（不推荐）」里可关闭 8 项（04/08/09/12/13/14/15/16），另外 8 项不可关闭；关掉后主界面常驻橙色「防护已降级」，`check` 输出也带 `|防护降级:…`。

**IP 一致性的判据是「现在用的出口是否等于这条实例的固定出口」**，不是「窗口里出现过几个出口」。所以跳到别处被熔断、之后又切回原来那条固定 IP，是正常使用，不会留下任何告警。第一次运行会把当前出口记为基线；确属永久更换出口时运行 `claude-switch.sh ip-baseline accept` 改基线（`ip-baseline show` 看当前基线与已固定天数）。

设置页「安全基线（更严格）」可以把「生态可达性」升成硬门槛：打开后 claude.ai / api.anthropic.com 连不上就拦启动，即使同时勾了「失败降为警告」。默认关闭。

> Kill-Switch 是**进程级急停**而非防火墙级 fail-closed，隧道断开到进程被杀存在已知时间窗口。完整安全边界见 [SECURITY.md](SECURITY.md)。

## 重点能力

- **四维加权评分**：身份 / 隔离 / 一致 / 守护四个维度，用来诊断和排序。首页**不显示这个分**——圆环里是「16/16」这样一个读数（通过项数 / 总项数），环的粗细只做边框、颜色只回答「能不能启动」。分数低不等于起不来：IP 纯净度偏低会让分掉下来，但它只是软信号，照样能启动。
- **IP 纯净度**：六源并行（ipquery / ip-api / ipinfo / stopforumspam / ipinfo widget demo / scamalytics 免费页）+ 本地 PTR，类型基线减分。widget 的 `asn.type=isp` 是**正面住宅证据**的主要来源，scamalytics 的欺诈分只做展示口径（可和业界工具直接对照），不参与扣分。代理特征要**两家以上**印证（或 ipquery / widget 自己报出来）才拦启动；只有 ip-api 单方面报、而其余源都说机房时，判机房并标「代理特征(单源)」，只提示不拦。分数是信誉分、判定是「能不能开」，文案里两者分开写（`判定:拦启动 / 判定:仅提示`）—— 同名同分不代表同一结论。
- **单一源被限流不会拖垮结论**：ipinfo 的 `/json` 与 `widget/demo` 共用同一份免注册额度，共享代理出口很容易把它打满（实测 `429 Rate limit hit`，而且限流按**调用方**算——同一条出口连查 `8.8.8.8`、`1.1.1.1` 也全 429）。运营商名依次问 ipinfo → ipquery → ip-api，`ip_org` 内部自己就走同一条链（不是只有上层才有兜底），缓存里过期的名字在三个源全挂时仍会用来兜底；`asn.type`/`company.type` 按 IP 存 24 小时，刚查到过的证据不会因为下一次没问到就作废。真的整条类型证据都取不到时，文案写「未评级(ipinfo 限流)」+ 标记「·类型源限流」，**不会**劝你换节点——那时我们手上没有任何证据说这个出口不好，劝换节点等于拿自己的取数失败指控你的线路。
- **扣分是连续的，封顶只在证据不足时用**：风险分每 5 分扣 1 分信誉（60 分以上封顶扣 12），滥用记录 1 次扣 5 分、45 次以上扣 14，没有「档口跳变」。类型只看结构证据（机房标志 / 代理特征 / Tor / PTR / 运营商名），**不受信誉分影响**——否则同一个出口 risk_score 差 1 分，类型标签、分数和动作建议会一起翻。**住宅要正面证据**（widget `asn.type=isp` / 白名单命中 / PTR 家宽特征）：有正面证据的干净出口就是 100；三者皆无报「类型不明」且**不给数字分数**（「未评级(类型证据缺失)」，放一个猜的分数不如不放），判定照常只提示不拦。风险维度没验成（缺 `risk_score`、只剩一家风险源、或整轮降级）封顶 **85** 且最多只给「仅提示」——「没查」不能冒充「查干净了」。这类结果的文案会明确标出来；它和完整结论一样缓存 24 小时，后台巡检不会为它重复问源——点「重新检查」会立刻重新拉取一次。
- **节点扫描与应用**：只读扫描当前控路 Selector 的候选节点并排名；「应用最优节点」只在门禁允许时出现，按下时实时复核门禁、切后复查出口国家，任一步不达标自动回滚。细节见 [AGENTS.md](AGENTS.md)。
- **一槽一套环境**：切 A–H 时连同 Claude Code 的 `~/.claude/` 与 `~/.claude.json` 一起换，桌面版和终端不再共用同一份登录态。槽位卡上的 `CLI` 角标表示这个槽位也存了终端状态。
- **槽位绑定出口**：可以给每个槽位声明「就走这条线」，切过去时先换线路再切账号；没绑定的槽位沿用「本次扫描最优节点」。绑定优先于本次扫描结果。
- **运行期守护**：放行后每 10s 比对出口、每 60s 跑整轮审计；异常连续两次才停 Claude，拦截写 `incidents.log` 并走窗口横幅 / 菜单栏 / 系统通知三条提醒。
- **菜单栏常驻**：关窗口只隐藏、Dock 不显示图标；菜单显示当前槽位与最近检查结果。
- **检查设置与脱敏诊断**：`checks.json` 控制 8 项非关键检查；客户端日志只记命令元数据，诊断包不含 IP、凭据、账号内容。
- **自动更新**：用户态 LaunchAgent 每 12 小时检查，逐项校验 `SHA256SUMS`，自检失败自动回滚。`touch ~/.claude-switcher/update-hold` 可让自动更新只报告不动手（手动 `update` 不受影响）。

## 安装

### 装到另一台机器：一个包搞定（推荐）

从 [最新版 Release](https://github.com/huanfine/claude-switcher/releases/latest) 下载 `*-macos-universal-full.zip`，解压后**双击 `INSTALL.command`**，按提示确认代理组 / 地区、输入一次开机密码，桌面就出现「Claude 环境检查器」。

这一个包里已经带上编译好的 App、核心脚本、守护进程与安装器：**不用装 Xcode、不用挑包、不用再跑升级命令**。目标机只需 macOS 13+ / Apple Silicon 或 Intel（通用二进制） / python3 / 一个正在运行的代理客户端 / Claude 桌面版。App 是 ad-hoc 签名、未公证，首次被系统拦下时右键点 `INSTALL.command` →「打开」即可（它会顺手清掉下载带来的隔离属性）。

> **只认 `INSTALL.command` 这一个入口。** 新版一体化包内所有文件名都是纯 ASCII，解压后根目录只有这一个 `.command`，不会出现乱码。macOS 自带的「归档实用工具」会把旧包里的中文名解成 `ä¸é®åè£.command` 之类，即使 zip 写了 UTF-8 标记也一样——那个文件点不开，也不是入口，**别双击、别在终端里粘贴它**。已经解压了带 `INSTALL.command` 的包无需重下，在该目录执行 `./INSTALL.command` 即可。详见包内 `README-INSTALL.txt`。

**不要从旧上游 `YOURSJEYO/claude-switcher` 的 Release 下载**：那里的核心脚本不认识 `node-scan` / `slot-node`，装完点节点扫描会报「脚本执行失败（退出码 2）」。

```bash
# 校验下载包
shasum -a 256 -c SHA256SUMS-release.txt

# 装完确认核心不是旧版
~/.local/bin/claude-switch.sh help | grep -E 'node-scan|slot-node'
```

只有特殊场景才需要其它包：

| 文件 | 什么时候用 |
| --- | --- |
| `*-installer-kit.zip` | 想从源码自己编译（需 Xcode 命令行工具） |
| `*-app-only.dmg` / `.zip` | 只想换界面，核心脚本已经是新版 |
| `scripts/upgrade-core.sh` | 旧机器只升级核心，不碰账号数据 |
| `*-windows.zip` / `*-linux.tar.gz` | Windows / Linux Beta |

> `*-installer-kit.zip` 里仍有 `installer/安装.command` 一类中文名文件，解压后可能显示成乱码；kit 同样**只认根目录的 `INSTALL.command`**，别去点 `installer/` 下的乱码文件。

### 已装过旧版：怎么升级

要看这一版改了哪一半。`1.8.7-dev` 修「点了一键修复却没修好」时，**同时改了菜单栏 App 的二进制和 `~/.local/bin/claude-switch.sh` 核心脚本**，那种情况下只跑 `scripts/upgrade-core.sh`、或只装 `*-app-only.*`，都只修到一半；而只改核心脚本的版本（如 `1.8.8-dev`）升核心即可。

不确定时一律重跑一体化包，最省事也最不容易漏：

1. 从 [最新版 Release](https://github.com/huanfine/claude-switcher/releases/latest) 下载 `*-macos-universal-full.zip`。
2. 解压后双击根目录的 `INSTALL.command`，按提示输入一次开机密码。安装器会覆盖桌面 App、核心脚本与守护进程，**不会删除账号槽位数据、快照或代理配置**。
3. 完全退出菜单栏的旧 App 再重新打开，确认两处版本：

```bash
plutil -extract CFBundleShortVersionString raw "$HOME/Desktop/Claude 环境检查器.app/Contents/Info.plist"
shasum -a 256 "$HOME/.local/bin/claude-switch.sh"
curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/SHA256SUMS | grep 'core/claude-switch.sh'
```

App 版本号应与 Release 页面一致，核心脚本哈希应与 `SHA256SUMS` 那一行一致。**别照抄文档里写死的哈希**——核心脚本每次修复都会变。

装好后再点一次「一键修复」。新界面会把「脚本压根没跑起来 / 修好了几项但收尾复测没过 / 这一项脚本本来就修不了」分开写清楚，不再一律显示「脚本执行失败」。若仍不行，在解压目录跑 `bash scripts/diagnose-fix.sh`，把桌面生成的 `claude-fix-diagnosis.txt` 发回来，里面有逐步 `FIX:` 输出和真实退出码。

### 从源码安装

**系统要求**：macOS 13+ · Clash Verge / FlClash / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）· Claude 桌面版 · python3 · 出口国家不能是 CN。

```bash
git clone https://github.com/huanfine/claude-switcher.git
cd claude-switcher
# 双击 installer/安装.command，自动识别代理客户端、代理组名与地区目标
```

安装器在本机编译界面 App、装入核心脚本与保镖 / 时区巡检。产物为 ad-hoc 签名、未公证，首次被 Gatekeeper 拦截时右键打开，或到「系统设置 → 隐私与安全性」放行；手动打包见 `scripts/package-macos.sh`。打 `v*` 标签推送即触发 `.github/workflows/release.yml` 自动构建并发布全平台安装包。

Windows / Linux Beta 见 [windows/README.md](windows/README.md) · [linux/README.md](linux/README.md)。浏览器侧检测页在 `docs/`，线上地址 [huanfine.github.io/claude-switcher](https://huanfine.github.io/claude-switcher/)（需在仓库 Settings → Pages 选 `main` / `/docs` 启用），本地预览见 [docs/WEB-README.md](docs/WEB-README.md)。

## 新界面 + 旧核心脚本（扫描报「退出码 2」）

`*-app-only.zip` / `*.dmg` 只替换界面，**不会**更新 `~/.local/bin/claude-switch.sh`。这时候点节点扫描会看到：

```
扫描失败：脚本执行失败（退出码 2）
用法: claude-switch.sh check|checkdetail|fix|status|switch A|B|C|D|set-region|...
```

`用法` 那行里没有 `node-scan` / `slot-node`，就说明核心脚本还是旧版。**旧版（v1.7.1 一带）的 `update` 指向原上游仓库，直接跑 `update` 拉不到本仓库的新核心**，所以界面会给一条专用升级命令，在终端执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)
```

它从 `main` 下载核心脚本与 `SHA256SUMS`，逐项校验哈希、备份旧脚本、迁移 `env.json`、跑 `help` / `status` 自检；任一步失败自动回滚到升级前。也可以直接下载最新的 `*-installer-kit.zip` 重装（kit 里附带了同一份脚本）。升级完成后 `update` 就恢复指向本仓库。

> 账号切换在旧核心下仍可正常使用，只是节点扫描会跳过——不会因此把人卡在旧账号上。

### 升级核心后必须再跑一次 `fix`

`upgrade-core.sh` 只替换脚本，**不碰** Clash Verge 的全局脚本，也不重启客户端。置顶规则写在 `profiles/Script.js` 里，所以升级完要再跑一次：

```bash
~/.local/bin/claude-switch.sh fix
```

只升级不跑 `fix`，「规则置顶」会一直红，看起来像「升级完全没用」。若 `fix` 报「无变化」但内核首条仍不是 UDP 规则，说明 Script.js 里还有一段在你管理块之后定义的 `main`，把我们的注入覆盖了——1.8.9 起管理块固定追加到文件末尾，重跑 `fix` 即可修正。判断依据看自检输出的 `script_structure` 段：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/diagnose-install.sh)
```

自检里的 `expect_sha256` 从发布清单实时取，取不到会写 `unknown` —— 它不再写死某个哈希值，所以「版本不符」这句话本身是可信的。

### 菜单栏看不到图标 / 桌面 App 没有图标

App 是 `LSUIElement`，**设计上就不常驻程序坞**，唯一常驻入口是菜单栏那一项。菜单栏塞满时 macOS 会静默折叠多余的项，于是看起来像「双击了但什么都没发生」。两条退路：

- **双击桌面上的「Claude 环境检查器」** → 直接打开主窗口（不会另起一个进程）。
- 想在程序坞也留一个入口：菜单里勾「在程序坞显示图标」，或执行

```bash
defaults write local.claude-switcher showInDock -bool true
```

桌面上的 App 图标显示成空白，通常是 Finder 图标缓存没跟上（安装器会 `rm -rf` 再同名重建）。1.8.9 起安装器会 `touch` 并重新向 LaunchServices 登记；更早的版本可以手动 `killall Finder`。图标文件本身没坏：`AppIcon.icns` 有 10 个尺寸、约 677 KB，自检的 `icns_bytes` 会打出来。

## 当前节点不支持 UDP（WebRTC 与「规则置顶」一起红）

HTTP / 部分不支持 UDP 的节点在运行时内核里是 `udp:false`。`proxy` 策略要求节点能承载 UDP（否则 STUN 流量可能直连泄漏），所以 `WebRTC` 和「规则置顶」会一起判 fail，文案也一样——后者其实没在测规则，是被同一道前置校验连坐。

点**「一键修复」**即可：它会先把 WebRTC 策略落盘成 `reject`（UDP 流量直接拒绝，同样不泄漏），再按新策略写入并验证置顶规则，期间会重启一次代理客户端。也可以手动切：

```bash
~/.local/bin/claude-switch.sh set-webrtc-policy reject   # 或换回 proxy
```

想维持 `proxy` 策略，就在客户端里换一个支持 UDP 的节点。

> `IP纯净度` 显示「类型预估·未实测信誉」或「风险未验证·封顶」时，说明风险维度这次没验成——前者是风险源全都没答上来（widget 也计一个源），分数只是按运营商名推出的类型基线；后者是拿到了类型证据（至少一个源答了）但拿不到风险分，分数封顶 85、判定最多到「仅提示」。两种都不是实测信誉。后台巡检不会为它们重复问源，点「重新检查」会立刻重新拉取一次。

## 出口 IP 评分看起来不对

先看检查项里的文字，对号入座：

| 现象 | 原因 | 现状 |
|---|---|---|
| 分数后拼着 `;; connection timed out;` | 反向解析超时把 `dig` 的诊断行当成了 PTR，既冒充「这个 IP 存在」，又被当成运营商名 | 已修，诊断行一律丢弃 |
| 分数忽高忽低、时好时坏、偶尔挂「风险源不可达」 | `.purity-cache.lock` 残留（进程被 kill / 断电），此后所有评分都写不进缓存，每次检查重新打四个网络请求 | 已修，超过 60 秒的锁自动回收；抢不到锁也不丢本次结果 |
| 三家源都说不是机房、风险分为 0，却报「机房 · 建议换住宅 IP」 | 早期版本把「运营商名不在住宅白名单」直接当成机房，而白名单只覆盖 11 个国家几十家运营商 | 已修：改成证据驱动判型——只看机房标志 / 代理特征 / Tor / PTR / 运营商名，信誉分不再参与类型判定；三家源都说不是机房就判住宅，证据不足才退「类型不明」。ASN 属性也不再对未收录的运营商报机房 |
| 升级到新版后，界面里**还**是写「疑似机房 / 类型不明」 | 界面上的每条结论都来自 `~/.local/bin/claude-switch.sh`，App 自己不判型。只换 App（`*-app-only.*`）不会更新脚本 | 先核对：`shasum -a 256 ~/.local/bin/claude-switch.sh` 与仓库 `SHA256SUMS` 是否一致；不一致就跑 `bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)` |

同一台机器、同一个出口 `66.17.65.38`（AS3257 GTT）的实测对照，三个版本的演化正好说明口径为什么改成「正面证据」：更早的核心报「疑似机房 · 70/100 类型不明」（把「运营商名没收录」当成机房）；中间一版报「评分 70/100 · 住宅宽带 · 无正面住宅证据 · 判定:仅提示」（把「没查到异常」判成住宅，再因拿不到正面证据封顶 70 —— 同一个出口被一套猜测摆布两次）；当前核心报「评分 100/100 · 住宅宽带 · GTT Communications Inc. ·欺诈分0 · 判定:ok」—— ipinfo widget 的 ASN 分类库明确给 `asn.type=isp`（正面证据成立），Scamalytics 欺诈分 0，ip.net.coffee 给 98，数字终于和业界对得上。差别只在脚本版本，不在 App。

分数是 IP 信誉（宽口径），「能不能拿它开 Claude」由硬门槛单独决定，两者会背离：例如 65 分的代理/VPN 节点会被硬门槛排除，49 分的机房节点反而可用。`node-scan` 报告会逐条写出排除原因。

`reject` 策略下 UDP 已在规则层直接拒绝，节点支不支持 UDP 不再是硬门槛；此时扫描表不会再把正在用的 HTTP 节点标成「UDP 未标注 · 不可用」。

## 一键修复显示 ✗，但单独检查又是绿的

`fix` 写完扩展脚本后会重启一次代理客户端。早期版本在 TUN 设备刚起来、默认路由尚未收敛时就立刻探测出口，拿到空 `trace`，于是收尾报 `WebRTC ✗ 未获取有效的 IPv4 出口`、`出口IP ✗ (无/未知)` 并 `exit=1`；可规则其实已经写入并验证加载了。现在只有这条确实重启过的路径会先等出口回来再复测；规则无变化、没重启时一次请求都不多发。

## 点了「一键修复」却看着什么都没修

`1.8.7-dev` 起界面会把三种情况分开说清楚，不再一律打成「脚本执行失败」：

- **脚本压根没跑起来**（前置校验就退出，日志里 `duration_ms=0`）：界面显示原始错误和一句能照做的提示。最常见的原因是菜单栏 App 从 Finder 启动时继承的 PATH 极简、找不到 `python3`，而安装器是在终端里做的检查；核心脚本现在按绝对路径解析解释器，不再赌 PATH。真缺解释器时按提示跑 `xcode-select --install`。
- **流程跑完了、收尾复测判失败**：以前 `fix` 一返回非 0，界面就把所有 `FIX:` 回执清空，只留「脚本执行失败（退出码 1）」，看着像一项都没修。现在保留「N 项已修复」的回执，点名剩下需要手动处理的项，再重新检查一次。
- **本来就不是脚本能修的项**：出口 IP、ASN 属性、IP 纯净度、生态可达性、更优节点需要换线路或换节点，按钮不会让它们变绿。

排查时点界面「导出诊断日志」即可：`1.8.7-dev` 起压缩包里多一份 `last-fix.log`，是最近一次修复的逐步 `FIX:` 输出（IP、本机路径、凭据已脱敏）。想看更完整的逐步输出，在**出问题那台 Mac** 的终端里跑一行，把桌面生成的 `claude-fix-diagnosis.txt` 发回来：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/diagnose-fix.sh)
```

它会原样跑一次 `fix`（可能弹一次管理员密码框），记录每一步、退出码和复查结果。

## 「规则已是最新」和「UDP 3478 规则没置顶」同时出现

这是 `last-fix.log` 里最容易被忽略的一种自相矛盾：

```text
FIX:置顶规则 ✓ 规则已是最新,未重启客户端
FIX:WebRTC ✗ UDP 3478 规则没置顶 · 点「一键修复」
```

`write_merge_rules` 只比较磁盘上的 `Script.js` / `Merge.yaml`，内容没变就回报「无变化」；`clash_rules verify` 读的却是**运行中内核**的 `/rules`。客户端冷启动、TUN 重建、或全局扩展脚本被临时关掉时，文件是对的、内核里却没那条置顶规则。旧逻辑一见「无变化」就打勾跳过重启，收尾复测必然再次失败，还叫你「点「一键修复」」——点多少次都停在原地。

现在「无变化」分支会先问一次内核：两边都认了才省下重启；只有「运行规则未按策略置顶」这类**重启真能解决**的失败才重启客户端并等 `verify` 通过；节点不支持 UDP、不在规则模式、代理组不对等重启也没用的原因会直接说明，不白等一次 TUN 重建。收尾也不再叫你点同一个按钮。

> 这一版（`1.8.8-dev`）只在核心脚本里改，界面 App 没有改动。**仅限已经装了 1.8.7-dev 的机器**不必重下整包，跑一次核心升级即可；界面版本落后更多时仍按上一节重跑 full 包：
>
> ```bash
> bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)
> ```
>
> 升级后用 `shasum -a 256 ~/.local/bin/claude-switch.sh` 与仓库 `SHA256SUMS` 核对。

## 日常使用

1. 双击桌面应用图标 → 等 16 项检查；硬性项全绿再选账号启动，红项用「一键修复」。
2. B/C/D 首次各登录一次，之后 A–H 随切随用、互不干扰。桌面版和终端里的 `claude` 各算一套状态，切槽位时两份一起换；**终端里开着 `claude` 时不能切**，先退出再点。
3. 换国家节点后跑 `~/.local/bin/claude-switch.sh set-region` 重新锁定国家 / 时区 / 地区格式。
4. 换代理客户端在界面下拉框切换，或 `set-client <mode>`；切换后自动重审。
5. 要给某个槽位固定出口：先点清单里「更优节点」那一行扫描一次，再点槽位卡右上角的链接图标，从报告里的候选里选一条。想还原成「每次按扫描结果决定」，在同一个菜单里解除绑定即可。命令行等价写法见下表 `slot-node`。

## 命令速查

下表路径前缀均为 `~/.local/bin/claude-switch.sh`；完整参数与结论含义运行 `help`（按「日常 / 出问题时 / 区域与客户端 / 槽位与出口 / 维护」分组）。

| 场景 | 命令 |
|---|---|
| 逐项检查 / 静默总检 | `checkdetail` / `check` / `checkdetail --json` |
| 报告契约 | `report [报告]`（稳定 ID / 证据 / 配置指纹，不重新探测） |
| 启动租约 | `lease` / `lease-check`（120 秒；绑定报告、环境指纹与核心脚本） |
| 一键修复 | `fix` |
| 切账号 / 状态 | `switch A\|B\|C\|D` / `status` |
| 运行期巡检 | `watch [间隔] [整轮周期]` |
| 节点扫描 / 应用 | `node-scan` / `node-apply [节点名]` |
| 槽位绑定出口 | `slot-node list` / `slot-node get <A\|B\|C\|D>` / `slot-node set <A\|B\|C\|D> <节点名>` / `slot-node clear <A\|B\|C\|D>` |
| 重锁地区 / 换客户端 | `set-region` / `set-client <mode>` / `get-client` |
| WebRTC UDP 策略 | `set-webrtc-policy <proxy\|reject>`（节点不支持 UDP 时一键修复会自动切 `reject`） |
| 故障演练 / 离线复核 | `drill [--auto\|--manual]` / `verdict [报告]` / `evidence <file>` |
| 只读体检 | `fingerprint` / `cli-info` / `diagnose-proxy --proxy URL` / `open-safe <url>` |
| 检查开关 | `get-check-config` / `set-check-config <json>` |
| 快照 / 诊断 / 更新 | `snapshot-export` · `snapshot-import` / `export-diagnostics <file>` / `update [--check\|--auto]` |

快照导出优先使用加密 DMG；当系统磁盘映像服务不可用时，会自动改写为同样受密码保护的兼容归档，`snapshot-import` 两种格式都能识别。

### 版本化检查报告

`checkdetail --json` 在完成同一轮检查后输出 `claude-switcher-report/2`，并写 `~/.claude-switcher/last-report.json`；`report [报告]` 只把已有文本报告转成同一格式，不重新探测。报告包含 16 个稳定检查 ID、关键性、逐项证据/建议、配置指纹、核心脚本哈希和 30 分钟有效期。旧的文本 `checkdetail`、`verdict` 与 `evidence` 行为不变。App 已优先调用 `checkdetail --json`，按稳定 ID 填行；旧核心忽略参数时复用同一份文本输出，退出码 2 拒绝时才补跑一次文本命令。报告只是检查快照；启动授权走 `lease`，默认 120 秒，并绑定 `report_id` / 配置指纹 / 核心脚本。`switch` 在 `open -a Claude` 前校验租约，拉起后立即撤销；环境、检查开关、节点、槽位或账号变化也会撤销。

报告里的 `probes` 是可选扩展，不参与 `config_fingerprint`，旧报告没有该字段时仍按原语义解析和签发租约。`probes.proxy` 记录正常代理链路的连通性/延迟（`status` / `http_code` / `latency_ms`）；`probes.direct` 在 TUN 开启时固定为 `unknown`，`reason=not_measured_while_tun_up`，不把“没测”写成 0；`probes.drill` 记录最近一次演练的 `tcp` / `dns` / `webrtc` 计数，每项都有 `status`、`success`、`failure`、`elapsed_ms`，探针或命令不可用时这三个数值为 `null`。

报告里的 `fail_closed` 字段恒在，回答的是另一个问题：**「代理挂了会不会直连」这件事被证明过没有**。取值 `unverified`（没跑过演练）/ `violated`（演练证明会直连）/ `established`（演练通过且证据在 7 天内）/ `stale`（证据过期或时间读不出来）。它是软信号——不拦启动、不进 `blockers`、不参与 `config_fingerprint`，但会追加到 `check` 的 OK 行并常驻显示在主界面。**16 项全绿只证明流量此刻走了代理**，证明不了故障时不直连；后者只有 `drill` 能验。旧报告缺这个字段时按 `unverified` 处理，不当成通过。

排障手册、架构纪律与验收标准见 [AGENTS.md](AGENTS.md)；分层结构、契约演进与已知缺口见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 平台能力矩阵

三个平台共用同一套报告格式与检查 ID，但**防护深度不一样**。装之前先看清自己这个平台有什么：

| 能力 | macOS | Windows（Beta） | Linux（实验） |
|---|---|---|---|
| 逐项检查 | 16 项 | 14 项（缺 IP纯净度 / 更优节点） | 14 项（同左） |
| 报告 v2 / 离线转换 | ✓ | ✓ | ✓ |
| 一键修复 / A–H 切换 | ✓ | ✓ | ✓ |
| 保镖（代理进程没了就停 Claude） | ✓ root LaunchDaemon | ✓ 计划任务 | ✓ |
| 启动租约（120 秒一次性授权） | ✓ | ✗ | ✗ |
| 运行期出口巡检（出口漂移即停） | ✓ | ✗ | ✗ |
| 故障演练 `drill`（证明断开不直连） | ✓ | ✗ | ✗ |
| 离线复核 `verdict` / `evidence` | ✓ | ✗ | ✗ |
| 节点扫描 / 应用 / 槽位绑定 | ✓ | ✗ | ✗ |
| WebRTC 策略切换 | ✓ | ✗ | ✗ |
| 检查项开关（降级防护） | ✓ | ✓ | ✗ |
| 加密快照导出 / 导入 | ✓ | ✓（格式与 macOS 不互通） | ✗ |
| 自动更新（SHA256 校验） | ✓ | ✓ | ✗ |
| 图形界面 | SwiftUI 菜单栏 App | WPF | 终端菜单 |

缺的那几项不是「以后补」，是当前的真实边界：**没有 `drill` 就无从证明 fail-closed，没有 `watch` 就只覆盖「代理进程没了」，不覆盖「出口悄悄换了」**。Windows / Linux 上「检查全绿」的含义比 macOS 弱，别按同一套预期使用。

## 来源与许可

本项目基于 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher)（MIT License）二次开发，原项目的版权与许可声明保留在 [LICENSE](LICENSE)。本仓库自 2026-11 起的界面重做、检查项扩展、节点扫描及文档维护由 huanfine 维护。

MIT © Claude Switcher Contributors

---

[AGENTS.md](AGENTS.md) · [SECURITY.md](SECURITY.md) · [windows/](windows/) · [linux/](linux/) · [Web 检测页](docs/WEB-README.md)
