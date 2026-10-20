extends Control

const SLOT_SIZE = 64
const GRID_COLUMNS = 6
const GRID_ROWS = 4
const TOTAL_SLOTS = GRID_COLUMNS * GRID_ROWS
const STIL := preload("res://Scripts/UI/inventar_stil.gd")

var inventory_data = []
var slots = []
var aktivna_kategorija = "all"

# Drag & Drop
var drag_index = -1
var drag_item = null
var drag_label : Label = null
var is_dragging = false

# UI nodeovi
var glavni_panel: Panel
var tooltip_panel: Panel
var tooltip_label: Label
var character_panel: Panel
var stat_label: Label # sažetak statistika lika po serveru (attack, armor, max HP)

# Equipment slotovi (paneli) i opremljeni itemi (podaci)
var equipment_slots = {
	"head": null, "chest": null, "legs": null,
	"boots": null, "weapon": null, "shield": null
}
var equipped_items = {}

func _init():
	inventory_data.resize(TOTAL_SLOTS)
	for i in TOTAL_SLOTS:
		inventory_data[i] = {}

func _ready():
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		return
	add_to_group("inventory")
	_napravi_ui()
	visible = false

func _oznaci_promenu():
	var hud = get_tree().get_first_node_in_group("hud")
	if hud and hud.has_method("oznaci_promenu"):
		hud.oznaci_promenu()
	QuestManager.osvezi_fetch_progres()

func _napravi_ui():
	var screen = get_viewport().get_visible_rect().size

	glavni_panel = Panel.new()
	glavni_panel.size = screen
	glavni_panel.position = Vector2(0, 0)
	add_child(glavni_panel)

	var panel_style = _napravi_stil(Color(0.08, 0.08, 0.12, 0.97), Color(0.6, 0.5, 0.2), 2, 0)
	glavni_panel.add_theme_stylebox_override("panel", panel_style)

	var naslov = Label.new()
	naslov.text = "⚔  " + tr("INVENTORY")
	naslov.position = Vector2(20, 15)
	naslov.add_theme_color_override("font_color", Color(0.9, 0.8, 0.3))
	naslov.add_theme_font_size_override("font_size", 24)
	glavni_panel.add_child(naslov)

	var separator = Panel.new()
	separator.position = Vector2(0, 50)
	separator.size = Vector2(screen.x, 2)
	var sep_style = StyleBoxFlat.new()
	sep_style.bg_color = Color(0.6, 0.5, 0.2, 0.8)
	separator.add_theme_stylebox_override("panel", sep_style)
	glavni_panel.add_child(separator)

	var zatvori_btn = Button.new()
	zatvori_btn.text = "✕"
	zatvori_btn.position = Vector2(screen.x - 45, 10)
	zatvori_btn.size = Vector2(32, 32)
	zatvori_btn.add_theme_font_size_override("font_size", 18)
	zatvori_btn.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	var btn_stil = _napravi_stil(Color(0.2, 0.1, 0.1), Color(0.8, 0.2, 0.2), 1, 4)
	zatvori_btn.add_theme_stylebox_override("normal", btn_stil)
	var btn_hover = _napravi_stil(Color(0.4, 0.1, 0.1), Color(1.0, 0.3, 0.3), 1, 4)
	zatvori_btn.add_theme_stylebox_override("hover", btn_hover)
	zatvori_btn.pressed.connect(func(): visible = false)
	glavni_panel.add_child(zatvori_btn)

	character_panel = Panel.new()
	character_panel.position = Vector2(20, 60)
	character_panel.size = Vector2(250, screen.y - 80)
	var char_style = _napravi_stil(Color(0.05, 0.05, 0.1, 0.8), Color(0.4, 0.35, 0.15), 1, 6)
	character_panel.add_theme_stylebox_override("panel", char_style)
	glavni_panel.add_child(character_panel)

	var char_label = Label.new()
	char_label.text = "👤"
	char_label.position = Vector2(90, 20)
	char_label.add_theme_font_size_override("font_size", 80)
	character_panel.add_child(char_label)

	_napravi_equipment_slotove()
	_napravi_statistike()

	var desni_panel = Panel.new()
	desni_panel.position = Vector2(285, 60)
	desni_panel.size = Vector2(screen.x - 305, screen.y - 80)
	var desni_stil = _napravi_stil(Color(0.05, 0.05, 0.1, 0.8), Color(0.4, 0.35, 0.15), 1, 6)
	desni_panel.add_theme_stylebox_override("panel", desni_stil)
	glavni_panel.add_child(desni_panel)

	_napravi_kategorije(desni_panel)

	var grid_container = GridContainer.new()
	grid_container.name = "GridContainer"
	grid_container.columns = GRID_COLUMNS
	grid_container.position = Vector2(10, 50)
	grid_container.add_theme_constant_override("h_separation", 4)
	grid_container.add_theme_constant_override("v_separation", 4)
	desni_panel.add_child(grid_container)

	for i in TOTAL_SLOTS:
		var slot = _napravi_slot(i)
		grid_container.add_child(slot)
		slots.append(slot)

	_napravi_tooltip(desni_panel)

