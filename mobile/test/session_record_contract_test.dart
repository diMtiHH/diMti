import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/session_core.dart';

class ContractStore implements SessionStore {
  String value;
  int writes = 0;
  ContractStore(this.value);
  @override
  Future<String?> read() async => value;
  @override
  Future<void> replace(String next) async {
    writes++;
    value = next;
  }
}

class RecoveryClock implements SessionClock {
  @override
  Future<ClockSample> read() async =>
      const ClockSample(100000, 100000, 'new-fixture-domain');
}

class NoRecoveryDraw implements AnswerSource {
  int calls = 0;
  @override
  int next100() {
    calls++;
    throw StateError('Recovery must never choose another answer');
  }
}

void main() {
  final cases = jsonDecode(
    File('test/fixtures/session_records.json').readAsStringSync(),
  ) as List;
  for (final item in cases.cast<Map<String, dynamic>>()) {
    test('shared native contract: ${item['scope']} ${item['name']}', () async {
      final store = ContractStore(item['raw'] as String);
      final random = NoRecoveryDraw();
      var validations = 0;
      final session = QuestionSession(
        diagnostic: item['scope'] == 'diagnostic',
        store: store,
        clock: RecoveryClock(),
        random: random,
        validateQuestion: (_, _) async {
          validations++;
          return Admission.unavailable;
        },
      );
      await session.initialize();
      expect(session.phase == SessionPhase.failed, item['valid'] == false);
      expect(random.calls, 0);
      expect(validations, 0);
      if (item['valid'] == false) {
        expect(store.writes, 0);
        expect(store.value, item['raw']);
      }
    });
  }
}
