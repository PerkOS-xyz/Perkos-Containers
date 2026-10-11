import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release_scope", ROOT / "scripts/select-build-scope.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseScopeTests(unittest.TestCase):
    def test_bridge_release_including_pipeline_does_not_provision_runtimes(self):
        files = list(release.BRIDGE_FILES) + [
            "images/perkos-a2a-bridge/Dockerfile",
            "tests/perkos-a2a-bridge/test_release_scope.py",
            "tests/perkos-a2a-bridge/verify-package.mjs",
        ]
        self.assertEqual(release.scope_for_paths(files), "bridge")

    def test_runtime_or_unclassified_changes_require_full_release(self):
        for path in ("images/hermes/Dockerfile", "tests/behavior/run.sh", "scripts/new.py"):
            self.assertEqual(release.scope_for_paths([path]), "all")
            self.assertEqual(release.scope_for_paths(["images/perkos-a2a-bridge/Dockerfile", path]), "all")

    def test_manual_scope_is_explicit(self):
        self.assertEqual(release.select_scope("workflow_dispatch", "all", "", ""), "all")
        self.assertEqual(release.select_scope("workflow_dispatch", "bridge", "", ""), "bridge")
        with self.assertRaises(ValueError):
            release.select_scope("workflow_dispatch", "", "", "")

    def test_invalid_inputs_and_empty_diff_fail_closed(self):
        for before in ("", "0" * 40, "not-a-sha"):
            with self.assertRaises(ValueError):
                release.select_scope("push", "", before, "a" * 40)
        with self.assertRaises(ValueError):
            release.select_scope("pull_request", "", "a" * 40, "b" * 40)
        with self.assertRaises(ValueError):
            release.scope_for_paths([])

    @patch.object(release.subprocess, "run")
    def test_missing_history_never_falls_back_to_full_release(self, run):
        run.side_effect = subprocess.CalledProcessError(128, "git")
        with self.assertRaises(subprocess.CalledProcessError):
            release.select_scope("push", "", "a" * 40, "b" * 40)

    @patch.object(release.subprocess, "run")
    def test_git_diff_preserves_null_delimited_paths(self, run):
        run.return_value = subprocess.CompletedProcess("git", 0, b"images/perkos-a2a-bridge/Dockerfile\0")
        self.assertEqual(release.select_scope("push", "", "a" * 40, "b" * 40), "bridge")
        self.assertEqual(run.call_args.args[0][-1], "--")
        self.assertIn("--no-renames", run.call_args.args[0])
        self.assertTrue(run.call_args.kwargs["check"])


if __name__ == "__main__":
    unittest.main()
