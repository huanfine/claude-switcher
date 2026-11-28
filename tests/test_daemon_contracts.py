"""守护模板、安装器与核心之间的契约。

这些点没有单元测试就会悄悄退化:
- 保镖模板必须用 __FAKE_PREFIX__ 占位,不能回到写死 198.18.;
- core 内置的 bodyguard plist 必须与 daemons/ 里的模板逐字节一致;
- 安装器必须走 restart-clash,而不是已知无效的 osascript quit;
- env.json 的时区/fake-ip 必须校验,目录权限必须是 700。
"""
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


class DaemonContractTests(unittest.TestCase):
    def test_bodyguard_uses_configurable_fake_ip_prefix(self):
        text = (ROOT / "daemons/claude-bodyguard.sh").read_text(encoding="utf-8")
        self.assertIn("__FAKE_PREFIX__", text)
        self.assertIn('grep -qF "inet $PREFIX"', text)
        self.assertNotIn("grep -q 'inet 198", text)

    def test_bodyguard_template_is_not_hardcoded_to_198_18(self):
        text = (ROOT / "daemons/claude-bodyguard.sh").read_text(encoding="utf-8")
        # 默认值只允许出现在「占位符缺失时的兜底」这一行
        self.assertEqual(text.count('PREFIX="198.18."'), 1)
        self.assertNotIn('inet 198.18.', text)

    def test_core_embedded_plist_matches_template(self):
        text = CORE.read_text(encoding="utf-8")
        start = text.index("bodyguard_plist_b64() {")
        block = text[text.index("cat <<'B64'", start):text.index("\nB64", start)]
        encoded = block.split("\n", 1)[1].strip()
        decoded = base64.b64decode(encoded)
        self.assertEqual(decoded, (ROOT / "daemons/local.claude-bodyguard.plist").read_bytes())

    def test_installer_disables_ipv6_on_every_service(self):
        """换一台走 Ethernet 的机器,只关 Wi-Fi 等于没关 IPv6。"""
        text = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
        self.assertIn("ipv6_on_services()", text)
        self.assertIn("listallnetworkservices", text)
        self.assertIn("setv6off", text)
        self.assertNotIn("setv6off Wi-Fi", text)
        self.assertNotIn("getinfo Wi-Fi", text)

    def test_installer_accepts_claude_in_user_applications(self):
        """Claude 可以被拖进 ~/Applications,不能只认 /Applications。"""
        text = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
        self.assertIn('"$H/Applications/Claude.app"', text)

    def test_runtime_detects_claude_outside_applications(self):
        core = CORE.read_text(encoding="utf-8")
        bodyguard = (ROOT / "daemons/claude-bodyguard.sh").read_text(encoding="utf-8")
        for text in (core, bodyguard):
            self.assertIn("Claude.app/Contents/MacOS/Claude", text)
            self.assertNotIn("/Applications/Claude.app/Contents/MacOS/Claude", text)

    def test_installer_uses_restart_clash(self):
        text = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
        self.assertIn("restart-clash", text)
        self.assertNotIn('osascript -e \'tell application "Clash Verge" to quit\'', text)
        self.assertIn("__FAKE_PREFIX__", text)
        self.assertIn("__LOG_DIR__", text)

    def test_installer_does_not_persist_launchdaemon_plists_in_home(self):
        text = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
        self.assertNotIn('cp "$REPO/daemons/local.claude-bodyguard.plist" '
                         '"$REPO/daemons/local.tz-watchdog.plist" "$H/.local/bin/"', text)
        self.assertIn('"$repo/daemons/local.claude-bodyguard.plist"', text)

    def test_installer_root_commands_are_not_concatenated_shell_source(self):
        text = (ROOT / "installer/安装.command").read_text(encoding="utf-8")
        self.assertIn("sudo /bin/bash -s --", text)
        self.assertIn("<<'ROOT_INSTALL'", text)
        self.assertNotIn("SYSCMDS=", text)
        self.assertNotIn('sudo bash -c "$SYSCMDS"', text)

    def test_core_syncs_root_target_instead_of_rewriting_watchdog(self):
        text = CORE.read_text(encoding="utf-8")
        self.assertIn("tz-target", text)
        self.assertIn("tz_target_sync_command", text)
        self.assertNotIn("s|^TARGET=.*|TARGET=", text)
        self.assertNotIn("__TZ_TARGET__", text)
        self.assertNotIn("__HOME__", text)
        self.assertNotIn("ENVJSON=", (ROOT / "daemons/tz-watchdog.sh").read_text(encoding="utf-8"))


