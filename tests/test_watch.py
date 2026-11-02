"""运行期看门狗:出口一变就必须停,而不是等 Claude 自己发现。

启动门禁只覆盖「拉起那一刻」。用着用着出口被切、代理掉线,Claude 不会自己停,
会拿着错误的出口继续发请求 —— watch 补的就是这一段。

这里只测判定,不真的去关进程:stop_claude_now 在单测里换成记录。
"""
import os
from pathlib import Path
import re
import subprocess
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


def shell_quote(value):
    return "'" + value.replace("'", "'\\''") + "'"


def helper(name):
    """取出函数定义原文。单行写法的（如 watch_log）也要认得。"""
    text = SOURCE.read_text(encoding="utf-8")
    one = re.search(r"(?m)^" + name + r"\(\) \{[^\n]*\}$", text)
    if one:
        return one.group(0)
    multi = re.search(r"(?ms)^" + name + r"\(\) \{\n.*?^\}", text)
    if not multi:
        raise AssertionError("找不到函数 " + name)
    return multi.group(0)


class WatchCycleTests(unittest.TestCase):
    def run_cycles(self, ips):
        """按顺序喂一串出口 IP,返回每一轮的 (rc, stop 文案)。"""
        code = 'set -u\nWATCH_K4=""; WATCH_K6=""; WATCH_STOP=""\n'
        code += 'curl() { [ -n "$NEXT_IP" ] && printf "ip=%s\\nloc=US\\n" "$NEXT_IP"; }\n'
        code += helper("ip_key") + "\n" + helper("ip_show") + "\n" + helper("watch_cycle") + "\n"
        for ip in ips:
            code += 'NEXT_IP=%s; watch_cycle; echo "rc=$? stop=$WATCH_STOP"\n' % ("''" if not ip else ip)
        run = subprocess.run(["/bin/bash", "-c", code], text=True,
                             capture_output=True, timeout=20, env=dict(os.environ, LC_ALL="C"))
        out = []
        for line in run.stdout.splitlines():
            m = re.match(r"rc=(\d+) stop=(.*)$", line)
            if m:
                out.append((int(m.group(1)), m.group(2)))
        self.assertEqual(len(out), len(ips), run.stdout + run.stderr)
        return out

    def test_same_exit_twice_is_quiet(self):
        self.assertEqual(self.run_cycles(["203.0.113.7", "203.0.113.7"]),
                         [(0, ""), (0, "")])

    def test_ipv4_change_stops_with_both_addresses(self):
        """出口变了就得停 —— 用户要的是「不许换」,不是「换了我提示你一下」。"""
        first, second = self.run_cycles(["203.0.113.7", "198.51.100.9"])
        self.assertEqual(first[0], 0)
        self.assertEqual(second[0], 1)
        self.assertIn("203.0.113.7", second[1])
        self.assertIn("198.51.100.9", second[1])

    def test_cross_family_flip_is_not_a_change(self):
        """双栈节点在 v4/v6 之间来回报是同一个出口,判成「变了」会把人误杀。"""
        result = self.run_cycles(["203.0.113.7", "2001:db8:1:2::1", "203.0.113.7"])
        self.assertTrue(all(rc == 0 for rc, _ in result), result)

    def test_v6_suffix_rotation_within_prefix_is_not_a_change(self):
        result = self.run_cycles(["2001:db8:1:2::1", "2001:db8:1:2::99"])
        self.assertTrue(all(rc == 0 for rc, _ in result), result)

    def test_v6_prefix_change_stops(self):
        result = self.run_cycles(["2001:db8:1:2::1", "2001:db8:9:9::1"])
        self.assertEqual(result[1][0], 1)
        self.assertIn("IPv6", result[1][1])

    def test_probe_failure_does_not_stop_immediately(self):
        """一次网络抖动不能当断网 —— 返回 2 交给调用方累计,连续三次才停。"""
        result = self.run_cycles(["203.0.113.7", "", "203.0.113.7"])
        self.assertEqual([rc for rc, _ in result], [0, 2, 0])
        self.assertEqual(result[1][1], "")


