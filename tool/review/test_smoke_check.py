"""Routing/exit-status regression tests. Uses disposable Git fixtures; no Flutter/network."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("smoke_check.sh").resolve()


class SmokeCheckTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = self.root / ".git" / "calls"
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        files = {
            "pubspec.yaml": "name: fixture\n",
            "README.md": "fixture\n",
            "lib/config/values.dart": "const boatPredictionTimeoutSeconds = 20;\nconst boatStaleTimeoutSeconds = 60;\nconst sendIntervalStoppedSec = 30;\n",
            "lib/services/other_boat_track_store.dart": "freshUntil = Duration(seconds: 10);\n",
            "lib/hooks/hook.dart": "// fixture\n",
            "lib/screens/view.dart": "// view\n",
            "lib/audio.dart": "'audio/test.mp3'\n",
            "assets/audio/test.mp3": "fixture",
            "tool/update_hazard_profile_hash.sh": "exit 0\n",
            "test/view_test.dart": "// test\n",
            "test/config/diagnostic_event_catalog_test.dart": "// catalog\n",
        }
        for name, text in files.items():
            self.write(name, text)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.bin = self.root / ".git" / "bin"
        self.bin.mkdir()
        for tool in ("dart", "flutter", "gh"):
            body = '#!/bin/bash\nprintf "%s\\n" "' + tool + ' $*" >> "$CALL_LOG"\n'
            if tool == "gh":
                body += 'printf "%s\\n" "${CI_RESULT:-}"\n'
            elif tool == "flutter":
                body += 'exit "${TEST_EXIT:-0}"\n'
            else:
                body += 'exit "${DART_EXIT:-0}"\n'
            path = self.bin / tool
            path.write_text(body)
            path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_check(self, *args, **overrides):
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"], CALL_LOG=str(self.calls))
        env.update(overrides)
        result = subprocess.run(["bash", str(SCRIPT), *args], cwd=self.root, env=env, capture_output=True, text=True)
        calls = self.calls.read_text().splitlines() if self.calls.exists() else []
        return result, calls

    def test_docs_only_no_runtime_or_network(self):
        self.write("README.md", "updated\n")
        result, calls = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls, [])

    def test_committed_safety_change_is_seen_with_base(self):
        self.write("lib/services/other_boat_track_store.dart", "freshUntil = Duration(seconds: 11);\n")
        self.git("add", "lib")
        self.git("commit", "-qm", "safety change")
        result, calls = self.run_check("--base", "HEAD~1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("flutter test", calls)

    def test_targeted_ui_change(self):
        self.write("lib/screens/view.dart", "// changed\n")
        result, calls = self.run_check("--targeted", "test/view_test.dart")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("dart analyze lib test tool", calls)
        self.assertIn("flutter test test/view_test.dart", calls)
        self.assertNotIn("flutter test", calls)

    def test_safety_change_cannot_be_narrowed_by_targeted(self):
        self.write("lib/hooks/hook.dart", "// changed\n")
        result, calls = self.run_check("--targeted", "test/view_test.dart")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c for c in calls if c.startswith("flutter ")], ["flutter test"])

    def test_unknown_new_file_is_not_docs_only(self):
        self.write("new_config.json", "{}")
        result, calls = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("flutter test", calls)

    def test_failed_test_returns_failure_and_does_not_repeat_catalog(self):
        result, calls = self.run_check("--full", TEST_EXIT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("テスト失敗あり", result.stdout)
        self.assertEqual([c for c in calls if c.startswith("flutter ")], ["flutter test"])

    def test_static_failure_returns_failure(self):
        self.write("lib/config/values.dart", "const boatPredictionTimeoutSeconds = 90;\nconst boatStaleTimeoutSeconds = 60;\nconst sendIntervalStoppedSec = 30;\n")
        result, calls = self.run_check("--static")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(c.startswith("gh ") for c in calls))

    def test_targeted_catalog_runs_once(self):
        result, calls = self.run_check("--targeted", "test/config/diagnostic_event_catalog_test.dart")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual([c for c in calls if c.startswith("flutter ")], ["flutter test test/config/diagnostic_event_catalog_test.dart"])

    def test_clean_ci_states(self):
        for state, full in [("completed/success", False), ("", False), ("in_progress/", False), ("completed/failure", True)]:
            with self.subTest(state=state):
                self.calls.unlink(missing_ok=True)
                result, calls = self.run_check(CI_RESULT=state)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual("flutter test" in calls, full)

    def test_invalid_arguments_fail_before_work(self):
        for args in [("--base", "missing-ref"), ("--targeted",), ("--targeted", "test/missing_test.dart")]:
            with self.subTest(args=args):
                result, calls = self.run_check(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
