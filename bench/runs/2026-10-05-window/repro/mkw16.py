# mkw16.py -- mem_test.c + the proposed W16 case -> mem_test_w16.c (repro only).
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline="").read()
chunk = open("w16_chunk.c.txt", newline="").read()
case = open("w16_case.c.txt", newline="").read()
defs = "#ifndef W16_N\n#define W16_N 96             /* caps in the sweep */\n#endif\n#ifndef W16_STEP\n#define W16_STEP 64          /* bytes between them: 96 x 64 B is one step of the fill */\n#endif\n"
anchor = "int main(void) {"
assert s.count(anchor) == 1
s = s.replace(anchor, defs + chunk + "\n" + anchor, 1)
# the case goes after W11, at the end of the W block
anchor2 = """    ok(st == 0 && st2 == LUA_YIELD && nreq == 2,
       "W11 live data past total + G/2: the reserve tier, not a refusal", d);
    lua_settop(W, 0);
    clear_javastate(W);
    lua_close(W);
"""
assert s.count(anchor2) == 1
s = s.replace(anchor2, anchor2 + case, 1)
open(dst, "w", newline="").write(s)
print("ok")