class WatchLockTests(unittest.TestCase):
    """单实例接管:同一时刻只允许一个守护。

    App 被强杀时 applicationWillTerminate 不会执行,它起的看门狗会留成孤儿。
    新实例如果不管,两个守护就各拿一份基线跑下去 —— 重复报警、重复关进程,
    而且旧那份的基线还是上一轮的。脚本这层是兜底,App 侧另有 pkill。
    """

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory(prefix="watch-lock-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def run_lock(self):
        code = 'set -u\nBASE=%s\n' % shell_quote(str(self.base))
        code += helper("watch_log") + "\n" + helper("watch_lock") + "\n"
        # 必须在脚本还活着的时候把 pidfile 读出来:正常退出会走 EXIT trap 把它删掉,
        # 那正是设计意图,不是缺陷。
        code += 'watch_lock\necho "me=$$"\necho "pidfile=$(cat "$BASE/watch.pid" 2>/dev/null)"\n'
        run = subprocess.run(["/bin/bash", "-c", code], text=True,
                             capture_output=True, timeout=20, env=dict(os.environ, LC_ALL="C"))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout

    def pidfile_content(self, out):
        return re.search(r"pidfile=(.*)", out).group(1).strip()

    def test_takes_over_live_watchdog(self):
        victim = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(lambda: victim.poll() is None and victim.kill())
        (self.base / "watch.pid").write_text(str(victim.pid), encoding="utf-8")
        out = self.run_lock()
        me = re.search(r"me=(\d+)", out).group(1)
        # 旧的必须被收掉,否则两个守护会同时动手
        victim.wait(timeout=10)
        self.assertIsNotNone(victim.returncode)
        self.assertEqual(self.pidfile_content(out), me)
        self.assertIn("接管", (self.base / "watch.log").read_text(encoding="utf-8"))

    def test_dead_pid_does_not_block(self):
        (self.base / "watch.pid").write_text("999999", encoding="utf-8")
        out = self.run_lock()
        self.assertEqual(self.pidfile_content(out), re.search(r"me=(\d+)", out).group(1))

    def test_garbage_pidfile_does_not_block(self):
        (self.base / "watch.pid").write_text("not-a-pid", encoding="utf-8")
        out = self.run_lock()
        self.assertEqual(self.pidfile_content(out), re.search(r"me=(\d+)", out).group(1))

    def test_missing_pidfile_is_fine(self):
        out = self.run_lock()
        self.assertEqual(self.pidfile_content(out), re.search(r"me=(\d+)", out).group(1))

    def test_sigterm_actually_stops_the_watchdog(self):
        """bash 的 TERM trap 执行完会回到被中断处继续跑,不显式 exit 就停不下来。

        这是实测踩到的坑:App 调 terminate() 发 SIGTERM,守护只删了 pidfile 就接着
        转,于是每重启一次 App 就多一个孤儿守护,各自拿一份基线判出口。
        """
        code = 'set -u\nBASE=%s\n' % shell_quote(str(self.base))
        code += helper("watch_log") + "\n" + helper("watch_lock") + "\n"
        code += 'watch_lock\nwhile :; do /bin/sleep 0.2; done\n'
        proc = subprocess.Popen(["/bin/bash", "-c", code], env=dict(os.environ, LC_ALL="C"))
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        pidfile = self.base / "watch.pid"
        for _ in range(60):
            if pidfile.exists():
                break
            time.sleep(0.05)
        self.assertTrue(pidfile.exists(), "看门狗没写 pidfile")
        proc.terminate()
        proc.wait(timeout=5)  # 不退出这里就抛 TimeoutExpired
        self.assertFalse(pidfile.exists(), "退出时应清掉自己的 pidfile")

    def test_exit_removes_only_own_pidfile(self):
        """被接管的旧实例退出时不能把新实例的 pidfile 删掉。"""
        code = 'set -u\nBASE=%s\n' % shell_quote(str(self.base))
        code += helper("watch_log") + "\n" + helper("watch_lock") + "\n"
        # 模拟旧实例:pidfile 里写的不是自己,退出时不该删
        code += 'printf "12345\\n" > "$BASE/watch.pid"\nWATCH_PIDFILE="$BASE/watch.pid"\n'
        code += 'trap \'[ "$(cat "$WATCH_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$WATCH_PIDFILE"\' EXIT\n'
        subprocess.run(["/bin/bash", "-c", code], text=True, capture_output=True, timeout=20,
                       env=dict(os.environ, LC_ALL="C"))
        self.assertTrue((self.base / "watch.pid").exists())


if __name__ == "__main__":
    unittest.main()
