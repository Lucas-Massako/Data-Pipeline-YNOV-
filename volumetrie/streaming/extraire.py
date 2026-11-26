"""S5 — M2 : lecture en streaming bornée de la partition NYC Taxi (Hugging Face Datasets).

Usage, depuis novamarket/ (venv actif) :
    HF_HUB_DISABLE_XET=1 python volumetrie/streaming/extraire.py --limite 20000
    python volumetrie/streaming/extraire.py --source-locale chemin.parquet   # test hors ligne uniquement

Règle de validité (M2) : les 3 colonnes Start_Zone, Trip_Distance, Trip_Duration sont présentes,
non nulles et numériques. Toute autre ligne est rejetée et comptée par motif.
Les contrôles de cohérence (distances et durées aberrantes) relèvent de M3 (controler.py).

Sorties (volumetrie/sorties/, ignoré par Git) :
    extraction_<horodatage>.jsonl      lignes retenues + position dans le flux (provenance)
    extraction_<horodatage>.bilan.json compteurs parcourues / retenues / rejetées, source, durée
"""
import argparse
import datetime as dt
import json
import math
import os
import sys
import time
from pathlib import Path

ICI = Path(__file__).resolve().parent
sys.path.insert(0, str(ICI.parent / "hf_datasets"))
import acces  # noqa: E402  (mécanisme d'accès fourni : révision épinglée, colonnes projetées)

SORTIES = ICI.parent / "sorties"


def motif_rejet(ligne: dict) -> str | None:
    for colonne in acces.SOURCE["columns"]:
        valeur = ligne.get(colonne)
        if valeur is None:
            return f"{colonne} manquant"
        if isinstance(valeur, bool) or not isinstance(valeur, (int, float)):
            return f"{colonne} non numérique"
        if isinstance(valeur, float) and not math.isfinite(valeur):
            return f"{colonne} non fini"
    return None


def ouvrir_flux(source_locale: Path | None):
    if source_locale is None:
        return acces.ouvrir()
    from datasets import load_dataset          # même API, fichier local : sert seulement aux tests
    return load_dataset("parquet", data_files={"train": str(source_locale)}, split="train",
                        streaming=True, columns=acces.SOURCE["columns"])


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--limite", type=int, default=20_000, help="nombre maximal de lignes parcourues")
    p.add_argument("--source-locale", type=Path, help="Parquet local de test (n'atteste pas le streaming distant)")
    args = p.parse_args()
    if args.limite < 1:
        p.error("--limite doit être >= 1")

    horodatage = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    SORTIES.mkdir(parents=True, exist_ok=True)
    sortie = SORTIES / f"extraction_{horodatage}.jsonl"
    bilan = {
        "source": "locale" if args.source_locale else f"hf://{acces.SOURCE['repo']}",
        "revision": None if args.source_locale else acces.SOURCE["revision"],
        "partition": str(args.source_locale) if args.source_locale else acces.SOURCE["shard"],
        "colonnes": acces.SOURCE["columns"], "limite": args.limite,
        "parcourues": 0, "retenues": 0, "rejetees": 0, "motifs_rejet": {},
        "fichier": str(sortie.relative_to(ICI.parents[1])), "statut": "en cours",
    }
    debut = time.perf_counter()
    flux = iter(ouvrir_flux(args.source_locale))
    try:
        with sortie.open("w", encoding="utf-8") as f:
            for position, ligne in enumerate(flux):
                if position >= args.limite:
                    break
                bilan["parcourues"] += 1                      # compté AVANT tout filtrage
                motif = motif_rejet(ligne)
                if motif:
                    bilan["rejetees"] += 1
                    bilan["motifs_rejet"][motif] = bilan["motifs_rejet"].get(motif, 0) + 1
                    continue
                bilan["retenues"] += 1
                f.write(json.dumps({**{c: ligne[c] for c in acces.SOURCE["columns"]},
                                    "position_source": position}) + "\n")
        bilan["statut"] = "terminé"
    except Exception as exc:                                   # l'incident est consigné, puis relancé
        bilan["statut"] = f"échec : {type(exc).__name__}: {exc}"
        raise
    finally:
        close = getattr(flux, "close", None)                   # fermeture propre même en cas d'erreur
        if close:
            close()
        bilan["duree_s"] = round(time.perf_counter() - debut, 2)
        sortie.with_suffix(".bilan.json").write_text(json.dumps(bilan, ensure_ascii=False, indent=2) + "\n",
                                                     encoding="utf-8")
        print(json.dumps(bilan, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    code = main()
    # Les threads réseau de datasets/fsspec peuvent empêcher l'arrêt de l'interpréteur
    # alors que le flux est fermé et le bilan écrit : on quitte explicitement.
    sys.stdout.flush()
    os._exit(code)
