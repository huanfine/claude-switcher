# Claude Switcher 安全与可靠性加固 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在不削弱出口一致性、账号隔离、root 权限边界和供应链校验的前提下，修复已确认的更新 fail-open、账号切换半状态、节点门禁绕过与运行期竞态，并建立可重复的发布验证。

**Architecture:** 保留“功能 / 数据 / 环境”三层分离和现有 `accounts/<A-H>/`、`cli/<A-H>/` 存档结构。更新改为“严格预检 → 同目录原子替换 → 结构化自检 → 可验证回滚”；切换改为“租约预检 → 备齐目标状态 → 租约复核 → 可恢复事务提交”；所有新增判定继续由核心脚本拥有，App 只编排和展示。

**Tech Stack:** Bash、内嵌 Python 3 标准库、SwiftUI/AppKit、macOS `hdiutil`/`openssl`/`tar`、Python `unittest`、GitHub Actions。

---

## 0. 方案状态与审计基线

本文件是实施方案，不是实施记录。编写本文件时未修改产品代码、未提交、未部署、未发布。

代码基线：`ed83582`。当前完整隔离回归为 **674 项通过**；运行时约 499 秒。行号会随实现变化，执行时先用函数名重新定位，不要机械套用旧行号。

已确认问题按本方案优先级分组：

| 优先级 | 问题 | 主要位置 |
|---|---|---|
| P0 | 更新清单可省略核心；损坏核心可被安装并报告成功 | `core/claude-switch.sh:self_update()`，当前约 5858 |
| P0 | 核心复制非原子，复制/回滚失败未检查 | 同上，当前约 5944–5951、5987、6012 |
| P0 | 自检不检查退出码、JSON 契约和 `ok → config` 退化 | 同上，当前约 5979–6019 |
| P1 | 桌面版、CLI、`current` 不是同一事务 | `restore_cli()` / `switch_to()`，当前约 7238 / 7380 |
| P1 | 租约在数据变更之后才检查 | `switch_to()`，当前约 7492 |
| P1 | E–H 可导出但 marker 只允许 A–D | `snapshot_import()`，当前约 6847 |
| P1 | `node-apply <leaf>` 绕过扫描硬门槛 | `node_apply()`，当前约 5185 |
| P1 | watch 停止/重启后，旧完成回调可污染新一代状态 | `app/main.swift:startWatch()` / `stopWatch()`，当前约 963 / 1070 |
| P2 | 兼容快照无完整性认证、成员预检过晚、允许链接成员 | `_snapshot_archive_*()` / `snapshot_import()` |
| P2 | 安装器把路径和时区拼进 `sudo bash -c` | `installer/安装.command`，当前约 479–507 |
| P2 | root 时区看门狗直接采纳用户可写 `env.json` | `daemons/tz-watchdog.sh:15` |
| P2 | tag 发布不重跑完整测试 | `.github/workflows/release.yml` |
| P2 | `slot_node_list()` 仍只列 A–D | `core/claude-switch.sh:slot_node_list()`，当前约 5305 |
| P2 | 清单未覆盖 `core/stun-probe.py` | `scripts/gen-sums.sh:5` |
| P2 | 回滚提示固定称“自动更新”且暗示必然自动恢复 | `app/main.swift:loadUpdateRollback()`，当前约 893 |
| P2 | 架构文档统计和纯净度数据源描述过期 | `ARCHITECTURE.md` |

### 0.1 不可改变的安全不变量

1. 出口国家与 `env.json` 目标不一致时，不得启动 Claude。
2. 切换前必须完全退出 Claude 桌面进程和 Claude Code CLI。
3. 硬性安全项不可关闭或降级；`skip` 永远不是通过。
4. 报告是快照，租约才是启动许可；环境、核心、检查配置或节点变化后旧租约必须失效。
5. 扫描只读，不得逐节点在线切换；不得污染 `iphistory` 或触发巡检。
6. 账号实时目录、存档目录和恢复暂存目录不得含来历不明的覆盖操作；`.new` / `.previous` 可能是唯一副本。
7. root 守护只安装在 `/Library/Application Support/claude-switcher/`，属 `root:wheel`、权限 755；日志只写 `/var/log/claude-switcher/`。
8. 不把住宅/代理 IP、Bearer/token/session/cookie、账号内容或 Clash 配置写入日志、回滚记录或诊断包。
9. 更新信任根仍是 GitHub + HTTPS；本方案不假装解决仓库接管或补发独立签名。
10. 所有测试使用隔离 HOME、假 curl、假内核和临时目录，不读取真实账号或代理凭据。

### 0.2 推荐决策与明确取舍

#### 决策 A：更新自检接受环境失败，但拒绝核心契约失败

保留 `ed83582` 的反自锁设计：

- 基线 `ok → fail`：回滚。
- 基线 `ok → config`：回滚；`config` 与 `fail` 都是阻断状态。
- 基线已经 `fail/config/warn/skip`：不因沿用旧状态回滚。
- 新核心首次检出的环境 `fail`：不阻止更新，但必须点名。
- 自检非零、报告不可解析、16 个稳定 ID 不完整、重复项、指纹不匹配：属于核心/执行契约失败，必须回滚。

理由：环境故障不应阻止“能修环境的新核心”安装；但“新核心根本不会产生可信报告”必须阻止安装。

#### 决策 B：快照 v2 使用 encrypt-then-MAC，不引入新依赖

macOS 自带 Python 当前未安装 `cryptography`，不能让基本功能依赖用户额外 pip 安装。

推荐 v2 兼容归档格式：

- 新 magic：`CLAUDE-SWITCHER-ARCHIVE-2`。
- AES-256-CBC 仍由系统 `openssl enc` 完成，密码经继承文件描述符传入，不进入 argv 或磁盘。
- 认证密钥由 Python 标准库 `hashlib.pbkdf2_hmac('sha256', ...)` 独立派生，域分离标签使用 `claude-switcher-archive-v2-auth`。
- 对“规范化 header + `Salted__` + salt + 密文”计算 HMAC-SHA256，先认证再解密、再解压。
- header 至少含 `version=2`、随机 16 字节 salt、认证 tag；header 本身进入 MAC。
- 比较 tag 使用 `hmac.compare_digest()`。
- v1 只保留导入迁移能力，明确提示“旧格式无完整性认证”；新导出绝不写 v1。
- v2 拒绝符号链接、硬链接、设备文件、FIFO、绝对路径和 `..`；超限成员在解压前拒绝。

这不是自创分组密码，而是标准 encrypt-then-MAC 结构；AES 原语仍交给 OpenSSL。若维护者不接受自定义 envelope，替代方案是要求并签名 `cryptography` 依赖，但会显著增加安装面，**不是本方案默认路径**。

#### 决策 C：root 看门狗使用“管理员授权时物化的目标副本”

