import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native presentation profile and bundled narration reject unsafe mutation',
    (tester) async {
      const channel = MethodChannel('ask_universe/presentation');
      const voice = MethodChannel('ask_universe/voice');
      final original = await channel.invokeMethod<String>('readProfile');
      if (original != null) expect(jsonDecode(original), isA<Map>());
      final permissions = await voice.invokeMapMethod<Object?, Object?>(
        'availability',
        {'language': 'ru'},
      );
      expect(permissions, isNotNull);

      Matcher platformCode(String expected) => throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          expected,
        ),
      );
      final fixture = <String, Object>{
        'version': 1,
        'name': 'profile fixture',
        'background': 'stars',
        'answerStyle': 'sphere',
        'onboardingStep': 0,
        'completed': false,
        'termsVersion': 0,
        'audioEnabled': true,
      };
      final valid = jsonEncode(fixture);
      // Never write a valid profile: a missing original has no delete/restore
      // API. Invalid writes must preserve both absence and an existing profile.
      final invalid = [
        '{}',
        '{',
        ' ' * 2049,
        jsonEncode({...fixture, 'version': true}),
        jsonEncode({...fixture, 'version': 1.0}),
        valid.replaceFirst('"version":1', '"version":1,"version":1'),
        valid.replaceFirst('"version":1', r'"version":1,"\u0076ersion":1'),
        jsonEncode({...fixture, 'name': 'a' * 41}),
        jsonEncode({...fixture, 'name': 'line\ncontrol'}),
        jsonEncode({...fixture, 'audioEnabled': 1}),
        jsonEncode({...fixture, 'completed': true}),
        jsonEncode({...fixture, 'termsVersion': 1}),
        jsonEncode({...fixture, 'background': '../stars'}),
        jsonEncode({...fixture, 'question': 'forbidden field'}),
      ];
      for (final value in invalid) {
        await expectLater(
          channel.invokeMethod<void>('writeProfile', {'value': value}),
          platformCode('invalid_profile'),
        );
        expect(await channel.invokeMethod<String>('readProfile'), original);
      }

      for (final language in ['ru', 'en']) {
        final info = await channel.invokeMapMethod<Object?, Object?>(
          'narrationInfo',
          {'language': language},
        );
        expect(info, isNotNull);
        expect(info!.keys, unorderedEquals(['durationMs']));
        expect(info['durationMs'], isA<int>());
        expect(info['durationMs'], inInclusiveRange(1, 600000));
      }
      await expectLater(
        channel.invokeMethod<Object?>('narrationInfo', {'language': '../ru'}),
        platformCode('unavailable'),
      );
      // No playback was started. A stale stop must remain a no-op; position
      // must reject the unknown generation instead of pretending audio plays.
      for (final id in [700201, 700202]) {
        await channel.invokeMethod<void>('stopNarration', {'id': id});
        await expectLater(
          channel.invokeMethod<Object?>('narrationPosition', {'id': id}),
          platformCode('interrupted'),
        );
      }
      final after = await voice.invokeMapMethod<Object?, Object?>(
        'availability',
        {'language': 'ru'},
      );
      expect(
        after!['microphoneAuthorized'],
        permissions!['microphoneAuthorized'],
      );
      expect(after['speechAuthorized'], permissions['speechAuthorized']);
      expect(await channel.invokeMethod<String>('readProfile'), original);
    },
  );
}
