import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_sentencepiece_tokenizer/dart_sentencepiece_tokenizer.dart';
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

// The UI can express only these three closed outcomes.
enum Outcome { risk, held, error }

class Reading {
  final Outcome outcome;
  final String reason;
  final int elapsedMs;
  final int rssBytes;
  const Reading(
    this.outcome,
    this.reason, [
    this.elapsedMs = 0,
    this.rssBytes = 0,
  ]);
}

const _hashes = {
  'model.onnx':
      'ca456c06b3a9505ddfd9131408916dd79290368331e7d76bb621f1cba6bc8665',
  'tokenizer.json':
      '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39',
  'head.json':
      'fc3593cfabdc324d4e37b69c4fd49749e957bb582e42367fcbcb7692feab8ea9',
};

class LocalEngine {
  final SentencePieceTokenizer tokenizer;
  final OrtSession _session;
  final List<List<double>> _weights;
  final List<double> _bias;
  final List<String> _labels;
  final double _threshold;
  LocalEngine._(
    this.tokenizer,
    this._session,
    this._weights,
    this._bias,
    this._labels,
    this._threshold,
  );

  static Future<LocalEngine> open(Directory assets) async {
    File file(String name) => File.fromUri(assets.uri.resolve(name));
    for (final entry in _hashes.entries) {
      final hash = await sha256.bind(file(entry.key).openRead()).single;
      if (hash.toString() != entry.value) {
        throw const FormatException('Asset checksum mismatch');
      }
    }
    final head = jsonDecode(await file('head.json').readAsString()) as Map;
    final weights = (head['coefficients'] as List)
        .map((row) => (row as List).cast<double>())
        .toList();
    final bias = (head['intercept'] as List).cast<double>();
    final labels = (head['classes'] as List).cast<String>();
    final tokenizer = await HuggingFaceTokenizerLoader.fromJsonFile(
      file('tokenizer.json').path,
    );
    final options = OrtSessionOptions();
    OrtSession? session;
    try {
      options.setIntraOpNumThreads(2);
      options.setInterOpNumThreads(1);
      session = OrtSession.fromFile(file('model.onnx'), options);
      final inputs = session.inputNames.toSet();
      if (inputs.length != 3 ||
          !inputs.containsAll([
            'input_ids',
            'attention_mask',
            'token_type_ids',
          ]) ||
          !session.outputNames.contains('last_hidden_state')) {
        throw const FormatException('Incompatible model signature');
      }
      return LocalEngine._(
        tokenizer,
        session,
        weights,
        bias,
        labels,
        head['threshold'] as double,
      );
    } catch (_) {
      await session?.release();
      rethrow;
    } finally {
      options.release();
    }
  }

  Reading inspect(String question, String language) {
    if (language != 'ru' && language != 'en') {
      return const Reading(Outcome.held, 'unsupported_language');
    }
    if (question.trim().isEmpty)
      return const Reading(Outcome.error, 'invalid_input');
    // Bound tokenizer work as well as the model context. Never inspect a prefix.
    if (question.length > 8192)
      return const Reading(Outcome.error, 'input_too_long');
    final watch = Stopwatch()..start();
    try {
      final ids = tokenizer.encode('query: $question').ids;
      if (ids.length > 512)
        return const Reading(Outcome.error, 'input_too_long');
      final scores = _infer(ids.toList());
      final result = _closedResult(question, scores);
      return Reading(
        result.outcome,
        result.reason,
        watch.elapsedMilliseconds,
        ProcessInfo.currentRss,
      );
    } catch (_) {
      return const Reading(Outcome.error, 'model_failure');
    }
  }

  List<double> _infer(List<int> ids) {
    final inputs = <String, OrtValue>{};
    var outputs = <OrtValue?>[];
    final options = OrtRunOptions();
    try {
      for (final entry in {
        'input_ids': ids,
        'attention_mask': List<int>.filled(ids.length, 1),
        'token_type_ids': List<int>.filled(ids.length, 0),
      }.entries) {
        inputs[entry.key] = OrtValueTensor.createTensorWithDataList(
          Int64List.fromList(entry.value),
          [1, ids.length],
        );
      }
      outputs = _session.run(options, inputs, ['last_hidden_state']);
      final tokens = ((outputs.single!.value as List).single as List);
      if (tokens.length != ids.length)
        throw const FormatException('Wrong sequence length');
      final pooled = Float64List(384);
      for (final token in tokens) {
        final vector = token as List;
        if (vector.length != pooled.length)
          throw const FormatException('Wrong embedding size');
        for (var i = 0; i < pooled.length; ++i) {
          pooled[i] += vector[i] as double;
        }
      }
      // Batch of one, no padding. L2 normalization cancels the mean divisor.
      final norm = math.sqrt(pooled.fold<double>(0, (sum, v) => sum + v * v));
      if (!norm.isFinite || norm <= 0)
        throw const FormatException('Invalid embedding');
      return List.generate(_labels.length, (c) {
        double logit = _bias[c];
        for (var i = 0; i < pooled.length; ++i) {
          logit += _weights[c][i] * pooled[i] / norm;
        }
        if (!logit.isFinite) throw const FormatException('Invalid score');
        return logit;
      });
    } finally {
      for (final output in outputs) {
        output?.release();
      }
      for (final input in inputs.values) {
        input.release();
      }
      options.release();
    }
  }

  Reading _closedResult(String text, List<double> scores) {
    final best = scores.reduce(math.max);
    final probability =
        1 / scores.fold<double>(0, (sum, s) => sum + math.exp(s - best));
    final label = _labels[scores.indexOf(best)];
    // Python's full casefold mappings that can contribute to the fixed veto words.
    const folds = {
      'ß': 'ss',
      'ſ': 's',
      'ᲂ': 'о',
      'ᲃ': 'с',
      'ᲄ': 'т',
      'ᲅ': 'т',
      'ﬁ': 'fi',
      'ﬂ': 'fl',
      'ﬃ': 'ffi',
      'ﬄ': 'ffl',
      'ﬅ': 'st',
      'ﬆ': 'st',
    };
    final folded = text.toLowerCase().replaceAllMapped(
      RegExp('[ßſᲂᲃᲄᲅﬁﬂﬃﬄﬅﬆ]'),
      (match) => folds[match[0]]!,
    );
    if (label == 'BLOCK_RISK' ||
        [
          'самоуб',
          'убить',
          'наркот',
          'kill',
          'suicid',
          'overdose',
        ].any(folded.contains)) {
      return const Reading(Outcome.risk, 'classified');
    }
    if (label == 'REFORMULATE')
      return const Reading(Outcome.held, 'review_pending');
    if (label == 'ALLOW' && probability >= _threshold) {
      return const Reading(Outcome.held, 'admission_disabled');
    }
    return const Reading(Outcome.held, 'classified');
  }

  Future<void> close() => _session.release();
}
