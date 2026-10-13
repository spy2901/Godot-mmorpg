extends CharacterBody3D

#MOVEMNT
var brzina = 5.0
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
const UNOSA_PO_PAKETU := 3  # redundansa: svaki paket nosi poslednja 3 unosa
const UNOS_RATE := 1.2      # server: najviše 1.2 * physics_ticks_per_second unosa/s (token bucket)
const UNOS_BURST := 10.0    # server: kapacitet kofe
# server: red unosa koji čekaju token. Rafal posle zastoja (servera ili klijenta) se zakasni umesto
# da se odbaci. Izmereno pod opterećenjem (analiza_rafala.py): najduži zaostatak 12, najgori viđeni
# događaj 28 uzastopnih odbijenih unosa -> 32 (~15% rezerve). Pun red odbacuje višak (speed-hack).
const UNOS_RED_MAX := 32

# unos = [seq: int, smer: Vector2, skok: bool, yaw: float]
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
var server_poz := Vector3.ZERO # poslednja pozicija od servera (testovi)
var korekcije_glatke := 0
var korekcije_snap := 0
var greska_max := 0.0
var greska_suma := 0.0
var greska_n := 0
var test_gubitak := 0.0 # test: deo paketa koji klijent odbacuje (oba smera)
var test_ubrzanje := 1  # test: unosa po physics tick-u (speed-hack)
var test_zadrzi := false # test: klijent pravi unose ali ih ne šalje; kad se pusti, šalje ih u rafalu
var _poslato_do := 0     # klijent: najveći seq koji je otišao u nekom paketu
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
var _reset := true           # sledeće stanje vlasniku nosi reset (spawn, prijava, respawn)
var rupe_seq := 0            # preskočeni seq-ovi (izgubljeni ili odbijeni)
# debug (server, MMORPG_DEBUG_SEQ=1): svaka rupa u seq obradi sa razlogom i vremenima
var _debug_seq := OS.get_environment("MMORPG_DEBUG_SEQ") == "1"
var _spawn_ms := 0           # server: kad je lik napravljen (konekcija peer-a)
var _ucitan_ms := -1         # server: kad je lik učitan iz baze
var _reset_ms := -1          # server: poslednji server_postavi_poziciju(reset=true)
var _odbijeni := {}          # seq -> razlog odbijanja (debug)
var _rupe_otvorene := {}     # seq -> ms kad je rupa nastala (debug: da li stigne kasnije)
var _dbg_poslato := 0        # klijent (debug): najveći poslati seq
var _dbg_paket_ms := 0       # server (debug): kad je stigao prethodni paket unosa
var _dbg_max_vidjen := 0     # server (debug): najveći seq viđen u bilo kom paketu (nezavisno od obrade)
# posmatrač
var _snimci: Array = []      # [tik, poz, yaw]
var _sat_pomak := 0.0        # lokalno vreme - serversko vreme (usrednjeno)

#ATTACK
var napad_damage = 25  # na serveru: učitano iz baze preko registruj_lik
var bonus_oruzja = 0   # na serveru: damage iz items.damage za opremljeno oružje
var napad_cooldown = 1.0
var moze_napasti = true
var ime_lika := ""      # samo na serveru

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
const SLOTOVI_OKLOPA := ["head", "chest", "legs", "boots", "shield"]

var hp := 100
var max_hp := 100
var mana := 100
var max_mana := 100
var mrtav := false # server: pravi status; klijent: ogledalo za blokiranje unosa
var armor := 0 # samo na serveru: zbir oklopa iz opreme
var _stanje_ucitano := false # samo na serveru: hp/mana učitani iz baze
var _neosjetljiv_do_ms := 0 # samo na serveru
var _regen_akum := 0.0 # samo na serveru
var _oklop_kljuc := "" # samo na serveru: koja oprema je već uračunata
var _oklop_verzija := 0 # samo na serveru

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
var _nameplate: Node3D
var _ime_label: Label3D
var _hp_traka: MeshInstance3D

@onready var kamera = $Camera3D

