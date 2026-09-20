extends Node3D

const PLAYER_SCENE = preload("res://Scenes/player.tscn")
const GOBLIN_SCENE = preload("res://Scenes/Enemies/goblin.tscn")

@onready var spawner := $MultiplayerSpawner
@onready var goblin_spawner := $GoblinSpawner

var _goblin_counter := 0

func _ready() -> void:
	spawner.spawn_function = _spawn_player
	goblin_spawner.spawn_function = _spawn_goblin
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func pokreni_spawn_za_mene() -> void:
	if NetworkManager.je_server():
		_spawn_za(1)

func _on_peer_connected(id: int) -> void:
	if NetworkManager.je_server():
		_spawn_za(id)

func _on_peer_disconnected(id: int) -> void:
	var p = get_node_or_null(str(id))
	if p:
		p.queue_free()

func _spawn_za(id: int) -> void:
	spawner.spawn(id)

func _spawn_player(id: int) -> Node:
	var player = PLAYER_SCENE.instantiate()
	player.name = str(id)
	player.set_multiplayer_authority(id)
	player.position = Vector3(randf_range(-2, 2), 1, randf_range(-2, 2))
	return player

func spawn_goblin() -> void:
	if not NetworkManager.je_server():
		return
	_goblin_counter += 1
	goblin_spawner.spawn(_goblin_counter)

func _spawn_goblin(id: int) -> Node:
	var goblin = GOBLIN_SCENE.instantiate()
	goblin.name = "goblin_%d" % id
	goblin.position = Vector3(randf_range(6, 10), 2, randf_range(6, 10))
	return goblin

@rpc("call_local", "reliable")
func despawn_goblin(goblin_name: String) -> void:
	var g = get_node_or_null(goblin_name)
	if g:
		g.queue_free()

func despawn_goblin_svima(goblin_name: String) -> void:
	if not multiplayer.is_server():
		return
	despawn_goblin.rpc(goblin_name)