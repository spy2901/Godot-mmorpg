extends Control

@onready var label_ime = $"Label (Name)"
@onready var hp_bar = $"ProgressBar(HP)"
@onready var mana_bar = $"ProgressBar(Mana_Resurce)"
@onready var xp_bar = $"ProgressBar(XP)"
@onready var inventory_ui = $"../InventoryUI"

var hp = 100
var mana = 100
var ime_igraca: String = GameState.ime_igraca
var max_hp = 100
var max_mana = 100
var vreme = 0.0

var xp = 0
var max_xp = 100
var level = 1

var gold = 100
var gold_label: Label

# Buffovi (stanje drži server, ovde samo prikaz sa preostalim vremenom); izgled u buff_stil.gd
const BUFF_STIL := preload("res://Scripts/UI/buff_stil.gd")
var buff_label: Label

# Quest tracker
var quest_tracker: Label
var quest_abandon_btn: Button

# Smrt (stanje stiže sa servera, ovde samo prikaz)
var je_mrtav: bool = false
var smrt_ekran: ColorRect
var smrt_label: Label
var _smrt_pocetak_ms := 0
const RESPAWN_DELAY := 3.0  # samo za odbrojavanje na ekranu; pravi respawn radi server

# Kratka poruka na sredini ekrana ("+30 HP", "Već si pun", ...)
const PORUKA_TRAJANJE := 2.0
var _poruka_label: Label
var _poruka_br := 0

# Save / load
const AUTOSAVE_INTERVAL = 30.0
const DIRTY_SAVE_DELAY = 3.0
var _ucitano: bool = false
var _dirty: bool = false
var _dirty_timer: float = 0.0
var _autosave_timer: float = 0.0

func _ready():
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	add_to_group("hud")
	get_tree().auto_accept_quit = false

	label_ime.text = tr("%s  Lv.%d") % [ime_igraca, level]
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

	buff_label = Label.new()
	buff_label.name = "BuffLabel"
	buff_label.position = BUFF_STIL.POZICIJA
	buff_label.size.x = BUFF_STIL.SIRINA
	buff_label.add_theme_font_size_override("font_size", BUFF_STIL.FONT_VELICINA)
	buff_label.add_theme_color_override("font_color", BUFF_STIL.BOJA_TEKST)
	buff_label.add_theme_color_override("font_shadow_color", BUFF_STIL.BOJA_SENKA)
	buff_label.add_theme_constant_override("shadow_offset_x", BUFF_STIL.SENKA_POMERAJ)
	buff_label.add_theme_constant_override("shadow_offset_y", BUFF_STIL.SENKA_POMERAJ)
	add_child(buff_label)

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
	quest_abandon_btn.text = "✕ " + tr("Abandon")
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

	_napravi_smrt_ekran()

	if ime_igraca == "":
		print("[SAVE] Nema imena lika (nije prijavljen?), ne učitavam i ne čuvam.")
		return
	# server preko tokena dobija ime lika, učita ga iz baze i vrati primi_lik
	get_parent().get_parent().posalji_lik_serveru(GameState.token)

func prikazi_poruku(tekst: String) -> void:
	if tekst == "":
		return
	if _poruka_label == null:
		_poruka_label = Label.new()
		_poruka_label.add_theme_font_size_override("font_size", 28)
		_poruka_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_poruka_label.add_theme_constant_override("outline_size", 6)
		_poruka_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_poruka_label.top_level = true
		var w := get_viewport().get_visible_rect().size.x
		_poruka_label.position = Vector2(w / 2 - 200, 260)
		_poruka_label.size = Vector2(400, 40)
		add_child(_poruka_label)
	_poruka_label.text = tr(tekst) # poruke servera stižu kao engleski ključevi
	_poruka_label.visible = true
	_poruka_br += 1
	var br := _poruka_br
	await get_tree().create_timer(PORUKA_TRAJANJE).timeout
	if br == _poruka_br: # novija poruka produžava prikaz
		_poruka_label.visible = false