func _napravi_equipment_slotove():
	var screen = get_viewport().get_visible_rect().size
	var panel_height = screen.y - 80

	var slot_info = [
		["head", "🪖 Head", 0.15],
		["chest", "🛡 Chest", 0.30],
		["legs", "👖 Legs", 0.45],
		["boots", "👢 Boots", 0.55],
		["weapon", "⚔ Weapon", 0.68],
		["shield", "🛡 Shield", 0.80]
	]

	for info in slot_info:
		var y_pos = panel_height * info[2]

		var label = Label.new()
		label.text = tr(info[1])
		label.position = Vector2(10, y_pos - 20)
		label.add_theme_font_size_override("font_size", 13)
		label.add_theme_color_override("font_color", Color(0.7, 0.6, 0.3))
		character_panel.add_child(label)

		var slot = Panel.new()
		slot.position = Vector2(10, y_pos)
		slot.size = Vector2(230, 45)
		var stil = _napravi_stil(Color(0.12, 0.12, 0.18), Color(0.5, 0.4, 0.2), 1, 4)
		slot.add_theme_stylebox_override("panel", stil)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.gui_input.connect(_on_equipment_slot_input.bind(info[0]))

		var slot_label = Label.new()
		slot_label.name = "SlotLabel"
		slot_label.text = tr("Empty")
		slot_label.set_anchors_preset(Control.PRESET_FULL_RECT)
		slot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		slot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		slot_label.add_theme_font_size_override("font_size", 12)
		slot_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
		slot_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(slot_label)

		character_panel.add_child(slot)
		equipment_slots[info[0]] = slot

# Sažetak statistika na dnu panela sa opremom; vrednosti računa server (igrač.stat_*), ovde je samo prikaz.
func _napravi_statistike() -> void:
	stat_label = Label.new()
	stat_label.position = Vector2(STIL.SAZETAK_MARGINA, character_panel.size.y - STIL.SAZETAK_ODOZDO)
	stat_label.size = Vector2(character_panel.size.x - 2 * STIL.SAZETAK_MARGINA, STIL.SAZETAK_VISINA)
	stat_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stat_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	stat_label.add_theme_font_size_override("font_size", STIL.SAZETAK_FONT)
	stat_label.add_theme_color_override("font_color", STIL.SAZETAK_BOJA)
	stat_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	character_panel.add_child(stat_label)
	var igrac = get_parent().get_parent()
	if igrac and igrac.has_signal("statistike_promenjene"):
		igrac.statistike_promenjene.connect(_osvezi_statistike)
	_osvezi_statistike()

func _osvezi_statistike() -> void:
	var igrac = get_parent().get_parent()
	if stat_label == null or igrac == null or not igrac.has_signal("statistike_promenjene"):
		return
	stat_label.text = tr("Attack: %d   Armor: %d   Max HP: %d") % [igrac.stat_attack, igrac.stat_armor, igrac.stat_max_hp]

