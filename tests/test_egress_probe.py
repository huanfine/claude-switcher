"""出口多采样、离线复核与证据落盘的回归测试。

背景(实测踩到的两个问题):
  1. 单次 curl 空返回会把网络抖动判成「出口IP异常」,进而拦住 Claude 启动;
  2. 节点在多个出口之间漂移时,单次采样看不出来,而这正是账号画像最怕的状态。
所以出口改成连采多次:全一致才 ok,采样间不一致判 unstable,一次都没取到判 unknown。
unknown 不再直接判 fail,但必须显式告知「本次出口未确认」。
"""
import json
import os
import re
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"


def extract(name, text=None):
    """取出核心脚本里的一个函数定义,供隔离环境单独运行。"""
    text = text if text is not None else SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^%s\(\) \{\n.*?^\}" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到函数 %s" % name)
    return match.group(0)


def extract_line(name, text=None):
    """取出单行函数(如 check_strict)。夹具必须用真身,不能自带一份副本 ——
    副本会和源码各改各的,测试从此只证明测试自己是对的。"""
    text = text if text is not None else SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"(?m)^%s\(\) \{.*$" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到单行函数 %s" % name)
    return match.group(0)


PROBE_FN = extract("ip_key") + "\n\n" + extract("probe_egress")
CHECK_FN = extract("check") + "\n\n" + extract("tz_current")

# 出口身份归一:check() 与 probe_egress() 都靠它,隔离环境里必须一起带上。
IP_HELPERS = "\n".join(extract(n) for n in (
    "ip_key", "ip_show", "ip_key_migrate", "ip_org", "ip_class",
    "current_instance", "ip_history_file", "ip_lastip_file", "migrate_ip_state",
    "last_seen", "last_save"))

# 固定基线:判定现在用的是不是那条固定出口。文件路径/读/时间/文案/写是一组,
# 少一个 check() 就会在 command not found 里静默降级成「一律不告警」。
# 必须叠在 IP_HELPERS 上:基线比较本身依赖 ip_key/ip_class/ip_org(判家宽还是机房)。
IP_BASELINE_HELPERS = IP_HELPERS + "\n" + "\n".join(extract(n) for n in (
    "ip_baseline_file", "ip_baseline_line", "ip_baseline_get",
    "ip_baseline_since", "ip_baseline_age", "ip_baseline_warn", "ip_baseline_set",
    "iphist_record", "iphist_count"))

# 出口历史相关:实例解析、文件路径、升级迁移、写入、只读计数。
IP_HISTORY_HELPERS = "\n".join(extract(n) for n in (
    "ip_key", "ip_show", "ip_key_migrate", "current_instance",
    "ip_history_file", "ip_lastip_file", "migrate_ip_state",
    "last_seen", "last_save", "iphist_record", "iphist_count"))

# check() 依赖的一整套外部命令。curl 由各用例按需覆盖,用来模拟三种出口状态。
CHECK_HARNESS = r"""
PROXY_MODE="shadowrocket"
load_check_config() { return 0; }
COUNTRY_TARGET="US"; TZ_TARGET="America/New_York"; LOCALE_TARGET="en_US"
FAKE_PREFIX="198.18."
BASE="$HOME"
proxy_alive() { return 0; }
tun_up() { return 0; }
readlink() { echo /var/db/timezone/zoneinfo/America/New_York; }
defaults() { case "$*" in *AppleLocale*) echo en_US ;; *) echo en-US ;; esac; }
networksetup() { echo 'IPv6: off'; }
dig() { echo '198.18.0.1'; }
webrtc_status() { echo 'ok:fixture'; }
bodyguard_status() { echo 'ok:fixture'; }
route_ok() { return 0; }
launchctl() { return 0; }
check_disabled() { return 1; }
support() { echo 'established:fixture'; }
ipv6_on_services() { :; }   # 空输出 = 所有服务的 IPv6 都关掉了
ip_purity() { echo 'ok|0|fixture||'; }
ecology_probe_start() { ECOLOGY_PID=""; }
ecology_probe_read() { ECO_CODE1="200:0.1"; ECO_CODE2="200:0.1"; }
ecology_probe_discard() { :; }
""" + extract_line("check_strict") + "\n" + extract("optional_failure") + "\n"


