#!/usr/bin/env bash
#
# Recover the Mac's display from another machine instead of the power button.
#
# Two different failures have looked identical from the user's chair -- a black
# screen -- and they need different things:
#
#   * The GPU driver stops responding. The whole machine freezes, the unified
#     log goes silent, and nothing here will reach it; a power cycle is the only
#     way out. Killing the Wine side first is still worth trying, and it is what
#     risks nothing.
#   * The window session breaks while the system keeps running. Logs keep
#     flowing, ssh answers, WindowServer burns CPU, and the display stays dark.
#     Re-initialising the session fixes it without losing a single process --
#     apps stay up, you just log back in.
#
# Run it over ssh (Tailscale reaches the machine while the screen is dark):
#
#   scripts/whisky-panic.sh                 # collect evidence, then kill Wine
#   scripts/whisky-panic.sh --session       # also re-init the window session
#   scripts/whisky-panic.sh --reboot        # clean reboot, last resort
#
set -uo pipefail

DO_SESSION=0
DO_REBOOT=0
for arg in "$@"; do
    case "$arg" in
        --session) DO_SESSION=1 ;;
        --reboot)  DO_REBOOT=1 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say() { printf '\n=== %s\n' "$*"; }

EVIDENCE="/tmp/whisky-panic-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$EVIDENCE"

# Collect first. Every recovery step below destroys the state that says which
# of the two failures this was, and the answer is only in the machine while it
# is still broken.
say "Collecting evidence into $EVIDENCE"
{
    echo "## date";        date
    echo "## uptime";      uptime
    echo "## wine";        pgrep -fl 'wine64|wineserver|winedevice|\.exe' || echo none
    echo "## compilers";   pgrep -x MTLCompilerService | wc -l
    echo "## WindowServer"; ps -o pid,stat,%cpu,etime -p "$(pgrep -x WindowServer | head -1)" 2>/dev/null
    echo "## displays";    system_profiler SPDisplaysDataType 2>/dev/null | grep -iE 'Resolution|Online|Main Display'
    echo "## console";     stat -f '%Su' /dev/console
} > "$EVIDENCE/state.txt" 2>&1
cat "$EVIDENCE/state.txt"

# A live system keeps logging; a wedged GPU driver does not. The per-minute
# line count over the last few minutes separates the two cases better than any
# single message, and it is the one thing that cannot be reconstructed later.
say "Log volume per minute (a hole here means the system froze)"
log show --last 6m --style compact 2>/dev/null \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:' \
    | cut -c1-16 | uniq -c | tee "$EVIDENCE/log-volume.txt"

say "GPU / display errors in the last 6 minutes"
log show --last 6m --style compact 2>/dev/null \
    | grep -iE 'AGX|IOAF|GPU restart|GPU hang|device lost|link unstable|retrain' \
    | tail -20 | tee "$EVIDENCE/gpu.txt"

# The wineserver goes last: killing it first reparents its clients to launchd,
# and from then on KERN_PROCARGS2 stops answering for them, so an orphan can no
# longer be attributed to a bottle.
say "Killing Wine clients"
pkill -9 -f '\.exe' 2>/dev/null
pkill -9 -f 'winedevice' 2>/dev/null
say "Killing wineserver"
pkill -9 -f 'wineserver' 2>/dev/null
pkill -9 -f 'wine64' 2>/dev/null

# Each in-flight pipeline compile is a process of its own and keeps feeding the
# driver after its client is gone.
say "Killing Metal shader compilers"
pkill -9 -x 'MTLCompilerService' 2>/dev/null

sleep 1
say "Wine processes after"
pgrep -fl 'wine64|wineserver|winedevice|\.exe' || echo "(none)"

say "Flushing filesystem buffers"
sync

if [ "$DO_SESSION" = 1 ]; then
    # Drops to the login window and rebuilds the session's window state. No
    # process is killed -- every app is still there after logging back in --
    # and unlike restarting WindowServer it needs no root. This is what fixed
    # the 2026-08-09 18:25 black screen: WindowServer went from 41% CPU to
    # 2.7% and the display came back, with the whole session intact.
    say "Re-initialising the window session (log back in; nothing is killed)"
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession" -suspend
fi

if [ "$DO_REBOOT" = 1 ]; then
    say "Rebooting"
    sudo shutdown -r now
fi

say "Evidence kept in $EVIDENCE"
echo "If the screen is still black: --session, then --reboot."