func _ready():
	add_to_group("player")
	_spawn_ms = Time.get_ticks_msec()
	_model_poz = $CharacterMain.position
	_kamera_poz = kamera.position
	# Node pripada vlasniku (RPC-ovi); poz_sync/yaw_sync šalje server ostalima.
	# position se NE replicira: vlasnikovu poziciju menjaju samo predikcija i reconciliation.
	$MultiplayerSynchronizer.set_multiplayer_authority(1)
	# Server je autoritet za sve likove; vlasnik predviđa svoj lik i šalje unose
	set_physics_process(multiplayer.is_server() or is_multiplayer_authority())
	if not multiplayer.is_server() and not is_multiplayer_authority():
		_napravi_nameplate()
	if not is_multiplayer_authority():
		set_process_unhandled_input(false)
		kamera.current = false
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	kamera.current = true

# Ukupan damage po udarcu: baza lika + bonus oružja
func izracunaj_damage() -> int:
	return napad_damage + bonus_oruzja

func napadni():
	if mrtav:
		return
	moze_napasti = false
	print("Napadaš za ", izracunaj_damage(), " damage!")

	var neprijatelji = get_tree().get_nodes_in_group("neprijatelj")
	for neprijatelj in neprijatelji:
		var distanca = global_position.distance_to(neprijatelj.global_position)
		if distanca < 3.0:
			if multiplayer.multiplayer_peer != null:
				if multiplayer.is_server():
					# host: damage računa sam server
					neprijatelj.primi_damage(izracunaj_damage(), multiplayer.get_unique_id())
				else:
					# klijent: šalje samo "napadam", server sam računa damage
					neprijatelj.zahtevaj_napad.rpc_id(1)
			else:
				neprijatelj.primi_damage(izracunaj_damage())

	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true

# ---------------------------------------------------------------- LIK -> SERVER

# Klijent (vlasnik lika) jednom pošalje token, server od /auth/verify dobije ime lika i učita statistike.
func posalji_lik_serveru(token: String) -> void:
	if multiplayer.is_server():
		registruj_lik(token)  # host: poziv je lokalan, nema RPC-a
	else:
		registruj_lik.rpc_id(1, token)

var _registracija_u_toku := false  # samo na serveru

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
	var r: Dictionary = await ApiManager.verify_token(token)
	_registracija_u_toku = false
	var ime := str(r.get("ime_lika", ""))
	if r.get("status", "") != "ok" or ime == "":
		var razlog := str(r.get("error", "neispravan odgovor"))
		print("[AUTH] Odbijen peer ", peer_id, ": ", razlog)
		_odbij(peer_id, "Prijava odbijena: " + razlog)
		return
	# Isti lik već u igri -> starog izbaci
	for p in get_tree().get_nodes_in_group("player"):
		if p != self and p.ime_lika == ime:
			print("[AUTH] ", ime, " je već prijavljen (peer ", p.get_multiplayer_authority(), "), izbacujem starog")
			p.ime_lika = ""
			p._odbij(p.get_multiplayer_authority(), "Prijavljen si sa drugog mesta")
	ime_lika = ime
	_sync_nameplate()
	print("[AUTH] Peer ", peer_id, " -> ", ime)
	_ucitaj_statistike_sa_servera(ime)

# Server: javi peer-u razlog pa ga diskonektuj (host koji igra: lokalni poziv)
func _odbij(peer_id: int, poruka: String) -> void:
	if peer_id == multiplayer.get_unique_id():
		registracija_odbijena(poruka)
		return
	registracija_odbijena.rpc_id(peer_id, poruka)
	NetworkManager.izbaci_peer(peer_id)

@rpc("any_peer", "reliable")
func registracija_odbijena(poruka: String) -> void:
	if not _poziv_od_servera():
		return
	print("[AUTH] ", poruka)
	NetworkManager.prekini()
	GameState.token = ""
	GameState.poruka_logina = poruka
	get_tree().change_scene_to_file("res://Scenes/UI/MainMenu.tscn")

