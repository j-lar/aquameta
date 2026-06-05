/*******************************************************************************
 * NAVIGATION
 * Agent navigation and search for Aquameta installations
 *
 * Provides two entry points:
 *   navigation.inventory(bundle_names text[] default null)
 *     -- enumerate every code-bearing surface as rows
 *   navigation.search(query text, bundle_names text[] default null)
 *     -- full-text search across DB-resident code (widgets, resources, functions)
 *
 * Both accept an optional bundle_names filter (NULL = all installed bundles).
 * Rows not tracked in any bundle are excluded (untracked = ephemeral/staging).
 *
 * Runs with caller's grants (no security definer).
 * If privileged discovery is needed, wrap with a security-definer variant.
 *
 * Copyright (c) 2026 - Aquameta - http://aquameta.org/
 ******************************************************************************/

create schema navigation;
comment on schema navigation is
    'Agent navigation: inventory and search across all DB-resident code surfaces. '
    'Scope with bundle_names[] param (NULL = all tracked). Caller grants apply.';


/*******************************************************************************
 * navigation.surface
 *
 * Per-bundle agent metadata declarations. Holds structured facts that
 * inventory() cannot derive: primacy (which surface is THE entry point),
 * purpose (what a bundle does), usage notes, and conventions.
 *
 * Bundle membership is determined by bundle tracking, not a column — derive
 * it via navigation._bundle_rows('navigation','surface'). Each bundle tracks
 * the surface rows describing itself; metadata travels with the bundle on
 * checkout.
 *
 * target_row points at the annotated DB object via meta.row_id. NULL means
 * the annotation applies to the bundle as a whole (kind='readme',
 * kind='convention').
 *
 * kind vocabulary:
 *   readme       — bundle-level purpose/description (target_row is null)
 *   entry_point  — the primary UI or API surface for this bundle
 *   convention   — a convention agents must know to work in this bundle
 *   api_note     — usage note for a specific function, resource, or widget
 ******************************************************************************/

create table navigation.surface (
    id          uuid        primary key default public.uuid_generate_v4(),
    kind        text        not null,
    name        text        not null,
    target_row  meta.row_id,
    description text        not null,
    created_at  timestamptz not null default now()
);

comment on table navigation.surface is
    'Per-bundle agent metadata: primacy, purpose, usage notes, conventions. '
    'Bundle membership via tracking, not a column. target_row=NULL means bundle-level.';
comment on column navigation.surface.kind is
    'readme | entry_point | convention | api_note';
comment on column navigation.surface.target_row is
    'meta.row_id of the annotated object; NULL for bundle-level annotations';


/*******************************************************************************
 * navigation.label_column
 *
 * Returns the best human-readable label column for a given relation.
 * Probes in preference order: name → title → label → description → first PK.
 *
 * Used by PGFS to build by-name virtual directories and _index files without
 * requiring any schema registration. Covers ~90% of relations with zero setup.
 *
 * Returns NULL if the relation does not exist in meta.column.
 ******************************************************************************/

create or replace function navigation.label_column(
    p_schema    text,
    p_relation  text
)
returns text
language sql stable as $$
    select coalesce(
        min(case when c.name = 'name'        then 'name'        end),
        min(case when c.name = 'title'       then 'title'       end),
        min(case when c.name = 'label'       then 'label'       end),
        min(case when c.name = 'description' then 'description' end),
        min(case when c.name = 'path'        then 'path'        end),
        min(case when c.primary_key          then c.name        end)
    )
    from meta.column c
    where c.schema_name   = p_schema
      and c.relation_name = p_relation
$$;

comment on function navigation.label_column(text, text) is
    'Returns the best label column for a relation: name > title > label > description > path > first PK. '
    'Used by PGFS by-name directories and _index files. No registration required.';


/*******************************************************************************
 * navigation._bundle_rows
 *
 * Internal helper: returns (bundle_name, pk) for all rows tracked in a given
 * schema+relation, across head commits of matching bundles.
 * bundle_names=NULL returns rows from all installed bundles.
 *
 * Handles both row_id formats used across bundle versions:
 *   Legacy text: (schema,relation,{pk_col},{pk_val})
 *   JSONB:       {"schema_name":"x","relation_name":"y","pk_column_names":["id"],"pk_values":["uuid"]}
 ******************************************************************************/

create or replace function navigation._bundle_rows(
    p_schema     text,
    p_relation   text,
    bundle_names text[] default null
)
returns table(bundle_name text, pk text)
language sql stable as $$
    -- legacy text format: (schema,relation,{pk_col},{pk_val})
    select
        r.name,
        (regexp_matches(
            row_text,
            '^\(' || p_schema || ',' || p_relation || ',\{[^}]+\},\{([^}]+)\}\)$'
        ))[1]
    from bundle.commit c
    join bundle.repository r
        on r.id = c.repository_id
       and r.head_commit_id = c.id
    cross join jsonb_array_elements_text(c.jsonb_rows) as row_text
    where row_text like '(' || p_schema || ',' || p_relation || ',%'
      and (bundle_names is null or r.name = any(bundle_names))

    union all

    -- JSONB format: {"schema_name":"x","relation_name":"y","pk_values":["uuid"]}
    select
        r.name,
        row_elem->'pk_values'->>0
    from bundle.commit c
    join bundle.repository r
        on r.id = c.repository_id
       and r.head_commit_id = c.id
    cross join jsonb_array_elements(c.jsonb_rows) as row_elem
    where row_elem->>'schema_name' = p_schema
      and row_elem->>'relation_name' = p_relation
      and (bundle_names is null or r.name = any(bundle_names))
