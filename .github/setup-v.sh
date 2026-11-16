#!/bin/sh
# Build the V commit pinned in .v-version and put it on PATH.
#
# vlang/setup-v builds a pin with V's own `make`, which bootstraps from
# whatever vlang/vc publishes today, so a pin that built yesterday can
# stop building with no change on our side. Since 2026-11-13 vc's v.c
# includes headers by V's CI checkout path (#include
# "/home/runner/work/v/v/vlib/os/fd_poll.h", vlang/v#32312) and every
# pin dies in `make`. So build the pin from the vc snapshot published
# just before it: the one V master itself bootstrapped from that day,
# which keeps the pin reproducible. Header paths are rewritten to this
# checkout in case a later pin's snapshot carries the CI paths.
#
# usage: setup-v.sh [dir]   (dir defaults to $RUNNER_TEMP/v)
set -eu

pin=$(tr -d '[:space:]' < "$(dirname "$0")/../.v-version")
vroot=${1:-${RUNNER_TEMP:-/tmp}/v}

git init --quiet "$vroot"
git -C "$vroot" fetch --quiet --depth 1 https://github.com/vlang/v "$pin"
git -C "$vroot" checkout --quiet FETCH_HEAD
pin_date=$(git -C "$vroot" log -1 --format=%cI)

git clone --quiet --filter=tree:0 --no-checkout https://github.com/vlang/vc "$vroot/vc"
vc=$(git -C "$vroot/vc" rev-list -1 --before="$pin_date" HEAD)
git -C "$vroot/vc" checkout --quiet "$vc"
echo "V $pin from vc $vc ($(git -C "$vroot/vc" log -1 --format=%s | cut -c1-80))"
for c in "$vroot/vc/v.c" "$vroot/vc/v_win.c"; do
	if [ -f "$c" ]; then
		perl -pi -e 's{^#include "/home/runner/work/v/v/}{#include "'"$vroot"'/}' "$c"
	fi
done

# fetch tcc as `make` would, then build from the vc checked out above
make -C "$vroot" latest_tcc
make -C "$vroot" local=1

if [ -n "${GITHUB_PATH:-}" ]; then
	echo "$vroot" >> "$GITHUB_PATH"
fi
"$vroot/v" version
