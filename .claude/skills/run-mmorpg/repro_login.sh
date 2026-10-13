#!/bin/bash
# Reprodukcija rupa u seq obradi posle prijave: jedan server + stub, pa N kratkih prijava potion
# klijenta (TestLik) jedna za drugom. Server radi sa MMORPG_DEBUG_SEQ=1 i beleži svaku rupu ([SEQ]).
# Upotreba (iz korena repoa): .claude/skills/run-mmorpg/repro_login.sh [N=30] [--opterecenje] [--aktivnost]
#   --opterecenje: 4 procesa `yes > /dev/null` za vreme petlje (gase se na kraju)
#   --aktivnost:   klijent svakih 0.2 s šalje reliable zahtev za predmet (kao potion test)
#   --izgubi-reset: klijent odbaci reset posle prijave (učitavanje pozicije iz baze), test hook
set -u
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
D=res://.claude/skills/run-mmorpg/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/repro-login}"
N=30; case "${1:-}" in [0-9]*) N=$1;; esac
PORT="${STUB_PORT:-18766}"
API="--server-url=http://127.0.0.1:$PORT"
mkdir -p "$OUT"; rm -f "$OUT"/*.log "$OUT"/ugasi_server

python3 "$(dirname "$0")/stub_api.py" "$PORT" > "$OUT/stub.log" 2>&1 &
PIDS="$!"
trap 'kill $PIDS 2>/dev/null' EXIT
for _ in $(seq 20); do curl -s "127.0.0.1:$PORT/items/apple" > /dev/null && break; sleep 0.2; done
OPT=0; AKT=""
IZG=""
for a in "$@"; do case "$a" in --opterecenje) OPT=1;; --aktivnost) AKT="aktivnost=1";; --izgubi-reset) IZG="izgubi_reset=1";; esac; done
if [ $OPT = 1 ]; then
  for _ in 1 2 3 4; do yes > /dev/null & PIDS="$PIDS $!"; done
fi
echo "load average: $(sysctl -n vm.loadavg)"

MMORPG_DEBUG_SEQ=1 "$G" --headless --path . --script $D -- server "stop=$OUT/ugasi_server" "dir=$OUT" "$API" "maxt=$((N * 20 + 60))" > "$OUT/server.log" 2>&1 &
S=$!
sleep 1.5
for i in $(seq "$N"); do
  MMORPG_DEBUG_SEQ=1 "$G" --headless --path . --script $D -- prijava "dir=$OUT" "$API" $AKT $IZG > "$OUT/prijava_$i.log" 2>&1
  sleep 0.5 # server snimi i ukloni lik pre sledeće prijave (isti TestLik)
done
touch "$OUT/ugasi_server"; wait $S

# rupe po prijavi: peer id iz [SEQ] linija servera, redom kojim su se peer-ovi pojavili
echo "prijava  rupa  razlozi"
i=0
for peer in $(grep -o 'Peer [0-9]* -> TestLik' "$OUT/server.log" | awk '{print $2}'); do
  i=$((i + 1))
  n=$(grep -c "^\[SEQ\] peer $peer RUPA" "$OUT/server.log")
  r=$(grep "^\[SEQ\] peer $peer RUPA" "$OUT/server.log" | grep -o 'razlog=[a-z ]*[a-z]' | sort | uniq -c | tr -s ' ' | tr '\n' ',')
  printf "%7d  %4d  %s\n" "$i" "$n" "$r"
done
echo "ukupno rupa: $(grep -c '^\[SEQ\] peer [0-9]* RUPA' "$OUT/server.log"), prijava sa rupama: $(grep '^\[SEQ\] peer [0-9]* RUPA' "$OUT/server.log" | awk '{print $3}' | sort -u | wc -l | tr -d ' ')/$N"
echo "klijent preskočio slanje: $(cat "$OUT"/prijava_*.log | grep -c 'preskočio slanje'), kasno stigli (van reda): $(grep -c 'KASNO' "$OUT/server.log")"
echo "snap-ova: $(cat "$OUT"/prijava_*.log | grep -o 'PRIJAVA_KRAJ snap=[0-9]*' | cut -d= -f2 | paste -sd+ - | bc), najveća greška: $(cat "$OUT"/prijava_*.log | grep -o 'greska_max=[0-9.]*' | cut -d= -f2 | sort -n | tail -1) m"
echo "prijava koje je server video: $(grep -c -- '-> TestLik' "$OUT/server.log")/$N, SCRIPT ERROR: $(cat "$OUT"/*.log | grep -c 'SCRIPT ERROR')"
echo "logovi: $OUT"
