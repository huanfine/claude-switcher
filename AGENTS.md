# AGENTS.md —— Agent 交接提示词

> 这份文件写给 AI Agent。用户把本项目交给你时，请按本文档执行安装与配置。
> 用户也可以直接把本文件内容粘贴给任意本地模型（Kimi Code / Cursor / Claude Code 等）作为指令。
> 本项目基于 [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher)（MIT）二次开发，本文件为当前仓库维护者续写的操作手册。

---

## 你的任务

帮助用户在 macOS 上安装并配置「Claude 环境检查器」：一个带环境安检的 Claude 账号启动/切换工具。目标状态是：**用户双击桌面图标，16 项检查均已完成，硬性安全项全部通过；仅用户显式配置的非关键项可显示跳过或警告，且可以正常启动 Claude**。

## 开始之前：必须先确认的前置条件

逐项检查，缺哪项就先补哪项：

1. **macOS**（Apple Silicon 或 Intel 均可）
2. **代理客户端**已安装且代理可用，支持 Clash Verge / FlClash / Shadowrocket / sing-box / ClashX / Surge 任一（TUN 可用）。Clash Verge 的配置目录应存在于 `~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/`；Shadowrocket 以 VPN 配置形式存在（`scutil --nc list` 可见）
3. **Claude 桌面版** 在 `/Applications/Claude.app`
4. **python3** 可用（`python3 --version` 能输出版本号；没有则引导用户运行 `xcode-select --install`）
5. **当前出口 IP 所在国家不能是 CN**——先跑 `curl -s https://www.cloudflare.com/cdn-cgi/trace | grep loc=`，返回的 `loc` 不是 `CN` 才能继续。是 CN 就停下，让用户先把代理调好（安装程序会按出口 IP 自动锁定地区目标：国家/时区/地区格式三件套，裸连时装机会把它们锁错）

## 架构:功能 / 数据 / 环境三层

改代码前先判断改动属于哪一层,**不要跨层写死**:

| 层 | 位置 | 规则 |
|---|---|---|
| 功能 | `core/claude-switch.sh`、`app/main.swift`、`daemons/` | 只放逻辑。**任何环境值都不得出现在这里**,所以发布产物 = 安装产物,`SHA256SUMS` 可以整份比对 |
| 数据 | `data/claude-rules.json` | 域名与 STUN 端口清单的唯一来源。各平台代码里的清单块由 `python3 scripts/sync-rules.py` 生成,块内禁止手改;`--check` 供测试与 CI 做漂移守卫(`tests/test_rules_sync.py`) |
| 环境 | `~/.claude-switcher/env.json` | 代理客户端 / 代理组名 / 国家 / 时区 / 地区 / Clash 配置目录 / fake-ip 网段。安装器用 `_support env-set` 写入,运行期 `load_env` 读取,用户可手改 |

三条纪律:

1. **加域名只改 `data/claude-rules.json`**,然后跑 `scripts/sync-rules.py`。改完不跑生成器,`tests/test_rules_sync.py` 会红。
2. **不要把环境值写进代码或安装器 sed**。历史上安装器、`set-client`、`set-region`、自动更新都在用 sed 回写脚本头部 5 个变量,导致安装产物 ≠ 发布产物、SHA256 校验要剔除 5 行、升级还要回注——这套已全部拆除,别再引入。
3. **探测不到就明确报错,不要静默用默认值**。`load_env` 遇到损坏的 env.json 会 fail,因为环境值错会直接把规则写进错误的代理组。

关于时区看门狗(踩过一次,代价是「修好了又坏了」):

- **看门狗的目标值只能来自 env.json**,脚本里那份 `TARGET=` 只是读不到 env.json 时的兜底。原来安装器把目标烧死进脚本,`set-region` / `fix` 只改 env.json 和系统时区,没人回来改这份副本——看门狗于是每小时把系统时区改回旧值,用户每次点「一键修复」都以为没生效。
- **改系统时区必须同时对齐看门狗**,两件事要落在同一次管理员授权里(`fix` 的 `adminCmds`),否则修完几分钟就被改回去。
- **`TARGET=` 有两种写法**:安装器写 `TARGET="x"`,同步时写 `TARGET=x`。读的一律剥引号,不要匹配引号。


关于置顶规则的几条硬约束(踩过就不要再踩):

- **规则顺序固定:端口 → 域名 → IP 兜底**。域名命中更快更精确,IP 只在域名没命中时兜。`expected_rules()` 按索引逐条比对内核 `/rules`,顺序错了会直接报「运行规则未按策略置顶」。
- **IP 兜底必须带 `no-resolve`**。不带的话每条规则都要先把域名反查成 IP 再匹配,首包明显变慢。
- **不要用 `GEOSITE` / `IP-ASN` 做兜底**。它们依赖客户端内置数据库,库里没有对应条目时 mihomo 会**拒绝加载整份配置**——为了兜底把用户代理搞挂,代价远大于收益。纯 CIDR 不需要任何数据库。
- **`ip_class()` 的 org 串要先归一(小写、去空格逗号)再匹配**。bash 的 `case` 模式是「词」,模式里的空格和 `&` 会终止词、直接语法错误;模式列表中间也不能夹注释(反斜杠续行会把注释并进同一条命令)。

## 安装步骤

首选引导用户运行安装器（双击 `installer/安装.command`，或终端执行它）。如果安装器环境受限，按下面的手动等效步骤执行：

1. 把 `core/claude-switch.sh` 复制为 `~/.local/bin/claude-switch.sh`（可执行），把 `core/stun-probe.py` 放到 `~/.claude-switcher/`。**核心脚本原样落地，不要再用 sed 改写它**——环境值走下一步的 `env.json`
2. 探测代理客户端，用 `claude-switch.sh _support env-set "proxy_mode=..."` 写进 `~/.claude-switcher/env.json`：存在 Clash Verge 配置目录 → `clash-verge`；否则 `scutil --nc list` 有 Shadowrocket VPN 配置 → `shadowrocket`；都没有则让用户在 clash-verge/flclash/shadowrocket/sing-box/clashx/surge/auto 中选择
3. Clash Verge 模式下，从 `clash-verge.yaml` 的 `proxy-groups:` 找第一个 `type: select` 的组名，同样用 `env-set "proxy_group=..."` 写入（其他客户端跳过）
4. 按出口 IP 自动锁定地区目标：多源依次尝试 ipinfo.io（country/timezone）→ ipapi.co（country_code/timezone）→ ifconfig.co（country_iso/timezone）→ Cloudflare trace（loc，时区用国家默认映射），全失败时让用户在 US/JP/TW/HK/SG/GB/DE/FR/KR/AU/CA 中手动选，`FORCE=1` 按 US + America/New_York；country 经映射表（US→en_US、JP→ja_JP、TW→zh_TW、HK→zh_HK、SG→en_SG、GB→en_GB、DE→de_DE、FR→fr_FR、KR→ko_KR、AU→en_AU、CA→en_CA，其余→en_US）→ locale，然后用 `env-set "country=..." "timezone=..." "locale=..."` 写入 env.json
5. 参照 `daemons/` 目录的模板，物化保镖与时区看门狗脚本（把 `__HOME__` / `__TZ_TARGET__` / `__PROXY_MODE__` 替换为实际值），用 sudo 装入 **root 所有的** `/Library/Application Support/claude-switcher/`（chown root:wheel、chmod 755，用户态不可写防提权）；`local.claude-bodyguard` / `local.tz-watchdog` 两个 LaunchDaemon 安装到 `/Library/LaunchDaemons/`（plist 的 ProgramArguments 已写死指向系统目录，直接 cp 即可）。自动更新 `local.claude-update` 是**用户态 LaunchAgent**：plist 放 `~/Library/LaunchAgents/`，用 `launchctl bootstrap gui/$(id -u)` 注册，不走 root（模板 `daemons/local.claude-update.plist`，每 12 小时跑一次 `update --auto`）
6. 现场编译界面 App（需要 Xcode 命令行工具，必须带 `-target` 否则新 SDK 产物在老系统拒启动）：
   ```bash
   swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" app/main.swift -o "Claude 环境检查器.app/Contents/MacOS/ClaudeSwitcher" -framework SwiftUI -framework AppKit
   ```
   图标用 `assets/icon-2048.png` 经 sips 生成 iconset 再 `iconutil -c icns` 打进 `Contents/Resources/AppIcon.icns`，`Info.plist` 声明 `CFBundleIconFile`，最后 `codesign --force --deep -s -`
