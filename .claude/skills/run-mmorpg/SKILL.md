---
name: run-mmorpg
description: Run, start, launch, drive, test or screenshot the mmorpg Godot game (dedicated server + clients over ENet) — verifies server-authoritative player movement end to end without the backend. Use when asked to run the game, check multiplayer/movement changes, or take a screenshot of the game.
---

# run-mmorpg

Godot 4.6 multiplayer igra (macOS, `/Applications/Godot.app`). Agent je pokreće preko
`run.sh`, koji podiže lažni backend `stub_api.py` (Python stdlib, port `STUB_PORT`=18765) i
**4 Godot procesa** sa istim drajverom `driver.gd` (SceneTree skripta):
`server` (headless, hostuje port 7777, `--server-url` → stub), `observer` (headless klijent),
`mover` (klijent koji se kreće, headless ili u prozoru sa screenshot-om) i `potion` (headless klijent
prijavljen kao `TestLik` preko stub-a, testira napitke). Drajver sam proverava rezultate i ispisuje
`PASS`/`FAIL`. Putanje su relativne u odnosu na koren repoa.

## Preduslovi

- Godot 4.6.3 na `/Applications/Godot.app/Contents/MacOS/Godot` (drugi binarni: `GODOT=/putanja`).
- Backend (MAMP, `localhost:8000`) **nije potreban** za ovaj tok. Vidi Gotchas.

## Pokretanje (agent)

```bash
.claude/skills/run-mmorpg/run.sh            # sve headless, ~20 s
.claude/skills/run-mmorpg/run.sh --window   # observer u prozoru 1280x720 + $OUT/nameplate_{zeleno,zuto,crveno,mrtav}.png
```

Izlaz: putanja do logova, 87 linija `PASS`/`FAIL` i linija `[M] korekcije ...` (broj glatkih/snap korekcija, prosečna/max greška predikcije). Exit 0 = svih 87 prošlo (WARN se računa kao prošao). `run.sh` pokreće movera i potion klijenta tek kad observer ispiše
`OBSERVER_SPREMAN` (prozorski observer kasni ~8 s, a mora da vidi movera od početka). Logovi su u
`$OUT` (podrazumevano `$TMPDIR/run-mmorpg`): `server.log`, `observer.log`, `mover.log`,
`potion.log`, `raspored1.log`, `raspored2.log`, `cilj.log`, `drugi.log`, `ai1.log`, `ai2.log`, `stub.log`, `nameplate_*.png`. Postavi `OUT=<scratchpad>/run1`: Read alat ne sme da čita `$TMPDIR` van radnih
direktorijuma (`blockReadsOutsideWorkingDirectories`), pa screenshot iz podrazumevane putanje ne možeš da pogledaš.

Šta mover radi (vreme od pojave sopstvenog lika): 4–6 s drži W (yaw = PI, ka +z); 7–8 s yaw = PI/2 + W;
8–12 s miruje, a observer za to vreme šalje `posalji_unos` za **tuđi** lik; 12.5 s šalje NaN/INF
unos; od 14 s drži W, a 15–18 s prestaje da šalje unos. Provere:
`na_podu`, `W_2s_napred` (~+10 z), `yaw_PI/2_ide_-x` (~-5 x), `tudji_unos_ignorisan`,
`neispravan_paket_odbacen` (prekratak paket, pogrešna dužina, stari format sa NaN), `istek_unosa_0.5s` (server ne pomera lik bez unosa: ~0.1–0.3 posle prekida, zatim 0), `observer_vidi_yaw`.

Deo B (predikcija + reconciliation), nastavak iste vremenske ose:
- 18.5–20.5 s hod ka +x → `mirno_0_korekcija` (0 korekcija, razlika klijent/server < 0.05 m posle zaustavljanja).
- 22 s mover upiše fazu `teleport` u `$OUT/faza`; server ga pomeri +3 x **bez** reset-a → `teleport_snap`.
- 24–27 s `test_ubrzanje = 3` (3 unosa po tick-u) → `speedhack_max_1.2x` (server ~1.2x, token bucket).
- 27.5–33 s `test_gubitak = 0.3` (klijent odbacuje 30% paketa u oba smera), hod 28–30 s →
  `gubitak_30%_konvergira`.
