#!/bin/bash
# /test-pi: dva prava klijenta (agent_test nalozi) protiv Pi-ja; uz --deploy pre toga lokalne provere (run-mmorpg) i deploy.
# Upotreba (iz korena repoa): .claude/skills/test-pi/run.sh [--deploy] [--bez-prozora] [--registruj]
#   bez --deploy:  Pi se ne menja (nema lokalnog kruga, export-a, scp-a ni restarta); journal se gleda od
#                  poslednjeg starta mmorpg-game
#   --deploy:      lokalne provere, export .pck, scp na Pi i restart mmorpg-game, pa klijenti (samo uz odobrenje korisnika)
#   --bez-prozora: igrac1 headless, bez screenshot-a
#   --registruj:   ako agent_test nalog ne postoji, registruj ga preko /auth/register
#   --bez-deploya: stara opcija, sada podrazumevana; ne radi ništa (samo upozorenje)
# Tajne (.env.test) idu samo kroz env procesa; nikad echo, argumenti ni log.
set -u
cd "$(dirname "$0")/../../.." || exit 1
G="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
D=res://.claude/skills/test-pi/driver.gd
OUT="${OUT:-${TMPDIR:-/tmp}/test-pi}"
PI="${PI:-spy2901@100.79.170.67}"
PI_DIR="mmorpg-server"
PROZOR=1; REG=0; DEPLOY=0
UPOTREBA="upotreba: .claude/skills/test-pi/run.sh [--deploy] [--bez-prozora] [--registruj]"
for a in "$@"; do
  case "$a" in
    --deploy) DEPLOY=1;; --bez-prozora) PROZOR=0;; --registruj) REG=1;;
    --bez-deploya) echo "UPOZORENJE: --bez-deploya je suvišna (bez --deploy se ionako ne deployuje)" >&2;;
    *) echo "nepoznata opcija: $a" >&2; echo "$UPOTREBA" >&2; exit 2;;
  esac
