# Minimapa (gore desno): 2D crtež iz podataka, bez druge kamere. Zone iz zone.gd, markeri iz grupa koje klijent već ima
# (neprijatelji i drugi igrači stižu sa servera, NPC-ovi su u sceni), pa ne otkriva ništa što klijent već nema.
# Sever (-z) gore, sopstveni lik je strelica u centru. Točkić iznad minimape menja zum (ZUM), N je uključuje i isključuje.
# Izgled je samo u minimap_stil.gd.
extends Control

const STIL := preload("res://Scripts/UI/minimap_stil.gd")
const Z := preload("res://Scripts/World/zone.gd")
const ZUM := [20.0, 40.0, 80.0] # m od centra do ivice (polovina stranice)

var zum := 1           # indeks u ZUM
var _igrac: Node
var _tocak := 0.0      # sabrani mali koraci točkića (factor < 1) do praga 1
var _crtano_ms := -1000
var _oznaka_zuma: Label

func _ready() -> void:
	if not is_multiplayer_authority():
		visible = false
		set_process(false)
		set_process_input(false)
		set_process_unhandled_input(false)
		return
	_igrac = get_parent()
	while _igrac and not _igrac.has_method("izaberi_cilj"):
		_igrac = _igrac.get_parent()
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -STIL.MARGINA - STIL.VELICINA
	offset_right = -STIL.MARGINA
	offset_top = STIL.MARGINA
	offset_bottom = STIL.MARGINA + STIL.VELICINA
	mouse_filter = Control.MOUSE_FILTER_STOP # klik preko minimape ne ide u svet (ne menja cilj)
	clip_contents = true
	_oznaka_zuma = Label.new()
	_oznaka_zuma.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_oznaka_zuma.add_theme_font_size_override("font_size", STIL.FONT_ZUM)
	_oznaka_zuma.add_theme_color_override("font_color", STIL.BOJA_ZUM)
	_oznaka_zuma.add_theme_color_override("font_outline_color", STIL.BOJA_OUTLINE)
	_oznaka_zuma.add_theme_constant_override("outline_size", STIL.OUTLINE)
	_oznaka_zuma.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, STIL.UVLAKA_ZUM)
	_oznaka_zuma.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_oznaka_zuma.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(_oznaka_zuma)
	postavi_zum(zum)

func postavi_zum(i: int) -> void:
	zum = clampi(i, 0, ZUM.size() - 1)
	_oznaka_zuma.text = tr("%d m") % int(ZUM[zum])
	queue_redraw()

func _process(_d: float) -> void:
	var sada := Time.get_ticks_msec()
	if visible and sada - _crtano_ms >= 1000 / STIL.OSVEZAVANJE_HZ:
		_crtano_ms = sada
		queue_redraw()

# Točkić iznad minimape je njen, ne kamerin. Zum kamere je u Player._input; minimapa je dete igrača, a _input ide obrnutim
# redosledom stabla (dete pre roditelja), pa set_input_as_handled ovde zaustavi zum kamere. Isti ulaz kao kamera
# (MOUSE_BUTTON_WHEEL); mali koraci (factor < 1) se sabiraju do praga 1, jedan nivo po pragu.
func _input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index not in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		return
	if not visible or not get_global_rect().has_point(mb.position) or _pokrivena():
		return
	get_viewport().set_input_as_handled() # i otpuštanje: kamera zumira i na njega
	if not mb.pressed:
		return
	var smer := -1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1 # gore = bliže, kao kamera
	if signf(_tocak) != smer:
		_tocak = 0.0
	_tocak += smer * (mb.factor if mb.factor > 0.0 else 1.0)
	if absf(_tocak) >= 1.0:
		_tocak = 0.0
		postavi_zum(zum + smer)

# Prozori preko minimape (inventar preko celog ekrana, mapa sveta, dijalog): točkić tada ide kao i do sada
func _pokrivena() -> bool:
	var inv := get_node_or_null("../InventoryUI")
	var mapa := _igrac.get_node_or_null("MapaSveta") as CanvasLayer
	return (inv != null and inv.visible) or (mapa != null and mapa.visible) or DialogueUI._active