- observer: `observer_korak_max_2x` (korak tuđeg lika po frame-u ≤ brzina·dt·2; snap > PRAG_SNAP se broji posebno).
- server: `seq_bez_rupa_bez_gubitka` (rupe u seq obradi po fazi; u fazama bez gubitka mora 0. U fazi
  gubitka rupa ima kad se izgube 3 uzastopna paketa (~0.3³ ≈ 2.7% tick-ova), u speed-hack-u su to odbijeni unosi).
  Rupa se vodi po liku (peer-u) sa vremenom kad je server primeti. WARN "neodlučno (zastoj klijenta)" samo ako
  je proces koji šalje inpute za TAJ lik imao frame > `ZASTOJ_PRAG` (100 ms) u prozoru ±`ZASTOJ_PROZOR` (0.5 s);
  zastoji se mere tek kad mover upiše fazu, bez prve sekunde faze (`ZASTOJ_WARMUP`), u `$OUT/zastoj_<peer>`.
  Rupa bez zastoja = FAIL. Napomena: Godot seče frame delta na `max_physics_steps_per_frame` (8 tick-ova =
  133 ms), pa zastoj klijenta nadoknadi najviše 8 unosa, što token bucket (10) propusti: rupe od zastoja su
  retke, a rupa bez zastoja je pravi nalaz. Ako je seq FAIL jedini FAIL, `run.sh` ponovi ceo krug jednom.

Napitci (`potion` klijent, provere preko stanja: HUD hp, `prebroj_item`, količina u stub "bazi"):
`potion_lik_ucitan`, `napitak_leci` (+30, količina -1 u bazi i UI-ju, poruka "+30 HP"),
`napitak_clamp_max` (+150 na 80/100 → 100), `pun_hp_odbija` ("Already at full health", ne troši),
`cooldown_odbija` ("Not ready yet"), `nema_predmet_odbija`, `nepotrosni_odbija` (mač),
`dva_istovremena_jedan_komad` (2 direktna RPC-a → 1 ok, backend trošio 1×), `mrtav_ne_moze`.
Štetu i smrt zadaje server drajver na komandu iz `$OUT/potion_cmd` ("br steta N" / "br ubij").
HP se regeneriše +2/s, pa se efekat proverava kao razlika uz toleranciju.

Action bar (`Scenes/UI/ActionBar.tscn`, potion klijent, tasteri preko `Input.parse_input_event`): raspored drži server
(`primi_action_bar`; TestLik nema sačuvan raspored, pa ga server popuni iz inventara), količina i cooldown iz
`primi_predmet`. Slot 1 = small HP, 2 = large, 3 = medium, 4 = apple, 10 prazan.
`action_slot_koristi_napitak` (taster 1: +30, baza -1), `action_cooldown_odbija` ("Not ready yet", overlay sa
sekundama), `action_prazan_slot_nista` (taster 0: nijedan zahtev), `action_kolicina_iz_servera` (slot 1 = baza,
slot 2 = 0 jer je large potrošen mimo bara). Sve 4 padaju bez implementacije (provereno).

Raspored action bara po liku (uloga `raspored`, lik `RasporedLik`: small x2, mač, apple x1, mana x1, bez sačuvanog
rasporeda). Dva procesa jedan za drugim (`korak=1`, pa `korak=2` = ponovna prijava); server se gasi tek kad oba završe.
Korak 1: `pocetni_raspored_upisan` (small, apple, mana u bar i u stub bazu), mana premeštena u slot 7
(`promeni_action_slot`), `nevazeci_slot_item_odbijen` (slot 0, slot 11, nepostojeći item: server odgovori rasporedom,
baza i bar nepromenjeni), apple potrošen, kupljen medium → `novi_predmet_prvi_prazan` (slot 3, ispražnjen
premeštanjem, ne 4). Korak 2: `raspored_prezivi_prijavu` (isti raspored iz baze) i `potroseni_ne_pomera_slotove`
(apple u slotu 2 sa 0, mana u 7). Svih 5 pada bez implementacije (provereno: stari bar posle prijave pomeri manu u slot 2).
Stub: `POST /players/{ime}/action_bar` (10 slotova, predmeti postoje) i `POST /players/{ime}/shop/buy` (samo doda komad).

