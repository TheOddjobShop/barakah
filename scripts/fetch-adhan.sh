#!/usr/bin/env bash
#
# Install a freely-licensed adhan recording for Barakah to play.
#
# Barakah deliberately ships no adhan audio. Every well-known recording is a
# copyrighted performance — the *text* of the adhan is roughly 1400 years old
# and unquestionably public domain, but a recording of it carries both the
# muezzin's performer's rights and the sound-recording copyright of whoever
# fixed it. Nearly every open-source prayer app bundles named-reciter files with
# no licence and no attribution; that is a widespread habit, not a defence.
#
# So the recordings below are fetched on request instead of committed. Each one
# is a field recording whose *recordist* dedicated their own work to the public
# domain, which is the only kind of free adhan audio that actually exists.
#
# Usage:  ./scripts/fetch-adhan.sh [name]
#         make adhan

set -euo pipefail

DEST="${HOME}/Library/Application Support/Barakah/Athan"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# name|description|licence|source page|download url
CATALOGUE=(
"adhan|Full adhan, field recording (1:42)|CC0 1.0|https://commons.wikimedia.org/wiki/File:Muslim_calling_to_prayer.ogg|https://upload.wikimedia.org/wikipedia/commons/a/a9/Muslim_calling_to_prayer.ogg"
"adhan-short|Abbreviated adhan (0:42)|CC0 1.0|https://commons.wikimedia.org/wiki/File:Adhan.ogg|https://upload.wikimedia.org/wikipedia/commons/e/e7/Adhan.ogg"
"iqamah|The iqama call (1:33)|CC0 1.0|https://commons.wikimedia.org/wiki/File:Iqamah.ogg|https://upload.wikimedia.org/wikipedia/commons/0/00/Iqamah.ogg"
)

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
dim()  { printf '\033[2m%s\033[0m\n' "$1"; }

usage() {
  bold "Available recordings"
  echo
  for entry in "${CATALOGUE[@]}"; do
    IFS='|' read -r name desc licence page _ <<< "$entry"
    printf '  %-14s %s\n' "$name" "$desc"
    dim   "                 $licence · $page"
  done
  echo
  echo "Usage: $0 [name|all]"
  echo
  dim "All three are recordings by the Wikimedia contributor Aishatu98, released"
  dim "under CC0 1.0 (public domain dedication). Attribution is not required;"
  dim "assets/NOTICE.md records it anyway."
  echo
  dim "You can also point Barakah at any file of your own:"
  dim "Settings → Athan → Choose a file…"
}

fetch_one() {
  local name="$1" url="$2" licence="$3" page="$4"
  local source="$WORK/$name.download"

  echo "==> Fetching $name"
  dim  "    $licence · $page"
  if ! curl -fsSL --retry 2 -A 'Barakah/0.1 (+https://github.com/justin06lee/barakah)' \
       "$url" -o "$source"; then
    echo "!!  Download failed for $name." >&2
    return 1
  fi

  mkdir -p "$DEST"
  local target="$DEST/$name.m4a"

  if command -v ffmpeg >/dev/null 2>&1; then
    # These recordings sit around -26 LUFS, which is far too quiet to serve as
    # an alarm. Normalising to -16 LUFS brings them to a usable level without
    # crushing the dynamics of the call.
    echo "    normalising to -16 LUFS"
    ffmpeg -nostdin -loglevel error -y -i "$source" \
      -af 'loudnorm=I=-16:TP=-1.5:LRA=11' \
      -c:a aac -b:a 160k "$target"
  else
    echo "!!  ffmpeg not found — installing the original without normalisation."
    dim  "    It will be noticeably quiet. Install ffmpeg with: brew install ffmpeg"
    target="$DEST/$name.ogg"
    cp "$source" "$target"
  fi

  echo "    installed: $target"
}

main() {
  local want="${1:-}"

  if [[ -z "$want" ]]; then usage; exit 0; fi

  local matched=0
  for entry in "${CATALOGUE[@]}"; do
    IFS='|' read -r name desc licence page url <<< "$entry"
    if [[ "$want" == "all" || "$want" == "$name" ]]; then
      fetch_one "$name" "$url" "$licence" "$page" && matched=1
    fi
  done

  if [[ "$matched" -eq 0 ]]; then
    echo "!! Unknown recording: $want" >&2
    echo >&2
    usage
    exit 1
  fi

  echo
  bold "Done."
  echo "Open Barakah → Settings → Athan and pick it from the sound list."
}

main "$@"