7. Clash Verge 模式下通过核心脚本的 `write-merge-rules` 隐藏入口生成「全局扩展脚本」(profiles/Script.js)，直接前置 `config.rules`，保留已有 main，备份并迁移 Merge.yaml 中本项目旧标记块；重启 Clash Verge 后必须验证内核 `/rules`。其他客户端提示用户自行添加 DOMAIN-SUFFIX 置顶规则

   **重启必须真的重启**：改 Script.js 不会让运行中的内核换规则——Clash Verge 只在自身启动/应用配置时重新生成运行时配置，`clash-verge.yaml` 的时间戳会一直停在上次重启。而 `osascript -e 'tell application "Clash Verge" to quit'` 对这个 Tauri 应用**不生效**（实测 PID 不变），紧跟的 `open -a` 只是把窗口唤到前台，于是内核仍是旧规则、`verify` 失败、用户看到「置顶规则 ✗ 未验证内核加载」。`fix` 现在走 `quit_clash_verge`：先 AppleScript quit，等 8 秒没退就补 SIGTERM，确认进程消失后再 `open`，最后等 TUN 网卡出现。
8. 时区与 IPv6（已是目标值则跳过对应命令）：`systemsetup -settimezone <TZ_TARGET>`、`networksetup -setv6off Wi-Fi`（需管理员）
9. 收尾自检：运行 `~/.local/bin/claude-switch.sh checkdetail` 确认各项状态

日常维护命令：`help`（分组命令说明，含 ok/warn/config/fail/skip 五种结论的含义；未知命令直接指到这里）/ `check`（静默总检）/ `checkdetail`（16 项逐项）/ `node-scan`（只读扫描当前控路 Selector 的候选节点，按纯净度排名出报告；不切节点、不动守护、不写 iphistory）/ `node-apply`（仅门禁允许时把最优节点切上去并固定；切前实时复核门禁、切后复查出口国家，不达标自动回滚）/ `fix`（一键修复）/ `switch A|B|C|D`（切换账号）/ `set-region`（换国家节点后重锁地区目标）/ `set-client <mode>`（安装后更换代理客户端：clash-verge|flclash|shadowrocket|sing-box|clashx|surge|auto，写 env.json）/ `env-set <key=value>...`（写环境层，键限 proxy_mode|proxy_group|country|timezone|locale|clash_dir|fake_ip_range；损坏的 env.json 会让核心脚本直接 fail，需用它重建）/ `drill [--auto|--manual] [--yes]`（fail-closed 演练：平时检查只能证明「流量走了代理」，证明不了「代理挂了会不会直连」。默认 auto 通过内核接口关 TUN——效果等价于核死时路由被撤销，但能精确恢复、不需要 sudo；`--manual` 走手动停核。结论写 `~/.claude-switcher/drill.log`。2026-11-01 实测本机为 `violated`：关掉 TUN 后域名探测直接从中国移动出口出去）/ `verdict [报告]`（只读复核 `last-check.txt`，输出 established|violated|incomplete 与 blockers/advisories/skipped；warn 与 skip 既不算 pass 也不算 fail；`config` 与 `fail` 一样计入 blockers；一项都没真正验证过是 incomplete——「没有失败」不等于「验过了」）/ `evidence <file>`（检查结果落 JSON：时间/主机/环境/逐项/判定，0600，只新建不覆盖）/ `fingerprint`（设备指纹体检：字体地区特征/GPU/虚拟机；Canvas/WebGL 用 Web 检测页）/ `cli-info`（Claude Code CLI 只读体检：版本/安装方式/多份安装冲突，不执行卸载升级）/ `open-safe <url>`（一次性隔离浏览器打开 http/https 链接；代理未就绪会拒绝，窗口关闭后销毁临时 profile）/ `snapshot-export <A|B|C|D> <file>` / `snapshot-import <file> <A|B|C|D>`（macOS 加密快照导出/导入，AES-256 DMG，密码经 stdin，目标槽位非空会拒绝）/ `update [--check|--auto]` / `update-check`（自动更新：`update-check` 为只读检查入口，只下载并校验、比对配置行后报告是否为新版本，不备份不写入；旧版核心不识别该入口时会安全退出，不会误触发真实更新；`update --check` 在新版中等价；`--auto` 由用户态 LaunchAgent 每 12 小时调用、输出落 `~/.claude-switcher/update.log`；手动跑则直接打印。完整流程：拉取 main → 逐项 SHA256 校验工件（对照仓库 SHA256SUMS，不符即中止）→ 整份比对核心脚本去重 → 备份 .bak → 替换脚本并把老版本脚本头部里的环境值迁进 `env.json` → 守护脚本仅比对并提示 → 自检，含任何 `=fail` 自动回滚）

检查设置：`get-check-config` / `set-check-config <json>` 读写 `~/.claude-switcher/checks.json`，App 齿轮与菜单栏也提供设置入口。只允许关闭 `IP一致`、`DNS`、`WebRTC`、`客户端语言`、`ASN属性`、`IP纯净度`、`生态可达性`、`更优节点`；禁用项必须真正跳过探测并显示灰色 `skip`，不能当作通过。`allowOptionalFailures` 只把这 8 项的失败降为警告。出口国家一致性、代理/TUN、Kill-Switch、保镖、账号归档安全、root 权限边界与更新 SHA256 等硬性安全项不可关闭或降级。

关于 IP 纯净度（第 14 项，`ip_purity`）：口径是**类型基线 − 扣分**，基线取 ip.net.coffee 实测区间的中位（住宅 100 / 移动 85 / VPN 65 / 机房 55 / Tor 46 / 类型不明 70），判定阈值比分数严。六条不能改回去的口径：

1. **不要改回单源。** 四个源交叉：`api.ipquery.io`（风险标志+风险分）、`ip-api.com`（proxy/hosting/mobile+城市，免费档只支持 http）、`ipinfo.io`（ASN+城市，顺带省掉一次请求）、`api.stopforumspam.org`（滥用频次）。任一源报出 `is_proxy` / `is_vpn` / `is_tor` 即算命中——实测 Cloudflare WARP 只有 ip-api 报 `proxy:true`，ipquery 只报 `datacenter`，单源会把这类出口当普通机房放过，而它恰好是最该拦的一类。
2. **不要丢掉 `dig +short -x`。** PTR 是出口自己写下的身份（`tor-exit-read-me.dfri.se`、`…static.cloudzy.com`、`c-73-158-10-5.hsd1.ca.comcast.net`），比任何第三方评分都硬；实测 fake-ip 不劫持反向解析。但也**不要加 DNSBL**：fake-ip 劫持所有 A 查询统一回 `198.18.0.x`，黑名单结果全是假的。
3. **风险分与滥用记录取较大者，不许相加。** 两者都是历史信誉信号且高度相关（Tor 出口天然两项都高），相加等于同一个事实罚两次，会让 51 分和 49 分的机房得到相反结论。
4. **地理那一维只标记、不扣分。** 先查三源城市是否一致。实测 RouterHosting `144.172.103.106` 被 ipquery/ipinfo 报犹他、被 ip-api 报内华达，跨了州；这时拿任一源的时区去要求用户对齐就是冤枉人，只能标「地理模糊」。住宅整段跳过（家宽注册地≠接入地不是风险，且另有时区项在管）；**Tor 与代理也必须跳过**——它们的「城市」是数据中心位置，三源按各自出口点库去标必然不一致（实测两个随机 Tor 出口全部命中），挂这个标记是纯噪声。
   **这些标记不再进分数**：地理维度和「时区」检查项说的是同一件事，扣一次分等于重复计费；而且 ip.net.coffee 的 Trust Score 不含这一维，我们多扣 4~6 分，用户拿两边一比就以为我们算错（2026-11-06 实测）。

5. **运营商名要有三级兜底。** ipinfo 免费额度会被打满并回 429（实测连续查询就会），那时 `ip_org` 也跟着空；只用 ipinfo 会让一个干净的 Comcast 退化成「类型不明」70 分 warn 并建议用户换住宅 IP。顺序是 ipinfo 响应的 `org` → **ipquery 响应里的 `org`（零成本）** → `ip_org`。中间的这层不能删。

