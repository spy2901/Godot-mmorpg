#!/usr/bin/env python3
"""Lažni backend za run-mmorpg testove (samo stdlib, stanje u memoriji).

Pokretanje: python3 stub_api.py PORT   (run.sh ga podiže i prosleđuje --server-url)
Pokriva samo rute koje game server/klijent zovu u testu. Token "potion-token" -> lik "TestLik".
Nepoznata ruta: 404 {"error": ...} i linija u stderr (vidi se u $OUT/stub.log).
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ITEM_USE_KASNJENJE = 0.3  # s: da se dva istovremena zahteva preklope

def _item(id, ime, tip, **x):
    d = {"id": id, "ime": ime, "tip": tip, "ikonica": "?", "vrednost": 1, "stackable": 1,
         "max_stack": 20, "damage": 0, "armor": 0, "hp_efekat": 0, "mana_efekat": 0, "cooldown_ms": 0}
    d.update(x)
    return d

ITEMS = {i["id"]: i for i in [
    _item("small_health_potion", "Small Health Potion", "consumable", hp_efekat=30, cooldown_ms=5000),
    _item("medium_health_potion", "Medium Health Potion", "consumable", hp_efekat=80, cooldown_ms=7000),
    _item("large_health_potion", "Large Health Potion", "consumable", hp_efekat=150, cooldown_ms=10000),
    _item("mana_potion", "Mana Potion", "consumable", mana_efekat=50, cooldown_ms=5000),
    _item("apple", "Apple", "consumable", hp_efekat=10, cooldown_ms=5000),
    _item("iron_sword", "Iron Sword", "weapon", stackable=0, max_stack=1, damage=10),
]}

PLAYERS = {"TestLik": {
    "ime": "TestLik", "level": 1, "xp": 0, "max_xp": 100, "gold": 100, "napad_damage": 25,
    "hp": 50, "max_hp": 100, "mana": 100, "max_mana": 100, "pos_x": 6, "pos_y": 1, "pos_z": -7,  # van putanje movera, van aggro dometa
    "aktivni_quest_id": None, "quest_progres": 0, "equipment": {},
    "inventory": [
        {"slot": 0, "id": "small_health_potion", "kolicina": 3},
        {"slot": 1, "id": "large_health_potion", "kolicina": 1},
        {"slot": 2, "id": "medium_health_potion", "kolicina": 3},
        {"slot": 3, "id": "iron_sword", "kolicina": 1},
        {"slot": 4, "id": "apple", "kolicina": 2},
    ],
}}
# mover/observer: lik bez pozicije u bazi (0,0,0) -> ostaje na spawn tački; server ga objavi ostalima tek
# posle učitavanja. Veliki HP: neprijatelji mogu da ga napadnu, a smrt (respawn) bi pomerila merenja.
for _ime in ("MoverLik", "ObserverLik"):
    PLAYERS[_ime] = dict(PLAYERS["TestLik"], ime=_ime, hp=100000, max_hp=100000, pos_x=0, pos_y=0, pos_z=0, inventory=[])
TOKENI = {"potion-token": "TestLik", "mover-token": "MoverLik", "observer-token": "ObserverLik"}
LOCK = threading.Lock()


class H(BaseHTTPRequestHandler):
    def _odgovor(self, d, kod=200):
        b = json.dumps(d).encode()
        self.send_response(kod)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _telo(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def do_GET(self):
        p = self.path
        if m := re.fullmatch(r"/items/([\w-]+)", p):
            it = ITEMS.get(m[1])
            return self._odgovor(it) if it else self._odgovor({"error": "Item not found"}, 404)
        if m := re.fullmatch(r"/quests/completed/([\w-]+)", p):
            return self._odgovor({"completed": []})
        if m := re.fullmatch(r"/players/([\w-]+)", p):
            with LOCK:
                pl = PLAYERS.get(m[1])
                return self._odgovor(json.loads(json.dumps(pl))) if pl else self._odgovor({"error": "Player not found"}, 404)
        self._nepoznato()

    def do_POST(self):
        p, d = self.path, self._telo()
        if p == "/auth/verify":
            ime = TOKENI.get(str(d.get("token", "")))
            return self._odgovor({"status": "ok", "ime_lika": ime, "username": ime.lower()} if ime
                                 else {"error": "Nevazeci ili istekao token"}, 200 if ime else 401)
        if m := re.fullmatch(r"/players/([\w-]+)/save", p):
            with LOCK:
                pl = PLAYERS.get(m[1])
                if not pl:
                    return self._odgovor({"error": "Player not found"}, 404)
                # inventar je autoritativan ovde (kao baza); save menja samo hp/manu/poziciju
                for k in ("hp", "mana", "pos_x", "pos_y", "pos_z"):
                    if k in d:
                        pl[k] = d[k]
            return self._odgovor({"status": "ok"})
        if m := re.fullmatch(r"/players/([\w-]+)/item/use", p):
            time.sleep(ITEM_USE_KASNJENJE)
            with LOCK:
                pl = PLAYERS.get(m[1])
                it = ITEMS.get(str(d.get("item_id", "")))
                if not pl:
                    return self._odgovor({"error": "Player not found"})
                if not it:
                    return self._odgovor({"error": "Item not found"})
                if it["tip"] != "consumable" or it["hp_efekat"] + it["mana_efekat"] <= 0:
                    return self._odgovor({"error": "Item nije potrosni"})
                inv = pl["inventory"]
                if sum(e["kolicina"] for e in inv if e["id"] == it["id"]) < 1:
                    return self._odgovor({"error": "Nedovoljno itema"})
                e = next(e for e in inv if e["id"] == it["id"])
                e["kolicina"] -= 1
                if e["kolicina"] == 0:
                    inv.remove(e)
                pl["item_use_br"] = pl.get("item_use_br", 0) + 1  # test: koliko puta je backend trošio
                return self._odgovor({"status": "ok", "item_id": it["id"], "hp_efekat": it["hp_efekat"],
                                      "mana_efekat": it["mana_efekat"], "cooldown_ms": it["cooldown_ms"],
                                      "inventory": inv})
        self._nepoznato()

    def _nepoznato(self):
        print("[STUB] nepoznata ruta:", self.command, self.path, file=sys.stderr, flush=True)
        self._odgovor({"error": "stub: nepoznata ruta"}, 404)

    def log_message(self, fmt, *a):
        print("[STUB]", fmt % a, file=sys.stderr, flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
