#!/bin/bash
set -euo pipefail
app=${1:?expected path to NeSpat.app}
output=${2:?expected output path}
here=$(cd "$(dirname "$0")" && pwd)
dmgbuild -s "$here/layout.py" -D "app=$app" -D "background=$here/../../Resources/Backdrop.tiff" NeSpat "$output"