继续把 `env.json` 作为用户配置源，但不让 root 每次直接采纳用户可写文件：

- `fix` / `set-region` 在同一次管理员授权中，把已验证的 IANA 时区写入 root 所有的 `/Library/Application Support/claude-switcher/tz-target`。
- 看门狗优先读该 root 文件；缺失时使用安装时烧入的兜底目标，不回读用户可写 `env.json`。
- 核心检查“当前系统时区、env 目标、root 看门狗目标”三者一致。
- 无效 IANA 时区在写 root 文件前拒绝，不执行 `systemsetup`。

理由：用户修改 env 是正常配置能力，但不应间接获得无需新授权的 root 时区修改能力。该决策会同步修改 AGENTS.md 中“巡检直接读 env”的旧约定。

#### 决策 D：账号切换采用可恢复事务，不追求跨文件系统原子性

桌面版目录、`~/.claude/`、`~/.claude.json` 和 `current` 位于不同位置，无法靠一次 rename 原子提交。方案采用：

1. 预检和准备阶段不改实时状态。
2. 操作前写 0600 事务日志，记录固定前缀下的备份/目标路径和旧 `current`。
3. 每一步先保留旧状态，再提交新状态。
4. 任何已知失败立即按日志逆序恢复。
5. 进程在提交中崩溃时，下次切换先恢复未完成事务；绝不盲目删除无法证明归属的目录。
6. 只有 Claude 已启动且租约已撤销后才清理事务备份。

代价是增加一个事务日志和少量暂存空间；收益是避免“桌面版已换 B、CLI 仍是 A”的登录态混用。

### 0.3 不在本方案内

- PF anchor / 系统级断网防火墙：需要单独真机验证和卸载设计。
- 更新独立签名与密钥轮换：需要密钥管理决策。
- Windows/Linux 防护能力补齐：按平台矩阵另立方案。
- 纯净度评分模型调整：当前问题不在评分口径。
- 新增第 17 项检查、改 16 个稳定 ID、改账号存档目录结构。

---

## 1. 执行纪律

每个任务严格执行 TDD：

1. 写失败测试。
2. 运行该测试，确认因目标缺陷失败，而不是夹具错误。
3. 写最小实现。
4. 运行聚焦测试和相邻回归。
5. 审查 diff，确认没有环境值、凭据或真实状态进入产物。
6. 若改了 `core/`、`daemons/`、`installer/`，运行 `bash scripts/gen-sums.sh`。
7. 提交一个小任务；不要在单提交里混入 P0、P1、P2。

通用命令：

```bash
cd "/Users/oursleo/本地开发/claude-switcher"
python3 -B -m unittest discover -s tests -p 'test_self_update.py' -v
python3 -B -m unittest discover -s tests -p 'test_snapshot_*.py' -v
python3 -B -m unittest discover -s tests -p 'test_menu_bar_model.py' -v
bash -n core/claude-switch.sh
shasum -a 256 -c SHA256SUMS
```

完整阶段门禁见第 3 节。不要用真实 `$HOME` 运行会写状态的 `checkdetail`、`fix`、`switch` 或 `update`。

---

## 2. 分阶段实施任务

## 阶段 P0：先堵住自动更新入口

### Task 1：远程清单严格校验 + 新核心语法预检

**Files:**

- Modify: `core/claude-switch.sh:self_update()`，当前约 5892–5906
- Test: `tests/test_self_update.py`
- Do not modify yet: `tests/test_app_update.py`（App 自更新是另一条链路）

**Step 1: 写失败测试**

在 `SelfUpdateTests` 中扩展 `serve_remote(content, manifest=None)`，使假 ZIP 始终含核心，清单可独立控制。新增以下用例：

```python
def test_manifest_without_core_entry_is_rejected(self):
    self.serve_remote("if then\n", manifest=["README.md"])
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
    self.assertIn("core/claude-switch.sh", run.stdout + run.stderr)
    self.assertEqual(self.bin.read_text(encoding="utf-8"),
                     SCRIPT.read_text(encoding="utf-8"))

def test_invalid_remote_syntax_never_replaces_local_core(self):
    self.serve_remote("if then\n")
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
    self.assertIn("语法", run.stdout + run.stderr)
    self.assertEqual(self.bin.read_text(encoding="utf-8"),
                     SCRIPT.read_text(encoding="utf-8"))

def test_manifest_rejects_parent_path(self):
    outside = self.root / "outside"
    outside.write_text("not-a-release-file", encoding="utf-8")
    digest = hashlib.sha256(outside.read_bytes()).hexdigest()
    self.sums_path.write_text(
        f"{digest}  ../outside\n"
        f"{hashlib.sha256(b'if then\\n').hexdigest()}  core/claude-switch.sh\n",
        encoding="utf-8")
    self.serve_remote("if then\n", manifest=False)
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
    self.assertIn("清单", run.stdout + run.stderr)

def test_manifest_rejects_duplicate_and_malformed_entries(self):
    self.serve_remote(SCRIPT.read_text(encoding="utf-8") + "\n# remote\n")
    core_digest = hashlib.sha256(
        (SCRIPT.read_text(encoding="utf-8") + "\n# remote\n").encode()).hexdigest()
    self.sums_path.write_text(
        f"{core_digest}  core/claude-switch.sh\n"
        f"{core_digest}  core/claude-switch.sh\n"
        "not-a-digest  README.md\n", encoding="utf-8")
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
```

`manifest=False` 表示测试自己写清单，不再由 helper 覆盖。

**Step 2: 确认失败**

```bash
python3 -B -m unittest discover -s tests -p 'test_self_update.py' -v
```

当前至少“缺核心条目”“非法语法”“父路径”用例失败；坏核心会被安装。

**Step 3: 最小实现**

在 `self_update()` 内用受信旧核心调用的内嵌 Python 校验清单，不要执行下载包里的辅助脚本：

```python
import hashlib, os, re, stat, sys
from pathlib import Path

manifest = Path(sys.argv[1])
root = Path(sys.argv[2]).resolve()
required = "core/claude-switch.sh"
seen = set()
entries = []
for number, raw in enumerate(manifest.read_text(encoding="utf-8").splitlines(), 1):
    if not raw or raw.startswith("#"):
        continue
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", raw)
    if not match:
        raise SystemExit(f"清单第 {number} 行格式无效")
    digest, rel = match.groups()
    parts = Path(rel).parts
    if (not rel or Path(rel).is_absolute() or rel in seen
            or any(part in ("", ".", "..") for part in parts)):
        raise SystemExit(f"清单路径无效或重复: {rel}")
    seen.add(rel)
    target = root.joinpath(*parts)
    cursor = root
    for part in parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise SystemExit(f"清单路径不得经过符号链接: {rel}")
    if not target.is_file() or not stat.S_ISREG(target.lstat().st_mode):
        raise SystemExit(f"清单工件缺失: {rel}")
    actual = hashlib.sha256(target.read_bytes()).hexdigest()
    if actual != digest:
        raise SystemExit(f"工件校验失败: {rel}")
    entries.append(rel)
if required not in seen:
    raise SystemExit("清单缺少 core/claude-switch.sh")
print(next(digest for digest, rel in entries if rel == required))
```

