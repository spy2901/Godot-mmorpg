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

Izlaz: putanja do logova, 140 linija `PASS`/`FAIL` i linija `[M] korekcije ...` (broj glatkih/snap korekcija, prosečna/max greška predikcije). Exit 0 = svih 140 prošlo (WARN se računa kao prošao). `run.sh` pokreće movera i potion klijenta tek kad observer ispiše
`OBSERVER_SPREMAN` (prozorski observer kasni ~8 s, a mora da vidi movera od početka). Logovi su u
`$OUT` (podrazumevano `$TMPDIR/run-mmorpg`): `server.log`, `observer.log`, `mover.log`,
`potion.log`, `raspored1.log`, `raspored2.log`, `cilj.log`, `drugi.log`, `ai1.log`, `ai2.log`, `oprema1.log`, `oprema2.log`, `oprema3.log`, `napredak1.log`, `napredak2.log`, `quest1.log`, `quest2.log`, `quest3.log`, `stub.log`, `nameplate_*.png`. Postavi `OUT=<scratchpad>/run1`: Read alat ne sme da čita `$TMPDIR` van radnih
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
  Zastoj **servera** (frame > `ZASTOJ_PRAG`, meri ga server drajver) opravdava rupu u istom prozoru za svakog lika:
  posle zastoja servera rupe dobiju svi povezani likovi u istom trenutku (pod opterećenjem: server frame 134 ms, rupe
  9-10 kod četiri peer-a u t=12.23). Rupa bez ikakvog zastoja i dalje je FAIL (mutacija "svaki 97. unos izgubljen" pada).
- Fajlovi stanja između procesa (`_pisi`) pišu se atomski (`.tmp` pa `rename`): ranije je čitanje u trenutku kad
  pisac isprazni fajl (WRITE) vraćalo "" i sva polja prazna (npr. `ai_posmatrac_ne_vidi_pretnju`: Ai2Lik "cilj ''").
- Server prima najviše `MAX_PLAYERS` (8) peer-a, a run.sh pokreće ~15 klijenata: klijent koji dobije
  `connection_failed` (server pun) ponovo se povezuje svake sekunde do `POVEZIVANJE_ROK` (60 s); ranije su sve provere
  tog klijenta izostajale (npr. `server_prekid_vraca_na_login`, QuestLik, OpremaLik).

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
(apple u slotu 2 sa 0). Svih 5 pada bez implementacije (provereno: stari bar posle prijave pomeri manu u slot 2).
Prevlačenje (korak 1 posle `novi_predmet_prvi_prazan`, pravi događaji miša kroz `Input.parse_input_event`: pritisak,
pomeranje u 4 koraka sa frame-om između, otpuštanje; prozor drajvera 1280x720): `prevlacenje_slot_na_prazan` (mana 7 → 5,
količine iste), `prevlacenje_zamena_atomska` (1 ↔ 3: od servera tačno jedan raspored, konačni), `esc_otkazuje_prevlacenje_ne_skida_cilj`
i `tasteri_tokom_prevlacenja_ignorisani` (cilj `goblin_960` koga server drajver stvori na (-14, 3), 8 m od lika; Esc i taster 1 pre
otpuštanja iznad slota 8), `otpustanje_van_prozora_otkazuje` (otpuštanje na (-50, -50)), `prevlacenje_van_trake_prazni_slot`
(sredina ekrana; inventar isti), `esc_otkazuje_prevlacenje_iz_inventara`, `inventar_na_traku_raspored_inventara_isti` (mana
iz inventara u slot 4; mač na slot 6 ne šalje ništa), `server_odbija_nepotrosni_i_tudji` (direktan zahtev: mač, i
large_health_potion koji lik nema), `klik_na_slot_koristi_napitak`. Korak 2 proverava konačni raspored (medium, apple, small,
mana). Provereno da pada: bez implementacije svih 11 (9 prevlačenja + 2 iz koraka 2); posebno zamena kroz dva zahteva
(međustanje), server bez provere potrošnog/posedovanja, tasteri tokom prevlačenja, van prozora = uklanjanje, Esc bez
obrade u traci i Esc bez obrade u inventaru.
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
implementacije (provereno). `ai_traka_pretnje_sakrivena` stanje "bez pretnje" i "bez cilja" čita tek kad klijent javi
izabran cilj sa vidljivim okvirom, odnosno skinut cilj sa sakrivenim okvirom (rok 2 s), ne jedno čitanje posle fiksnog
čekanja; mutacije (tuđa pretnja vidljiva, traka uvek vidljiva) i dalje obaraju obe provere.

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
preklope; brojač `item_use_br`), `POST /players/{ime}/xp/change` samo za `XP_LIKOVI` (NapredakLik; ostali test
likovi imaju veštački HP koji bi statistike iz nivoa prepisale) sa `primeni_xp` iz pravog backend-a: stub uvozi
`napredak.py` iz `BACKEND_DIR` (podrazumevano `~/mmorpg-server`), pa bez backend repoa `run.sh` odmah ispiše
`FAIL stub_api`. Nepoznate rute: 404 i linija u `$OUT/stub.log`. TestLik ima sačuvanu
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

