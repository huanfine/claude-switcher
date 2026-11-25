"""App 自更新(release 通道)的回归护栏。

钉住方案(2026-11-25 §4/§6)的核心契约:
  1. 版本比较按数值比("1.8.2" < "1.8.10"),-dev 后缀忽略;
  2. app_auto_update 开关:默认开,显式 false 才关,坏配置按开(方向安全);
  3. bundle 探测三位置(/Applications ~/Applications ~/Desktop),找不到明确报错;
  4. 换装端到端:下载 → sha256 校验(对照 SHA256SUMS-release.txt) → 解压去
     quarantine → 同卷 rename × 2 原子换装 → 自检(可执行/签名/版本号) →
     version.txt 落盘;
  5. 负例:校验两次不过 → 放弃且旧 bundle 完好;自检失败 → 回滚且 fail 计数,
     连续 2 次 → 熔断哨兵;熔断后 --auto SKIP、手动可执行且成功即解除;
  6. version.txt 自愈:--check 也会把已装 App 版本落盘(手装形态 core_version
     不再 unknown)。
全部负例在 harness 里做(假 curl + 真 zip/签名),不碰真实网络。
"""
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "core/claude-switch.sh"


def extract(name):
    text = CORE.read_text(encoding="utf-8")
    import re
    match = re.search(r"(?ms)^%s\(\) \{\n.*?^\}" % re.escape(name), text)
    if match is None:
        raise AssertionError("找不到函数 %s" % name)
    return match.group(0)


def extract_constants():
    import re
    text = CORE.read_text(encoding="utf-8")
    lines = re.findall(r"(?m)^(?:APP_BUNDLE_NAME|APP_UPDATE_\w+)=.*$", text)
    assert len(lines) >= 5, "APP_UPDATE_* 常量定义不全"
    return "\n".join(lines)


def make_fake_app(dst: Path, version: str) -> None:
    """造一个最小但可过 codesign/plutil 自检的 bundle。"""
    bin_dir = dst / "Contents/MacOS"
    bin_dir.mkdir(parents=True)
    (dst / "Contents/Resources").mkdir()
    info = {
        "CFBundleIdentifier": "local.claude-switcher",
        "CFBundleExecutable": "ClaudeSwitcher",
        "CFBundleName": "Claude 环境检查器",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "LSUIElement": True,
    }
    with open(dst / "Contents/Info.plist", "wb") as f:
        plistlib.dump(info, f)
    exe = bin_dir / "ClaudeSwitcher"
    exe.write_bytes(Path("/bin/echo").read_bytes())
    exe.chmod(0o755)
    subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(dst)],
                   check=True, capture_output=True)


def make_zip(src: Path, out: Path) -> None:
    import zipfile
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(src.rglob("*")):
            zf.write(p, p.relative_to(src).as_posix())


class AppUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cs-appupd-")
        self.home = Path(self.tmp) / "home"
        self.base = self.home / ".claude-switcher"
        self.base.mkdir(parents=True)
        self.apps_dir = self.home / "Applications"
        self.apps_dir.mkdir()

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- harness ----

    def run_harness(self, body, *, remote_version="9.9.9", zip_path=None,
                    sums=None, curl_fail=0, disk_free_mb=None,
                    mode="manual", extra_flag="", busy_stub=True):
        """隔离 HOME + 假 curl + (可选)假 df 跑 update-app。

        zip_path/sums: 提供 → 假 curl 按 URL 供应真文件;
        curl_fail: zip 下载失败次数(按调用顺序消耗)。
        """
        fake_dir = Path(self.tmp) / "fake"
        fake_dir.mkdir(exist_ok=True)
        (fake_dir / "app.zip").write_bytes(zip_path.read_bytes() if zip_path else b"")
        (fake_dir / "sums.txt").write_text(sums or "", encoding="utf-8")

        fake_curl = f'''
CALLS="$FAKE_DIR/curl-calls"
FAIL_LEFT={curl_fail}
# 真 curl 的 -o 必须模拟:内容写文件而不是 stdout,否则二进制 zip 灌进日志
curl() {{
    echo "curl $*" >> "$CALLS"
    local out="" url="" a
    while [ $# -gt 0 ]; do
        case "$1" in
            -o) out="$2"; shift 2 ;;
            http://*|https://*) url="$1"; shift ;;
            *) shift ;;
        esac
    done
    local body=""
    case "$url" in
        */releases/latest*)
            # 真调用是 -o /dev/null -w '%{{url_effective}}':URL 走 stdout 而非 -o
            [ -n "{remote_version}" ] || {{ echo "curl: (7)" >&2; return 7; }}
            printf '%s' "https://github.com/o/r/releases/tag/v{remote_version}"
            return 0 ;;
        *SHA256SUMS-release.txt*) body="$(cat "$FAKE_DIR/sums.txt")" ;;
        *app-only.zip*)
            if [ "$FAIL_LEFT" -gt 0 ]; then FAIL_LEFT=$((FAIL_LEFT-1)); echo "curl: (7)" >&2; return 7; fi
            # zip 是二进制,$( ) 会剥 NUL 损坏内容,必须 cp
            if [ -n "$out" ]; then cp "$FAKE_DIR/app.zip" "$out"; else cat "$FAKE_DIR/app.zip"; fi
            return 0 ;;
        *) echo "curl: unexpected $url" >&2; return 7 ;;
    esac
    if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
}}
'''
        fake_df = ""
        if disk_free_mb is not None:
            # df -g 的输出:Available 是第 4 列
            fake_df = ('df() { echo "Filesystem 1024-blocks Used Available Capacity Mounted on"; '
                       f'echo "fake 999 1 {disk_free_mb} 1% /"; }}\n')

        harness = "\n".join([
            'set -u',
            'BASE="%s"' % self.base,
            extract_constants(),
            'FAKE_DIR="%s"' % fake_dir,
            fake_curl,
            fake_df,
            extract("app_find_bundle"),
            extract("app_installed_version"),
            extract("app_version_cmp"),
            extract("latest_release_version"),
            extract("app_auto_update_enabled"),
            extract("app_update_busy"),
            extract("app_sync_version_txt"),
            extract("app_self_update"),
            # busy guard 读真实进程表(隔离 HOME 隔离不了它),默认在函数定义
            # 之后桩成「不忙」;busy 用例传 busy_stub=False 走真 pgrep + 假进程。
            'app_update_busy() { return 1; }' if busy_stub else "",
            body,
        ])
        # 隔离真机:探测顺序里的 /Applications 指向真机已装 App,
        # 替换成不存在的 /Applications-fake,让探测只看隔离 HOME。
        harness = harness.replace('"/Applications"', '"/Applications-fake"')
        env = dict(os.environ, HOME=str(self.home), PATH="/usr/bin:/bin:/usr/sbin:/sbin")
        env.pop("PYTHONPATH", None)
        return subprocess.run(["/bin/bash", "-c", harness, "cs-test", mode, extra_flag],
                              env=env, text=True, capture_output=True, timeout=60,
                              errors="replace")

    # ---- 纯逻辑 ----

    def test_version_cmp_numeric(self):
        run = self.run_harness(
            'echo "a=$(app_version_cmp 1.8.2 1.8.10) b=$(app_version_cmp 1.8.10 1.8.2) '
            'c=$(app_version_cmp 1.8.13-dev 1.8.13) d=$(app_version_cmp 2.0 1.9.9)"')
        self.assertIn("a=-1 b=1 c=0 d=1", run.stdout, "必须数值比较且 -dev 后缀忽略")

    def test_switch_default_and_explicit(self):
        run = self.run_harness(
            'echo "default=$(app_auto_update_enabled)"; '
            f'printf \'{{"app_auto_update": false}}\' > "{self.base}/checks.json"; '
            'echo "off=$(app_auto_update_enabled)"; '
            f'printf \'not json\' > "{self.base}/checks.json"; '
            'echo "broken=$(app_auto_update_enabled)"')
        self.assertIn("default=1", run.stdout)
        self.assertIn("off=0", run.stdout)
        self.assertIn("broken=1", run.stdout,
                      "默认开/显式 false 关/坏配置按开(方向安全)")

    def test_find_bundle_locations(self):
        # 无 bundle:明确失败,不猜路径
        run = self.run_harness('app_find_bundle && echo FOUND || echo "find-fail"')
        self.assertIn("find-fail", run.stdout)
        # 放入 ~/Applications:命中
        run = self.run_harness(
            f'mkdir -p "{self.apps_dir}/Claude 环境检查器.app"; '
            'app_find_bundle && echo FOUND')
        self.assertIn("FOUND", run.stdout)

    # ---- version.txt 自愈(--check 也要落盘) ----

    def test_check_syncs_version_txt(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.2.3")
        run = self.run_harness('app_self_update "manual" "--check"; echo "rc=$?"',
                               remote_version="9.9.9")
        self.assertIn("App 有更新 1.2.3 → 9.9.9", run.stdout)
        self.assertIn("rc=0", run.stdout)
        vt = (self.base / "version.txt")
        self.assertTrue(vt.exists(), "--check 也要补写 version.txt(方案 §5 自愈)")
        self.assertEqual(vt.read_text(encoding="utf-8").strip(), "1.2.3")
        self.assertEqual(vt.stat().st_mode & 0o777, 0o600)

    def test_check_up_to_date(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "9.9.9")
        run = self.run_harness('app_self_update "manual" "--check"', remote_version="9.9.9")
        self.assertIn("已是最新(9.9.9)", run.stdout)
        self.assertFalse((self.base / "app-update-fails").exists())

    # ---- 端到端换装 ----

    def _prepare_release_zip(self, bundle_version, release_version=None):
        """造发版包:zip 里 bundle 版本 = bundle_version,sums 行名用 release_version
        (默认与 bundle_version 相同)。两者分开才能造「校验过但版本错」的自检失败包。"""
        release_version = release_version or bundle_version
        stage = Path(self.tmp) / "stage"
        if stage.exists():
            import shutil
            shutil.rmtree(stage)
        bundle = stage / "Claude 环境检查器.app"
        make_fake_app(bundle, bundle_version)
        zip_path = stage / "app.zip"
        make_zip(stage, zip_path)
        import hashlib
        sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
        sums = f"{sha}  ClaudeSwitcher-{release_version}-macos-universal-app-only.zip\n"
        return zip_path, sums

    def test_full_swap_success(self):
        zip_path, sums = self._prepare_release_zip("9.9.9")
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        run = self.run_harness(
            'app_self_update "manual"; echo "rc=$?"; '
            'v=$(plutil -extract CFBundleShortVersionString raw '
            f'"{self.apps_dir}/Claude 环境检查器.app/Contents/Info.plist"); echo "now=$v"',
            zip_path=zip_path, sums=sums, remote_version="9.9.9")
        self.assertIn("rc=0", run.stdout, run.stderr[-500:])
        self.assertIn("已更新到 9.9.9", run.stdout)
        self.assertIn("now=9.9.9", run.stdout, "换装后 bundle 版本必须是目标版本")
        self.assertEqual((self.base / "version.txt").read_text(encoding="utf-8").strip(), "9.9.9")
        self.assertFalse((self.base / "app-update-disabled").exists(), "成功不得触发熔断")
        # 备份清理:成功后不得残留 .old-*
        leftovers = list(self.apps_dir.glob("Claude 环境检查器.app.old-*"))
        self.assertEqual(leftovers, [], "成功换装后旧 bundle 备份应被清理")

    def test_bad_zip_two_fails_keeps_old_bundle(self):
        zip_path, sums = self._prepare_release_zip("9.9.9")
        # sums 与 zip 不匹配(校验必败)
        wrong_sums = "0" * 64 + "  ClaudeSwitcher-9.9.9-macos-universal-app-only.zip\n"
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        old_plist = self.apps_dir / "Claude 环境检查器.app/Contents/Info.plist"
        with open(old_plist, "rb") as f:
            old_version = plistlib.load(f)["CFBundleShortVersionString"]
        run = self.run_harness('app_self_update "manual"; echo "rc=$?"',
                               zip_path=zip_path, sums=wrong_sums, remote_version="9.9.9")
        self.assertIn("两次未过", run.stdout, "校验两次失败必须放弃")
        self.assertIn("rc=1", run.stdout)
        # 旧 bundle 完好可用
        with open(old_plist, "rb") as f:
            self.assertEqual(plistlib.load(f)["CFBundleShortVersionString"], old_version)

    def test_selfcheck_failure_rolls_back_then_circuit_breaks(self):
        # 包内版本 ≠ 目标版本 → 校验通过但自检失败 → 回滚;第二次 → 熔断哨兵
        zip_path, sums = self._prepare_release_zip("8.8.8", release_version="9.9.9")
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        run = self.run_harness(
            'app_self_update "manual"; echo "rc1=$?"; '
            'app_self_update "manual"; echo "rc2=$?"; '
            f'[ -f "{self.base}/app-update-disabled" ] && echo "BREAKER=on"',
            zip_path=zip_path, sums=sums, remote_version="9.9.9")
        self.assertIn("rc1=1", run.stdout)
        self.assertIn("rc2=1", run.stdout)
        self.assertIn("BREAKER=on", run.stdout, "连续 2 轮失败必须熔断")
        with open(self.apps_dir / "Claude 环境检查器.app/Contents/Info.plist", "rb") as f:
            self.assertEqual(plistlib.load(f)["CFBundleShortVersionString"], "1.0.0",
                             "回滚后必须是旧版本")

    def test_circuit_breaker_auto_skips_manual_heals(self):
        # 熔断后 --auto SKIP;手动执行成功(换正常包)后哨兵解除
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        run = self.run_harness(
            f'touch "{self.base}/app-update-disabled"; '
            'app_self_update "--auto"; echo "auto_rc=$?"; '
            'app_self_update "manual"; echo "manual_rc=$?"; '
            f'[ -f "{self.base}/app-update-disabled" ] && echo "STILL=on" || echo "STILL=off"',
            zip_path=zip_path, sums=sums, remote_version="9.9.9")
        self.assertIn("已熔断停用", run.stdout)
        self.assertIn("auto_rc=0", run.stdout, "--auto 熔断时安全跳过,不算失败")
        self.assertIn("manual_rc=0", run.stdout)
        self.assertIn("STILL=off", run.stdout, "手动成功后熔断哨兵应解除")

    def test_auto_respects_switch(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        run = self.run_harness(
            f'printf \'{{"app_auto_update": false}}\' > "{self.base}/checks.json"; '
            'app_self_update "--auto"; echo "rc=$?"',
            zip_path=zip_path, sums=sums, remote_version="9.9.9")
        self.assertIn("app_auto_update 已关闭", run.stdout)
        self.assertIn("rc=0", run.stdout)
        # 开关只约束 --auto:手动照常走完
        run = self.run_harness(
            f'printf \'{{"app_auto_update": false}}\' > "{self.base}/checks.json"; '
            'app_self_update "manual" >/dev/null; echo "rc=$?"; '
            'v=$(plutil -extract CFBundleShortVersionString raw '
            f'"{self.apps_dir}/Claude 环境检查器.app/Contents/Info.plist"); echo "now=$v"',
            zip_path=zip_path, sums=sums, remote_version="9.9.9")
        self.assertIn("rc=0", run.stdout)
        self.assertIn("now=9.9.9", run.stdout, "开关不得限制手动显式更新")

    def test_busy_guard_skips(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        # 在 harness 里起一个匹配 busy 模式的假进程
        fake_core = Path(self.tmp) / "claude-switch.sh"
        fake_core.write_text("#!/bin/bash\nsleep 5\n")
        fake_core.chmod(0o755)
        proc = subprocess.Popen(["/bin/bash", str(fake_core), "check"],
                                stdout=subprocess.DEVNULL)
        try:
            run = self.run_harness(
                'app_self_update "manual"; echo "rc=$?"; '
                'v=$(plutil -extract CFBundleShortVersionString raw '
                f'"{self.apps_dir}/Claude 环境检查器.app/Contents/Info.plist"); echo "now=$v"',
                zip_path=zip_path, sums=sums, remote_version="9.9.9",
                busy_stub=False)
            self.assertIn("本轮跳过 App 更新", run.stdout)
            self.assertIn("rc=0", run.stdout)
            self.assertIn("now=1.0.0", run.stdout, "忙时不换装")
        finally:
            proc.kill()
            proc.wait()

    def test_low_disk_aborts(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        run = self.run_harness('app_self_update "manual"; echo "rc=$?"',
                               zip_path=zip_path, sums=sums,
                               remote_version="9.9.9", disk_free_mb=100)
        self.assertIn("磁盘余量不足", run.stdout)
        self.assertIn("rc=1", run.stdout)
        with open(self.apps_dir / "Claude 环境检查器.app/Contents/Info.plist", "rb") as f:
            self.assertEqual(plistlib.load(f)["CFBundleShortVersionString"], "1.0.0")

    def test_network_fail_no_bundle_touch(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        # curl 全部失败:latest 拿不到 → 直接失败;旧 bundle 不动
        run = self.run_harness('app_self_update "manual"; echo "rc=$?"',
                               zip_path=zip_path, sums=sums,
                               remote_version="", curl_fail=99)
        self.assertIn("获取远端最新版本失败", run.stdout)
        self.assertIn("rc=1", run.stdout)

    def test_download_retry_then_giveup(self):
        make_fake_app(self.apps_dir / "Claude 环境检查器.app", "1.0.0")
        zip_path, sums = self._prepare_release_zip("9.9.9")
        # 前 2 次 zip 下载失败(第 1 次 latest 成功,2/3 是 zip 失败,第 4 次起恢复)
        # → 两次尝试都碰上失败 → 放弃
        run = self.run_harness('app_self_update "manual"; echo "rc=$?"',
                               zip_path=zip_path, sums=sums,
                               remote_version="9.9.9", curl_fail=3)
        self.assertIn("两次未过", run.stdout)
        with open(self.apps_dir / "Claude 环境检查器.app/Contents/Info.plist", "rb") as f:
            self.assertEqual(plistlib.load(f)["CFBundleShortVersionString"], "1.0.0")

    # ---- 接线 ----

    def test_dispatch_and_auto_wiring(self):
        sh = CORE.read_text(encoding="utf-8")
        self.assertIn("update-app) app_self_update", sh, "update-app 手动入口必须存在")
        self.assertIn("app_self_update --auto", sh, "--auto 必须接在 update 链路后")
        self.assertIn('app_self_update "" "--check"', sh, "update-check 必须带 App 只读检查")
        # busy guard / 熔断哨兵 / 开关读取的函数都在
        for fn in ("app_update_busy", "app_auto_update_enabled", "app_find_bundle"):
            self.assertIn(f"{fn}()", sh)


if __name__ == "__main__":
    unittest.main()
