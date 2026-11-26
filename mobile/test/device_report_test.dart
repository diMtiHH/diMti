import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/device_report.dart';
import 'package:universe_lab/device_run.dart';
import 'package:universe_lab/engine.dart';

void main() {
  test(
    'report preserves units, UTC time, build mode and verified asset identity',
    () {
      final report = DeviceReport(
        measurement: const DeviceRun(12, 34, 567, 20),
        measuredAt: DateTime.parse('2026-11-26T15:00:00+03:00'),
        loadMs: 1234,
        operatingSystem: 'ios',
        operatingSystemVersion: 'test-version',
        buildMode: 'release',
      );
      expect(jsonDecode(report.encode()), {
        'protocol': 'stage2-20-checks-v1',
        'measured_at_utc': '2026-11-26T12:00:00.000Z',
        'operating_system': 'ios',
        'operating_system_version': 'test-version',
        'build_mode': 'release',
        'assets_sha256': modelAssetHashes,
        'admission': 'closed',
        'checks': 20,
        'load_ms': 1234,
        'p50_ms': 12,
        'p95_ms': 34,
        'max_sampled_rss_mib': 567,
        'memory_sampling': 'process RSS after each check; not peak memory',
      });
    },
  );
}
