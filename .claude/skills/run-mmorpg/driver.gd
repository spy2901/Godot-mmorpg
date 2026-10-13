extends SceneTree
# Drajver za mmorpg: jedan Godot proces = jedna uloga.
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- server
#   godot --headless --path . --script res://.claude/skills/run-mmorpg/driver.gd -- observer
#   godot            --path . --script res://.claude/skills/run-mmorpg/driver.gd -- observer dir=/abs/out shot=/abs/out/nameplate
#   server prima i stop=/abs/fajl: gasi se kad fajl postoji (run.sh ga pravi kad mover ispiše CEKAM_GASENJE)
# Pokreće se preko run.sh (server -> observer -> mover). Ispisuje PASS/FAIL linije.
# Backend nije potreban: klijent bez imena lika ne šalje token, pa ga server ne izbacuje.

var uloga := ""
var shot := ""
var stop := ""
var dir := ""           # zajednički direktorijum: mover upisuje fazu u dir/faza, server je čita
var _cpp := {}          # mover: checkpoint -> predviđena (lokalna) pozicija
var _kor := {}          # mover: checkpoint -> [glatke, snap]
var _faza_rupe := {}    # server: faza -> preskočeni seq-ovi
var _teleportovano := false
var _poslednja_faza := ""
# test rafala: mover zadrži ~24 unosa (0.4 s) pa ih pošalje odjednom; red mora da ih primi i isprazni.
# Višak od ~14 preko kofe se prazni brzinom 1.2*60 - 60 = 12/s -> ~1.2 s; granica sa rezervom:
const RAFAL_PRAZNJENJE_MAX_MS := 2500
var _rafal_vrh := 0
var _rafal_ms := -1
var _rafal_pre := []    # red_zaostatak na ulasku u fazu rafal
var _reset_od := -1.0
var _resetovan := false
var _mover_red_max := 0
var _mover_odbijeno := 0
var _red_max_dozvoljen := 0
var _obs_pre = null     # observer: pozicija tuđeg lika u prošlom frame-u
var _obs_od := -1.0
var _obs_kraci := 0     # koraka većih od brzina*dt*2 (a manjih od PRAG_SNAP)
var _obs_snap := 0
var _obs_max := 0.0     # najveći korak / (brzina*dt)
var _obs_d := 0.0       # delta prethodnog frame-a
var _potion_krenuo := false
var _potion_kraj := false
var _cmd_izvrsena := ""  # server: poslednja izvršena komanda iz dir/potion_cmd
var _server_hp_upisan := ""
var _nameplate_na_serveru := false
# observer: nameplate provere (tuđi lik TestLik)
var _spreman := false
var _sync_poklapanja := 0
var _server_hp_pre := ""
var _cekana_steta := -1     # hp posle poslednje štete na serveru, čeka se u hp_sync
var _steta_ms := 0
var _stete := 0
var _max_kasnjenje_ms := 0
var _samo_tudji := false
var _video_mrtvog := false
var _video_respawn := false
var _snimljeno := {}        # kategorija -> boja/stanje ok
var _snimak_frame := -1
# zastoj klijenta (za seq_bez_rupa_bez_gubitka): meri se tek kad mover upiše fazu, bez prve sekunde faze
const ZASTOJ_PRAG := 0.1    # s: duži frame je zastoj
const ZASTOJ_WARMUP := 1.0  # s od početka faze
const ZASTOJ_PROZOR := 0.5  # s: rupa je opravdana samo zastojem istog procesa u +-0.5 s
var _max_delta := 0.0
var _faza_merenja := ""
var _faza_od := 0.0
var _zastoji: PackedStringArray = [] # "t_kraj delta" (unix s)
var _rupe_po_igracu := {}   # server: peer -> poslednji rupe_seq
var _rupe_dogadjaji := []   # server: [t, peer, broj, faza]
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
var _t0 := -1.0         # mover: početak vremenske ose (lik stao na pod)
var _spawn = null       # mover: [vreme, pozicija] pojave lika (za ispis kad na_podu padne)
const PODLOGA_TIMEOUT := 5.0
const MAX_T := 120.0    # zaštita od zaglavljivanja
var _max_t := MAX_T     # server u repro_login.sh radi duže (maxt=)
var _aktivnost := false # prijava: reliable zahtevi za predmet dok traje sesija
var _izgubi_reset := false # prijava: klijent odbaci reset posle prijave (test hook)

func _initialize():
	var args := OS.get_cmdline_user_args()
	uloga = args[0] if args.size() > 0 else ""
	for a in args:
		if a.begins_with("shot="):
			shot = a.substr(5)
		if a.begins_with("stop="):
			stop = a.substr(5)
		if a.begins_with("dir="):
			dir = a.substr(4)
		if a.begins_with("maxt="):
			_max_t = float(a.substr(5))
		if a == "aktivnost=1":
			_aktivnost = true
		if a == "izgubi_reset=1":
			_izgubi_reset = true

