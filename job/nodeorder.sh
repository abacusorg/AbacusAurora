#!/bin/bash
# Node order for multisim.pbs, which sources this file.  By default each sim runs on its
# slice of the sorted node list.  With hashrun -E ABACUS_NODE_ORDER=block, each slice is
# instead rewritten by nodelist_block.py so that small rank blocks land on consecutive
# (sorted) nodes, in seeded random block order.  That keeps each block physically compact
# while scattering neighboring blocks across racks, so the Manifest, Z-neighbor and
# transpose traffic spreads over many rack pairs instead of piling onto a few.
#   ABACUS_NODE_ORDER       sorted (default) | block
#   ABACUS_NODE_BLOCK       <X rows>x<Z ranks> (default 4x4); 5x4 for the 225x80 Flagship
#   ABACUS_NODE_ORDER_SEED  block shuffle seed (default 1)
# e.g. hashrun.sh -nps 9000 ... -E ABACUS_NODE_ORDER=block -E ABACUS_NODE_BLOCK=5x4
# The rank grid is nx x NumZRanks with Z fastest; NumZRanks comes from each sim's par2
# (with the job's -P overrides) and nx from the slice's node count.  SimName is untouched,
# and onesim.sh reuses the rewritten slice on every relaunch.
#
# Like daos.sh, these functions work on multisim.pbs's globals (overrides, abacus_prod)
# rather than taking them as arguments.

nodeorder_ppn=2   # aurora.def's mpirun_cmd

# Check the ABACUS_NODE_* settings.  Exits on a bad value.
nodeorder_check() {
    case ${ABACUS_NODE_ORDER:-sorted} in
        sorted) return 0 ;;
        block) ;;
        *) echo "ERROR: ABACUS_NODE_ORDER='$ABACUS_NODE_ORDER' (want sorted or block)" >&2; exit 1 ;;
    esac
    if [[ ! ${ABACUS_NODE_BLOCK:-4x4} =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]] ||
       (( BASH_REMATCH[2] % nodeorder_ppn )); then
        echo "ERROR: ABACUS_NODE_BLOCK='$ABACUS_NODE_BLOCK' (want <rows>x<zranks>," \
             "with zranks a multiple of $nodeorder_ppn ranks per node)" >&2
        exit 1
    fi
    if [[ ! ${ABACUS_NODE_ORDER_SEED:-1} =~ ^[0-9]+$ ]]; then
        echo "ERROR: ABACUS_NODE_ORDER_SEED='$ABACUS_NODE_ORDER_SEED' (want an integer)" >&2
        exit 1
    fi
}

# nodeorder_apply <par2> <hostfile>: rewrite <hostfile> in place in the requested order.
# A no-op for the sorted order.  Returns nonzero on failure.
nodeorder_apply() {
    local par2=$1 hf=$2 pargs=() o nz nx nnodes rows zw
    [[ ${ABACUS_NODE_ORDER:-sorted} == block ]] || return 0

    for o in ${overrides[@]+"${overrides[@]}"}; do pargs+=(-P "$o"); done
    nz=$(python -m abacus.param "$par2" ${pargs[@]+"${pargs[@]}"} -o /dev/stdout |
         awk -F'=' '/^NumZRanks[[:space:]]*=/ && !seen {print $2 + 0; seen = 1}')
    nnodes=$(( $(wc -l < "$hf") ))
    if [[ ! $nz =~ ^[1-9][0-9]*$ ]] || (( nodeorder_ppn * nnodes % nz )); then
        echo "ERROR: $nnodes nodes x $nodeorder_ppn ranks don't divide into NumZRanks='$nz' ($par2)" >&2
        return 1
    fi
    nx=$(( nodeorder_ppn * nnodes / nz ))
    rows=${ABACUS_NODE_BLOCK:-4x4}; zw=${rows#*x}; rows=${rows%x*}

    python "$abacus_prod/job/nodelist_block.py" --nx "$nx" --nz "$nz" --ppn "$nodeorder_ppn" \
        --block-rows "$rows" --block-z "$zw" --seed "${ABACUS_NODE_ORDER_SEED:-1}" \
        "$hf" "$hf.tmp" && mv "$hf.tmp" "$hf"
}
