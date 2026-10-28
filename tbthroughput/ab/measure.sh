#!/usr/bin/env bash
# A/B 한 상태 측정: 로드된 모듈 확인 → B 부하 표본 → libtbvcoll all-reduce(256K/1M/4M) 3회 → perftest 대표 4줄 → 재전송·이상 로그 수.
#   measure.sh <라벨>   결과: raw/ab_<라벨>.sum
set -uo pipefail
L=$1; E=$(cd "$(dirname "$0")/.." && pwd); B=parks-zbook@10.99.0.2; SUM=$E/raw/ab_$L.sum; : > "$SUM"
log() { echo "$*" | tee -a "$SUM"; }
since=$(date '+%Y-%m-%d %H:%M:%S')
log "## $L  $(date '+%F %T')  A=$(cat /sys/module/thunderbolt_ibverbs/srcversion) B=$(ssh -o BatchMode=yes $B cat /sys/module/thunderbolt_ibverbs/srcversion)"
log "B 부하: $(ssh -o BatchMode=yes $B "top -bn1 -w 160 | sed -n '3p'; top -bn1 -w 160 | sed -n '8,10p' | awk '{printf \"%s %s%% | \", \$12, \$9}'")"
for r in 1 2 3; do
  (cd "$E/coll" && LABEL=ab_${L}_r$r DT=bf16 SIZES=262144,1048576,4194304 ITERS=300 bash run_tbvcoll.sh >/dev/null 2>&1)
  log "AR r$r: $(grep -E '^ +[0-9]+ +[0-9]' "$E/raw/coll_ab_${L}_r$r.rank0.log" | awk '{printf "%s=%sus(%sGb/s)  ", $1, $2, $6}')"
done
for spec in "usb4_rdma0|1048576|0" "usb4_rdma0 usb4_rdma5|1048576|0" "usb4_rdma0 usb4_rdma5|1048576|1" "usb4_rdma0 usb4_rdma5|65536|1"; do
  IFS='|' read -r devs s bi <<< "$spec"
  r=$(EXTRA="-u 20" QPS=1 SIZES=$s DIRS=$bi DEVSETS="$devs" "$E/bw_matrix.sh" "ab_${L}_pt" 5 2>&1 | tail -1)
  log "PT $r"
done
log "재전송 A=$(journalctl -k --since "$since" --no-pager | grep -c 'native retransmit') B=$(ssh -o BatchMode=yes $B "journalctl -k --since '$since' --no-pager | grep -c 'native retransmit'")  이상 A=$(journalctl -k --since "$since" --no-pager | grep -cE 'Oops|BUG:|WARNING:') B=$(ssh -o BatchMode=yes $B "journalctl -k --since '$since' --no-pager | grep -cE 'Oops|BUG:|WARNING:'")"
