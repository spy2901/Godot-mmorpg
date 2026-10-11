extends Control

@onready var label_ime = $"Label (Name)"
@onready var hp_bar = $"ProgressBar(HP)"
@onready var mana_bar = $"ProgressBar(Mana_Resurce)"
@onready var xp_bar = $"ProgressBar(XP)"
@onready var inventory_ui = $"../InventoryUI"

var hp = 100
var mana = 100
var ime_igraca: String = GameState.ime_igraca if GameState.ime_igraca != "" else "Spajko"
var max_hp = 100
var max_mana = 100
var hp_regen = 2.0
var mana_regen = 3.0
var vreme = 0.0

var xp = 0
var max_xp = 100
var level = 1

var gold = 100
var gold_label: Label

# Quest tracker
var quest_tracker: Label
var quest_abandon_btn: Button

# Respawn
var spawn_pozicija: Vector3 = Vector3.ZERO
var je_mrtav: bool = false
var neosjetljiv: bool = false

# Save / load
const AUTOSAVE_INTERVAL = 30.0
const DIRTY_SAVE_DELAY = 3.0
var _ucitano: bool = false
var _dirty: bool = false
var _dirty_timer: float = 0.0
var _autosave_timer: float = 0.0
var _saving: bool = false

func _ready():
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	add_to_group("hud")
	get_tree().auto_accept_quit = false

	label_ime.text = ime_igraca + "  Lv." + str(level)
	label_ime.position = Vector2(20, 5)

	# HP bar
	hp_bar.max_value = max_hp
	hp_bar.value = hp
	hp_bar.custom_minimum_size = Vector2(325, 50)
	hp_bar.position = Vector2(20, 85)
	hp_bar.show_percentage = false
	var hp_label := Label.new()
	hp_label.name = "HPLabel"
	hp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_label.add_theme_color_override("font_color", Color.WHITE)
	hp_label.add_theme_font_size_override("font_size", 16)
	hp_bar.add_child(hp_label)

	# Mana bar
	mana_bar.max_value = max_mana
	mana_bar.value = mana
	mana_bar.custom_minimum_size = Vector2(325, 50)
	mana_bar.position = Vector2(20, 140)
	mana_bar.show_percentage = false
	var mana_label := Label.new()
	mana_label.name = "ManaLabel"
	mana_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	mana_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	mana_label.add_theme_color_override("font_color", Color.WHITE)
	mana_label.add_theme_font_size_override("font_size", 16)
	mana_bar.add_child(mana_label)

	# XP bar
	xp_bar.custom_minimum_size = Vector2(325, 20)
	xp_bar.position = Vector2(20, 195)
	xp_bar.max_value = max_xp
	xp_bar.value = 0
	xp_bar.show_percentage = false
	var xp_label := Label.new()
	xp_label.name = "XPLabel"
	xp_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	xp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	xp_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	xp_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.6))
	xp_label.add_theme_font_size_override("font_size", 11)
	xp_bar.add_child(xp_label)

	# Gold label ispod barova
	gold_label = Label.new()
	gold_label.position = Vector2(20, 220)
	gold_label.add_theme_font_size_override("font_size", 15)
	gold_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	add_child(gold_label)

	# Quest tracker (gore desno)
	var screen_w = get_viewport().get_visible_rect().size.x
	quest_tracker = Label.new()
	quest_tracker.position = Vector2(screen_w - 340, 20)
	quest_tracker.size = Vector2(320, 80)
	quest_tracker.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	quest_tracker.add_theme_font_size_override("font_size", 14)
	quest_tracker.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	quest_tracker.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	quest_tracker.add_theme_constant_override("shadow_offset_x", 1)
	quest_tracker.add_theme_constant_override("shadow_offset_y", 1)
	quest_tracker.visible = false
	add_child(quest_tracker)

	quest_abandon_btn = Button.new()
	quest_abandon_btn.text = "✕ Odustani"
	quest_abandon_btn.position = Vector2(screen_w - 340, 100)
	quest_abandon_btn.size = Vector2(110, 26)
	quest_abandon_btn.add_theme_font_size_override("font_size", 12)
	quest_abandon_btn.add_theme_color_override("font_color", Color(1, 0.45, 0.4))
	quest_abandon_btn.visible = false
	quest_abandon_btn.pressed.connect(func(): QuestManager.odustani_quest())
	add_child(quest_abandon_btn)

	QuestManager.quest_prihvacen.connect(func(_q): _osvezi_quest_tracker())
	QuestManager.quest_progres_azuriran.connect(func(_a, _b): _osvezi_quest_tracker())
	QuestManager.quest_zavrsen_signal.connect(func(_q): _osvezi_quest_tracker())
	QuestManager.quest_odustao.connect(func(): _osvezi_quest_tracker())

	_osvezi_barove()
	_osvezi_gold()
	_osvezi_quest_tracker()

	var player = get_tree().get_first_node_in_group("player")
	if player:
		spawn_pozicija = player.global_position

	await _ucitaj_igraca()

