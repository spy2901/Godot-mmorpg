extends Node3D

const PLAYER_SCENE = preload("res://Scenes/player.tscn")
const ENEMY_SCENES := {
	"goblin": preload("res://Scenes/Enemies/goblin.tscn"),
	"skeleton": preload("res://Scenes/Enemies/skeleton.tscn"),
	"troll": preload("res://Scenes/Enemies/troll.tscn"),
}
const RESPAWN_DELAY := 5.0

@onready var spawner := $MultiplayerSpawner
@onready var goblin_spawner := $GoblinSpawner  # spawner za sve neprijatelje

var _enemy_counter := 0
var _aktivno := false
var _zivi := {}     # spawn_tacka -> Node neprijatelja koji je trenutno živ
var _cekanje := {}  # spawn_tacka -> preostalo vreme do sledećeg spawna

func _ready() -> void:
	spawner.spawn_function = _spawn_player
	goblin_spawner.spawn_function = _spawn_enemy
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func pokreni_spawn_za_mene() -> void:
	if NetworkManager.je_server():
		_spawn_za(1)

# Server poziva ovo kad krene da sluša. Od tog trenutka tačke održavaju neprijatelje.
func pokreni_spawn_tacke() -> void:
	if NetworkManager.je_server():
		_aktivno = true

func _process(delta: float) -> void:
	if not _aktivno:
		return
	for tacka in get_tree().get_nodes_in_group("spawn_tacka"):
		var zivi = _zivi.get(tacka)
		if is_instance_valid(zivi):
			continue
		if _zivi.has(tacka):  # bio je živ, sad je mrtav
			_zivi.erase(tacka)
			_cekanje[tacka] = RESPAWN_DELAY
		if not _cekanje.has(tacka):
			_cekanje[tacka] = 0.0  # prvi spawn odmah
		_cekanje[tacka] -= delta
		if _cekanje[tacka] <= 0.0:
			_cekanje.erase(tacka)
			var novi = _spawn_na_tacki(tacka)
			if novi:
				_zivi[tacka] = novi

func _spawn_na_tacki(tacka: Node3D) -> Node:
	var vrsta: String = tacka.vrsta
	if not ENEMY_SCENES.has(vrsta):
		print("[SPAWN] Nepoznata vrsta na tački: ", vrsta)
		return null
	_enemy_counter += 1
	print("[SPAWN] ", vrsta, " na ", tacka.name, " (", tacka.position, ")")
	return goblin_spawner.spawn({"vrsta": vrsta, "id": _enemy_counter, "pos": tacka.position, "nivo": tacka.nivo})

# Ručni spawn goblina (dugme u test meniju)
func spawn_goblin() -> void:
	if not NetworkManager.je_server():
		return
	_enemy_counter += 1
	goblin_spawner.spawn({
		"vrsta": "goblin",
		"id": _enemy_counter,
		"pos": Vector3(randf_range(6, 10), 2, randf_range(6, 10)),
	})

func _spawn_enemy(data: Dictionary) -> Node:
	var enemy = ENEMY_SCENES[data["vrsta"]].instantiate()
	enemy.name = "%s_%d" % [data["vrsta"], data["id"]]
	enemy.get_node("CharacterBody3D").nivo = int(data.get("nivo", 1)) # i na klijentu (spawn podaci), pre _ready
	enemy.position = data["pos"]
	return enemy

func _on_peer_connected(id: int) -> void:
	if NetworkManager.je_server():
		_spawn_za(id)

func _on_peer_disconnected(id: int) -> void:
	var p = get_node_or_null(str(id))
	if p == null:
		return
	if p.has_method("server_sacuvaj_konacno"):
		# van grupe i sakriven dok čekamo backend, da ga neprijatelji ne vide
		p.remove_from_group("player")
		p.hide()
		p.set_physics_process(false) # bez simulacije i primi_stanje ka peer-u koji je otišao
		await p.server_sacuvaj_konacno()
	if is_instance_valid(p):
		p.queue_free()

func _spawn_za(id: int) -> void:
	spawner.spawn(id)

# Spawn tačka igrača (i respawn posle smrti): promeni IGRAC_SPAWN da pomeriš sve odjednom
const IGRAC_SPAWN := Vector3(0, 1, 0)

func spawn_pozicija() -> Vector3:
	return IGRAC_SPAWN + Vector3(randf_range(-2, 2), 0, randf_range(-2, 2))

func _spawn_player(id: int) -> Node:
	var player = PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id)
	player.position = spawn_pozicija()
	return player

@rpc("call_local", "reliable")
func despawn_goblin(goblin_name: String) -> void:
	var g = get_node_or_null(goblin_name)
	if g:
		g.queue_free()

func despawn_goblin_svima(goblin_name: String) -> void:
	if not multiplayer.is_server():
		return
	despawn_goblin.rpc(goblin_name)