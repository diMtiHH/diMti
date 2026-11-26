// One native XCTest host runs every iOS scenario without reinstalling the app.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'ios_model_test.dart' as model;
import 'ios_session_test.dart' as session;
import 'ios_voice_test.dart' as voice;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // XCTest may enable platform accessibility after the first test starts.
  // Establish that platform-owned handle before testWidgets records its
  // baseline. Semantics stay enabled and per-test leak checks stay active.
  setUp(() {
    binding.platformDispatcher.semanticsEnabledTestValue = true;
  });
  tearDown(binding.platformDispatcher.clearSemanticsEnabledTestValue);

  session.main();
  voice.main();
  model.main();
}
