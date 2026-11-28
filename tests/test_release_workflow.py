"""发布门禁与运行时工件完整性契约。"""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ReleaseWorkflowTests(unittest.TestCase):
    def test_release_reuses_full_checks_workflow(self):
        release = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("uses: ./.github/workflows/checks.yml", release)
        self.assertIn("needs: test", release)

    def test_checks_workflow_is_reusable(self):
        checks = (ROOT / ".github/workflows/checks.yml").read_text(encoding="utf-8")
        self.assertIn("workflow_call:", checks)

    def test_sums_cover_runtime_payload(self):
        paths = {
            line.split("  ", 1)[1]
            for line in (ROOT / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
            if "  " in line
        }
        for required in (
            "core/stun-probe.py",
            "scripts/upgrade-core.sh",
            "scripts/diagnose-fix.sh",
            "scripts/diagnose-install.sh",
        ):
            with self.subTest(path=required):
                self.assertIn(required, paths)


if __name__ == "__main__":
    unittest.main()
