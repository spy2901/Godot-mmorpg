extends Node


const MAX_POKUSAJA := 3

func _zahtev(path: String, method: int = HTTPClient.METHOD_GET, body: Dictionary = {}, pokusaji: int = MAX_POKUSAJA, dodatni_headeri: PackedStringArray = [], sa_kljucem: bool = true) -> Variant:
	for pokusaj in pokusaji:
		var r = await _jedan_zahtev(path, method, body, dodatni_headeri, sa_kljucem)
		if r != null:
			return r
		if pokusaj < pokusaji - 1:
			await get_tree().create_timer(0.5 * (pokusaj + 1)).timeout
	return null

func _jedan_zahtev(path: String, method: int, body: Dictionary, dodatni_headeri: PackedStringArray, sa_kljucem: bool) -> Variant:
	var http = HTTPRequest.new()
	http.timeout = 8.0
	add_child(http)

	var headers: PackedStringArray = []
	var body_str := ""
	if method == HTTPClient.METHOD_POST:
		headers = ["Content-Type: application/json"]
		body_str = JSON.stringify(body)
	if sa_kljucem and Config.SERVER_KEY != "":
		headers.append("X-Server-Key: " + Config.SERVER_KEY)
	headers.append_array(dodatni_headeri)

	var err = http.request(Config.SERVER_URL + path, headers, method, body_str)
	if err != OK:
		print("[API] HTTP greška: ", path)
		http.queue_free()
		return null

	var response = await http.request_completed
	http.queue_free()

	if response[0] != HTTPRequest.RESULT_SUCCESS:
		print("[API] Server nedostupan: ", path)
		return null

	var json = JSON.new()
	if json.parse(response[3].get_string_from_utf8()) != OK:
		print("[API] Neispravan JSON: ", path)
		return null
	return json.get_data()

# ---------------------------------------------------------------- AUTH
# Javne rute bez server ključa i bez retry-a. Odgovor sa "error" se vraća kao Dictionary.

func register(username: String, password: String) -> Dictionary:
	var r = await _zahtev("/auth/register", HTTPClient.METHOD_POST, {"username": username, "password": password}, 1, [], false)
	return r if r is Dictionary else {"error": "Server unavailable"}

func login(username: String, password: String) -> Dictionary:
	var r = await _zahtev("/auth/login", HTTPClient.METHOD_POST, {"username": username, "password": password}, 1, [], false)
	return r if r is Dictionary else {"error": "Server unavailable"}

func logout(token: String) -> Dictionary:
	var r = await _zahtev("/auth/logout", HTTPClient.METHOD_POST, {}, 1, ["Authorization: Bearer " + token], false)
	return r if r is Dictionary else {"error": "Server unavailable"}

# Zaštićeno (X-Server-Key): zove samo game server
func verify_token(token: String) -> Dictionary:
	var r = await _zahtev("/auth/verify", HTTPClient.METHOD_POST, {"token": token})
	return r if r is Dictionary else {"error": "Login server unavailable"}

# ---------------------------------------------------------------- ITEMS

func get_item(item_id: String) -> Dictionary:
	var r = await _zahtev("/items/" + item_id)
	return r if r is Dictionary else {}

func get_all_items() -> Array:
	var r = await _zahtev("/items")
	if r is Dictionary:
		return r.get("items", [])
	return []

# ---------------------------------------------------------------- QUESTS

func get_quest(quest_id: String) -> Dictionary:
	var r = await _zahtev("/quests/" + quest_id)
	return r if r is Dictionary else {}

func get_all_quests() -> Array:
	var r = await _zahtev("/quests")
	if r is Dictionary:
		return r.get("quests", [])
	return []

# Zaštićeno (X-Server-Key): zove samo game server
func get_completed_quests(ime: String) -> Array:
	var r = await _zahtev("/quests/completed/" + ime)
	if r is Dictionary:
		return r.get("completed", [])
	return []

# ---------------------------------------------------------------- PLAYERS (zove samo game server)

func get_player(ime: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime)
	return r if r is Dictionary else {}

func save_player(ime: String, data: Dictionary) -> bool:
	var r = await _zahtev("/players/" + ime + "/save", HTTPClient.METHOD_POST, data)
	return r is Dictionary and r.get("status", "") == "ok"

# ---------------------------------------------------------------- INVENTAR (bez retry-a)

func promeni_inventar(ime: String, item_id: String, delta: int) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/inventory/change", HTTPClient.METHOD_POST, {"item_id": item_id, "delta": delta}, 1)
	return r if r is Dictionary else {}

# ---------------------------------------------------------------- SERVER (zove samo game server, bez retry-a)

func promeni_xp(ime: String, delta: int, razlog: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/xp/change", HTTPClient.METHOD_POST, {"delta": delta, "razlog": razlog}, 1)
	return r if r is Dictionary else {}

func koristi_item(ime: String, item_id: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/item/use", HTTPClient.METHOD_POST, {"item_id": item_id}, 1)
	return r if r is Dictionary else {}

func sacuvaj_action_bar(ime: String, slotovi: Array) -> bool:
	var r = await _zahtev("/players/" + ime + "/action_bar", HTTPClient.METHOD_POST, {"slotovi": slotovi}, 1)
	return r is Dictionary and r.get("status", "") == "ok"

func kupi_item(ime: String, item_id: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/shop/buy", HTTPClient.METHOD_POST, {"item_id": item_id, "kolicina": 1}, 1)
	return r if r is Dictionary else {}

func prihvati_quest_server(ime: String, quest_id: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/quest/accept", HTTPClient.METHOD_POST, {"quest_id": quest_id}, 1)
	return r if r is Dictionary else {}

func zabelezi_kill_server(ime: String, tip: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/quest/kill", HTTPClient.METHOD_POST, {"tip": tip}, 1)
	return r if r is Dictionary else {}

func odustani_quest_server(ime: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/quest/abandon", HTTPClient.METHOD_POST, {}, 1)
	return r if r is Dictionary else {}

func predaj_quest_server(ime: String, quest_id: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime + "/quest/turnin", HTTPClient.METHOD_POST, {"quest_id": quest_id}, 1)
	return r if r is Dictionary else {}
