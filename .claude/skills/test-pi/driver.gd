extends SceneTree
# Drajver za test-pi: dva prava klijenta (agent_test nalozi) protiv game servera na Pi-ju.
#   godot [--headless] --path . --script res://.claude/skills/test-pi/driver.gd -- igrac1|igrac2 dir=/abs/out \
#         host=spajko port=7777 [shot=/abs/slika.png] [registruj=1] --server-url=http://spajko:8001
# Kredencijali stižu SAMO kroz env (TEST_USER_n / TEST_PASS_n iz .env.test), nikad kroz argumente ni log.
# Uloge se usklađuju preko fajlova u dir/ (stanje, pomeranje, kraj), ne po satu. Ispisuje PASS/FAIL linije.

var uloga := ""
var dir := ""
var host := ""
var port := 7777
var shot := ""
var registruj := false
var t := 0.0
var _krenuo := false
var _kraj := false
const MAX_T := 120.0
const GRESKA_WARN_M := 1.0 # najveća greška predikcije iznad ovoga = WARN

func _initialize():
	var args := OS.get_cmdline_user_args()
	uloga = args[0] if args.size() > 0 else ""
	for a in args:
		if a.begins_with("dir="): dir = a.substr(4)
		if a.begins_with("host="): host = a.substr(5)
		if a.begins_with("port="): port = int(a.substr(5))
		if a.begins_with("shot="): shot = a.substr(5)
		if a == "registruj=1": registruj = true

func _process(d):
	t += d
	if not _krenuo and root.has_node("GameState"): # autoload-ovi nisu u stablu u _initialize
		_krenuo = true
		_scenario()
	if t > MAX_T and not _kraj:
		_provera("zavrseno_na_vreme", false, "prekoračeno %d s" % MAX_T)
		return true
	return _kraj

func _provera(ime: String, ok: bool, detalj: String) -> void:
	print("%s %s:%s  %s" % ["PASS" if ok else "FAIL", uloga, ime, detalj])

func _cekaj(uslov: Callable, sek: float) -> bool:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	while not uslov.call():
		if Time.get_ticks_msec() > kraj: return false
		await process_frame
	return true

func _pisi(ime: String, s: String) -> void:
	var f := FileAccess.open(dir + "/" + ime, FileAccess.WRITE)
	f.store_string(s)
	f.close()

func _citaj(ime: String) -> String:
	return FileAccess.get_file_as_string(dir + "/" + ime) if FileAccess.file_exists(dir + "/" + ime) else ""

func _drugi_uloga() -> String:
	return "igrac2" if uloga == "igrac1" else "igrac1"

func _world(): return current_scene.get_node_or_null("World") if current_scene else null
func _moj():
	if _world() == null or not get_multiplayer().has_multiplayer_peer(): return null
	return _world().get_node_or_null(str(get_multiplayer().get_unique_id()))
func _lik_po_imenu(ime: String):
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p != _moj() and p.ime_sync == ime: return p
	return null

func _zavrsi() -> void:
	_pisi(uloga + "_gotov", "1")
	await _cekaj(func(): return _citaj(_drugi_uloga() + "_gotov") != "", 30.0) # drugi još meri nas
	var gs = root.get_node("GameState")
	if gs.token != "":
		await root.get_node("ApiManager").logout(gs.token) # oslobodi sesiju na backendu
	_kraj = true

# ---------------------------------------------------------------- SCENARIO