class ProbeEgressTests(unittest.TestCase):
    def run_probe(self, curl_body, count=3, budget=10):
        with tempfile.TemporaryDirectory() as tmp:
            src = "curl() { %s; }\n%s\nprobe_egress %d %d\necho \"status=$PROBE_STATUS\"\n" \
                  "echo \"ip=$PROBE_IP\"\necho \"seen=$PROBE_SEEN\"\n" % (
                      curl_body, PROBE_FN, count, budget)
            run = subprocess.run(["/bin/bash", "-c", src], cwd=tmp, text=True,
                                 capture_output=True, timeout=30)
        return run

    def test_stable_exit_is_ok(self):
        run = self.run_probe("printf 'ip=198.51.100.2\\nloc=US\\n'")
        self.assertIn("status=ok", run.stdout)
        self.assertIn("ip=198.51.100.2", run.stdout)

    def test_drifting_exit_is_unstable(self):
        # 每次返回不同出口 = 节点在漂移,必须能被识别出来。
        # 用文件计数而不是 shell 变量:curl 在命令替换的子 shell 里跑,变量不会回传。
        run = self.run_probe(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "printf 'ip=198.51.100.%s\\nloc=US\\n' \"$c\"")
        self.assertIn("status=unstable", run.stdout)

    def test_no_sample_at_all_is_unknown(self):
        run = self.run_probe("true")
        self.assertIn("status=unknown", run.stdout)

    def test_partial_failure_still_ok(self):
        # 3 次里只有 1 次拿到,但拿到的是一致的:算 ok,不因抖动判失败。
        run = self.run_probe(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "[ \"$c\" = 2 ] && printf 'ip=198.51.100.2\\nloc=US\\n'; true")
        self.assertIn("status=ok", run.stdout)

    def test_drift_stops_sampling_immediately(self):
        # 采样间不一致就立刻返回:再采只会更慢,结论不会变好。
        with tempfile.TemporaryDirectory() as tmp:
            src = ("curl() { c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
                   "printf 'ip=198.51.100.%s\\nloc=US\\n' \"$c\"; }\n"
                   + PROBE_FN + "\nprobe_egress 6 10\n"
                   "echo \"status=$PROBE_STATUS\"\necho \"calls=$(cat ctr)\"\n")
            run = subprocess.run(["/bin/bash", "-c", src], cwd=tmp, text=True,
                                 capture_output=True, timeout=30)
        self.assertIn("status=unstable", run.stdout)
        self.assertIn("calls=2", run.stdout, "第 2 次就不一致,不该继续采到第 6 次")

    def test_dual_stack_alternating_is_not_drift(self):
        # 同一节点双栈时,v4 与 v6 是两条腿,交替出现不是漂移。
        # 原来直接比原始串,这种机器会被判「出口在漂移」并拦住启动。
        run = self.run_probe(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "if [ $((c % 2)) = 1 ]; then printf 'ip=198.51.100.2\\nloc=US\\n'; "
            "else printf 'ip=2602:fa59:10:503::1\\nloc=US\\n'; fi", count=4)
        self.assertIn("status=ok", run.stdout)

    def test_v6_suffix_rotation_is_not_drift(self):
        # 同一 /64 内换接口标识:网段没变,账号来源没变。
        run = self.run_probe(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "printf 'ip=2602:fa59:10:503::%s\\nloc=US\\n' \"$c\"")
        self.assertIn("status=ok", run.stdout)

    def test_v6_prefix_change_is_drift(self):
        # 换了 /64 = 换了网段,这是真的在漂移,必须拦住。
        run = self.run_probe(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "printf 'ip=2602:fa59:10:%s::1\\nloc=US\\n' \"$((500 + c))\"")
        self.assertIn("status=unstable", run.stdout)

    def test_budget_caps_total_time(self):
        # 网络半死:每次 curl 都卡满 2 秒。总耗时必须封顶在预算内,否则会把 App 的
        # 45 秒检查超时吃光,用户看到的是「操作超时」而不是「网络在抖」。
        start = time.time()
        run = self.run_probe("sleep 2; true", count=6, budget=3)
        elapsed = time.time() - start
        self.assertIn("status=unknown", run.stdout)
        self.assertLess(elapsed, 7.0, "预算 3 秒不该跑到 %.1f 秒" % elapsed)