func _ucitaj_statistike_sa_servera(ime: String) -> void:
	var p: Dictionary = await ApiManager.get_player(ime)
	if p.is_empty() or p.has("error"):
		print("[SERVER] Ne mogu da učitam lik: ", ime)
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

	await _primeni_oruzje(str(eq.get("weapon", "")))
	await _primeni_oklop(eq)
	var zavrseni: Array = await ApiManager.get_completed_quests(ime)
	if ime_lika != ime:  # izbačen dok smo čekali backend
		return

	# HP i mana: od sada ih drži server
	max_hp = int(p.get("max_hp", 100))
	max_mana = int(p.get("max_mana", 100))
	hp = clampi(int(p.get("hp", max_hp)), 1, max_hp)
	mana = clampi(int(p.get("mana", max_mana)), 0, max_mana)
	mrtav = false
	_neosjetljiv_do_ms = 0
	_stanje_ucitano = true
	_ucitan_ms = Time.get_ticks_msec()
	_sync_nameplate()
	print("[SERVER] Lik ", ime, " registrovan, damage: ", izracunaj_damage(), ", predmeta: ", vlasnistvo.size())

	_ucitano_stanje = {"inventory": p.get("inventory", []), "equipment": eq}
	var podaci := {
		"level": p.get("level", 1), "xp": p.get("xp", 0), "max_xp": p.get("max_xp", 100),
		"hp": hp, "max_hp": max_hp,
		"mana": mana, "max_mana": max_mana,
		"gold": p.get("gold", 100), "napad_damage": napad_damage,
		"inventory": p.get("inventory", []), "equipment": eq,
		"aktivni_quest_id": p.get("aktivni_quest_id", null), "quest_progres": p.get("quest_progres", 0),
		"zavrseni_questovi": zavrseni
	}
	var pos := Vector3(float(p.get("pos_x", 0)), float(p.get("pos_y", 0)), float(p.get("pos_z", 0)))
	if pos != Vector3.ZERO:
		server_postavi_poziciju(pos, true)
		podaci["pos_x"] = pos.x
		podaci["pos_y"] = pos.y
		podaci["pos_z"] = pos.z
	var vlasnik := get_multiplayer_authority()
	if vlasnik == multiplayer.get_unique_id():
		primi_lik(podaci)
	else:
		primi_lik.rpc_id(vlasnik, podaci)

# ---------------------------------------------------------------- SNIMANJE (server)

const SAVE_RAZMAK_MS := 2000
var _ucitano_stanje: Dictionary = {}  # inventory/equipment iz baze; prazno = lik nije učitan
var _poslednje_stanje: Dictionary = {}  # poslednji raspored inventara od klijenta
var _poslednje_snimanje_ms := -SAVE_RAZMAK_MS
var _snimanje_zakazano := false

# Klijent (vlasnik) šalje samo raspored inventara/opreme; hp/manu i poziciju server uzima sam.
@rpc("any_peer", "reliable")
func posalji_stanje(inventory: Array, equipment: Dictionary) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik() or ime_lika == "":
		return
	_poslednje_stanje = {"inventory": inventory, "equipment": equipment}
	_primeni_oklop(equipment)
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
		"inventory": s["inventory"], "equipment": s["equipment"]
	})
	if not ok:
		print("[SAVE] Snimanje nije uspelo za ", ime)

func _zakazano_snimanje() -> void:
	if _snimanje_zakazano:
		_snimanje_zakazano = false
		_server_sacuvaj(false)

# ---------------------------------------------------------------- OPREMA -> SERVER

# Klijent javlja serveru koje oružje je opremio ("" kad skine). Server proverava u bazi.
@rpc("any_peer", "reliable")
func postavi_oruzje(item_id: String) -> void:
	if multiplayer.multiplayer_peer != null:
		if not multiplayer.is_server():
			return
		var posiljalac := multiplayer.get_remote_sender_id()
		if posiljalac != 0 and posiljalac != get_multiplayer_authority():
			return
	if item_id != "" and not posjeduje(item_id):
		print("[SERVER] Odbijeno oružje koje lik ne poseduje: ", item_id)
		bonus_oruzja = 0
		return
	await _primeni_oruzje(item_id)

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

func _primeni_oruzje(item_id: String) -> void:
	if item_id == "":
		bonus_oruzja = 0
		return
	var item: Dictionary = await ApiManager.get_item(item_id)
	if item.is_empty() or item.has("error") or str(item.get("tip", "")) != "weapon":
		print("[SERVER] Nije validno oružje: ", item_id)
		bonus_oruzja = 0
		return
	bonus_oruzja = int(item.get("damage", 0))
	print("[SERVER] Oružje ", item_id, " bonus: ", bonus_oruzja)

# ---------------------------------------------------------------- ZDRAVLJE (server)

