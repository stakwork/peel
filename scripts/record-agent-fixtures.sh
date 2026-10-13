#!/bin/bash
# Records one provider's real streams for the agent's decoder tests: a
# streamed text reply and a streamed tool call, each written raw to
# Tests/AgentKitTests/Fixtures/recorded/<provider>-text.sse and
# <provider>-tool.sse, which the tests then use instead of the hand-written
# ones. Run by hand only, with your own key; no test runs it, and tests
# never use a key or the network (docs/testing.md, "Recorded streams").
#
#   PEEL_AGENT_PROVIDER=anthropic|openai|openrouter PEEL_AGENT_API_KEY=… \
#     scripts/record-agent-fixtures.sh
#   optional: PEEL_AGENT_MODEL=<id> (default below, copied from the picker's
#   recommended model in AgentProvider.models), PEEL_AGENT_MAX_TOKENS=<n>
#
# Two small requests, shaped by hand as Peel sends them: keep them in step
# with AnthropicProvider.body and OpenAICompatibleProvider.body. Only
# response bodies are written, never headers, the request or the key. Ids that name the account or the request
# are replaced with fixed placeholders. If what would be written holds the
# key, its last six characters or anything shaped like an `sk-` key,
# nothing is written. The key reaches curl on stdin, never on its command
# line.
set -euo pipefail

die() { echo "record-agent-fixtures: $*" >&2; exit 1; }

provider="${PEEL_AGENT_PROVIDER:-}"
key="${PEEL_AGENT_API_KEY:-}"
case "$provider" in
    anthropic)  url=https://api.anthropic.com/v1/messages;         model=claude-sonnet-5-5;           tokens=256 ;;
    openai)     url=https://api.openai.com/v1/chat/completions;    model=gpt-5;                       tokens=1024 ;;
    openrouter) url=https://openrouter.ai/api/v1/chat/completions; model=anthropic/claude-sonnet-5.5; tokens=256 ;;
    *) die "set PEEL_AGENT_PROVIDER to anthropic, openai or openrouter" ;;
esac
[ -n "$key" ] || die "set PEEL_AGENT_API_KEY to your $provider key"
[[ "$key" =~ ^[A-Za-z0-9._-]{20,}$ ]] || die "PEEL_AGENT_API_KEY does not look like an API key"
[ -t 0 ] || die "run this by hand in a terminal"
model="${PEEL_AGENT_MODEL:-$model}"
# A reasoning model's thinking counts against the cap, so OpenAI's default
# is larger; a reply cut at the cap is refused below.
tokens="${PEEL_AGENT_MAX_TOKENS:-$tokens}"
[[ "$model" =~ ^[A-Za-z0-9._/:-]+$ ]] || die "PEEL_AGENT_MODEL has unexpected characters"
[[ "$tokens" =~ ^[0-9]+$ ]] || die "PEEL_AGENT_MAX_TOKENS must be a number"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/Tests/AgentKitTests/Fixtures/recorded"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Long enough to arrive in several pieces; one argument, so its JSON
# arrives in pieces too.
text_prompt='Count from 1 to 10, separated by spaces.'
tool_prompt='Call the secret_word tool with language set to English.'
tool_name=secret_word
tool_description="Returns today's secret word in a language."
tool_schema='{"type":"object","properties":{"language":{"type":"string"}},"required":["language"]}'

