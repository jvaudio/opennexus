import Testing

/// The hosted suites, one at a time: the timing budgets (A4) are measured with nothing else
/// on the main actor, and the suites share the app's window and library. Swift Testing would
/// otherwise run them side by side. LiveTests stay apart: `scripts/test-ipad.sh` runs them
/// one by one.
@MainActor
@Suite(.serialized) struct HostedTests {}
