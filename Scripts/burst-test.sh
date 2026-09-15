#!/bin/bash
#
# ThermalForge burst test — repeatable load for comparing fan profiles.
#
# Usage: select a profile in the menu bar app, then run
#   Scripts/burst-test.sh <label>          e.g. Scripts/burst-test.sh smart
#
# Phases: bursts (3 s load / 5 s idle) for 5 min, sustained load for 3 min, then 2 min
# idle to watch the fan settle. Load is `yes` on every core — on an M4 Mac mini that
# gives ~60–75°C with spikes, like everyday work; compute-bound loops reach 90°C+ in
# seconds and would trip the 95°C safety override. Samples the hottest CPU/GPU core
# (same sensors the profiles use) and fan RPM once a second, then prints a summary.
# The run aborts, and is marked invalid, if the hottest core reaches ABORT_AT (93°C).
#
# Durations can be overridden for a quick check, e.g.
#   BURST_PHASE_SEC=30 SUSTAINED_SEC=10 SETTLE_SEC=10 START_WAIT_SEC=0 Scripts/burst-test.sh smoke
#

set -u

label="${1:?usage: $0 <label>}"
TF="${THERMALFORGE:-thermalforge}"
BURST_SEC="${BURST_SEC:-3}"
IDLE_SEC="${IDLE_SEC:-5}"
BURST_PHASE_SEC="${BURST_PHASE_SEC:-300}"
SUSTAINED_SEC="${SUSTAINED_SEC:-180}"
SETTLE_SEC="${SETTLE_SEC:-120}"
START_BELOW="${START_BELOW:-45}"
START_WAIT_SEC="${START_WAIT_SEC:-300}"
ABORT_AT="${ABORT_AT:-93}"

LOG_DIR="$HOME/Library/Logs/ThermalForge"
mkdir -p "$LOG_DIR"
csv="$LOG_DIR/burst-test-$label-$(date -u +%Y%m%dT%H%M%SZ).csv"
abort_flag="$csv.abort"
cores="$(sysctl -n hw.ncpu)"
load_pids=()
sampler_pid=""

# One status read → "hottest_core_temp rpm". Killed after 5 s so a stuck SMC read
# shows up as a sampling gap instead of stalling the run (macOS has no `timeout`).
sample() {
    perl -e 'alarm shift; exec @ARGV' 5 "$TF" status 2>/dev/null | awk '
        /"T[CpGg][^"]*" *:/ { v = $NF + 0; if (v > t) t = v }
        /"actual_rpm" *:/ && rpm == "" { gsub(/,/, "", $NF); rpm = $NF }
        END { if (t > 0 && rpm != "") printf "%.1f %s\n", t, rpm }'
}

