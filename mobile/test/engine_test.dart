import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/device_run.dart';
import 'package:universe_lab/worker.dart';

void main() {
  final assets = Directory('assets/stage2').absolute;
  late LocalEngine model;
  setUpAll(() async {
    model = await LocalEngine.open(assets);
    addTearDown(model.close);
  });

  test('FP32 Dart path agrees with the frozen Python implementation, one full question per run', () async {
    final cases =
        jsonDecode(await File('test/reference.json').readAsString()) as List;
    expect(cases.length, 58);
    for (final row in cases.cast<Map>()) {
      final text = row['text'] as String;
      expect(
        model.tokenizer.encode('query: $text').ids.toList(),
        row['ids'],
        reason: row['id'],
      );
      final verdict = model.inspect(text, row['language'] as String);
      expect(verdict.outcome.name, row['outcome'], reason: row['id']);
      expect(verdict.reason, row['reason'], reason: row['id']);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('full input is required', () {
    expect(model.inspect('word ' * 600, 'en').reason, 'input_too_long');
    expect(model.inspect('', 'ru').reason, 'invalid_input');
    expect(model.inspect('ſuicide', 'en').outcome, Outcome.risk);
    expect(model.inspect('texte', 'fr').reason, 'unsupported_language');
  });

  test('missing or corrupt model fails at startup', () async {
    final empty = await Directory.systemTemp.createTemp('universe-corrupt-');
    try {
      await expectLater(
        LocalEngine.open(empty),
        throwsA(isA<FileSystemException>()),
      );
      await File.fromUri(empty.uri.resolve('model.onnx'))
          .writeAsString('fixture');
      await expectLater(LocalEngine.open(empty), throwsFormatException);
    } finally {
      await empty.delete(recursive: true);
    }
  });

  test('UI worker runs the bundled model off the UI isolate', () async {
    final worker = ModelWorker();
    try {
      await worker.start(assets.path);
      final first = worker.inspect('Should I read a novel tonight?', 'en');
      final duplicate = await worker.inspect('Duplicate request', 'en');
      expect(duplicate.outcome, Outcome.error);
      expect((await first).outcome, isNot(Outcome.error));
      final measured = await DeviceRun.measure(worker.inspect, () => true);
      expect(measured.checked, 20);
      expect(measured.maxSampledRssMiB, greaterThan(0));
      expect(worker.loadMs, greaterThan(0));
    } finally {
      worker.close();
    }
  });
}
