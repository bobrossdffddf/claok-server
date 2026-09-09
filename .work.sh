#!/bin/bash
ROOT="$(cd "$(dirname "$0")" && pwd)"
: > "$ROOT/.out.txt"
nohup /bin/bash -c "/bin/bash '$ROOT/.cmd.sh' >> '$ROOT/.out.txt' 2>&1; echo DONE >> '$ROOT/.out.txt'" >/dev/null 2>&1 &
echo launched