func _napravi_kategorije(parent: Control):
	var screen = get_viewport().get_visible_rect().size
	var panel_width = screen.x - 305

	var kategorije = [
		["all", "All"],
		["weapon", "⚔ Weapons"],
		["armor", "🛡 Armor"],
		["consumable", "🧪 Consumables"],
		["material", "🪨 Materials"],
		["quest", "📜 Quest"]
	]

	var btn_width = (panel_width - 20) / kategorije.size()

	for i in range(kategorije.size()):
		var btn = Button.new()
		btn.text = tr(kategorije[i][1])
		btn.position = Vector2(10 + i * btn_width, 10)
		btn.size = Vector2(btn_width - 5, 30)
		btn.add_theme_font_size_override("font_size", 12)

		var btn_stil = _napravi_stil(Color(0.15, 0.15, 0.22), Color(0.5, 0.4, 0.2), 1, 4)
		btn.add_theme_stylebox_override("normal", btn_stil)
		var btn_hover_stil = _napravi_stil(Color(0.25, 0.25, 0.35), Color(0.8, 0.7, 0.3), 1, 4)
		btn.add_theme_stylebox_override("hover", btn_hover_stil)

		var id = kategorije[i][0]
		btn.pressed.connect(func(): _promeni_kategoriju(id))
		parent.add_child(btn)

func _napravi_tooltip(parent: Control):
	var screen = get_viewport().get_visible_rect().size
	var panel_width = screen.x - 325
	var panel_height = screen.y - 80

	tooltip_panel = Panel.new()
	tooltip_panel.position = Vector2(10, panel_height - 120)
	tooltip_panel.size = Vector2(panel_width, 110)
	var stil = _napravi_stil(Color(0.05, 0.05, 0.1, 0.95), Color(0.6, 0.5, 0.2), 1, 6)
	tooltip_panel.add_theme_stylebox_override("panel", stil)
	tooltip_panel.visible = false
	parent.add_child(tooltip_panel)

	tooltip_label = Label.new()
	tooltip_label.position = Vector2(15, 10)
	tooltip_label.size = Vector2(panel_width - 30, 90)
	tooltip_label.add_theme_font_size_override("font_size", 14)
	tooltip_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	tooltip_panel.add_child(tooltip_label)

func _napravi_stil(bg: Color, border: Color, border_width: int = 1, radius: int = 4) -> StyleBoxFlat:
	var stil = StyleBoxFlat.new()
	stil.bg_color = bg
	stil.border_color = border
	stil.set_border_width_all(border_width)
	stil.set_corner_radius_all(radius)
	return stil

func _napravi_slot(index: int) -> Panel:
	var slot = Panel.new()
	slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
	slot.name = "Slot" + str(index)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP

	var stil = _napravi_stil(Color(0.12, 0.12, 0.18), Color(0.4, 0.35, 0.15), 1, 4)
	slot.add_theme_stylebox_override("panel", stil)

	var ikonica = Label.new()
	ikonica.name = "Ikonica"
	ikonica.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ikonica.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ikonica.set_anchors_preset(Control.PRESET_FULL_RECT)
	ikonica.add_theme_font_size_override("font_size", 28)
	ikonica.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(ikonica)

	var stack = Label.new()
	stack.name = "Stack"
	stack.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	stack.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	stack.add_theme_font_size_override("font_size", 11)
	stack.add_theme_color_override("font_color", Color(1, 1, 0.8))
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(stack)

	slot.gui_input.connect(_on_slot_input.bind(index))
	slot.mouse_entered.connect(_on_slot_hover.bind(index))
	slot.mouse_exited.connect(_on_slot_unhover.bind(index))

	return slot

# ---------------------------------------------------------------- DRAG & DROP

func _on_slot_input(event: InputEvent, index: int):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if index < inventory_data.size() and not inventory_data[index].is_empty():
					drag_index = index
					drag_item = inventory_data[index].duplicate()
					is_dragging = false
					_pokreni_drag()
			else:
				if is_dragging:
					var bar = get_tree().get_first_node_in_group("action_bar")
					if bar and bar.prevuci_iz_inventara(drag_item, get_global_mouse_position()):
						_zavrsi_drag(-1) # na traku: raspored inventara se ne menja
					else:
						_zavrsi_drag(_nadji_slot_ispod_misa())
				else:
					if drag_index != -1:
						_on_slot_klik(drag_index)
					drag_index = -1
					drag_item = null
					if drag_label:
						drag_label.queue_free()
						drag_label = null

