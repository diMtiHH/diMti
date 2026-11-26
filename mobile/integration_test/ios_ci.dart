// One native XCTest host runs every iOS scenario without reinstalling the app.
import 'ios_model_test.dart' as model;
import 'ios_session_test.dart' as session;

void main() {
  session.main();
  model.main();
}
