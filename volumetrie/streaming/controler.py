"""S5 — M3 : contrôle qualité de l'extraction et préparation de l'entrée Spark.

Usage : python volumetrie/streaming/controler.py volumetrie/sorties/extraction_<horodatage>.jsonl

Règles de qualité (une ligne est rejetée au premier motif rencontré) :
  R1  Start_Zone entier entre 1 et 265 (codes de la table de zones TLC)
  R2  Trip_Distance > 0 et <= 100 miles
  R3  Trip_Duration > 0 et <= 14 400 s (4 h)
  R4  vitesse moyenne <= 100 mph (distance / durée incohérentes sinon)
La zone inconnue de la table (ex. 264/265 « Unknown ») n'est pas rejetée ici : les non-appariements
sont mesurés à la jointure Spark (M4).

Sortie : <extraction>.spark.jsonl  (types normalisés + provenance : révision, partition, position)
         <extraction>.qualite.json (bilan avant / après, par règle)
"""
import argparse
import json
from pathlib import Path

ZONE_MIN, ZONE_MAX = 1, 265
DISTANCE_MAX, DUREE_MAX, VITESSE_MAX = 100.0, 14_400, 100.0


def motif(l: dict) -> str | None:
    zone, distance, duree = l["Start_Zone"], float(l["Trip_Distance"]), float(l["Trip_Duration"])
    if float(zone) != int(zone) or not ZONE_MIN <= int(zone) <= ZONE_MAX:
        return "R1 zone hors 1-265"
    if not 0 < distance <= DISTANCE_MAX:
        return "R2 distance <= 0 ou > 100 miles"
    if not 0 < duree <= DUREE_MAX:
        return "R3 durée <= 0 ou > 4 h"
    if distance / (duree / 3600) > VITESSE_MAX:
        return "R4 vitesse > 100 mph"
    return None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("extraction", type=Path)
    args = p.parse_args()
    bilan_m2 = json.loads(args.extraction.with_suffix(".bilan.json").read_text(encoding="utf-8"))
    sortie = args.extraction.with_suffix(".spark.jsonl")
    if sortie.exists():
        raise SystemExit(f"{sortie} existe déjà : relancer l'extraction pour un nouvel essai")

    bilan = {"entree": str(args.extraction.name), "lignes_avant": 0, "lignes_apres": 0,
             "rejets_par_regle": {}, "provenance": {k: bilan_m2[k] for k in ("source", "revision", "partition")}}
    with args.extraction.open(encoding="utf-8") as src, sortie.open("w", encoding="utf-8") as dst:
        for texte in src:
            l = json.loads(texte)
            bilan["lignes_avant"] += 1
            m = motif(l)
            if m:
                bilan["rejets_par_regle"][m] = bilan["rejets_par_regle"].get(m, 0) + 1
                continue
            bilan["lignes_apres"] += 1
            dst.write(json.dumps({
                "Start_Zone": int(l["Start_Zone"]),
                "Trip_Distance": float(l["Trip_Distance"]),
                "Trip_Duration": float(l["Trip_Duration"]),
                "source_revision": bilan_m2["revision"],
                "source_partition": bilan_m2["partition"],
                "position_source": l["position_source"],
            }) + "\n")
    bilan["lignes_rejetees"] = bilan["lignes_avant"] - bilan["lignes_apres"]
    args.extraction.with_suffix(".qualite.json").write_text(json.dumps(bilan, ensure_ascii=False, indent=2) + "\n",
                                                            encoding="utf-8")
    print(json.dumps({**bilan, "fichier_spark": sortie.name}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
