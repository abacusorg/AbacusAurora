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
# Usage: hashrun.sh -nps N [-n TOTAL] [-t MIN] [-P KEY=VALUE]... <code-ref> <par2-list> [qsub args...]
#   <code-ref>   git ref in the code repo; resolved & built
#   <par2-list>  file with one par2 path per line (relative to this prod repo's root;
#                blank lines and #-comments ignored) — one sim per line
#   -nps N       nodes per sim (sims are launched on equal N-node slices)
#   -n TOTAL     total nodes to request (default nps x #par2); the surplus over
#                nps x #par2 becomes a spare pool for node blacklist/replace
#   -t MIN       wall-time budget in minutes; sets both -l walltime and PBS_MINUTES
#   -P KEY=VAL   override a par2 parameter (repeatable); forwarded to abacus.run
# The two bare args are <code-ref> and <par2-list>; other flags pass through to
# qsub (but not select/walltime — those are derived).
#
# Run from a login node.

set -euo pipefail

env_script=env/aurora-1D.sh
code_repo=${ABACUS_REPO:-$HOME/abacus}
store_root=${ABACUS_STORE_ROOT:-$HOME/abacus-store}
prod=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)

usage() {
    cat <<'EOF'
usage: hashrun.sh -nps N [-t MIN] [-P KEY=VALUE]... <code-ref> <par2-list> [qsub args...]
  <code-ref>   git ref in the abacus code repo; resolved & built (cached by hash)
  <par2-list>  file with one par2 path per line, relative to this prod repo's root
               (blank lines and #-comments ignored); one sim per line
  -nps N       nodes per sim (--nodes-per-sim); sims run on equal N-node slices
  -n TOTAL     total nodes (--nodes; default nps x #par2); surplus becomes a spare pool
  -t MIN       wall-time budget in minutes (--time); sets both -l walltime and PBS_MINUTES
  -P KEY=VAL   override a par2 parameter (repeatable); forwarded to abacus.run
  other flags pass through to qsub, e.g. -q prod. Do NOT pass select/walltime (derived).
EOF
}

# --- parse args: <code-ref> <par2-list>; our flags may appear before the qsub
#     flags; the first unrecognized flag switches to qsub pass-through ---
positionals=()
nps=""
nodes=""
tmin=""
overrides=()
qsub_args=()
qsub=0
while (( $# )); do
    if (( qsub )); then qsub_args+=("$1"); shift; continue; fi
    case $1 in
        -nps|--nodes-per-sim)     nps=$2; shift 2 ;;
        -nps=*|--nodes-per-sim=*) nps=${1#*=}; shift ;;
        -n|--nodes)               nodes=$2; shift 2 ;;
        -n=*|--nodes=*)           nodes=${1#*=}; shift ;;
        -t|--time)                tmin=$2; shift 2 ;;
        -t=*|--time=*)            tmin=${1#*=}; shift ;;
        -P|--param)               overrides+=("$2"); shift 2 ;;
        -P*)                      overrides+=("${1#-P}"); shift ;;
        -h|--help)                usage; exit 0 ;;
        --)                       shift; qsub=1 ;;
        -*)                       qsub=1 ;;   # first qsub flag: it and the rest pass through
        *)                        positionals+=("$1"); shift ;;
    esac
done

