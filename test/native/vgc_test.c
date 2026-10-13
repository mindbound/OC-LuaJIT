/* vgc_test.c -- VALUE DISPOSAL's C half, on its own terms: lj52_vgc_install,
 * the __gc wrapper it puts on jnlua's shared Java-object metatable, and
 * lj52_close's closing flag (native/lj52shim.c; the defect is
 * docs/research/gc-dispose-leak.md).
 *
 * Compiled the way jnlua.c is compiled (-include lj52shim.h), linked against
 * the same lj52shim.o the DLL links, and with NO JVM: this file plays jnlua
 * AND the JVM.  The JVM probe (OcljSmoke vd-*) proves the Java half -- the
 * per-Value count, the disposer -- against real jnlua; this proves the C
 * half's mechanics, every one of which is invisible from Java when it is
 * wrong: a callback made through a reference jnlua just deleted, a Java
 * exception lost or leaked across a finalizer, a local reference per
 * finalizer piling up in one native frame, a failed install that leaves the
 * stack or the metatable changed.
 *
 * WHAT IS UNDER TEST.  OC wraps every host Value in a Lua TABLE proxy whose
 * __gc disposes it, and LuaJIT finalizes no table, so Value.dispose never ran.
 * The fix replaces the __gc FIELD of registry["jnlua.Object"] -- the field,
 * never the table: jnlua recognizes a Java object only by rawequal on that
 * table (build/native/jnlua-luajit.c:2083-2107) -- with a C wrapper that, for
 * a finalized userdata whose object is an instance of the Value class Java
 * handed over, calls LuaStateLuaJIT.ocljValueFinalized(Object), and then
 * ALWAYS chains to jnlua's own gcjavaobject (jnlua-luajit.c:2120-2134), which
 * releases the global ref.  At lua_close it makes no JNI call at all: stock
 * OC disposes nothing at close either (design F5).
 *
 * THE FAKE JVM, AND WHY IT IS STRICT.  A JNIEnv is a pointer to a function
 * table (jni.h), so the fake is two filled `struct JNINativeInterface_` and
 * one `struct JNIInvokeInterface_`.  Every slot the contract does not name is
 * a TRAP that records the call (V12d) and answers 0.  A fake jobject is a
 * pointer into a never-reused pool of references, each GLOBAL, WEAK or LOCAL,
 * live or deleted, so a use after delete, a double delete, a delete of the
 * wrong kind (V12b) and a local reference left live (V12e) are all visible.
 * A fake that answered any pointer would pass the order sabotage below,
 * which in a JVM is a crash: the wrapper calling jnlua's gcjavaobject FIRST
 * and then IsInstanceOf/CallVoidMethod on the object it just released (the
 * review's C5a).  A deleted reference still answers for its object, as a
 * JVM's handle slot does until it is reused, so that sabotage fails the
 * order check and nothing downstream of it.
 *   TWO ENVS (the review's T5a).  The install runs on ENV_A -- the server
 * thread, Machine.init -> initialize() -- and every finalizer on ENV_B,
 * which is what GetEnv answers outside the install: OC finalizes on the
 * executor during the kernel's collect.  A wrapper that cached the install's
 * env would call ENV_A from a finalizer: V12a.  In a JVM an env used off its
 * thread is undefined behaviour that -Xcheck:jni reports and production
 * does not.
 *   PENDING EXCEPTIONS (design F9).  Each env has one pending slot, and any
 * function outside the JNI spec's exception-safe list (ExceptionOccurred,
 * ExceptionDescribe, ExceptionClear, ExceptionCheck, DeleteLocalRef,
 * DeleteGlobalRef, DeleteWeakGlobalRef) called while it is set is V12c.  The
 * case is real: GC checkpoints run inside lua_loadx (LuaJIT lj_load.c:74)
 * after jnlua's readhandler can have left an exception pending, and stock
 * gcjavaobject calls only DeleteGlobalRef, which is on the list.
 *   GetEnv answers JNI_EVERSION past JNI_VERSION_1_8, as the Java 8 JVM
 * Minecraft 1.12.2 runs does (the review's C4: a wrapper asking for 9+ skips
 * every callback silently, and only the version record -- V1e, V12a -- would
 * say why).  GetMethodID resolves only "ocljValueFinalized"
 * "(Ljava/lang/Object;)V" on the Java LuaState's class, and answers anything
 * else with NULL and a pending NoSuchMethodError, as a JVM does.
 *
 * THE JNLUA SIDE is newstate_protected's setup (jnlua-luajit.c:198-227): the
 * JAVASTATE holder -- a userdata holding a weak global ref, with its own
 * unregistered metatable whose __gc is gcjavaobject over upvalue true --
 * then registry["jnlua.Object"] = {__metatable = false, __gc = gcjavaobject
 * over upvalue false}; and pushjavaobject (jnlua-luajit.c:2068-2080): a new
 * userdata and a new global ref per push.  The fake gcjavaobject is jnlua's:
 * it deletes the ref and reads its OWN upvalue 1, so it notices a wrapper
 * that ran it outside its closure (the C pointer called in the wrapper's own
 * frame would read the wrapper's upvalue, a function, and delete a global
 * ref as a weak one).  jnlua's getthreadenv is not routed through the fake
 * GetEnv: it answers the current env, which is what V8 needs (the wrapper's
 * GetEnv fails, jnlua's own lookup at JNLUA_JNIVERSION does not -- C4's case).
 * The holder is the oldest __gc userdata of every state, so at lua_close it
 * is finalized LAST (newest first: lj_gc_separateudata walks the main
 * thread's list, which lj_udata_new prepends to; lj_state.c:341); V3e reads
 * the closing counter from inside it.
 *
 * THE CHECKS.  Ids are stable; each is one assertion family.  Every case
 * takes its tallies BEFORE its teardown close, and no case but V3 (the close
 * case) leaves a jnlua.Object userdata alive at its close, so a sabotage of
 * the close path cannot leak into another case's ids.
 *   V0a LJ52_JNLUA_OBJECT is jnlua's own spelling; V0b the install codes are
 *       the contract's; V0c a state with no install reports zero counters
 *   V1  a Value (one pushed BEFORE the install, one after: LuaJIT resolves
 *       __gc at finalize time, lj_gc.c:573) -- V1a the install: OK, installed,
 *       a new C __gc, __metatable kept; V1b one callback each, on the
 *       installed Java state, through the resolved method; V1c no callback
 *       after its original and none through a deleted reference; V1d the
 *       original ran once each, inside its own closure; V1e the wrapper's
 *       calls came on GetEnv's env, asked for at JNI_VERSION_1_6
 *   V2  non-Values (a JavaFunction before the install, a LuaError and a
 *       String after) -- V2a no callback, no NewLocalRef or CallVoidMethod;
 *       V2b the original ran once each
 *   V3  lj52_close with 5 live Values and 3 live non-Values -- V3a no
 *       callback; V3b the original ran once for each, the holder's once;
 *       V3c no JNI call during close but the release; V3d the class and
 *       state refs released, each exactly once; V3e every jnlua.Object
 *       finalization at close counted as a closing skip
 *   V4  an exception pending when the finalizer runs -- V4a nothing outside
 *       the exception-safe list called while it was pending; V4b the
 *       callback still made; V4c the SAME exception pending afterwards;
 *       V4d the original ran
 *   V5  the callback throws -- V5a cleared, nothing pending after; V5b
 *       counted (jerr 1, calls 1); V5c the original still ran
 *   V6  install twice -- V6a the second keeps the same wrapper closure,
 *       whose one upvalue is the original; V6b a Value: one callback, one
 *       original; V6c the second install's refs replaced the first's
 *   V7  the Lua part refuses -- V7a no registry["jnlua.Object"]: ENOMT;
 *       V7b its __gc a Lua function: ENOGC; V7c the protected call refused
 *       by the cap: ELUA; each with the stack top unchanged (the review's
 *       C1), the metatable untouched, nothing pending, no reference left,
 *       installed 0; V7d with room again, the same state installs
 *   V8  GetEnv fails -- V8a no callback, no JNIEnv call; V8b the original
 *       still ran; V8c counted (noenv 1)
 *   V9  the JNI part fails -- V9a GetMethodID (NoSuchMethodError pending):
 *       EMETHOD; V9b NewWeakGlobalRef (OutOfMemoryError pending): EREF; V9c
 *       NewGlobalRef of the class (OOM pending): EREF; V9d GetJavaVM: EJVM;
 *       each with the exception CLEARED (the review's C2: Java must see the
 *       code), every reference released, the stack and metatable as they
 *       were; V9e a state the shim did not make: ENORECORD, no JNI call
 *   V10 the shim's ARMED emergency collector -- V10a 2000 Values finalized
 *       inside ONE allocation's checkpoint, each with its callback and its
 *       original (lj52shim.c lj52_gc_arm: stepmul 0 makes one lj_gc_step a
 *       whole cycle, finalizers included -- in production, inside one jnlua
 *       native frame); V10b live local references never grew past the
 *       baseline + 2 there, and were back at it after (the review's C5c)
 *   V11 a mixed population -- V11a calls == callbacks == the 7 Values, none
 *       for the 5 non-Values; V11b the Lua-side stats (_OCLJ_VGCSTATS 1-5;
 *       _OCLJ_GCSTATS 21-25 only on a shim without it) report the same five
 *       figures as lj52_vgc_counters
 *   V12 the whole run's JNI hygiene -- V12a no call on another thread's
 *       env, every GetEnv at JNI_VERSION_1_6; V12b no deleted, unknown or
 *       mis-kinded reference, no bad argument; V12c nothing outside the
 *       exception-safe list while an exception was pending; V12d no slot
 *       outside the contract's list; V12e no local reference left live;
 *       V12f every global and weak reference ever made deleted
 *
 * THE SABOTAGES (test/native/negative-control.sh, section 7) and the EXACT
 * failing set each must produce.  PREDICTED from the contract before the
 * shim existed, then measured on 2026-10-13 against scratch copies of the
 * first complete shim, section 7's own sed lines run verbatim: all ten sets
 * matched, and the unsabotaged copy passed 47/47.  A difference from now on
 * is a finding about this file or about the shim, never noise:
 *   vgcnochain     drop the chain to jnlua's gcjavaobject
 *                  -> V1d V2b V3b V4d V5c V6b V8b V10a V12f
 *   vgcnoclosing   drop the closing check
 *                  -> V3a V3c V3e
 *   vgcnosave      drop the pending exception's save and re-throw
 *                  -> V4a V4c V12c
 *   vgcnofilter    drop the IsInstanceOf class filter
 *                  -> V2a V11a
 *   vgcnosettop    drop the install's lua_settop after the lua_cpcall
 *                  -> V7c
 *   vgcnoinstclear drop the ExceptionClear on an install failure
 *                  -> V9a V9b V9c
 *   vgcnodeljs     drop the wrapper's DeleteLocalRef of the state
 *                  -> V10b V12e
 *   vgcswapchain   chain to the original BEFORE the callback (the review's
 *                  C5a; in a JVM, a crash)
 *                  -> V1c V12b
 *   vgcnorelease   drop the post-close release of the class/state refs
 *                  -> V3d V12f
 *   vgcnopostclear drop the ExceptionClear after the callback
 *                  -> V5a
 * The first seven are the contract's list; the last three are the review's
 * (C5, T4), added because each guards a mistake that crashes or leaks in a
 * JVM and passes everything else here.  V6 (the already-wrapped test) and
 * V8 (the GetEnv check) have no permanent sabotage: the review asked for
 * them to be shown failing once by hand, as their paths are unreachable in
 * production (T4).  Done the same day, on the same scratch copies: the
 * already-wrapped test removed -> V6a V6b; the noenv count removed -> V8c;
 * and C4's case, the wrapper's GetEnv at JNI_VERSION_10, which a Java 8 JVM
 * refuses -> V1b V1e V4b V5a V5b V6b V10a V11a V12a, with every original
 * still run: the silent leak C4 describes, named by V1e and V12a.
 *
 * FAIL-FIRST: on HEAD aa12418 this file does not LINK -- LJ52_JNLUA_OBJECT,
 * lj52_vgc_install and lj52_vgc_counters do not exist -- which is this
 * suite's fail-first, as -DMEMTEST_OLD was mem_test's; the behavioural
 * fail-first is the sabotage table above.
 *
 * Build: see run-vgc.sh next to this file.  Exit status 0 iff every check
 * passes.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <stdint.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <jni.h>

/* ---- we are pretending to be jnlua ----------------------------------------
 * lj52shim.h's lua_setallocf macro names JNLUA_JAVASTATE and jnlua's three
 * static accessors (see mem_test.c for why defining them here PINS them).
 * JNLUA_OBJECT is jnlua's own spelling, jnlua-luajit.c:31, deliberately NOT
 * the header's LJ52_JNLUA_OBJECT: the setup below is jnlua's, and V0a
 * asserts the shim's copy matches it -- a test that built the metatable
 * under the shim's own name would pass against a shim that drifted. */
