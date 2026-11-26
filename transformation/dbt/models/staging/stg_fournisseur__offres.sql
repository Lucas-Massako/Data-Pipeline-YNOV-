-- Grain : une offre observée un jour. Renommage en français, prix en euros ajouté.
select
    offer_id                       as offre_id,
    observed_on                    as date_observation,
    supplier_id                    as fournisseur_id,
    product_id                     as produit_id,
    price_cents                    as prix_cents,
    round(price_cents / 100.0, 2)  as prix_euros,
    currency                       as devise,
    available_units                as unites_disponibles,
    chargement_id
from {{ source('fournisseur', 'offres_observations') }}
