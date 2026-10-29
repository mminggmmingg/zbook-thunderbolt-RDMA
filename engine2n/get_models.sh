#!/usr/bin/env bash
# Qwen3.8-Flash-Next GGUF 받기(unsloth, revision 고정, sha256 확인). 사용자 승인 후 실행.
#   get_models.sh q4|iq4|q8|mtp ...    예) get_models.sh q4 mtp      (q4 = UD-Q4_K_XL 111.3 GB, iq4 = UD-IQ4_XS 93.7 GB, q8 = Q8_0 188.2 GB, mtp = shared Q8_0 2.79 GB)
# 저장: /data/parksThink/hf-models/qwen38-flash-next-gguf/<set>/  · 로그: 그 폴더의 .pdl.log
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd); M=$D/models_manifest.json
DST=/data/parksThink/hf-models/qwen38-flash-next-gguf
[ $# -ge 1 ] || { sed -n 2,4p "$0"; exit 2; }
for want in "$@"; do
  case $want in q4) set=UD-Q4_K_XL ;; iq4) set=UD-IQ4_XS ;; q8) set=Q8_0 ;; mtp) set=MTP ;; *) echo "모름: $want"; exit 2 ;; esac
  python3 -I - "$M" "$set" <<'EOF' | while read -r path size sha rev; do
import json, sys
m = json.load(open(sys.argv[1]))
for f in m["files"]:
    if f["set"] == sys.argv[2]:
        print(f["path"], f["size"], f["sha256"], m["revision"])
EOF
    mkdir -p "$DST/$(dirname "$path")"
    python3 -I "$D/tools/pdl.py" "https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/$rev/$path" \
      "$DST/$path" "$size" "$sha" 8 64 >> "$DST/.pdl.log" 2>&1
    echo "$(date +%T) $path rc=$?" | tee -a "$DST/.pdl.log"
  done
done
