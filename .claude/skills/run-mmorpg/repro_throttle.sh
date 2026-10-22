#!/bin/bash
# Merenje ENet throttle-a pri skoku RTT-a, bez ostalih klijenata (nema čekanja na mesto): server + stub + udp_proksi.py +
# ThrottleLik koji posle 4 s stabilnog hoda dobije RTT +SKOK ms na 2 s. Ispisuje [THROTTLE] i rtt_skok_bez_rupa.
# Upotreba (iz korena repoa): .claude/skills/run-mmorpg/repro_throttle.sh [--crna-rupa=MS] [SKOK_MS=400]...
#   više vrednosti SKOK_MS: krug po vrednosti; --crna-rupa=MS: proxy prvih MS ms odbacuje sve (čekanje na handshake)
set -u
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
D=res://.claude/skills/run-mmorpg/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/repro-throttle}"
PORT="${STUB_PORT:-18767}"
PROKSI_PORT="${PROKSI_PORT:-7790}"
API="--server-url=http://127.0.0.1:$PORT"
mkdir -p "$OUT"
python3 "$(dirname "$0")/stub_api.py" "$PORT" > "$OUT/stub.log" 2>&1 &
PIDS="$!"
trap 'kill $PIDS 2>/dev/null' EXIT
for _ in $(seq 20); do curl -s "127.0.0.1:$PORT/items/apple" > /dev/null && break; sleep 0.2; done
CRNA=0; SKOKOVI=()
for a in "$@"; do case "$a" in --crna-rupa=*) CRNA=${a#*=};; *) SKOKOVI+=("$a");; esac; done
[ ${#SKOKOVI[@]} = 0 ] && SKOKOVI=(400)
for SKOK in "${SKOKOVI[@]}"; do
  rm -f "$OUT"/throttle_* "$OUT"/ugasi_server "$OUT"/faza
  [ "$CRNA" != 0 ] && echo -1 > "$OUT/throttle_rtt" && ( sleep $(echo "scale=3; 1.5 + $CRNA / 1000" | bc); echo 0 > "$OUT/throttle_rtt" ) &
  "$G" --headless --path . --script $D -- server "stop=$OUT/ugasi_server" "dir=$OUT" "$API" maxt=60 > "$OUT/server_$SKOK.log" 2>&1 &
  S=$!
  python3 "$(dirname "$0")/udp_proksi.py" "$PROKSI_PORT" 7777 "$OUT/throttle_rtt" > "$OUT/proksi_$SKOK.log" 2>&1 &
  X=$!
  sleep 1.5
  "$G" --headless --path . --script $D -- throttle "dir=$OUT" "$API" "port=$PROKSI_PORT" "skok=$SKOK" > "$OUT/klijent_$SKOK.log" 2>&1
  touch "$OUT/ugasi_server"; wait $S; kill $X; wait $X 2>/dev/null
  grep -h '^\[THROTTLE\]\|^PASS rtt\|^FAIL rtt\|SCRIPT ERROR' "$OUT/klijent_$SKOK.log"
  grep -h 'za 1 s' "$OUT/proksi_$SKOK.log" | sed 's/^\[PROKSI\] t=[0-9.]* //' | tr '\n' ';' | sed 's/;/\n  /g' | head -20
done
echo "logovi: $OUT"
