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
	_povezi_signale()
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
	_povezi_signale()
	return true

# Posle odjave se ponovo hostuje/pridružuje, pa signali smeju da se povežu samo jednom
func _povezi_signale() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		return
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)

func _on_connected_to_server() -> void:
	print("[NET] Povezan na server kao ID ", multiplayer.get_unique_id())
	emit_signal("connected_to_server")

func _on_connection_failed() -> void:
	print("[NET] Konekcija neuspešna")
	emit_signal("connection_failed")

# Server: diskonektuje peer-a posle kratke pauze (da reliable RPC stigne pre prekida)
func izbaci_peer(id: int, pauza: float = 0.2) -> void:
	await get_tree().create_timer(pauza).timeout
	if multiplayer.multiplayer_peer and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)

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