# N uključuje i isključuje; ne dok se kuca u polje za tekst
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("minimapa") or event.is_echo():
		return
	var fokus := get_viewport().gui_get_focus_owner()
	if fokus is LineEdit or fokus is TextEdit:
		return
	visible = not visible
	get_viewport().set_input_as_handled()

# Markeri u polju minimape: [vrsta, (x, z) u svetu, čvor]; vrsta je "neprijatelj", "igrac", "npc" ili "quest"
func markeri() -> Array:
	var r := []
	if _igrac == null:
		return r
	var c := _centar()
	var rad: float = ZUM[zum]
	var dodaj := func(vrsta: String, n: Node3D) -> void:
		var p := Vector2(n.global_position.x, n.global_position.z)
		if absf(p.x - c.x) <= rad and absf(p.y - c.y) <= rad:
			r.append([vrsta, p, n])
	for e in get_tree().get_nodes_in_group("neprijatelj"):
		if e.is_visible_in_tree() and e.hp > 0:
			dodaj.call("neprijatelj", e)
	for i in get_tree().get_nodes_in_group("player"):
		if i != _igrac and i.is_visible_in_tree(): # tuđi lik je skriven do prvog snimka sa servera
			dodaj.call("igrac", i)
	for n in get_tree().get_nodes_in_group("npc"):
		dodaj.call("quest" if n.interaction_type == n.InteractionType.QUEST_GIVER else "npc", n)
	return r

func _centar() -> Vector2:
	return Vector2(_igrac.global_position.x, _igrac.global_position.z)

func _draw() -> void:
	if _igrac == null:
		return
	var c := _centar()
	var k: float = size.x / (2.0 * ZUM[zum]) # px po m
	var u_px := func(p: Vector2) -> Vector2: return size / 2.0 + (p - c) * k
	draw_rect(Rect2(Vector2.ZERO, size), STIL.BOJA_POZADINA)
	for z in Z.ZONE:
		var o: Rect2 = z.oblast
		draw_rect(Rect2(u_px.call(o.position), o.size * k), Color(z.boja, STIL.PROVIDNOST_ZONA))
	for m in markeri():
		var p: Vector2 = u_px.call(m[1])
		match m[0]:
			"neprijatelj":
				draw_circle(p, STIL.MARKER, STIL.BOJA_NEPRIJATELJ)
			"igrac":
				var boja: Color = STIL.BOJA_MRTAV if m[2].mrtav_sync else STIL.BOJA_IGRAC
				if m[2].nevidljiv_sync:
					boja.a = STIL.PROVIDNOST_NEVIDLJIV
				draw_circle(p, STIL.MARKER, boja)
			"npc":
				draw_circle(p, STIL.MARKER, STIL.BOJA_NPC)
			"quest":
				draw_circle(p, STIL.MARKER, STIL.BOJA_QUEST)
				draw_string(ThemeDB.fallback_font, p + Vector2(-2, -STIL.MARKER - 1), "!", HORIZONTAL_ALIGNMENT_LEFT, -1,
					STIL.FONT_QUEST, STIL.BOJA_QUEST)
	var s := strelica(size / 2.0, _igrac.rotation.y, STIL.STRELICA_DUZINA, STIL.STRELICA_SIRINA)
	draw_colored_polygon(s, STIL.BOJA_STRELICA)
	draw_polyline(s + PackedVector2Array([s[0]]), STIL.BOJA_STRELICA_IVICA, 1.0)
	draw_rect(Rect2(Vector2.ZERO, size), STIL.BOJA_IVICA, false, STIL.IVICA)

# Strelica lika sa vrhom ka smeru gledanja (i za mapu sveta): napred je -basis.z, u (x, z) = (-sin yaw, -cos yaw); na
# mapi x desno, z dole
static func strelica(s: Vector2, yaw: float, duzina: float, sirina: float) -> PackedVector2Array:
	var napred := Vector2(-sin(yaw), -cos(yaw))
	var bok := Vector2(-napred.y, napred.x)
	return PackedVector2Array([s + napred * duzina, s - napred * duzina * 0.6 + bok * sirina, s - napred * duzina * 0.3,
		s - napred * duzina * 0.6 - bok * sirina])
