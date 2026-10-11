extends Node


func _zahtev(path: String, method: int = HTTPClient.METHOD_GET, body: Dictionary = {}) -> Variant:
	var http = HTTPRequest.new()
	add_child(http)

	var headers: PackedStringArray = []
	var body_str := ""
	if method == HTTPClient.METHOD_POST:
		headers = ["Content-Type: application/json"]
		body_str = JSON.stringify(body)

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

func complete_quest(ime: String, quest_id: String) -> Dictionary:
	var r = await _zahtev("/quests/" + quest_id + "/complete/" + ime, HTTPClient.METHOD_POST)
	return r if r is Dictionary else {}

func get_completed_quests(ime: String) -> Array:
	var r = await _zahtev("/quests/completed/" + ime)
	if r is Dictionary:
		return r.get("completed", [])
	return []

# ---------------------------------------------------------------- PLAYERS

func get_player(ime: String) -> Dictionary:
	var r = await _zahtev("/players/" + ime)
	return r if r is Dictionary else {}

func save_player(ime: String, data: Dictionary) -> bool:
	var r = await _zahtev("/players/" + ime + "/save", HTTPClient.METHOD_POST, data)
	return r is Dictionary and r.get("status", "") == "ok"
