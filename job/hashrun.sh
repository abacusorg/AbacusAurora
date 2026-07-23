#!/bin/bash
# Provenance-controlled sim launcher.
#
# Builds a hash-keyed checkout of the abacus CODE repo ($ABACUS_REPO, default
# ~/abacus) and submits a sim that runs from it against the production specs in
# THIS repo (the one containing this script).
#
# The prod repo is used in place at its current HEAD; it must be clean so its
# recorded hash truly matches the job content. Put throwaway/dirty inputs under
# untracked/. Code builds are cached in $ABACUS_STORE_ROOT (default ~/abacus-store).
#
# Usage: hashrun.sh [-P KEY=VALUE]... <code-ref> <par2> [qsub args...]
#   <code-ref>  git ref in the code repo; resolved & built
#   <par2>      par2 path relative to this prod repo's root
#   -P KEY=VAL  override a par2 parameter (repeatable); forwarded to abacus.run
# The first two bare args are <code-ref> and <par2>; other flags go to qsub.
#
# Run from a login node.

set -euo pipefail

env_script=env/aurora-1D.sh
code_repo=${ABACUS_REPO:-$HOME/abacus}
store_root=${ABACUS_STORE_ROOT:-$HOME/abacus-store}
prod=$(cd "$(dirname "${BASH_SOURCE[0]}")" && git rev-parse --show-toplevel)

usage() {
    cat <<'EOF'
usage: hashrun.sh [-P KEY=VALUE]... <code-ref> <par2> [qsub args...]
  <code-ref>  git ref in the abacus code repo; resolved & built (cached by hash)
  <par2>      par2 path relative to this prod repo's root
  -P KEY=VAL  override a par2 parameter (repeatable); forwarded to abacus.run
  flags after the two positionals pass through to qsub, e.g. -l select=16
EOF
}

# --- parse args: first two bare args are <code-ref> <par2>; rest -> qsub ---
overrides=()
positionals=()
qsub_args=()
while (( $# )); do
    case $1 in
        -P|--param) overrides+=("$2"); shift 2 ;;
        -P*)        overrides+=("${1#-P}"); shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          if (( ${#positionals[@]} < 2 )); then positionals+=("$1"); else qsub_args+=("$1"); fi
                    shift ;;
    esac
done
if (( ${#positionals[@]} != 2 )); then usage >&2; exit 1; fi
code_ref=${positionals[0]}
par2=${positionals[1]}

# --- prod repo: record HEAD and require a clean tree (untracked ok only in untracked/) ---
prod_hash=$(git -C "$prod" rev-parse --verify --quiet HEAD) \
    || { echo "error: prod repo $prod has no commits (commit your specs first)" >&2; exit 1; }
changes=$(git -C "$prod" status --porcelain | grep -v '^?? untracked/' || true)
if [[ -n $changes ]]; then
    echo "error: prod repo is not clean (commit changes, or move them under untracked/):" >&2
    echo "$changes" >&2
    exit 1
fi
[[ -f $prod/$par2 ]] || { echo "error: par2 '$par2' not found in $prod" >&2; exit 1; }

# --- code repo: resolve ref and build (cached by hash) ---
git -C "$code_repo" fetch --quiet origin || echo "warning: code fetch failed; using local refs" >&2
code_hash=$(git -C "$code_repo" rev-parse --verify --quiet "${code_ref}^{commit}") \
    || { echo "error: cannot resolve code ref '$code_ref' in $code_repo" >&2; exit 1; }

build=$store_root/$code_hash   # hash-keyed built checkout of the code
if [[ ! -d $build ]]; then
    echo "Building code $code_hash -> $build"
    tmp=$build.tmp.$$
    rm -rf "$tmp"
    git init -q "$tmp"
    git -C "$tmp" fetch --quiet --depth 1 "$code_repo" "$code_hash"
    git -C "$tmp" checkout --quiet --detach FETCH_HEAD
    git -C "$tmp" submodule update --quiet --init --recursive --depth 1
    bash -lc "set -e; cd '$tmp'; . ./$env_script; uv sync --no-editable; meson setup build; meson compile -C build"
    mv -T "$tmp" "$build"   # atomic publish
else
    echo "Reusing code build $build"
fi

# --- sanity-check the par2 (parse it here so we fail before queuing, not after) ---
spec=$(mktemp -d "$store_root/submit.XXXXXX")
echo "Parsing $par2 ..."
bash -lc '
    set -e
    cd "$1"; . "./$2"
    exec python -m abacus.param "$3" -o "$4"
' hashrun "$build" "$env_script" "$prod/$par2" "$spec/flattened.par"

# --- record the job spec (sourced by hashjob.pbs; also the provenance record) ---
{
    echo "# hashrun.sh $(date -Is)"
    printf 'ABACUS_ENV=%q\n'  "$build/$env_script"
    printf 'ABACUS_PROD=%q\n' "$prod"
    printf 'ABACUS_PAR2=%q\n' "$par2"
    printf 'CODE_HASH=%q\n'   "$code_hash"
    printf 'CODE_REF=%q\n'    "$code_ref"
    printf 'PROD_HASH=%q\n'   "$prod_hash"
    printf 'OVERRIDES=('; for o in ${overrides[@]+"${overrides[@]}"}; do printf ' %q' "$o"; done; printf ' )\n'
} > "$spec/jobspec.sh"

# --- submit ---
echo "Submitting: code=$code_hash prod=$prod_hash par2=$par2"
qsub -v "HASHRUN_SPEC=$spec" ${qsub_args[@]+"${qsub_args[@]}"} "$prod/job/hashjob.pbs"
