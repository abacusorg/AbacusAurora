#!/bin/bash
# Copy derivative sets from flare into the DAOS Derivatives container, which
# ABACUS_DAOS_DERIVATIVES=on then points the sims at.
#
# The copy goes through the DFS API rather than a dfuse mount, so no mount is needed
# and none is made.
#
# Usage: daos-stage-derivatives.sh <CPD> [CPD ...]
#   e.g. daos-stage-derivatives.sh 1029 1125
# With no arguments, the CPDs available on flare are listed.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

if (( ! $# )); then
    echo "usage: daos-stage-derivatives.sh <CPD> [CPD ...]" >&2
    echo "CPDs available in $FLARE_DERIVATIVES as deriv32_<CPD>_8_2_8:" >&2
    (cd "$FLARE_DERIVATIVES" && ls -d deriv32_*_8_2_8/ 2>/dev/null \
        | sed -E 's|^deriv32_(.*)_8_2_8/$|\1|' | sort -n | paste -sd' ') >&2 || true
    exit 2
fi

daos_preflight || exit 1
daos_require_containers "$DAOS_CONT_DERIVATIVES" || exit 1

for cpd; do
    [[ $cpd =~ ^[0-9]+$ ]] || { echo "error: '$cpd' is not a CPD" >&2; exit 1; }
    set_name=deriv32_${cpd}_8_2_8
    src=$FLARE_DERIVATIVES/$set_name
    dst=daos://$DAOS_POOL/$DAOS_CONT_DERIVATIVES
    [[ -d $src ]] || { echo "error: no derivative set $src" >&2; exit 1; }

    echo "Staging $src ($(du -sh "$src" | cut -f1)) -> $dst/$set_name"
    daos_cli daos filesystem copy --src "$src" --dst "$dst"
done
