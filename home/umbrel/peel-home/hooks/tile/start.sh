#!/bin/sh
# The tile's server. It answers only umbreld's app gateway, the one path with
# Umbrel's login in front of it: umbreld runs on the host, so its requests come
# from this network's gateway, and every other app's container on Umbrel's
# network comes from an address of its own, which gets a 403. (umbreld adds
# no header another container couldn't send too.)
set -eu
TILE_PROXY=$(ip route show default | awk '{ print $3; exit }')
[ -n "$TILE_PROXY" ] || { echo "tile: no default gateway to allow" >&2; exit 1; }
export TILE_PROXY
printf 'A:%s\nD:*\n' "$TILE_PROXY" >/tmp/httpd.conf
# IPv4 only: on IPv6's socket, httpd sees [::ffff:a.b.c.d], which its rules miss.
exec httpd -f -p 0.0.0.0:8080 -h /www -c /tmp/httpd.conf
