"""시험 요청: 결정적(greedy) 완성 3개 → 출력 해시, 긴 생성 1개 → 디코드 속도."""
import hashlib, json, sys, time, urllib.request
U = sys.argv[1]
def post(path, body):
    r = urllib.request.Request(U + path, json.dumps(body).encode(), {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=1200))
P = ["The capital of France is", "def fibonacci(n):\n", "한국의 수도는 어디이고, 그 도시의 특징을 설명하면"]
import os
def _comp():
    for i, p in enumerate(P):
        t = time.time(); o = post("/v1/completions", {"model": "glm-5.3-flash", "prompt": p, "max_tokens": 64, "temperature": 0})
        txt = o["choices"][0]["text"]
        print(f"[probe] {i} {time.time()-t:.1f}s 해시 {hashlib.sha256(txt.encode()).hexdigest()[:16]} {txt[:120]!r}", flush=True)
def _chat():
    for rep in range(int(__import__("os").environ.get("CHAT_REPS","1"))):
      t = time.time()
      o = post("/v1/chat/completions", {"model": "glm-5.3-flash", "max_tokens": 256, "temperature": 0,
               "messages": [{"role": "user", "content": "Thunderbolt 로 연결된 두 노트북에서 LLM 을 나눠 돌리는 방법을 짧게 설명해줘."}]})
      dt = time.time() - t; n = o["usage"]["completion_tokens"]
      m = o["choices"][0]["message"]
      print(f"[probe] chat#{rep} {n} tok / {dt:.1f}s = {n/dt:.2f} tok/s (프롬프트 포함)", flush=True)
      print("[probe] chat 내용:", repr((m.get("reasoning_content") or "")[:150]), repr((m.get("content") or "")[:300]), flush=True)
if os.environ.get("CHAT_FIRST")=="1":
    _chat(); _comp()
else:
    _comp(); _chat()
