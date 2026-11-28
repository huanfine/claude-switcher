"""Regression tests for macOS snapshot archive and account-switch failure boundaries.

No Claude installation, login, launchd, credentials or network is accessed.
Only named functions extracted from the project source run with isolated _trash
fixtures. Tests intentionally simulate filesystem failures.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT / "core" / "claude-switch.sh"
TRASH = PROJECT / "_trash"


def function_source(name):
    text = SOURCE.read_text(encoding="utf-8")
    pattern = rf"(?ms)^{re.escape(name)}\(\) \{{\n.*?^\}}"
    match = re.search(pattern, text)
    if match is None:
        raise AssertionError(f"Missing shell function: {name}")
    return match.group(0)


class SnapshotSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        TRASH.mkdir(exist_ok=True)
        cls.archive = function_source("archive_current")
        cls.switch = function_source("switch_to")
        cls.valid = function_source("valid_account")
        dependency_names = (
            "archive_cli", "restore_cli", "cli_slot_has_payload", "copy_tree",
            "stage_keep_paths", "keep_path_safe", "restore_keep_paths", "switch_txn_support", "txn_verify", "txn_get",
            "txn_mark", "txn_flag", "cleanup_switch_txn", "recover_switch_state",
            "recover_switch_txn", "backup_switch_live", "prepare_switch_target",
            "install_switch_target", "write_current_atomic",
        )
        cls.transaction = "\n".join(
            function_source(name) for name in dependency_names
            if re.search(rf"(?ms)^{re.escape(name)}\(\) \{{", SOURCE.read_text(encoding="utf-8"))
        )

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(
            prefix="snapshot-safety-", dir=str(TRASH)
        )
        self.addCleanup(self.tmp.cleanup)
        self.fixture = Path(self.tmp.name)
        self.base = self.fixture / "state"
        self.data = self.fixture / "live"
        self.cli_dir = self.fixture / ".claude"
        self.cli_json = self.fixture / ".claude.json"
        self.cli_base = self.base / "cli"
        (self.base / "accounts" / "A").mkdir(parents=True)
        (self.base / "accounts" / "B").mkdir()
        self.data.mkdir()
        (self.base / "accounts" / "A" / "marker").write_text("old-A")
        (self.base / "accounts" / "B" / "marker").write_text("saved-B")
        (self.data / "marker").write_text("live-A")

    def run_shell(self, code, *, injection="none"):
        env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.fixture),
            "BASE": str(self.base),
            "DATA": str(self.data),
            "CLI_DIR": str(self.cli_dir),
            "CLI_JSON": str(self.cli_json),
            "CLI_BASE": str(self.cli_base),
            "CLAUDE_SWITCHER_SOURCE": str(SOURCE),
            "CLAUDE_SWITCHER_PYTHON": sys.executable,
            "CLI_RUNNING": "0",
            "FIXTURE": str(self.fixture),
            "INJECT": injection,
            "LC_ALL": "C",
        }
        harness = r'''
set -u
log() { printf '%s\n' "$*" >> "$FIXTURE/calls"; }
copy_tree() {
    if [ "$INJECT" = "copy_error" ]; then return 43; fi
    mkdir -p "$2" && cp -R "$1/." "$2/"
}
quit_claude() { printf 'quit\n' >> "$FIXTURE/calls"; return 0; }
open() {
    if [ "$INJECT" = "open_failure" ]; then return 42; fi
    printf 'called' > "$FIXTURE/launched"
}
claude_cli_running() { [ "${CLI_RUNNING:-0}" = "1" ]; }
require_lease_for_launch() {
    printf 'lease\n' >> "$FIXTURE/calls"
    [ "$INJECT" != "invalid_lease" ] && {
        [ "$INJECT" != "late_invalid_lease" ] || [ "$(grep -c '^lease$' "$FIXTURE/calls")" -eq 1 ]
    }
}
lease_revoke() { :; }
mv() {
    local args=("$@") last src dst
    last=$((${#args[@]} - 1))
    src=${args[$((last - 1))]}; dst=${args[$last]}
    if [ "$INJECT" = "cli_json_move_error" ] &&
       [ "$src" = "$CLI_BASE/B.new/home.json" ] && [ "$dst" = "$CLI_JSON" ]; then
        return 31
    fi
    if [ "$INJECT" = "backup_rollback_error" ] &&
       { [ "$src" = "$CLI_JSON" ] || { [ "$dst" = "$DATA" ] && [[ "$src" == */old-data ]]; }; }; then
        return 33
    fi
    if [ "$INJECT" = "current_write_error" ] && [ "$dst" = "$BASE/current" ] &&
       [ "$(cat "$src" 2>/dev/null)" = "B" ]; then
        return 32
    fi
    if [ "$INJECT" = "first_move_error" ] && [ "$src" = "$DATA" ]; then
        return 23
    fi
    if [ "$INJECT" = "copy_error" ] && [ "$src" = "$DATA" ]; then
        return 23
    fi
    if [ "$INJECT" = "final_rename_error" ] &&
       [ "$src" = "$BASE/accounts/A.new" ] &&
       [ "$dst" = "$BASE/accounts/A" ]; then
        return 23
    fi
    if [ "$INJECT" = "old_rename_error" ] &&
       [ "$src" = "$BASE/accounts/A" ] &&
       [ "$dst" = "$BASE/accounts/A.previous" ]; then
        return 23
    fi
    command mv "$@"
}
'''
        return subprocess.run(
            ["/bin/bash", "-c", "\n".join([
                self.valid, self.archive, self.transaction, harness, code,
            ])],
            env=env,
            cwd=self.fixture,
            text=True,
            capture_output=True,
            check=False,
            timeout=8,
        )

    def assert_data(self, expected_live="live-A", expected_old="old-A"):
        if expected_live is not None:
            self.assertEqual((self.data / "marker").read_text(), expected_live)
        if expected_old is not None:
            self.assertEqual(
                (self.base / "accounts" / "A" / "marker").read_text(),
                expected_old,
            )

    def seed_cli(self, tag):
        self.cli_dir.mkdir(exist_ok=True)
        (self.cli_dir / "session").write_text(tag, encoding="utf-8")
        self.cli_json.write_text(json.dumps({"account": tag}), encoding="utf-8")

    def seed_cli_slot(self, slot, tag):
        home = self.cli_base / slot / "home"
        home.mkdir(parents=True)
        (home / "session").write_text(tag, encoding="utf-8")
        (self.cli_base / slot / "home.json").write_text(
            json.dumps({"account": tag}), encoding="utf-8")

    def assert_cli(self, tag):
        if tag is None:
            self.assertFalse(self.cli_dir.exists())
            self.assertFalse(self.cli_json.exists())
            return
        self.assertEqual((self.cli_dir / "session").read_text(), tag)
        self.assertEqual(json.loads(self.cli_json.read_text())["account"], tag)

    def calls(self):
        path = self.fixture / "calls"
        return path.read_text(encoding="utf-8") if path.exists() else ""

    def test_final_rename_failure_rolls_back_and_fails(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="final_rename_error",
        )
        self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assert_data()
        self.assertFalse((self.base / "accounts" / "A.previous").exists())
        self.assertFalse((self.base / "accounts" / "A.new").exists())

    def test_existing_staging_is_not_deleted(self):
        staged = self.base / "accounts" / "A.new"
        staged.mkdir()
        (staged / "marker").write_text("pending-only-copy")
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((staged / "marker").read_text(), "pending-only-copy")

    def test_existing_recovery_archive_is_not_deleted(self):
        previous = self.base / "accounts" / "A.previous"
        previous.mkdir()
        (previous / "marker").write_text("recovery-only-copy")
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((previous / "marker").read_text(), "recovery-only-copy")

    def test_failure_to_preserve_old_snapshot_stops_and_restores_live(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="old_rename_error",
        )
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()

    def test_copy_fallback_failure_is_not_reported_as_success(self):
        run = self.run_shell(
            self.archive + "\narchive_current A",
            injection="copy_error",
        )
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()

    def test_successfully_archives_new_snapshot_and_retires_previous(self):
        run = self.run_shell(self.archive + "\narchive_current A")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual(
            (self.base / "accounts" / "A" / "marker").read_text(), "live-A"
        )
        self.assertFalse(self.data.exists())
        self.assertFalse((self.base / "accounts" / "A.new").exists())
        self.assertFalse((self.base / "accounts" / "A.previous").exists())

    def test_switch_does_not_advance_if_archive_fails(self):
        (self.base / "current").write_text("A")
        code = (
            "archive_current() { return 23; }\n"
            + self.switch
            + "\nswitch_to B"
        )
        run = self.run_shell(code)
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())

    def test_first_enrollment_does_not_advance_if_archive_fails(self):
        code = (
            "archive_current() { return 23; }\n"
            + self.switch
            + "\nswitch_to B"
        )
        run = self.run_shell(code)
        self.assertNotEqual(run.returncode, 0)
        self.assert_data()
        self.assertFalse((self.base / "current").exists())
        self.assertFalse((self.fixture / "launched").exists())


    def test_invalid_lease_prevents_archive_and_all_live_changes(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        code = r'''
quit_claude() { printf 'quit\n' >> "$FIXTURE/calls"; }
archive_current() { printf 'archive_current\n' >> "$FIXTURE/calls"; }
archive_cli() { printf 'archive_cli\n' >> "$FIXTURE/calls"; }
''' + self.switch + "\nswitch_to B"
        run = self.run_shell(code, injection="invalid_lease")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(self.calls(), "lease\n")
        self.assert_data()
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())
        self.assertFalse((self.base / "switch-txn.json").exists())

    def test_first_capture_cli_failure_restores_desktop_live_state(self):
        self.seed_cli("A")
        code = (
            'archive_cli() { printf "archive_cli\\n" >> "$FIXTURE/calls"; return 43; }\n'
            + self.switch + "\nswitch_to B"
        )
        run = self.run_shell(code)
        self.assertNotEqual(run.returncode, 0)
        self.assert_data(expected_old="live-A")
        self.assert_cli("A")
        self.assertFalse((self.base / "current").exists())
        self.assertFalse((self.fixture / "launched").exists())

    def test_cli_json_move_failure_restores_desktop_cli_and_current(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        run = self.run_shell(self.switch + "\nswitch_to B",
                             injection="cli_json_move_error")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data(expected_old="live-A")
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())

    def test_current_write_failure_restores_all_live_state(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        run = self.run_shell(self.switch + "\nswitch_to B",
                             injection="current_write_error")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data(expected_old="live-A")
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())

    def test_open_failure_restores_all_live_state(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        run = self.run_shell(self.switch + "\nswitch_to B",
                             injection="open_failure")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data(expected_old="live-A")
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.fixture / "launched").exists())

    def test_existing_switch_journal_is_never_deleted_blindly(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        journal = self.base / "switch-txn.json"
        journal.write_text("{broken journal", encoding="utf-8")
        before = journal.read_bytes()
        run = self.run_shell(self.switch + "\nswitch_to B")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual(journal.read_bytes(), before)
        self.assert_data()
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertNotIn("quit\n", self.calls())
        self.assertFalse((self.fixture / "launched").exists())

    def test_late_lease_expiry_rolls_back_before_launch(self):
        (self.base / "current").write_text("A")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        run = self.run_shell(self.switch + "\nswitch_to B", injection="late_invalid_lease")
        self.assertNotEqual(run.returncode, 0)
        self.assert_data(expected_old="live-A")
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertEqual([line for line in self.calls().splitlines() if line == "lease"],
                         ["lease", "lease"])
        self.assertEqual(self.calls().splitlines()[:2], ["lease", "quit"])
        self.assertFalse((self.fixture / "launched").exists())
        self.assertFalse((self.base / "switch-txn.json").exists())

    def test_interrupted_backup_is_never_auto_deleted(self):
        (self.base / "current").write_text("A")
        self.seed_cli("A")
        code = r'''
info=$(switch_txn_support init B A) || exit 1
directory=${info#*$'\t'}; directory=${directory%%$'\t'*}
txn_mark state backing_up
command mv "$DATA" "$directory/old-data"
command mv "$CLI_DIR" "$directory/old-cli"
command mv "$CLI_JSON" "$directory/old-cli.json"
''' + self.switch + "\nswitch_to B"
        run = self.run_shell(code, injection="invalid_lease")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("拒绝自动恢复", run.stdout)
        self.assertTrue((self.base / "switch-txn.json").exists())
        self.assertFalse(self.data.exists())
        self.assert_cli(None)
        self.assertTrue(list(self.base.glob("switch-txn.*/old-data/marker")))
        self.assertTrue(list(self.base.glob("switch-txn.*/old-cli/session")))
        self.assertTrue(list(self.base.glob("switch-txn.*/old-cli.json")))

    def test_failed_backup_rollback_preserves_the_only_copy(self):
        self.seed_cli("live-A")
        (self.base / "current").write_text("A", encoding="utf-8")
        failed = self.run_shell(self.switch + "\nswitch_to B", injection="backup_rollback_error")
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        journal_path = self.base / "switch-txn.json"
        journal = json.loads(journal_path.read_text(encoding="utf-8"))
        self.assertEqual(journal["state"], "backing_up")
        self.assertFalse(journal["backup_ready"])
        backup = Path(journal["txn_dir"])
        self.assertEqual((backup / "old-data" / "marker").read_text(), "live-A")
        self.assertEqual((self.cli_dir / "session").read_text(), "live-A")
        self.assertFalse((backup / "old-cli").exists())
        self.assertFalse(self.data.exists())

        retry = self.run_shell(self.switch + "\nswitch_to B")
        self.assertNotEqual(retry.returncode, 0, retry.stdout + retry.stderr)
        self.assertIn("拒绝自动恢复", retry.stdout)
        self.assertTrue(journal_path.exists())
        self.assertEqual((backup / "old-data" / "marker").read_text(), "live-A")

    def test_next_switch_recovers_committed_live_state_before_lease(self):
        (self.base / "current").write_text("A")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        code = r'''
switch_txn_support init B A >/dev/null
backup_switch_live
prepare_switch_target B
install_switch_target B
write_current_atomic B
txn_mark current_committed 1
txn_mark state current_committed
''' + self.switch + "\nswitch_to C"
        run = self.run_shell(code, injection="invalid_lease")
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("已恢复切换前", run.stdout)
        self.assert_data()
        self.assert_cli("A")
        self.assertEqual((self.base / "current").read_text(), "A")
        self.assertFalse((self.base / "switch-txn.json").exists())
        self.assertFalse((self.fixture / "launched").exists())

    def test_keep_paths_merge_into_staged_target(self):
        (self.base / "current").write_text("A")
        (self.base / "keep-in-workspace.txt").write_text("settings.json\n")
        (self.data / "settings.json").write_text("shared")
        (self.base / "accounts" / "B" / "settings.json").write_text("saved-B")
        run = self.run_shell(self.switch + "\nswitch_to B")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.data / "settings.json").read_text(), "shared")
        self.assertFalse((self.base / "keep-stage").exists())

    def test_unknown_target_stage_is_preserved_on_failure(self):
        (self.base / "current").write_text("A")
        staged = self.fixture / "live.new"
        staged.mkdir()
        (staged / "marker").write_text("unknown-stage")
        run = self.run_shell(self.switch + "\nswitch_to B")
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual((staged / "marker").read_text(), "unknown-stage")
        self.assert_data(expected_old="live-A")
        self.assertEqual((self.base / "current").read_text(), "A")

    def test_successful_switch_commits_all_three_states(self):
        (self.base / "current").write_text("A", encoding="utf-8")
        self.seed_cli("A")
        self.seed_cli_slot("B", "B")
        run = self.run_shell(self.switch + "\nswitch_to B")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertEqual((self.data / "marker").read_text(), "saved-B")
        self.assert_cli("B")
        self.assertEqual((self.base / "current").read_text(), "B")
        self.assertTrue((self.fixture / "launched").exists())
        self.assertFalse((self.base / "switch-txn.json").exists())
        self.assertFalse(list(self.base.glob("switch-txn.*")))


if __name__ == "__main__":
    unittest.main()
