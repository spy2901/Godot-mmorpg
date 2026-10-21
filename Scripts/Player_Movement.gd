extends CharacterBody3D

#MOVEMNT
const BRZINA := 5.0 # m/s bez buff-a
const BRZINA_BUFF_MAX := 30 # %: najveći buff brzine (speed_potion, migracija 010); server ograničava raspored na ovo
const BRZINA_MAX := BRZINA * (100 + BRZINA_BUFF_MAX) / 100.0 # najveća moguća brzina (ograničenje prikaza tuđeg lika)
var brzina = BRZINA # za simuliraj_korak: postavlja se po unosu (_brzina_za_seq), na serveru i kod vlasnika
var gravitacija = -9.8
var mouse_sensitivity = 0.3
var rotacija_misa = false
var yaw_sync := 0.0 # server -> ostali klijenti (MultiplayerSynchronizer); vlasnik koristi lokalni rotation.y
const SKOK := 5.0
const UNOS_ISTEK_MS := 500 # server: posle ovoliko bez unosa sam simulira lik bez unosa (gravitacija)

#PREDIKCIJA I RECONCILIATION (podešavanje)
const PRAG_IGNORISI := 0.05 # m: manja greška predikcije se ignoriše
const PRAG_SNAP := 1.5      # m: veća greška = snap; između = glatko preko CharacterMain
const SMOOTH_TIME := 0.1    # s: trajanje glatke korekcije modela i kamere
const INTERP_DELAY := 0.1   # s: tuđi likovi se crtaju ovoliko u prošlosti
const MAX_EKSTRAPOLACIJA := 0.25 # s: posle poslednjeg snimka tuđi lik staje
const MAX_BUFFER := 120     # nepotvrđenih unosa na klijentu
const UNOSA_NEPOTVRDJENIH_MAX := 32 # redundansa: paket nosi sve unose koje server nije potvrdio (seq u stanju), najviše 32
const UNOS_RATE := 1.2      # server: najviše 1.2 * physics_ticks_per_second unosa/s (token bucket)
const UNOS_BURST := 10.0    # server: kapacitet kofe
# server: red unosa koji čekaju token. Rafal posle zastoja (servera ili klijenta) se zakasni umesto
# da se odbaci. Izmereno pod opterećenjem (analiza_rafala.py): najduži zaostatak 12, najgori viđeni
# događaj 28 uzastopnih odbijenih unosa -> 32 (~15% rezerve). Pun red odbacuje višak (speed-hack).
const UNOS_RED_MAX := 32

# unos = [seq: int, smer: Vector2, skok: bool, yaw: float, reset_id: int]
var poz_sync := Vector3.ZERO # server -> ostali klijenti (MultiplayerSynchronizer); vlasnik je ne čita
var tik_sync := 0            # server physics frame kome pripada poz_sync
# klijent-vlasnik
var _seq := 0
var _buffer: Array = []      # nepotvrđeni unosi
var _stanje = null           # poslednje stanje od servera, primenjuje se u physics tick-u
var _inicijalizovan := false
var _vizuelni_offset := Vector3.ZERO
var _offset_brzina := 0.0
var _model_poz := Vector3.ZERO
var _kamera_poz := Vector3.ZERO
var _kamera_rot0 := Vector3.ZERO # rotacija kamere iz scene; yaw/roll ostaju, menja se samo pitch
var _pitch := 0.0                # pitch kamere (rad), jedini izvor ugla gore/dole
var _zum_korak := 0              # koraci zuma od početnog offseta iz scene (0 = početni)
var _kamera_z0 := 0.0            # početni offset kamere (z) iz scene
var server_poz := Vector3.ZERO # poslednja pozicija od servera (testovi)
var korekcije_glatke := 0
var korekcije_snap := 0
var greska_max := 0.0
var greska_suma := 0.0
var greska_n := 0
var test_gubitak := 0.0 # test: deo paketa koji klijent odbacuje (oba smera)
var test_ubrzanje := 1  # test: unosa po physics tick-u (speed-hack)
var test_izgubi_paketa := 0 # test: sledećih N paketa unosa se ne šalje (uzastopni gubitak)
var test_izgubljeno_paketa := 0
var paket_bajtova := 0 # klijent: veličina poslednjeg kodiranog paketa unosa (payload, bez RPC zaglavlja)
var test_zadrzi := false # test: klijent pravi unose ali ih ne šalje; kad se pusti, šalje ih u rafalu
var _poslato_do := 0     # klijent: najveći seq koji je otišao u nekom paketu
var _za_slanje: Array = [] # klijent: nepotvrđeni unosi za slanje (najviše UNOSA_NEPOTVRDJENIH_MAX); reset ga NE briše
# (inače unosi koji su bili na putu u trenutku reset-a ostanu bez redundanse i jedan izgubljen paket = rupa)
var test_izgubi_posle_reseta := false # test: paketi kasne 1 tick, a onaj na putu kad stigne reset se izgubi
var test_izgubljen_paket := false     # test: hook je zaista izgubio paket
var test_izgubi_reset_prijave := false # test: klijent odbaci prvo reset stanje posle inicijalizacije (učitavanje iz baze)
# test (brzina): veštački RTT vlasnika, pola na izlazu (unosi, pong) i pola na ulazu (stanje, raspored brzine, ping), uz
# jitter +-ms bez preuređivanja poruka; prvi raspored brzine kasni ("kasni:N" ms) ili se izgubi ("izgubi")
var test_rtt_ms := 0
var test_jitter_ms := 0
var test_raspored_brzine := ""
var test_brzina_pocela_ms := 0 # test postavi -1: ovde se upiše vreme prvog lokalnog koraka bržeg od BRZINA
var _t_izlaz: Array = [] # [rok ms, Callable]
var _t_ulaz: Array = []
var _t_isporuka := false
var test_reset_izgubljen := false      # test: hook je zaista odbacio reset
var test_zakasni_reset := false        # test: sačuvaj kopiju prvog reset stanja (za test_ubaci_zakasneli_reset)
var _test_reset_kopija = null
var _test_paket = null
# server
var _red: Array = []         # validni unosi čekaju token (najviše UNOS_RED_MAX)
var odbijeno_red_pun := 0    # server: unosi (različiti seq) odbačeni jer je red bio pun
var _odbijen_do := 0         # server: najveći seq već uračunat u odbijeno_red_pun
var red_max := 0             # server: najveća dužina reda (testovi, debug)
var _red_od_ms := -1         # server: kad je red počeo da zaostaje (debug: vreme pražnjenja)
var _red_vrh := 0            # server: vrh reda u tekućem zaostatku
var red_zaostatak := [0, 0]  # server: [vrh, ms] poslednjeg ispražnjenog zaostatka (testovi)
var _poslednji_seq := 0
var _tokeni := UNOS_BURST
var _tokeni_ms := 0
var _unos_ms := -UNOS_ISTEK_MS
# reset (spawn, prijava, respawn): server ga šalje u SVAKOM stanju (isti reset_id i pozicija) dok ne stigne
# unos sa tim reset_id-om; dotle drži lik na reset poziciji i odbacuje unose iz ranije epohe
var _reset_id := 0           # server: id poslednjeg reset-a (rastući po peer-u)
var _reset_ceka := false     # server: reset još nije potvrđen unosom
var _reset_poz := Vector3.ZERO
var reset_izdato := 0        # server: broj reset-a u sesiji ([SESIJA])
var reset_paketa := 0        # server: broj stanja poslatih sa reset-om ([SESIJA])
var _reset_id_prim := 0      # klijent: poslednji primenjeni reset_id (duplikati se ignorišu)
var rupe_seq := 0            # preskočeni seq-ovi (izgubljeni ili odbijeni)
var rupe_najduza := 0        # najduži niz uzastopno preskočenih seq-ova
var rupe_nizovi := {"1": 0, "2": 0, "3": 0, "4-6": 0, "7+": 0} # broj nizova po dužini
# debug (server, MMORPG_DEBUG_SEQ=1): svaka rupa u seq obradi sa razlogom i vremenima
var _debug_seq := OS.get_environment("MMORPG_DEBUG_SEQ") == "1"
var _spawn_ms := 0           # server: kad je lik napravljen (konekcija peer-a)
var _je_server := false      # zapamćeno u _ready: u _exit_tree peer može već biti zatvoren
var _ucitan_ms := -1         # server: kad je lik učitan iz baze
var _reset_ms := -1          # server: poslednji server_postavi_poziciju(reset=true)
var _odbijeni := {}          # seq -> razlog odbijanja (debug)
var _rupe_otvorene := {}     # seq -> ms kad je rupa nastala (debug: da li stigne kasnije)
var _dbg_poslato := 0        # klijent (debug): najveći poslati seq
var _dbg_paket_ms := 0       # server (debug): kad je stigao prethodni paket unosa
# server, uvek (za [SESIJA]): da li je server zastajao ili paketi nisu stizali
var paket_razmak_max := 0     # ms, najveći razmak između dva paketa unosa ovog peer-a
var paketa_posle_pauze := 0   # paketa posle razmaka > 100 ms
var frame_max_ms := 0         # najduži server frame dok je lik bio u igri
var frame_dugih := 0          # server frame-ova > 50 ms
var paket_b_zbir := 0         # server: primljeni paketi unosa (bajtova, broj, max) za [SESIJA]
var paket_b_br := 0
var paket_b_max := 0
var _dbg_max_vidjen := 0     # server (debug): najveći seq viđen u bilo kom paketu (nezavisno od obrade)
# posmatrač
var _snimci: Array = []      # [tik, poz, yaw]
var _sat_pomak := 0.0        # lokalno vreme - serversko vreme (usrednjeno)

#ATTACK
var napad_damage = 10  # na serveru: učitano iz baze preko registruj_lik (osnovni napad nivoa)
var bonus_oruzja = 0   # na serveru: attack opremljenog oružja (items.damage)
var napad_cooldown = 1.0
const DOMET_NAPADA := 3.5  # m, od SERVER pozicije igrača do cilja
var _napad_spreman_ms := 0 # server: od kada sme sledeći napad
signal napad_odgovor(odgovor: Dictionary) # klijent: odgovor servera na napad
var ime_lika := ""      # samo na serveru
var nivo_lika := 1      # samo na serveru: nivo po bazi (XP ubistva prema razlici nivoa, Enemy._isplati_kill)

#CAMERA
var zum_brzina = 1.0
var min_zum = 0.0
var max_zum = 2.0

var vlasnistvo: Dictionary = {}  # item_id -> količina (samo na serveru)

#ZDRAVLJE (server je jedini izvor istine; klijent samo prikazuje preko primi_hp)
const HP_REGEN := 2
const MANA_REGEN := 3
const RESPAWN_DELAY := 3.0
const NEOSJETLJIVOST_MS := 2000
const SLOTOVI_OPREME := ["head", "chest", "legs", "boots", "weapon", "shield"]
const MAX_SLOTOVA_INVENTARA := 24 # = backend MAX_SLOTOVA i inventar klijenta (6 x 4)

var hp := 100
var max_hp := 100
var mana := 100
var max_mana := 100
var mrtav := false # server: pravi status; klijent: ogledalo za blokiranje unosa
var armor := 0 # samo na serveru: zbir armor-a opreme
var hp_bonus := 0 # samo na serveru: zbir hp_bonus-a opreme; max_hp = max_hp_osnovni + hp_bonus
var max_hp_osnovni := 100 # samo na serveru: iz baze (raste sa nivoom)
var oprema := {} # samo na serveru: slot -> item_id; jedini izvor opreme (klijent šalje samo zahteve)
var _predmeti := {} # samo na serveru: item_id -> podaci predmeta iz API-ja (statistike i slot se ne menjaju)
var _oprema_u_toku := false # samo na serveru
signal oprema_odgovor(odgovor: Dictionary) # klijent: odgovor na zahtev za opremanje/skidanje
signal statistike_promenjene # klijent: stigle statistike od servera
var stat_attack := 0 # klijent: statistike lika po serveru (samo za prikaz)
var stat_armor := 0
var stat_max_hp := 0
var _stanje_ucitano := false # samo na serveru: hp/mana učitani iz baze
var _neosjetljiv_do_ms := 0 # samo na serveru
var _regen_akum := 0.0 # samo na serveru

#NAMEPLATE (ime + HP traka iznad tuđih igrača; samo na klijentima)
const MAX_PRIKAZ_DALJINA := 40.0 # m od kamere lokalnog igrača
const NAMEPLATE_VISINA := 1.65   # m iznad stopala (model igrača je ~1.35 m; 2.2 kao kod neprijatelja lebdi visoko)
const NAMEPLATE_SIRINA := 0.9    # m, HP traka
const NAMEPLATE_DEBLJINA := 0.1
const BOJA_HP_VISOK := Color(0.2, 0.85, 0.2)   # > 50%
const BOJA_HP_SREDNJI := Color(0.95, 0.8, 0.1) # 25-50%
const BOJA_HP_NIZAK := Color(0.9, 0.15, 0.1)   # < 25%
const BOJA_IME_MRTAV := Color(0.55, 0.55, 0.55)

# server -> svi klijenti (MultiplayerSynchronizer, ON_CHANGE); postavlja ih samo _sync_nameplate()
var hp_sync := 100:
	set(v):
		hp_sync = v
		_osvezi_nameplate()
var max_hp_sync := 100:
	set(v):
		max_hp_sync = v
		_osvezi_nameplate()
var mrtav_sync := false:
	set(v):
		mrtav_sync = v
		_osvezi_nameplate()
var ime_sync := "":
	set(v):
		ime_sync = v
		_osvezi_nameplate()
# nevidljivost: svi klijenti (i vlasnik) vide providan model; postavlja ga samo _buffovi_promenjeni
const PROVIDNOST_NEVIDLJIV := 0.7
var nevidljiv_sync := false:
	set(v):
		nevidljiv_sync = v
		var model := get_node_or_null("CharacterMain")
		if model:
			for m in model.find_children("*", "GeometryInstance3D", true, false):
				m.transparency = PROVIDNOST_NEVIDLJIV if v else 0.0
