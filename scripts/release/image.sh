#!/bin/bash
set -euo pipefail
app=${1:?expected path to NeSpat.app}
output=${2:?expected output path}
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun swiftc "$here/Backdrop.swift" -o "$tmp/render"
"$tmp/render" "$tmp/Backdrop.tiff"
dmgbuild -s "$here/layout.py" -D "app=$app" -D "background=$tmp/Backdrop.tiff" NeSpat "$output"