Ciljanje (uloga `cilj`, lik `CiljLik` na (-20, 1.16, -20), okrenut ka +z; prozor drajvera 1280x720 jer je headless
64x64 i action bar bi pokrio ceo ekran). Test neprijatelje (`goblin_9xx`, max_hp 50) pravi i menja server drajver po
komandama iz `$OUT/cilj_cmd` (spawn, pomeri, steta, mrtav = `_mrtav` bez despawn-a, ubij) i upisuje cilj CiljLik-a po
serveru u `$OUT/cilj_server`. Klik = `InputEventMouseButton` na `kamera.unproject_position` neprijatelja.
`cilj_klik_bira` (klijent + server + okvir "Goblin  Lv.1" + prsten), `okvir_prati_hp` (šteta 20 → "30 / 50" = server),
`cilj_van_dometa_odbijen` (35 m), `cilj_nepostojeci_i_mrtav_odbijen`, `klik_preko_ui_ne_menja` (klik na action bar),
`klik_na_prazno_brise` (pod), `esc_brise_cilj`, `udaljavanje_brise_cilj` (31 m ostaje = histereza, 33 m skida),
`smrt_cilja_brise`; observer: `drugi_ne_vidi_cilj` (dok server drži cilj CiljLik-a, kod observera nema ni
`cilj_id`, ni okvira, ni prstena). Svih 10 pada bez implementacije (provereno).
`esc_zatvara_prozor_ne_cilj` (otvoren dijalog pa trgovac: Esc zatvara samo prozor, cilj ostaje; padao pre popravke).

Napad (taster **R**; desni klik drži kameru, F je `interact`). Klijent šalje samo `zatrazi_napad` bez mete; server napada
svoj `_cilj_srv` i odgovara `odgovor_napad` (signal `napad_odgovor`, HUD poruka). Provere (CiljLik, goblin_904 na
~2.7 m i goblin_905 na ~2.5 m, oba u dometu 3.5 m): `napad_bez_cilja` ("No target"), `klik_bira_ne_steti`,
`klik_preko_ui_ne_napada` (klik na action bar: ni odgovor ni šteta), `napad_samo_cilj` (904 -25, 905 netaknut),
`napad_cooldown` ("Not ready yet"), `napad_predaleko` (904 na ~6 m), `smrt_cilja_pa_nema_cilja`, `mrtav_ne_napada`
(server komanda `ubij_lik CiljLik`; R i klik → "You are dead"). Uloga `drugi` (`DrugiLik` na (-15, 1.16, -16), token
`drugi-token`): kad CiljLik upiše `drugi_kreni`, klik u nebo + R → `drugi_ne_napada_tudji_cilj` ("No target", HP
tuđeg cilja nepromenjen), pa upiše `drugi_gotov`. Svih 8 novih pada bez implementacije (provereno).

AI neprijatelja (`Enemy.gd`: stanja MIROVANJE/JURENJE/POVRATAK, tabela pretnje, leash; prelazi u logu kao `[AI]`).
Scenario vodi server drajver (`_ai_scenario`) nad test goblinom `goblin_950` na (20, 20) (meta `ai_test`, aggro 5 m,
brzina 2); likove pomera `server_postavi_poziciju`, štetu zadaje `primi_damage(n, peer_id)`. Klijenti uloge `ai`
(`korak=1` AiLik (14, 22), `korak=2` Ai2Lik (24, 14), HP 1000) slušaju `$OUT/ai_cmd_<ime>` (`cilj <id>|-`, `kraj` =
odjava) i svaki frame upisuju `$OUT/ai_klijent_<ime>` (cilj|pretnja|ja_meta|okvir|traka|vrednost). Kraj: server
upiše `$OUT/ai_gotov` (`run.sh` čeka i to pre gašenja). Provere: `ai_mirovanje_ne_napada`,
`ai_jurenje_u_dometu_napada`, `ai_steta_pretnja_1_1`, `ai_posmatrac_ne_vidi_pretnju`, `ai_meta_tek_preko_110` (23 vs
21 ostaje, 24 menja), `ai_traka_pretnje_sa_servera` (100/110, pa 88/100), `ai_traka_pretnje_sakrivena`,
`ai_smrt_brise_pretnju` (Ai2Lik umre i odmah se odjavi, pre respawn-a na spawn-u), `ai_leash_povratak_ne_napada`,
`ai_povratak_ne_jurenje`, `ai_povratak_stize_regen`, `ai_napadnut_van_dometa_jurenje`, `ai_respawn_mirovanje`
(sopstvena spawn tačka (20, -20): test server ne pali tačke scene), `ai_odjava_brise_pretnju`. Svih 14 pada bez
implementacije (provereno).

