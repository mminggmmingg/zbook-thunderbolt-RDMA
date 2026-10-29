# rocprofv3 kernel trace → GPU 바쁨/쉼 분석. argv: kernel_trace.csv [창 초(끝에서부터)] [토큰 수]
import csv, sys, collections
f = sys.argv[1]; win = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0; ntok = int(sys.argv[3]) if len(sys.argv) > 3 else 0
K = []
with open(f) as fh:
    for r in csv.DictReader(fh):
        K.append((int(r['Start_Timestamp']), int(r['End_Timestamp']), r['Kernel_Name']))
K.sort()
t_end = K[-1][1]; K = [k for k in K if k[0] >= t_end - win * 1e9]
t0 = K[0][0]; span = t_end - t0
busy = 0; cur_s, cur_e = K[0][0], K[0][1]; gaps = []  # (gap_ns, prev_name, next_name)
prev_name = K[0][2]
for s, e, n in K[1:]:
    if s > cur_e:
        busy += cur_e - cur_s; gaps.append((s - cur_e, prev_name, n)); cur_s, cur_e = s, e
    else:
        cur_e = max(cur_e, e)
    prev_name = n
busy += cur_e - cur_s
print(f"window {span/1e6:.1f} ms, kernels {len(K)}, GPU busy {busy/span*100:.1f}%, idle {(span-busy)/1e6:.1f} ms")
if ntok: print(f"per token: {span/ntok/1e6:.2f} ms, kernels {len(K)/ntok:.0f}, busy {busy/ntok/1e6:.2f} ms, idle {(span-busy)/ntok/1e6:.2f} ms")
B = [(0, 2e3), (2e3, 5e3), (5e3, 10e3), (10e3, 30e3), (30e3, 100e3), (100e3, 1e12)]
for lo, hi in B:
    g = [x for x in gaps if lo <= x[0] < hi]
    print(f"  gaps {lo/1e3:>5.0f}-{hi/1e3:<6.0f}us: n {len(g):>7}, total {sum(x[0] for x in g)/1e6:8.1f} ms ({sum(x[0] for x in g)/span*100:5.1f}% of time)")
short = lambda n: n.split('(')[0].replace('void ', '')[:60]
big = collections.Counter(); bign = collections.Counter()
for g, p, n in gaps:
    if g >= 10e3:
        key = f"{short(p)} -> {short(n)}"; big[key] += g; bign[key] += 1
print("largest gap kinds (>=10us):")
for k, v in big.most_common(8): print(f"  {v/1e6:8.1f} ms  n {bign[k]:>6}  {k}")
tk = collections.Counter(); nk = collections.Counter()
for s, e, n in K: tk[short(n)] += e - s; nk[short(n)] += 1
print("top kernels by GPU time:")
for k, v in tk.most_common(12): print(f"  {v/1e6:8.1f} ms  n {nk[k]:>6}  avg {v/nk[k]/1e3:6.1f} us  {k}")