# ---------------------------------------------------------------- SAVE / LOAD

func oznaci_promenu() -> void:
	_dirty = true
	_dirty_timer = 0.0

# Stanje ide game serveru (host: lokalni poziv); server ga snima u bazu.
func sacuvaj_igraca() -> void:
	if not _ucitano:
		return
	_dirty = false
	var player = get_parent().get_parent()
	var inv: Dictionary = inventory_ui.serijalizuj()
	var raspored: Array = inv.get("inventory", [])
	var oprema: Dictionary = inv.get("equipment", {})
	if multiplayer.is_server():
		player.posalji_stanje(raspored, oprema)
	else:
		player.posalji_stanje.rpc_id(1, raspored, oprema)

# Pošalji stanje i daj mu vremena da ode pre izlaska/odjave
func sacuvaj_pre_izlaska() -> void:
	if _ucitano:
		sacuvaj_igraca()
		await get_tree().create_timer(0.3).timeout

# Server šalje podatke lika iz baze (Player.primi_lik)
func primeni_lik(p: Dictionary) -> void:
	level = int(p.get("level", 1))
	xp = int(p.get("xp", 0))
	max_xp = int(p.get("max_xp", 100))
	gold = int(p.get("gold", 100))
	max_hp = int(p.get("max_hp", 100))
	max_mana = int(p.get("max_mana", 100))
	hp = clamp(int(p.get("hp", max_hp)), 1, max_hp)
	mana = clamp(int(p.get("mana", max_mana)), 0, max_mana)
	je_mrtav = false

	# Lik ovog klijenta je roditelj HUD-a (TopBar → ui → Player), ne prvi igrač u grupi
	var player = get_parent().get_parent()
	player.napad_damage = int(p.get("napad_damage", 10))

	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	label_ime.text = tr("%s  Lv.%d") % [ime_igraca, level]

	await get_tree().process_frame
	await inventory_ui.ucitaj(p.get("inventory", []), p.get("equipment", {}))

	QuestManager.ucitaj_zavrsene(ime_igraca, p.get("zavrseni_questovi", []))

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
		await sacuvaj_pre_izlaska()  # server ionako snima i na diskonekt
		get_tree().quit()

# ---------------------------------------------------------------- UI

func _osvezi_barove() -> void:
	hp_bar.value = hp
	mana_bar.value = mana
	# max_xp 0 = maksimalni nivo: traka puna, bez deljenja nulom
	xp_bar.max_value = max(max_xp, 1)
	xp_bar.value = xp_bar.max_value if max_xp <= 0 else xp

	var hp_lbl = hp_bar.get_node_or_null("HPLabel")
	if hp_lbl:
		hp_lbl.text = tr("HP: %d / %d") % [hp, max_hp]

	var mana_lbl = mana_bar.get_node_or_null("ManaLabel")
	if mana_lbl:
		mana_lbl.text = tr("Mana: %d / %d") % [mana, max_mana]

	var xp_lbl = xp_bar.get_node_or_null("XPLabel")
	if xp_lbl:
		xp_lbl.text = tr("XP: MAX  |  Lv.%d") % level if max_xp <= 0 else tr("XP: %d / %d  |  Lv.%d") % [xp, max_xp, level]

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
	var glagol = tr("Kill") if q.get("tip", "") == "kill" else tr("Bring")
	if QuestManager.je_quest_zavrsen():
		quest_tracker.text = "📜 %s\n   ✓ %s" % [naziv, tr("Complete: return to the quest giver")]
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
	var player = get_parent().get_parent()
	if player and s.has("napad_damage"):
		player.napad_damage = int(s["napad_damage"])
	if s.get("level_up", false):
		prikazi_poruku(tr("Level up! Lv.%d") % level)
	# hp, manu i njihove maksimume (sa bonusom opreme, i punjenje na level-up) šalje server preko primeni_hp;
	# max_hp iz stats je osnovni, bez opreme
	label_ime.text = tr("%s  Lv.%d") % [ime_igraca, level]
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

	label_ime.text = tr("%s  Lv.%d") % [ime_igraca, level]
	_osvezi_barove()
	print("LEVEL UP! Lv.%d | Max HP: %d | Max Mana: %d | Damage: %d" % [
		level, max_hp, max_mana, player.napad_damage if player else 0
	])
	oznaci_promenu()