class IpIdentityTests(unittest.TestCase):
    """出口身份归一:比对用 key,展示用 show,历史统计按 key 去重。"""

    def run_bash(self, expr):
        return subprocess.run(["/bin/bash", "-c", IP_HELPERS + "\n" + expr],
                              text=True, capture_output=True, timeout=20).stdout.strip()

    def test_v4_keeps_full_address(self):
        self.assertEqual(self.run_bash("ip_key 198.51.100.2"), "v4:198.51.100.2")

    def test_v6_reduces_to_prefix(self):
        self.assertEqual(self.run_bash("ip_key 2602:fa59:10:503::1"),
                         "v6:2602:fa59:10:503")

    def test_show_strips_family_tag(self):
        # 界面上不该出现 v4:/v6: 这种内部记号。
        self.assertEqual(self.run_bash('ip_show "$(ip_key 2602:fa59:10:503::1)"'),
                         "2602:fa59:10:503")

    def test_legacy_lastip_is_migrated(self):
        # 升级前 lastip 存的是裸地址;不迁移的话第一次检查必然误报「IP 变了」。
        self.assertEqual(self.run_bash("ip_key_migrate 198.51.100.2"), "v4:198.51.100.2")
        self.assertEqual(self.run_bash("ip_key_migrate v6:2602:fa59:10:503"),
                         "v6:2602:fa59:10:503")

    def test_empty_ip_has_no_key(self):
        self.assertEqual(self.run_bash('ip_key "" || echo none'), "none")

    def test_families_keep_separate_last_seen(self):
        # 两族各自维护自己的「上次」:记了 v6 不能把 v4 的记录冲掉,
        # 否则下次回到 v4 时会再误报一次「IP 变了」。
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "lastip").write_text("144.172.103.106", encoding="utf-8")
            src = "BASE=" + tmp + "\n" + IP_HELPERS + "\n" + (
                "last_save v6:2602:fa59:10:503\n"
                'printf "v4=[%s]\\n" "$(last_seen v4)"\n'
                'printf "v6=[%s]\\n" "$(last_seen v6)"\n')
            out = subprocess.run(["/bin/bash", "-c", src], text=True,
                                 capture_output=True, timeout=20).stdout
        self.assertIn("v4=[v4:144.172.103.106]", out)
        self.assertIn("v6=[v6:2602:fa59:10:503]", out)

    def run_history(self, tmp, body):
        """在隔离环境里跑一段历史操作。record 负责写,count 只负责读。"""
        src = "BASE=%s\nIP_STABILITY_WINDOW=604800\n%s\n%s" % (
            tmp, IP_HISTORY_HELPERS, body)
        return subprocess.run(["/bin/bash", "-c", src], text=True,
                              capture_output=True, timeout=30)

    def test_history_counts_one_node_once(self):
        # 同一节点的 v4/v6 两种形态必须算一个出口,否则双栈机器「变化次数」翻倍,
        # 把正常使用报成账号画像风险。这里故意传裸地址:旧版历史文件里存的就是裸地址。
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_history(tmp, (
                "iphist_record 198.51.100.2\n"
                "iphist_record 2602:fa59:10:503::1\n"
                "iphist_record 2602:fa59:10:503::9\n"
                "iphist_record 203.0.113.7\n"
                "iphist_count\n")).stdout.strip()
        self.assertEqual(out, "2", "v4 + v6 同一节点算一个出口,另一个节点算第二个")

    def test_history_accepts_normalised_keys(self):
        # 生产路径传进来的是 curkey,已经是 v4:/v6: 归一后的形态。
        # 回归点:若再套一层 ip_key,v4:1.2.3.4 含冒号会被当成 v6 地址,
        # 归一成 v6:v4:1.2.3.4 —— 所有 v4 记录塌进 v6 一族,「按族取最大」失效。
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_history(tmp, (
                "iphist_record v4:198.51.100.2\n"
                "iphist_record v6:2602:fa59:10:503\n"
                "iphist_record v6:2602:fa59:10:503\n"
                "iphist_record v4:198.51.100.2\n"
                "iphist_count\n")).stdout.strip()
        self.assertEqual(out, "1", "跳走再切回来,窗口里仍然只有一个出口")

    def test_history_mixes_legacy_and_normalised_keys(self):
        # 升级现场:同一个出口既有旧版写的裸地址,又有新版写的归一键,还可能夹着
        # 另一族。三种形态必须归到同一个身份,不能各算一次。
        with tempfile.TemporaryDirectory() as tmp:
            now = int(time.time())
            (Path(tmp) / "iphistory.log").write_text("".join("%s %d\n" % (k, now) for k in (
                "144.172.103.106",          # 旧版裸 v4
                "v4:144.172.103.106",       # 新版归一 v4
                "2602:fa59:10:503::1",      # 旧版裸 v6
                "v6:2602:fa59:10:503",      # 新版归一 v6
            )), encoding="utf-8")
            out = self.run_history(tmp, "iphist_count\n").stdout.strip()
        self.assertEqual(out, "1", "两种写法的同一个出口只能算一个身份")

    def test_history_separates_real_exit_changes(self):
        # 真正的换出口必须照实统计 —— 修复不能顺手把告警也一起改没了。
        with tempfile.TemporaryDirectory() as tmp:
            out = self.run_history(tmp, (
                "iphist_record v4:198.51.100.2\n"
                "iphist_record v4:198.51.100.3\n"
                "iphist_record v4:198.51.100.4\n"
                "iphist_count\n")).stdout.strip()
        self.assertEqual(out, "3", "窗口内三个不同 v4 出口,就是 3 个")


