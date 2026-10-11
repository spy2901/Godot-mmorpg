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

# Klijent (vlasnik lika) jednom pošalje ime lika, server učita statistike iz baze.
func posalji_lik_serveru(ime: String) -> void:
	if multiplayer.is_server():
		registruj_lik(ime)  # host: poziv je lokalan, nema RPC-a
	else:
		registruj_lik.rpc_id(1, ime)

@rpc("any_peer", "reliable")
func registruj_lik(ime: String) -> void:
	if not multiplayer.is_server():
		return
	# Samo vlasnik lika sme da registruje svoj lik
	var posiljalac := multiplayer.get_remote_sender_id()
	if posiljalac != 0 and posiljalac != get_multiplayer_authority():
		return
	ime_lika = ime
	_ucitaj_statistike_sa_servera(ime)

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
	print("[SERVER] Lik ", ime, " registrovan, damage: ", izracunaj_damage(), ", predmeta: ", vlasnistvo.size())

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
func primi_kill(tip_neprijatelja: String, xp: int) -> void:
	if not _poziv_od_servera():
		return
	var hud = _hud()
	if hud:
		hud.dodaj_xp(xp)
	QuestManager.azuriraj_progres_kill(tip_neprijatelja)

@rpc("any_peer")
func primi_damage_od_neprijatelja(kolicina: int) -> void:
	if not _poziv_od_servera():
		return
	var hud = _hud()
	if hud:
		hud.primi_damage(kolicina)