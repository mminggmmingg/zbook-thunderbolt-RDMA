#!/usr/bin/env bash
# tbv 모듈을 이전(old, 원본 eeeecb15…) / 새(new, 송신 취소 스캔 생략 c5d79e61…) 사이에서 바꾼다. 재부팅 없이 재적재.
# 두 모듈은 같은 빌드 트리에서 나와 심볼 CRC 가 같다(설치 전 다시 확인).
#   sudo bash ~/tbv-ab/swap.sh old|new
set -euo pipefail
K=7.0.0-1015-oem; U=/lib/modules/$K/updates; H=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
case "${1:-}" in
  old) SRC=$U/thunderbolt_ibverbs.ko.pre-sendskip.bak; WANT=eeeecb15b9de3452; SV=204282CC2EFCF9A637C08B7 ;;
  new) SRC=$H/tbv-deploy-sendskip2/thunderbolt_ibverbs.ko; WANT=c5d79e61f87217aa; SV=E475F47027AD6CFCB11B2AB ;;
  *) echo "사용법: sudo bash $0 old|new"; exit 2 ;;
esac
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행"; exit 1; }
[ "$(sha256sum "$SRC" | cut -c1-16)" = $WANT ] || { echo "$SRC sha 불일치"; exit 1; }
diff <(modprobe --dump-modversions $U/thunderbolt_ibverbs.ko.pre-sendskip.bak | sort) \
     <(modprobe --dump-modversions "$SRC" | sort) >/dev/null || { echo "심볼 CRC 불일치 — 중단"; exit 1; }
install -m644 "$SRC" $U/thunderbolt_ibverbs.ko
depmod -a $K
systemctl stop tbv-multirail || true
[ -d /sys/module/thunderbolt_ibverbs ] && rmmod thunderbolt_ibverbs
systemctl reset-failed tbv-multirail || true
systemctl start tbv-multirail || true
got=$(cat /sys/module/thunderbolt_ibverbs/srcversion 2>/dev/null || echo 미로드)
echo "$1 로드: srcversion=$got $([ "$got" = $SV ] && echo OK || echo '← 기대값과 다름')"
