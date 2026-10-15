#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/sotto-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
mkdir -p "$icon_work/cache"
CLANG_MODULE_CACHE_PATH="$icon_work/cache" swift scripts/create-icon.swift "$icon_work"
python3 - "$icon_work" "$project_dir/Resources" <<'PY'
from pathlib import Path
import shutil,struct,sys
source=Path(sys.argv[1]);resources=Path(sys.argv[2]);chunks=[]
for kind,size in [('icp4',16),('icp5',32),('icp6',64),('ic07',128),('ic08',256),('ic09',512),('ic10',1024)]:
    image=(source/f'{size}.png').read_bytes()
    chunks.append(kind.encode()+struct.pack('>I',len(image)+8)+image)
contents=b''.join(chunks)
(resources/'Sotto.icns').write_bytes(b'icns'+struct.pack('>I',len(contents)+8)+contents)
shutil.copy2(source/'1024.png',resources/'SottoIcon.png')
shutil.copy2(source/'SottoMenuTemplate.png',resources/'SottoMenuTemplate.png')
print('Built app, menu-bar and PNG icons.')
PY
