#!/usr/bin/env bash
# gate-instrument: none - a development convenience that prints this machine's LAN address; it checks nothing.
# Print the exact address to type into the app's Server Connection field.
#
#   scripts/dev_lan_address.sh
#
# Run it ON THE MACHINE RUNNING THE SERVER — the Ubuntu VM in README.md §4's
# two-device walkthrough, not your Mac.
#
# **Why this exists (task 11.37, item 5).** The walkthrough used to say: run
# `ip addr show`, pick out "a normal 192.168.x.x on your home network, not a
# 10.211.55.x Parallels-internal one", then `curl` it, then type it into the
# app. Three of those four steps are a person reading output and retyping a
# value, and the picking step is described in prose — which is the defect class
# this task is about. `ip addr show` on a machine running Docker prints half a
# dozen addresses, several of which look plausible and none of which are
# labelled.
#
# **This does the picking by measurement rather than by description.** It finds
# every non-loopback IPv4 address on this host and asks the server for
# `/health` on each one. The address that answers is the answer. That is not a
# judgement anybody has to vouch for — it is a request that either got a reply
# or did not, and if none do, the honest output is that none do.
#
# **Contrast `scripts/verify_source_identity.sh`, which is deliberately NOT
# automated in this way.** That one ends in a verdict about whether this host
# preserves a caller's source address, and its verdict becomes
# `TRITRACK_TRUSTED_PROXIES=peer-verified` — an operator asserting a measured
# property of their own network. A tool that wrote that value on its own would
# be asserting the measurement on their behalf, which is the control, not the
# chore. Reachability has no such property: nothing is being vouched for.
#
# **It still cannot finish the job, and that is not a shortcoming to fix.** The
# destination is a text field on a phone. No script reaches it.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORT="${SERVER_PORT:-}"
if [ -z "$PORT" ] && [ -f .env ]; then
  PORT="$(sed -n 's/^[[:space:]]*SERVER_PORT[[:space:]]*=[[:space:]]*//p' .env | tail -1)"
fi
PORT="${PORT:-8080}"

# `ip -o -4 addr` on Linux, `ifconfig` on macOS. Both are read for addresses
# only; neither verdict below comes from parsing their labels.
addresses() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
  else
    ifconfig 2>/dev/null | awk '/inet /{print $2}'
  fi
}

CANDIDATES="$(addresses | grep -v '^127\.' | sort -u)"
if [ -z "$CANDIDATES" ]; then
  echo "No non-loopback IPv4 address on this host. Is the network up?" >&2
  exit 1
fi

REACHABLE=()
UNREACHABLE=()
for ADDRESS in $CANDIDATES; do
  if curl -fsS --max-time 2 "http://$ADDRESS:$PORT/health" >/dev/null 2>&1; then
    REACHABLE+=("$ADDRESS")
  else
    UNREACHABLE+=("$ADDRESS")
  fi
done

if [ "${#REACHABLE[@]}" -eq 0 ]; then
  cat >&2 <<EOF

The server did not answer /health on any address on this host, on port $PORT.

Addresses tried: ${UNREACHABLE[*]}

The usual cause is that the stack is published on loopback only, which is the
safe default and is deliberate. For the LAN walkthrough you need, in .env:

  SERVER_PUBLISH_ADDRESS=0.0.0.0
  TRITRACK_TRUSTED_PROXIES=peer-verified   # only after your OWN PRESERVED run
                                           # of scripts/verify_source_identity.sh

and the stack brought up with the development overlay:

  . scripts/lib/host_user.sh   # so the sign-in link is readable by you
  docker compose -f docker-compose.yml -f docker-compose.dev-lan.yml up --build -d

See README.md §4. If the server refuses to start, read what it prints — it
refuses on purpose when it cannot tell one caller from another.
EOF
  exit 1
fi

printf '\n\033[1mType this into the app: More \342\206\222 Server Connection\033[0m\n\n'
for ADDRESS in "${REACHABLE[@]}"; do
  # No trailing slash, and this script will never print one. A saved trailing
  # slash produced `//auth/magic-link`, a 404, and a "could not reach the
  # server" message that sent somebody to check a working network — the
  # finding that opened task 11.37. The app now normalises the address anyway,
  # so a slash typed by hand is harmless; this just does not create one.
  printf '  http://%s:%s\n' "$ADDRESS" "$PORT"
done
printf '\n'

if [ "${#REACHABLE[@]}" -gt 1 ]; then
  printf 'More than one address answered. Any of them works from a device that can\n'
  printf 'route to it; on a home network that is normally the 192.168.x.x one.\n\n'
fi

if [ "${#UNREACHABLE[@]}" -gt 0 ]; then
  printf 'Did not answer, listed so a silent omission is not mistaken for a\n'
  printf 'complete list: %s\n\n' "${UNREACHABLE[*]}"
fi

printf 'Verified by asking each address for /health just now. If the phone still\n'
printf 'cannot reach it, the remaining suspects are the phone being on a different\n'
printf 'network, and a release or profile build refusing plain http:// (README.md\n'
printf '\302\247 4, "The trap").\n\n'
