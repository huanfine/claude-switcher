"""数据层一致性守卫(不访问网络、不执行 PowerShell)。

功能 / 数据 / 环境三层里的数据层约束:域名与端口清单只能有一个来源,
即 data/claude-rules.json。各平台代码里的清单块由 scripts/sync-rules.py 生成,
这里确保「数据源改了但忘了重新生成」不会静默溜进发布。
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SYNC = ROOT / "scripts/sync-rules.py"
SOURCE = ROOT / "data/claude-rules.json"
BLOCK_BEGIN = "# >>> claude-switcher:rules generated >>>"
# 只出现在生成块里的特征域名,用来检测「有人在块外又抄了一份清单」
SENTINEL = "cdn.usefathom.com"
TARGETS = (
    "core/claude-switch.sh",
    "linux/claude-switch.sh",
    "linux/install.sh",
    "windows/claude-switch.ps1",
)


def data():
    return json.loads(SOURCE.read_text(encoding="utf-8"))


def domains():
    return [d for group in data()["domain_groups"] for d in group["domains"]]


class RulesSyncTests(unittest.TestCase):
    def test_generated_blocks_match_data_source(self):
        run = subprocess.run([sys.executable, "-S", str(SYNC), "--check"],
                             text=True, encoding="utf-8", capture_output=True, timeout=60)
        self.assertEqual(run.returncode, 0,
                         "生成物与数据源不一致,请运行 python3 scripts/sync-rules.py\n"
                         + run.stdout + run.stderr)

    def test_data_source_is_wellformed(self):
        payload = data()
        self.assertEqual(payload["schema"], 1)
        names = domains()
        self.assertEqual(len(names), len(set(names)), "域名不允许重复")
        self.assertTrue(payload["domain_groups"], "至少要有一个域名分组")
        for group in payload["domain_groups"]:
            self.assertTrue(group["domains"], "分组不允许为空")
            for domain in group["domains"]:
                self.assertNotIn(" ", domain)
                self.assertTrue(domain.strip() == domain)
        for port in payload["ports"]["values"]:
            self.assertIs(type(port), int)

    def test_claude_critical_domains_are_present(self):
        """这几个漏了会直接换出口,是回归红线。"""
        names = domains()
        for domain in ("claude.ai", "claude.com", "anthropic.com",
                       "clau.de", "claudemcpclient.com", "claudemcpcontent.com",
                       "claudeusercontent.com", "browser-intake-us5-datadoghq.com",
                       # 这两条的根域名不在任何已有后缀里,漏了就是纯漏网
                       "anthropic.auth0.com", "anthropic.com.cdn.cloudflare.net"):
            with self.subTest(domain=domain):
                self.assertIn(domain, names)

    def test_ip_fallback_covers_anthropic_own_range(self):
        """域名规则是白名单,漏一个就换出口;IP 段是最后一道防线,不能为空。"""
        cidrs = (data().get("ip_fallback") or {}).get("cidrs") or []
        self.assertIn("160.79.104.0/21", cidrs, "Anthropic 自有 IPv4 段必须收录")
        for cidr in cidrs:
            self.assertIn("/", cidr)
            self.assertNotIn(" ", cidr)

    def test_ip_fallback_renders_into_every_target(self):
        for rel in TARGETS:
            with self.subTest(path=rel):
                text = (ROOT / rel).read_text(encoding="utf-8-sig")
                self.assertIn("160.79.104.0/21", text, f"{rel} 没渲染 IP 兜底清单")
                self.assertIn("CLAUDE_IPS" if rel != "core/claude-switch.sh" else "IP_FALLBACK",
                              text, f"{rel} 没渲染 IP 兜底变量")

    def test_manifest_lives_only_in_generated_blocks(self):
        for rel in TARGETS:
            with self.subTest(path=rel):
                text = (ROOT / rel).read_text(encoding="utf-8-sig")
                blocks = text.count(BLOCK_BEGIN)
                self.assertGreaterEqual(blocks, 1, f"{rel} 缺少生成块标记")
                self.assertEqual(text.count(SENTINEL), blocks,
                                 f"{rel} 在生成块之外还有手写清单")

    def test_linux_bash_block_stays_parseable(self):
        for rel in ("linux/claude-switch.sh", "linux/install.sh"):
            with self.subTest(path=rel):
                run = subprocess.run(["bash", "-n", str(ROOT / rel)],
                                     text=True, capture_output=True, timeout=30)
                self.assertEqual(run.returncode, 0, run.stderr)


if __name__ == "__main__":
    unittest.main()
