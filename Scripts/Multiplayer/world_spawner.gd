extends Node3D

const PLAYER_SCENE = preload("res://Scenes/player.tscn")

@onready var spawner := $MultiplayerSpawner

func _ready() -> void:
	spawner.spawn_function = _spawn_player
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func pokreni_spawn_za_mene() -> void:
	if NetworkManager.je_server() and not has_node("1"):
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
