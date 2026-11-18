"""代理专用探测通道与 drill 计数器的回归测试。

报告 v2 的 16 行文本契约不变。新增的 probes 是可选 sidecar:
  - proxy 走正常链路测连通性/延迟;
  - direct 在 TUN 开启时无法有效测量,必须显式 unknown,不能用 0 冒充;
  - drill 的 TCP/DNS/WebRTC 计数器各自带状态,命令/探针不可用时为 unknown。
旧报告没有这些字段时,指纹与租约语义都不能变。
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
FULL = """\
代理内核=ok:Clash Verge 运行中
TUN网卡=ok
出口IP=ok:203.0.113.10/US
IP一致=ok:首次记录
时区=ok
地区=ok
IPv6=ok:已关闭
DNS=ok:走隧道
WebRTC=ok:仅暴露代理出口IP
保镖=ok:待命
规则置顶=ok
客户端语言=ok:en-US
ASN属性=ok:Example Residential
IP纯净度=ok:100/100 · 住宅宽带
生态可达性=ok:claude.ai:200 api:200
更优节点=skip:尚未扫描
"""


def extract(name):
    text = SCRIPT.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^%s\(\) \{\n.*?^\}" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到函数 %s" % name)
    return match.group(0)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="probes-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        self.base = self.home / ".claude-switcher"
        self.base.mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        CLAUDE_SWITCHER_PYTHON=os.environ.get("PYTHON", "python3"))

    def support(self, *args, env=None):
        return subprocess.run(["/bin/bash", str(SCRIPT), "_support", *args],
                              env=env or self.env, text=True, capture_output=True, timeout=30)

    def stub_curl(self, body):
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir(exist_ok=True)
        path = bin_dir / "curl"
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        env = dict(self.env, PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        return env

    def test_proxy_probe_records_latency_and_explicit_direct_unknown(self):
        env = self.stub_curl("printf '200 0.123\\n'")
        run = self.support("probe", "2026-11-11 12:00:00", env=env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads(run.stdout)
        self.assertEqual(doc["schema"], "claude-switcher-probes/1")
        self.assertEqual(doc["proxy"]["status"], "ok")
        self.assertEqual(doc["proxy"]["http_code"], 200)
        self.assertEqual(doc["proxy"]["latency_ms"], 123)
        self.assertEqual(doc["direct"]["status"], "unknown")
        self.assertEqual(doc["direct"]["reason"], "not_measured_while_tun_up")
        self.assertEqual(stat.S_IMODE((self.base / "probes.json").stat().st_mode), 0o600)

    def test_probe_failure_is_not_reported_as_zero(self):
        env = self.stub_curl("printf '000 0.000\\n'; exit 7")
        run = self.support("probe", "2026-11-11 12:00:00", env=env)
        doc = json.loads(run.stdout)
        self.assertEqual(doc["proxy"]["status"], "fail")
        self.assertIsNone(doc["proxy"]["latency_ms"])

    def test_drill_counters_keep_unknown_distinct_from_zero(self):
        run = self.support("drill-record", "2026-11-11 12:01:00", "established",
                           "ok", "4", "2", "1500",
                           "unknown", "0", "0", "0",
                           "fail", "0", "1", "800")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        doc = json.loads((self.base / "drill-counters.json").read_text(encoding="utf-8"))
        self.assertEqual(doc["tcp"], {"status": "ok", "success": 4, "failure": 2,
                                      "elapsed_ms": 1500})
        self.assertEqual(doc["dns"], {"status": "unknown", "success": None,
                                      "failure": None, "elapsed_ms": None})
        self.assertEqual(doc["webrtc"]["failure"], 1)

    def test_report_includes_probes_without_changing_fingerprint(self):
        env = self.stub_curl("printf '200 0.050\\n'")
        text = "# 2026-11-11 12:00:00 pid=1 开始\n" + FULL
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text(text, encoding="utf-8")
        before = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(before.returncode, 0, before.stdout + before.stderr)
        old = json.loads(before.stdout)
        self.assertNotIn("probes", old)

        self.assertEqual(self.support("probe", "2026-11-11 12:00:00", env=env).returncode, 0)
        self.assertEqual(self.support("drill-record", "2026-11-11 12:01:00", "established",
                                      "ok", "3", "0", "900",
                                      "fail", "0", "3", "100",
                                      "unknown", "0", "0", "0").returncode, 0)
        after = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(after.returncode, 0, after.stdout + after.stderr)
        new = json.loads(after.stdout)
        self.assertEqual(new["config_fingerprint"], old["config_fingerprint"])
        self.assertEqual(new["probes"]["proxy"]["status"], "ok")
        self.assertEqual(new["probes"]["direct"]["status"], "unknown")
        self.assertEqual(new["probes"]["drill"]["tcp"]["success"], 3)
        self.assertIsNone(new["probes"]["drill"]["webrtc"]["success"])

    def test_probe_sidecar_for_another_run_is_ignored(self):
        path = Path(self.tmp.name) / "last-check.txt"
        path.write_text("# 2026-11-11 12:00:00 pid=1 开始\n" + FULL, encoding="utf-8")
        self.assertEqual(self.support("probe", "2026-11-11 12:00:01").returncode, 0)
        run = self.support("report", str(path), str(SCRIPT))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn("probes", json.loads(run.stdout))

    def test_drill_function_emits_counters_and_records_sidecar(self):
        captured = Path(self.tmp.name) / "recorded.txt"
        harness = "\n".join((
            "BASE=%s" % self.tmp.name,
            "PROBE_IP=; PROBE_STATUS=unknown",
            "proxy_alive() { return 0; }",
            "tun_up() { return 0; }",
            "clash_sock() { echo /tmp/fake.sock; }",
            "probe_egress() { PROBE_IP=198.51.100.9; PROBE_STATUS=ok; }",
            "tun_set() { echo \"$1\" > %s/state; }" % self.tmp.name,
            "tun_state() { cat %s/state 2>/dev/null || echo true; }" % self.tmp.name,
            "webrtc_test() { echo RESULT:198.51.100.9; }",
            "support() { printf '%%s\\n' \"$@\" > %s; }" % captured,
            extract("drill"),
            "drill --auto --yes",
        ))
        bin_dir = Path(self.tmp.name) / "bin"
        bin_dir.mkdir()
        (bin_dir / "curl").write_text(
            "#!/bin/bash\nprintf 'ip=198.51.100.9\\n'; exit 0\n", encoding="utf-8")
        (bin_dir / "curl").chmod(0o755)
        (bin_dir / "dig").write_text("#!/bin/bash\necho 198.51.100.10\n", encoding="utf-8")
        (bin_dir / "dig").chmod(0o755)
        (Path(self.tmp.name) / "stun-probe.py").write_text("", encoding="utf-8")
        env = dict(self.env, PATH=str(bin_dir) + ":/usr/bin:/bin:/usr/sbin:/sbin")
        run = subprocess.run(["/bin/bash", "-c", harness], env=env, cwd=self.tmp.name,
                             text=True, capture_output=True, timeout=30)
        self.assertIn("PROBE:tcp=ok success=6 failure=0", run.stdout)
        self.assertIn("PROBE:dns=ok success=3 failure=0", run.stdout)
        self.assertIn("PROBE:webrtc=ok success=1 failure=0", run.stdout)
        recorded = captured.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(recorded), 15, recorded)
        self.assertEqual(recorded[0], "drill-record")
        self.assertEqual(recorded[3], "ok")
        self.assertEqual(recorded[7], "ok")
        self.assertEqual(recorded[11], "ok")


if __name__ == "__main__":
    unittest.main()