$$;


/*******************************************************************************
 * navigation.inventory
 *
 * Returns every code-bearing surface as (bundle, kind, name, detail) rows.
 * Covers: bundles, schemas, tables, functions, widgets, endpoint resources,
 * and template routes.
 *
 * bundle_names=NULL returns surfaces from all installed bundles.
 * "kind" values: bundle, schema, table, function, widget, resource, template_route
 ******************************************************************************/

create or replace function navigation.inventory(
    bundle_names text[] default null
)
returns table (
    bundle  text,
    kind    text,
    name    text,
    detail  text
)
language sql stable as $$
    -- installed bundles
    select
        r.name,
        'bundle',
        r.name,
        coalesce(
            (select c.message
             from bundle.commit c
             where c.repository_id = r.id
             order by c.commit_time desc
             limit 1),
            '(no commits)'
        )
    from bundle.repository r
    where bundle_names is null or r.name = any(bundle_names)

    union all

    -- schemas (not bundle-scoped — always show installed schemas)
    select null, 'schema', s.name, null
    from meta.schema s
    where s.name not in (
        'pg_catalog','information_schema','pg_toast','pg_temp_1','pg_toast_temp_1'
    )

    union all

    -- tables
    select br.bundle_name, 'table', t.schema_name || '.' || t.name, null
    from meta.table t
    join navigation._bundle_rows('meta', 'table', bundle_names) br
        on br.pk = t.id::text

    union all

    -- functions
    select br.bundle_name, 'function', f.schema_name || '.' || f.name, f.return_type
    from meta.function f
    join navigation._bundle_rows('meta', 'function', bundle_names) br
        on br.pk = f.id::text

    union all

    -- widgets
    select br.bundle_name, 'widget', w.name, null
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br
        on br.pk = w.id::text

    union all

    -- endpoint resources
    select br.bundle_name, 'resource', res.path,
        (select m.mimetype from endpoint.mimetype m where m.id = res.mimetype_id)
    from endpoint.resource res
    join navigation._bundle_rows('endpoint', 'resource', bundle_names) br
        on br.pk = res.id::text

    union all

    -- template routes
    select br.bundle_name, 'template_route', tr.url_pattern, null
    from endpoint.template_route tr
    join navigation._bundle_rows('endpoint', 'template_route', bundle_names) br
        on br.pk = tr.id::text
$$;

comment on function navigation.inventory(text[]) is
    'Enumerate every code-bearing surface. bundle_names=NULL returns all tracked rows. '
    'Untracked (staging) rows are excluded. Schemas are always shown.';


/*******************************************************************************
 * navigation.search
 *
 * Search across all DB-resident code: widget JS/HTML/CSS, endpoint resource
 * content, and function definitions. Returns (surface, bundle, location, column_,
 * pk) so the caller can navigate directly to the matching row.
 *
 * This is the layer grep-over-files cannot replicate: dependencies between
 * widgets and DB objects exist only as strings in text columns.
 *
 * bundle_names=NULL searches all tracked bundles.
 ******************************************************************************/

create or replace function navigation.search(
    query        text,
    bundle_names text[] default null
)
returns table (
    surface  text,
    bundle   text,
    location text,
    column_  text,
    pk       text
)
language sql stable as $$
    -- widget pre_js
    select 'widget', br.bundle_name, w.name, 'pre_js', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.pre_js ilike '%' || query || '%'

    union all

    -- widget common_js
    select 'widget', br.bundle_name, w.name, 'common_js', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.common_js ilike '%' || query || '%'

    union all

    -- widget post_js
    select 'widget', br.bundle_name, w.name, 'post_js', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.post_js ilike '%' || query || '%'

    union all

    -- widget server_js
    select 'widget', br.bundle_name, w.name, 'server_js', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.server_js ilike '%' || query || '%'

    union all

    -- widget html
    select 'widget', br.bundle_name, w.name, 'html', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.html ilike '%' || query || '%'

    union all

    -- widget css
    select 'widget', br.bundle_name, w.name, 'css', w.id::text
    from widget.widget w
    join navigation._bundle_rows('widget', 'widget', bundle_names) br on br.pk = w.id::text
    where w.css ilike '%' || query || '%'

    union all

    -- endpoint resource content
    select 'resource', br.bundle_name, res.path, 'content', res.id::text
    from endpoint.resource res
    join navigation._bundle_rows('endpoint', 'resource', bundle_names) br on br.pk = res.id::text
    where res.content ilike '%' || query || '%'

    union all

    -- function definitions
    select 'function', br.bundle_name, f.schema_name || '.' || f.name, 'definition', f.id::text
    from meta.function f
    join navigation._bundle_rows('meta', 'function', bundle_names) br on br.pk = f.id::text
    where f.definition ilike '%' || query || '%'
$$;

comment on function navigation.search(text, text[]) is
    'Search across all DB-resident code (widget JS/HTML/CSS, resources, functions). '
    'Returns surface/bundle/location/column_/pk for direct row navigation. '
    'bundle_names=NULL searches all tracked bundles. '
    'This is the layer grep-over-files cannot replicate.';
