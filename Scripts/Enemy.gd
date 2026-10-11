extends CharacterBody3D

# ENEMY BASE CLASS

@export var ime = "Neprijatelj"
@export var max_hp = 100
@export var brzina = 2.0
@export var napad_damage = 10
@export var aggro_range = 10.0
@export var napad_range = 2.0
@export var xp_nagrada = 50
@export var napad_cooldown = 2.0
@export var loot_tabela = [
	{"id": "goblin_ear", "sansa": 100},
	{"id": "iron_ore", "sansa": 50},
	{"id": "bronze_coin", "sansa": 75},
	{"id": "rusty_sword", "sansa": 10}
]
@export var moze_napasti = true

var hp = 100:
	set(value):
		hp = value
		if is_instance_valid(hp_label):
			_osvezi_hp_label()

@onready var ime_label = $ImeLabel
@onready var hp_label = $HpLabel

var player: Node3D = null
var napadaci: Array = []  # peer ID-jevi koji su naneli damage (dobijaju XP)
var _mrtav := false

const RETARGET_INTERVAL := 0.5
var _retarget_timer := 0.0

func _ready():
	add_to_group("neprijatelj")
	hp = max_hp
	ime_label.text = ime
	ime_label.position = Vector3(0, 2.2, 0)
	ime_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hp_label.position = Vector3(0, 2.0, 0)
	hp_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_osvezi_hp_label()

	if _je_multiplayer_aktivan():
		player = _nadji_najblizeg_igraca()
	else:
		player = get_tree().get_first_node_in_group("player")

func _je_multiplayer_aktivan() -> bool:
	return multiplayer.multiplayer_peer != null

func _ja_sam_autoritet() -> bool:
	if not _je_multiplayer_aktivan():
		return true
	return multiplayer.is_server()

func _nadji_najblizeg_igraca() -> Node3D:
	var najblizi: Node3D = null
	var min_dist = INF
	for p in get_tree().get_nodes_in_group("player"):
		var d = global_position.distance_to(p.global_position)
		if d < min_dist:
			min_dist = d
			najblizi = p
	return najblizi

func _nadji_igraca_po_id(peer_id: int) -> Node:
	for p in get_tree().get_nodes_in_group("player"):
		if p.get_multiplayer_authority() == peer_id:
			return p
	return null

func _osvezi_hp_label() -> void:
	if hp_label:
		hp_label.text = str(hp) + "/" + str(max_hp)

func _physics_process(delta):
	if not _ja_sam_autoritet():
		return

	_retarget_timer -= delta
	if _retarget_timer <= 0.0:
		_retarget_timer = RETARGET_INTERVAL
		player = _nadji_najblizeg_igraca_u_aggro()

	if player == null or not is_instance_valid(player):
		velocity.x = 0
		velocity.z = 0
		if not is_on_floor():
			velocity.y -= 9.8 * delta
		move_and_slide()
		return

	var distanca = global_position.distance_to(player.global_position)

	if not is_on_floor():
		velocity.y -= 9.8 * delta

	if distanca <= aggro_range:
		var smer = (player.global_position - global_position).normalized()
		if distanca > napad_range:
			velocity.x = smer.x * brzina
			velocity.z = smer.z * brzina
		else:
			velocity.x = 0
			velocity.z = 0
			if moze_napasti:
				napadni_igraca()
	else:
		velocity.x = 0
		velocity.z = 0

	move_and_slide()

# Najbliži igrač unutar aggro_range, ili null
func _nadji_najblizeg_igraca_u_aggro() -> Node3D:
	var najblizi: Node3D = null
	var min_dist = aggro_range
	for p in get_tree().get_nodes_in_group("player"):
		var d = global_position.distance_to(p.global_position)
		if d <= min_dist:
			min_dist = d
			najblizi = p
	return najblizi

