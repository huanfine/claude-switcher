"""「配置没变 → 不重启 → 内核永远没加载规则」死循环的回归护栏。

用户 1.8.7-dev 的 last-fix.log 实测同时出现:

    FIX:置顶规则 ✓ 规则已是最新,未重启客户端
    FIX:WebRTC ✗ UDP 3478 规则没置顶 · 点「一键修复」

前者说文件是最新的,后者说运行中的内核没这条规则。旧 fix() 见「无变化」
就直接打勾跳过重启,于是收尾 verify 必然再失败,点多少次都停在原地。

这里直接抽出 core 里真实的 B2 段来跑(不是抄一份),用桩复现三种内核状态。
"""
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


STUBS = r'''
set -u
PROXY_MODE=clash-verge
just_reloaded=0
CALLS="$1"
VERIFY_MODE="$2"
WRITE_MODE="$3"
CLASH_DIR="$(dirname "$CALLS")/clash"
mkdir -p "$CLASH_DIR/profiles"
printf 'function main(config) { return config; }\n// claude-switcher managed rules\n' > "$CLASH_DIR/profiles/Script.js"
printf 'items:\n- uid: ABC\n' > "$CLASH_DIR/profiles.yaml"
: > "$CALLS"
rm -f "$CALLS.restarted"

clash_mode() { echo rule; }
write_merge_rules() {
    case "$WRITE_MODE" in
        unchanged) echo "OK:全局脚本已写入(proxy，无变化)" ;;
        changed)   echo "OK:全局脚本已写入(proxy，变更 2 处)" ;;
    esac
}
clash_rules() {
    case "$VERIFY_MODE" in
        ok) echo OK ;;
        missing_then_ok)
            if [ ! -f "$CALLS.restarted" ]; then
                echo "FAIL:运行规则未按策略置顶:UDP/3478" >&2
                return 1
            fi
            echo OK ;;
        missing_forever)
            echo "FAIL:运行规则未按策略置顶:UDP/3478" >&2
            return 1 ;;
        node_no_udp)
            echo "FAIL:当前节点未确认支持 UDP，请更换节点或选择 reject 策略" >&2
            return 1 ;;
    esac
}
quit_clash_verge() { echo quit >> "$CALLS"; : > "$CALLS.restarted"; }
open() { echo "open $*" >> "$CALLS"; }
tun_up() { return 0; }
sleep() { :; }
proxy_name() { echo "Clash Verge"; }
route_ok() { return 0; }

b2() {
__BLOCK__
}
b2
__B2_RC__=$?
echo "just_reloaded=$just_reloaded"
exit "$__B2_RC__"
'''


class RuntimeReloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sh = CORE.read_text(encoding="utf-8")
        start = sh.index("    # B2. 更新全局脚本")
        end = sh.index("    # C. 复测与日常审计", start)
        cls.block = sh[start:end].rstrip()
        cls.sh = sh

    def run_b2(self, verify_mode, write_mode="unchanged"):
        script = STUBS.replace("__BLOCK__", self.block)
        with tempfile.TemporaryDirectory(prefix="fix-reload-") as tmp:
            calls = str(Path(tmp) / "calls")
            run = subprocess.run(
                ["/bin/bash", "-s", calls, verify_mode, write_mode],
                input=script, text=True, capture_output=True, timeout=20)
            log = Path(calls).read_text() if Path(calls).exists() else ""
        return run, log

    def test_unchanged_but_kernel_missing_forces_a_restart(self):
        """用户的实际状态:文件对、内核没加载 → 必须重启并等 verify 通过。"""
        run, log = self.run_b2("missing_then_ok")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("配置没变但内核未加载规则,正在重启客户端", run.stdout)
        self.assertIn("已验证内核实际加载", run.stdout)
        self.assertIn("quit", log)
        self.assertIn("open -a Clash Verge", log)
        self.assertIn("just_reloaded=1", run.stdout)

    def test_unchanged_and_kernel_ready_still_skips_restart(self):
        """别把「省钱路径」弄丢:两边都就绪时不该白付一次 TUN 重建。"""
        run, log = self.run_b2("ok")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("规则与内核都已就绪,未重启客户端", run.stdout)
        self.assertEqual(log.strip(), "")
        self.assertIn("just_reloaded=0", run.stdout)

    def test_non_restartable_verify_failure_does_not_restart(self):
        """节点不支持 UDP 时重启也修不好,别让用户白等 40 秒。"""
        run, log = self.run_b2("node_no_udp")
        self.assertIn("重启无法解决", run.stdout)
        self.assertEqual(log.strip(), "")
        self.assertIn("just_reloaded=0", run.stdout)

    def test_restart_that_still_fails_reports_actionable_error(self):
        run, log = self.run_b2("missing_forever")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("未验证内核加载", run.stdout)
        self.assertIn("全局扩展脚本是否启用", run.stdout)
        self.assertIn("quit", log)

    def test_changed_config_path_still_restarts(self):
        """原有「配置有变化」分支不能被重构弄丢。"""
        run, log = self.run_b2("ok", write_mode="changed")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("已验证内核实际加载", run.stdout)
        self.assertIn("quit", log)
        self.assertIn("just_reloaded=1", run.stdout)

    def test_fix_does_not_tell_you_to_click_repair_again_after_repair(self):
        """收尾那句「点「一键修复」」会构成无限循环,必须指向具体动作。"""
        fix = self.sh.split("\nfix() {", 1)[1].split("\n}\n", 1)[0]
        tail = fix[fix.index('    wr=$(webrtc_status'):]
        tail = tail[:tail.index("    # D.")]
        self.assertIn("*规则没置顶*|*内核缺少*", tail)
        self.assertIn("全局扩展脚本已启用", tail)


