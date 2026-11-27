/// Personal installation requested by the founder, 27 November 2026.
/// Public releases must use --dart-define=UNIVERSE_PERSONAL_TEST=false.
const personalTestBuild = bool.fromEnvironment(
  'UNIVERSE_PERSONAL_TEST',
  defaultValue: true,
);

/// No statistics service is contacted unless an HTTPS endpoint is configured.
const worldApiEndpoint = String.fromEnvironment('UNIVERSE_WORLD_API');
