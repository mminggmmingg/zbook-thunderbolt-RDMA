#!/usr/bin/env bash
# eval_ppl.sh 가 쓰는 글(eval/ppl_text.txt)을 llama.cpp 문서 3개(MIT)로 다시 만든다.
set -euo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
cat "$D/llama.cpp/docs/build.md" "$D/llama.cpp/docs/function-calling.md" "$D/llama.cpp/tools/server/README.md" > "$D/eval/ppl_text.txt"
wc -c "$D/eval/ppl_text.txt"
