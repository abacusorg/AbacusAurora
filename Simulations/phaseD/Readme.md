The sims in parfiles_D2 were run with Derivatives that were generated at run-time, not the usual set of pre-generated files.  The irregularity is that they were being generated 8-fold in parallel, so the files were overwriting.  But comparing to the usual files, the values in the files seemed fine.



The following 4 sims were finished, we believe correctly, but didn't complete the epilogue of the final timestep, perhaps because of DAOS problem, before the job timed out.  As a result, the timings for the last time step are not in the history.asdf file, nor are those logs available.  But we believe the MapLogs and subsamples are correct, so we accepted the sim:
AbacusAurora_emulatorslim0p5_c110_ph312
AbacusAurora_emulatorslim0p5_c271_ph311
AbacusAurora_emulatorslim0p5_c282_ph313
AbacusAurora_emulatorslim0p5_c287_ph313
