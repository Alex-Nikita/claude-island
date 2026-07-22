#!/bin/sh
# Capture README screenshots of Claude Island with pixel-consistent crops.
#
# Regions assume the 16" MacBook Pro default scaled resolution (1728x1117 pt,
# notch 185 pt) and the app's fixed panel sizes (see NotchModeController):
#   collapsed 343x41 / expanded 666x338 / decision 666x422 / settings 794x562,
# all top-centered. Adjust WIDTH if your display differs.
#
# Usage: scripts/capture-screenshots.sh <shot> [delay-seconds]
#   collapsed  full-width top strip (waiting glow / working island)
#   expanded   expanded island + margin
#   decision   the taller question/permission pane + margin
#   settings   the settings pane + margin
#   pill       interactive: press SPACE, click the popover window
#   full       top 400 pt of the screen (safety net)

set -e
SHOT="${1:-decision}"
DELAY="${2:-4}"
WIDTH=1728
OUT="docs/shots"
mkdir -p "$OUT"
FILE="$OUT/$SHOT-$(date +%H%M%S).png"

center() { echo $(( (WIDTH - $1) / 2 )); }

case "$SHOT" in
  collapsed) R="0,0,$WIDTH,56" ;;
  expanded)  R="$(( $(center 666) - 40 )),0,746,418" ;;
  decision)  R="$(( $(center 666) - 40 )),0,746,438" ;;
  settings)  R="$(( $(center 746) - 40 )),0,826,578" ;;
  full)      R="0,0,$WIDTH,400" ;;
  pill)      R="" ;;
  *) echo "unknown shot: $SHOT" >&2; exit 1 ;;
esac

if [ -z "$R" ]; then
  echo "Open the pill popover, then press SPACE and click the popover window…"
  screencapture -i -W -o "$FILE"
else
  echo "Capturing '$SHOT' in ${DELAY}s — stage the island now…"
  screencapture -x -T "$DELAY" -R "$R" "$FILE"
fi
echo "Saved $FILE"