# Backend je izračunao nove statistike (xp/change, quest turnin); server ih preuzima.
# Na level-up server sam puni hp i manu.
func server_primeni_stats(st: Dictionary) -> void:
	napad_damage = int(st.get("napad_damage", napad_damage))
	max_hp = int(st.get("max_hp", max_hp))
	max_mana = int(st.get("max_mana", max_mana))
	if st.get("level_up", false):
		hp = max_hp
		mana = max_mana
	hp = mini(hp, max_hp)
	mana = mini(mana, max_mana)
	_posalji_hp()

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
	if _debug_seq and multiplayer.is_server() and delta > 0.1 and _je_prvi_igrac():
		print("[SEQ-S] t=%d dugačak server frame %d ms" % [Time.get_ticks_msec(), int(delta * 1000)])
	if not multiplayer.is_server() or not _stanje_ucitano or mrtav:
		return
	_regen_akum += delta
	if _regen_akum < 1.0:
		return
	_regen_akum -= 1.0
	if hp < max_hp or mana < max_mana:
		hp = mini(hp + HP_REGEN, max_hp)
		mana = mini(mana + MANA_REGEN, max_mana)
		_posalji_hp()

# Poziva Enemy na serveru. Šteta = max(1, šteta - oklop).
func server_primi_damage(sirova_steta: int) -> void:
	if not multiplayer.is_server() or not _stanje_ucitano or mrtav:
		return
	if Time.get_ticks_msec() < _neosjetljiv_do_ms:
		return
	var steta := maxi(1, sirova_steta - armor)
	hp = maxi(hp - steta, 0)
	print("[DMG] ", ime_lika, " -", steta, " (oklop ", armor, ") -> hp ", hp)
	if hp == 0:
		_server_umri()
	_posalji_hp()

func _server_umri() -> void:
	mrtav = true
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
	else:
		primi_hp.rpc_id(vlasnik, hp, max_hp, mana, max_mana, mrtav)

# Oklop = zbir `armor` kolone opremljenih komada koje lik zaista poseduje.
# Računa se ponovo samo kad se promeni skup opremljenih komada.
func _primeni_oklop(eq: Dictionary) -> void:
	var ids: PackedStringArray = []
	for slot in SLOTOVI_OKLOPA:
		var id := str(eq.get(slot, ""))
		if id != "" and posjeduje(id):
			ids.append(id)
	var kljuc := ",".join(ids)
	if kljuc == _oklop_kljuc:
		return
	_oklop_kljuc = kljuc
	_oklop_verzija += 1
	var verzija := _oklop_verzija
	var zbir := 0
	for id in ids:
		var item: Dictionary = await ApiManager.get_item(id)
		if item.is_empty() or item.has("error") or str(item.get("tip", "")) != "armor":
			continue
		zbir += int(item.get("armor", 0))
	if verzija != _oklop_verzija:
		return # stigla je novija promena opreme
	armor = zbir
	print("[SERVER] Oklop ", ime_lika, ": ", armor)

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
func _posalji_i_cekaj(tip: String, odgovor_signal: Signal, zahtev: Callable, arg: String) -> Dictionary:
	if _zahtevi_u_toku.get(tip, false):
		return {"ok": false, "poruka": "Zahtev je u toku"}
	_zahtevi_u_toku[tip] = true
	var stanje := {"odgovor": null}
	var primi := func(d: Dictionary): stanje.odgovor = d
	odgovor_signal.connect(primi)
	if multiplayer.is_server():
		zahtev.call(arg)
	else:
		zahtev.rpc_id(1, arg)
	var rok := Time.get_ticks_msec() + ZAHTEV_TIMEOUT_MS
	while stanje.odgovor == null and Time.get_ticks_msec() < rok:
		await get_tree().process_frame
	odgovor_signal.disconnect(primi)
	_zahtevi_u_toku.erase(tip)
	if stanje.odgovor == null:
		return {"ok": false, "poruka": "Server ne odgovara"}
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
		return "Lik nije registrovan"
	if _server_zauzet.get(tip, false):
		return "Zahtev je u toku"
	return ""

func _neuspeh(r: Dictionary) -> Dictionary:
	return {"ok": false, "poruka": str(r.get("error", "Server nedostupan"))}

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
		"poruka": "" if ok else str(r.get("error", "Server nedostupan"))
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
		_odgovori(odgovor_item, {"ok": false, "poruka": greska})
		return
	_server_zauzet["item"] = true
	var d := await _iskoristi_item(item_id)
	_server_zauzet.erase("item")
	_odgovori(odgovor_item, d)

