  /* -- OCLJ REFUSAL FORENSICS (the instrumented copy only; see oclj_refrec) -- */
  int           oc_log;        /* OCLJ_REFLOG, read once at lj52_newstate     */
  int           oc_inref;      /* between oclj_ref_pre and oclj_ref_post      */
  int           oc_tryproof;   /* a proof ran inside the refusal's own TRY    */
  int           oc_trytier;    /* ... and the tier it left                    */
  int           oc_pwin, oc_ptier, oc_parmby;   /* a proof's state before it  */
  long long     oc_pgrown;
  long          oc_arms[5];    /* by cause: 0 gate 1 wall(cadence) 2 window  */
                               /* 3 refusal 4 flush                           */
  long          oc_proofs;     /* proven cycles                               */
  oclj_refrec   oc_cur;        /* the refusal being recorded                  */
