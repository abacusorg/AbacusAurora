#!/bin/bash
# Tear down the login-node mounts made by daos-mount-login.sh.
#
# Usage: daos-umount-login.sh [container ...]    (default: Outputs Checkpoints Derivatives)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

conts=("$@")
(( ${#conts[@]} )) || conts=("$DAOS_CONT_OUTPUTS" "$DAOS_CONT_CHECKPOINTS" "$DAOS_CONT_RESOURCES")

for cont in "${conts[@]}"; do
    mnt=$(daos_login_mountpoint "$cont")
    if mountpoint -q "$mnt"; then
        fusermount3 -u "$mnt"
        echo "unmounted $mnt"
    else
        echo "not mounted: $mnt"
    fi
    rmdir "$mnt" 2>/dev/null || true
done

mount | grep dfuse | grep $USER || true