func _nadji_slot_ispod_misa() -> int:
	var mouse_pos = get_global_mouse_position()
	for i in slots.size():
		var slot = slots[i]
		var rect = Rect2(slot.global_position, slot.size)
		if rect.has_point(mouse_pos):
			return i
	return -1

# Esc tokom prevlačenja ga otkazuje i ne stiže do igrača (ne skida cilj)
func _input(event):
	if drag_index != -1 and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_zavrsi_drag(-1)
		get_viewport().set_input_as_handled()

func _pokreni_drag():
	if drag_label:
		drag_label.queue_free()
	drag_label = Label.new()
	drag_label.text = drag_item.get("ikonica", "?")
	drag_label.add_theme_font_size_override("font_size", 36)
	drag_label.z_index = 100
	drag_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_label.global_position = get_global_mouse_position() - Vector2(18, 18)
	add_child(drag_label)

func _zavrsi_drag(cilj_index: int):
	is_dragging = false

	if drag_label:
		drag_label.queue_free()
		drag_label = null

	if drag_index == -1 or cilj_index == -1 or cilj_index == drag_index:
		drag_index = -1
		drag_item = null
		_resetuj_sve_slotove()
		return

	var temp = {}
	if typeof(inventory_data[cilj_index]) == TYPE_DICTIONARY:
		temp = inventory_data[cilj_index].duplicate()

	inventory_data[cilj_index] = drag_item
	inventory_data[drag_index] = temp

	osvezi_slot(drag_index)
	osvezi_slot(cilj_index)

	drag_index = -1
	drag_item = null
	_resetuj_sve_slotove()
	_oznaci_promenu()

# ---------------------------------------------------------------- EQUIP

# Slot dolazi iz baze (items.slot); predmet bez slota (npr. iron_gloves) se ne oprema.
func _eq_slot_za_item(item: Dictionary) -> String:
	var slot = item.get("slot")
	return str(slot) if slot != null and equipment_slots.has(str(slot)) else ""

func _on_slot_klik(index: int):
	if index >= inventory_data.size() or inventory_data[index].is_empty():
		return
	var item = inventory_data[index]
	if item.get("tip", "") == "consumable":
		_koristi_item(str(item.get("id", "")))
		return
	var eq_slot = _eq_slot_za_item(item)
	if eq_slot == "":
		return # ne oprema se (npr. predmet bez slota); tooltip to kaže
	_zatrazi_opremanje(index, eq_slot)

# Opremanje odlučuje server (predmet u inventaru, pravi slot, lik živ); UI pomera predmet tek posle potvrde.
func _zatrazi_opremanje(index: int, eq_slot: String) -> void:
	var item_id := str(inventory_data[index].get("id", ""))
	var r: Dictionary = await get_parent().get_parent().opremi_na_serveru(eq_slot, item_id)
	if not r.get("ok", false):
		_prikazi_poruku(str(r.get("poruka", "")))
		return
	if str(inventory_data[index].get("id", "")) != item_id: # raspored se u međuvremenu promenio
		index = inventory_data.find_custom(func(x): return str(x.get("id", "")) == item_id)
		if index < 0:
			return
	_opremi_item(index, eq_slot)

func _prikazi_poruku(tekst: String) -> void:
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		hud.prikazi_poruku(tekst)

# Potrošni predmet troši server; UI skida komad tek kad server potvrdi (tako se slaže sa bazom)
func _koristi_item(item_id: String) -> void:
	var r: Dictionary = await get_parent().get_parent().koristi_item_na_serveru(item_id)
	var poruka := str(r.get("poruka", ""))
	if r.get("ok", false):
		ukloni_item(item_id, 1)
		var delovi: PackedStringArray = []
		if int(r.get("hp_efekat", 0)) > 0: delovi.append(tr("+%d HP") % int(r.hp_efekat))
		if int(r.get("mana_efekat", 0)) > 0: delovi.append(tr("+%d Mana") % int(r.mana_efekat))
		var opis: String = get_parent().get_parent().opis_buffa(str(r.get("buff_tip", "")), int(r.get("buff_vrednost", 0)))
		if opis != "": delovi.append(tr("%s for %d s") % [opis, int(r.get("buff_trajanje_ms", 0)) / 1000])
		poruka = "  ".join(delovi)
	var hud = get_tree().get_first_node_in_group("hud")
	if hud:
		hud.prikazi_poruku(poruka)

