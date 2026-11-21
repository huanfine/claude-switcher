"""self_update（核心里的 update / update --auto）的回归。

背景:--auto 由 LaunchAgent 每 12 小时静默调用,它的跳过判断只 diff「内容
是否不同」——发布产物 = 安装产物,双方都是 main 的原样拷贝,没有可比较的
版本号。代价是:开发机上本地改动还没推送时,--auto 会把远端旧版盖回来,
2026-11-21 实测把已验证安装的纯净度修复降级回滚。

这里用假 HOME + 假 curl(假 zip + 假 SHA256SUMS)验证:
  1. --auto 在 update-hold 哨兵存在时不覆盖本地;
  2. 哨兵不拦手动 update(显式执行就是要比对/换远端版)。

关键实现细节:self_update 的 BIN 从 $0 推导,所以必须把真核心**拷贝**到
假安装位再从那里运行 —— 直接跑仓库路径会把仓库工作区当成安装目录覆盖掉
(第一版夹具犯过,core/claude-switch.sh 被写成了 33 字节的假脚本)。

不碰真实 ~/.local/bin、不联网。
"""
import hashlib
import json
import shutil
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT / "core/claude-switch.sh"
TRASH = PROJECT / "_trash"

FAKE_CURL = """\
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *SHA256SUMS) cp "$CS_SERVE_SUMS" "$out" ;;
  *codeload*) cp "$CS_SERVE_ZIP" "$out" ;;
  *) exit 22 ;;
esac
"""


class SelfUpdateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="self-update-", dir=str(TRASH))
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        (self.home / ".local/bin").mkdir(parents=True)
        (self.home / ".claude-switcher").mkdir(parents=True)
        # 真核心拷贝进假安装位:BIN 从 $0 推导,必须让推导落在假 HOME 里。
        self.bin = self.home / ".local/bin/claude-switch.sh"
        shutil.copy(SCRIPT, self.bin)
        self.bin.chmod(self.bin.stat().st_mode | stat.S_IXUSR)
        (self.home / ".claude-switcher/env.json").write_text(json.dumps({
            "schema": 1, "proxy_mode": "clash-verge", "proxy_group": "g",
            "country": "US", "timezone": "America/Denver", "locale": "en-US",
            "clash_dir": str(self.root / "nonexistent-clash"),
            "fake_ip_range": "198.18.0.0/16",
        }), encoding="utf-8")
        self.fakebin = self.root / "bin"
        self.fakebin.mkdir()
        curl = self.fakebin / "curl"
        curl.write_text(FAKE_CURL, encoding="utf-8")
        curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
        # 远端材料默认与本地相同,让手动 update 走 diff 短路返回,
        # 不触发替换后的完整自检(那是 checkdetail 全链路,单测不伺候);
        # auto 用例要测「内容不同 + 哨兵」,在自己体内把远端改成不同。
        self.zip_path = self.root / "main.zip"
        self.sums_path = self.root / "SHA256SUMS"
        self.serve_remote(SCRIPT.read_text(encoding="utf-8"))

    def serve_remote(self, content):
        """把「远端 main」换成给定内容:重写假 zip 与假 SHA256SUMS。"""
        with zipfile.ZipFile(self.zip_path, "w") as zf:
            zf.writestr("claude-switcher-main/core/claude-switch.sh", content)
        digest = hashlib.sha256(content.encode("utf-8")).hexdigest()
        self.sums_path.write_text(f"{digest}  core/claude-switch.sh\n", encoding="utf-8")

    def run_update(self, *args):
        env = {
            "PATH": f"{self.fakebin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "CS_SERVE_ZIP": str(self.zip_path),
            "CS_SERVE_SUMS": str(self.sums_path),
            "LC_ALL": "C",
        }
        return subprocess.run(["/bin/bash", str(self.bin), "update", *args],
                              text=True, capture_output=True, env=env, timeout=90)

    def update_log(self):
        log = self.home / ".claude-switcher" / "update.log"
        return log.read_text(encoding="utf-8") if log.exists() else ""

    def test_auto_update_respects_update_hold_sentinel(self):
        """--auto 在哨兵存在时不得覆盖本地:本地改动可能还没推送。

        替换发生前的最后一道闸。没有它,无人值守通道每 12 小时把远端 main
        原样盖回本地 —— 对生产安装是「保持与远端一致」的正确行为,
        对开发机是把未推送的工作静默回滚。
        """
        (self.home / ".claude-switcher/update-hold").write_text("", encoding="utf-8")
        # 远端换成不同内容:没有哨兵时 --auto 会执行替换,这样才能证明是哨兵拦住的
        # (若是「远端相同走了 diff 短路」,文件不变但日志里不会有 SKIP,断言会漏)。
        self.serve_remote(SCRIPT.read_text(encoding="utf-8") + "\n# unpushed dev line\n")
        run = self.run_update("--auto")
        self.assertEqual(self.bin.read_text(encoding="utf-8"),
                         SCRIPT.read_text(encoding="utf-8"),
                         "哨兵存在时 --auto 覆盖了本地核心")
        self.assertIn("update-hold", self.update_log())

    def test_manual_update_ignores_update_hold_sentinel(self):
        """手动 update 是显式意志,哨兵不得拦。

        哨兵只约束无人值守通道。用户亲手敲 update 就是要比对/换远端,
        这时再报 SKIP 就是把工具意志凌驾于用户意志之上。
        远端与本地相同,diff 判断直接放行并报「已是最新版本」——
        走到这一句即证明流程通过了哨兵检查。
        """
        (self.home / ".claude-switcher/update-hold").write_text("", encoding="utf-8")
        run = self.run_update()
        combined = run.stdout + run.stderr + self.update_log()
        self.assertNotIn("SKIP", combined, "哨兵拦下了手动 update")
        self.assertIn("已是最新版本", combined, "手动 update 没走到远端比对")
        self.assertEqual(self.bin.read_text(encoding="utf-8"),
                         SCRIPT.read_text(encoding="utf-8"),
                         "远端与本地相同时不该有任何写入")


if __name__ == "__main__":
    unittest.main()
