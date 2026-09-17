extends Node

const CONFIG_PATH = "user://settings.cfg"

var ime_igraca: String = ""

func _ready() -> void:
	_ucitaj()

func postavi_ime(ime: String) -> void:
	ime_igraca = ime.strip_edges()
	_sacuvaj()

func _sacuvaj() -> void:
	var cfg = ConfigFile.new()
	cfg.set_value("igrac", "ime", ime_igraca)
	cfg.save(CONFIG_PATH)

func _ucitaj() -> void:
	var cfg = ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		ime_igraca = str(cfg.get_value("igrac", "ime", ""))