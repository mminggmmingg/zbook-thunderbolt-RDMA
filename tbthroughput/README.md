# tbthroughput — 로드맵 4단계(TB 처리량) 측정 도구

측정 기록과 해석은 [NOTES.md](NOTES.md). A=10.99.0.1(서버 쪽), B=`parks-zbook@10.99.0.2`.

| 파일 | 용도 |
|---|---|
| `perf_pair.sh` | perftest 한 쌍(B 서버·A 클라이언트) |
| `lat_sweep.sh` | 크기별 ib_write_lat/ib_send_lat |
| `bw_matrix.sh` | ib_write_bw 행렬: 케이블 1·2개 × 단·양방향 × QP × 크기 (`EXTRA SIZES QPS DEVSETS DIRS`) |
| `cpu_during.sh` | 전송 중 양쪽 스레드별 CPU 표본 |
| `profile_tx.sh` | 송신(B) `perf record -a -g` (B 에 perf_event_paranoid=-1 필요) |
| `inflight_sweep.sh` | `native_tx_max_inflight` 런타임 sweep (파라미터 파일 쓰기 권한 필요) |
| `lanes_set.sh` | `lanes` 변경 + 재적재(sudo, 설정 백업) |
| `ab/swap.sh`, `ab/measure.sh` | 같은 부팅에서 tbv 모듈 이전/새 교체(sudo)와 한 상태 측정 |
| `coll/` | libtbvcoll 끝단 all-reduce 벤치 — `libtbvcoll/step4/libtbvcoll.cpp` 로 `libtbvcoll.so` 를 빌드해 `tbvcoll.py` 와 같은 폴더에 둔다 |
| `deploy/install-sendskip.sh` | 송신 취소 스캔 생략 수정본(tbv 4110684) 설치 스크립트 |

tbv 모듈 빌드 주의: 로드된 패치 thunderbolt.ko 와 **같은 소스 트리의 헤더와 Module.symvers** 로 빌드한다.
스톡 `/usr/src/linux-headers-*/include/linux/thunderbolt.h` 에는 패치 필드(`callback_xd` 등)가 없어, 심볼 CRC 를 억지로 맞춘 모듈은 커널 oops 를 낸다(NOTES.md §5).
