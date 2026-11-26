"""Chargeur des offres fournisseurs validées en S3 vers PostgreSQL (S4 — M1).

Usage, depuis novamarket/ (venv actif, PostgreSQL démarré) :
    export NOVAMARKET_DSN='host=127.0.0.1 port=15432 dbname=novamarket user=atelier'
    export PGPASSWORD=...            # ou PGPASSFILE ; jamais dans le code ni dans Git
    python transformation/chargement_postgres.py                          # lot S3 (ingestion/data/valid/offres.jsonl)
    python transformation/chargement_postgres.py --secours                # lot de secours (20 offres)
    python transformation/chargement_postgres.py --simuler-echec          # échec volontaire : rien n'est écrit

Modèle (schéma `fournisseur`, séparé des ventes `metier`) :
  fournisseurs           référentiel F01, F02, F03 (contrat de l'API S3)
  offres_observations    grain = une offre observée un jour ; clé (offer_id, observed_on)
  chargements            journal de chaque exécution (bilan)
  rejets_chargement      lignes refusées, avec motif et contenu brut

Un lot = une transaction : en cas d'erreur, aucune écriture partielle (y compris le journal).
Rejeu : INSERT ... ON CONFLICT ; une observation identique est « inchangée », une observation
de même clé mais de valeur différente est « mise à jour ». Un second passage du même lot
ne crée donc aucune ligne.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import sys
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb

RACINE = Path(__file__).resolve().parents[1]                 # novamarket/
ENTREE_S3 = RACINE / "ingestion" / "data" / "valid" / "offres.jsonl"
ENTREE_SECOURS = RACINE / "transformation" / "secours" / "offres.jsonl"
CHAMPS = ("offer_id", "supplier_id", "product_id", "price_cents", "currency", "available_units", "observed_on")

DDL = """
CREATE SCHEMA IF NOT EXISTS fournisseur;