Nameplate (observer gleda TestLik-a; server upisuje njegov "hp max mrtav" u `$OUT/server_hp`):
`nameplate_sync_poklapa` (hp_sync/max_hp_sync/mrtav_sync/ime_sync = server), `hp_sync_prati_stetu`
(kašnjenje od serverske štete do hp_sync, ≤ 250 ms), `nameplate_samo_tudji` (tuđi lik ima vidljiv
`Nameplate`, sopstveni ga nema), `mrtav_sync_i_respawn` (traka sakrivena + sivo ime, pa nazad),
`nameplate_boje` (zelena/žuta/crvena po HP-u, mrtav), server: `nameplate_nema_na_serveru`.
Potion klijent posle testa napitaka vodi TestLik-a kroz 100 → 40 → ~15 HP → smrt → respawn i za svako
stanje upiše kategoriju u `$OUT/snimi`; observer snima kad vidi to stanje (+10 frame-ova za render) i
upiše `$OUT/snimljeno_<kat>` (headless: samo marker, bez slike).

Stub (`stub_api.py`): `/auth/verify` (token `potion-token` → `TestLik`), `GET /players/{ime}`,
`GET /items/{id}`, `/quests/completed/{ime}`, `POST /players/{ime}/save` (samo hp/mana/pozicija;
inventar je autoritativan u stub-u), `POST /players/{ime}/item/use` (kašnjenje 0.3 s da se zahtevi
preklope; brojač `item_use_br`). Nepoznate rute: 404 i linija u `$OUT/stub.log`. TestLik ima sačuvanu
poziciju (9, 1, -7): van putanje movera i van aggro dometa neprijatelja (na spawn-u bi blokirao movera).
Mover i observer i dalje rade bez prijave (lažni token "x").

Red unosa (server, `UNOS_RED_MAX`): `rafal_bez_rupa` (mover 34.0–34.4 s ne šalje, pa pošalje ~24 unosa
odjednom; 0 rupa, zaostatak ispražnjen ≤ 2.5 s, tipično ~1.2 s), `red_pun_odbacuje` (speed-hack napuni red,
višak se odbacuje i broji), `reset_paket_izgubljen` + `reset_bez_rupa` (38.5–40.5 s: hook kasni pakete
1 tick i izgubi onaj na putu kad server pošalje reset; klijent šalje iz zasebne istorije, pa 0 rupa).
Debug: `MMORPG_DEBUG_SEQ=1` u env-u servera/klijenta → `[SEQ]` (rupe, RED, PAUZA), `[SEQ-K]`, `[SEQ-P]`;
`analiza_rafala.py server.log` računa rafale i zaostatak; `repro_login.sh [N] [--opterecenje] [--aktivnost]`.

Reset (spawn, učitavanje iz baze, respawn) nosi `reset_id`; server ga šalje u svakom stanju dok ne stigne
unos sa tim id-om, a klijent duplikate ignoriše. `reset_prijave_bez_snapa` (potion: hook odbaci reset
posle prijave → 0 snap-ova, greška < 1 m) i `zakasneli_reset_ignorisan` (mover 40.6–41.6 s hoda, pa se
ubaci zakasneli duplikat reset-a → bez pomeraja i bez korekcije). `repro_login.sh --izgubi-reset` isto
za kratke prijave. Oba testa padaju bez odgovarajuće popravke (provereno).

