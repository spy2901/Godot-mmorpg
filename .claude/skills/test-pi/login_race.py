# Paralelna prijava dva agent_test naloga N puta; broji HTTP statuse (500 = sudar sesija, MariaDB 1020).
# Upotreba: python3 login_race.py [API_URL] [N]   (API_URL podrazumevano http://localhost:8000, N=50)
# Nalozi i lozinke iz env (TEST_USER_1/2, TEST_PASS_1/2, npr. set -a; . ./.env.test); ništa se ne ispisuje osim brojki.
import json, os, sys, threading, urllib.request, urllib.error
from collections import Counter

api = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000").rstrip("/")
n = int(sys.argv[2]) if len(sys.argv) > 2 else 50
nalozi = [(os.environ["TEST_USER_1"], os.environ["TEST_PASS_1"]), (os.environ["TEST_USER_2"], os.environ["TEST_PASS_2"])]
if not all(u.startswith("agent_test") for u, _ in nalozi):
    sys.exit("samo agent_test nalozi")

def post(put, telo, token=""):
    r = urllib.request.Request(api + put, data=json.dumps(telo).encode(), method="POST",
                               headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(r, timeout=30) as o:
            return o.status, json.load(o)
    except urllib.error.HTTPError as e:
        return e.code, {}

statusi, tokeni = Counter(), []
for _ in range(n):
    b = threading.Barrier(2)
    def prijava(u, p):
        b.wait()
        s, telo = post("/auth/login", {"username": u, "password": p})
        statusi[s] += 1
        if telo.get("token"): tokeni.append(telo["token"])
    t = [threading.Thread(target=prijava, args=x) for x in nalozi]
    [x.start() for x in t]; [x.join() for x in t]
for tok in tokeni:  # odjava, da ne ostanu sesije
    post("/auth/logout", {}, tok)
print(f"{n} parova prijava: " + ", ".join(f"{k}: {v}" for k, v in sorted(statusi.items())) + f"  (500-ica: {statusi[500]})")
