#!/bin/bash
# Mount this project's DAOS containers on the login node you are on, for browsing and
# copying data out. Nothing to do with the compute-node mounts multisim.pbs makes --
# those are per-job and live at /tmp/<pool>/<cont>.
#
# The mounting itself is daos_login_mount in job/daos.sh, so that tools which need a
# login mount of their own (postprocessing.sh --daos) get the same preflight, module
# environment and settle-wait rather than a second copy of them.
#
# Usage: daos-mount-login.sh [container ...]     (default: Outputs Checkpoints Derivatives)
#        daos-umount-login.sh                    to tear them down

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../job" && pwd)/daos.sh"

conts=("$@")
(( ${#conts[@]} )) || conts=("$DAOS_CONT_OUTPUTS" "$DAOS_CONT_CHECKPOINTS" "$DAOS_CONT_RESOURCES")

daos_login_mount "${conts[@]}"

# mount | grep dfuse | grep $USER
