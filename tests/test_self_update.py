"""self_update（核心里的 update / update --auto）的回归。

背景:--auto 由 LaunchAgent 每 12 小时静默调用,它的跳过判断只 diff「内容
是否不同」——发布产物 = 安装产物,双方都是 main 的原样拷贝,没有可比较的
版本号。代价是:开发机上本地改动还没推送时,--auto 会把远端旧版盖回来,
2026-11-21 实测把已验证安装的纯净度修复降级回滚。

这里用假 HOME + 假 curl(假 zip + 假 SHA256SUMS)验证:
  1. --auto 在 update-hold 哨兵存在时不覆盖本地;
  2. 哨兵不拦手动 update(显式执行就是要比对/换远端版)。

关键实现细节:self_update 的 BIN 从 $0 推导,所以必须把真核心**拷贝**到
假安装位再从那里运行 —— 直接跑仓库路径会把仓库工作区当成安装目录覆盖掉
(第一版夹具犯过,core/claude-switch.sh 被写成了 33 字节的假脚本)。

不碰真实 ~/.local/bin、不联网。
"""
import hashlib
import json
import shutil
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "core/claude-switch.sh"
TRASH = PROJECT / "_trash"

FAKE_CURL = """\
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *SHA256SUMS) cp "$CS_SERVE_SUMS" "$out" ;;
  *codeload*) cp "$CS_SERVE_ZIP" "$out" ;;
  *) exit 22 ;;
esac
"""


class SelfUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="self-update-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".claude-switcher").mkdir(parents=True)
        # 真核心拷贝进假安装位:BIN 从 $0 推导,必须让推导落在假 HOME 里。
        self.bin = self.home / ".local/bin/claude-switch.sh"
        shutil.copy(SCRIPT, self.bin)
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IXUSR)
        (self.home / ".claude-switcher/env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "g",
            "country": "US", "timezone": "America/Denver", "locale": "en-US",
            "clash_dir": str(self.root / "nonexistent-clash"),
            "fake_ip_range": "198.18.0.0/16",
        }), encoding="utf-8")
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        curl = self.fakebin / "curl"
        curl.write_text(FAKE_CURL, encoding="utf-8")
        curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
        # 远端材料默认与本地相同,让手动 update 走 diff 短路返回,
        # 不触发替换后的完整自检(那是 checkdetail 全链路,单测不伺候);
        # auto 用例要测「内容不同 + 哨兵」,在自己体内把远端改成不同。
        self.zip_path = self.root / "main.zip"
        self.sums_path = self.root / "SHA256SUMS"
        self.serve_remote(SCRIPT.read_text(encoding="utf-8"))

    def serve_remote(self, content, manifest=None):
        """把「远端 main」换成给定内容;False 表示保留测试手写清单。"""
        payloads = {"core/claude-switch.sh": content}
        if manifest is None or manifest is False:
            paths = ["core/claude-switch.sh"]
        else:
            paths = list(manifest)
            for rel in paths:
                payloads.setdefault(rel, f"fixture for {rel}\n")
        with zipfile.ZipFile(self.zip_path, "w") as zf:
            for rel, payload in payloads.items():
                zf.writestr(f"claude-switcher-main/{rel}", payload)
        if manifest is not False:
            lines = []
            for rel in paths:
                digest = hashlib.sha256(payloads[rel].encode("utf-8")).hexdigest()
                lines.append(f"{digest}  {rel}")
            self.sums_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def run_update(self, *args):
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "CS_SERVE_ZIP": str(self.zip_path),
            "CS_SERVE_SUMS": str(self.sums_path),
            "LC_ALL": "C",
        }
        return subprocess.run(["/bin/bash", str(self.bin), "update", *args],
                              text=True, capture_output=True, env=env, timeout=90)

    def update_log(self):
        log = self.home / ".claude-switcher" / "update.log"
        return log.read_text(encoding="utf-8") if log.exists() else ""

    def test_auto_update_respects_update_hold_sentinel(self):
        """--auto 在哨兵存在时不得覆盖本地:本地改动可能还没推送。

        替换发生前的最后一道闸。没有它,无人值守通道每 12 小时把远端 main
        原样盖回本地 —— 对生产安装是「保持与远端一致」的正确行为,
        对开发机是把未推送的工作静默回滚。
        """
        (self.home / ".claude-switcher/update-hold").write_text("", encoding="utf-8")
        # 远端换成不同内容:没有哨兵时 --auto 会执行替换,这样才能证明是哨兵拦住的
        # (若是「远端相同走了 diff 短路」,文件不变但日志里不会有 SKIP,断言会漏)。
        self.serve_remote(SCRIPT.read_text(encoding="utf-8") + "\n# unpushed dev line\n")
        run = self.run_update("--auto")
        self.assertEqual(self.bin.read_text(encoding="utf-8"),
                         SCRIPT.read_text(encoding="utf-8"),
                         "哨兵存在时 --auto 覆盖了本地核心")
        self.assertIn("update-hold", self.update_log())

    def test_manual_update_ignores_update_hold_sentinel(self):
        """手动 update 是显式意志,哨兵不得拦。

        哨兵只约束无人值守通道。用户亲手敲 update 就是要比对/换远端,
        这时再报 SKIP 就是把工具意志凌驾于用户意志之上。
        远端与本地相同,diff 判断直接放行并报「已是最新版本」——
        走到这一句即证明流程通过了哨兵检查。
        """
        (self.home / ".claude-switcher/update-hold").write_text("", encoding="utf-8")
        run = self.run_update()
        combined = run.stdout + run.stderr + self.update_log()
        self.assertNotIn("SKIP", combined, "哨兵拦下了手动 update")
        self.assertIn("已是最新版本", combined, "手动 update 没走到远端比对")
        self.assertEqual(self.bin.read_text(encoding="utf-8"),
                         SCRIPT.read_text(encoding="utf-8"),
                         "远端与本地相同时不该有任何写入")

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
        core = b"if then\n"
        self.sums_path.write_text(
            f"{digest}  ../outside\n"
            f"{hashlib.sha256(core).hexdigest()}  core/claude-switch.sh\n",
            encoding="utf-8")
        self.serve_remote(core.decode(), manifest=False)
        run = self.run_update()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("清单", run.stdout + run.stderr)

    def test_manifest_rejects_duplicate_and_malformed_entries(self):
        remote = SCRIPT.read_text(encoding="utf-8") + "\n# remote\n"
        self.serve_remote(remote, manifest=False)
        core_digest = hashlib.sha256(remote.encode("utf-8")).hexdigest()
        self.sums_path.write_text(
            f"{core_digest}  core/claude-switch.sh\n"
            f"{core_digest}  core/claude-switch.sh\n"
            "not-a-digest  README.md\n", encoding="utf-8")
        run = self.run_update()
        self.assertNotEqual(run.returncode, 0)

    def test_candidate_copy_failure_keeps_old_core(self):
        fail_cp = self.fakebin / "cp"
        fail_cp.write_text("""#!/bin/bash
for arg in "$@"; do
  case "$arg" in *claude-switch.sh.new.*) exit 41 ;; esac
done
exec /bin/cp "$@"
""", encoding="utf-8")
        fail_cp.chmod(0o755)
        self.bin.write_text(inject_checkdetail(
            SCRIPT.read_text(encoding="utf-8"), ["代理内核=ok"]), encoding="utf-8")
        self.serve_remote(inject_checkdetail(
            SCRIPT.read_text(encoding="utf-8") + "\n# remote\n", ["代理内核=ok"]))
        before = self.bin.read_bytes()
        run = self.run_update()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.bin.read_bytes(), before)
        self.assertFalse(list(self.bin.parent.glob("claude-switch.sh.new.*")))

    def test_atomic_rename_failure_keeps_old_core(self):
        fail_mv = self.fakebin / "mv"
        fail_mv.write_text("""#!/bin/bash
for arg in "$@"; do
  case "$arg" in *claude-switch.sh.new.*) exit 42 ;; esac
done
exec /bin/mv "$@"
""", encoding="utf-8")
        fail_mv.chmod(0o755)
        self.bin.write_text(inject_checkdetail(
            SCRIPT.read_text(encoding="utf-8"), ["代理内核=ok"]), encoding="utf-8")
        self.serve_remote(inject_checkdetail(
            SCRIPT.read_text(encoding="utf-8") + "\n# remote\n", ["代理内核=ok"]))
        before = self.bin.read_bytes()
        run = self.run_update()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.bin.read_bytes(), before)
        self.assertFalse(list(self.bin.parent.glob("claude-switch.sh.new.*")))

    def test_backup_symlink_is_rejected_without_touching_target(self):
        outside = self.root / "outside-backup"
        outside.write_bytes(b"keep me")
        backup = self.bin.with_suffix(".sh.bak")
        backup.symlink_to(outside)
        self.serve_remote(inject_checkdetail(
            SCRIPT.read_text(encoding="utf-8") + "\n# remote\n", ["代理内核=ok"]))
        before = self.bin.read_bytes()
        run = self.run_update()
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.bin.read_bytes(), before)
        self.assertEqual(outside.read_bytes(), b"keep me")


