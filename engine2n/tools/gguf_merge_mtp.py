# 공유형 MTP GGUF(nextn_shared_target_tensors) 에 본 모델의 텐서를 붙여 단독으로 열리는 MTP 파일을 만든다(표준 라이브러리, 스트리밍 복사).
#   gguf_merge_mtp.py <mtp.gguf> <본 모델 조각.gguf> <출력.gguf> <텐서 이름>...
import struct, sys, os, shutil
TYPE_SIZE = {0: (1, 4), 1: (1, 2), 30: (1, 2), 8: (32, 34), 14: (256, 210), 20: (32, 18), 21: (256, 110), 23: (256, 136)}

def parse(path):
    f = open(path, 'rb')
    rd = lambda fmt: struct.unpack('<' + fmt, f.read(struct.calcsize('<' + fmt)))[0]
    def s(): n = rd('Q'); return f.read(n).decode('utf-8', 'replace')
    SC = {0: 'B', 1: 'b', 2: 'H', 3: 'h', 4: 'I', 5: 'i', 6: 'f', 7: '?', 10: 'Q', 11: 'q', 12: 'd'}
    def val(t):
        if t in SC: return rd(SC[t])
        if t == 8: return s()
        if t == 9:
            et = rd('I'); n = rd('Q'); return [val(et) for _ in range(n)]
        raise ValueError(t)
    assert f.read(4) == b'GGUF'; ver = rd('I'); nt = rd('Q'); nkv = rd('Q')
    kv_start = f.tell(); align = 32
    for _ in range(nkv):
        k = s(); t = rd('I'); v = val(t)
        if k == 'general.alignment': align = v
    kv_end = f.tell()
    tensors = []
    for _ in range(nt):
        name = s(); nd = rd('I'); dims = [rd('Q') for _ in range(nd)]; ty = rd('I'); off = rd('Q')
        tensors.append((name, dims, ty, off))
    info_end = f.tell()
    data_start = (info_end + align - 1) // align * align
    return dict(path=path, ver=ver, nkv=nkv, kv=(kv_start, kv_end), tensors=tensors, data=data_start, align=align)

def nbytes(dims, ty):
    n = 1
    for d in dims: n *= d
    blk, sz = TYPE_SIZE[ty]
    assert n % blk == 0
    return n // blk * sz

mtp_p, main_p, out_p, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
A = parse(mtp_p); B = parse(main_p); align = A['align']
extra = [t for t in B['tensors'] if t[0] in names]
assert len(extra) == len(names), f"missing in main: {set(names) - {t[0] for t in extra}}"
plan = []  # (name, dims, type, src_path, src_abs_offset, nbytes)
for name, dims, ty, off in A['tensors']: plan.append((name, dims, ty, mtp_p, A['data'] + off, nbytes(dims, ty)))
for name, dims, ty, off in extra: plan.append((name, dims, ty, main_p, B['data'] + off, nbytes(dims, ty)))
out = open(out_p + '.tmp', 'wb')
w = lambda fmt, v: out.write(struct.pack('<' + fmt, v))
out.write(b'GGUF'); w('I', A['ver']); w('Q', len(plan)); w('Q', A['nkv'])
src = open(mtp_p, 'rb'); src.seek(A['kv'][0]); out.write(src.read(A['kv'][1] - A['kv'][0]))
off = 0; offs = []
for name, dims, ty, _, _, nb in plan:
    offs.append(off); off = (off + nb + align - 1) // align * align
for (name, dims, ty, _, _, nb), o in zip(plan, offs):
    b = name.encode(); w('Q', len(b)); out.write(b); w('I', len(dims))
    for d in dims: w('Q', d)
    w('I', ty); w('Q', o)
pad = (-out.tell()) % align; out.write(b'\0' * pad); data0 = out.tell()
for (name, dims, ty, sp, so, nb), o in zip(plan, offs):
    assert out.tell() == data0 + o
    with open(sp, 'rb') as f:
        f.seek(so); left = nb
        while left:
            chunk = f.read(min(left, 64 << 20)); assert chunk; out.write(chunk); left -= len(chunk)
    out.write(b'\0' * ((-nb) % align))
out.close(); os.replace(out_p + '.tmp', out_p)
print(f"wrote {out_p}: {len(plan)} tensors ({len(extra)} from main), {os.path.getsize(out_p)/1e9:.2f} GB")