Pokretanje procesa (`pokreni` u `run.sh`): klijenti se pokreću uz razmak (čeka se `[CONFIG]` + 0.3 s). Ako
proces izađe pre prve linije našeg koda (`[CONFIG]`; npr. Godot pad u `RotatedFileLogger` pri istovremenom
startu), pokreće se još jednom i ispisuje `RESTART <uloga>` (i u `$OUT/restart.txt`).

Faze se usklađuju preko fajla `$OUT/faza` ("ime peer_id"), koji mover piše, a server i observer čitaju
(`dir=` argument). Observer po tom peer_id-u zna koji lik je mover (u svetu su 3 tuđa lika).
Pozicije u proverama su `server_poz` (poslednje stanje koje je server poslao), a ne predviđena lokalna.

Posle toga mover ispiše `CEKAM_GASENJE`, a `run.sh` napravi `$OUT/ugasi_server`. Server
(`stop=` argument) to vidi i sam se ugasi (`quit()`, da ENet odmah pošalje disconnect; `kill`
bi čekao ENet timeout). Klijenti su još živi. Provere: `server_prekid_vraca_na_login` (MainMenu
sa porukom "Lost connection to the server", token obrisan) i `nema_greske_neaktivnog_peera`
(`run.sh` grep-uje mover/observer log za "isn't currently active" i "No multiplayer peer is
assigned").

Za novu proveru dodaj fazu i `_provera(...)` u `_mover`/`_observer` u `driver.gd`. Za poziciju
koju zna server koristi `p.server_poz`; `p.global_position` vlasnika je predviđena.

Brza provera da se skripte kompajliraju (sa autoload-ovima): pokreni `run.sh`. Greška u
skripti se vidi kao `SCRIPT ERROR` u izlazu.

Tekstovi (`proveri_tekstove.py`, bez Godot-a, `run.sh` ga pokreće na kraju; log `$OUT/tekstovi.log`). Svi tekstovi koje
igrač vidi idu kroz `tr()` iz `translations/teksti.csv` (`keys,en,sr`, ključ = engleski tekst, podrazumevani jezik en u
`GameState.JEZIK`); server šalje engleske ključeve, klijent ih prevodi pri prikazu. `run.sh` na početku radi
`--import` (CSV -> `.translation`, ne idu u git). `backend_poruke_u_csv`: svaka poruka greške iz `~/mmorpg-server`
(`BACKEND_DIR`) osim internih (`INTERNE` u skripti) ima red u CSV-u, ključ tačno kao backend. `bez_srpskog_u_prikazu`:
stringovi u `Scripts/*.gd` (bez komentara, print/push_error/_dbg_seq i `[DEBUG]` prefiksa; jedna reč malim slovom se
preskače) i tekstovi u `.tscn` bez č ć š ž đ i tipičnih srpskih reči. Na starom kodu (main pre prevoda) nalazi 75
stringova; bez reda `Inventory pun` u CSV-u pada i prva.

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
- **Snimanje screenshot-a koči frame** (GPU readback). Zato prozor ima observer (ne mover): zastoj
  u moveru bi skratio W fazu i `W_2s_napred` bi pao (-8 umesto -10).
- **Headless ne može screenshot** (dummy renderer). Za sliku koristi `--window`.
- **Neprijatelji ne jure test likove**: server drajver svakom neprijatelju (grupa `neprijatelj`, osim mete `ai_test`)
  postavlja `aggro_range = 0`, `brzina = 0` i `moze_napasti = false` (neprijatelj koga igrač udari ulazi u JURENJE
  po pretnji, pa samo aggro 0 nije dovoljan). Test server ne pali spawn tačke scene (`hostuj()` bez
  `pokreni_spawn_tacke`), pa sveta neprijatelja nema; postoje samo oni koje drajver napravi. Borba nad igračima se
  testira komandama servera (`potion_cmd`, `cilj_cmd`).
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

- **Server objavljuje lika ostalim klijentima tek posle učitavanja iz baze** (`public_visibility` sinhronizatora,
  važi i za spawn); do tada ga vidi samo vlasnik. Zato mover i observer imaju stub naloge (`MoverLik`,
  `ObserverLik`; MoverLik bez pozicije (0,0,0), ObserverLik na (11, 1.16, 4) van putanje movera; veliki HP): klijent bez učitavanja (token `"x"`) ostaje nevidljiv drugima.
- **Pomoćni likovi stoje van putanje movera** (x -9..6, z -12..16), bar 5 m jedan od drugog: TestLik (9, -7), ObserverLik
  (11, 4), RasporedLik (-14, -5), CiljLik (-20, -20), DrugiLik (-15, -16). Do učitavanja iz baze svaki lik stoji na
  nasumičnom spawn-u (±2 oko 0,0); `visi` se nikad ne učita, pa ga server drajver odmah skloni na `VISI_PARKING`
  (14, -14). Ranije je stajao ~12 s na spawn-u i mover bi naleteo na njega (`W_2s_napred` ~0.9 umesto ~10).
  Provere `prva_pojava_na_poziciji_iz_baze` i `novi_lik_000_se_pojavljuje`.
- **Učitavanje ima rok** (`UCITAVANJE_TIMEOUT` 10 s od `registruj_lik`): verify ili čitanje lika koje ne uspe ili
  istekne -> server izbaci peer-a, lik nikad ne postaje vidljiv. Uloga `visi` (token `visi-token`, stub ga drži
  40 s) proverava `ucitavanje_istek_izbacuje` (izbačen < 12 s) i `neucitan_lik_nevidljiv` (observer ga nikad ne vidi).
  `visi.log` sadrži `WARNING: ObjectDB instances leaked` (prekid usred scene), zato se WARN broji kao `^WARN `.
- **Action bar: raspored se čuva po liku** (`players.action_bar`, backend migracija 005). Lik bez sačuvanog rasporeda
  dobije potrošne predmete po redosledu inventara i to se upiše. Posle toga se iz inventara ništa ne dopunjuje: novi
  predmet ide u prvi prazan slot samo kad ga server dodeli (loot, kupovina, nagrada), pa predmet dodat direktno u
  bazi (npr. `inventory/change` mimo game servera) ne dobija slot. Nema drag-and-drop-a ni UI-ja za izmenu.
- **Server radi bez `server_relay`** (`NetworkManager.hostuj`). Sa relay-em Godot pri odlasku peer-a A
  šalje `DEL_PEER` ostalima (kanal 0) pre nego što ENet ukloni peer-a B koji je otišao u istom paketu
  → `Unable to send packet on channel 0, max channels: 0` u journal-u (dva klijenta izađu zajedno).
  Posledica: **klijenti više ne dobijaju `peer_connected`/`peer_disconnected` za druge klijente**, a
  `multiplayer.get_peers()` na klijentu vraća samo `[1]`. Tuđi likovi i dalje stižu preko
  `MultiplayerSpawner`-a. Sve što ide od klijenta ka klijentu (chat, party, trgovina) mora da ide
  preko servera (`rpc_id(1, ...)` pa server prosleđuje), ne `rpc()` sa klijenta.
- **`ERROR: Condition "!pinfo.recv_nodes.has(net_id)"` na klijentima** kad se `potion` klijent odjavi:
  Godot poruka pri despawn-u tuđeg lika, ne utiče na provere.

## Troubleshooting

| Simptom | Uzrok / rešenje |
|---|---|
| U prozorskom modu samo `observer_vidi_yaw`, mover nema PASS linije | Server se ugasio pre kraja movera (stara verzija sa fiksnim vremenom). Server mora da čeka dok peer-ovi ne odu. |
| `FAIL yaw_PI/2_ide_-x delta=(-0.78, 0, 0)` i `istek ... posle prekida 0.00` | Lik je udario u NPC na (0, _, -10). Putanja mora da ga zaobiđe (prva faza ide ka +z). |
| `FAIL W_2s_napred delta=(0, 0, -8)` | Screenshot ili drugi zastoj u W fazi; pomeri snimanje u fazu mirovanja. |
| `PASS nema_greske_neaktivnog_peera`, ali samo 1–2 linije ukupno i exit 1 | Drajver nije ni krenuo (npr. `SCRIPT ERROR: Parse Error` u driver.gd); grep greške je prazan jer nema logova. Gledaj `SCRIPT ERROR` linije. |
| `SCRIPT ERROR: Invalid assignment ... 'token' ... 'null instance'` | Autoload se koristi u `_initialize`; premesti u `_process`. |
