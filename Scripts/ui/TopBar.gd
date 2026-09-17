extends Control

@onready var label_ime = $"Label (Name)"
@onready var hp_bar = $"ProgressBar(HP)"
@onready var mana_bar = $"ProgressBar(Mana_Resurce)"
@onready var xp_bar = $"ProgressBar(XP)"
@onready var inventory_ui = $"../InventoryUI"

var hp = 100
var mana = 100
var ime_igraca = "Spajko"
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

func _ready():
	add_to_group("hud")

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

	# Zapamti spawn poziciju
	var player = get_tree().get_first_node_in_group("player")
	if player:
		spawn_pozicija = player.global_position

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

func dodaj_gold(kolicina: int) -> void:
	gold += kolicina
	_osvezi_gold()

func potrosi_gold(kolicina: int) -> bool:
	if gold < kolicina:
		return false
	gold -= kolicina
	_osvezi_gold()
	return true

func dodaj_xp(kolicina):
	xp += kolicina
	print("XP: %d/%d" % [xp, max_xp])
	_osvezi_barove()
	if xp >= max_xp:
		level_up()

func level_up():
	level += 1
	xp = 0
	max_xp = int(max_xp * 1.5)

	# Stat boost
	max_hp = int(max_hp * 1.15)    # +15% max HP
	max_mana = int(max_mana * 1.1) # +10% max mana
	hp = max_hp
	mana = max_mana

	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	xp_bar.max_value = max_xp

	# Povećaj damage playeru
	var player = get_tree().get_first_node_in_group("player")
	if player:
		player.napad_damage = int(player.napad_damage * 1.1) # +10% damage

	label_ime.text = ime_igraca + "  Lv." + str(level)
	_osvezi_barove()
	print("LEVEL UP! Lv.%d | Max HP: %d | Max Mana: %d | Damage: %d" % [
		level, max_hp, max_mana, player.napad_damage if player else 0
	])

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

func potrosi_manu(kolicina):
	mana -= kolicina
	mana = max(mana, 0)
	_osvezi_barove()

func dodaj_item(ime):
	inventory_ui.dodaj_item_u_slot(ime)
	print("Pokupljen item: ", ime)

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