#define JNLUA_JAVASTATE "jnlua.JavaState"
#define JNLUA_OBJECT    "jnlua.Object"

static int failures = 0, checks = 0;

static void ok(int cond, const char *what, const char *detail) {
  checks++;
  printf("  %s  %-64s %s\n", cond ? "PASS" : "FAIL", what, detail ? detail : "");
  if (!cond) failures++;
}

/* ===================================================================== *
 * the fake Java heap
 * ===================================================================== */

enum { K_VALUE = 1, K_PLAIN, K_STATE, K_CLASS_VALUE, K_CLASS_STATE, K_CLASS_OTHER, K_THROWABLE };

typedef struct FakeObj {
  int kind;
  const char *name;
  /* what the Java side saw: ocljValueFinalized(this) */
  struct FakeObj *cb_state;      /* the Java LuaState the last callback reached */
  int callbacks;
  int cb_deadref;                /* ... of them through a deleted reference */
  int cb_after_orig;             /* ... of them after this object's original __gc */
  /* what jnlua's gcjavaobject saw */
  int origs;
  int orig_badup;                /* ran without its own boolean upvalue 1 */
} FakeObj;

#define MAXOBJS 8192
static FakeObj OBJS[MAXOBJS];
static int nobjs;

static FakeObj *obj_new(int kind, const char *name) {
  FakeObj *o;
  if (nobjs >= MAXOBJS) { printf("SETUP FAIL: fake object pool exhausted\n"); exit(2); }
  o = &OBJS[nobjs++];
  memset(o, 0, sizeof *o);
  o->kind = kind;
  o->name = name;
  return o;
}

static FakeObj *CLS_VALUE, *CLS_STATE, *CLS_OTHER;

/* ---- references --------------------------------------------------------- */

enum { R_LOCAL = 1, R_GLOBAL = 2, R_WEAK = 3 };

typedef struct FakeRef {
  unsigned magic;
  int kind;
  int live;
  int shim;                      /* made through the fake JNI table */
  FakeObj *obj;
} FakeRef;

#define REF_MAGIC 0x76676372u    /* "vgcr" */
#define MAXREFS 65536
static FakeRef REFS[MAXREFS];
static int nrefs;
static long LIVE[4];             /* by kind */
static long SHIM_LIVE[4];        /* ... of them made through the table */
static long PEAK_LOCAL;

/* ---- the misuse record ---------------------------------------------------- */

enum { V_ENV, V_DEAD, V_PENDING, V_ARGS, V_NKIND };
static long VIOL[V_NKIND];
static const char *const VIOL_WHAT[V_NKIND] = {
  "wrong env", "deleted, unknown or mis-kinded reference",
  "call while an exception is pending", "bad argument"
};

/* A NOTE, never a FAIL line: negative-control.sh reads the ids of the
 * "  FAIL " lines, and a misuse repeated a thousand times must not turn one
 * failing id into a thousand. */
static void viol(int k, const char *fn, const char *what) {
  VIOL[k]++;
  if (VIOL[k] <= 3)
    printf("  NOTE  JNI misuse (%s) #%ld: %s %s\n", VIOL_WHAT[k], VIOL[k], fn, what);
}

static jobject ref_new(FakeObj *o, int kind, int shim) {
  FakeRef *f;
  if (nrefs >= MAXREFS) { printf("SETUP FAIL: fake reference pool exhausted\n"); exit(2); }
  f = &REFS[nrefs++];
  f->magic = REF_MAGIC;
  f->kind = kind;
  f->live = 1;
  f->shim = shim;
  f->obj = o;
  LIVE[kind]++;
  if (shim) SHIM_LIVE[kind]++;
  if (kind == R_LOCAL && LIVE[R_LOCAL] > PEAK_LOCAL) PEAK_LOCAL = LIVE[R_LOCAL];
  return (jobject)f;
}

/* The pool entry behind a jobject, or NULL for one the fake never made. */
static FakeRef *ref_get(jobject r) {
  uintptr_t p = (uintptr_t)r, lo = (uintptr_t)&REFS[0], hi = (uintptr_t)&REFS[MAXREFS];
  FakeRef *f;
  if (r == NULL || p < lo || p >= hi || (p - lo) % sizeof(FakeRef) != 0) return NULL;
  f = (FakeRef *)r;
  return f->magic == REF_MAGIC ? f : NULL;
}

/* A reference handed to a JNI function: its object, recorded if it is dead.
 * A deleted one still answers for its object (see the header). */
static FakeObj *use(jobject r, const char *fn, const char *arg) {
  FakeRef *f;
  char m[192];
  if (r == NULL) return NULL;
  f = ref_get(r);
  if (f == NULL) { sprintf(m, "%s: a reference the fake never made", arg); viol(V_DEAD, fn, m); return NULL; }
  if (!f->live) { sprintf(m, "%s: a DELETED reference (%s)", arg, f->obj ? f->obj->name : "?"); viol(V_DEAD, fn, m); }
  return f->obj;
}

static void ref_del(jobject r, int kind, const char *fn) {
  FakeRef *f;
  if (r == NULL) return;                /* JNI: deleting NULL is a no-op */
  f = ref_get(r);
  if (f == NULL) { viol(V_DEAD, fn, "deletes a reference the fake never made"); return; }
  if (!f->live) { viol(V_DEAD, fn, "deletes a reference twice"); return; }
  if (f->kind != kind) viol(V_DEAD, fn, "deletes a reference of another kind");
  f->live = 0;
  LIVE[f->kind]--;
  if (f->shim) SHIM_LIVE[f->kind]--;
}

/* ===================================================================== *
 * the fake JNI
 * ===================================================================== */

enum { F_GETENV, F_GETJAVAVM, F_NEWGLOBAL, F_DELGLOBAL, F_NEWWEAK, F_DELWEAK,
       F_NEWLOCAL, F_DELLOCAL, F_GETOBJCLASS, F_GETMETHOD, F_ISINST, F_CALLVOID,
       F_EXOCC, F_EXCHECK, F_EXCLEAR, F_EXDESC, F_THROW, F_NFN };
static long CALLS[F_NFN];
static long SEQ;                         /* one tick per JNI call or original __gc */

static struct JNINativeInterface_ TAB_A, TAB_B;
static JNIEnv ENV_A = &TAB_A;            /* the install's thread */
static JNIEnv ENV_B = &TAB_B;            /* every finalizer's thread */
static struct JNIInvokeInterface_ VMTAB;
static JavaVM FAKE_VM = &VMTAB;
static JNIEnv *cur_env = &ENV_B;         /* the thread the test is on */
static FakeObj *PENDING[2];              /* per env: the pending exception */
static int METHOD_TOKEN;                 /* &METHOD_TOKEN is the only valid jmethodID */

/* failure injection, all off between cases */
static int GETENV_FAIL, FAIL_GETJAVAVM, FAIL_NEWGLOBAL, FAIL_NEWWEAK, FAIL_GETMETHOD, CALLBACK_THROWS;
static void modes_off(void) {
  GETENV_FAIL = FAIL_GETJAVAVM = FAIL_NEWGLOBAL = FAIL_NEWWEAK = FAIL_GETMETHOD = CALLBACK_THROWS = 0;
}