class IpStabilityWindowTests(unittest.TestCase):
    """「一个实例一周内不应换出口」的口径。

    原来的写法是 48 小时窗口 + 3 个以上才提示。第 3 天换的出口到第 5 天就滑出
    窗口,统计从 2 掉回 1,看上去「一直很稳」;只换过一次时连提示都没有。
    """

    def run_bash(self, tmp, body):
        src = "BASE=%s\nIP_STABILITY_WINDOW=604800\n%s\n%s" % (tmp, IP_HISTORY_HELPERS, body)
        return subprocess.run(["/bin/bash", "-c", src], text=True,
                              capture_output=True, timeout=30)

    def test_exit_older_than_a_week_is_dropped(self):
        with tempfile.TemporaryDirectory() as tmp:
            now = int(time.time())
            (Path(tmp) / "iphistory.log").write_text(
                "v4:198.51.100.9 %d\n" % (now - 8 * 86400), encoding="utf-8")
            out = self.run_bash(tmp, "iphist_record v4:198.51.100.2\niphist_count\n").stdout.strip()
            lines = (Path(tmp) / "iphistory.log").read_text().splitlines()
        self.assertEqual(out, "1", "8 天前的出口已经出了承诺窗口,不该再算")
        self.assertEqual(len(lines), 1, "出了窗口的行要在下一次写入时裁掉,不能让文件无限长")

    def test_exit_inside_a_week_is_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            now = int(time.time())
            (Path(tmp) / "iphistory.log").write_text(
                "v4:198.51.100.9 %d\n" % (now - 6 * 86400), encoding="utf-8")
            out = self.run_bash(tmp, "iphist_record v4:198.51.100.2\niphist_count\n").stdout.strip()
        self.assertEqual(out, "2", "6 天前的出口仍在窗口内 —— 一周内换过就是换过")

    def test_steady_state_does_not_touch_the_history_file(self):
        # 这是响应速度的关键:出口没变就一个字节都不写。
        # 原来的写法每次检查都重写整个文件(实测 2000 行 1.3s / 2 万行 13s),
        # 而它对当次结论毫无贡献 —— 检查的热路径不该为「留证据」付钱。
        with tempfile.TemporaryDirectory() as tmp:
            body = "iphist_record v4:198.51.100.2\n" + \
                "".join("iphist_record v4:198.51.100.2\n" for _ in range(30))
            self.run_bash(tmp, body)
            lines = (Path(tmp) / "iphistory.log").read_text().splitlines()
        self.assertEqual(len(lines), 1, "同一出口重复 31 次,文件里只该留一行")

    def test_instances_do_not_share_history(self):
        # A 换节点不能被记到 B 头上,否则「一个实例一周不变」无从判定。
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "current").write_text("A\n", encoding="utf-8")
            first = self.run_bash(
                tmp, "iphist_record v4:198.51.100.2\niphist_count\n").stdout.strip()
            (Path(tmp) / "current").write_text("B\n", encoding="utf-8")
            second = self.run_bash(
                tmp, "iphist_record v4:203.0.113.7\niphist_count\n").stdout.strip()
            a = (Path(tmp) / "iphistory-A.log").exists()
            b = (Path(tmp) / "iphistory-B.log").exists()
        self.assertEqual(first, "1")
        self.assertEqual(second, "1", "B 只见过自己的出口,不该看到 A 的记录")
        self.assertTrue(a and b, "两个实例各写自己的文件")

    def test_legacy_single_history_is_migrated_to_current_instance(self):
        # 升级现场:旧版只有一份 iphistory.log。不迁移的话「一周内变过」的证据
        # 会凭空消失,变成一片绿。
        with tempfile.TemporaryDirectory() as tmp:
            now = int(time.time())
            (Path(tmp) / "current").write_text("B\n", encoding="utf-8")
            (Path(tmp) / "iphistory.log").write_text(
                "v4:198.51.100.9 %d\n" % (now - 3600), encoding="utf-8")
            out = self.run_bash(tmp, "iphist_record v4:203.0.113.7\niphist_count\n").stdout.strip()
            legacy_gone = not (Path(tmp) / "iphistory.log").exists()
            migrated = (Path(tmp) / "iphistory-B.log").exists()
        self.assertEqual(out, "2", "迁移过来的旧出口必须仍然算数")
        self.assertTrue(legacy_gone and migrated, "旧文件应被认给当前实例,而不是留着两份")

    def test_decision_is_baseline_equality_not_window_count(self):
        # 判据必须是「现在用的是不是那条固定出口」,不是「窗口里出现过几个出口」。
        # 后者会把「跳到别处 → 被熔断 → 切回原出口」记成一次风险,
        # 而用户回来继续用原来那条固定 IP,本来就是合理的。
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("IP_STABILITY_LIMIT", text,
                         "「数出几个出口才告警」的口径已经废掉,不能再留一半")
        # 文案只有一处来源:check 与 checkdetail 各写一份,必然有一天只改一边。
        self.assertEqual(text.count("ip_baseline_warn \""), 2,
                         "check 与 checkdetail 都该调同一个文案函数")


