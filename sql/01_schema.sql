-- =====================================================================
-- NovaMarket S1 — M1/M2 : schéma (réception, rejets, métier)
-- Rejouable : supprime et recrée les deux schémas.
-- Exécution : docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U atelier -d novamarket < sql/01_schema.sql
-- =====================================================================
\set ON_ERROR_STOP 1
BEGIN;

DROP SCHEMA IF EXISTS metier CASCADE;
DROP SCHEMA IF EXISTS reception CASCADE;
CREATE SCHEMA reception;   -- copie fidèle des fichiers bruts (tout en texte)
CREATE SCHEMA metier;      -- données validées, typées et contraintes

-- ---------------------------------------------------------------------
-- 1. RÉCEPTION : tout en text, aucune contrainte -> aucune ligne perdue.
--    ligne_id = numéro d'ordre de lecture dans le fichier (1 = 1re ligne
--    de données), sert à tracer un rejet jusqu'à sa ligne source.
-- ---------------------------------------------------------------------
CREATE TABLE reception.customers (
    ligne_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   text,
    customer_name text,
    city          text
);

CREATE TABLE reception.orders (
    ligne_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id    text,
    customer_id text,
    ordered_on  text,
    status      text
);

CREATE TABLE reception.order_items (
    ligne_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_item_id    text,
    order_id         text,
    product_id       text,
    quantity         text,
    unit_price_cents text
);

-- NDJSON : un document JSON par ligne, stocké tel quel.
CREATE TABLE reception.payments (
    ligne_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    document jsonb NOT NULL
);

-- Journal des rejets : une ligne par ligne source écartée, avec sa cause.
CREATE TABLE reception.rejets (
    rejet_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source     text        NOT NULL,   -- fichier d'origine
    ligne_id   bigint      NOT NULL,   -- ligne dans la table de réception
    cle_source text,                   -- identifiant lu dans la source
    motif      text        NOT NULL,   -- cause du rejet
    contenu    jsonb       NOT NULL,   -- ligne brute complète
    rejete_le  timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 2. MÉTIER : types stricts, clés, contraintes.
--    Montants en centimes -> integer (pas de float, pas d'arrondi).
-- ---------------------------------------------------------------------
CREATE TABLE metier.customers (
    customer_id   integer PRIMARY KEY,
    customer_name text    NOT NULL,
    city          text    NOT NULL
);

CREATE TABLE metier.orders (
    order_id    integer PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES metier.customers (customer_id),
    ordered_on  date    NOT NULL,
    status      text    NOT NULL CHECK (status IN ('completed', 'pending', 'cancelled'))
);

CREATE TABLE metier.order_items (
    order_item_id    integer PRIMARY KEY,
    order_id         integer NOT NULL REFERENCES metier.orders (order_id),
    product_id       integer NOT NULL,           -- catalogue hors périmètre S1 : pas de FK
    quantity         integer NOT NULL CHECK (quantity > 0),
    unit_price_cents integer NOT NULL CHECK (unit_price_cents > 0)
);

CREATE TABLE metier.payments (
    payment_id   integer PRIMARY KEY,
    order_id     integer NOT NULL REFERENCES metier.orders (order_id),
    paid_on      date    NOT NULL,
    amount_cents integer NOT NULL CHECK (amount_cents > 0),
    status       text    NOT NULL CHECK (status IN ('captured', 'pending'))
);

-- Index sur les clés étrangères (jointures des indicateurs)
CREATE INDEX ON metier.orders (customer_id);
CREATE INDEX ON metier.order_items (order_id);
CREATE INDEX ON metier.payments (order_id);

COMMIT;
