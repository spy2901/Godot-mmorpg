# Izgled okvira cilja i markera na neprijatelju: SVE boje, dimenzije, razmaci i fontovi su ovde
# (logika je u okvir_cilja.gd). Osnovni izgled, bez ikonica.
extends RefCounted

# okvir (vrh ekrana, sredina)
const SIRINA := 220                # px
const MARGINA_VRH := 10            # px od vrha ekrana
const PADDING := 6                 # px unutar okvira
const RAZMAK := 3                  # px između imena i trake
const BOJA_OKVIR := Color(0.0, 0.0, 0.0, 0.45)
const IVICA := 1                   # px
const BOJA_IVICA := Color(0.0, 0.0, 0.0, 0.8)

# HP traka
const VISINA_TRAKE := 14           # px
const BOJA_TRAKA := Color(0.75, 0.12, 0.12)
const BOJA_TRAKA_POZADINA := Color(0.15, 0.03, 0.03, 0.85)

# traka pretnje (ispod HP trake): moja pretnja kao % pretnje mete; puna = PRETNJA_MAX (prag promene mete)
const VISINA_PRETNJE := 4          # px
const PRETNJA_MAX := 110           # % (Enemy.PRAG_PROMENE_META)
const BOJA_PRETNJA := Color(0.95, 0.8, 0.15)
const BOJA_PRETNJA_POZADINA := Color(0.15, 0.12, 0.02, 0.85)

# tekst (FONT = null -> podrazumevani font teme)
const FONT: Font = null
const FONT_IME := 14               # "Goblin  Lv.1"
const FONT_HP := 11                # "40 / 50" preko trake
const BOJA_TEKST := Color(1, 1, 1)
const BOJA_OUTLINE := Color(0, 0, 0)
const OUTLINE := 3

# marker na neprijatelju: ravan prsten oko stopala
const PRSTEN_UNUTRA := 0.55        # m
const PRSTEN_SPOLJA := 0.7         # m
const PRSTEN_Y := -0.95            # m ispod centra neprijatelja (kapsula visine 2)
const BOJA_PRSTEN := Color(1.0, 0.85, 0.2)
