"""节点应用必须重新通过扫描硬门槛。

夹具只运行核心里抽取的真实 shell 函数,内核枚举、纯度结果和出口探测全部由
本地假数据提供;不切真实节点、不访问网络、不读写用户账号。
"""
import contextlib
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest

from test_node_scan import FAKE_CONFIG, load_rules_module


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"
TRASH = ROOT / "_trash"
SELECTOR = "🧠 AI·干净IP"


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


def optional_function_source(name):
    try:
        return function_source(name)
    except AssertionError:
        return ""


def run_shell(script, env, timeout=20):
    return subprocess.run(
        ["/bin/bash", "-c", script], text=True, capture_output=True,
        env=env, timeout=timeout, check=False,
    )


class NodeApplyGateTests(unittest.TestCase):
    def setUp(self):
        TRASH.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="node-apply-gate-", dir=TRASH)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "state"
        self.base.mkdir()
        self.report = self.base / "node-scan.txt"
        self.fresh_report = self.root / "fresh-report.txt"
        self.raw = self.root / "raw.txt"
        self.current = self.root / "current.txt"
        self.calls = self.root / "calls.txt"
        self.preferred = self.base / "preferred-node"
        self.raw.write_text(
            f"SCANv1\nGROUP\t🤖 OpenAi\nCURRENT\tA\n"
            f"NODE\t{SELECTOR}\tA\t192.0.2.1\tknown\t1\n"
            f"NODE\t{SELECTOR}\tB\t192.0.2.2\tknown\t1\n",
            encoding="utf-8",
        )
        self.current.write_text("A", encoding="utf-8")
        self.env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.root),
            "BASE": str(self.base),
            "NODE_SCAN_FILE": str(self.report),
            "PREFERRED_NODE_FILE": str(self.preferred),
            "NODE_SCAN_TTL": "86400",
            "COUNTRY_TARGET": "US",
            "TMPDIR": str(self.root),
            "FIXTURE": str(self.root),
            "SCAN_FAIL": "0",
            "DENY_AFTER_SCAN": "0",
            "TRACE_LOC": "US",
            "LC_ALL": "C",
        }
        self.write_reports()

    def write_reports(self, *, epoch=None, selector=SELECTOR, current="A",
                      best="B", candidates=None):
        if candidates is None:
            candidates = [(selector, "B", "1", "", "88", "192.0.2.2", "US",
                           "ok", "residential", "known", "1")]
        values = {
            "EPOCH": str(int(time.time()) if epoch is None else epoch),
            "GROUP": "🤖 OpenAi",
            "SELECTOR": selector,
            "CURRENT": current,
            "CURRENT_SCORE": "49",
            "BEST": best,
            "BEST_SCORE": "88",
            "BEST_IP": "192.0.2.2",
            "BEST_SELECTOR": selector,
            "DELTA": "39",
            "GATE": "auto-ok",
            "ELIGIBLE": "1",
        }
        text = "".join(f"{key}={value}\n" for key, value in values.items())
        text += "".join(
            "CANDIDATE\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" % row
            for row in candidates
        )
        self.report.write_text(text, encoding="utf-8")
        self.fresh_report.write_text(text, encoding="utf-8")

    def script(self, body):
        dependencies = "\n".join(filter(None, (
            optional_function_source("node_candidate_gate"),
            optional_function_source("node_scan_report_fresh"),
            optional_function_source("node_report_candidate"),
            function_source("purity_fail_reason"),
            function_source("node_apply"),
        )))
        harness = r'''
set -u
lease_revoke() { :; }
node_gate() { printf 'auto-ok|fixture\n'; }
node_apply_gate() {
    printf 'gate\n' >> "$FIXTURE/calls.txt"
    if [ "$DENY_AFTER_SCAN" = "1" ]; then
        printf 'denied|扫描期间 Claude 已启动\n'
    else
        printf 'allowed|fixture\n'
    fi
}
scan_nodes() {
    printf 'scan\n' >> "$FIXTURE/calls.txt"
    [ "$SCAN_FAIL" = "1" ] && return 1
    cp "$FIXTURE/fresh-report.txt" "$NODE_SCAN_FILE"
}
clash_rules() {
    case "$1" in
        node-scan)
            printf 'SCANv1\nGROUP\t🤖 OpenAi\nCURRENT\t'
            cat "$FIXTURE/current.txt"
            printf '\n'
            cat "$FIXTURE/raw.txt"
            ;;
        node-select)
            printf 'select\t%s\t%s\n' "$2" "$3" >> "$FIXTURE/calls.txt"
            printf '%s' "$3" > "$FIXTURE/current.txt"
            ;;
    esac
}
curl() { printf 'ip=203.0.113.10\nloc=%s\n' "$TRACE_LOC"; }
sleep() { :; }
'''
        return run_shell("\n".join((dependencies, harness, body)), self.env)

    def apply(self, leaf="B"):
        call = "node_apply" if leaf is None else f"node_apply {leaf!r}"
        return self.script(call)

    def call_lines(self):
        return self.calls.read_text(encoding="utf-8").splitlines() if self.calls.exists() else []

    def selected(self):
        return [line.split("\t")[2] for line in self.call_lines() if line.startswith("select\t")]

    def assert_rejected_without_select(self, run, reason=None):
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.selected(), [], run.stdout + run.stderr)
        if reason:
            self.assertIn(reason, run.stdout + run.stderr)

    def test_explicit_leaf_rejected_when_scan_says_tor_or_proxy(self):
        for reason in ("硬门槛:Tor 出口", "硬门槛:代理/VPN 特征(信誉 68 分,分数与判定分开)"):
            with self.subTest(reason=reason):
                self.calls.unlink(missing_ok=True)
                self.current.write_text("A", encoding="utf-8")
                self.write_reports(candidates=[(SELECTOR, "B", "0", reason, "68", "192.0.2.2", "US",
                                                 "fail", "vpn", "known", "1")])
                self.assert_rejected_without_select(self.apply(), reason)

    def test_explicit_leaf_rejected_when_country_mismatches(self):
        reason = "国家不符(JP≠US)"
        self.write_reports(candidates=[(SELECTOR, "B", "0", reason, "88", "192.0.2.2", "JP",
                                         "ok", "residential", "known", "1")])
        self.assert_rejected_without_select(self.apply(), reason)

    def test_explicit_leaf_rejected_when_fronted_or_unrated(self):
        for reason in ("CDN 前置,出口未知", "未评级(类型证据缺失)"):
            with self.subTest(reason=reason):
                self.calls.unlink(missing_ok=True)
                self.current.write_text("A", encoding="utf-8")
                egress = "fronted" if reason.startswith("CDN") else "known"
                self.write_reports(candidates=[(SELECTOR, "B", "0", reason, "", "", "",
                                                 "", "", egress, "1")])
                self.assert_rejected_without_select(self.apply(), reason)

    def test_stale_scan_is_refreshed_and_cannot_authorize_explicit_leaf(self):
        stale = int(time.time()) - 86401
        self.write_reports(epoch=stale)
        self.write_reports(candidates=[(SELECTOR, "B", "0", "国家不符(JP≠US)", "88", "192.0.2.2", "JP",
                                         "ok", "residential", "known", "1")])
        run = self.apply()
        self.assert_rejected_without_select(run, "国家不符")
        self.assertIn("scan", self.call_lines(), "过期报告必须先重扫,不能直接作为授权依据")

    def test_fresh_scan_failure_prevents_explicit_apply(self):
        self.env["SCAN_FAIL"] = "1"
        self.assert_rejected_without_select(self.apply(), "扫描")

    def test_execution_gate_is_rechecked_after_fresh_scan(self):
        self.env["DENY_AFTER_SCAN"] = "1"
        run = self.apply()
        self.assert_rejected_without_select(run, "Claude 已启动")
        self.assertIn("scan", self.call_lines())
        self.assertIn("gate", self.call_lines())

    def test_explicit_leaf_must_match_the_fresh_selector(self):
        self.write_reports(candidates=[("另一个 Selector", "B", "1", "", "88", "192.0.2.2", "US",
                                         "ok", "residential", "known", "1")])
        self.assert_rejected_without_select(self.apply(), "Selector")

    def test_duplicate_candidate_rows_are_rejected(self):
        rows = [
            (SELECTOR, "B", "1", "", "88", "192.0.2.2", "US", "ok", "residential", "known", "1"),
            (SELECTOR, "B", "0", "国家不符(JP≠US)", "88", "192.0.2.2", "JP",
             "ok", "residential", "known", "1"),
        ]
        self.write_reports(candidates=rows)
        self.assert_rejected_without_select(self.apply(), "候选")

    def test_no_argument_apply_uses_the_same_candidate_gate(self):
        self.write_reports(candidates=[(SELECTOR, "B", "0", "硬门槛:Tor 出口", "47", "192.0.2.2", "US",
                                         "fail", "tor", "known", "1")])
        self.assert_rejected_without_select(self.apply(None), "Tor 出口")

    def test_tampered_eligible_row_is_rechecked_by_the_shared_gate(self):
        self.write_reports(candidates=[(SELECTOR, "B", "1", "", "68", "192.0.2.2", "US",
                                         "fail", "vpn", "known", "1")])
        self.assert_rejected_without_select(self.apply(), "代理/VPN 特征")

    def test_eligible_explicit_leaf_is_applied_and_fixed(self):
        run = self.apply()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.selected(), ["B"])
        self.assertIn("APPLY=OK", run.stdout)
        fields = self.preferred.read_text(encoding="utf-8").strip().split("\t")
        self.assertEqual(fields[:2], [SELECTOR, "B"])
        self.assertEqual(fields[2], "192.0.2.2")

    def test_eligible_no_argument_best_is_applied(self):
        run = self.apply(None)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.selected(), ["B"])
        self.assertIn("APPLIED=B", run.stdout)

    def test_post_switch_country_failure_restores_previous_leaf(self):
        self.env["TRACE_LOC"] = "JP"
        run = self.apply()
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(self.selected(), ["B", "A"], run.stdout + run.stderr)
        self.assertIn("已回滚到 A", run.stdout + run.stderr)
        self.assertFalse(self.preferred.exists())