6. **「数据源认识这个地址吗」与「拿到几个风险信号」必须分开判（`known` 与 `src_n`），不要合并成一个布尔。** 前者回答地址是否真实存在，用来挡空壳响应（ipquery 对 `192.0.2.55` 会回结构完整、标志全 false、风险分 0 的空壳，和「住宅且毫无风险」长得一模一样）；后者回答证据够不够。合并之后两侧都会错：空壳拿到 100 分，或者在有运营商名、有 PTR 的情况下只回一句没有信息量的「未评级」。

   四档结论：

   | 情形 | 结论 |
   |---|---|
   | `src_n == 2` | 正常评分 |
   | `src_n == 1` | 正常评分 + 标 `·仅一家风险源可达`（缺一家就可能漏判代理特征，但不改判定） |
   | `src_n == 0` 且 `known` | **降级判型**：按运营商名 / PTR 定类型，`base` 封顶 70、判定封顶 warn，标 `·风险源不可达`，下一句换成「仅按运营商名或反向解析判型,稍后重查」 |
   | `known` 为空 | 「未评级」+ warn，且不写缓存 |

   降级判型的两个封顶都不能拆：报 100 分是用「没查」冒充「查干净了」；把 warn 升成 fail 是拿我们自己的网络抖动去堵用户（IP 纯净度是可关闭的软信号，不是 Kill-Switch）。另外 PTR 能解出来本身就证明地址存在，所以 `rdns` 非空也算 `known` —— 三家 HTTP 源全挂时它是最后一根线索。

机房出口只给 warn 不拦启动（大量用户就用机房节点），代理特征与 Tor 才拦；机房只有掉到 30 分以下（转租段+滥用记录）才拦。

结果缓存 24 小时（`~/.claude-switcher/purity-cache.v4`），**查不到不写缓存**，否则一次网络抖动会把「未知」钉住一整天。缓存七个字段的顺序是 `ip|时间戳|判定|分数|类型|detail|cc`，分隔符是 `|`：不要改回 tab，tab 属于 IFS 空白，`read` 会把前导空字段整个吞掉，导致 score 与 detail 静默错位。第 7 列 `cc` 是出口国家代码，从已有的 ip-api / ipquery / ipinfo 响应里顺带取出，不发额外请求，供节点扫描的国家硬门槛使用。文件名带 `v3` 是因为多了这一列（v2 的 6 列没有它，混读会让 detail 把 `|US` 吞进去，宁可让旧缓存整体作废）；带 `v4` 是因为 2026-11-06 的类型判定改成证据驱动 —— 列结构没变、**结论口径变了**，不换名字的话升级后 24 小时内还会读到「类型不明 / 机房」的旧结论，用户重装完以为又没修好。改判定必须顺手换缓存名。**降级判型与「仅一家风险源可达」这两类结果不能缓存满 24 小时**——写入时把时间戳往前拨成仅剩 5 分钟 TTL，否则一次数据源抖动会把「没查干净」钉住一整天。多个 IP 并发打分时各自写缓存会互相覆盖，用 `mkdir .purity-cache.lock` 串行化。

**不要把「可关闭」摆到主界面上**：16 项默认全部拦启动，按能不能关分组会让人以为「有些可以不拦」，等于把降级当选项推荐。主界面只列一份清单；关闭入口只在设置页的「降级防护（不推荐）」里。关掉之后必须持续可见——主界面常驻橙色「防护已降级：…」，`check` 输出追加 `|防护降级:…`，否则命令行、日志、自动化这些看不到界面的地方完全无从判断。

**首页不要拿分数当红绿灯**（2026-11-06 用户原话：「不要用分数让别人误会，IP 非常不干净按道理还是能启动」）。`HealthSummary.score` 是四维加权的合成分，只用于诊断与排序，不进主视觉：圆环里是「16/16」这样的读数（通过项数 / 总项数），环色只跟 `HealthSummary.color`（ok / notice / cannotStart）走。曾经有过 `scoreColor`（≥85 绿、60–84 琥珀、<60 红），后果是「IP 纯净度偏低 → 分数掉到 80 → 整圈变琥珀」而徽章明明写着「可以启动」，一屏两句话互相打架，用户只记住颜色，于是把「能启动」读成「快不行了」。同理，同一屏不要出现两处通过数（圆环一处就够，右边原本还有一句「13/15 项通过」）。分数与能否启动本来就会背离 —— README 里那句「65 分的代理会被硬门槛排除、49 分的机房反而可用」就是这个意思 —— 拿它当红绿灯等于把结论建立在软信号上。

**圆环的排布（丑在哪）**（2026-11-06 用户两次反馈：「检查圆环这里的显示……现在的这个不行」「圆形没问题，是你之前排布太丑」）。圆这个形态没问题，**丑在环里那堆字**和环的粗细：

- 环径 92 / 描边 3。原来是 80 / 5，粗环配 26pt 大字像仪表盘；细环才是「环是边框、数字是主体」。
- 环内**一行**「16/16」+ 一行「项通过」。旧排布是两行「16」和「/16 项」——两个 16 挨着、斜杠贴着分母往下沉，读的人得先解析一次才知道哪个是通过数。
- 分子分母拼进**同一个 Text**（`Text(a) + Text(b)`），别用 HStack 对基线：HStack 里斜杠那段的字体度量会让它看起来浮在数字上方。
- 值与分母约 2:1，分母用 `muted`（8.8:1）而不是 `faint`（4.6:1）—— 12pt 下 faint 太浅，扫一眼会读成「16」。
- 单位「项通过」留在环内。挪到环外下方会把整个左块顶高，卡片看着左高右低（实测过：那行字被顶到卡片下边缘）。
- **不要改成「一段一项」的分段环。** 试过 16 段弧、缝 2.5°、按项着色：段长只比缝宽一点，整圈读起来是「加载中的虚线 spinner」，比原来更廉价，用户当场否决（「太丑了」）。`tests/test_hero_semantics.py` 有一条断言盯着这个（环必须是连续弧、环里不许 ForEach）。

出口身份归一：`IP一致` 与 48h 变化统计都不直接比原始地址，而是比归一身份——v4 原样，v6 取 `/64` 前缀。`lastip` 按协议族各存一行，两族互不覆盖；历史统计先按族去重再取最大值。这样同一节点双栈交替（先报 v4 再报 v6、或 v6 在同一 /64 内换接口标识）不会被判成「出口在漂移」或「IP 变了」。旧版写下的裸地址在读取时自动迁移，升级后第一次检查不会误报。`出口IP` 走 v6 时**不再**额外标注「IPv6 出口」——冒号地址本身已说明协议族，补这一句反而容易让用户误以为自己开了本机 IPv6。三条相关行各说各的层，不要合并：`IPv6` 查本机网卡（出口是 v6 时写「本机已关闭 · 节点出口为 IPv6」）；`出口IP` 报节点侧对 Cloudflare 呈现的地址；`WebRTC` 的 STUN 探针只走 v4，无 v4 出口时写「节点无 IPv4 出口，STUN 只回 IPv4，无法比对(非泄漏)」。

客户端日志与诊断：默认在 `~/Library/Logs/claude-switcher/client.log` 记录脱敏命令元数据，512 KiB 后轮转为 `client.log.1`，可用配置中的 `logging` 关闭。`export-diagnostics <file>` 与 App「导出诊断日志」生成 zip，只含客户端日志、检查设置和脱敏环境/状态摘要。不得把公网/住宅/代理 IP、Bearer/token/session/cookie、账号内容、Clash 配置、`lastip`、`iphistory` 或原始 `last-check.txt` 写入日志或诊断包。

跨身份保留（可选，默认关闭）：`~/.claude-switcher/keep-in-workspace.txt` 每行一个相对 Claude 数据目录的路径（如 `settings.json`、`skills/`），`#` 注释、空行忽略。切换时先收进 `~/.claude-switcher/keep-stage/`，还原目标账号后合并回去；绝对路径、含 `..` 和符号链接会跳过并记 WARN。文件不存在或为空时行为与未启用完全一致。只放通用配置，不要放登录态/缓存等账号专属文件。

## 节点扫描与应用（第 16 项，只读优先）

写这一层代码前先把边界记住：**扫描只读，应用只在门禁允许时切一次**。逐节点「切上去实测出口」那条路会写 N 条 `iphistory.log`，把「IP 与上次一致」凭空扣成分数，还会被看门狗当成出口变化直接停掉 Claude——不允许走。

