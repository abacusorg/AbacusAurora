#!/bin/bash
# Provenance-controlled sim launcher.
#
# Builds a hash-keyed checkout of the abacus CODE repo ($ABACUS_REPO, default
# ~/abacus) and submits a multisim job that uses it to run production specs in
# THIS repo (the one containing this script).
#
# The prod repo is used in place at its current HEAD; it must be clean so its
# recorded hash truly matches the job content. Put throwaway/dirty inputs under
# untracked/. Code builds are cached in $ABACUS_STORE_ROOT (default ~/abacus-store).
#
# Usage: hashrun.sh -nps N -t HH:MM [-n TOTAL] [-P KEY=VALUE]... [-E KEY=VALUE]... <code-ref> <par2-list> [qsub args...]
#   <code-ref>   git ref in the code repo; resolved & built
#   <par2-list>  file with one par2 path per line (relative to this prod repo's root;
#                blank lines and #-comments ignored) — one sim per line
#   -nps N       nodes per sim (sims are launched on equal N-node slices)
#   -n TOTAL     total nodes to request (default nps x #par2); the surplus over
#                nps x #par2 becomes a spare pool for node blacklist/replace
#   -t HH:MM     wall-time budget as HH:MM; sets both -l walltime and PBS_MINUTES
#   -P KEY=VAL   override a par2 parameter (repeatable); forwarded to abacus.run
#   -E KEY=VAL   set an environment variable in the job (repeatable)
#   --daos       put outputs and checkpoints on DAOS
# The two bare args are <code-ref> and <par2-list>; other flags pass through to
# qsub (but not select/walltime/filesystems — those are derived).
#
# Run from a login node.

set -euo pipefail

env_script=env/aurora.sh
code_repo=${ABACUS_REPO:-$HOME/abacus}
store_root=${ABACUS_STORE_ROOT:-$HOME/abacus-store}
prod=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)

