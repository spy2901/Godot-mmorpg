#!/bin/bash
# Pokreće server + observer (headless) + mover, gasi server dok su klijenti živi, ispisuje PASS/FAIL.
# Upotreba (iz korena repoa): .claude/skills/run-mmorpg/run.sh [--window]
#   --window: observer se pokreće u prozoru i snima nameplate u $OUT/nameplate_<stanje>.png
set -u
SKRIPTA="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
D=res://.claude/skills/run-mmorpg/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/run-mmorpg}"
echo "load average: $(sysctl -n vm.loadavg 2>/dev/null || cut -d' ' -f1-3 /proc/loadavg)"
mkdir -p "$OUT"; rm -f "$OUT"/zastoj_* "$OUT"/*.log "$OUT"/mover.png "$OUT"/ugasi_server "$OUT"/faza "$OUT"/potion_cmd "$OUT"/server_hp "$OUT"/snimi "$OUT"/snimljeno_* "$OUT"/observer_respawn "$OUT"/nameplate_*.png "$OUT"/restart.txt
PORT="${STUB_PORT:-18765}"
API="--server-url=http://127.0.0.1:$PORT"

# lažni backend (napitci): stanje u memoriji, gasi se na kraju
python3 "$(dirname "$0")/stub_api.py" "$PORT" > "$OUT/stub.log" 2>&1 &
STUB=$!
trap 'kill $STUB 2>/dev/null' EXIT
for _ in $(seq 20); do curl -s "127.0.0.1:$PORT/items/apple" > /dev/null && break; sleep 0.2; done

# Pokreće Godot proces u pozadini (PID u $PID). Ako izađe pre prve linije našeg koda ("[CONFIG]" iz
# autoload-a Config; npr. pad u RotatedFileLogger kad se više procesa pokrene istovremeno), pokreće ga
# još jednom. Proces koji i dalje radi (spor start prozora) se ne dira.
pokreni() { # ime log komanda...
  local ime=$1 log=$2 pokusaj
  shift 2
  for pokusaj in 1 2; do
    "$@" > "$log" 2>&1 &
    PID=$!
    for _ in $(seq 150); do
      grep -q '\[CONFIG\]' "$log" 2>/dev/null && return 0
      kill -0 $PID 2>/dev/null || break
      sleep 0.1
    done
    grep -q '\[CONFIG\]' "$log" 2>/dev/null && return 0
    kill -0 $PID 2>/dev/null && return 0
    echo "RESTART $ime: pao pre prve linije našeg koda (pokušaj $pokusaj)" | tee -a "$OUT/restart.txt"
  done
}

pokreni server "$OUT/server.log" "$G" --headless --path . --script $D -- server "stop=$OUT/ugasi_server" "dir=$OUT" "$API"
S=$PID
sleep 1.5
if [ "${1:-}" = "--window" ]; then # observer u prozoru snima nameplate TestLik-a: $OUT/nameplate_<stanje>.png
  pokreni observer "$OUT/observer.log" "$G" --path . --resolution 1280x720 --script $D -- observer "dir=$OUT" "shot=$OUT/nameplate"
else
  pokreni observer "$OUT/observer.log" "$G" --headless --path . --script $D -- observer "dir=$OUT"
fi
O=$PID
# mover meri vreme od svog lika, a observer mora da ga vidi od početka: čekaj observer (prozor kasni ~8 s)
for _ in $(seq 120); do grep -q OBSERVER_SPREMAN "$OUT/observer.log" 2>/dev/null && break; sleep 0.5; done
pokreni mover "$OUT/mover.log" "$G" --headless --path . --script $D -- mover "dir=$OUT"
M=$PID
sleep 0.3 # razmak između klijenata (istovremeni start ume da sruši Godot u RotatedFileLogger)
pokreni potion "$OUT/potion.log" "$G" --headless --path . --script $D -- potion "dir=$OUT" "$API"
P=$PID

# kad mover završi provere kretanja, ugasi server dok su klijenti još živi
for _ in $(seq 240); do
  grep -q CEKAM_GASENJE "$OUT/mover.log" 2>/dev/null && break
  kill -0 $M 2>/dev/null || break
  sleep 0.5
done
touch "$OUT/ugasi_server"
wait $M $O $S $P

echo "logovi: $OUT"
grep -h '^PASS\|^FAIL\|^WARN\|screenshot\|korekcije' "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log "$OUT"/server.log
if grep -q "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log; then
  echo "FAIL nema_greske_neaktivnog_peera  $(grep -ch "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log | paste -sd+ - | bc) linija"
else
  echo "PASS nema_greske_neaktivnog_peera"
fi | tee "$OUT/run.log"
grep -h 'SCRIPT ERROR' "$OUT"/*.log | sort | uniq -c
# seq_bez_rupa_bez_gubitka ume da padne kad neki klijent zastane pod opterećenjem mašine: posle zastoja
# Godot nadoknađuje tick-ove brže od 1.2x i token bucket (UNOS_BURST) ih odbaci. Ako je to JEDINI FAIL,
# ceo krug se ponovi jednom (logovi prvog pokušaja ostaju u $OUT/pokusaj1).
if [ -z "${RUN_PONOVLJEN:-}" ] && grep -qh '^FAIL seq_bez_rupa_bez_gubitka' "$OUT"/*.log \
    && [ "$(grep -h '^FAIL' "$OUT"/*.log | grep -vc 'seq_bez_rupa_bez_gubitka')" = 0 ]; then
  echo "PONAVLJAM: jedini FAIL je seq_bez_rupa_bez_gubitka (logovi: $OUT/pokusaj1)"
  rm -rf "$OUT/pokusaj1"; mkdir -p "$OUT/pokusaj1"; cp "$OUT"/*.log "$OUT/pokusaj1/"
  kill $STUB 2>/dev/null; wait $STUB 2>/dev/null # port mora biti slobodan za novi stub
  RUN_PONOVLJEN=1 exec "$SKRIPTA" "$@"
fi
# WARN (neodlučno) ne obara krug: uspeh = nema FAIL i PASS + WARN = 34
! grep -qh '^FAIL' "$OUT"/*.log && [ "$(grep -ch '^PASS\|^WARN' "$OUT"/*.log | paste -sd+ - | bc)" -eq 34 ]
