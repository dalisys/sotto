#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
task_cache="${TMPDIR:-/tmp}/sotto-swift-cache"
mkdir -p "$task_cache/clang" "$task_cache/swift"
export CLANG_MODULE_CACHE_PATH="$task_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_cache/swift"
swift test --disable-sandbox "$@"
