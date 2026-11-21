#!/bin/sh
set -eu

expected_ack='cloudflare-public-http-egress-v1-verified'

if [ -z "${BROWSER_RENDERER_TOKEN:-}" ]; then
  printf '%s\n' 'BROWSER_RENDERER_TOKEN is required.' >&2
  exit 78
fi

if [ "${WATCHBROWSER_CHROMIUM_EGRESS_ACK:-disabled}" = "$expected_ack" ]; then
  export BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED=true
else
  export BROWSER_RENDERER_CHROMIUM_EGRESS_ISOLATED=false
fi

exec "$@"
