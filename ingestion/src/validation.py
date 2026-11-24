"""Règles de validation des offres fournisseurs (S3 — M4).

Une offre est acceptée si elle respecte le contrat de l'API :
  offer_id, supplier_id      texte non vide
  product_id                 entier présent dans le catalogue S2 (s2/donnees/products.csv)
  price_cents                entier >= 0 (centimes)
  currency                   "EUR"
  available_units            entier >= 0
  observed_on                date ISO AAAA-MM-JJ
et si son offer_id n'a pas déjà été accepté dans la même collecte (doublon).
Le premier motif rencontré est retenu.
"""
import csv
import datetime as dt
from pathlib import Path

CHAMPS = ("offer_id", "supplier_id", "product_id", "price_cents",
          "currency", "available_units", "observed_on")


def charger_catalogue(fichier: Path) -> set[int]:
    """Codes produit connus (catalogue S2). Le doublon de la source n'a pas d'effet sur un ensemble."""
    with fichier.open(encoding="utf-8", newline="") as f:
        return {int(ligne["product_id"]) for ligne in csv.DictReader(f)}


def _entier(valeur) -> bool:
    # bool est une sous-classe de int en Python : on l'exclut explicitement
    return isinstance(valeur, int) and not isinstance(valeur, bool)


def motif_rejet(offre, produits: set[int], deja_vus: set[str]) -> str | None:
    """Renvoie None si l'offre est valide, sinon le motif du rejet."""
    if not isinstance(offre, dict):
        return "offre non objet JSON"
    manquants = [c for c in CHAMPS if c not in offre or offre[c] is None]
    if manquants:
        return "champ manquant : " + ", ".join(manquants)
    for champ in ("offer_id", "supplier_id"):
        if not isinstance(offre[champ], str) or not offre[champ].strip():
            return f"{champ} non texte ou vide"
    if not _entier(offre["product_id"]):
        return "product_id non entier"
    if not _entier(offre["price_cents"]):
        return "price_cents non entier"
    if offre["price_cents"] < 0:
        return "price_cents négatif"
    if offre["currency"] != "EUR":
        return "currency différente de EUR"
    if not _entier(offre["available_units"]) or offre["available_units"] < 0:
        return "available_units non entier ou négatif"
    try:
        if not isinstance(offre["observed_on"], str) or len(offre["observed_on"]) != 10:
            raise ValueError
        dt.date.fromisoformat(offre["observed_on"])
    except ValueError:
        return "observed_on non ISO AAAA-MM-JJ"
    if offre["product_id"] not in produits:
        return "product_id absent du catalogue"
    if offre["offer_id"] in deja_vus:
        return "doublon de offer_id"
    return None


def separer(pages: dict[int, list], produits: set[int]):
    """Parcourt les pages dans l'ordre et sépare offres valides et rejets."""
    valides, rejets, deja_vus = [], [], set()
    for page in sorted(pages):
        for position, offre in enumerate(pages[page], start=1):
            motif = motif_rejet(offre, produits, deja_vus)
            if motif is None:
                deja_vus.add(offre["offer_id"])
                valides.append({c: offre[c] for c in CHAMPS})
            else:
                rejets.append({"page": page, "position": position, "motif": motif, "objet_brut": offre})
    return valides, rejets