func primi_damage(kolicina, napadac_id: int = 0):
	if not _ja_sam_autoritet() or _mrtav:
		return
	if napadac_id != 0 and not napadaci.has(napadac_id):
		napadaci.append(napadac_id)
	hp -= kolicina
	hp = max(hp, 0)
	print("[HIT] ", ime, " -", kolicina, " -> hp ", hp)
	if hp == 0:
		_mrtav = true
		print("[DEATH] ", ime)
		if _je_multiplayer_aktivan():
			_isplati_personal_loot()
			_isplati_kill()
			var goblin_root = get_parent()  # Node3D wrapper
			var world = goblin_root.get_parent() if goblin_root else null
			if world and world.has_method("despawn_goblin_svima"):
				world.despawn_goblin_svima(goblin_root.name)
			elif goblin_root:
				goblin_root.queue_free()
		else:
			_drop_fizicki_loot()
			var hud = get_tree().get_first_node_in_group("hud")
			if hud:
				hud.dodaj_xp(xp_nagrada)
			QuestManager.azuriraj_progres_kill(ime.to_lower())
			queue_free()

@rpc("call_local", "reliable")
func _obavesti_smrt() -> void:
	pass  # samo "reliable" okidač da se despawn sigurno propagira i pre nego što queue_free stigne

func _drop_fizicki_loot() -> void:
	for loot in loot_tabela:
		var roll = randi() % 100 + 1
		if roll <= loot["sansa"]:
			var item_scena = load("res://Scenes/Items/item.tscn")
			var item = item_scena.instantiate()
			item.ime_itema = loot["id"]
			get_tree().root.add_child(item)
			item.global_position = global_position + Vector3(
				randf_range(-1.0, 1.0),
				0.5,
				randf_range(-1.0, 1.0)
			)

func _isplati_personal_loot() -> void:
	if not multiplayer.is_server():
		return
	var peers: Array = multiplayer.get_peers()
	if not peers.has(1) and not OS.has_feature("dedicated_server"):
		peers.append(1)  # host igra i sam
	print("[LOOT] ", ime, " umro, peers: ", peers)

	for peer_id in peers:
		var igrac = _nadji_igraca_po_id(peer_id)
		if igrac == null or not igrac.has_method("server_isplati_loot"):
			print("[LOOT] Nema igrača za peer ", peer_id)
			continue
		# bacanje kockica je sinhrono, a upis u bazu preuzima igrač
		var dobijeno: Array = []
		for loot in loot_tabela:
			if randi() % 100 + 1 <= loot["sansa"]:
				dobijeno.append(loot["id"])
		if not dobijeno.is_empty():
			igrac.server_isplati_loot(dobijeno)

# XP + kill progres za sve koji su naneli damage
func _isplati_kill() -> void:
	for peer_id in napadaci:
		var igrac = _nadji_igraca_po_id(peer_id)
		if igrac == null:
			continue
		igrac.server_zabelezi_kill(ime.to_lower())
		if peer_id == multiplayer.get_unique_id():
			igrac.primi_kill(ime.to_lower(), xp_nagrada)
		else:
			igrac.primi_kill.rpc_id(peer_id, ime.to_lower(), xp_nagrada)

func napadni_igraca():
	moze_napasti = false
	if _je_multiplayer_aktivan():
		var peer_id = player.get_multiplayer_authority()
		if peer_id == multiplayer.get_unique_id():
			player.primi_damage_od_neprijatelja(napad_damage)
		else:
			player.primi_damage_od_neprijatelja.rpc_id(peer_id, napad_damage)
	else:
		var hud = get_tree().get_first_node_in_group("hud")
		if hud:
			hud.primi_damage(napad_damage)

	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true

@rpc("any_peer")
func zahtevaj_napad() -> void:
	if not multiplayer.is_server():
		return
	var napadac_id = multiplayer.get_remote_sender_id()
	var napadac = _nadji_igraca_po_id(napadac_id)
	if napadac == null:
		print("[HIT] Napadač nije pronađen, ID: ", napadac_id)
		return
	var distanca = global_position.distance_to(napadac.global_position)
	print("[HIT] ", ime, " napadnut od ", napadac_id, ", distanca: ", snappedf(distanca, 0.01))
	if distanca > 3.5:
		print("[HIT] Predaleko, odbijeno")
		return
	# damage računa server: baza lika + bonus oružja
	primi_damage(napadac.izracunaj_damage(), napadac_id)