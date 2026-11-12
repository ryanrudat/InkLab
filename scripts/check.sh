#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"

check_server() {
  node -e '
    const [major, minor] = process.versions.node.split(".").map(Number)
    if (major !== 24 || minor < 12) {
      console.error(`InkLab Server requires Node 24.12+; found ${process.version}`)
      process.exit(1)
    }
  '
  npm --prefix "$ROOT/Server" ci
  npm --prefix "$ROOT/Server" run check
}

check_swift() {
  local packages=(
    InkLabRecognition InkLabDoc InkLabMath InkLabUnits InkLabChem InkLabBio
    InkLabCanvasCore InkLabReactive InkLabFit InkLabMultiRep InkLabRouter InkLabSearch
  )

  for package in "${packages[@]}"; do
    swift test --package-path "$ROOT/Packages/$package"
  done
  swift build --package-path "$ROOT/Packages/InkLabKit"
}

case "$MODE" in
  server) check_server ;;
  swift) check_swift ;;
  all)
    check_server
    check_swift
    ;;
  *)
    echo "usage: bash scripts/check.sh [all|server|swift]" >&2
    exit 2
    ;;
esac
