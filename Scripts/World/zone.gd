# Zone sveta: JEDINA lista (pod u bojama, minimapa, mapa sveta). Nova zona = jedan red ovde + ime u teksti.csv.
# oblast je Rect2 u ravni (x, z). Granica je poluotvorena (Rect2.has_point): tačka na x = 25 pripada zoni 2.
# nivoi = najmanji i najveći nivo spawn tačaka u oblasti (proverava ih test zone_jedan_izvor). Isti kod je i na
# serveru, pa zona_na() radi i tamo, bez mreže.
extends RefCounted

const ZONE := [
	{"ime": "Meadowvale", "oblast": Rect2(-25, -25, 50, 50), "nivoi": Vector2i(1, 10), "boja": Color(0.38, 0.52, 0.3)},
	{"ime": "Darkwood", "oblast": Rect2(25, -25, 50, 50), "nivoi": Vector2i(11, 20), "boja": Color(0.4, 0.33, 0.24)},
]

# Indeks zone u kojoj je tačka (x, z), -1 = van svih zona
static func zona_na(x: float, z: float) -> int:
	for i in ZONE.size():
		if ZONE[i].oblast.has_point(Vector2(x, z)):
			return i
	return -1