func _nm(): return root.get_node("NetworkManager")
func _world(): return current_scene.get_node_or_null("World") if current_scene else null
func _id() -> String:
	return str(get_multiplayer().get_unique_id()) if get_multiplayer().has_multiplayer_peer() else ""
func _moj():
	return _world().get_node_or_null(_id()) if _world() else null
# observer gleda movera: njegov peer_id je u dir/faza (mover ga upisuje od prve faze)
func _drugi():
	if _world() == null: return null
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ") if dir != "" else PackedStringArray()
	if f.size() == 2: return _world().get_node_or_null(f[1])
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
			if uloga == "potion" or uloga == "prijava": # pravi login preko stub API-ja (token -> TestLik)
				root.get_node("GameState").token = "potion-token"
				root.get_node("GameState").ime_igraca = "TestLik"
			change_scene_to_file("res://Scenes/UI/MultiplayerTest.tscn")
			_faza = "scena"
		return false
	if _faza == "scena":
		if t < 1.0: return false
		_faza = "mreza"
		if uloga == "server": _nm().hostuj()
		else: _nm().pridruzi_se("127.0.0.1")
	_log_t += d
	_meri_zastoj(d)
	var log := _log_t >= 0.5
	if log: _log_t = 0.0
	match uloga:
		"server": return _server(log)
		"observer": return _observer(log, d)
		"mover": return _mover(log)
		"potion": return _potion()
		"prijava": return _prijava()
	push_error("uloga mora biti server|observer|mover")
	return true

func _server(log: bool) -> bool:
	if log and _world():
		for p in _world().get_children():
			if p.is_in_group("player"):
				print("[S t=%.1f] %s %s on_floor=%s" % [t, p.name, _fmt(p), p.is_on_floor()])
	# faza od movera: "ime peer_id"; rupe u seq obradi se broje po fazi
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ") if dir != "" else PackedStringArray()
	var faza := f[0] if f.size() == 2 else "normal"
	if faza != _poslednja_faza: # za analizu rafala (vreme u ms kao [SEQ] linije)
		_poslednja_faza = faza
		print("[S-FAZA] t=%d %s" % [Time.get_ticks_msec(), faza])
	# rupe po igraču (lik koji se odjavio ne sme da "vrati" svoje rupe iz zbira)
	if _world():
		for p in _world().get_children():
			if p.is_in_group("player") and p.rupe_seq > _rupe_po_igracu.get(p.name, 0):
				var n: int = p.rupe_seq - _rupe_po_igracu.get(p.name, 0)
				_rupe_po_igracu[p.name] = p.rupe_seq
				_rupe_dogadjaji.append([Time.get_unix_time_from_system(), str(p.name), n, faza]) # vreme = kad je server primeti
				_faza_rupe[faza] = _faza_rupe.get(faza, 0) + n
				if faza == "normal" or faza == "teleport":
					print("[S t=%.2f] rupa %d u fazi %s, peer %s" % [t, n, faza, p.name])
	if f.size() == 2 and _world() and _world().has_node(f[1]):
		var m = _world().get_node(f[1])
		# zaostatak = red posle obrade u tick-u; Player pamti [vrh, ms] poslednjeg ispražnjenog.
		# Računa se samo zaostatak ispražnjen TOKOM faze rafal (ne ostatak speed-hack-a od ranije).
		if faza == "rafal":
			if _rafal_pre.is_empty(): _rafal_pre = m.red_zaostatak.duplicate()
			if m.red_zaostatak != _rafal_pre and m.red_zaostatak[0] > _rafal_vrh:
				_rafal_vrh = m.red_zaostatak[0]
				_rafal_ms = m.red_zaostatak[1]
		_mover_red_max = m.red_max
		_mover_odbijeno = m.odbijeno_red_pun
		_red_max_dozvoljen = m.UNOS_RED_MAX
	if faza == "reset" and _reset_od < 0: _reset_od = t
	if faza == "reset" and not _resetovan and t - _reset_od > 0.3 and _world() and _world().has_node(f[1]):
		_resetovan = true
		var mr = _world().get_node(f[1])
		mr.server_postavi_poziciju(mr.global_position, true)
		print("[S] reset ", f[1], " (test redundanse posle reset-a)")
	if faza == "teleport" and not _teleportovano and _world() and _world().has_node(f[1]):
		_teleportovano = true
		var m = _world().get_node(f[1])
		m.server_postavi_poziciju(m.global_position + Vector3(3, 0, 0), false) # bez reset-a: odlučuje PRAG_SNAP
		print("[S] teleport ", f[1], " +3 x")
	if _world():
		for p in _world().get_children():
			if not p.is_in_group("player"): continue
			if p.has_node("Nameplate"): _nameplate_na_serveru = true
			if p.ime_lika == "TestLik" and dir != "":
				var st := "%d %d %s" % [p.hp, p.max_hp, p.mrtav]
				if st != _server_hp_upisan:
					_server_hp_upisan = st
					var fh := FileAccess.open(dir + "/server_hp", FileAccess.WRITE)
					fh.store_string(st)
					fh.close()
	# komande od potion klijenta: "br steta N" / "br ubij"
	var cmd := FileAccess.get_file_as_string(dir + "/potion_cmd") if dir != "" else ""
	if cmd != "" and cmd != _cmd_izvrsena and _world():
		for p in _world().get_children():
			if p.is_in_group("player") and p.ime_lika == "TestLik":
				_cmd_izvrsena = cmd
				var c := cmd.split(" ")
				p.server_primi_damage(int(c[2]) if c[1] == "steta" else 100000)
				print("[S] potion komanda: ", cmd)
	# gasi se na okidač (dok su klijenti živi): quit() zatvara ENet i klijenti odmah dobiju server_disconnected
	if stop != "" and FileAccess.file_exists(stop):
		var bez: int = _faza_rupe.get("normal", 0) + _faza_rupe.get("teleport", 0)
		_proveri_rupe()
		_provera("nameplate_nema_na_serveru", not _nameplate_na_serveru, "")
		_provera("rafal_bez_rupa", _faza_rupe.get("rafal", 0) == 0 and _rafal_vrh > 10 and _rafal_ms >= 0 and _rafal_ms <= RAFAL_PRAZNJENJE_MAX_MS,
			"rupe=%d, vrh reda %d, ispražnjen za %d ms (dozvoljeno %d)" % [_faza_rupe.get("rafal", 0), _rafal_vrh, _rafal_ms, RAFAL_PRAZNJENJE_MAX_MS])
		_provera("reset_bez_rupa", _resetovan and _faza_rupe.get("reset", 0) == 0, "reset izveden=%s, rupe u fazi reset=%d" % [_resetovan, _faza_rupe.get("reset", 0)])
		_provera("red_pun_odbacuje", _mover_odbijeno > 0 and _mover_red_max <= _red_max_dozvoljen,
			"odbačeno (pun red) %d, najduži red %d / %d" % [_mover_odbijeno, _mover_red_max, _red_max_dozvoljen])
		print("[S] gasim server (okidač)")
		return true
	return t > _max_t