class RootInstallerTests(unittest.TestCase):
    INSTALLER = ROOT / "installer/安装.command"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="root-installer-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.stage = self.base / "stage dir 'quoted"
        self.repo = self.base / "repo dir 'quoted"
        self.logs = self.base / "log dir 'quoted"
        self.appdir = self.base / "Library/Application Support/claude-switcher"
        self.daemons = self.base / "Library/LaunchDaemons"
        self.zoneinfo = self.base / "zoneinfo"
        self.sentinel = self.base / "injected"
        self.calls = self.base / "calls"
        self.bin = self.base / "bin"
        for path in (self.stage, self.repo, self.bin):
            path.mkdir()
        self.daemons.mkdir(parents=True)
        (self.stage / "claude-bodyguard.sh").write_text("bodyguard\n", encoding="utf-8")
        (self.stage / "tz-watchdog.sh").write_text("watchdog\n", encoding="utf-8")
        for name in ("local.claude-bodyguard.plist", "local.tz-watchdog.plist"):
            (self.repo / "daemons").mkdir(exist_ok=True)
            (self.repo / "daemons" / name).write_text(name + "\n", encoding="utf-8")
        zone = self.zoneinfo / "America/New_York"
        zone.parent.mkdir(parents=True)
        zone.write_text("test zone\n", encoding="utf-8")
        for name in ("chown", "launchctl", "dscacheutil", "killall"):
            self.stub(name)
        install = self.bin / "install"
        install.write_text(
            "#!/bin/bash\nargs=()\nwhile [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in -o|-g) shift 2 ;; *) args+=(\"$1\"); shift ;; esac\n"
            "done\nexec /usr/bin/install \"${args[@]}\"\n", encoding="utf-8")
        install.chmod(0o755)
        self.stub("systemsetup", absolute=True)
        self.stub("networksetup", absolute=True)

    def stub(self, name, absolute=False):
        path = self.bin / name
        path.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"" + name + " $*\" >> \"$ROOT_CALLS\"\n",
            encoding="utf-8")
        path.chmod(0o755)

    def root_body(self):
        text = self.INSTALLER.read_text(encoding="utf-8")
        marker = "    sudo /bin/bash -s --"
        if marker not in text or "<<'ROOT_INSTALL'" not in text:
            return ""
        start = text.index(marker)
        start = text.index("\n", start) + 1
        end = text.index("\nROOT_INSTALL", start)
        body = text[start:end]
        body = body.replace("/Library/Application Support/claude-switcher", str(self.appdir))
        body = body.replace("/Library/LaunchDaemons", str(self.daemons))
        body = body.replace("/usr/share/zoneinfo", str(self.zoneinfo))
        body = body.replace("/usr/sbin/systemsetup", str(self.bin / "systemsetup"))
        body = body.replace("/usr/sbin/networksetup", str(self.bin / "networksetup"))
        return body

    def run_root(self, timezone="America/New_York", set_tz="1", services=""):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.defpath,
                   ROOT_CALLS=str(self.calls))
        return subprocess.run(
            ["/bin/bash", "-s", "--", str(self.stage), str(self.repo), str(self.logs),
             timezone, set_tz, services],
            input=self.root_body(), text=True, capture_output=True, env=env, timeout=30)

    def test_special_character_paths_and_services_remain_single_arguments(self):
        service = "Wi-Fi; touch " + str(self.sentinel)
        result = self.run_root(services=service + "\nThunderbolt Bridge\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.appdir / "claude-bodyguard.sh").read_text(), "bodyguard\n")
        self.assertEqual((self.appdir / "tz-watchdog.sh").read_text(), "watchdog\n")
        self.assertEqual((self.appdir / "tz-target").read_text(), "America/New_York\n")
        self.assertEqual((self.appdir / "tz-target").stat().st_mode & 0o777, 0o644)
        self.assertTrue((self.daemons / "local.tz-watchdog.plist").is_file())
        calls = self.calls.read_text(encoding="utf-8")
        self.assertIn("systemsetup -settimezone America/New_York", calls)
        self.assertIn("networksetup -setv6off " + service, calls)
        self.assertIn("networksetup -setv6off Thunderbolt Bridge", calls)
        self.assertFalse(self.sentinel.exists())

    def test_symlink_install_directory_is_rejected(self):
        outside = self.base / "outside"
        outside.mkdir()
        self.appdir.parent.mkdir(parents=True)
        self.appdir.symlink_to(outside, target_is_directory=True)
        result = self.run_root()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])

    def test_invalid_timezone_is_rejected_before_any_system_change(self):
        timezone = "America/New_York'; touch " + str(self.sentinel) + "; '"
        result = self.run_root(timezone=timezone)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.appdir.exists())
        self.assertFalse(self.sentinel.exists())


class EnvValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.env = self.home / ".claude-switcher/env.json"

    def write_env(self, **overrides):
        payload = {
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "G",
            "country": "US", "timezone": "America/New_York", "locale": "en_US",
            "fake_ip_range": "198.18.0.0/16",
        }
        payload.update(overrides)
        self.env.write_text(json.dumps(payload), encoding="utf-8")

    def run_core(self, *args):
        env = dict(os.environ, HOME=str(self.home), LC_ALL="C")
        env.pop("CLAUDE_SWITCHER_FAKE_IP_RANGE", None)
        return subprocess.run(["/bin/bash", str(CORE), *args], text=True,
                              capture_output=True, env=env, timeout=30)

    def test_fake_prefix_follows_mask(self):
        cases = {
            "198.18.0.0/16": "198.18.",
            "10.0.0.0/8": "10.",
            "192.168.1.0/24": "192.168.1.",
            "172.16.0.0/12": "172.",
        }
        for cidr, expected in cases.items():
            with self.subTest(cidr=cidr):
                self.write_env(fake_ip_range=cidr)
                run = self.run_core("fake-prefix")
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                self.assertEqual(run.stdout.strip(), expected)

    def test_invalid_timezone_is_rejected(self):
        self.write_env(timezone="UTC; id > /tmp/pwned")
        run = self.run_core("fake-prefix")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("timezone", run.stderr)

    def test_valid_iana_timezone_with_hyphen_or_plus_is_accepted(self):
        for timezone in ("America/Port-au-Prince", "Etc/GMT+5"):
            with self.subTest(timezone=timezone):
                self.write_env(timezone=timezone)
                run = self.run_core("fake-prefix")
                self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_unknown_timezone_is_rejected(self):
        self.write_env(timezone="America/No_Such_City")
        run = self.run_core("fake-prefix")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("timezone", run.stderr)

    def test_invalid_fake_range_is_rejected(self):
        self.write_env(fake_ip_range="198.18.0.0/16; id")
        run = self.run_core("fake-prefix")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("fake_ip_range", run.stderr)

    def test_state_dirs_are_private(self):
        self.write_env()
        run = self.run_core("fake-prefix")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        base = self.home / ".claude-switcher"
        for path in (base, base / "accounts"):
            self.assertEqual(path.stat().st_mode & 0o777, 0o700, path)


class CoreTimezoneTargetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tz-target-command-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.appdir = self.base / "Application Support/claude-switcher"
        self.appdir.mkdir(parents=True)
        self.zoneinfo = self.base / "zoneinfo"
        zone = self.zoneinfo / "America/New_York"
        zone.parent.mkdir(parents=True)
        zone.write_text("test zone\n", encoding="utf-8")
        text = CORE.read_text(encoding="utf-8")
        start = text.index("shq() {")
        end = text.index("\n# 一键修复", start)
        self.helpers = text[start:end]

    def command(self, target):
        run = subprocess.run(
            ["/bin/bash", "-c", self.helpers + '\ntz_target_sync_command "$1"', "--", target],
            text=True, capture_output=True, timeout=10)
        self.assertEqual(run.returncode, 0, run.stderr)
        return (run.stdout
                .replace("/Library/Application Support/claude-switcher", str(self.appdir))
                .replace("/usr/share/zoneinfo", str(self.zoneinfo))
                .replace("chown root:wheel", ":"))

    def test_command_atomically_writes_root_target(self):
        run = subprocess.run(["/bin/bash", "-c", self.command("America/New_York")],
                             text=True, capture_output=True, timeout=10, cwd=self.base)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        target = self.appdir / "tz-target"
        self.assertEqual(target.read_text(encoding="utf-8"), "America/New_York\n")
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        self.assertEqual(list(self.appdir.glob(".tz-target.*")), [])

    def test_command_rejects_injected_timezone_before_writing(self):
        target = self.appdir / "tz-target"
        run = subprocess.run(
            ["/bin/bash", "-c", self.command("America/New_York'; touch injected; '")],
            text=True, capture_output=True, timeout=10, cwd=self.base)
        self.assertNotEqual(run.returncode, 0)
        self.assertFalse(target.exists())
        self.assertFalse((self.base / "injected").exists())


