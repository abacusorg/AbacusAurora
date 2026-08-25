#!/bin/bash
# Tear down the login-node mounts made by daos-mount-login.sh.  The unmounting itself
# is daos_login_unmount in job/daos.sh.
#
# Usage: daos-umount-login.sh [container ...]    (default: Outputs Checkpoints Derivatives)

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

conts=("$@")
(( ${#conts[@]} )) || conts=("$DAOS_CONT_OUTPUTS" "$DAOS_CONT_CHECKPOINTS" "$DAOS_CONT_RESOURCES")

daos_login_unmount "${conts[@]}"

mount | grep dfuse | grep $USER || true