func _greska_itema(item_id: String) -> String:
	if not _stanje_ucitano:
		return "Lik nije registrovan"
	if mrtav:
		return "Mrtav si"
	if not posjeduje(item_id):
		return "Nemaš taj predmet"
	if Time.get_ticks_msec() < _item_cd_do_ms.get(item_id, 0):
		return "Još nije spremno"
	return ""

func _iskoristi_item(item_id: String) -> Dictionary:
	var item: Dictionary = await ApiManager.get_item(item_id)
	var hp_e := int(item.get("hp_efekat", 0))
	var mana_e := int(item.get("mana_efekat", 0))
	if item.is_empty() or item.has("error") or str(item.get("tip", "")) != "consumable" or hp_e + mana_e <= 0:
		return {"ok": false, "poruka": "Predmet se ne može koristiti"}
	if mrtav:
		return {"ok": false, "poruka": "Mrtav si"}
	if not ((hp_e > 0 and hp < max_hp) or (mana_e > 0 and mana < max_mana)):
		return {"ok": false, "poruka": "Već si pun"}
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
		s["inventory"] = r["inventory"]
	if not mrtav: # poginuo dok smo čekali backend: komad je potrošen, efekta nema
		hp = mini(hp + hp_e, max_hp)
		mana = mini(mana + mana_e, max_mana)
		_posalji_hp()
	print("[ITEM] ", ime, " koristio ", item_id, " -> hp ", hp, ", mana ", mana)
	return {"ok": true, "item_id": item_id, "hp_efekat": hp_e, "mana_efekat": mana_e, "cooldown_ms": cd}

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
			_kamera_poz.z = max(_kamera_poz.z - zum_brzina, min_zum)
			if _kamera_poz.z <= 0.1:
				$CharacterMain.visible = false

		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_kamera_poz.z = min(_kamera_poz.z + zum_brzina, max_zum)
			if _kamera_poz.z > 0.1:
				$CharacterMain.visible = true

		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if moze_napasti and not mrtav:
				napadni()

	if event is InputEventMouseMotion and rotacija_misa:
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		kamera.rotate_x(deg_to_rad(-event.relative.y * mouse_sensitivity))
		kamera.rotation.x = clamp(kamera.rotation.x, deg_to_rad(-60), deg_to_rad(60))

func _physics_process(_delta):
	if not multiplayer.has_multiplayer_peer():
		return
	var dt := 1.0 / Engine.physics_ticks_per_second
	if multiplayer.is_server():
		if is_multiplayer_authority():
			posalji_unos([_novi_unos()]) # host koji igra: lokalni poziv, bez predikcije
		_server_korak(dt)
	elif is_multiplayer_authority():
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
	return [_seq, smer, skok, rotation.y]

# ---------------------------------------------------------------- KLIJENT: PREDIKCIJA

func _klijent_korak(dt: float) -> void:
	if _stanje != null:
		_uskladi(_stanje, dt)
		_stanje = null
	if not _inicijalizovan:
		return # čekamo prvo stanje od servera
	for i in test_ubrzanje:
		var u := _novi_unos()
		simuliraj_korak(u, dt)
		_buffer.append(u)
	while _buffer.size() > MAX_BUFFER:
		_buffer.pop_front()
	if test_zadrzi:
		return
	# posle test_zadrzi: zaostali unosi odjednom, svaki u paketu sa svoja 2 prethodnika (kao pravi rafal)
	for i in _buffer.size():
		if _buffer[i][0] > _poslato_do and _buffer[i][0] < _seq:
			posalji_unos.rpc_id(1, _buffer.slice(maxi(0, i - 2), i + 1))
	_poslato_do = _seq
	var paket := _buffer.slice(-UNOSA_PO_PAKETU)
	if _debug_seq and not paket.is_empty():
		if paket[0][0] > _dbg_poslato + 1 and _dbg_poslato > 0:
			print("[SEQ-K] klijent preskočio slanje: poslednji poslat %d, paket počinje %d (buffer %d)" % [_dbg_poslato, paket[0][0], _buffer.size()])
		_dbg_poslato = paket[-1][0]
	if randf() >= test_gubitak:
		posalji_unos.rpc_id(1, paket)

# Server -> vlasnik, svaki physics tick: stanje posle obrade unosa `seq`.
@rpc("any_peer", "unreliable_ordered")
func primi_stanje(seq: int, poz: Vector3, vel: Vector3, reset: bool) -> void:
	if not _poziv_od_servera() or randf() < test_gubitak:
		return
	server_poz = poz
	# više stanja u istom frame-u: važi poslednje, ali reset se ne gubi
	_stanje = [seq, poz, vel, reset or (_stanje != null and _stanje[3])]

