"""Exercise host detection in the real helper, without publishing widget events."""

import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest


HELPER = Path(os.environ.get(
    "AGENT_MONITOR_TEST_HELPER",
    Path(__file__).parents[1] / ".build/debug/agent-monitor-helper",
)).resolve()


class HelperProcessTests(unittest.TestCase):
    def test_host_detection_finishes_with_a_long_ancestor_command(self):
        self.assertTrue(HELPER.is_file(), "Build the helper with swift build first")
        # Keep an ancestor alive whose command exceeds the macOS pipe capacity.
        # Waiting for ps before draining stdout deadlocks on this command.
        launcher = """
import subprocess, sys
result = subprocess.run([sys.argv[1], 'doctor'])
sys.exit(result.returncode)
"""
        process = subprocess.Popen(
            [sys.executable, "-c", launcher, str(HELPER), "x" * 100_000],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        try:
            try:
                stdout, stderr = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                raise AssertionError("Host detection exceeded Codex's three-second hook timeout") from None
            self.assertEqual(process.returncode, 0, stderr.decode())
            self.assertIn(b"Terminal:", stdout)
            self.assertEqual(stderr, b"")
        finally:
            # Also reap the helper and ps if the regression leaves them blocked.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()


if __name__ == "__main__":
    unittest.main()
