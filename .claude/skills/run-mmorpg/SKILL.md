---
name: run-mmorpg
description: Run, start, launch, drive, test or screenshot the mmorpg Godot game (dedicated server + clients over ENet) — verifies server-authoritative player movement end to end without the backend. Use when asked to run the game, check multiplayer/movement changes, or take a screenshot of the game.
---

# run-mmorpg

Godot 4.6 multiplayer igra (macOS, `/Applications/Godot.app`). Agent je pokreće preko
`run.sh`, koji podiže **3 Godot procesa** sa istim drajverom `driver.gd` (SceneTree skripta):
`server` (headless, hostuje port 7777), `observer` (headless klijent) i `mover` (klijent koji
se kreće, headless ili u prozoru sa screenshot-om). Drajver sam proverava rezultate i ispisuje
`PASS`/`FAIL`. Putanje su relativne u odnosu na koren repoa.

## Preduslovi

- Godot 4.6.3 na `/Applications/Godot.app/Contents/MacOS/Godot` (drugi binarni: `GODOT=/putanja`).
- Backend (MAMP, `localhost:8000`) **nije potreban** za ovaj tok. Vidi Gotchas.

## Pokretanje (agent)

```bash
.claude/skills/run-mmorpg/run.sh            # sve headless, ~20 s
.claude/skills/run-mmorpg/run.sh --window   # mover u prozoru 1280x720 + $OUT/mover.png, ~30 s
```

Izlaz: putanja do logova, 15 linija `PASS`/`FAIL` i linija `[M] korekcije ...` (broj glatkih/snap korekcija, prosečna/max greška predikcije). Exit 0 = svih 15 prošlo. Logovi su u
`$OUT` (podrazumevano `$TMPDIR/run-mmorpg`): `server.log`, `observer.log`, `mover.log`,
`mover.png`. Postavi `OUT=<scratchpad>/run1`: Read alat ne sme da čita `$TMPDIR` van radnih
direktorijuma (`blockReadsOutsideWorkingDirectories`), pa screenshot iz podrazumevane putanje ne možeš da pogledaš.

Šta mover radi (vreme od pojave sopstvenog lika): 4–6 s drži W (yaw = PI, ka +z); 7–8 s yaw = PI/2 + W;
8–12 s miruje, a observer za to vreme šalje `posalji_unos` za **tuđi** lik; 12.5 s šalje NaN/INF
unos; od 14 s drži W, a 15–18 s prestaje da šalje unos. Provere:
`na_podu`, `W_2s_napred` (~+10 z), `yaw_PI/2_ide_-x` (~-5 x), `tudji_unos_ignorisan`,
`NaN_odbacen`, `istek_unosa_0.5s` (server ne pomera lik bez unosa: ~0.1–0.3 posle prekida, zatim 0), `observer_vidi_yaw`.

Deo B (predikcija + reconciliation), nastavak iste vremenske ose:
- 18.5–20.5 s hod ka +x → `mirno_0_korekcija` (0 korekcija, razlika klijent/server < 0.05 m posle zaustavljanja).
- 22 s mover upiše fazu `teleport` u `$OUT/faza`; server ga pomeri +3 x **bez** reset-a → `teleport_snap`.
- 24–27 s `test_ubrzanje = 3` (3 unosa po tick-u) → `speedhack_max_1.2x` (server ~1.2x, token bucket).
- 27.5–33 s `test_gubitak = 0.3` (klijent odbacuje 30% paketa u oba smera), hod 28–30 s →
  `gubitak_30%_konvergira`.
- observer: `observer_korak_max_2x` (korak tuđeg lika po frame-u ≤ brzina·dt·2; snap > PRAG_SNAP se broji posebno).
- server: `seq_bez_rupa_bez_gubitka` (rupe u seq obradi po fazi; u fazama bez gubitka mora 0. U fazi
  gubitka rupa ima kad se izgube 3 uzastopna paketa (~0.3³ ≈ 2.7% tick-ova), u speed-hack-u su to odbijeni unosi).

Faze se usklađuju preko fajla `$OUT/faza` ("ime peer_id"), koji mover piše, a server čita (`dir=` argument).
Pozicije u proverama su `server_poz` (poslednje stanje koje je server poslao), a ne predviđena lokalna.

