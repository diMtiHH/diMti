import 'engine.dart';
import 'release_features.dart';
import 'session_core.dart';
import 'world_catalog.dart';

/// The research model remains frozen. Personal testing opens only an exact
/// catalog phrase that the intact model ALSO classifies ALLOW at its threshold.
class PersonalTestGate {
  final Future<Reading> Function(String, String) inspect;
  final bool enabled;
  const PersonalTestGate(this.inspect, {this.enabled = personalTestBuild});
  Future<Admission> call(String text, String language) async {
    if (language != 'ru' && language != 'en') return Admission.unavailable;
    try {
      final result = await inspect(text, language);
      if (result.outcome == Outcome.error) return Admission.unavailable;
      if (result.outcome == Outcome.risk) return Admission.risk;
      if (personalTestBuild &&
          enabled &&
          result.reason == 'admission_disabled' &&
          matchWorldTopic(text, language) != null)
        return Admission.allowed;
      return Admission.held;
    } catch (_) {
      return Admission.unavailable;
    }
  }
}
