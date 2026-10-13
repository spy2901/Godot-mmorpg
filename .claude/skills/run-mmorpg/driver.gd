extends SceneTree
# Drajver za mmorpg: jedan Godot proces = jedna uloga.
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- server
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- observer
#   godot            --path . --script res://.claude/skills/run-mmorpg/driver.gd -- mover [shot=/abs/putanja.png]
#   server prima i stop=/abs/fajl: gasi se kad fajl postoji (run.sh ga pravi kad mover ispiše CEKAM_GASENJE)
# Pokreće se preko run.sh (server -> observer -> mover). Ispisuje PASS/FAIL linije.
# Backend nije potreban: klijent bez imena lika ne šalje token, pa ga server ne izbacuje.

var uloga := ""
var shot := ""
var stop := ""
var _ceka_gasenje := -1.0
var _menu_t := -1.0       # mover: kad je MainMenu postao aktivan # mover: t kad je počeo da čeka gašenje servera
var t := 0.0
var _faza := ""
var _log_t := 0.0
var _cp := {}          # mover: checkpoint -> pozicija
var _slikano := false
var _video_yaw := false # observer: video tuđi yaw_sync ~ PI/2
var _yaw_t := -1.0      # observer: kad je prvi put video yaw
var _video_drugog := false
var _t0 := -1.0         # mover: kad se pojavio sopstveni lik
const MAX_T := 120.0    # zaštita od zaglavljivanja

func _initialize():
	var args := OS.get_cmdline_user_args()
	uloga = args[0] if args.size() > 0 else ""
	for a in args:
		if a.begins_with("shot="):
			shot = a.substr(5)
		if a.begins_with("stop="):
			stop = a.substr(5)

func _nm(): return root.get_node("NetworkManager")
func _world(): return current_scene.get_node_or_null("World") if current_scene else null
func _id() -> String:
	return str(get_multiplayer().get_unique_id()) if get_multiplayer().has_multiplayer_peer() else ""
func _moj():
	return _world().get_node_or_null(_id()) if _world() else null
func _drugi():
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p.name != _id(): return p
	return null
func _fmt(p) -> String:
	var g: Vector3 = p.global_position
	return "pos=(%.2f, %.2f, %.2f) rot.y=%.2f yaw_sync=%.2f" % [g.x, g.y, g.z, p.rotation.y, p.yaw_sync]
func _provera(ime: String, ok: bool, detalj: String) -> void:
	print("%s %s  %s" % ["PASS" if ok else "FAIL", ime, detalj])

func _process(d):
	t += d
	# Autoload-ovi nisu u stablu u _initialize; čekamo prvi frame
	if _faza == "":
		if root.has_node("GameState"):
			root.get_node("GameState").token = "x" # bez tokena MultiplayerTest vraća na login
			change_scene_to_file("res://Scenes/UI/MultiplayerTest.tscn")
			_faza = "scena"
		return false
	if _faza == "scena":
		if t < 1.0: return false
		_faza = "mreza"
		if uloga == "server": _nm().hostuj()
		else: _nm().pridruzi_se("127.0.0.1")
	_log_t += d
	var log := _log_t >= 0.5
	if log: _log_t = 0.0
	match uloga:
		"server": return _server(log)
		"observer": return _observer(log)
		"mover": return _mover(log)
	push_error("uloga mora biti server|observer|mover")
	return true

func _server(log: bool) -> bool:
	if log and _world():
		for p in _world().get_children():
			if p.is_in_group("player"):
				print("[S t=%.1f] %s %s on_floor=%s" % [t, p.name, _fmt(p), p.is_on_floor()])
	# gasi se na okidač (dok su klijenti živi): quit() zatvara ENet i klijenti odmah dobiju server_disconnected
	if stop != "" and FileAccess.file_exists(stop):
		print("[S] gasim server (okidač)")
		return true
	return t > MAX_T

func _observer(log: bool) -> bool:
	var o = _drugi()
	if o:
		_video_drugog = true
		if absf(o.yaw_sync - PI / 2) < 0.05 and absf(o.rotation.y - o.yaw_sync) < 0.01:
			_video_yaw = true
			if _yaw_t < 0: _yaw_t = t
		# 1.5-3.5 s posle yaw faze mover miruje: šalji unos za TUĐI lik, server mora da ga ignoriše
		if _yaw_t > 0 and t > _yaw_t + 1.5 and t < _yaw_t + 3.5:
			o.posalji_unos.rpc_id(1, Vector2(1, 0), true, 0.0)
		if log: print("[O t=%.1f] tudji %s %s" % [t, o.name, _fmt(o)])
	if (_video_drugog and o == null) or t > MAX_T:
		_provera("observer_vidi_yaw", _video_yaw, "rotation.y = yaw_sync = PI/2 na tuđem liku")
		return true
	return false