class CheckEgressGateTests(unittest.TestCase):
    """check() 面对 unknown 与 unstable 的两种不同处理。"""

    def run_check(self, curl_body, disabled="", lastip=None, baseline=None,
                  baseline_age_days=None, strict=""):
        """跑一次真的 check()。

        baseline 是「这条实例的固定出口」;baseline_age_days 模拟它固定了多久。
        两者都不给 = 第一次运行(基线还没记录)。
        """
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            if lastip:
                (Path(tmp) / "lastip").write_text(lastip, encoding="utf-8")
            if baseline:
                when = int(time.time()) - int((baseline_age_days or 0) * 86400)
                (Path(tmp) / "ipbaseline").write_text(
                    "%s %d\n" % (baseline, when), encoding="utf-8")
            # 需要模拟「用户关掉了某项」时,把 check_disabled 换成真读 CHECKS_DISABLED 的版本
            # (后面定义的同名函数覆盖 harness 里的桩)。
            override = ""
            if disabled:
                override += (
                    'CHECKS_DISABLED="%s"\n'
                    'check_disabled() { case ",$CHECKS_DISABLED," in *",$1,"*) return 0 ;; '
                    '*) return 1 ;; esac; }\n' % disabled)
            if strict:
                override += 'CHECKS_STRICT="%s"\n' % strict
            src = CHECK_HARNESS + "\ncurl() { %s; }\n" % curl_body + override + \
                IP_BASELINE_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            return subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                  text=True, capture_output=True, timeout=60)

    def test_cross_family_exit_does_not_warn(self):
        # 实测踩到的误报:同一节点上次报 v4、这次报 v6,被判成「IP 变了」。
        # 两条腿不可比,不该拿一个去比另一个。
        run = self.run_check("printf 'ip=2602:fa59:10:503::1\\nloc=US\\n'",
                             lastip="144.172.103.106")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("不一致", run.stdout)

    def test_hosting_ip_change_is_flagged(self):
        # 机房 IP 变动是明确的风控信号:固定出口是硬要求。
        run = self.run_check(
            'case "$*" in *ipinfo.io*) printf \'{"org":"AS14956 RouterHosting LLC"}\' ;; '
            '*) printf \'ip=198.51.100.2\\nloc=US\\n\' ;; esac',
            baseline="v4:203.0.113.9", baseline_age_days=3)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("机房出口应固定一个", run.stdout)
        # 当前值、基线值、基线固定了多久,三样都要给 —— 少一样用户就没法判断
        # 是「忘了切回」还是「这条实例本来就该换」。
        self.assertIn("当前 198.51.100.2", run.stdout)
        self.assertIn("基线 203.0.113.9", run.stdout)
        self.assertIn("已固定 3 天", run.stdout)

    def test_first_run_records_baseline_without_warning(self):
        # 第一次跑没有基线可比:记下来,不告警。否则升级当天所有人都会先挨一条假警告。
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            src = CHECK_HARNESS + "\ncurl() { printf 'ip=198.51.100.2\\nloc=US\\n'; }\n" + \
                IP_BASELINE_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            run = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                 text=True, capture_output=True, timeout=60)
            saved = (Path(tmp) / "ipbaseline").read_text(encoding="utf-8").split()
        self.assertNotIn("基线", run.stdout)
        self.assertEqual(saved[0], "v4:198.51.100.2")
        self.assertTrue(saved[1].isdigit(), "基线必须带时间,否则说不出「已固定多久」")

    def test_returning_to_the_fixed_ip_is_silent(self):
        # 用户要的场景:一个人一条固定 IP,中途跳了、被检测到、软件退出,
        # 他回来继续用原来那条 IP —— 基线从没变过,不该有任何提示。
        # 历史里留着那个跳过去的出口也没关系:判据是基线,不是历史。
        run = self.run_check(
            "printf 'ip=198.51.100.2\\nloc=US\\n'",
            baseline="v4:198.51.100.2", baseline_age_days=30,
            lastip="v4:203.0.113.7")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("不一致", run.stdout)
        self.assertNotIn("注意", run.stdout)

    def test_mismatch_does_not_silently_adopt_the_new_exit(self):
        # 不一致时绝不能顺手把基线改成新的 —— 那等于「跳了就跳了」,
        # 一周不变这条承诺当场作废。改基线必须由用户显式 accept。
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            (Path(tmp) / "ipbaseline").write_text(
                "v4:203.0.113.9 %d\n" % (int(time.time()) - 86400), encoding="utf-8")
            src = CHECK_HARNESS + "\ncurl() { printf 'ip=198.51.100.2\\nloc=US\\n'; }\n" + \
                IP_BASELINE_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                           text=True, capture_output=True, timeout=60)
            after = (Path(tmp) / "ipbaseline").read_text(encoding="utf-8").split()[0]
        self.assertEqual(after, "v4:203.0.113.9", "基线只能由 ip-baseline accept 改")

    def test_residential_ip_change_is_soft(self):
        # 家宽 IP 定期轮换是正常网络行为。拿机房的措辞套家宽,只会制造假警报,
        # 最后用户学会忽略这条提示 —— 那比不提示更糟。
        # 但也不能不吭声:用户选了「固定出口」这条承诺,变了就得让他知道。
        run = self.run_check(
            'case "$*" in *ipinfo.io*) printf \'{"org":"AS7922 Comcast Cable Communications"}\' ;; '
            '*) printf \'ip=198.51.100.2\\nloc=US\\n\' ;; esac',
            baseline="v4:203.0.113.9", baseline_age_days=9)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("家宽轮换概率大", run.stdout)
        self.assertNotIn("机房", run.stdout)

    def test_disabled_checks_are_named_in_the_gate_output(self):
        # 关掉某项防护是用户的选择,但不能是「悄悄没了」:门禁输出里必须留痕,
        # 否则命令行、日志、自动化这些看不到界面的地方就完全无从判断。
        run = self.run_check("printf 'ip=198.51.100.2\\nloc=US\\n'",
                             disabled="WebRTC,客户端语言")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("防护降级", run.stdout)
        self.assertIn("WebRTC", run.stdout)
        self.assertIn("客户端语言", run.stdout)

    def test_no_degradation_note_when_nothing_is_disabled(self):
        run = self.run_check("printf 'ip=198.51.100.2\\nloc=US\\n'")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("防护降级", run.stdout)

    def test_unknown_does_not_block_launch(self):
        # 抖动导致的取不到,不该拦住 Claude 启动;但必须写明「未确认」。
        run = self.run_check("true")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("未确认", run.stdout)
        self.assertNotIn("出口IP异常", run.stdout)

    def test_unstable_blocks(self):
        run = self.run_check(
            "c=$(cat ctr 2>/dev/null || echo 0); c=$((c+1)); echo $c > ctr; "
            "printf 'ip=198.51.100.%s\\nloc=US\\n' \"$c\"")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("漂移", run.stdout)

    def test_wrong_country_still_blocks(self):
        run = self.run_check("printf 'ip=198.51.100.2\\nloc=JP\\n'")
        self.assertNotEqual(run.returncode, 0, run.stdout)
        # 文案要同时给出当前值与期望值:只说「异常」用户不知道该改哪边。
        self.assertIn("出口IP不符(当前 198.51.100.2/JP,期望 US)", run.stdout)

    def test_negative_control_baseline_match_is_quiet(self):
        # 负例对照:把同样的输入换成「与基线一致」,上面那些告警必须全部消失。
        # 少了这一条,「机房出口应固定一个」可能在任何情况下都打印,测试照样绿。
        run = self.run_check(
            'case "$*" in *ipinfo.io*) printf \'{"org":"AS14956 RouterHosting LLC"}\' ;; '
            '*) printf \'ip=198.51.100.2\\nloc=US\\n\' ;; esac',
            baseline="v4:198.51.100.2", baseline_age_days=3)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("机房出口应固定一个", run.stdout)


