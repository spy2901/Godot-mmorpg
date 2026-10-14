# Početno stanje agent_test likova pre svakog /test-pi (server key iz env TEST_SERVER_KEY, samo agent_test*):
#   - pozicija (fiksna), HP 60 (da napitak +30 ne udari u "Već si pun");
#   - small_health_potion tačno CILJ_NAPITAKA komada (POST /players/{ime}/inventory/change, delta);
#   - ostali predmeti i equipment se NE diraju (ostali predmeti samo upozorenje).
# --proveri N: samo ispiši i proveri broj small_health_potion za TEST_USER_1 (posle testa action bara).
# Ključ i lozinke se nikad ne ispisuju; ispis je ime lika, pozicija, HP i broj napitaka.
import json, os, sys, urllib.request

NAPITAK = "small_health_potion"
CILJ_NAPITAKA = 3
HP_POCETNO = 60
POZICIJE = {os.environ["TEST_USER_1"]: (0.0, 1.16, 0.0), os.environ["TEST_USER_2"]: (4.0, 1.16, 0.0)}
api = os.environ["TEST_API_URL"].rstrip("/")
kljuc = os.environ.get("TEST_SERVER_KEY", "")
if not kljuc:
    sys.exit("TEST_SERVER_KEY nije postavljen u .env.test")

def zahtev(put, telo=None):
    r = urllib.request.Request(api + put, method="POST" if telo is not None else "GET",
                               data=json.dumps(telo).encode() if telo is not None else None,
                               headers={"X-Server-Key": kljuc, "Content-Type": "application/json"})
    with urllib.request.urlopen(r, timeout=10) as o:
        return json.load(o)

def broj(lik, item_id):
    return sum(int(e.get("kolicina", 1)) for e in lik.get("inventory", []) if e.get("id") == item_id)

def proveri_ime(ime):
    if not ime.startswith("agent_test"):
        sys.exit(f"odbijeno: '{ime}' nema prefiks agent_test")

if len(sys.argv) == 3 and sys.argv[1] == "--proveri":
    ime = os.environ["TEST_USER_1"]
    proveri_ime(ime)
    try:
        n = broj(zahtev(f"/players/{ime}"), NAPITAK)
    except Exception as e:
        sys.exit(f"{ime}: {type(e).__name__} {getattr(e, 'code', '')}")
    print(f"{ime}: {NAPITAK} u bazi {n} (očekivano {sys.argv[2]})")
    sys.exit(0 if n == int(sys.argv[2]) else 1)

for ime, (x, y, z) in POZICIJE.items():
    proveri_ime(ime)
    try:
        lik = zahtev(f"/players/{ime}")
        if "error" in lik:
            sys.exit(f"{ime}: {lik['error']}")
        ostali = sorted({str(e.get("id")) for e in lik.get("inventory", []) if e.get("id") != NAPITAK})
        if ostali:
            print(f"   UPOZORENJE {ime}: u inventaru ima i drugih predmeta (ne diram): {', '.join(ostali)}")
        n0 = broj(lik, NAPITAK)
        if n0 != CILJ_NAPITAKA:
            r = zahtev(f"/players/{ime}/inventory/change", {"item_id": NAPITAK, "delta": CILJ_NAPITAKA - n0})
            if r.get("status") != "ok":
                sys.exit(f"{ime}: inventory/change {r.get('error', 'nije ok')}")
            lik = zahtev(f"/players/{ime}")  # save šalje inventar kakav je u bazi (posle izmene)
        r = zahtev(f"/players/{ime}/save", {"hp": HP_POCETNO, "mana": lik["mana"], "pos_x": x, "pos_y": y, "pos_z": z,
                                             "inventory": lik["inventory"], "equipment": lik["equipment"]})
        posle = zahtev(f"/players/{ime}")
    except Exception as e:  # HTTPError/URLError: poruka ne sadrži zaglavlja
        sys.exit(f"{ime}: {type(e).__name__} {getattr(e, 'code', '')}")
    if r.get("status") != "ok" or max(abs(posle["pos_" + k] - v) for k, v in zip("xyz", (x, y, z))) > 0.01 \
            or int(posle["hp"]) != min(HP_POCETNO, int(posle["max_hp"])) or broj(posle, NAPITAK) != CILJ_NAPITAKA \
            or (posle["mana"], posle["equipment"]) != (lik["mana"], lik["equipment"]):
        sys.exit(f"{ime}: upis nije potvrđen")
    print(f"   {ime}: ({lik['pos_x']:.2f}, {lik['pos_y']:.2f}, {lik['pos_z']:.2f}) -> ({x}, {y}, {z}), hp {lik['hp']} -> {posle['hp']}, {NAPITAK} {n0} -> {broj(posle, NAPITAK)}")