# The request bodies, as Peel's providers build them.
body() { # <kind>
    local prompt="$text_prompt" tools=''
    [ "$1" = tool ] && prompt="$tool_prompt"
    if [ "$provider" = anthropic ]; then
        [ "$1" = tool ] && tools=',"tools":[{"name":"'"$tool_name"'","description":"'"$tool_description"'","input_schema":'"$tool_schema"',"eager_input_streaming":true}]'
        printf '{"model":"%s","max_tokens":%s,"stream":true,"cache_control":{"type":"ephemeral"},"messages":[{"role":"user","content":[{"type":"text","text":"%s"}]}]%s}' \
            "$model" "$tokens" "$prompt" "$tools"
    else
        local field=max_completion_tokens
        [ "$provider" = openrouter ] && field=max_tokens
        [ "$1" = tool ] && tools=',"tools":[{"type":"function","function":{"name":"'"$tool_name"'","description":"'"$tool_description"'","parameters":'"$tool_schema"'}}]'
        printf '{"model":"%s","%s":%s,"stream":true,"stream_options":{"include_usage":true},"messages":[{"role":"user","content":"%s"}]%s}' \
            "$model" "$field" "$tokens" "$prompt" "$tools"
    fi
}

# Headers go to curl as a config on stdin, so the key is in no process's
# arguments. printf is a shell builtin.
headers() {
    case "$provider" in
        anthropic)  printf 'header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n' "$key" ;;
        openai)     printf 'header = "authorization: Bearer %s"\n' "$key" ;;
        openrouter) printf 'header = "authorization: Bearer %s"\nheader = "HTTP-Referer: https://peel.chat"\nheader = "X-Title: Peel"\n' "$key" ;;
    esac
}

# Replaces ids with placeholders (each distinct value its own, its prefix
# kept: msg_01, chatcmpl-01), checks the result holds no key and ended
# as asked, and writes it. Reads the key from the environment.
scrub='
import os, re, sys
raw, dest, provider, kind = sys.argv[1:5]
key = os.environ["PEEL_AGENT_API_KEY"]
text = open(raw, encoding="utf-8").read()
names = r"id|request_id|system_fingerprint|organization|org_id|organization_id|user|user_id"
seen = {}
def placeholder(match):
    name, value = match.groups()
    if value not in seen:
        prefix = re.match(r"[A-Za-z]+[_-]", value)
        seen[value] = (prefix.group(0) if prefix else "id-") + "%02d" % (len(seen) + 1)
    return name + seen[value] + "\""
text = re.sub(r"(\"(?:" + names + r")\"\s*:\s*\")([^\"\\]*)\"", placeholder, text)
if key in text or key[-6:] in text or re.search(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_*-]{6,}", text):
    sys.exit("holds the key or something shaped like one")
ends = {
    ("anthropic", "text"): "\"stop_reason\":\"end_turn\"", ("anthropic", "tool"): "\"stop_reason\":\"tool_use\"",
    ("openai", "text"): "\"finish_reason\":\"stop\"", ("openai", "tool"): "\"finish_reason\":\"tool_calls\"",
}[("anthropic" if provider == "anthropic" else "openai", kind)]
if not re.search(ends.replace(":", r"\s*:\s*"), text):
    sys.exit("did not end with " + ends + " (cut at max tokens? raise PEEL_AGENT_MAX_TOKENS)")
open(dest, "w", encoding="utf-8").write(text)
'

for kind in text tool; do
    body "$kind" > "$work/$kind.json"
    status=$(headers | curl --config - --silent --show-error --proto =https --max-time 120 --no-buffer \
        --header 'content-type: application/json' --data-binary "@$work/$kind.json" \
        --output "$work/$kind.raw" --write-out '%{http_code}' "$url") || die "$kind: the request failed"
    # An error body may echo the key, masked or not: never printed or kept.
    [ "$status" = 200 ] || die "$kind: $provider answered HTTP $status; nothing written"
    python3 -I -c "$scrub" "$work/$kind.raw" "$work/$provider-$kind.sse" "$provider" "$kind" ||
        die "$kind: refused; nothing written"
done

mkdir -p "$out"
for kind in text tool; do
    mv "$work/$provider-$kind.sse" "$out/$provider-$kind.sse"
    echo "wrote Tests/AgentKitTests/Fixtures/recorded/$provider-$kind.sse ($(wc -c < "$out/$provider-$kind.sse" | tr -d ' ') bytes)"
done
echo "Check them with: swift test --filter StreamCaseTests"
