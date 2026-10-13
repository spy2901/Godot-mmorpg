#!/usr/bin/env python3
"""Analiza rafala unosa iz server.log-ova (MMORPG_DEBUG_SEQ=1): koliko bi red unosa morao da primi.

Upotreba: analiza_rafala.py server.log [server.log ...]
Za svaki peer simulira token bucket iz Player_Movement.gd (stopa 1.2 * 60/s, kapacitet 10) sa
NEOGRANIČENIM redom i meri zaostatak (unosi koji čekaju token). Faze speedhack i gubitak se preskaču
(speedhack namerno šalje 3x, gubitak namerno gubi pakete). Ispisuje najduži zaostatak, p99 vrhova
zaostatka po događaju i najduže vreme pražnjenja.
"""
import re
import sys

STOPA = 1.2 * 60 / 1000.0  # tokena po ms
KAPACITET = 10.0
ISKLJUCENE = {"speedhack", "gubitak"}

vrhovi, praznjenja, rafali = [], [], []
for log in sys.argv[1:]:
    faze, paketi = [], {}
    for l in open(log, errors="replace"):
        if m := re.match(r"\[S-FAZA\] t=(\d+) (\w+)", l):
            faze.append((int(m[1]), m[2]))
        elif m := re.match(r"\[SEQ-P\] t=(\d+) peer (\d+) novih=(\d+)", l):
            paketi.setdefault(m[2], []).append((int(m[1]), int(m[3])))

    def faza(t):
        f = "normal"
        for ft, fn in faze:
            if ft <= t:
                f = fn
        return f

    for peer, ps in paketi.items():
        tokeni, red, t0, vrh, pocetak = KAPACITET, 0, ps[0][0], 0, None
        pret = ps[0][0]
        u_rafalu = False
        for t, n in ps:
            if faza(t) in ISKLJUCENE:
                tokeni, red, vrh, pocetak, pret = KAPACITET, 0, 0, None, t
                continue
            # rafal: posle pauze > 50 ms, zbir novih unosa u paketima koji stižu < 5 ms jedan za drugim
            if t - pret > 50:
                rafali.append(n)
                u_rafalu = True
            elif u_rafalu and t - pret < 5:
                rafali[-1] += n
            else:
                u_rafalu = False
            pret = t
            tokeni = min(KAPACITET, tokeni + (t - t0) * STOPA)
            # unosi čekaju u redu dok ima tokena; red se troši pre novih
            red += n
            uzeto = min(red, int(tokeni))
            red -= uzeto
            tokeni -= uzeto
            t0 = t
            if red > 0 and pocetak is None:
                pocetak = t
            vrh = max(vrh, red)
            if red == 0 and pocetak is not None:
                vrhovi.append(vrh)
                praznjenja.append(t - pocetak)
                vrh, pocetak = 0, None

# stvarni red (posle popravke): [SEQ] ... RED ispražnjen za N ms (vrh V), van speedhack/gubitak/rafal
stvarni = []
for log in sys.argv[1:]:
    faze = [(int(m[1]), m[2]) for m in re.finditer(r"\[S-FAZA\] t=(\d+) (\w+)", open(log, errors="replace").read())]
    for m in re.finditer(r"\[SEQ\] t=(\d+) peer \d+ RED ispražnjen za (\d+) ms \(vrh (\d+)\)", open(log, errors="replace").read()):
        f = "normal"
        for ft, fn in faze:
            if ft <= int(m[1]):
                f = fn
        if f not in ISKLJUCENE | {"rafal"}:
            stvarni.append((int(m[3]), int(m[2])))

def p99(x):
    return sorted(x)[min(len(x) - 1, int(len(x) * 0.99))] if x else 0

print(f"događaja sa zaostatkom: {len(vrhovi)}")
print(f"najduži zaostatak (unosa): {max(vrhovi, default=0)}, p99: {p99(vrhovi)}")
print(f"najduže pražnjenje: {max(praznjenja, default=0)} ms, p99: {p99(praznjenja)} ms")
print(f"rafali posle pauze > 50 ms: {len(rafali)}, najduži {max(rafali, default=0)} novih unosa, p99 {p99(rafali)}")
if stvarni:
    print(f"stvarni red: zaostataka {len(stvarni)}, najduži vrh {max(v for v, _ in stvarni)}, najduže pražnjenje {max(ms for _, ms in stvarni)} ms")
