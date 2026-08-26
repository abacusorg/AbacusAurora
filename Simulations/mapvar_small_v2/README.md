This directory contains a progression of simulations of 1800^3 in 488 Mpc/h, intended to explore the effects of
variations of the MAP hyperparameters.  We also ran a range of cosmologies.  These boxes are small enough that 
they may be useful for code development.

Boxes of type "small" are the base; these include the usual subsample epochs.  There are no lightcones.

Boxes of type "smallMAP" then change the MAP parameters.  Because the DM is unchanged, we did not output
the subsample files, only the MAPlog files (this saves a lot of space!).

Important: these boxes are all at the same phase, ph350, but the first few dozen simulations were mislabeled as ph300.
We will change the directory names, but the headers in the files will still have the wrong label.

Three MAP hyperparameters are varied: Aaccrete, Amerge, and bmergeproper.  These are varied in a pattern of +-1 and +-2 units,
and then all pairs of +-1 unit (i.e., all edges of the cube, not the corners).  m001..12 are the unidirectional shifts, and
then m020..31 are the bidirectional shifts.  We then decided to expand the range of the variations; these are m041..52 and m060..71.
We do all of these for c000.  For other cosmologies, we only did some unidirectional shifts.
