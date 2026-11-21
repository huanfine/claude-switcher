# 变更记录

本文件按时间倒序记录核心脚本（`core/claude-switch.sh`）与界面（`app/main.swift`）的行为变化。
每条都注明**触发条件 / 影响组件 / 根因**，方便日后判断「这条改动到底动了什么」。
更细的工程依据（代码位置、实测命令、负例对照）在 [AGENTS.md](AGENTS.md)。

## 未发布（自 v1.8.12-dev）

### 修复

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
