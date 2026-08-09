#!/usr/bin/env bash
#
# Reproduce the DirectDraw black screen under controlled conditions, and record
# enough to tell afterwards what actually happened.
#
# Run it from a terminal on the Mac itself, NOT over ssh: an ssh session has no
# access to the window server, so Wine loads no display driver and the test
# never gets a window ("no driver could be loaded").
#
# The test is given --bench N --autoclose 1 so it exits on its own. That is
# deliberate: the first freeze happened while closing the window by hand, so
# taking that out of the loop separates "the test cannot run" from "closing it
# is what breaks".
#
# Usage:
#   scripts/ddraw-repro.sh                    # current path: wined3d on OpenGL
#   scripts/ddraw-repro.sh --renderer vulkan  # wined3d on Vulkan (KosmicKrisp)
#   scripts/ddraw-repro.sh --both             # both, in sequence, and compare
#   scripts/ddraw-repro.sh --test dx8         # a different backend
#   scripts/ddraw-repro.sh --env bare        # without the variables Whisky sets
#   scripts/ddraw-repro.sh --repeat 3        # same combination three times
#
# --env is the one that has actually separated a good run from a bad one. On
# 2026-08-09 the same test at 18:47:33 came up clean under the full Whisky
# environment and blacked the display at 18:47:56 under a bare one, 12 seconds
# apart. That is a single pair, so it may yet be luck -- hence --repeat.
#
# If the screen goes black: the machine is usually still on the network. From
# another host, ssh in and run scripts/whisky-panic.sh (add --session if the
# display stays dark). Do not reach for the power button first -- that is what
# loses filesystem state, and it destroys the evidence this script exists to
# collect.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXE="${AIO_EXE:-$HOME/Downloads/AIO-Graphics-Test-64bit.exe}"
WINE_DIR="$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine"
BOTTLES="$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"

RENDERER=gl
TEST=ddraw2d
SECONDS_RUN=5
BOTH=0
ENVSET=whisky
REPEAT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --renderer) RENDERER="$2"; shift 2 ;;
        --test)     TEST="$2";     shift 2 ;;
        --seconds)  SECONDS_RUN="$2"; shift 2 ;;
        --both)     BOTH=1; shift ;;
        --env)      ENVSET="$2"; shift 2 ;;
        --repeat)   REPEAT="$2"; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '\n\033[1m=== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- preflight ---------------------------------------------------------------
[ -n "${SSH_CONNECTION:-}" ] && die "run this from a terminal on the Mac, not over ssh -- Wine gets no display driver in an ssh session"
[ -f "$EXE" ] || die "test binary not found: $EXE (set AIO_EXE=/path/to/it)"
[ -x "$WINE_DIR/bin/wine64" ] || die "Wine not installed at $WINE_DIR"

BOTTLE="${WHISKY_BOTTLE:-$(ls -d "$BOTTLES"/*/ 2>/dev/null | head -1)}"
[ -n "$BOTTLE" ] && [ -d "$BOTTLE" ] || die "no bottle found under $BOTTLES"

OUT="/tmp/ddraw-repro-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
JOURNAL="$OUT/journal.txt"

# Everything is also written to a file as it happens. Once the display is black
# there is nothing to read on screen, and a run that has to be watched to be
# useful is no use at all for the failure being chased.
exec > >(tee -a "$JOURNAL") 2>&1

# A black screen is announced out loud, because that is the one channel the
# failure does not take away.
announce() { command say -r 200 "$*" >/dev/null 2>&1 & }

SCREEN_BIN="/tmp/whisky-screen-state"
if [ ! -x "$SCREEN_BIN" ] && [ -f "$SCRIPT_DIR/screen-state.c" ]; then
    cc -O2 -o "$SCREEN_BIN" "$SCRIPT_DIR/screen-state.c" -framework ApplicationServices 2>/dev/null
fi

# What the screen looks like before anything has run. A covering window is only
# meaningful as "one that was not there a moment ago", so the comparison needs
# a before.
if [ -x "$SCREEN_BIN" ]; then
    "$SCREEN_BIN" > "$OUT/screen-baseline.txt" 2>&1
    BASELINE_WINDOWS=$(grep -c '^  [0-9-]' "$OUT/screen-baseline.txt" 2>/dev/null || echo 0)
else
    BASELINE_WINDOWS=0
    warn "screen-state probe unavailable -- a black screen will not be detected automatically"
fi

# Is the display showing anything? Answers the two states a healthy compositor
# can still render as black: a gamma ramp collapsed to zero, and a window that
# appeared over everything. Echoes "ok", or a reason.
screen_verdict() {   # <file to write the probe output to>
    local file="$1"
    [ -x "$SCREEN_BIN" ] || { echo "unknown"; return; }
    "$SCREEN_BIN" > "$file" 2>&1

    if grep -q 'GAMMA IS BLACK' "$file"; then
        echo "gamma collapsed to zero"
        return
    fi
    local now
    now=$(grep -c '^  [0-9-]' "$file" 2>/dev/null || echo 0)
    if [ "$now" -gt "$((BASELINE_WINDOWS + 2))" ]; then
        echo "$((now - BASELINE_WINDOWS)) more on-screen windows than before the run"
        return
    fi
    echo ok
}

