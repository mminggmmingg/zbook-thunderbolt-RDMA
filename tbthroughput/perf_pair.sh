#!/usr/bin/env bash
# perftest 한 쌍: B 에서 서버, A 에서 클라이언트. 결과는 OUT 에 남긴다.
#   perf_pair.sh <ib_write_lat|ib_send_lat|ib_write_bw|...> <A 장치> <B 장치> <라벨> [perftest 추가 인자...]
# RoCE v2 GID index 1(thunderbolt0 IPv4). 제어 TCP 는 10.99.0.2.
set -uo pipefail
TOOL=$1 ADEV=$2 BDEV=$3 LABEL=$4; shift 4
B=parks-zbook@10.99.0.2
OUT=${OUT:-$(cd "$(dirname "$0")" && pwd)/raw}; mkdir -p "$OUT"
PORT=${PORT:-18$((RANDOM % 900 + 100))}
F="$OUT/${LABEL}_${TOOL}_${ADEV}-${BDEV}.txt"
ssh -o BatchMode=yes "$B" "timeout 300 $TOOL -d $BDEV -x 1 -p $PORT $* > /tmp/perf_srv_$PORT.log 2>&1" &
SP=$!
sleep 1.5
timeout 300 $TOOL -d "$ADEV" -x 1 -p "$PORT" "$@" 10.99.0.2 > "$F" 2>&1
rc=$?
wait $SP
ssh -o BatchMode=yes "$B" "cat /tmp/perf_srv_$PORT.log" > "${F%.txt}.server.txt" 2>&1
echo "rc=$rc $F"
