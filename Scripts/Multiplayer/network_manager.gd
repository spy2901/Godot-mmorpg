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
	# Bez server relay-a: klijenti ne šalju jedni drugima (sve ide preko servera). Sa relay-em Godot pri
	# odlasku peer-a A šalje DEL_PEER ostalima (kanal 0) pre nego što ENet ukloni i peer-a B koji je otišao
	# u istom paketu -> "Unable to send packet on channel 0, max channels: 0". Mora pre multiplayer_peer.
	(multiplayer as SceneMultiplayer).server_relay = false
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
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# ENet throttle (podrazumevano interval 5000 ms, ubrzanje 2, usporenje 2) odbacuje nepouzdane pakete kad RTT pouzdanih
# poraste iznad najmanjeg RTT-a iz prethodnog intervala + 2 * varijansa; već podrhtavanje RTT-a od nekoliko ms ga spusti na 0,
# kad ENet propušta 1 od 32 paketa. Unosi (klijent -> server) i stanja (server -> klijent) su nepouzdani i mali (jedan
# paket po tick-u, desetine bajtova), a gubitak već pokriva redundansa (UNOSA_NEPOTVRDJENIH_MAX); throttle ne rasterećuje
# mrežu, samo pravi rupe. Usporenje 0: throttle ostaje na PACKET_THROTTLE_SCALE (sve se šalje), ubrzanje SCALE: ako je
# pre podešavanja pao, odmah se vrati. Pouzdan saobraćaj ima svoj prozor i na njega ovo ne utiče.
# Samo klijent (unosi ka serveru): ENet šalje THROTTLE_CONFIGURE drugoj strani, pa server za tu vezu dobije isto podešavanje
# (izmereno: serverski peer [5000, 32, 0], throttle ka klijentu stalno 32). Serverski poziv je bio suvišan.
func _bez_throttle(pp: ENetPacketPeer) -> void:
	if pp != null:
		pp.throttle_configure(5000, ENetPacketPeer.PACKET_THROTTLE_SCALE, 0)

func _enet_peer(id: int) -> ENetPacketPeer:
	var mp := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	return mp.get_peer(id) if mp != null else null

func _on_connected_to_server() -> void:
	print("[NET] Povezan na server kao ID ", multiplayer.get_unique_id())
	_bez_throttle(_enet_peer(1))
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

# Klijent: server je otišao. Peer se odmah skida (null), da _process ne zove zatvoren peer.
func _on_server_disconnected() -> void:
	print("[NET] Veza sa serverom je prekinuta")
	prekini()
	GameState.token = ""
	GameState.poruka_logina = "Lost connection to the server"
	get_tree().change_scene_to_file("res://Scenes/UI/MainMenu.tscn")

func _on_peer_connected(id: int) -> void:
	print("[NET] Peer povezan: ", id)
	emit_signal("peer_connected", id)

func _on_peer_disconnected(id: int) -> void:
	print("[NET] Peer diskonektovan: ", id)
	emit_signal("peer_disconnected", id)