func _opremi_item(inventory_index: int, eq_slot: String):
	var item = inventory_data[inventory_index].duplicate()

	var stari = equipped_items.get(eq_slot, null)
	if stari != null and not stari.is_empty():
		inventory_data[inventory_index] = stari
	else:
		inventory_data[inventory_index] = {}

	equipped_items[eq_slot] = item
	_prikazi_opremu(eq_slot, item)
	osvezi_slot(inventory_index)
	print("Opremio: ", item.get("ime", ""), " u slot: ", eq_slot)
	_oznaci_promenu()

func _on_equipment_slot_input(event: InputEvent, eq_slot: String):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_skini_opremu(eq_slot)

# Skidanje: prvo slobodno mesto u inventaru, pa potvrda servera, pa pomeranje u UI-ju.
func _skini_opremu(eq_slot: String):
	var item = equipped_items.get(eq_slot, null)
	if item == null or item.is_empty():
		return
	if not inventory_data.any(func(x): return x.is_empty()):
		_prikazi_poruku("Inventory full")
		return
	var r: Dictionary = await get_parent().get_parent().opremi_na_serveru(eq_slot, "")
	if not r.get("ok", false):
		_prikazi_poruku(str(r.get("poruka", "")))
		return
	for i in TOTAL_SLOTS:
		if inventory_data[i].is_empty():
			inventory_data[i] = item
			equipped_items.erase(eq_slot)
			_prikazi_opremu(eq_slot, {})
			osvezi_slot(i)
			print("Skinuo: ", item.get("ime", ""))
			_oznaci_promenu()
			return
	print("Inventory je pun, ne mogu da skinem opremu!")

func _prikazi_opremu(eq_slot: String, item: Dictionary):
	var slot_panel = equipment_slots[eq_slot]
	var slot_label = slot_panel.get_node("SlotLabel")
	if item.is_empty():
		slot_label.text = tr("Empty")
		slot_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
		var stil = _napravi_stil(Color(0.12, 0.12, 0.18), Color(0.5, 0.4, 0.2), 1, 4)
		slot_panel.add_theme_stylebox_override("panel", stil)
	else:
		slot_label.text = str(item.get("ikonica", "")) + " " + str(item.get("ime", ""))
		slot_label.add_theme_color_override("font_color", _boja_po_tipu(item.get("tip", "")))
		var stil = _napravi_stil(Color(0.1, 0.2, 0.1), Color(0.3, 0.8, 0.3), 2, 4)
		slot_panel.add_theme_stylebox_override("panel", stil)

# ---------------------------------------------------------------- HOVER / TOOLTIP

