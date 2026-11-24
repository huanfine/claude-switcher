"""DNS 上游体检(dns_audit)与托管修复块(write_dns_merge)的回归护栏。

背景(2026-11-23 实测):订阅原生 DNS 架构(nameserver=国内 DoH + fallback 并发)
会把海外域名的解析送进国内递归,权威侧看到国内解析器;而检查器旧 DNS 项只验
「走隧道」,泄露存在时照样 ok。这里钉住:
  1. 老架构(fallback 非空 / 纯国内 nameserver / 明文上游)必须被 audit 报出;
  2. 修复后架构(海外加密 DoH + fallback 清空)必须通过;
  3. 修复块进 Merge.yaml:块外内容保留、块外顶层 dns: 移除(重复键会让
     mihomo 拒载整份配置)、幂等、旧托管块被替换不叠加;
  4. check 的 DNS 项与 fix 都必须调用 audit,fix 在写规则前先修 DNS。
"""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


def extract(name):
    text = CORE.read_text(encoding="utf-8")
    match = re.search(r"(?ms)^%s\(\) \{\n.*?^\}" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到函数 %s" % name)
    return match.group(0)


OLD_ARCH = """dns:
  enable: true
  respect-rules: true
  nameserver:
  - https://doh.pub/dns-query
  - https://dns.alidns.com/dns-query
  fallback:
  - https://dns.google/dns-query
  - https://cloudflare-dns.com/dns-query
  proxy-server-nameserver:
  - https://doh.pub/dns-query
  nameserver-policy:
    geosite:cn:
    - https://doh.pub/dns-query
"""

PLAINTEXT_ARCH = """dns:
  enable: true
  nameserver:
  - 8.8.4.4
  - https://1.1.1.1/dns-query
  fallback: []
"""

GOOD_ARCH = """dns:
  enable: true
  respect-rules: true
  nameserver:
  - https://8.8.8.8/dns-query
  - https://1.1.1.1/dns-query
  fallback: []
  proxy-server-nameserver:
  - https://doh.pub/dns-query
  nameserver-policy:
    geosite:cn:
    - https://doh.pub/dns-query
"""

MERGE_OLD = """---
profile:
  store-selected: true

dns:
  use-system-hosts: false
  nameserver:
  - https://doh.pub/dns-query
  fallback:
  - 8.8.4.4
"""


class DnsAuditTests(unittest.TestCase):
    def run_harness(self, dns_section, merge_text=None, proxy_mode="clash-verge"):
        """隔离目录 + 提取函数,跑 dns_audit / write_dns_merge。"""
        tmp = tempfile.TemporaryDirectory(prefix="dns-audit-")
        self.addCleanup(tmp.cleanup)
        clash_dir = Path(tmp.name) / "clash"
        (clash_dir / "profiles").mkdir(parents=True)
        if dns_section is not None:
            (clash_dir / "clash-verge.yaml").write_text(dns_section, encoding="utf-8")
        merge = clash_dir / "profiles" / "Merge.yaml"
        if merge_text is not None:
            merge.write_text(merge_text, encoding="utf-8")
        harness = "\n".join((
            "CLASH_DIR=%s" % shlex.quote(str(clash_dir)),
            "PROXY_MODE=%s" % shlex.quote(proxy_mode),
            extract("runtime_dns_section"),
            extract("dns_audit"),
            extract("write_dns_merge"),
            'dns_audit; echo "audit_rc=$?"; write_dns_merge; echo "merge_rc=$?"',
        ))
        env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        run = subprocess.run(["/bin/bash", "-c", harness], env=env,
                             text=True, capture_output=True, timeout=30)
        return run, merge

    def test_old_arch_reports_fallback_and_domestic_only(self):
        run, _ = self.run_harness(OLD_ARCH)
        self.assertIn("audit_rc=0", run.stdout)
        self.assertIn("fallback 并发查询未清空", run.stdout)
        self.assertIn("无海外加密上游", run.stdout)

    def test_plaintext_upstream_is_reported(self):
        run, _ = self.run_harness(PLAINTEXT_ARCH)
        self.assertIn("audit_rc=0", run.stdout)
        self.assertIn("明文上游(8.8.4.4)", run.stdout)
        self.assertNotIn("无海外加密上游", run.stdout)

    def test_fixed_arch_passes(self):
        run, _ = self.run_harness(GOOD_ARCH)
        self.assertIn("audit_rc=1", run.stdout)
        self.assertIn("merge_rc=0", run.stdout)

    def test_non_clash_verge_skips_audit(self):
        run, _ = self.run_harness(OLD_ARCH, proxy_mode="flclash")
        self.assertIn("audit_rc=1", run.stdout)

    def test_missing_config_does_not_invent_issues(self):
        run, _ = self.run_harness(None)
        self.assertIn("audit_rc=1", run.stdout)
        self.assertIn("merge_rc=0", run.stdout)

    def test_merge_write_drops_external_dns_and_keeps_rest(self):
        run, merge = self.run_harness(GOOD_ARCH, merge_text=MERGE_OLD)
        self.assertIn("merge_rc=0", run.stdout)
        text = merge.read_text(encoding="utf-8")
        self.assertIn("# >>> claude-switcher managed dns >>>", text)
        self.assertEqual(text.count("dns:"), 1, "顶层 dns: 键重复会让 mihomo 拒载")
        self.assertIn("store-selected: true", text)
        self.assertIn("respect-rules: true", text)
        self.assertNotIn("8.8.4.4", text)
        self.assertNotIn("use-system-hosts", text)  # 块外旧 dns 子树已被托管块接管

    def test_merge_write_is_idempotent(self):
        run, merge = self.run_harness(GOOD_ARCH, merge_text=MERGE_OLD)
        first = merge.read_text(encoding="utf-8")
        run2, _ = self.run_harness(GOOD_ARCH, merge_text=first)
        self.assertIn("无变化", run2.stdout)

    def test_old_managed_block_is_replaced_not_duplicated(self):
        seeded = MERGE_OLD + ("# >>> claude-switcher managed dns >>>\n"
                              "dns:\n  respect-rules: false\n"
                              "# <<< claude-switcher managed dns <<<\n")
        run, merge = self.run_harness(GOOD_ARCH, merge_text=seeded)
        text = merge.read_text(encoding="utf-8")
        self.assertEqual(text.count("claude-switcher managed dns >>>"), 1)
        self.assertNotIn("respect-rules: false", text)
        self.assertIn("respect-rules: true", text)

    def test_check_and_fix_wire_the_audit(self):
        sh = CORE.read_text(encoding="utf-8")
        self.assertIn('optional_result "DNS" fail "上游泄露架构', sh)
        fix_body = sh.split("fix() {", 1)[1]
        self.assertIn("dns_audit", fix_body)
        self.assertIn("write_dns_merge", fix_body)
        self.assertLess(fix_body.index("dns_audit"),
                        fix_body.index("write_merge_rules"))
        self.assertIn("上游架构已审计通过", fix_body)


if __name__ == "__main__":
    unittest.main()
