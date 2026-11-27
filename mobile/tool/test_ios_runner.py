import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import run_ios_test


class IOSCommandRunner(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name)

    def command(self, script, *arguments):
        return [sys.executable, '-u', '-c', script, *map(str, arguments)]

    def wait_for(self, path, timeout=10):
        deadline = time.monotonic() + timeout
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(path.exists(), f'Timed out waiting for {path.name}')

    def test_inherited_stdout_does_not_keep_successful_step_open(self):
        ready = self.output / 'ready'
        release = self.output / 'release'
        finished = self.output / 'finished'
        child = '''
from pathlib import Path
import sys
import time
ready, release, finished = map(Path, sys.argv[1:])
print('descendant started', flush=True)
ready.touch()
deadline = time.monotonic() + 30
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
print('descendant still alive after parent exit', flush=True)
sys.stdout.close()
sys.stderr.close()
finished.touch()
'''
        parent = '''
from pathlib import Path
import subprocess
import sys
import time
child, ready, release, finished = sys.argv[1:]
subprocess.Popen([sys.executable, '-u', '-c', child, ready, release, finished],
                 stdout=sys.stdout, stderr=sys.stderr,
                 creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
deadline = time.monotonic() + 10
while not Path(ready).exists() and time.monotonic() < deadline:
    time.sleep(0.02)
if not Path(ready).exists():
    raise SystemExit(9)
print('direct command finished', flush=True)
'''
        try:
            started = time.monotonic()
            with contextlib.redirect_stdout(io.StringIO()):
                code = run_ios_test.run(
                    self.command(parent, child, ready, release, finished),
                    'inherited', self.output, 15)
            self.assertEqual(code, 0)
            self.assertLess(time.monotonic() - started, 8)
            self.assertFalse(finished.exists(), 'Descendant must outlive the direct command')
        finally:
            release.touch()
            self.wait_for(finished)
        self.assertIn('descendant still alive after parent exit',
                      (self.output / 'inherited.log').read_text(encoding='utf-8'))

    def test_stdout_stderr_and_non_utf8_bytes_are_preserved(self):
        script = "import os; os.write(1, b'out\\n'); os.write(2, b'err\\n'); os.write(1, b'partial\\xff')"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(run_ios_test.run(self.command(script), 'bytes', self.output, 10), 0)
        self.assertEqual((self.output / 'bytes.log').read_bytes(), b'out\nerr\npartial\xff')

    def test_nonzero_exit_is_not_hidden_by_success_looking_output(self):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(run_ios_test.StepFailed) as error:
            run_ios_test.checked(self.command("print('Finished'); raise SystemExit(7)"),
                                 'failure', self.output, 10)
        self.assertEqual(error.exception.code, 7)
        self.assertIn('Finished', (self.output / 'failure.log').read_text(encoding='utf-8'))

    def test_real_timeout_stops_direct_process_and_returns_124(self):
        spawned = []
        real_popen = subprocess.Popen

        def capture_process(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            spawned.append(process)
            return process

        with mock.patch.object(run_ios_test.subprocess, 'Popen', side_effect=capture_process), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(run_ios_test.run(self.command('import time; time.sleep(30)'),
                                             'timeout', self.output, 0.2), 124)
        self.assertEqual(len(spawned), 1)
        self.assertIsNotNone(spawned[0].poll())

    def test_timeout_escalates_to_kill_for_unresponsive_process_group(self):
        process = mock.Mock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired('command', 1),
                                    subprocess.TimeoutExpired('command', 5), 0]
        with mock.patch.object(run_ios_test.subprocess, 'Popen', return_value=process), \
                mock.patch.object(run_ios_test.os, 'name', 'posix'), \
                mock.patch.object(run_ios_test.os, 'killpg', create=True) as kill_group, \
                mock.patch.object(run_ios_test.signal, 'SIGKILL', 9, create=True), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(run_ios_test.run(['command'], 'escalation', self.output, 1), 124)
        self.assertEqual(kill_group.call_args_list,
                         [mock.call(12345, run_ios_test.signal.SIGTERM), mock.call(12345, 9)])

    def test_slow_live_console_cannot_turn_success_into_failure(self):
        entered = threading.Event()
        release = threading.Event()
        drained = threading.Event()

        class SlowConsole(io.StringIO):
            def write(self, value):
                if 'child payload' in value:
                    entered.set()
                    release.wait(10)
                return super().write(value)

        original_tail = run_ios_test._tail_log

        def observed_tail(*args):
            try:
                original_tail(*args)
            finally:
                drained.set()

        try:
            with contextlib.redirect_stdout(SlowConsole()), \
                    mock.patch.object(run_ios_test, '_tail_log', side_effect=observed_tail):
                code = run_ios_test.run(self.command("print('child payload')"),
                                       'slow-console', self.output, 10)
            self.assertTrue(entered.is_set())
            self.assertEqual(code, 0)
            self.assertFalse(drained.is_set(), 'Console must still be blocked when the step returns')
        finally:
            release.set()
            self.assertTrue(drained.wait(10))
        self.assertEqual((self.output / 'slow-console.log').read_text(encoding='utf-8'),
                         'child payload\n')

    def test_spawn_failure_is_not_reported_as_success(self):
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(OSError):
            run_ios_test.run([str(self.output / 'nonexistent-command')], 'spawn', self.output, 1)


if __name__ == '__main__':
    unittest.main()
