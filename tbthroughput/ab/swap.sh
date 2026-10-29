#!/usr/bin/env bash
# tbv 모듈을 이전(old, 원본 eeeecb15…) / new(송신 취소 스캔 생략 1차 c5d79e61…) / new2(재전송 이력 없는 send 도 생략 9923174f…) / new3(+MR sg 커서 복사 4752843d…) / new4(+여러 프레임 SEND 의 RNR 대기 c81f49da…) 사이에서 바꾼다. 재부팅 없이 재적재.
# 모두 같은 빌드 트리에서 나왔다. 설치 전, 새 모듈이 가져오는 모든 심볼이 동작하던 모듈(백업)에 같은 CRC 로 있는지 확인한다(부분집합).
#   sudo bash ~/tbv-ab/swap.sh old|new|new2|new3|new4
set -euo pipefail
export LC_ALL=C
K=7.0.0-1015-oem; U=/lib/modules/$K/updates; H=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
case "${1:-}" in
  old) SRC=$U/thunderbolt_ibverbs.ko.pre-sendskip.bak; WANT=eeeecb15b9de3452; SV=204282CC2EFCF9A637C08B7 ;;
  new) SRC=$H/tbv-deploy-sendskip2/thunderbolt_ibverbs.ko; WANT=c5d79e61f87217aa; SV=E475F47027AD6CFCB11B2AB ;;
  new2) SRC=$H/tbv-deploy-sendskip3/thunderbolt_ibverbs.ko; WANT=9923174f47de8b15; SV=0E989E584CFD24C34898365 ;;
  new3) SRC=$H/tbv-deploy-sendskip4/thunderbolt_ibverbs.ko; WANT=4752843dfae7d354; SV=7DE3F58A9EFA920761251A4 ;;
  new4) SRC=$H/tbv-deploy-sendskip5/thunderbolt_ibverbs.ko; WANT=c81f49dadb779b4e; SV=C8A6733DE6C7ADEFE716E4F ;;
  *) echo "사용법: sudo bash $0 old|new|new2|new3|new4"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행"; exit 1; }
[ "$(sha256sum "$SRC" | cut -c1-16)" = $WANT ] || { echo "$SRC sha 불일치"; exit 1; }
extra=$(comm -13 <(modprobe --dump-modversions $U/thunderbolt_ibverbs.ko.pre-sendskip.bak | sort -u) \
                 <(modprobe --dump-modversions "$SRC" | sort -u))
[ -z "$extra" ] || { echo "동작하던 모듈에 없는 심볼·CRC — 중단:"; echo "$extra"; exit 1; }
install -m644 "$SRC" $U/thunderbolt_ibverbs.ko
depmod -a $K
systemctl stop tbv-multirail || true
[ -d /sys/module/thunderbolt_ibverbs ] && rmmod thunderbolt_ibverbs
systemctl reset-failed tbv-multirail || true
systemctl start tbv-multirail || true
got=$(cat /sys/module/thunderbolt_ibverbs/srcversion 2>/dev/null || echo 미로드)
echo "$1 로드: srcversion=$got $([ "$got" = $SV ] && echo OK || echo '← 기대값과 다름')"
