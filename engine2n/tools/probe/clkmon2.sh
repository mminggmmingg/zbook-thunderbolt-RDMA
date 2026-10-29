# 100 ms 마다 sclk/mclk/fclk 의 '*' 표시 줄(없으면 none)과 gpu_busy 를 읽어 도메인별 분포를 낸다(읽기만). $1 = 초
D=/sys/class/drm/card1/device; end=$(( $(date +%s) + $1 ))
while [ $(date +%s) -lt $end ]; do
  for c in sclk mclk fclk; do
    v=$(grep '\*' $D/pp_dpm_$c | awk '{print $2}'); [ -z "$v" ] && v=none
    if [ $c = sclk ]; then v=$(( ${v%Mhz} / 100 * 100 ))Mhz; [ "$v" = 0Mhz ] && v=none; fi
    echo "$c $v"
  done
  echo "busy $(( $(cat $D/gpu_busy_percent) / 10 * 10 ))"
  sleep 0.1
done | awk '{c[$1" "$2]++; n[$1]++} END {for (k in c) {split(k,a," "); printf "  %-5s %-9s %5.1f%%\n", a[1], a[2], 100*c[k]/n[a[1]]}}' | sort
