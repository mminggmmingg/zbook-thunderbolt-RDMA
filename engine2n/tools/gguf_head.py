# GGUF 머리 읽기(표준 라이브러리만): 메타데이터와 텐서 목록. 긴 배열은 길이만. argv: 파일 [키 필터]
import struct, sys
f = open(sys.argv[1], 'rb'); flt = sys.argv[2] if len(sys.argv) > 2 else ''
rd = lambda fmt: struct.unpack('<' + fmt, f.read(struct.calcsize('<' + fmt)))[0]
def s(): n = rd('Q'); return f.read(n).decode('utf-8', 'replace')
SC = {0: 'B', 1: 'b', 2: 'H', 3: 'h', 4: 'I', 5: 'i', 6: 'f', 7: '?', 10: 'Q', 11: 'q', 12: 'd'}
def val(t):
    if t in SC: return rd(SC[t])
    if t == 8: return s()
    if t == 9:
        et = rd('I'); n = rd('Q')
        items = [val(et) for _ in range(n)]
        return items if n <= 8 or flt else f"array[{n}]"
    raise ValueError(t)
assert f.read(4) == b'GGUF'; ver = rd('I'); nt = rd('Q'); nkv = rd('Q')
print('version', ver, 'tensors', nt, 'kv', nkv)
for _ in range(nkv):
    k = s(); t = rd('I'); v = val(t)
    if not k.startswith('tokenizer') and flt in k: print(' ', k, '=', v)
TN = {0:'F32',1:'F16',8:'Q8_0',14:'Q6_K',20:'IQ4_NL',21:'IQ3_S',23:'IQ4_XS',30:'BF16'}
for _ in range(nt):
    name = s(); nd = rd('I'); dims = [rd('Q') for _ in range(nd)]; ty = rd('I'); off = rd('Q')
    if flt in name or not flt: print('  T', name, TN.get(ty, ty), dims)
