---
name: test-pi
description: Deploy the mmorpg Godot server to the Raspberry Pi and test it end to end with two real clients (agent_test accounts from .env.test, real /auth and real database) — character load, server-authoritative movement, HP/mana, other player's nameplate, screenshot. Use when asked to test on the Pi, deploy and verify, or run /test-pi.
---

# test-pi

Ceo tok je u `run.sh` (bash) i `driver.gd` (SceneTree skripta, kao kod `run-mmorpg`):

```bash
.claude/skills/test-pi/run.sh                 # lokalno -> deploy -> 2 klijenta (igrac1 u prozoru + screenshot)
.claude/skills/test-pi/run.sh --bez-prozora   # isto, bez screenshot-a
.claude/skills/test-pi/run.sh --registruj     # agent_test nalog koji ne postoji registruje preko /auth/register
.claude/skills/test-pi/run.sh --bez-deploya   # deploy je već urađen (npr. pi_010.sh): bez koraka 1-2, Pi se ne restartuje,
                                              # journal od poslednjeg starta mmorpg-game
```

Postavi `OUT=<scratchpad>/pi1` da bi Read alat mogao da otvori `$OUT/pi_igrac1.png`.
Izlaz: `PASS`/`FAIL` linije i `REZULTAT: ...`. Exit 0 = sve prošlo. Na prvi pad koraka 1–3 skripta staje.

## Koraci (`run.sh`)

1. **Lokalno**: `run-mmorpg/run.sh` (log `$OUT/lokalno.log`). Pad = stop, ništa se ne deployuje.
2. **Deploy**: `--export-pack "Linux (server)" export/mmorpg-server.pck`, prethodni `.pck` sa Pi-ja
   se čuva u `$OUT/pi-prethodni.pck` (rollback), scp, **jedan** `sudo systemctl restart mmorpg-game`,
   `is-active`. Pad = stop, testovi se ne pokreću.
3. **Čekanje**: API (`$TEST_API_URL/items` = 200) i game server (journal od restarta sadrži
   "Sluša na portu"; ENet je UDP pa `nc` ne pomaže).
4. **Klijenti** `igrac1` (prozor) i `igrac2` (headless), uloge se usklađuju preko fajlova u `$OUT`.
   Provere po klijentu (`igracN:ime`):
   - `prijava`: pravi `/auth/login` (uz `--registruj`: register ako nalog ne postoji).
   - `konekcija`: ENet na `TEST_GAME_HOST:TEST_GAME_PORT`.
   - `lik_ucitan_iz_baze`: server preko tokena učita lik iz baze i pošalje `primi_lik` (HUD `_ucitano`).
   - `hp_mana`: vrednosti u opsegu, lik živ.
   - `nameplate_drugog`: tuđi lik ima `Nameplate`, `ime_sync` = njegovo ime, `hp_sync` = HP iz
     njegovog HUD-a (oba stižu od servera, kroz različite kanale); sopstveni lik nema nameplate.
   - `kretanje_server_authority` (igrac1): 1 s W → server pomeren ~5 m, predikcija = server posle stajanja.
     Meri se kad server potvrdi poslednji unos sa W (prazan/noviji prediction buffer), ne posle fiksnog vremena.
   - `drugi_vidi_kretanje` (igrac2): tuđi lik se pomerio koliko je server javio.
   - screenshot `$OUT/pi_igrac1.png`: igrac1 se okrene ka drugom igraču pa snimi.
   - action bar (igrac1, odmah posle učitavanja): `action_bar_napitak` (taster 1 = small_health_potion: HP 88-100,
     slot pokazuje 2) i `action_bar_cooldown` (drugi pritisak čim server potvrdi prvi: "Not ready yet", overlay
     sa sekundama). Screenshot-ovi `$OUT/pi_igrac1_bar.png` (popunjen bar) i `$OUT/pi_igrac1_cooldown.png`.
     Posle klijenata `run.sh`: `baza_posle_action_bara` (small_health_potion u bazi 3 -> 2, `reset_stanje.py --proveri 2`).
   - `statistike_na_pravom_serveru` (oba igrača, samo čitanje, bez opremanja): server posle učitavanja pošalje
     statistike; agent_test likovi nemaju opremu, pa je attack = osnovni napad iz baze, armor 0, max HP = HUD, a
     sažetak u inventaru "Attack: … Armor: … Max HP: …". igrac1 snimi `$OUT/pi_igrac1_inventar.png` (inventar
     otvoren pa zatvoren).
   - `napredak_na_pravom_serveru` (oba igrača, samo čitanje): nivo L iz baze i statistike po odobrenoj krivi
     (migracija 008): max_xp 25·L²+75·L (0 i traka "XP: MAX  |  Lv.20" na nivou 20), max HP 100+15·(L−1) (bez
     opreme), max mana 100+10·(L−1), osnovni napad 10+2·(L−1) = attack sa servera. Pre migracije 008 na Pi-ju pada
     (napad 250).
   - `cilj_na_pravom_serveru` (igrac1 u prozoru, posle screenshot-a): okrene se ka najbližem živom neprijatelju bližem
     od 25 m, levi klik na njega → server potvrdi cilj, okvir pokazuje HP = replicirani hp; screenshot
     `$OUT/pi_igrac1_cilj.png`; Esc skida cilj.
   - `traka_pretnje_sakrivena_na_pravom_serveru` (isti cilj, screenshot `_cilj`): bez pretnje nema ni procenta sa
     servera ni žute trake. `neprijatelj_miruje_na_pocetku`: taj neprijatelj je < 1 m od svoje spawn tačke, ne pomeri
     se dok se lik okreće i klikće (~2 s), a svi likovi su van njegovog aggro_range (MIROVANJE, bez aggro-a na
     test likove).
   - `napad_predaleko_na_pravom_serveru` (pre Esc-a): tačno jedan napad (R) na izabran cilj van dometa napada (cilj
     mora biti dalje od 5.5 m, inače se R ne pritiska i provera pada): server odgovori "Too far", HP cilja
     nepromenjen; screenshot `$OUT/pi_igrac1_napad.png`. Test ne ubija neprijatelje (XP i loot test naloga su u
     pravoj bazi).
   - `WARN igracN:greska_predikcije` kad je najveća greška predikcije > 1 m (`GRESKA_WARN_M`), npr. snap
     pri prijavi kad se izgubi reset; WARN ne obara rezultat.
   Za vreme klijenata ide `ping -i 0.1` (`$OUT/ping.log`), najmanje ~100 uzoraka (posle klijenata radi do 13 s;
   < 100 uzoraka = nevažeće). Gubitak > 2% ili prosečan RTT > 300 ms (samo ping, ne rupe iz igre) →
   `REZULTAT: NEVAŽEĆ (razlog)` i exit 2 (ne FAIL): mreža je preloša da bi provere kretanja bile merodavne.
   Zatim: `pi_journal_bez_gresaka` (journal od restarta, bez linija sa "key") i `tajne_van_logova`
   (nijedna lozinka u `$OUT/**/*.log`).