func _on_slot_hover(index: int):
	if index >= inventory_data.size() or inventory_data[index].is_empty():
		return

	var slot = slots[index]
	var hover_stil = _napravi_stil(Color(0.25, 0.25, 0.35), Color(0.9, 0.8, 0.3), 2, 4)
	slot.add_theme_stylebox_override("panel", hover_stil)

	var hovered_item = inventory_data[index]
	var tip_boja = _boja_po_tipu(hovered_item.get("tip", ""))
	tooltip_label.text = tr("%s  %s\nType: %s  |  Value: %s gold  |  Stack: %s/%s") % [
		hovered_item.get("ikonica", ""),
		hovered_item.get("ime", ""),
		str(hovered_item.get("tip", "")).to_upper(),
		str(int(hovered_item.get("vrednost", 0))),
		str(hovered_item.get("kolicina", 1)),
		str(int(hovered_item.get("max_stack", 1)))
	]
	var stat: PackedStringArray = []
	if int(hovered_item.get("damage", 0)) > 0: stat.append(tr("Attack +%d") % int(hovered_item.damage))
	if int(hovered_item.get("armor", 0)) > 0: stat.append(tr("Armor +%d") % int(hovered_item.armor))
	if int(hovered_item.get("hp_bonus", 0)) > 0: stat.append(tr("Max HP +%d") % int(hovered_item.hp_bonus))
	if not stat.is_empty():
		tooltip_label.text += "\n" + "  |  ".join(stat)
	if hovered_item.get("tip", "") in ["weapon", "armor"] and _eq_slot_za_item(hovered_item) == "":
		tooltip_label.text += "\n" + tr("Can't be equipped")
	var hp_e := int(hovered_item.get("hp_efekat", 0))
	var mana_e := int(hovered_item.get("mana_efekat", 0))
	if hovered_item.get("tip", "") == "consumable" and hp_e + mana_e > 0:
		tooltip_label.text += tr("\nClick: %s%s  |  cooldown %.0f s") % [
			tr("+%d HP") % hp_e + " " if hp_e > 0 else "", tr("+%d Mana") % mana_e if mana_e > 0 else "",
			int(hovered_item.get("cooldown_ms", 0)) / 1000.0]
	var buff_tip = hovered_item.get("buff_tip")
	var opis: String = get_parent().get_parent().opis_buffa(str(buff_tip), int(hovered_item.get("buff_vrednost", 0))) \
		if hovered_item.get("tip", "") == "consumable" and buff_tip is String else ""
	if opis != "":
		tooltip_label.text += tr("\nClick: %s for %d s  |  cooldown %.0f s") % [opis,
			int(hovered_item.get("buff_trajanje_ms", 0)) / 1000, int(hovered_item.get("cooldown_ms", 0)) / 1000.0]
	tooltip_label.add_theme_color_override("font_color", tip_boja)
	tooltip_panel.visible = true

func _on_slot_unhover(index: int):
	if is_dragging:
		return
	var slot = slots[index]
	var stil = _napravi_stil(Color(0.12, 0.12, 0.18), Color(0.4, 0.35, 0.15), 1, 4)
	slot.add_theme_stylebox_override("panel", stil)
	tooltip_panel.visible = false

func _resetuj_sve_slotove():
	for i in slots.size():
		var normal_stil = _napravi_stil(Color(0.12, 0.12, 0.18), Color(0.4, 0.35, 0.15), 1, 4)
		slots[i].add_theme_stylebox_override("panel", normal_stil)
	tooltip_panel.visible = false

func _boja_po_tipu(tip: String) -> Color:
	match tip:
		"weapon": return Color(1.0, 0.4, 0.4)
		"armor": return Color(0.4, 0.7, 1.0)
		"consumable": return Color(0.4, 1.0, 0.4)
		"quest": return Color(1.0, 0.8, 0.0)
		"material": return Color(0.8, 0.6, 0.4)
		"currency": return Color(1.0, 0.9, 0.2)
		_: return Color(0.9, 0.85, 0.7)

func _promeni_kategoriju(kategorija: String):
	aktivna_kategorija = kategorija
	_osvezi_grid()

# ---------------------------------------------------------------- ITEMI

func dodaj_item_u_slot(item_id: String, kolicina: int = 1):
	var item = await ApiManager.get_item(item_id)
	if item.is_empty() or item.has("error"):
		return

	if item.get("stackable", 0) == 1.0:
		for i in TOTAL_SLOTS:
			if not inventory_data[i].is_empty() and inventory_data[i].get("id") == item_id:
				var novi_stack = int(inventory_data[i].get("kolicina", 1)) + kolicina
				var max_stack = int(item.get("max_stack", 1))
				inventory_data[i]["kolicina"] = min(novi_stack, max_stack)
				osvezi_slot(i)
				_oznaci_promenu()
				return

	for i in TOTAL_SLOTS:
		if inventory_data[i].is_empty():
			var novi_item = item.duplicate()
			novi_item["kolicina"] = kolicina
			inventory_data[i] = novi_item
			osvezi_slot(i)
			_oznaci_promenu()
			return

	print("Inventory je pun!")

func prebroj_item(item_id: String) -> int:
	var n = 0
	for i in TOTAL_SLOTS:
		if not inventory_data[i].is_empty() and str(inventory_data[i].get("id", "")) == item_id:
			n += int(inventory_data[i].get("kolicina", 1))
	return n

