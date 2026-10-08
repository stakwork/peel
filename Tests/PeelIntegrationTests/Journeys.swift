import Testing

/// Every journey, one at a time: they share one stack, and the bank
/// restarts its mixer once (`Bank`). Each journey makes its own accounts.
@Suite(
    .serialized,
    .enabled(if: integrationEnabled, "integration journeys run with PEEL_INTEGRATION=1"),
    .timeLimit(.minutes(10))
)
struct Journeys {}
