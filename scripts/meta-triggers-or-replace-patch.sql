-- meta-triggers-or-replace-patch.sql
--
-- Override patch for meta_triggers submodule functions that need CREATE OR REPLACE
-- semantics to survive fresh-install bundle checkout on a system where the extension
-- SQL already created the backing objects.
--
-- Background: meta.stmt_view_create and meta.stmt_function_create generate plain
-- "CREATE VIEW" / "CREATE FUNCTION" DDL. When checking out bundles onto a system
-- where the ai/companion extension SQL already ran (creating those views/functions),
-- the meta trigger fires on each row insert and executes the generated DDL — which
-- fails with "already exists". OR REPLACE prevents this.
--
-- Limitation: CREATE OR REPLACE VIEW cannot change existing column names/types;
-- CREATE OR REPLACE FUNCTION cannot change the return type. These fixes are safe
-- because the bundle definition matches the extension-created schema.
--
-- Load this file after meta_triggers SQL files in the install sequence.


CREATE OR REPLACE FUNCTION meta.stmt_view_create(schema_name text, view_name text, query text) RETURNS text AS $$
    SELECT 'create or replace view ' || quote_ident(schema_name) || '.' || quote_ident(view_name) || ' as ' || query;
$$ LANGUAGE sql;


CREATE OR REPLACE FUNCTION meta.stmt_function_create(
    schema_name text, function_name text, type_sig text[], parameters text[],
    return_type text, definition text, language text, returns_set boolean,
    volatility text, parallel text, security text
) RETURNS text AS $$
DECLARE
    stmt text;
BEGIN
    stmt := 'create or replace function ' || quote_ident(schema_name) || '.' || quote_ident(function_name);

    IF parameters IS NOT NULL THEN
        stmt := stmt || '(' || array_to_string(parameters, ',') || ') ';
    ELSE
        stmt := stmt || '(' || array_to_string(type_sig, ',') || ') ';
    END IF;

    stmt := stmt || 'returns ' || return_type || E' as $body$\n';
    stmt := stmt || definition || E'\n$body$ language ' || quote_ident(language);

    IF volatility IS NOT NULL AND volatility != 'volatile' THEN
        stmt := stmt || ' ' || volatility;
    END IF;

    IF parallel IS NOT NULL AND parallel != 'unsafe' THEN
        stmt := stmt || ' ' || parallel;
    END IF;

    IF security IS NOT NULL AND security != 'invoker' THEN
        stmt := stmt || ' security ' || security;
    END IF;

    stmt := stmt || ';';
    RETURN stmt;
END;
$$ LANGUAGE plpgsql;
