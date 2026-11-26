import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native voice capability and cancellation never request capture',
    (tester) async {
      const channel = MethodChannel('ask_universe/voice');
      final before = <String, Map<Object?, Object?>>{};
      for (final language in ['ru', 'en']) {
        final result = await channel.invokeMapMethod<Object?, Object?>(
          'availability',
          {'language': language},
        );
        expect(result, isNotNull);
        expect(result!['supported'], isA<bool>());
        expect(result['microphoneAuthorized'], isA<bool>());
        expect(result['speechAuthorized'], isA<bool>());
        before[language] = result;
      }
      // An unsupported locale must fail before asking the OS for permissions.
      await expectLater(
        channel.invokeMethod<void>('start', {'id': 700001, 'language': 'xx'}),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'unavailable',
          ),
        ),
      );
      await channel.invokeMethod<void>('stop', {'id': 700001});
      await channel.invokeMethod<void>('cancel', {'id': 700001});
      for (final language in ['ru', 'en']) {
        final after = await channel.invokeMapMethod<Object?, Object?>(
          'availability',
          {'language': language},
        );
        expect(
          after!['microphoneAuthorized'],
          before[language]!['microphoneAuthorized'],
        );
        expect(
          after['speechAuthorized'],
          before[language]!['speechAuthorized'],
        );
      }
    },
  );
}