func _observer(log: bool, d: float) -> bool:
	if not _spreman and _moj():
		_spreman = true
		print("OBSERVER_SPREMAN") # run.sh tek tada pokreće movera i potion klijenta
	_observer_nameplate()
	var o = _drugi()
	if o:
		_video_drugog = true
		if _obs_od < 0: _obs_od = t
		# korak tuđeg lika po frame-u (posle 1 s, kad stignu prvi snimci). SceneTree _process ide pre
		# _process čvora, pa je izmereni korak napravljen sa delta-om PRETHODNOG frame-a.
		if _obs_pre != null and t - _obs_od > 1.0 and _obs_d > 0:
			var korak: float = o.global_position.distance_to(_obs_pre)
			if korak > o.PRAG_SNAP: _obs_snap += 1
			else:
				_obs_max = maxf(_obs_max, korak / (o.brzina * _obs_d))
				if korak > o.brzina * _obs_d * 2 * 1.001: _obs_kraci += 1
		_obs_d = d
		_obs_pre = o.global_position
		if absf(o.yaw_sync - PI / 2) < 0.05 and absf(o.rotation.y - o.yaw_sync) < 0.01:
			_video_yaw = true
			if _yaw_t < 0: _yaw_t = t
		# 1.5-3.5 s posle yaw faze mover miruje: šalji unos za TUĐI lik, server mora da ga ignoriše
		if _yaw_t > 0 and t > _yaw_t + 1.5 and t < _yaw_t + 3.5:
			o.posalji_unos.rpc_id(1, [[1 << 40, Vector2(1, 0), true, 0.0, o._reset_id_prim]])
		if log: print("[O t=%.1f] tudji %s %s" % [t, o.name, _fmt(o)])
	if (_video_drugog and o == null) or t > MAX_T:
		_provera("observer_vidi_yaw", _video_yaw, "rotation.y = yaw_sync = PI/2 na tuđem liku")
		_provera("nameplate_sync_poklapa", _sync_poklapanja > 0, "frame-ova sa ime/hp/max/mrtav = server: %d" % _sync_poklapanja)
		_provera("hp_sync_prati_stetu", _stete >= 2 and _max_kasnjenje_ms <= 250, "šteta=%d, najveće kašnjenje %d ms" % [_stete, _max_kasnjenje_ms])
		_provera("nameplate_samo_tudji", _samo_tudji, "tuđi ima vidljiv Nameplate, sopstveni nema")
		_provera("mrtav_sync_i_respawn", _video_mrtvog and _video_respawn, "mrtav=%s respawn=%s" % [_video_mrtvog, _video_respawn])
		_provera("nameplate_boje", _snimljeno.size() == 4 and not _snimljeno.values().has(false), "%s" % _snimljeno)
		_provera("observer_korak_max_2x", _obs_kraci == 0, "prekoracenja=%d, max korak=%.2f x brzina*dt, snap-ova=%d" % [_obs_kraci, _obs_max, _obs_snap])
		return true
	return false