class StrictBaselineTests(unittest.TestCase):
    """「生态可达性」可以设成安全基线:设了就必须可达。

    默认它是「可选项」:失败时按 allowOptionalFailures 的策略处理(用户勾了容忍
    可选项失败就只提示)。一旦设成安全基线,这条策略对它失效 —— 必须可达。
    有些人对账号安全的要求更高,愿意用「宁可打不开也不在可疑环境里用」换确定性;
    但不能替所有人做这个决定,所以默认不开。
    """

    def run_check(self, eco_codes, strict="", allow_optional=False):
        override = (
            'ecology_probe_read() { ECO_CODE1="%s"; ECO_CODE2="%s"; }\n' % eco_codes)
        if allow_optional:
            override += 'ALLOW_OPTIONAL_FAILURES="1"\n'
        if strict:
            override += 'CHECKS_STRICT="%s"\n' % strict
        src = CHECK_HARNESS + override + \
            "curl() { printf 'ip=198.51.100.2\\nloc=US\\n'; }\n" + \
            IP_BASELINE_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            env = dict(os.environ, HOME=tmp)
            return subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                  text=True, capture_output=True, timeout=60)

    def test_unreachable_ecology_blocks_by_default(self):
        run = self.run_check(("000:0", "000:0"))
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("Anthropic生态不可达", run.stdout)

    def test_tolerated_optional_failure_does_not_block(self):
        # 负例对照:用户明确勾了「容忍可选项失败」,这一项就不该拦住启动。
        run = self.run_check(("000:0", "000:0"), allow_optional=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_strict_overrides_tolerance(self):
        # 设成安全基线的意义就在这条:用户勾了容忍,它照样拦。
        run = self.run_check(("000:0", "000:0"), strict="生态可达性", allow_optional=True)
        self.assertNotEqual(run.returncode, 0, run.stdout)
        self.assertIn("Anthropic生态不可达", run.stdout)

    def test_reachable_ecology_never_blocks(self):
        # 负例对照:可达时不管 strict 与否都不该拦 —— 否则「设了基线就一定红」。
        run = self.run_check(("200:0.2", "200:0.3"), strict="生态可达性",
                             allow_optional=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("不可达", run.stdout)

    def test_strict_and_disabled_cannot_coexist(self):
        # 既关掉又设成基线是自相矛盾的配置,必须在解析时挡住,
        # 否则用户会以为「已经是最严」,实际这项根本没跑。
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            run = subprocess.run(
                [str(SCRIPT), "set-check-config",
                 '{"disabled":["生态可达性"],"strict":["生态可达性"]}'],
                env=env, text=True, capture_output=True, timeout=30)
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_strict_alone_is_accepted_and_read_back(self):
        # 负例对照:不矛盾时写入必须成功,并且读得回来 ——
        # 否则上面那条「拒绝矛盾配置」可能只是因为整条命令从来不工作。
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            write = subprocess.run(
                [str(SCRIPT), "set-check-config", '{"strict":["生态可达性"]}'],
                env=env, text=True, capture_output=True, timeout=30)
            read = subprocess.run([str(SCRIPT), "get-check-config"],
                                  env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(write.returncode, 0, write.stdout + write.stderr)
        self.assertIn("生态可达性", read.stdout)


class VerdictTests(unittest.TestCase):
    def call(self, *args, home):
        env = dict(os.environ, HOME=home)
        return subprocess.run(["/bin/bash", str(SCRIPT), *args], env=env,
                              text=True, capture_output=True, timeout=30)

    def test_established_when_no_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "出口IP=ok:198.51.100.2\nWebRTC=ok:仅暴露代理出口IP\n"
                "ASN属性=warn:疑似机房\n客户端语言=skip:用户已禁用\n", encoding="utf-8")
            run = self.call("verdict", home=tmp)
        self.assertIn("VERDICT:established", run.stdout)
        # warn 只算 advisory,不能被当成 pass,也不能被当成 fail
        self.assertIn("advisories=ASN属性", run.stdout)
        self.assertIn("blockers=\n", run.stdout)

    def test_violated_when_any_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "出口IP=ok:198.51.100.2\n规则置顶=fail:未生效\n", encoding="utf-8")
            run = self.call("verdict", home=tmp)
        self.assertIn("VERDICT:violated", run.stdout)
        self.assertIn("blockers=规则置顶", run.stdout)

    def test_config_is_a_blocker_not_a_pass(self):
        # config = 环境层没就绪,它和 fail 一样拦启动。早先解析只认 ok/warn/fail/skip,
        # config 行被直接丢掉 —— 离线复核会把「没配好」判成 established。
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "代理内核=ok:x\n规则置顶=config:环境层未就绪(未取到代理组) · 点「一键修复」\n",
                encoding="utf-8")
            run = self.call("verdict", home=tmp)
        self.assertIn("VERDICT:violated", run.stdout)
        self.assertIn("blockers=规则置顶", run.stdout)

    def test_all_skipped_is_incomplete_not_established(self):
        # 检查项全关掉之后,「没有失败」不等于「验过了」。
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "WebRTC=skip:用户已禁用\nDNS=skip:用户已禁用\n", encoding="utf-8")
            run = self.call("verdict", home=tmp)
        self.assertIn("VERDICT:incomplete", run.stdout)

    def test_empty_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "empty.txt"
            path.write_text("", encoding="utf-8")
            run = self.call("verdict", str(path), home=tmp)
        self.assertEqual(run.returncode, 2)