CREATE TABLE IF NOT EXISTS fournisseur.fournisseurs (
    supplier_id text PRIMARY KEY
);
INSERT INTO fournisseur.fournisseurs (supplier_id) VALUES ('F01'), ('F02'), ('F03')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS fournisseur.chargements (
    chargement_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fichier         text        NOT NULL,
    empreinte_sha256 text       NOT NULL,
    lignes_lues     integer     NOT NULL,
    inserees        integer     NOT NULL,
    mises_a_jour    integer     NOT NULL,
    inchangees      integer     NOT NULL,
    rejetees        integer     NOT NULL,
    debut           timestamptz NOT NULL,
    fin             timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fournisseur.offres_observations (
    offer_id        text    NOT NULL,
    observed_on     date    NOT NULL,
    supplier_id     text    NOT NULL REFERENCES fournisseur.fournisseurs (supplier_id),
    product_id      integer NOT NULL REFERENCES metier.products (product_id),
    price_cents     integer NOT NULL CHECK (price_cents >= 0),
    currency        text    NOT NULL CHECK (currency = 'EUR'),
    available_units integer NOT NULL CHECK (available_units >= 0),
    chargement_id   bigint  NOT NULL REFERENCES fournisseur.chargements (chargement_id),
    PRIMARY KEY (offer_id, observed_on)
);

CREATE TABLE IF NOT EXISTS fournisseur.rejets_chargement (
    chargement_id bigint  NOT NULL REFERENCES fournisseur.chargements (chargement_id),
    ligne         integer NOT NULL,
    motif         text    NOT NULL,
    contenu       jsonb,
    PRIMARY KEY (chargement_id, ligne)
);
"""

UPSERT = """
INSERT INTO fournisseur.offres_observations
    (offer_id, observed_on, supplier_id, product_id, price_cents, currency, available_units, chargement_id)
VALUES (%(offer_id)s, %(observed_on)s, %(supplier_id)s, %(product_id)s, %(price_cents)s,
        %(currency)s, %(available_units)s, %(chargement_id)s)
ON CONFLICT (offer_id, observed_on) DO UPDATE SET
    supplier_id = excluded.supplier_id, product_id = excluded.product_id,
    price_cents = excluded.price_cents, currency = excluded.currency,
    available_units = excluded.available_units, chargement_id = excluded.chargement_id
WHERE (o.supplier_id, o.product_id, o.price_cents, o.currency, o.available_units)
      IS DISTINCT FROM
      (excluded.supplier_id, excluded.product_id, excluded.price_cents, excluded.currency, excluded.available_units)
RETURNING (xmax = 0) AS inseree
""".replace("INSERT INTO fournisseur.offres_observations", "INSERT INTO fournisseur.offres_observations AS o", 1)


def entier(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def controler(offre, produits: set[int], fournisseurs: set[str]):
    """Renvoie (ligne typée, None) si valide, sinon (None, motif)."""
    if not isinstance(offre, dict):
        return None, "ligne non objet JSON"
    manquants = [c for c in CHAMPS if offre.get(c) is None]
    if manquants:
        return None, "champ manquant : " + ", ".join(manquants)
    if not isinstance(offre["offer_id"], str) or not offre["offer_id"].strip():
        return None, "offer_id vide"
    if offre["supplier_id"] not in fournisseurs:
        return None, "fournisseur inconnu"
    if not entier(offre["product_id"]) or offre["product_id"] not in produits:
        return None, "produit absent du catalogue"
    if not entier(offre["price_cents"]) or offre["price_cents"] < 0:
        return None, "prix non entier ou négatif (centimes attendus)"
    if offre["currency"] != "EUR":
        return None, "devise différente de EUR"
    if not entier(offre["available_units"]) or offre["available_units"] < 0:
        return None, "unités non entières ou négatives"
    try:
        jour = dt.date.fromisoformat(offre["observed_on"]) if len(str(offre["observed_on"])) == 10 else None
    except (TypeError, ValueError):
        jour = None
    if jour is None:
        return None, "date non ISO AAAA-MM-JJ"
    ligne = {c: offre[c] for c in CHAMPS}
    ligne["observed_on"] = jour
    return ligne, None


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--entree", type=Path, help="fichier JSONL à charger")
    p.add_argument("--secours", action="store_true", help="utiliser transformation/secours/offres.jsonl")
    p.add_argument("--simuler-echec", action="store_true", help="lever une erreur avant COMMIT (preuve du rollback)")
    args = p.parse_args()

    dsn = os.environ.get("NOVAMARKET_DSN")
    if not dsn:
        sys.exit("NOVAMARKET_DSN non défini (ex. host=127.0.0.1 port=15432 dbname=novamarket user=atelier)")
    entree = args.entree or (ENTREE_SECOURS if args.secours else ENTREE_S3)
    contenu = entree.read_bytes()
    debut = dt.datetime.now(dt.timezone.utc)

    bilan = dict(fichier=str(entree.relative_to(RACINE) if entree.is_relative_to(RACINE) else entree),
                 empreinte_sha256=hashlib.sha256(contenu).hexdigest(),
                 lignes_lues=0, inserees=0, mises_a_jour=0, inchangees=0, rejetees=0)
    try:
        with psycopg.connect(dsn, connect_timeout=5) as db:       # une transaction : commit à la sortie, rollback si exception
            db.execute(DDL)
            produits = {r[0] for r in db.execute("SELECT product_id FROM metier.products")}
            fournisseurs = {r[0] for r in db.execute("SELECT supplier_id FROM fournisseur.fournisseurs")}
            chargement_id = db.execute(
                """INSERT INTO fournisseur.chargements
                   (fichier, empreinte_sha256, lignes_lues, inserees, mises_a_jour, inchangees, rejetees, debut)
                   VALUES (%s, %s, 0, 0, 0, 0, 0, %s) RETURNING chargement_id""",
                (bilan["fichier"], bilan["empreinte_sha256"], debut)).fetchone()[0]

            vus = set()
            for numero, texte in enumerate(contenu.decode("utf-8").splitlines(), start=1):
                if not texte.strip():
                    continue
                bilan["lignes_lues"] += 1
                try:
                    brut = json.loads(texte)
                except json.JSONDecodeError:
                    brut, ligne, motif = None, None, "JSON invalide"
                else:
                    ligne, motif = controler(brut, produits, fournisseurs)
                if ligne and (ligne["offer_id"], ligne["observed_on"]) in vus:
                    ligne, motif = None, "doublon de clé dans le lot"
                if motif:
                    bilan["rejetees"] += 1
                    db.execute("INSERT INTO fournisseur.rejets_chargement VALUES (%s, %s, %s, %s)",
                               (chargement_id, numero, motif, Jsonb(brut) if brut is not None else None))
                    continue
                vus.add((ligne["offer_id"], ligne["observed_on"]))
                res = db.execute(UPSERT, {**ligne, "chargement_id": chargement_id}).fetchone()
                if res is None:
                    bilan["inchangees"] += 1
                elif res[0]:
                    bilan["inserees"] += 1
                else:
                    bilan["mises_a_jour"] += 1

            db.execute("""UPDATE fournisseur.chargements SET lignes_lues=%(lignes_lues)s, inserees=%(inserees)s,
                          mises_a_jour=%(mises_a_jour)s, inchangees=%(inchangees)s, rejetees=%(rejetees)s, fin=now()
                          WHERE chargement_id=%(id)s""", {**bilan, "id": chargement_id})
            if args.simuler_echec:
                raise RuntimeError("échec simulé avant COMMIT")
            total = db.execute("SELECT count(*) FROM fournisseur.offres_observations").fetchone()[0]
    except Exception as exc:                                      # rollback déjà fait par le bloc with
        print(json.dumps({**bilan, "statut": "échec, transaction annulée", "erreur": str(exc)}, ensure_ascii=False))
        return 1

    print(json.dumps({**bilan, "chargement_id": chargement_id, "statut": "validé",
                      "observations_en_base": total}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
