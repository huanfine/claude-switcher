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


PROBE_FN = extract("ip_key") + "\n\n" + extract("probe_egress")
CHECK_FN = extract("check")

# 出口身份归一:check() 与 probe_egress() 都靠它,隔离环境里必须一起带上。
IP_HELPERS = "\n".join(extract(n) for n in (
    "ip_key", "ip_show", "ip_key_migrate", "ip_org", "ip_class",
    "last_seen", "last_save"))

# check() 依赖的一整套外部命令。curl 由各用例按需覆盖,用来模拟三种出口状态。
CHECK_HARNESS = r"""
PROXY_MODE="shadowrocket"
load_check_config() { return 0; }
COUNTRY_TARGET="US"; TZ_TARGET="America/New_York"; LOCALE_TARGET="en_US"
FAKE_PREFIX="198.18."
BASE="$HOME"
proxy_alive() { return 0; }
tun_up() { return 0; }
iphist_count() { echo 0; }
readlink() { echo /var/db/timezone/zoneinfo/America/New_York; }
defaults() { case "$*" in *AppleLocale*) echo en_US ;; *) echo en-US ;; esac; }
networksetup() { echo 'IPv6: off'; }
dig() { echo '198.18.0.1'; }
webrtc_status() { echo 'ok:fixture'; }
bodyguard_status() { echo 'ok:fixture'; }
route_ok() { return 0; }
launchctl() { return 0; }
check_disabled() { return 1; }
"""


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

    def test_history_counts_one_node_once(self):
        # 同一节点的 v4/v6 两种形态在 48h 统计里必须算一个出口,
        # 否则双栈机器「变化次数」翻倍,把正常使用报成账号画像风险。
        # 这里故意传裸地址:旧版本历史文件里存的就是裸地址,升级后要能继续读。
        with tempfile.TemporaryDirectory() as tmp:
            src = "BASE=%s\n%s\n%s\n" % (tmp, IP_HELPERS, extract("iphist_count")) + \
                "iphist_count 198.51.100.2 >/dev/null\n" \
                "iphist_count 2602:fa59:10:503::1 >/dev/null\n" \
                "iphist_count 2602:fa59:10:503::9 >/dev/null\n" \
                "iphist_count 203.0.113.7\n"
            out = subprocess.run(["/bin/bash", "-c", src], text=True,
                                 capture_output=True, timeout=20).stdout.strip()
        self.assertEqual(out, "2", "v4 + v6 同一节点算一个出口,另一个节点算第二个")

    def test_history_accepts_normalised_keys(self):
        # 生产路径传进来的是 curkey,已经是 v4:/v6: 归一后的形态,不是裸地址。
        # 回归点:这里若再套一层 ip_key,v4:1.2.3.4 含冒号会被当成 v6 地址,
        # 归一成 v6:v4:1.2.3.4 —— 所有 v4 记录塌进 v6 一族,「按族取最大」失效,
        # 一个没换过的节点被数成多次变动并报 warn,而这项用户无从修复。
        with tempfile.TemporaryDirectory() as tmp:
            src = "BASE=%s\n%s\n%s\n" % (tmp, IP_HELPERS, extract("iphist_count")) + \
                "iphist_count v4:198.51.100.2 >/dev/null\n" \
                "iphist_count v6:2602:fa59:10:503 >/dev/null\n" \
                "iphist_count v6:2602:fa59:10:503 >/dev/null\n" \
                "iphist_count v4:198.51.100.2\n"
            out = subprocess.run(["/bin/bash", "-c", src], text=True,
                                 capture_output=True, timeout=20).stdout.strip()
        self.assertEqual(out, "1", "同一出口反复记录,两族各一个身份,取最大仍是 1")

    def test_history_mixes_legacy_and_normalised_keys(self):
        # 升级现场:同一个出口既有旧版写的裸地址,又有新版写的归一键,
        # 还可能夹着另一族的写法。三种形态必须归到同一个身份,不能各算一次。
        with tempfile.TemporaryDirectory() as tmp:
            hist = Path(tmp) / "iphistory.log"
            now = int(time.time())
            hist.write_text("".join("%s %d\n" % (k, now) for k in (
                "144.172.103.106",          # 旧版裸 v4
                "v4:144.172.103.106",       # 新版归一 v4
                "2602:fa59:10:503::1",      # 旧版裸 v6
                "v6:2602:fa59:10:503",      # 新版归一 v6
            )), encoding="utf-8")
            src = "BASE=%s\n%s\n%s\n" % (tmp, IP_HELPERS, extract("iphist_count")) + \
                "iphist_count v4:144.172.103.106\n"
            out = subprocess.run(["/bin/bash", "-c", src], text=True,
                                 capture_output=True, timeout=20).stdout.strip()
        self.assertEqual(out, "1", "两种写法的同一个出口只能算一个身份")

    def test_history_separates_real_exit_changes(self):
        # 真正的换出口必须照实统计 —— 修复不能顺手把告警也一起改没了。
        with tempfile.TemporaryDirectory() as tmp:
            src = "BASE=%s\n%s\n%s\n" % (tmp, IP_HELPERS, extract("iphist_count")) + \
                "iphist_count v4:198.51.100.2 >/dev/null\n" \
                "iphist_count v4:198.51.100.3 >/dev/null\n" \
                "iphist_count v4:198.51.100.4\n"
            out = subprocess.run(["/bin/bash", "-c", src], text=True,
                                 capture_output=True, timeout=20).stdout.strip()
        self.assertEqual(out, "3", "48h 内三个不同 v4 出口,就是 3 次")


