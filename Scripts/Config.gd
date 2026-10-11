extends Node

# Default: lokalni MAMP backend za dev rad
var SERVER_URL: String = "http://localhost:8000"

# Tajni ključ game servera (samo dedicated server ga ima). Nikad iz config.cfg, nikad u log.
var SERVER_KEY := ""

const CONFIG_PATH = "user://config.cfg"

func _ready() -> void:
	_ucitaj_iz_fajla()
	_ucitaj_iz_cmdline()
	_ucitaj_server_kljuc()
	print("[CONFIG] SERVER_URL = ", SERVER_URL)

func _ucitaj_iz_fajla() -> void:
	var cfg = ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		SERVER_URL = str(cfg.get_value("server", "url", SERVER_URL))

func _ucitaj_iz_cmdline() -> void:
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--server-url="):
			SERVER_URL = arg.split("=", true, 1)[1]

func _ucitaj_server_kljuc() -> void:
	SERVER_KEY = OS.get_environment("MMORPG_SERVER_KEY")
	if SERVER_KEY != "":
		return
	var args: PackedStringArray = OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--server-key="):
			SERVER_KEY = arg.split("=", true, 1)[1]

func sacuvaj_url(url: String) -> void:
	SERVER_URL = url
	var cfg = ConfigFile.new()
	cfg.set_value("server", "url", url)
	cfg.save(CONFIG_PATH)