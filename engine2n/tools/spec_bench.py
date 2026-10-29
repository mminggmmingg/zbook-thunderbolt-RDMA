# llama-server 생성 속도·추측 디코딩 채택 측정(표준 라이브러리만). greedy, 프롬프트마다 1회.
#   spec_bench.py <server URL> <prompts.json> <max_tokens> <결과 jsonl>
import json, sys, time, hashlib, urllib.request
url, pfile, nmax, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
prompts = json.load(open(pfile, encoding='utf-8'))
rows = []
for p in prompts:
    body = {"messages": [{"role": "user", "content": p["text"]}], "max_tokens": nmax, "temperature": 0,
            "cache_prompt": False, "stream": False}
    req = urllib.request.Request(url + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=1800))
    wall = time.time() - t0
    tm = r.get("timings", {})
    msg = r["choices"][0]["message"]
    text = (msg.get("reasoning_content") or "") + "\n" + (msg.get("content") or "")
    row = {"id": p["id"], "n": tm.get("predicted_n"), "tps": tm.get("predicted_per_second"),
           "draft_n": tm.get("draft_n"), "draft_acc": tm.get("draft_n_accepted"), "prompt_tps": tm.get("prompt_per_second"),
           "wall_s": round(wall, 2), "sha": hashlib.sha256(text.encode()).hexdigest()[:16], "text": text}
    rows.append(row)
    print(json.dumps({k: v for k, v in row.items() if k != "text"}, ensure_ascii=False), flush=True)
with open(out, "w") as f:
    for row in rows: f.write(json.dumps(row, ensure_ascii=False) + "\n")
n = sum(r["n"] or 0 for r in rows); t = sum((r["n"] or 0) / r["tps"] for r in rows if r["tps"])
print(f"TOTAL tokens {n}, decode {n/t:.2f} tok/s (token-weighted)")
