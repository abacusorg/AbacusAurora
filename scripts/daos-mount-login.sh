#!/bin/bash
# Mount this project's DAOS containers on the login node you are on, for browsing and
# copying data out. Nothing to do with the compute-node mounts multisim.pbs makes --
# those are per-job and live at /tmp/<pool>/<cont>.
#
# Usage: daos-mount-login.sh [container ...]     (default: Outputs Checkpoints Derivatives)
#        daos-umount-login.sh                    to tear them down

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

conts=("$@")
(( ${#conts[@]} )) || conts=("$DAOS_CONT_OUTPUTS" "$DAOS_CONT_CHECKPOINTS" "$DAOS_CONT_DERIVATIVES")

daos_preflight || exit 1

for cont in "${conts[@]}"; do
    mnt=$(daos_login_mountpoint "$cont")
    if mountpoint -q "$mnt"; then
        echo "already mounted: $mnt"
        continue
    fi
    if ! daos_have_container "$cont"; then
        echo "error: no container $DAOS_POOL:$cont" >&2
        exit 1
    fi

    mkdir -p "$mnt"
    daos_cli start-dfuse.sh -m "$mnt" --pool "$DAOS_POOL" --cont "$cont"

    # dfuse daemonizes, so the mount appears a moment after the launcher returns.
    for _ in $(seq 20); do
        mountpoint -q "$mnt" && break
        sleep 0.5
    done
    if ! mountpoint -q "$mnt"; then
        echo "error: dfuse did not mount $mnt" >&2
        exit 1
    fi
    echo "mounted $DAOS_POOL:$cont at $mnt"
done

# mount | grep dfuse | grep $USER