class EvidenceTests(unittest.TestCase):
    def test_writes_structured_evidence_and_refuses_overwrite(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "出口IP=ok:198.51.100.2\nWebRTC=fail:STUN 暴露了非代理出口地址\n",
                encoding="utf-8")
            out = Path(tmp) / "ev.json"
            env = dict(os.environ, HOME=tmp)
            first = subprocess.run(["/bin/bash", str(SCRIPT), "evidence", str(out)],
                                   env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            doc = json.loads(out.read_text(encoding="utf-8"))
            self.assertEqual(doc["schema_version"], "claude-switcher-evidence/0.1")
            self.assertEqual(doc["verdict"], "violated")
            self.assertEqual(doc["items"]["WebRTC"]["status"], "fail")
            self.assertEqual(oct(out.stat().st_mode & 0o777), "0o600")

            # 证据被覆盖就失去追溯意义,第二次必须拒绝
            second = subprocess.run(["/bin/bash", str(SCRIPT), "evidence", str(out)],
                                    env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(second.returncode, 2)
            self.assertIn("未覆盖", second.stderr)

    def test_all_skipped_evidence_is_incomplete(self):
        """全部关掉时「没有失败」不等于「验过了」,证据不能记成 established。"""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "WebRTC=skip:已关闭\nASN属性=skip:已关闭\n", encoding="utf-8")
            out = Path(tmp) / "ev.json"
            env = dict(os.environ, HOME=tmp)
            run = subprocess.run(["/bin/bash", str(SCRIPT), "evidence", str(out)],
                                 env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["verdict"],
                             "incomplete")

    def test_config_evidence_is_violated(self):
        """环境层没就绪和实测不达标一样拦启动,证据里都要记成 violated。"""
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp) / ".claude-switcher"
            base.mkdir()
            (base / "last-check.txt").write_text(
                "出口IP=ok:198.51.100.2\n时区=config:未配置\n", encoding="utf-8")
            out = Path(tmp) / "ev.json"
            env = dict(os.environ, HOME=tmp)
            run = subprocess.run(["/bin/bash", str(SCRIPT), "evidence", str(out)],
                                 env=env, text=True, capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["verdict"],
                             "violated")