/* tallies */
static long GETENV_BADVER, CB_TOTAL, CB_NONVALUE, ORIG_TOTAL, HOLDER_GCS, TRAP_TOTAL;
static long CB_IN_STEP[3], ORIG_IN_STEP[3];
static int CUR_STEP;                     /* V10: which allocation is running */
static long REL_DELCLASS, REL_DELSTATE, REL_DELOTHER;   /* the deletes' targets */
static int IN_CLOSE, CLOSE_SAMPLED;
static long long CLOSE_SAMPLE[5];

static int pidx(JNIEnv *env) { return env == &ENV_A ? 0 : 1; }

static int enter(JNIEnv *env, int fn, const char *name, int pending_ok) {
  int t = pidx(env);
  SEQ++;
  CALLS[fn]++;
  if (env != cur_env)
    viol(V_ENV, name, env == &ENV_A ? "on the install's env, from the finalizer thread (a cached env)"
                    : env == &ENV_B ? "on the finalizer thread's env, during the install"
                    : "on an env the fake never handed out");
  if (!pending_ok && PENDING[t] != NULL)
    viol(V_PENDING, name, "with an exception pending: not in the JNI spec's exception-safe list");
  return t;
}

static jint JNICALL f_GetEnv(JavaVM *vm, void **penv, jint version) {
  SEQ++;
  CALLS[F_GETENV]++;
  if (vm != &FAKE_VM) viol(V_ARGS, "GetEnv", "on a JavaVM GetJavaVM never handed out");
  if (version != JNI_VERSION_1_6) GETENV_BADVER++;
  if (penv != NULL) *penv = NULL;
  if (GETENV_FAIL) return JNI_EVERSION;
  /* A Java 8 JVM, as Minecraft 1.12.2 runs: nothing past 1.8. */
  if (version < JNI_VERSION_1_1 || version > JNI_VERSION_1_8) return JNI_EVERSION;
  if (penv != NULL) *penv = (void *)cur_env;
  return JNI_OK;
}

static jint JNICALL f_GetJavaVM(JNIEnv *env, JavaVM **vm) {
  enter(env, F_GETJAVAVM, "GetJavaVM", 0);
  if (FAIL_GETJAVAVM) { if (vm != NULL) *vm = NULL; return JNI_ERR; }
  if (vm != NULL) *vm = &FAKE_VM;
  return JNI_OK;
}

static jobject JNICALL f_NewGlobalRef(JNIEnv *env, jobject lobj) {
  int t = enter(env, F_NEWGLOBAL, "NewGlobalRef", 0);
  FakeObj *o = use(lobj, "NewGlobalRef", "its argument");
  if (FAIL_NEWGLOBAL) { PENDING[t] = obj_new(K_THROWABLE, "OutOfMemoryError (NewGlobalRef)"); return NULL; }
  return o != NULL ? ref_new(o, R_GLOBAL, 1) : NULL;
}

static void JNICALL f_DeleteGlobalRef(JNIEnv *env, jobject gref) {
  FakeRef *f = ref_get(gref);
  enter(env, F_DELGLOBAL, "DeleteGlobalRef", 1);
  if (f != NULL && f->obj != NULL && f->obj->kind == K_CLASS_VALUE) REL_DELCLASS++;
  else if (gref != NULL) REL_DELOTHER++;
  ref_del(gref, R_GLOBAL, "DeleteGlobalRef");
}

static jweak JNICALL f_NewWeakGlobalRef(JNIEnv *env, jobject obj) {
  int t = enter(env, F_NEWWEAK, "NewWeakGlobalRef", 0);
  FakeObj *o = use(obj, "NewWeakGlobalRef", "its argument");
  if (FAIL_NEWWEAK) { PENDING[t] = obj_new(K_THROWABLE, "OutOfMemoryError (NewWeakGlobalRef)"); return NULL; }
  return o != NULL ? (jweak)ref_new(o, R_WEAK, 1) : NULL;
}

static void JNICALL f_DeleteWeakGlobalRef(JNIEnv *env, jweak ref) {
  FakeRef *f = ref_get(ref);
  enter(env, F_DELWEAK, "DeleteWeakGlobalRef", 1);
  if (f != NULL && f->obj != NULL && f->obj->kind == K_STATE) REL_DELSTATE++;
  else if (ref != NULL) REL_DELOTHER++;
  ref_del(ref, R_WEAK, "DeleteWeakGlobalRef");
}

static jobject JNICALL f_NewLocalRef(JNIEnv *env, jobject ref) {
  FakeObj *o;
  enter(env, F_NEWLOCAL, "NewLocalRef", 0);
  o = use(ref, "NewLocalRef", "its argument");
  return o != NULL ? ref_new(o, R_LOCAL, 1) : NULL;
}

static void JNICALL f_DeleteLocalRef(JNIEnv *env, jobject obj) {
  enter(env, F_DELLOCAL, "DeleteLocalRef", 1);
  ref_del(obj, R_LOCAL, "DeleteLocalRef");
}

static jclass JNICALL f_GetObjectClass(JNIEnv *env, jobject obj) {
  FakeObj *o, *c;
  enter(env, F_GETOBJCLASS, "GetObjectClass", 0);
  o = use(obj, "GetObjectClass", "its argument");
  if (o == NULL) { viol(V_ARGS, "GetObjectClass", "of null"); return NULL; }
  c = o->kind == K_STATE ? CLS_STATE : o->kind == K_VALUE ? CLS_VALUE : CLS_OTHER;
  return (jclass)ref_new(c, R_LOCAL, 1);
}

static jmethodID JNICALL f_GetMethodID(JNIEnv *env, jclass clazz, const char *name, const char *sig) {
  int t = enter(env, F_GETMETHOD, "GetMethodID", 0);
  FakeObj *c = use(clazz, "GetMethodID", "its class");
  if (c == NULL || c->kind != K_CLASS_STATE) viol(V_ARGS, "GetMethodID", "not on the Java LuaState's class");
  if (!FAIL_GETMETHOD && c != NULL && c->kind == K_CLASS_STATE && name != NULL && sig != NULL
      && strcmp(name, "ocljValueFinalized") == 0 && strcmp(sig, "(Ljava/lang/Object;)V") == 0)
    return (jmethodID)&METHOD_TOKEN;
  if (!FAIL_GETMETHOD)
    printf("  NOTE  GetMethodID(\"%s\", \"%s\") resolves nothing: the generated class declares "
           "ocljValueFinalized (Ljava/lang/Object;)V\n", name ? name : "(null)", sig ? sig : "(null)");
  PENDING[t] = obj_new(K_THROWABLE, "NoSuchMethodError");
  return NULL;
}

static jboolean JNICALL f_IsInstanceOf(JNIEnv *env, jobject obj, jclass clazz) {
  FakeObj *o, *c;
  enter(env, F_ISINST, "IsInstanceOf", 0);
  o = use(obj, "IsInstanceOf", "the object");
  c = use(clazz, "IsInstanceOf", "the class");
  if (c == NULL || c->kind != K_CLASS_VALUE) viol(V_ARGS, "IsInstanceOf", "not asked about the installed Value class");
  if (obj == NULL) return JNI_TRUE;     /* JNI: null is an instance of every class */
  return o != NULL && o->kind == K_VALUE ? JNI_TRUE : JNI_FALSE;
}

/* The Java side of the callback: LuaStateLuaJIT.ocljValueFinalized(Object).
 * Records what it was called with; in CALLBACK_THROWS mode it leaves an
 * exception behind, as a Java method that throws does. */
static void callback(JNIEnv *env, const char *fn, jobject self, jmethodID mid, jobject arg) {
  int t = enter(env, F_CALLVOID, fn, 0);
  FakeObj *s = use(self, fn, "the target"), *a = use(arg, fn, "the argument");
  FakeRef *ar = ref_get(arg);
  if (s == NULL || s->kind != K_STATE) viol(V_ARGS, fn, "the target is not a Java LuaState");
  if (mid != (jmethodID)&METHOD_TOKEN) viol(V_ARGS, fn, "not through the method GetMethodID resolved");
  if (a == NULL) { viol(V_ARGS, fn, "with a null or unknown argument"); return; }
  a->callbacks++;
  a->cb_state = s;
  if (ar != NULL && !ar->live) a->cb_deadref++;
  if (a->origs > 0) a->cb_after_orig++;
  CB_TOTAL++;
  CB_IN_STEP[CUR_STEP]++;
  if (a->kind != K_VALUE) CB_NONVALUE++;
  if (CALLBACK_THROWS) PENDING[t] = obj_new(K_THROWABLE, "RuntimeException from ocljValueFinalized");
}

static void JNICALL f_CallVoidMethod(JNIEnv *env, jobject obj, jmethodID methodID, ...) {
  va_list ap;
  jobject a;
  va_start(ap, methodID);
  a = va_arg(ap, jobject);
  va_end(ap);
  callback(env, "CallVoidMethod", obj, methodID, a);
}

static void JNICALL f_CallVoidMethodV(JNIEnv *env, jobject obj, jmethodID methodID, va_list args) {
  callback(env, "CallVoidMethodV", obj, methodID, va_arg(args, jobject));
}

static void JNICALL f_CallVoidMethodA(JNIEnv *env, jobject obj, jmethodID methodID, const jvalue *args) {
  callback(env, "CallVoidMethodA", obj, methodID, args != NULL ? args[0].l : NULL);
}

static jthrowable JNICALL f_ExceptionOccurred(JNIEnv *env) {
  int t = enter(env, F_EXOCC, "ExceptionOccurred", 1);
  return PENDING[t] != NULL ? (jthrowable)ref_new(PENDING[t], R_LOCAL, 1) : NULL;
}

static jboolean JNICALL f_ExceptionCheck(JNIEnv *env) {
  int t = enter(env, F_EXCHECK, "ExceptionCheck", 1);
  return PENDING[t] != NULL ? JNI_TRUE : JNI_FALSE;
}

static void JNICALL f_ExceptionClear(JNIEnv *env) {
  int t = enter(env, F_EXCLEAR, "ExceptionClear", 1);
  PENDING[t] = NULL;
}

static void JNICALL f_ExceptionDescribe(JNIEnv *env) {
  int t = enter(env, F_EXDESC, "ExceptionDescribe", 1);
  PENDING[t] = NULL;                    /* it prints, then clears */
}

