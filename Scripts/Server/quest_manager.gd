extends Node

var aktivni_quest: Dictionary = {}
var progres: int = 0
var quest_zavrsen: bool = false
var zavrseni_questovi: Array = []
var ime_igraca: String = ""
var zadnja_greska := ""

signal quest_prihvacen(quest: Dictionary)
signal quest_progres_azuriran(trenutno: int, ukupno: int)
signal quest_zavrsen_signal(quest: Dictionary)
signal quest_odustao()


func _inventory():
	return get_tree().get_first_node_in_group("inventory")

func _online() -> bool:
	return multiplayer.multiplayer_peer != null

# Lik ovog klijenta: TopBar (hud) → ui → Player
func _igrac():
	var hud = get_tree().get_first_node_in_group("hud")
	if hud == null or hud.get_parent() == null:
		return null
	return hud.get_parent().get_parent()

func _oznaci_promenu() -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("oznaci_promenu"):
		hud.oznaci_promenu()

# ---------------------------------------------------------------- PRIHVATANJE

func prihvati_quest(quest: Dictionary) -> void:
	zadnja_greska = ""
	if not aktivni_quest.is_empty():
		print("[QUEST] Vec imas aktivan quest: %s" % aktivni_quest.get("naziv", ""))
		return
	if _online():
		var igrac = _igrac()
		var o: Dictionary = {"ok": false, "poruka": "Character not found"}
		if igrac:
			o = await igrac.prihvati_quest_na_serveru(str(quest.get("id", "")))
		if not o.get("ok", false):
			zadnja_greska = str(o.get("poruka", ""))
			print("[QUEST] Prihvat odbijen: %s" % zadnja_greska)
			DialogueUI.open("Quest", [zadnja_greska])
			return
	_lokalno_prihvati(quest)

func _lokalno_prihvati(quest: Dictionary) -> void:
	aktivni_quest = quest
	progres = 0
	quest_zavrsen = false
	print("[QUEST] Prihvacen quest: %s" % quest.get("naziv", ""))
	emit_signal("quest_prihvacen", quest)
	if quest.get("tip", "") == "fetch":
		osvezi_fetch_progres()  # racuna ono sto vec imas u torbi
	_oznaci_promenu()

# ---------------------------------------------------------------- PROGRES

func _postavi_progres(novi: int, oznaka: String) -> void:
	var kolicina = int(aktivni_quest.get("kolicina", 0))
	novi = clamp(novi, 0, kolicina)
	var novo_zavrsen = novi >= kolicina
	if novi == progres and novo_zavrsen == quest_zavrsen:
		return
	progres = novi
	print("[QUEST] Progres: %d/%d (%s)" % [progres, kolicina, oznaka])
	emit_signal("quest_progres_azuriran", progres, kolicina)
	var bio_zavrsen = quest_zavrsen
	quest_zavrsen = novo_zavrsen
	if quest_zavrsen and not bio_zavrsen:
		print("[QUEST] Quest završen: %s" % aktivni_quest.get("naziv", ""))
		emit_signal("quest_zavrsen_signal", aktivni_quest)
	_oznaci_promenu()

func azuriraj_progres_kill(tip_neprijatelja: String) -> void:
	if aktivni_quest.is_empty() or quest_zavrsen:
		return
	if aktivni_quest.get("tip", "") != "kill":
		return
	if aktivni_quest.get("cilj", "") != tip_neprijatelja:
		return
	_postavi_progres(progres + 1, tip_neprijatelja)

# Fetch progres = koliko cilj-itema ima u inventoriju. Poziva se iz InventoryUI
# pri svakoj promeni, tako da radi i za kupovinu, drop, drag&drop...
func osvezi_fetch_progres() -> void:
	if aktivni_quest.is_empty() or aktivni_quest.get("tip", "") != "fetch":
		return
	var inv = _inventory()
	if inv == null:
		return
	var cilj = str(aktivni_quest.get("cilj", ""))
	_postavi_progres(inv.prebroj_item(cilj), cilj)

# Kompatibilnost sa item.gd (stari poziv) — samo osvezi iz inventorija
func azuriraj_progres_fetch(_item_id: String) -> void:
	osvezi_fetch_progres()

# ---------------------------------------------------------------- PREDAJA