# ---- 自检回归对比 ----
# 2026-11-20~27 他机实测:旧自检 `grep -q '=fail'` 一票否决,地区漂移一项
# fail 就把更新回滚了 7 天 14+ 轮;DNS泄露=fail 更自锁——能修它的核心(新核心
# 才有这项检查/修复)因为它的存在装不上。新逻辑只回滚「基线 ok → 新核心 fail」
# 的真退化;基线已 fail/warn/skip/config 与新核心首次检出的项不阻塞,只交代。
#
# 测试确定性:checkdetail 全链路依赖网络与代理状态,单测伺候不起。这里往
# `operation="${1:-}"`(顶层 dispatch 之前)注入 checkdetail 函数覆盖——
# bash 函数定义在调用时解析,后定义者胜出,于是基线(旧核心)与自检(新核心)
# 各自输出我们指定的固定行,不必跑真探测。
DISPATCH_ANCHOR = 'operation="${1:-}"'


def inject_checkdetail(content, lines):
    override = "checkdetail(){ printf '%s\\n' " + " ".join(
        f"'{line}'" for line in lines) + "; }"
    assert DISPATCH_ANCHOR in content, "dispatch 锚点不在核心里,sed 注入会失效"
    return content.replace(DISPATCH_ANCHOR, DISPATCH_ANCHOR + "\n" + override, 1)


