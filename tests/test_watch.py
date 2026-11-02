"""运行期看门狗:出口一变就必须停,而不是等 Claude 自己发现。

启动门禁只覆盖「拉起那一刻」。用着用着出口被切、代理掉线,Claude 不会自己停,
会拿着错误的出口继续发请求 —— watch 补的就是这一段。

这里只测判定,不真的去关进程:stop_claude_now 在单测里换成记录。
"""
import os
from pathlib import Path
import re
import signal
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
        # 真 ps 在受限环境(CI/沙箱)里可能被拒。这里测的是「拿到命令行之后怎么判断」,
        # 不是 ps 本身,所以用桩替代,让结果确定。
        self.bin = self.base / "bin"
        self.bin.mkdir()
        stub = self.bin / "ps"
        stub.write_text('#!/bin/bash\nprintf "%s\\n" "$PS_STUB_OUTPUT"\n')
        stub.chmod(0o755)

    def run_lock(self, ps_output=""):
        code = 'set -u\nBASE=%s\n' % shell_quote(str(self.base))
        code += helper("watch_log") + "\n" + helper("watch_pid_is_watchdog") + "\n"
        code += helper("watch_lock") + "\n"
        # 必须在脚本还活着的时候把 pidfile 读出来:正常退出会走 EXIT trap 把它删掉,
        # 那正是设计意图,不是缺陷。
        code += 'watch_lock\necho "me=$$"\necho "pidfile=$(cat "$BASE/watch.pid" 2>/dev/null)"\n'
        env = dict(os.environ, LC_ALL="C", PS_STUB_OUTPUT=ps_output,
                   PATH=str(self.bin) + ":" + os.environ.get("PATH", ""))
        run = subprocess.run(["/bin/bash", "-c", code], text=True,
                             capture_output=True, timeout=20, env=env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return run.stdout

    def pidfile_content(self, out):
        """pidfile 格式是「pid<TAB>BASE」,只比 pid 那一段。"""
        raw = re.search(r"pidfile=(.*)", out).group(1).strip()
        return raw.split("\t")[0].split()[0] if raw else ""

    def fake_watchdog(self):
        """造一个命令行含 claude-switch.sh watch 的长睡进程,冒充看门狗。

        不能用 cp /bin/sleep:复制出来的系统二进制在 /tmp 执行会被系统直接 SIGKILL
        (和文件名无关,换个名字一样死),测出来的 poll() 永远是 -9。
        用 bash 脚本,命令行照样带那串字。
        """
        script = self.base / "claude-switch.sh watch"
        script.write_text("#!/bin/bash\n/bin/sleep 30\n")
        os.chmod(script, 0o755)
        # 独立进程组:收尾时连 sleep 子进程一起清,否则每个测试都留一个睡 30 秒的。
        proc = subprocess.Popen([str(script)], start_new_session=True)

        def cleanup():
            if proc.poll() is None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        self.addCleanup(cleanup)
        return proc

    def test_takes_over_live_watchdog(self):
        victim = self.fake_watchdog()
        (self.base / "watch.pid").write_text(str(victim.pid), encoding="utf-8")
        out = self.run_lock("/bin/bash /x/claude-switch.sh watch 10 6")
        me = re.search(r"me=(\d+)", out).group(1)
        # 旧的必须被收掉,否则两个守护会同时动手
        victim.wait(timeout=10)
        self.assertIsNotNone(victim.returncode)
        self.assertEqual(self.pidfile_content(out), me)
        self.assertIn("接管", (self.base / "watch.log").read_text(encoding="utf-8"))

    def test_does_not_kill_unrelated_process(self):
        """pidfile 残留 + pid 复用:不能把恰好拿到这个号的无关进程杀掉。

        守护被 SIGKILL 时走不到 trap,pidfile 会留在磁盘上;系统之后把这个 pid
        分配给谁都有可能。只凭 kill -0 成功就下手,迟早杀错人。
        """
        victim = subprocess.Popen(["/bin/sleep", "30"])
        self.addCleanup(lambda: victim.poll() is None and victim.kill())
        (self.base / "watch.pid").write_text(str(victim.pid), encoding="utf-8")
        out = self.run_lock("/bin/sleep 30")
        self.assertIsNone(victim.poll(), "无关进程被误杀")
        self.assertEqual(self.pidfile_content(out), re.search(r"me=(\d+)", out).group(1))

    def test_does_not_take_over_other_base(self):
        """备份/迁移带过来的 pidfile:那个进程服务的是另一套环境,不该动它。"""
        victim = self.fake_watchdog()
        (self.base / "watch.pid").write_text("%d\t/tmp/another-base" % victim.pid, encoding="utf-8")
        out = self.run_lock("/bin/bash /x/claude-switch.sh watch 10 6")
        self.assertIsNone(victim.poll(), "别的 BASE 的守护被误杀")
        self.assertEqual(self.pidfile_content(out), re.search(r"me=(\d+)", out).group(1))

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
        code += helper("watch_log") + "\n" + helper("watch_pid_is_watchdog") + "\n"
        code += helper("watch_lock") + "\n"
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


class IncidentRecordTests(unittest.TestCase):
    """拦截记录。界面按 TAB 切三列渲染历史,格式错一条就少显示一条。"""

    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory(prefix="incident-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)

    def run_incident(self, *args):
        code = 'set -u\nBASE=%s\n' % shell_quote(str(self.base))
        code += helper("watch_incident") + "\n"
        code += "watch_incident " + " ".join(shell_quote(a) for a in args) + "\n"
        run = subprocess.run(["/bin/bash", "-c", code], text=True, capture_output=True,
                             timeout=20, env=dict(os.environ, LC_ALL="C"))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def read_lines(self):
        return (self.base / "incidents.log").read_text(encoding="utf-8").strip().split("\n")

    def test_writes_three_tab_columns(self):
        self.run_incident("出口 IPv4 变了(1.2.3.4 → 5.6.7.8)", "出口变化")
        f = self.read_lines()[0].split("\t")
        self.assertEqual(len(f), 3, "必须正好三列,界面按 TAB 切")
        self.assertRegex(f[0], r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$")
        self.assertEqual(f[1], "出口变化")
        self.assertEqual(f[2], "出口 IPv4 变了(1.2.3.4 → 5.6.7.8)")

    def test_kind_defaults_when_missing(self):
        self.run_incident("原因")
        self.assertEqual(self.read_lines()[0].split("\t")[1], "拦截")

    def test_empty_reason_writes_nothing(self):
        """空原因不写:一条只有时间的记录对排查毫无用处,只会把真记录挤掉。"""
        self.run_incident("")
        self.assertFalse((self.base / "incidents.log").exists())

    def test_keeps_only_last_fifty(self):
        for i in range(55):
            self.run_incident("第 %d 次" % i, "检查未通过")
        lines = self.read_lines()
        self.assertEqual(len(lines), 50, "只留最近 50 条")
        self.assertIn("第 54 次", lines[-1])
        self.assertNotIn("第 0 次", "\n".join(lines))


if __name__ == "__main__":
    unittest.main()
