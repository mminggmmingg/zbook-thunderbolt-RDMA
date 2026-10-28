#!/usr/bin/env bash
# native_tx_max_inflight(경로당 송신 중 프레임 상한, 런타임 적용) sweep. 양 노드 파라미터 파일 쓰기 권한 필요(사용자가 임시 chmod 666).
# 값마다: perftest 4줄(-u 20) + libtbvcoll all-reduce(1 MiB, 4 MiB) 2회 + 재전송·이상 로그 수. 끝나면 END 값으로 되돌린다.
#   inflight_sweep.sh "64 128 256 512" [END=64]
set -uo pipefail
VALS=${1:-"64 128 256 512"}; END=${2:-64}
E=$(cd "$(dirname "$0")" && pwd); B=parks-zbook@10.99.0.2; P=/sys/module/thunderbolt_ibverbs/parameters/native_tx_max_inflight
SUM=$E/raw/inflight_sweep.sum; : > "$SUM"; log() { echo "$*" | tee -a "$SUM"; }
setv() { echo $1 > $P && ssh -o BatchMode=yes $B "echo $1 > $P" && echo "A=$(cat $P) B=$(ssh -o BatchMode=yes $B cat $P)"; }
for v in $VALS; do
  log "## inflight=$v  ($(setv $v))  $(date +%T)"
  since=$(date '+%Y-%m-%d %H:%M:%S')
  for spec in "usb4_rdma0|1048576|0" "usb4_rdma0 usb4_rdma5|1048576|0" "usb4_rdma0 usb4_rdma5|1048576|1" "usb4_rdma0 usb4_rdma5|65536|1"; do
    IFS='|' read -r devs s bi <<< "$spec"
    log "PT $(EXTRA="-u 20" QPS=1 SIZES=$s DIRS=$bi DEVSETS="$devs" "$E/bw_matrix.sh" "if${v}_pt" 5 2>&1 | tail -1)"
  done
  for r in 1 2; do
    (cd "$E/coll" && LABEL=if${v}_r$r DT=bf16 SIZES=1048576,4194304 ITERS=200 INNER_TO=300 bash run_tbvcoll.sh >/dev/null 2>&1)
    log "AR r$r: $(grep -E '^ +[0-9]+ +[0-9]' "$E/raw/coll_if${v}_r$r.rank0.log" | awk '{printf "%s=%sus(%sGb/s) %s  ", $1, $2, $6, $7}')"
  done
  log "재전송 A=$(journalctl -k --since "$since" --no-pager | grep -c 'native retransmit') B=$(ssh -o BatchMode=yes $B "journalctl -k --since '$since' --no-pager | grep -c 'native retransmit'")  이상 A=$(journalctl -k --since "$since" --no-pager | grep -cE 'Oops|BUG:|WARNING:|timed out|stall') B=$(ssh -o BatchMode=yes $B "journalctl -k --since '$since' --no-pager | grep -cE 'Oops|BUG:|WARNING:|timed out|stall'")"
done
log "## 되돌림: $(setv $END)"