func _mover(log: bool) -> bool:
	if _ceka_gasenje >= 0:
		return _mover_ceka_gasenje()
	var p = _moj()
	if p == null:
		return t > MAX_T
	if _spawn == null: _spawn = [t, p.global_position]
	if _t0 < 0:
		if not p.is_on_floor() and t - _spawn[0] < PODLOGA_TIMEOUT: return false
		_t0 = t
	var t := t - _t0 + 3.0  # vremenska osa od dodira poda (ranije: pojava + ~1 s pada)
	var w := (t > 4.0 and t < 6.0) or (t > 7.0 and t < 8.0) or (t > 14.0 and t < 18.0) \
		or (t > 18.5 and t < 20.5) or (t > 24.0 and t < 27.0) or (t > 28.0 and t < 30.0) or (t > 40.6 and t < 41.6)
	if w: Input.action_press("ui_up")
	else: Input.action_release("ui_up")
	if t > 4.0 and t < 6.0: p.rotation.y = PI  # ka +z: na -z (0, _, -10) stoji NPC i blokira put
	if t > 7.0 and t < 8.0: p.rotation.y = PI / 2
	if t > 18.5 and t < 20.5: p.rotation.y = -PI / 2 # ka +x, nazad
	if t > 24.0 and t < 27.0: p.rotation.y = 0.0 # ka -z
	if t > 28.0 and t < 30.0: p.rotation.y = PI
	if t > 12.5 and t < 12.7: p.posalji_unos.rpc_id(1, [[p._seq + 1000, Vector2(NAN, 1), false, INF, p._reset_id_prim]])
	p.set_physics_process(not (t > 15.0 and t < 18.0)) # 15-18 s: prestaje da šalje unos dok "drži" W
	p.test_ubrzanje = 3 if t > 24.0 and t < 27.0 else 1 # speed-hack: 3 unosa po tick-u
	p.test_gubitak = 0.3 if t > 27.5 and t < 33.0 else 0.0
	p.test_zadrzi = t > 34.0 and t < 34.4 # ~24 unosa pa rafal: red mora da ih primi bez rupa
	if t > 38.6 and t < 38.7 and not _cp.has("reset_hook"): # paket na putu u trenutku reset-a se izgubi
		_cp["reset_hook"] = true
		p.test_izgubi_posle_reseta = true
		p.test_zakasni_reset = true # i sačuvaj kopiju reset stanja: ubacuje se ponovo pošto lik prohoda
	if t > 41.9 and not _cp.has("zakasneli"): # duplikat reset-a pošto je lik hodao 40.6-41.6 s
		_cp["zakasneli"] = [p.global_position, p.korekcije_glatke + p.korekcije_snap, p.test_ubaci_zakasneli_reset(), p._test_reset_kopija]
	if t > 42.5 and not _cp.has("zakasneli_posle"):
		_cp["zakasneli_posle"] = [p.global_position, p.korekcije_glatke + p.korekcije_snap]
	var faza := "normal"
	if t > 22.0 and t < 23.5: faza = "teleport"
	elif t > 23.5 and t < 27.5: faza = "speedhack"
	elif t > 27.5 and t < 33.5: faza = "gubitak"
	elif t > 33.8 and t < 38.0: faza = "rafal"
	elif t > 38.5 and t < 40.5: faza = "reset"
	_upisi_fazu(faza, p.name)
	if shot != "" and not _slikano and t > 6.7: # u mirovanju: snimanje koči frame
		_slikano = true
		root.get_viewport().get_texture().get_image().save_png(shot)
		print("[M] screenshot -> ", shot)
	for k in [3.5, 6.5, 8.5, 12.0, 13.5, 15.0, 16.5, 17.5, 18.5, 21.5, 22.0, 23.3, 24.5, 26.5, 28.0, 33.0]:
		if t >= k and not _cp.has(k):
			_cp[k] = p.server_poz  # pozicija koju javlja server
			_cpp[k] = p.global_position  # predviđena
			_kor[k] = p.korekcije_glatke + p.korekcije_snap
			if k == 3.5:
				var sudar = p.get_last_slide_collision()
				_cp["podloga"] = [p.is_on_floor(), sudar.get_collider().name if sudar and sudar.get_collider() else "-", sudar.get_position() if sudar else Vector3.ZERO]
	if log: print("[M t=%.1f] moj %s server=%s kor=%d/%d" % [t, _fmt(p), p.server_poz, p.korekcije_glatke, p.korekcije_snap])
	if t > 43.0:
		var z: Array = _cp["zakasneli"]
		var zp: Array = _cp["zakasneli_posle"]
		var kopija = z[3]
		_provera("zakasneli_reset_ignorisan", z[2] and zp[0].distance_to(z[0]) < 0.3 and zp[1] == z[1],
			"ubačen=%s, pomeraj posle ubacivanja %.3f m (reset poz %s), korekcija posle %d" % [z[2], zp[0].distance_to(z[0]), kopija[1] if kopija != null else "-", zp[1] - z[1]])
		_provera("reset_paket_izgubljen", p.test_izgubljen_paket, "hook je izgubio paket koji je bio na putu kad je stigao reset")
		var c := _cp
		var w1: Vector3 = c[6.5] - c[3.5]
		var w2: Vector3 = c[8.5] - c[6.5]
		var pod: Array = c["podloga"]
		_provera("na_podu", absf(c[3.5].y - 1.16) < 0.1, "y=%.2f, spawn %s, is_on_floor=%s, podloga '%s' u %s, čekanje poda %.2f s" % [c[3.5].y, _spawn[1], pod[0], pod[1], pod[2], _t0 - _spawn[0]])
		_provera("W_2s_napred", w1.z > 8.5 and w1.z < 11.5 and absf(w1.x) < 1.5, "delta=%s" % w1)
		_provera("yaw_PI/2_ide_-x", w2.x < -4.0 and absf(w2.z) < 1.5, "delta=%s" % w2)
		_provera("tudji_unos_ignorisan", c[12.0].distance_to(c[8.5]) < 0.05, "delta=%s" % (c[12.0] - c[8.5]))
		_provera("NaN_odbacen", c[13.5].distance_to(c[12.0]) < 0.05, "delta=%s" % (c[13.5] - c[12.0]))
		var posle: float = c[16.5].distance_to(c[15.0])
		_provera("istek_unosa_0.5s", posle < 4.5 and c[17.5].distance_to(c[16.5]) < 0.05, "posle prekida %.2f, zatim %.2f" % [posle, c[17.5].distance_to(c[16.5])])
		var hod: float = c[21.5].distance_to(c[18.5])
		_provera("mirno_0_korekcija", _kor[21.5] == _kor[18.5] and hod > 8.0 and _cpp[21.5].distance_to(c[21.5]) < 0.05,
			"korekcija=%d hod=%.2f razlika posle zaustavljanja=%.3f" % [_kor[21.5] - _kor[18.5], hod, _cpp[21.5].distance_to(c[21.5])])
		_provera("teleport_snap", _kor[23.3] > _kor[22.0] and c[23.3].distance_to(c[22.0]) > 2.5 and _cpp[23.3].distance_to(c[23.3]) < 0.05,
			"server pomeren %.2f, korekcija=%d, razlika=%.3f" % [c[23.3].distance_to(c[22.0]), _kor[23.3] - _kor[22.0], _cpp[23.3].distance_to(c[23.3])])
		var hack: float = c[26.5].distance_to(c[24.5]) / (2.0 * p.brzina)
		_provera("speedhack_max_1.2x", hack > 0.5 and hack < 1.25, "server brzina %.2fx normalne" % hack)
		_provera("gubitak_30%_konvergira", c[33.0].distance_to(c[28.0]) > 7.0 and _cpp[33.0].distance_to(c[33.0]) < 0.05,
			"hod=%.2f razlika=%.3f" % [c[33.0].distance_to(c[28.0]), _cpp[33.0].distance_to(c[33.0])])
		print("[M] korekcije glatke=%d snap=%d, greska predikcije prosek=%.4f max=%.3f m (n=%d)" % [p.korekcije_glatke, p.korekcije_snap, p.greska_suma / maxi(p.greska_n, 1), p.greska_max, p.greska_n])
		Input.action_release("ui_up")
		_upisi_fazu("kraj", p.name)
		_ceka_gasenje = self.t  # globalno vreme (lokalni t je pomeren)
		print("CEKAM_GASENJE")
	return false

