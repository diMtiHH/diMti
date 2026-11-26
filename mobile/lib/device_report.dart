import 'dart:convert';

import 'device_run.dart';
import 'engine.dart';

/// Fixed benchmark data only. No question text, paths or device identifiers.
class DeviceReport {
  final DeviceRun measurement;
  final DateTime measuredAt;
  final int loadMs;
  final String operatingSystem, operatingSystemVersion, buildMode;

  const DeviceReport({
    required this.measurement,
    required this.measuredAt,
    required this.loadMs,
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.buildMode,
  });

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'protocol': 'stage2-20-checks-v1',
    'measured_at_utc': measuredAt.toUtc().toIso8601String(),
    'operating_system': operatingSystem,
    'operating_system_version': operatingSystemVersion,
    'build_mode': buildMode,
    'assets_sha256': modelAssetHashes,
    'admission': 'closed',
    'checks': measurement.checked,
    'load_ms': loadMs,
    'p50_ms': measurement.p50Ms,
    'p95_ms': measurement.p95Ms,
    'max_sampled_rss_mib': measurement.maxSampledRssMiB,
    'memory_sampling': 'process RSS after each check; not peak memory',
  });
}