## Pravila

- `.env.test` (u `.gitignore`) se učitava samo u env procesa. Lozinke i tokeni nikad ne idu u
  argumente, ispis ni log; drajver čita `TEST_USER_n`/`TEST_PASS_n` preko `OS.get_environment`.
- Samo nalozi sa prefiksom `agent_test` (proverava i `run.sh` i drajver). Ništa se ne briše u bazi.
  `reset_stanje.py` na početku svakog pokretanja postavlja agent_test likove: fiksna pozicija, HP 60 i tačno 3
  `small_health_potion` (`POST /players/{ime}/inventory/change`); ostale predmete ne dira (samo upozorenje), equipment
  ne dira. Test menja još poziciju (snimanje pri odjavi) i troši jedan napitak (action bar). Na kraju klijent radi `/auth/logout`.
- Drajver ne zove `GameState.prijavi()` da ne prepiše zapamćeno korisničko ime u `user://settings.cfg`.
- Pi: `spy2901@100.79.170.67` (`PI=` za drugi), servis `mmorpg-game`, backend `mmorpg-api` na :8001.

## Gotchas

- **Klijent i server se deploy-uju zajedno.** Paket unosa je kompaktno kodiran (`PackedByteArray`: 13 B zaglavlje
  + 6 B po unosu, do 32 nepotvrđena unosa, `Player_Movement._kodiraj/_dekodiraj`). Server odbacuje stari format
  (Array) kao neispravan paket, a stari server ne razume novi: klijent starije verzije se poveže, ali se lik ne
  pomera. Svaka promena formata = novi build i za server (Pi) i za sve klijente u isto vreme.

- Hostname (`spajko`, Tailscale) se razrešava u drajveru (`IP.resolve_hostname`) pre `pridruzi_se`.
- Prozorski klijent kasni ~8 s; zato se sve čeka preko stanja (fajlovi `igracN_ime`, `igracN_hp`,
  `igrac1_pomeren`, `igracN_gotov`), ne po satu.
- Pozicija likova dolazi iz baze: ako je igrac1 uz zid, `kretanje_server_authority` padne sa malim
  pomerajem (vidi detalj u liniji); ako su likovi > 40 m razmaknuti, nameplate je (ispravno) sakriven.
- Lik koji je već prijavljen negde drugde server izbacuje ("Prijavljen si sa drugog mesta").
