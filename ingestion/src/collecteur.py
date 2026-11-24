"""Collecteur asynchrone des offres fournisseurs NovaMarket (S3 — M2, M3, M4).

Usage, depuis novamarket/ avec le venv activé et l'API démarrée :
    python ingestion/src/collecteur.py --scenario clean   --run clean01
    python ingestion/src/collecteur.py --scenario atelier --run atelier01
    python ingestion/src/collecteur.py --scenario panne   --run panne01
    python ingestion/src/collecteur.py --scenario clean   --run seq01 --concurrence 1   # séquentiel

Stratégie :
  1. page 1 seule, pour lire total_pages ;
  2. pages 2..total_pages en parallèle, au plus --concurrence requêtes simultanées (Semaphore) ;
  3. chaque page : au plus --max-essais tentatives ; reprise sur timeout, 429 (Retry-After
     respecté), 5xx, JSON invalide ou réponse incohérente ; arrêt immédiat sur les autres 4xx ;
  4. si toutes les pages sont reçues : validation, puis publication de data/valid/offres.jsonl ;
     sinon : aucun fichier valide publié, bilan en statut "échec".
"""
import argparse
import asyncio
import datetime as dt
import json
import os
import sys
from pathlib import Path

import aiohttp

sys.path.insert(0, str(Path(__file__).resolve().parent))
from journalisation import Bilan, configurer_logger  # noqa: E402
from validation import charger_catalogue, separer      # noqa: E402

RACINE = Path(__file__).resolve().parents[2]          # novamarket/
DONNEES = RACINE / "ingestion" / "data"
CATALOGUE = RACINE / "s2" / "donnees" / "products.csv"
ATTENTE_MAX_S = 10.0                                   # plafond d'attente entre deux essais


class EchecPage(Exception):
    """Page définitivement non obtenue."""


def ecrire_jsonl(fichier: Path, lignes) -> None:
    fichier.parent.mkdir(parents=True, exist_ok=True)
    with fichier.open("w", encoding="utf-8") as f:
        for ligne in lignes:
            f.write(json.dumps(ligne, ensure_ascii=False) + "\n")


class Collecteur:
    def __init__(self, args, bilan, log):
        self.args, self.bilan, self.log = args, bilan, log
        self.base = f"http://127.0.0.1:{args.port}"
        self.limite = asyncio.Semaphore(args.concurrence)
        self.en_vol = 0
        self.bilan_concurrence_max = 0
        self.brut = []                                 # toutes les réponses reçues (raw/)

    async def obtenir_page(self, session, page: int) -> dict:
        params = {"page": page, "scenario": self.args.scenario, "run": self.args.run}
        for essai in range(1, self.args.max_essais + 1):
            attente, nature = None, None
            async with self.limite:                    # borne les appels simultanés
                self.en_vol += 1
                self.bilan_concurrence_max = max(self.bilan_concurrence_max, self.en_vol)
                self.bilan.requetes_http += 1
                if essai > 1:
                    self.bilan.reprises += 1
                try:
                    async with session.get(f"{self.base}/offers", params=params) as rep:
                        texte = await rep.text()
                        self.brut.append({"page": page, "essai": essai, "statut_http": rep.status,
                                          "recu_le": dt.datetime.now().isoformat(timespec="seconds"),
                                          "corps": texte})
                        if rep.status == 200:
                            try:
                                corps = json.loads(texte)
                            except json.JSONDecodeError:
                                nature = "json_invalide"
                            else:
                                if (isinstance(corps, dict) and corps.get("page") == page
                                        and isinstance(corps.get("items"), list)
                                        and isinstance(corps.get("total_pages"), int)):
                                    self.log.info("page %s reçue (essai %s, %s offres)", page, essai, len(corps["items"]))
                                    return corps
                                nature = "reponse_incoherente"
                        elif rep.status == 429:
                            nature = "http_429"
                            try:
                                attente = float(rep.headers.get("Retry-After", ""))
                            except ValueError:
                                attente = None
                        elif rep.status >= 500:
                            nature = f"http_{rep.status}"
                        else:                          # 4xx hors 429 : requête fautive, inutile de réessayer
                            self.bilan.erreur(f"http_{rep.status}")
                            raise EchecPage(f"page {page} : HTTP {rep.status} non récupérable")
                except asyncio.TimeoutError:
                    nature = "timeout"
                except aiohttp.ClientError as exc:
                    nature = "erreur_reseau"
                    self.log.debug("page %s : %s", page, exc)
                finally:
                    self.en_vol -= 1
            # hors du sémaphore : on n'occupe pas une place pendant l'attente
            self.bilan.erreur(nature)
            if essai == self.args.max_essais:
                break
            if attente is None:
                attente = 0.5 * 2 ** (essai - 1)       # 0,5 s ; 1 s ; 2 s ...
            attente = min(attente, ATTENTE_MAX_S)
            self.log.warning("page %s : %s (essai %s/%s), nouvel essai dans %.1f s",
                             page, nature, essai, self.args.max_essais, attente)
            await asyncio.sleep(attente)
        raise EchecPage(f"page {page} : {nature} après {self.args.max_essais} essais")

    async def collecter(self) -> tuple[dict[int, list], list[str]]:
        timeout = aiohttp.ClientTimeout(total=self.args.timeout)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            premiere = await self.obtenir_page(session, 1)
            total = premiere["total_pages"]
            self.bilan.pages_attendues = total
            pages = {1: premiere["items"]}
            taches = {p: asyncio.create_task(self.obtenir_page(session, p)) for p in range(2, total + 1)}
            resultats = await asyncio.gather(*taches.values(), return_exceptions=True)
            echecs = []
            for page, res in zip(taches, resultats):
                if isinstance(res, Exception):
                    echecs.append(str(res))
                    self.bilan.pages_en_echec.append(page)
                else:
                    pages[page] = res["items"]
            # condition d'arrêt : la dernière page annonce next_page = null
            if total in pages and not echecs:
                derniere = next(r for r in self.brut[::-1] if r["page"] == total and r["statut_http"] == 200)
                if json.loads(derniere["corps"]).get("next_page") is not None:
                    echecs.append(f"page {total} : next_page non nul en fin de pagination")
            return pages, echecs


