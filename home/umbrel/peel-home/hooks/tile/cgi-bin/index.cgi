#!/bin/sh
# Peel Home's page on Umbrel (the tile in ../../../docker-compose.yml): where
# Peel Home is, and the two things to do about it, Send back and Cancel. It
# runs as its own user and sees only data/page, where setup's relay
# (setup.sh) writes `setup.sh status` and takes one request at a time. Behind
# Umbrel's login, which matters: during a send-back it shows the link that
# hands Peel Home over. busybox httpd serves it for "/" (there is no index.html).
set -uf
page=/data/page

# Only umbreld's gateway, the logged-in path (start.sh, which also tells
# httpd so). Anyone else gets nothing, the link least of all.
if [ -z "${TILE_PROXY:-}" ] || [ "${REMOTE_ADDR:-}" != "$TILE_PROXY" ]; then
    printf 'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'
    exit 0
fi

# A form: hand it to setup, then back to the page, so a reload doesn't post it
# again. Only with the token the page carries, so another site's page can't
# post it. setup drops it if the page showed an older state than setup's.
if [ "${REQUEST_METHOD:-GET}" = POST ]; then
    action= token= shown=
    for pair in $(head -c "${CONTENT_LENGTH:-0}" | tr '&' ' '); do
        case $pair in action=*) action=${pair#action=} ;; token=*) token=${pair#token=} ;; state=*) shown=${pair#state=} ;; esac
    done
    case $action in send-back | cancel | keep) ;; *) action= ;; esac
    case $shown in '' | *[!0-9]*) action= ;; esac
    if [ -n "$action" ] && [ -n "${TILE_TOKEN:-}" ] && [ "$token" = "$TILE_TOKEN" ]; then
        printf '%s %s\n' "$action" "$shown" >"$page/ask.tmp" && mv "$page/ask.tmp" "$page/ask"
    fi
    printf 'HTTP/1.1 303 See Other\r\nLocation: /\r\nContent-Length: 0\r\n\r\n'
    exit 0
fi

# setup's relay writes it every 2 s: an older one means setup isn't running.
status= where=down link=
if [ -f "$page/status" ] && [ $(($(date +%s) - $(stat -c %Y "$page/status"))) -le 10 ]; then
    status=$(cat "$page/status")
    where=${status%% *}
    case $status in *" "*) link=${status#* } ;; esac
fi
# What a form says it was shown for (setup compares it with its own).
shown_for=$(printf '%s' "$status" | cksum | cut -d' ' -f1)

open_button() {
    printf '<p><a class="button primary" href="%s">Open in Peel</a></p>\n' \
        "$(printf '%s' "$link" | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')"
}
# form ACTION LABEL [CONFIRM]: a button that posts ACTION, after CONFIRM's
# question, which holds the page's reload while it is open. The token is hex
# and shown_for a number: neither needs escaping.
form() {
    ask=
    [ -n "${3:-}" ] && ask=" onsubmit=\"stay(); if (confirm('$3')) return true; again(); return false\""
    printf '<form method="post" action="/cgi-bin/index.cgi"%s><input type="hidden" name="token" value="%s"><input type="hidden" name="state" value="%s"><input type="hidden" name="action" value="%s"><button class="button">%s</button></form>\n' \
        "$ask" "${TILE_TOKEN:-}" "$shown_for" "$1" "$2"
}
keep_question="Keep Peel Home here only if the Mac hasn\\'t taken it: if it has, your agent would run in two places."
send_back=$(form send-back "Send Peel Home back" "Your agent stops here until the Mac takes it back. Send it back?")

# How soon the page looks again, while something is changing; 0 when only a
# button here changes it.
refresh=3
case $where in
empty)
    title="Move Peel Home to this Umbrel" refresh=10
    body="<p>On the Mac that runs Peel, click Open in Peel. Peel asks first, then moves your agent here. It is offline for about a minute.</p>
$(open_button)"
    [ -n "$link" ] || where=waiting ;;
failing)
    title="Peel Home's setup hit an error" refresh=30
    body="<p>It tries again by itself. If this stays, Umbrel shows what went wrong in this app's logs (setup).</p>" ;;
incomplete)
    title="A move here didn't finish" refresh=0
    body="<p>A move from the Mac stopped partway, so the Mac still has Peel Home. Clearing what it left here needs a shell on this Umbrel: see “When something is stuck” in Peel's home/README.md.</p>" ;;
starting)
    title="Peel Home is starting here"
    body="<p class=\"muted\">Waiting for strut to answer.</p>
$send_back" ;;
here)
    title="Peel Home is running here" refresh=0
    body="<p>Your agent answers from this Umbrel while the Mac sleeps.</p>
<p class=\"muted\">To run it on the Mac again, send it back, then open its link on the Mac.</p>
$send_back" ;;
sending)
    title="Sending Peel Home back"
    if [ -n "$link" ]; then
        body="<p>On the Mac, click Open in Peel. Peel asks first, then takes your agent back.</p>
$(open_button)
<p class=\"muted\">Changed your mind? Only before the Mac has taken it:</p>
$(form keep "Keep Peel Home here" "$keep_question")"
    else
        body="<p class=\"muted\">Stopping your agent here and packing it.</p>
$(form cancel "Cancel")"
    fi ;;
stopped)
    title="Peel Home is stopped here" refresh=0
    body="<p>A send-back was cut short, so your agent is stopped here: the Mac may have taken it already.</p>
$(form send-back "Send Peel Home back")
$(form keep "Keep Peel Home here" "$keep_question")" ;;
*) where=waiting ;;
esac
# A request on its way to setup shows as a wait, not as the old state's buttons.
[ -f "$page/ask" ] && where=waiting
if [ "$where" = waiting ]; then
    title="Getting ready" refresh=3
    body="<p class=\"muted\">Peel Home's setup is starting.</p>"
fi

printf 'Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
cat <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Peel Home</title>
<style>
  :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --bg: #fff; --line: #d2d2d7; --accent: #0071e3; --on-accent: #fff; }
  @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --muted: #a1a1a6; --bg: #1c1c1e; --line: #3a3a3c; --accent: #0a84ff; } }
  body { margin: 0; background: var(--bg); color: var(--fg); font: 16px/1.5 -apple-system, system-ui, sans-serif; }
  main { max-width: 32rem; margin: 0 auto; padding: 3rem 1.25rem; }
  h1 { font-size: 1.5rem; margin: 0 0 1rem; }
  p { margin: 0 0 1rem; }
  .muted { color: var(--muted); }
  form { margin: 0 0 .75rem; }
  .button { display: inline-block; font: inherit; font-weight: 600; padding: .55rem 1.1rem; border-radius: 8px; border: 1px solid var(--line); background: transparent; color: var(--fg); text-decoration: none; cursor: pointer; }
  .button.primary { background: var(--accent); border-color: var(--accent); color: var(--on-accent); }
</style>
</head>
<body>
<main>
<h1>$title</h1>
$body
</main>
<script>
  // Looks again on its own; stay() holds it while a question is open.
  var timer;
  function again() { if ($refresh) timer = setTimeout(function () { location.replace("/"); }, $refresh * 1000); }
  function stay() { clearTimeout(timer); }
  again();
</script>
</body>
</html>
EOF