func ukloni_item(item_id: String, kolicina: int) -> bool:
	if prebroj_item(item_id) < kolicina:
		return false
	var ostalo = kolicina
	for i in TOTAL_SLOTS:
		if ostalo <= 0:
			break
		var it = inventory_data[i]
		if it.is_empty() or str(it.get("id", "")) != item_id:
			continue
		var k = int(it.get("kolicina", 1))
		if k <= ostalo:
			ostalo -= k
			inventory_data[i] = {}
		else:
			inventory_data[i]["kolicina"] = k - ostalo
			ostalo = 0
		osvezi_slot(i)
	_oznaci_promenu()
	return true

func osvezi_slot(index: int):
	if index >= slots.size():
		return
	var slot = slots[index]
	var ikonica = slot.get_node("Ikonica")
	var stack = slot.get_node("Stack")

	if index < inventory_data.size() and not inventory_data[index].is_empty():
		var item = inventory_data[index]
		ikonica.text = item.get("ikonica", "?")
		var kolicina = int(item.get("kolicina", 1))
		stack.text = str(kolicina) if kolicina > 1 else ""
	else:
		ikonica.text = ""
		stack.text = ""

func _osvezi_grid():
	for i in slots.size():
		if inventory_data[i].is_empty():
			slots[i].get_node("Ikonica").text = ""
			slots[i].get_node("Stack").text = ""
			continue

		var item = inventory_data[i]
		var tip = item.get("tip", "")

		if aktivna_kategorija == "all" or aktivna_kategorija == tip:
			slots[i].get_node("Ikonica").text = item.get("ikonica", "?")
			var kolicina = int(item.get("kolicina", 1))
			slots[i].get_node("Stack").text = str(kolicina) if kolicina > 1 else ""
		else:
			slots[i].get_node("Ikonica").text = ""
			slots[i].get_node("Stack").text = ""

# ---------------------------------------------------------------- SAVE / LOAD

func serijalizuj() -> Dictionary:
	var inv: Array = []
	for i in TOTAL_SLOTS:
		if not inventory_data[i].is_empty():
			inv.append({
				"slot": i,
				"id": str(inventory_data[i].get("id", "")),
				"kolicina": int(inventory_data[i].get("kolicina", 1))
			})
	var eq: Dictionary = {}
	for k in equipped_items.keys():
		if not equipped_items[k].is_empty():
			eq[k] = str(equipped_items[k].get("id", ""))
	return {"inventory": inv, "equipment": eq}

func ucitaj(inv: Array, eq: Dictionary) -> void:
	for i in TOTAL_SLOTS:
		inventory_data[i] = {}
	equipped_items.clear()
	for k in equipment_slots.keys():
		_prikazi_opremu(k, {})

	for e in inv:
		var slot = int(e.get("slot", -1))
		var id = str(e.get("id", ""))
		if slot < 0 or slot >= TOTAL_SLOTS or id == "":
			continue
		var item = await ApiManager.get_item(id)
		if item.is_empty() or item.has("error"):
			continue
		var novi = item.duplicate()
		novi["kolicina"] = int(e.get("kolicina", 1))
		inventory_data[slot] = novi

	for k in eq.keys():
		var id = str(eq[k])
		if id == "" or not equipment_slots.has(k):
			continue
		var item = await ApiManager.get_item(id)
		if item.is_empty() or item.has("error"):
			continue
		equipped_items[k] = item
		_prikazi_opremu(k, item)

	_osvezi_grid()
	print("[SAVE] Inventory učitan: %d itema, %d opremljeno" % [inv.size(), equipped_items.size()])

# ---------------------------------------------------------------- PROCESS

func _process(_delta):
	if drag_label:
		var mouse_pos = get_global_mouse_position()
		drag_label.global_position = mouse_pos - Vector2(18, 18)
		if drag_index != -1 and not is_dragging:
			var slot = slots[drag_index]
			var start_pos = slot.global_position + slot.size / 2
			if mouse_pos.distance_to(start_pos) > 10:
				is_dragging = true

func toggle():
	visible = !visible	
