#!/usr/bin/env bash
# 크기별 지연 sweep(memlock 8 MiB 안에서 1 MiB 까지). 한 줄 요약: 크기 t_min t_typical t_avg t_99 t_99.9 (µs)
#   lat_sweep.sh <ib_write_lat|ib_send_lat> <A 장치> <B 장치> <라벨> [반복=2000]
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
TOOL=$1 ADEV=$2 BDEV=$3 LABEL=$4 N=${5:-2000}
SUM="$D/raw/${LABEL}_${TOOL}_${ADEV}-${BDEV}.sum"; mkdir -p "$D/raw"; : > "$SUM"
for S in 2 64 1024 4096 10240 16384 65536 262144 1048576; do
  OUT=$D/raw/sweep PORT=18$((RANDOM % 900 + 100)) "$D/perf_pair.sh" "$TOOL" "$ADEV" "$BDEV" "${LABEL}_s$S" -s "$S" -n "$N" -F >/dev/null 2>&1
  L=$(grep -E "^[[:space:]]*$S[[:space:]]" "$D/raw/sweep/${LABEL}_s${S}_${TOOL}_${ADEV}-${BDEV}.txt" | tail -1)
  echo "$S ${L:-실패}" | awk '{ if (NF>=8) printf "%8d B  min %7s  typ %7s  avg %7s  stdev %6s  p99 %7s  p99.9 %7s us\n", $1,$4,$6,$7,$8,$9,$10; else print $0 }' | tee -a "$SUM"
done
