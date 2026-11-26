-- Grain : une ligne d'article d'une commande completed (décision D1 de S1).
select
    i.order_item_id                    as ligne_id,
    i.order_id                         as commande_id,
    i.product_id                       as produit_id,
    i.quantity                         as quantite,
    i.unit_price_cents                 as prix_unitaire_cents,
    i.quantity * i.unit_price_cents    as montant_cents,
    o.ordered_on                       as date_commande
from {{ source('metier', 'order_items') }} as i
join {{ source('metier', 'orders') }}      as o on o.order_id = i.order_id
where o.status = 'completed'
