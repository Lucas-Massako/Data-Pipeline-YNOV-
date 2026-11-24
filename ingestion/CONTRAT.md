# Contrat de l'API fournisseur (S3 — M1)

URL de base : `http://127.0.0.1:18080` (port réglable par `NOVAMARKET_API_PORT`).

| Endpoint | Réponse |
|---|---|
| `GET /health` | `{"status": "ok"}` |
| `GET /offers?page=N&scenario=S&run=R` | une page d'offres |
| `GET /demo` | exemple technique indépendant |

Paramètres de `/offers` : `page` (1 à 6), `scenario` (`clean`, `atelier`, `panne`), `run` (1 à 64 caractères `[a-zA-Z0-9_-]`). Paramètre invalide : HTTP 400.

## Pagination

| Champ | Type | Sens |
|---|---|---|
| `page` | entier | numéro de la page renvoyée |
| `total_pages` | entier | nombre total de pages (6) |
| `next_page` | entier ou `null` | page suivante ; `null` sur la dernière |
| `items` | liste | offres de la page (4 par page) |

Condition d'arrêt : `next_page = null` (page 6 = `total_pages`). Volume attendu : 6 pages × 4 offres = 24 offres.

## Offre

| Champ | Type | Règle |
|---|---|---|
| `offer_id` | texte | identifiant de l'offre — **clé métier** |
| `supplier_id` | texte | F01, F02 ou F03 |
| `product_id` | entier | code produit du catalogue S2 |
| `price_cents` | entier ≥ 0 | prix en centimes |
| `currency` | texte | `EUR` |
| `available_units` | entier ≥ 0 | unités disponibles |
| `observed_on` | texte | date ISO `AAAA-MM-JJ` |

## Exemple de réponse (données fictives)

```json
{"page": 1, "total_pages": 6, "next_page": 2, "items": [
  {"offer_id": "O001", "supplier_id": "F01", "product_id": 1, "price_cents": 625,
   "currency": "EUR", "available_units": 2, "observed_on": "2026-11-24"}, "…"]}
```

## Scénarios comparés

| Scénario | Comportement HTTP (premier essai d'un run) | Contenu des offres |
|---|---|---|
| `clean` | 200 sur les 6 pages | 24 offres conformes |
| `atelier` | page 2 : 429 + `Retry-After: 1` ; page 3 : 200 avec JSON invalide ; page 4 : réponse après environ 1,5 s | page 2 : `supplier_id` absent ; page 3 : `price_cents = "inconnu"` ; page 5 : `product_id = 9999` ; page 6 : doublon de `O001` |
| `panne` | page 6 : 503 à chaque essai | — |

Un HTTP 200 ne garantit pas une donnée correcte : en `atelier`, la page 3 renvoie 200 avec un JSON invalide, et des pages 200 contiennent des offres non conformes.
