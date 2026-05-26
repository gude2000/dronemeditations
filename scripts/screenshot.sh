#!/usr/bin/env bash
#
# App Store screenshot helper for Drone Meditations.
#
# Two commands:
#
#   ./scripts/screenshot.sh setup
#       Boots iPhone 17 Pro Max + iPad Pro 13" simulators if not already
#       running, installs the latest Debug build into each, and overrides
#       their status bars to the canonical Apple screenshot look
#       (9:41 AM, full battery, full signal). Run this once before
#       starting a session.
#
#   ./scripts/screenshot.sh snap <slug>
#       Captures one screenshot from every booted simulator and writes
#       them to ./screenshots/<NN>-<slug>-{iphone,ipad}.png where NN is
#       auto-incremented (or pass --num NN to override). Navigate the
#       sim to the desired state first, then run this.
#
#   ./scripts/screenshot.sh list
#       Lists screenshots taken so far.
#
#   ./scripts/screenshot.sh reset-status
#       Removes the status-bar override so the sim is back to its
#       normal time/battery display. Run this when you're done.
#
# Output naming convention:
#   01-hero-iphone.png         01-hero-ipad.png
#   02-main-ui-iphone.png      02-main-ui-ipad.png
#   ...
#
# Apple App Store requires at minimum the 6.7" iPhone (we use iPhone
# 17 Pro Max → 1290×2796) and the 13" iPad (iPad Pro 13" M5 →
# 2064×2752). simctl io screenshot captures at the simulator's native
# resolution so the output is already at the right pixel dimensions.

set -e

# ── Configuration ──────────────────────────────────────────────────
IPHONE_NAME="iPhone 17 Pro Max"
IPAD_NAME="iPad Pro 13-inch (M5)"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS_DIR="$PROJECT_ROOT/screenshots"
mkdir -p "$SHOTS_DIR"

# ── Helpers ───────────────────────────────────────────────────────

# Find a booted device UDID matching a name substring. Empty if none.
udid_for() {
  local name="$1"
  xcrun simctl list devices booted | grep "$name" | head -1 | \
    sed -nE 's/.*\(([0-9A-F-]+)\) \(Booted\).*/\1/p'
}

# Find ANY device (booted or not) matching a name substring.
any_udid_for() {
  local name="$1"
  xcrun simctl list devices available 2>/dev/null | grep "$name" | \
    head -1 | sed -nE 's/.*\(([0-9A-F-]+)\).*/\1/p'
}

ensure_booted() {
  local name="$1"
  local udid="$(udid_for "$name")"
  if [ -z "$udid" ]; then
    udid="$(any_udid_for "$name")"
    if [ -z "$udid" ]; then
      echo "  ✗ No simulator named '$name' available." >&2
      return 1
    fi
    echo "  → Booting $name ($udid) …"
    xcrun simctl boot "$udid" 2>/dev/null || true
    sleep 3
  else
    echo "  ✓ $name already booted ($udid)"
  fi
  echo "$udid"
}

apply_status_bar() {
  local udid="$1"
  xcrun simctl status_bar "$udid" override \
    --time "9:41" \
    --dataNetwork wifi \
    --wifiMode active \
    --wifiBars 3 \
    --cellularMode active \
    --cellularBars 4 \
    --batteryState charged \
    --batteryLevel 100 \
    >/dev/null 2>&1 || true
}

# Determine next sequence number for the screenshots folder by
# counting existing matching slug shots; the user can also pass
# --num NN to override.
next_seq() {
  local existing="$(ls "$SHOTS_DIR" 2>/dev/null | grep -E '^[0-9]{2}-' | wc -l | tr -d ' ')"
  printf "%02d" $(( (existing / 2) + 1 ))
}

# ── Subcommands ──────────────────────────────────────────────────

