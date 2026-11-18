"""Windows/Linux 发布产物的跨平台门禁测试。

不跑真实发布；用临时 BUILD_DIR 生成与仓库内容一致的 zip/tar.gz，
真实执行 scripts/release-check-platforms.sh 的成功与失败路径。
"""
import io
import os
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts" / "release-check-platforms.sh"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"
VERSION = "9.9-test"

WIN_FILES = (
    "windows/claude-switch.ps1",
    "windows/SwitcherUI.ps1",
    "windows/install.ps1",
    "windows/claude-bodyguard.ps1",
    "windows/README.md",
    "README.md",
    "AGENTS.md",
    "SECURITY.md",
    "LICENSE",
)
LINUX_FILES = (
    "linux/claude-switch.sh",
    "linux/install.sh",
    "linux/stun-probe.py",
    "linux/claude-bodyguard.sh",
    "linux/README.md",
    "README.md",
    "AGENTS.md",
    "SECURITY.md",
    "LICENSE",
)
LINUX_EXECUTABLES = (
    "linux/claude-switch.sh",
    "linux/install.sh",
    "linux/claude-bodyguard.sh",
)


def _make_packages(build: Path, *, overrides=None, omit=None, linux_modes=None):
    overrides = overrides or {}
    omit = set(omit or ())
    linux_modes = linux_modes or {}

    def payload(rel):
        if rel in overrides:
            return overrides[rel]
        return (ROOT / rel).read_bytes()

    win_top = f"ClaudeSwitcher-{VERSION}-windows"
    with zipfile.ZipFile(build / f"{win_top}.zip", "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in WIN_FILES:
            if rel not in omit:
                zf.writestr(f"{win_top}/{rel}", payload(rel))
        if "VERSION" not in omit:
            zf.writestr(
                f"{win_top}/VERSION",
                overrides.get("VERSION", (VERSION + "\n").encode()),
            )

    linux_top = f"ClaudeSwitcher-{VERSION}-linux"
    with tarfile.open(build / f"{linux_top}.tar.gz", "w:gz") as tf:
        for rel in LINUX_FILES:
            if rel in omit:
                continue
            data = payload(rel)
            info = tarfile.TarInfo(f"{linux_top}/{rel}")
            info.size = len(data)
            info.mode = linux_modes.get(
                rel, 0o755 if rel in LINUX_EXECUTABLES else 0o644
            )
            tf.addfile(info, io.BytesIO(data))


def _run_gate(build: Path):
    env = dict(os.environ, BUILD_DIR=str(build))
    return subprocess.run(
        ["bash", str(GATE), VERSION],
        capture_output=True, text=True, env=env, timeout=60,
    )


class ReleasePlatformGateTests(unittest.TestCase):
    def test_gate_is_executable_and_wired_into_release(self):
        self.assertTrue(os.access(GATE, os.X_OK))
        gate = GATE.read_text(encoding="utf-8")
        # mktemp 失败时变量为空;绝不能退化成 rm -rf /*。
        self.assertIn("TMP_MODE=$(mktemp -d", gate)
        self.assertIn("无法创建临时目录", gate)
        self.assertNotIn('"$TMP_MODE"/*', gate)
        workflow = RELEASE.read_text(encoding="utf-8")
        self.assertIn("bash scripts/release-check-platforms.sh \"$VERSION\"", workflow)
        # 必须在打包之后、生成发布校验和之前运行。
        self.assertLess(
            workflow.index("Package Windows and Linux scripts"),
            workflow.index("Verify Windows and Linux packages"),
        )
        self.assertLess(
            workflow.index("Verify Windows and Linux packages"),
            workflow.index("Generate release checksums"),
        )

    def test_matching_packages_pass(self):
        with tempfile.TemporaryDirectory() as td:
            build = Path(td)
            _make_packages(build)
            proc = _run_gate(build)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn("跨平台发布门禁通过", proc.stdout)
            self.assertIn("Windows 包含 function Get-CheckReport", proc.stdout)
            self.assertIn("Linux 包含 report_json()", proc.stdout)

    def test_tampered_windows_script_fails_hash_gate(self):
        with tempfile.TemporaryDirectory() as td:
            build = Path(td)
            original = (ROOT / "windows" / "claude-switch.ps1").read_bytes()
            _make_packages(build, overrides={
                "windows/claude-switch.ps1": original + b"\n# stale package\n",
            })
            proc = _run_gate(build)
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("Windows windows/claude-switch.ps1 与仓库不一致", proc.stdout)

    def test_missing_linux_script_fails_inventory_gate(self):
        with tempfile.TemporaryDirectory() as td:
            build = Path(td)
            _make_packages(build, omit={"linux/claude-switch.sh"})
            proc = _run_gate(build)
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("Linux 包缺少 linux/claude-switch.sh", proc.stdout)

    def test_non_executable_linux_entry_fails_mode_gate(self):
        with tempfile.TemporaryDirectory() as td:
            build = Path(td)
            _make_packages(build, linux_modes={"linux/claude-switch.sh": 0o644})
            proc = _run_gate(build)
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn(
                "Linux linux/claude-switch.sh 在 tar.gz 中缺少可执行位",
                proc.stdout,
            )

    def test_wrong_version_fails_gate(self):
        with tempfile.TemporaryDirectory() as td:
            build = Path(td)
            _make_packages(build, overrides={"VERSION": "0.0-wrong\n"})
            proc = _run_gate(build)
            self.assertNotEqual(proc.returncode, 0, proc.stdout)
            self.assertIn("Windows VERSION=0.0-wrong,期望 9.9-test", proc.stdout)


if __name__ == "__main__":
    unittest.main()