def main() -> int:
    p = argparse.ArgumentParser(description="Collecte asynchrone des offres fournisseurs")
    p.add_argument("--scenario", choices=["clean", "atelier", "panne"], default="atelier")
    p.add_argument("--run", default=dt.datetime.now().strftime("run%Y%m%d%H%M%S"),
                   help="identifiant d'essai (lettres, chiffres, _ ou -) ; en changer pour rejouer les erreurs")
    p.add_argument("--concurrence", type=int, default=3, help="requêtes simultanées maximum")
    p.add_argument("--max-essais", type=int, default=4, help="tentatives maximum par page")
    p.add_argument("--timeout", type=float, default=1.0, help="délai maximum d'une requête (s)")
    p.add_argument("--port", type=int, default=int(os.environ.get("NOVAMARKET_API_PORT", "18080")))
    args = p.parse_args()
    if args.concurrence < 1 or args.max_essais < 1:
        p.error("--concurrence et --max-essais doivent valoir au moins 1")

    log = configurer_logger(DONNEES / "journaux" / args.run / "collecte.log")
    bilan = Bilan(run=args.run, scenario=args.scenario, concurrence=args.concurrence)
    log.info("début : scénario=%s run=%s concurrence=%s max_essais=%s timeout=%ss",
             args.scenario, args.run, args.concurrence, args.max_essais, args.timeout)

    collecteur = Collecteur(args, bilan, log)
    try:
        pages, echecs = asyncio.run(collecteur.collecter())
    except EchecPage as exc:                           # page 1 introuvable
        pages, echecs = {}, [str(exc)]
        bilan.pages_en_echec.append(1)

    bilan.pages_recues = len(pages)
    ecrire_jsonl(DONNEES / "raw" / args.run / "reponses.jsonl", collecteur.brut)

    valides, rejets = separer(pages, charger_catalogue(CATALOGUE))
    bilan.lignes_vues = sum(len(v) for v in pages.values())
    bilan.lignes_valides = len(valides)
    for r in rejets:
        bilan.rejet(r["motif"])
    ecrire_jsonl(DONNEES / "rejected" / args.run / "rejets.jsonl", rejets)

    if echecs:
        for e in echecs:
            log.error(e)
        log.error("lot INCOMPLET : aucune publication dans data/valid/")
        bilan.terminer("échec")
    else:
        ecrire_jsonl(DONNEES / "valid" / args.run / "offres.jsonl", valides)
        publie = DONNEES / "valid" / "offres.jsonl"
        temporaire = publie.with_suffix(".jsonl.tmp")
        ecrire_jsonl(temporaire, valides)
        os.replace(temporaire, publie)                  # publication atomique du lot complet
        log.info("lot complet publié : %s", publie.relative_to(RACINE))
        bilan.terminer("publié")

    donnees = bilan.ecrire(DONNEES / "journaux" / args.run / "bilan.json")
    donnees["concurrence_max_observee"] = collecteur.bilan_concurrence_max
    bilan_fichier = DONNEES / "journaux" / args.run / "bilan.json"
    bilan_fichier.write_text(json.dumps(donnees, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    log.info("bilan : %s", json.dumps(donnees, ensure_ascii=False))
    return 0 if not echecs else 1


if __name__ == "__main__":
    raise SystemExit(main())
