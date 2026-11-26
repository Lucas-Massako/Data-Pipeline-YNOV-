-- Grain : un produit. Jointure 1-1 vers sa catégorie (category_id est une FK obligatoire).
select
    p.product_id      as produit_id,
    p.sku,
    p.product_name    as produit_nom,
    p.category_id     as categorie_id,
    c.category_name   as categorie_nom,
    p.first_listed_on as date_mise_en_vente
from {{ source('metier', 'products') }}   as p
join {{ source('metier', 'categories') }} as c on c.category_id = p.category_id
