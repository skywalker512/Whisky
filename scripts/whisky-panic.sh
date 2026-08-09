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
#   scripts/whisky-panic.sh --session       # also cycle the display
#   scripts/whisky-panic.sh --wsrestart     # restart WindowServer (logs you out)
#   scripts/whisky-panic.sh --reboot        # clean reboot, last resort
#
set -uo pipefail

DO_SESSION=0
DO_WSRESTART=0
DO_REBOOT=0
for arg in "$@"; do
    case "$arg" in
        --session)   DO_SESSION=1 ;;
        --wsrestart) DO_WSRESTART=1 ;;
        --reboot)    DO_REBOOT=1 ;;
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

# These need root and are pure observation. Grant them once in
# /etc/sudoers.d (sample, spindump, powermetrics, killall -HUP WindowServer)
# so this runs unattended while the screen is dark; each is attempted
# individually and simply skipped when it is not permitted, rather than
# blocking on a password prompt nobody can see. Probing with `sudo -n true`
# would report the wrong answer, since a correctly narrow rule does not
# include `true`. A screenshot is deliberately not attempted: screen capture
# is gated behind TCC, which neither root nor launchctl asuser satisfies from
# an ssh session.
say "Sampling WindowServer (says what it is spinning on)"
if sudo -n /usr/bin/sample WindowServer 3 -file "$EVIDENCE/windowserver-sample.txt" >/dev/null 2>&1; then
    grep -A12 'Call graph' "$EVIDENCE/windowserver-sample.txt" | head -16
else
    echo "(not permitted -- add /usr/bin/sample to /etc/sudoers.d)"
fi

say "GPU power state (a wedged GPU sits pinned, an idle one drops to P1)"
if sudo -n /usr/bin/powermetrics --samplers gpu_power -n 1 -i 300 > "$EVIDENCE/gpu-power.txt" 2>/dev/null; then
    grep -iE 'GPU HW active|idle residency' "$EVIDENCE/gpu-power.txt"
else
    echo "(not permitted -- add /usr/bin/powermetrics to /etc/sudoers.d)"
fi

# WindowServer composited normally through the 2026-08-09 18:47 outage -- its
# stack was indistinguishable from a healthy one -- so a black screen can be
# something the compositor is faithfully drawing: a window covering everything,
# or a gamma ramp that maps every value to zero. Neither appears in any log.
say "What the display is actually showing (windows + gamma)"
SCREEN_STATE="$SCRIPT_DIR/screen-state.c"
SCREEN_BIN="/tmp/whisky-screen-state"
if [ -f "$SCREEN_STATE" ]; then
    [ -x "$SCREEN_BIN" ] || cc -O2 -o "$SCREEN_BIN" "$SCREEN_STATE" -framework ApplicationServices 2>/dev/null
    if [ -x "$SCREEN_BIN" ]; then
        "$SCREEN_BIN" | tee "$EVIDENCE/screen-state.txt"
    else
        echo "(could not build $SCREEN_STATE)"
    fi
fi

say "System-wide spindump (catches whoever else is stuck)"
if sudo -n /usr/sbin/spindump -reveal 2 1 -file "$EVIDENCE/spindump.txt" >/dev/null 2>&1; then
    echo "written to $EVIDENCE/spindump.txt"
else
    echo "(not permitted -- add /usr/sbin/spindump to /etc/sudoers.d)"
fi

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
    # Cycling display power re-runs the mode set and the gamma upload, which is
    # the cheapest thing that touches both of the states a healthy compositor
    # can still render as black. Nothing is killed. CGSession -suspend used to
    # live here on the claim that it recovered the 18:25 outage; that binary
    # does not exist on macOS 26, so it never ran and cannot have.
    say "Cycling the display (nothing is killed)"
    pmset displaysleepnow
    sleep 4
    caffeinate -u -t 3
fi

if [ "$DO_WSRESTART" = 1 ]; then
    # Heavier than --session: this tears the whole window session down and
    # every app goes with it. Only worth reaching for when re-initialising the
    # session did not bring the display back.
    say "Restarting WindowServer (every app is lost; you land at the login window)"
    sudo -n /usr/bin/killall -HUP WindowServer 2>/dev/null \
        || sudo /usr/bin/killall -HUP WindowServer
fi

if [ "$DO_REBOOT" = 1 ]; then
    say "Rebooting"
    sudo shutdown -r now
fi

say "Evidence kept in $EVIDENCE"
echo "If the screen is still black: --session, then --reboot."