Posle toga mover ispiše `CEKAM_GASENJE`, a `run.sh` napravi `$OUT/ugasi_server`. Server
(`stop=` argument) to vidi i sam se ugasi (`quit()`, da ENet odmah pošalje disconnect; `kill`
bi čekao ENet timeout). Klijenti su još živi. Provere: `server_prekid_vraca_na_login` (MainMenu
sa porukom "Veza sa serverom je prekinuta", token obrisan) i `nema_greske_neaktivnog_peera`
(`run.sh` grep-uje mover/observer log za "isn't currently active" i "No multiplayer peer is
assigned").

Za novu proveru dodaj fazu i `_provera(...)` u `_mover`/`_observer` u `driver.gd`. Za poziciju
koju zna server koristi `p.server_poz`; `p.global_position` vlasnika je predviđena.

Brza provera da se skripte kompajliraju (sa autoload-ovima): pokreni `run.sh`. Greška u
skripti se vidi kao `SCRIPT ERROR` u izlazu.

## Pokretanje (čovek)

Otvori projekat u Godot editoru i pokreni ga (F5): MainMenu → login (traži backend) →
MultiplayerTest → Hostuj/Pridruži se. Dedicated server je export sa feature tagom
`dedicated_server` (auto-host). Agent ovo ne koristi.

## Gotchas

- **Login traži backend.** `MultiplayerTest` bez `GameState.token` vraća na login. Drajver
  postavlja lažni token `"x"`. Pošto `GameState.korisnicko_ime` ostaje prazno, `TopBar` ne
  zove `posalji_lik_serveru`, pa server ne proverava token i ne izbacuje klijenta. Posledica:
  HP/inventar/oprema se ne učitavaju, a `server_primi_damage` se ignoriše (`_stanje_ucitano`
  je false). Za te sisteme treba upaljen MAMP backend i pravi login.
- **Autoload-ovi nisu u stablu u `_initialize()`** SceneTree skripte (`Node not found:
  "/root/GameState"`). Drajver čeka prvi `_process`.
- **`godot --check-only --script X.gd`** pada sa `Identifier not found: ApiManager` jer ne učitava
  autoload-ove. To nije prava greška.
- **Prozorski klijent kasni ~8 s** (Metal/shaderi). Zato se uloge ne usklađuju po satu:
  server se gasi kad svi peer-ovi odu, observer kreće posle yaw faze movera, a mover meri
  vreme od pojave svog lika.
- **Snimanje screenshot-a koči frame** (GPU readback). Ako se snima usred W faze, faza
  traje kraće u stvarnom vremenu i `W_2s_napred` pada (-8 umesto -10). Snima se u mirovanju.
- **Headless ne može screenshot** (dummy renderer). Za sliku koristi `--window`.
- **NPC stoji na (0, 2.7, -10)** (crna kapsula na screenshot-u) i blokira kretanje ka -z, pa se lik zaglavi zavisno od nasumičnog x spawna. Zato prva W faza ide ka +z.
- **Spawn je nasumičan** (±2 oko (0,1,0)), pa lik ponekad zakači prepreku. Tolerancije
  bočnog pomeranja su 1.5.
- **`has_multiplayer_peer()` ne štiti od zatvorenog peer-a.** Vraća false samo za `null` peer;
  za zatvoren a još postavljen ENet peer vraća true, a `is_server()` /
  `is_multiplayer_authority()` tada bacaju "isn't currently active". Zato
  `NetworkManager._on_server_disconnected` odmah radi `prekini()` (peer = null), a guard u
  `Player_Movement._process/_physics_process` pokriva frame do promene scene. Bez handlera
  `nema_greske_neaktivnog_peera` pada (~12 linija); proveravano isključivanjem `connect`-a.
- `timeout` ne postoji na macOS-u, a `gdtoolkit`/`gdparse` se ne instalira preko pip-a u
  sandbox-u (`platform.mac_ver()` vraća prazno → `ValueError` u pip truststore-u).

- **SceneTree `_process` drajvera ide pre `_process` čvorova.** Korak tuđeg lika izmeren u frame-u N
  napravljen je sa delta-om frame-a N-1; observer zato poredi sa prethodnim `d`.
- **Server obrađuje unose kako stignu** (više u jednom tick-u posle rafala), pa bi interpolacija
  tuđeg lika pokazala >2x brzinu; `_postavi` ograničava prikaz na 2x brzinu hoda.

## Troubleshooting

| Simptom | Uzrok / rešenje |
|---|---|
| U prozorskom modu samo `observer_vidi_yaw`, mover nema PASS linije | Server se ugasio pre kraja movera (stara verzija sa fiksnim vremenom). Server mora da čeka dok peer-ovi ne odu. |
| `FAIL yaw_PI/2_ide_-x delta=(-0.78, 0, 0)` i `istek ... posle prekida 0.00` | Lik je udario u NPC na (0, _, -10). Putanja mora da ga zaobiđe (prva faza ide ka +z). |
| `FAIL W_2s_napred delta=(0, 0, -8)` | Screenshot ili drugi zastoj u W fazi; pomeri snimanje u fazu mirovanja. |
| `PASS nema_greske_neaktivnog_peera`, ali samo 1–2 linije ukupno i exit 1 | Drajver nije ni krenuo (npr. `SCRIPT ERROR: Parse Error` u driver.gd); grep greške je prazan jer nema logova. Gledaj `SCRIPT ERROR` linije. |
| `SCRIPT ERROR: Invalid assignment ... 'token' ... 'null instance'` | Autoload se koristi u `_initialize`; premesti u `_process`. |