Bash 侧捕获该 Python 的非零退出并中止，把成功的单行输出保存为 `remote_core_sha`；随后、在任何 `cp`/`mv` 之前执行：

```bash
"${BASH:-/bin/bash}" -n "$NEW/core/claude-switch.sh" || {
    echo "FAIL:远程核心脚本语法检查失败,已中止"
    rm -rf "$tmpd"
    return 1
}
```

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_self_update.py' -v
bash -n core/claude-switch.sh
```

Expected：新增用例通过；原有 `update-hold`、手动更新、回归对比测试仍通过。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_self_update.py SHA256SUMS
git commit -m "fix(update): 强制核心清单与语法预检,阻断损坏核心安装"
```

**回滚：** 单独 revert 该提交即可；它尚未改变已安装核心的替换语义。

---

### Task 2：同目录候选文件、原子替换与可验证回滚

**Files:**

- Modify: `core/claude-switch.sh:self_update()`，当前约 5944–5955、5987–5989、6012–6014
- Test: `tests/test_self_update.py`

**Step 1: 写失败测试**

新增 PATH 桩，只在目标路径精确匹配时让 `cp` 或 `mv` 失败，避免误伤假 ZIP 夹具：

```python
def test_candidate_copy_failure_keeps_old_core(self):
    fail_cp = self.fakebin / "cp"
    fail_cp.write_text("""#!/bin/bash
for arg in "$@"; do
  case "$arg" in *claude-switch.sh.new.*) exit 41 ;; esac
done
exec /bin/cp "$@"
""", encoding="utf-8")
    fail_cp.chmod(0o755)
    self.serve_remote(SCRIPT.read_text(encoding="utf-8") + "\n# remote\n")
    before = self.bin.read_bytes()
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
    self.assertEqual(self.bin.read_bytes(), before)

def test_atomic_rename_failure_keeps_old_core(self):
    fail_mv = self.fakebin / "mv"
    fail_mv.write_text("""#!/bin/bash
case "$1" in *claude-switch.sh.new.*) exit 42 ;; esac
exec /bin/mv "$@"
""", encoding="utf-8")
    fail_mv.chmod(0o755)
    self.serve_remote(SCRIPT.read_text(encoding="utf-8") + "\n# remote\n")
    before = self.bin.read_bytes()
    run = self.run_update()
    self.assertNotEqual(run.returncode, 0)
    self.assertEqual(self.bin.read_bytes(), before)
    self.assertFalse(list(self.bin.parent.glob("claude-switch.sh.new.*")))
```

同时保留 Task 3 会加强的“自检失败恢复旧字节”测试。

**Step 2: 确认失败**

当前实现直接 `cp` 到正式路径，注入失败后仍可能继续执行并返回成功。运行 `test_self_update.py`，确认至少一个新增用例失败。

**Step 3: 最小实现**

定义更新专用辅助函数或收紧 `self_update()` 内联实现：

```bash
candidate="$BIN/.claude-switch.sh.new.$$"
rollback="$BIN/.claude-switch.sh.rollback.$$"
old_sha=""
installed=0
cleanup_update_files() {
    rm -f "$candidate" "$rollback"
}

if [ -f "$BIN/claude-switch.sh" ]; then
    old_sha=$(shasum -a 256 "$BIN/claude-switch.sh" | awk '{print $1}')
    cp -p "$BIN/claude-switch.sh" "$BIN/claude-switch.sh.bak" || return 1
    cp -p "$BIN/claude-switch.sh" "$rollback" || return 1
fi
cp "$NEW/core/claude-switch.sh" "$candidate" || return 1
chmod +x "$candidate" || return 1
"${BASH:-/bin/bash}" -n "$candidate" || return 1
[ "$(shasum -a 256 "$candidate" | awk '{print $1}')" = "$remote_core_sha" ] || return 1
mv -f "$candidate" "$BIN/claude-switch.sh" || return 1
installed=1

rollback_core() {
    local reason="$1"
    if [ "$installed" -eq 1 ] && [ -f "$rollback" ]; then
        mv -f "$rollback" "$BIN/claude-switch.sh" || return 1
        installed=0
    fi
    "${BASH:-/bin/bash}" -n "$BIN/claude-switch.sh" || return 1
    [ "$(shasum -a 256 "$BIN/claude-switch.sh" | awk '{print $1}')" = "$old_sha" ] || return 1
    printf '%s|core|%s\n' "$(date '+%F %T')" "$reason" > "$BASE/update-rollback.txt"
    chmod 600 "$BASE/update-rollback.txt"
}
```

要求：

- 候选与回滚文件必须位于 `$BIN`，保证 rename 不跨文件系统。
- `mv -f` 是唯一覆盖正式核心的动作。
- 所有早退点显式调用 `cleanup_update_files`，不要设置可能泄漏到调用方的 `RETURN` trap。
- 写入前确认 `.bak`、candidate、rollback 均不是符号链接；不跟随用户目录中的意外链接。
- `rollback_core` 自身失败时输出 `FAIL:回滚未完成,旧核心备份保留在 ...`，不得打印“已自动回滚”。
- 验证回滚后 SHA 等于更新前 SHA；只恢复文件存在不算回滚成功。

**Step 4: 验证**
```bash
python3 -B -m unittest discover -s tests -p 'test_self_update.py' -v
```

Expected：复制/rename 注入失败均保留旧核心字节、非零退出、无残留候选文件。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_self_update.py SHA256SUMS
git commit -m "fix(update): 核心候选同目录原子换装并验证回滚哈希"
```

**回滚：** revert 提交；不要用旧 `.bak` 覆盖开发仓库。

---

### Task 3：结构化自检、完整 16 项契约与 ok→config 回滚

**Files:**

- Modify: `core/claude-switch.sh` 的 `PY_SUPPORT` 和 `self_update()`
- Test: `tests/test_self_update.py`
- Test: `tests/test_update_report_contract.py`

**Step 1: 写失败测试**

先把现有 `inject_checkdetail()` 升级为同时支持文本与 JSON 的桩。JSON 桩应使用真实 `_support report` 从固定 16 行生成报告，使指纹对应当前候选核心，而不是手写一个永远合法的假对象。

新增用例：

```python
def test_nonzero_self_check_rolls_back_even_with_valid_json(self):
    # 新核心输出合法报告后 return 7；当前实现会忽略退出码。

