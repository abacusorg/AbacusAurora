#!/bin/bash
# Node-order sweep for multisim.pbs, which sources this file.  ABACUS_NODE_ORDERS (e.g.
# hashrun -E ABACUS_NODE_ORDERS=sorted,random,block) runs the job's one par2 once per
# listed order, in sequence on the same nodes_per_sim nodes, so the runs differ only in
# where each rank lands:
#   sorted  rack, chassis, slot: the placement every other job gets
#   random  a seeded shuffle of the nodes
#   block   nodelist_block.py's 4x4 rank blocks, in seeded random order
# Both seeds are ABACUS_NODE_ORDER_SEED (default 1).  Run i is SimName-<jobid>-i-<order>.
#
# Like daos.sh, these functions work on multisim.pbs's globals (num_sims, par2s, overrides,
# nodes_per_sim, out, onesim, abacus_prod) rather than taking arguments.

# Split $ABACUS_NODE_ORDERS into node_orders[] and check it.  Exits on a bad list.
nodeorder_check() {
    local o
    IFS=', ' read -r -a node_orders <<< "${ABACUS_NODE_ORDERS:-}"
    for o in ${node_orders[@]+"${node_orders[@]}"}; do
        case $o in
            sorted|random|block) ;;
            *) echo "ERROR: ABACUS_NODE_ORDERS: unknown order '$o' (sorted, random, block)" >&2; exit 1 ;;
        esac
    done
    if (( ${#node_orders[@]} && num_sims != 1 )); then
        echo "ERROR: ABACUS_NODE_ORDERS runs exactly one par2, under each order; got $num_sims" >&2
        exit 1
    fi
}

# Write one hostfile per order, run the sim on each in turn, and exit with the sweep's status.
nodeorder_sweep() {
    local ppn=2   # aurora.def's mpirun_cmd
    local par2=${par2s[0]} pargs=() hostfiles=() o i hf sim_name nz nx seed rc=0
    for o in ${overrides[@]+"${overrides[@]}"}; do pargs+=(-P "$o"); done
    python -m abacus.param "$par2" ${pargs[@]+"${pargs[@]}"} -o sweep.par
    sim_name=$(awk -F'"' '/^SimName[[:space:]]*=/ {print $2; exit}' sweep.par)
    nz=$(awk -F'=' '/^NumZRanks[[:space:]]*=/ {print $2 + 0; exit}' sweep.par)
    if (( nz < 1 || ppn * nodes_per_sim % nz )); then
        echo "ERROR: $nodes_per_sim nodes x $ppn ranks don't divide into NumZRanks=$nz" >&2
        exit 1
    fi
    nx=$(( ppn * nodes_per_sim / nz ))
    seed=${ABACUS_NODE_ORDER_SEED:-1}
    head -n "$nodes_per_sim" nodes.sorted > nodes.sweep

    for i in "${!node_orders[@]}"; do
        hf="$out/nodefile_order_${i}_${node_orders[$i]}"
        case ${node_orders[$i]} in
            sorted) cp nodes.sweep "$hf" ;;
            random) python -c 'import random, sys
hosts = open(sys.argv[1]).read().split()
random.Random(int(sys.argv[2])).shuffle(hosts)
open(sys.argv[3], "w").write("\n".join(hosts) + "\n")' nodes.sweep "$seed" "$hf" ;;
            block)  python "$abacus_prod/job/nodelist_block.py" --nx "$nx" --nz "$nz" --ppn "$ppn" \
                        --seed "$seed" nodes.sweep "$hf" ;;
        esac
        hostfiles+=("$hf")
    done

    set +e
    for i in "${!node_orders[@]}"; do
        o=${node_orders[$i]}
        if [[ -e $ABACUS_JOB_HALT_FILE ]] || { [[ -n ${ABACUS_JOB_HALT_TIME:-} ]] &&
               (( ABACUS_JOB_HALT_TIME - $(date +%s) < ${ONESIM_MIN_RELAUNCH_SECONDS:-900} )); }; then
            echo "Halt requested, or too close to the halt time to start another run; skipping orders $i and later" >&2
            rc=1
            break
        fi
        echo "Order $i: $o on $nodes_per_sim node(s) -> sim_${i}.out"
        "$onesim" "$par2" "${hostfiles[$i]}" ${overrides[@]+"${overrides[@]}"} \
            "SimName=$sim_name-${PBS_JOBID%%.*}-$i-$o" < /dev/null > "sim_${i}.out" 2>&1 \
            || { echo "Order $i ($o) exited nonzero" >&2; rc=1; }
    done
    echo "Node-order sweep finished (rc=$rc)"
    exit "$rc"
}
