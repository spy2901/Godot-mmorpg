#!/bin/bash
# Pokreće server + observer (headless) + mover, gasi server dok su klijenti živi, ispisuje PASS/FAIL.
# Upotreba (iz korena repoa): .claude/skills/run-mmorpg/run.sh [--window]
#   --window: observer se pokreće u prozoru i snima nameplate u $OUT/nameplate_<stanje>.png
set -u
SKRIPTA="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
# uvoz resursa (translations/teksti.csv -> .translation): bez ovoga posle izmene CSV-a igra koristi stare prevode
"$G" --headless --path . --import > /dev/null 2>&1 || true
D=res://.claude/skills/run-mmorpg/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/run-mmorpg}"
echo "load average: $(sysctl -n vm.loadavg 2>/dev/null || cut -d' ' -f1-3 /proc/loadavg)"
mkdir -p "$OUT"; rm -f "$OUT"/zastoj_* "$OUT"/*.log "$OUT"/mover.png "$OUT"/ugasi_server "$OUT"/faza "$OUT"/potion_cmd "$OUT"/server_hp "$OUT"/snimi "$OUT"/snimljeno_* "$OUT"/observer_respawn "$OUT"/nameplate_*.png "$OUT"/restart.txt "$OUT"/visi_id "$OUT"/izgubljeno_* "$OUT"/cilj_* "$OUT"/drugi_* "$OUT"/ai_* "$OUT"/oprema_* "$OUT"/napredak_* "$OUT"/quest_* "$OUT"/lovac_* "$OUT"/buff_* "$OUT"/buff2_* "$OUT"/brzina_*
PORT="${STUB_PORT:-18765}"
API="--server-url=http://127.0.0.1:$PORT"

# lažni backend (napitci): stanje u memoriji, gasi se na kraju
python3 "$(dirname "$0")/stub_api.py" "$PORT" > "$OUT/stub.log" 2>&1 &
STUB=$!
trap 'kill $STUB 2>/dev/null' EXIT
for _ in $(seq 20); do curl -s "127.0.0.1:$PORT/items/apple" > /dev/null && break; sleep 0.2; done
# stub uvozi napredak.py iz backend repoa (BACKEND_DIR, podrazumevano ~/mmorpg-server): bez njega nema kruga
kill -0 $STUB 2>/dev/null || { echo "FAIL stub_api  nije pokrenut ($(tail -1 "$OUT/stub.log"))"; exit 1; }

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
  pokreni observer "$OUT/observer.log" "$G" --path . --resolution 1280x720 --script $D -- observer "dir=$OUT" "shot=$OUT/nameplate" "$API"
else
  pokreni observer "$OUT/observer.log" "$G" --headless --path . --script $D -- observer "dir=$OUT" "$API"
fi
O=$PID
# mover meri vreme od svog lika, a observer mora da ga vidi od početka: čekaj observer (prozor kasni ~8 s)
for _ in $(seq 120); do grep -q OBSERVER_SPREMAN "$OUT/observer.log" 2>/dev/null && break; sleep 0.5; done
pokreni mover "$OUT/mover.log" "$G" --headless --path . --script $D -- mover "dir=$OUT"
M=$PID
sleep 0.3 # razmak između klijenata (istovremeni start ume da sruši Godot u RotatedFileLogger)
pokreni potion "$OUT/potion.log" "$G" --headless --path . --script $D -- potion "dir=$OUT" "$API"
P=$PID
sleep 0.3
pokreni visi "$OUT/visi.log" "$G" --headless --path . --script $D -- visi "dir=$OUT"
V=$PID
sleep 0.3
# raspored action bara: korak 1 menja raspored i odjavi se, korak 2 (novi proces) je ponovna prijava istog lika
( pokreni raspored1 "$OUT/raspored1.log" "$G" --headless --path . --script $D -- raspored korak=1 "dir=$OUT" "$API"
  wait $PID
  pokreni raspored2 "$OUT/raspored2.log" "$G" --headless --path . --script $D -- raspored korak=2 "dir=$OUT" "$API"
  wait $PID ) &
R=$!
sleep 0.3
pokreni cilj "$OUT/cilj.log" "$G" --headless --path . --script $D -- cilj "dir=$OUT" "$API"
C=$PID
sleep 0.3
pokreni drugi "$OUT/drugi.log" "$G" --headless --path . --script $D -- drugi "dir=$OUT" "$API"
DR=$PID
sleep 0.3
pokreni ai1 "$OUT/ai1.log" "$G" --headless --path . --script $D -- ai korak=1 "dir=$OUT" "$API"
A1=$PID
sleep 0.3
pokreni ai2 "$OUT/ai2.log" "$G" --headless --path . --script $D -- ai korak=2 "dir=$OUT" "$API"
A2=$PID
sleep 0.3
# oprema: korak 1 oprema i skida i odjavi se, korak 2 (novi proces) je ponovna prijava; korak 3 = drugi igrač
( pokreni oprema1 "$OUT/oprema1.log" "$G" --headless --path . --script $D -- oprema korak=1 "dir=$OUT" "$API"
  wait $PID
  pokreni oprema2 "$OUT/oprema2.log" "$G" --headless --path . --script $D -- oprema korak=2 "dir=$OUT" "$API"
  wait $PID ) &
OP=$!
sleep 0.3
pokreni oprema3 "$OUT/oprema3.log" "$G" --headless --path . --script $D -- oprema korak=3 "dir=$OUT" "$API"
O3=$PID
sleep 0.3
# napredak: korak 1 ubistva (level-up, više nivoa, nivo 20) i odjava, korak 2 (novi proces) je ponovna prijava
( pokreni napredak1 "$OUT/napredak1.log" "$G" --headless --path . --script $D -- napredak korak=1 "dir=$OUT" "$API"
  wait $PID
  pokreni napredak2 "$OUT/napredak2.log" "$G" --headless --path . --script $D -- napredak korak=2 "dir=$OUT" "$API"
  wait $PID ) &
NP=$!
sleep 0.3
# sadržaj: QuestLik (quest NPC klikom, loot, XP) i PosmatracLik (pored, ne napada) istovremeno
pokreni quest1 "$OUT/quest1.log" "$G" --headless --path . --script $D -- quest korak=1 "dir=$OUT" "$API"
Q1=$PID
sleep 0.3
pokreni quest2 "$OUT/quest2.log" "$G" --headless --path . --script $D -- quest korak=2 "dir=$OUT" "$API"
Q2=$PID
sleep 0.3
pokreni quest3 "$OUT/quest3.log" "$G" --headless --path . --script $D -- quest korak=3 "dir=$OUT" "$API"
Q3=$PID
# buffovi: BuffLik (eliksiri) i Buff2Lik (napadač bez buff-a) istovremeno, tek kad cilj i drugi izađu: server prima
# najviše MAX_PLAYERS (8), pa bi dva klijenta više na početku odložila PosmatracLik-a (QuestLik ga čeka do PARTNER_ROK)
( while kill -0 $C 2>/dev/null || kill -0 $DR 2>/dev/null; do sleep 0.5; done
  pokreni buff1 "$OUT/buff1.log" "$G" --headless --path . --script $D -- buff korak=1 "dir=$OUT" "$API"
  B1=$PID
  sleep 0.3
  pokreni buff2 "$OUT/buff2.log" "$G" --headless --path . --script $D -- buff korak=2 "dir=$OUT" "$API"
  B2=$PID
  sleep 0.3
  # brzina: korak 1 BrzinaLik (buff brzine pod veštačkim RTT-om, smrt, odjava), korak 2 ponovna prijava
  pokreni brzina1 "$OUT/brzina1.log" "$G" --headless --path . --script $D -- brzina korak=1 "dir=$OUT" "$API"
  wait $PID
  pokreni brzina2 "$OUT/brzina2.log" "$G" --headless --path . --script $D -- brzina korak=2 "dir=$OUT" "$API"
  wait $B1 $B2 $PID ) &
BF=$!

# kad mover završi provere kretanja, ugasi server dok su klijenti još živi
for _ in $(seq 240); do
  grep -q CEKAM_GASENJE "$OUT/mover.log" 2>/dev/null && break
  kill -0 $M 2>/dev/null || break
  sleep 0.5
done
# raspored, cilj, drugi i AI scenario (server upiše ai_gotov) moraju da završe pre gašenja servera. Rok 240 s = 2 * MAX_T
# (driver.gd): uloga koja čeka partnera (PARTNER_ROK) živi toliko; uspeh je čim sve završe. Mover čeka gašenje 250 s.
CEKANJE_OD=$SECONDS
for _ in $(seq 480); do
  { kill -0 $R || kill -0 $C || kill -0 $DR || kill -0 $A1 || kill -0 $A2 || kill -0 $OP || kill -0 $O3 || kill -0 $NP || kill -0 $Q1 || kill -0 $Q2 || kill -0 $Q3 || kill -0 $BF || [ ! -f "$OUT/ai_gotov" ]; } 2>/dev/null || break
  sleep 0.5
done
echo "uloge završile $((SECONDS - CEKANJE_OD)) s posle movera"
touch "$OUT/ugasi_server"
wait $M $O $S $P $V $R $C $DR $A1 $A2 $OP $O3 $NP $Q1 $Q2 $Q3 $BF

echo "logovi: $OUT"
grep -h '^PASS\|^FAIL\|^WARN \|screenshot\|korekcije' "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log "$OUT"/visi.log "$OUT"/raspored1.log "$OUT"/raspored2.log "$OUT"/cilj.log "$OUT"/drugi.log "$OUT"/ai1.log "$OUT"/ai2.log "$OUT"/oprema1.log "$OUT"/oprema2.log "$OUT"/oprema3.log "$OUT"/napredak1.log "$OUT"/napredak2.log "$OUT"/quest1.log "$OUT"/quest2.log "$OUT"/quest3.log "$OUT"/buff1.log "$OUT"/buff2.log "$OUT"/brzina1.log "$OUT"/brzina2.log "$OUT"/server.log
if grep -q "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log; then
  echo "FAIL nema_greske_neaktivnog_peera  $(grep -ch "isn't currently active\|No multiplayer peer is assigned" "$OUT"/mover.log "$OUT"/observer.log "$OUT"/potion.log | paste -sd+ - | bc) linija"
else
  echo "PASS nema_greske_neaktivnog_peera"
fi | tee "$OUT/run.log"
# server ne šalje HP igraču koji je otišao (regeneracija dok server snima odjavu; stub drži /save Oprema2Lik-a)
if ! grep -q "spori save Oprema2Lik" "$OUT/stub.log"; then
  echo "FAIL server_ne_salje_hp_odjavljenom  scenario nije odrađen (nema sporog save-a Oprema2Lik-a u stub.log)"
elif grep -q "Attempt to call RPC with unknown peer ID" "$OUT/server.log"; then
  echo "FAIL server_ne_salje_hp_odjavljenom  $(grep -c "Attempt to call RPC with unknown peer ID" "$OUT/server.log") grešaka; prva: $(grep -m1 -A4 "Attempt to call RPC with unknown peer ID" "$OUT/server.log" | grep -o '\[0\] [^ ]*' | head -1)"
else
  echo "PASS server_ne_salje_hp_odjavljenom"
fi | tee -a "$OUT/run.log"
# /save: game server šalje raspored koji backend prihvata (int slot i kolicina), i za lik koji tokom sesije ne menja
# inventar (tada ide raspored iz baze; JSON ga čita kao float). Stub validira kao backend i upozori kao on.
# (Odbijanje zbog broja komada je namerno: raspored se mimoišao sa izmenom na serveru, ostaje stanje iz baze.)
if grep -q "neispravan inventory/equipment (format" "$OUT/stub.log"; then
  echo "FAIL save_raspored_prihvacen  $(grep -c "(format" "$OUT/stub.log") odbijenih zbog formata; likovi: $(grep "(format" "$OUT/stub.log" | grep -o "save '[A-Za-z0-9]*'" | sort -u | tr '\n' ' ')"
else
  echo "PASS save_raspored_prihvacen  $(grep -c 'POST /players/[A-Za-z0-9]*/save' "$OUT/stub.log") snimanja, nijedno zbog formata ($(grep -c "(broj komada)" "$OUT/stub.log") zbog broja komada)"
fi | tee -a "$OUT/run.log"
# tekstovi (bez Godot-a): poruke backenda u translations/teksti.csv, bez srpskog u prikazu
python3 .claude/skills/run-mmorpg/proveri_tekstove.py > "$OUT/tekstovi.log" 2>&1; cat "$OUT/tekstovi.log"
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
# WARN (neodlučno) ne obara krug: uspeh = nema FAIL i PASS + WARN = 168
! grep -qh '^FAIL' "$OUT"/*.log && [ "$(grep -ch '^PASS \|^WARN ' "$OUT"/*.log | paste -sd+ - | bc)" -eq 168 ]
