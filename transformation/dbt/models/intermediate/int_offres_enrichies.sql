-- Réutilisable : chaque observation d'offre + son produit + le prix de vente moyen NovaMarket.
-- Grain inchangé : une offre observée un jour.
-- Les ventes sont d'abord agrégées par produit (1 ligne par produit) AVANT la jointure,
-- sinon chaque offre serait répétée autant de fois que le produit a de lignes vendues.
with ventes_par_produit as (
    select
        produit_id,
        sum(quantite)                                        as unites_vendues,
        round(sum(montant_cents)::numeric / sum(quantite))   as prix_vente_moyen_cents
    from {{ ref('stg_metier__lignes_vendues') }}
    group by produit_id
)

select
    o.offre_id,
    o.date_observation,
    o.fournisseur_id,
    o.produit_id,
    p.sku,
    p.produit_nom,
    p.categorie_nom,
    o.prix_cents,
    o.unites_disponibles,
    v.unites_vendues,
    v.prix_vente_moyen_cents,
    v.prix_vente_moyen_cents - o.prix_cents as marge_unitaire_cents
from {{ ref('stg_fournisseur__offres') }} as o
join {{ ref('stg_metier__produits') }}    as p on p.produit_id = o.produit_id
left join ventes_par_produit              as v on v.produit_id = o.produit_id
