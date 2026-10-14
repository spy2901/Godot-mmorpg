# Action bar: slotovi sa potrošnim predmetima i tasterima. Ponovo upotrebljiv (ActionBar.tscn): broj slotova,
# tasteri i orijentacija su parametri. Izgled je samo u action_bar_stil.gd.
# Raspored (koji predmet je u kom slotu) drži server po liku (igrač.action_bar, signal action_bar_promenjen);
# izmenu traži igrač.promeni_action_slot. Stanje (količina, cooldown) takođe od servera (igrač.kolicine /
# igrač.cd_do_ms, signal predmet_promenjen); taster samo pošalje zahtev (InventoryUI._koristi_item -> server).
extends Control

const STIL := preload("res://Scripts/UI/action_bar_stil.gd")

@export var broj_slotova := 10
@export var tasteri: Array[Key] = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0]
@export_enum("Horizontalno", "Vertikalno") var orijentacija := 0

var slotovi: Array[String] = []  # item_id po slotu, "" = prazan
var _predmeti: Dictionary = {}   # item_id -> podaci predmeta (ime...) za oznaku; {} dok se čitaju
var _igrac: Node
var _prikaz: Array = []          # po slotu: {panel, oznaka, kolicina, overlay, cd}

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		set_process_unhandled_input(false)
		return
	_igrac = _nadji_igraca()
	slotovi.resize(broj_slotova)
	slotovi.fill("")
	_napravi()
	if _igrac:
		_igrac.predmet_promenjen.connect(_na_predmet)
		_igrac.action_bar_promenjen.connect(_na_raspored)
		_na_raspored()

func _nadji_igraca() -> Node:
	var n := get_parent()
	while n and not n.has_method("koristi_item_na_serveru"):
		n = n.get_parent()
	return n

# ---------------------------------------------------------------- prikaz

func _napravi() -> void:
	var okvir := PanelContainer.new()
	okvir.mouse_filter = Control.MOUSE_FILTER_STOP # klik preko bara ne ide u svet (ne menja cilj)
	var sb := StyleBoxFlat.new()
	sb.bg_color = STIL.BOJA_BAR
	sb.set_border_width_all(STIL.IVICA_BAR)
	sb.border_color = STIL.BOJA_IVICA_BAR
	sb.set_content_margin_all(STIL.PADDING)
	okvir.add_theme_stylebox_override("panel", sb)
	var niz: BoxContainer = HBoxContainer.new() if orijentacija == 0 else VBoxContainer.new()
	niz.add_theme_constant_override("separation", STIL.RAZMAK)
	niz.mouse_filter = Control.MOUSE_FILTER_IGNORE
	okvir.add_child(niz)
	add_child(okvir)
	for i in broj_slotova:
		niz.add_child(_napravi_slot(i))
	# dno ekrana, sredina
	okvir.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM, Control.PRESET_MODE_MINSIZE)
	okvir.grow_horizontal = Control.GROW_DIRECTION_BOTH
	okvir.grow_vertical = Control.GROW_DIRECTION_BEGIN
	okvir.position.y -= STIL.MARGINA_DNO
	_osvezi_sve()