def test_partial_json_report_rolls_back(self):
    # 新核心只输出 15 项，缺少 DNS泄露；其余环境状态全部 ok。

def test_ok_to_config_is_regression(self):
    # 基线：地区=ok；新核心：地区=config。

def test_preexisting_config_does_not_block_update(self):
    # 基线：地区=config；新核心：地区=config，更新成功。

def test_duplicate_or_wrong_fingerprint_rolls_back(self):
    # 合法 JSON 结构但 summary.duplicates 非空，或 config_fingerprint 被改。
```

**Step 2: 确认失败**

当前自检读取文本，不调用 `--json`，上述契约测试应失败。`ok → config` 当前不会进入回归列表。

**Step 3: 最小实现**

在 `PY_SUPPORT` 增加两个内部动作，不进入公开 help：

1. `validate-update-report <report.json> <core_path>`：
   - 必须是对象，`schema == claude-switcher-report/2`、`protocol == 2`。
   - `checks` 是列表；ID 唯一；16 个 `CHECK_SPECS` ID 全部存在。
   - 每项 `state` 属于五态，`critical` 与核心规格一致。
   - `summary.duplicates`、`summary.missing_critical` 为空。
   - 重算 blockers、advisories、skipped、missing 和各项计数，与 summary 一致。
   - `verdict` 与重算结果一致；环境 violated 可以保留，契约不完整不行。
   - `config_fingerprint`、`core_sha256` 必须对应当前核心、env 和 checks 配置。
   - `expires_at` 可解析且未过期。
2. `update-regression <baseline.txt> <report.json> <core_path>`：
   - 先调用同一报告校验。
   - 基线文本用 `parse_report_checks()` 解析。
   - 返回 `REGRESSED=<names>`、`NEW_FAILS=<names>`，或非零结构化错误。
   - 只有基线明确 `ok`、新报告为 `fail/config` 才计入 `REGRESSED`。
   - 基线缺失时不把“缺项”猜成 ok；无法取得可信基线时保守回滚，并明确原因。

`self_update()` 改为：

```bash
selfcheck_stdout="$tmpd/new-report.json"
selfcheck_stderr="$tmpd/new-check.err"
if ! "$BIN/claude-switch.sh" checkdetail --json \
    >"$selfcheck_stdout" 2>"$selfcheck_stderr"; then
    rollback_core "新版自检退出码非零" || return 1
    echo "FAIL:新版自检退出码非零,已自动回滚"
    return 1
fi
if ! support validate-update-report "$selfcheck_stdout" "$BIN/claude-switch.sh"; then
    rollback_core "新版自检报告契约无效" || return 1
    echo "FAIL:新版自检报告契约无效,已自动回滚"
    return 1
fi
```

注意：当前实现会在自检前 `rm -rf "$tmpd"`，Task 2/3 必须把临时目录生命周期延长到自检与回滚记录完成，或用 `$BASE` 下专用临时文件。不得把报告 stdout 混入 stderr 进度行后再当纯 JSON 解析；用单独文件接收 stdout，stderr 仅作诊断。

`env-migrate` 失败从 WARN 升级为回滚原因：迁移失败会让新核心在错误环境上运行，不能继续提交成功。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_self_update.py' -v
python3 -B -m unittest discover -s tests -p 'test_update_report_contract.py' -v
python3 -B -m unittest discover -s tests -p 'test_fail_closed.py' -v
```

Expected：环境旧 fail/config 不阻断；核心契约错误、非零自检和 `ok → config` 均恢复旧 SHA。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_self_update.py tests/test_update_report_contract.py SHA256SUMS
git commit -m "fix(update): 自检强制报告契约并覆盖配置退化回滚"
```

**回滚：** revert；保留旧更新器仍可读取文本基线。

---

### Task 4：租约前移 + 桌面/CLI/current 可恢复切换事务

**Files:**

- Modify: `core/claude-switch.sh:switch_to()`，当前约 7380
- Modify: `core/claude-switch.sh:restore_cli()`，当前约 7238
- Test: `tests/test_snapshot_safety.py`
- Test: `tests/test_cli_slot.py`

**Step 1: 写失败测试**

在 `test_snapshot_safety.py` 的抽取式夹具中补齐 `CLI_DIR`、`CLI_JSON`、`CLI_BASE`、`require_lease_for_launch`、`restore_cli`、`claude_cli_running`、`restore_keep_paths` 等依赖。

新增关键用例：

```python
def test_invalid_lease_prevents_archive_and_all_live_changes(self):
    # require_lease_for_launch 返回 1；断言 quit_claude、archive_current、
    # archive_cli 都未调用，DATA/CLI/current 均保持原样。

def test_first_capture_cli_failure_restores_desktop_live_state(self):
    # 首次收编桌面成功、archive_cli 失败；恢复桌面 live-A 和 current=none。

def test_cli_json_move_failure_restores_desktop_cli_and_current(self):
    # 已切到 B 的桌面目录和 ~/.claude 已就位，~/.claude.json 移动失败。
    # 最终 DATA=live-A、CLI home=A、CLI json=A、current=A、未启动 Claude。

def test_current_write_failure_restores_all_live_state(self):
    # 用只读目录或桩函数让 current 写入失败。

def test_open_failure_restores_all_live_state(self):
    # open 返回非零；不得留下 B 的数据却显示切换失败。

def test_existing_switch_journal_is_never_deleted_blindly(self):
    # 预置损坏/陌生 journal；切换拒绝并保留，不猜测路径删除。
```

在 `test_cli_slot.py` 增加：

```python
def test_restore_rolls_back_when_home_json_move_fails(self):
    # 旧 ~/.claude 和 ~/.claude.json 均有 marker；第二段 mv 失败后逐字节恢复。
