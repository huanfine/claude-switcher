"""账号快照加密导出/导入回归测试(仅 macOS)。

使用隔离 HOME 与临时目录,不接触真实账号、登录态或系统设置。
"""
import base64
import hashlib
import hmac
import io
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "core" / "claude-switch.sh"
PASSWORD = "test-password-123"
ARCHIVE_MAGIC = b"CLAUDE-SWITCHER-ARCHIVE-2\n"
AUTH_ITERATIONS = 250000
ENCRYPTION_ITERATIONS = 200000


def function_source(name):
    text = SCRIPT.read_text(encoding="utf-8")
    match = re.search(rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}", text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


def tar_bytes(entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for name, kind, payload in entries:
            member = tarfile.TarInfo(name)
            member.mode = 0o755 if kind == "dir" else 0o644
            if kind == "file":
                data = payload.encode() if isinstance(payload, str) else payload
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
            elif kind == "dir":
                member.type = tarfile.DIRTYPE
                archive.addfile(member)
            elif kind == "symlink":
                member.type = tarfile.SYMTYPE
                member.linkname = payload
                archive.addfile(member)
            elif kind == "hardlink":
                member.type = tarfile.LNKTYPE
                member.linkname = payload
                archive.addfile(member)
            elif kind in ("device", "fifo"):
                member.type = tarfile.FIFOTYPE if kind == "fifo" else tarfile.CHRTYPE
                archive.addfile(member)
            else:
                raise ValueError(kind)
    return stream.getvalue()


def authenticated_archive(payload, *, magic=ARCHIVE_MAGIC, password=PASSWORD, salt=bytes(range(16))):
    header = json_canonical({
        "auth_iterations": AUTH_ITERATIONS,
        "auth_kdf": "pbkdf2-hmac-sha256",
        "cipher": "aes-256-cbc",
        "encryption_iterations": ENCRYPTION_ITERATIONS,
        "salt": base64.b64encode(salt).decode("ascii"),
        "version": 2,
    })
    password_read, password_write = os.pipe()
    try:
        os.write(password_write, password.encode() + b"\n")
    finally:
        os.close(password_write)
    try:
        encrypted = subprocess.run(
            ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", str(ENCRYPTION_ITERATIONS),
             "-md", "sha256", "-salt", "-pass", f"fd:{password_read}"],
            input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(password_read,), check=True,
        ).stdout
    finally:
        os.close(password_read)
    key = hashlib.pbkdf2_hmac(
        "sha256", password.encode(), b"claude-switcher-archive-v2-auth\0" + salt,
        AUTH_ITERATIONS, dklen=32,
    )
    tag = hmac.new(key, magic + header + b"\n" + encrypted, hashlib.sha256).hexdigest().encode()
    return magic + header + b"\n" + tag + b"\n" + encrypted


def snapshot_payload(account="A"):
    import json
    marker = json.dumps({
        "format": "claude-switcher-snapshot",
        "version": 1,
        "account": account,
        "created": "2026-11-28 00:00:00",
    }, separators=(",", ":"))
    return tar_bytes([
        (".", "dir", ""),
        (".claude-switcher-snapshot.json", "file", marker),
        ("sub", "dir", ""),
        ("sub/marker.txt", "file", f"account-{account}"),
    ])


def legacy_archive(payload, password=PASSWORD):
    password_read, password_write = os.pipe()
    try:
        os.write(password_write, password.encode() + b"\n")
    finally:
        os.close(password_write)
    try:
        encrypted = subprocess.run(
            ["openssl", "enc", "-aes-256-cbc", "-pbkdf2", "-iter", str(ENCRYPTION_ITERATIONS),
             "-md", "sha256", "-salt", "-pass", f"fd:{password_read}"],
            input=payload, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(password_read,), check=True,
        ).stdout
    finally:
        os.close(password_read)
    return b"CLAUDE-SWITCHER-ARCHIVE-1\n" + encrypted


def json_canonical(value):
    import json
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("ascii")


@unittest.skipUnless(shutil.which("openssl") and shutil.which("tar"),
                     "archive v2 requires openssl and tar")
