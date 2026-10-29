# rocprofv3 kernel trace → (커널 이름, grid) 묶음별 토큰당 시간. 토큰 수는 토큰마다 한 번인 표지 커널(기본 topk_moe 48회=1토큰)로 센다.
#   kgroups.py <kernel_trace.csv> [끝에서 몇 초] [표지 커널 부분이름] [표지 커널 토큰당 횟수]
import csv, sys, collections, re
f = sys.argv[1]; win = float(sys.argv[2]) if len(sys.argv) > 2 else 1.2
marker = sys.argv[3] if len(sys.argv) > 3 else 'topk_moe'; per_tok = int(sys.argv[4]) if len(sys.argv) > 4 else 48
K = []
with open(f) as fh:
    for r in csv.DictReader(fh):
        K.append((int(r['Start_Timestamp']), int(r['End_Timestamp']), r['Kernel_Name'], int(r['Grid_Size_X']), int(r['Workgroup_Size_X'])))
K.sort(); t_end = K[-1][1]; K = [k for k in K if k[0] >= t_end - win * 1e9]
ntok = sum(1 for k in K if marker in k[2]) / per_tok
span = K[-1][1] - K[0][0]
def short(n):
    n = n.replace('void ', '')
    m = re.match(r'([A-Za-z_0-9]+)(<.*?>)?\(', n)
    if not m: return n[:70]
    tpl = (m.group(2) or '')
    tpl = re.sub(r'\(ggml_type\)', 't', tpl)
    return (m.group(1) + tpl)[:90]
g = collections.defaultdict(lambda: [0, 0])
busy = 0
for s, e, n, gx, wx in K:
    key = (short(n), gx, wx); g[key][0] += e - s; g[key][1] += 1; busy += e - s
print(f"window {span/1e6:.1f} ms, tokens {ntok:.1f}, per token {span/ntok/1e6:.2f} ms, kernel time/token {busy/ntok/1e6:.2f} ms, kernels/token {len(K)/ntok:.0f}")
tot = sum(v[0] for v in g.values())
acc = 0
for (n, gx, wx), (t, c) in sorted(g.items(), key=lambda x: -x[1][0])[:40]:
    acc += t
    print(f"{t/ntok/1e3:8.0f} us/tok {100*t/tot:5.1f}% (cum {100*acc/tot:5.1f}%) n/tok {c/ntok:6.1f} avg {t/c/1e3:6.1f} us  grid {gx:>7} wg {wx:>4}  {n}")
