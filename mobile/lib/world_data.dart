import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'release_features.dart';
import 'world_catalog.dart';

const worldPeriods = ['day', 'week', 'month'];
const worldLanguages = ['all', 'ru', 'en'];
void _keys(Map value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.toSet().containsAll(keys)) {
    throw const FormatException('World schema');
  }
}

String worldDay(DateTime value) =>
    value.toUtc().toIso8601String().substring(0, 10);
bool _day(Object? value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value))
    return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null &&
      worldDay(DateTime.utc(parsed.year, parsed.month, parsed.day)) == value;
}

class WorldBucket {
  final String topic, language, day;
  final int count;
  const WorldBucket(this.topic, this.language, this.day, this.count);
  factory WorldBucket.decode(Object? raw) {
    if (raw is! Map) throw const FormatException('Bucket');
    _keys(raw, {'topic', 'language', 'day', 'count'});
    if (raw['topic'] is! String ||
        topicById(raw['topic']) == null ||
        !['ru', 'en'].contains(raw['language']) ||
        !_day(raw['day']) ||
        raw['count'] is! int ||
        raw['count'] < 1 ||
        raw['count'] > 48) {
      throw const FormatException('Bucket fields');
    }
    return WorldBucket(raw['topic'], raw['language'], raw['day'], raw['count']);
  }
  String get key => '$topic/$language/$day';
  Map<String, Object> encode() => {
    'topic': topic,
    'language': language,
    'day': day,
    'count': count,
  };
}

List<WorldBucket> _buckets(Object? raw) {
  if (raw is! List || raw.length > 64) throw const FormatException('Buckets');
  final result = raw.map(WorldBucket.decode).toList();
  if (result.map((x) => x.key).toSet().length != result.length)
    throw const FormatException('Duplicate bucket');
  return result;
}

class WorldSnapshot {
  final String period, language, through;
  final bool testing;
  final List<(WorldTopic, int)> items;
  const WorldSnapshot(
    this.period,
    this.language,
    this.through,
    this.testing,
    this.items,
  );
  factory WorldSnapshot.decode(Object? raw) {
    if (raw is! Map) throw const FormatException('Ranking');
    _keys(raw, {
      'version',
      'environment',
      'period',
      'language',
      'through',
      'threshold',
      'items',
    });
    if (raw['version'] != 1 ||
        raw['threshold'] != 10 ||
        !['test', 'production'].contains(raw['environment']) ||
        !worldPeriods.contains(raw['period']) ||
        !worldLanguages.contains(raw['language']) ||
        !_day(raw['through']) ||
        raw['items'] is! List ||
        (raw['items'] as List).length > worldCatalog.length) {
      throw const FormatException('Ranking fields');
    }
    final items = <(WorldTopic, int)>[];
    final seen = <String>{};
    for (final row in raw['items']) {
      if (row is! Map) throw const FormatException('Ranking item');
      _keys(row, {'topic', 'count'});
      final topic = row['topic'] is String ? topicById(row['topic']) : null;
      final count = row['count'];
      if (topic == null ||
          !seen.add(topic.id) ||
          count is! int ||
          count < 10 ||
          count > 16000000000 ||
          count % 5 != 0) {
        throw const FormatException('Unsafe ranking');
      }
      items.add((topic, count));
    }
    return WorldSnapshot(
      raw['period'],
      raw['language'],
      raw['through'],
      raw['environment'] == 'test',
      List.unmodifiable(items),
    );
  }
  String get key => '$period/$language';
  Map<String, Object> encode() => {
    'version': 1,
    'environment': testing ? 'test' : 'production',
    'period': period,
    'language': language,
    'through': through,
    'threshold': 10,
    'items': [
      for (final row in items) {'topic': row.$1.id, 'count': row.$2},
    ],
  };
}

abstract interface class WorldStore {
  Future<String?> read();
  Future<void> write(String value);
}

class IosWorldStore implements WorldStore {
  static const channel = MethodChannel('ask_universe/presentation');
  @override
  Future<String?> read() => channel.invokeMethod<String>('readWorld');
  @override
  Future<void> write(String value) =>
      channel.invokeMethod<void>('writeWorld', {'value': value});
}

abstract interface class WorldTransport {
  bool get configured;
  Future<WorldSnapshot> ranking(String period, String language);
  Future<void> upload(Map<String, Object> batch);
  void cancel();
}