done
mkdir -p "$OUT"; rm -rf "$OUT"/*.log "$OUT"/*.png "$OUT"/igrac* "$OUT"/lokalno
pad() { echo "FAIL $*"; echo "REZULTAT: prekinuto ($*)"; exit 1; }

# ---------------------------------------------------------------- 0. .env.test
[ -f .env.test ] || pad "env: .env.test ne postoji"
set -a; . ./.env.test; set +a
for v in TEST_API_URL TEST_GAME_HOST TEST_GAME_PORT TEST_USER_1 TEST_PASS_1 TEST_USER_2 TEST_PASS_2; do
  [ -n "${!v:-}" ] || pad "env: $v nije postavljen u .env.test"
done
for u in "$TEST_USER_1" "$TEST_USER_2"; do
  case "$u" in agent_test*) ;; *) pad "env: TEST_USER_n mora počinjati sa agent_test";; esac
done

if [ $DEPLOY = 0 ]; then
  echo "== 1-2/4 preskočeno (bez --deploy): Pi se ne menja"
  SINCE=$(ssh "$PI" "date -d \"\$(systemctl show -p ActiveEnterTimestamp --value mmorpg-game)\" '+%Y-%m-%d %H:%M:%S'") || pad "ssh"
  echo "   mmorpg-game radi od $SINCE"
else
# ---------------------------------------------------------------- 1. lokalne provere
echo "== 1/4 lokalne provere (run-mmorpg)"
if OUT="$OUT/lokalno" .claude/skills/run-mmorpg/run.sh > "$OUT/lokalno.log" 2>&1; then
  echo "PASS lokalne_provere  $(grep -c '^PASS' "$OUT/lokalno.log") PASS"
else
  grep '^FAIL\|SCRIPT ERROR' "$OUT/lokalno.log"
  pad "lokalne_provere (log: $OUT/lokalno.log)"
fi

# ---------------------------------------------------------------- 2. deploy
echo "== 2/4 deploy na $PI"
"$G" --headless --path . --export-pack "Linux (server)" export/mmorpg-server.pck > "$OUT/export.log" 2>&1 \
  && [ -s export/mmorpg-server.pck ] || pad "deploy: export-pack (log: $OUT/export.log)"
# scp do 3 pokušaja (pauza 3 s); Tailscale ume da izgubi par paketa
scp3() { for i in 1 2 3; do scp -q "$@" && return 0; echo "   scp pokušaj $i/3 neuspešan"; [ $i -lt 3 ] && sleep 3; done; return 1; }
scp3 "$PI:$PI_DIR/mmorpg-server.pck" "$OUT/pi-prethodni.pck" || pad "deploy: ne mogu da preuzmem prethodni .pck (3 pokušaja)"
SINCE=$(ssh "$PI" 'date "+%Y-%m-%d %H:%M:%S"') || pad "deploy: ssh"
scp3 export/mmorpg-server.pck "$PI:$PI_DIR/mmorpg-server.pck" || pad "deploy: scp (3 pokušaja), servis NIJE restartovan"
VEL=$(wc -c < export/mmorpg-server.pck | tr -d ' '); VEL_PI=$(ssh "$PI" "wc -c < $PI_DIR/mmorpg-server.pck")
[ "$VEL" = "$VEL_PI" ] || pad "deploy: veličina .pck na Pi-ju $VEL_PI != lokalno $VEL, servis NIJE restartovan"
ssh "$PI" 'sudo -n systemctl restart mmorpg-game' || pad "deploy: restart"
sleep 3
[ "$(ssh "$PI" 'systemctl is-active mmorpg-game')" = active ] || pad "deploy: servis nije active (rollback: $OUT/pi-prethodni.pck)"
echo "PASS deploy  (prethodni .pck: $OUT/pi-prethodni.pck)"
fi

# ---------------------------------------------------------------- 3. čekanje API-ja i game servera
echo "== 3/4 čekam API i game server"
ok=0; for _ in $(seq 30); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "$TEST_API_URL/items")" = 200 ] && ok=1 && break; sleep 1
done
[ $ok = 1 ] && echo "PASS api_odgovara  $TEST_API_URL" || pad "api_odgovara: $TEST_API_URL/items"
# ENet je UDP (nc ne pomaže): game server je spreman kad journal od restarta kaže da sluša
ok=0; for _ in $(seq 30); do
  ssh "$PI" "journalctl -u mmorpg-game --since '$SINCE' --no-pager" 2>/dev/null | grep -q "Sluša na portu $TEST_GAME_PORT" && ok=1 && break; sleep 1
done
[ $ok = 1 ] && echo "PASS game_server_slusa  $TEST_GAME_HOST:$TEST_GAME_PORT" || pad "game_server_slusa"

# ---------------------------------------------------------------- 3b. fiksna početna pozicija (pre prijave)
python3 .claude/skills/test-pi/reset_stanje.py || pad "reset_stanja"
echo "PASS reset_stanja  (pozicija, HP 60, small_health_potion 3)"

# ---------------------------------------------------------------- 4. dva prava klijenta
echo "== 4/4 dva klijenta protiv Pi-ja"
# ping u pozadini za vreme celog testa klijenata (gubitak paketa baš dok se meri)
ping -i 0.1 -q "${PI#*@}" > "$OUT/ping.log" 2>&1 &
PING_OD=$SECONDS
PING=$!; trap 'kill $PING 2>/dev/null' EXIT # ne ostavljaj ping ako skripta stane ranije
ARG=("dir=$OUT" "host=$TEST_GAME_HOST" "port=$TEST_GAME_PORT" "--server-url=$TEST_API_URL")
[ $REG = 1 ] && ARG+=("registruj=1")
if [ $PROZOR = 1 ]; then
  "$G" --path . --resolution 1280x720 --script $D -- igrac1 "${ARG[@]}" "shot=$OUT/pi_igrac1.png" > "$OUT/igrac1.log" 2>&1 &
else
  "$G" --headless --path . --script $D -- igrac1 "${ARG[@]}" > "$OUT/igrac1.log" 2>&1 &
fi
P1=$!
"$G" --headless --path . --script $D -- igrac2 "${ARG[@]}" > "$OUT/igrac2.log" 2>&1 &
P2=$!
wait $P1 $P2
# najmanje 100 uzoraka (0,1 s): ping radi bar 13 s (stvarno ~8-9 paketa/s, SECONDS je ceo broj)
PREOSTALO=$((13 - (SECONDS - PING_OD))); [ $PREOSTALO -gt 0 ] && sleep $PREOSTALO
kill -INT $PING 2>/dev/null; wait $PING 2>/dev/null
echo "PING za vreme testa: $(grep -h 'packet loss' "$OUT/ping.log" | sed 's/^ *//') | $(grep -h 'round-trip' "$OUT/ping.log" | sed 's/.*= //')"

