#!/bin/bash
# One cosm per node: pick the root from the PALS rank id, then run one stage.
set -euo pipefail
roots=($ROOTS)
root=abacus_cosm${roots[$PALS_RANKID]}
cd /home/helenshao/InitialConditions/AbacusAurora/util
python -u run_class_one.py "$STAGE" "$root" $EXTRA_ARGS \
    > ../job/neutrino_recal/${STAGE}_${root}.log 2>&1