func _mover(log: bool) -> bool:
	if _ceka_gasenje >= 0:
		return _mover_ceka_gasenje()
	var p = _moj()
	if p == null:
		return t > MAX_T
	if _t0 < 0: _t0 = t
	var t := t - _t0 + 2.0  # vremenska osa od pojave lika (lik pada na pod ~1 s)
	var w := (t > 4.0 and t < 6.0) or (t > 7.0 and t < 8.0) or t > 14.0
	if w: Input.action_press("ui_up")
	else: Input.action_release("ui_up")
	if t > 4.0 and t < 6.0: p.rotation.y = PI  # ka +z: na -z (0, _, -10) stoji NPC i blokira put
	if t > 7.0 and t < 8.0: p.rotation.y = PI / 2
	if t > 12.5 and t < 12.7: p.posalji_unos.rpc_id(1, Vector2(NAN, 1), false, INF)
	if t > 15.0: p.set_physics_process(false) # prestaje da šalje unos dok "drži" W
	if shot != "" and not _slikano and t > 6.7: # u mirovanju: snimanje koči frame
		_slikano = true
		root.get_viewport().get_texture().get_image().save_png(shot)
		print("[M] screenshot -> ", shot)
	for k in [3.5, 6.5, 8.5, 12.0, 13.5, 15.0, 16.5, 17.5]:
		if t >= k and not _cp.has(k):
			_cp[k] = p.global_position
	if log: print("[M t=%.1f] moj %s" % [t, _fmt(p)])
	if t > 18.0:
		var c := _cp
		var w1: Vector3 = c[6.5] - c[3.5]
		var w2: Vector3 = c[8.5] - c[6.5]
		_provera("na_podu", absf(c[3.5].y - 1.16) < 0.1, "y=%.2f" % c[3.5].y)
		_provera("W_2s_napred", w1.z > 8.5 and w1.z < 11.5 and absf(w1.x) < 1.5, "delta=%s" % w1)
		_provera("yaw_PI/2_ide_-x", w2.x < -4.0 and absf(w2.z) < 1.5, "delta=%s" % w2)
		_provera("tudji_unos_ignorisan", c[12.0].distance_to(c[8.5]) < 0.05, "delta=%s" % (c[12.0] - c[8.5]))
		_provera("NaN_odbacen", c[13.5].distance_to(c[12.0]) < 0.05, "delta=%s" % (c[13.5] - c[12.0]))
		var posle: float = c[16.5].distance_to(c[15.0])
		_provera("istek_unosa_0.5s", posle < 4.5 and c[17.5].distance_to(c[16.5]) < 0.05, "posle prekida %.2f, zatim %.2f" % [posle, c[17.5].distance_to(c[16.5])])
		Input.action_release("ui_up")
		_ceka_gasenje = self.t  # globalno vreme (lokalni t je pomeren)
		print("CEKAM_GASENJE")
	return false

# Server se gasi dok je klijent živ: klijent mora da se vrati na login sa porukom
func _mover_ceka_gasenje() -> bool:
	var scena := current_scene.scene_file_path if current_scene else ""
	var poruka: String = root.get_node("GameState").poruka_logina
	# MainMenu prikaže poruku i obriše je iz GameState; zato se gleda tekst greške na ekranu
	if scena == "res://Scenes/UI/MainMenu.tscn" and _menu_t < 0:
		_menu_t = t
	# još 1 s u meniju, da se u logu vidi ima li grešaka posle prekida
	if _menu_t >= 0 and t - _menu_t > 1.0:
		var ok: bool = current_scene.get("_error_label") != null and current_scene._error_label.text == "Veza sa serverom je prekinuta"
		_provera("server_prekid_vraca_na_login", ok, "scena=%s poruka='%s' token='%s'" % [scena, current_scene._error_label.text, root.get_node("GameState").token])
		return true
	if t - _ceka_gasenje >= 30.0:
		_provera("server_prekid_vraca_na_login", false, "nema promene scene za 30 s (scena=%s poruka='%s')" % [scena, poruka])
		return true
	return false