func predaj_quest() -> Dictionary:
	zadnja_greska = ""
	if aktivni_quest.is_empty():
		return {}
	if not quest_zavrsen:
		print("[QUEST] Quest nije završen! Progres: %d/%d" % [progres, aktivni_quest.get("kolicina", 0)])
		return {}

	var zavrsen = aktivni_quest.duplicate()
	var quest_id = str(zavrsen.get("id", ""))
	var inv = _inventory()
	var hud = get_tree().get_first_node_in_group("hud")

	if _online():
		# server proverava i isplaćuje; ovde je samo lokalno ogledalo
		var igrac = _igrac()
		var o: Dictionary = {"ok": false, "poruka": "Character not found"}
		if igrac:
			o = await igrac.predaj_quest_na_serveru(quest_id)
		if not o.get("ok", false):
			zadnja_greska = str(o.get("poruka", ""))
			print("[QUEST] Predaja odbijena: %s" % zadnja_greska)
			return {}
		if zavrsen.get("tip", "") == "fetch" and inv:
			inv.ukloni_item(str(zavrsen.get("cilj", "")), int(zavrsen.get("kolicina", 1)))
		if hud:
			hud.postavi_gold(int(o.get("gold", hud.gold)))
			var stats: Dictionary = o.get("stats", {})
			if not stats.is_empty():
				hud.primeni_stats(stats)  # XP je server već upisao, lokalno se ne dodaje
		var nagrada: Dictionary = o.get("nagrada", {})
		var item = nagrada.get("item")
		if item != null and str(item) != "" and inv:
			inv.dodaj_item_u_slot(str(item))
	else:
		# Offline: lokalno skidanje fetch itema i isplata nagrade
		if zavrsen.get("tip", "") == "fetch":
			var cilj = str(zavrsen.get("cilj", ""))
			var kolicina = int(zavrsen.get("kolicina", 1))
			if inv == null or not inv.ukloni_item(cilj, kolicina):
				print("[QUEST] Nemaš dovoljno %s za predaju!" % cilj)
				return {}
		if hud:
			hud.dodaj_gold(int(zavrsen.get("nagrada_gold", 0)))
		var item = zavrsen.get("nagrada_item")
		if item != null and str(item) != "" and inv:
			inv.dodaj_item_u_slot(str(item))

	if quest_id != "" and not zavrseni_questovi.has(quest_id):
		zavrseni_questovi.append(quest_id)

	aktivni_quest = {}
	progres = 0
	quest_zavrsen = false
	print("[QUEST] Quest predat: %s" % zavrsen.get("naziv", ""))
	_oznaci_promenu()
	return zavrsen

func odustani_quest() -> void:
	if aktivni_quest.is_empty():
		return
	print("[QUEST] Odustao od questa: %s" % aktivni_quest.get("naziv", ""))
	if _online():
		var igrac = _igrac()
		if igrac:
			igrac.odustani_quest_na_serveru()
	aktivni_quest = {}
	progres = 0
	quest_zavrsen = false
	emit_signal("quest_odustao")
	_oznaci_promenu()
# ---------------------------------------------------------------- STANJE

func ima_aktivan_quest() -> bool:
	return not aktivni_quest.is_empty()

func je_quest_zavrsen() -> bool:
	return quest_zavrsen

func je_quest_vec_zavrsen(quest_id: String) -> bool:
	return quest_id in zavrseni_questovi

# ---------------------------------------------------------------- SAVE / LOAD

func serijalizuj() -> Dictionary:
	if aktivni_quest.is_empty():
		return {"aktivni_quest_id": null, "quest_progres": 0}
	return {
		"aktivni_quest_id": str(aktivni_quest.get("id", "")),
		"quest_progres": progres
	}

func ucitaj_stanje(quest_id: String, sacuvan_progres: int) -> void:
	if quest_id == "":
		return
	var quest: Dictionary = await ApiManager.get_quest(quest_id)
	if quest.is_empty() or quest.has("error"):
		print("[QUEST] Ne mogu da učitam sačuvan quest: %s" % quest_id)
		return
	aktivni_quest = quest
	if quest.get("tip", "") == "fetch":
		progres = 0
		quest_zavrsen = false
		osvezi_fetch_progres()  # inventory je vec ucitan pre ovoga
	else:
		progres = sacuvan_progres
		quest_zavrsen = progres >= int(quest.get("kolicina", 1))
	print("[QUEST] Učitan aktivan quest: %s (%d/%d)" % [quest.get("naziv", ""), progres, quest.get("kolicina", 1)])
	emit_signal("quest_prihvacen", quest)

func ucitaj_zavrsene(ime: String, lista: Array) -> void:
	ime_igraca = ime
	zavrseni_questovi = lista
	print("[QUEST] Učitano završenih questova: %d" % zavrseni_questovi.size())
