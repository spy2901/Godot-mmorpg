extends Node

const SERVER_URL = "http://localhost:8000"

func get_item(item_id: String) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	
	var error = http.request(SERVER_URL + "/items/" + item_id)
	if error != OK:
		print("HTTP greška!")
		return {}
	
	var response = await http.request_completed
	var json = JSON.new()
	json.parse(response[3].get_string_from_utf8())
	var result = json.get_data()
	
	http.queue_free()
	return result

func get_all_items() -> Array:
	var http = HTTPRequest.new()
	add_child(http)
	
	var error = http.request(SERVER_URL + "/items")
	if error != OK:
		print("HTTP greška!")
		return []
	
	var response = await http.request_completed
	var json = JSON.new()
	json.parse(response[3].get_string_from_utf8())
	var result = json.get_data()
	
	http.queue_free()
	return result.get("items", [])

func get_quest(quest_id: String) -> Dictionary:
	var http = HTTPRequest.new()
	add_child(http)
	
	var error = http.request(SERVER_URL + "/quests/" + quest_id)
	if error != OK:
		print("HTTP greška!")
		return {}
	
	var response = await http.request_completed
	var json = JSON.new()
	json.parse(response[3].get_string_from_utf8())
	var result = json.get_data()
	
	http.queue_free()
	return result

func get_all_quests() -> Array:
	var http = HTTPRequest.new()
	add_child(http)
	
	var error = http.request(SERVER_URL + "/quests")
	if error != OK:
		print("HTTP greška!")
		return []
	
	var response = await http.request_completed
	var json = JSON.new()
	json.parse(response[3].get_string_from_utf8())
	var result = json.get_data()
	
	http.queue_free()
	return result.get("quests", [])


func complete_quest(ime: String, quest_id: String) -> Dictionary:
	var r = await _zahtev("/quests/" + quest_id + "/complete/" + ime, HTTPClient.METHOD_POST)
	return r if r is Dictionary else {}

func get_completed_quests(ime: String) -> Array:
	var r = await _zahtev("/quests/completed/" + ime)
	if r is Dictionary:
		return r.get("completed", [])
	return []
