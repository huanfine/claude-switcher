"""一体化安装包（*-full.zip）的回归。

背景：以前别的机器要在 installer-kit / app-only / upgrade-core 之间做选择题，
kit 还得现场用 swiftc 编译 App（macOS 26/27 上 SwiftUI 宏经常编不过）。
现在一个 full 包带上编译好的 App，安装器检测到就直接复制，全程不碰 swiftc。

这里不联网、不装系统组件、不碰真实 HOME：
  - 从 安装.command 抽出「第 4 段·安装 App」，用会失败的假 swiftc 证明预编译路径
    真的绕过了编译器；再证明源码包路径仍然会编译。
  - 把打包脚本里的「一键安装.command」抽出来真跑一次，确认入口能找到安装器。
  - 静态校验打包脚本 / CI / README 的 full 包契约，避免以后又悄悄退回三个包。
"""
import os
import plistlib
import re
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "installer/安装.command"
PACKAGER = PROJECT / "scripts/package-macos.sh"
WORKFLOW = PROJECT / ".github/workflows/release.yml"
README = PROJECT / "README.md"

APP_REL = "Claude 环境检查器.app/Contents/MacOS/ClaudeSwitcher"


def _app_section(text: str) -> str:
    """取出「第 4 段」；测试环境不能真去 kill 用户正在运行的 App。"""
    start = text.index("# ---- 4.")
    end = text.index("# ---- 5.")
    return text[start:end].replace(
        "pkill -x ClaudeSwitcher 2>/dev/null", ": # pkill skipped in tests"
    )


def _fake_app(root: Path) -> Path:
    app = root / "Claude 环境检查器.app"
    exe = app / "Contents/MacOS/ClaudeSwitcher"
    exe.parent.mkdir(parents=True)
    exe.write_text("#!/bin/sh\nexit 0\n")
    exe.chmod(0o755)
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps({"CFBundleShortVersionString": "9.9-test"})
    )
    return app


def _fake_swiftc(bin_dir: Path, marker: Path, succeed: bool) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    script = bin_dir / "swiftc"
    script.write_text(
        "#!/bin/bash\n"
        f"touch '{marker}'\n"
        + ("exit 1\n" if not succeed else
           'out=""; while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi; done\n'
           'printf "#!/bin/sh\\nexit 0\\n" > "$out"; chmod +x "$out"; exit 0\n')
    )
    script.chmod(0o755)


