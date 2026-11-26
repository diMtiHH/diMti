@import XCTest;
@import integration_test;

// The SDK maps each actual Dart result to an XCTest case. No VM-service
// discovery or host-side Flutter test driver is involved in this path.
INTEGRATION_TEST_IOS_RUNNER(UniverseIntegrationTests)