class CheckEgressGateTests(unittest.TestCase):
    """check() 面对 unknown 与 unstable 的两种不同处理。"""

    def run_check(self, curl_body, disabled="", lastip=None):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            if lastip:
                (Path(tmp) / "lastip").write_text(lastip, encoding="utf-8")
            # 需要模拟「用户关掉了某项」时,把 check_disabled 换成真读 CHECKS_DISABLED 的版本
            # (后面定义的同名函数覆盖 harness 里的桩)。
            override = ""
            if disabled:
                override = (
                    'CHECKS_DISABLED="%s"\n'
                    'check_disabled() { case ",$CHECKS_DISABLED," in *",$1,"*) return 0 ;; '
                    '*) return 1 ;; esac; }\n' % disabled)
            src = CHECK_HARNESS + "\ncurl() { %s; }\n" % curl_body + override + \
                IP_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            return subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                  text=True, capture_output=True, timeout=60)

    def test_cross_family_exit_does_not_warn(self):
        # 实测踩到的误报:同一节点上次报 v4、这次报 v6,被判成「IP 变了」。
        # 两条腿不可比,不该拿一个去比另一个。
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            (Path(tmp) / "lastip").write_text("144.172.103.106", encoding="utf-8")
            src = CHECK_HARNESS + "\ncurl() { printf 'ip=2602:fa59:10:503::1\\nloc=US\\n'; }\n" + \
                IP_HELPERS + "\n" + PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            run = subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                 text=True, capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("与上次不同", run.stdout)

    def test_hosting_ip_change_is_flagged(self):
        # 机房 IP 变动是明确的风控信号:固定出口是硬要求。
        run = self.run_check(
            'case "$*" in *ipinfo.io*) printf \'{"org":"AS14956 RouterHosting LLC"}\' ;; '
            '*) printf \'ip=198.51.100.2\\nloc=US\\n\' ;; esac',
            lastip="203.0.113.9")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("机房 IP 发生变动", run.stdout)

    def test_residential_ip_change_is_not_flagged(self):
        # 家宽 IP 定期轮换是正常网络行为。拿机房的标准套家宽,只会制造假警报,
        # 最后用户学会忽略这条提示 —— 那比不提示更糟。
        run = self.run_check(
            'case "$*" in *ipinfo.io*) printf \'{"org":"AS7922 Comcast Cable Communications"}\' ;; '
            '*) printf \'ip=198.51.100.2\\nloc=US\\n\' ;; esac',
            lastip="203.0.113.9")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("与上次不同", run.stdout)
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