```

**Step 2: 确认失败**

当前租约检查在最后；CLI 第二段 `mv` 失败后现场已被清空。运行两个测试文件，确认上述用例失败。

**Step 3: 最小实现**

采用以下顺序，不改变存档布局：

1. 校验槽位、CLI 未运行。若存在未完成事务，先验证并恢复；无法安全恢复则拒绝新切换。恢复旧事务属于止损，不要求新的启动租约。
2. **在退出 Claude、任何 archive、stage、live move 之前调用 `require_lease_for_launch`。** 租约无效时连正在使用的 Claude 都不退出。
3. 完全退出桌面 Claude。
4. 在 `$BASE/switch-txn.json` 写 0600 初始 journal，内容包括随机 transaction ID、旧 current、`cur=none` 标志、固定根目录、源存档路径、实时路径、事务备份路径和各步骤状态。日志路径全部限制在 `$BASE` 和已知实时路径下；journal 本身用同目录临时文件 + rename 原子更新。
5. 首次收编或归档当前账号，准备 keep-stage；保留现有 `.new` / `.previous` 拒绝覆盖语义。每次移动前更新 journal。首次 `archive_cli` 失败时也必须把已收编的桌面状态放回实时位置，不能只删 keep-stage。
6. 目标桌面状态复制到 `$DATA.new`；目标 CLI 状态复制到 `$CLI_BASE/$target.new`；把 keep-stage 合并进 `$DATA.new`，不是实时 `$DATA`。任一步失败，实时状态仍保持旧账号。
7. 归档若已把实时状态移走，恢复源是 journal 指向的旧账号/CLI 存档；若仍有实时残留，先移到事务备份。恢复函数不得假设“实时目录一定还在”。
8. 移入目标桌面和 CLI 状态；`current` 用同目录临时文件 + rename 提交。
9. 再次确认租约仍有效，`open -a Claude`；成功后才撤销租约。`open` 返回非零按提交失败处理。
10. 标记事务完成并清理本次创建的备份。清理失败只告警并保留 0700 暂存，不把已成功的切换改报失败。

恢复函数必须：

- 按 journal 逆序恢复；旧实时目录不存在时，从旧账号/CLI 存档复制恢复；
- 恢复前验证 transaction ID 和每个路径的父目录，拒绝符号链接；
- 不删除不在 journal 中的 `.new` / `.previous`；
- 恢复后校验 `current`、桌面 marker、CLI 两个 marker；
- 无法恢复时保留全部现场并输出可供人工处理的精确路径。

`restore_cli()` 本身也改为“先完整 staged，再备份实时两段，再逐段移入，失败整体恢复”，这样同账号修复路径也安全。`restore_keep_paths()` 增加显式目标目录参数，默认仍为 `$DATA`，事务路径传入 `$DATA.new`。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_snapshot_safety.py' -v
python3 -B -m unittest discover -s tests -p 'test_cli_slot.py' -v
python3 -B -m unittest discover -s tests -p 'test_lease.py' -v
```

Expected：每个注入失败点都恢复旧账号三处状态；成功路径仍隔离 B 的 CLI；无租约时零归档、零实时变更。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_snapshot_safety.py tests/test_cli_slot.py SHA256SUMS
git commit -m "fix(switch): 租约前移并让桌面与CLI状态可恢复事务切换"
```

**回滚：** 代码 revert 不影响已提交账号存档；未完成事务必须先用新恢复逻辑处理，不能直接删 journal 或备份。

---

### Task 5：E–H 快照导入与完整槽位枚举

**Files:**

- Modify: `core/claude-switch.sh:snapshot_import()` 的 marker 校验，当前约 6847
- Modify: `core/claude-switch.sh:slot_node_list()`，当前约 5305
- Test: `tests/test_snapshot_transfer.py`
- Test: `tests/test_cli_slot.py:SlotNodeBindingTests`

**Step 1: 写失败测试**

```python
def test_boundary_slots_e_and_h_round_trip(self):
    for target in ("E", "H"):
        with self.subTest(target=target):
            slot = self.home / ".claude-switcher" / "accounts" / target
            slot.mkdir()
            (slot / "marker.txt").write_text(target, encoding="utf-8")
            image = self.root / f"account-{target}.dmg"
            self.assertEqual(self.export(target, image).returncode, 0)
            shutil.rmtree(slot)
            result = self.import_into(target, image)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((slot / "marker.txt").read_text(), target)
```

绑定枚举新增：

```python
def test_list_includes_e_through_h(self):
    for slot in ("E", "F", "G", "H"):
        self.shell(f'slot_node_set {slot} "节点-{slot}" >/dev/null')
    listed = self.shell("slot_node_list").stdout.strip().splitlines()
    self.assertEqual([line.split("\t")[0] for line in listed],
                     ["E", "F", "G", "H"])
```

**Step 2: 确认失败**

E/H 导入在 marker 校验失败；列表缺 E–H。

**Step 3: 最小实现**

- marker 校验改为 `assert meta.get("account") in tuple("ABCDEFGH")`，并继续要求与目标槽位一致。
- `slot_node_list()` 使用已有 `slots()`；抽取式测试要把 `slots` 一起载入，避免 `set -u` 缺函数。
- 不改 marker version，不改变账号目录结构。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_snapshot_transfer.py' -v
python3 -B -m unittest discover -s tests -p 'test_cli_slot.py' -v
```

Expected：A、E、H 边界均可往返；A–H 枚举顺序稳定。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_snapshot_transfer.py tests/test_cli_slot.py SHA256SUMS
git commit -m "fix(snapshot): 补齐E-H导入与槽位节点枚举"
```

**回滚：** revert；E–H 已导入数据仍保持标准目录结构，不会丢失。

---

### Task 6：节点应用重新过扫描硬门槛

**Files:**

- Modify: `core/claude-switch.sh:scan_nodes()`，当前约 4909
- Modify: `core/claude-switch.sh:node_apply()`，当前约 5185
- Test: 新增 `tests/test_node_apply_gate.py`，复用现有节点扫描夹具

**Step 1: 写失败测试**

为 selector/leaf、入口类型、分数、判定、国家、UDP、WebRTC 策略建立纯函数或抽取式夹具：

```python
def test_explicit_leaf_rejected_when_scan_says_tor_or_proxy(self):
    # 同一 leaf 在 /proxies 中仍存在，但扫描结论为 fail。

def test_explicit_leaf_rejected_when_country_mismatches(self):
    # 扫描 cc=JP，env country=US。

def test_explicit_leaf_rejected_when_fronted_or_unrated(self):
    # egress=fronted；以及 score 为空的合法未评级结论。

def test_udp_gate_follows_reject_policy(self):
    # proxy 策略拒绝 udp=0；reject 策略不因 UDP 未标注拒绝。

def test_stale_scan_cannot_authorize_explicit_leaf(self):
    # EPOCH 超过 NODE_SCAN_TTL；应用前必须重扫或拒绝。

def test_post_switch_country_failure_restores_previous_leaf(self):
    # 切换成功但目标国家不符，必须恢复原 leaf 并返回失败。
