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
		_osvezi_hp_label()

@onready var ime_label = $ImeLabel
@onready var hp_label = $HpLabel

var player: Node3D = null

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
	# U singleplayer-u (bez multiplayer sesije) svako je "autoritet".
	# U multiplayer-u, samo server sme da pokreće AI/damage.
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

func _osvezi_hp_label() -> void:
	if hp_label:
		hp_label.text = str(hp) + "/" + str(max_hp)

func _physics_process(delta):
	if not _ja_sam_autoritet():
		return

	if player == null or not is_instance_valid(player):
		if _je_multiplayer_aktivan():
			player = _nadji_najblizeg_igraca()
		else:
			player = get_tree().get_first_node_in_group("player")
		if player == null:
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

func primi_damage(kolicina):
	if not _ja_sam_autoritet():
		return
	hp -= kolicina
	hp = max(hp, 0)
	if hp == 0:
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
		var giver_id = str(player.name) if player else ""
		var hud = _nadji_hud_za(giver_id)
		if hud:
			hud.dodaj_xp(xp_nagrada)
		queue_free()

func _nadji_hud_za(peer_ime: String) -> Node:
	if not _je_multiplayer_aktivan():
		return get_tree().get_first_node_in_group("hud")
	if player == null:
		return null
	for hud in get_tree().get_nodes_in_group("hud"):
		if hud.is_multiplayer_authority():
			return hud
	return null

func napadni_igraca():
	moze_napasti = false
	if player and player.has_method("primi_damage_od_neprijatelja"):
		player.primi_damage_od_neprijatelja(napad_damage)
	else:
		var hud = get_tree().get_first_node_in_group("hud")
		if hud:
			hud.primi_damage(napad_damage)

	await get_tree().create_timer(napad_cooldown).timeout
	moze_napasti = true

# ---------------------------------------------------------------- RPC

@rpc("any_peer")
func zahtevaj_napad(damage: int) -> void:
	if not multiplayer.is_server():
		return
	var napadac_id = multiplayer.get_remote_sender_id()
	var napadac = get_parent().get_node_or_null(str(napadac_id))
	if napadac == null:
		return
	var distanca = global_position.distance_to(napadac.global_position)
	if distanca > 3.5:
		return
	primi_damage(damage)