static jint JNICALL f_Throw(JNIEnv *env, jthrowable obj) {
  int t = enter(env, F_THROW, "Throw", 0);
  FakeObj *o = use(obj, "Throw", "its argument");
  if (o == NULL || o->kind != K_THROWABLE) { viol(V_ARGS, "Throw", "of something that is not a Throwable"); return JNI_ERR; }
  PENDING[t] = o;
  return 0;
}

/* ---- the traps --------------------------------------------------------------
 * Every slot of both tables that the contract does not name.  Each knows its
 * slot number; the JavaVM table's traps are numbered from 248 so the two
 * tables never share a number.  A trap answers 0 -- NULL, JNI_OK, JNI_FALSE
 * -- and is counted for V12d, with a NOTE the first time a slot is hit (the
 * slot's name is its position in jni.h's struct). */
typedef void (*vgc_fn)(void);
static long TRAP_HIT[256];

static jlong trap_hit(int slot) {
  TRAP_TOTAL++;
  if (TRAP_HIT[slot]++ == 0)
    printf("  NOTE  a JNI slot outside the contract's list was called: %s slot %d\n",
           slot >= 248 ? "JavaVM" : "JNIEnv", slot >= 248 ? slot - 248 : slot);
  return 0;
}

#define VT(h, l) static jlong JNICALL vtrap_##h##l(void) { return trap_hit(0x##h##l); }
#define VTROW(h) VT(h,0) VT(h,1) VT(h,2) VT(h,3) VT(h,4) VT(h,5) VT(h,6) VT(h,7) \
                 VT(h,8) VT(h,9) VT(h,a) VT(h,b) VT(h,c) VT(h,d) VT(h,e) VT(h,f)
VTROW(0) VTROW(1) VTROW(2) VTROW(3) VTROW(4) VTROW(5) VTROW(6) VTROW(7)
VTROW(8) VTROW(9) VTROW(a) VTROW(b) VTROW(c) VTROW(d) VTROW(e) VTROW(f)
#define VR(h, l) (vgc_fn)vtrap_##h##l
#define VRROW(h) VR(h,0), VR(h,1), VR(h,2), VR(h,3), VR(h,4), VR(h,5), VR(h,6), VR(h,7), \
                 VR(h,8), VR(h,9), VR(h,a), VR(h,b), VR(h,c), VR(h,d), VR(h,e), VR(h,f)
static const vgc_fn VTRAPS[256] = {
  VRROW(0), VRROW(1), VRROW(2), VRROW(3), VRROW(4), VRROW(5), VRROW(6), VRROW(7),
  VRROW(8), VRROW(9), VRROW(a), VRROW(b), VRROW(c), VRROW(d), VRROW(e), VRROW(f)
};

static void fill_with_traps(void *tab, size_t size, int first) {
  size_t i, n = size / sizeof(vgc_fn);
  if (size % sizeof(vgc_fn) != 0 || first + n > 256 || (first == 0 && n > 248)) {
    printf("SETUP FAIL: a JNI table of %lu slots does not fit the traps\n", (unsigned long)n);
    exit(2);
  }
  for (i = 0; i < n; i++) memcpy((char *)tab + i * sizeof(vgc_fn), &VTRAPS[first + i], sizeof(vgc_fn));
}

static void jni_init(void) {
  struct JNINativeInterface_ *t;
  int k;
  fill_with_traps(&VMTAB, sizeof VMTAB, 248);
  VMTAB.GetEnv = f_GetEnv;
  for (k = 0; k < 2; k++) {
    t = k ? &TAB_B : &TAB_A;
    fill_with_traps(t, sizeof *t, 0);
    t->GetJavaVM = f_GetJavaVM;
    t->NewGlobalRef = f_NewGlobalRef;
    t->DeleteGlobalRef = f_DeleteGlobalRef;
    t->NewWeakGlobalRef = f_NewWeakGlobalRef;
    t->DeleteWeakGlobalRef = f_DeleteWeakGlobalRef;
    t->NewLocalRef = f_NewLocalRef;
    t->DeleteLocalRef = f_DeleteLocalRef;
    t->GetObjectClass = f_GetObjectClass;
    t->GetMethodID = f_GetMethodID;
    t->IsInstanceOf = f_IsInstanceOf;
    t->CallVoidMethod = f_CallVoidMethod;
    t->CallVoidMethodV = f_CallVoidMethodV;
    t->CallVoidMethodA = f_CallVoidMethodA;
    t->ExceptionOccurred = f_ExceptionOccurred;
    t->ExceptionCheck = f_ExceptionCheck;
    t->ExceptionClear = f_ExceptionClear;
    t->ExceptionDescribe = f_ExceptionDescribe;
    t->Throw = f_Throw;
  }
  CLS_VALUE = obj_new(K_CLASS_VALUE, "class li.cil.oc.api.machine.Value");
  CLS_STATE = obj_new(K_CLASS_STATE, "class LuaStateLuaJIT");
  CLS_OTHER = obj_new(K_CLASS_OTHER, "some other class");
}

/* ===================================================================== *
 * jnlua
 * ===================================================================== */

/* jnlua's getthreadenv: the current thread's env.  Not through the fake
 * GetEnv -- see the header (V8). */
static JNIEnv *getthreadenv(void) { return cur_env; }

/* The accounting's legacy accessors.  Never reached: every capped case here
 * hands the cap over first (C mode, docs/accounting-sync.md). */
static void getluamemory(JNIEnv *env, jobject obj, jint *total, jint *used) {
  (void)env; (void)obj;
  *total = 0;
  *used = 0;
}
static void setluamemory(JNIEnv *env, jobject obj, jint used) { (void)env; (void)obj; (void)used; }

/* jnlua's gcjavaobject (jnlua-luajit.c:2120-2134), recording.  Upvalue 1 is
 * true for the JAVASTATE holder's weak ref, false for every pushed object. */
static int fake_gcjavaobject(lua_State *L) {
  JNIEnv *env = getthreadenv();
  int boolup = lua_type(L, lua_upvalueindex(1)) == LUA_TBOOLEAN;
  int weak = lua_toboolean(L, lua_upvalueindex(1));
  jobject r;
  FakeRef *f;
  SEQ++;
  if (env == NULL) return 0;
  r = *(jobject *)lua_touserdata(L, 1);
  f = ref_get(r);
  if (f != NULL && f->obj != NULL) {
    f->obj->origs++;
    if (!boolup) f->obj->orig_badup++;
  }
  if (weak) {
    HOLDER_GCS++;
    if (IN_CLOSE && !CLOSE_SAMPLED) {
      /* The last finalizer at lua_close: every jnlua.Object one has run. */
      lj52_vgc_counters(L, CLOSE_SAMPLE);
      CLOSE_SAMPLED = 1;
    }
    ref_del(r, R_WEAK, "jnlua gcjavaobject (weak)");
  } else {
    ORIG_TOTAL++;
    ORIG_IN_STEP[CUR_STEP]++;
    ref_del(r, R_GLOBAL, "jnlua gcjavaobject");
  }
  return 0;
}

#define ORIG_KEY "vgc_test.original"

/* luaL_newstate + newstate_protected, as jnlua does them; objmt = 0 leaves
 * registry["jnlua.Object"] out (V7a). */
static lua_State *jnlua_open(FakeObj *jstate, int objmt) {
  lua_State *L = luaL_newstate();       /* -> lj52_newstate */
  jobject *ref;
  if (L == NULL) { printf("SETUP FAIL: luaL_newstate returned NULL\n"); exit(2); }
  lua_setallocf(L, NULL, NULL);         /* l_alloc_unchecked: accounting off */
  ref = (jobject *)lua_newuserdata(L, sizeof(jobject));
  lua_createtable(L, 0, 1);
  lua_pushboolean(L, 1);                /* weak global reference */
  lua_pushcclosure(L, fake_gcjavaobject, 1);
  lua_setfield(L, -2, "__gc");
  *ref = ref_new(jstate, R_WEAK, 0);
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, JNLUA_JAVASTATE);
  if (objmt) {
    luaL_newmetatable(L, JNLUA_OBJECT);
    lua_pushboolean(L, 0);
    lua_setfield(L, -2, "__metatable");
    lua_pushboolean(L, 0);              /* non-weak global reference */
    lua_pushcclosure(L, fake_gcjavaobject, 1);
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, ORIG_KEY);   /* the test's own handle on the original */
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
  }
  return L;
}

/* pushjavaobject (jnlua-luajit.c:2068-2080): a new userdata, a new global ref. */
static void push_obj(lua_State *L, FakeObj *o) {
  jobject *ud = (jobject *)lua_newuserdata(L, sizeof(jobject));
  luaL_getmetatable(L, JNLUA_OBJECT);
  *ud = ref_new(o, R_GLOBAL, 0);
  lua_setmetatable(L, -2);
}

/* The JNI entry ocljInstallValueFinalizer, as a JVM runs it: a native frame
 * on the install's thread (ENV_A) whose arguments are local references, freed
 * when the frame returns -- along with any the shim left, which the JVM would
 * free too but V12e counts.  An exception still pending at the return is
 * what Java would see thrown instead of the return code (the review's C2). */
static int INSTALL_TOP_DELTA;
static long INSTALL_LOCALS_LEFT;
static FakeObj *INSTALL_PENDING;

static int install(lua_State *L, FakeObj *jstate) {
  jobject self = ref_new(jstate, R_LOCAL, 0);
  jobject vc = ref_new(CLS_VALUE, R_LOCAL, 0);
  long l0 = LIVE[R_LOCAL];
  int top0 = lua_gettop(L), rc;
  cur_env = &ENV_A;
  rc = lj52_vgc_install(L, &ENV_A, self, (jclass)vc);
  cur_env = &ENV_B;
  INSTALL_TOP_DELTA = lua_gettop(L) - top0;
  INSTALL_LOCALS_LEFT = LIVE[R_LOCAL] - l0;
  INSTALL_PENDING = PENDING[0];
  PENDING[0] = NULL;                    /* thrown into Java at the return */
  ref_del(self, R_LOCAL, "(the native frame's return)");
  ref_del(vc, R_LOCAL, "(the native frame's return)");
  return rc;
}

static void vgcc(lua_State *L, long long c[5]) {
  int i;
  for (i = 0; i < 5; i++) c[i] = -99;   /* a figure never written reads as -99 */
  lj52_vgc_counters(L, c);
}

