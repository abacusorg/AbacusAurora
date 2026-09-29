#!/bin/bash
# Submit calib (A_s calibration) for cosm212-218; when it exits 0, submit final
# (full CLASS + write_s8). debug-scaling allows only 1 queued job per user, so the
# final job is submitted from here rather than with depend=afterok.
# Keeps printing progress. Run inside screen: screen -r neutrino_recal
cd /home/helenshao/InitialConditions/AbacusAurora/job/neutrino_recal
touch jobids.txt
[ -s jobids.txt ] || qsub -N nu_recal_calib -o $PWD/calib.pbs.out \
    -v STAGE=calib,EXTRA_ARGS="--wait-log ../util/neutrino_recal_run_class.log" neutrino_recal.pbs >> jobids.txt
j1=$(sed -n 1p jobids.txt)
while true; do
  if [ "$(grep -c . jobids.txt)" -eq 1 ]; then
    st=$(qstat -xf "$j1" | awk '/job_state/{s=$3} /Exit_status/{e=$3} END{print s, e}')
    if [ "$st" = "F 0" ]; then
      qsub -N nu_recal_final -o $PWD/final.pbs.out -v STAGE=final neutrino_recal.pbs >> jobids.txt \
        || echo "final qsub failed; will retry" >&2
    elif [ "${st%% *}" = F ]; then
      echo "calib job finished with exit status '${st#F }' -- NOT submitting final. Check calib_*.log"
    fi
  fi
  date
  qstat -x $(cat jobids.txt) 2>&1
  for f in calib_*.log final_*.log; do [ -f "$f" ] && { echo "== $f"; tail -2 "$f"; }; done
  echo "== login-node run (cosm211)"; tail -2 ../../util/neutrino_recal_run_class.log
  echo "== README.txt (root | A_s | sigma8_m | sigma8_cb)"
  grep -E "^\| abacus_cosm21[1-8]" ../../Cosmologies/README.txt | cut -d'|' -f2,7,15,16
  echo; sleep 120
done
