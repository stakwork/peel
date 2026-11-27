# home/'s settings (its README, "Running it"), for Umbrel: its own ports, since
# urbit takes 8090 and mattermost 8443, and the address setup's links name.
# The Mac reaches the box at umbrel.local; the peer port's certificate is for
# the fixed name peel-home whatever the address, so nothing else changes.
export HOME_SETUP_PORT=3781
export HOME_PEER_PORT=3782
export HOME_SETUP_HOST="${DEVICE_DOMAIN_NAME}:${HOME_SETUP_PORT}"
# The tile's forms carry it, so another site's page can't post them.
export APP_PEEL_HOME_TILE_TOKEN="$(derive_entropy "${app_entropy_identifier}-tile-token")"