/* registry["jnlua.Object"].__gc is rawequal registry[key]? */
static int gc_is(lua_State *L, const char *key) {
  int top = lua_gettop(L), r = 0;
  lua_getfield(L, LUA_REGISTRYINDEX, JNLUA_OBJECT);
  if (lua_istable(L, -1)) {
    lua_getfield(L, -1, "__gc");
    lua_getfield(L, LUA_REGISTRYINDEX, key);
    r = lua_rawequal(L, -1, -2);
  }
  lua_settop(L, top);
  return r;
}

/* Copy registry["jnlua.Object"].__gc to registry[key]. */
static void gc_save(lua_State *L, const char *key) {
  int top = lua_gettop(L);
  lua_getfield(L, LUA_REGISTRYINDEX, JNLUA_OBJECT);
  if (lua_istable(L, -1)) lua_getfield(L, -1, "__gc"); else lua_pushnil(L);
  lua_setfield(L, LUA_REGISTRYINDEX, key);
  lua_settop(L, top);
}

/* The installed __gc's shape: a C function?  Its upvalue 1 the original?
 * How many upvalues?  __metatable still false? */
static void gc_shape(lua_State *L, int *iscf, int *up1orig, int *nups, int *mtfalse) {
  int top = lua_gettop(L);
  *iscf = *up1orig = *nups = *mtfalse = 0;
  lua_getfield(L, LUA_REGISTRYINDEX, JNLUA_OBJECT);
  if (!lua_istable(L, -1)) { lua_settop(L, top); return; }
  lua_getfield(L, -1, "__metatable");
  *mtfalse = lua_isboolean(L, -1) && !lua_toboolean(L, -1);
  lua_pop(L, 1);
  lua_getfield(L, -1, "__gc");
  *iscf = lua_iscfunction(L, -1);
  while (lua_getupvalue(L, -1, *nups + 1) != NULL) {
    if (*nups == 0) {
      lua_getfield(L, LUA_REGISTRYINDEX, ORIG_KEY);
      *up1orig = lua_rawequal(L, -1, -2);
      lua_pop(L, 1);
    }
    lua_pop(L, 1);
    (*nups)++;
  }
  lua_settop(L, top);
}

/* The n-th value a raw stats global returns (booleans as 1/0), -1 if absent;
 * as mem_test.c's statn. */
static double statg(lua_State *L, const char *global, int n) {
  double v = -1;
  int top = lua_gettop(L);
  lua_getglobal(L, global);
  if (!lua_isfunction(L, -1) || lua_pcall(L, 0, LUA_MULTRET, 0) != 0) { lua_settop(L, top); return -1; }
  if (lua_gettop(L) - top >= n) {
    int idx = top + n;
    if (lua_isboolean(L, idx)) v = lua_toboolean(L, idx) ? 1 : 0;
    else if (lua_isnumber(L, idx)) v = lua_tonumber(L, idx);
  }
  lua_settop(L, top);
  return v;
}
#define statn(L, n) statg((L), "_OCLJ_GCSTATS", (n))

/* Is a raw global a function? */
static int has_global_fn(lua_State *L, const char *global) {
  int r;
  lua_getglobal(L, global);
  r = lua_isfunction(L, -1);
  lua_pop(L, 1);
  return r;
}

/* ---- per-case snapshots ---------------------------------------------------- */

typedef struct {
  long viol[V_NKIND];
  long calls[F_NFN];
  long cb, cbnon, orig, holder, badver, trap;
  long shim_g, shim_w;
} Snap;

static void snap(Snap *s) {
  memcpy(s->viol, VIOL, sizeof VIOL);
  memcpy(s->calls, CALLS, sizeof CALLS);
  s->cb = CB_TOTAL; s->cbnon = CB_NONVALUE; s->orig = ORIG_TOTAL; s->holder = HOLDER_GCS;
  s->badver = GETENV_BADVER; s->trap = TRAP_TOTAL;
  s->shim_g = SHIM_LIVE[R_GLOBAL]; s->shim_w = SHIM_LIVE[R_WEAK];
}

/* JNIEnv-table calls between two snapshots (GetEnv, the JavaVM's, excluded). */
static long env_calls(const Snap *a, const Snap *b) {
  long n = 0;
  int f;
  for (f = 0; f < F_NFN; f++) if (f != F_GETENV) n += b->calls[f] - a->calls[f];
  return n;
}

/* One allocation with exactly one GC checkpoint (lua_createtable's
 * lj_gc_check), in a bare frame.  Only where a refusal is impossible: V10's
 * cap leaves 64 KB of headroom for a 64-byte table. */
static void one_alloc(lua_State *L) {
  lua_createtable(L, 0, 0);
  lua_pop(L, 1);
}

static void *foreign_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
  (void)ud; (void)osize;
  if (nsize == 0) { free(ptr); return NULL; }
  return realloc(ptr, nsize);
}

#define BIGCAP (1024LL * 1024 * 1024)

/* ===================================================================== */