var _upisana_faza := ""
func _upisi_fazu(faza: String, id: String) -> void:
	if dir == "" or faza == _upisana_faza: return
	_upisana_faza = faza
	var f := FileAccess.open(dir + "/faza", FileAccess.WRITE)
	f.store_string(faza + " " + id)
	f.close()

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

# ---------------------------------------------------------------- POTION (napitci preko stub API-ja)

func _potion() -> bool:
	if _moj() and not _moj().test_reset_izgubljen and not _potion_krenuo:
		_moj().test_izgubi_reset_prijave = true # odbaci reset posle prijave (učitavanje iz baze)
	if not _potion_krenuo and _moj() and _moj().has_node("ui/Control"):
		_potion_krenuo = true
		_potion_scenario()
	return _potion_kraj or t > MAX_T

func _cekaj(uslov: Callable, sek := 10.0) -> bool:
	var kraj := Time.get_ticks_msec() + int(sek * 1000)
	while not uslov.call():
		if Time.get_ticks_msec() > kraj: return false
		await process_frame
	return true

# količina u "bazi" (stub)
func _baza(item_id: String) -> int:
	var pl: Dictionary = await root.get_node("ApiManager").get_player("TestLik")
	var n := 0
	for e in pl.get("inventory", []):
		if e.id == item_id: n += int(e.kolicina)
	return n

var _cmd_br := 0
func _komanda(c: String) -> void:
	_cmd_br += 1
	var f := FileAccess.open(dir + "/potion_cmd", FileAccess.WRITE)
	f.store_string("%d %s" % [_cmd_br, c])
	f.close()

