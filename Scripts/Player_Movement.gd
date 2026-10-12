extends CharacterBody3D

#MOVEMNT
var brzina = 5.0
var gravitacija = -9.8
var mouse_sensitivity = 0.3
var rotacija_misa = false

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

@onready var kamera = $Camera3D

func _ready():
	add_to_group("player")
	if not is_multiplayer_authority():
		set_process_unhandled_input(false)
		set_physics_process(false)
		kamera.current = false
		return
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	kamera.current = true

# Ukupan damage po udarcu: baza lika + bonus oružja
func izracunaj_damage() -> int:
	return napad_damage + bonus_oruzja

func napadni():
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
	var zavrseni: Array = await ApiManager.get_completed_quests(ime)
	if ime_lika != ime:  # izbačen dok smo čekali backend
		return
	print("[SERVER] Lik ", ime, " registrovan, damage: ", izracunaj_damage(), ", predmeta: ", vlasnistvo.size())

	_ucitano_stanje = {
		"hp": int(p.get("hp", 100)), "mana": int(p.get("mana", 100)),
		"inventory": p.get("inventory", []), "equipment": eq
	}
	var podaci := {
		"level": p.get("level", 1), "xp": p.get("xp", 0), "max_xp": p.get("max_xp", 100),
		"hp": p.get("hp", 100), "max_hp": p.get("max_hp", 100),
		"mana": p.get("mana", 100), "max_mana": p.get("max_mana", 100),
		"gold": p.get("gold", 100), "napad_damage": napad_damage,
		"inventory": p.get("inventory", []), "equipment": eq,
		"aktivni_quest_id": p.get("aktivni_quest_id", null), "quest_progres": p.get("quest_progres", 0),
		"zavrseni_questovi": zavrseni
	}
	var pos := Vector3(float(p.get("pos_x", 0)), float(p.get("pos_y", 0)), float(p.get("pos_z", 0)))
	if pos != Vector3.ZERO:
		global_position = pos
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
var _ucitano_stanje: Dictionary = {}    # hp/mana/inventory/equipment iz baze; prazno = lik nije učitan
var _poslednje_stanje: Dictionary = {}  # poslednje stanje od klijenta
var _poslednje_snimanje_ms := -SAVE_RAZMAK_MS
var _snimanje_zakazano := false

# Klijent (vlasnik) šalje hp/manu/raspored; poziciju server uzima sa svog node-a.
@rpc("any_peer", "reliable")
func posalji_stanje(hp: int, mana: int, inventory: Array, equipment: Dictionary) -> void:
	if not multiplayer.is_server() or not _posiljalac_je_vlasnik() or ime_lika == "":
		return
	_poslednje_stanje = {"hp": hp, "mana": mana, "inventory": inventory, "equipment": equipment}
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
		"hp": int(s["hp"]), "mana": int(s["mana"]),
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
	napad_damage = int(r.get("napad_damage", napad_damage))
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

# ---------------------------------------------------------------- KUPOVINA I QUESTOVI KROZ SERVER

signal kupovina_odgovor(odgovor: Dictionary)
signal quest_prihvat_odgovor(odgovor: Dictionary)
signal quest_predaja_odgovor(odgovor: Dictionary)

const ZAHTEV_TIMEOUT_MS := 8000
var _zahtevi_u_toku: Dictionary = {}  # klijent: tip -> true dok čeka odgovor
var _server_zauzet: Dictionary = {}   # server: tip -> true dok se izvršava

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
	if stats.has("napad_damage"):
		napad_damage = int(stats["napad_damage"])
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
			kamera.position.z = max(kamera.position.z - zum_brzina, min_zum)
			if kamera.position.z <= 0.1:
				$CharacterMain.visible = false

		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			kamera.position.z = min(kamera.position.z + zum_brzina, max_zum)
			if kamera.position.z > 0.1:
				$CharacterMain.visible = true

		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if moze_napasti:
				napadni()

	if event is InputEventMouseMotion and rotacija_misa:
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		kamera.rotate_x(deg_to_rad(-event.relative.y * mouse_sensitivity))
		kamera.rotation.x = clamp(kamera.rotation.x, deg_to_rad(-60), deg_to_rad(60))

func _physics_process(delta):
	if not is_multiplayer_authority():
		return
	if not is_on_floor():
		velocity.y += gravitacija * delta
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = 5.0
	var smer = Vector3.ZERO

	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		smer -= transform.basis.z
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		smer += transform.basis.z
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		smer -= transform.basis.x
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		smer += transform.basis.x

	smer = smer.normalized()
	velocity.x = smer.x * brzina
	velocity.z = smer.z * brzina

	move_and_slide()

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

@rpc("any_peer")
func primi_damage_od_neprijatelja(kolicina: int) -> void:
	if not _poziv_od_servera():
		return
	var hud = _hud()
	if hud:
		hud.primi_damage(kolicina)