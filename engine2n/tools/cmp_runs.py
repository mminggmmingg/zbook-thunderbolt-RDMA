# 두 spec_bench 결과(results.jsonl)의 프롬프트별 속도와 출력 비교: 같은지, 다르면 처음 갈라지는 위치와 주변. argv: A B
import sys, json
a = {r['id']: r for r in map(json.loads, open(sys.argv[1]))}
b = {r['id']: r for r in map(json.loads, open(sys.argv[2]))}
for k in a:
    x, y = a[k].get('text', ''), b[k].get('text', '')
    i = next((j for j in range(min(len(x), len(y))) if x[j] != y[j]), min(len(x), len(y)))
    same = x == y
    print(f"{k:8} {a[k]['tps']:5.1f} -> {b[k]['tps']:5.1f} t/s  same={same}" + ("" if same else f"  first diff at char {i}/{len(x)}"))
    if not same:
        print("     A: " + repr(x[max(0, i-60):i+60]))
        print("     B: " + repr(y[max(0, i-60):i+60]))