func _potion_scenario() -> void:
	var p = _moj()
	var hud = p.get_node("ui/Control")
	var inv = p.get_node("ui/InventoryUI")
	var api = root.get_node("ApiManager")
	var ucitan: bool = await _cekaj(func(): return hud.hp == 50 and inv.prebroj_item("small_health_potion") == 3)
	await _cekaj(func(): return p.test_reset_izgubljen and p._reset_id_prim >= 2, 3.0)
	_provera("reset_prijave_bez_snapa", p.test_reset_izgubljen and p._reset_id_prim >= 2 and p.korekcije_snap == 0 and p.greska_max < 1.0,
		"reset odbačen=%s, primenjen reset_id=%d, snap=%d, najveća greška %.3f m, server_poz=%s" % [p.test_reset_izgubljen, p._reset_id_prim, p.korekcije_snap, p.greska_max, p.server_poz])
	_provera("potion_lik_ucitan", ucitan, "hp=%d small=%d" % [hud.hp, inv.prebroj_item("small_health_potion")])
	if not ucitan:
		_potion_kraj = true
		return

	# 1. ispod punog: +30, količina -1 (UI gest = isti klik kao za opremu -> _koristi_item).
	# HP regeneriše +2/s, pa se efekat proverava kao razlika uz malu toleranciju.
	var hp0: int = hud.hp
	await inv._koristi_item("small_health_potion")
	await _cekaj(func(): return hud.hp >= hp0 + 30, 3.0)
	var b: int = await _baza("small_health_potion")
	_provera("napitak_leci", hud.hp - hp0 >= 30 and hud.hp - hp0 <= 34 and b == 2 and inv.prebroj_item("small_health_potion") == 2 and hud._poruka_label.text == "+30 HP",
		"hp %d->%d baza=%d ui=%d poruka='%s'" % [hp0, hud.hp, b, inv.prebroj_item("small_health_potion"), hud._poruka_label.text])

	# cooldown: drugi pokušaj odmah po potvrdi prvog (HP nije pun, pa je jedini razlog cooldown)
	var r: Dictionary = await p.koristi_item_na_serveru("small_health_potion")
	b = await _baza("small_health_potion")
	_provera("cooldown_odbija", hud.hp < hud.max_hp and r.get("poruka") == "Još nije spremno" and b == 2, "hp=%d r=%s baza=%d" % [hud.hp, r, b])

	# 2. +150 na 80/100 -> clamp na 100
	r = await p.koristi_item_na_serveru("large_health_potion")
	await _cekaj(func(): return hud.hp == 100, 3.0)
	b = await _baza("large_health_potion")
	_provera("napitak_clamp_max", r.get("ok", false) and hud.hp == 100 and b == 0, "r=%s hp=%d baza=%d" % [r, hud.hp, b])

	# 3. pun HP: odbijeno, ne troši
	r = await p.koristi_item_na_serveru("medium_health_potion")
	b = await _baza("medium_health_potion")
	_provera("pun_hp_odbija", not r.get("ok", true) and r.get("poruka") == "Već si pun" and b == 3, "r=%s baza=%d" % [r, b])

	# 4. šteta: HP ispod maksimuma za test dva istovremena zahteva
	_komanda("steta 40")
	await _cekaj(func(): return hud.hp <= 64, 3.0)

	# 5. predmet koji nema; 6. nepotrošni
	r = await p.koristi_item_na_serveru("mana_potion")
	_provera("nema_predmet_odbija", r.get("poruka") == "Nemaš taj predmet", "r=%s" % r)
	r = await p.koristi_item_na_serveru("iron_sword")
	b = await _baza("iron_sword")
	_provera("nepotrosni_odbija", r.get("poruka") == "Predmet se ne može koristiti" and b == 1, "r=%s baza=%d" % [r, b])

	# 7. dva istovremena zahteva (direktni RPC, mimo klijentske zaštite) -> jedan komad
	var pre: Dictionary = await api.get_player("TestLik")
	var odgovori := []
	var hvataj := func(d): odgovori.append(d)
	p.item_odgovor.connect(hvataj)
	p.zatrazi_koriscenje_itema.rpc_id(1, "medium_health_potion")
	p.zatrazi_koriscenje_itema.rpc_id(1, "medium_health_potion")
	await _cekaj(func(): return odgovori.size() == 2, 5.0)
	p.item_odgovor.disconnect(hvataj)
	await _cekaj(func(): return hud.hp == 100, 3.0)
	var posle: Dictionary = await api.get_player("TestLik")
	b = await _baza("medium_health_potion")
	var okova := odgovori.filter(func(d): return d.get("ok", false)).size()
	_provera("dva_istovremena_jedan_komad", odgovori.size() == 2 and okova == 1 and b == 2 and int(posle.get("item_use_br", 0)) - int(pre.get("item_use_br", 0)) == 1 and hud.hp == 100,
		"odgovori=%s baza=%d backend_trosenja=%d hp=%d" % [odgovori, b, int(posle.get("item_use_br", 0)) - int(pre.get("item_use_br", 0)), hud.hp])

	# nameplate stanja (observer snima): pun -> 40% -> <25%
	await _snimak("zeleno")
	_komanda("steta 60")
	await _cekaj(func(): return hud.hp <= 50 and hud.hp >= 25, 3.0)
	await _snimak("zuto")
	_komanda("steta 25")
	await _cekaj(func(): return hud.hp < 25, 3.0)
	await _snimak("crveno")

	# 8. mrtav ne može
	_komanda("ubij")
	await _cekaj(func(): return hud.je_mrtav, 3.0)
	r = await p.koristi_item_na_serveru("apple")
	b = await _baza("apple")
	_provera("mrtav_ne_moze", hud.je_mrtav and r.get("poruka") == "Mrtav si" and b == 2, "mrtav=%s r=%s baza=%d" % [hud.je_mrtav, r, b])
	await _snimak("mrtav")
	# respawn (server, 3 s) pa sačekaj da ga observer vidi pre odjave
	await _cekaj(func(): return not hud.je_mrtav, 6.0)
	await _cekaj(func(): return FileAccess.file_exists(dir + "/observer_respawn"), 5.0)
	_potion_kraj = true

