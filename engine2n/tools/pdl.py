"""병렬 구간 다운로더: Range 요청 여러 개를 파일의 제자리(pwrite)에 바로 쓴다 — 메모리 사용이 일정하다.
완료한 조각 번호를 <dest>.part.done 에 한 줄씩 남겨 중단 후 이어받는다. 끝나면 크기와 sha256 을 확인하고 이름을 바꾼다.

  python3 -I pdl.py <url> <dest> <size> <sha256> [workers] [chunk_MiB]
"""
import hashlib, os, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

url, dest, size, sha = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
workers = int(sys.argv[5]) if len(sys.argv) > 5 else 8
chunk = (int(sys.argv[6]) if len(sys.argv) > 6 else 64) << 20
part, donef = dest + ".part", dest + ".part.done"
n = (size + chunk - 1) // chunk

if os.path.exists(dest) and os.path.getsize(dest) == size:
    print(f"{os.path.basename(dest)}: 이미 있음(크기 일치) — 건너뜀", flush=True)
    sys.exit(0)
done = set()
if os.path.exists(donef):
    done = {int(x) for x in open(donef).read().split()}
fd = os.open(part, os.O_RDWR | os.O_CREAT, 0o644)
if os.fstat(fd).st_size != size:
    os.ftruncate(fd, size)
lock = threading.Lock()
got = [0]
t0 = time.time()


def fetch(i):
    lo = i * chunk
    hi = min(size, lo + chunk) - 1
    last = None
    for attempt in range(8):
        try:
            req = urllib.request.Request(url, headers={"Range": f"bytes={lo}-{hi}", "User-Agent": "pdl/1"})
            with urllib.request.urlopen(req, timeout=60) as r:
                if r.status != 206:
                    raise RuntimeError(f"HTTP {r.status} (구간 요청 미지원)")
                off = lo
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    os.pwrite(fd, b, off)
                    off += len(b)
                    with lock:
                        got[0] += len(b)
            if off != hi + 1:
                raise RuntimeError(f"짧은 응답 {off - lo}/{hi - lo + 1}")
            return i
        except Exception as e:  # 재시도(지수 대기)
            last = e
            time.sleep(min(60, 2 ** attempt))
    raise RuntimeError(f"조각 {i} 실패: {last}")


todo = [i for i in range(n) if i not in done]
print(f"{os.path.basename(dest)}: {n} 조각 중 {len(done)} 완료, {len(todo)} 남음, 병렬 {workers}", flush=True)
with ThreadPoolExecutor(workers) as ex, open(donef, "a") as dfh:
    futs = [ex.submit(fetch, i) for i in todo]
    last_print = 0
    for k, f in enumerate(as_completed(futs), 1):
        i = f.result()
        dfh.write(f"{i}\n"); dfh.flush()
        now = time.time()
        if now - last_print > 30 or k == len(futs):
            last_print = now
            rate = got[0] / max(1e-9, now - t0) / 2**20
            have = (len(done) + k) * chunk
            print(f"  {min(have, size)/2**30:.1f}/{size/2**30:.1f} GiB, {rate:.1f} MiB/s", flush=True)
os.fsync(fd); os.close(fd)

h = hashlib.sha256()
with open(part, "rb") as f:
    while True:
        b = f.read(64 << 20)
        if not b:
            break
        h.update(b)
if os.path.getsize(part) != size or h.hexdigest() != sha:
    print(f"검증 실패: size={os.path.getsize(part)} sha={h.hexdigest()}", flush=True)
    sys.exit(2)
os.rename(part, dest)
print(f"완료·검증 OK: {dest}", flush=True)
