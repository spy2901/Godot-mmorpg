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
   - `WARN igracN:greska_predikcije` kad je najveća greška predikcije > 1 m (`GRESKA_WARN_M`), npr. snap
     pri prijavi kad se izgubi reset; WARN ne obara rezultat.
   Za vreme klijenata ide `ping -i 0.2` (`$OUT/ping.log`). Gubitak > 2% ili prosečan RTT > 300 ms →
   `REZULTAT: NEVAŽEĆ (razlog)` i exit 2 (ne FAIL): mreža je preloša da bi provere kretanja bile merodavne.
   Zatim: `pi_journal_bez_gresaka` (journal od restarta, bez linija sa "key") i `tajne_van_logova`
   (nijedna lozinka u `$OUT/**/*.log`).

## Pravila

- `.env.test` (u `.gitignore`) se učitava samo u env procesa. Lozinke i tokeni nikad ne idu u
  argumente, ispis ni log; drajver čita `TEST_USER_n`/`TEST_PASS_n` preko `OS.get_environment`.
- Samo nalozi sa prefiksom `agent_test` (proverava i `run.sh` i drajver). Ništa se ne briše u bazi;
  test menja samo poziciju agent_test likova (snimanje pri odjavi). Na kraju klijent radi `/auth/logout`.
- Drajver ne zove `GameState.prijavi()` da ne prepiše zapamćeno korisničko ime u `user://settings.cfg`.
- Pi: `spy2901@100.79.170.67` (`PI=` za drugi), servis `mmorpg-game`, backend `mmorpg-api` na :8001.

## Gotchas

- Hostname (`spajko`, Tailscale) se razrešava u drajveru (`IP.resolve_hostname`) pre `pridruzi_se`.
- Prozorski klijent kasni ~8 s; zato se sve čeka preko stanja (fajlovi `igracN_ime`, `igracN_hp`,
  `igrac1_pomeren`, `igracN_gotov`), ne po satu.
- Pozicija likova dolazi iz baze: ako je igrac1 uz zid, `kretanje_server_authority` padne sa malim
  pomerajem (vidi detalj u liniji); ako su likovi > 40 m razmaknuti, nameplate je (ispravno) sakriven.
- Lik koji je već prijavljen negde drugde server izbacuje ("Prijavljen si sa drugog mesta").