# Reconciliation: serversko stanje + ponovo odigrani nepotvrđeni unosi, pa poređenje sa predikcijom.
func _uskladi(s: Array, dt: float) -> void:
	var seq: int = s[0]
	if s[3] or not _inicijalizovan:
		if _debug_seq:
			print("[SEQ-K] reset: ack=%d moj_seq=%d buffer=%d inicijalizovan=%s" % [seq, _seq, _buffer.size(), _inicijalizovan])
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
	for u in _buffer:
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
# ograničava na 2x brzinu hoda; razlika veća od PRAG_SNAP je teleport/respawn i ide snap.
func _postavi(poz: Vector3, yaw: float, delta: float) -> void:
	if global_position.distance_to(poz) > PRAG_SNAP:
		global_position = poz
	else:
		global_position = global_position.move_toward(poz, brzina * 2.0 * delta)
	rotation.y = yaw

# ---------------------------------------------------------------- SERVER: UNOSI

# Pozicija se nikad ne prima od klijenta, samo unosi.
@rpc("any_peer", "unreliable_ordered")
func posalji_unos(unosi: Array) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik():
		return
	var sad := Time.get_ticks_msec()
	if _debug_seq and _dbg_paket_ms > 0 and sad - _dbg_paket_ms > 100 and not unosi.is_empty() and typeof(unosi[0]) == TYPE_ARRAY and unosi[0].size() > 0:
		_dbg_seq("PAUZA %d ms pre paketa (prvi seq %s, zadnji obrađen %d)" % [sad - _dbg_paket_ms, str(unosi[0][0]), _poslednji_seq])
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
	for sirov in unosi.slice(0, UNOSA_PO_PAKETU):
		var u := _validan_unos(sirov)
		if u.is_empty() or u[0] <= zadnji:
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
		rupe_seq += u[0] - zadnji - 1
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

# [seq, smer, skok, yaw] sa proverom tipova; [] za neispravan unos
func _validan_unos(u) -> Array:
	if typeof(u) != TYPE_ARRAY or u.size() != 4 or typeof(u[0]) != TYPE_INT or typeof(u[1]) != TYPE_VECTOR2 \
			or typeof(u[2]) != TYPE_BOOL or typeof(u[3]) != TYPE_FLOAT:
		return []
	if not u[1].is_finite() or not is_finite(u[3]):
		return []
	return [u[0], u[1].limit_length(1.0), u[2], wrapf(u[3], -PI, PI)]

func _server_korak(dt: float) -> void:
	if _red.is_empty() and Time.get_ticks_msec() - _unos_ms > UNOS_ISTEK_MS:
		simuliraj_korak([0, Vector2.ZERO, false, rotation.y], dt) # vlasnik ćuti: bez unosa, samo gravitacija
	# token bucket: ista stopa po stvarnom vremenu kao pre (UNOS_RATE * tps/s), ali se troši pri obradi
	# iz reda, ne pri prijemu. Po tick-u bi preopterećen server (< 60 tick/s) dobijao manje tokena od
	# klijentovih 60 unosa/s i red bi rastao.
	var sad := Time.get_ticks_msec()
	_tokeni = minf(UNOS_BURST, _tokeni + (sad - _tokeni_ms) / 1000.0 * UNOS_RATE * Engine.physics_ticks_per_second)
	_tokeni_ms = sad
	red_max = maxi(red_max, _red.size())
	while not _red.is_empty() and _tokeni >= 1.0:
		var u: Array = _red.pop_front()
		_tokeni -= 1.0
		if mrtav:
			u = [u[0], Vector2.ZERO, false, u[3]]
		simuliraj_korak(u, dt)
		_poslednji_seq = u[0]
	_prati_red()
	poz_sync = global_position
	tik_sync = Engine.get_physics_frames()
	yaw_sync = rotation.y
	var vlasnik := get_multiplayer_authority()
	if vlasnik != multiplayer.get_unique_id():
		primi_stanje.rpc_id(vlasnik, _poslednji_seq, global_position, velocity, _reset)
	_reset = false

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
	_reset = _reset or reset
	if reset:
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
	_ime_label.text = ime_sync + (" (mrtav)" if mrtav_sync else "")
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