start_load() { for _ in $(seq "$cores"); do yes >/dev/null & load_pids+=($!); done; }
# Guarded: bash 3.2 (macOS) treats an empty array as unbound under set -u
stop_load() {
    if [ ${#load_pids[@]} -gt 0 ]; then
        kill "${load_pids[@]}" 2>/dev/null; wait "${load_pids[@]}" 2>/dev/null
    fi
    load_pids=()
}
cleanup() { stop_load; [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null; rm -f "$abort_flag"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

[ -n "$(sample)" ] || { echo "Can't read sensors with '$TF status'. Is ThermalForge installed?" >&2; exit 1; }

# CPU load doesn't prevent idle sleep; a mid-run sleep freezes both the app and sampling.
# caffeinate exits on its own when this script does.
caffeinate -i -w $$ &

# Start from a comparable state: wait (bounded) for the hottest core to cool
echo "Waiting up to ${START_WAIT_SEC}s for the hottest core to drop below ${START_BELOW}°C..."
# A failed read (empty) counts as "not cool yet", so it can't end the wait early.
waited=0
while :; do
    read -r temp _ <<<"$(sample)"
    whole="${temp%.*}"
    [ -n "$whole" ] && [ "$whole" -lt "$START_BELOW" ] && break
    [ "$waited" -ge "$START_WAIT_SEC" ] && break
    sleep 5; waited=$((waited + 5))
done
echo "Starting at ${temp:-unknown}°C"

total=$((BURST_PHASE_SEC + SUSTAINED_SEC + SETTLE_SEC))
start_epoch=$(date +%s)
start_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "elapsed,phase,temp_c,rpm" >"$csv"

# Sampler: phase is derived from elapsed time so it needs no shared state
(
    while :; do
        e=$(( $(date +%s) - start_epoch ))
        [ "$e" -ge "$total" ] && break
        if [ "$e" -lt "$BURST_PHASE_SEC" ]; then p=bursts
        elif [ "$e" -lt $((BURST_PHASE_SEC + SUSTAINED_SEC)) ]; then p=sustained
        else p=settle; fi
        read -r t r <<<"$(sample)"
        if [ -n "${t:-}" ]; then
            echo "$e,$p,$t,$r" >>"$csv"
            if [ "${t%.*}" -ge "$ABORT_AT" ]; then
                echo "hottest core reached ${t}°C at ${e}s ($p phase)" >"$abort_flag"
                break
            fi
        fi
        sleep 1
    done
) &
sampler_pid=$!

# Sleep for up to $2 seconds, but never past $1 seconds after the start, so the load
# schedule stays aligned with the sampler's phase labels. Sleeps in 1 s steps and
# returns 1 as soon as the sampler flags an abort.
sleep_until() {
    local stop=$(( $(date +%s) - start_epoch + $2 ))
    [ "$stop" -gt "$1" ] && stop=$1
    while [ $(( $(date +%s) - start_epoch )) -lt "$stop" ]; do
        [ -e "$abort_flag" ] && return 1
        sleep 1
    done
    [ ! -e "$abort_flag" ]
}
abort_run() {
    stop_load
    local invalid="${csv%.csv}-ABORTED.csv"
    mv "$csv" "$invalid"
    echo
    echo "ABORTED: $(cat "$abort_flag"). Stopped before the 95°C safety override could max"
    echo "the fans, so this run is invalid and must not be compared. Samples: $invalid"
    exit 3
}
burst_end=$BURST_PHASE_SEC
sustained_end=$((BURST_PHASE_SEC + SUSTAINED_SEC))
total_end=$((sustained_end + SETTLE_SEC))

echo "Phase 1/3: bursts (${BURST_SEC}s load / ${IDLE_SEC}s idle) for ${BURST_PHASE_SEC}s"
while [ $(( $(date +%s) - start_epoch )) -lt "$burst_end" ]; do
    start_load; sleep_until "$burst_end" "$BURST_SEC" || abort_run; stop_load
    sleep_until "$burst_end" "$IDLE_SEC" || abort_run
done

echo "Phase 2/3: sustained load for ${SUSTAINED_SEC}s"
start_load; sleep_until "$sustained_end" "$SUSTAINED_SEC" || abort_run; stop_load

echo "Phase 3/3: idle for ${SETTLE_SEC}s"
sleep_until "$total_end" "$SETTLE_SEC" || abort_run
wait "$sampler_pid"; sampler_pid=""
end_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Fan hand-over events the app logged during the run (any profile's "fans on/off" lines)
events=$(ls -1 "$LOG_DIR"/thermalforge-*.log 2>/dev/null | tail -2 | xargs cat 2>/dev/null |
    awk -F'[][]' -v s="$start_iso" -v e="$end_iso" '$2 >= s && $2 <= e' |
    awk '{ l = tolower($0) } l ~ /fans on:/ { on++ } l ~ /fans off:/ { off++ } END { printf "%d %d", on, off }')

# Profiles the app actually ran, from its trigger and anomaly log lines
profiles_seen=$(ls -1 "$LOG_DIR"/thermalforge-*.log 2>/dev/null | tail -2 | xargs cat 2>/dev/null |
    awk -F'[][]' -v s="$start_iso" -v e="$end_iso" '$2 >= s && $2 <= e' |
    sed -n -E 's/.*\| Profile: (.*)$/\1/p; s/.*Sustained trigger: .* \[(.*)\]$/\1/p' | sort -u | paste -sd, - | sed 's/,/, /g')

# A long gap or early end means sampling stalled (Mac asleep, hung sensor reads), so the
# phases no longer compare. A single slow read leaves a gap of ~6 s, which is fine.
gaps=$(awk -F, -v total="$total" '
    NR > 2 && $1 - prev > 15 { printf "%s%ss→%ss", (n++ ? ", " : ""), prev, $1 }
    NR > 1 { prev = $1 }
    END { if (prev < total - 15) printf "%sended at %ss of %ss", (n ? ", " : ""), prev + 0, total }' "$csv")

echo
echo "Burst test \"$label\" — $start_iso to $end_iso"
echo "Profile(s) the app ran: ${profiles_seen:-unknown (no profile lines logged)}"
echo "Samples: $csv"
if [ -n "$gaps" ]; then
    echo "INVALID: sampling gaps at $gaps (Mac asleep or sensor reads stalled). Don't compare this run."
fi
# Surge: RPM rises ≥1000 above the lowest RPM of the previous 10 samples; re-arms once back within 500.
awk -F, -v events="$events" '
    NR == 1 { next }
    {
        p = $2; t = $3; r = $4
        n[p]++; st[p] += t; sr[p] += r
        if (t > mt[p]) mt[p] = t
        if (r > mr[p]) mr[p] = r
        lo = r; for (i = 1; i <= 10; i++) if ((i in win) && win[i] < lo) lo = win[i]
        if (!surging && r - lo >= 1000) { surges[p]++; surging = 1 }
        else if (surging && r - lo < 500) surging = 0
        for (i = 10; i > 1; i--) if ((i - 1) in win) win[i] = win[i - 1]
        win[1] = r
        N++; ST += t; SR += r; if (r > MR) MR = r; if (t > MT) MT = t
    }
    END {
        printf "%-10s %7s %9s %8s %8s %7s\n", "phase", "avg °C", "peak °C", "avg RPM", "max RPM", "surges"
        split("bursts sustained settle", order, " ")
        for (k = 1; k <= 3; k++) { p = order[k]; if (!(p in n)) continue
            printf "%-10s %7.1f %9.1f %8d %8d %7d\n", p, st[p]/n[p], mt[p], sr[p]/n[p], mr[p], surges[p] + 0
            total_surges += surges[p] }
        if (N) printf "%-10s %7.1f %9.1f %8d %8d %7d\n", "all", ST/N, MT, SR/N, MR, total_surges
        split(events, ev, " ")
        printf "\nFans on events: %d   Fans off events: %d\n", ev[1], ev[2]
    }' "$csv"
