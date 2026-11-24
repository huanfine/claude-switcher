# DNS 泄露检测器审计(2026-11-23/24)

> 结论:**检查逻辑主体正确,一处缺口已修复上线**。
> 审计对象:`dns_audit` + 第 16 项「DNS泄露」+ `write_dns_merge` 修复闭环
> (core/claude-switch.sh,commit `2ca2af6` → `6c2bbac`)。

## 背景

2026-11-23 用户泄露测试页测出国内解析器,而检查器 16 项全绿。根因:订阅原生
DNS 架构(国内 DoH nameserver + fallback 并发查询)把海外域名解析送进国内递归;
旧 DNS 项只验「走隧道」,验不出上游是谁。同日交付:dns_audit 审计、检查项
「DNS泄露」、fix 托管修复块(详见 CHANGELOG 未发布段)。

本文记录的是交付后的**复审**:检测器自己的判断对不对。

## 方法

不靠目测,全部端到端实测:隔离 harness 提取真实函数,喂六种真实配置形态,
核对判定与原因;另跑修复闭环(老架构 → fix → Merge.yaml 落盘 → 复审)。

## 六形态终验结果

| 形态 | 期望 | 实测 |
|---|---|---|
| ① 老订阅架构(国内 DoH nameserver + fallback 并发) | fail | ✅ 两条原因均点名(fallback 并发 / 无海外加密上游) |
| ② 明文 UDP 上游(8.8.4.4) | fail | ✅ 点名「nameserver 含明文上游(8.8.4.4)」 |
| ③ 修复后形态(海外加密 DoH + `fallback: []`) | pass | ✅ |
| ④ 内联数组老架构(`nameserver: [doh.pub]` / `fallback: [8.8.4.4]`) | fail 且原因正确 | 修复前:fail 但报「nameserver 为空」(原因错);**修复后:✅ 原因正确** |
| ⑤ 内联数组干净配置 | pass | 修复前:误报 fail;**修复后:✅ pass** |
| ⑥ DoT 加密(`tls://8.8.8.8`) | pass | ✅ 正确识别为加密 |

修复闭环实测:老架构 → `write_dns_merge` → Merge.yaml 托管块落盘
(用户既有内容保留、顶层 `dns:` 键无重复、标记块完整)→ 复审通过。

## 发现并修复的缺口(commit `6c2bbac`)

**内联数组写法判错原因。** 旧提取只认逐行块形式,`nameserver: [x]` 这种
YAML 内联数组被判成「nameserver 为空」:

- 后果一(轻):老架构 fail 成立但原因写错,误导诊断;
- 后果二(中):干净的内联配置被误报 fail;
- **不存在的后果:漏放行**。fail 仍然成立,fix 仍然会写托管块,修复后
  运行配置重生成即块形式,复审通过 —— 闭环始终是安全的。

修复:新增 `dns_list_entries`(块形式 + 内联数组通吃),`dns_audit` 接线;
负例 2 例进 `tests/test_dns_audit.py`(共 11 例,全过)。

## 设计边界(不查是分工,不是漏)

| 不审计的项 | 理由 |
|---|---|
| `default-nameserver` 明文(223.5.5.5 等) | 只用于解析 DoH 服务器自己的域名,用户域名不经过它 |
| `nameserver-policy: geosite:cn → 国内 DoH` | 国内域名直连快解析是设计意图,不是泄露 |
| `/dns/query` 活性探测不验应答真假 | 防污染由「规则置顶」项钉 IP 段负责(160.79.104.0/21),分工明确 |

## 海外加密上游白名单机制说明

「无海外加密上游」判定基于硬编码已知名单(8.8.8.8 / 1.1.1.1 / dns.google /
cloudflare-dns.com / 9.9.9.9 / dns.sb / opendns / adguard 等常见形态)。
不在名单内的海外解析器会被误判 fail —— 方向是「宁可误报不漏报」,
且 fail 有一键修复兜底,不会把用户锁死。

## 关联

- 泄露根因与修复决策:CHANGELOG 未发布段「DNS 上游体检」条目
- 组名自愈(订阅换组死循环):CHANGELOG「代理组消失后一键修复不再死循环」
- 回归护栏:`tests/test_dns_audit.py`(11 例)、`tests/test_group_reselect.py`(7 例)
