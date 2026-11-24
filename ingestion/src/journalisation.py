"""Journal d'exécution et bilan de collecte (S3 — M4)."""
import json
import logging
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path


def configurer_logger(fichier: Path) -> logging.Logger:
    """Logger qui écrit à la fois dans la console et dans un fichier UTF-8."""
    fichier.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("collecteur")
    logger.setLevel(logging.INFO)
    logger.handlers.clear()
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%H:%M:%S")
    for handler in (logging.StreamHandler(), logging.FileHandler(fichier, encoding="utf-8")):
        handler.setFormatter(fmt)
        logger.addHandler(handler)
    return logger


@dataclass
class Bilan:
    """Compteurs d'une exécution. Requêtes HTTP et lignes sont comptées séparément."""
    run: str
    scenario: str
    concurrence: int
    statut: str = "en cours"            # "publié" ou "échec"
    pages_attendues: int = 0
    pages_recues: int = 0
    requetes_http: int = 0              # toutes les tentatives, y compris les échecs
    reprises: int = 0                   # tentatives au-delà de la première
    erreurs: dict = field(default_factory=dict)   # type d'incident -> nombre
    lignes_vues: int = 0
    lignes_valides: int = 0
    lignes_rejetees: int = 0
    motifs_rejet: dict = field(default_factory=dict)
    pages_en_echec: list = field(default_factory=list)
    duree_s: float = 0.0
    _debut: float = field(default_factory=time.perf_counter, repr=False)

    def erreur(self, nature: str) -> None:
        self.erreurs[nature] = self.erreurs.get(nature, 0) + 1

    def rejet(self, motif: str) -> None:
        self.lignes_rejetees += 1
        self.motifs_rejet[motif] = self.motifs_rejet.get(motif, 0) + 1

    def terminer(self, statut: str) -> None:
        self.statut = statut
        self.duree_s = round(time.perf_counter() - self._debut, 3)

    def ecrire(self, fichier: Path) -> dict:
        donnees = {k: v for k, v in asdict(self).items() if not k.startswith("_")}
        fichier.parent.mkdir(parents=True, exist_ok=True)
        fichier.write_text(json.dumps(donnees, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        return donnees
