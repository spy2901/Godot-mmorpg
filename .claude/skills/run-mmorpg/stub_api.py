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

def _prebroj(inv, eq):
    c = {}
    for e in inv:
        c[e["id"]] = c.get(e["id"], 0) + int(e.get("kolicina", 1))
    for x in eq.values():
        if x:
            c[x] = c.get(x, 0) + 1
    return c


def _item(id, ime, tip, **x):
    d = {"id": id, "ime": ime, "tip": tip, "ikonica": "?", "vrednost": 1, "stackable": 1,
         "max_stack": 20, "damage": 0, "armor": 0, "hp_bonus": 0, "slot": None, "hp_efekat": 0, "mana_efekat": 0, "cooldown_ms": 0}
    d.update(x)
    return d

ITEMS = {i["id"]: i for i in [
    _item("small_health_potion", "Small Health Potion", "consumable", hp_efekat=30, cooldown_ms=5000),
    _item("medium_health_potion", "Medium Health Potion", "consumable", hp_efekat=80, cooldown_ms=7000),
    _item("large_health_potion", "Large Health Potion", "consumable", hp_efekat=150, cooldown_ms=10000),
    _item("mana_potion", "Mana Potion", "consumable", mana_efekat=50, cooldown_ms=5000),
    _item("apple", "Apple", "consumable", hp_efekat=10, cooldown_ms=5000),
    _item("iron_sword", "Iron Sword", "weapon", stackable=0, max_stack=1, damage=25, slot="weapon"),
    # oprema kao u bazi posle migracije 007 (attack = damage, armor, hp_bonus, slot; iron_gloves bez slota)
    _item("golden_sword", "Golden Sword", "weapon", stackable=0, max_stack=1, damage=40, slot="weapon"),
    _item("iron_helmet", "Iron Helmet", "armor", stackable=0, max_stack=1, armor=10, slot="head"),
    _item("iron_chestplate", "Iron Chestplate", "armor", stackable=0, max_stack=1, armor=20, slot="chest"),
    _item("iron_leggings", "Iron Leggings", "armor", stackable=0, max_stack=1, armor=12, slot="legs"),
    _item("iron_boots", "Iron Boots", "armor", stackable=0, max_stack=1, armor=6, slot="boots"),
    _item("steel_shield", "Steel Shield", "armor", stackable=0, max_stack=1, armor=20, hp_bonus=10, slot="shield"),
    _item("dragon_scale_armor", "Dragon Scale Armor", "armor", stackable=0, max_stack=1, armor=35, hp_bonus=50,
          slot="chest"),
    _item("iron_gloves", "Iron Gloves", "armor", stackable=0, max_stack=1, armor=5),
]}

