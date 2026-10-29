# 큰 GPU 쉼(>200us)을 호스트 HIP API 활동으로 분류. argv: run_dir
import csv, sys, collections, bisect
d = sys.argv[1]
K = []
with open(d + '/a_kernel_trace.csv') as fh:
    for r in csv.DictReader(fh):
        K.append((int(r['Start_Timestamp']), int(r['End_Timestamp']), r['Kernel_Name'].split('(')[0].replace('void ', '')[:28]))
K.sort(); t_end = K[-1][1]; K = [k for k in K if k[0] >= t_end - 2.0e9]
A = []
with open(d + '/a_hip_api_trace.csv') as fh:
    for r in csv.DictReader(fh):
        s = int(r['Start_Timestamp'])
        if s >= t_end - 2.3e9: A.append((s, int(r['End_Timestamp']), r['Function']))
A.sort(); starts = [a[0] for a in A]
cls = collections.Counter(); clst = collections.Counter(); ctx = collections.Counter()
for i in range(1, len(K)):
    gs, ge = K[i-1][1], K[i][0]
    if ge - gs < 200e3: continue
    lo = bisect.bisect_left(starts, gs - 2e6)
    ov = collections.Counter()
    last_before = None
    for a in A[lo:]:
        if a[0] >= ge: break
        o = min(a[1], ge) - max(a[0], gs)
        if o > 0: ov[a[2]] += o
        if a[0] < gs: last_before = a[2]
    tot = sum(ov.values())
    c = 'no HIP call (host elsewhere)' if tot < 0.2 * (ge - gs) else 'in ' + ov.most_common(1)[0][0]
    key = f"{c} | after {K[i-1][2]} -> {K[i][2]}"
    cls[key] += 1; clst[key] += ge - gs
for k, n in clst.most_common(12): print(f"{n/1e6:7.1f} ms  n {cls[k]:>4}  avg {n/cls[k]/1e3:6.0f} us  {k}")