var _nameplate: Node3D
var _ime_label: Label3D
var _hp_traka: MeshInstance3D

@onready var kamera = $Camera3D

func _ready():
	add_to_group("player")
	_spawn_ms = Time.get_ticks_msec()
	_je_server = multiplayer.is_server()
	if _je_server:
		server_postavi_poziciju(global_position, true) # spawn je reset br. 1
	_model_poz = $CharacterMain.position
	_kamera_poz = kamera.position
	_kamera_rot0 = kamera.rotation
	_kamera_z0 = _kamera_poz.z
	_pitch = _kamera_rot0.x
	# Node pripada vlasniku (RPC-ovi); poz_sync/yaw_sync šalje server ostalima.
	# position se NE replicira: vlasnikovu poziciju menjaju samo predikcija i reconciliation.
	$MultiplayerSynchronizer.set_multiplayer_authority(1)
	if _je_server:
		# Ostali klijenti ne dobijaju lika (ni spawn: vidljivost sinhronizatora važi i za spawn) dok se
		# ne učita iz baze, inače ga vide na spawn tački pa skok. Vlasnik ga dobija odmah (šalje unose).
		$MultiplayerSynchronizer.public_visibility = false
		$MultiplayerSynchronizer.set_visibility_for(get_multiplayer_authority(), true)
	# Server je autoritet za sve likove; vlasnik predviđa svoj lik i šalje unose
	set_physics_process(multiplayer.is_server() or is_multiplayer_authority())
	if not multiplayer.is_server() and not is_multiplayer_authority():
		_napravi_nameplate()
		hide() # tuđi lik: skriven do prvog snimka sa servera (spawn_function ga stavlja na nasumičan spawn)
	if not is_multiplayer_authority():
		set_process_unhandled_input(false)
		kamera.current = false
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	kamera.current = true

# Ukupan damage po udarcu: (baza lika + bonus oružja) * buff napada
func izracunaj_damage() -> int:
	return roundi((napad_damage + bonus_oruzja) * (100 + buff("napad")) / 100.0)

# Klijent: jedan pritisak = jedan zahtev. Metu, domet, cooldown i štetu određuje server.
func napadni() -> void:
	if multiplayer.is_server():
		zatrazi_napad()
	else:
		zatrazi_napad.rpc_id(1)

@rpc("any_peer", "reliable")
func zatrazi_napad() -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	_odgovori(odgovor_napad, _napadni_cilj())

# Server: napad na cilj koji je server zapamtio za ovog igrača.
func _napadni_cilj() -> Dictionary:
	if mrtav:
		return {"ok": false, "poruka": "You are dead"}
	var e := neprijatelj_po_id(_cilj_srv) if _cilj_srv != "" else null
	if e == null or e._mrtav:
		return {"ok": false, "poruka": "No target"}
	if global_position.distance_to(e.global_position) > DOMET_NAPADA:
		return {"ok": false, "poruka": "Too far"}
	var sada := Time.get_ticks_msec()
	if sada < _napad_spreman_ms:
		return {"ok": false, "poruka": "Not ready yet"}
	_napad_spreman_ms = sada + int(napad_cooldown * 1000)
	if _buffovi.has("nevidljivost"): # napad prekida nevidljivost pre štete, pa pretnja odmah važi
		_buffovi.erase("nevidljivost")
		print("[BUFF] ", ime_lika, " nevidljivost prekinuta napadom")
		_buffovi_promenjeni()
	e.primi_damage(izracunaj_damage(), get_multiplayer_authority())
	return {"ok": true}

