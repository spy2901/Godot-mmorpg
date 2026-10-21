# Izgled oznake buffova u HUD-u: SVE boje, dimenzije i fontovi su ovde (logika je u TopBar.gd). Tekst, bez ikonica.
extends RefCounted

const POZICIJA := Vector2(20, 248)  # px, ispod zlata (gore levo); buffovi pa debuffovi, jedan ispod drugog
const SIRINA := 260                 # px
const FONT_VELICINA := 14
const BOJA_TEKST := Color(0.55, 0.9, 1.0)
const BOJA_DEBUFF := Color(1.0, 0.4, 0.35) # debuffovi (otrov), u posebnom redu ispod buffova
const BOJA_SENKA := Color(0, 0, 0, 0.8)
const SENKA_POMERAJ := 1            # px
const RAZMAK_VREME := "  "          # između efekta i preostalog vremena ("Attack +20%  0:42")
