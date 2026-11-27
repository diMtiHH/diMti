import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/universe_startup.dart';

import 'voice_page_test.dart' show pauseApp, resumeApp;

void main() {
  testWidgets(
    'animation time cannot unlock the screen before actual readiness',
    (tester) async {
      var complete = 0;
      bool ready = false;
      Widget app() => MaterialApp(
        home: UniverseStartup(
          language: 'ru',
          name: 'Астра',
          ready: ready,
          onComplete: () => complete++,
        ),
      );
      await tester.pumpWidget(app());
      expect(find.text('Создаём твою Вселенную'), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(complete, 0);
      expect(find.text('Привет, Астра'), findsOneWidget);
      ready = true;
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 800));
      expect(complete, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(complete, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'background suspends completion and reduced motion has no repeating frames',
    (tester) async {
      resumeApp(tester.binding);
      var complete = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: UniverseStartup(
              language: 'en',
              name: '',
              ready: false,
              onComplete: () => complete++,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(complete, 0);
      expect(tester.binding.hasScheduledFrame, false);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: UniverseStartup(
            language: 'en',
            name: '',
            ready: true,
            onComplete: () => complete++,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 660));
      pauseApp(tester.binding);
      await tester.pump(const Duration(seconds: 2));
      expect(complete, 0);
      resumeApp(tester.binding);
      await tester.pump(const Duration(seconds: 1));
      expect(complete, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
