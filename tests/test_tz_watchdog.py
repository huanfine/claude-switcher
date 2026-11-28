"""root 时区看门狗:只认管理员授权写入的 tz-target,不读用户可写环境。

夹具把 /etc/localtime、systemsetup 与 zoneinfo 换成临时路径,不碰真实系统。
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "daemons/tz-watchdog.sh"


class TzWatchdogTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "_trash").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="tz-watchdog-", dir=ROOT / "_trash")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.home = self.base / "home"
        (self.home / ".claude-switcher").mkdir(parents=True)
        self.log_dir = self.base / "logs"
        self.log_dir.mkdir()
        self.zoneinfo = self.base / "zoneinfo"
        for name in ("America/New_York", "America/Los_Angeles", "Asia/Tokyo"):
            path = self.zoneinfo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("test zone\n", encoding="utf-8")
        self.target = self.base / "tz-target"

        self.localtime = self.base / "localtime"
        os.symlink("/var/db/timezone/zoneinfo/America/Los_Angeles", self.localtime)
        self.record = self.base / "systemsetup.log"
        self.fake_systemsetup = self.base / "systemsetup"
        self.fake_systemsetup.write_text(
            "#!/bin/bash\nprintf '%s\\n' \"$*\" >> " + repr(str(self.record)) + "\n",
            encoding="utf-8")
        self.fake_systemsetup.chmod(0o755)

    def watchdog(self):
        text = TEMPLATE.read_text(encoding="utf-8")
        self.assertNotIn("__TZ_TARGET__", text)
        self.assertNotIn("__HOME__", text)
        self.assertIn("__LOG_DIR__", text)
        text = text.replace("__LOG_DIR__", str(self.log_dir))
        text = text.replace("/Library/Application Support/claude-switcher/tz-target",
                            str(self.target))
        text = text.replace("/usr/share/zoneinfo", str(self.zoneinfo))
        text = text.replace("/usr/sbin/systemsetup", str(self.fake_systemsetup))
        text = text.replace("/etc/localtime", str(self.localtime))
        path = self.base / "tz-watchdog.sh"
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)
        return path

    def write_env(self, **values):
        payload = {"proxy_mode": "clash-verge", "proxy_group": "G",
                   "country": "US", "timezone": "America/Los_Angeles",
                   "locale": "en_US", "schema": 1}
        payload.update(values)
        (self.home / ".claude-switcher/env.json").write_text(
            json.dumps(payload, indent=2), encoding="utf-8")

    def run_watchdog(self, target="America/New_York"):
        if target is not None:
            self.target.write_text(target + "\n", encoding="utf-8")
        return subprocess.run(["/bin/bash", str(self.watchdog())], text=True,
                              capture_output=True, timeout=30)

    def applied(self):
        if not self.record.exists():
            return []
        return [line.strip() for line in self.record.read_text(encoding="utf-8").splitlines()
                if line.strip()]

    def log(self):
        path = self.log_dir / "tz-watchdog.log"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def test_root_target_wins_over_user_env(self):
        self.write_env(timezone="America/Los_Angeles")
        result = self.run_watchdog()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.applied(), ["-settimezone America/New_York"])

    def test_missing_root_target_does_nothing_and_logs(self):
        self.write_env(timezone="America/Los_Angeles")
        result = self.run_watchdog(target=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.applied(), [])
        self.assertIn("tz-target", self.log())

    def test_invalid_or_unknown_root_target_is_never_executed(self):
        for value in ("", "../etc/passwd", "/America/New_York",
                      "America/New_York;id", "No/Such_Zone", "UTC"):
            with self.subTest(value=value):
                if self.record.exists():
                    self.record.unlink()
                result = self.run_watchdog(value)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.applied(), [])
                self.assertIn("tz-target", self.log())

    def test_symlink_target_is_rejected(self):
        real = self.base / "user-controlled-target"
        real.write_text("America/New_York\n", encoding="utf-8")
        self.target.symlink_to(real)
        result = self.run_watchdog(target=None)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.applied(), [])

    def test_noop_when_already_on_target(self):
        os.unlink(self.localtime)
        os.symlink("/var/db/timezone/zoneinfo/America/New_York", self.localtime)
        self.run_watchdog()
        self.assertEqual(self.applied(), [])

    def test_logs_the_correction(self):
        self.run_watchdog()
        self.assertIn("America/Los_Angeles", self.log())
        self.assertIn("America/New_York", self.log())


if __name__ == "__main__":
    unittest.main()