func _scenario() -> void:
	var api = root.get_node("ApiManager")
	var gs = root.get_node("GameState")
	var n := "1" if uloga == "igrac1" else "2"
	var korisnik := OS.get_environment("TEST_USER_" + n)
	var lozinka := OS.get_environment("TEST_PASS_" + n)
	if not korisnik.begins_with("agent_test"):
		_provera("nalog", false, "TEST_USER_%s mora počinjati sa agent_test" % n)
		_kraj = true
		return

	# 1. pravi /auth tok (login; registracija samo ako nalog ne postoji i registruj=1)
	var r: Dictionary = await api.login(korisnik, lozinka)
	var registrovan := false
	if not r.has("token") and registruj:
		var reg: Dictionary = await api.register(korisnik, lozinka)
		if not reg.has("error"):
			registrovan = true
			r = await api.login(korisnik, lozinka)
		else:
			r = {"error": "login: %s / registracija: %s" % [r.get("error", "?"), reg.error]}
	var ime := str(r.get("ime_lika", ""))
	_provera("prijava", r.has("token") and ime != "", "lik=%s%s%s" % [ime, " (nalog upravo registrovan)" if registrovan else "", "" if r.has("token") else " greška: " + str(r.get("error", "?"))])
	if not r.has("token"):
		_kraj = true
		return
	# direktno (ne GameState.prijavi): ne prepisujemo zapamćeno korisničko ime u user://settings.cfg
	gs.token = str(r.token)
	gs.ime_igraca = ime

	# 2. konekcija na Pi game server
	change_scene_to_file("res://Scenes/UI/MultiplayerTest.tscn")
	await create_timer(1.0).timeout
	var ip := IP.resolve_hostname(host, IP.TYPE_IPV4)
	var spojen: bool = ip != "" and root.get_node("NetworkManager").pridruzi_se(ip, port)
	spojen = spojen and await _cekaj(func(): return _moj() != null, 20.0)
	_provera("konekcija", spojen, "%s (%s):%d" % [host, ip, port])
	if not spojen:
		await _zavrsi()
		return
	var p = _moj()
	var hud = p.get_node("ui/Control")

	# 3. lik iz prave baze: server ga učita (token -> /auth/verify -> /players) i pošalje primi_lik
	var ucitan: bool = await _cekaj(func(): return hud._ucitano and p._inicijalizovan, 20.0)
	_provera("lik_ucitan_iz_baze", ucitan and hud.ime_igraca == ime, "lv=%d hp=%d/%d mana=%d/%d gold=%d poz=%s" % [hud.level, hud.hp, hud.max_hp, hud.mana, hud.max_mana, hud.gold, p.server_poz])
	if not ucitan:
		await _zavrsi()
		return
	_provera("hp_mana", hud.max_hp > 0 and hud.hp > 0 and hud.hp <= hud.max_hp and hud.mana >= 0 and hud.mana <= hud.max_mana and not hud.je_mrtav,
		"hp=%d/%d mana=%d/%d mrtav=%s" % [hud.hp, hud.max_hp, hud.mana, hud.max_mana, hud.je_mrtav])
	_pisi(uloga + "_ime", ime)

	# 4. drugi igrač: nameplate sa njegovim imenom i HP-om koji server šalje (poredi se sa njegovim HUD-om)
	await _cekaj(func():
		var ime2 := _citaj(_drugi_uloga() + "_ime")
		return ime2 != "" and _lik_po_imenu(ime2) != null, 30.0)
	var drugo_ime := _citaj(_drugi_uloga() + "_ime")
	var o = _lik_po_imenu(drugo_ime)
	if o == null:
		_provera("nameplate_drugog", false, "ne vidim drugog igrača (ime='%s')" % drugo_ime)
		await _zavrsi()
		return
	_pisi(uloga + "_hp", str(hud.hp))
	var hp_ok: bool = await _cekaj(func():
		_pisi(uloga + "_hp", str(hud.hp))
		return o.hp_sync == int(_citaj(_drugi_uloga() + "_hp")), 5.0)
	var np = o.get_node_or_null("Nameplate")
	var daljina: float = o.global_position.distance_to(p.global_position)
	var vidljiv: bool = np != null and (np.visible or daljina > o.MAX_PRIKAZ_DALJINA)
	_provera("nameplate_drugog", np != null and vidljiv and o.ime_sync == drugo_ime and hp_ok and not p.has_node("Nameplate"),
		"ime=%s hp_sync=%d/%d (njegov HUD %s) vidljiv=%s daljina=%.1f m" % [o.ime_sync, o.hp_sync, o.max_hp_sync, _citaj(_drugi_uloga() + "_hp"), np.visible if np else false, daljina])

	# 5. kretanje: igrac1 hoda 1 s (server authority + predikcija), igrac2 gleda
	if uloga == "igrac1":
		# ka centru mape: pozicija se čuva u bazi, uvek isti smer bi lik svakim pokretanjem gurao ka ivici
		p.rotation.y = atan2(p.global_position.x, p.global_position.z) # napred je -basis.z
		await create_timer(0.5).timeout
		var pre: Vector3 = p.server_poz
		Input.action_press("ui_up")
		await create_timer(1.0).timeout
		Input.action_release("ui_up")
		await create_timer(0.7).timeout
		var hod: float = p.server_poz.distance_to(pre)
		var razlika: float = p.global_position.distance_to(p.server_poz)
		_provera("kretanje_server_authority", hod > 3.0 and hod < 7.0 and razlika < 0.1,
			"server pomeren %.2f m za 1 s (očekivano ~5), predikcija-server %.3f m, korekcije %d/%d, greška max %.3f m" % [hod, razlika, p.korekcije_glatke, p.korekcije_snap, p.greska_max])
		_pisi("igrac1_pomeren", "%f" % hod)
	else:
		var start: Vector3 = o.global_position
		var dosao: bool = await _cekaj(func(): return _citaj("igrac1_pomeren") != "", 30.0)
		await create_timer(0.5).timeout # INTERP_DELAY + rezerva
		var vidi: float = o.global_position.distance_to(start)
		var server_hod := float(_citaj("igrac1_pomeren"))
		_provera("drugi_vidi_kretanje", dosao and absf(vidi - server_hod) < 0.3, "vidim %.2f m, server %.2f m" % [vidi, server_hod])

	# 6. screenshot (igrac1 u prozoru): okreni se ka drugom igraču pa snimi
	if shot != "" and uloga == "igrac1":
		var kraj := Time.get_ticks_msec() + 1500
		while Time.get_ticks_msec() < kraj:
			var dv: Vector3 = o.global_position - p.global_position
			p.rotation.y = atan2(-dv.x, -dv.z) # napred je -basis.z
			await process_frame
		root.get_viewport().get_texture().get_image().save_png(shot)
		print("[%s] screenshot -> %s (drugi igrač na %.1f m)" % [uloga, shot, o.global_position.distance_to(p.global_position)])
	# greška predikcije sopstvenog lika (npr. snap pri prijavi kad se izgubi reset): WARN, ne FAIL
	if p.greska_max > GRESKA_WARN_M:
		print("WARN %s:greska_predikcije  najveća %.3f m > %.1f m (korekcije glatke %d, snap %d)" % [uloga, p.greska_max, GRESKA_WARN_M, p.korekcije_glatke, p.korekcije_snap])
	await _zavrsi()
