/* OCLJ REFUSAL FORENSICS: the hooks, defined after the collector. */
static void oclj_ref_init(lj52_mem *M);
static void oclj_rsv_note(lj52_mem *M, long long total, long long used);
static void oclj_ref_pre(lj52_mem *M, long long total, long long used, long long delta, int legacy);
static void oclj_ref_post(lj52_mem *M);
static void oclj_arm_note(lj52_mem *M, int why);
static void oclj_prf_pre(lj52_mem *M);
static void oclj_prf_post(lj52_mem *M, long long total, long long used);