int main(void) {
  char d[640];
  lua_State *L;
  Snap s0, s1;
  long long c[5];
  int rc, i;

  setvbuf(stdout, NULL, _IONBF, 0);
  printf("vgc_test -- Value disposal: the __gc wrapper on jnlua.Object, against a strict fake JNI\n");
  jni_init();

  /* ---- V0: the contract's constants ------------------------------------- */
  sprintf(d, "LJ52_JNLUA_OBJECT=\"%s\", jnlua's JNLUA_OBJECT=\"%s\"", LJ52_JNLUA_OBJECT, JNLUA_OBJECT);
  ok(strcmp(LJ52_JNLUA_OBJECT, JNLUA_OBJECT) == 0, "V0a LJ52_JNLUA_OBJECT is jnlua's own spelling", d);
  sprintf(d, "OK %d ENORECORD %d EJVM %d EREF %d EMETHOD %d ENOMT %d ENOGC %d ELUA %d",
          LJ52_VGC_OK, LJ52_VGC_ENORECORD, LJ52_VGC_EJVM, LJ52_VGC_EREF, LJ52_VGC_EMETHOD,
          LJ52_VGC_ENOMT, LJ52_VGC_ENOGC, LJ52_VGC_ELUA);
  ok(LJ52_VGC_OK == 0 && LJ52_VGC_ENORECORD == 1 && LJ52_VGC_EJVM == 2 && LJ52_VGC_EREF == 3
       && LJ52_VGC_EMETHOD == 4 && LJ52_VGC_ENOMT == 5 && LJ52_VGC_ENOGC == 6 && LJ52_VGC_ELUA == 7,
     "V0b the install codes are the contract's 0..7", d);
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V0)");
    L = jnlua_open(js, 1);
    vgcc(L, c);
    sprintf(d, "calls %ld jerr %ld closing %ld noenv %ld installed %ld",
            (long)c[0], (long)c[1], (long)c[2], (long)c[3], (long)c[4]);
    ok(c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0 && c[4] == 0,
       "V0c a state with no install reports zero counters", d);
    lua_close(L);                       /* -> lj52_close */
  }

  /* ---- V1: a Value -> one callback, BEFORE the original ----------------- */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V1)");
    FakeObj *a = obj_new(K_VALUE, "Value A (pushed before the install)");
    FakeObj *b = obj_new(K_VALUE, "Value B (pushed after)");
    int iscf, up1orig, nups, mtfalse;
    L = jnlua_open(js, 1);
    push_obj(L, a);                     /* stays on the stack across the install */
    rc = install(L, js);
    vgcc(L, c);
    gc_shape(L, &iscf, &up1orig, &nups, &mtfalse);
    sprintf(d, "rc=%d installed=%ld; __gc a C function: %s, still the original: %s; __metatable false: %s; "
               "stack %+d, locals left %ld, pending %s",
            rc, (long)c[4], iscf ? "yes" : "no", gc_is(L, ORIG_KEY) ? "YES" : "no", mtfalse ? "yes" : "no",
            INSTALL_TOP_DELTA, INSTALL_LOCALS_LEFT, INSTALL_PENDING ? INSTALL_PENDING->name : "none");
    ok(rc == LJ52_VGC_OK && c[4] == 1 && iscf && !gc_is(L, ORIG_KEY) && mtfalse
         && INSTALL_TOP_DELTA == 0 && INSTALL_PENDING == NULL,
       "V1a the install: OK, installed, a new C __gc, __metatable kept", d);
    push_obj(L, b);
    lua_settop(L, 0);
    snap(&s0);
    lua_gc(L, LUA_GCCOLLECT, 0);        /* one full cycle finalizes the dead */
    snap(&s1);
    sprintf(d, "callbacks: A %d, B %d (all %ld); to the installed state: %s; bad arguments %ld",
            a->callbacks, b->callbacks, s1.cb - s0.cb,
            a->cb_state == js && b->cb_state == js ? "yes" : "NO", s1.viol[V_ARGS] - s0.viol[V_ARGS]);
    ok(a->callbacks == 1 && b->callbacks == 1 && s1.cb - s0.cb == 2 && a->cb_state == js && b->cb_state == js
         && s1.viol[V_ARGS] == s0.viol[V_ARGS],
       "V1b one callback per Value, on the installed state, resolved method", d);
    sprintf(d, "callbacks after the original: A %d, B %d; through a deleted ref: A %d, B %d; "
               "deleted-ref uses in the collect %ld",
            a->cb_after_orig, b->cb_after_orig, a->cb_deadref, b->cb_deadref,
            s1.viol[V_DEAD] - s0.viol[V_DEAD]);
    ok(a->cb_after_orig == 0 && b->cb_after_orig == 0 && a->cb_deadref == 0 && b->cb_deadref == 0
         && s1.viol[V_DEAD] == s0.viol[V_DEAD],
       "V1c every callback before its original, through a live ref", d);
    sprintf(d, "originals: A %d, B %d (outside their own closure: %d, %d)",
            a->origs, b->origs, a->orig_badup, b->orig_badup);
    ok(a->origs == 1 && b->origs == 1 && a->orig_badup == 0 && b->orig_badup == 0,
       "V1d the original __gc ran once each, inside its own closure", d);
    sprintf(d, "GetEnv calls %ld (versions other than 1.6: %ld); calls on another thread's env %ld",
            s1.calls[F_GETENV] - s0.calls[F_GETENV], s1.badver - s0.badver, s1.viol[V_ENV] - s0.viol[V_ENV]);
    ok(s1.calls[F_GETENV] - s0.calls[F_GETENV] >= 2 && s1.badver == s0.badver && s1.viol[V_ENV] == s0.viol[V_ENV],
       "V1e the wrapper's calls on GetEnv's env, at JNI_VERSION_1_6", d);
    lua_close(L);
  }

  /* ---- V2: non-Values pass through -------------------------------------- */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V2)");
    FakeObj *x = obj_new(K_PLAIN, "a JavaFunction (pushed before the install)");
    FakeObj *y = obj_new(K_PLAIN, "a LuaError");
    FakeObj *z = obj_new(K_PLAIN, "a String");
    L = jnlua_open(js, 1);
    push_obj(L, x);
    rc = install(L, js);
    push_obj(L, y);
    push_obj(L, z);
    lua_settop(L, 0);
    snap(&s0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    snap(&s1);
    sprintf(d, "rc=%d; wrapper ran %ld times (GetEnv); callbacks %d/%d/%d; NewLocalRef %ld, CallVoidMethod %ld",
            rc, s1.calls[F_GETENV] - s0.calls[F_GETENV], x->callbacks, y->callbacks, z->callbacks,
            s1.calls[F_NEWLOCAL] - s0.calls[F_NEWLOCAL], s1.calls[F_CALLVOID] - s0.calls[F_CALLVOID]);
    ok(rc == LJ52_VGC_OK && s1.calls[F_GETENV] - s0.calls[F_GETENV] >= 3
         && x->callbacks == 0 && y->callbacks == 0 && z->callbacks == 0 && s1.cb == s0.cb
         && s1.calls[F_NEWLOCAL] == s0.calls[F_NEWLOCAL] && s1.calls[F_CALLVOID] == s0.calls[F_CALLVOID],
       "V2a non-Values: no callback, no NewLocalRef or CallVoidMethod", d);
    sprintf(d, "originals %d/%d/%d (outside their closure: %d)", x->origs, y->origs, z->origs,
            x->orig_badup + y->orig_badup + z->orig_badup);
    ok(x->origs == 1 && y->origs == 1 && z->origs == 1 && x->orig_badup + y->orig_badup + z->orig_badup == 0,
       "V2b the original __gc ran once for each non-Value", d);
    lua_close(L);
  }

  /* ---- V3: lj52_close -- no JNI for live Values, every original, release - */
  {
    enum { K = 5, J = 3 };
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V3)");
    FakeObj *o[K + J];
    long other, gotorig = 0, badup = 0;
    for (i = 0; i < K + J; i++) o[i] = obj_new(i < K ? K_VALUE : K_PLAIN, i < K ? "a live Value" : "a live non-Value");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    lua_createtable(L, K + J, 0);
    for (i = 0; i < K + J; i++) { push_obj(L, o[i]); lua_rawseti(L, -2, i + 1); }
    lua_setfield(L, LUA_REGISTRYINDEX, "vgc_test.live");
    lua_gc(L, LUA_GCCOLLECT, 0);        /* all live: nothing is finalized */
    snap(&s0);
    REL_DELCLASS = REL_DELSTATE = REL_DELOTHER = 0;
    CLOSE_SAMPLED = 0;
    IN_CLOSE = 1;
    lua_close(L);                       /* -> lj52_close */
    IN_CLOSE = 0;
    snap(&s1);
    for (i = 0; i < K + J; i++) { gotorig += o[i]->origs == 1; badup += o[i]->orig_badup; }
    sprintf(d, "rc=%d; callbacks during close %ld", rc, s1.cb - s0.cb);
    ok(rc == LJ52_VGC_OK && s1.cb == s0.cb, "V3a lj52_close: no callback for the live Values (stock parity)", d);
    sprintf(d, "%ld of %d userdata had their original exactly once (outside the closure: %ld); holder's gc %ld",
            gotorig, K + J, badup, s1.holder - s0.holder);
    ok(gotorig == K + J && badup == 0 && s1.holder - s0.holder == 1,
       "V3b the original __gc ran once for each live userdata at close", d);
    other = env_calls(&s0, &s1) - (s1.calls[F_DELGLOBAL] - s0.calls[F_DELGLOBAL])
            - (s1.calls[F_DELWEAK] - s0.calls[F_DELWEAK]);
    sprintf(d, "during lj52_close: GetEnv %ld, DeleteGlobalRef %ld (of the class %ld), DeleteWeakGlobalRef %ld "
               "(of the state %ld), deletes of anything else %ld, every other call %ld",
            s1.calls[F_GETENV] - s0.calls[F_GETENV], s1.calls[F_DELGLOBAL] - s0.calls[F_DELGLOBAL],
            REL_DELCLASS, s1.calls[F_DELWEAK] - s0.calls[F_DELWEAK], REL_DELSTATE, REL_DELOTHER, other);
    ok(s1.calls[F_GETENV] - s0.calls[F_GETENV] <= 1 && s1.calls[F_DELGLOBAL] - s0.calls[F_DELGLOBAL] <= 1
         && s1.calls[F_DELWEAK] - s0.calls[F_DELWEAK] <= 1 && REL_DELOTHER == 0 && other == 0,
       "V3c no JNI call during close but the release", d);
    sprintf(d, "the shim's live refs across close: global %ld -> %ld, weak %ld -> %ld; deleted: class %ld, "
               "state %ld; reference misuse during close %ld",
            s0.shim_g, s1.shim_g, s0.shim_w, s1.shim_w, REL_DELCLASS, REL_DELSTATE,
            s1.viol[V_DEAD] - s0.viol[V_DEAD]);
    ok(s0.shim_g - s1.shim_g == 1 && s0.shim_w - s1.shim_w == 1 && REL_DELCLASS == 1 && REL_DELSTATE == 1
         && s1.viol[V_DEAD] == s0.viol[V_DEAD],
       "V3d the class and state refs released after close, once each", d);
    sprintf(d, "closing counter read inside the holder's gc (the last finalizer at close): %s%ld, want %d",
            CLOSE_SAMPLED ? "" : "NEVER SAMPLED ", (long)CLOSE_SAMPLE[2], K + J);
    ok(CLOSE_SAMPLED && CLOSE_SAMPLE[2] == K + J,
       "V3e every jnlua.Object finalization at close counted as a closing skip", d);
  }

  /* ---- V4: an exception pending when the finalizer runs ------------------ */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V4)");
    FakeObj *v = obj_new(K_VALUE, "a Value");
    FakeObj *e1 = obj_new(K_THROWABLE, "the exception jnlua's readhandler left pending");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    push_obj(L, v);
    lua_settop(L, 0);
    PENDING[1] = e1;
    snap(&s0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    snap(&s1);
    sprintf(d, "rc=%d; calls outside the exception-safe list while it was pending: %ld",
            rc, s1.viol[V_PENDING] - s0.viol[V_PENDING]);
    ok(rc == LJ52_VGC_OK && s1.viol[V_PENDING] == s0.viol[V_PENDING],
       "V4a nothing but the exception-safe JNI calls while it is pending", d);
    sprintf(d, "callbacks %d", v->callbacks);
    ok(v->callbacks == 1, "V4b the callback is still made", d);
    sprintf(d, "pending afterwards: %s", PENDING[1] == NULL ? "nothing (LOST)" : PENDING[1] == e1 ? "the same exception" : PENDING[1]->name);
    ok(PENDING[1] == e1, "V4c the SAME exception is pending afterwards (re-thrown)", d);
    sprintf(d, "originals %d", v->origs);
    ok(v->origs == 1, "V4d the original __gc ran", d);
    PENDING[1] = NULL;
    lua_close(L);
  }

  /* ---- V5: the callback throws ------------------------------------------ */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V5)");
    FakeObj *v = obj_new(K_VALUE, "a Value whose dispose throws");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    push_obj(L, v);
    lua_settop(L, 0);
    CALLBACK_THROWS = 1;
    lua_gc(L, LUA_GCCOLLECT, 0);
    CALLBACK_THROWS = 0;
    vgcc(L, c);
    sprintf(d, "rc=%d; callbacks %d; pending after the finalizer: %s", rc, v->callbacks,
            PENDING[1] ? PENDING[1]->name : "nothing");
    ok(rc == LJ52_VGC_OK && v->callbacks == 1 && PENDING[1] == NULL,
       "V5a the callback's exception is cleared, nothing left pending", d);
    sprintf(d, "jerr %ld, calls %ld", (long)c[1], (long)c[0]);
    ok(c[1] == 1 && c[0] == 1, "V5b counted: jerr 1, calls 1", d);
    sprintf(d, "originals %d", v->origs);
    ok(v->origs == 1, "V5c the original __gc still ran", d);
    PENDING[1] = NULL;
    lua_close(L);
  }

  /* ---- V6: install twice -> one wrapper level ---------------------------- */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V6)");
    FakeObj *v = obj_new(K_VALUE, "a Value");
    int rc2, iscf, up1orig, nups, mtfalse, same;
    long g0, w0;
    char d6c[256];
    L = jnlua_open(js, 1);
    g0 = SHIM_LIVE[R_GLOBAL];
    w0 = SHIM_LIVE[R_WEAK];
    rc = install(L, js);
    gc_save(L, "vgc_test.wrapper1");
    rc2 = install(L, js);
    same = gc_is(L, "vgc_test.wrapper1");
    gc_shape(L, &iscf, &up1orig, &nups, &mtfalse);
    sprintf(d, "rc %d then %d; __gc after the second: the first's wrapper %s, upvalues %d, upvalue 1 the original %s",
            rc, rc2, same ? "yes" : "NO", nups, up1orig ? "yes" : "NO");
    ok(rc == LJ52_VGC_OK && rc2 == LJ52_VGC_OK && same && iscf && nups == 1 && up1orig,
       "V6a a second install keeps the one wrapper over the original", d);
    sprintf(d6c, "the shim's live refs after two installs: global %+ld, weak %+ld (want +1, +1)",
            SHIM_LIVE[R_GLOBAL] - g0, SHIM_LIVE[R_WEAK] - w0);
    {
      int c6 = SHIM_LIVE[R_GLOBAL] - g0 == 1 && SHIM_LIVE[R_WEAK] - w0 == 1;
      push_obj(L, v);
      lua_settop(L, 0);
      lua_gc(L, LUA_GCCOLLECT, 0);
      sprintf(d, "callbacks %d, originals %d", v->callbacks, v->origs);
      ok(v->callbacks == 1 && v->origs == 1, "V6b a Value: one callback, one original", d);
      ok(c6, "V6c the second install's refs replaced the first's", d6c);
    }
    lua_close(L);
  }

  /* ---- V7: the Lua part refuses ------------------------------------------ */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V7a)");
    long g0, w0;
    int absent;
    L = jnlua_open(js, 0);              /* no registry["jnlua.Object"] */
    g0 = SHIM_LIVE[R_GLOBAL];
    w0 = SHIM_LIVE[R_WEAK];
    rc = install(L, js);
    vgcc(L, c);
    lua_getfield(L, LUA_REGISTRYINDEX, JNLUA_OBJECT);
    absent = lua_isnil(L, -1);
    lua_pop(L, 1);
    sprintf(d, "rc=%d (ENOMT %d); registry entry still absent %s; stack %+d; pending %s; refs left: global %+ld "
               "weak %+ld local %ld; installed %ld",
            rc, LJ52_VGC_ENOMT, absent ? "yes" : "NO", INSTALL_TOP_DELTA,
            INSTALL_PENDING ? INSTALL_PENDING->name : "none", SHIM_LIVE[R_GLOBAL] - g0, SHIM_LIVE[R_WEAK] - w0,
            INSTALL_LOCALS_LEFT, (long)c[4]);
    ok(rc == LJ52_VGC_ENOMT && absent && INSTALL_TOP_DELTA == 0 && INSTALL_PENDING == NULL
         && SHIM_LIVE[R_GLOBAL] == g0 && SHIM_LIVE[R_WEAK] == w0 && INSTALL_LOCALS_LEFT == 0 && c[4] == 0,
       "V7a no jnlua.Object: ENOMT, nothing changed, nothing left", d);
    lua_close(L);
  }
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V7b)");
    long g0, w0;
    int kept;
    L = jnlua_open(js, 1);
    lua_getfield(L, LUA_REGISTRYINDEX, JNLUA_OBJECT);
    luaL_loadstring(L, "return");       /* a Lua function as __gc */
    lua_pushvalue(L, -1);
    lua_setfield(L, LUA_REGISTRYINDEX, "vgc_test.luagc");
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);
    g0 = SHIM_LIVE[R_GLOBAL];
    w0 = SHIM_LIVE[R_WEAK];
    rc = install(L, js);
    vgcc(L, c);
    kept = gc_is(L, "vgc_test.luagc");
    sprintf(d, "rc=%d (ENOGC %d); __gc still that function %s; stack %+d; pending %s; refs left: global %+ld "
               "weak %+ld local %ld; installed %ld",
            rc, LJ52_VGC_ENOGC, kept ? "yes" : "NO", INSTALL_TOP_DELTA,
            INSTALL_PENDING ? INSTALL_PENDING->name : "none", SHIM_LIVE[R_GLOBAL] - g0, SHIM_LIVE[R_WEAK] - w0,
            INSTALL_LOCALS_LEFT, (long)c[4]);
    ok(rc == LJ52_VGC_ENOGC && kept && INSTALL_TOP_DELTA == 0 && INSTALL_PENDING == NULL
         && SHIM_LIVE[R_GLOBAL] == g0 && SHIM_LIVE[R_WEAK] == w0 && INSTALL_LOCALS_LEFT == 0 && c[4] == 0,
       "V7b __gc a Lua function: ENOGC, nothing changed, nothing left", d);
    lua_close(L);
  }
  {
    /* THE FORCED REFUSAL (the review's C1).  The install's protected function
     * reports a failed CHECK by returning, never by raising, so V7a and V7b
     * leave the stack as they found it whether or not the core restores the
     * top: the only path that leaves an error object behind is the
     * lua_cpcall itself failing.  So make it fail: the accounting's native
     * cap set to one byte over 256 KB of ballast, with nothing to spare on
     * credit either (THE CREDIT's ceiling is cap + G + the kernel's slice,
     * 49 KB at the 32 KB floor of G), and the cpcall's own GCfunc
     * (lj_api.c:1140-1143, lj_func_newC) is refused inside the protected
     * frame: LUA_ERRMEM, the message left at the old top.  The refusals
     * counter (_OCLJ_GCSTATS 4) proves the refusal happened. */
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V7c)");
    long g0, w0;
    double ref0, ref1;
    int kept, rc2;
    L = jnlua_open(js, 1);
    lua_newuserdata(L, 256 * 1024);     /* ballast: no metatable, never finalized */
    lua_setfield(L, LUA_REGISTRYINDEX, "vgc_test.ballast");
    lj52_mem_settotal(L, BIGCAP);       /* C mode (docs/accounting-sync.md): no legacy JNI */
    ref0 = statn(L, 4);
    g0 = SHIM_LIVE[R_GLOBAL];
    w0 = SHIM_LIVE[R_WEAK];
    lj52_mem_settotal(L, 1);
    lua_setallocf(L, NULL, L);          /* the capped form: accounting on */
    rc = install(L, js);
    lua_setallocf(L, NULL, NULL);       /* accounting off again, and room */
    lj52_mem_settotal(L, BIGCAP);
    ref1 = statn(L, 4);
    vgcc(L, c);
    kept = gc_is(L, ORIG_KEY);
    sprintf(d, "rc=%d (ELUA %d); refusals %.0f -> %.0f; stack %+d; __gc still the original %s; pending %s; "
               "refs left: global %+ld weak %+ld local %ld; installed %ld",
            rc, LJ52_VGC_ELUA, ref0, ref1, INSTALL_TOP_DELTA, kept ? "yes" : "NO",
            INSTALL_PENDING ? INSTALL_PENDING->name : "none", SHIM_LIVE[R_GLOBAL] - g0, SHIM_LIVE[R_WEAK] - w0,
            INSTALL_LOCALS_LEFT, (long)c[4]);
    ok(rc == LJ52_VGC_ELUA && ref1 > ref0 && INSTALL_TOP_DELTA == 0 && kept && INSTALL_PENDING == NULL
         && SHIM_LIVE[R_GLOBAL] == g0 && SHIM_LIVE[R_WEAK] == w0 && INSTALL_LOCALS_LEFT == 0 && c[4] == 0,
       "V7c the protected call refused: ELUA, stack top unchanged", d);
    lua_settop(L, 0);
    rc2 = install(L, js);
    vgcc(L, c);
    sprintf(d, "rc=%d, installed %ld", rc2, (long)c[4]);
    ok(rc2 == LJ52_VGC_OK && c[4] == 1, "V7d with room again the same state installs", d);
    lua_close(L);
  }

  /* ---- V8: GetEnv fails --------------------------------------------------- */
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V8)");
    FakeObj *v = obj_new(K_VALUE, "a Value");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    push_obj(L, v);
    lua_settop(L, 0);
    GETENV_FAIL = 1;
    snap(&s0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    snap(&s1);
    GETENV_FAIL = 0;
    vgcc(L, c);
    sprintf(d, "rc=%d; GetEnv %ld (all refused); callbacks %d; JNIEnv calls %ld",
            rc, s1.calls[F_GETENV] - s0.calls[F_GETENV], v->callbacks, env_calls(&s0, &s1));
    ok(rc == LJ52_VGC_OK && s1.calls[F_GETENV] - s0.calls[F_GETENV] >= 1 && v->callbacks == 0
         && env_calls(&s0, &s1) == 0,
       "V8a GetEnv refused: no callback, no JNIEnv call", d);
    sprintf(d, "originals %d", v->origs);
    ok(v->origs == 1, "V8b the original __gc still ran (jnlua's own env lookup)", d);
    sprintf(d, "noenv %ld, calls %ld", (long)c[3], (long)c[0]);
    ok(c[3] == 1 && c[0] == 0, "V8c counted: noenv 1, calls 0", d);
    lua_close(L);
  }

  /* ---- V9: the JNI part fails --------------------------------------------- */
  {
    static const struct { const char *what; int fn; int want; } V9[] = {
      { "V9a GetMethodID fails: EMETHOD, exception cleared, nothing left", F_GETMETHOD, LJ52_VGC_EMETHOD },
      { "V9b NewWeakGlobalRef fails: EREF, exception cleared, nothing left", F_NEWWEAK, LJ52_VGC_EREF },
      { "V9c NewGlobalRef of the class fails: EREF, cleared, nothing left", F_NEWGLOBAL, LJ52_VGC_EREF },
      { "V9d GetJavaVM fails: EJVM, nothing left", F_GETJAVAVM, LJ52_VGC_EJVM },
    };
    int k;
    for (k = 0; k < 4; k++) {
      FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V9)");
      long g0, w0, hit;
      int kept;
      L = jnlua_open(js, 1);
      g0 = SHIM_LIVE[R_GLOBAL];
      w0 = SHIM_LIVE[R_WEAK];
      snap(&s0);
      if (V9[k].fn == F_GETMETHOD) FAIL_GETMETHOD = 1;
      if (V9[k].fn == F_NEWWEAK) FAIL_NEWWEAK = 1;
      if (V9[k].fn == F_NEWGLOBAL) FAIL_NEWGLOBAL = 1;
      if (V9[k].fn == F_GETJAVAVM) FAIL_GETJAVAVM = 1;
      rc = install(L, js);
      modes_off();
      snap(&s1);
      vgcc(L, c);
      kept = gc_is(L, ORIG_KEY);
      hit = s1.calls[V9[k].fn] - s0.calls[V9[k].fn];
      sprintf(d, "rc=%d (want %d); the failing call made %ld times; pending at return: %s; refs left: global %+ld "
                 "weak %+ld local %ld; __gc untouched %s; stack %+d; installed %ld",
              rc, V9[k].want, hit, INSTALL_PENDING ? INSTALL_PENDING->name : "none",
              SHIM_LIVE[R_GLOBAL] - g0, SHIM_LIVE[R_WEAK] - w0, INSTALL_LOCALS_LEFT, kept ? "yes" : "NO",
              INSTALL_TOP_DELTA, (long)c[4]);
      ok(rc == V9[k].want && hit == 1 && INSTALL_PENDING == NULL && SHIM_LIVE[R_GLOBAL] == g0
           && SHIM_LIVE[R_WEAK] == w0 && INSTALL_LOCALS_LEFT == 0 && kept && INSTALL_TOP_DELTA == 0 && c[4] == 0,
         V9[k].what, d);
      lua_close(L);
    }
  }
  {
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V9e)");
    lua_State *F = lua_newstate(foreign_alloc, NULL);   /* LuaJIT's own: not the shim's allocator */
    if (F == NULL) { printf("SETUP FAIL: lua_newstate(foreign) returned NULL\n"); return 2; }
    snap(&s0);
    rc = install(F, js);
    snap(&s1);
    vgcc(F, c);
    sprintf(d, "rc=%d (ENORECORD %d); JNI calls %ld (GetEnv %ld); stack %+d; counters %ld %ld %ld %ld %ld",
            rc, LJ52_VGC_ENORECORD, env_calls(&s0, &s1), s1.calls[F_GETENV] - s0.calls[F_GETENV],
            INSTALL_TOP_DELTA, (long)c[0], (long)c[1], (long)c[2], (long)c[3], (long)c[4]);
    ok(rc == LJ52_VGC_ENORECORD && env_calls(&s0, &s1) == 0 && s1.calls[F_GETENV] == s0.calls[F_GETENV]
         && INSTALL_TOP_DELTA == 0 && c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0 && c[4] == 0,
       "V9e a state the shim did not make: ENORECORD, no JNI call", d);
    lua_close(F);                       /* -> lj52_close: no record, a plain lua_close */
  }

  /* ---- V10: the ARMED emergency collector --------------------------------
   * lj52_gc_arm (lj52shim.c) sets stepmul 0, which makes lj_gc_step's budget
   * LJ_MAX_MEM: the next checkpoint runs a WHOLE cycle, its finalize phase
   * included (lj_gc.c:706-716).  In production that checkpoint sits inside
   * one jnlua native call, so every wrapper call of the cycle shares one JNI
   * frame and a local reference leaked per call piles up until the frame
   * returns.  The dead Values are made with the collector stopped, so the
   * armed cycle is the first to see them; the cap is handed over (C mode)
   * 64 KB above the heap, under the 128 KB watermark floor, so the first
   * allocation arms and the second one's checkpoint runs the cycle. */
  {
    enum { N = 2000 };
    static FakeObj *vals[N];
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V10)");
    double arms0, arms1, coll0, coll1;
    long long used;
    long base, peak, after, cbok = 0, origok = 0;
    for (i = 0; i < N; i++) vals[i] = obj_new(K_VALUE, "one of 2000 dead Values");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    lua_gc(L, LUA_GCCOLLECT, 0);
    lua_gc(L, LUA_GCSTOP, 0);
    lua_createtable(L, N, 0);
    for (i = 0; i < N; i++) { push_obj(L, vals[i]); lua_rawseti(L, -2, i + 1); }
    lua_settop(L, 0);                   /* all N dead, none seen by a cycle */
    lua_gc(L, LUA_GCRESTART, -1);       /* threshold at twice the heap: no step before the arm */
    lj52_mem_settotal(L, BIGCAP);
    arms0 = statn(L, 1);
    coll0 = statn(L, 2);
    used = lj52_mem_used(L);
    lj52_mem_settotal(L, used + 64 * 1024);
    lua_setallocf(L, NULL, L);          /* accounting on */
    CB_IN_STEP[1] = CB_IN_STEP[2] = ORIG_IN_STEP[1] = ORIG_IN_STEP[2] = 0;
    CUR_STEP = 1;
    one_alloc(L);                       /* arms */
    CUR_STEP = 2;
    base = LIVE[R_LOCAL];
    PEAK_LOCAL = base;
    one_alloc(L);                       /* its checkpoint runs the whole cycle */
    peak = PEAK_LOCAL;
    after = LIVE[R_LOCAL];
    CUR_STEP = 0;
    lua_setallocf(L, NULL, NULL);
    lj52_mem_settotal(L, BIGCAP);
    arms1 = statn(L, 1);
    coll1 = statn(L, 2);
    for (i = 0; i < N; i++) { cbok += vals[i]->callbacks == 1; origok += vals[i]->origs == 1; }
    sprintf(d, "rc=%d; callbacks in the arming allocation %ld, in the next one's checkpoint %ld (of %d); "
               "each Value once: callback %ld, original %ld; arms %.0f -> %.0f, collects %.0f -> %.0f",
            rc, CB_IN_STEP[1], CB_IN_STEP[2], N, cbok, origok, arms0, arms1, coll0, coll1);
    ok(rc == LJ52_VGC_OK && CB_IN_STEP[1] == 0 && CB_IN_STEP[2] == N && ORIG_IN_STEP[2] == N
         && cbok == N && origok == N && arms1 > arms0 && coll1 > coll0,
       "V10a the armed cycle: 2000 finalizations in ONE checkpoint", d);
    sprintf(d, "live local refs: %ld before the checkpoint, peak %ld during it, %ld after", base, peak, after);
    ok(peak - base <= 2 && after == base, "V10b no local-ref growth across those finalizations", d);
    lua_close(L);
  }

  /* ---- V11: the counters over a mixed population -------------------------- */
  {
    static const int VAL[12] = { 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1 };   /* 7 Values, 5 not */
    FakeObj *js = obj_new(K_STATE, "LuaStateLuaJIT (V11)");
    FakeObj *o[12];
    long once = 0, none = 0;
    double g[5];
    int k;
    for (i = 0; i < 12; i++) o[i] = obj_new(VAL[i] ? K_VALUE : K_PLAIN, VAL[i] ? "a Value" : "a non-Value");
    L = jnlua_open(js, 1);
    rc = install(L, js);
    for (i = 0; i < 12; i++) push_obj(L, o[i]);
    lua_settop(L, 0);
    snap(&s0);
    lua_gc(L, LUA_GCCOLLECT, 0);
    snap(&s1);
    vgcc(L, c);
    for (i = 0; i < 12; i++) {
      if (VAL[i]) once += o[i]->callbacks == 1;
      else none += o[i]->callbacks == 0;
    }
    sprintf(d, "rc=%d; calls %ld, callbacks received %ld; each Value once %ld/7, each non-Value never %ld/5; "
               "jerr %ld closing %ld noenv %ld installed %ld",
            rc, (long)c[0], s1.cb - s0.cb, once, none, (long)c[1], (long)c[2], (long)c[3], (long)c[4]);
    ok(rc == LJ52_VGC_OK && c[0] == 7 && s1.cb - s0.cb == 7 && once == 7 && none == 5
         && c[1] == 0 && c[2] == 0 && c[3] == 0 && c[4] == 1,
       "V11a calls == callbacks == the finalized Values", d);
    /* Where Lua reads the five: the shim's own global _OCLJ_VGCSTATS, 1-5 --
     * not _OCLJ_GCSTATS 21-25, as the contract first had it, because twenty
     * values is LUA_MINSTACK and two gates pin that count (mem_test C0c, the
     * harness's acc-1); _OCLJ_WALLSTATS is separate for the same reason.  The
     * contract's form is read only when the shim has no _OCLJ_VGCSTATS. */
    {
      int sep = has_global_fn(L, "_OCLJ_VGCSTATS");
      for (k = 0; k < 5; k++)
        g[k] = sep ? statg(L, "_OCLJ_VGCSTATS", 1 + k) : statn(L, 21 + k);
      sprintf(d, "%s: %.0f %.0f %.0f %.0f %.0f; lj52_vgc_counters: %ld %ld %ld %ld %ld",
              sep ? "_OCLJ_VGCSTATS 1-5" : "_OCLJ_GCSTATS 21-25 (no _OCLJ_VGCSTATS)",
              g[0], g[1], g[2], g[3], g[4], (long)c[0], (long)c[1], (long)c[2], (long)c[3], (long)c[4]);
    }
    ok(g[0] == (double)c[0] && g[1] == (double)c[1] && g[2] == (double)c[2] && g[3] == (double)c[3]
         && g[4] == (double)c[4],
       "V11b the Lua-side stats report the same five figures", d);
    lua_close(L);
  }

  /* ---- V12: the whole run's JNI hygiene ------------------------------------ */
  modes_off();
  sprintf(d, "calls on another thread's env %ld; GetEnv at a version other than 1.6: %ld",
          VIOL[V_ENV], GETENV_BADVER);
  ok(VIOL[V_ENV] == 0 && GETENV_BADVER == 0, "V12a every call on its thread's env, GetEnv at 1.6", d);
  sprintf(d, "deleted/unknown/mis-kinded references %ld, bad arguments %ld", VIOL[V_DEAD], VIOL[V_ARGS]);
  ok(VIOL[V_DEAD] == 0 && VIOL[V_ARGS] == 0, "V12b no dead, unknown or mis-kinded reference", d);
  sprintf(d, "calls outside the exception-safe list while an exception was pending: %ld", VIOL[V_PENDING]);
  ok(VIOL[V_PENDING] == 0, "V12c nothing unsafe while an exception is pending", d);
  sprintf(d, "trapped calls %ld", TRAP_TOTAL);
  ok(TRAP_TOTAL == 0, "V12d no JNI slot outside the contract's list", d);
  sprintf(d, "live local refs at the end: %ld", LIVE[R_LOCAL]);
  ok(LIVE[R_LOCAL] == 0, "V12e no local reference left live", d);
  sprintf(d, "live at the end: global %ld (the shim's %ld), weak %ld (the shim's %ld)",
          LIVE[R_GLOBAL], SHIM_LIVE[R_GLOBAL], LIVE[R_WEAK], SHIM_LIVE[R_WEAK]);
  ok(LIVE[R_GLOBAL] == 0 && LIVE[R_WEAK] == 0, "V12f every global and weak reference deleted", d);

  printf("\nchecks=%d failures=%d\n", checks, failures);
  return failures ? 1 : 0;
}