class SelfCheckRegressionTests(unittest.TestCase):
    """「更新自检一票否决」改「回归对比」后的契约。"""

    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="self-update-regress-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.bin = self.home / ".local/bin/claude-switch.sh"
        (self.home / ".claude-switcher/env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "g",
            "country": "US", "timezone": "America/Denver", "locale": "en-US",
            "clash_dir": str(self.root / "nonexistent-clash"),
            "fake_ip_range": "198.18.0.0/16",
        }), encoding="utf-8")
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        curl = self.fakebin / "curl"
        curl.write_text(FAKE_CURL, encoding="utf-8")
        curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
        self.zip_path = self.root / "main.zip"
        self.sums_path = self.root / "SHA256SUMS"

    def serve_remote(self, content):
        with zipfile.ZipFile(self.zip_path, "w") as zf:
            zf.writestr("claude-switcher-main/core/claude-switch.sh", content)
        digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
        self.sums_path.write_text(f"{digest}  core/claude-switch.sh\n", encoding="utf-8")

    def install_local(self, content):
        self.bin.write_text(content, encoding="utf-8")
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IXUSR)

    def run_update(self):
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "CS_SERVE_ZIP": str(self.zip_path),
            "CS_SERVE_SUMS": str(self.sums_path),
            "LC_ALL": "C",
        }
        return subprocess.run(["/bin/bash", str(self.bin), "update"],
                              text=True, capture_output=True, env=env, timeout=90)

    def rollback_record(self):
        f = self.home / ".claude-switcher" / "update-rollback.txt"
        return f.read_text(encoding="utf-8") if f.exists() else ""

    def update_log(self):
        log = self.home / ".claude-switcher" / "update.log"
        return log.read_text(encoding="utf-8") if log.exists() else ""

    def test_regression_rolls_back_and_leaves_record(self):
        """基线 ok → 新核心 fail 必须回滚,且留下可读的回滚痕迹。

        这是自检的本职:新核心让原本通过的项挂了,就是新核心的锅。
        痕迹文件是 App「上次更新被回滚」提示的唯一事实来源——没有它,
        回滚只剩 exit=1 一条日志,用户永远不知道机器为什么停在旧核心。
        """
        local = inject_checkdetail(SCRIPT.read_text(encoding="utf-8"),
                                   ["代理内核=ok:基线通过"])
        remote = inject_checkdetail(SCRIPT.read_text(encoding="utf-8"),
                                    ["代理内核=fail:注入的真退化"])
        self.install_local(local)
        self.serve_remote(remote)
        run = self.run_update()
        self.assertEqual(self.bin.read_text(encoding="utf-8"), local,
                         "回归被回滚后本地核心应原样保留")
        self.assertIn("已自动回滚", run.stdout, "回滚必须明说,不能只退 exit code")
        self.assertIn("代理内核", run.stdout, "回滚原因要点名退化的项")
        record = self.rollback_record()
        self.assertIn("代理内核", record, "回滚痕迹文件缺退化项名")

    def test_preexisting_and_new_fails_do_not_block_update(self):
        """旧核心同样 fail、以及新核心首次检出的 fail,都不再阻塞更新。

        反自锁的关键用例:环境漂移(地区)与「只有新核心才看得见的问题」
        (DNS泄露)回滚解决不了——装回旧核心它们照样在。能修它们的恰恰是
        新核心,所以更新必须过去,但要把这些 fail 如实交代出来。
        更新成功还应清掉历史回滚痕迹(文件在 = 最后一次更新失败)。
        """
        record = self.home / ".claude-switcher" / "update-rollback.txt"
        record.write_text("2026-11-20 20:54:22|地区=fail(旧逻辑的历史回滚)", encoding="utf-8")
        local = inject_checkdetail(SCRIPT.read_text(encoding="utf-8"),
                                   ["代理内核=fail:环境本来就坏",
                                    "地区=fail:漂移,两边都一样",
                                    "ASN属性=warn:照旧"])
        remote = inject_checkdetail(SCRIPT.read_text(encoding="utf-8"),
                                    ["代理内核=fail:环境本来就坏",
                                     "地区=fail:漂移,两边都一样",
                                     "ASN属性=warn:照旧",
                                     "DNS泄露=fail:新核心首次检出"])
        self.install_local(local)
        self.serve_remote(remote)
        run = self.run_update()
        combined = run.stdout + run.stderr + self.update_log()
        self.assertIn("OK:更新完成", combined, f"环境 fail 不该阻塞更新,输出:{combined}")
        self.assertNotIn("已自动回滚", combined)
        self.assertEqual(self.bin.read_text(encoding="utf-8"), remote,
                         "更新没有落地:本地核心应已是远端内容")
        self.assertIn("DNS泄露", combined, "首次检出的 fail 要如实交代,不能静默")
        self.assertFalse(record.exists(), "更新成功后必须清掉回滚痕迹")


if __name__ == "__main__":
    unittest.main()