# ---------------------------------------------------------------- NAMEPLATE (observer gleda TestLik-a)

func _testlik():
	if _world() == null: return null
	for p in _world().get_children():
		if p.is_in_group("player") and p.name != _id() and p.ime_sync == "TestLik": return p
	return null

func _kategorija(p) -> String:
	if p.mrtav_sync: return "mrtav"
	var deo := float(p.hp_sync) / maxi(p.max_hp_sync, 1)
	return "zeleno" if deo > 0.5 else ("zuto" if deo >= 0.25 else "crveno")

func _observer_nameplate() -> void:
	var p = _testlik()
	if p == null or dir == "": return
	var np = p.get_node_or_null("Nameplate")
	if np and np.visible and not _moj().has_node("Nameplate"): _samo_tudji = true
	# poređenje sa serverom (server upisuje "hp max mrtav" u dir/server_hp)
	var st := FileAccess.get_file_as_string(dir + "/server_hp")
	var f := st.split(" ")
	if f.size() == 3:
		if st != _server_hp_pre:
			var pre := _server_hp_pre.split(" ")
			if pre.size() == 3 and int(f[0]) < int(pre[0]):
				_cekana_steta = int(f[0])
				_steta_ms = Time.get_ticks_msec()
			elif _cekana_steta >= 0 and int(f[0]) != _cekana_steta:
				_cekana_steta = -1 # regen/lečenje pre nego što je šteta stigla: ne meri se
			_server_hp_pre = st
		if p.hp_sync == int(f[0]) and p.max_hp_sync == int(f[1]) and str(p.mrtav_sync) == f[2]:
			_sync_poklapanja += 1
			if _cekana_steta >= 0:
				_stete += 1
				_max_kasnjenje_ms = maxi(_max_kasnjenje_ms, Time.get_ticks_msec() - _steta_ms)
				_cekana_steta = -1
	var traka: Node3D = np.get_node("HpTraka") if np else null
	if p.mrtav_sync and traka and not traka.visible and np.get_node("Pozadina").visible == false \
			and p._ime_label.modulate == p.BOJA_IME_MRTAV:
		_video_mrtvog = true
	if _video_mrtvog and not p.mrtav_sync and p.hp_sync == p.max_hp_sync and traka and traka.visible:
		if not _video_respawn: _marker("observer_respawn")
		_video_respawn = true
	# snimak: potion traži kategoriju u dir/snimi; snima se kad je stanje tu, posle 10 frame-ova (render)
	var trazi := FileAccess.get_file_as_string(dir + "/snimi")
	if trazi == "" or _snimljeno.has(trazi) or _kategorija(p) != trazi:
		_snimak_frame = -1
		return
	if _snimak_frame < 0: _snimak_frame = 0
	_snimak_frame += 1
	if _snimak_frame < 10: return
	var ok: bool
	if trazi == "mrtav":
		ok = not traka.visible and p._ime_label.modulate == p.BOJA_IME_MRTAV
	else:
		var ocekivana: Color = {"zeleno": p.BOJA_HP_VISOK, "zuto": p.BOJA_HP_SREDNJI, "crveno": p.BOJA_HP_NIZAK}[trazi]
		ok = traka.mesh.material.albedo_color == ocekivana and traka.visible
	_snimljeno[trazi] = ok
	if shot != "":
		var putanja := "%s_%s.png" % [shot, trazi]
		root.get_viewport().get_texture().get_image().save_png(putanja)
		print("[O] screenshot %s hp=%d/%d -> %s" % [trazi, p.hp_sync, p.max_hp_sync, putanja])
	_marker("snimljeno_" + trazi)

func _marker(ime: String) -> void:
	var f := FileAccess.open(dir + "/" + ime, FileAccess.WRITE)
	f.close()