source "$prod/job/daos.sh"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: hashrun.sh -nps N -t HH:MM [-n TOTAL] [-P KEY=VALUE]... [-E KEY=VALUE]... <code-ref> <par2-list> [qsub args...]
  <code-ref>   git ref in the abacus code repo; resolved & built (cached by hash)
  <par2-list>  file with one par2 path per line, relative to this prod repo's root
               (blank lines and #-comments ignored); one sim per line
  -nps N       nodes per sim (--nodes-per-sim); sims run on equal N-node slices
  -n TOTAL     total nodes (--nodes; default nps x #par2); surplus becomes a spare pool
  -t HH:MM     wall-time budget as HH:MM (--time); sets both -l walltime and PBS_MINUTES
  -P KEY=VAL   override a par2 parameter (repeatable); forwarded to abacus.run
  -E KEY=VAL   set an environment variable in the job (repeatable)
  --daos|--no-daos  force DAOS on/off for this job
  other flags pass through to qsub, e.g. -q prod.
  Do NOT pass select/walltime/filesystems (derived).
EOF
}

# Parse the CLI. The two bare args are <code-ref> <par2-list>; our flags may appear
# before them; the first unrecognized flag switches to qsub pass-through.
# Sets: code_ref par2list nps nodes twall daos_opt overrides[] env_overrides[] qsub_args[]
parse_args() {
    nps="" nodes="" twall="" daos_opt=""
    overrides=() env_overrides=() qsub_args=()
    local positionals=() qsub=0
    while (( $# )); do
        if (( qsub )); then qsub_args+=("$1"); shift; continue; fi
        case $1 in
            -nps|--nodes-per-sim)     nps=$2; shift 2 ;;
            -nps=*|--nodes-per-sim=*) nps=${1#*=}; shift ;;
            -n|--nodes)               nodes=$2; shift 2 ;;
            -n=*|--nodes=*)           nodes=${1#*=}; shift ;;
            -t|--time)                twall=$2; shift 2 ;;
            -t=*|--time=*)            twall=${1#*=}; shift ;;
            -P|--param)               overrides+=("$2"); shift 2 ;;
            -P*)                      overrides+=("${1#-P}"); shift ;;
            -E|--env)                 env_overrides+=("$2"); shift 2 ;;
            -E*)                      env_overrides+=("${1#-E}"); shift ;;
            --daos)                   daos_opt=on; shift ;;
            --no-daos)                daos_opt=off; shift ;;
            -h|--help)                usage; exit 0 ;;
            --)                       shift; qsub=1 ;;
            -*)                       qsub=1 ;;   # first qsub flag: it and the rest pass through
            *)                        positionals+=("$1"); shift ;;
        esac
    done
    (( ${#positionals[@]} == 2 )) || { usage >&2; die "need <code-ref> and <par2-list>"; }
    code_ref=${positionals[0]}
    par2list=${positionals[1]}
    [[ ${nps} =~ ^[1-9][0-9]*$ ]]           || die "-nps/--nodes-per-sim is required and must be a positive integer (got '${nps}')"
    [[ -z ${nodes} || ${nodes} =~ ^[1-9][0-9]*$ ]] || die "-n/--nodes must be a positive integer (got '${nodes}')"
    [[ ${twall} =~ ^[0-9]+:[0-5][0-9]$ ]] || die "-t/--time is required and must be HH:MM (got '${twall}')"
    local e
    for e in ${env_overrides[@]+"${env_overrides[@]}"}; do
        [[ $e =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "-E/--env must be KEY=VALUE with a valid identifier key (got '$e')"
    done
}

# Read $par2list into par2s[] (one path per line; blank lines and #-comments ignored).
read_par2_list() {
    [[ -f $par2list ]] || die "par2 list '$par2list' not found"
    par2s=()
    local par2
    while read -r par2 _ || [[ -n ${par2:-} ]]; do
        par2=${par2%$'\r'}
        [[ -z $par2 || $par2 == '#'* ]] && continue
        par2s+=("$par2")
    done < "$par2list"
    (( ${#par2s[@]} >= 1 )) || die "par2 list '$par2list' has no entries"
}

# Record the prod repo's HEAD ($prod_hash) and require a clean tree (untracked
# files allowed only under untracked/); check every par2 exists.
check_prod() {
    prod_hash=$(git -C "$prod" rev-parse --verify --quiet HEAD) \
        || die "prod repo $prod has no commits (commit your specs first)"
    local changes
    changes=$(git -C "$prod" status --porcelain | grep -v '^?? untracked/' || true)
    if [[ -n $changes ]]; then
        echo "error: prod repo is not clean (commit changes, or move them under untracked/):" >&2
        echo "$changes" >&2
        exit 1
    fi
    local par2
    for par2 in "${par2s[@]}"; do
        [[ -f $prod/$par2 ]] || die "par2 '$par2' (from $par2list) not found in $prod"
    done
}

# Apply the DAOS switches ($daos_conts, the storage roots, $filesystems) and check
# the pool is up and the containers are there — creating them is a manual step, never
# ours. Done before the build so a dead pool costs a second, not a compile. The roots
# are exported so stage_spec's par2 parse resolves the same paths the sims will write
# to; the job itself does not re-decide, it replays what we record in the spec.
setup_daos() {
    # The -E overrides reach the job's environment, so they must reach ours too, or
    # e.g. -E ABACUS_DAOS_OUTPUTS=off would be honoured at run time but not here.
    local e
    for e in ${env_overrides[@]+"${env_overrides[@]}"}; do export "$e"; done
    [[ -n $daos_opt ]] && export ABACUS_DAOS=$daos_opt   # the flag outranks -E

    daos_resolve
    if (( ${#daos_conts[@]} == 0 )); then
        filesystems=flare
        echo "DAOS: off; all storage on flare"
        return
    fi

    daos_preflight || exit 1
    daos_require_containers "${daos_conts[@]}" || exit 1
    filesystems=flare:daos_user_fs
    echo "DAOS: pool $DAOS_POOL, containers ${daos_conts[*]}"
}

# Resolve $code_ref in the code repo ($code_hash) and build it into a hash-keyed
# checkout ($checkout), reusing an existing build if present.
build_code() {
    git -C "$code_repo" fetch --quiet origin || echo "warning: code fetch failed; using local refs" >&2
    code_hash=$(git -C "$code_repo" rev-parse --verify --quiet "${code_ref}^{commit}") \
        || die "cannot resolve code ref '$code_ref' in $code_repo"
    checkout=$store_root/$code_hash
    if [[ -d $checkout ]]; then
        echo "Reusing code checkout $checkout"
        return
    fi
    echo "Building code $code_hash -> $checkout"
    local tmp=$checkout.tmp.$$
    rm -rf "$tmp"
    git init -q "$tmp"
    git -C "$tmp" fetch --quiet --depth 1 "$code_repo" "$code_hash"
    git -C "$tmp" checkout --quiet --detach FETCH_HEAD
    git -C "$tmp" submodule update --quiet --init --recursive --depth 1
    bash -lc "set -e; cd '$tmp'; . ./$env_script; uv sync --no-editable; meson setup build; meson compile -C build"
    mv -T "$tmp" "$checkout"   # atomic publish
}

# Parse every par2 now (throwaway) so we fail before queuing, then write the job
# spec ($spec/jobspec.sh) that multisim.pbs sources. $spec is scratch: submit()
# moves its contents into out/<jobid>/ once the job id exists.
stage_spec() {
    spec=$(mktemp -d -t hashrun.XXXXXX)
    trap 'rm -rf "$spec"' EXIT
    local p o e a
    cp "$par2list" "$spec/par2list"   # record the exact submitted list (incl. comments)

    # The invocation, re-runnable as a script. Its paths are relative to the
    # invoking directory, so that is recorded too.
    {
        printf '#!/bin/bash\n# hashrun.sh invocation, %s\n' "$(date -Is)"
        printf '# cwd: %q\n' "$PWD"
        printf '%q' "${argv[0]}"
        for a in "${argv[@]:1}"; do printf ' %q' "$a"; done
        printf '\n'
    } > "$spec/cmdline"

    # -E overrides go in their own file
    {
        echo "# hashrun.sh -E environment overrides"
        for e in ${env_overrides[@]+"${env_overrides[@]}"}; do printf 'export %q\n' "$e"; done
    } > "$spec/env_overrides.sh"

    bash -lc '
        set -e
        checkout=$1 env_script=$2 prod=$3 env_file=$4; shift 4
        cd "$checkout"; . "./$env_script"; . "$env_file"
        for par2; do
            echo "Parsing $par2 ..."
            python -m abacus.param "$prod/$par2" -o /dev/null
        done
    ' hashrun "$checkout" "$env_script" "$prod" "$spec/env_overrides.sh" "${par2s[@]}"
    {
        echo "# hashrun.sh $(date -Is)"
        printf 'abacus_env=%q\n'    "$checkout/$env_script"
        printf 'abacus_prod=%q\n'   "$prod"
        printf 'nodes_per_sim=%q\n' "$nps"
        printf 'code_hash=%q\n'     "$code_hash"
        printf 'code_ref=%q\n'      "$code_ref"
        printf 'prod_hash=%q\n'     "$prod_hash"
        printf 'daos_pool=%q\n'        "$DAOS_POOL"
        printf 'working_root=%q\n'     "$ABACUS_WORKING_ROOT"
        printf 'output_root=%q\n'      "$ABACUS_OUTPUT_ROOT"
        printf 'checkpoint_root=%q\n'  "$ABACUS_CHECKPOINT_ROOT"
        printf 'derivatives_root=%q\n' "$ABACUS_DERIVATIVES_ROOT"
        printf 'daos_conts=('; for o in ${daos_conts[@]+"${daos_conts[@]}"}; do printf ' %q' "$o"; done; printf ' )\n'
        printf 'par2s=(';     for p in "${par2s[@]}";                     do printf ' %q' "$p"; done; printf ' )\n'
        printf 'overrides=('; for o in ${overrides[@]+"${overrides[@]}"}; do printf ' %q' "$o"; done; printf ' )\n'
    } > "$spec/jobspec.sh"
}

# Derive the node request (-nps x #sims, or -n; surplus = spare pool) and walltime
# (from -t, also PBS_MINUTES), then submit held so that out/<jobid>/ can be
# populated (staged spec + qalter'd stdout/stderr) before releasing.
submit() {
    local nsims=${#par2s[@]}
    local min_nodes=$(( nps * nsims ))
    local total_nodes=${nodes:-$min_nodes}
    (( total_nodes >= min_nodes )) \
        || die "-n $total_nodes is fewer than nodes-per-sim x #par2 ($nps x $nsims = $min_nodes)"

    local hh=${twall%:*} mm=${twall#*:}
    local walltime="${twall}:00"        # PBS HH:MM:SS form
    # The job locates its own out/<jobid>/ (and thus the spec) from the prod repo
    # path plus $PBS_JOBID; only the path has to be passed in.
    local vlist="HASHRUN_PROD=$prod,PBS_MINUTES=$(( 10#$hh * 60 + 10#$mm ))"

    echo "Submitting: code=$code_hash prod=$prod_hash  $nsims sim(s) x $nps node(s), select=$total_nodes ($(( total_nodes - min_nodes )) spare), walltime=$walltime, filesystems=$filesystems"
    local jobid
    jobid=$(qsub -h -l "select=$total_nodes" -l "walltime=$walltime" \
                 -l "filesystems=$filesystems" -v "$vlist" \
                 ${qsub_args[@]+"${qsub_args[@]}"} "$prod/job/multisim.pbs")
    local out=$prod/job/out/${jobid%%.*}
    mkdir -p "$out"
    mv "$spec"/* "$out"/ \
        || { echo "error: staging into $out failed; deleting held job $jobid" >&2; qdel "$jobid"; exit 1; }
    qalter -A Abacus -o "$out/stdout" -e "$out/stderr" "$jobid" \
        || { echo "error: qalter failed; deleting held job $jobid" >&2; qdel "$jobid"; exit 1; }
    qrls "$jobid" \
        || { echo "error: qrls failed; job $jobid left held (qrls or qdel it)" >&2; exit 1; }
    echo "$jobid"
    echo "outputs -> $out/"
}

argv=("$0" "$@")     # recorded verbatim into out/<jobid>/cmdline
parse_args "$@"
read_par2_list
check_prod
setup_daos
build_code
stage_spec
submit
