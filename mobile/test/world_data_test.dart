import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/world_data.dart';
import 'package:universe_lab/world_catalog.dart';

class MemoryWorldStore implements WorldStore {
  String? value;
  final writes = <String>[];
  bool fail = false;
  Completer<void>? block;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String text) async {
    await block?.future;
    if (fail) throw StateError('storage');
    value = text;
    writes.add(text);
  }
}

class TestWorldTransport implements WorldTransport {
  @override
  bool configured = true;
  bool fail = false;
  int cancels = 0;
  Completer<void>? block;
  final uploads = <Map<String, Object>>[];
  WorldSnapshot? result;
  @override
  Future<WorldSnapshot> ranking(String period, String language) async {
    if (fail) throw StateError('network');
    return result ??
        WorldSnapshot(period, language, '2026-11-26', false, [
          (worldCatalog.first, 10),
        ]);
  }

  @override
  Future<void> upload(Map<String, Object> batch) async {
    uploads.add(Map<String, Object>.from(jsonDecode(jsonEncode(batch)) as Map));
    await block?.future;
    if (fail) throw StateError('ambiguous transport');
  }

  @override
  void cancel() {
    ++cancels;
  }
}

void main() {
  late MemoryWorldStore store;
  late TestWorldTransport api;
  late WorldController model;
  setUp(() async {
    store = MemoryWorldStore();
    api = TestWorldTransport();
    model = WorldController(
      store: store,
      transport: api,
      now: () => DateTime.utc(2026, 11, 27),
      personalBuild: false,
    );
    await model.load();
  });
  tearDown(() => model.dispose());
  test(
    'no consent means no writes or upload; unknown IDs never enter queue',
    () async {
      await model.record('read_novel', 'ru');
      expect(store.writes, isEmpty);
      expect(await model.flush(), false);
      await model.setConsent(true);
      await model.record('private text', 'ru');
      await model.record('read_novel', 'fr');
      expect(await model.flush(), false);
      expect(api.uploads, isEmpty);
    },
  );
  test('only fixed fields leave the device; aggregated counts and receipt survive restart', () async {
    await model.setConsent(true);
    await model.record('read_novel', 'ru');
    await model.record('read_novel', 'ru');
    api.fail = true;
    expect(await model.flush(), false);
    final first = api.uploads.single;
    expect(first.keys, unorderedEquals(['version', 'batch', 'buckets']));
    expect((first['buckets'] as List).single, {
      'topic': 'read_novel',
      'language': 'ru',
      'day': '2026-11-27',
      'count': 2,
    });
    final restored = WorldController(
      store: store,
      transport: api,
      now: () => DateTime.utc(2026, 11, 27),
      personalBuild: false,
    );
    await restored.load();
    api.fail = false;
    expect(await restored.flush(), true);
    expect(api.uploads.last, first);
    expect(jsonDecode(store.value!)['batch'], null);
    restored.dispose();
    for (final key in [
      'question',
      'name',
      'audio',
      'answer',
      'deviceId',
      'userId',
    ])
      expect(jsonEncode(first), isNot(contains('"$key"')));
  });
  test(
    'withdrawal clears persisted queue and invalidates late acknowledgement',
    () async {
      await model.setConsent(true);
      await model.record('read_novel', 'ru');
      api.block = Completer<void>();
      final sending = model.flush();
      await Future<void>.delayed(Duration.zero);
      expect(api.uploads, hasLength(1));
      expect(await model.setConsent(false), true);
      expect(model.consent, false);
      expect(api.cancels, 1);
      await model.record('puzzle', 'en');
      api.block!.complete();
      expect(await sending, false);
      final state = jsonDecode(store.value!);
      expect(state['pending'], isEmpty);
      expect(state['batch'], null);
      final restored = WorldController(
        store: store,
        transport: api,
        personalBuild: false,
      );
      await restored.load();
      expect(restored.consent, false);
      expect(await restored.flush(), false);
      restored.dispose();
    },
  );
  test(
    'new counts while a batch is in flight survive successful acknowledgement',
    () async {
      await model.setConsent(true);
      await model.record('read_novel', 'ru');
      api.block = Completer<void>();
      final sending = model.flush();
      await Future<void>.delayed(Duration.zero);
      await model.record('puzzle', 'en');
      api.block!.complete();
      expect(await sending, true);
      api.block = null;
      expect(await model.flush(), true);
      expect((api.uploads.last['buckets'] as List).single['topic'], 'puzzle');
    },
  );
  test(
    'personal build excludes all counts even with consent and retries',
    () async {
      final personal = WorldController(
        store: MemoryWorldStore(),
        transport: api,
        personalBuild: true,
      );
      await personal.load();
      await personal.setConsent(true);
      await personal.record('read_novel', 'ru');
      expect(await personal.flush(), false);
      expect(api.uploads, isEmpty);
      personal.dispose();
    },
  );
  test('lost storage acknowledgement stops upload rather than sending uncommitted consent', () async {
    store.fail = true;
    expect(await model.setConsent(true), false);
    expect(model.consent, false);
    await model.record('read_novel', 'ru');
    expect(await model.flush(), false);
    expect(api.uploads, isEmpty);
  });
  test(
    'cache survives offline restart and follows exact period and language',
    () async {
      expect(await model.refresh('week', 'ru'), true);
      final restored = WorldController(
        store: store,
        transport: api,
        now: () => DateTime.utc(2026, 11, 27),
      );
      await restored.load();
      api.fail = true;
      expect(await restored.refresh('week', 'ru'), false);
      expect(restored.cache['week/ru']!.items.single.$2, 10);
      expect(restored.cache['week/en'], null);
      restored.dispose();
    },
  );
  test('wrong filter, current day, unknown topic, rare count and extra text are rejected', () async {
    api.result = WorldSnapshot('month', 'en', '2026-11-26', false, []);
    expect(await model.refresh('week', 'ru'), false);
    expect(model.cache, isEmpty);
    api.result = WorldSnapshot('week', 'ru', '2026-11-27', false, []);
    expect(await model.refresh('week', 'ru'), false);
    final base = WorldSnapshot('week', 'ru', '2026-11-26', false, [
      (worldCatalog.first, 10),
    ]).encode();
    for (final row in [
      {'topic': 'harm', 'count': 10},
      {'topic': 'read_novel', 'count': 9},
      {'topic': 'read_novel', 'count': 11},
      {'topic': 'read_novel', 'count': true},
      {'topic': 'read_novel', 'count': 10, 'text': 'private'},
    ])
      expect(
        () => WorldSnapshot.decode({
          ...base,
          'items': [row],
        }),
        throwsFormatException,
      );
    expect(
      () => WorldSnapshot.decode({...base, 'name': 'private'}),
      throwsFormatException,
    );
  });
  test(
    'corrupt saved data is not replaced by defaults or used for collection',
    () async {
      store.value = '{"version":1,"question":"private"}';
      final restored = WorldController(
        store: store,
        transport: api,
        personalBuild: false,
      );
      await restored.load();
      expect(restored.failed, true);
      expect(restored.loaded, false);
      await restored.record('read_novel', 'ru');
      expect(await restored.flush(), false);
      expect(store.value, contains('private'));
      restored.dispose();
    },
  );
  test('reduce motion persists independently of session and consent', () async {
    expect(await model.setReduceMotion(true), true);
    final restored = WorldController(store: store, transport: api);
    await restored.load();
    expect(restored.reduceMotion, true);
    expect(restored.consent, false);
    expect(api.uploads, isEmpty);
    restored.dispose();
  });
  test('HTTPS origin only; credentials, redirects destination parameters and cleartext disallowed', () {
    for (final endpoint in [
      'http://localhost:8000',
      'https://user:pass@host',
      'https://host/path',
      'https://host/?q=private',
      'https://host/#x',
    ]) {
      expect(() => HttpWorldTransport(endpoint), throwsFormatException);
    }
    expect(HttpWorldTransport().configured, false);
    expect(HttpWorldTransport('https://example.org').configured, true);
  });
  test('old offline receipts are discarded instead of endlessly retrying rejected uploads', () async {
    await model.setConsent(true);
    await model.record('read_novel', 'ru');
    api.fail = true;
    await model.flush();
    final restored = WorldController(
      store: store,
      transport: api,
      now: () => DateTime.utc(2027, 1, 10),
      personalBuild: false,
    );
    await restored.load();
    api.fail = false;
    api.uploads.clear();
    expect(await restored.flush(), false);
    expect(api.uploads, isEmpty);
    expect(jsonDecode(store.value!)['batch'], null);
    restored.dispose();
  });
}
