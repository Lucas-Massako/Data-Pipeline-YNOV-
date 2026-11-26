"""S5 — M5 : prépare le dossier publication/ (Dataset Card + données autorisées) pour le Hub.

Usage, depuis novamarket/ :
    python volumetrie/publication/preparer.py --version 1    # puis hf upload ... "v1 : ..."
    python volumetrie/publication/preparer.py --version 2    # puis hf upload ... "v2 : ..."

Données publiées : UNIQUEMENT l'agrégat des trajets FICTIFS de volumetrie/secours/ (jeu synthétique
fourni pour l'exercice). Aucune ligne du miroir NYC TaxiData (licence « unknown ») n'est republiée.
  v1 : nb_trajets et distance moyenne par arrondissement
  v2 : ajout de la durée moyenne (min) et de la vitesse moyenne (mph), documenté dans la carte
"""
import argparse
import csv
import json
import shutil
from collections import defaultdict
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

VOL = Path(__file__).resolve().parents[1]
RACINE = VOL.parent
SORTIE = RACINE / "publication"
TRAJETS = VOL / "secours" / "trajets_fictifs.jsonl"
ZONES = VOL / "secours" / "zones.csv"


def agreger(version: int):
    zones = {int(r["LocationID"]): r["Borough"] for r in csv.DictReader(ZONES.open(encoding="utf-8"))}
    lus = rejetes = sans_zone = 0
    acc = defaultdict(lambda: {"n": 0, "dist": 0.0, "duree": 0.0})
    for texte in TRAJETS.open(encoding="utf-8"):
        t = json.loads(texte)
        lus += 1
        if t["Trip_Distance"] <= 0 or t["Trip_Duration"] <= 0:
            rejetes += 1
            continue
        if t["Start_Zone"] not in zones:
            sans_zone += 1
            continue
        a = acc[zones[t["Start_Zone"]]]
        a["n"] += 1
        a["dist"] += t["Trip_Distance"]
        a["duree"] += t["Trip_Duration"]
    lignes = []
    for arr, a in sorted(acc.items(), key=lambda kv: (-kv[1]["n"], kv[0])):
        ligne = {"arrondissement": arr, "nb_trajets": a["n"], "distance_moyenne_miles": round(a["dist"] / a["n"], 3)}
        if version >= 2:
            ligne["duree_moyenne_min"] = round(a["duree"] / a["n"] / 60, 2)
            ligne["vitesse_moyenne_mph"] = round(a["dist"] / (a["duree"] / 3600), 2)
        lignes.append(ligne)
    return lignes, dict(lus=lus, rejetes=rejetes, sans_zone=sans_zone, gardes=sum(l["nb_trajets"] for l in lignes))


def carte(version: int, lignes, cpt) -> str:
    colonnes = [
        "| `arrondissement` | texte | arrondissement TLC (`Borough` de zones.csv) |",
        "| `nb_trajets` | entier | nombre de trajets fictifs retenus |",
        "| `distance_moyenne_miles` | réel | distance moyenne, en miles |",
    ]
    if version >= 2:
        colonnes += ["| `duree_moyenne_min` | réel | durée moyenne, en minutes |",
                     "| `vitesse_moyenne_mph` | réel | distance totale / durée totale, en miles par heure |"]
    revisions = ["- **v1** : agrégat initial (nb_trajets, distance moyenne) par arrondissement."]
    if version >= 2:
        revisions.append("- **v2** : ajout des colonnes `duree_moyenne_min` et `vitesse_moyenne_mph` ; "
                         "lignes, filtres et grain inchangés. Motif : permettre la comparaison des durées en S6.")
    return f"""---
pretty_name: NovaMarket S5 — agrégat de trajets fictifs par arrondissement
license: other
tags:
  - education
  - synthetic
size_categories:
  - n<1K
---

# NovaMarket S5 — agrégat de trajets fictifs

Jeu d'exercice du cours « Ingénierie des données et pipelines SQL » (YNOV, M1 Data IA).
Il est **synthétique et agrégé** : il est calculé à partir du fichier de secours
`volumetrie/secours/trajets_fictifs.jsonl` fourni par le formateur, et de la table de zones TLC
`volumetrie/secours/zones.csv`. Aucune ligne du miroir `DinoPonjevic/NYC_TaxiData`
(révision `5941adbf8c0b9930e47002dc3103de3f9291360d`, licence indiquée « unknown ») n'est republiée.

Usage : pédagogique uniquement. Ne pas utiliser pour une analyse réelle du trafic new-yorkais.

## Colonnes et unités

Grain : **un arrondissement** (Borough). Fichier : `agregat_arrondissements.parquet`, {len(lignes)} lignes.

| Colonne | Type | Description |
|---|---|---|
{chr(10).join(colonnes)}

Pas de valeur manquante. Pas de dimension temporelle (les trajets fictifs ne sont pas datés).

## Extraction et qualité

- Lignes parcourues : {cpt['lus']} ; rejetées (distance ou durée ≤ 0) : {cpt['rejetes']} ;
  sans zone connue (non appariées à zones.csv) : {cpt['sans_zone']} ; retenues : {cpt['gardes']}.
- Clé de jointure `Start_Zone` = `LocationID`, unique dans zones.csv (265 zones).
- Limite : 6 trajets fictifs seulement ; les moyennes n'ont aucune valeur statistique.
- Reproduction, depuis `novamarket/` : `python volumetrie/publication/preparer.py --version {version}`.

## Révisions

{chr(10).join(revisions)}
"""


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--version", type=int, choices=[1, 2], required=True)
    args = p.parse_args()
    lignes, cpt = agreger(args.version)
    if SORTIE.exists():
        shutil.rmtree(SORTIE)                    # dossier régénéré : il ne contient que README + données
    SORTIE.mkdir()
    pq.write_table(pa.Table.from_pylist(lignes), SORTIE / "agregat_arrondissements.parquet")
    (SORTIE / "README.md").write_text(carte(args.version, lignes, cpt), encoding="utf-8")
    print(json.dumps({"version": args.version, "fichiers": sorted(f.name for f in SORTIE.iterdir()),
                      "lignes": lignes, **cpt}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