class HttpWorldTransport implements WorldTransport {
  final Uri? endpoint;
  HttpClient? _client;
  HttpWorldTransport([String url = worldApiEndpoint])
    : endpoint = _endpoint(url);
  static Uri? _endpoint(String value) {
    if (value.isEmpty) return null;
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const FormatException('HTTPS service origin required');
    }
    return uri;
  }

  @override
  bool get configured => endpoint != null;
  Future<Object?> _request(
    String path, {
    Map<String, String>? query,
    Map<String, Object>? body,
  }) async {
    if (endpoint == null) throw const SocketException('No service configured');
    final client = _client ??= (HttpClient()
      ..connectionTimeout = const Duration(seconds: 5));
    final uri = endpoint!.resolve(path).replace(queryParameters: query);
    final request = await client
        .openUrl(body == null ? 'GET' : 'POST', uri)
        .timeout(const Duration(seconds: 7));
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw const FormatException('Service response');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 7))) {
      if (bytes.length + chunk.length > 32768) {
        cancel();
        throw const FormatException('Response too large');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<WorldSnapshot> ranking(String period, String language) async =>
      WorldSnapshot.decode(
        await _request(
          '/v1/ranking',
          query: {'period': period, 'language': language},
        ),
      );
  @override
  Future<void> upload(Map<String, Object> batch) async {
    final response = await _request('/v1/counts', body: batch);
    if (response is! Map ||
        response.length != 1 ||
        response['accepted'] != true)
      throw const FormatException('Upload not accepted');
  }

  @override
  void cancel() {
    _client?.close(force: true);
    _client = null;
  }
}

class WorldController extends ChangeNotifier {
  final WorldStore store;
  final WorldTransport transport;
  final DateTime Function() now;
  final bool personalBuild;
  bool loaded = false,
      failed = false,
      offline = false,
      consent = false,
      reduceMotion = false;
  bool _disposed = false, _uploading = false;
  bool _loading = false;
  int _epoch = 0;
  Future<void> _writes = Future.value();
  List<WorldBucket> _pending = [];
  Map<String, Object>? _batch;
  final Map<String, WorldSnapshot> cache = {};
  WorldController({
    required this.store,
    required this.transport,
    DateTime Function()? now,
    this.personalBuild = personalTestBuild,
  }) : now = now ?? DateTime.now;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> _serial(Future<void> Function() task) {
    final result = Completer<bool>();
    _writes = _writes.then((_) async {
      try {
        if (_disposed) {
          result.complete(false);
          return;
        }
        await task();
        result.complete(true);
      } catch (_) {
        failed = true;
        result.complete(false);
      }
      _changed();
    });
    return result.future;
  }

  String _encode() => jsonEncode({
    'version': 1,
    'consent': consent,
    'reduceMotion': reduceMotion,
    'pending': _pending.map((x) => x.encode()).toList(),
    'batch': _batch,
    'cache': cache.values.map((x) => x.encode()).toList(),
  });
  Future<void> _save() => store.write(_encode());
  Future<void> load() async {
    if (_loading) return;
    _loading = true;
    await _serial(() async {
      final raw = await store.read();
      if (raw != null) {
        if (utf8.encode(raw).length > 65536)
          throw const FormatException('World data too large');
        final value = jsonDecode(raw);
        if (value is! Map) throw const FormatException('World state');
        _keys(value, {
          'version',
          'consent',
          'reduceMotion',
          'pending',
          'batch',
          'cache',
        });
        if (value['version'] != 1 ||
            value['consent'] is! bool ||
            value['reduceMotion'] is! bool ||
            value['cache'] is! List ||
            (value['cache'] as List).length > 9)
          throw const FormatException('World state fields');
        final pending = _buckets(value['pending']);
        Map<String, Object>? batch;
        if (value['batch'] != null) {
          final data = value['batch'];
          if (data is! Map) throw const FormatException('Batch');
          _keys(data, {'version', 'batch', 'buckets'});
          if (data['version'] != 1 ||
              data['batch'] is! String ||
              !RegExp(r'^[0-9a-f]{32}$').hasMatch(data['batch']))
            throw const FormatException('Batch id');
          batch = {
            'version': 1,
            'batch': data['batch'],
            'buckets': _buckets(data['buckets'])
                .map((x) => x.encode())
                .toList(),
          };
        }
        final savedCache = <String, WorldSnapshot>{};
        for (final raw in value['cache']) {
          final snapshot = WorldSnapshot.decode(raw);
          if (savedCache.containsKey(snapshot.key))
            throw const FormatException('Duplicate snapshot');
          savedCache[snapshot.key] = snapshot;
        }
        if (!value['consent'] && (pending.isNotEmpty || batch != null))
          throw const FormatException('Counters without consent');
        consent = value['consent'];
        reduceMotion = value['reduceMotion'];
        _pending = pending;
        _batch = batch;
        cache
          ..clear()
          ..addAll(savedCache);
      }
      loaded = true;
      failed = false;
    });
    _loading = false;
  }

  Future<bool> setConsent(bool enabled) {
    if (!enabled) {
      consent = false;
      ++_epoch;
      transport.cancel();
    }
    final epoch = _epoch;
    return _serial(() async {
      if (!loaded || failed) throw StateError('Storage unavailable');
      if (enabled && epoch != _epoch) return;
      if (!enabled) {
        _pending = [];
        _batch = null;
      }
      consent = enabled;
      try {
        await _save();
      } catch (_) {
        consent = false;
        rethrow;
      }
    });
  }

  Future<bool> setReduceMotion(bool enabled) => _serial(() async {
    if (!loaded || failed) throw StateError('Storage unavailable');
    final previous = reduceMotion;
    reduceMotion = enabled;
    try {
      await _save();
    } catch (_) {
      reduceMotion = previous;
      rethrow;
    }
  });
  Future<bool> record(String topic, String language) => _serial(() async {
    // Personal answers and the limit-reset tool must never inflate public data.
    if (!loaded ||
        failed ||
        !consent ||
        personalBuild ||
        topicById(topic) == null ||
        !['ru', 'en'].contains(language))
      return;
    final day = worldDay(now());
    final oldest = worldDay(now().toUtc().subtract(const Duration(days: 30)));
    _pending.removeWhere(
      (x) => x.day.compareTo(oldest) < 0 || x.day.compareTo(day) > 0,
    );
    final bucket = WorldBucket(topic, language, day, 1);
    final index = _pending.indexWhere((x) => x.key == bucket.key);
    if (index < 0) {
      if (_pending.length < 64) _pending.add(bucket);
    } else {
      final old = _pending[index];
      _pending[index] = WorldBucket(
        topic,
        language,
        day,
        min(48, old.count + 1),
      );
    }
    await _save();
  });
  Future<bool> refresh(String period, String language) async {
    if (!worldPeriods.contains(period) || !worldLanguages.contains(language))
      return false;
    if (!transport.configured) {
      offline = true;
      _changed();
      return false;
    }
    try {
      final snapshot = await transport.ranking(period, language);
      if (_disposed) return false;
      if (snapshot.period != period ||
          snapshot.language != language ||
          snapshot.through.compareTo(worldDay(now())) >= 0) {
        throw const FormatException('Mismatched snapshot');
      }
      final saved = await _serial(() async {
        if (!loaded || failed) throw StateError('Storage unavailable');
        cache[snapshot.key] = snapshot;
        await _save();
        offline = false;
      });
      return saved;
    } catch (_) {
      offline = true;
      _changed();
      return false;
    }
  }

  Future<bool> flush() async {
    if (_uploading ||
        !loaded ||
        failed ||
        !consent ||
        personalBuild ||
        !transport.configured)
      return false;
    _uploading = true;
    final epoch = _epoch;
    try {
      final prepared = await _serial(() async {
        if (!consent || epoch != _epoch) return;
        final oldest = worldDay(
          now().toUtc().subtract(const Duration(days: 30)),
        );
        final today = worldDay(now());
        _pending.removeWhere(
          (x) => x.day.compareTo(oldest) < 0 || x.day.compareTo(today) > 0,
        );
        if (_batch != null &&
            _buckets(_batch!['buckets']).any(
              (x) => x.day.compareTo(oldest) < 0 || x.day.compareTo(today) > 0,
            )) {
          _batch = null;
          await _save();
        }
        if (_batch == null && _pending.isNotEmpty) {
          final rng = Random.secure();
          final id = List.generate(
            16,
            (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
          _batch = {
            'version': 1,
            'batch': id,
            'buckets': _pending.map((x) => x.encode()).toList(),
          };
          _pending = [];
          await _save();
        }
      });
      final batch = _batch;
      if (!prepared || batch == null || !consent || epoch != _epoch)
        return false;
      await transport.upload(batch);
      if (_disposed || !consent || epoch != _epoch) return false;
      return await _serial(() async {
        if (consent && epoch == _epoch && identical(batch, _batch)) {
          _batch = null;
          await _save();
        }
      });
    } catch (_) {
      return false;
    } finally {
      _uploading = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    transport.cancel();
    super.dispose();
  }
}
