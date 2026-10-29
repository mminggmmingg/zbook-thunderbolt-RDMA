# GPU 쉼(>300us, 끝 2초)마다 그 사이 호스트의 HIP API 호출을 모은다. argv: run_dir(a_kernel_trace.csv, a_hip_api_trace.csv)
import csv, sys, collections, bisect
d = sys.argv[1]
K = []
with open(d + '/a_kernel_trace.csv') as fh:
    for r in csv.DictReader(fh):
        K.append((int(r['Start_Timestamp']), int(r['End_Timestamp']), r['Kernel_Name'].split('(')[0].replace('void ', '')[:40]))
K.sort(); t_end = K[-1][1]; K = [k for k in K if k[0] >= t_end - 2.0e9]
A = []
with open(d + '/a_hip_api_trace.csv') as fh:
    for r in csv.DictReader(fh):
        s = int(r['Start_Timestamp'])
        if s >= t_end - 2.2e9: A.append((s, int(r['End_Timestamp']), r['Function'], r['Thread_Id']))
A.sort(); starts = [a[0] for a in A]
gaps = [(K[i-1][1], K[i][0], K[i-1][2], K[i][2]) for i in range(1, len(K)) if K[i][0] - K[i-1][1] > 300e3]
print('big gaps', len(gaps))
agg = collections.Counter(); aggn = collections.Counter()
for gi, (gs, ge, pn, nn) in enumerate(gaps):
    lo = bisect.bisect_left(starts, gs - 50e3); calls = [a for a in A[lo:] if a[0] < ge]
    for a in calls:
        ov = min(a[1], ge) - max(a[0], gs)
        if ov > 0: agg[a[2]] += ov; aggn[a[2]] += 1
    if gi < 2:
        print(f"-- gap {(ge-gs)/1e3:.0f} us after {pn} before {nn}")
        for a in calls:
            if a[1] - a[0] > 5e3 or a[2] not in ('hipLaunchKernel', 'hipModuleLaunchKernel', 'hipExtModuleLaunchKernel'):
                print(f"   {(a[0]-gs)/1e3:8.1f} us dur {(a[1]-a[0])/1e3:8.1f}  tid {a[3]}  {a[2]}")
print('API time overlapping the gaps (sum over gaps):')
for k, v in agg.most_common(10): print(f"  {v/1e6:8.2f} ms  n {aggn[k]:>6}  {k}")
