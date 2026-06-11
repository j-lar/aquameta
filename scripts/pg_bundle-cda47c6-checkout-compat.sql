-- Compatibility shim for pg_bundle cda47c6 checkout helpers when bundle exports
-- store meta.row_id values as PostgreSQL composite text, JSON objects, or
-- JSON-object strings.
--
-- Load after pg_bundle itself has been loaded, because this replaces bundle.*
-- helper functions and depends on bundle.field_hash.

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION bundle._compat_make_row_id(_row_id jsonb)
RETURNS meta.row_id
LANGUAGE sql IMMUTABLE STRICT
AS $$
    SELECT meta.make_row_id(
        _row_id->>'schema_name',
        _row_id->>'relation_name',
        ARRAY(SELECT jsonb_array_elements_text(_row_id->'pk_column_names')),
        ARRAY(SELECT jsonb_array_elements_text(_row_id->'pk_values'))
    )
$$;

CREATE OR REPLACE FUNCTION bundle._compat_parse_row_id(_row_id text)
RETURNS meta.row_id
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
BEGIN
    IF left(ltrim(_row_id), 1) = '{' THEN
        RETURN bundle._compat_make_row_id(_row_id::jsonb);
    END IF;

    RETURN _row_id::meta.row_id;
END;
$$;

CREATE OR REPLACE FUNCTION bundle._compat_parse_row_id(_row_id jsonb)
RETURNS meta.row_id
LANGUAGE plpgsql IMMUTABLE STRICT
AS $$
BEGIN
    IF jsonb_typeof(_row_id) = 'object' THEN
        RETURN bundle._compat_make_row_id(_row_id);
    ELSIF jsonb_typeof(_row_id) = 'string' THEN
        RETURN bundle._compat_parse_row_id(_row_id #>> '{}');
    END IF;

    RETURN (_row_id::text)::meta.row_id;
END;
$$;

CREATE OR REPLACE FUNCTION bundle._get_commit_rows(
    _commit_id uuid,
    _relation_id_filter meta.relation_id DEFAULT NULL
)
RETURNS TABLE(_position integer, row_id meta.row_id)
LANGUAGE sql
AS $$
    SELECT parsed.position, parsed.row_id
    FROM (
        SELECT
            row_number() OVER (ORDER BY ord)::integer AS position,
            bundle._compat_parse_row_id(elem) AS row_id
        FROM bundle.commit c,
             LATERAL jsonb_array_elements(c.jsonb_rows) WITH ORDINALITY AS u(elem, ord)
        WHERE c.id = _commit_id
    ) parsed
    WHERE _relation_id_filter IS NULL
       OR meta.row_id_to_relation_id(parsed.row_id)::text = _relation_id_filter::text;
$$;

CREATE OR REPLACE FUNCTION bundle._get_commit_fields(_commit_id uuid)
RETURNS SETOF bundle.field_hash
LANGUAGE sql
AS $$
    SELECT
        meta.make_field_id(bundle._compat_parse_row_id(e.row_key), f.column_name),
        f.value_hash
    FROM bundle.commit c
    CROSS JOIN LATERAL jsonb_each(c.jsonb_fields) AS e(row_key, fields)
    CROSS JOIN LATERAL jsonb_each_text(e.fields) AS f(column_name, value_hash)
    WHERE c.id = _commit_id;
$$;

CREATE OR REPLACE FUNCTION bundle._checkout_row(row_id meta.row_id, fields jsonb, upsert boolean DEFAULT false)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    stmt text;
    unhashed_fields jsonb := '{}';
    field_key text;
    field_value text;
    unhashed_value text;
    parsed_value jsonb;
    target_schema text;
    target_table text;
    cols text;
    pk_columns text[];
    update_cols text;
    conflict_clause text := '';
    target_column_exists boolean;
    skip_defaulted_not_null boolean;
BEGIN
    target_schema := (row_id).schema_name;
    target_table := (row_id).relation_name;

    FOR field_key, field_value IN SELECT key, value FROM jsonb_each_text(fields) LOOP
        SELECT EXISTS (
            SELECT 1
            FROM pg_attribute a
            JOIN pg_class cls ON cls.oid = a.attrelid
            JOIN pg_namespace ns ON ns.oid = cls.relnamespace
            WHERE ns.nspname = target_schema
              AND cls.relname = target_table
              AND a.attname = field_key
              AND a.attnum > 0
              AND NOT a.attisdropped
        ) INTO target_column_exists;

        IF NOT target_column_exists THEN
            CONTINUE;
        END IF;

        unhashed_value := bundle.unhash(field_value);

        IF unhashed_value = 'null' THEN
            SELECT a.attnotnull AND d.adbin IS NOT NULL
            INTO skip_defaulted_not_null
            FROM pg_attribute a
            JOIN pg_class cls ON cls.oid = a.attrelid
            JOIN pg_namespace ns ON ns.oid = cls.relnamespace
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE ns.nspname = target_schema
              AND cls.relname = target_table
              AND a.attname = field_key
              AND a.attnum > 0
              AND NOT a.attisdropped;

            IF coalesce(skip_defaulted_not_null, false) THEN
                CONTINUE;
            END IF;
        END IF;

        BEGIN
            parsed_value := unhashed_value::jsonb;
        EXCEPTION WHEN others THEN
            parsed_value := to_jsonb(unhashed_value);
        END;

        unhashed_fields := unhashed_fields || jsonb_build_object(field_key, parsed_value);
    END LOOP;

    SELECT string_agg(quote_ident(key), ', ') INTO cols
    FROM jsonb_object_keys(unhashed_fields) AS key;

    IF cols IS NULL THEN
        RETURN;
    END IF;

    IF upsert THEN
        pk_columns := (row_id).pk_column_names;

        SELECT string_agg(format('%I = excluded.%I', col, col), ', ')
        INTO update_cols
        FROM jsonb_object_keys(unhashed_fields) col
        WHERE NOT (col = ANY(pk_columns));

        IF update_cols IS NULL THEN
            conflict_clause := format(
                ' on conflict (%s) do nothing',
                array_to_string(array(SELECT quote_ident(col) FROM unnest(pk_columns) col), ', ')
            );
        ELSE
            conflict_clause := format(
                ' on conflict (%s) do update set %s',
                array_to_string(array(SELECT quote_ident(col) FROM unnest(pk_columns) col), ', '),
                update_cols
            );
        END IF;
    END IF;

    stmt := format($sql$
        INSERT INTO %I.%I (%s)
        SELECT %s FROM jsonb_populate_record(NULL::%I.%I, %L)%s
    $sql$,
        target_schema, target_table, cols, cols,
        target_schema, target_table, unhashed_fields, conflict_clause
    );

    EXECUTE stmt;
EXCEPTION
    WHEN others THEN
        RAISE EXCEPTION '_checkout_row() failed for %.%: %',
            target_schema, target_table, SQLERRM;
END;
$$;
