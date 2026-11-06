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


if __name__ == "__main__":
    unittest.main()