# potion: traži snimak kategorije i čeka da ga observer napravi (stanje, ne sat)
func _snimak(kat: String) -> bool:
	var f := FileAccess.open(dir + "/snimi", FileAccess.WRITE)
	f.store_string(kat)
	f.close()
	return await _cekaj(func(): return FileAccess.file_exists(dir + "/snimljeno_" + kat), 20.0)

# ---------------------------------------------------------------- ZASTOJ (za seq_bez_rupa_bez_gubitka)
# Rupa u seq obradi nekog lika je opravdana (WARN) samo ako je proces koji šalje inpute za TAJ lik
# imao frame > ZASTOJ_PRAG u prozoru +-ZASTOJ_PROZOR oko trenutka rupe (posle zastoja Godot nadoknađuje
# tick-ove brže od 1.2x i token bucket ih odbaci). Inače FAIL. Server ne šalje inpute: ne meri se.

func _meri_zastoj(d: float) -> void:
	if dir == "" or uloga == "server" or _moj() == null:
		return
	var f := FileAccess.get_file_as_string(dir + "/faza").split(" ")
	if f.size() != 2:
		return # mover još nije upisao fazu
	var sad := Time.get_unix_time_from_system()
	if f[0] != _faza_merenja:
		_faza_merenja = f[0]
		_faza_od = sad
	if (f[0] != "normal" and f[0] != "teleport") or sad - _faza_od < ZASTOJ_WARMUP:
		return
	var promena := d > _max_delta or d > ZASTOJ_PRAG
	_max_delta = maxf(_max_delta, d)
	if d > ZASTOJ_PRAG:
		_zastoji.append("%f %f" % [sad, d])
	if promena: # fajl po peer-u: uloga, najduži frame, pa zastoji
		var fh := FileAccess.open(dir + "/zastoj_" + _id(), FileAccess.WRITE)
		fh.store_string("%s\n%f\n%s" % [uloga, _max_delta, "\n".join(_zastoji)])
		fh.close()

# [uloga, najduži frame, [[t_kraj, delta], ...]] za peer; [] ako proces nije merio
func _zastoj_peer(peer: String) -> Array:
	var s := FileAccess.get_file_as_string(dir + "/zastoj_" + peer)
	if s == "": return []
	var l := s.split("\n", false)
	var z := []
	for k in range(2, l.size()):
		var v := l[k].split(" ")
		z.append([float(v[0]), float(v[1])])
	return [l[0], float(l[1]), z]

func _proveri_rupe() -> void:
	var naj := [0.0, "-"]
	for f in DirAccess.get_files_at(dir):
		if f.begins_with("zastoj_"):
			var z := _zastoj_peer(f.substr(7))
			if z.size() == 3 and z[1] > naj[0]: naj = [z[1], z[0]]
	var opravdane := 0
	var neopravdane := []
	for e in _rupe_dogadjaji:
		if e[3] != "normal" and e[3] != "teleport": continue
		var z := _zastoj_peer(e[1])
		var ok := false
		for st in (z[2] if z.size() == 3 else []): # zastoj [t_kraj - d, t_kraj] seče [t - P, t + P]
			ok = ok or (st[0] - st[1] <= e[0] + ZASTOJ_PROZOR and st[0] >= e[0] - ZASTOJ_PROZOR)
		if ok: opravdane += e[2]
		else: neopravdane.append("%d (%s)" % [e[2], z[0] if z.size() == 3 else "peer " + e[1]])
	var opis := "rupe po fazi %s, opravdane zastojem %d, bez zastoja %s; najduži frame %.0f ms (%s)" % [_faza_rupe, opravdane, neopravdane, naj[0] * 1000, naj[1]]
	if not neopravdane.is_empty() or opravdane == 0:
		_provera("seq_bez_rupa_bez_gubitka", neopravdane.is_empty(), opis)
	else:
		print("WARN seq_bez_rupa_bez_gubitka  neodlučno (zastoj klijenta): ", opis)

# ---------------------------------------------------------------- PRIJAVA (repro_login.sh: jedna kratka sesija)

var _prijava_t := -1.0
var _akt_t := 0.0
func _prijava() -> bool:
	var p = _moj()
	if p and _izgubi_reset and not p.test_izgubi_reset_prijave and not p.test_reset_izgubljen:
		p.test_izgubi_reset_prijave = true
	if _prijava_t < 0 and p and p.get_node("ui/Control")._ucitano:
		_prijava_t = t
		print("PRIJAVA_UCITAN t=%.2f" % t)
	if _aktivnost and _prijava_t >= 0 and t - _akt_t >= 0.2:
		_akt_t = t
		p.zatrazi_koriscenje_itema.rpc_id(1, "mana_potion") # reliable, ne menja stanje ("Nemaš taj predmet")
	if _prijava_t >= 0 and t - _prijava_t > 5.0:
		print("PRIJAVA_KRAJ snap=%d glatke=%d greska_max=%.3f reset_izgubljen=%s server_poz=%s" % [p.korekcije_snap, p.korekcije_glatke, p.greska_max, p.test_reset_izgubljen, p.server_poz])
		return true
	return t > 30.0
