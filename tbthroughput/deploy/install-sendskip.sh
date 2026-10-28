#!/usr/bin/env bash
# tbv: 성공한 재전송 가능 send 완료 시 불필요한 취소 스캔을 건너뛰는 수정본(2차, 올바른 헤더로 빌드) 설치 + 모듈 재적재.
# 빌드: B 의 ~/kbuild-1015 헤더(callback_xd 포함) + ~/tbmod-1015/thunderbolt/Module.symvers — 로드된 thunderbolt.ko 와 같은 트리.
# 같은 환경에서 정본을 다시 빌드하면 설치본과 기계어가 같았다(주소 제외). 원본 모듈은 .pre-sendskip.bak(sha eeeecb15…).
set -euo pipefail
K=7.0.0-1015-oem; D="$(cd "$(dirname "$0")" && pwd)"; U=/lib/modules/$K/updates; KO=$D/thunderbolt_ibverbs.ko
[ "$(id -u)" = 0 ] || { echo "sudo 로 실행"; exit 1; }
[ "$(uname -r)" = "$K" ] || { echo "커널 $(uname -r) ≠ $K"; exit 1; }
[ "$(sha256sum $KO | cut -c1-16)" = c5d79e61f87217aa ] || { echo "모듈 sha 불일치"; exit 1; }
[ "$(modinfo -F srcversion $KO)" = E475F47027AD6CFCB11B2AB ] || { echo "모듈 srcversion 불일치"; exit 1; }
[ -f $U/thunderbolt_ibverbs.ko.pre-sendskip.bak ] || cp -a $U/thunderbolt_ibverbs.ko $U/thunderbolt_ibverbs.ko.pre-sendskip.bak
[ "$(sha256sum $U/thunderbolt_ibverbs.ko.pre-sendskip.bak | cut -c1-16)" = eeeecb15b9de3452 ] || { echo "백업이 원본이 아님 — 중단"; exit 1; }
diff <(modprobe --dump-modversions $U/thunderbolt_ibverbs.ko.pre-sendskip.bak | sort) \
     <(modprobe --dump-modversions $KO | sort) >/dev/null || { echo "심볼 CRC 가 동작하던 모듈과 다름 — 설치 중단"; exit 1; }
install -m644 $KO $U/thunderbolt_ibverbs.ko
depmod -a $K
systemctl stop tbv-multirail || true
if [ -d /sys/module/thunderbolt_ibverbs ]; then rmmod thunderbolt_ibverbs; fi
systemctl reset-failed tbv-multirail || true
systemctl start tbv-multirail || true
echo "로드된 srcversion: $(cat /sys/module/thunderbolt_ibverbs/srcversion 2>/dev/null || echo 미로드)"; ibv_devices
echo "롤백: sudo cp $U/thunderbolt_ibverbs.ko.pre-sendskip.bak $U/thunderbolt_ibverbs.ko && sudo depmod -a $K && sudo reboot"