class FullPackageTests(unittest.TestCase):
    def _run_app_section(self, *, prebuilt: bool, swiftc_succeeds: bool):
        text = INSTALLER.read_text()
        body = _app_section(text)
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            repo, home, bin_dir = tmp / "repo", tmp / "home", tmp / "bin"
            home.mkdir()
            (home / "Desktop").mkdir()
            repo.mkdir()
            marker = tmp / "swiftc-called"
            _fake_swiftc(bin_dir, marker, swiftc_succeeds)
            if prebuilt:
                _fake_app(repo)

            prelude = "\n".join([
                "#!/bin/bash",
                f'H="{home}"',
                f'REPO="{repo}"',
                f'PREBUILT_APP="{repo}/Claude 环境检查器.app"',
                f'USE_PREBUILT={1 if prebuilt else 0}',
                "",
            ])
            script = tmp / "section.sh"
            script.write_text(prelude + body)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
            proc = subprocess.run(
                ["bash", str(script)], capture_output=True, text=True,
                stdin=subprocess.DEVNULL, env=env, timeout=60,
            )
            installed = home / "Desktop" / "Claude 环境检查器.app" / "Contents/MacOS/ClaudeSwitcher"
            # 必须在 TemporaryDirectory 还没销毁前取快照,否则查到的永远是「不存在」。
            return proc, marker.exists(), installed.exists(), os.access(installed, os.X_OK)

    def test_prebuilt_app_skips_swiftc_even_if_compiler_is_broken(self):
        """随包 App 必须直接复制过去；故意让 swiftc 一调用就失败。"""
        proc, swiftc_called, installed, executable = self._run_app_section(
            prebuilt=True, swiftc_succeeds=False
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertFalse(swiftc_called, "预编译包不该调用 swiftc")
        self.assertTrue(installed, "App 没有被复制到桌面")
        self.assertTrue(executable)
        self.assertIn("跳过编译", proc.stdout)
        self.assertNotIn("App 编译失败", proc.stdout)

    def test_source_kit_still_compiles_when_no_prebuilt_app(self):
        """没有随包 App 的老 kit 路径不能被改坏。"""
        proc, swiftc_called, installed, _ = self._run_app_section(
            prebuilt=False, swiftc_succeeds=True
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertTrue(swiftc_called, "源码包应当调用 swiftc")
        self.assertTrue(installed)
        self.assertIn("App 编译完成", proc.stdout)

    def test_launcher_delegates_to_installer(self):
        """双击「一键安装.command」要能找到包内 installer/安装.command。"""
        packager = PACKAGER.read_text()
        match = re.search(
            r"cat > \"\$FULL_ROOT/一键安装\.command\" <<'LAUNCH_EOF'\n(.*?)\nLAUNCH_EOF",
            packager, re.S,
        )
        self.assertIsNotNone(match, "打包脚本里找不到一键安装入口")
        with tempfile.TemporaryDirectory() as td:
            pkg = Path(td) / "pkg"
            (pkg / "installer").mkdir(parents=True)
            (pkg / "installer/安装.command").write_text(
                '#!/bin/bash\necho "LAUNCH_OK:$PWD"\n'
            )
            launcher = pkg / "一键安装.command"
            launcher.write_text(match.group(1))
            launcher.chmod(0o755)
            proc = subprocess.run(
                ["bash", str(launcher)], capture_output=True, text=True,
                stdin=subprocess.DEVNULL, timeout=30,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
            self.assertIn(f"LAUNCH_OK:{pkg}", proc.stdout)

    def test_packager_contract(self):
        script = PACKAGER.read_text()
        for needle in (
            "FULL_ZIP=", "FULL_NAME=", "一键安装.command", "先读我.txt",
            'ditto "$APP" "$FULL_ROOT/Claude 环境检查器.app"',
            "com.apple.quarantine", "一体化安装包缺少",
        ):
            self.assertIn(needle, script, f"打包脚本缺少: {needle}")

    def test_installer_contract(self):
        script = INSTALLER.read_text()
        self.assertIn('PREBUILT_APP="$REPO/Claude 环境检查器.app"', script)
        self.assertIn('[ -x "$PREBUILT_APP/Contents/MacOS/ClaudeSwitcher" ]', script)
        self.assertIn('if [ "$USE_PREBUILT" -eq 0 ] && ! command -v swiftc', script)
        self.assertIn('ditto "$PREBUILT_APP" "$APP"', script)

    def test_release_workflow_publishes_full_zip(self):
        workflow = WORKFLOW.read_text()
        self.assertIn('"ClaudeSwitcher-${VERSION}-macos-arm64-full.zip" \\', workflow)
        self.assertIn('"build/ClaudeSwitcher-${VERSION}-macos-arm64-full.zip"', workflow)

    def test_readme_leads_with_single_package(self):
        readme = README.read_text()
        self.assertIn("-full.zip", readme)
        self.assertIn("一个包搞定", readme)
        self.assertIn("一键安装.command", readme)
        self.assertIn("releases/latest", readme)

    def test_built_full_zip_if_present(self):
        """本地跑过打包时，顺手验一下产物清单与可执行位。"""
        zips = sorted((PROJECT / "build").glob("ClaudeSwitcher-*-macos-*-full.zip"))
        if not zips:
            self.skipTest("本地尚未运行 package-macos.sh")
        # ditto 写 zip 时中文名是 UTF-8 字节但没置 UTF-8 flag,zipfile 会按 cp437
        # 解成乱码。这里把字节还原回来,免得误报「包里缺文件」。
        def fixed(name):
            try:
                return name.encode("cp437").decode("utf-8")
            except (UnicodeEncodeError, UnicodeDecodeError):
                return name

        with zipfile.ZipFile(zips[-1]) as zf:
            infos = {fixed(i.filename): i for i in zf.infolist()}
            root = next(iter(infos)).split("/")[0]
            def has(rel):
                return f"{root}/{rel}" in infos
            def executable(rel):
                info = infos.get(f"{root}/{rel}")
                return bool(info and info.external_attr >> 16 & 0o111)
            for rel in (
                "一键安装.command", "先读我.txt", "core/claude-switch.sh",
                "core/stun-probe.py", "daemons/claude-bodyguard.sh",
                "installer/安装.command", "installer/卸载.command",
                "scripts/upgrade-core.sh", "SHA256SUMS", APP_REL,
            ):
                self.assertTrue(has(rel), f"full 包缺少 {rel}")
            for rel in ("一键安装.command", "installer/安装.command",
                        "scripts/upgrade-core.sh", APP_REL):
                self.assertTrue(executable(rel), f"full 包里 {rel} 丢了可执行位")


if __name__ == "__main__":
    unittest.main()
