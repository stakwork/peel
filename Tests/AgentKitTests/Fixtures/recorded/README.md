# Recorded streams

Real streamed replies from the model providers, one text reply and one tool
call each, as `<provider>-text.sse` and `<provider>-tool.sse`. When one is
here, `StreamCaseTests` (and the provider tests that serve a stream) decode
it instead of the hand-written stream in `Fixtures/`. Tests only read these
files; no test calls a provider or uses a key.

Tom records them by hand, one provider at a time, with his own key:

```sh
PEEL_AGENT_PROVIDER=anthropic  PEEL_AGENT_API_KEY=… scripts/record-agent-fixtures.sh
PEEL_AGENT_PROVIDER=openai     PEEL_AGENT_API_KEY=… scripts/record-agent-fixtures.sh
PEEL_AGENT_PROVIDER=openrouter PEEL_AGENT_API_KEY=… scripts/record-agent-fixtures.sh
swift test --filter StreamCaseTests
```

Files here must never contain a key, a request, headers, or ids that name
an account or a request. The script writes response bodies only, replaces
ids with placeholders, and refuses to write anything holding the key, its
last six characters, or an `sk-` style token. Read a file before committing
it.