Oprema i statistike (`Player_Movement`: server drži `oprema` i računa attack = `napad_damage` + damage oružja,
armor = zbir, max HP = osnovni + hp_bonus; primljena šteta = max(1, šteta·100/(100+armor)); zahtev
`zatrazi_opremanje(slot, item_id)`, "" = skidanje). Uloga `oprema`: `korak=1` OpremaLik (8 komada opreme u stub-u,
osnovno 25/0/100) oprema kroz inventar (`_on_slot_klik`, `_skini_opremu`) i direktnim zahtevima; server drajver
upisuje statistike po serveru u `$OUT/oprema_server` i izvršava `$OUT/oprema_cmd` ("steta N" u istom frame-u ->
`$OUT/oprema_steta`, "hp N"). `korak=2` je ponovna prijava, `korak=3` Oprema2Lik šalje zahtev za tuđi lik. Provere:
`oprema_osnovne_vrednosti`, `oruzje_povecava_stetu`, `oklop_68_smanjuje_stetu_25_na_14`,
`max_hp_predmet_podize_maksimum`, `skidanje_max_hp_ogranicava_hp`, `odbija_predmet_koji_nije_u_inventaru`,
`odbija_pogresan_slot`, `odbija_isti_predmet_dvaput`, `iron_gloves_se_ne_oprema` (klik ne šalje zahtev, opis "Can't be
equipped"), `skidanje_vraca_stare_vrednosti`, `drugi_igrac_ne_oprema_tudji_predmet`, `statistike_prezive_prijavu`,
`hp_iznad_osnovnog_prezivi_prijavu`. Svih 13 pada bez implementacije (provereno). Stub `/save` čuva inventar i opremu
samo kad se broj komada slaže (kao backend). Mover čeka gašenje servera do 70 s (`run.sh` čeka uloge do 60 s).
`hp_iznad_osnovnog_prezivi_prijavu`: korak 1 se odjavi sa HP 150 (pun maksimum, regeneracija ga ne menja) i upiše ga
u `$OUT/oprema_korak1`; server drajver upiše HP u prvom frame-u posle učitavanja (`$OUT/oprema_ucitan`); HP pri
odjavi, HP koji je stub snimio i HP posle učitavanja moraju biti jednaki (stub koji snimi 3 manje -> FAIL).
`server_ne_salje_hp_odjavljenom` (`run.sh`, grep `server.log`): Oprema2Lik ima HP 50/1000, a stub drži njegov
`/save` 2.5 s (`SPORI_SAVE`), pa posle odjave regeneracija kuca dok server snima; u logu ne sme biti
"Attempt to call RPC with unknown peer ID" (bez guard-a u `_posalji_hp` pada sa 2 greške).

Napredak lika (backend `napredak.py`: kriva 25·n²+75·n, statistike iz nivoa, maksimum 20). Uloga `napredak`:
`korak=1` NapredakLik (nivo 1, HP 40/100, mana 30, steel_shield +10 max HP, napad 10) traži od servera
(`$OUT/napredak_cmd`: "ubij XP" / "hp HP MANA") ubistvo test goblina (goblin_97N) sa zadatim `xp_nagrada`: goblin umire
pravim putem (`Enemy.primi_damage` -> `server_isplati_xp` -> stub `/xp/change`). Server drajver upisuje statistike
lika u `$OUT/napredak_server`. Provere: `napredak_ubistvo_daje_xp_i_level_up_po_krivi` (100 XP -> Lv.2 0/250, HUD,
stub, napad 12), `napredak_level_up_poruka_u_hud_u` ("Level up! Lv.2"),
`napredak_statistike_sa_servera_pun_hp_i_mana_sa_bonusom_opreme` (server 12/115+10, HP 125 i mana 110 puni, HUD max
HP 125, ne osnovni 115), `napredak_vise_nivoa_odjednom` (730 XP -> Lv.4 30/700), `napredak_nivo_20_maksimum_xp_se_ne_skuplja`
(Lv.20 0/0, traka "XP: MAX  |  Lv.20" puna, ubistvo na 20 ne menja ništa i ne pokazuje poruku); `korak=2` je
ponovna prijava: `napredak_statistike_prezive_prijavu`. Ubistvo daje najviše 25% XP-a trenutnog nivoa, pa je nivo 2
četiri ubistva po 25 XP; "više nivoa odjednom" i nivo 20 idu komandom "xp N" (`server_isplati_xp`, kao nagrada questa).

Sadržaj (uloga `quest`, prozor drajvera 1280x720; `korak=1` QuestLik i `korak=2` PosmatracLik istovremeno). Server
drajver na početku proverava scenu i podatke: `neprijatelji_nivoi_i_spawn_tacke` (goblin 3 tačke nivoa 1-3, kostur 3
nivoa 4-6, trol 2 nivoa 8-10 sa jednim nivoa 10; tačke ≥ 12 m od spawna igrača, aggro zone se ne preklapaju, quest
NPC-ovi van aggro zona), `xp_po_razlici_nivoa_pragovi` (`Enemy.xp_mnozilac` za razliku -12..+6, 10-20 ubistava po
nivou, minimum 1 XP), `najbolja_oprema_samo_trol_nivoa_10` (šest predmeta samo u troll.tscn sa `min_nivo` 10 i šansom
0.4%; `baci_loot` 30000 puta za trola 10: 0.2-0.6% po predmetu (na 1% pada), 0 za ostale vrste i nivoe), `iron_gloves_van_loota_i_prodavnice`,
`questovi_dostupni_u_svetu` (svaki quest iz `/quests` dostupan lancem od nekog quest NPC-a u sceni; kill cilj se spawn-uje,
fetch cilj pada sa spawn tačke ili je nagrada). Komande `$OUT/quest_cmd` ("ubij NIVO NAPADAČ [LIK_SA_ŠTETOM_0]",
"spawn VRSTA ID NIVO"), potvrda `$OUT/quest_server`. QuestLik (nivo 1, dva mača, 1.1 m ispred Village Elder-a):
`quest_klikom_na_npc_prihvat_i_predaja` (levi klik na NPC-a, klik na Accept, pa klik na NPC i Turn in: stub zlato +100,
mačevi skinuti, 120 XP -> Lv.2 20/250), `quest_lanac_redosled` (goblin_killer pre skupljac_oruzja odbijen "Prethodni
quest nije zavrsen", prva ponuda Weapon Collector, posle predaje Goblin Trouble), `loot_samo_napadacima` i
`bez_stete_bez_kill_i_quest_credita` (PosmatracLik sa aktivnim goblin_killer udari 0, QuestLik ubije: samo QuestLik
dobija loot, kill i progres, i na klijentu), `xp_po_razlici_nivoa_po_napadacu` (PosmatracLik nivo 12 ubija goblina
nivoa 12+d; stub `xp_dnevnik`), `neprijatelji_statistike_skaliraju_sa_nivoom` (trol 10, kostur 5, goblin 3 na klijentu),
`prodavnica_bez_iron_gloves_i_najbolje_opreme` (MerchantUI ih ne nudi, server odbija kupovinu). Svih 12 pada bez
implementacije (provereno); posebno i bez klika na NPC-a, sa štetom 0 kao napadom i bez `min_nivo`.
Zona 2 (sadržaj 2, migracija 009): server proverava i `vrste_neprijatelja_jedna_lista` (`spawn_point.VRSTE` = spawner
`ENEMY_SCENES` = enum u editoru; svaka vrsta ima scenu, ime = ključ i red u teksti.csv), `zona2_spawn_tacke` (x > 25:
vuk 11-13, pauk 14-16, utvara 17/18/20, na podu do x 75, Hunter), `zona2_loot_t3_t4_samo_svoja_zona` (steel_greaves pauk
min_nivo 11 3%, shadow_boots utvara 17 2%, dragonscale_leggings utvara 20 0.4%; 30000 bacanja na min_nivo i min_nivo-1) i
`novi_predmeti_dostupni` (9 predmeta iz 009: prodavnica za T1, loot ili nagrada questa za T3/T4). `neprijatelji_nivoi_i_spawn_tacke`
sada pokriva svih 17 tačaka (aggro zone ≥ 0.5 m razmaka). QuestLik još: `nove_vrste_nivoi_statistike_xp` (vuk 11, pauk 15,
utvara 20 na klijentu), `prodavnica_t1_da_t3_t4_ne`; PosmatracLik ubija i goblina svog nivoa (d = 0, bez ograničenja).
`korak=3` LovacLik (nivo 1, 6 krzna, ispred Hunter-a na (29, 0); svoj kanal `$OUT/lovac_cmd`/`lovac_server`):
`xp_limit_po_ubistvu` (vuk 11 -> 25 = 25% od 100, goblin 1 -> 7), `quest_lovac_klikom_prihvat_i_predaja` i
`quest_lovac_lanac_redosled` (svila_za_krojaca pre vucja_krzna odbijen). OpremaLik: `oklop_prema_nivou_napadaca_10_i_20`
(komanda "steta 25 N": 18 i 20; nivo 1 ostaje 14). Svih 10 novih pada bez implementacije (oklop: na staroj formuli).
Stub: `/items`, `/quests`, `/quests/{id}`, `/quests/completed/{ime}`, `quest/accept|kill|turnin|abandon` (kao
routers/players.py, lanac i redosled grešaka), `inventory/change` (loot). Bez implementacije (loot svima) RasporedLik i
OpremaLik dobijaju tuđi loot pa padaju i njihove provere inventara.

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
  bazi (npr. `inventory/change` mimo game servera) ne dobija slot. Izmena rasporeda: prevlačenje mišem (`action_bar.gd`,
  ručno, prag 10 px kao inventar; slot → slot = `zatrazi_zamenu_action_slotova`, van trake = prazan slot, inventar →
  slot = `zatrazi_action_slot`), server prihvata samo potrošni predmet koji lik ima ili je već na traci.
- **Headless prozor je 64x64**: UI koji se testira mišem (traka na dnu, okvir cilja na vrhu) se preklapa i viri van
  prozora; uloga `raspored` (kao `cilj`) zato postavi `root.size = 1280x720`.
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
