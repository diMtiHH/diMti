import 'engine.dart';
import 'session_core.dart';

/// Production binding for the accepted stage 1 policy: NO real question may
/// reach the RNG. Admission.allowed is intentionally unreachable here.
class ClosedModelGate {
  final Future<Reading> Function(String, String) inspect;
  const ClosedModelGate(this.inspect);

  Future<Admission> call(String text, String language) async {
    if (language != 'ru' && language != 'en') return Admission.unavailable;
    try {
      final reading = await inspect(text, language);
      return switch (reading.outcome) {
        Outcome.risk => Admission.risk,
        Outcome.held => Admission.held,
        Outcome.error => Admission.unavailable,
      };
    } catch (_) {
      return Admission.unavailable;
    }
  }
}
