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


PROBE_FN = extract("probe_egress")
CHECK_FN = extract("check")

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
    def run_probe(self, curl_body, count=3):
        with tempfile.TemporaryDirectory() as tmp:
            src = "curl() { %s; }\n%s\nprobe_egress %d\necho \"status=$PROBE_STATUS\"\n" \
                  "echo \"ip=$PROBE_IP\"\necho \"seen=$PROBE_SEEN\"\n" % (curl_body, PROBE_FN, count)
            run = subprocess.run(["/bin/bash", "-c", src], cwd=tmp, text=True,
                                 capture_output=True, timeout=20)
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


class CheckEgressGateTests(unittest.TestCase):
    """check() 面对 unknown 与 unstable 的两种不同处理。"""

    def run_check(self, curl_body):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Library" / "Logs").mkdir(parents=True, exist_ok=True)
            src = CHECK_HARNESS + "\ncurl() { %s; }\n" % curl_body + \
                PROBE_FN + "\n" + CHECK_FN + "\ncheck\n"
            env = dict(os.environ, HOME=tmp)
            return subprocess.run(["/bin/bash", "-c", src], env=env, cwd=tmp,
                                  text=True, capture_output=True, timeout=60)

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