# --- one run -----------------------------------------------------------------
run_once() {  # <renderer>
    local renderer="$1"
    local tag="$TEST-$renderer-$ENVSET-$(date +%H%M%S)"
    local log="$OUT/$tag.log"
    local started ended

    say "Running $TEST -- renderer=$renderer env=$ENVSET (${SECONDS_RUN}s, exits on its own)"

    # Only what Wine cannot run without. Anything beyond this is what the
    # comparison is about.
    local -a env_vars=(
        "WINEPREFIX=$BOTTLE"
        "WINEDEBUG=+winediag"
        "DYLD_FALLBACK_LIBRARY_PATH=$WINE_DIR/lib"
    )
    # The rest is what the Whisky app sets when it launches a program, so a
    # `whisky` run reflects how a bottle actually behaves and a `bare` one
    # reflects launching the same binary from a shell by hand.
    if [ "$ENVSET" = whisky ]; then
        env_vars+=(
            "PROTON_DISABLE_LSTEAMCLIENT=1"
            "WINEMSYNC_NO_MANUALEVENT=1"
            "WINE_NX_COMPAT=1"
            "WINE_DISABLE_IPV6=1"
            "SDL_JOYSTICK_MFI=0"
            "GST_DEBUG=1"
            "DXVK_CONFIG=dxvk.numCompilerThreads = 4"
        )
    fi
    # wined3d reads this ahead of the registry and it lasts exactly one run, so
    # nothing persists into the bottle either way.
    [ "$renderer" = vulkan ] && env_vars+=("WINE_D3D_CONFIG=renderer=vulkan")

    started="$(date '+%Y-%m-%d %H:%M:%S')"
    ( cd "$OUT" && env "${env_vars[@]}" \
        "$WINE_DIR/bin/wine64" "$EXE" --cube "$TEST" --bench "$SECONDS_RUN" --autoclose 1 ) \
        > "$log" 2>&1 &
    local pid=$!

    # A run that never returns is the interesting failure, so bound it rather
    # than leaving a wedged process holding the GPU.
    ( sleep $((SECONDS_RUN + 60)); kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill "$watchdog" 2>/dev/null
    ended="$(date '+%Y-%m-%d %H:%M:%S')"

    say "Result for $tag (exit $rc)"

    # Which renderer wined3d actually chose. Selecting it is the whole point of
    # the vulkan run, and it is silent about falling back.
    grep -iE 'Using the (Vulkan|OpenGL) renderer' "$log" | sed 's/^/  /' \
        || warn "  wined3d never reported a renderer (it may not have initialised)"

    grep -iE 'no driver could be loaded|explorer process failed' "$log" >/dev/null \
        && warn "  no display driver -- this shell has no window server access"

    # Metal compiles are the mechanism behind the first freeze: a fixed-function
    # title specialises a pipeline per render state, and each one is a compile.
    local compiles
    compiles=$(log show --start "$started" --end "$ended" --style compact 2>/dev/null \
        | grep -c 'Compilation BEGIN')
    echo "  Metal compiles during the run: $compiles"

    # A frozen machine stops logging; a live one does not. This is the only
    # signal that reliably separated the two failures so far.
    log show --start "$started" --end "$ended" --style compact 2>/dev/null \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:' \
        | cut -c1-16 | uniq -c > "$OUT/$tag.log-volume.txt"
    echo "  log volume per minute -> $OUT/$tag.log-volume.txt"

    local gpuerr
    gpuerr=$(log show --start "$started" --end "$ended" --style compact 2>/dev/null \
        | grep -icE 'AGX|IOAF|GPU restart|GPU hang|device lost|link unstable')
    echo "  GPU/display errors: $gpuerr"

    printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$rc" "$compiles" "$gpuerr" "$started" \
        >> "$OUT/summary.tsv"

    # Let the compositor settle before asking: the window is torn down
    # asynchronously and a verdict taken too early reports the teardown, not
    # the state it settles into.
    sleep 3
    local verdict
    verdict="$(screen_verdict "$OUT/$tag.screen.txt")"
    echo "  screen after the run: $verdict"
    printf '%s\tscreen: %s\n' "$tag" "$verdict" >> "$OUT/summary.tsv"

    if [ "$verdict" != ok ] && [ "$verdict" != unknown ]; then
        warn "  DISPLAY BROKE -- $verdict"
        announce "black screen detected. stopping."
        SCREEN_BROKE=1

        # The ramp is display state and outlives the process that set it, so
        # nothing puts it back on its own. This runs in the window session
        # already, which is where it has to happen.
        say "Trying to bring the display back (nothing is killed)"
        [ -x "$SCREEN_BIN" ] && "$SCREEN_BIN" --restore
        pmset displaysleepnow
        sleep 4
        caffeinate -u -t 3
        sleep 2
        echo "  after the display cycle: $(screen_verdict "$OUT/$tag.screen-after.txt")"
    else
        announce "pass done. screen ok."
    fi
}

printf 'test\texit\tcompiles\tgpu_errors\tstarted\n' > "$OUT/summary.tsv"

SCREEN_BROKE=0
for i in $(seq 1 "$REPEAT"); do
    if [ "$SCREEN_BROKE" = 1 ]; then
        warn "Stopping after pass $((i - 1)): further passes would run blind"
        break
    fi
    [ "$REPEAT" -gt 1 ] && say "Pass $i of $REPEAT"
    if [ "$BOTH" = 1 ]; then
        run_once gl
        say "Pausing 10s so the two runs stay separable in the log"
        sleep 10
        run_once vulkan
    else
        run_once "$RENDERER"
    fi
    [ "$i" -lt "$REPEAT" ] && sleep 10
done

say "Summary"
column -t -s "$(printf '\t')" "$OUT/summary.tsv"
echo
echo "Everything written to $OUT (journal.txt has this whole transcript)"
echo "If the display breaks later, ssh in from another host and run:"
echo "  $SCRIPT_DIR/whisky-panic.sh --session"
