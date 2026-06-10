--
-- Backward compatibility patch for v0.4 bundle commit formats
--
-- pg_bundle v0.5 changed commit.jsonb_rows from composite text strings to JSON objects.
-- Old v0.4 bundles (e.g. org.aquameta.core.mimetypes) still use the composite text format.
-- These patches make _get_commit_rows and _get_commit_fields handle both formats.
--
-- Apply to any v0.5 installation that needs to checkout commits created in v0.4.
--

--
-- Helper: build a meta.field_id from a jsonb row_id representation
-- (needed because some v0.5 installs lack meta.make_field_id)
--
create or replace function bundle.make_field_id(_row_id jsonb, _column_name text)
returns meta.field_id as $$
    select meta.field_id(
        (_row_id->>'schema_name')::text,
        (_row_id->>'relation_name')::text,
        (select array_agg(value) from jsonb_array_elements_text(_row_id->'pk_column_names')),
        (select array_agg(value) from jsonb_array_elements_text(_row_id->'pk_values')),
        _column_name
    );
$$ language sql immutable;

--
-- Helper: build a meta.field_id from a typed meta.row_id
--
create or replace function bundle.make_field_id(_row_id meta.row_id, _column_name text)
returns meta.field_id as $$
    select meta.field_id(
        (_row_id).schema_name,
        (_row_id).relation_name,
        (_row_id).pk_column_names,
        (_row_id).pk_values,
        _column_name
    );
$$ language sql immutable;

--
-- _get_commit_rows: handle both old composite-text and new JSON-object row IDs
--
create or replace function bundle._get_commit_rows(
    _commit_id uuid,
    _relation_id_filter meta.relation_id default null
)
returns table(_position integer, row_id meta.row_id)
as $$
    select position, row_id
    from (
        select row_number() over (order by ord) as position,
               -- handle both old format (composite text) and new format (JSON object)
               case when elem like '{%' then elem::jsonb::meta.row_id
               else elem::meta.row_id end as row_id
        from bundle.commit c,
             lateral jsonb_array_elements_text(c.jsonb_rows) with ordinality as u(elem, ord)
        where c.id = _commit_id
    ) as subquery
    where (_relation_id_filter is null)
       or (meta.row_id_to_relation_id(row_id)::jsonb = _relation_id_filter::jsonb);
$$ language sql;

--
-- _get_commit_fields: handle both old composite-text and new JSON-object row IDs
--
create or replace function bundle._get_commit_fields(
    _commit_id uuid
    /*, _relation_id_filter meta.relation_id default null TODO? */
)
returns setof bundle.field_hash
as $$
    select
        bundle.make_field_id(
            case when e.key like '{%' then e.key::jsonb::meta.row_id
            else e.key::meta.row_id end,
            (jsonb_each_text(e.value)).key::text
        ),
        (jsonb_each_text(e.value)).value as val
    from
        bundle.commit,
        lateral jsonb_each(jsonb_fields) e
    where id=_commit_id;
$$ language sql;