# Server šalje hp/manu/status smrti (Player.primi_hp). Klijent samo prikazuje.
func primeni_hp(novi_hp: int, novi_max_hp: int, nova_mana: int, nova_max_mana: int, mrtav: bool) -> void:
	max_hp = novi_max_hp
	max_mana = nova_max_mana
	hp = clampi(novi_hp, 0, max_hp)
	mana = clampi(nova_mana, 0, max_mana)
	hp_bar.max_value = max_hp
	mana_bar.max_value = max_mana
	if mrtav and not je_mrtav:
		_smrt_pocetak_ms = Time.get_ticks_msec()
	je_mrtav = mrtav
	_osvezi_barove()
	_osvezi_smrt_ekran()

func _napravi_smrt_ekran() -> void:
	smrt_ekran = ColorRect.new()
	smrt_ekran.color = Color(0.35, 0.0, 0.0, 0.45)
	smrt_ekran.set_anchors_preset(Control.PRESET_FULL_RECT)
	smrt_ekran.mouse_filter = Control.MOUSE_FILTER_IGNORE
	smrt_ekran.top_level = true  # preko celog ekrana, nezavisno od veličine HUD-a
	smrt_ekran.visible = false
	smrt_label = Label.new()
	smrt_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	smrt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	smrt_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	smrt_label.add_theme_font_size_override("font_size", 36)
	smrt_label.add_theme_color_override("font_color", Color(1, 0.85, 0.85))
	smrt_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	smrt_label.add_theme_constant_override("shadow_offset_x", 2)
	smrt_label.add_theme_constant_override("shadow_offset_y", 2)
	smrt_ekran.add_child(smrt_label)
	add_child(smrt_ekran)

func _osvezi_smrt_ekran() -> void:
	if smrt_ekran == null:
		return
	smrt_ekran.visible = je_mrtav
	if je_mrtav:
		var ostalo := maxf(RESPAWN_DELAY - (Time.get_ticks_msec() - _smrt_pocetak_ms) / 1000.0, 0.0)
		smrt_label.text = tr("You died\nRespawn in %d s") % int(ceil(ostalo))

func dodaj_item(ime):
	inventory_ui.dodaj_item_u_slot(ime)
	print("Pokupljen item: ", ime)

# ---------------------------------------------------------------- PROCESS

# Jedan red po buff-u: "Attack +20%  0:42"; istekao lokalno se ne prikazuje (server javlja istek posebno)
func tekst_buffova() -> String:
	var p = get_parent().get_parent()
	var sada := Time.get_ticks_msec()
	var redovi: PackedStringArray = []
	for tip in p.buffovi:
		var ostalo := ceili((int(p.buffovi[tip][1]) - sada) / 1000.0)
		if ostalo > 0:
			redovi.append(p.opis_buffa(tip, int(p.buffovi[tip][0])) + BUFF_STIL.RAZMAK_VREME + "%d:%02d" % [ostalo / 60, ostalo % 60])
	return "\n".join(redovi)

func _process(delta):
	buff_label.text = tekst_buffova()
	if je_mrtav:
		_osvezi_smrt_ekran()  # odbrojavanje
	elif Input.is_action_just_pressed("ui_inventory"):
		inventory_ui.toggle()

	vreme += delta
	if vreme >= 1.0:
		vreme = 0.0
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