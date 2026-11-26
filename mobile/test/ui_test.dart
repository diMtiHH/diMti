import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universe_lab/main.dart';

Future<void> waitForStatus(WidgetTester tester, String status) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  await tester.runAsync(() async {
    while (find.text(status).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  });
  expect(find.text(status), findsOneWidget);
}

void main() {
  testWidgets(
    'unavailable iOS bundle leaves input disabled and language switch usable',
    (tester) async {
      await tester.pumpWidget(const UniverseLab());
      await waitForStatus(tester, 'Модель недоступна. Проверка заблокирована.');
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      await tester.tap(find.text('English'));
      await tester.pump();
      expect(find.text('Model unavailable. Check blocked.'), findsOneWidget);
    },
  );

  testWidgets(
    'real question entry clears text and returns a closed outcome in both languages',
    (tester) async {
      final assets = Directory('assets/stage2').absolute;
      await tester.pumpWidget(
        MaterialApp(home: LabPage(modelDirectory: assets)),
      );
      await waitForStatus(tester, 'Модель готова');
      await tester.tap(find.text('Вставить пример'));
      await tester.tap(find.text('Проверить на устройстве'));
      await waitForStatus(tester, 'Проверка завершена. Допуск закрыт.');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.enterText(
        find.byType(TextField),
        'Should I not take my life-saving medicine?',
      );
      await tester.tap(find.text('Check on device'));
      await waitForStatus(tester, 'The model flagged possible risk.');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    },
  );

  testWidgets(
    'only a completed benchmark can copy a report without question text',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? clipboard;
      var clipboardFails = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          if (clipboardFails)
            throw PlatformException(code: 'clipboard_unavailable');
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LabPage(modelDirectory: Directory('assets/stage2').absolute),
        ),
      );
      await waitForStatus(tester, 'Модель готова');
      expect(find.text('Копировать отчёт'), findsNothing);
      const draft = 'PRIVATE_TEST_DRAFT_DO_NOT_EXPORT';
      await tester.enterText(find.byType(TextField), draft);
      await tester.tap(find.text('Замер на 20 примерах'));
      await waitForStatus(tester, 'Копировать отчёт');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(clipboard, isNull); // No automatic clipboard writes.
      await tester.tap(find.text('Копировать отчёт'));
      await tester.pumpAndSettle();
      expect(find.text('Не удалось скопировать отчёт.'), findsOneWidget);
      expect(clipboard, isNull);
      clipboardFails = false;
      await tester.tap(find.text('Копировать отчёт'));
      await tester.pumpAndSettle();
      final data = jsonDecode(clipboard!) as Map;
      expect(data['checks'], 20);
      expect(data['admission'], 'closed');
      expect(data['build_mode'], 'debug');
      expect(data['load_ms'], greaterThan(0));
      expect(data['max_sampled_rss_mib'], greaterThan(0));
      expect(clipboard, isNot(contains(draft)));
      expect(
        clipboard,
        isNot(contains(Directory('assets/stage2').absolute.path)),
      );
      final firstCopy = clipboard;
      await tester.tap(find.text('English'));
      await tester.pump();
      await tester.tap(find.text('Copy report'));
      await tester.pumpAndSettle();
      expect(clipboard, firstCopy);

      // A new, interrupted run must not leave the previous report exportable.
      await tester.tap(find.text('Measure 20 checks'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await waitForStatus(tester, 'Check on device');
      expect(find.text('Copy report'), findsNothing);
      expect(find.textContaining('Checks: 20'), findsNothing);
      expect(
        clipboard,
        firstCopy,
      ); // Backgrounding does not rewrite the clipboard.
    },
  );
}