PLAYERS = {"TestLik": {
    "ime": "TestLik", "level": 1, "xp": 0, "max_xp": 100, "gold": 100, "napad_damage": 25,
    "hp": 50, "max_hp": 100, "mana": 100, "max_mana": 100, "pos_x": 9, "pos_y": 1, "pos_z": -7,  # van putanje movera, van aggro dometa
    "aktivni_quest_id": None, "quest_progres": 0, "equipment": {}, "action_bar": None,
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
# MoverLik je nov (0,0,0 = bez pozicije, nasumičan spawn); ObserverLik ima svoju poziciju van putanje movera
# (mover ide x -9..6, z -12..16): na (4, 0) mu je mover u speedhack fazi udarao u leđa (speedhack_max_1.2x 0.42x),
# a na spawn-u bi se stvorili jedan na drugom. Odavde TestLik (9, -7) ostaje ispred kamere (screenshot --window).
# Svi pomoćni likovi imaju fiksnu poziciju van putanje movera (x -9..6, z -12..16) i bar 5 m jedan od drugog (domet
# napada 3.5 m): TestLik (9, -7), ObserverLik (11, 4), RasporedLik (-14, -5), CiljLik (-20, -20), DrugiLik (-15, -16).
# visi se nikad ne učita iz baze; server drajver ga skloni na (14, -14) (VISI_PARKING u driver.gd).
for _ime, _poz in (("MoverLik", (0, 0, 0)), ("ObserverLik", (11, 1.16, 4))):
    PLAYERS[_ime] = dict(PLAYERS["TestLik"], ime=_ime, hp=100000, max_hp=100000,
                         pos_x=_poz[0], pos_y=_poz[1], pos_z=_poz[2], inventory=[])
# ObserverLik ima nekoliko potrošnih predmeta: action bar na screenshot-u (--window) nije prazan
PLAYERS["ObserverLik"]["inventory"] = [
    {"slot": 0, "id": "small_health_potion", "kolicina": 5},
    {"slot": 1, "id": "mana_potion", "kolicina": 2},
    {"slot": 2, "id": "apple", "kolicina": 1},
]
# RasporedLik: raspored action bara posle ponovne prijave (uloga raspored, korak 1 pa korak 2)
PLAYERS["RasporedLik"] = dict(PLAYERS["TestLik"], ime="RasporedLik", pos_x=-14, pos_z=-5, inventory=[
    {"slot": 0, "id": "small_health_potion", "kolicina": 2},
    {"slot": 1, "id": "iron_sword", "kolicina": 1},
    {"slot": 2, "id": "apple", "kolicina": 1},
    {"slot": 3, "id": "mana_potion", "kolicina": 1},
])
# CiljLik: ciljanje (uloga cilj), u uglu mape da test neprijatelji ne smetaju ostalima
PLAYERS["CiljLik"] = dict(PLAYERS["TestLik"], ime="CiljLik", pos_x=-20, pos_y=1.16, pos_z=-20, inventory=[])
# DrugiLik: drugi igrač pored CiljLik-ovog cilja (napad bez sopstvenog cilja)
PLAYERS["DrugiLik"] = dict(PLAYERS["TestLik"], ime="DrugiLik", pos_x=-15, pos_y=1.16, pos_z=-16, inventory=[])
# AiLik / Ai2Lik: AI neprijatelja (uloga ai, server vodi scenario oko test goblina na (20, 20), aggro 5 m): oba van
# aggro-a na početku (6.3 m i 7.2 m), u uglu van putanje movera i ostalih likova. HP 1000: goblin ih udara tokom testa.
for _ime, _poz in (("AiLik", (14, 22)), ("Ai2Lik", (24, 14))):
    PLAYERS[_ime] = dict(PLAYERS["TestLik"], ime=_ime, hp=1000, max_hp=1000, pos_x=_poz[0], pos_y=1.16, pos_z=_poz[1],
                         inventory=[])
# OpremaLik: oprema i statistike (uloga oprema, korak 1 pa korak 2 = ponovna prijava); osnovno attack 25, max HP 100.
# Oprema2Lik (korak 3): drugi igrač koji pokušava da opremi tuđi predmet. Obojica van putanje movera i ostalih.
PLAYERS["OpremaLik"] = dict(PLAYERS["TestLik"], ime="OpremaLik", hp=100, max_hp=100, pos_x=-20, pos_y=1.16, pos_z=10,
                            equipment={}, inventory=[{"slot": i, "id": x, "kolicina": 1} for i, x in enumerate(
                                ["iron_sword", "iron_helmet", "iron_chestplate", "iron_leggings", "iron_boots",
                                 "steel_shield", "dragon_scale_armor", "iron_gloves"])])
# Oprema2Lik ima HP 50/1000 (regeneracija nikad ne stane), a stub njegov /save drži SPORI_SAVE s: posle njegove odjave
# server snima dok mu regeneracija otkucava (server_ne_salje_hp_odjavljenom).
PLAYERS["Oprema2Lik"] = dict(PLAYERS["TestLik"], ime="Oprema2Lik", hp=50, max_hp=1000, pos_x=-20, pos_y=1.16, pos_z=16,
                             inventory=[])
SPORI_SAVE = {"Oprema2Lik": 2.5}
TOKENI = {"oprema-token": "OpremaLik", "oprema2-token": "Oprema2Lik", "ailik-token": "AiLik", "ai2lik-token": "Ai2Lik", "potion-token": "TestLik", "mover-token": "MoverLik", "observer-token": "ObserverLik",
          "raspored-token": "RasporedLik", "cilj-token": "CiljLik", "drugi-token": "DrugiLik"}
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
            if d.get("token") == "visi-token":  # verify koji visi (duže od ApiManager 3x8 s): server mora sam da izbaci peer-a
                time.sleep(40)
                return self._odgovor({"error": "istek"}, 504)
            ime = TOKENI.get(str(d.get("token", "")))
            return self._odgovor({"status": "ok", "ime_lika": ime, "username": ime.lower()} if ime
                                 else {"error": "Nevazeci ili istekao token"}, 200 if ime else 401)
        if m := re.fullmatch(r"/players/([\w-]+)/save", p):
            if m[1] in SPORI_SAVE:
                print(f"[STUB] spori save {m[1]} ({SPORI_SAVE[m[1]]} s)", file=sys.stderr, flush=True)
                time.sleep(SPORI_SAVE[m[1]])
            with LOCK:
                pl = PLAYERS.get(m[1])
                if not pl:
                    return self._odgovor({"error": "Player not found"}, 404)
                # hp/mana/pozicija uvek; inventar i oprema kao backend: samo kad se broj komada slaže sa "bazom"
                # (inventar ostaje autoritativan ovde: item/use i kupovina ga menjaju mimo game servera)
                for k in ("hp", "mana", "pos_x", "pos_y", "pos_z"):
                    if k in d:
                        pl[k] = d[k]
                if "inventory" in d and _prebroj(d["inventory"], d.get("equipment", {})) == \
                        _prebroj(pl.get("inventory", []), pl.get("equipment", {})):
                    pl["inventory"], pl["equipment"] = d["inventory"], d.get("equipment", {})
            return self._odgovor({"status": "ok"})
        if m := re.fullmatch(r"/players/([\w-]+)/action_bar", p):  # kao backend: 10 slotova, predmeti postoje
            sl = d.get("slotovi")
            if not isinstance(sl, list) or len(sl) != 10:
                return self._odgovor({"error": "action bar mora imati 10 slotova"})
            if any(i is not None and i not in ITEMS for i in sl):
                return self._odgovor({"error": "Item not found"})
            with LOCK:
                if m[1] not in PLAYERS:
                    return self._odgovor({"error": "Player not found"})
                PLAYERS[m[1]]["action_bar"] = sl
            return self._odgovor({"status": "ok", "action_bar": sl})
        if m := re.fullmatch(r"/players/([\w-]+)/shop/buy", p):  # bez golda: samo doda komad u novi stack
            with LOCK:
                pl = PLAYERS.get(m[1])
                if not pl or str(d.get("item_id")) not in ITEMS:
                    return self._odgovor({"error": "Player not found" if not pl else "Item not found"})
                inv = pl["inventory"]
                inv.append({"slot": max([e["slot"] for e in inv], default=-1) + 1, "id": d["item_id"], "kolicina": 1})
                return self._odgovor({"status": "ok", "gold": pl["gold"], "inventory": inv})
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
