"""检查结论的语义:把「没配好」和「不安全」分开,失败文案要能直接照着做。

背景:环境层没就绪(代理组/目标值缺失)和实测不达标(出口 IP 跑偏)都报 fail,
用户看到的是同一种红叉。前者该去补配置,后者才该去修环境 —— 混在一起时,
「没配置」看起来像「不安全」,用户照着提示修规则,越修越远。

这里只跑隔离夹具:假 HOME + 假外部命令,不碰真实网络与真实配置。
"""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "core/claude-switch.sh"


class CheckSemanticsTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="check-semantics-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / "home"
        self.home.mkdir()
        (self.home / ".claude-switcher").mkdir()
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.bin) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1",
                        # 默认指向不存在的文件:断言不能随开发机上真实的看门狗状态飘
                        TZ_WATCHDOG_FILE=str(Path(self.tmp.name) / "no-watchdog.sh"))
        self.stub("pgrep", "exit 0")
        self.stub("ifconfig", "echo 'inet 198.18.0.1'")
        self.stub("curl", '''case "$*" in
  *cdn-cgi/trace*) printf 'ip=203.0.113.10\\nloc=US\\n' ;;
  *ipinfo.io*) printf '{"org":"Example Residential"}' ;;
  *claude.ai*|*api.anthropic.com*) printf '200' ;;
esac''')
        self.stub("dig", "echo 198.18.0.2")
        self.stub("defaults", '''if [[ "$*" == *AppleLocale* ]]; then echo en_US; else printf '(\\n    en-US,\\n)'; fi''')
        self.stub("networksetup", "echo 'IPv6: Off'")
        self.stub("launchctl", "exit 1")
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/New_York")

    # ---- 夹具 ----

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\n" + body + "\n", encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def core(self, tz_target="America/New_York", proxy_mode="clash-verge"):
        """生成一份改过保底值的脚本副本。断言替换命中,避免默认值一改测试静默失效。"""
        text = SOURCE.read_text(encoding="utf-8")
        text = text.replace('TZ_TARGET="America/New_York"', 'TZ_TARGET="' + tz_target + '"', 1)
        text = text.replace('PROXY_MODE="clash-verge"', 'PROXY_MODE="' + proxy_mode + '"', 1)
        self.assertIn('TZ_TARGET="' + tz_target + '"', text)
        path = Path(self.tmp.name) / ("claude-switch-" + tz_target.replace("/", "_") + ".sh")
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)
        return path

    def run_core(self, script, *args):
        return subprocess.run(["/bin/bash", str(script), *args], text=True,
                              capture_output=True, env=self.env, timeout=60)

    @staticmethod
    def line(output, name):
        match = re.search(r"(?m)^" + re.escape(name) + r"=(.*)$", output)
        return match.group(1) if match else None

    # ---- 断言 ----

    def test_missing_env_layer_is_config_not_fail(self):
        """代理组取不到 = 环境层没就绪,不能报成「规则没生效」。"""
        run = self.run_core(self.core(proxy_mode="clash-verge"), "checkdetail")
        value = self.line(run.stdout, "规则置顶")
        self.assertIsNotNone(value, run.stdout + run.stderr)
        self.assertTrue(value.startswith("config:"), "应为 config 而非 fail:" + value)
        self.assertIn("环境层未就绪", value)
        self.assertNotIn("未生效", value, "旧文案会把用户引去查规则")

    def test_timezone_mismatch_shows_current_and_expected(self):
        """报「当前 vs 期望」,不报 readlink 的完整路径 —— 后者看着像系统坏了。"""
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/Los_Angeles")
        run = self.run_core(self.core(), "checkdetail")
        value = self.line(run.stdout, "时区")
        self.assertIsNotNone(value, run.stdout + run.stderr)
        self.assertTrue(value.startswith("fail:"), value)
        self.assertIn("当前 America/Los_Angeles", value)
        self.assertIn("期望 America/New_York", value)
        self.assertNotIn("/var/db/timezone/zoneinfo", value, "路径前缀对用户没有意义")

    def test_watchdog_holding_old_target_is_warn_not_ok(self):
        """当前时区对了还不够:看门狗若守着别的目标,几分钟内就会改回去。

        这正是「一键修复没生效」的真实成因 —— 修完一小时内被看门狗改回旧值,
        而检查项只看系统时区,一句话都没提。
        """
        wd = Path(self.tmp.name) / "tz-watchdog.sh"
        wd.write_text('TARGET="America/Los_Angeles"\n', encoding="utf-8")
        env = dict(self.env, TZ_WATCHDOG_FILE=str(wd))
        run = subprocess.run(["/bin/bash", str(self.core()), "checkdetail"], text=True,
                             capture_output=True, env=env, timeout=60)
        value = self.line(run.stdout, "时区")
        self.assertTrue((value or "").startswith("warn:"), value)
        self.assertIn("America/Los_Angeles", value)
        self.assertIn("改回去", value)
        self.assertIn("一键修复", value, "只说有问题不给下一步,用户不知道点哪")

    def test_watchdog_target_parsing_accepts_both_quote_styles(self):
        """安装器写 TARGET="x",set-region 同步写 TARGET=x —— 两种都得认。"""
        for body in ('TARGET="Asia/Tokyo"\n', "TARGET=Asia/Tokyo\n"):
            with self.subTest(body=body.strip()):
                wd = Path(self.tmp.name) / "wd-quote.sh"
                wd.write_text(body, encoding="utf-8")
                env = dict(self.env, TZ_WATCHDOG_FILE=str(wd))
                run = subprocess.run(["/bin/bash", str(self.core()), "checkdetail"], text=True,
                                     capture_output=True, env=env, timeout=60)
                value = self.line(run.stdout, "时区")
                self.assertTrue((value or "").startswith("warn:"), value)
                self.assertIn("Asia/Tokyo", value)

    def test_watchdog_on_same_target_keeps_ok(self):
        """看门狗和期望一致时不该多话 —— 全部 ok 的场景不要凭空冒出 warn。"""
        wd = Path(self.tmp.name) / "tz-watchdog-ok.sh"
        wd.write_text('TARGET="America/New_York"\n', encoding="utf-8")
        env = dict(self.env, TZ_WATCHDOG_FILE=str(wd))
        run = subprocess.run(["/bin/bash", str(self.core()), "checkdetail"], text=True,
                             capture_output=True, env=env, timeout=60)
        self.assertEqual(self.line(run.stdout, "时区"), "ok", run.stdout + run.stderr)

    def test_check_failure_names_both_values(self):
        """check 的 FAIL 串是用户唯一能看到的失败原因,同样要带两边取值。"""
        self.stub("readlink", "echo /var/db/timezone/zoneinfo/America/Los_Angeles")
        run = self.run_core(self.core(), "check")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("FAIL:", run.stdout)
        self.assertIn("时区不符(当前 America/Los_Angeles,期望 America/New_York)", run.stdout)
        self.assertNotIn("/var/db/timezone/zoneinfo", run.stdout)

    def test_empty_target_is_config_and_says_so(self):
        """目标值为空属于配置缺失:checkdetail 报 config,check 报「环境未配置」。"""
        script = self.core(tz_target="")
        detail = self.run_core(script, "checkdetail")
        value = self.line(detail.stdout, "时区")
        self.assertTrue((value or "").startswith("config:"), detail.stdout + detail.stderr)
        self.assertIn("未取到时区目标", value or "")

        check = self.run_core(script, "check")
        self.assertNotEqual(check.returncode, 0)
        self.assertIn("环境未配置(时区目标缺失", check.stdout)

    def test_cn_upstream_resolver_is_warn_not_ok(self):
        """fake-ip 只能证明「本机解析被接管」,证明不了 mihomo 的上游从哪出去。

        上游是国内 DoH 时,查询从国内发起,ECS 会把发起地网段带给权威 DNS ——
        连接从海外出去、解析从国内发起,正是风控看的地域矛盾。
        """
        value = self.dns_line("dns:\n  nameserver:\n  - https://dns.alidns.com/dns-query\n"
                              "  default-nameserver:\n  - 223.5.5.5\n")
        self.assertTrue(value.startswith("warn:"), value)
        self.assertIn("上游解析器在国内", value)
        self.assertIn("DoH", value, "只说有问题不给下一步,用户不知道改哪里")

    def test_foreign_upstream_resolver_stays_ok(self):
        value = self.dns_line("dns:\n  nameserver:\n  - https://dns.google/dns-query\n"
                              "  - 1.1.1.1\n")
        self.assertEqual(value, "ok:走隧道", value)

    def test_per_domain_policy_is_not_counted(self):
        """nameserver-policy 只影响个别域名,报出来是噪音,不该让整项变黄。"""
        value = self.dns_line("dns:\n  nameserver:\n  - https://dns.google/dns-query\n"
                              "  nameserver-policy:\n    inter-90v.pages.dev:\n"
                              "    - https://dns.alidns.com/dns-query\n")
        self.assertEqual(value, "ok:走隧道", value)

    def dns_line(self, dns_yaml):
        clash = Path(self.tmp.name) / "clash"
        clash.mkdir(exist_ok=True)
        (clash / "clash-verge.yaml").write_text(dns_yaml + "proxies:\n- name: x\n", encoding="utf-8")
        env = dict(self.env, CLAUDE_SWITCHER_CLASH_DIR=str(clash))
        run = subprocess.run(["/bin/bash", str(self.core()), "checkdetail"], text=True,
                             capture_output=True, env=env, timeout=60)
        value = self.line(run.stdout, "DNS")
        self.assertIsNotNone(value, run.stdout + run.stderr)
        return value

    def test_rule_hint_turns_kernel_errors_into_actions(self):
        """内核校验的错误要翻成「缺什么 + 点哪里」,而不是原样抛给用户。"""
        text = SOURCE.read_text(encoding="utf-8")
        start = text.find("rule_fix_hint() {")
        self.assertGreaterEqual(start, 0, "rule_fix_hint 应存在于核心脚本")
        body = text[start:text.find("\n}", start) + 2]
        cases = [
            ("运行规则未按策略置顶:clau.de", "内核缺少 Claude 域名(clau.de 等)"),
            ("运行规则未按策略置顶:UDP/3478", "UDP 3478 规则没置顶"),
            ("Clash 当前不是 rule 模式", "客户端不在规则模式"),
            ("配置的代理组不存在", "代理组在客户端里不存在"),
            ("代理组当前节点为直连或拒绝，请选择代理节点", "换一个代理节点"),
            ("当前节点未确认支持 UDP，请更换节点或选择 reject 策略", "节点未确认支持 UDP"),
            ("运行中的规则数量不足", "内核规则条数不足"),
            ("Clash 内核接口不可用(ConnectionRefusedError)", "读不到内核控制接口"),
            ("", "规则校验未通过"),
        ]
        script = (body + "\nwhile IFS= read -r message; do printf '%s\\n' \"$(rule_fix_hint \"$message\")\"; done <<'CASES'\n"
                  + "\n".join(message for message, _ in cases) + "\nCASES\n")
        run = subprocess.run(["/bin/bash", "-c", script], text=True, capture_output=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        lines = run.stdout.splitlines()
        self.assertEqual(len(lines), len(cases), run.stdout)
        for (message, expected), got in zip(cases, lines):
            with self.subTest(message=message):
                self.assertIn(expected, got)
                if message:
                    # 每条失败都必须给出下一步动作。动作不一定是「一键修复」:
                    # 换节点、切模式这些改不了,但同样要写清楚。
                    self.assertIn("·", got, "失败文案缺少「· 下一步」")
                    self.assertTrue(got.split("·", 1)[1].strip(), "「·」后面要有动作")


if __name__ == "__main__":
    unittest.main()