- `node-scan` 从运行中内核的 `/proxies` 沿 `now` 链找到**最深一层含叶子的 Selector**，只列当前真正控路的组；递归列所有嵌套 Selector 会把「☑️ 手动切换」那 75 个无关节点也带进来。
- 合并配置 `proxies:` 块只按白名单读 `name / server / servername / sni / host / type / udp / network` 八个字段，**不读 `uuid` / `password` / 证书**，不导出订阅原文，报告与诊断包都不含凭据。这与 FlClash 一键修复的「不读订阅节点与凭据」是两条独立边界：那条写规则数据库、不碰节点；这条只读节点名和入口地址、不写任何代理配置。
- **硬门槛先于纯净度**：国家不符 / 国家取不到 / Tor 或代理判定 / UDP 未标注的节点都不参与推荐。带 `servername` / `Host` 的 CDN 前置节点 `server` 只是入口，标「出口未知」并排除，不能拿入口 IP 打分。多个叶子共用同一落地 IP 只查一次。
- 差距不足 `NODE_SCAN_MARGIN`（10 分）不出 `BEST`，免得每次扫描都催用户改线路；清空 `BEST` 时必须连 `BEST_IP` / `BEST_SCORE` / `BEST_SELECTOR` 一起清，别留半截报告。
- `checkdetail` 的第 16 项**只读报告文件**，绝不在 45 秒检查预算里发网络请求。没有报告 / 报告过期 → `skip`，不是 `ok`；`skip` 不扣分，用户关掉检查项不该反而掉分。有 `preferred-node` 时，`PREFERRED_MATCH=0` 优先于「还有更优节点」报「已偏离固定节点」。
- 报告门禁 `node_gate()` 只看两个**瞬时**事实：Claude 进程 / CLI 在跑、看门狗仍在驻守，任一成立即 `report-only`。**不要**再把「任一 A–D 已建档槽位」算进去 —— 槽位是常驻资产，存过一次 `hasA=1` 就永远为真，那条判据会让 `node-apply` 对任何用过本工具的人永久拒绝，界面上「应用最优节点」从不出现。执行门禁 `node_apply_gate()` 必须**重新实时判定**，不信报告里的旧快照；看门狗那条从「pidfile 存在」升级为「进程确实已不在跑」的事实检查，残留 pidfile 不阻塞、真有守护仍拒绝。
- 换槽位时这条链自己会走一遍（`VM.optimizeNodeForSwitch`）：审计通过 → `slot-node get <目标>` → `node-scan` → 有绑定就切绑定那条、否则报告里真有 `BEST` 才切 → `stopWatch()` + `node-apply <叶子>` → 重新审计 → 再切账号。三个例外都必须保留：扫描失败不阻断切换；`node-apply` 失败不阻断切换（只把原因写进回执）；换完线路重新审计没过就**不切账号**（fail-closed，新账号第一次连上的就是那条出口）。
- **绑定优先于本次最优**：`BEST` 是「现在谁更干净」的比较结果，绑定是「这个身份就该走这条线」的声明，后者不能被一次扫描盖掉。所以 `node_apply` 支持显式叶子（`node-apply <leaf>`），无参时才取报告里的 `BEST`。绑定存 `$BASE/slot-node/<A-D>`，格式 `selector<TAB>leaf<TAB>epoch`，**不存分数**；命令族 `slot-node list|get|set|clear`。界面在槽位卡右上角给常驻的链接图标菜单，选项只来自最近一次报告的 `CURRENT` / `TOP1-3`，不让人手敲节点名。
- 界面读绑定是直接读盘（`VM.loadSlotNodes`），核心脚本负责写。两处各自拼同一个路径，改动必须同步；`tests/test_cli_slot.py::SlotNodeBindingTests` 钉着这条契约。跟 `probeSlotLogin` 一样，读取属于显示需求，不塞进 `status` 的输出契约。
- 守护归 App 管、切换归脚本管：App 先 `stopWatch()`，`node-apply` 不杀 App 持有的守护（否则 App 会误报「守护意外退出」），切完由 `checkEnvironment` 通过后自动 `startWatch()`。已建立的连接不会迁移；只对 `Selector` 生效，`URLTest` / `Fallback` 会被自动选路覆盖。

## 界面与核心的版本契约（新 App + 旧脚本）

`*-app-only.*` 只换 App，`installer-kit` 才带核心脚本、守护与安装器。所以「新版界面 + v1.7.1 一带旧核心」是可复现的常态，不是个例：旧核心不认识 `node-scan` / `slot-node`，甩一行老 `用法:` 后以退出码 2 退出。

- App 侧 `VM.isStaleCore(_:)` 只认「退出码 2 + 老 usage / 未知命令」这个组合，普通扫描失败不能误判成版本问题；命中后 `coreOutdated` 置位、节点面板显示人话原因和**可复制**的升级命令，`NodeScanSheet` 也带一个复制按钮。`VM.upgradeCoreCommand` 是这条命令的唯一来源，README 与测试都引它，别在多个地方手抄 URL。
- 升级走 `scripts/upgrade-core.sh`，唯一对外入口是 `bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)`：旧版 `self_update` 写死原上游 `YOURSJEYO/claude-switcher`，**不能**指望用户跑 `update` 自愈。脚本从本仓库 `main` 拉 `core/claude-switch.sh` + `SHA256SUMS`，校验哈希、`bash -n`、备份旧脚本、`_support env-migrate` 迁移环境配置、落盘后跑 `help` / `status` 自检；单一 `EXIT` trap + `DONE` 成功标记保证任一步失败都从备份回滚。别用 `ERR` trap —— `die` 走 `exit 1` 时它不触发。
- **旧核心不能阻断切账号**：`optimizeNodeForSwitch` 里扫描失败仍 `done(true)`，只是把「核心脚本过旧，未扫描节点」写进回执。版本错配时把人卡在旧账号上，比跳过节点优化更糟。
- `scripts/package-macos.sh` 必须把 `scripts/upgrade-core.sh` 和 `SHA256SUMS` 一起放进 installer-kit，并列入必备文件检查；只装过 app-only 的人也要有这条急救路径。改 kit 清单要同步改 `tests/test_upgrade_core.py` 的文档/命令契约断言。
- **界面上的每一条结论都来自 `~/.local/bin/claude-switch.sh`，App 不内置任何判型。** 所以「App 里还显示机房 / 类型不明」这类反馈，第一步永远是 `shasum -a 256 ~/.local/bin/claude-switch.sh` 对一下 `SHA256SUMS`，而不是去改 App 或界面。2026-11-06 实测：同一台机器、同一个出口 `66.17.65.38`(AS3257)，旧核心报「疑似机房 · 70/100 类型不明」，仓库里的核心报「运营商未归类 · 100/100 住宅宽带」—— 同一次 `checkdetail`，只差脚本版本。桌面 App 停在 1.8.3-dev 而核心停在更早版本，是「改了没用」最常见的组合：App 只影响界面与交互，判据全在脚本里。
- 别拿仓库里的新版核心往真实 `$HOME` 里跑来做「实机复核」：`check` / `checkdetail` 会写 `~/.claude-switcher/last-check.txt` 与 `iphistory.log`，把用户真实状态覆盖成一次测试的产物。要复核用临时 HOME（`HOME=/tmp/x bash core/claude-switch.sh checkdetail`，把 `env.json` 复制进去即可），跑完不留痕。

## WebRTC 策略自锁与 IP 评分的证据边界

一次实测把三个看似独立的报障串成了同一条链：**当前节点是 HTTP 协议、运行时 `/proxies` 里 `udp:false`**。

- `validate_group` 在 `policy == "proxy"` 时要求 `selected["udp"] is True`（**别删**：UDP 走代理是防 WebRTC 泄漏的正当前提）。它挂在 `clash_rules verify` 里，于是 `WebRTC` 与「规则置顶」双双 fail 且文案一模一样 —— 「规则置顶」其实没测规则，是被同一道前置校验连坐。
- `fix` → `write_merge_rules` → `clash_rules write` 又过同一道校验，0 秒 `return 1`，客户端日志表现为 `command=fix exit=1 duration_ms=0`。
- 最要命的是**自锁**：`webrtc-policy` 唯一写入方是 `clash_rules write`，而它先过这道校验；报错让用户「改用 reject 策略」，界面却没有任何入口能改。提示指向一个不存在的动作。

修法是**不放松门禁，只补一条不经过内核校验的落盘路径**：`set-webrtc-policy <proxy|reject>` 只写策略文件；`fix` 在写规则前探测到「未确认支持 UDP」就先落盘 `reject` 并置 `WEBRTC_POLICY=reject`，后续规则按 `REJECT` 写、按 `REJECT` 验。UDP 直接拒绝，仍然不泄漏。`tests/test_webrtc_rules.py::PolicyUnlockTests` 钉住「入口存在 / 门禁仍在 / 先探测后切换」三件事。

IP 纯净度那侧是独立的证据 bug，别和上面混：