@rpc("any_peer", "reliable")
func odgovor_napad(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	napad_odgovor.emit(d)
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and not d.get("ok", false):
		hud.prikazi_poruku(str(d.get("poruka", ""))) # prikazi_poruku prevodi

# ---------------------------------------------------------------- LIK -> SERVER

# Klijent (vlasnik lika) jednom pošalje token, server od /auth/verify dobije ime lika i učita statistike.
func posalji_lik_serveru(token: String) -> void:
	if multiplayer.is_server():
		registruj_lik(token)  # host: poziv je lokalan, nema RPC-a
	else:
		registruj_lik.rpc_id(1, token)

var _registracija_u_toku := false  # samo na serveru
# Server: rok za učitavanje (verify + čitanje lika). Ne uspe ili istekne -> peer se izbacuje, lik nikad
# ne postaje vidljiv ostalima (_objavi_ostalima proverava _odbijen: kasni odgovor posle izbacivanja).
const UCITAVANJE_TIMEOUT := 10.0
var _odbijen := false
var _objavljen := false

@rpc("any_peer", "reliable")
func registruj_lik(token: String) -> void:
	if not multiplayer.is_server():
		return
	# Samo vlasnik lika sme da registruje svoj lik
	var posiljalac := multiplayer.get_remote_sender_id()
	if posiljalac != 0 and posiljalac != get_multiplayer_authority():
		return
	if ime_lika != "" or _registracija_u_toku:
		return
	_registracija_u_toku = true
	var peer_id := get_multiplayer_authority()
	get_tree().create_timer(UCITAVANJE_TIMEOUT).timeout.connect(_istek_ucitavanja)
	var r: Dictionary = await ApiManager.verify_token(token)
	_registracija_u_toku = false
	if _odbijen:
		return
	var ime := str(r.get("ime_lika", ""))
	if r.get("status", "") != "ok" or ime == "":
		var razlog := str(r.get("error", "invalid response"))
		print("[AUTH] Odbijen peer ", peer_id, ": ", razlog)
		_odbij(peer_id, "Login rejected: %s", razlog)
		return
	# Isti lik već u igri -> starog izbaci
	for p in get_tree().get_nodes_in_group("player"):
		if p != self and p.ime_lika == ime:
			print("[AUTH] ", ime, " je već prijavljen (peer ", p.get_multiplayer_authority(), "), izbacujem starog")
			p.ime_lika = ""
			p._odbij(p.get_multiplayer_authority(), "Logged in from another location")
	ime_lika = ime
	_sync_nameplate()
	print("[AUTH] Peer ", peer_id, " -> ", ime)
	_ucitaj_statistike_sa_servera(ime)

func _istek_ucitavanja() -> void:
	if _objavljen or _odbijen:
		return
	print("[AUTH] Peer ", get_multiplayer_authority(), ": učitavanje lika nije završeno za ", UCITAVANJE_TIMEOUT, " s, izbacujem")
	_odbij(get_multiplayer_authority(), "Loading the character failed (timed out)")

# Server: javi peer-u razlog pa ga diskonektuj (host koji igra: lokalni poziv). poruka je engleski ključ (može sa %s),
# detalj (npr. greška backenda) se prevodi posebno.
func _odbij(peer_id: int, poruka: String, detalj := "") -> void:
	_odbijen = true
	if peer_id == multiplayer.get_unique_id():
		registracija_odbijena(poruka, detalj)
		return
	registracija_odbijena.rpc_id(peer_id, poruka, detalj)
	NetworkManager.izbaci_peer(peer_id)

@rpc("any_peer", "reliable")
func registracija_odbijena(poruka: String, detalj: String) -> void:
	if not _poziv_od_servera():
		return
	var sablon := "%s" in poruka
	print("[AUTH] ", poruka % detalj if sablon else poruka)
	NetworkManager.prekini()
	GameState.token = ""
	GameState.poruka_logina = tr(poruka) % tr(detalj) if sablon else tr(poruka)
	get_tree().change_scene_to_file("res://Scenes/UI/MainMenu.tscn")

func _ucitaj_statistike_sa_servera(ime: String) -> void:
	var p: Dictionary = await ApiManager.get_player(ime)
	if _odbijen:
		return
	if p.is_empty() or p.has("error"):
		print("[SERVER] Ne mogu da učitam lik: ", ime)
		_odbij(get_multiplayer_authority(), "Loading the character failed")
		return
	napad_damage = int(p.get("napad_damage", napad_damage))

	# vlasništvo = sve što je u inventaru + sve što je opremljeno
	vlasnistvo.clear()
	for e in p.get("inventory", []):
		var id := str(e.get("id", ""))
		if id != "":
			vlasnistvo[id] = vlasnistvo.get(id, 0) + int(e.get("kolicina", 1))
	var eq: Dictionary = p.get("equipment", {})
	for slot in eq:
		var id := str(eq[slot])
		if id != "":
			vlasnistvo[id] = vlasnistvo.get(id, 0) + 1
	# JSON iz baze daje brojeve kao float (3 -> 3.0), a /save prihvata samo int slot i kolicina: lik koji tokom sesije
	# ne promeni inventar (klijent ne pošalje raspored) bi pri odjavi poslao 3.0 i backend bi odbio raspored
	var inventar: Array = p.get("inventory", []).map(_int_unos)
	# oprema iz baze važi samo ako predmet ide baš u taj slot; ostalo se vraća u inventar
	oprema.clear()
	for slot in eq:
		var id := str(eq[slot])
		if id == "":
			continue
		if slot in SLOTOVI_OPREME and str((await _predmet(id)).get("slot", "")) == slot:
			oprema[slot] = id
		else:
			print("[OPREMA] ", ime, ": ", id, " ne ide u slot ", slot, ", vraćen u inventar")
			_inv_vrati(inventar, id)
	var ab_sacuvan := await _ucitaj_action_bar(p.get("action_bar"), p.get("inventory", []))
	var zavrseni: Array = await ApiManager.get_completed_quests(ime)
	if ime_lika != ime:  # izbačen dok smo čekali backend
		return

	# HP i mana: od sada ih drži server; maksimum HP-a = osnovni iz baze + hp_bonus opreme
	max_hp_osnovni = int(p.get("max_hp", 100))
	_preracunaj_statistike()
	max_mana = int(p.get("max_mana", 100))
	hp = clampi(int(p.get("hp", max_hp)), 1, max_hp)
	mana = clampi(int(p.get("mana", max_mana)), 0, max_mana)
	mrtav = false
	_neosjetljiv_do_ms = 0
	nivo_lika = int(p.get("level", 1))
	_stanje_ucitano = true
	_ucitan_ms = Time.get_ticks_msec()
	_sync_nameplate()
	print("[SERVER] Lik ", ime, " registrovan, damage: ", izracunaj_damage(), ", predmeta: ", vlasnistvo.size())

	_ucitano_stanje = {"inventory": inventar}
	var podaci := {
		"level": p.get("level", 1), "xp": p.get("xp", 0), "max_xp": p.get("max_xp", 100),
		"hp": hp, "max_hp": max_hp,
		"mana": mana, "max_mana": max_mana,
		"gold": p.get("gold", 100), "napad_damage": napad_damage,
		"inventory": inventar, "equipment": oprema.duplicate(),
		"aktivni_quest_id": p.get("aktivni_quest_id", null), "quest_progres": p.get("quest_progres", 0),
		"zavrseni_questovi": zavrseni
	}
	var pos := Vector3(float(p.get("pos_x", 0)), float(p.get("pos_y", 0)), float(p.get("pos_z", 0)))
	if pos != Vector3.ZERO:
		server_postavi_poziciju(pos, true)
		podaci["pos_x"] = pos.x
		podaci["pos_y"] = pos.y
		podaci["pos_z"] = pos.z
	_objavi_ostalima()
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_lik(podaci)
	else:
		primi_lik.rpc_id(vlasnik, podaci)
	_javi_statistike()
	if ab_sacuvan:
		_javi_action_bar()
	else:
		_ab_sacuvaj() # početni raspored (iz inventara) se upisuje u bazu

# Server: lik je učitan (pozicija iz baze ili spawn za novi lik) -> postaje vidljiv ostalim klijentima.
# Sync polja se pune odmah da spawn paket već nosi pravu poziciju.
func _objavi_ostalima() -> void:
	if _odbijen:
		return
	_objavljen = true
	for id in vlasnistvo:
		_javi_predmet(id)
	poz_sync = global_position
	tik_sync = Engine.get_physics_frames()
	yaw_sync = rotation.y
	$MultiplayerSynchronizer.public_visibility = true

# ---------------------------------------------------------------- SNIMANJE (server)

const SAVE_RAZMAK_MS := 2000
var _ucitano_stanje: Dictionary = {}  # inventory/equipment iz baze; prazno = lik nije učitan
var _poslednje_stanje: Dictionary = {}  # poslednji raspored inventara od klijenta
var _poslednje_snimanje_ms := -SAVE_RAZMAK_MS
var _snimanje_zakazano := false

# Klijent (vlasnik) šalje samo raspored inventara; opremu drži server (equipment od klijenta se ignoriše),
# a hp/manu i poziciju server uzima sam.
@rpc("any_peer", "reliable")
func posalji_stanje(inventory: Array, _equipment: Dictionary) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik() or ime_lika == "":
		return
	_poslednje_stanje = {"inventory": inventory}
	_server_sacuvaj(false)

func server_sacuvaj_konacno() -> void:
	if not multiplayer.is_server():
		return
	await _server_sacuvaj(true)

func _server_sacuvaj(konacno: bool) -> void:
	if ime_lika == "" or _ucitano_stanje.is_empty():
		return
	if not konacno:
		var preostalo := _poslednje_snimanje_ms + SAVE_RAZMAK_MS - Time.get_ticks_msec()
		if preostalo > 0:
			if not _snimanje_zakazano:
				_snimanje_zakazano = true
				get_tree().create_timer(preostalo / 1000.0).timeout.connect(_zakazano_snimanje)
			return
	_snimanje_zakazano = false
	_poslednje_snimanje_ms = Time.get_ticks_msec()
	var s: Dictionary = _ucitano_stanje if _poslednje_stanje.is_empty() else _poslednje_stanje
	var pos := global_position
	var ime := ime_lika
	var ok: bool = await ApiManager.save_player(ime, {
		"hp": hp, "mana": mana,
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z,
		"inventory": s["inventory"], "equipment": oprema
	})
	if not ok:
		print("[SAVE] Snimanje nije uspelo za ", ime)

func _zakazano_snimanje() -> void:
	if _snimanje_zakazano:
		_snimanje_zakazano = false
		_server_sacuvaj(false)

# ---------------------------------------------------------------- OPREMA -> SERVER

# Server proverava vlasništvo pre bilo kakvog bonusa
func posjeduje(item_id: String) -> bool:
	return vlasnistvo.get(item_id, 0) > 0

func server_isplati_loot(item_ids: Array) -> void:
	if not multiplayer.is_server():
		return
	if ime_lika == "":
		print("[LOOT] Lik nije registrovan (ime_lika prazno), loot preskočen")
		return
	print("[LOOT] Isplata za ", ime_lika, ": ", item_ids)
	for item_id in item_ids:
		var r = await ApiManager.promeni_inventar(ime_lika, str(item_id), 1)
		if r.get("status", "") != "ok":
			print("[LOOT] Odbijeno za ", ime_lika, ": ", item_id, " (", r.get("error", "server nedostupan"), ")")
			continue
		dodaj_u_vlasnistvo(str(item_id), 1)
		print("[LOOT] ", ime_lika, " +", item_id)
		var vlasnik := get_multiplayer_authority()
		if vlasnik == multiplayer.get_unique_id():
			primi_loot(str(item_id), 1)
		else:
			primi_loot.rpc_id(vlasnik, str(item_id), 1)

# XP upisuje backend (/xp/change); server osvežava damage, klijent dobija nove statistike
func server_isplati_xp(xp: int, razlog: String) -> void:
	if not multiplayer.is_server():
		return
	if ime_lika == "":
		print("[XP] Lik nije registrovan (ime_lika prazno), XP preskočen")
		return
	var r = await ApiManager.promeni_xp(ime_lika, xp, razlog)
	if r.get("status", "") != "ok":
		print("[XP] Odbijeno za ", ime_lika, ": +", xp, " (", r.get("error", "server nedostupan"), ")")
		return
	server_primeni_stats(r)
	print("[XP] ", ime_lika, " +", xp, " -> Lv.", r.get("level", "?"), ", damage: ", izracunaj_damage())
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_stats(r)
	else:
		primi_stats.rpc_id(vlasnik, r)

# Server poziva ovo kad sam dodeli predmet (loot), pre slanja RPC-a klijentu
func dodaj_u_vlasnistvo(item_id: String, kolicina: int = 1) -> void:
	vlasnistvo[item_id] = vlasnistvo.get(item_id, 0) + kolicina
	_javi_predmet(item_id)
	if await _ab_dodaj(item_id):
		_ab_sacuvaj()

# ---------------------------------------------------------------- ZDRAVLJE (server)

# Backend je izračunao nove statistike (xp/change, quest turnin); server ih preuzima.
# Na level-up server sam puni hp i manu.
func server_primeni_stats(st: Dictionary) -> void:
	nivo_lika = int(st.get("level", nivo_lika))
	napad_damage = int(st.get("napad_damage", napad_damage))
	max_hp_osnovni = int(st.get("max_hp", max_hp_osnovni))
	max_hp = max_hp_osnovni + hp_bonus
	max_mana = int(st.get("max_mana", max_mana))
	if st.get("level_up", false):
		hp = max_hp
		mana = max_mana
	hp = mini(hp, max_hp)
	mana = mini(mana, max_mana)
	_posalji_hp()
	_javi_statistike()

# Regeneracija: 2 hp i 3 mane u sekundi, samo za žive i učitane igrače
func _process(delta: float) -> void:
	if not multiplayer.has_multiplayer_peer(): # posle prekida veze, do promene scene
		return
	if not multiplayer.is_server():
		if is_multiplayer_authority():
			_pomeri_vizuelno(delta)
			if _debug_seq and delta > 0.1:
				print("[SEQ-K] dugačak frame %d ms (seq %d)" % [int(delta * 1000), _seq])
		else:
			_interpoliraj(delta)
			_proveri_daljinu_nameplate()
	if _je_server:
		frame_max_ms = maxi(frame_max_ms, int(delta * 1000))
		if delta > 0.05: frame_dugih += 1
	if _debug_seq and multiplayer.is_server() and delta > 0.1 and _je_prvi_igrac():
		print("[SEQ-S] t=%d dugačak server frame %d ms" % [Time.get_ticks_msec(), int(delta * 1000)])
	if not multiplayer.is_server() or not _stanje_ucitano or mrtav:
		return
	if not _buffovi.is_empty():
		_proveri_istek_buffova()
	_regen_akum += delta
	if _regen_akum < 1.0:
		return
	_regen_akum -= 1.0
	# otrov (debuff): tick u istom ritmu kao regeneracija, pre nje, mimo oklopa
	var otrov := buff("otrov")
	if otrov > 0:
		hp = maxi(hp - otrov, 0)
		print("[OTROV] ", ime_lika, " -", otrov, " -> hp ", hp)
		if hp == 0:
			_server_umri()
			_posalji_hp()
			return
	if otrov > 0 or hp < max_hp or mana < max_mana:
		hp = mini(hp + HP_REGEN, max_hp)
		mana = mini(mana + MANA_REGEN, max_mana)
		_posalji_hp()

# Poziva Enemy na serveru. Šteta = max(1, šteta - oklop).
# Oklop smanjuje štetu za armor / (armor + K); K raste sa nivoom napadača, pa isti oklop vredi manje protiv jačih
# (nivo 1: K = 100, kao ranije). Jedino mesto za ove konstante.
const OKLOP_K := 100
const OKLOP_K_PO_NIVOU := 10

static func steta_posle_oklopa(sirova: int, oklop: int, nivo_napadaca: int) -> int:
	var k := OKLOP_K + OKLOP_K_PO_NIVOU * (maxi(nivo_napadaca, 1) - 1)
	return maxi(1, sirova * k / (k + oklop))

func server_primi_damage(sirova_steta: int, nivo_napadaca := 1) -> void:
	if not multiplayer.is_server() or not _stanje_ucitano or mrtav:
		return
	if Time.get_ticks_msec() < _neosjetljiv_do_ms:
		return
	var oklop := armor + buff("oklop")
	var steta := steta_posle_oklopa(sirova_steta, oklop, nivo_napadaca)
	hp = maxi(hp - steta, 0)
	print("[DMG] ", ime_lika, " -", steta, " (oklop ", oklop, ") -> hp ", hp)
	if hp == 0:
		_server_umri()
	_posalji_hp()

# Jedini punkt smrti (udarac: server_primi_damage, otrov: _process). Vaskrsenje se računa kao smrt: skida sve buffove i
# debuffove (i sam buff vaskrsenja), ali lik ostaje živ na istom mestu, mana ista, sa NEOSJETLJIVOST_MS; tabela pretnje
# neprijatelja se ne dira. Pozivalac posle šalje HP (_posalji_hp).
func _server_umri() -> void:
	var vaskrsenje := buff("vaskrsenje")
	if vaskrsenje > 0:
		_ocisti_buffove()
		hp = maxi(1, max_hp * vaskrsenje / 100)
		_neosjetljiv_do_ms = Time.get_ticks_msec() + NEOSJETLJIVOST_MS
		print("[VASKRSENJE] ", ime_lika, " -> hp ", hp, "/", max_hp)
		return
	mrtav = true
	_ocisti_buffove()
	print("[DEATH] ", ime_lika, " je poginuo, respawn za ", RESPAWN_DELAY, " s")
	await get_tree().create_timer(RESPAWN_DELAY).timeout
	if not is_instance_valid(self) or not mrtav or ime_lika == "":
		return # u međuvremenu se odjavio
	_server_respawn()

func _server_respawn() -> void:
	var svet := get_parent()
	var tacka := Vector3(0, 1, 0)
	if svet and svet.has_method("spawn_pozicija"):
		tacka = svet.spawn_pozicija()
	hp = max_hp
	mana = max_mana
	mrtav = false
	_neosjetljiv_do_ms = Time.get_ticks_msec() + NEOSJETLJIVOST_MS
	server_postavi_poziciju(tacka, true)
	_regen_akum = 0.0
	_posalji_hp()
	print("[RESPAWN] ", ime_lika, " -> ", tacka)

# Javi vlasniku trenutno stanje (klijent ga samo prikazuje)
func _posalji_hp() -> void:
	_sync_nameplate()
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_hp(hp, max_hp, mana, max_mana, mrtav)
	elif vlasnik in multiplayer.get_peers(): # vlasnik je možda već otišao (regeneracija dok server snima njegovu odjavu)
		primi_hp.rpc_id(vlasnik, hp, max_hp, mana, max_mana, mrtav)

# ---------------------------------------------------------------- OPREMA (server je autoritet)

# Podaci predmeta iz API-ja, jednom po predmetu (slot i statistike se ne menjaju dok server radi).
func _predmet(item_id: String) -> Dictionary:
	if not _predmeti.has(item_id):
		var item: Dictionary = await ApiManager.get_item(item_id)
		if item.is_empty() or item.has("error"):
			return {}
		_predmeti[item_id] = item
	return _predmeti[item_id]

# Statistike iz opreme (svi predmeti opreme su već u _predmeti): attack oružja, zbir armor-a i hp_bonus-a.
# Skidanje hp_bonus-a ograničava trenutni HP na novi maksimum.
func _preracunaj_statistike() -> void:
	bonus_oruzja = 0
	armor = 0
	hp_bonus = 0
	for slot in oprema:
		var item: Dictionary = _predmeti.get(oprema[slot], {})
		armor += int(item.get("armor", 0))
		hp_bonus += int(item.get("hp_bonus", 0))
		if slot == "weapon":
			bonus_oruzja = int(item.get("damage", 0))
	max_hp = max_hp_osnovni + hp_bonus
	hp = mini(hp, max_hp)
	print("[OPREMA] ", ime_lika, ": attack ", izracunaj_damage(), ", armor ", armor, ", max HP ", max_hp, " ", oprema)

func _javi_statistike() -> void:
	_odgovori(primi_statistike, {"attack": izracunaj_damage(), "armor": armor + buff("oklop"), "max_hp": max_hp})

@rpc("any_peer", "reliable")
func primi_statistike(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	stat_attack = int(d.get("attack", 0))
	stat_armor = int(d.get("armor", 0))
	stat_max_hp = int(d.get("max_hp", 0))
	statistike_promenjene.emit()

# ---------------------------------------------------------------- BUFFOVI (server je autoritet)

# Privremeni efekti potrošnih predmeta (items.buff_*, migracija 010). Samo u memoriji servera: smrt, odjava i restart
# ih brišu. Isti buff ponovo osvežava trajanje (vrednost se ne sabira); različiti važe istovremeno.
# Vrednost je procenat, osim oklopa (apsolutno). Klijent ne šalje buff: dobija ga samo kroz primi_buffove.
# protivotrov (antidote): skida otrov i ne da novi dok traje (vrednost bez značenja).
# nevidljivost: neprijatelji ne vide lik (Enemy: aggro i tabela pretnje), napad je prekida; ostali vide providan lik.
# vaskrsenje: smrtonosna šteta ostavlja lik živim na mestu sa vrednost % max HP-a (_server_umri).
const BUFF_TIPOVI := ["napad", "oklop", "xp", "loot", "brzina", "protivotrov", "nevidljivost", "vaskrsenje"]
# Debuffovi su u istom _buffovi (istek, smrt, odjava, primi_buffove), ali ih nijedan predmet ne daje.
# otrov: [šteta po sekundi, kraj]; nanosi ga neprijatelj (Enemy.otrov_*), osvežava trajanje bez sabiranja.
const DEBUFF_TIPOVI := ["otrov"]
signal buffovi_promenjeni # klijent: stiglo novo stanje buffova od servera
var _buffovi := {} # server: tip -> [vrednost, ms kad ističe]
var buffovi := {}  # klijent: tip -> [vrednost, lokalni ms kad ističe]

# Server: nevidljiv za neprijatelje (Enemy._dodaj_aggro, _ocisti_pretnju)
func nevidljiv() -> bool:
	return buff("nevidljivost") > 0

# Server: trenutna vrednost buff-a (0 ako ga nema ili je istekao)
func buff(tip: String) -> int:
	var b = _buffovi.get(tip)
	return int(b[0]) if b != null and Time.get_ticks_msec() < int(b[1]) else 0

func _dodaj_buff(tip: String, vrednost: int, trajanje_ms: int) -> void:
	_buffovi[tip] = [vrednost, Time.get_ticks_msec() + trajanje_ms]
	print("[BUFF] ", ime_lika, " ", tip, " +", vrednost, " ", trajanje_ms, " ms")
	if tip == "brzina":
		_zakazi_brzinu(vrednost, trajanje_ms)
	if tip == "protivotrov":
		_buffovi.erase("otrov")
	_buffovi_promenjeni()

# Server, zove Enemy posle udarca: mrtav, neosetljiv i lik pod protivotrovom se ne truju
func server_otruj(steta: int, trajanje_ms: int) -> void:
	if not multiplayer.is_server() or not _stanje_ucitano or mrtav or steta <= 0 or trajanje_ms <= 0:
		return
	if Time.get_ticks_msec() < _neosjetljiv_do_ms or buff("protivotrov") > 0:
		return
	_buffovi["otrov"] = [steta, Time.get_ticks_msec() + trajanje_ms]
	print("[OTROV] ", ime_lika, " otrovan ", steta, "/s ", trajanje_ms, " ms")
	_buffovi_promenjeni()

func _ocisti_buffove() -> void:
	if not _raspored_brzine.is_empty():
		_raspored_brzine.clear()
		_javi_raspored_brzine()
	if _buffovi.is_empty():
		return
	_buffovi.clear()
	_buffovi_promenjeni()

# Brzina (speed_potion) ne važi po satu, nego po seq-u unosa vlasnika: server zakaže [od, do) seq-ova unapred za procenjeni
# RTT i javi raspored vlasniku, a server, predikcija i replay simuliraju svaki unos brzinom za njegov seq. Varijanta "po
# satu" (server menja brzinu odmah, vlasnik kad stigne poruka) daje 0,3-0,4 m greške predikcije pri RTT 150-250 ms.
# Brzinu, trajanje i početak određuje samo server; _buffovi["brzina"] služi za HUD i istek po satu.
var _raspored_brzine: Array = [] # server i vlasnik: [[od_seq, do_seq, vrednost u %]]
const BRZINA_MARGINA_TIKOVA := 3  # rezerva preko procenjenog RTT-a (jitter, frame u kom stiže raspored)

func _brzina_za_seq(seq: int) -> float:
	return BRZINA * (100 + _buff_brzine_za_seq(seq)) / 100.0

func _buff_brzine_za_seq(seq: int) -> int:
	for x in _raspored_brzine:
		if seq >= int(x[0]) and seq < int(x[1]):
			return int(x[2])
	return 0

# Vlasnik: rezerva kad raspored kasni ili ne stigne. Stanje nosi buff brzine kojim je server obradio potvrđeni unos;
# ako se ne slaže sa rasporedom za taj seq, nepotvrđeni unosi idu brzinom potvrđenog (inače bi se predikcija razilazila
# svaki drugi tick do kraja buff-a: izmereno 181 korekcija za izgubljen raspored, 9 za raspored koji kasni 500 ms; sa
# rezervom po 1).
var _buff_ack := 0          # buff brzine potvrđenog unosa (iz primi_stanje)
var _raspored_kasni := false

func _brzina_vlasnik(seq: int) -> float:
	return BRZINA * (100 + _buff_ack) / 100.0 if _raspored_kasni else _brzina_za_seq(seq)

func _zakazi_brzinu(vrednost: int, trajanje_ms: int) -> void:
	vrednost = clampi(vrednost, 0, BRZINA_BUFF_MAX)
	var tps := Engine.physics_ticks_per_second
	var najnoviji: int = _red[-1][0] if not _red.is_empty() else _poslednji_seq # vlasnik je već poslao bar ovoliko
	var od := najnoviji + ceili(_rtt_ms() * tps / 1000.0) + BRZINA_MARGINA_TIKOVA
	var do_ := od + ceili(trajanje_ms * tps / 1000.0)
	_raspored_brzine = _raspored_brzine.filter(func(x): return int(x[1]) > _poslednji_seq)
	# osvežavanje: aktivan interval (kraj posle najnovijeg primljenog unosa) se produžava, bez rupe sporog hoda između
	# starog kraja i novog početka. Ako zahtev stigne u poslednjem RTT-u pre kraja, vlasnik saznaje kasno i dobije jednu
	# glatku korekciju (najviše RTT * razlika brzina), umesto rupe koju bi video i on i server.
	if not _raspored_brzine.is_empty() and int(_raspored_brzine[-1][1]) > najnoviji and int(_raspored_brzine[-1][2]) == vrednost:
		_raspored_brzine[-1][1] = maxi(int(_raspored_brzine[-1][1]), do_)
	else:
		_raspored_brzine.append([od, do_, vrednost])
	print("[BUFF] ", ime_lika, " brzina po seq-u ", _raspored_brzine, " (najnoviji ", najnoviji, ", rtt ", _rtt_ms(), " ms)")
	_javi_raspored_brzine()

func _javi_raspored_brzine() -> void:
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_raspored_brzine(_raspored_brzine)
	elif vlasnik in multiplayer.get_peers():
		primi_raspored_brzine.rpc_id(vlasnik, _raspored_brzine)

# samo od servera: klijent ne može da postavi brzinu (ni sebi preko servera, ni serveru)
@rpc("any_peer", "reliable")
func primi_raspored_brzine(lista: Array) -> void:
	if not _poziv_od_servera():
		return
	if _t_kasni_ulaz(primi_raspored_brzine.bind(lista)):
		return
	if test_raspored_brzine == "izgubi":
		test_raspored_brzine = ""
		return
	if test_raspored_brzine.begins_with("kasni:"):
		var n := int(test_raspored_brzine.substr(6))
		test_raspored_brzine = ""
		await get_tree().create_timer(n / 1000.0).timeout
	_raspored_brzine = lista.duplicate(true)

# RTT za zakazivanje: server šalje vlasniku ping, vlasnik vraća isti broj (ceo krug, sa frame-ovima obe strane).
# Procena je 75. percentil poslednjih PING_UZORAKA, bez uzoraka iz prvih PING_ZAGREVANJE_MS posle učitavanja lika: klijent
# tada učitava scenu i odgovara sa zakašnjenjem (izmereno 333-532 ms pri RTT 150-250), pa je prvi napitak kasnio
# 250-300 ms više od narednih. Dok nema uzoraka: ENet RTT (pravo mrežno kašnjenje, bez frame-ova).
const PING_RAZMAK_MS := 250
const PING_UZORAKA := 12
const PING_ZAGREVANJE_MS := 2000
var _ping_ms := 0
var _rtt_uzorci: Array = []

func _rtt_ms() -> int:
	if _rtt_uzorci.is_empty():
		var mp := multiplayer.multiplayer_peer
		var p = mp.get_peer(get_multiplayer_authority()) if mp is ENetMultiplayerPeer else null
		return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)) if p != null else 0
	var u := _rtt_uzorci.duplicate()
	u.sort()
	return u[mini(u.size() - 1, (u.size() * 3) / 4)]