class InstallVersionTests(unittest.TestCase):
    """安装器写版本 ↔ 核心读版本。

    断掉任意一头,报告里的 core_version 就恒为 unknown —— 排查时又分不清
    用户装的是哪一版。macOS 侧此前只有读端(core app_version),没有写端。
    这里直接抽安装器里真实的两段代码执行,不抄副本。
    """

    INSTALLER = ROOT / "installer/安装.command"
    WRITE_START = r"""printf '%s\n' "$APP_VERSION" > "$H/.claude-switcher/version.txt"""
    WRITE_END = 'chmod 600 "$H/.claude-switcher/version.txt"'

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="install-version-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = root / "repo"
        self.repo.mkdir()
        self.home = root / "home"
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.env = dict(os.environ, LC_ALL="C", HOME=str(self.home),
                        GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null",
                        GIT_CONFIG_NOSYSTEM="1")

    def block(self, start_marker, end_marker):
        text = self.INSTALLER.read_text(encoding="utf-8")
        start = text.index(start_marker)
        return text[start:text.index("\n", text.index(end_marker, start))]

    def resolve(self):
        code = ("set -u\nREPO=%s\n" % shlex.quote(str(self.repo))
                + self.block('APP_VERSION="$(head -1',
                             '[ "${#APP_VERSION}" -le 40 ]')
                + '\nprintf "%s" "$APP_VERSION"\n')
        run = subprocess.run(["/bin/bash", "-c", code], text=True,
                             capture_output=True, env=self.env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        return run.stdout

    def write_version(self, version):
        code = ("set -u\nH=%s\nAPP_VERSION=%s\n"
                % (shlex.quote(str(self.home)), shlex.quote(version))
                + self.block(self.WRITE_START, self.WRITE_END) + "\n")
        run = subprocess.run(["/bin/bash", "-c", code], text=True,
                             capture_output=True, env=self.env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stderr)
        return self.home / ".claude-switcher/version.txt"

    def test_packaged_version_file_wins(self):
        (self.repo / "VERSION").write_text("1.8.12-dev\n", encoding="utf-8")
        self.assertEqual(self.resolve(), "1.8.12-dev")

    def test_source_install_falls_back_to_git_describe(self):
        """clone 仓库后双击安装器:没有 VERSION,也不能一律叫 0.0.0-dev。"""
        if not shutil.which("git"):
            self.skipTest("git 不可用")
        for args in (["init", "-q", str(self.repo)],
                     ["-C", str(self.repo), "-c", "user.email=t@example.invalid",
                      "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init"],
                     ["-C", str(self.repo), "tag", "v1.2.3"]):
            subprocess.run(["git", *args], env=self.env, check=True,
                           capture_output=True, timeout=30)
        self.assertEqual(self.resolve(), "1.2.3")

    def test_missing_sources_fall_back_to_dev(self):
        self.assertEqual(self.resolve(), "0.0.0-dev")

    def test_invalid_or_overlong_version_falls_back(self):
        """字符集/长度必须与 core app_version() 一致,否则写进去也读不出来。"""
        for bad in ("1.0/../../x", "1.0; id", "9" * 41):
            with self.subTest(bad=bad):
                (self.repo / "VERSION").write_text(bad + "\n", encoding="utf-8")
                self.assertEqual(self.resolve(), "0.0.0-dev")

    def test_installer_writes_private_version_file(self):
        path = self.write_version("1.8.12-dev")
        self.assertEqual(path.read_text(encoding="utf-8").strip(), "1.8.12-dev")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_core_report_reads_installed_version(self):
        """端到端:安装器落盘的版本必须出现在报告 v2 的 core_version 里。"""
        self.write_version("1.8.12-dev")
        report = Path(self.temp.name) / "last-check.txt"
        report.write_text("代理内核=ok:Clash Verge 运行中\nTUN网卡=ok\n", encoding="utf-8")
        env = dict(self.env, CLAUDE_SWITCHER_PYTHON=sys.executable, PYTHONUTF8="1")
        run = subprocess.run(["/bin/bash", str(CORE), "_support", "report",
                              str(report), str(CORE)],
                             text=True, capture_output=True, env=env, timeout=30)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(json.loads(run.stdout)["core_version"], "1.8.12-dev")


if __name__ == "__main__":
    unittest.main()
