#!/bin/bash
# Copy the shared, precomputed inputs from flare into the DAOS Resources container,
# which ABACUS_DAOS_RESOURCES=on then points the sims at.  The container mirrors the
# flare layout, so only the prefix differs between the two backends:
#
#   Resources/Derivatives/deriv32_<CPD>_8_2_8/
#   Resources/Wisdom/fftw_cpd<CPD>_zranks<N>.wisdom
#
# Wisdom is a few hundred KB in total and is keyed by (CPD, NumZRanks), so the whole
# directory is synced every time rather than selected per CPD.  The derivatives are
# ~85 TB across all CPDs, hence the explicit CPD arguments.
#
# The copy goes through the DFS API rather than a dfuse mount, so no mount is needed
# and none is made.  The container and its two top-level directories are created by
# hand, once -- see the README.
#
# Usage: daos-stage-resources.sh <CPD> [CPD ...]
#   e.g. daos-stage-resources.sh 1029 1125
# With no arguments, the CPDs available on flare are listed.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

FLARE_DERIVATIVES=$FLARE_RESOURCES/Derivatives
FLARE_WISDOM=$FLARE_RESOURCES/Wisdom

if (( ! $# )); then
    echo "usage: daos-stage-resources.sh <CPD> [CPD ...]" >&2
    echo "CPDs available in $FLARE_DERIVATIVES as deriv32_<CPD>_8_2_8:" >&2
    (cd "$FLARE_DERIVATIVES" && ls -d deriv32_*_8_2_8/ 2>/dev/null \
        | sed -E 's|^deriv32_(.*)_8_2_8/$|\1|' | sort -n | paste -sd' ') >&2 || true
    exit 2
fi

daos_preflight || exit 1
daos_require_containers "$DAOS_CONT_RESOURCES" || exit 1

dst_root=daos://$DAOS_POOL/$DAOS_CONT_RESOURCES

# Wisdom first: it is small, and a derivative set is useless without the matching
# (CPD, NumZRanks) plan.
echo "Staging $FLARE_WISDOM ($(du -sh "$FLARE_WISDOM" | cut -f1)) -> $dst_root/Wisdom"
daos_cli daos filesystem copy --src "$FLARE_WISDOM" --dst "$dst_root"

for cpd; do
    [[ $cpd =~ ^[0-9]+$ ]] || { echo "error: '$cpd' is not a CPD" >&2; exit 1; }
    set_name=deriv32_${cpd}_8_2_8
    src=$FLARE_DERIVATIVES/$set_name
    [[ -d $src ]] || { echo "error: no derivative set $src" >&2; exit 1; }

    echo "Staging $src ($(du -sh "$src" | cut -f1)) -> $dst_root/Derivatives/$set_name"
    daos_cli daos filesystem copy --src "$src" --dst "$dst_root/Derivatives"
done
