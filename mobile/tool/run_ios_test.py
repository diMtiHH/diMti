"""Boot the CI simulator with one recovery attempt and bound test startup."""
import subprocess
import sys


def main():
    device = sys.argv[1]
    for attempt in range(2):
        try:
            boot = subprocess.run(
                ['xcrun', 'simctl', 'bootstatus', device, '-b'],
                capture_output=True, text=True, timeout=300,
            )
            output = boot.stdout + boot.stderr
            print(output, flush=True)
            if boot.returncode == 0 and 'Data Migration Failed' not in output:
                break
        except subprocess.TimeoutExpired as error:
            for partial in (error.stdout, error.stderr):
                if partial:
                    print(partial.decode(errors='replace') if isinstance(partial, bytes) else partial, flush=True)
            print('Simulator boot timed out.', flush=True)
        if attempt == 1:
            raise SystemExit('Simulator did not boot; application test was not run.')
        print('Restarting simulator after unsuccessful boot.', flush=True)
        try:
            subprocess.run(['xcrun', 'simctl', 'shutdown', device], timeout=60, check=False)
        except subprocess.TimeoutExpired:
            print('Simulator shutdown timed out; application test was not run.', flush=True)
            return 124
    try:
        result = subprocess.run(
            ['flutter', 'test', '--verbose', '--reporter', 'expanded', '--no-pub', '-d', device,
             *(sys.argv[2:] or ['integration_test/ios_model_test.dart'])],
            timeout=1200,
        )
        return result.returncode
    except subprocess.TimeoutExpired:
        print('Simulator test exceeded 20 minutes, including build and launch.', flush=True)
        return 124


if __name__ == '__main__':
    sys.exit(main())
