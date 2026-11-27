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
      if (original != null) {
        final profile = jsonDecode(original) as Map;
        expect(profile['version'], 2);
        expect(
          profile.keys,
          unorderedEquals([
            'version',
            'name',
            'background',
            'answerStyle',
            'onboardingStep',
            'completed',
            'termsVersion',
            'audioEnabled',
            'ambientEnabled',
            'hapticsEnabled',
          ]),
        );
      }
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
        'version': 2,
        'name': 'profile fixture',
        'background': 'aurora',
        'answerStyle': 'livingMatter',
        'onboardingStep': 0,
        'completed': false,
        'termsVersion': 0,
        'audioEnabled': true,
        'ambientEnabled': false,
        'hapticsEnabled': true,
      };
      final valid = jsonEncode(fixture);
      final legacy =
          <String, Object>{
            ...fixture,
            'version': 1,
            'background': 'nebula',
            'answerStyle': 'sphere',
          }..removeWhere(
            (key, _) => key == 'ambientEnabled' || key == 'hapticsEnabled',
          );
      // Never write a valid profile: a missing original has no delete/restore
      // API. Invalid writes must preserve both absence and an existing profile.
      final invalid = [
        '{}',
        '{',
        ' ' * 2049,
        jsonEncode({...fixture, 'version': true}),
        jsonEncode({...fixture, 'version': 2.0}),
        jsonEncode({...fixture, 'version': 1}),
        jsonEncode({...fixture, 'version': 3}),
        valid.replaceFirst('"version":2', '"version":2,"version":2'),
        valid.replaceFirst('"version":2', r'"version":2,"\u0076ersion":2'),
        jsonEncode({...fixture, 'name': 'a' * 41}),
        jsonEncode({...fixture, 'name': 'line\ncontrol'}),
        jsonEncode({...fixture, 'audioEnabled': 1}),
        jsonEncode({...fixture, 'ambientEnabled': 1}),
        jsonEncode({...fixture, 'hapticsEnabled': 'true'}),
        jsonEncode({...fixture}..remove('ambientEnabled')),
        jsonEncode({...fixture, 'completed': true}),
        jsonEncode({...fixture, 'termsVersion': 1}),
        jsonEncode({...fixture, 'background': '../stars'}),
        jsonEncode({...fixture, 'background': 'nebula'}),
        jsonEncode({...fixture, 'answerStyle': 'sphere'}),
        jsonEncode({...fixture, 'question': 'forbidden field'}),
        jsonEncode({...legacy, 'audioEnabled': 1}),
        jsonEncode({...legacy, 'background': 'aurora'}),
        jsonEncode({...legacy, 'ambientEnabled': false}),
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