grep -h '^PASS\|^FAIL\|^WARN \|screenshot' "$OUT"/igrac1.log "$OUT"/igrac2.log
grep -h 'SCRIPT ERROR' "$OUT"/igrac*.log | sort | uniq -c
F=$(grep -h '^FAIL' "$OUT"/igrac*.log | wc -l | tr -d ' ')
# action bar (igrac1 pritisnuo 1 pa 1 u cooldown-u): u bazi 3 -> 2; klijent nema server key, pa proverava run.sh
if [ -f "$OUT/igrac1_bar" ]; then
  if B=$(python3 .claude/skills/test-pi/reset_stanje.py --proveri 2); then echo "PASS baza_posle_action_bara  $B"
  else echo "FAIL baza_posle_action_bara  $B"; F=$((F + 1)); fi
fi
# journal na Pi-ju od restarta (linije sa ključem se ne prikazuju)
ssh "$PI" "journalctl -u mmorpg-game --since '$SINCE' --no-pager" | grep -iv 'key' > "$OUT/pi-journal.log"
if grep -q 'ERROR' "$OUT/pi-journal.log"; then
  echo "FAIL pi_journal_bez_gresaka"; grep -A3 'ERROR' "$OUT/pi-journal.log" | tail -20; F=$((F + 1))
else
  echo "PASS pi_journal_bez_gresaka"
fi
# nijedna lozinka ne sme da završi u logu (sadržaj se ne ispisuje)
if grep -rqF --include="*.log" -e "$TEST_PASS_1" -e "$TEST_PASS_2" "$OUT"; then
  echo "FAIL tajne_van_logova"; F=$((F + 1))
else
  echo "PASS tajne_van_logova"
fi

echo "logovi: $OUT"
W=$(cat "$OUT"/igrac*.log | grep -c '^WARN ')
# Mreža tokom testa (ping u pozadini): previše loša -> run je NEVAŽEĆ (exit 2), ne FAIL
GUBITAK=$(grep -oE '[0-9.]+% packet loss' "$OUT/ping.log" | grep -oE '^[0-9.]+')
RTT=$(grep -h 'round-trip' "$OUT/ping.log" | sed 's/.*= //' | cut -d/ -f2)
UZORAKA=$(grep -oE '^[0-9]+ packets transmitted' "$OUT/ping.log" | grep -oE '^[0-9]+')
# samo ping odlučuje (rupe iz igre ne čine run nevažećim); gubitak se računa tek na >= 100 uzoraka
RAZLOG=""
[ -z "$GUBITAK" ] && RAZLOG="nema ping merenja"
[ -n "$UZORAKA" ] && [ "$UZORAKA" -lt 100 ] && RAZLOG="premalo uzoraka ($UZORAKA < 100)"
[ -n "$GUBITAK" ] && awk "BEGIN{exit !($GUBITAK > 2)}" && RAZLOG="${RAZLOG:+$RAZLOG, }gubitak ${GUBITAK}% > 2%"
[ -n "$RTT" ] && awk "BEGIN{exit !($RTT > 300)}" && RAZLOG="${RAZLOG:+$RAZLOG, }prosečan RTT ${RTT} ms > 300 ms"
if [ -n "$RAZLOG" ]; then
  echo "REZULTAT: NEVAŽEĆ ($RAZLOG; provere: $F FAIL$([ "$W" != 0 ] && echo ", $W WARN"))"
  exit 2
fi
[ "$F" = 0 ] && echo "REZULTAT: sve prošlo$([ "$W" != 0 ] && echo ", $W WARN")" || echo "REZULTAT: $F FAIL$([ "$W" != 0 ] && echo ", $W WARN")"
[ "$F" = 0 ]
