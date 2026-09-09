#!/bin/bash
# Patched copy of ALCF's /soft/daos/bin/launch-dfuse.sh (a symlink to
# launch-dfuse_user_clush.sh; md5 42ef04e2, 2026-04-21).  The mount recipe is theirs
# verbatim, so `diff` this against /soft/daos/bin/launch-dfuse.sh after an image roll
# to see whether the fork has drifted.  Only LIBFABRIC_LIBDIR and its two uses, the
# argument guards and set -euo pipefail are ours.
#
# The fork exists because this image leaves libfabric out of the linker cache:
# /etc/ld.so.conf.d/libfabric.conf names libfabric.so.1 itself where ldconfig will
# only read a directory, so ldconfig skips it.  Everything still works wherever a
# module has put libfabric on LD_LIBRARY_PATH, but clush reaches the other nodes over
# ssh, which strips LD_* and runs no rc files, so dfuse there cannot dlopen mercury's
# OFI plugin.  Every node past the first then fails to mount with DER_HG(-1020)
# 'Transport layer mercury error' -- an error that never mentions libfabric.  Retire
# the fork once ALCF ships a libfabric.conf that ldconfig accepts.
#
# Usage: launch-dfuse.sh <pool>:<container> [<pool>:<container> ...]
#
# Run on the head node of an allocation, by hand or from a job; job/daos.sh calls it
# from daos_mount.

set -euo pipefail

# Needed twice over: once exported, for the head-node dfuse below, and again on the
# clush line, because ssh will not carry it across.
LIBFABRIC_LIBDIR=${LIBFABRIC_LIBDIR:-/opt/cray/libfabric/2.3.1/lib64}

# start-dfuse.sh stays ALCF's: it carries their FI_CXI_* tuning and the agent socket.
BINDIR=/soft/daos/bin

if (( $# == 0 )); then
    echo "usage: ${0##*/} <pool>:<container> [<pool>:<container> ...]" >&2
    exit 2
fi
: "${PBS_NODEFILE:?not set -- run this on the head node of an allocation}"
if [[ ! -e $LIBFABRIC_LIBDIR/libfabric.so.1 ]]; then
    echo "${0##*/}: no libfabric.so.1 under $LIBFABRIC_LIBDIR." >&2
    echo "  The image has probably rolled; set LIBFABRIC_LIBDIR to the new path." >&2
    exit 1
fi
export LD_LIBRARY_PATH=$LIBFABRIC_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

module use /soft/modulefiles
module load mpifileutils

for mnt in "$@";
do

IFS=':' read -ra ids <<< ${mnt}

mountpt="/tmp/${ids[0]}/${ids[1]}"
NNODES=$(cat $PBS_NODEFILE | wc -l)

# create mountpoint
mpiexec --no-vni -np $NNODES -ppn 1 mkdir -p ${mountpt}

# mount dfuse on head node
hfile=$(mktemp /tmp/${USER}_handles.XXXXX)
dfuse --pool ${ids[0]} --cont ${ids[1]} -m ${mountpt} --dump-handles ${hfile} --disable-caching --disable-wb-cache

# copy handles to other nodes
mpiexec --no-vni -np $(( NNODES * 2 )) -ppn 2 dbcast ${hfile} ${hfile} > /dev/null

if [ $NNODES -gt 1 ];
then

  # start dfuse on all other nodes
  tail -n +2 $PBS_NODEFILE > /tmp/${USER}_node_list
  clush --hostfile=/tmp/${USER}_node_list -f 208 -o "-o LogLevel=QUIET -o StrictHostKeyChecking=no" \
     env LD_LIBRARY_PATH=${LIBFABRIC_LIBDIR} \
     ${BINDIR}/start-dfuse.sh oneScratch \
     --pool ${ids[0]} \
     --cont ${ids[1]} \
     -m ${mountpt} \
     --read-handles ${hfile} \
     --disable-caching \
     --disable-wb-cache
fi

done