@rpc("any_peer", "unreliable_ordered")
func ping_brzine(t_ms: int) -> void:
	if not _poziv_od_servera():
		return
	if _t_kasni_ulaz(ping_brzine.bind(t_ms)):
		return
	_t_posalji(func(): pong_brzine.rpc_id(1, t_ms))

@rpc("any_peer", "unreliable_ordered")
func pong_brzine(t_ms: int) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	if _ucitan_ms < 0 or t_ms - _ucitan_ms < PING_ZAGREVANJE_MS:
		return # klijent još učitava scenu: odgovor kasni zbog frame-ova, ne mreže
	_rtt_uzorci.append(Time.get_ticks_msec() - t_ms)
	if _rtt_uzorci.size() > PING_UZORAKA:
		_rtt_uzorci.pop_front()

func _proveri_istek_buffova() -> void:
	var sada := Time.get_ticks_msec()
	var istekli := _buffovi.keys().filter(func(tip): return sada >= int(_buffovi[tip][1]))
	if istekli.is_empty():
		return
	for tip in istekli:
		_buffovi.erase(tip)
		print("[BUFF] ", ime_lika, " ", tip, " istekao")
	_buffovi_promenjeni()

# Vlasniku ide preostalo vreme (ne apsolutno: satovi servera i klijenta se razlikuju); napad i oklop menjaju statistike
func _buffovi_promenjeni() -> void:
	nevidljiv_sync = nevidljiv()
	var sada := Time.get_ticks_msec()
	var d := {}
	for tip in _buffovi:
		d[tip] = [int(_buffovi[tip][0]), maxi(0, int(_buffovi[tip][1]) - sada)]
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_buffove(d)
	elif vlasnik in multiplayer.get_peers(): # vlasnik je možda otišao (istek dok server snima odjavu)
		primi_buffove.rpc_id(vlasnik, d)
	else:
		return
	_javi_statistike()

