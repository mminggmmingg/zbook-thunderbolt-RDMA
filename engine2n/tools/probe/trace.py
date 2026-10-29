# AR 호출별 기록(trace-a/b.txt: idx gap sync net bytes)을 토큰 주기로 접어 위치별 평균을 낸다. argv: run_dir [period]
import sys, statistics as st
d = sys.argv[1]; P = int(sys.argv[2]) if len(sys.argv) > 2 else 0
def load(f):
    rows = [list(map(int, l.split())) for l in open(f)]
    return [r for r in rows if r[4] == 10240]          # 디코드 AR 만(10 KiB)
A, B = load(d + '/trace-a.txt'), load(d + '/trace-b.txt')
def best_period(rows):
    s = [r[2] for r in rows]
    best = None
    for p in range(90, 106):
        groups = [[s[i] for i in range(k, len(s), p)] for k in range(p)]
        v = sum(st.pvariance(g) for g in groups if len(g) > 1) / p
        if best is None or v < best[1]: best = (p, v)
    return best[0]
if not P: P = best_period(A); print('period', P, '(B best', best_period(B), ')')
def fold(rows):
    base = rows[0][0]
    acc = {}
    for r in rows:
        acc.setdefault((r[0] - base) % P, []).append(r)
    return {k: (st.mean(x[1] for x in v), st.median(x[2] for x in v), st.mean(x[3] for x in v)) for k, v in acc.items()}
fa, fb = fold(A), fold(B)
# B 와 A 의 인덱스 기준을 맞춘다: 같은 AR 은 같은 전역 번호를 갖는다고 가정(두 서버 모두 처음부터 같은 순서로 AR 을 셈)
off = (B[0][0] - A[0][0]) % P
print(f"{'pos':>3} {'A sync':>7} {'B sync':>7} {'B/A':>5} {'A net':>6} {'B net':>6}")
tot = [0, 0, 0]
for k in range(P):
    a = fa.get(k); b = fb.get((k - off) % P)
    if not a or not b: continue
    tot[0] += a[1]; tot[1] += b[1]; tot[2] += max(a[1], b[1])
    print(f"{k:>3} {a[1]:>7.0f} {b[1]:>7.0f} {b[1]/max(a[1],1):>5.2f} {a[2]:>6.0f} {b[2]:>6.0f}")
print(f"sum of median sync per token: A {tot[0]/1000:.1f} ms, B {tot[1]/1000:.1f} ms, max(A,B) {tot[2]/1000:.1f} ms")
