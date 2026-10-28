"""RCCL all-reduce over tbv (GLM 과 같은 NCCL 설정). 크기별 20회, 결과 확인, 평균 시간.
환경: RANK, MASTER_ADDR, MASTER_PORT (WORLD_SIZE=2)."""
import datetime, os, time, torch, torch.distributed as dist

rank = int(os.environ["RANK"])
torch.cuda.set_device(0)
t0 = time.time()
dist.init_process_group("nccl", rank=rank, world_size=2, timeout=datetime.timedelta(seconds=150))
print(f"[r{rank}] init_process_group {time.time() - t0:.1f}s", flush=True)
for nbytes in (4096, 65536, 1 << 20, 16 << 20, 64 << 20):
    n = nbytes // 2
    x = torch.full((n,), float(rank + 1), dtype=torch.bfloat16, device="cuda")
    t = time.time()
    dist.all_reduce(x)
    torch.cuda.synchronize()
    first = time.time() - t
    ok = bool(torch.all(x == 3.0))
    t = time.time()
    for _ in range(20):
        dist.all_reduce(x)
    torch.cuda.synchronize()
    dt = (time.time() - t) / 20
    if rank == 0:
        print(f"[r0] {nbytes:>9} B  첫 {first*1e3:8.1f} ms  평균 {dt*1e6:9.1f} us  algbw {nbytes*8/dt/1e9:6.2f} Gb/s  {'OK' if ok else 'BAD'}", flush=True)
dist.destroy_process_group()
print(f"[r{rank}] 끝", flush=True)