class SnapshotArchiveV2Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stage = self.root / "stage"
        self.stage.mkdir()
        (self.stage / "marker.txt").write_text("account-a", encoding="utf-8")
        self.archive = self.root / "account.csnap"
        self.plain = self.root / "plain.tar.gz"
        self.functions = "\n".join(function_source(name) for name in (
            "_snapshot_timeout", "_snapshot_archive_v2", "_snapshot_archive_write",
            "_snapshot_archive_decode", "_snapshot_tar_preflight", "_snapshot_tree_preflight",
            "_snapshot_archive_check",
        ))

    def shell(self, code, password=PASSWORD):
        env = dict(os.environ, HOME=str(self.root), TMPDIR=str(self.root),
                   CLAUDE_SWITCHER_PYTHON=sys.executable,
                   SNAPSHOT_ARCHIVE_MAGIC="CLAUDE-SWITCHER-ARCHIVE-2",
                   SNAPSHOT_ARCHIVE_MAGIC_V1="CLAUDE-SWITCHER-ARCHIVE-1",
                   TEST_ARCHIVE=str(self.archive), TEST_PLAIN=str(self.plain),
                   TEST_STAGE=str(self.stage), TEST_PASSWORD=password, LC_ALL="C")
        return subprocess.run(
            ["/bin/bash", "-c", "set -u\n" + self.functions + "\n" + code],
            env=env, text=True, capture_output=True, timeout=45,
        )

    def decode(self, password=PASSWORD):
        return self.shell(
            '_snapshot_archive_decode "$TEST_ARCHIVE" "$TEST_PASSWORD" "$TEST_PLAIN" 30',
            password=password,
        )

    def test_writer_emits_v2_and_roundtrip_authenticates(self):
        written = self.shell(
            '_snapshot_archive_write "$TEST_STAGE" "$TEST_ARCHIVE" "$TEST_PASSWORD" 30')
        self.assertEqual(written.returncode, 0, written.stdout + written.stderr)
        self.assertTrue(self.archive.read_bytes().startswith(ARCHIVE_MAGIC))
        self.assertEqual(self.archive.stat().st_mode & 0o777, 0o600)
        self.assertFalse(list(self.root.glob(".claude-snapshot-*")))
        checked = self.shell(
            '_snapshot_archive_check "$TEST_ARCHIVE" "$TEST_PASSWORD" 30')
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)

    def test_v2_header_and_tag_tampering_are_rejected(self):
        original = authenticated_archive(snapshot_payload())
        magic, rest = original.split(b"\n", 1)
        header, tag, blob = rest.split(b"\n", 2)
        cases = (
            magic + b"\n" + header.replace(b'"version":2', b'"version":1') + b"\n" + tag + b"\n" + blob,
            magic + b"\n" + header + b"\n" + bytes([tag[0] ^ 1]) + tag[1:] + b"\n" + blob,
        )
        for data in cases:
            with self.subTest(size=len(data)):
                self.archive.write_bytes(data)
                result = self.decode()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("归档认证失败", result.stdout + result.stderr)
                self.assertFalse(self.plain.exists())

    def test_writer_does_not_overwrite_existing_output(self):
        self.archive.write_bytes(b"keep-existing-output")
        result = self.shell(
            '_snapshot_archive_write "$TEST_STAGE" "$TEST_ARCHIVE" "$TEST_PASSWORD" 30')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.archive.read_bytes(), b"keep-existing-output")

    def test_v2_tampered_ciphertext_is_rejected_before_decrypt(self):
        data = bytearray(authenticated_archive(tar_bytes([("marker.txt", "file", "account-a")])))
        data[-1] ^= 1
        self.archive.write_bytes(data)
        result = self.decode()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("归档认证失败", result.stdout + result.stderr)
        self.assertFalse(self.plain.exists(), "认证失败不得写出明文")

    def test_v2_truncated_archive_is_rejected_before_decrypt(self):
        data = authenticated_archive(tar_bytes([("marker.txt", "file", "account-a")]))
        self.archive.write_bytes(data[:-1])
        result = self.decode()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("归档认证失败", result.stdout + result.stderr)
        self.assertFalse(self.plain.exists())

    def test_v2_wrong_password_is_rejected_before_decrypt(self):
        self.archive.write_bytes(authenticated_archive(
            tar_bytes([("marker.txt", "file", "account-a")])))
        result = self.decode("wrong-password")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("归档认证失败", result.stdout + result.stderr)
        self.assertFalse(self.plain.exists())

    def test_archive_symlink_member_is_rejected_before_extraction(self):
        self.archive.write_bytes(authenticated_archive(tar_bytes([
            ("link", "symlink", "../outside"),
        ])))
        result = self.shell(
            '_snapshot_archive_decode "$TEST_ARCHIVE" "$TEST_PASSWORD" "$TEST_PLAIN" 30 && '
            '_snapshot_tar_preflight "$TEST_PLAIN"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported archive member", result.stdout + result.stderr)

    def test_archive_parent_or_absolute_member_is_rejected(self):
        for name in ("../outside", "/absolute/outside"):
            with self.subTest(name=name):
                self.archive.write_bytes(authenticated_archive(tar_bytes([(name, "file", "bad")])))
                result = self.shell(
                    '_snapshot_archive_decode "$TEST_ARCHIVE" "$TEST_PASSWORD" "$TEST_PLAIN" 30 && '
                    '_snapshot_tar_preflight "$TEST_PLAIN"')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsafe archive path", result.stdout + result.stderr)

    def test_archive_hardlink_device_and_fifo_members_are_rejected(self):
        for kind in ("hardlink", "device", "fifo"):
            with self.subTest(kind=kind):
                if kind == "hardlink":
                    payload = tar_bytes([
                        ("marker.txt", "file", "account-a"),
                        ("link", "hardlink", "marker.txt"),
                    ])
                else:
                    payload = tar_bytes([("special", kind, "")])
                self.archive.write_bytes(authenticated_archive(payload))
                result = self.shell(
                    '_snapshot_archive_decode "$TEST_ARCHIVE" "$TEST_PASSWORD" "$TEST_PLAIN" 30 && '
                    '_snapshot_tar_preflight "$TEST_PLAIN"')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unsupported archive member", result.stdout + result.stderr)

    def test_archive_duplicate_and_conflicting_members_are_rejected(self):
        cases = (
            [("same", "file", "one"), ("same", "file", "two")],
            [("same", "file", "one"), ("same/child", "file", "two")],
        )
        for entries in cases:
            with self.subTest(entries=entries):
                self.archive.write_bytes(authenticated_archive(tar_bytes(entries)))
                result = self.shell(
                    '_snapshot_archive_decode "$TEST_ARCHIVE" "$TEST_PASSWORD" "$TEST_PLAIN" 30 && '
                    '_snapshot_tar_preflight "$TEST_PLAIN"')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("archive member", result.stdout + result.stderr)

    def test_tree_preflight_rejects_symlinks_and_oversized_marker(self):
        tree = self.root / "tree"
        tree.mkdir()
        marker = tree / ".claude-switcher-snapshot.json"
        marker.write_text("{}", encoding="utf-8")
        environment = dict(os.environ, CLAUDE_SWITCHER_PYTHON=sys.executable)
        command = ["/bin/bash", "-c", "set -u\n" + self.functions +
                   '\n_snapshot_tree_preflight "$1"', "_", str(tree)]
        result = subprocess.run(command, env=environment, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        (tree / "link").symlink_to("marker.txt")
        result = subprocess.run(command, env=environment, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symbolic link", result.stdout + result.stderr)
        (tree / "link").unlink()
        marker.write_bytes(b"x" * (64 * 1024))
        result = subprocess.run(command, env=environment, text=True,
                                capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid snapshot marker", result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "darwin", "snapshot transfer uses hdiutil (macOS)")
class SnapshotTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.accounts = self.home / ".claude-switcher" / "accounts"
        (self.accounts / "A" / "sub").mkdir(parents=True)
        (self.accounts / "A" / "sub" / "marker.txt").write_text("account-a", encoding="utf-8")
        (self.home / ".claude-switcher" / "current").write_text("B", encoding="utf-8")
        self.image = self.root / "account-a.dmg"

    def run_core(self, *args, password=None, home=None, extra_env=None):
        # hdiutil 在部分系统上会卡住;测试把单步超时压到 15 秒,让失败尽快暴露,
        # 而不是等满 90 秒的 subprocess 超时。
        env = dict(os.environ, HOME=str(home or self.home),
                   CLAUDE_SWITCHER_SNAPSHOT_TIMEOUT="15")
        if extra_env:
            env.update(extra_env)
        return subprocess.run(
            ["/bin/bash", str(SCRIPT), *args],
            input=(password + "\n") if password is not None else None,
            text=True, capture_output=True, env=env, timeout=90,
        )

    def export(self, target="A", image=None):
        return self.run_core("snapshot-export", target, str(image or self.image),
                             "--password-stdin", password=PASSWORD)

    def import_into(self, target, image=None, password=PASSWORD, home=None):
        return self.run_core("snapshot-import", str(image or self.image), target,
                             "--password-stdin", password=password, home=home)

    def test_roundtrip_restores_snapshot(self):
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.image.is_file())

        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.run_core(
            "snapshot-import", str(self.image), "A", "--password-stdin",
            password=PASSWORD, home=home2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restored = home2 / ".claude-switcher" / "accounts" / "A" / "sub" / "marker.txt"
        self.assertEqual(restored.read_text(encoding="utf-8"), "account-a")
        self.assertFalse((home2 / ".claude-switcher" / "accounts" / "A"
                          / ".claude-switcher-snapshot.json").exists())

    def test_boundary_slots_e_and_h_round_trip(self):
        for target in ("E", "H"):
            with self.subTest(target=target):
                slot = self.accounts / target
                slot.mkdir()
                (slot / "marker.txt").write_text(target, encoding="utf-8")
                image = self.root / f"account-{target}.dmg"
                exported = self.export(target, image)
                self.assertEqual(exported.returncode, 0, exported.stdout + exported.stderr)
                shutil.rmtree(slot)
                imported = self.import_into(target, image)
                self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
                self.assertEqual((slot / "marker.txt").read_text(encoding="utf-8"), target)
                self.assertFalse((slot / ".claude-switcher-snapshot.json").exists())

    def test_authenticated_archive_rejects_unsafe_member_before_import(self):
        self.image.write_bytes(authenticated_archive(tar_bytes([
            ("../outside", "file", "bad"),
        ])))
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.import_into("A", home=home2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不安全成员", result.stdout + result.stderr)
        self.assertFalse((home2 / ".claude-switcher" / "accounts" / "A").exists())
        self.assertFalse((home2 / ".claude-switcher" / "outside").exists())

    def test_authenticated_archive_imports_without_diskimages(self):
        self.image.write_bytes(authenticated_archive(snapshot_payload()))
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.import_into("A", home=home2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        restored = home2 / ".claude-switcher" / "accounts" / "A" / "sub" / "marker.txt"
        self.assertEqual(restored.read_text(encoding="utf-8"), "account-A")

    def test_legacy_archive_import_warns_about_missing_authentication(self):
        self.image.write_bytes(legacy_archive(snapshot_payload()))
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.import_into("A", home=home2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("没有完整性认证", result.stdout + result.stderr)
        restored = home2 / ".claude-switcher" / "accounts" / "A" / "sub" / "marker.txt"
        self.assertEqual(restored.read_text(encoding="utf-8"), "account-A")

    def test_wrong_password_leaves_no_snapshot(self):
        self.assertEqual(self.export().returncode, 0)
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.run_core("snapshot-import", str(self.image), "A",
                               "--password-stdin", password="wrong-password", home=home2)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((home2 / ".claude-switcher" / "accounts" / "A").exists())

    def test_metadata_validation_cannot_be_disabled_by_python_optimize(self):
        self.image.write_bytes(authenticated_archive(tar_bytes([
            (".claude-switcher-snapshot.json", "file",
             '{"format":"not-a-snapshot","version":1,"account":"A"}'),
            ("marker.txt", "file", "bad"),
        ])))
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.run_core(
            "snapshot-import", str(self.image), "A", "--password-stdin",
            password=PASSWORD, home=home2, extra_env={"PYTHONOPTIMIZE": "1"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((home2 / ".claude-switcher" / "accounts" / "A").exists())

    def test_account_mismatch_is_rejected(self):
        self.assertEqual(self.export().returncode, 0)
        home2 = self.root / "home2"
        (home2 / ".claude-switcher" / "accounts").mkdir(parents=True)
        result = self.run_core("snapshot-import", str(self.image), "B",
                               "--password-stdin", password=PASSWORD, home=home2)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((home2 / ".claude-switcher" / "accounts" / "B").exists())

    def test_existing_target_is_not_overwritten(self):
        self.assertEqual(self.export().returncode, 0)
        (self.accounts / "B").mkdir()
        result = self.import_into("B")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.accounts / "B" / "sub").exists())

    def test_short_password_is_rejected(self):
        result = self.run_core("snapshot-export", "A", str(self.image),
                               "--password-stdin", password="short")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.image.exists())

    def test_current_account_cannot_be_exported(self):
        (self.home / ".claude-switcher" / "current").write_text("A", encoding="utf-8")
        result = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.image.exists())


if __name__ == "__main__":
    unittest.main()