func _napravi_slot(i: int) -> Control:
	var panel := Panel.new()
	panel.name = "Slot%d" % (i + 1)
	panel.custom_minimum_size = Vector2(STIL.SLOT_VELICINA, STIL.SLOT_VELICINA)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var oznaka := _label(STIL.FONT_OZNAKA, STIL.BOJA_OZNAKA, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	var taster := _label(STIL.FONT_TASTER, STIL.BOJA_TEKST, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP)
	taster.text = OS.get_keycode_string(tasteri[i]) if i < tasteri.size() else ""
	var kolicina := _label(STIL.FONT_KOLICINA, STIL.BOJA_TEKST, HORIZONTAL_ALIGNMENT_RIGHT, VERTICAL_ALIGNMENT_BOTTOM)
	var overlay := ColorRect.new()
	overlay.color = STIL.BOJA_CD_OVERLAY
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	var cd := _label(STIL.FONT_CD, STIL.BOJA_CD_TEKST, HORIZONTAL_ALIGNMENT_CENTER, VERTICAL_ALIGNMENT_CENTER)
	for c in [oznaka, overlay, cd]:
		panel.add_child(c)
	for c in [taster, kolicina]: # uvučeni od ivice
		panel.add_child(c)
		c.offset_left = STIL.UVLAKA_TEKSTA
		c.offset_top = STIL.UVLAKA_TEKSTA
		c.offset_right = -STIL.UVLAKA_TEKSTA
		c.offset_bottom = -STIL.UVLAKA_TEKSTA
	_prikaz.append({"panel": panel, "oznaka": oznaka, "taster": taster, "kolicina": kolicina, "overlay": overlay, "cd": cd})
	return panel

func _label(velicina: int, boja: Color, h: HorizontalAlignment, v: VerticalAlignment) -> Label:
	var l := Label.new()
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.set_anchors_preset(Control.PRESET_FULL_RECT)
	l.horizontal_alignment = h
	l.vertical_alignment = v
	l.add_theme_font_size_override("font_size", velicina)
	l.add_theme_color_override("font_color", boja)
	l.add_theme_color_override("font_outline_color", STIL.BOJA_OUTLINE)
	l.add_theme_constant_override("outline_size", STIL.OUTLINE)
	if STIL.FONT:
		l.add_theme_font_override("font", STIL.FONT)
	return l

func _stil_slota(prazan: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = STIL.BOJA_SLOT_PRAZAN if prazan else STIL.BOJA_SLOT
	sb.set_border_width_all(STIL.IVICA)
	sb.border_color = STIL.BOJA_IVICA
	return sb

func _osvezi_sve() -> void:
	for i in broj_slotova:
		_osvezi_slot(i)

func _osvezi_slot(i: int) -> void:
	var p: Dictionary = _prikaz[i]
	var id := slotovi[i]
	p.panel.add_theme_stylebox_override("panel", _stil_slota(id == ""))
	p.oznaka.text = kratka_oznaka(_predmeti.get(id, {})) if id != "" else ""
	var n := kolicina(i)
	p.kolicina.text = str(n) if id != "" else ""
	p.kolicina.add_theme_color_override("font_color", STIL.BOJA_KOLICINA_NULA if id != "" and n == 0 else STIL.BOJA_TEKST)
	var ms := preostalo_ms(i)
	p.overlay.visible = ms > 0
	p.cd.visible = ms > 0
	p.cd.text = str(ceili(ms / 1000.0)) if ms > 0 else ""

func _process(_d: float) -> void:
	for i in broj_slotova: # cooldown odbrojava lokalno do roka koji je javio server
		if slotovi[i] != "" and (preostalo_ms(i) > 0 or _prikaz[i].overlay.visible):
			_osvezi_slot(i)

# "Small Health Potion" -> "SHP", "Apple" -> "A"
static func kratka_oznaka(predmet: Dictionary) -> String:
	var s := ""
	for rec in str(predmet.get("ime", "?")).split(" ", false):
		s += rec[0].to_upper()
	return s.substr(0, 3)

# ---------------------------------------------------------------- stanje od servera

func kolicina(i: int) -> int:
	return int(_igrac.kolicine.get(slotovi[i], 0)) if _igrac and slotovi[i] != "" else 0

func preostalo_ms(i: int) -> int:
	if not _igrac or slotovi[i] == "":
		return 0
	return maxi(0, int(_igrac.cd_do_ms.get(slotovi[i], 0)) - Time.get_ticks_msec())

func _na_predmet(item_id: String) -> void:
	var i := slotovi.find(item_id)
	if i >= 0:
		_osvezi_slot(i)

func _na_raspored() -> void:
	for i in broj_slotova:
		slotovi[i] = str(_igrac.action_bar[i]) if i < _igrac.action_bar.size() else ""
		if slotovi[i] != "" and not _predmeti.has(slotovi[i]):
			_ucitaj_predmet(slotovi[i])
	_osvezi_sve()

func _ucitaj_predmet(id: String) -> void:
	_predmeti[id] = {}
	var predmet: Dictionary = await ApiManager.get_item(id)
	if predmet.is_empty() or predmet.has("error"):
		_predmeti.erase(id) # API nedostupan: pokušava ponovo pri sledećem rasporedu od servera
		return
	_predmeti[id] = predmet
	_osvezi_sve()

# ---------------------------------------------------------------- tasteri

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var i := tasteri.find(event.keycode)
	if i < 0 or i >= broj_slotova:
		return
	get_viewport().set_input_as_handled()
	if _blokirano():
		return
	koristi_slot(i)

# chat/dijalog/prodavnica otvoreni ili fokus u polju za tekst: tasteri bara ne rade
func _blokirano() -> bool:
	var fokus := get_viewport().gui_get_focus_owner()
	if fokus is LineEdit or fokus is TextEdit:
		return true
	var dijalog := get_node_or_null("/root/DialogueUI")
	if dijalog and dijalog.has_method("is_open") and dijalog.is_open():
		return true
	var prodavnica := get_node_or_null("/root/MerchantUI")
	return prodavnica != null and prodavnica.visible

# prazan slot: ništa. Inače postojeći tok (isti kao klik u inventaru): zahtev serveru, server odlučuje.
func koristi_slot(i: int) -> void:
	if i < 0 or i >= broj_slotova or slotovi[i] == "" or not _igrac:
		return
	var inv := _igrac.get_node_or_null("ui/InventoryUI")
	if inv:
		await inv._koristi_item(slotovi[i])
	else:
		await _igrac.koristi_item_na_serveru(slotovi[i])