# ---------------------------------------------------------------- SAVE / LOAD

func oznaci_promenu() -> void:
	_dirty = true
	_dirty_timer = 0.0

func _prikupi_stanje() -> Dictionary:
	# backend prihvata samo ova polja; level/xp/gold/statistike upisuje server
	var player = get_tree().get_first_node_in_group("player")
	var pos: Vector3 = player.global_position if player else Vector3.ZERO
	var inv: Dictionary = inventory_ui.serijalizuj()
	return {
		"hp": int(hp), "mana": int(mana),
		"pos_x": pos.x, "pos_y": pos.y, "pos_z": pos.z,
		"inventory": inv.get("inventory", []),
		"equipment": inv.get("equipment", {})
	}

func sacuvaj_igraca() -> void:
	if not _ucitano or _saving:
		return
	_saving = true
	_dirty = false
	var ok = await ApiManager.save_player(ime_igraca, _prikupi_stanje())
	_saving = false
	if ok:
		print("[SAVE] Sačuvano.")
	else:
		print("[SAVE] Čuvanje nije uspelo (server?)")
		_dirty = true

func _ucitaj_igraca() -> void:
	var p: Dictionary = await ApiManager.get_player(ime_igraca)
	if p.is_empty():
		print("[SAVE] Server nedostupan, koristim default stanje (bez čuvanja).")
		return

	level = int(p.get("level", 1))
	xp = int(p.get("xp", 0))
	max_xp = int(p.get("max_xp", 100))
	gold = int(p.get("gold", 100))
	max_hp = int(p.get("max_hp", 100))
	max_mana = int(p.get("max_mana", 100))
	hp = clamp(int(p.get("hp", max_hp)), 1, max_hp)
	mana = clamp(int(p.get("mana", max_mana)), 0, max_mana)

	# Lik ovog klijenta je roditelj HUD-a (TopBar → ui → Player), ne prvi igrač u grupi
	var player = get_parent().get_parent()
	if player:
		player.napad_damage = int(p.get("napad_damage", 250))
		var pos = Vector3(float(p.get("pos_x", 0)), float(p.get("pos_y", 0)), float(p.get("pos_z", 0)))
		if pos != Vector3.ZERO:
			player.global_position = pos
		# server mora da zna statistike ovog lika (učitava ih iz baze)
		player.posalji_lik_serveru(ime_igraca)

	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	xp_bar.max_value = max_xp
	label_ime.text = ime_igraca + "  Lv." + str(level)

	await get_tree().process_frame
	await inventory_ui.ucitaj(p.get("inventory", []), p.get("equipment", {}))

	await QuestManager.ucitaj_zavrsene(ime_igraca)

	var qid = p.get("aktivni_quest_id", null)
	if qid != null and str(qid) != "":
		await QuestManager.ucitaj_stanje(str(qid), int(p.get("quest_progres", 0)))

	_osvezi_barove()
	_osvezi_gold()
	_osvezi_quest_tracker()
	_ucitano = true
	print("[SAVE] Lik učitan: Lv.%d, %d gold" % [level, gold])


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if _ucitano:
			await sacuvaj_igraca()
		get_tree().quit()

# ---------------------------------------------------------------- UI

func _osvezi_barove() -> void:
	hp_bar.value = hp
	mana_bar.value = mana
	xp_bar.value = xp

	var hp_lbl = hp_bar.get_node_or_null("HPLabel")
	if hp_lbl:
		hp_lbl.text = "HP: %d / %d" % [hp, max_hp]

	var mana_lbl = mana_bar.get_node_or_null("ManaLabel")
	if mana_lbl:
		mana_lbl.text = "Mana: %d / %d" % [mana, max_mana]

	var xp_lbl = xp_bar.get_node_or_null("XPLabel")
	if xp_lbl:
		xp_lbl.text = "XP: %d / %d  |  Lv.%d" % [xp, max_xp, level]

func _osvezi_gold() -> void:
	gold_label.text = "🪙 %d" % gold

func _osvezi_quest_tracker() -> void:
	if not QuestManager.ima_aktivan_quest():
		quest_tracker.visible = false
		quest_abandon_btn.visible = false
		return
	var q = QuestManager.aktivni_quest
	var naziv = str(q.get("naziv", ""))
	var cilj = str(q.get("cilj", ""))
	var kolicina = int(q.get("kolicina", 1))
	var glagol = "Ubij" if q.get("tip", "") == "kill" else "Donesi"
	if QuestManager.je_quest_zavrsen():
		quest_tracker.text = "📜 %s\n   ✓ Završeno — vrati se NPC-u" % naziv
		quest_tracker.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	else:
		quest_tracker.text = "📜 %s\n   %s %s  %d/%d" % [naziv, glagol, cilj, QuestManager.progres, kolicina]
		quest_tracker.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	quest_tracker.visible = true
	quest_abandon_btn.visible = true