- `dig +short -x` 超时会把诊断行 `;; connection timed out; ...` 写到 **stdout**，`+short` 挡不住。它曾被 `head -1` 取成 `rdns`：既让 `known=1`（零个有效风险源也照常出分），又被当成运营商名拼进检查项，用户看到「评分 60/100 · 机房 · ;; connection timed out;」。诊断行必须以 `;;` 开头丢掉，用 `sed` 而不是 `grep`（空结果别带出非零码）。
- 降级判型时 `score` 只是 `hosting=55` 这类**类型基线**，风险维度一个都没验过。保留 `评分 N/100` 前缀（下游按它取数），但补 `(类型预估·未实测信誉)`；这类结果写缓存时本来就把 epoch 调成 5 分钟后过期，不要改成 24h。
- 节点扫描的 `TOPn` 分数来自 `purity-cache.v3`，可能比当前出口旧一天。两处分数对不上时先比 IP 和扫描时间，不要急着改评分模型。

同一轮实机复查又挖出四个连带坑，**改评分模型之前先排除它们**：

- **陈旧缓存锁**：`.purity-cache.lock` 是 `mkdir` 出来的目录，进程被 kill / 断电会留下空目录，此后 5 次 `mkdir` 全失败、`got=0` 就整段不写缓存。本机实测一把 23 小时前的锁，导致每次检查都重新打四个网络请求、分数随网络抖动飘。锁目录里必须记创建时间，超过 60 秒回收；抢不到锁也要落盘（少一行缓存只是多查一次，静默丢结果会让 5 分钟重查 / 24h 复用整套口径失效）。`tests/test_ip_purity.py` 两个用例分别钉住「陈旧锁被回收」与「活锁不丢结果」。
- **名字不在住宅白名单 ≠ 机房（2026-11-06 改过口径，别再改回去）。** 旧写法是 `ip_class` 对白名单外的运营商一律回 `hosting`；白名单只覆盖 11 个国家的几十家运营商，于是 GTT（AS3257）这种 ipquery `is_datacenter:false`、ip-api `hosting:false`、`risk_score:0` 的出口被报「疑似机房 · 建议换住宅节点」，而 ip.net.coffee 判它「住宅 98/100」。
  现在 `ip_class` 三态：白名单命中 → `residential`；名字含 hosting/cloud/vps/datacenter/colo/backbone/transit/cdn 等**明确机房词** → `hosting`；其余 → `unknown`。
  判型处再补一条 `clean_residential`：两家风险源都可达（`src_n>=2`）、风险标志全否、`risk_score<=10`、无滥用记录、名字里没有机房词 → 判 `residential`（与网站同口径）。**缺任何一条就退回 `unknown`（70 分、`warn`）**，所以这不是「没查到就放行」。
  两个配套约束：`PTR` 里单独一个 `static` 不再算机房特征（家宽静态 IP 就长这样）；`unknown` 绝不能当 `hosting` 用——那正是这次误报的来源。
- **重启后的假失败**：`fix` 写完扩展脚本会 `quit_clash_verge` + 重开，`tun_up` 为真只说明 TUN 设备在了，默认路由还要几秒才把流量送出去。旧版立刻探 `cdn-cgi/trace` 拿到空结果，收尾报 `WebRTC ✗ / 出口IP ✗` 并 `exit=1`，而随后单独跑 `checkdetail` 两项全绿 —— 用户读成「修复不成功」。只在 `just_reloaded=1` 的路径上先等出口回来（最多 4 次），规则无变化不重启时一次请求都不多发。
- **reject 下的 UDP 硬门槛**：切到 `reject` 后 UDP/3478 已在规则层 `REJECT`，节点支不支持 UDP 不再影响泄漏。`scan_nodes` 里的「UDP 未标注」一票否决必须跟随 `$BASE/webrtc-policy` 生效，否则刚修完就把用户正在用的 HTTP 节点标成不可用、两处结论打架。图例里的门槛清单也跟着变。

## 槽位隔离的边界（桌面版 + Claude Code）

一个槽位不只是一个目录，是「一组目录 + 一个文件」：

| 内容 | 桌面版 Claude | Claude Code |
| --- | --- | --- |
| 实时路径 | `~/Library/Application Support/Claude` | `~/.claude/`、`~/.claude.json` |
| 槽内存档 | `$BASE/accounts/<A-D>/` | `$BASE/cli/<A-D>/home/`、`$BASE/cli/<A-D>/home.json` |

- **不要**把 `~/.claude` 塞进 `accounts/<A-D>` 树：那棵树的语义是「桌面版数据目录的内容」，混入子目录会被原样复制回 `DATA`。并列放 `$BASE/cli` 也不动老快照，避免迁移几百 MB 历史目录。
- 归档用**移动语义**：`archive_cli` 先 `mv ~/.claude`，失败要能把已挪走的部分放回原位，不能留「目录没了、`~/.claude.json` 还在」的半截状态；`restore_cli` 会**先清空现场**再放回，目标槽位没存档时 `~/.claude` 和 `~/.claude.json` 一并删除 —— 否则没存过的槽位会接着用上一个账号的登录态，等于没隔离。
- `switch_to` 开头用 `claude_cli_running` 挡住「终端里开着 claude 就切」：CLI 没有 osascript 那种优雅退出口子，直接把正在写的目录抽走会丢状态。进程判据三选一：`pgrep -x claude`（brew / `~/.local/bin` 的原生二进制，`argv[0]` 就是 `claude`）、`claude-code/cli.js`、`@anthropic-ai/claude-code`；大小写敏感，不能误伤桌面 App 的 `Claude`。
- `status` 会把每个槽位的 CLI 存档体积报成 `cliA=151M@2026-11-04`，界面据此在卡片上加一个 `CLI` 角标；老脚本不输出这个字段，缺了就当没有，不能因此判 `status` 失败。

## 独立代理诊断

`bash core/claude-switch.sh diagnose-proxy --config /path/to/private-proxy.json` 只验证明确指定代理到 Claude 网页/API 的无认证传输，详见 README。它可直接从仓库运行，不适用上述安装/启动前置条件，不启动或关闭应用，不创建账号状态、不修改系统设置。输出 JSON；401/403 分别标注认证或访问状态，传输到达不等于账号可用、启动许可或防泄漏通过。不要为运行诊断先安装后台或改 TUN/时区。

隔离回归：`python3 -m unittest discover -s tests -v`。测试使用本机假 curl 和隔离 HOME，不使用真实登录资料或代理。

## 出口多采样、故障演练与离线复核

出口判定不再取单次样本。`check` 对同一域名连采 3 次，全部一致才判 `ok`；采样间不一致判 `fail`（节点在漂移，同一账号的来源在变，比单点异常更危险）；一次都没取到判 `unknown`，只出警告、不拦启动。放宽的前提是连采两轮、共 6 次全空才认 `unknown`——单次空返回多半是网络抖动，之前正是它把抖动误判成「出口IP异常」并拦住 Claude 启动。

`drill [--auto|--manual] [--yes]` 是 fail-closed 演练。平时的检查只能证明「流量走了代理」，证明不了「代理挂了会不会直连」。它先记录基准出口，同时用域名和裸 IP 各探 3 次：任何一条还能出去就是漏，判 `violated` 并报出直连 IP；全部无响应才算 `established`。**默认 `--auto`** 通过内核接口关 TUN，效果等价于核死时路由被撤销，但能精确恢复、不需要 sudo；`--manual` 才是手动停核那条路。全程挂着提醒恢复的 trap，结果追加到 `~/.claude-switcher/drill.log`。2026-11-01 本机实测结论为 `violated`：关掉 TUN 后域名探测直接从中国移动出口出去。

`verdict [报告]` 离线复核 `last-check.txt`（或指定报告），只读不探测，输出 `VERDICT:established|violated|incomplete` 与 blockers/advisories/skipped 三行。`warn` 与 `skip` 既不会被提升成 pass，也不会被当成 fail。`evidence <file>` 把最近一次检查写成 JSON（时间、主机、环境、逐项状态、判定），权限 0600，只新建不覆盖——证据被覆盖就失去追溯意义。

## 运行期出口看门狗（watch）

`check` 是拉起前的门禁，只管那一刻。`watch [间隔] [整轮周期]` 管「已经在用」的那段时间：出口变了就立刻停 Claude。四条纪律，改它之前先读完：