```

**Step 2: 确认失败**

当前显式 leaf 只检查成员关系和切后国家，Tor/代理、UDP、未评级、CDN 前置等用例会失败。

**Step 3: 最小实现**

1. 把扫描中的资格判定提取为单一函数，例如：

```bash
node_candidate_gate() {
    # 参数：egress score verdict cc udp webRtcPolicy countryTarget
    # stdout：ok 或具体排除原因；不得复制第二套阈值。
}
```

2. `scan_nodes()` 与 `node_apply()` 都调用该函数。
3. 扫描报告增加机器可读的候选行，例如 `CANDIDATE<TAB>selector<TAB>leaf<TAB>eligible<TAB>reason`；控制字符节点名在枚举边界拒绝，避免破坏 TSV。
4. 显式 `node-apply <leaf>` 先通过实时 report-only 门禁，再执行只读扫描（`NODE_SCAN_QUIET=1`），从本次报告精确匹配 selector + leaf；报告过期则重扫，扫描失败则拒绝应用。扫描可能耗时，因此在 PUT 前必须再次调用执行门禁，不能沿用扫描前的允许结论。
5. 无参应用仍只使用本次 `BEST`，且同样校验候选资格。
6. 切换后保留实时国家复核和节点回滚；任何复核失败都恢复切换前 leaf。
7. `slot-node set` 只接受本次报告中 `eligible=1` 的叶子；已有绑定在目标变化后也必须重新过门禁。

不得为了获得候选 IP 而逐个在线切节点；仍只使用枚举元数据、纯度缓存和既有报告。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_node_apply_gate.py' -v
python3 -B -m unittest discover -s tests -p 'test_node_scan.py' -v
python3 -B -m unittest discover -s tests -p 'test_cli_slot.py' -v
```

Expected：推荐路径和显式绑定走同一资格函数；所有硬门槛排除项都不能被显式 leaf 绕过。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_node_apply_gate.py SHA256SUMS
git commit -m "fix(node): 显式节点应用重新校验扫描硬门槛"
```

**回滚：** revert；不回滚用户已绑定的节点文件。

---

### Task 7：watch 代际隔离

**Files:**

- Modify: `app/main.swift:startWatch()` / `stopWatch()`，当前约 963 / 1070
- Test: `tests/MenuBarModelTests.swift`
- Test: `tests/test_menu_bar_model.py` 的 `SCENARIOS`

**Step 1: 写失败测试**

在 Swift 假核心夹具中增加“可控完成”能力：旧 watch 进程延迟回调，新 watch 已启动后再释放旧回调。

新增场景：

```python
"watch_stale_completion_cannot_clear_new_guard",
"watch_stale_line_cannot_fail_new_guard",
"watch_stale_completion_cannot_restart_after_quit",
```

核心断言：

- 旧完成回调后，新 watch 仍 `watchActive=true`、`guarding=true`、`phase=.ready`。
- 旧 `STOP` 行不得把新一代标记为 intercepted。
- 已退出 App 时旧回调不得重新设置 phase 或启动 watch。

**Step 2: 确认失败**

当前共享 `watchStopping` 会被新 `startWatch()` 重置，旧回调可清状态或进入失败分支。运行 `test_menu_bar_model.py`，确认新场景失败。

**Step 3: 最小实现**

- 增加单调递增 `watchGeneration`。
- 每次 `startWatch()` 和 `stopWatch()` 都使其递增。
- `startWatch()` 捕获本次 generation；`onLine`、`onStart`、完成回调第一行检查：

```swift
guard self.watchGeneration == generation else { return }
```

- 完成回调只有当代才清 `watchProcess`、`watchActive`、`guarding`。
- 删除跨代共享的 `watchStopping` 作为正确性依据；代际不匹配直接 no-op。
- 不把 `Process` 对象身份当唯一判据，测试和真实回调都可能晚到。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_menu_bar_model.py' -v
swiftc -O -parse-as-library -warnings-as-errors \
  -target "$(uname -m)-apple-macos13.0" app/main.swift \
  -o /tmp/ClaudeSwitcher -framework SwiftUI -framework AppKit
```

Expected：原 watch 五场景和新竞态场景全过；严格编译无警告。

**Step 5: 提交**

```bash
git add app/main.swift tests/MenuBarModelTests.swift tests/test_menu_bar_model.py
git commit -m "fix(ui): 隔离看门狗重启后的陈旧回调"
```

**回滚：** revert；不涉及核心哈希。

---

## 阶段 P2：快照、权限边界与发布维护

### Task 8：快照 v2 认证 + 解压前成员预检

**Files:**

- Modify: `core/claude-switch.sh` 的 `_snapshot_archive_write()`、`_snapshot_archive_check()`、`snapshot_export()`、`snapshot_import()`
- Test: `tests/test_snapshot_transfer.py`
- Test: `tests/test_snapshot_safety.py`

**Step 1: 写失败测试**

新增不依赖 DiskImages 的纯归档测试，直接调用 v2 写入/校验辅助函数：

```python
def test_v2_tampered_ciphertext_is_rejected(self):
    # 翻转一个密文字节后导入，校验失败且不创建 accounts/target。

def test_v2_truncated_archive_is_rejected(self):
    # 截掉尾部；不得解压或创建快照。

def test_v2_wrong_password_is_rejected(self):
    # 已有 v1 用例保留，v2 同样验证。

def test_archive_symlink_member_is_rejected_before_extraction(self):
    # tar 中放 ../outside 链接；断言链接和外部文件都未出现。

def test_archive_parent_or_absolute_member_is_rejected(self):
    # 分别覆盖 ../x、/absolute/x。

def test_legacy_v1_imports_with_explicit_unauthenticated_warning(self):
    # 保持迁移能力，但 stdout/stderr 明确旧格式无完整性认证。
```

**Step 2: 确认失败**

当前 v1 无 MAC，翻转密文可能造成解压失败，但没有“先认证再解压”的契约；链接成员可进入临时目录。运行聚焦测试确认失败。

**Step 3: 最小实现**

- 新写入使用第 0.2 节决策 B 的 v2 envelope。
- 密码只通过继承 fd 传给 OpenSSL/Python；临时文件权限 0600，结束后立即删除。
- v2 读取顺序固定：**读 header → 验证长度和版本 → 认证整个 envelope → 解密 → tar 成员预检 → 解压**。
- tar 预检使用 `tarfile` 遍历元数据，不 extract：

```python
for member in archive.getmembers():
    path = PurePosixPath(member.name)
    if path.is_absolute() or ".." in path.parts:
        raise ValueError("unsafe archive path")
    if member.issym() or member.islnk() or member.isdev() or member.isfifo():
        raise ValueError("unsupported archive member")
    if not (member.isfile() or member.isdir()):
        raise ValueError("unsupported archive member")
```

- 解压后再次确认没有符号链接，marker 是普通文件且小于 64 KiB，再校验 A–H。
- DMG 路径也必须在 `ditto` 前拒绝符号链接；不能只加固兼容归档。
- v1 不重写成“认证格式”；只在成功校验旧 marker 后给出一次迁移提示，建议在源机器重新导出。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_snapshot_transfer.py' -v
python3 -B -m unittest discover -s tests -p 'test_snapshot_safety.py' -v
```

Expected：篡改、截断、错误密码、链接/路径成员均在写账号目录前失败；A/E/H 正常快照仍可导入。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh tests/test_snapshot_transfer.py tests/test_snapshot_safety.py SHA256SUMS
git commit -m "fix(snapshot): 新归档认证加密并在解压前拒绝危险成员"
```

