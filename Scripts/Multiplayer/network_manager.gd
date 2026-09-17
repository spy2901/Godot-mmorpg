extends Node

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 8

signal server_started()
signal connected_to_server()
signal connection_failed()
signal peer_connected(id: int)
signal peer_disconnected(id: int)

func hostuj(port: int = DEFAULT_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS)
	if err != OK:
		print("[NET] Ne mogu da pokrenem server: ", err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("[NET] Server pokrenut na portu ", port, " (moj ID: ", multiplayer.get_unique_id(), ")")
	emit_signal("server_started")
	return true

func pridruzi_se(ip: String, port: int = DEFAULT_PORT) -> bool:
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		print("[NET] Ne mogu da se povežem: ", err)
		return false
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func():
		print("[NET] Povezan na server kao ID ", multiplayer.get_unique_id())
		emit_signal("connected_to_server")
	)
	multiplayer.connection_failed.connect(func():
		print("[NET] Konekcija neuspešna")
		emit_signal("connection_failed")
	)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	return true

func prekini() -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

func je_server() -> bool:
	return multiplayer.multiplayer_peer != null and multiplayer.is_server()

func _on_peer_connected(id: int) -> void:
	print("[NET] Peer povezan: ", id)
	emit_signal("peer_connected", id)

func _on_peer_disconnected(id: int) -> void:
	print("[NET] Peer diskonektovan: ", id)
	emit_signal("peer_disconnected", id)