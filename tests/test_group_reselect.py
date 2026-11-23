"""代理组自愈(ensure_proxy_group)的回归护栏。

症状:订阅更新整份覆盖客户端配置后,env.json 记的老组名在内核里已不存在,
规则写入与校验永远失败,fix 用旧组名重试形成死循环 —— 用户看到
「一键修复修不好」。这里钉住自愈行为:
  1. 现组名仍存在 → 无条件保留,不许乱换;
  2. 现组名消失 → 按「固定IP > AI/干净 > 稳定型组」打分换到现存最优组;
  3. 换组必须写回 env.json(经 support env-set);
  4. fix() 必须在写规则之前调用自愈;
  5. 内核里没有可用组(接口不可用/空配置)时不许静默编造组名。
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
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


def proxies_payload(groups):
    """构造 /proxies 响应。groups: {组名: (type, [成员])}"""
    proxies = {}
    for name, (gtype, members) in groups.items():
        proxies[name] = {"type": gtype, "all": list(members), "now": members[0]}
    for node in ("DIRECT", "REJECT", "GLOBAL", "PASS"):
        proxies[node] = {"type": node.lower()}
    return json.dumps({"proxies": proxies})


class EnsureProxyGroupTests(unittest.TestCase):
    def run_harness(self, payload, current_group):
        """在隔离 HOME + 假 curl + 假 support 下跑 ensure_proxy_group。"""
        tmp = tempfile.TemporaryDirectory(prefix="group-reselect-")
        self.addCleanup(tmp.cleanup)
        curl = Path(tmp.name) / "curl"
        curl.write_text("#!/bin/bash\ncat %s\n" % json.dumps(
            str(Path(tmp.name) / "payload")), encoding="utf-8")
        curl.chmod(0o755)
        (Path(tmp.name) / "payload").write_text(payload, encoding="utf-8")
        captured = Path(tmp.name) / "envset.log"
        harness = "\n".join((
            "BASE=%s" % tmp.name,
            "PROXY_GROUP=%s" % shlex.quote(current_group),
            "clash_sock() { echo /tmp/fake.sock; }",
            "support() { printf '%%s\\n' \"$*\" >> %s; return 0; }" % captured,
            extract("ensure_proxy_group"),
            "ensure_proxy_group; rc=$?",
            'printf "rc=%s pick=%s re=%s\\n" "$rc" "$PROXY_GROUP" "$GROUP_RESELECTED"',
        ))
        home = Path(tmp.name) / "home"
        home.mkdir()
        env = dict(os.environ,
                   PATH=str(curl.parent) + ":/usr/bin:/bin",
                   HOME=str(home))
        run = subprocess.run(["/bin/bash", "-c", harness], env=env,
                             text=True, capture_output=True, timeout=30)
        envset = captured.read_text(encoding="utf-8").splitlines() \
            if captured.exists() else []
        return run, envset

    def test_keeps_current_group_when_still_valid(self):
        payload = proxies_payload({
            "🧠 固定IP": ("fallback", ["🏠 固定IP·经良心云", "🏠 固定IP·美国-阿什本"]),
            "🤖 OpenAi": ("select", ["节点A"]),
        })
        run, envset = self.run_harness(payload, "🤖 OpenAi")
        self.assertIn("rc=0 pick=🤖 OpenAi re=", run.stdout)
        self.assertNotIn("re=1", run.stdout)
        self.assertEqual(envset, [])

    def test_reselects_when_group_missing_prefers_fixed_ip(self):
        payload = proxies_payload({
            "🧠 AI·自动最快": ("fallback", ["鱼1·美国"]),
            "🐟 鱼源·最快": ("url-test", ["鱼2·美国"]),
            "🧠 固定IP": ("fallback", ["🏠 固定IP·经良心云", "🏠 固定IP·美国-阿什本"]),
        })
        run, envset = self.run_harness(payload, "🤖 OpenAi")
        self.assertIn("rc=0 pick=🧠 固定IP re=1", run.stdout)
        self.assertIn("proxy_group=🧠 固定IP", "\n".join(envset))

    def test_falls_back_to_ai_group_without_fixed(self):
        payload = proxies_payload({
            "🌐 海外代理": ("select", ["🐟 鱼源·最快"]),
            "🧠 AI·自动最快": ("fallback", ["鱼1·美国"]),
        })
        run, envset = self.run_harness(payload, "🧠 AI·干净IP")
        self.assertIn("pick=🧠 AI·自动最快", run.stdout)
        self.assertIn("re=1", run.stdout)

    def test_rejects_direct_only_groups(self):
        payload = proxies_payload({
            "只直连组": ("select", ["DIRECT"]),
            "🧠 固定IP": ("fallback", ["🏠 固定IP·美国-阿什本"]),
        })
        run, _ = self.run_harness(payload, "没了的组")
        self.assertIn("pick=🧠 固定IP", run.stdout)

    def test_no_usable_group_returns_failure_without_inventing(self):
        run, envset = self.run_harness("", "🤖 OpenAi")
        self.assertIn("rc=1", run.stdout)
        self.assertEqual(envset, [])

    def test_fix_calls_selfheal_before_writing_rules(self):
        sh = CORE.read_text(encoding="utf-8")
        fix_body = sh.split("fix() {", 1)[1]
        self.assertIn("ensure_proxy_group", fix_body)
        self.assertLess(fix_body.index("ensure_proxy_group"),
                        fix_body.index("write_merge_rules"))

    def test_check_hint_points_at_automatic_reselect(self):
        sh = CORE.read_text(encoding="utf-8")
        self.assertIn("会自动切换到可用组", sh)
        self.assertNotIn("点「一键修复」重新选择", sh)


if __name__ == "__main__":
    unittest.main()
