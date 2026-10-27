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
      prof = os.environ.get("PROF") == "1" and rep == 1
      if prof:
          urllib.request.urlopen(urllib.request.Request(U + "/start_profile", b"", method="POST"), timeout=120)
          print("[probe] 프로파일 시작", flush=True)
      t = time.time()
      o = post("/v1/chat/completions", {"model": "glm-5.3-flash", "max_tokens": 256, "temperature": 0,
               "messages": [{"role": "user", "content": "Thunderbolt 로 연결된 두 노트북에서 LLM 을 나눠 돌리는 방법을 짧게 설명해줘."}]})
      dt = time.time() - t; n = o["usage"]["completion_tokens"]
      m = o["choices"][0]["message"]
      print(f"[probe] chat#{rep} {n} tok / {dt:.1f}s = {n/dt:.2f} tok/s (프롬프트 포함)", flush=True)
      if prof:
          urllib.request.urlopen(urllib.request.Request(U + "/stop_profile", b"", method="POST"), timeout=600)
          print("[probe] 프로파일 종료", flush=True)
      print("[probe] chat 내용:", repr((m.get("reasoning_content") or m.get("reasoning") or "")[:150]), repr((m.get("content") or "")[:300]), flush=True)
def _nll():
    """고정 텍스트의 프롬프트 NLL(낮을수록 좋음). 가중치 int8·fp8 BMM 끄기처럼 수치가 바뀌는 설정은
    greedy 해시가 달라지므로, 품질은 이 값이 기준과 비슷한지로 본다."""
    for name in ("nll_en", "nll_ko"):
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), name + ".txt")
        if not os.path.exists(p):
            continue
        o = post("/v1/completions", {"model": "glm-5.3-flash", "prompt": open(p).read(), "max_tokens": 1,
                                     "temperature": 0, "prompt_logprobs": 0})
        lps = [next(iter(d.values()))["logprob"] for d in o["choices"][0].get("prompt_logprobs") or [] if d]
        if lps:
            print(f"[probe] NLL {name} {-sum(lps)/len(lps):.4f} ({len(lps)} tok)", flush=True)
def _reasoning_check():
    """REASONING=1 일 때: 생각을 끝내고 답할 만큼 길게(1024) + reasoning_effort=low 로 한 번 보내,
    파서가 reasoning_content 와 content 를 실제로 나누는지 본다(256 토큰은 생각 도중에 끊길 수 있다)."""
    if os.environ.get("REASONING") != "1":
        return
    # low: 생각을 짧게(또는 생략) 하고 답함 → content 확인. max(기본): 생각이 길게 나옴 → reasoning 필드 확인.
    for effort, mt in (("low", 1024), ("max", 1536)):
      _one_reasoning_check(effort, mt)
def _one_reasoning_check(effort, mt):
    t = time.time()
    o = post("/v1/chat/completions", {"model": "glm-5.3-flash", "max_tokens": mt, "temperature": 0,
             "chat_template_kwargs": {"reasoning_effort": effort},
             "messages": [{"role": "user", "content": "Thunderbolt 로 연결된 두 노트북에서 LLM 을 나눠 돌리는 방법을 3문장으로 설명해줘."}]})
    dt = time.time() - t; n = o["usage"]["completion_tokens"]; m = o["choices"][0]["message"]
    rc, ct = m.get("reasoning_content") or m.get("reasoning") or "", m.get("content") or ""
    print(f"[probe] 파서확인({effort}) {n} tok / {dt:.1f}s = {n/dt:.2f} tok/s, finish={o['choices'][0].get('finish_reason')}, "
          f"reasoning {len(rc)}자, content {len(ct)}자, content 안 <think>: {'<think>' in ct or '</think>' in ct}", flush=True)
    print(f"[probe] 파서확인({effort}) 생각:", repr(rc[:200]), flush=True)
    print(f"[probe] 파서확인({effort}) 답변:", repr(ct[:400]), flush=True)
if os.environ.get("CHAT_FIRST")=="1":
    _chat(); _comp()
else:
    _comp(); _chat()
_reasoning_check()
_nll()