class ScriptBlockPlacementTests(unittest.TestCase):
    """管理块必须在文件末尾执行,否则会被用户在块后写的 main 覆盖。

    实测:用户的 Script.js 5023 字节(我们那份约 2400),块后面还有他自己的
    逻辑;块原地替换时 IIFE 先跑、随后被覆盖,内核首条成了 ipinfo.io,
    而 write 每次都报「无变化」—— 文件看上去完全正确。
    """

    @classmethod
    def setUpClass(cls):
        cls.sh = CORE.read_text(encoding="utf-8")
        cls.body = cls.sh.split("def script_text(", 1)[1].split("\ndef ", 1)[0]

    def test_old_block_is_removed_then_appended_at_the_end(self):
        self.assertIn('pattern.sub("", old, count=1)', self.body)
        self.assertNotIn("pattern.sub(lambda _: block", self.body)
        self.assertIn('rstrip() + "\\n"', self.body)

    def test_no_early_return_that_keeps_the_block_in_place(self):
        self.assertNotIn("return pattern.sub(", self.body)


class RegisterScriptTests(unittest.TestCase):
    """Clash Verge 只认 profiles.yaml 里注册过的 Script.js。

    文件写了但没有 `uid: Script` 条目时,重启客户端也不会加载它 —— 这正是
    「配置没变但内核未加载」重启后仍然失败的那一层。
    """

    @classmethod
    def setUpClass(cls):
        cls.sh = CORE.read_text(encoding="utf-8")

    def run_register(self, clash):
        base = clash.parent / "base"
        base.mkdir(exist_ok=True)
        return subprocess.run(
            ["/bin/bash", str(CORE), "clash-rules", "register-script",
             str(clash), str(base), ""],
            text=True, capture_output=True, timeout=20,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                 "HOME": str(clash.parent)})

    def make_profiles(self, tmp):
        clash = Path(tmp) / "clash"
        (clash / "profiles").mkdir(parents=True)
        (clash / "profiles.yaml").write_text(
            "# Profiles Config for Clash Verge\n\ncurrent: ABC\nitems:\n"
            "- uid: ABC\n  type: remote\n  name: test\n  file: ABC.yaml\n",
            encoding="utf-8")
        return clash

    def test_registers_missing_global_script_item(self):
        with tempfile.TemporaryDirectory(prefix="reg-script-") as tmp:
            clash = self.make_profiles(tmp)
            run = self.run_register(clash)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            text = (clash / "profiles.yaml").read_text(encoding="utf-8")
            self.assertIn("- uid: Script", text)
            self.assertIn("  type: script", text)
            self.assertIn("  file: Script.js", text)
            self.assertLess(text.index("- uid: Script"), text.index("- uid: ABC"),
                            "补注册项要在 items 里,且不能打乱原有条目")

    def test_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="reg-script-") as tmp:
            clash = self.make_profiles(tmp)
            self.run_register(clash)
            run = self.run_register(clash)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("已注册", run.stdout)
            text = (clash / "profiles.yaml").read_text(encoding="utf-8")
            self.assertEqual(text.count("uid: Script"), 1)

    def test_restart_block_registers_after_quit_before_open(self):
        """必须等客户端退出后再改 profiles.yaml,否则会被它退出时写回覆盖。"""
        fix = self.sh.split("\nfix() {", 1)[1].split("\n}\n", 1)[0]
        register_at = fix.index("clash_rules register-script")
        quit_at = fix.rindex("quit_clash_verge", 0, register_at)
        open_at = fix.index('open -a "Clash Verge"', register_at)
        self.assertLess(quit_at, register_at)
        self.assertLess(register_at, open_at)

    def test_failure_dumps_why_instead_of_only_asking_user_to_check(self):
        fix = self.sh.split("\nfix() {", 1)[1].split("\n}\n", 1)[0]
        self.assertIn("FIX:诊断:Script.js", fix)
        self.assertIn("FIX:诊断:profiles.yaml", fix)
        self.assertIn("FIX:诊断:Clash Verge 版本", fix)


if __name__ == "__main__":
    unittest.main()