1. **基线只来自「放行那一刻」**。`watch_cycle` 第一轮采到的值即基线，之后每轮比对。App 侧只在 `passed` 之后 `startWatch()`，`refresh()` 开头 `stopWatch()`——拿上一轮的基线继续判，会在检查还没跑完时先按旧结论把 Claude 关掉。
2. **v4/v6 分族记账，v6 只比 `/64` 前缀**。同一台机器在 v4 与 v6 之间来回切是代理正常行为，不是出口变化；v6 后缀轮换同理（隐私扩展地址天天换）。只有前缀变了才算换了网段。
3. **一次失败不动手**。整轮审计失败先 `sleep 5` 复检，仍失败才停；出口探测连续 3 次拿不到地址才判定代理已断。一次 curl 抖动就杀进程，比漏判更让人受不了——这条是用户原话，别改。
4. **停 Claude 必须落到 `pkill`**。`osascript quit` 对 Tauri/Electron 应用经常无响应，等 3 秒仍在就直接 `pkill`，同时清掉 `claude-code/cli.js` 与 `@anthropic-ai/claude-code` 两类 CLI 进程。少清一类，就会留下一个还在发请求的进程。
5. **`TERM`/`INT` 的 trap 里必须 `exit`**。bash 的 trap 执行完会回到被中断的地方继续跑，只删 pidfile 不 `exit` 的话，App 的 `terminate()` 压根停不下看门狗——实测就是这样每重启一次 App 就多一个孤儿守护，各自拿一份基线判出口。`EXIT` 分支只做清理，不要 `exit`（会递归）。
6. **定位看门狗只认 pidfile，不用 `pkill -f "claude-switch.sh watch"`**。`-f` 匹配整条命令行，任何命令行里含这串字的进程都会被误杀——包括用户自己的 `grep`、`tail`，以及诊断命令本身。实测踩到过，表现为「正在跑的 shell 突然收到 SIGTERM」。App 侧读 pidfile 后还要用 `ps -p <pid> -o command=` 确认一次，避免 pid 复用误杀无关进程。

拦截后的提醒走三条路：窗口横幅、菜单栏图标、系统通知。**通知不能省**——出问题时用户多半没开着窗口，前两条都看不见。通知走 `osascript display notification` 而不是 `UNUserNotificationCenter`：App 是 ad-hoc 签名，重签名后通知授权会失效。

**菜单栏图标是状态指示器，不是品牌装饰**（2026-11-06 更正：这段以前写的是「换成 `exclamationmark.shield.fill`」，早就不是了）。现在是 `MenuBarBrand` 自绘的 18pt 模板图：正常态「实心盾 + 挖空十二射线星芒」，拦截态「实心盾 + 挖空感叹号」。两条判据：

- 看到菜单栏是**盾牌加感叹号**，不要当成「星芒没生效」的缺陷去查图标资源 —— 那是拦截态在如实工作。正确的下一步是 `~/.claude-switcher/incidents.log` 最后一条，那里写着被拦的真实原因。
- 拦截态**故意**不画星芒：18pt 下星芒挖空前只剩 8pt，与正常态区分不出来，而状态图标的第一职责是「一眼看出出没出事」。试过保留星芒的四种画法（斜杠划过 / 右下警示点 / 只留上半圈射线 / 星芒+小徽章），四种在 18pt 下要么糊成一团，要么把盾牌边缘啃出缺口，都不如现状。要改先按这个尺寸渲染比对，别凭想象定稿。
- 代价是它和系统 `exclamationmark.shield.fill` 同形，用户容易以为「图标还是旧的」。这属于状态语义与品牌识别的取舍，**不要靠改图形解决**；真要优化，方向是让「已拦截」这件事更早被用户读到（横幅文案、通知标题），而不是把星芒硬塞回去。

7. **拦截必须留结构化记录**。`stop_claude_now` 末尾调 `watch_incident <原因> <类型>`，写 `incidents.log`：TAB 分隔「时间 / 类型 / 原因」三列，只留最近 50 条。界面的「拦截记录」卡片按 TAB 切列渲染，**列数或分隔符一改，界面就整条丢掉**。`watch.log` 是流水账（启动/复检/接管全在里面），别拿它当历史——用户想回看「上次为什么被停」时，从几百行里捞是灾难。空原因不写：一条只有时间的记录只会把真记录挤出 50 条窗口。

App 退出时必须 `stopWatch()`。App 关了而看门狗还在杀 Claude，是最坏的一种组合。

## 验收标准（全部满足才算装完）

- 终端执行 `~/.local/bin/claude-switch.sh checkdetail` 输出完整 16 行；硬性安全项全部 `=ok`，非关键项只能是 `=ok`、既有警告，或用户显式配置的 `=skip`/降级警告
- 每行结论只允许 `ok` / `fail` / `config` / `warn` / `skip` 五种。`fail` 与 `config` 都拦启动，但语义不同：`fail` 是实测不达标（去修环境），`config` 是环境层没就绪、无从判定（去补配置）。文案必须带「当前值 vs 期望值 + 一条动作」，禁止只写「未生效」「异常」这类无动作的结论
- 双击桌面 App，无红色硬性安全项，能正常启动 Claude；灰色 `skip` 不得当成绿色通过
- `launchctl print system/local.claude-bodyguard`、`system/local.tz-watchdog` 与 `gui/$(id -u)/local.claude-update` 均能查到（服务已注册）
- `/Library/Application Support/claude-switcher/` 下两个守护脚本属 root:wheel、权限 755，当前用户不可写
- 切换一次账号 B 再切回 A，A 的登录态完好

## 排障手册（以下全是实战中踩过的坑，按症状直接查）

| 症状 | 根因 | 处理 |
|---|---|---|
| TUN 网卡消失、出口变回国内 | **Clash Verge 更新/异常重启会把 `enable_tun_mode` 重置为 false** | 退出 App → 改 `verge.yaml` 为 true → 重启 App。切换器的一键修复已内置此逻辑 |
| 时区总是自己变回去 | macOS 自动时区或未知程序改动 | 看门狗会自动回滚；查 `~/Library/Logs/tz-watchdog.log` 留痕 |
| 检查结果显示 0/11、数据为空 | 中文日志被 `cut -c` 按字节截断产生非法 UTF-8，Swift 严格解码整体失败 | 脚本必须 `export LC_ALL=en_US.UTF-8`；界面端用容错解码 `String(decoding:as:)` |
| 修改 App 后界面没变化 | 菜单栏版本关闭窗口仅隐藏；`pkill` 匹配中文路径还可能因 Unicode NFD 编码失配而静默失败 | 先从盾牌菜单选「退出 Claude 环境检查器」，再替换 App；开发排障也可按进程名退出测试实例。不要把关窗改回退出，以免破坏菜单栏驻留 |
| headless Chrome 做 WebRTC 检测无结果 | headless 模式 ICE 子系统不产出候选 | 不要走浏览器路线，用本项目的纯 Python STUN 探针 |
| 代理节点报错但流量没泄漏 | 节点被重置时隧道内请求失败≠泄漏；Fail-Closed 下流量只断不绕 | 换线路即可 |
| 切换账号报「存在待恢复快照，拒绝覆盖」 | 上次归档被中断，`~/.claude-switcher/accounts/<账号>.new` 或 `.previous` 残留（可能是唯一副本） | 先确认 `<账号>/` 是否完整；若有 `.previous` 且正式目录缺失，用它恢复；确认无价值后再删除 `.new`/`.previous` 重试 |
| 规则置顶显示「内核缺少 Claude 域名」/「环境层未就绪」 | 前者是 rule 模式下 Script.js 未启用或规则被覆盖；后者是代理组名没取到，环境层（`env.json`）不完整，与规则本身无关 | 前者跑 `fix` 写全局扩展脚本；后者先跑 `fix` 让它反查内核补出代理组，再看提示重试。global 模式下规则本不生效（正常），显示为 ok |
| WebRTC 检测失败但 TUN 正常 | STUN 被国内直连规则匹配、全局脚本未启用、代理组或节点 UDP 能力不符 | Clash Verge 运行 `fix` 写入全局 Script.js；FlClash 运行 `fix` 备份并在当前 Profile 事务写入域名与 UDP 3478/5349/19302 规则，重启验证，失败回滚。默认 proxy；`WEBRTC_POLICY=reject claude-switch.sh fix` 可切换并持久化拒绝策略（影响部分通话）。不要再向全局 Merge.yaml 手写 prepend-rules，不要把无 STUN 响应视为零暴露 |
| 安装器未能识别出口国家 | 只探测 ipinfo.io，代理规则判直连/被墙/限流时国家为空直接退出 | 已改为 ipinfo → ipapi → ifconfig → Cloudflare trace 多源自动兜底；仍失败时检查代理规则是否把这些域名判直连，或 `FORCE=1` + 手动选地区 |
| Windows 地区检查误红（非美国用户） | `$LOCALE_TARGET` 与系统「区域格式」不一致；旧版曾写死 `en-US` | 运行 `claude-switch.ps1 set-region`；或在「设置 → 时间和语言 → 语言和区域 → 区域格式」中改成目标 locale，并确认 `$LOCALE_TARGET` |
| 切换账号后对方看到"新设备" | 正常：快照隔离意味着每个账号有独立设备指纹，这正是设计目标 | 无需处理 |
| 切换后某些文件没过去／不该过去 | 跨身份保留默认关闭，只复制 `~/.claude-switcher/keep-in-workspace.txt` 中列出的相对路径；绝对路径、含 `..`、符号链接会被跳过 | 对照该文件与 `~/Library/Logs/claude-switch.log` 的 WARN；只保留通用配置，不要把登录态/缓存列进去 |