@rpc("any_peer", "reliable")
func primi_buffove(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	var sada := Time.get_ticks_msec()
	buffovi = {}
	for tip in d:
		buffovi[str(tip)] = [int(d[tip][0]), sada + int(d[tip][1])]
	buffovi_promenjeni.emit()

# Tekst efekta za HUD, tooltip i poruku (engleski ključevi kroz tr())
static func opis_buffa(tip: String, vrednost: int) -> String:
	match tip:
		"napad": return TranslationServer.translate("Attack +%d%%") % vrednost
		"oklop": return TranslationServer.translate("Armor +%d") % vrednost
		"xp": return TranslationServer.translate("XP +%d%%") % vrednost
		"loot": return TranslationServer.translate("Loot chance +%d%%") % vrednost
		"brzina": return TranslationServer.translate("Speed +%d%%") % vrednost
		"protivotrov": return TranslationServer.translate("Poison immunity")
		"otrov": return TranslationServer.translate("Poisoned -%d HP/s") % vrednost
		"nevidljivost": return TranslationServer.translate("Invisible")
		"vaskrsenje": return TranslationServer.translate("Resurrection %d%% HP") % vrednost
	return ""

# Klijent: zahtev za opremanje (item_id) ili skidanje ("") predmeta u slotu; čeka odgovor servera.
func opremi_na_serveru(slot: String, item_id: String) -> Dictionary:
	return await _posalji_i_cekaj("oprema", oprema_odgovor, zatrazi_opremanje, [slot, item_id])

@rpc("any_peer", "reliable")
func zatrazi_opremanje(slot: String, item_id: String) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	var d := await _opremi(slot, item_id)
	if d.get("ok", false):
		_javi_statistike()
		_posalji_hp()
		_server_sacuvaj(false)
	else:
		print("[OPREMA] ", ime_lika, " odbijeno ", slot, "/", item_id, ": ", d.get("poruka", ""))
	_odgovori(odgovor_oprema, d)

# Proverava zahtev i menja opremu; inventar za snimanje prati promenu (isti broj komada kao kod klijenta posle
# poteza), pa raspored koji klijent pošalje posle toga backend prihvata.
func _opremi(slot: String, item_id: String) -> Dictionary:
	var greska := _greska_opreme(slot, item_id)
	if greska == "" and item_id != "":
		_oprema_u_toku = true
		var item := await _predmet(item_id)
		_oprema_u_toku = false
		greska = _greska_opreme(slot, item_id) # stanje je moglo da se promeni dok se čekao API
		if greska == "" and str(item.get("slot", "")) != slot:
			greska = "Can't be equipped" if item.get("slot") == null else "Can't be equipped in that slot"
	if greska != "":
		return {"ok": false, "poruka": greska, "oprema": oprema.duplicate()}
	var inventar: Array = _inv_za_snimanje()
	var staro: String = oprema.get(slot, "")
	if item_id == "":
		oprema.erase(slot)
	else:
		oprema[slot] = item_id
		_inv_uzmi(inventar, item_id)
	if staro != "":
		_inv_vrati(inventar, staro)
	_preracunaj_statistike()
	return {"ok": true, "oprema": oprema.duplicate()}

func _greska_opreme(slot: String, item_id: String) -> String:
	if not _stanje_ucitano:
		return "Character not registered"
	if mrtav:
		return "You are dead"
	if _oprema_u_toku:
		return "Request in progress"
	if not slot in SLOTOVI_OPREME:
		return "Can't be equipped in that slot"
	if item_id == "":
		if not oprema.has(slot):
			return "Nothing equipped"
		return "Inventory full" if _inv_za_snimanje().size() >= MAX_SLOTOVA_INVENTARA else ""
	if not posjeduje(item_id):
		return "You don't have that item"
	if oprema.values().count(item_id) >= int(vlasnistvo.get(item_id, 0)):
		return "Already equipped" # svi komadi tog predmeta su već opremljeni
	return ""

@rpc("any_peer", "reliable")
func odgovor_oprema(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	oprema_odgovor.emit(d)

func _inv_za_snimanje() -> Array:
	var s: Dictionary = _ucitano_stanje if _poslednje_stanje.is_empty() else _poslednje_stanje
	return s.get("inventory", [])

# Jedan komad predmeta iz inventara (opremljen je).
func _inv_uzmi(inventar: Array, item_id: String) -> void:
	for i in inventar.size():
		if str(inventar[i].get("id", "")) == item_id:
			if int(inventar[i].get("kolicina", 1)) > 1:
				inventar[i]["kolicina"] = int(inventar[i]["kolicina"]) - 1
			else:
				inventar.remove_at(i)
			return

# Skinut predmet ide u prvi slobodan slot inventara.
func _int_unos(e) -> Dictionary:
	var u: Dictionary = e.duplicate() if e is Dictionary else {}
	for k in ["slot", "kolicina"]:
		if u.has(k) and (u[k] is float or u[k] is int):
			u[k] = int(u[k])
	return u

func _inv_vrati(inventar: Array, item_id: String) -> void:
	var zauzeti := inventar.map(func(e): return int(e.get("slot", -1)))
	for i in MAX_SLOTOVA_INVENTARA:
		if not i in zauzeti:
			inventar.append({"slot": i, "id": item_id, "kolicina": 1})
			return

# ---------------------------------------------------------------- KUPOVINA I QUESTOVI KROZ SERVER

signal kupovina_odgovor(odgovor: Dictionary)
signal quest_prihvat_odgovor(odgovor: Dictionary)
signal quest_predaja_odgovor(odgovor: Dictionary)
signal item_odgovor(odgovor: Dictionary)

const ZAHTEV_TIMEOUT_MS := 8000
var _zahtevi_u_toku: Dictionary = {}  # klijent: tip -> true dok čeka odgovor
var _server_zauzet: Dictionary = {}   # server: tip -> true dok se izvršava
var _item_cd_do_ms: Dictionary = {}   # server: item_id -> kad predmet ponovo sme da se koristi

func skini_iz_vlasnistva(item_id: String, kolicina: int = 1) -> void:
	var ostalo: int = vlasnistvo.get(item_id, 0) - kolicina
	if ostalo <= 0:
		vlasnistvo.erase(item_id)
	else:
		vlasnistvo[item_id] = ostalo
	_javi_predmet(item_id)

# --- stanje predmeta za vlasnika (action bar): količina i preostali cooldown po serveru

signal predmet_promenjen(item_id: String) # klijent: stiglo novo stanje predmeta od servera
var kolicine: Dictionary = {}  # klijent: item_id -> količina po serveru
var cd_do_ms: Dictionary = {}  # klijent: item_id -> lokalni ms kad cooldown ističe (preostalo po serveru)

func _javi_predmet(item_id: String) -> void:
	if not multiplayer.is_server() or not _stanje_ucitano:
		return
	var n: int = vlasnistvo.get(item_id, 0)
	var cd := maxi(0, int(_item_cd_do_ms.get(item_id, 0)) - Time.get_ticks_msec())
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_predmet(item_id, n, cd)
	else:
		primi_predmet.rpc_id(vlasnik, item_id, n, cd)

@rpc("any_peer", "reliable")
func primi_predmet(item_id: String, kolicina: int, cd_ms: int) -> void:
	if not _poziv_od_servera():
		return
	kolicine[item_id] = kolicina
	cd_do_ms[item_id] = Time.get_ticks_msec() + cd_ms
	predmet_promenjen.emit(item_id)

# --- action bar: raspored po liku (10 slotova, item_id ili ""). Drži ga server, klijent samo prikazuje i traži izmenu.

const BROJ_SLOTOVA_BARA := 10
signal action_bar_promenjen # klijent: stigao raspored od servera (i kad je zahtev odbijen)
var action_bar: Array = []  # indeks 0 = slot 1; server: izvor istine (prazno dok lik nije učitan), klijent: kopija
var _ab_upis_u_toku := false
var _ab_prljav := false

# Server, pri učitavanju: sačuvan raspored iz baze; lik bez rasporeda dobija potrošne predmete redom iz inventara.
# Vraća da li je raspored bio sačuvan.
func _ucitaj_action_bar(sacuvan, inventory: Array) -> bool:
	action_bar.resize(BROJ_SLOTOVA_BARA)
	action_bar.fill("")
	if sacuvan is Array:
		for i in mini(sacuvan.size(), BROJ_SLOTOVA_BARA):
			action_bar[i] = "" if sacuvan[i] == null else str(sacuvan[i])
		return true
	for e in inventory: # redom, da raspored prati redosled inventara
		await _ab_dodaj(str(e.get("id", "")))
	return false

# Novi potrošni predmet ide u prvi prazan slot. Predmet koji već ima slot ostaje u njemu (i sa 0 komada).
func _ab_dodaj(item_id: String) -> bool:
	if item_id == "" or action_bar.has(item_id) or not action_bar.has(""):
		return false
	var item: Dictionary = await ApiManager.get_item(item_id)
	if str(item.get("tip", "")) != "consumable" or action_bar.has(item_id) or not action_bar.has(""):
		return false
	action_bar[action_bar.find("")] = item_id
	return true

# Javi vlasniku pa upiši u bazu. Jedan upis u letu; promena za vreme upisa ide posle (poslednji raspored pobeđuje).
func _ab_sacuvaj() -> void:
	_javi_action_bar()
	_ab_prljav = true
	if _ab_upis_u_toku:
		return
	_ab_upis_u_toku = true
	var ime := ime_lika
	while _ab_prljav:
		_ab_prljav = false
		var slotovi := action_bar.map(func(id): return null if id == "" else id)
		if not await ApiManager.sacuvaj_action_bar(ime, slotovi):
			print("[ACTION BAR] Upis nije uspeo za ", ime)
	_ab_upis_u_toku = false

func _javi_action_bar() -> void:
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_action_bar(action_bar)
	else:
		primi_action_bar.rpc_id(vlasnik, action_bar)

@rpc("any_peer", "reliable")
func primi_action_bar(slotovi: Array) -> void:
	if not _poziv_od_servera():
		return
	action_bar = slotovi.duplicate()
	action_bar_promenjen.emit()

# Klijent: zahtev da slot (1-10) drži item_id ("" = isprazni). Server odlučuje i uvek vrati raspored.
func promeni_action_slot(slot: int, item_id: String) -> void:
	if multiplayer.is_server():
		zatrazi_action_slot(slot, item_id)
	else:
		zatrazi_action_slot.rpc_id(1, slot, item_id)

@rpc("any_peer", "reliable")
func zatrazi_action_slot(slot: int, item_id: String) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik() or not _stanje_ucitano:
		return
	var ok := slot >= 1 and slot <= BROJ_SLOTOVA_BARA
	if ok and item_id != "": # predmet postoji (isti id i u odgovoru: id nije deo neke druge putanje), potrošni je i lik ga
		# ima ili je već na traci (premeštanje predmeta sa 0 komada)
		var item: Dictionary = await ApiManager.get_item(item_id)
		ok = str(item.get("id", "")) == item_id and str(item.get("tip", "")) == "consumable" \
			and (posjeduje(item_id) or action_bar.has(item_id))
	if not ok:
		print("[ACTION BAR] Odbijeno za ", ime_lika, ": slot ", slot, " = '", item_id, "'")
		_javi_action_bar()
		return
	var staro := action_bar.find(item_id) # predmet je u najviše jednom slotu: premešta se
	if item_id != "" and staro >= 0:
		action_bar[staro] = ""
	action_bar[slot - 1] = item_id
	_ab_sacuvaj()

# Klijent: zamena mesta dva slota (1-10; prazan slot = premeštanje). Jedan zahtev, pa i jedan raspored nazad (bez međustanja).
func zameni_action_slotove(a: int, b: int) -> void:
	if multiplayer.is_server():
		zatrazi_zamenu_action_slotova(a, b)
	else:
		zatrazi_zamenu_action_slotova.rpc_id(1, a, b)

@rpc("any_peer", "reliable")
func zatrazi_zamenu_action_slotova(a: int, b: int) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik() or not _stanje_ucitano:
		return
	if a < 1 or a > BROJ_SLOTOVA_BARA or b < 1 or b > BROJ_SLOTOVA_BARA or a == b:
		print("[ACTION BAR] Zamena odbijena za ", ime_lika, ": ", a, " <-> ", b)
		_javi_action_bar()
		return
	var x: String = action_bar[a - 1]
	action_bar[a - 1] = action_bar[b - 1]
	action_bar[b - 1] = x
	_ab_sacuvaj()

# --- klijent (zovu UI-ji)

func kupi_na_serveru(item_id: String) -> Dictionary:
	return await _posalji_i_cekaj("kupovina", kupovina_odgovor, zatrazi_kupovinu, item_id)

func prihvati_quest_na_serveru(quest_id: String) -> Dictionary:
	return await _posalji_i_cekaj("prihvat", quest_prihvat_odgovor, zatrazi_prihvat_questa, quest_id)

func predaj_quest_na_serveru(quest_id: String) -> Dictionary:
	return await _posalji_i_cekaj("predaja", quest_predaja_odgovor, zatrazi_predaju_questa, quest_id)

func koristi_item_na_serveru(item_id: String) -> Dictionary:
	return await _posalji_i_cekaj("item", item_odgovor, zatrazi_koriscenje_itema, item_id)

func odustani_quest_na_serveru() -> void:
	if multiplayer.is_server():
		zatrazi_odustajanje()
	else:
		zatrazi_odustajanje.rpc_id(1)

# Pošalje zahtev serveru (host: direktan poziv) i čeka signal odgovora, najviše 8 s.
# Kasni odgovor posle timeouta nema više slušaoca, pa se ignoriše.
func _posalji_i_cekaj(tip: String, odgovor_signal: Signal, zahtev: Callable, arg) -> Dictionary:
	var args: Array = arg if arg is Array else [arg]
	if _zahtevi_u_toku.get(tip, false):
		return {"ok": false, "poruka": "Request in progress"}
	_zahtevi_u_toku[tip] = true
	var stanje := {"odgovor": null}
	var primi := func(d: Dictionary): stanje.odgovor = d
	odgovor_signal.connect(primi)
	if multiplayer.is_server():
		zahtev.callv(args)
	else:
		callv("rpc_id", [1, zahtev.get_method()] + args)
	var rok := Time.get_ticks_msec() + ZAHTEV_TIMEOUT_MS
	while stanje.odgovor == null and Time.get_ticks_msec() < rok:
		await get_tree().process_frame
	odgovor_signal.disconnect(primi)
	_zahtevi_u_toku.erase(tip)
	if stanje.odgovor == null:
		return {"ok": false, "poruka": "Server not responding"}
	return stanje.odgovor

# --- server

func _posiljalac_je_vlasnik() -> bool:
	var posiljalac := multiplayer.get_remote_sender_id()
	return posiljalac == 0 or posiljalac == get_multiplayer_authority()

# Odgovor vlasniku lika; ako je vlasnik sam server, poziv je lokalan (emituje signal).
func _odgovori(odgovor: Callable, d: Dictionary) -> void:
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		odgovor.call(d)
	else:
		odgovor.rpc_id(vlasnik, d)

# Zajedničke provere za zahteve; vraća poruku greške ili "" ako sme da se izvrši.
func _greska_zahteva(tip: String) -> String:
	if ime_lika == "":
		return "Character not registered"
	if _server_zauzet.get(tip, false):
		return "Request in progress"
	return ""

func _neuspeh(r: Dictionary) -> Dictionary:
	return {"ok": false, "poruka": str(r.get("error", "Server unavailable"))}

@rpc("any_peer", "reliable")
func zatrazi_kupovinu(item_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _posiljalac_je_vlasnik():
		return
	var greska := _greska_zahteva("kupovina")
	if greska != "":
		_odgovori(odgovor_kupovina, {"ok": false, "poruka": greska})
		return
	if Config.VAN_PRODAVNICE.has(item_id):
		print("[SHOP] Odbijeno za ", ime_lika, ": ", item_id, " (nije u prodavnici)")
		_odgovori(odgovor_kupovina, {"ok": false, "poruka": "Item not for sale"})
		return
	_server_zauzet["kupovina"] = true
	var r: Dictionary = await ApiManager.kupi_item(ime_lika, item_id)
	_server_zauzet.erase("kupovina")
	if r.get("status", "") != "ok":
		print("[SHOP] Odbijeno za ", ime_lika, ": ", item_id, " (", r.get("error", "server nedostupan"), ")")
		_odgovori(odgovor_kupovina, _neuspeh(r))
		return
	dodaj_u_vlasnistvo(item_id, 1)
	print("[SHOP] ", ime_lika, " kupio ", item_id)
	_odgovori(odgovor_kupovina, {"ok": true, "gold": r.get("gold", 0), "item_id": item_id})

@rpc("any_peer", "reliable")
func zatrazi_prihvat_questa(quest_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _posiljalac_je_vlasnik():
		return
	var greska := _greska_zahteva("prihvat")
	if greska != "":
		_odgovori(odgovor_prihvat, {"ok": false, "poruka": greska})
		return
	_server_zauzet["prihvat"] = true
	var r: Dictionary = await ApiManager.prihvati_quest_server(ime_lika, quest_id)
	_server_zauzet.erase("prihvat")
	var ok: bool = r.get("status", "") == "ok"
	_odgovori(odgovor_prihvat, {
		"ok": ok,
		"quest": r.get("quest", {}),
		"poruka": "" if ok else str(r.get("error", "Server unavailable"))
	})

@rpc("any_peer", "reliable")
func zatrazi_predaju_questa(quest_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _posiljalac_je_vlasnik():
		return
	var greska := _greska_zahteva("predaja")
	if greska != "":
		_odgovori(odgovor_predaja, {"ok": false, "poruka": greska})
		return
	_server_zauzet["predaja"] = true
	var r: Dictionary = await ApiManager.predaj_quest_server(ime_lika, quest_id)
	_server_zauzet.erase("predaja")
	if r.get("status", "") != "ok":
		print("[QUEST] Predaja odbijena za ", ime_lika, ": ", quest_id, " (", r.get("error", "server nedostupan"), ")")
		_odgovori(odgovor_predaja, _neuspeh(r))
		return
	var quest: Dictionary = r.get("quest", {})
	var nagrada: Dictionary = r.get("nagrada", {})
	if str(quest.get("tip", "")) == "fetch":
		skini_iz_vlasnistva(str(quest.get("cilj", "")), int(quest.get("kolicina", 1)))
	var nagrada_item = nagrada.get("item")
	if nagrada_item != null and str(nagrada_item) != "":
		dodaj_u_vlasnistvo(str(nagrada_item), 1)
	print("[QUEST] ", ime_lika, " predao ", quest_id)
	var stats: Dictionary = r.get("stats", {})
	if not stats.is_empty():
		server_primeni_stats(stats)
	_odgovori(odgovor_predaja, {"ok": true, "nagrada": nagrada, "gold": r.get("gold", 0), "quest": quest, "stats": stats})

@rpc("any_peer", "reliable")
func zatrazi_odustajanje() -> void:
	if not multiplayer.is_server():
		return
	if not _posiljalac_je_vlasnik():
		return
	if _greska_zahteva("odustajanje") != "":
		return
	_server_zauzet["odustajanje"] = true
	await ApiManager.odustani_quest_server(ime_lika)
	_server_zauzet.erase("odustajanje")

# Potrošni predmet: server proverava sve pre trošenja, backend skida komad, server primenjuje efekat.
# _server_zauzet["item"]: dva istovremena zahteva troše najviše jedan komad.
@rpc("any_peer", "reliable")
func zatrazi_koriscenje_itema(item_id: String) -> void:
	if not multiplayer.is_server():
		return
	if not _posiljalac_je_vlasnik():
		return
	var greska := _greska_zahteva("item")
	if greska == "":
		greska = _greska_itema(item_id)
	if greska != "":
		_javi_predmet(item_id)
		_odgovori(odgovor_item, {"ok": false, "poruka": greska})
		return
	_server_zauzet["item"] = true
	var d := await _iskoristi_item(item_id)
	_server_zauzet.erase("item")
	_javi_predmet(item_id) # cooldown je postavljen tek posle skidanja komada
	_odgovori(odgovor_item, d)

func _greska_itema(item_id: String) -> String:
	if not _stanje_ucitano:
		return "Character not registered"
	if mrtav:
		return "You are dead"
	if not posjeduje(item_id):
		return "You don't have that item"
	if Time.get_ticks_msec() < _item_cd_do_ms.get(item_id, 0):
		return "Not ready yet"
	return ""

func _iskoristi_item(item_id: String) -> Dictionary:
	var item: Dictionary = await ApiManager.get_item(item_id)
	var hp_e := int(item.get("hp_efekat", 0))
	var mana_e := int(item.get("mana_efekat", 0))
	var buff_tip = item.get("buff_tip") # null pre migracije 010 i za predmete bez buff-a
	var je_buff: bool = buff_tip is String and BUFF_TIPOVI.has(buff_tip)
	if item.is_empty() or item.has("error") or str(item.get("tip", "")) != "consumable" or (hp_e + mana_e <= 0 and not je_buff):
		return {"ok": false, "poruka": "This item can't be used"}
	if mrtav:
		return {"ok": false, "poruka": "You are dead"}
	if not je_buff and not ((hp_e > 0 and hp < max_hp) or (mana_e > 0 and mana < max_mana)):
		return {"ok": false, "poruka": "Already at full health" if hp_e > 0 else "Already at full mana"}
	var ime := ime_lika
	var r: Dictionary = await ApiManager.koristi_item(ime, item_id)
	if r.get("status", "") != "ok":
		print("[ITEM] Odbijeno za ", ime, ": ", item_id, " (", r.get("error", "server nedostupan"), ")")
		return _neuspeh(r)
	skini_iz_vlasnistva(item_id, 1)
	hp_e = int(r.get("hp_efekat", hp_e))
	mana_e = int(r.get("mana_efekat", mana_e))
	var cd := int(r.get("cooldown_ms", 0))
	_item_cd_do_ms[item_id] = Time.get_ticks_msec() + cd
	# raspored za snimanje prati bazu, da save sa starim brojem komada ne bude odbijen
	var s: Dictionary = _ucitano_stanje if _poslednje_stanje.is_empty() else _poslednje_stanje
	if r.has("inventory") and not s.is_empty():
		s["inventory"] = r["inventory"].map(_int_unos) # JSON: brojevi kao float, /save traži int
	# buff po backend-u (izvor istine je baza), samo poznat tip
	var bt = r.get("buff_tip")
	var bv := int(r.get("buff_vrednost", 0))
	var btr := int(r.get("buff_trajanje_ms", 0))
	if not (bt is String and BUFF_TIPOVI.has(bt) and btr > 0):
		bt = null
	if not mrtav: # poginuo dok smo čekali backend: komad je potrošen, efekta nema
		hp = mini(hp + hp_e, max_hp)
		mana = mini(mana + mana_e, max_mana)
		_posalji_hp()
		if bt != null:
			_dodaj_buff(bt, bv, btr)
	print("[ITEM] ", ime, " koristio ", item_id, " -> hp ", hp, ", mana ", mana)
	return {"ok": true, "item_id": item_id, "hp_efekat": hp_e, "mana_efekat": mana_e, "cooldown_ms": cd,
		"buff_tip": bt if bt != null else "", "buff_vrednost": bv, "buff_trajanje_ms": btr}

# Enemy poziva na serveru za svakog napadača kad neprijatelj umre
func server_zabelezi_kill(tip: String) -> void:
	if not multiplayer.is_server() or ime_lika == "":
		return
	await ApiManager.zabelezi_kill_server(ime_lika, tip)

# --- odgovori ka klijentu

@rpc("any_peer", "reliable")
func odgovor_kupovina(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	kupovina_odgovor.emit(d)

@rpc("any_peer", "reliable")
func odgovor_prihvat(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	quest_prihvat_odgovor.emit(d)

@rpc("any_peer", "reliable")
func odgovor_predaja(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	quest_predaja_odgovor.emit(d)

@rpc("any_peer", "reliable")
func odgovor_item(d: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	item_odgovor.emit(d)

func _input(event):
	if not is_multiplayer_authority():
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			rotacija_misa = event.pressed
			if rotacija_misa:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zumiraj(-1)
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zumiraj(1)

	if event is InputEventMouseMotion and rotacija_misa:
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		# pitch se čuva kao broj i ograničava pre primene; rotate_x + clamp Ojlerovog ugla na kameri koja ima yaw/roll iz
		# scene nije reverzibilan na granici i ostavljao je yaw/roll (kamera "pod čudnim uglom" posle first person-a)
		_pitch = clampf(_pitch + deg_to_rad(-event.relative.y * mouse_sensitivity), deg_to_rad(-60), deg_to_rad(60))
		kamera.rotation = Vector3(_pitch, _kamera_rot0.y, _kamera_rot0.z)

# Zum u koracima od početnog offseta iz scene, pa se odzumiranjem vraća tačno na njega (koraci od min/max ne bi);
# z <= 0.1 je first person (model skriven).
func _zumiraj(smer: int) -> void:
	var k_min := floori((min_zum - _kamera_z0) / zum_brzina)
	var k_max := ceili((max_zum - _kamera_z0) / zum_brzina)
	_zum_korak = clampi(_zum_korak + smer, k_min, k_max)
	_kamera_poz.z = clampf(_kamera_z0 + _zum_korak * zum_brzina, min_zum, max_zum)
	$CharacterMain.visible = _kamera_poz.z > 0.1

# ---------------------------------------------------------------- CILJ (klik na neprijatelja)
# Cilj drži server po igraču (čvor ovog igrača, pa nestaje sa odjavom) i javlja ga samo vlasniku; ne replicira se.
# ID neprijatelja = ime njegovog čvora u World-u (npr. "goblin_3", jedinstveno po spawn-u).

const MAX_DOMET_CILJA := 30.0  # m, od SERVER pozicije igrača
const HISTEREZA_CILJA := 2.0   # m preko dometa pre nego što se cilj izgubi (da ne treperi na granici)
const DOMET_KLIKA := 200.0     # m, dužina zraka iz kamere (domet izbora proverava server)
signal cilj_promenjen          # klijent: server javio cilj (i kad je zahtev odbijen)
var cilj_id := ""              # klijent: cilj po serveru, "" = nema
var cilj_pretnja := -1         # klijent: moja pretnja kod cilja kao % pretnje njegove mete, -1 = nemam pretnju
var cilj_ja_meta := false      # klijent: ja sam meta cilja
var _cilj_srv := ""            # server: cilj ovog igrača
var _pretnja_poslata := -1     # server: poslednji procenat poslat vlasniku

func neprijatelj_po_id(id: String) -> Node:
	for e in get_tree().get_nodes_in_group("neprijatelj"):
		if str(e.get_parent().name) == id:
			return e
	return null

# Levi klik u sceni bira neprijatelja pod mišem ili skida cilj (klik na prazno); ne napada. Klik na NPC-a razgovara sa njim
# (kao F, ako je lik u njegovom dometu) i ne menja cilj. R napada cilj. Klik i taster preko UI-ja ovde ne stižu (UI ih
# potroši). Esc skida cilj; otvoren dijalog/trgovac ga potroši pre ovoga.
func _unhandled_input(event: InputEvent) -> void:
	if not is_multiplayer_authority():
		return
	var klik: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	if not multiplayer.has_multiplayer_peer():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		napadni()
		return
	var id := cilj_id
	if klik:
		var pod = _pod_misem(event.position)
		if pod and pod.is_in_group("npc"):
			pod.klik()
			return
		id = str(pod.get_parent().name) if pod and pod.is_in_group("neprijatelj") else ""
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		id = ""
	if id != cilj_id:
		izaberi_cilj(id)

func _pod_misem(poz: Vector2) -> Object:
	var od: Vector3 = kamera.project_ray_origin(poz)
	var upit := PhysicsRayQueryParameters3D.create(od, od + kamera.project_ray_normal(poz) * DOMET_KLIKA)
	upit.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(upit).get("collider")

# Klijent: zahtev serveru ("" = skini cilj). Server odlučuje i uvek vrati trenutni cilj.
func izaberi_cilj(id: String) -> void:
	if multiplayer.is_server():
		zatrazi_cilj(id)
	else:
		zatrazi_cilj.rpc_id(1, id)

@rpc("any_peer", "reliable")
func zatrazi_cilj(id: String) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	if id != "":
		var e := neprijatelj_po_id(id)
		if e == null or e._mrtav or global_position.distance_to(e.global_position) > MAX_DOMET_CILJA:
			print("[CILJ] Odbijeno za ", ime_lika, ": ", id)
			id = _cilj_srv
	_cilj_srv = id
	_javi_cilj()

# Server, svaki tick: cilj koji je umro, nestao ili otišao preko dometa + histereze se skida.
func _server_proveri_cilj() -> void:
	if _cilj_srv == "":
		return
	var e := neprijatelj_po_id(_cilj_srv)
	if e == null or e._mrtav or global_position.distance_to(e.global_position) > MAX_DOMET_CILJA + HISTEREZA_CILJA:
		_cilj_srv = ""
		_javi_cilj()
	elif e.pretnja_procenat(get_multiplayer_authority()) != _pretnja_poslata:
		_javi_cilj()

# Vlasniku: cilj i samo njegova pretnja kod cilja (procenat i da li je meta), bez tuđe pretnje.
func _javi_cilj() -> void:
	var vlasnik := get_multiplayer_authority()
	var e := neprijatelj_po_id(_cilj_srv) if _cilj_srv != "" else null
	_pretnja_poslata = e.pretnja_procenat(vlasnik) if e else -1
	var meta: bool = _pretnja_poslata >= 0 and e._meta_id == vlasnik
	if vlasnik == multiplayer.get_unique_id():
		primi_cilj(_cilj_srv, _pretnja_poslata, meta)
	else:
		primi_cilj.rpc_id(vlasnik, _cilj_srv, _pretnja_poslata, meta)

@rpc("any_peer", "reliable")
func primi_cilj(id: String, pretnja: int, ja_meta: bool) -> void:
	if not _poziv_od_servera():
		return
	cilj_id = id
	cilj_pretnja = pretnja
	cilj_ja_meta = ja_meta
	cilj_promenjen.emit()

func _physics_process(_delta):
	if not multiplayer.has_multiplayer_peer():
		return
	var dt := 1.0 / Engine.physics_ticks_per_second
	if multiplayer.is_server():
		if is_multiplayer_authority():
			posalji_unos(_kodiraj([_novi_unos()])) # host koji igra: lokalni poziv, bez predikcije
		_server_korak(dt)
		_server_proveri_cilj()
	elif is_multiplayer_authority():
		if not _t_izlaz.is_empty() or not _t_ulaz.is_empty():
			_t_isporuci()
		_klijent_korak(dt)

# Jedan korak kretanja: isti kod na serveru (autoritet) i na vlasniku (predikcija i replay).
func simuliraj_korak(unos: Array, delta: float) -> void:
	var smer: Vector2 = unos[1]
	rotation.y = unos[3]
	# gravitacija uvek; na podu je move_and_slide poništi, pa replay ne zavisi od starog is_on_floor
	velocity.y += gravitacija * delta
	if unos[2] and is_on_floor():
		velocity.y = SKOK
	var pravac := transform.basis.x * smer.x - transform.basis.z * smer.y
	velocity.x = pravac.x * brzina
	velocity.z = pravac.z * brzina
	move_and_slide()

# Vlasnik: smer.x = desno(+)/levo(-), smer.y = napred(+)/nazad(-), yaw = rotation.y lika.
func _novi_unos() -> Array:
	var smer := Vector2.ZERO
	var skok := false
	if not mrtav:
		if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
			smer.y += 1.0
		if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
			smer.y -= 1.0
		if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
			smer.x -= 1.0
		if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
			smer.x += 1.0
		skok = Input.is_key_pressed(KEY_SPACE)
	_seq += 1
	# smer i yaw se kvantizuju odmah: predikcija i server koriste istu vrednost koju paket prenosi
	smer = Vector2(_kv8(smer.x) / 127.0, _kv8(smer.y) / 127.0)
	return [_seq, smer, skok, _yaw_iz16(_yaw16(rotation.y)), _reset_id if multiplayer.is_server() else _reset_id_prim]

# ---------------------------------------------------------------- KODIRANJE PAKETA UNOSA
# Zaglavlje 13 B: seq prvog (s64), reset_id najnovijeg (s32), broj unosa (u8). Po unosu 6 B:
# seq - seq0 (u8), smer x/y (s8, /127), yaw (u16, ceo krug), flag (bit 0 skok, bitovi 1-7 = reset_id0 - reset_id).
# 32 unosa = 205 B. Kvantizovana vrednost se kodira bez gubitka, pa server dekodira isto što je klijent predvideo.
const KOD_ZAGLAVLJE := 13
const KOD_UNOS := 6

static func _kv8(x: float) -> int:
	return clampi(roundi(x * 127.0), -127, 127)

static func _yaw16(y: float) -> int:
	return posmod(roundi(wrapf(y, -PI, PI) / TAU * 65536.0), 65536)

static func _yaw_iz16(q: int) -> float:
	return wrapf(q * TAU / 65536.0, -PI, PI)

func _kodiraj(unosi: Array) -> PackedByteArray:
	var b := PackedByteArray()
	if unosi.is_empty():
		return b
	var seq0: int = unosi[0][0]
	var rid0: int = unosi[-1][4]
	b.resize(KOD_ZAGLAVLJE + KOD_UNOS * unosi.size())
	b.encode_s64(0, seq0)
	b.encode_s32(8, rid0)
	b.encode_u8(12, unosi.size())
	var o := KOD_ZAGLAVLJE
	for u in unosi:
		b.encode_u8(o, clampi(u[0] - seq0, 0, 255))
		b.encode_s8(o + 1, _kv8(u[1].x))
		b.encode_s8(o + 2, _kv8(u[1].y))
		b.encode_u16(o + 3, _yaw16(u[3]))
		b.encode_u8(o + 5, (1 if u[2] else 0) | (clampi(rid0 - u[4], 0, 127) << 1))
		o += KOD_UNOS
	return b

# [] = neispravan paket (pogrešan tip, dužina ili broj unosa); inače unosi kao [seq, smer, skok, yaw, reset_id]
func _dekodiraj(b) -> Array:
	if typeof(b) != TYPE_PACKED_BYTE_ARRAY or b.size() < KOD_ZAGLAVLJE:
		return []
	var n: int = b.decode_u8(12)
	if n == 0 or n > UNOSA_NEPOTVRDJENIH_MAX or b.size() != KOD_ZAGLAVLJE + KOD_UNOS * n:
		return []
	var seq0: int = b.decode_s64(0)
	var rid0: int = b.decode_s32(8)
	var r := []
	for i in n:
		var o := KOD_ZAGLAVLJE + KOD_UNOS * i
		var f: int = b.decode_u8(o + 5)
		r.append([seq0 + b.decode_u8(o), Vector2(b.decode_s8(o + 1) / 127.0, b.decode_s8(o + 2) / 127.0),
			f & 1 == 1, _yaw_iz16(b.decode_u16(o + 3)), rid0 - (f >> 1)])
	return r

# ---------------------------------------------------------------- KLIJENT: PREDIKCIJA

func _klijent_korak(dt: float) -> void:
	if _stanje != null:
		_uskladi(_stanje, dt)
		_stanje = null
	if not _inicijalizovan:
		return # čekamo prvo stanje od servera
	for i in test_ubrzanje:
		var u := _novi_unos()
		brzina = _brzina_vlasnik(u[0])
		if test_brzina_pocela_ms == -1 and brzina > BRZINA:
			test_brzina_pocela_ms = Time.get_ticks_msec()
		simuliraj_korak(u, dt)
		_buffer.append(u)
		_za_slanje.append(u)
	while _za_slanje.size() > UNOSA_NEPOTVRDJENIH_MAX:
		_za_slanje.pop_front()
	while _buffer.size() > MAX_BUFFER:
		_buffer.pop_front()
	if test_zadrzi:
		return
	# posle test_zadrzi: zaostali unosi odjednom, svaki u paketu sa svoja 2 prethodnika (kao pravi rafal)
	for i in _buffer.size():
		if _buffer[i][0] > _poslato_do and _buffer[i][0] < _seq:
			var rafal := _kodiraj(_buffer.slice(maxi(0, i - 2), i + 1))
			_t_posalji(func(): posalji_unos.rpc_id(1, rafal))
	_poslato_do = _seq
	var paket := _za_slanje.duplicate()
	if _debug_seq and not paket.is_empty():
		if paket[0][0] > _dbg_poslato + 1 and _dbg_poslato > 0:
			print("[SEQ-K] klijent preskočio slanje: poslednji poslat %d, paket počinje %d (buffer %d)" % [_dbg_poslato, paket[0][0], _buffer.size()])
		_dbg_poslato = paket[-1][0]
	if test_izgubi_posle_reseta:
		if _test_paket != null:
			var tp := _kodiraj(_test_paket)
			_t_posalji(func(): posalji_unos.rpc_id(1, tp))
		_test_paket = paket
		return
	var kodiran := _kodiraj(paket)
	paket_bajtova = kodiran.size()
	if test_izgubi_paketa > 0:
		test_izgubi_paketa -= 1
		test_izgubljeno_paketa += 1
		return
	if randf() >= test_gubitak:
		_t_posalji(func(): posalji_unos.rpc_id(1, kodiran))

# Server -> vlasnik, svaki physics tick: stanje posle obrade unosa `seq`.
@rpc("any_peer", "unreliable_ordered")
func primi_stanje(seq: int, poz: Vector3, vel: Vector3, reset_id: int, buff_brzine := 0) -> void:
	if not _poziv_od_servera() or randf() < test_gubitak:
		return
	if _t_kasni_ulaz(primi_stanje.bind(seq, poz, vel, reset_id, buff_brzine)):
		return
	if test_izgubi_reset_prijave and reset_id >= 2: # prvo stanje sa reset-om posle prijave (učitavanje)
		test_izgubi_reset_prijave = false
		test_reset_izgubljen = true
		if _debug_seq:
			print("[SEQ-K] TEST: odbačen reset id %d (seq %d, poz %s)" % [reset_id, seq, poz])
		return
	if test_zakasni_reset and reset_id > 0 and _test_reset_kopija == null:
		_test_reset_kopija = [seq, poz, vel, reset_id] # test: ista kopija se kasnije ubacuje ponovo
	if reset_id > 0 and reset_id <= _reset_id_prim:
		return # duplikat već primenjenog reset-a (server ga ponavlja do potvrde, ili zakasni): ignoriše se
	server_poz = poz
	# više stanja u istom frame-u: važi poslednje, ali reset se ne gubi
	_stanje = [seq, poz, vel, maxi(reset_id, _stanje[3] if _stanje != null else 0), buff_brzine]

# Test: zakasneli duplikat reset-a stiže pošto je klijent već hodao (mora da se ignoriše)
func test_ubaci_zakasneli_reset() -> bool:
	if _test_reset_kopija == null:
		return false
	var k: Array = _test_reset_kopija
	primi_stanje(k[0], k[1], k[2], k[3])
	# obradi odmah, sam (inače bi se spojio sa novijim stanjem iz istog frame-a i uzeo njegovu poziciju)
	if _stanje != null and _stanje[3] == k[3]:
		_uskladi(_stanje, 1.0 / Engine.physics_ticks_per_second)
		_stanje = null
	return true

# Reconciliation: serversko stanje + ponovo odigrani nepotvrđeni unosi, pa poređenje sa predikcijom.
func _uskladi(s: Array, dt: float) -> void:
	var seq: int = s[0]
	while not _za_slanje.is_empty() and _za_slanje[0][0] <= seq: # server potvrdio: više se ne šalje
		_za_slanje.pop_front()
	if s[3] > _reset_id_prim or not _inicijalizovan:
		if _debug_seq:
			print("[SEQ-K] reset id %d: ack=%d moj_seq=%d buffer=%d inicijalizovan=%s" % [s[3], seq, _seq, _buffer.size(), _inicijalizovan])
		_reset_id_prim = maxi(_reset_id_prim, s[3])
		if test_izgubi_posle_reseta and _test_paket != null and _inicijalizovan:
			_test_paket = null # paket koji je bio "na putu" kad je stigao reset: izgubljen
			test_izgubi_posle_reseta = false
			test_izgubljen_paket = true
		_buffer.clear()
		global_position = s[1]
		velocity = s[2]
		_vizuelni_offset = Vector3.ZERO
		_inicijalizovan = true
		return
	while not _buffer.is_empty() and _buffer[0][0] <= seq:
		_buffer.pop_front()
	var pre_poz := global_position
	var pre_vel := velocity
	var pre_yaw := rotation.y
	global_position = s[1]
	velocity = s[2]
	_buff_ack = s[4]
	_raspored_kasni = _buff_ack != _buff_brzine_za_seq(seq)
	for u in _buffer:
		brzina = _brzina_vlasnik(u[0])
		simuliraj_korak(u, dt)
	rotation.y = pre_yaw
	var greska := pre_poz.distance_to(global_position)
	greska_suma += greska
	greska_n += 1
	greska_max = maxf(greska_max, greska)
	if greska < PRAG_IGNORISI:
		global_position = pre_poz
		velocity = pre_vel
	elif greska <= PRAG_SNAP:
		# telo je već ispravljeno; model i kamera stižu za SMOOTH_TIME
		korekcije_glatke += 1
		_vizuelni_offset += pre_poz - global_position
		_offset_brzina = _vizuelni_offset.length() / SMOOTH_TIME
	else:
		korekcije_snap += 1
		_vizuelni_offset = Vector3.ZERO

func _pomeri_vizuelno(delta: float) -> void:
	_vizuelni_offset = _vizuelni_offset.move_toward(Vector3.ZERO, _offset_brzina * delta)
	var lok := global_basis.inverse() * _vizuelni_offset
	$CharacterMain.position = _model_poz + lok
	kamera.position = _kamera_poz + lok

# ---------------------------------------------------------------- POSMATRAČ: INTERPOLACIJA

func _interpoliraj(delta: float) -> void:
	var tps := float(Engine.physics_ticks_per_second)
	var sad := Time.get_ticks_usec() / 1e6
	if tik_sync > 0 and (_snimci.is_empty() or tik_sync > _snimci[-1][0]):
		var uzorak := sad - tik_sync / tps
		_sat_pomak = uzorak if _snimci.is_empty() else lerpf(_sat_pomak, uzorak, 0.02)
		if not _snimci.is_empty() and _snimci[-1][1].distance_to(poz_sync) > PRAG_SNAP:
			_snimci.clear() # teleport/respawn: snap, bez klizanja preko mape
		if _snimci.is_empty() and not visible: # prvi snimak: odmah na poziciju sa servera, pa prikaži
			global_position = poz_sync
			show()
		_snimci.append([tik_sync, poz_sync, yaw_sync])
	if _snimci.is_empty():
		return
	var t := (sad - _sat_pomak - INTERP_DELAY) * tps # render vreme u tikovima servera
	while _snimci.size() > 2 and _snimci[1][0] <= t:
		_snimci.pop_front()
	var a = _snimci[0]
	if t <= a[0] or _snimci.size() == 1:
		_postavi(a[1], a[2], delta)
		return
	var b = _snimci[1]
	if t <= b[0]:
		var k: float = (t - a[0]) / float(b[0] - a[0])
		_postavi(a[1].lerp(b[1], k), lerp_angle(a[2], b[2], k), delta)
		return
	# iza poslednjeg snimka: nastavi istom brzinom najviše MAX_EKSTRAPOLACIJA, pa stani
	var v: Vector3 = (b[1] - a[1]) / float(b[0] - a[0])
	_postavi(b[1] + v * minf(t - b[0], MAX_EKSTRAPOLACIJA * tps), b[2], delta)

# Server obrađuje unose kako stignu (2+ koraka u jednom tick-u posle rafala), pa se prikaz
# ograničava na 2x najveću moguću brzinu (posmatrač ne zna tuđi buff brzine); razlika veća od PRAG_SNAP je
# teleport/respawn i ide snap.
func _postavi(poz: Vector3, yaw: float, delta: float) -> void:
	if global_position.distance_to(poz) > PRAG_SNAP:
		global_position = poz
	else:
		global_position = global_position.move_toward(poz, BRZINA_MAX * 2.0 * delta)
	rotation.y = yaw

# ---------------------------------------------------------------- SERVER: UNOSI

# Pozicija se nikad ne prima od klijenta, samo unosi.
@rpc("any_peer", "unreliable_ordered")
func posalji_unos(paket) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	var unosi := _dekodiraj(paket)
	if unosi.is_empty():
		return
	paket_b_zbir += paket.size()
	paket_b_br += 1
	paket_b_max = maxi(paket_b_max, paket.size())
	var sad := Time.get_ticks_msec()
	if _debug_seq and _dbg_paket_ms > 0 and sad - _dbg_paket_ms > 100 and not unosi.is_empty() and typeof(unosi[0]) == TYPE_ARRAY and unosi[0].size() > 0:
		_dbg_seq("PAUZA %d ms pre paketa (prvi seq %s, zadnji obrađen %d)" % [sad - _dbg_paket_ms, str(unosi[0][0]), _poslednji_seq])
	if _dbg_paket_ms > 0:
		paket_razmak_max = maxi(paket_razmak_max, sad - _dbg_paket_ms)
		if sad - _dbg_paket_ms > 100: paketa_posle_pauze += 1
	_dbg_paket_ms = sad
	if _debug_seq: # novi unosi klijenta po paketu (za analizu rafala: analiza_rafala.py)
		var najveci := _dbg_max_vidjen
		for x in unosi:
			if typeof(x) == TYPE_ARRAY and x.size() > 0 and typeof(x[0]) == TYPE_INT and x[0] < _dbg_max_vidjen + 1000:
				najveci = maxi(najveci, x[0])
		if najveci > _dbg_max_vidjen:
			print("[SEQ-P] t=%d peer %s novih=%d" % [sad, name, najveci - _dbg_max_vidjen])
			_dbg_max_vidjen = najveci
	var zadnji: int = _red[-1][0] if not _red.is_empty() else _poslednji_seq
	for sirov in unosi.slice(0, UNOSA_NEPOTVRDJENIH_MAX): # duplikati (seq <= zadnji) se preskaču ispod
		var u := _validan_unos(sirov)
		if u.is_empty() or u[4] != _reset_id:
			continue # neispravan ili iz epohe pre poslednjeg reset-a (klijent ga još nije primenio): bez rupe
		if _reset_ceka: # prvi unos posle reset-a: klijent je primenio reset, odavde se broji ispočetka
			_reset_ceka = false
			_red.clear()
			_poslednji_seq = u[0] - 1
			zadnji = u[0] - 1
		if u[0] <= zadnji:
			if _debug_seq and not u.is_empty() and _rupe_otvorene.has(u[0]):
				_dbg_seq("KASNO seq=%d stigao %d ms posle rupe (van reda)" % [u[0], sad - _rupe_otvorene[u[0]]])
				_rupe_otvorene.erase(u[0])
			continue # neispravan, duplikat ili star
		if _red.size() >= UNOS_RED_MAX:
			if u[0] > _odbijen_do: # redundantne kopije istog seq-a se ne broje ponovo
				odbijeno_red_pun += 1
				_odbijen_do = u[0]
			if _debug_seq and not _odbijeni.has(u[0]):
				_odbijeni[u[0]] = "red pun"
				_dbg_seq("ODBIJEN seq=%d razlog=red pun (%d)" % [u[0], _red.size()])
			continue # redundantna kopija u sledećem paketu može da uđe kad se red isprazni
		var niz: int = u[0] - zadnji - 1
		if niz > 0:
			rupe_seq += niz
			rupe_najduza = maxi(rupe_najduza, niz)
			rupe_nizovi[str(niz) if niz <= 3 else ("4-6" if niz <= 6 else "7+")] += 1
		if _debug_seq:
			for r in range(zadnji + 1, u[0]):
				_rupe_otvorene[r] = sad
				_dbg_seq("RUPA seq=%d (primljen %d, zadnji %d) razlog=%s red=%d" % [r, u[0], zadnji, _odbijeni.get(r, "nije stigao"), _red.size()])
		zadnji = u[0]
		_red.append(u)
		_unos_ms = sad

# debug: dugačak server frame se ispisuje samo jednom (prvi igrač u svetu), ne po igraču
func _je_prvi_igrac() -> bool:
	for c in get_parent().get_children():
		if c.is_in_group("player"):
			return c == self
	return false

# debug linija sa vremenima: od konekcije (spawn), od učitavanja lika, od poslednjeg reset-a
func _dbg_seq(tekst: String) -> void:
	var sad := Time.get_ticks_msec()
	print("[SEQ] t=%d peer %s %s | od_konekcije=%d od_ucitavanja=%s od_reseta=%s" % [sad, name, tekst, sad - _spawn_ms,
		str(sad - _ucitan_ms) if _ucitan_ms >= 0 else "-", str(sad - _reset_ms) if _reset_ms >= 0 else "-"])

# [seq, smer, skok, yaw, reset_id] sa proverom tipova; [] za neispravan unos
func _validan_unos(u) -> Array:
	if typeof(u) != TYPE_ARRAY or u.size() != 5 or typeof(u[0]) != TYPE_INT or typeof(u[1]) != TYPE_VECTOR2 \
			or typeof(u[2]) != TYPE_BOOL or typeof(u[3]) != TYPE_FLOAT or typeof(u[4]) != TYPE_INT:
		return []
	if not u[1].is_finite() or not is_finite(u[3]):
		return []
	return [u[0], u[1].limit_length(1.0), u[2], wrapf(u[3], -PI, PI), u[4]]

# test: rok isporuke za veštački RTT (pola puta + jitter), nikad pre prethodne poruke u istom smeru
func _t_rok(red: Array) -> int:
	var rok := Time.get_ticks_msec() + test_rtt_ms / 2 + (randi_range(-test_jitter_ms, test_jitter_ms) if test_jitter_ms > 0 else 0)
	return maxi(rok, int(red[-1][0]) if not red.is_empty() else 0)

func _t_kasni_ulaz(c: Callable) -> bool:
	if test_rtt_ms <= 0 or _t_isporuka:
		return false
	_t_ulaz.append([_t_rok(_t_ulaz), c])
	return true

func _t_posalji(c: Callable) -> void:
	if test_rtt_ms <= 0 and _t_izlaz.is_empty():
		c.call()
	else:
		_t_izlaz.append([_t_rok(_t_izlaz), c])

func _t_isporuci() -> void:
	var sad := Time.get_ticks_msec()
	while not _t_izlaz.is_empty() and int(_t_izlaz[0][0]) <= sad:
		_t_izlaz.pop_front()[1].call()
	_t_isporuka = true
	while not _t_ulaz.is_empty() and int(_t_ulaz[0][0]) <= sad:
		_t_ulaz.pop_front()[1].call()
	_t_isporuka = false

func _server_korak(dt: float) -> void:
	var ceka := _ceka_reset()
	if ceka: # do potvrde reset-a lik stoji na reset poziciji (isto stanje kao kod klijenta posle reset-a)
		global_position = _reset_poz
		velocity = Vector3.ZERO
	elif _red.is_empty() and Time.get_ticks_msec() - _unos_ms > UNOS_ISTEK_MS:
		simuliraj_korak([0, Vector2.ZERO, false, rotation.y], dt) # vlasnik ćuti: bez unosa, samo gravitacija
	# token bucket: ista stopa po stvarnom vremenu kao pre (UNOS_RATE * tps/s), ali se troši pri obradi
	# iz reda, ne pri prijemu. Po tick-u bi preopterećen server (< 60 tick/s) dobijao manje tokena od
	# klijentovih 60 unosa/s i red bi rastao.
	var sad := Time.get_ticks_msec()
	_tokeni = minf(UNOS_BURST, _tokeni + (sad - _tokeni_ms) / 1000.0 * UNOS_RATE * Engine.physics_ticks_per_second)
	_tokeni_ms = sad
	red_max = maxi(red_max, _red.size())
	while not ceka and not _red.is_empty() and _tokeni >= 1.0:
		var u: Array = _red.pop_front()
		_tokeni -= 1.0
		if mrtav:
			u = [u[0], Vector2.ZERO, false, u[3]]
		brzina = _brzina_za_seq(u[0])
		simuliraj_korak(u, dt)
		_poslednji_seq = u[0]
	_prati_red()
	poz_sync = global_position
	tik_sync = Engine.get_physics_frames()
	yaw_sync = rotation.y
	var vlasnik := get_multiplayer_authority()
	if vlasnik != multiplayer.get_unique_id():
		var rid := _reset_id if ceka else 0
		if rid > 0:
			reset_paketa += 1
			if _debug_seq:
				_dbg_seq("RESET poslat (id %d, seq %d, poz %s)" % [rid, _poslednji_seq, global_position])
		# buff brzine potvrđenog unosa (rezerva za vlasnika) ide samo dok nije 0: bez buff-a paket je isti kao ranije
		var bb := _buff_brzine_za_seq(_poslednji_seq)
		if bb != 0:
			primi_stanje.rpc_id(vlasnik, _poslednji_seq, global_position, velocity, rid, bb)
		else:
			primi_stanje.rpc_id(vlasnik, _poslednji_seq, global_position, velocity, rid)
		if sad - _ping_ms >= PING_RAZMAK_MS:
			_ping_ms = sad
			ping_brzine.rpc_id(vlasnik, sad)

# Host koji igra nema mrežnu potvrdu (unosi mu nose _reset_id direktno): za njega se ne čeka
func _ceka_reset() -> bool:
	return _reset_ceka and get_multiplayer_authority() != multiplayer.get_unique_id()

# Server, uvek (bez debug flag-a): jedna linija po sesiji kad se lik ukloni (odjava ili gašenje servera)
func _exit_tree() -> void:
	if _je_server and get_multiplayer_authority() != 1:
		print("[SESIJA] peer %s lik '%s': trajanje %d s, max red %d, odbijeno_red_pun %d, rupe %d (najduži niz %d, nizovi 1:%d 2:%d 3:%d 4-6:%d 7+:%d), reseta %d (paketa sa reset-om %d), paketi: max razmak %d ms (posle pauze > 100 ms: %d), server frame: max %d ms (> 50 ms: %d), paket unosa: prosek %d B, max %d B" % [
			name, ime_lika, (Time.get_ticks_msec() - _spawn_ms) / 1000, red_max, odbijeno_red_pun, rupe_seq, rupe_najduza,
			rupe_nizovi["1"], rupe_nizovi["2"], rupe_nizovi["3"], rupe_nizovi["4-6"], rupe_nizovi["7+"], reset_izdato, reset_paketa, paket_razmak_max, paketa_posle_pauze, frame_max_ms, frame_dugih,
			paket_b_zbir / maxi(paket_b_br, 1), paket_b_max])

# Zaostatak = red koji ostaje posle obrade u tick-u (normalno 0). Debug: vrh i vreme pražnjenja.
func _prati_red() -> void:
	if _red.is_empty():
		if _red_od_ms >= 0:
			red_zaostatak = [_red_vrh, Time.get_ticks_msec() - _red_od_ms]
			if _debug_seq:
				_dbg_seq("RED ispražnjen za %d ms (vrh %d)" % [red_zaostatak[1], _red_vrh])
		_red_od_ms = -1
		_red_vrh = 0
		return
	if _red_od_ms < 0:
		_red_od_ms = Time.get_ticks_msec()
	if _red.size() > _red_vrh:
		_red_vrh = _red.size()
		if _debug_seq:
			_dbg_seq("RED zaostaje: %d unosa" % _red.size())

# Server: premesti lik. reset=true (prijava, respawn) briše vlasnikov buffer; inače odlučuje PRAG_SNAP.
func server_postavi_poziciju(poz: Vector3, reset: bool) -> void:
	global_position = poz
	velocity = Vector3.ZERO
	if reset:
		_reset_id += 1
		_reset_ceka = true
		_reset_poz = poz
		_red.clear()
		reset_izdato += 1
		_reset_ms = Time.get_ticks_msec()

# ---------------------------------------------------------------- NAMEPLATE

# Server: jedino mesto gde se pune sync polja (zove ga _posalji_hp i prijava). Mana/oklop se ne šalju.
func _sync_nameplate() -> void:
	hp_sync = hp
	max_hp_sync = max_hp
	mrtav_sync = mrtav
	ime_sync = ime_lika

# Klijent, tuđi lik: Label3D + dve billboard trake (pozadina, punjenje). Bez SubViewport-a.
func _napravi_nameplate() -> void:
	_nameplate = Node3D.new()
	_nameplate.name = "Nameplate"
	_nameplate.position.y = NAMEPLATE_VISINA
	add_child(_nameplate)
	_ime_label = Label3D.new()
	_ime_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_ime_label.position.y = 0.17
	_ime_label.font_size = 40
	_ime_label.outline_size = 10
	_nameplate.add_child(_ime_label)
	_nameplate.add_child(_napravi_traku("Pozadina", Color(0, 0, 0, 0.6), 0))
	_hp_traka = _napravi_traku("HpTraka", BOJA_HP_VISOK, 1)
	_nameplate.add_child(_hp_traka)
	_osvezi_nameplate()

# Providne trake ne pišu dubinu, pa punjenje (render_priority 1) uvek ide preko pozadine
func _napravi_traku(ime: String, boja: Color, prioritet: int) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = boja
	mat.render_priority = prioritet
	var q := QuadMesh.new()
	q.size = Vector2(NAMEPLATE_SIRINA, NAMEPLATE_DEBLJINA)
	q.material = mat
	var m := MeshInstance3D.new()
	m.name = ime
	m.mesh = q
	m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return m

# Zove se samo iz settera sync polja (kad se vrednost promeni), ne svaki frame
func _osvezi_nameplate() -> void:
	if _nameplate == null:
		return
	_ime_label.text = tr("%s (dead)") % ime_sync if mrtav_sync else ime_sync
	_ime_label.modulate = BOJA_IME_MRTAV if mrtav_sync else Color.WHITE
	_hp_traka.visible = not mrtav_sync
	_nameplate.get_node("Pozadina").visible = not mrtav_sync
	var deo := clampf(float(hp_sync) / maxi(max_hp_sync, 1), 0.0, 1.0)
	var q: QuadMesh = _hp_traka.mesh
	q.size.x = NAMEPLATE_SIRINA * deo
	q.center_offset.x = -NAMEPLATE_SIRINA * (1.0 - deo) / 2.0 # puni se sleva (u ravni billboard-a)
	q.material.albedo_color = BOJA_HP_VISOK if deo > 0.5 else (BOJA_HP_SREDNJI if deo >= 0.25 else BOJA_HP_NIZAK)

func _proveri_daljinu_nameplate() -> void:
	var kam := get_viewport().get_camera_3d()
	var vidljiv := kam == null or kam.global_position.distance_to(global_position) <= MAX_PRIKAZ_DALJINA
	if _nameplate.visible != vidljiv:
		_nameplate.visible = vidljiv

# ---------------------------------------------------------------- SERVER -> IGRAC (RPC)

# Prihvata se samo poziv od servera (ID 1) ili lokalni poziv (host koji i igra).
func _poziv_od_servera() -> bool:
	var sender = multiplayer.get_remote_sender_id()
	return sender == 0 or sender == 1

func _hud():
	return get_node_or_null("ui/Control")

@rpc("any_peer")
func primi_loot(item_id: String, kolicina: int = 1) -> void:
	if not _poziv_od_servera():
		return
	var inv = get_node_or_null("ui/InventoryUI")
	if inv:
		inv.dodaj_item_u_slot(item_id, kolicina)
	else:
		print("[LOOT] Ne mogu da nađem InventoryUI za item: ", item_id)

@rpc("any_peer")
func primi_kill(tip_neprijatelja: String, _xp: int) -> void:
	if not _poziv_od_servera():
		return
	# XP stiže preko primi_stats (server ga upisuje u bazu)
	QuestManager.azuriraj_progres_kill(tip_neprijatelja)

# "any_peer" + provera pošiljaoca kao primi_loot: vlasnik ovog node-a je klijent, ne server
@rpc("any_peer", "reliable")
func primi_stats(stats: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	var hud = _hud()
	if hud:
		hud.primeni_stats(stats)

@rpc("any_peer", "reliable")
func primi_lik(podaci: Dictionary) -> void:
	if not _poziv_od_servera():
		return
	var hud = _hud()
	if hud:
		hud.primeni_lik(podaci)

# Server šalje stanje; klijent ga samo prikazuje i blokira unos dok je mrtav
@rpc("any_peer", "reliable")
func primi_hp(novi_hp: int, novi_max_hp: int, nova_mana: int, nova_max_mana: int, je_mrtav: bool) -> void:
	if not _poziv_od_servera():
		return
	mrtav = je_mrtav
	if mrtav:
		velocity = Vector3.ZERO
	var hud = _hud()
	if hud:
		hud.primeni_hp(novi_hp, novi_max_hp, nova_mana, nova_max_mana, je_mrtav)