**回滚：** revert 后仍可读取 v1；已生成 v2 需保留新版导入器，因此发布前不得回退到不认 v2 的版本。

---

### Task 9：安装器 root 命令参数化 + 看门狗授权目标副本

**Files:**

- Modify: `installer/安装.command`，当前约 479–507
- Modify: `daemons/tz-watchdog.sh`
- Modify: `core/claude-switch.sh` 的 `fix` / `set-region` 管理员命令和时区巡检比较
- Test: `tests/test_daemon_contracts.py`
- Test: `tests/test_tz_watchdog.py`
- Docs: `AGENTS.md` 的时区巡检约定

**Step 1: 写失败测试**

- 抽取安装器 root heredoc，在临时 STAGE 路径和时区参数中加入单引号/空格，用假 `install`、`launchctl`、`systemsetup` 执行；断言参数保持完整，不触发额外命令。
- 静态断言安装器不再有 `sudo bash -c "$SYSCMDS"`。
- 看门狗测试：root 目标有效时使用它；用户 env 被改成另一个有效 IANA 时区时，看门狗不得跟随；root 目标为空/损坏时使用安全兜底并记录，不执行非法值。

**Step 2: 确认失败**

当前路径进入 `bash -c` 字符串；看门狗直接读 env。聚焦运行后确认失败。

**Step 3: 最小实现**

安装器使用静态 heredoc + 位置参数：

```bash
sudo /bin/bash -s -- "$STAGE" "$LOG_DIR" "$TZV" "$TARGET_HOME" <<'ROOT_INSTALL'
set -euo pipefail
stage=$1
log_dir=$2
tz=$3
target_home=$4
appdir="/Library/Application Support/claude-switcher"
install -d -o root -g wheel -m 755 "$appdir" "$log_dir"
install -o root -g wheel -m 755 \
    "$stage/claude-bodyguard.sh" "$stage/tz-watchdog.sh" "$appdir/"
printf '%s\n' "$tz" > "$appdir/tz-target"
chown root:wheel "$appdir/tz-target"
chmod 644 "$appdir/tz-target"
/usr/sbin/systemsetup -settimezone "$tz"
ROOT_INSTALL
```

实际实现继续保留原有 plist 注册与守护物化，只把所有动态值改为 `$1...$n`，不在 root 脚本中拼接 shell 源码。root 侧验证时区为 IANA 形式且对应 zoneinfo 文件存在；`stage` 不得经过符号链接。

看门狗：

- `TARGET_FILE="/Library/Application Support/claude-switcher/tz-target"`。
- 只读 root 文件；读取值必须匹配 `^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$` 且 `/usr/share/zoneinfo/$TARGET` 存在。
- 不再读取 `__HOME__/.claude-switcher/env.json` 作为 root 执行目标。
- `fix` / `set-region` 的 `adminCmds` 在同一次 sudo 中原子写 `tz-target` 并设置系统时区。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_daemon_contracts.py' -v
python3 -B -m unittest discover -s tests -p 'test_tz_watchdog.py' -v
bash -n "installer/安装.command"
bash -n daemons/tz-watchdog.sh
```

Expected：特殊字符路径不被解释为命令；看门狗目标只能由管理员授权路径改变。

**Step 5: 提交**

```bash
bash scripts/gen-sums.sh
git add core/claude-switch.sh daemons/tz-watchdog.sh "installer/安装.command" \
  tests/test_daemon_contracts.py tests/test_tz_watchdog.py AGENTS.md SHA256SUMS
git commit -m "fix(install): root命令参数化并收紧时区巡检授权边界"
```

**回滚：** 安装器/守护代码可 revert；已安装旧看门狗仍需用户明确授权后重跑安装器刷新，不得由 Agent 私自部署。

---

### Task 10：tag 完整测试门禁 + 工件清单覆盖

**Files:**

- Modify: `.github/workflows/checks.yml`
- Modify: `.github/workflows/release.yml`
- Modify: `scripts/gen-sums.sh`
- Modify: `scripts/package-macos.sh` 的 kit 必备清单（如新增清单项）
- Test: 新增 `tests/test_release_workflow.py`

**Step 1: 写失败测试**

```python
def test_release_reuses_full_checks_workflow(self):
    release = (ROOT / ".github/workflows/release.yml").read_text()
    self.assertIn("uses: ./.github/workflows/checks.yml", release)

def test_checks_workflow_is_reusable(self):
    checks = (ROOT / ".github/workflows/checks.yml").read_text()
    self.assertIn("workflow_call:", checks)

def test_sums_cover_runtime_payload(self):
    paths = {line.split("  ", 1)[1] for line in
             (ROOT / "SHA256SUMS").read_text().splitlines() if "  " in line}
    for required in (
        "core/stun-probe.py", "scripts/upgrade-core.sh",
        "scripts/diagnose-fix.sh", "scripts/diagnose-install.sh",
    ):
        self.assertIn(required, paths)
```

**Step 2: 确认失败**

release 当前不调用完整 checks；清单缺 STUN 探针。

**Step 3: 最小实现**

- `checks.yml` 增加 `workflow_call:`，保留现有 PR/main/manual 触发。
- release 的 Build and publish job 增加 `needs: test`，`test` job 使用 `uses: ./.github/workflows/checks.yml`。
- 打包与发布只在完整 macOS Python/Swift/语法/哈希/JS 和 Windows 双壳集成全部成功后开始。
- `gen-sums.sh` 至少加入 `core/stun-probe.py`；同时审计 installer-kit 的运行时脚本，把 `scripts/upgrade-core.sh`、`scripts/diagnose-fix.sh`、`scripts/diagnose-install.sh` 一并纳入完整性清单。三项已经随 kit 分发，不能只校验核心而漏掉可执行修复/诊断入口。若新增清单项，必须同步假 ZIP 夹具和 kit 校验。
- 清单格式沿用 Task 1 的严格解析，不允许注释行被误当工件。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_release_workflow.py' -v
bash scripts/gen-sums.sh
shasum -a 256 -c SHA256SUMS
bash scripts/package-macos.sh 0.0.0-test
```

打包只生成 `build/` 产物，不安装、不发布。Expected：kit/full 包内清单校验通过。

**Step 5: 提交**

```bash
git add .github/workflows/checks.yml .github/workflows/release.yml \
  scripts/gen-sums.sh scripts/package-macos.sh tests/test_release_workflow.py \
  tests/test_self_update.py SHA256SUMS
git commit -m "ci(release): tag发布前复用完整跨平台测试门禁"
```

**回滚：** revert；不得为了发版绕过失败的 workflow。

---

### Task 11：回滚提示、架构文档与测试卫生

**Files:**

- Modify: `app/main.swift:loadUpdateRollback()`，当前约 893
- Test: `tests/MenuBarModelTests.swift`、`tests/test_menu_bar_model.py`
- Modify: `ARCHITECTURE.md`
- Optional: 清理触发 ResourceWarning 的测试资源

