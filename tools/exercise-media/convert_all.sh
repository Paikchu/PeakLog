#!/bin/bash
# Transcodes every dataset GIF to a looping HEVC .mov and copies the matching
# thumbnail, keyed by the dataset's 4-digit record id.
#
#   ./convert_all.sh <dataset-clone-dir> <output-dir>
#
# The dataset clone is https://github.com/hasaneyldrm/exercises-dataset (its
# videos/ and images/ are named "<id>-<media_id>.<ext>"). Output is flat:
# "<id>.mov" + "<id>.jpg", which is what ExerciseMedia resolves at runtime.

set -euo pipefail

DATASET="${1:?usage: convert_all.sh <dataset-dir> <out-dir>}"
OUT="${2:?usage: convert_all.sh <dataset-dir> <out-dir>}"
QUALITY="${3:-0.7}"
HERE="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$OUT"

# Build the converter once; swiftc on every file would dominate the runtime.
BIN="$(mktemp -d)/gif2hevc"
swiftc -O -o "$BIN" "$HERE/gif2hevc.swift"

export BIN OUT QUALITY

convert_one() {
  local gif="$1"
  local stem id
  stem="$(basename "$gif" .gif)"   # 0001-2gPfomN
  id="${stem%%-*}"                 # 0001
  "$BIN" "$gif" "$OUT/$id.mov" "$QUALITY" > /dev/null
}
export -f convert_one

find "$DATASET/videos" -name '*.gif' -print0 \
  | xargs -0 -P "$(sysctl -n hw.ncpu)" -I{} bash -c 'convert_one "$@"' _ {}

# Thumbnails ship as-is: 180x180 JPEGs, ~6 KB each, already small enough that
# re-encoding buys less than it costs in fidelity.
for jpg in "$DATASET"/images/*.jpg; do
  stem="$(basename "$jpg" .jpg)"
  cp "$jpg" "$OUT/${stem%%-*}.jpg"
done

echo "movies: $(ls "$OUT"/*.mov | wc -l | tr -d ' ')  thumbs: $(ls "$OUT"/*.jpg | wc -l | tr -d ' ')"
du -sh "$OUT"