cmd_setup() {
  echo "── Setup: booting simulators + applying canonical status bar ──"
  IPHONE_UDID="$(ensure_booted "$IPHONE_NAME" | tail -1)"
  IPAD_UDID="$(ensure_booted "$IPAD_NAME" | tail -1)"
  # Wait for boot to finish (simctl returns before the device is responsive).
  echo "  → Waiting for simulators to settle (8 s)…"
  sleep 8
  echo "  → Applying status-bar override (9:41, full signal, full battery)…"
  [ -n "$IPHONE_UDID" ] && apply_status_bar "$IPHONE_UDID"
  [ -n "$IPAD_UDID" ]   && apply_status_bar "$IPAD_UDID"
  echo
  echo "✓ Setup complete. Now:"
  echo "    1. Open Simulator.app and navigate each sim to the screen you want."
  echo "    2. Run: ./scripts/screenshot.sh snap <slug>"
  echo "       Slugs from the listing plan: hero, main-ui, preset-picker, morph,"
  echo "       granular, listen, journeys, samples"
}

cmd_snap() {
  local slug="$1"
  local seq=""
  if [ "$2" = "--num" ] && [ -n "$3" ]; then seq="$(printf '%02d' "$3")"; fi
  if [ -z "$slug" ]; then
    echo "Usage: ./scripts/screenshot.sh snap <slug> [--num NN]" >&2
    exit 1
  fi
  [ -z "$seq" ] && seq="$(next_seq)"
  local taken=0
  for label in iphone ipad; do
    if [ "$label" = "iphone" ]; then
      udid="$(udid_for "$IPHONE_NAME")"
    else
      udid="$(udid_for "$IPAD_NAME")"
    fi
    if [ -z "$udid" ]; then
      echo "  ⏭  $label: no booted sim, skipped"
      continue
    fi
    out="$SHOTS_DIR/${seq}-${slug}-${label}.png"
    xcrun simctl io "$udid" screenshot --type=png "$out"
    if [ -f "$out" ]; then
      size="$(du -h "$out" | awk '{print $1}')"
      echo "  ✓ $out ($size)"
      taken=$((taken+1))
    else
      echo "  ✗ Failed to capture $label"
    fi
  done
  if [ $taken -eq 0 ]; then
    echo "  !! Nothing captured. Did you run './scripts/screenshot.sh setup'?"
    exit 1
  fi
}

cmd_list() {
  echo "── Screenshots in $SHOTS_DIR ──"
  ls -lh "$SHOTS_DIR" 2>/dev/null | grep -E '\.png$' || echo "  (none yet)"
}

cmd_reset_status() {
  echo "── Removing status-bar overrides ──"
  for name in "$IPHONE_NAME" "$IPAD_NAME"; do
    udid="$(udid_for "$name")"
    if [ -n "$udid" ]; then
      xcrun simctl status_bar "$udid" clear
      echo "  ✓ Cleared on $name"
    fi
  done
}

cmd_help() {
  cat <<EOF
Drone Meditations · App Store screenshot helper

Usage:
  ./scripts/screenshot.sh setup
  ./scripts/screenshot.sh snap <slug> [--num NN]
  ./scripts/screenshot.sh list
  ./scripts/screenshot.sh reset-status

Recommended workflow:
  1. ./scripts/screenshot.sh setup
  2. In Xcode, run the app on the booted simulators.
  3. Navigate each sim to the desired screen.
  4. ./scripts/screenshot.sh snap hero
  5. Navigate to next screen.
  6. ./scripts/screenshot.sh snap main-ui
  7. … repeat for: preset-picker, morph, granular, listen, journeys, samples
  8. ./scripts/screenshot.sh reset-status
  9. Files are in screenshots/ ready for App Store Connect upload.
EOF
}

# ── Dispatch ─────────────────────────────────────────────────────

case "${1:-help}" in
  setup) cmd_setup ;;
  snap)  shift; cmd_snap "$@" ;;
  list)  cmd_list ;;
  reset-status) cmd_reset_status ;;
  -h|--help|help|"") cmd_help ;;
  *) echo "Unknown command: $1"; cmd_help; exit 1 ;;
esac
