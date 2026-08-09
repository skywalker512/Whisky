#!/usr/bin/env bash
#
# Recover a wedged Mac without the power button.
#
# A legacy title (DirectDraw / D3D8 fixed function) can hand the GPU driver a
# whole pipeline set at once; the driver stops responding, the display link
# drops, and the machine looks dead — black screen, no cursor, no input. The
# network stack usually survives that, so SSH in from another host (Tailscale
# works) and run this instead of long-pressing power. A forced power cut is
# what risks the filesystem; killing the Wine side is not.
#
# Usage (over SSH):
#   scripts/whisky-panic.sh              # kill Wine + the Metal compilers
#   scripts/whisky-panic.sh --display    # also restart WindowServer (logs you out)
#   scripts/whisky-panic.sh --reboot     # clean reboot when nothing else helps
#
set -uo pipefail

DO_DISPLAY=0
DO_REBOOT=0
for arg in "$@"; do
    case "$arg" in
        --display) DO_DISPLAY=1 ;;
        --reboot)  DO_REBOOT=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '=== %s\n' "$*"; }

say "Wine processes before"
pgrep -fl 'wine64|wineserver|winedevice|\.exe' || echo "(none)"

# The wineserver last: killing it first orphans the clients, and an orphan is
# harder to attribute to a bottle afterwards (KERN_PROCARGS2 stops answering
# for a reparented process).
say "Killing Wine clients"
pkill -9 -f '\.exe' 2>/dev/null
pkill -9 -f 'winedevice' 2>/dev/null
say "Killing wineserver"
pkill -9 -f 'wineserver' 2>/dev/null
pkill -9 -f 'wine64' 2>/dev/null

# Each in-flight pipeline is a compiler process of its own. They keep feeding
# the driver after the client is gone, so they have to go too.
say "Killing Metal shader compilers"
pkill -9 -x 'MTLCompilerService' 2>/dev/null

sleep 1
say "Wine processes after"
pgrep -fl 'wine64|wineserver|winedevice|\.exe' || echo "(none)"

say "Flushing filesystem buffers"
sync

if [ "$DO_DISPLAY" = 1 ]; then
    # Rebuilds the whole window session: every app is torn down and you land
    # back at the login window. Only worth it when the display stays dark
    # after the GPU work is gone.
    say "Restarting WindowServer (this logs you out)"
    sudo killall -HUP WindowServer
fi

if [ "$DO_REBOOT" = 1 ]; then
    say "Rebooting"
    sudo shutdown -r now
fi

say "Done. If the screen is still black, try --display, then --reboot."
