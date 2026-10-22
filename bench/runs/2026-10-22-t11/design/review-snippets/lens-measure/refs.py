import zlib
data = bytes(((i * 7 + 3) % 256) for i in range(1, 4097))
print("zlib crc 123456789", zlib.crc32(b"123456789"))
print("zlib crc DATA", zlib.crc32(data))
M = 0xFFFFFFFF
x = 2463534242
for s in range(1, 1001):
    x ^= (x << 13) & M
    x ^= x >> 17
    x ^= (x << 5) & M
    if s == 1:
        print("xs step1", x)
print("xs step1000", x)
d = 0xDEADBEEF
print("rotr7", ((d >> 7) | (d << 25)) & M)
acc = 0
bs = 0
for i in range(0, 4096, 4):
    acc += data[i] * 16777216 + data[i + 1] * 65536 + data[i + 2] * 256 + data[i + 3]
bs = sum(data)
print("pack ref", acc, bs, acc < 2**53)
print("sel ref", sum(k + 35 for k in range(1, 101)))