(( ${#positionals[@]} == 2 )) \
    || { echo "error: need <code-ref> and <par2-list>" >&2; usage >&2; exit 1; }
code_ref=${positionals[0]}
par2list=${positionals[1]}
[[ ${nps:-} =~ ^[1-9][0-9]*$ ]] \
    || { echo "error: -nps/--nodes-per-sim is required and must be a positive integer (got '${nps:-}')" >&2; exit 1; }
[[ -z ${nodes:-} || ${nodes} =~ ^[1-9][0-9]*$ ]] \
    || { echo "error: -n/--nodes must be a positive integer (got '$nodes')" >&2; exit 1; }
[[ -z ${tmin:-} || ${tmin} =~ ^[1-9][0-9]*$ ]] \
    || { echo "error: -t/--time must be a positive integer number of minutes (got '$tmin')" >&2; exit 1; }

# read the par2 list: one path per line, blank lines and #-comments ignored
[[ -f $par2list ]] || { echo "error: par2 list '$par2list' not found" >&2; exit 1; }
par2s=()
while read -r par2 _ || [[ -n ${par2:-} ]]; do
    par2=${par2%$'\r'}
    [[ -z $par2 || $par2 == '#'* ]] && continue
    par2s+=("$par2")
done < "$par2list"
(( ${#par2s[@]} >= 1 )) || { echo "error: par2 list '$par2list' has no entries" >&2; exit 1; }

# --- prod repo: record HEAD and require a clean tree (untracked ok only in untracked/) ---
prod_hash=$(git -C "$prod" rev-parse --verify --quiet HEAD) \
    || { echo "error: prod repo $prod has no commits (commit your specs first)" >&2; exit 1; }
changes=$(git -C "$prod" status --porcelain | grep -v '^?? untracked/' || true)
if [[ -n $changes ]]; then
    echo "error: prod repo is not clean (commit changes, or move them under untracked/):" >&2
    echo "$changes" >&2
    exit 1
fi
for par2 in "${par2s[@]}"; do
    [[ -f $prod/$par2 ]] || { echo "error: par2 '$par2' (from $par2list) not found in $prod" >&2; exit 1; }
done

# --- code repo: resolve ref and build (cached by hash) ---
git -C "$code_repo" fetch --quiet origin || echo "warning: code fetch failed; using local refs" >&2
code_hash=$(git -C "$code_repo" rev-parse --verify --quiet "${code_ref}^{commit}") \
    || { echo "error: cannot resolve code ref '$code_ref' in $code_repo" >&2; exit 1; }

checkout=$store_root/$code_hash   # hash-keyed built checkout of the code
if [[ ! -d $checkout ]]; then
    echo "Building code $code_hash -> $checkout"
    tmp=$checkout.tmp.$$
    rm -rf "$tmp"
    git init -q "$tmp"
    git -C "$tmp" fetch --quiet --depth 1 "$code_repo" "$code_hash"
    git -C "$tmp" checkout --quiet --detach FETCH_HEAD
    git -C "$tmp" submodule update --quiet --init --recursive --depth 1
    bash -lc "set -e; cd '$tmp'; . ./$env_script; uv sync --no-editable; meson setup build; meson compile -C build"
    mv -T "$tmp" "$checkout"   # atomic publish
else
    echo "Reusing code checkout $checkout"
fi

# --- sanity-check each par2 (parse here so we fail before queuing, not after) ---
spec=$(mktemp -d "$store_root/submit.XXXXXX")
mkdir -p "$spec/flattened"
cp "$par2list" "$spec/par2list"   # record the exact submitted list (incl. comments)
for par2 in "${par2s[@]}"; do
    echo "Parsing $par2 ..."
    flat=${par2//\//_}; flat=${flat%.par2}.par
    bash -lc '
        set -e
        checkout=$1 env_script=$2 par2=$3 out=$4
        cd "$checkout"; . "./$env_script"
        exec python -m abacus.param "$par2" -o "$out"
    ' hashrun "$checkout" "$env_script" "$prod/$par2" "$spec/flattened/$flat"
done

# --- record the job spec (sourced by multisim.pbs; also the provenance record) ---
{
    echo "# hashrun.sh $(date -Is)"
    printf 'abacus_env=%q\n'    "$checkout/$env_script"
    printf 'abacus_prod=%q\n'   "$prod"
    printf 'nodes_per_sim=%q\n' "$nps"
    printf 'code_hash=%q\n'     "$code_hash"
    printf 'code_ref=%q\n'      "$code_ref"
    printf 'prod_hash=%q\n'     "$prod_hash"
    printf 'par2s=(';     for p in "${par2s[@]}";                     do printf ' %q' "$p"; done; printf ' )\n'
    printf 'overrides=('; for o in ${overrides[@]+"${overrides[@]}"}; do printf ' %q' "$o"; done; printf ' )\n'
} > "$spec/jobspec.sh"

# --- node request: -n total (default -nps x #sims); the surplus is a spare pool.
#     From -t: the walltime + self-halt budget ---
nsims=${#par2s[@]}
min_nodes=$(( nps * nsims ))
total_nodes=${nodes:-$min_nodes}
(( total_nodes >= min_nodes )) \
    || { echo "error: -n $total_nodes is fewer than nodes-per-sim x #par2 ($nps x $nsims = $min_nodes)" >&2; exit 1; }
vlist="HASHRUN_SPEC=$spec"
time_args=()
if [[ -n ${tmin:-} ]]; then
    walltime=$(printf '%d:%02d:00' $(( tmin / 60 )) $(( tmin % 60 )))
    time_args=(-l "walltime=$walltime")
    vlist+=",PBS_MINUTES=$tmin"     # wall-time budget for the run to halt itself in time
fi

# --- submit held, point stdout/stderr into out/<jobid>/ once we know the jobid,
#     then release; PBS stages the streams into the same git-ignored dir.
echo "Submitting: code=$code_hash prod=$prod_hash  $nsims sim(s) x $nps node(s), select=$total_nodes ($(( total_nodes - min_nodes )) spare)${tmin:+, walltime=$walltime}"
jobid=$(qsub -h -l "select=$total_nodes" ${time_args[@]+"${time_args[@]}"} -v "$vlist" \
             ${qsub_args[@]+"${qsub_args[@]}"} "$prod/job/multisim.pbs")
out=$prod/job/out/${jobid%%.*}
mkdir -p "$out"
qalter -A Abacus -o "$out/stdout" -e "$out/stderr" "$jobid" \
    || { echo "error: qalter failed; deleting held job $jobid" >&2; qdel "$jobid"; exit 1; }
qrls "$jobid" \
    || { echo "error: qrls failed; job $jobid left held (qrls or qdel it)" >&2; exit 1; }
echo "$jobid"
echo "outputs -> $out/"