**Step 1: 写失败测试**

增加纯解析场景：

- v1 两列记录 `时间|原因` 显示为“上次核心更新被回滚”，不武断写成“自动更新”。
- 新三列记录 `时间|core|原因` 能解析。
- 超长原因截断到有限长度，不无限撑大界面。
- 超过 64 KiB 的文件被忽略，不整份读入。
- 文案不再包含“环境修好后会自动恢复更新”。

**Step 2: 确认失败**

当前文案固定“自动更新”，且无大小上限。

**Step 3: 最小实现**

- 提示统一为：`上次核心更新被回滚：<原因>。点「检查更新」可手动重试；自动更新仍按既定策略检查`。
- 增加有界读取：普通文件、最大 64 KiB；只取最后一条完整记录。
- 解析函数独立为可测纯函数；文件读取失败清空提示。
- `ARCHITECTURE.md` 删除易腐烂的精确行数/测试数，或改为由脚本生成；把 IP 纯净度描述更新为“六个 HTTP 源 + PTR，类型证据与风险证据分开判定”。
- 对完整测试中的 SQLite/subprocess ResourceWarning，定位未关闭资源并修复；不为消除警告而在测试里 `filterwarnings=ignore`。

**Step 4: 验证**

```bash
python3 -B -m unittest discover -s tests -p 'test_menu_bar_model.py' -v
python3 -B -W default -m unittest discover -s tests -p 'test_*.py' -v
```

Expected：提示场景通过；完整回归不出现本方案负责清理的资源警告。

**Step 5: 提交**

```bash
git add app/main.swift tests/MenuBarModelTests.swift tests/test_menu_bar_model.py ARCHITECTURE.md
git commit -m "docs(ui): 修正核心回滚提示并更新架构说明"
```

**回滚：** revert；回滚痕迹文件仍保持兼容。

---

## 3. 完整验证矩阵

每个阶段完成后执行；最终发布前再完整执行一次。

| 验证 | 命令 | 成功标准 |
|---|---|---|
| Bash 语法 | `bash -n core/claude-switch.sh`；遍历 `daemons/*.sh`、`linux/*.sh`、`scripts/*.sh`、安装器 | 全部退出 0 |
| Python 全量 | `python3 -B -m unittest discover -s tests -v` | 全过，数量不低于 674，新增用例计入 |
| Swift 场景 | `python3 -B -m unittest discover -s tests -p test_menu_bar_model.py -v` | 含代际竞态全部通过 |
| Swift 严格编译 | 使用 CI 中 `swiftc -O -parse-as-library -warnings-as-errors -target ...` | 无错误、无警告 |
| 工件哈希 | `bash scripts/gen-sums.sh && shasum -a 256 -c SHA256SUMS` | 全部 OK |
| 规则漂移 | `python3 scripts/sync-rules.py --check` | 无漂移 |
| JS 语法 | `node --check docs/app.js` | 退出 0 |
| 打包 | `bash scripts/package-macos.sh 0.0.0-test` | macOS full/app-only/kit 与平台包门禁通过 |
| Windows | CI 中 PowerShell 5.1 与 pwsh 7 的 report/switch/snapshot 集成 | 双壳全过 |
| 工作树 | `git status --short`、`git diff --check` | 无意外文件、无空白错误 |

额外安全断言：

- 所有更新失败测试都断言旧核心 SHA/字节完全一致。
- 所有切换失败测试都断言桌面、CLI 目录、CLI JSON、`current` 和启动调用五项状态。
- 所有快照攻击测试都断言 `accounts/<target>` 不存在，且外部 marker 未被创建。
- 所有节点绕过测试都断言内核 selector 未发生切换。
- 所有 watch 竞态测试都断言新一代状态未被旧回调修改。

---

## 4. 发布顺序与回滚策略

### 4.1 提交顺序

1. P0 Task 1–3：更新链路，单独发布或至少单独提交，优先阻断坏核心。
2. P1 Task 4–7：切换事务、E–H、节点门禁、watch。
3. P2 Task 8–11：快照、root 边界、CI、文档提示。
4. 每个提交后若触及受哈希保护文件，必须同提交更新 `SHA256SUMS`。
5. 全量验证通过后，先 `git fetch origin main`，确认远端无他人新工作，再按维护者授权推送。
6. 打 tag / 发布 Release 仍需当次明确授权；本方案不授权自动发布。

### 4.2 版本回滚兼容

- **核心更新器回滚**：同目录旧核心备份 + SHA 校验；回滚失败保留备份并明确报错。
- **账号事务回滚**：事务 journal + 实时状态备份；不删除账号正式存档。
- **节点回滚**：恢复切换前 leaf；国家复核失败时不得继续切账号。
- **快照格式回滚**：v2 发布后旧版本不认 v2，因此必须保留新版导入器或提供迁移工具，不能直接降级。
- **看门狗回滚**：代码可 revert，但 root 目标文件属于安装态；需用户授权重跑安装器，不手工覆盖系统目录。
- **CI 回滚**：revert workflow；不能靠跳过检查发布。

### 4.3 真机验收（需维护者另行授权）

仓库内测试不替代真机验收。未来获批后按以下顺序，在维护者本机明确同意的窗口执行：

1. 记录当前核心/App 版本、SHA、检查基线。
2. 仅部署到测试安装位或临时 HOME，验证更新成功、语法失败回滚、报告契约失败回滚。
3. 用两个测试槽位验证桌面/CLI 同时切换与故障恢复；不得使用真实登录账号做破坏性注入。
4. 验证旧看门狗刷新、root 目标文件和时区检查一致。
5. 验证 watch 停止/重启、退出 App 无孤儿进程。
6. 验证 v1 快照迁移提示和 v2 往返。
7. 验收失败立即按对应回滚路径处理，不继续发布。

---

## 5. 完成定义

只有同时满足以下条件，才能宣布加固完成：

- P0 三个复现用例全部转为通过：缺核心清单、坏语法、非零/不完整自检都无法安装新核心。
- 任意注入失败点都不留下桌面/CLI/current 混用状态。
- E–H 导入与 A–H 节点枚举通过。
- 显式 leaf 与推荐 leaf 使用同一硬门槛。
- watch 陈旧回调对新一代零影响。
- v2 篡改、链接和路径攻击在写账号目录前被拒绝。
- tag 发布独立重跑完整测试，工件清单覆盖随包运行时文件。
- 全量回归、Swift 严格编译、哈希、规则漂移、打包和 Windows 双壳集成全绿。
- 文档、提示和实际行为一致，未新增第 17 项检查，未改变账号存档结构。
- 未部署维护者本机、未发布 Release，除非维护者后续给出单独明确授权。
