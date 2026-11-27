"""Build once, then run all iOS checks through XCTest (no VM-service discovery)."""
import codecs
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import threading
from uuid import UUID

from check_xctest_result import validate


class StepFailed(RuntimeError):
    def __init__(self, name, code):
        super().__init__(f'{name} failed with exit code {code}')
        self.code = code


def _tail_log(path, stop, console):
    """Best-effort live view; the subprocess writes the complete log directly."""
    decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
    try:
        with path.open('rb') as source:
            while not stop.wait(0.1):
                chunk = source.read(65536)
                if chunk:
                    console.write(decoder.decode(chunk))
                    console.flush()
            # A descendant may keep writing after the direct command exits.
            # Drain only a bounded final chunk, never wait for its EOF.
            console.write(decoder.decode(source.read(65536), final=True))
            console.flush()
    except (OSError, ValueError):
        # Console forwarding cannot invalidate the command's actual result.
        # Its original stdout/stderr bytes remain in the artifact log.
        return


def _terminate_group(process, force=False):
    if os.name == 'posix':
        os.killpg(process.pid, signal.SIGKILL if force else signal.SIGTERM)
    elif force:
        process.kill()
    else:
        process.terminate()


def run(command, name, output, timeout):
    """Use the direct exit code; terminate its process group only on timeout."""
    print(f'CI STEP {name}: starting (limit {timeout}s)', flush=True)
    path = output / f'{name}.log'
    with path.open('wb', buffering=0) as log:
        # CoreSimulator descendants inherit bootstatus's stdout. A pipe would
        # stay open after a successful boot and falsely fail while awaiting EOF.
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT,
                                   start_new_session=True,
                                   creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        stop = threading.Event()
        reader = threading.Thread(target=_tail_log, args=(path, stop, sys.stdout), daemon=True)
        reader.start()
        try:
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                print(f'CI STEP {name}: timeout; stopping its process group.', flush=True)
                try:
                    _terminate_group(process)
                    process.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    _terminate_group(process, force=True)
                    process.wait(timeout=5)
                code = 124
        finally:
            stop.set()
            # A slow CI console is not a failed command. The daemon owns only
            # its read handle; returning cannot close a file it is writing to.
            reader.join(timeout=1)
    print(f'CI STEP {name}: exit {code}', flush=True)
    return code


def checked(command, name, output, timeout):
    code = run(command, name, output, timeout)
    if code:
        raise StepFailed(name, code)


def boot(device, output):
    for attempt in range(2):
        name = f'boot-{attempt + 1}'
        code = run(['xcrun', 'simctl', 'bootstatus', device, '-b'], name, output, 300)
        if code == 0 and 'Data Migration Failed' not in (output / f'{name}.log').read_text(encoding='utf-8'):
            return
        if attempt == 0:
            checked(['xcrun', 'simctl', 'shutdown', device], 'boot-recovery-shutdown', output, 30)
    raise StepFailed('simulator-boot-before-tests', 124)


def main():
    if sys.platform != 'darwin':
        raise SystemExit('XCTest requires the macOS CI runner.')
    output = Path('build/ios_ci').resolve()
    output.mkdir(parents=True, exist_ok=False)
    device = None
    try:
        checked(['flutter', 'build', 'ios', '--config-only', '--debug', '--simulator',
                 '--no-codesign', '--no-pub', '--target', 'integration_test/ios_ci.dart',
                 '--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=true'],
                'configure', output, 600)
        derived = output / 'DerivedData'
        # Compile before booting CoreSimulator so the first device migration
        # does not compete with the Dart compiler and Xcode for resources.
        checked(['xcodebuild', 'build-for-testing', '-workspace', 'ios/Runner.xcworkspace',
                 '-scheme', 'Runner', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                 '-destination', 'generic/platform=iOS Simulator',
                 '-derivedDataPath', str(derived), f'ARCHS={platform.machine()}', 'ONLY_ACTIVE_ARCH=YES',
                 'CODE_SIGNING_ALLOWED=NO', 'COMPILER_INDEX_STORE_ENABLE=NO'],
                'build', output, 1200)
        products = list((derived / 'Build/Products').glob('*.xctestrun'))
        if len(products) != 1:
            raise RuntimeError(f'Expected one freshly built .xctestrun, found {len(products)}')
        created = subprocess.run(['xcrun', 'simctl', 'create', 'Universe XCTest 18.5',
                                  'com.apple.CoreSimulator.SimDeviceType.iPhone-16',
                                  'com.apple.CoreSimulator.SimRuntime.iOS-18-5'],
                                 check=True, capture_output=True, text=True, timeout=30)
        # simctl accepts a lower-case UUID, but Xcode destination matching
        # requires the exact identifier returned by CoreSimulator.
        device = created.stdout.strip()
        UUID(device)  # Validate without changing its case.
        boot(device, output)
        bundle = output / 'Tests.xcresult'
        checked(['xcodebuild', 'test-without-building', '-xctestrun', str(products[0]),
                 '-destination', f'platform=iOS Simulator,id={device}', '-destination-timeout', '120',
                 '-parallel-testing-enabled', 'NO',
                 '-resultBundlePath', str(bundle)], 'test', output, 600)
        for kind in ('summary', 'tests'):
            result = subprocess.run(['xcrun', 'xcresulttool', 'get', 'test-results', kind,
                                     '--path', str(bundle), '--compact'],
                                    check=True, capture_output=True, text=True, timeout=30)
            (output / f'{kind}.json').write_text(result.stdout, encoding='utf-8')
        passed = validate(json.loads((output / 'tests.json').read_text(encoding='utf-8')))
        (output / 'verified.json').write_text(json.dumps({
            'protocol': 'stage8-xctest-v1', 'flutter_integration_tests_passed': 7,
            'native_resource_tests_passed': 1, 'cases': passed,
            'runner': platform.machine(), 'test_retries': 0,
        }, indent=2) + '\n', encoding='utf-8')
        print('VERIFIED: all 7 Flutter integration tests and 1 native resource test passed in one XCTest run.', flush=True)
        for name in passed:
            print(f'PASS {name}', flush=True)
        return 0
    except (StepFailed, subprocess.SubprocessError, OSError, ValueError, RuntimeError) as error:
        print(f'CI FAILED: {error}', flush=True)
        if device:
            try:
                run(['xcrun', 'simctl', 'spawn', device, 'log', 'show', '--last', '10m',
                     '--style', 'compact', '--predicate', 'process == "Runner"'],
                    'device-diagnostics', output, 20)
            except (StepFailed, OSError) as diagnostic_error:
                print(f'Diagnostics unavailable: {diagnostic_error}', flush=True)
        return error.code if isinstance(error, StepFailed) else 1
    finally:
        if device:
            try:
                subprocess.run(['xcrun', 'simctl', 'shutdown', device], timeout=15,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except (subprocess.SubprocessError, OSError):
                print('Simulator cleanup did not finish; test result is unchanged.', flush=True)


if __name__ == '__main__':
    sys.exit(main())
