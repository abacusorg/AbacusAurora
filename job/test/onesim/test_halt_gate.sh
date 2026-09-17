#!/bin/bash
# test_halt_gate.sh — exercise onesim.sh's deadline gate without MPI, DAOS or a built
# Abacus.  A stub `python` on $PATH stands in for both `python -m abacus.param` (whose
# empty output onesim already tolerates with a warning) and `python -m abacus.run`,
# which here just fails immediately so every run lands on the retry path.
#
# Usage: job/test/onesim/test_halt_gate.sh
# Exits 0 if all cases pass, 1 otherwise.

set -uo pipefail

onesim=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/onesim.sh
# Explicit template: macOS's mktemp ignores $TMPDIR unless one is given.
work=$(mktemp -d "${TMPDIR:-/tmp}/onesim-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# The stub. Always nonzero, so `abacus.run` reads as a failed invocation and
# `abacus.param` yields no OutputDirectory (onesim warns and skips provenance).
mkdir -p "$work/bin"
cat > "$work/bin/python" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$work/bin/python"
export PATH="$work/bin:$PATH"

: > "$work/sim.par2"
echo "node0001" > "$work/hostfile"

# min_healthy_seconds is 14400, so the stub's instant failures are all "rapid" and
# max_consec_fail=2 ends an ungated run after exactly 2 invocations.
fails=0
check() {  # check <name> <want_rc> <want_invocations> [VAR=VAL ...]
    local name=$1 want_rc=$2 want_n=$3; shift 3
    local out rc n
    out=$(env "$@" "$onesim" "$work/sim.par2" "$work/hostfile" 2>&1); rc=$?
    n=$(grep -c '^=== abacus invocation ' <<< "$out")
    if (( rc == want_rc && n == want_n )); then
        echo "PASS  $name (rc=$rc, $n invocation(s))"
    else
        echo "FAIL  $name: want rc=$want_rc with $want_n invocation(s), got rc=$rc with $n"
        sed 's/^/      | /' <<< "$out"
        fails=$((fails+1))
    fi
}

now=$(date +%s)
halt_file="$work/HALT.job"

# The bug this gate fixes: the deadline has passed (the sim halted, then its final state
# write hung until StepTimeout killed it), and onesim relaunched anyway.
check "past the halt time"        3 1 "ABACUS_JOB_HALT_TIME=$((now - 60))"

# Inside the 900s margin: a relaunch could not reach the deadline and close out.
check "inside the margin"         3 1 "ABACUS_JOB_HALT_TIME=$((now + 300))"

# Just outside it: still plenty of allocation left, so the caps alone decide.
check "outside the margin"        1 2 "ABACUS_JOB_HALT_TIME=$((now + 5000))"

# The margin is tunable per job.
check "margin overridden to 0"    1 2 "ABACUS_JOB_HALT_TIME=$((now + 300))" \
                                      "ONESIM_MIN_RELAUNCH_SECONDS=0"

# An allocation-wide halt someone touched by hand, with no deadline in play at all.
: > "$halt_file"
check "job halt file present"     3 1 "ABACUS_JOB_HALT_FILE=$halt_file"
rm -f "$halt_file"
check "job halt file absent"      1 2 "ABACUS_JOB_HALT_FILE=$halt_file"

# A garbled deadline: multistep warns and ignores it, and so must we -- refusing
# relaunches on an unparseable value would silently shorten every job.
check "unparseable halt time"     1 2 "ABACUS_JOB_HALT_TIME=not-a-number"

# Standalone onesim.sh, outside multisim.pbs: neither signal is set, behavior unchanged.
check "no halt signals at all"    1 2 "PATH=$PATH"

if (( fails )); then
    echo "$fails case(s) failed"
    exit 1
fi
echo "all cases passed"
