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

启动 Claude 之前跑完 **16 项环境审计**，硬性项不过就不拉起应用；放行之后由运行期看门狗守着出口，一变就停 Claude。账号切换用整目录快照（A–D 四个独立档案），而不是反复登录登出。

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
| 04 | IP 一致性 | 出口 IP 漂移（按出口类型分级 + 48h 历史） |
| 05 | 时区 | 系统时区与 IP 归属地冲突、看门狗守着旧目标 |
| 06 | 地区 Locale | 系统区域设置不符 |
| 07 | IPv6 | 双栈旁路直连 |
| 08 | DNS 隧道 | Fake-IP 校验 + 上游解析器地域 |
| 09 | WebRTC | 纯标准库 STUN 多节点交叉探测 |
| 10 | 保镖守护进程 | Kill-Switch 是否在线 |
| 11 | 置顶路由规则 | Claude 生态域名是否被强制走代理 |
| 12 | 客户端语言 | 语言与目标地区不符 |
| 13 | ASN 属性 | 网络类型不符（ISP 分类不等于住宅认证） |
| 14 | IP 纯净度 | 四源交叉 + PTR 的可解释 0–100 评分 |
| 15 | 生态可达性 | claude.ai / api.anthropic.com 连通性 |
| 16 | 更优节点 | 本地候选节点里是否存在更干净的出口 |

结论只有五种：`ok` 通过 / `fail` 实测不达标 / `config` 环境层没配好无从判定 / `warn` 提示 / `skip` 用户主动关闭。**`fail` 与 `config` 都拦启动，`skip` 永远不算通过**。

界面上这是一份清单、不分组，默认全部拦启动。设置页「降级防护（不推荐）」里可关闭 8 项（04/08/09/12/13/14/15/16），另外 8 项不可关闭；关掉后主界面常驻橙色「防护已降级」，`check` 输出也带 `|防护降级:…`。

> Kill-Switch 是**进程级急停**而非防火墙级 fail-closed，隧道断开到进程被杀存在已知时间窗口。完整安全边界见 [SECURITY.md](SECURITY.md)。

## 重点能力

- **四维加权评分**：身份 / 隔离 / 一致 / 守护四个维度，颜色只按分数分档，能否启动由徽章单独表达。
- **IP 纯净度**：四源交叉（ipquery / ip-api / ipinfo / stopforumspam）+ 本地 PTR，类型基线减分；机房只给警告，代理特征与 Tor 才拦启动。
- **节点扫描与应用**：只读扫描当前控路 Selector 的候选节点并排名；「应用最优节点」只在门禁允许时出现，按下时实时复核门禁、切后复查出口国家，任一步不达标自动回滚。细节见 [AGENTS.md](AGENTS.md)。
- **运行期守护**：放行后每 10s 比对出口、每 60s 跑整轮审计；异常连续两次才停 Claude，拦截写 `incidents.log` 并走窗口横幅 / 菜单栏 / 系统通知三条提醒。
- **菜单栏常驻**：关窗口只隐藏、Dock 不显示图标；菜单显示当前槽位与最近检查结果。
- **检查设置与脱敏诊断**：`checks.json` 控制 8 项非关键检查；客户端日志只记命令元数据，诊断包不含 IP、凭据、账号内容。
- **自动更新**：用户态 LaunchAgent 每 12 小时检查，逐项校验 `SHA256SUMS`，自检失败自动回滚。

## 安装

**系统要求**：macOS 13+ · Clash Verge / FlClash / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）· Claude 桌面版 · python3 · 出口国家不能是 CN。

```bash
git clone https://github.com/huanfine/claude-switcher.git
cd claude-switcher
# 双击 installer/安装.command，自动识别代理客户端、代理组名与地区目标
```

安装器在本机编译界面 App、装入核心脚本与保镖 / 时区看门狗。产物为 ad-hoc 签名、未公证，首次被 Gatekeeper 拦截时右键打开，或到「系统设置 → 隐私与安全性」放行；手动打包见 `scripts/package-macos.sh`。

Windows / Linux Beta 见 [windows/README.md](windows/README.md) · [linux/README.md](linux/README.md)。浏览器侧检测页在 `docs/`，线上地址 [huanfine.github.io/claude-switcher](https://huanfine.github.io/claude-switcher/)（需在仓库 Settings → Pages 选 `main` / `/docs` 启用），本地预览见 [docs/WEB-README.md](docs/WEB-README.md)。

## 日常使用

1. 双击桌面应用图标 → 等 16 项检查；硬性项全绿再选账号启动，红项用「一键修复」。
2. B/C/D 首次各登录一次，之后 A–D 随切随用、互不干扰。
3. 换国家节点后跑 `~/.local/bin/claude-switch.sh set-region` 重新锁定国家 / 时区 / 地区格式。
4. 换代理客户端在界面下拉框切换，或 `set-client <mode>`；切换后自动重审。

## 命令速查

下表路径前缀均为 `~/.local/bin/claude-switch.sh`；完整参数与结论含义运行 `help`（按「日常 / 出问题时 / 区域与客户端 / 维护」分组）。

| 场景 | 命令 |
|---|---|
| 逐项检查 / 静默总检 | `checkdetail` / `check` |
| 一键修复 | `fix` |
| 切账号 / 状态 | `switch A\|B\|C\|D` / `status` |
| 运行期看门狗 | `watch [间隔] [整轮周期]` |
| 节点扫描 / 应用 | `node-scan` / `node-apply` |
| 重锁地区 / 换客户端 | `set-region` / `set-client <mode>` / `get-client` |
| 故障演练 / 离线复核 | `drill [--auto\|--manual]` / `verdict [报告]` / `evidence <file>` |
| 只读体检 | `fingerprint` / `cli-info` / `diagnose-proxy --proxy URL` / `open-safe <url>` |
| 检查开关 | `get-check-config` / `set-check-config <json>` |
| 快照 / 诊断 / 更新 | `snapshot-export` · `snapshot-import` / `export-diagnostics <file>` / `update [--check\|--auto]` |

排障手册、架构纪律与验收标准见 [AGENTS.md](AGENTS.md)。

## 来源与许可

本项目基于 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher)（MIT License）二次开发，原项目的版权与许可声明保留在 [LICENSE](LICENSE)。本仓库自 2026-11 起的界面重做、检查项扩展、节点扫描及文档维护由 huanfine 维护。

MIT © Claude Switcher Contributors

---

[AGENTS.md](AGENTS.md) · [SECURITY.md](SECURITY.md) · [windows/](windows/) · [linux/](linux/) · [Web 检测页](docs/WEB-README.md)