# ---------------------------------------------------------------- STATS

# Online: zlato postavlja server (odgovor kupovine / predaje questa)
func postavi_gold(novo: int) -> void:
	gold = novo
	_osvezi_gold()

# samo za offline režim
func dodaj_gold(kolicina: int) -> void:
	gold += kolicina
	_osvezi_gold()
	oznaci_promenu()

# samo za offline režim
func potrosi_gold(kolicina: int) -> bool:
	if gold < kolicina:
		return false
	gold -= kolicina
	_osvezi_gold()
	oznaci_promenu()
	return true

# Online: statistike stižu sa servera (xp/change, quest turnin)
func primeni_stats(s: Dictionary) -> void:
	level = int(s.get("level", level))
	xp = int(s.get("xp", xp))
	max_xp = int(s.get("max_xp", max_xp))
	max_hp = int(s.get("max_hp", max_hp))
	max_mana = int(s.get("max_mana", max_mana))
	var player = get_parent().get_parent()
	if player and s.has("napad_damage"):
		player.napad_damage = int(s["napad_damage"])
	if s.get("level_up", false):
		hp = max_hp
		mana = max_mana
		print("LEVEL UP! Lv.%d | Max HP: %d | Max Mana: %d" % [level, max_hp, max_mana])
	hp = min(hp, max_hp)
	mana = min(mana, max_mana)
	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	xp_bar.max_value = max_xp
	label_ime.text = ime_igraca + "  Lv." + str(level)
	_osvezi_barove()

# samo za offline režim (online XP dodaje server)
func dodaj_xp(kolicina):
	if multiplayer.multiplayer_peer != null:
		return
	xp += kolicina
	print("XP: %d/%d" % [xp, max_xp])
	_osvezi_barove()
	if xp >= max_xp:
		level_up()
	oznaci_promenu()

# samo za offline režim
func level_up():
	if multiplayer.multiplayer_peer != null:
		return
	level += 1
	xp = 0
	max_xp = int(max_xp * 1.5)

	max_hp = int(max_hp * 1.15)
	max_mana = int(max_mana * 1.1)
	hp = max_hp
	mana = max_mana

	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	xp_bar.max_value = max_xp

	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.napad_damage = int(player.napad_damage * 1.1)

	label_ime.text = ime_igraca + "  Lv." + str(level)
	_osvezi_barove()
	print("LEVEL UP! Lv.%d | Max HP: %d | Max Mana: %d | Damage: %d" % [
		level, max_hp, max_mana, player.napad_damage if player else 0
	])
	oznaci_promenu()

func primi_damage(kolicina):
	if neosjetljiv or je_mrtav:
		return
	hp -= kolicina
	hp = max(hp, 0)
	_osvezi_barove()
	if hp == 0:
		_umri()

func _umri() -> void:
	if je_mrtav:
		return
	je_mrtav = true
	print("Lik je mrtav! Respawn za 3 sekunde...")

	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.velocity = Vector3.ZERO

	await get_tree().create_timer(3.0).timeout
	_respawn()

func _respawn() -> void:
	je_mrtav = false

	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.global_position = spawn_pozicija

	hp = max_hp
	mana = max_mana
	_osvezi_barove()

	neosjetljiv = true
	print("Respawn! Neosjetljiv 2 sekunde.")
	await get_tree().create_timer(2.0).timeout
	neosjetljiv = false
	print("Neosjetljivost gotova.")
	oznaci_promenu()

func potrosi_manu(kolicina):
	mana -= kolicina
	mana = max(mana, 0)
	_osvezi_barove()

func dodaj_item(ime):
	inventory_ui.dodaj_item_u_slot(ime)
	print("Pokupljen item: ", ime)

# ---------------------------------------------------------------- PROCESS

func _process(delta):
	if Input.is_action_just_pressed("ui_inventory"):
		inventory_ui.toggle()

	if Input.is_key_pressed(KEY_H):
		primi_damage(1)
	if Input.is_key_pressed(KEY_M):
		potrosi_manu(1)

	vreme += delta
	if vreme >= 1.0:
		vreme = 0.0
		if hp < max_hp and not je_mrtav:
			hp = min(hp + hp_regen, max_hp)
		if mana < max_mana and not je_mrtav:
			mana = min(mana + mana_regen, max_mana)
		_osvezi_barove()
		_osvezi_quest_tracker()

	if not _ucitano:
		return

	if _dirty:
		_dirty_timer += delta
		if _dirty_timer >= DIRTY_SAVE_DELAY:
			sacuvaj_igraca()

	_autosave_timer += delta
	if _autosave_timer >= AUTOSAVE_INTERVAL:
		_autosave_timer = 0.0
		sacuvaj_igraca()


#  ------------------------------------------------------------------ GOLD
