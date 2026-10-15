import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

SUPERVISOR = Path(__file__).parents[1] / "scripts/supervisor.py"


class GracefulSupervisor(unittest.TestCase):
    def test_term_requests_a_graceful_child_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "child.py"
            request = root / "request"
            child.write_text("import pathlib,time,sys\np=pathlib.Path(sys.argv[1])\nprint('child_ready',flush=True)\nwhile not p.exists(): time.sleep(.01)\nprint('child_committed',flush=True)\n")
            command = self.launch(child, request, 2)
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(process.stdout.readline().strip(), "child_ready")
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors)
            self.assertIn("child_committed", output)
            self.assertIn("supervisor_shutdown_requested", output)
            self.assertNotIn("supervisor_shutdown_timeout", output)
            self.assertFalse(request.exists())

    def test_unresponsive_child_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            child = root / "child.py"
            request = root / "request"
            child.write_text("import time\nprint('child_ready',flush=True)\ntime.sleep(30)\n")
            process = subprocess.Popen(self.launch(child, request, 0.2), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(process.stdout.readline().strip(), "child_ready")
            started = time.monotonic()
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1, errors)
            self.assertLess(time.monotonic() - started, 3)
            self.assertIn("supervisor_shutdown_timeout", output)
            self.assertFalse(request.exists())

    @staticmethod
    def launch(child, request, timeout):
        script = "import importlib.util,pathlib,sys; s=importlib.util.spec_from_file_location('supervisor',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);sys.exit(m.supervise([sys.executable,sys.argv[2],sys.argv[3]],pathlib.Path(sys.argv[3]),float(sys.argv[4])))"
        return [sys.executable, "-c", script, str(SUPERVISOR), str(child), str(request), str(timeout)]