## 安全红线（Agent 必须遵守）

1. **绝不在出口国家与目标不一致时启动 Claude**——任何时候先验 cloudflare trace 的 `loc` 与 `~/.claude-switcher/env.json` 里的 `country` 一致；换了国家节点先跑 `claude-switch.sh set-region` 再启动
2. 切换账号前必须先完全退出 Claude 进程，再交换数据目录
3. 不要在日志、文档、Issue 里暴露用户的住宅/代理 IP 与任何凭据
4. 不要改动 `~/.claude-switcher/accounts/` 下的存档结构
5. **维护纪律**：`core/`、`daemons/`、`installer/` 下任何文件改动后，提交前必须运行 `scripts/gen-sums.sh` 重新生成根目录 `SHA256SUMS` 并同提交——自动更新靠它校验工件完整性，清单与代码不一致会导致所有用户更新失败
6. **守护进程脚本只在 root 目录**：`/Library/Application Support/claude-switcher/` 下的保镖/看门狗属 root:wheel，任何功能都不要改回写 `~/.local/bin/` 下的同名脚本（用户可写=提权面）；需要变更时引导用户重跑安装器

## 问题修复决策规则（Agent 必须遵守）

接到反馈时，**先判断这是「用户个例」还是「所有用户都会遇到的普遍问题」，再决定改不改产品**：

1. **用户个例**：只与对方的节点、分流规则、系统设置、操作顺序、第三方软件冲突有关，默认配置下无法复现 → 只给排查步骤与用户侧修复方案（改配置、换节点、重装、更新），不轻易改产品代码。
2. **普遍问题**：默认安装/升级路径、平台兼容性、安装器健壮性、数据安全、竞态、官方客户端行为变化等，任何用户都可能遇到 → 应当修复；修复要向后兼容，附回归测试，并说明影响面与回滚方式。
3. **先复现再定性**：能在隔离环境复现或找到证据（日志、API 返回、上游 issue）才算普遍问题；无法复现先按个例处理并记录，除非有明确证据表明影响所有用户。
4. **修复前先说清根因与范围**：向维护者说明「问题是什么、影响谁、为什么这样修、怎么验证」；破坏性/高风险改动仍需维护者确认后再执行。
5. **不为修个例牺牲安全不变量**：不能为了让某个环境通过而放宽出口一致性、Kill-Switch、root 权限边界或供应链校验。
6. **发布前检查**：测试全过、文档与 SHA256SUMS 同步、回滚路径明确；无法真机验证的平台必须如实标注。

## Windows 版（windows/ 目录, Beta）

Windows 用户请使用 `windows/` 下的 PowerShell 版本。关键差异与注意事项：

