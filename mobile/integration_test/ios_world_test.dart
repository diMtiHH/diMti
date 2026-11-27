import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universe_lab/engine.dart';
import 'package:universe_lab/ios_session.dart';
import 'package:universe_lab/personal_test_gate.dart';
import 'package:universe_lab/session_core.dart';
import 'package:universe_lab/world_catalog.dart';
import 'package:universe_lab/world_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native world privacy catalog admission and personal reset', (
    tester,
  ) async {
    final store = IosWorldStore();
    final original = await store.read();
    final empty = jsonEncode({
      'version': 1,
      'consent': false,
      'reduceMotion': false,
      'pending': [],
      'batch': null,
      'cache': [],
    });
    await store.write(empty);
    final world = WorldController(
      store: store,
      transport: HttpWorldTransport(),
    );
    await world.load();
    expect(world.loaded, true);
    expect(world.consent, false);
    expect(await world.setReduceMotion(true), true);
    final restored = WorldController(
      store: store,
      transport: HttpWorldTransport(),
    );
    await restored.load();
    expect(restored.reduceMotion, true);
    expect(await restored.setConsent(true), true);
    await restored.record('read_novel', 'ru');
    expect(jsonDecode((await store.read())!)['pending'], isEmpty);
    await restored.setConsent(false);
    final before = await store.read();
    for (final unsafe in [
      '{"question":"private"}',
      empty.replaceFirst('"version":1', '"version":1,"version":1'),
    ]) {
      await expectLater(store.write(unsafe), throwsA(isA<PlatformException>()));
      expect(await store.read(), before);
    }
    world.dispose();
    restored.dispose();
    await store.write(original ?? empty);
    final app = File(Platform.resolvedExecutable).parent;
    final model = await LocalEngine.open(
      Directory.fromUri(
        app.uri.resolve(
          'Frameworks/App.framework/flutter_assets/assets/stage2/',
        ),
      ),
    );
    const backend = IosSessionBackend();
    final oldSession = await backend.read();
    try {
      await backend.replace('{"version":1,"phase":"idle"}');
      final gate = PersonalTestGate(
        (text, language) async => model.inspect(text, language),
      );
      for (final language in ['ru', 'en']) {
        for (final topic in worldCatalog)
          expect(
            await gate.call(topic.text(language), language),
            Admission.allowed,
            reason: '${topic.id}/$language',
          );
      }
      expect(
        await gate.call('Should I hurt myself?', 'en'),
        isNot(Admission.allowed),
      );
      final session = QuestionSession(
        store: backend,
        clock: const BackendClock(backend),
        random: SystemAnswerSource(),
        validateQuestion: gate.call,
        notifications: const BackendNotifications(backend),
      );
      await session.initialize();
      session.edit(worldCatalog.first.ru);
      expect(await session.confirm(session.review()!), SubmitResult.pending);
      final answer = session.pendingAnswer;
      expect(await session.resetPersonalPause(), false);
      await session.initialize();
      expect(session.pendingAnswer, answer);
      expect(await session.acknowledgeShown(), true);
      expect(session.remainingSeconds, 1800);
      expect(await session.resetPersonalPause(), true);
      await session.initialize();
      expect(session.phase, SessionPhase.ready);
      expect((await backend.preferences()).englishNotifications, true);
    } finally {
      await model.close();
      await backend.replace(oldSession ?? '{"version":1,"phase":"idle"}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