class NodeScanCandidateReportTests(unittest.TestCase):
    def setUp(self):
        TRASH.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="node-candidate-report-", dir=TRASH)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "state"
        self.base.mkdir()
        self.report = self.base / "node-scan.txt"
        self.raw = self.root / "raw.txt"
        self.purity = self.root / "purity-b.txt"
        self.env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.root),
            "BASE": str(self.base),
            "PROXY_GROUP": "🤖 OpenAi",
            "NODE_SCAN_FILE": str(self.report),
            "NODE_SCAN_TTL": "86400",
            "NODE_SCAN_MARGIN": "10",
            "NODE_SCAN_PARALLEL": "1",
            "COUNTRY_TARGET": "US",
            "TMPDIR": str(self.root),
            "FIXTURE": str(self.root),
            "NODE_SCAN_QUIET": "1",
            "LC_ALL": "C",
        }

    def scan(self, *, egress="known", udp="1", purity="88|ok|residential|干净|US",
             policy="proxy"):
        ip = "192.0.2.2" if egress == "known" else ""
        self.raw.write_text(
            f"SCANv1\nGROUP\t🤖 OpenAi\nCURRENT\tA\n"
            f"NODE\t{SELECTOR}\tA\t192.0.2.1\tknown\t1\n"
            f"NODE\t{SELECTOR}\tB\t{ip}\t{egress}\t{udp}\n",
            encoding="utf-8",
        )
        self.purity.write_text(purity + "\n", encoding="utf-8")
        policy_file = self.base / "webrtc-policy"
        if policy is None:
            policy_file.unlink(missing_ok=True)
        else:
            policy_file.write_text(policy + "\n", encoding="utf-8")
        dependencies = "\n".join((
            optional_function_source("node_candidate_gate"),
            function_source("purity_fail_reason"),
            function_source("purity_band"),
            function_source("preferred_node_leaf"),
            function_source("scan_nodes"),
        ))
        harness = r'''
set -u
clash_rules() { [ "$1" = node-scan ] && cat "$FIXTURE/raw.txt"; }
ip_purity() {
    case "$1" in
        192.0.2.1) printf '49|warn|hosting|机房|US\n' ;;
        192.0.2.2) cat "$FIXTURE/purity-b.txt" ;;
    esac
}
node_gate() { printf 'auto-ok|fixture\n'; }
preferred_node_leaf() { :; }
scan_nodes
'''
        run = run_shell(dependencies + "\n" + harness, self.env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        return self.candidate("B")

    def candidate(self, leaf):
        rows = []
        for line in self.report.read_text(encoding="utf-8").splitlines():
            fields = line.split("\t")
            if len(fields) >= 5 and fields[0] == "CANDIDATE" and fields[2] == leaf:
                rows.append(fields)
        self.assertEqual(len(rows), 1, self.report.read_text(encoding="utf-8"))
        return rows[0]

    def test_scan_report_exposes_tor_and_proxy_gate_results(self):
        for ptype, score, reason in (("tor", "47", "Tor 出口"),
                                     ("vpn", "68", "代理/VPN 特征")):
            with self.subTest(ptype=ptype):
                row = self.scan(purity=f"{score}|fail|{ptype}|{reason}|US")
                self.assertEqual(row[1], SELECTOR)
                self.assertEqual(row[2], "B")
                self.assertEqual(row[3], "0")
                self.assertIn(reason, row[4])

    def test_scan_report_exposes_country_mismatch(self):
        row = self.scan(purity="88|ok|residential|干净|JP")
        self.assertEqual(row[3], "0")
        self.assertEqual(row[4], "国家不符(JP≠US)")

    def test_scan_report_exposes_fronted_and_unrated_results(self):
        row = self.scan(egress="fronted")
        self.assertEqual(row[3], "0")
        self.assertEqual(row[4], "CDN 前置,出口未知")
        row = self.scan(purity="|unknown|unknown|未评级(类型证据缺失)|")
        self.assertEqual(row[3], "0")
        self.assertEqual(row[4], "未评级(类型证据缺失)")

    def test_eligible_report_keeps_best_selector_and_full_candidate_metadata(self):
        row = self.scan()
        values = dict(line.split("=", 1) for line in self.report.read_text(encoding="utf-8").splitlines()
                      if "=" in line)
        self.assertEqual(values["BEST"], "B")
        self.assertEqual(values["BEST_SELECTOR"], SELECTOR)
        self.assertEqual(values["BEST_SCORE"], "88")
        self.assertEqual(row[5:], ["88", "192.0.2.2", "US", "ok", "residential", "known", "1"])

    def test_udp_gate_follows_reject_policy(self):
        row = self.scan(udp="0", policy="proxy")
        self.assertEqual(row[3], "0")
        self.assertEqual(row[4], "UDP 未标注")
        row = self.scan(udp="0", policy="reject")
        self.assertEqual(row[3], "1")
        self.assertEqual(row[4], "")

    def test_missing_policy_keeps_conservative_udp_gate(self):
        row = self.scan(udp="0", policy=None)
        self.assertEqual(row[3], "0")
        self.assertEqual(row[4], "UDP 未标注")


class SlotNodeEligibilityTests(unittest.TestCase):
    def setUp(self):
        TRASH.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="slot-node-gate-", dir=TRASH)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / "state"
        self.base.mkdir()
        self.report = self.base / "node-scan.txt"
        self.slot_dir = self.base / "slot-node"
        self.env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.root),
            "BASE": str(self.base),
            "SLOT_NODE_DIR": str(self.slot_dir),
            "NODE_SCAN_FILE": str(self.report),
            "NODE_SCAN_TTL": "86400",
            "LC_ALL": "C",
        }

    def write_report(self, *, eligible="1", reason="", selector=SELECTOR, epoch=None):
        verdict = "fail" if "硬门槛" in reason else "ok"
        ptype = "tor" if "Tor" in reason else "residential"
        self.report.write_text(
            f"EPOCH={int(time.time()) if epoch is None else epoch}\n"
            f"SELECTOR={selector}\n"
            f"CANDIDATE\t{selector}\tB\t{eligible}\t{reason}\t88\t192.0.2.2\tUS\t"
            f"{verdict}\t{ptype}\tknown\t1\n",
            encoding="utf-8",
        )

    def set_binding(self, selector=""):
        dependencies = "\n".join(filter(None, (
            optional_function_source("node_scan_report_fresh"),
            optional_function_source("node_candidate_gate"),
            optional_function_source("node_report_candidate"),
            function_source("valid_account"),
            function_source("slot_node_set"),
        )))
        call = "slot_node_set B B" + (f" {selector!r}" if selector else "")
        return run_shell(dependencies + "\nset -u\nlease_revoke() { :; }\n" + call, self.env)

    def test_eligible_candidate_can_be_bound(self):
        self.write_report()
        run = self.set_binding()
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.slot_dir / "B").read_text(encoding="utf-8").split("\t")[:2],
                         [SELECTOR, "B"])

    def test_ineligible_candidate_cannot_be_bound(self):
        self.write_report(eligible="0", reason="硬门槛:Tor 出口")
        run = self.set_binding()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("Tor 出口", run.stdout + run.stderr)
        self.assertFalse((self.slot_dir / "B").exists())

    def test_explicit_selector_must_match_an_eligible_report_row(self):
        self.write_report()
        run = self.set_binding("另一个 Selector")
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse((self.slot_dir / "B").exists())

    def test_stale_report_cannot_create_a_binding(self):
        self.write_report(epoch=int(time.time()) - 86401)
        run = self.set_binding()
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("过期", run.stdout + run.stderr)
        self.assertFalse((self.slot_dir / "B").exists())


class NodeEnumerationBoundaryTests(unittest.TestCase):
    def setUp(self):
        TRASH.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="node-enumeration-", dir=TRASH)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.clash = self.root / "clash"
        self.clash.mkdir()
        (self.clash / "clash-verge.yaml").write_text(FAKE_CONFIG, encoding="utf-8")
        self.mod = load_rules_module(self.root)

    def test_control_characters_in_node_names_are_rejected(self):
        for char in ("\t", "\r", "\n", "\x00", "\x1b", "\x7f"):
            with self.subTest(char=repr(char)):
                leaf = "bad" + char + "node"
                proxies = {"proxies": {
                    "G": {"type": "Selector", "all": [leaf], "now": leaf},
                    leaf: {"type": "Vless"},
                }}
                self.mod.controller_config = lambda _cli: (("unix", "/fake.sock", None), "")
                self.mod.api_get = lambda _b, _s, _p: proxies
                with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
                    self.mod.node_scan(self.clash, "G")


if __name__ == "__main__":
    unittest.main()