TUN_STATE_FN = extract("tun_state")


class TunStateTests(unittest.TestCase):
    """tun_state 对内核 /configs 的解析。

    踩过的坑:最初用 sed 的 \\| 交替写 (true\\|false),macOS 自带 BSD sed 和这台
    机器上的 toybox sed 都不支持 —— 静默返回空值,演练就把「TUN 已关」误判成
    「没关掉」,直接判演练无效。这里用真实内核返回的 JSON 形状做回归。
    """

    def run_state(self, payload):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "configs.json"
            cfg.write_text(payload, encoding="utf-8")
            src = ("clash_sock() { echo %s; }\n" % (Path(tmp) / "s.sock")) + \
                TUN_STATE_FN + "\n" + \
                "curl() { cat '%s'; }\n" % cfg + \
                "tun_state\n"
            return subprocess.run(["/bin/bash", "-c", src], cwd=tmp, text=True,
                                  capture_output=True, timeout=20)

    def test_enabled(self):
        # 真实形状:enable 后面还挂着一串键,JSON 里带空格
        run = self.run_state('{"mode": "rule", "tun": {"enable": true, '
                             '"device": "utun1024", "stack": "Mixed", '
                             '"auto-route": true}, "ipv6": false}')
        self.assertEqual(run.stdout.strip(), "true")

    def test_disabled(self):
        run = self.run_state('{"mode": "rule", "tun": {"enable": false, '
                             '"device": "utun1024"}}')
        self.assertEqual(run.stdout.strip(), "false")

    def test_missing_tun_is_unknown(self):
        run = self.run_state('{"mode": "rule", "ipv6": false}')
        self.assertEqual(run.stdout.strip(), "unknown")


if __name__ == "__main__":
    unittest.main()
