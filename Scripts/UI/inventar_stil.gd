# Izgled novih delova inventara (statistike): boje, fontovi i razmaci su ovde, logika je u inventory_ui.gd.
extends RefCounted

# sažetak statistika lika (dno panela sa opremom)
const SAZETAK_FONT := 13            # px
const SAZETAK_BOJA := Color(0.95, 0.85, 0.55)
const SAZETAK_ODOZDO := 48          # px od dna panela sa opremom
const SAZETAK_VISINA := 40          # px (dva reda kad se tekst prelomi)
const SAZETAK_MARGINA := 10         # px levo i desno
