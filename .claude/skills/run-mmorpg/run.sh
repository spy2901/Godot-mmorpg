#!/bin/bash
# Pokreće server + observer (headless) + mover, gasi server dok su klijenti živi, ispisuje PASS/FAIL.
# Upotreba (iz korena repoa): .claude/skills/run-mmorpg/run.sh [--window]
#   --window: mover se pokreće u prozoru i snima screenshot u $OUT/mover.png
set -u
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
D=res://.claude/skills/run-mmorpg/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/run-mmorpg}"
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/mover.png "$OUT"/ugasi_server

"$G" --headless --path . --script $D -- server "stop=$OUT/ugasi_server" > "$OUT/server.log" 2>&1 &
S=$!
sleep 1.5
"$G" --headless --path . --script $D -- observer > "$OUT/observer.log" 2>&1 &
O=$!
sleep 0.5
if [ "${1:-}" = "--window" ]; then
  "$G" --path . --resolution 1280x720 --script $D -- mover "shot=$OUT/mover.png" > "$OUT/mover.log" 2>&1 &
else
  "$G" --headless --path . --script $D -- mover > "$OUT/mover.log" 2>&1 &
fi
M=$!

# kad mover završi provere kretanja, ugasi server dok su klijenti još živi
for _ in $(seq 240); do
  grep -q CEKAM_GASENJE "$OUT/mover.log" 2>/dev/null && break
  kill -0 $M 2>/dev/null || break
  sleep 0.5
done
touch "$OUT/ugasi_server"
wait $M $O $S

echo "logovi: $OUT"
grep -h '^PASS\|^FAIL\|screenshot' "$OUT"/mover.log "$OUT"/observer.log
if grep -q "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log; then
  echo "FAIL nema_greske_neaktivnog_peera  $(grep -ch "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log | paste -sd+ - | bc) linija"
else
  echo "PASS nema_greske_neaktivnog_peera"
fi | tee "$OUT/run.log"
grep -h 'SCRIPT ERROR' "$OUT"/*.log | sort | uniq -c
! grep -qh '^FAIL' "$OUT"/*.log && [ "$(grep -ch '^PASS' "$OUT"/*.log | paste -sd+ - | bc)" -eq 9 ]
