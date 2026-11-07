#!/usr/bin/env bash
# replay.sh — run the app's shot-recognition pipeline on a video, from a
# machine without Swift, using a Mac over ssh.
#
#   Tools/cv/replay.sh <video> [labels.csv] [out-dir] [-- cv-replay options]
#
#   Tools/cv/replay.sh ~/clips/gym.mp4
#   Tools/cv/replay.sh ~/clips/gym.mp4 ~/clips/gym.labels.csv
#   Tools/cv/replay.sh ~/clips/gym.mp4 - /tmp/gym -- --stride 2 --fov 64
#
# 1. syncs this repo to the Mac (rsync --delete; the package's symlinks
#    point into the app sources, so the whole repo goes),
# 2. copies the video there unless it's already in ~/Projects/hoop-footage
#    on the Mac at the same path and size,
# 3. builds Tools/HoopTrackCore (cv-replay + shot-eval, debug) and runs
#    cv-replay on the video,
# 4. copies the results back (default /tmp/cv-replay/<clip name>/), cleans
#    up on the Mac and prints the summary.
#
# Environment:
#   CV_REPLAY_HOST   ssh host of the Mac            (default: macbook)
#   CV_REPLAY_DIR    repo copy on the Mac, relative to its home
#                    (default: Projects/wt-replay)
#   CV_REPLAY_FOOTAGE       local footage folder mirrored on the Mac
#                           (default: ~/Projects/hoop-footage)
#   CV_REPLAY_MAC_FOOTAGE   its copy on the Mac, relative to its home
#                           (default: Projects/hoop-footage)
#   CV_REPLAY_KEEP   1 = leave the video this run copied on the Mac, for the
#                    next run (a copy that was already there is never removed)
#
# See Tools/cv/README.md for what the outputs mean.

set -euo pipefail

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

[[ $# -ge 1 ]] || usage
[[ $1 == -h || $1 == --help ]] && usage 0

video=$1; shift
labels=""
out=""
if [[ $# -gt 0 && $1 != "--" ]]; then labels=$1; shift; fi
if [[ $# -gt 0 && $1 != "--" ]]; then out=$1; shift; fi
if [[ $# -gt 0 && $1 == "--" ]]; then shift; fi
extra=("$@")
[[ $labels == "-" ]] && labels=""

host=${CV_REPLAY_HOST:-macbook}
mac_dir=${CV_REPLAY_DIR:-Projects/wt-replay}
repo=$(cd "$(dirname "$0")/../.." && pwd)

[[ -f $video ]] || { echo "replay.sh: no such video: $video" >&2; exit 1; }
[[ -z $labels || -f $labels ]] || { echo "replay.sh: no such labels file: $labels" >&2; exit 1; }
video=$(realpath "$video")
name=$(basename "$video")
clip=${name%.*}
safe=$(printf '%s' "$clip" | tr -c 'A-Za-z0-9._-' '_')
ext=${name##*.}
out=${out:-/tmp/cv-replay/$clip}

# Single-quote for the Mac's shell.
q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

mac_home=$(ssh "$host" 'printf %s "$HOME"')
root="$mac_home/$mac_dir"
scratch="$root/.replay"
remote_out="$scratch/out/$safe"

echo "== syncing $repo to $host:$mac_dir"
ssh "$host" "mkdir -p $(q "$root") $(q "$scratch/videos") $(q "$scratch/labels")"
# .replay (videos, results) lives in the Mac copy; keep --delete off it.
rsync -a --delete --exclude .build --exclude .git --exclude /.replay/ "$repo/" "$host:$mac_dir/"

# The footage collection is mirrored on the Mac: use it in place if the
# same file is there.
remote_video=""
copied=0
footage=$(realpath -m "${CV_REPLAY_FOOTAGE:-$HOME/Projects/hoop-footage}")
mac_footage=${CV_REPLAY_MAC_FOOTAGE:-Projects/hoop-footage}
if [[ $video == "$footage"/* ]]; then
    rel=${video#"$footage"/}
    candidate="$mac_home/$mac_footage/$rel"
    size=$(stat -c %s "$video" 2>/dev/null || stat -f %z "$video")
    remote_size=$(ssh "$host" "stat -f %z $(q "$candidate") 2>/dev/null || true")
    if [[ $remote_size == "$size" ]]; then
        remote_video=$candidate
        echo "== using $host:${candidate#"$mac_home"/}"
    fi
fi
if [[ -z $remote_video ]]; then
    remote_video="$scratch/videos/$safe.$ext"
    # Only a copy this run made is removed afterwards.
    if ssh "$host" "test -e $(q "$remote_video")"; then
        echo "== $name already on $host (rsync updates it if it changed)"
    else
        echo "== copying $name to $host"
        copied=1
    fi
    rsync -a --partial "$video" "$host:$mac_dir/.replay/videos/$safe.$ext"
fi

label_args=""
if [[ -n $labels ]]; then
    rsync -a "$labels" "$host:$mac_dir/.replay/labels/$safe.csv"
    label_args="--labels $(q "$scratch/labels/$safe.csv")"
fi
extra_args=""
for arg in "${extra[@]+"${extra[@]}"}"; do extra_args+=" $(q "$arg")"; done

echo "== building cv-replay on $host"
if ! ssh "$host" "cd $(q "$root/Tools/HoopTrackCore") && swift build > $(q "$scratch/build.log") 2>&1"; then
    ssh "$host" "grep -E 'error' $(q "$scratch/build.log") | head -40; tail -5 $(q "$scratch/build.log")" >&2
    echo "replay.sh: build failed" >&2
    exit 1
fi

echo "== running"
status=0
ssh "$host" "cd $(q "$root") && rm -rf $(q "$remote_out") && Tools/HoopTrackCore/.build/debug/cv-replay $(q "$remote_video") --out $(q "$remote_out") $label_args$extra_args > /dev/null" || status=$?

mkdir -p "$out"
if ssh "$host" "test -d $(q "$remote_out")"; then
    rsync -a --delete "$host:$mac_dir/.replay/out/$safe/" "$out/"
fi
cleanup="rm -rf $(q "$remote_out") $(q "$scratch/labels/$safe.csv")"
if [[ $copied == 1 && ${CV_REPLAY_KEEP:-0} != 1 ]]; then cleanup+=" $(q "$remote_video")"; fi
ssh "$host" "$cleanup"

if [[ $status != 0 ]]; then
    echo "replay.sh: cv-replay failed (exit $status)" >&2
    exit "$status"
fi
echo
cat "$out/summary.txt"
echo
echo "Results: $out  (summary.txt, shots.csv, fidelity.txt, shot-eval.txt, detections.jsonl, strips/)"