- **文件编码**：所有 `.ps1` 文件必须保持 **UTF-8 with BOM**（Windows PowerShell 5.1 无 BOM 会把中文读成乱码）。编辑后若中文变乱码，重新加 BOM。
- **时区 ID 体系不同**：Windows 用 `Eastern Standard Time` 这类 ID，核心脚本的 `ConvertTo-WindowsTimeZone` 负责把 IANA 时区（America/New_York）映射过去，`install.ps1` 保留同映射的副本。
- **地区自适应**：安装器按国家写入 `$COUNTRY_TARGET` / `$TZ_TARGET` / `$LOCALE_TARGET`；换节点后运行 `set-region` 重新探测出口（ipinfo → ipapi → ifconfig → Cloudflare trace），更新三个目标、通过一次 UAC 设置时区、用用户级 `Set-Culture` 设置地区格式；出口 CN 拒绝。`地区` 检查比较 `CurrentCulture.Name` 与 `$LOCALE_TARGET`，不再写死 `en-US`。
- **权限模型**：`install.ps1` 需要管理员运行（注册计划任务/锁时区/关 IPv6）；日常使用中「一键修复」通过 `Start-Process -Verb RunAs` 触发 UAC 弹窗。
- **保镖实现**：用计划任务（AtLogOn 触发）启动隐藏 PowerShell 常驻进程，10 秒巡检，与 Mac 版行为一致。
- **robocopy 退出码**：0-7 都是成功，8+ 才是失败——判断切换成败时不要按常规退出码判断。
- **切换写入顺序**：先复制到 `accounts\<槽位>.new`，复制成功后才改名提交，旧快照暂存为 `.previous`。同盘时，载入暂存与换位备份放在 `%USERPROFILE%\.claude-switcher\staging\Claude.new` / `Claude.old`，避免 `%APPDATA%` 同时出现多个 Claude 数据目录；重定向到不同盘时回退 `%APPDATA%\Claude.new` / `Claude.old` 以避免跨卷改名。数据与 `current.txt` 先一起提交，再清理旧目录。预先存在的不明残留一律拒绝覆盖、绝不自动删除；仅 `staging\cleanup.json` 能证明路径与当前账号归属的 `Claude.old` 可在下次切换前重试清理。隔离回归：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows-switch-integration.ps1`（临时目录 + 打桩进程，不需要真机账号）。
- **账号数据目录**：传统 EXE 版为 `%APPDATA%\Claude`；旧目录不存在时自动发现 MSIX/Appx 的 `%LOCALAPPDATA%\Claude-Data\<PackageFamilyName>`（不是 macOS 的 `~/Library/Application Support/Claude`）。WPF 与 `status` 均支持 A–D、快照大小和日期；切换前必须重新完成审计。`keep-in-workspace.txt` 的语义与 macOS 相同，但 Windows 还需拒绝重解析点。
- **代理客户端**：支持 `clash-verge` / `flclash` / `sing-box` / `clashx` / `surge` / `wireguard` / `other` / `auto`。`set-client` 同时更新核心脚本与 `proxy-mode.txt`，保镖每轮重新读取该文件；不要套用 macOS 的 root 守护同步方式。
- **工具与快照**：`fingerprint`、`cli-info`、`open-safe`、`diagnose-proxy` 均已提供 Windows 实现。`snapshot-export` / `snapshot-import` 使用流式 `.csnap`（PBKDF2-HMAC-SHA256 200,000 轮、AES-256-CBC、HMAC-SHA256），不与 macOS DMG 兼容；密码仅经 stdin，先认证再解压，目标槽位非空或包路径越界必须拒绝。隔离回归另有 `tests\windows-snapshot-integration.ps1`。
- **检查设置与日志**：Windows 有自己的 6 项非关键检查白名单（macOS 为 8 项），`allowOptionalFailures` 的作用边界与 macOS 一致；配置在 `%USERPROFILE%\.claude-switcher\checks.json`，脱敏日志在 `%USERPROFILE%\.claude-switcher\logs\client.log`，512 KiB 轮转。WPF 设置窗口和 `export-diagnostics` 可导出脱敏诊断 zip，不得包含账号、IP、凭据、Clash 配置或原始检查详情。独立代理诊断不得创建账号状态或写客户端日志。
- **已知限制**：新 WPF、FlClash、隔离浏览器、代理诊断、加密快照、安装与更新流程尚未做 Windows 真机验收，静态/XAML 测试不能冒充真机测试；Clash Verge 的 TUN 开关被更新重置后在 Windows 端需手动重开。
- **自动更新**：启动时静默检查 GitHub 最新 Release，有新版显示提示条；一键更新会下载 zip、校验 SHA256、备份并替换用户目录脚本、重启保镖任务和界面，失败自动回滚，不需要管理员。发布 zip 根必须带 `VERSION`（`release.yml` 已写入），安装后落到 `%USERPROFILE%\.claude-switcher\version.txt`。
- **Clash 规则**：一键修复先识别 Clash 模式（Mihomo API `/configs`，失败回退 `clash-verge.yaml`/`config.yaml`/`verge.yaml` 的 `mode:`）。全局/直连模式不写规则，仅清理旧 Merge；规则模式只写 `profiles\Script.js` 托管块，重启后用内核 `/rules` 验证前 16 条，失败回滚。安装器不再写 `Merge.yaml`，旧 `prepend-rules`/`---` 会被清理并备份。控制接口地址从 `clash-verge.yaml` → `config.yaml` → `verge.yaml` 依次查找（不支持 unix socket）；「规则置顶」告警括号里会带原因（未配置/拒绝连接/鉴权失败/超时），只读排查用 `rules-status`。
- SmartScreen 首次运行拦截属正常现象（未签名脚本），引导用户「更多信息 → 仍要运行」。

## Linux 版（linux/ 目录, Beta）

Linux 用户使用 `linux/` 下的 bash 版本。**开始之前必须先理解最大的前提差异**：

- **Claude 官方没有 Linux 桌面版**——使用形态是「网页版(浏览器) + Claude Code CLI」。因此：
  - 账号切换切换的是**浏览器配置目录**（`~/.config/google-chrome` 或 `~/.config/chromium`），即切换 Web 登录态；切换前必须完全退出浏览器
  - 保镖只终止 `claude` CLI 进程，**不要让它去杀浏览器**（网页端保护交给 TUN + 置顶规则）
- **多客户端**：`PROXY_MODE` 支持 clash-verge / mihomo / sing-box / v2raya / nekobox / hiddify / wireguard / other / auto；非 Clash 客户端不做配置改写，只做 fake-ip 行为检测并提示用户自行加 DOMAIN-SUFFIX 规则；`wireguard` / `other` 为通用虚拟网卡启发式判定
- **地区自适应**：`COUNTRY_TARGET` / `TZ_TARGET` / `LOCALE_TARGET` 由安装器按出口自动写入；`CN` 出口拒绝安装；换国家节点后手动改这三个值（Linux 版暂无 `set-region` 命令）
- **常驻服务**：systemd 用户单元（`~/.config/systemd/user/`，免 sudo、登录自启）
- **系统设置**：时区用 `timedatectl set-timezone`（sudo）；IPv6 用 `sysctl -w net.ipv6.conf.all.disable_ipv6=1` + `/etc/sysctl.d/` 持久化
- **DNS 查询工具**：`dig` → `nslookup` → `getent` 逐级回退（部分发行版默认无 dig，脚本已内置回退，勿改成 dig 硬依赖）
- **界面**：无 GUI，终端菜单（`claude-switch menu`）+ CLI 参数
- **发行版差异**：安装器不区分发行版，但依赖 systemd；非 systemd 发行版（如 Alpine/void 部分配置）需要手工替代保镖常驻方式
- 配置目录路径：Clash Verge Linux 版配置在 `~/.config/io.github.clash-verge-rev.clash-verge-rev/`（脚本已兼容两种常见路径）

## 文件索引

- 核心逻辑：`core/claude-switch.sh`（安检/切换/修复全在这一个文件）
- 泄漏探针：`core/stun-probe.py`
- 界面：`app/main.swift`（单文件 SwiftUI）
- 守护进程模板：`daemons/`
- 安装器：`installer/`
- Windows 版：`windows/`（核心 `claude-switch.ps1` / 界面 `SwitcherUI.ps1` / 安装器 `install.ps1` / 保镖 `claude-bodyguard.ps1`）
- Linux 版：`linux/`（核心 `claude-switch.sh` / 保镖 `claude-bodyguard.sh` / 安装器 `install.sh`）
- Web 版：`docs/` 下的 index.html/app.js/style.css（纯静态环境检测页，GitHub Pages 从 docs/ 发布）

## 一键修复「点了没反应」的三层根因（1.8.7-dev）

- **解释器 PATH 不一致**：安装器在终端做 `python3 --version`，菜单栏 App 从 Finder 启动继承的却是 launchd 极简 PATH。终端能跑 `fix`、界面 0 秒失败，就是这么来的。核心脚本顶部 `resolve_python()` 按绝对路径解析并 `export CLAUDE_SWITCHER_PYTHON`，所有内嵌 Python 一律写 `"${CLAUDE_SWITCHER_PYTHON:-python3}"`，禁止再写裸 `python3`。注意 `fix()` 函数体会被 `test_webrtc_rules` 单独抽出来跑，**里面不能依赖顶层函数**（解释器缺失的提示放在 `clash_rules policy` 失败分支里，用 `case` 自包含判断）。
- **非零退出抹掉回执**：`fix()` 收尾 `WebRTC ✗` 会 `return 1`，而 App 旧代码对任何非零退出都 `fixStates = [:]` + `phase = .failed`，把「已修好 8 项」显示成「脚本执行失败（退出码 1）」。判定依据只能是完整输出里有没有**唯一**的 `FIX:修复流程结束`：有 = 流程跑完，保留回执、点名剩余项并复查；没有 = 启动阶段就退出，才显示原始错误 + 可操作提示。流式 `onLine` 跑在后台队列，必须回主线程改 `@Published`，并在 `done` 里用完整输出幂等重放一次。
- **诊断包看不到失败点**：`export-diagnostics` 的 `client.log` 白名单只留 `command=... exit=... duration_ms=...`，`recent-status.json` 只有状态摘要，两者都定位不了 `fix` 卡在哪一行。App 现在把 `fix` 原始输出写到 `~/Library/Logs/claude-switcher/last-fix.log`（0600），导出时经 `safe_fix_log()` 白名单 + IP/IPv6/本机路径/URL/凭据脱敏后作为 `last-fix.log` 入包。**新增任何输出文件都要先过这道脱敏，别整份塞进 zip。** 文件不存在（旧版 App / 还没点过修复）要静默跳过。

## 第四层根因：「规则已是最新」≠ 内核已加载（1.8.7-dev 之后）

`last-fix.log` 里同时出现 `FIX:置顶规则 ✓ 规则已是最新,未重启客户端` 与
`FIX:WebRTC ✗ UDP 3478 规则没置顶 · 点「一键修复」` 时，别再回头查 python3 / 回执 / 诊断导出
——那三层已经修好了。这是 `write_merge_rules`（只比较磁盘上的 `Script.js` / `Merge.yaml`，
返回「无变化」）与 `clash_rules verify`（读运行中内核的 `/rules`）判的不是同一个东西：
客户端冷启动、TUN 重建、全局扩展脚本被临时关掉时，文件对而内核没加载。

- `fix()` B2 的 `*无变化*` 分支**必须先跑一次 `clash_rules verify`**，只有内核也认了才允许跳过重启。
- 只有 `*未按策略置顶*` 这类重启能解决的失败才设 `need_reload=1`；节点不支持 UDP、非 rule 模式、
  代理组不存在、控制接口读不到时重启也修不好，直接说明原因，别让用户白等一次 TUN 重建。
- `just_reloaded=1` 必须紧贴 `quit_clash_verge`（`test_fix_waits_for_egress_only_after_a_real_restart`
  按 60 字符窗口断言），且只在真重启过时置位，C 段的路由收敛等待才不会拖慢省钱路径。
- 收尾 `FIX:WebRTC ✗` 不能再照抄 `rule_fix_hint` 的「点「一键修复」」——那是刚刚点过的同一个按钮，
  会构成无限循环；`*规则没置顶*|*内核缺少*` 要改指「确认全局扩展脚本已启用」。
- 回归见 `tests/test_fix_runtime_reload.py`：直接抽 core 里真实的 B2 段用桩执行，别抄一份脚本。
- 这类修复只动核心脚本时，**不要让用户重下整包**：界面 App 没变，`upgrade-core.sh` 升核心即可。

## 维护者本机纪律（Agent 必须遵守）

**除非维护者在当次对话中明确要求，否则不得更新/部署维护者本机的已安装版本。** 具体包括：

- 不得覆盖 `~/.local/bin/claude-switch.sh`、`~/.local/bin/local.claude-*.plist`
- 不得重新编译或替换桌面 App（安装器、`scripts/package-macos.sh` 与 Windows 快捷方式统一为 `~/Desktop/Claude 环境检查器.app` / 「Claude 环境检查器」；窗口标题同名）
- 不得改动 `/Library/Application Support/claude-switcher/`、`/Library/LaunchDaemons/local.claude-*`、`~/Library/LaunchAgents/local.claude-*`
- 不得触发本机 `update`、不得执行安装器/卸载器

日常开发默认流程：**只修改仓库文件 → 验证（本地只跑不影响安装态的测试/静态检查）→ 提交推送**。维护者已持续授权：每次修复完成并通过适用验证后，可直接提交并推送 `main`，无需逐次确认；推送前仍需 `git fetch origin main` 核对远端，不得覆盖他人工作，也不得提交故意保留的未跟踪交接文档。需要真机验证时，先询问维护者是否允许在本机部署。打 tag、发布 Release、执行安装器/更新器或修改真实账号与代理配置，仍须逐次明确授权。
