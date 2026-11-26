import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:universe_lab/main.dart' as app;

Future<void> waitForText(WidgetTester tester, String text) async {
  final watch = Stopwatch()..start();
  final expected = find.text(text);
  while (expected.evaluate().isEmpty &&
      watch.elapsed < const Duration(minutes: 2)) {
    expect(
      find.text('Модель недоступна. Проверка заблокирована.'),
      findsNothing,
    );
    await tester.pump(const Duration(milliseconds: 200));
  }
  expect(expected, findsOneWidget);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('iOS Runner loads the bundled model and checks RU and EN', (
    tester,
  ) async {
    app.main();
    await tester.pump();
    await waitForText(tester, 'Модель готова');
    await tester.tap(find.text('Вставить пример'));
    await tester.tap(find.text('Проверить на устройстве'));
    await waitForText(tester, 'Проверка завершена. Допуск закрыт.');
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    // Built-in bilingual measurement checks both risk and held outcomes.
    final benchmark = find.text('Measure 20 checks');
    await tester.ensureVisible(benchmark);
    await tester.tap(benchmark);
    final result = find.textContaining('Checks: 20');
    final watch = Stopwatch()..start();
    while (result.evaluate().isEmpty &&
        watch.elapsed < const Duration(minutes: 2)) {
      expect(find.text('Could not complete the check.'), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(result, findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
