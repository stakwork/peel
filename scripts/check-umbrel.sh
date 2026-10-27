#!/bin/sh
# The Umbrel app (home/umbrel/, published as its own repo) carries copies of
# home/'s files and writes out home/'s image pins: fails if either has
# drifted from home/.
#   scripts/check-umbrel.sh
set -eu
cd "$(dirname "$0")/.."
app=home/umbrel/peel-home
failed=

for f in docker-compose.yml setup.sh gate.sh Caddyfile; do
    if ! cmp -s "home/$f" "$app/hooks/home/$f"; then
        echo "check-umbrel: $app/hooks/home/$f is not home/$f (cp home/$f $app/hooks/home/)"
        failed=1
    fi
done

# FILE SERVICE: the service's `image:`, without a ${VAR:-…} around it.
image_of() {
    awk -v want="$2" '
        /^  [a-z_]+:/ { service = $1; sub(":", "", service) }
        service == want && /^    image:/ { sub(/^    image: */, ""); print; exit }
    ' "$1" | sed 's/^\${[A-Z_]*:-\(.*\)}$/\1/'
}
for service in $(sed -n 's/^      service: *//p' "$app/docker-compose.yml"); do
    home_image=$(image_of home/docker-compose.yml "$service")
    app_image=$(image_of "$app/docker-compose.yml" "$service")
    if [ -z "$home_image" ] || [ "$home_image" != "$app_image" ]; then
        echo "check-umbrel: $service's image is ${app_image:-missing} in $app/docker-compose.yml, ${home_image:-missing} in home/"
        failed=1
    fi
done

[ -z "$failed" ] || exit 1
echo "check-umbrel: the Umbrel app matches home/"
