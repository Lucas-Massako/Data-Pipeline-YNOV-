-- Aucun prix ou stock négatif dans le mart.
select produit_id, date_observation
from {{ ref('mart_offres_par_produit') }}
where meilleur_prix_cents < 0 or unites_disponibles < 0
