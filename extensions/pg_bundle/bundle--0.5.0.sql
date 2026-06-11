------------------------------------------------------------------------------
-- INIT
------------------------------------------------------------------------------
/*
\unset ECHO
\set QUIET 1
\pset format unaligned
\pset tuples_only true
\pset pager off
\set ON_ERROR_ROLLBACK 1
\set ON_ERROR_STOP true
*/

create extension if not exists hstore schema public;
-- NOTE: disabled for compatibility
-- create extension if not exists "pg_uuidv7" schema public;
create extension if not exists "uuid-ossp" schema public;
create extension if not exists pgcrypto schema public;

-- reset stats
-- NOTE: disabled for compatibility
-- create extension if not exists pg_stat_statements schema public;
-- select public.pg_stat_statements_reset();

-- meta is installed directly by run.sh, not as an extension



------------------------------------------------------------------------------
-- TYPES
-- All custom type definitions for the bundle module
------------------------------------------------------------------------------

--
-- Version Domain
-- Semantic versioning 2.0.0 with validation
--

create domain bundle.version as text
    check (
        value ~
        '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' -- x.y.z
        '(-([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?'              -- -prerelease
        '(\+([0-9A-Za-z-]+)(\.[0-9A-Za-z-]+)*)?$'            -- +build
    );


--
-- Repository & Commit Types
--

-- Field identifier with hash value
create type field_hash as ( field_id meta.field_id, value_hash text);

-- Row identifier with existence flag
create type row_exists as( row_id meta.row_id, exists boolean );

-- Commit ancestry information
create type _commit_ancestor as(
    commit_id uuid,
    position integer,
    commit_time timestamptz,
    message text,
    author_name text,
    author_email text
);

-- Schema relationship edge (for dependency tracking)
create type bundle.schema_edge as (from_relation_id meta.relation_id, to_relation_id meta.relation_id);


--
-- Stage Types
--

-- Field hash difference (for tracking changes)
create type field_hash_diff as (
    field_id meta.field_id,
    db_value_hash text,
    commit_value_hash text
);

-- Stage row with new row flag
create type stage_row as (row_id meta.row_id, new_row boolean);


--
-- Stash Types
--

-- Field value for stash storage
create type bundle.stash_field_value as (
    field_id meta.field_id,
    value text
);


--
-- Status Types
--

-- Row state enumeration
create type row_state as enum ('tracked', 'staged', 'in_commit');
------------------------------------------------------------------------------
-- UTIL / MISC FUNCTIONS
-- General purpose utils that probably belong somewhere else.
------------------------------------------------------------------------------

--
-- random_string()
--

CREATE OR REPLACE FUNCTION random_string( int ) RETURNS TEXT as $$
    SELECT substr(md5(random()::text), 0, $1+1);
$$ language sql;

create or replace function jsonb_merge_recurse(orig jsonb, delta jsonb)
returns jsonb language sql as $$
    select
        jsonb_object_agg(
            coalesce(keyOrig, keyDelta),
            case
                when valOrig isnull then valDelta
                when valDelta isnull then valOrig
                when (jsonb_typeof(valOrig) <> 'object' or jsonb_typeof(valDelta) <> 'object') then valDelta
                else bundle.jsonb_merge_recurse(valOrig, valDelta)
            end
        )
    from jsonb_each(orig) e1(keyOrig, valOrig)
    full join jsonb_each(delta) e2(keyDelta, valDelta) on keyOrig = keyDelta
$$;


-- jsonb_merge
--

-- https://www.tyil.nl/post/2020/12/15/merging-json-in-postgresql/
CREATE OR REPLACE FUNCTION jsonb_merge( original jsonb, delta jsonb ) RETURNS jsonb AS $$
    DECLARE result jsonb;
    BEGIN
    SELECT
        json_object_agg(
            COALESCE(original_key, delta_key),
            CASE
                WHEN original_value IS NULL THEN delta_value
                WHEN delta_value IS NULL THEN original_value
                WHEN (jsonb_typeof(original_value) <> 'object' OR jsonb_typeof(delta_value) <> 'object') THEN delta_value
                ELSE bundle.jsonb_merge(original_value, delta_value)
            END
        )
        INTO result
        FROM jsonb_each(original) e1(original_key, original_value)
        FULL JOIN jsonb_each(delta) e2(delta_key, delta_value) ON original_key = delta_key;
    RETURN result;
END
$$ LANGUAGE plpgsql;


--
-- clock_diff()
--

create or replace function clock_diff( start_time timestamp ) returns text as $$
    select round(extract(epoch from (clock_timestamp() - start_time))::numeric, 3) as seconds;
$$ language sql;


--
-- array_reverse()
--

-- https://wiki.postgresql.org/wiki/Array_reverse
create or replace function array_reverse( anyarray ) returns anyarray as $$
select array(
    select $1[i]
        from generate_subscripts($1,1) as s(i)
            order by i desc
            );
$$ language 'sql' strict immutable;


create or replace function exec(statements text[]) returns setof record as $$
   declare
       statement text;
   begin
       foreach statement in array statements loop
           raise debug 'EXEC statement: %', statement;
           return query execute statement;
       end loop;
    end;
$$ language plpgsql volatile returns null on null input;



--
-- row_to_jsonb_text()
--

-- TODO: This is the main row serializer.  Right now it's just handing off to
-- to_jsonb(), but to_jsonb() converts arrays, composite types and numbers to
-- non-text values.  we need a function that takes a record and does to_jsonb
-- except produces a flat object with all text values instead.

create or replace function row_to_jsonb_text( input_record anyelement )
returns jsonb as $$
    select to_jsonb(input_record);
    /*
    from (
        select key, value
        from jsonb_each_text(to_jsonb(input_record))
    ) subquery;
    */
$$
language sql stable;
------------------------------------------------------------------------------
-- HASH / UNHASH functions
------------------------------------------------------------------------------

--
-- blob
--

create table blob (
    hash text primary key not null,
    value text
);
create index blob_hash_hash_index on blob using hash (hash);

-- special case for null
insert into blob ( hash, value ) values (
    '\xc0178022ef029933301a5585abee372c28ad47d08e3b5b6b748ace8e5263d2c9',
    null
);

create function create_blob( val text ) returns boolean as $$
declare
    _hash text;
begin
    _hash := bundle.hash(val);

    if val is null then
        return false;
    end if;

    if exists (select 1 from bundle.blob b where b.hash = _hash) then
        return false;
    end if;

    insert into bundle.blob (hash, value) values (_hash, val);
    return true;
end;
$$ language plpgsql;


/*
create or replace function _blob_hash_gen_trigger() returns trigger as $$
    begin
        if NEW.value is NULL then
            NEW.hash = '\xc0178022ef029933301a5585abee372c28ad47d08e3b5b6b748ace8e5263d2c9'::bytea;
            return NEW;
        end if;

        NEW.hash = bundle.hash(NEW.value);
        if exists (select 1 from bundle.blob b where b.hash = NEW.hash) then
            return NULL;
        end if;

        return NEW;
    end;
$$ language plpgsql;

create trigger blob_hash_update
    before insert or update on blob
    for each row execute procedure _blob_hash_gen_trigger();
*/


/*
Get hash of a text value.
If the value is longer than the length of a hash (32 chars) then just store the
value.  Otherwise store the sha256 hash of the value.
Maybe just ditch this stupid optimization.
*/

create or replace function hash( value text ) returns text as $$
begin
/*
    if length(value) < 32 then -- length(public.digest('foo','sha256')) then
        return value;
    end if;
*/
    if value is null then
        return '\xc0178022ef029933301a5585abee372c28ad47d08e3b5b6b748ace8e5263d2c9';
    end if;

    return public.digest(value, 'sha256');
end;
$$ language plpgsql;

-- constraint on bundle.blob to verify hash matches hash(value)
alter table blob add constraint blob_hash_matches_value check (hash = bundle.hash(value));


-- Lookup the text value corresponding to supplied hash, in the blob table.
create or replace function unhash( _hash text ) returns text as $$
declare
    val text;
begin
    /*
    if length(_hash) < 32 then -- length(public.digest('foo','sha256')) then
        return _hash;
    end if;
    */

    if _hash is null then
        return '\xc0178022ef029933301a5585abee372c28ad47d08e3b5b6b748ace8e5263d2c9';
    end if;

    if not exists (select 1 from bundle.blob b where b.hash = _hash) then
        raise exception 'unhash(): hash % has no blob.', _hash;
    end if;

    select value into val from bundle.blob where hash = _hash;
    return val;
end;
$$ language plpgsql;


/*
build a jsonb object from record that contains the record's keys as columns and
a hash of the records value as the key's value.
*/

create or replace function row_to_jsonb_hash_obj(
    rec record,
    create_blob boolean default false, -- should the blob be created (if necessary) in the blob table?
    columns text[] default null -- the columns in this record (optimization so we can skip pg_catalog lookup per-row)
) returns jsonb as $$
declare
    hash_obj jsonb := '{}';
    col text;
    val text;
begin
    -- TODO: only look up row's column names, if not supplied
    if columns is null then
        select
            array_agg(
                a.attname
                -- format_type(a.atttypid, a.atttypmod) as data_type,
                -- a.attnum as "position"
                order by a.attnum
            )
            from pg_attribute a
            where a.attrelid = (
                select typrelid from pg_type where oid = pg_typeof(rec)::oid
            )
            and a.attnum > 0
            and not a.attisdropped
        into columns;
    end if;

    -- raise notice 'columns: %', columns;

    -- create the object
    foreach col in array columns loop
        execute format('select to_jsonb(($1).%I)::text', col)
        into val
        using rec;

        hash_obj := hash_obj || jsonb_build_object(col, bundle.hash(val));

        -- create the blob?
        if create_blob then
            perform bundle.create_blob(val);
        end if;
    end loop;

    return hash_obj;
end;
$$ language plpgsql;

create or replace function _get_rowset_relations(rowset jsonb) returns meta.relation_id[] as $$
    select array_agg(distinct relation_id) from (
        select meta.row_id_to_relation_id(x::jsonb) as relation_id from jsonb_array_elements(rowset) el(x)
    ) y;
$$ language sql;
------------------------------------------------------------------------------
-- CORE
-- Core repository and commit tables and functions
------------------------------------------------------------------------------

--
-- commit
--

create table commit (
    id uuid not null default public.uuid_generate_v4() primary key,
    repository_id uuid not null, -- will add FK constraint after repository table is created
    parent_id uuid references commit(id), --null means first commit
    merge_parent_id uuid references commit(id),

    -- rows jsonb array. values are row_id::text
    jsonb_rows jsonb not null default '[]' check (jsonb_typeof(jsonb_rows) = 'array'),
    -- fields jsonb obj.  key is row_id, value is "column": "value hash" map
    jsonb_fields jsonb not null default '{}' check (jsonb_typeof(jsonb_fields) = 'object'),

    author_name text not null default '',
    author_email text not null default '',
    message text not null default '',
    commit_time timestamptz not null default now(),

    -- semver release tag (nullable - most commits aren't releases)
    version bundle.version
);
create index commit_jsonb_rows_idx on bundle.commit using gin (jsonb_rows);
create index commit_jsonb_fields_idx on bundle.commit using gin (jsonb_fields);
create index commit_repository_id_idx on bundle.commit (repository_id);
create index commit_parent_id_idx on bundle.commit (parent_id);
-- unique version per repo, nulls allowed
create unique index commit_repository_version_idx on bundle.commit (repository_id, version) where version is not null;

-- TODO: check constraint for only one null parent_id per repo
-- TODO: i am not my own grandpa


--
-- repository
--

create table repository (
    id uuid not null default public.uuid_generate_v4() primary key,
    name text not null unique check(name != ''),
    head_commit_id uuid unique references commit(id) on delete set null deferrable initially deferred,
    checkout_commit_id uuid unique references commit(id) on delete set null deferrable initially deferred,

    tracked_rows_added     jsonb not null default '[]' check (jsonb_typeof(tracked_rows_added) = 'array'),

    stage_rows_to_add      jsonb not null default '[]' check (jsonb_typeof(stage_rows_to_add) = 'array'),
    stage_rows_to_remove   jsonb not null default '[]' check (jsonb_typeof(stage_rows_to_remove) = 'array'),
    stage_fields_to_change jsonb not null default '[]' check (jsonb_typeof(stage_fields_to_change) = 'array') -- {} ?
);
-- Add foreign key constraint on commit.repository_id now that repository table exists
alter table bundle.commit add constraint commit_repository_id_fkey foreign key (repository_id) references bundle.repository(id) on delete cascade;

-- Index the jsonbs
create index repository_tracked_rows_added_idx on bundle.repository using gin (tracked_rows_added);
create index repository_stage_rows_to_add_idx on bundle.repository using gin (stage_rows_to_add);
create index repository_stage_rows_to_remove_idx on bundle.repository using gin (stage_rows_to_remove);
create index repository_stage_fields_to_change_idx on bundle.repository using gin (stage_fields_to_change);

-- TODO: stage_commit can't be checkout_commit or head_commit

-- circular fk
-- Repository_id column already added to commit table, constraint added above



/*
--
-- migrations
--

create table commit_migration (
    id uuid not null default public.uuid_generate_v4() primary key,
    commit_id uuid not null references commit(id),
    up_code text,
    down_code text, -- can we auto-generate a lot of this?
    before_checkout boolean,
    ordinal_position integer
);
*/


--
-- repository_dependency
--
-- Repository-level dependency requirements (like package.json)
-- Specifies what versions a repository needs to function
-- Mutable: changes when requirements change
--

create table repository_dependency (
    id uuid not null default public.uuid_generate_v4() primary key,
    commit_id uuid not null references bundle.commit(id) on delete cascade,
    depends_on_repository_id uuid not null references bundle.repository(id) on delete cascade,
    version_range text not null check(version_range != '')
);


--
-- commit_dependency
--
-- Commit-level dependency snapshot (like package-lock.json)
-- Records exact versions that were checked out when commit was made
-- Immutable: never changes once committed
--

create table commit_dependency (
    id uuid not null default public.uuid_generate_v4() primary key,
    commit_id uuid not null references bundle.commit(id) on delete cascade,
    depends_on_commit_id uuid not null references bundle.commit(id) on delete cascade
);


-------------------------------
-- Name/id functions
-------------------------------

--
-- repository_id()
--

create or replace function repository_id( repository_name text ) returns uuid as $$
    select id from bundle.repository where name=repository_name;
$$ stable language sql;


--
-- repository_name()
--

create or replace function _repository_name( repository_id uuid ) returns text as $$
    select name from bundle.repository where id=repository_id;
$$ stable language sql;


--
-- head_commit_id()
--

create or replace function _head_commit_id( repository_id uuid ) returns uuid as $$
    select head_commit_id from bundle.repository where id=repository_id;
$$ stable language sql;

create or replace function head_commit_id( repository_name text ) returns uuid as $$
    select head_commit_id from bundle.repository where name=repository_name;
$$ stable language sql;


--
-- checkout_commit_id()
--

create or replace function _checkout_commit_id( repository_id uuid ) returns uuid as $$
    select checkout_commit_id from bundle.repository where id=repository_id;
$$ stable language sql;

create or replace function checkout_commit_id( repository_name text ) returns uuid as $$
    select checkout_commit_id from bundle.repository where name=repository_name;
$$ stable language sql;


--
-- resolve_version()
--
-- Resolve a version spec to a commit_id.
-- Specs: live, head, head~N, UUID, or semver (1.0.0)
--

create or replace function resolve_version(
    _repository_name text,
    _version_spec text
) returns uuid as $$
declare
    _repo_id uuid;
    _commit_id uuid;
    _n int;
begin
    -- get repository
    select id, head_commit_id into _repo_id, _commit_id
    from bundle.repository
    where name = _repository_name;

    if _repo_id is null then
        raise exception 'repository not found: %', _repository_name;
    end if;

    -- live: return null (caller uses live DB, not time-travel)
    if _version_spec = 'live' then
        return null;
    end if;

    -- head: return head_commit_id
    if _version_spec = 'head' then
        return _commit_id;
    end if;

    -- head~N: walk back N commits
    if _version_spec ~ '^head~[0-9]+$' then
        _n := substring(_version_spec from 6)::int;
        for i in 1.._n loop
            select parent_id into _commit_id
            from bundle.commit
            where id = _commit_id;

            if _commit_id is null then
                return null; -- ran out of history
            end if;
        end loop;
        return _commit_id;
    end if;

    -- UUID: return as-is if valid commit
    if _version_spec ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        select id into _commit_id
        from bundle.commit
        where id = _version_spec::uuid
          and repository_id = _repo_id;
        return _commit_id;
    end if;

    -- semver: lookup by version column
    select id into _commit_id
    from bundle.commit
    where repository_id = _repo_id
      and version = _version_spec::bundle.version;

    return _commit_id;
end;
$$ language plpgsql stable;


-------------------------------
-- operation functions
-------------------------------

--
-- create_repository()
--

create or replace function create_repository( repository_name text ) returns uuid as $$
declare
    _repository_id uuid;
--     _stage_commit_id uuid;
begin
    raise notice 'Create repository %', repository_name;
    if repository_name = '' then
        raise exception 'Repository name cannot be empty string.';
    end if;

    if repository_name is null then
        raise exception 'Repository name cannot be null.';
    end if;

    -- create repository
    insert into bundle.repository (name) values (repository_name) returning id into _repository_id;

    return _repository_id;
exception
    when unique_violation then
        raise exception 'Repository with name % already exists.', repository_name;
    when others then raise;
end
$$ language plpgsql;


--
-- delete_repository()
--

create or replace function _delete_repository( repository_id uuid ) returns void as $$
    begin
        if not bundle._repository_exists(repository_id) then
            raise exception 'Repository with id % does not exist.', repository_id;
        end if;

        delete from bundle.repository where id = repository_id;
    end;
$$ language plpgsql;

create or replace function delete_repository( repository_name text ) returns void as $$
    begin
    raise notice 'Delete repository %', repository_name;
        if not bundle.repository_exists(repository_name) then
            raise exception 'Repository with name % does not exist.', repository_name;
        end if;

        perform bundle._delete_repository(bundle.repository_id(repository_name));

    end;
$$ language plpgsql;


--
-- garbage_collect()
--

/*
create or replace function garbage_collect() returns setof text as $$
    delete from bundle.blob
    using (
        select b.hash as bad_hash from bundle.blob b
            left join GONE: bundle.commit_field_changed cfc on cfc.value_hash = b.hash
        where  cfc.value_hash is null
    )
    where hash = bad_hash
    returning bad_hash
$$ language sql;
*/

-------------------------------
-- info functions
-------------------------------

--
-- repository_exists()
--

create or replace function repository_exists( _name text ) returns boolean as $$
    select exists (select 1 from bundle.repository where name = _name);
$$ language sql;

create or replace function _repository_exists( repository_id uuid ) returns boolean as $$
    select exists (select 1 from bundle.repository where id = repository_id);
$$ language sql;


--
-- repository_has_commits()
--

create or replace function _repository_has_commits( _repository_id uuid ) returns boolean as $$
    select exists (select 1 from bundle.commit where repository_id = _repository_id);
$$ language sql;


--
-- repository_has_staged_changes()
-- Returns true if there are any staged changes (rows to add/remove, fields to change)
--

create or replace function _repository_has_staged_changes( _repository_id uuid ) returns boolean as $$
    select
        jsonb_array_length(stage_rows_to_add) > 0 or
        jsonb_array_length(stage_rows_to_remove) > 0 or
        jsonb_array_length(stage_fields_to_change) > 0
    from bundle.repository
    where id = _repository_id;
$$ language sql;


--
-- repository_has_offstage_changes()
-- Returns true if there are any unstaged changes in the working database
--

create or replace function _repository_has_offstage_changes( _repository_id uuid ) returns boolean as $$
    declare
        is_checked_out boolean;
    begin
        -- if it isn't checked out, it doesn't have offstage changes
        select (checkout_commit_id is not null) from bundle.repository where id=_repository_id
        into is_checked_out;

        if not is_checked_out then return false; end if;

        -- Check for offstage changes using the existing offstage functions
        return exists (
            select 1 from bundle._get_offstage_deleted_rows(_repository_id)
            union all
            select 1 from bundle._get_offstage_updated_fields(_repository_id) limit 1
        );
    end;
$$ language plpgsql;


--
-- repository_has_working_changes()
-- Returns true if there are any changes in the working state (staged OR offstage)
-- This is the renamed version of the old _repository_has_uncommitted_changes
--

create or replace function _repository_has_working_changes( _repository_id uuid ) returns boolean as $$
    declare
        is_checked_out boolean;
        has_staged_changes boolean;
        has_tracked_changes boolean;
    begin
        -- if it isn't checked out, it doesn't have working changes
        select (checkout_commit_id is not null) from bundle.repository where id=_repository_id
        into is_checked_out;

        if not is_checked_out then return false; end if;

        -- Check for staged changes
        select bundle._repository_has_staged_changes(_repository_id) into has_staged_changes;
        if has_staged_changes then return true; end if;

        -- Check for offstage changes
        return bundle._repository_has_offstage_changes(_repository_id);
    end;
$$ language plpgsql;


--
-- repository_is_clean()
-- Returns true if the repository has no staged or offstage changes
--

create or replace function _repository_is_clean( _repository_id uuid ) returns boolean as $$
    select not bundle._repository_has_working_changes(_repository_id);
$$ language sql;


--
-- DEPRECATED: repository_has_uncommitted_changes()
-- Use _repository_has_working_changes() instead
--

create or replace function _repository_has_uncommitted_changes( _repository_id uuid ) returns boolean as $$
    -- Deprecated: This function name is ambiguous. Use _repository_has_working_changes() instead.
    select bundle._repository_has_working_changes(_repository_id);
$$ language sql;


--
-- checkout_would_conflict()
-- Returns true if checking out the target commit would conflict with working changes
-- A conflict occurs when checkout would modify the same rows/fields that have working changes
--

create or replace function _checkout_would_conflict(_target_commit_id uuid)
returns boolean as $$
declare
    _repository_id uuid;
    has_conflicts boolean;
begin
    -- Get repository from target commit
    select repository_id from bundle.commit where id = _target_commit_id into _repository_id;

    if _repository_id is null then
        raise exception 'Commit % does not exist', _target_commit_id;
    end if;

    -- A conflict occurs when:
    -- 1. Checkout would change a row/field (difference between target commit and current DB)
    -- 2. AND we have working changes to that same row/field (staged or offstage)

    -- Check field conflicts:
    -- Fields that differ between target commit and DB AND have working changes
    with checkout_field_changes as (
        -- Fields where DB value differs from target commit value
        select coalesce(db.field_id, commit.field_id) as field_id
        from bundle._get_db_commit_fields(_target_commit_id) db
        full outer join bundle._get_commit_fields(_target_commit_id) commit
            on db.field_id = commit.field_id
        where db.value_hash is distinct from commit.value_hash
    ),
    working_field_changes as (
        -- Staged field changes
        select jsonb_array_elements(stage_fields_to_change)::meta.field_id as field_id
        from bundle.repository where id = _repository_id
        union
        -- Offstage field changes
        select field_id from bundle._get_offstage_updated_fields(_repository_id)
    )
    select exists (
        select 1
        from checkout_field_changes cfc
        join working_field_changes wfc using (field_id)
    ) into has_conflicts;

    if has_conflicts then
        return true;
    end if;

    -- Check row conflicts:
    -- Rows that would be added/deleted by checkout AND have working changes
    with checkout_row_changes as (
        -- Rows that exist differently between DB and target commit
        select coalesce(dbr.row_id, cr.row_id) as row_id
        from bundle._get_db_commit_rows(_target_commit_id) dbr
        full outer join bundle._get_commit_rows(_target_commit_id) cr
            on dbr.row_id = cr.row_id
        where dbr.row_id is null     -- In commit but not in DB (would be added)
           or cr.row_id is null       -- In DB but not in commit (would be deleted)
           or dbr.exists = false      -- Tracked but missing from DB
    ),
    working_row_changes as (
        -- Staged row additions
        select jsonb_array_elements(stage_rows_to_add)::meta.row_id as row_id
        from bundle.repository where id = _repository_id
        union
        -- Staged row removals
        select jsonb_array_elements(stage_rows_to_remove)::meta.row_id as row_id
        from bundle.repository where id = _repository_id
        union
        -- Offstage deleted rows
        select row_id from bundle._get_offstage_deleted_rows(_repository_id)
        union
        -- Newly tracked rows (not yet staged)
        select jsonb_array_elements(tracked_rows_added)::meta.row_id as row_id
        from bundle.repository where id = _repository_id
    )
    select exists (
        select 1
        from checkout_row_changes crc
        join working_row_changes wrc using (row_id)
    ) into has_conflicts;

    return has_conflicts;
end;
$$ language plpgsql;


--
-- checkout_is_safe()
-- Returns true if checkout can proceed without conflicts
--

create or replace function _checkout_is_safe(_target_commit_id uuid)
returns boolean as $$
    select not bundle._checkout_would_conflict(_target_commit_id);
$$ language sql;


--
-- commit_exists()
--

create or replace function _commit_exists(commit_id uuid) returns boolean as $$
    select exists (select 1 from bundle.commit where id=commit_id);
$$ language sql;


--
-- get_commit_rows()
--

create or replace function _get_commit_rows( _commit_id uuid, _relation_id_filter meta.relation_id default null )
returns table(_position integer, row_id meta.row_id)
as $$
    select position, row_id
    from (
        select row_number() over (order by ord) as position, elem::meta.row_id as row_id -- id as commit_id, jsonb_array_elements(jsonb_rows)::meta.row_id as row_id
        from bundle.commit c, lateral jsonb_array_elements(c.jsonb_rows) with ordinality as u(elem, ord)
        where c.id = _commit_id
    ) as subquery
    where (_relation_id_filter is null) or (meta.row_id_to_relation_id(row_id)::jsonb = _relation_id_filter::jsonb);
    ;
$$ language sql;

--
-- get_head_commit_rows()
--

create or replace function _get_head_commit_rows( _repository_id uuid, _relation_id_filter meta.relation_id default null )
 returns table(_position integer, row_id meta.row_id) as $$
    select * from bundle._get_commit_rows(bundle._head_commit_id(_repository_id), _relation_id_filter);
$$ language sql;

create or replace function get_head_commit_rows( repository_name text, _relation_id_filter meta.relation_id default null )
 returns table(_position integer, row_id meta.row_id) as $$
    select *
    from bundle._get_commit_rows(
        bundle._head_commit_id(bundle.repository_id(repository_name)),
        _relation_id_filter
    );
$$ language sql;


--
-- get_commit_fields()
--
-- returns all fields and their value hashes
-- NOTE: field_hash type is defined in types.sql

create or replace function _get_commit_fields(_commit_id uuid /*, _relation_id_filter meta.relation_id default null TODO? */)
returns setof field_hash as $$
    select
        meta.make_field_id(e.key::jsonb, (jsonb_each_text(e.value)).key::text),
        (jsonb_each_text(e.value)).value as val
    from
        bundle.commit,
        lateral jsonb_each(jsonb_fields) e
    where id=_commit_id;
$$ language sql;


--
-- get_head_commit_fields()
--
create or replace function _get_head_commit_fields( _repository_id uuid ) returns setof field_hash as $$
    select * from bundle._get_commit_fields(bundle._head_commit_id(_repository_id));
$$ language sql;


--
-- get_commit_jsonb_rows()
--

create or replace function _get_commit_jsonb_rows( _commit_id uuid ) returns jsonb as $$
    select jsonb_rows from bundle.commit where id = _commit_id;
$$ language sql;


-- get_commit_jsonb_fields()
--

create or replace function _get_commit_jsonb_fields( _commit_id uuid ) returns jsonb as $$
    select jsonb_fields from bundle.commit where id = _commit_id;
$$ language sql;


--
-- get_commit_row_count_by_relation( _commit_id uuid, relation_id uuid )
-- used in summary

create or replace function _get_commit_row_count_by_relation( _commit_id uuid )
returns table( relation_id meta.relation_id, row_count integer ) as $$
    select meta.row_id_to_relation_id(row_id) as relation_id, count(*) as row_count
    from bundle._get_commit_rows(_commit_id)
    group by meta.row_id_to_relation_id(row_id)
$$ language sql;


--
-- get_repository_by_row()
--
-- Given a row_id, returns the repository(s) it belongs to.

create or replace function get_repository_by_row(
    _row_id meta.row_id
) returns table (
    repository_id uuid,
    repository_name text
) as $$
    -- committed rows (in head commit)
    select r.id, r.name
    from bundle.repository r
    join bundle.commit c on c.id = r.head_commit_id
    where c.jsonb_rows @> jsonb_build_array(_row_id)

    union

    -- tracked but not yet committed
    select r.id, r.name
    from bundle.repository r
    where r.tracked_rows_added @> jsonb_build_array(_row_id)
$$ language sql stable;
------------------------------------------------------------------------------
-- TRACKABLE / IGNORE
------------------------------------------------------------------------------

--
-- trackable_nontable_relation
--

/* By default, only rows in *tables* are included in untracked rows, rows in
 * views and other non-table relations are not.  However, there are times when
 * one might wish to version control views, foreign tables, or other types of
 * non-table relations.  When their relation_id is added to this table, their
 * contents are included in untracked_rows, and can be version-controlled.
 */

create table trackable_nontable_relation(
    id uuid not null default public.uuid_generate_v4() primary key,
    relation_id meta.relation_id not null unique,
    pk_column_names text[] not null
);

--
-- [un]track_nontable_relation()
--

create or replace function _track_nontable_relation(_relation_id meta.relation_id, _pk_column_names text[]) returns void as $$
    insert into bundle.trackable_nontable_relation (relation_id, pk_column_names) values (_relation_id, _pk_column_names);
$$ language sql;

create or replace function _untrack_nontable_relation(_relation_id meta.relation_id) returns void as $$
    delete from bundle.trackable_nontable_relation where _relation_id = relation_id;
$$ language sql;


--
-- ignore rules
--

-- schema
create table ignored_schema (
    id uuid not null default public.uuid_generate_v4() primary key,
    schema_id meta.schema_id not null
);

-- table
create table ignored_table (
    id uuid not null default public.uuid_generate_v4() primary key,
    relation_id meta.relation_id not null
);

-- row
create table ignored_row (
    id uuid not null default public.uuid_generate_v4() primary key,
    row_id meta.row_id
);

-- column
create table ignored_column (
    id uuid not null default public.uuid_generate_v4() primary key,
    column_id meta.column_id not null
);


--
-- ignore_*() functions
--

-- schema
create or replace function ignore_schema( _schema_id meta.schema_id ) returns void as $$
    insert into bundle.ignored_schema(schema_id) values (_schema_id);
$$ language sql;

create or replace function unignore_schema( _schema_id meta.schema_id ) returns void as $$
    delete from bundle.ignored_schema where schema_id = _schema_id;
$$ language sql;


-- table
create or replace function ignore_table( _relation_id meta.relation_id ) returns void as $$
    insert into bundle.ignored_table(relation_id) values (_relation_id);
$$ language sql;

create or replace function unignore_table( _relation_id meta.relation_id ) returns void as $$
    delete from bundle.ignored_table where relation_id = _relation_id;
$$ language sql;


-- row
create or replace function ignore_row( _row_id meta.row_id ) returns void as $$
    insert into bundle.ignored_row(row_id) values (_row_id);
$$ language sql;

create or replace function unignore_row( _row_id meta.row_id ) returns void as $$
    delete from bundle.ignored_row where row_id = _row_id;
$$ language sql;


-- column
create or replace function ignore_column( _column_id meta.column_id ) returns void as $$
    insert into bundle.ignored_column(column_id) values (_column_id);
$$ language sql;

create or replace function unignore_column( _column_id meta.column_id ) returns void as $$
    delete from bundle.ignored_column where column_id = _column_id;
$$ language sql;


--
-- tracked query
--

create table tracked_query(
    id uuid not null default public.uuid_generate_v4() primary key,
    repository_id uuid not null references repository(id),
    query text,
    pk_column_names text[] not null
);


--
-- trackable relation
--

create or replace view trackable_relation as
    select relation_id, primary_key_column_names as pk_column_names
    from (
        -- every table that has a primary key/keys
        select
            t.id as relation_id,
            array_agg(c.name order by c.position) as primary_key_column_names
        from meta.table t
            join meta.column c on c.schema_name = t.schema_name and c.relation_name = t.name
            where c.primary_key is true
        group by t.id

        -- ...plus every trackable_nontable_relation
        union

        select
            relation_id,
            pk_column_names
        from bundle.trackable_nontable_relation
    ) r

    -- ...that is not ignored

    where relation_id not in (
        select relation_id from bundle.ignored_table
    )

    -- ...and is not in an ignored schema

        and meta.relation_id_to_schema_id(relation_id) not in (
            select schema_id from bundle.ignored_schema
        )
    ;


--
-- not_ignored_row_stmt
--

create or replace view not_ignored_row_stmt as
select *, 'select meta.make_row_id(' ||
        quote_literal((r.relation_id).schema_name) || ', ' ||
        quote_literal((r.relation_id).name) || ', ' ||
        quote_literal(r.pk_column_names) || '::text[], ' ||
        'array[' ||
            meta._pk_stmt(r.pk_column_names, null, '%1$I::text', ',') ||
        ']' ||
    ') as row_id from ' ||
    quote_ident((r.relation_id).schema_name) || '.' || quote_ident((r.relation_id).name) ||

    -- special case meta rows so that ignored_* cascades down to all objects in its scope:
    -- exclude rows from meta that are in "normal" tables that are ignored
    case
        -- schemas
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name = 'schema' then
           ' where id not in (select schema_id from bundle.ignored_schema) '
        -- relations
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name in ('table', 'view', 'relation') then
           ' where id not in (select relation_id from bundle.ignored_table) and meta.make_schema_id(schema_name) not in (select schema_id from bundle.ignored_schema)'
        -- functions
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name = 'function' then
           ' where meta.make_schema_id(schema_name) not in (select schema_id from bundle.ignored_schema)'
        -- columns
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name = 'column' then
           ' where id not in (select column_id from bundle.ignored_column) and meta.column_id_to_relation_id(id) not in (select relation_id from bundle.ignored_table) and meta.column_id_to_schema_id(id) not in (select schema_id from bundle.ignored_schema)'

        -- objects that exist in schema scope

        -- operator
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name in ('operator') then
           ' where meta.make_schema_id(schema_name) not in (select schema_id from bundle.ignored_schema)'
        -- type
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name in ('type') then
           ' where meta.make_schema_id(schema_name) not in (select schema_id from bundle.ignored_schema)'
        -- constraint_unique, constraint_check, table_privilege
        when (r.relation_id).schema_name = 'meta' and (r.relation_id).name in ('constraint_check','constraint_unique','table_privilege') then
           ' where meta.make_schema_id(schema_name) not in (select schema_id from bundle.ignored_schema) and table_id not in (select relation_id from bundle.ignored_table)'
        else ''
    end

    -- TODO: When meta views are tracked via 'trackable_nontable_relation', they should exclude
    -- rows from meta that are in trackable non-table tables that are ignored

    as stmt
from bundle.trackable_relation r;



--
-- get_untracked_rows()
--

create or replace function _get_untracked_rows(_relation_id meta.relation_id default null) returns setof meta.row_id as $$
-- all rows that aren't ignored by an ignore rule
select r.row_id
from bundle.exec((
    select array_agg (stmt)
    from bundle.not_ignored_row_stmt
    where relation_id = coalesce(_relation_id, relation_id)
)) r (row_id meta.row_id)

except

-- ...except the following:
select * from (
    -- stage_rows_to_add
    select jsonb_array_elements(r.stage_rows_to_add)::meta.row_id from bundle.repository r -- where relation_id=....?

    union
    -- tracked rows
    -- select t.row_id from bundle.track_untracked_rowed t
    select jsonb_array_elements(r.tracked_rows_added)::meta.row_id from bundle.repository r -- where relation_id=....?

    union
    -- stage_rows_to_remove
    -- select d.row_id from bundle.stage_row_to_remove
    select jsonb_array_elements(r.stage_rows_to_remove)::meta.row_id from bundle.repository r-- where relation_id=....?

    union
    -- head_commit_rows for all tables
    select hcr.row_id as row_id
    from bundle.repository r, bundle._get_head_commit_rows(r.id) hcr
) r;
$$ language sql;


--
-- _get_trackable_relation_pk()
--

-- returns the pk_column_name(s) of a relation's primary key, including of nontable_relations

create or replace function _get_trackable_relation_pk(_relation_id meta.relation_id)
returns text[] as $$
declare
    pk_column_names text[];
begin
    -- first check trackable_relations view, to catch nontable_relations (and anything else)
    select tr.pk_column_names from bundle.trackable_relation tr where relation_id = _relation_id into pk_column_names;

    if pk_column_names is not null and array_length(pk_column_names, 1) is not null then
        return pk_column_names;
    end if;


    select array_agg(a.attname order by array_position(c.conkey, a.attnum))
    into pk_column_names
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    join pg_attribute a on a.attnum = any(c.conkey) and a.attrelid = t.oid
    where n.nspname = (_relation_id).schema_name
      and t.relname = (_relation_id).name
      and c.contype = 'p';

    if pk_column_names is null then
        raise exception 'No primary key found for table %.%', (_relation_id).schema_name, (_relation_id).name;
    end if;

    return pk_column_names;
end;
$$ language plpgsql;
------------------------------------------------------------------------------
-- TRACKED / UNTRACKED ROWS
------------------------------------------------------------------------------

/*
 * _is_newly_tracked()
 */

create or replace function _is_newly_tracked( repository_id uuid, row_id meta.row_id ) returns boolean as $$
declare
    row_count integer;
begin
    select count(*) into row_count from bundle.repository
    where id = repository_id
        and tracked_rows_added @> jsonb_build_array(row_id);

    if row_count > 0 then
        return true;
    else
        return false;
    end if;
end;
$$ language plpgsql;


/*
 * track_untracked_row()
 *
 * Adds an untracked row to a repository's tracked_rows_added column.
 */

create or replace function _track_untracked_row( _repository_id uuid, row_id meta.row_id ) returns void as $$
    declare
    begin

        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        if meta.row_exists(meta.make_row_id('bundle','tracked_row_added', 'row_id', row_id::text)) then
            raise exception 'Row with row_id % is already tracked.', row_id;
        end if;

        -- assert row exists
        if not meta.row_exists(row_id) then
            raise exception 'Row with row_id % does not exist.', row_id;
        end if;

        -- assert row_id uses actual pk columns (not alternate keys)
        perform meta.validate_row_id_pk(row_id);

        -- assert row is not already tracked
        if bundle._is_newly_tracked(_repository_id, row_id) then
            raise exception 'Row with row_id % is already tracked.', row_id;
        end if;

        update bundle.repository set tracked_rows_added = tracked_rows_added || row_id where id = _repository_id;
    end;
$$ language plpgsql;


create or replace function track_untracked_row( repository_name text, row_id meta.row_id ) returns void as $$
    declare
    begin

        -- assert repository exists
        if not bundle.repository_exists(repository_name) then
            raise exception 'Repository with name % does not exist.', repository_name;
        end if;

        perform bundle._track_untracked_row(
            bundle.repository_id(repository_name),
            row_id
        );
    end;
$$ language plpgsql;


--
-- untrack_tracked_row()
--

create or replace function _untrack_tracked_row( _repository_id uuid, _row_id meta.row_id ) returns uuid as $$
    declare
        tracked_row_id uuid;
        c integer;
    begin

        select count(*) into c from bundle.repository where id = _repository_id and tracked_rows_added @> jsonb_build_array(_row_id);
        if c < 1 then
            raise exception 'Row with row_id % cannot be removed because it is not tracked by supplied repository.', _row_id::text;
        end if;

        update bundle.repository set tracked_rows_added = (
            select coalesce(jsonb_agg(elem.value), '[]'::jsonb)
            from jsonb_array_elements(tracked_rows_added) elem(value)
            where elem.value != _row_id::jsonb
        ) where id = _repository_id;

        return tracked_row_id;
    end;
$$ language plpgsql;

create or replace function untrack_tracked_row( name text, row_id meta.row_id ) returns uuid as $$
    select bundle._untrack_tracked_row(bundle.repository_id(name), row_id);
$$ language sql;


--
-- untrack_tracked_rows_added()
--

create or replace function _untrack_tracked_rows_added( _repository_id uuid ) returns void as $$
    update bundle.repository set tracked_rows_added='[]'::jsonb where id = _repository_id;
$$ language sql;


--
-- tracked_rows_added
--

create or replace function _get_tracked_rows_added( _repository_id uuid )
returns table(repository_id uuid, row_id meta.row_id) as $$
    select id, jsonb_array_elements(tracked_rows_added)::meta.row_id
    from bundle.repository
    where id = _repository_id;
$$ language sql;

create or replace function get_tracked_rows_added( repository_name text )
returns table(repository_id uuid, row_id meta.row_id) as $$
    select bundle._get_tracked_rows_added(
        bundle.repository_id(repository_name)
    );
$$ language sql;

create or replace view tracked_row_added as
    select id as repository_id, jsonb_array_elements(tracked_rows_added)::meta.row_id as row_id
    from bundle.repository;


--
-- track_untracked_rows_by_relation()
-- Track all untracked rows for a specific relation
--

create or replace function bundle._track_untracked_rows_by_relation( _repository_id uuid, _relation_id meta.relation_id )
returns void as $$ -- returns setof uuid?
declare
    start_time timestamp := clock_timestamp();
begin
    -- assert repository exists
    if not bundle._repository_exists(_repository_id) then
        raise exception 'Repository with id % does not exist.', _repository_id;
    end if;

    -- if there are no untracked rows, jsonb_agg returns null, so coalesce to empty array
    update bundle.repository
    set tracked_rows_added = tracked_rows_added || coalesce(
        (select jsonb_agg(row_id)
         from bundle._get_untracked_rows(_relation_id) row_id),
        '[]'::jsonb
    ) where id = _repository_id;

    raise notice '_track_untracked_rows_by_relation() ... %s', bundle.clock_diff(start_time);
end;
$$ language plpgsql;

create or replace function bundle.track_untracked_rows_by_relation( repository_name text, relation_id meta.relation_id )
returns void as $$ -- setof uuid?
    select bundle._track_untracked_rows_by_relation(bundle.repository_id(repository_name), relation_id);
$$ language sql;
------------------------------------------------------------------------------
-- STAGE / DB COMPARISON / WORKING COPY FUNCTIONS
--
-- This file consolidates:
--   1. DB State Functions - Read current database state and compare to commits
--   2. Stage Operations - Manipulate the staging area
--   3. Stage-Dependent Comparisons - Compare staged changes to database/commit state
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- PART 1: DB STATE FUNCTIONS
-- Functions that read current database state and compare to commit snapshots
------------------------------------------------------------------------------


--
-- get_db_commit_rows()
--
-- NOTE: row_exists type is defined in types.sql

create or replace function _get_db_commit_rows( _commit_id uuid, _relation_id meta.relation_id default null ) returns setof row_exists as $$
declare
    rel record;
    stmts text[] := '{}';
    literals_stmt text;
    pk_comparison_stmt text;
begin
    if not bundle._commit_exists( _commit_id ) then
        -- raise warning 'get_db_commit_rows(): Commit with id % does not exist.', _commit_id;
        return;
    end if;

/*
    WIP:

    -- is the supplied commit the head commit?  if so, use head_commit_row mat view instead of
    -- commit_rows() for much speed
    select repository_id from bundle.commit where commit_id = _commit_id into _repository_id;
    if _commit_id = bundle._head_commit_id(repository_id) then
        commit_rows_stmt := 'bundle.get_head_commit_rows';
    else
        commit_rows_stmt := 'bundle._get_commit_rows(_commit_id) row_id'
    end if;
*/

    -- for each relation in this commit
    for rel in
        select
            row_id->>'relation_name' as relation_name,
            row_id->>'schema_name' as schema_name,
            row_id->'pk_column_names' as pk_column_names_jsonb
        from bundle._get_commit_rows(_commit_id) row_id
        where meta.row_id_to_relation_id(row_id) =
            case
                when _relation_id is null then meta.row_id_to_relation_id(row_id)
                else _relation_id
            end
        group by row_id->>'relation_name', row_id->>'schema_name', row_id->'pk_column_names'
    loop
        -- Convert JSONB array to PostgreSQL text array
        declare
            pk_column_names text[];
        begin
            select array_agg(value::text) from jsonb_array_elements_text(rel.pk_column_names_jsonb) into pk_column_names;

        -- raise notice '#### _db_commit_rows rel: %', rel;

        -- for this relation, select the commit_rows that are in this relation, and also in this
        -- repository, and inner join them with the relation's data, breaking it out into one row per
        -- field.

        -- TODO: check that each relation exists and still has the same primary key

        -- generate the pk comparisons line
        -- FIXME: fails on composite keys because row('a','b','c') != '(a,b,c)':
        -- 'ERROR:  input of anonymous composite types is not implemented' (bug in pg)
        pk_comparison_stmt := meta._pk_stmt(pk_column_names, pk_column_names, 'x.%1$I::text = (row_id)->''pk_values''->>(%3$s-1)');
        -- WAS: pk_comparison_stmt := meta._pk_stmt(rel.pk_column_names, rel.pk_column_names, '(row_id).pk_values[%3$s] = x.%1$I::text', ' and ');


        stmts := array_append(stmts, format('
            select row_id, x.%I is not null as exists
            from bundle._get_commit_rows(%L, meta.make_relation_id(%L,%L)) row_id
                left join %I.%I x on
                    %s and
                    (row_id)->>''schema_name'' = %L and
                    (row_id)->>''relation_name'' = %L',
            pk_column_names[1], -- 1 is ok here because we're just checking for exist w/ left join & pks cannot be null.  TODO: non-table_rel??
            _commit_id,
            rel.schema_name,
            rel.relation_name,
            rel.schema_name,
            rel.relation_name,
            pk_comparison_stmt,
            rel.schema_name,
            rel.relation_name
        ));
        end;
    end loop;

    literals_stmt := array_to_string(stmts,E'\nunion\n');

    -- raise notice 'literals_stmt: %', literals_stmt;

    if literals_stmt != '' then
        return query execute literals_stmt;
    else
        return;
    end if;
end;
$$ language plpgsql;


--
-- get_db_head_commit_rows()
--

create or replace function _get_db_head_commit_rows( repository_id uuid ) returns setof row_exists as $$
    select * from bundle._get_db_commit_rows(bundle._head_commit_id(repository_id))
$$ language sql;


--
-- get_db_commit_fields()
--

/*
Returns a field_hash for live database values for a given commit.  It returns
*all* columns present, without regard to what columns or fields are actually
being tracked in the database.  Think `select * from my.table`.  This means:

- when a field is changed since the last commit, the change will be reflected here
- when a column is added since the provided commit, it will be present in this list
- when a column is deleted since the provided commit, it will be absent from this list

Steps:

1) make a list of the relations of all rows in the supplied commit

2) for each relation "x":
   a) start with the contents of get_commit_rows(), then LEFT JOIN with
      the relation, on

      rowset_row.row_id.pk_value IS NOT DISTINCT FROM x.$pk_column_name

      (NOT DISTINCT because null != null, and that's a match in this situation)

   b) call jsonb_each_text(to_json(x)) which makes a row for each field
   c) construct the field's field_id, and sha256 the field's value

3) UNION all these field_id + hashes from all these relations together and
   return a big list of field_hash records, (meta.field_id, value_hash)

It returns the value hash of all fields on any row in the supplied commit, with
its value hash.  Typically, this would be called with the repo's head commit
(repository.head_commit_id), though it can be used to diff against previous
commits as well.

It is useful for generating a repository's row list with change info, as well
as the stage.  When you INNER JOIN this function's results against
get_commit_fields(), non-matching hashes will be fields changed.  When you OUTER
JOIN, it'll pick up new fields (from new columns presumably).
*/


create or replace function _get_db_commit_fields(commit_id uuid) returns setof bundle.field_hash as $$
declare
    rel record;
    stmts text[] = '{}';
    literals_stmt text;
    pk_comparison_stmt text;
begin
    -- all relations in the head commit
    for rel in
        select distinct
            (meta.row_id_to_relation_id(row_id))->>'name' as relation_name,
            (meta.row_id_to_relation_id(row_id))->>'schema_name' as schema_name,
            row_id->'pk_column_names' as pk_column_names
        from bundle._get_commit_rows(commit_id) row_id
    loop
        -- for each relation, select head commit rows in this relation and also
        -- in this repository, and inner join them with the relation's data,
        -- into one row per field

        -- TODO: check that each relation exists and has not been deleted.
        -- currently, when that happens, this function will fail.

        -- Convert JSONB array to PostgreSQL text array
        declare
            pk_column_names text[];
        begin
            select array_agg(value::text) from jsonb_array_elements_text(rel.pk_column_names) into pk_column_names;

        pk_comparison_stmt := meta._pk_stmt(pk_column_names, '{}'::text[], 'x.%1$I::text = (row_id)->''pk_values''->>(%3$s-1)');
        -- WAS: pk_comparison_stmt := meta._pk_stmt(rel.pk_column_names, '{}'::text[], '(row_id).pk_values[%3$s] = x.%1$I::text', ' and ');

        stmts := array_append(stmts, format('
            select row_id, jsonb_each_text(bundle.row_to_jsonb_hash_obj(x)) as keyval
            from bundle._get_db_commit_rows(%L, meta.make_relation_id(%L,%L)) row_id
                left join %I.%I x on
                    %s and
                    (row_id)->>''schema_name'' = %L and
                    (row_id)->>''relation_name'' = %L',
            commit_id,
            rel.schema_name,
            rel.relation_name,
            rel.schema_name,
            rel.relation_name,
            pk_comparison_stmt,
            rel.schema_name,
            rel.relation_name
        ));
        end;
    end loop;

    literals_stmt := array_to_string(stmts,E'\nunion\n');

    if literals_stmt = '' then return; end if;

    -- wrap stmt to beautify columns
    literals_stmt := format('
        select
            meta.make_field_id(row_id, (keyval).key),
            -- TODO bundle.hash((keyval).value)::text as value_hash
            ((keyval).value)::text as value_hash
        from (%s) fields;',
        literals_stmt
    );

    -- raise notice 'literals_stmt: %', literals_stmt;

    return query execute literals_stmt;

end
$$ language plpgsql;


--
-- _get_db_head_commit_fields()
create or replace function _get_db_head_commit_fields(_repository_id uuid) returns setof bundle.field_hash as $$
    select * from bundle._get_db_commit_fields(bundle._head_commit_id(_repository_id));
$$ language sql;



/*
--
-- get_db_row_fields_obj()
--
-- returns a jsonb object whose keys are column names and values are live db values.
-- one-row at a time.  called from commit().  slow and crappy, shouldn't be used

create or replace function _get_db_row_fields_obj(_row_id meta.row_id) returns jsonb as $$
declare
    stmt text;
    obj jsonb;
begin
    stmt := format('select * from %I.%I xx where %s',
        _row_id->>'schema_name',
        _row_id->>'relation_name',
        -- BAD!  This slows things down like 10x:
        -- meta._pk_stmt(_row_id, '%1$I::text = %2$L')
        meta._pk_stmt(_row_id, '%1$I = %2$L')

    );

    obj := bundle.query_to_jsonb_text(stmt);
    return obj;
end;
$$ language plpgsql;



--
-- get_db_row_field_hashes_obj()
--
-- returns a jsonb object whose keys are column names and values are live db value hashes
-- TODO: can this be done inline so values aren't stored in memory in temp obj?

create or replace function _get_db_row_field_hashes_obj(_row_id meta.row_id) returns jsonb as $$
declare
    stmt text;
    obj jsonb;
    hashed_obj jsonb := '{}';
    key text;
    value text;
begin
    -- build key: value temp obj
    stmt := format('select to_json(xx) from %I.%I xx where %s',
        _row_id->>'schema_name',
        _row_id->>'relation_name',
        meta._pk_stmt(_row_id, '%1$I = %2$L')
    );
    execute stmt into obj;
    -- raise notice 'get_db_row_field_hashes_obj: %', obj;

    -- hash values into hashed_obj, for return
    for key, value in select * from jsonb_each_text(obj) loop
        -- hashed_obj := hashed_obj || jsonb_build_object(key, TODO bundle.hash(value));
        hashed_obj := hashed_obj || jsonb_build_object(key, value::text);
    end loop;

    return hashed_obj;
end;
$$ language plpgsql;
*/

--
-- tracked
--

create or replace function _get_db_tracked_rows_added( _repository_id uuid )
returns table(row_id meta.row_id, row_exists boolean) as $$
    select
        elem::meta.row_id as row_id,
        meta.row_exists(elem::meta.row_id) as row_exists
    from bundle.repository r,
         lateral jsonb_array_elements(r.tracked_rows_added) elem
    where r.id = _repository_id;
$$ language sql;

create or replace function get_db_tracked_rows_added( repository_name text )
returns table(row_id meta.row_id, row_exists boolean) as $$
    select * from bundle._get_db_tracked_rows_added(
        bundle.repository_id(repository_name)
    );
$$ language sql;


--
-- stage
--

create or replace function _get_db_stage_rows_added( _repository_id uuid )
returns table(row_id meta.row_id, row_exists boolean) as $$
    select
        elem::meta.row_id as row_id,
        meta.row_exists(elem::meta.row_id) as row_exists
    from bundle.repository r,
         lateral jsonb_array_elements(r.stage_rows_to_add) elem
    where r.id = _repository_id;
$$ language sql;

/*

failure:

create or replace function _get_db_rowset_fields_obj(rowset jsonb) returns jsonb as $$
declare
    relations meta.relation_id[];
    rel_id meta.relation_id;
    col_id meta.column_id;

    col_stmt text;
    col_stmts text[];
    stmt text;
    stmts text[] = '{}';

    results jsonb;
begin
    raise notice 'rowset: %', rowset;
    -- relations in the rowset
    foreach rel_id in array bundle._get_rowset_relations(rowset) loop

        -- builds a key/val to pass to jsonb_build_object
        -- e.g.
        -- 'id', bundle.hash(r.id::text),               -- "id": '\x123123123'
        -- 'schema_id', bundle.hash(r.schema_id::text)

        col_stmts := '{}';
        foreach col_id in array meta.get_columns(rel_id) loop
            col_stmts := array_append(col_stmts, format('%L, bundle.hash(r.%I::text)',
                col_id->>'name',
                col_id->>'name',
                col_id->>'name')
            );
        end loop;

        col_stmt := array_to_string(col_stmts, E',\n');
        raise notice 'col_stmt: %', col_stmt;

        stmt := format('select meta.make_row_id(%L,%L,%L,%L) row_id, jsonb_build_object(%s) obj
                from %I.%I r
                join jsonb_array_elements_text(%s::jsonb) rs on %s',

            -- row_id
            rel_id->>'schema_name',
            rel_id->>'name',
            'x',
            'x',

            -- col stmts
            col_stmt,

            -- from relation
            rel_id->>'schema_name',
            rel_id->>'name',

            -- rowset???
            quote_literal(rowset::text), -- inefficient as heck but thought you could use USING.  can't.

            '1=1' -- meta._pk_stmt(..)
        );

        stmts := array_append(stmts, stmt);
    end loop;

    stmt := array_to_string(stmts,E'\nunion\n');

    raise notice '_get_db_rowset_fields_obj stmt: %', stmt;

    -- wrap the big union stmt with an object_agg to pull it all together
    stmt := format('select jsonb_object_agg(row_id, obj) from (%s) s(row_id, obj)',
        stmt
    );

    execute stmt into results using rowset;
    raise notice 'RESULTS: %', results;
    return results;
end;
$$ language plpgsql;
*/




/*
big diff queries:

select *
from get_db_commit_fields(head_commit_id('io.bundle.test')) dbcf
full outer join commit_fields(head_commit_id('io.bundle.test')) cf on dbcf.field_id = cf.field_id
where
    dbcf.value_hash != cf.value_hash or
    dbcf.field_id is null
    or cf.field_id is null;



select * from _get_db_commit_rows(head_commit_id('io.bundle.test')) dbcr
full outer join _get_commit_rows(head_commit_id('io.bundle.test')) cr on dbcr.row_id = cr.row_id
where
    dbcr.row_id is null
    or cr.row_id is null
    or dbcr.exists = false;
*/


------------------------------------------------------------------------------
-- PART 2: STAGE OPERATIONS
-- Functions that manipulate the staging area
------------------------------------------------------------------------------



-------------------------------------------------
-- Staging / Unstaging Action Functions
-------------------------------------------------

--
-- stage_tracked_row()
--

create or replace function _stage_tracked_row( _repository_id uuid, _row_id meta.row_id ) returns void as $$
    begin
        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        -- check that it's not already staged
        if meta.row_exists(meta.make_row_id('bundle','stage_row_to_add', 'row_id', _row_id::text)) then
            raise exception 'Row with row_id % is already staged.', _row_id;
        end if;

        if exists (
            select 1 from bundle._get_head_commit_rows(_repository_id)
            where row_id = _row_id
        ) then
            raise exception 'Row with row_id % is already in the repository.', _row_id;
        end if;

        -- untrack
        perform bundle._untrack_tracked_row(_repository_id, _row_id);

        -- stage
        update bundle.repository
        set stage_rows_to_add = stage_rows_to_add || _row_id
        where id = _repository_id;
    end;
$$ language plpgsql;

create or replace function stage_tracked_row( repository_name text, row_id meta.row_id )
returns void as $$
    begin
        -- assert repository exists
        if not bundle.repository_exists(repository_name) then
            raise exception 'Repository with name % does not exist.', repository_name;
        end if;

        perform bundle._stage_tracked_row(
            bundle.repository_id(repository_name),
            row_id
        );
    end;
$$ language plpgsql;


--
-- unstage_tracked_row()
--

create or replace function _unstage_tracked_row(_repository_id uuid, _row_id meta.row_id)
returns void language plpgsql as $$
begin
    -- assert repository exists
    if not bundle._repository_exists(_repository_id) then
        raise exception 'Repository with id % does not exist.', _repository_id;
    end if;

    -- remove from stage_rows_to_add jsonb array
    update bundle.repository
    set stage_rows_to_add = (
        select coalesce(jsonb_agg(elem.value), '[]'::jsonb)
        from jsonb_array_elements(stage_rows_to_add) elem(value)
        where elem.value != to_jsonb(_row_id)
    )
    where id = _repository_id;

    -- re-track the row (correct column: tracked_rows_added)
    update bundle.repository
    set tracked_rows_added = coalesce(tracked_rows_added, '[]'::jsonb) || to_jsonb(_row_id)
    where id = _repository_id
    and not (coalesce(tracked_rows_added, '[]'::jsonb) @> jsonb_build_array(to_jsonb(_row_id)));
end;
$$;




--
-- stage_row_to_remove()
--

create or replace function _stage_row_to_remove( _repository_id uuid, _row_id meta.row_id ) returns void as $$
    declare
    begin

        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        if not exists (
            select 1 from bundle._get_head_commit_rows(_repository_id)
            where row_id = _row_id
        ) then
            raise exception 'Row with row_id % is not in the head commit.', _row_id;
        end if;

        -- stage
        update bundle.repository
        set stage_rows_to_remove = stage_rows_to_remove || _row_id
        where id = _repository_id;
    end;
$$ language plpgsql;

create or replace function stage_row_to_remove( repository_name text, row_id meta.row_id )
returns void as $$
    begin

        -- assert repository exists
        if not bundle.repository_exists(repository_name) then
            raise exception 'Repository with name % does not exist.', repository_name;
        end if;

        perform bundle._stage_row_to_remove(
            bundle.repository_id(repository_name),
            row_id
        );
    end;
$$ language plpgsql;


--
-- unstage_row_to_remove()
--
-- Removes a staged row (add or delete) from the stage.  Split these up?

create or replace function _unstage_row_to_remove( _repository_id uuid, _row_id meta.row_id ) returns void as $$
    declare
        row_exists boolean;
    begin

        -- assert row is staged
        select exists (select 1 from bundle.stage_row_to_add sra where sra.row_id = _row_id) into row_exists;
        if not row_exists then
            raise exception 'Row with row_id % is not staged.', _row_id;
        end if;

        update bundle.repository
        set stage_rows_to_remove = (
            select coalesce(jsonb_agg(elem.value), '[]'::jsonb)
            from jsonb_array_elements(stage_rows_to_remove) elem(value)
            where elem.value != _row_id::jsonb
        )
        where id = _repository_id;
    end;
$$ language plpgsql;

create or replace function unstage_row_to_remove( _repository_id uuid, row_id meta.row_id )
returns void as $$
    select bundle._unstage_row_to_remove(_repository_id, row_id);
$$ language sql;


--
-- stage a field change
--

create or replace function _stage_field_to_change( _repository_id uuid, _field_id meta.field_id ) returns boolean as $$
    begin
        -- TODO: assert field is changed and part of repo
        update bundle.repository
        -- obj approach: set stage_fields_to_change = stage_fields_to_change || jsonb_build_object(_field_id::text, meta.field_id_literal_value(_field_id))
        set stage_fields_to_change = stage_fields_to_change || _field_id
        where id = _repository_id;
        return true;
    end;
$$ language plpgsql;

--
-- unstage a field change
--

create or replace function _unstage_field_to_change(_repository_id uuid, _field_id meta.field_id)
returns boolean
language plpgsql as $$
begin
    update bundle.repository
    set stage_fields_to_change = (
        select coalesce(jsonb_agg(elem), '[]'::jsonb)
        from jsonb_array_elements(stage_fields_to_change) as elem
        where elem != _field_id::jsonb
    )
    where id = _repository_id;
    return true;
end;
$$;

create or replace function unstage_field_to_change( repository_name text, _field_id meta.field_id ) returns void as $$
    select bundle._unstage_field_to_change(bundle.repository_id(repository_name), _field_id);
$$ language sql;


--
-- stage_all()
--
-- Stage all changes at once: tracked rows, updated fields, and deleted rows

create or replace function _stage_all( _repository_id uuid, relation_id_filter meta.relation_id default null ) returns void as $$
    begin
        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        -- stage tracked rows (new rows)
        perform bundle._stage_tracked_rows(_repository_id);

        -- stage updated fields (changes to existing rows)
        perform bundle._stage_updated_fields(_repository_id, relation_id_filter);

        -- stage deleted rows (rows removed from db)
        perform bundle._stage_deleted_rows(_repository_id, relation_id_filter);
    end;
$$ language plpgsql;

create or replace function stage_all( repository_name text, relation_id_filter meta.relation_id default null ) returns void as $$
    select bundle._stage_all(bundle.repository_id(repository_name), relation_id_filter);
$$ language sql;

--
-- empty_stage()
--

create or replace function _empty_stage( _repository_id uuid ) returns void as $$
    begin
        update bundle.repository set stage_rows_to_add = '[]' where id = _repository_id;
        update bundle.repository set stage_rows_to_remove = '[]' where id = _repository_id;
        update bundle.repository set stage_fields_to_change = '[]' where id = _repository_id;
    end;
$$ language plpgsql;

create or replace function empty_stage( repository_name text ) returns void as $$
    select bundle._empty_stage(bundle.repository_id(repository_name));
$$ language sql;



-------------------------------------------------
-- Set Views / Functions
-- Convention: _get_*()
-------------------------------------------------

--
-- get_stage_rows_to_add()
--

create or replace function _get_stage_rows_to_add( _repository_id uuid ) returns table (repository_id uuid, row_id meta.row_id) as $$
    select id, jsonb_array_elements(stage_rows_to_add)
    from bundle.repository
    where id = _repository_id;
$$ language sql;

create view stage_row_to_add as
select id as repository_id, jsonb_array_elements(stage_rows_to_add) as row_id
from bundle.repository;


--
-- get_stage_rows_to_remove()
--

create or replace function _get_stage_rows_to_remove( _repository_id uuid ) returns table(repository_id uuid, row_id meta.row_id) as $$
    select id, jsonb_array_elements(stage_rows_to_remove)
    from bundle.repository
    where id = _repository_id;
$$ language sql;

create view stage_row_to_remove as
select id as repository_id, jsonb_array_elements(stage_rows_to_remove) as row_id
from bundle.repository;


--
-- get_stage_fields_to_change()
--

create or replace function _get_stage_fields_to_change( _repository_id uuid ) returns setof meta.field_id as $$
    select jsonb_array_elements(stage_fields_to_change)
    from bundle.repository
    where id = _repository_id;
$$ language sql;

create view stage_field_to_change as
    -- select id, jsonb_array_elements(stage_fields_to_change)
select id as repository_id, jsonb_array_elements(stage_fields_to_change) as field_id
from bundle.repository;


--
-- _is_staged()
--

create or replace function _is_staged( repository_id uuid, row_id meta.row_id ) returns boolean as $$
begin
    return (
        select stage_rows_to_add @> jsonb_build_array(row_id)
        from bundle.repository
        where id = repository_id
    );
end;
$$ language plpgsql;



--
-- get_tracked_rows()
-- Returns *all* tracked rows: Newly tracked, staged and head_commit rows

create or replace function _get_tracked_rows( _repository_id uuid ) returns setof meta.row_id as $$
    -- head commit rows
    select row_id from bundle._get_head_commit_rows(_repository_id)

    -- ...plus newly tracked rows
    union

    select jsonb_array_elements(r.tracked_rows_added)::meta.row_id
    from bundle.repository r
    where r.id = _repository_id

    -- plus staged rows
    union

    select jsonb_array_elements(r.stage_rows_to_add)::meta.row_id
    from bundle.repository r
    where r.id = _repository_id
$$ language sql;

create or replace function get_tracked_rows( repository_name text ) returns setof meta.row_id as $$
    select bundle._get_tracked_rows(
        bundle.repository_id(repository_name)
    );
$$ language sql;



create or replace function _get_offstage_deleted_rows(
    _repository_id uuid,
    relation_id_filter meta.relation_id default null
) returns setof meta.row_id as $$
    -- rows deleted from head commit
    select row_id
    from bundle._get_db_head_commit_rows(_repository_id)
    where exists = false
    and (relation_id_filter is null or meta.row_id_to_relation_id(row_id) = relation_id_filter)

    except

    -- minus those that have been staged for deletion
    select jsonb_array_elements(r.stage_rows_to_remove)::meta.row_id
    from bundle.repository r where r.id = _repository_id;
$$ language sql;


--
-- get_stage_updated_fields() TODO
--

--
-- get_offstage_updated_fields()
--
-- NOTE: field_hash_diff type is defined in types.sql

create or replace function _get_db_stage_fields_to_change(
    _repository_id uuid,
    relation_id_filter meta.relation_id default null
)
returns table (
    field_id meta.field_id,
    row_exists boolean,
    column_exists boolean,
    field_is_changed boolean,
    db_value_hash text
) as $$
    select
        staged.field_id,
        coalesce(db_rows.exists, false) as row_exists,
        db_fields.field_id is not null as column_exists,
        coalesce(commit_fields.value_hash != db_fields.value_hash, false) as field_is_changed,
        db_fields.value_hash as db_value_hash
    from (
        select jsonb_array_elements(stage_fields_to_change)::meta.field_id as field_id
        from bundle.repository
        where id = _repository_id
    ) staged
    -- check if row exists
    left join bundle._get_db_head_commit_rows(_repository_id) db_rows
        on meta.field_id_to_row_id(staged.field_id) = db_rows.row_id
    -- get current db value (tells us if column exists)
    left join bundle._get_db_head_commit_fields(_repository_id) db_fields
        on staged.field_id = db_fields.field_id
    -- get committed value to compare
    left join bundle._get_head_commit_fields(_repository_id) commit_fields
        on staged.field_id = commit_fields.field_id
    where relation_id_filter is null
       or meta.field_id_to_relation_id(staged.field_id) = relation_id_filter;
$$ language sql;


create or replace function _get_offstage_updated_fields(
    _repository_id uuid,
    relation_id_filter meta.relation_id default null
) returns setof bundle.field_hash_diff as $$
    -- fields whos commit hash is different from db hash
    select
        hcf.field_id as field_id,
        dbf.value_hash as db_value_hash,
        hcf.value_hash as commit_value_hash
    -- fields from head commit
    from bundle._get_head_commit_fields(_repository_id) hcf
        -- join with existing rows to exclude deleted rows from field change detection
        join bundle._get_db_head_commit_rows(_repository_id) existing_rows
            on meta.field_id_to_row_id(hcf.field_id) = existing_rows.row_id
        -- left joined because db_fields() excludes dropped columns and columns may have been dropped
        left join bundle._get_db_head_commit_fields(_repository_id) dbf on dbf.field_id = hcf.field_id
        -- exclude staged fields
        left join bundle._get_db_stage_fields_to_change(_repository_id, relation_id_filter) sfc on sfc.field_id = hcf.field_id
    -- where value is different
    where existing_rows.exists = true
    and hcf.value_hash != dbf.value_hash -- hash should never be NULL so we can use != here
    -- and it's not on the stage
    and sfc.field_id is null
    -- relation filter
    and (relation_id_filter is null or meta.field_id_to_relation_id(hcf.field_id) = relation_id_filter)

/*
    except

    select field_id, value_hash from bundle._get_db_stage_fields_to_change(_repository_id, relation_id_filter);
*/
$$ language sql;


--
-- _get_stage_rows()
--
-- NOTE: stage_row type is defined in types.sql

create or replace function _get_stage_rows( _repository_id uuid ) returns setof stage_row as $$
    select row_id, false as new_row from (
        -- head_commit_row
        select hcr.row_id as row_id
        from bundle._get_head_commit_rows(_repository_id) hcr

        except

        -- ...minus deleted rows
        select jsonb_array_elements(stage_rows_to_remove)::meta.row_id as row_id
        from bundle.repository r
        where r.id = _repository_id

    ) remaining_rows

    union

    -- ...plus staged rows
    select jsonb_array_elements(r.stage_rows_to_add)::meta.row_id, true as new_row
    from bundle.repository r
    where r.id = _repository_id

$$ language sql;


-------------------------------------------------
-- Macro-ops
-------------------------------------------------

--


--
-- stage_tracked_rows()
--

create or replace function _stage_tracked_rows( _repository_id uuid ) returns void as $$
declare
    _tracked_rows_obj jsonb;
begin
    -- append tracked_rows_added to stage_rows_to_add
    update bundle.repository
    set stage_rows_to_add = stage_rows_to_add || tracked_rows_added
    where id = _repository_id;

    -- clear repository.tracked_rows_added
    update bundle.repository set tracked_rows_added = '[]'::jsonb
    where id = _repository_id;

end;
$$ language plpgsql;

create or replace function stage_tracked_rows( repository_name text ) returns void as $$
    select bundle._stage_tracked_rows(bundle.repository_id(repository_name))
$$ language sql;


--
-- stage_updated_fields()
-- stages all changed unstaged field changes on a repository

create or replace function _stage_updated_fields( _repository_id uuid, relation_id_filter meta.relation_id default null ) returns void as $$
    declare
        updated_fields jsonb;
        start_time timestamp := clock_timestamp();
    begin
        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        with updated_fields as (
            select jsonb_agg(f.field_id) field
            from bundle._get_offstage_updated_fields(_repository_id) f
            where (relation_id_filter is null or meta.field_id_to_relation_id(f.field_id) = relation_id_filter)
        )
        update bundle.repository
        set stage_fields_to_change = stage_fields_to_change || coalesce(updated_fields.field, '[]'::jsonb)
        from updated_fields
        where id = _repository_id;

        raise notice '_stage_updated_fields() ... %s', bundle.clock_diff(start_time);
    end;
$$ language plpgsql;

create or replace function stage_updated_fields( repository_name text, relation_id_filter meta.relation_id default null ) returns void as $$
    select bundle._stage_updated_fields(bundle.repository_id(repository_name), relation_id_filter);
$$ language sql;


--
-- stage_deleted_rows()
-- stage all off-stage deleted rows for removal
--

create or replace function _stage_deleted_rows( _repository_id uuid, relation_id_filter meta.relation_id default null ) returns void as $$
    declare
        start_time timestamp := clock_timestamp();
    begin
        -- assert repository exists
        if not bundle._repository_exists(_repository_id) then
            raise exception 'Repository with id % does not exist.', _repository_id;
        end if;

        update bundle.repository
        set stage_rows_to_remove = stage_rows_to_remove || coalesce(
            (select to_jsonb(array_agg(r)) lateral from bundle._get_offstage_deleted_rows (_repository_id, relation_id_filter) r),
            '[]'::jsonb
        )
        where id = _repository_id;
        raise notice '_stage_deleted_rows() ... %s', bundle.clock_diff(start_time);
    end;
$$ language plpgsql;

create or replace function stage_deleted_rows( repository_name text, relation_id_filter meta.relation_id default null ) returns void as $$
    select bundle._stage_deleted_rows(bundle.repository_id(repository_name), relation_id_filter);
$$ language sql;


--
-- unstage_tracked_row()
-- remove a row from stage_rows_to_add (move back to tracked_rows_added)
--

create or replace function _unstage_tracked_row( _repository_id uuid, _row_id meta.row_id ) returns void as $$
declare
    row_id_json jsonb := to_jsonb(_row_id);
begin
    -- remove from stage_rows_to_add
    update bundle.repository
    set stage_rows_to_add = (
        select coalesce(jsonb_agg(elem), '[]'::jsonb)
        from jsonb_array_elements(stage_rows_to_add) elem
        where elem != row_id_json
    )
    where id = _repository_id;

    -- add back to tracked_rows_added
    update bundle.repository
    set tracked_rows_added = tracked_rows_added || jsonb_build_array(row_id_json)
    where id = _repository_id;
end;
$$ language plpgsql;

create or replace function unstage_tracked_row( repository_name text, _row_id meta.row_id ) returns void as $$
    select bundle._unstage_tracked_row(bundle.repository_id(repository_name), _row_id);
$$ language sql;


--
-- unstage_all()
-- clear all staged items, moving rows back to tracked_rows_added
--

create or replace function unstage_all( repository_name text ) returns void as $$
declare
    repo bundle.repository;
begin
    select * into repo from bundle.repository r where r.name = repository_name;
    if not found then
        raise exception 'Repository not found: %', repository_name;
    end if;

    -- move staged rows to add back to tracked_rows_added, clear all staging arrays
    update bundle.repository
    set tracked_rows_added = tracked_rows_added || coalesce(stage_rows_to_add, '[]'::jsonb),
        stage_rows_to_add = '[]'::jsonb,
        stage_rows_to_remove = '[]'::jsonb,
        stage_fields_to_change = '[]'::jsonb
    where id = repo.id;
end;
$$ language plpgsql;




------------------------------------------------------------------------------
-- PART 3: STAGE-DEPENDENT DB COMPARISONS
-- Functions that depend on stage operations and compare staged state
------------------------------------------------------------------------------


create or replace function _get_db_stage_rows_added( _repository_id uuid )
returns table(row_id meta.row_id, row_exists boolean) as $$
    select
        elem::meta.row_id as row_id,
        meta.row_exists(elem::meta.row_id) as row_exists
    from bundle.repository r,
         lateral jsonb_array_elements(r.stage_rows_to_add) elem
    where r.id = _repository_id;
$$ language sql;

create or replace function _get_db_offstage_updated_fields(
    _repository_id uuid,
    relation_id_filter meta.relation_id default null
)
returns table(field_id meta.field_id, db_value_hash text, commit_value_hash text, row_exists boolean)
as $$
    select
        f.field_id,
        f.db_value_hash,
        f.commit_value_hash,
        meta.row_exists(meta.field_id_to_row_id(f.field_id)) as row_exists
    from bundle._get_offstage_updated_fields(_repository_id, relation_id_filter) f;
$$ language sql;


create or replace function _get_db_stage_rows_to_remove(_repository_id uuid)
returns table(repository_id uuid, row_id meta.row_id, row_exists boolean)
as $$
    select
        s.repository_id,
        s.row_id,
        meta.row_exists(s.row_id) as row_exists
    from bundle._get_stage_rows_to_remove(_repository_id) s;
$$ language sql;


/*

failure:

create or replace function _get_db_rowset_fields_obj(rowset jsonb) returns jsonb as $$
declare
    relations meta.relation_id[];
    rel_id meta.relation_id;
    col_id meta.column_id;

    col_stmt text;
    col_stmts text[];
    stmt text;
    stmts text[] = '{}';

    results jsonb;
begin
    raise notice 'rowset: %', rowset;
    -- relations in the rowset
    foreach rel_id in array bundle._get_rowset_relations(rowset) loop

        -- builds a key/val to pass to jsonb_build_object
        -- e.g.
        -- 'id', bundle.hash(r.id::text),               -- "id": '\x123123123'
        -- 'schema_id', bundle.hash(r.schema_id::text)

        col_stmts := '{}';
        foreach col_id in array meta.get_columns(rel_id) loop
            col_stmts := array_append(col_stmts, format('%L, bundle.hash(r.%I::text)',
                col_id->>'name',
                col_id->>'name',
                col_id->>'name')
            );
        end loop;

        col_stmt := array_to_string(col_stmts, E',\n');
        raise notice 'col_stmt: %', col_stmt;

        stmt := format('select meta.make_row_id(%L,%L,%L,%L) row_id, jsonb_build_object(%s) obj
                from %I.%I r
                join jsonb_array_elements_text(%s::jsonb) rs on %s',

            -- row_id
            rel_id->>'schema_name',
            rel_id->>'name',
            'x',
            'x',

            -- col stmts
            col_stmt,

            -- from relation
            rel_id->>'schema_name',
            rel_id->>'name',

            -- rowset???
            quote_literal(rowset::text), -- inefficient as heck but thought you could use USING.  can't.

            '1=1' -- meta._pk_stmt(..)
        );

        stmts := array_append(stmts, stmt);
    end loop;

    stmt := array_to_string(stmts,E'\nunion\n');

    raise notice '_get_db_rowset_fields_obj stmt: %', stmt;

    -- wrap the big union stmt with an object_agg to pull it all together
    stmt := format('select jsonb_object_agg(row_id, obj) from (%s) s(row_id, obj)',
        stmt
    );

    execute stmt into results using rowset;
    raise notice 'RESULTS: %', results;
    return results;
end;
$$ language plpgsql;
*/




/*
big diff queries:

select *
from get_db_commit_fields(head_commit_id('io.bundle.test')) dbcf
full outer join commit_fields(head_commit_id('io.bundle.test')) cf on dbcf.field_id = cf.field_id
where
    dbcf.value_hash != cf.value_hash or
    dbcf.field_id is null
    or cf.field_id is null;



select * from _get_db_commit_rows(head_commit_id('io.bundle.test')) dbcr
full outer join _get_commit_rows(head_commit_id('io.bundle.test')) cr on dbcr.row_id = cr.row_id
where
    dbcr.row_id is null
    or cr.row_id is null
    or dbcr.exists = false;
*/
------------------------------------------------------------------------------
-- COMMIT
------------------------------------------------------------------------------

create or replace function _get_commit_ancestry(_commit_id uuid) returns setof _commit_ancestor as $$
    with recursive parent as (
        select c.id, c.parent_id, c.commit_time, c.message, c.author_name, c.author_email, 1 as position
        from bundle.commit c
        where c.id = _commit_id
        union
        select c.id, c.parent_id, c.commit_time, c.message, c.author_name, c.author_email, p.position + 1
        from bundle.commit c
        join parent p on c.id = p.parent_id
    )
    select id, position, commit_time, message, author_name, author_email
    from parent
$$ language sql;


--
-- commit_log()
--

create or replace function _commit_log(_repository_id uuid)
returns table(
    "position" integer,
    commit_id uuid,
    message text,
    author_name text,
    author_email text,
    commit_time timestamptz
) as $$
    select position, commit_id, message, author_name, author_email, commit_time
    from bundle._get_commit_ancestry(bundle._head_commit_id(_repository_id))
    order by position;
$$ language sql stable;

create or replace function commit_log(repository_name text)
returns table(
    "position" integer,
    commit_id uuid,
    message text,
    author_name text,
    author_email text,
    commit_time timestamptz
) as $$
    select * from bundle._commit_log(bundle.repository_id(repository_name));
$$ language sql stable;


create or replace function __commit_stage_blobs( _repository_id uuid, new_commit_id uuid, parent_commit_id uuid ) returns void as $$
begin
        --
        -- blob
        --

        /*
        raise debug '  - Inserting blobs @ % ...', clock_diff(start_time);

        ultimately we want a list of values to add to the blob table
        1. get relations present in stage_rows_to_add
        2. get columns for each relation
        3. for each relation join stage_rows_to_add on pks=pks
        4.     for every row also in stage_rows_to_add

        insert into bundle.blob (value)
        select distinct (jsonb_each(sra.value)).value
        from bundle._get_stage_rows_to_add(_repository_id); -- FIXME
        */
end;
$$ language plpgsql;


create or replace function __commit_stage_rows( _repository_id uuid, new_commit_id uuid, parent_commit_id uuid ) returns meta.relation_id[] as $$
declare
    commit_relations meta.relation_id[];
    tmp jsonb;
begin
    if parent_commit_id is null then
        /*
         * First Commit
         * Set jsonb_rows to sort(stage_rows_to_add)
         */

        -- Compute topo-sorted commit_relations from stage_rows_to_add
        select bundle._topological_sort_relations(bundle._get_rowset_relations(stage_rows_to_add))
        from bundle.repository
        where id=_repository_id
        into commit_relations;

        raise debug '__commit_stage_rows(): topo-sorted relations are: %', commit_relations;

        -- Check for empty stage
        if array_length(commit_relations,1) is null then -- zero length array returns NULL! :/
            raise exception 'Stage is empty.  Aborting.';
        end if;

        -- write sorted stage_rows_to_add to commit.jsonb_rows
        update bundle.commit
        set jsonb_rows = (select jsonb_agg(r.row_id) from (
                select row_id
                from bundle.repository
                    cross join lateral jsonb_array_elements(stage_rows_to_add) row_id
                where id=_repository_id
                order by array_position(commit_relations, meta.row_id_to_relation_id(
                    case jsonb_typeof(row_id) when 'string' then (row_id #>> '{}')::meta.row_id else jsonb_populate_record(null::meta.row_id, row_id) end
                ))
            ) r
        ) where id = new_commit_id;

        /*
        old:
        update bundle.commit set jsonb_rows = stage_rows_to_add
        from bundle.repository
        where repository.id=_repository_id and commit.id = new_commit_id;
        */

    else

        /*
         * not first commit
         * jsonb_rows is parent commit's rows + stage_rows_to_add - stage_rows_to_remove
         */

        -- set to parent rows + stage_rows_to_add
        update bundle.commit set jsonb_rows = parent_rows
        from (
            select jsonb_rows || stage_rows_to_add as parent_rows
            from bundle.commit
                join bundle.repository on commit.repository_id = repository.id
            where commit.id = parent_commit_id
        ) f
        where commit.id = new_commit_id;

        -- get topo sorted relations *before* row removal/rewrite
        select bundle._topological_sort_relations(bundle._get_rowset_relations(jsonb_rows))
        from bundle.commit
        where id=new_commit_id
        into commit_relations;

        -- rewrite, removing rows and sorting
        update bundle.commit
        set jsonb_rows = coalesce(( -- catch nulls
            select jsonb_agg(f.elem) from (
                select a.elem from jsonb_array_elements(jsonb_rows) a(elem)
                left join (
                    select jsonb_array_elements(stage_rows_to_remove)
                    from bundle.repository where id=_repository_id
                ) x(rem) on x.rem = a.elem
                where x.rem is null
                order by array_position(commit_relations, meta.row_id_to_relation_id(
                    case jsonb_typeof(a.elem) when 'string' then (a.elem #>> '{}')::meta.row_id else jsonb_populate_record(null::meta.row_id, a.elem) end
                ))
            ) f
        ), '[]'::jsonb)
        where id = new_commit_id;

    end if;

    -- get topo-sorted commit_relations
    select bundle._topological_sort_relations(bundle._get_rowset_relations(jsonb_rows))
    from bundle.commit
    where id=new_commit_id
    into commit_relations;

    raise notice '    - commit_relations: %', commit_relations;

    return commit_relations;
end;
$$ language plpgsql;

--
-- __commit_stage_fields
--

create or replace function __commit_stage_fields( _repository_id uuid, new_commit_id uuid, parent_commit_id uuid, commit_relations meta.relation_id[] ) returns void as $$
declare
    rec record;
    rel meta.relation_id;
    stmt text;
    stmts text[] := '{}';
begin
    /*
    1. Set commit.jsonb_fields to repo.rows_to_add.fields
    2. If this is not the first commit:
        a) jsonb_fields += parent_commit.jsonb_fields - repo.rows_to_remove.fields
        b) Merge in repo.fields_to_change
    */

    -- no rows?  can occur if all rows are removed.
    if array_length(commit_relations, 1) is null then
        return;
    end if;

    /*
    1. Set commit.jsonb_fields to repo.rows_to_add.fields
    */

    -- for each relation in the commit
    foreach rel in array commit_relations loop
        -- create a SQL stmt that does this:
        -- for each row in the newly-created (incomplete) commit that is of this relation,
        -- select it's row_id as a text field, and all it's col:val pairs as a jsonb row object
        stmt := format('
(
    with row_ids as (
        select row_id, row_id::meta.row_id as row_id_typed
        from bundle.commit c
        cross join lateral jsonb_array_elements(c.jsonb_rows) row_id
        where c.id=%L
            and row_id->>''relation_name''=%L
    )
    select row_ids.row_id, bundle.row_to_jsonb_hash_obj(x, true) as row_obj
        from %I.%I x
            join row_ids on %s -- x.id::text = (row_ids.row_id_typed).pk_values[1]
)',
            new_commit_id,
            (rel).name,
            (rel).schema_name,
            (rel).name,
            meta._pk_stmt(
                bundle._get_trackable_relation_pk(rel),
                null,
                'x.%1$I::text = (row_ids.row_id)->''pk_values''->>(%3$s-1)'
            )
        );

        -- raise notice '__commit_fields stmt: %', stmt;
        stmts := stmts || stmt;
    end loop;


    -- create a statement that does this:
    -- update the newly created commit's jsonb_field to contain
    -- the aggregate of all the above stmts (one per relation) into a single jsonb object

    stmt := format('update bundle.commit c set jsonb_fields = coalesce(
        (select jsonb_object_agg (row_id::text, row_obj) from (


%s


        ) x),
        ''{}''::jsonb
    ) where c.id = %L',
        array_to_string(stmts, E'\n\nunion\n\n'),
        new_commit_id
    );

    -- raise notice 'FULL stmt: %', stmt;
    execute stmt;

    if parent_commit_id is not null then
        /*
         * NOT FIRST COMMIT
         */

        --
        -- parent commit fields - stage_rows_to_remove.fields
        --

        -- raise notice '    - applying (parent_commit - stage_rows_to_remove) fields @ % ...', bundle.clock_diff(start_time);
        update bundle.commit
        set jsonb_fields = jsonb_fields || parent_commit.parent_minus_removed_fields
        from (
            select jsonb_fields - (stage_rows_to_remove::text) as parent_minus_removed_fields
            from bundle.commit c
                join bundle.repository r on c.repository_id = r.id
            where c.id = parent_commit_id
        ) parent_commit
        where id = new_commit_id;


        --
        -- fields_to_change
        --

        with staged_fields as (
            select
                case jsonb_typeof(raw_field_id)
                    when 'string' then (raw_field_id #>> '{}')::meta.field_id
                    else jsonb_populate_record(null::meta.field_id, raw_field_id)
                end as field_id
            from bundle.repository
                cross join lateral jsonb_array_elements(stage_fields_to_change) raw_field_id
            where id = _repository_id
        ),
        commit_rows as (
            select
                case jsonb_typeof(raw_row_id)
                    when 'string' then (raw_row_id #>> '{}')::meta.row_id
                    else jsonb_populate_record(null::meta.row_id, raw_row_id)
                end as row_id,
                case jsonb_typeof(raw_row_id)
                    when 'string' then raw_row_id #>> '{}'
                    else raw_row_id::text
                end as row_key
            from bundle.commit c
                cross join lateral jsonb_array_elements(c.jsonb_rows) raw_row_id
            where c.id = new_commit_id
        ),
        field_values as (
            select
                staged_fields.field_id,
                commit_rows.row_id,
                commit_rows.row_key,
                db_fields.value_hash
            from staged_fields
                join commit_rows
                    on meta.field_id_to_row_id(staged_fields.field_id) = commit_rows.row_id
                join bundle._get_db_commit_rows(new_commit_id) existing_rows
                    on commit_rows.row_id = existing_rows.row_id
                join bundle._get_db_commit_fields(new_commit_id) db_fields
                    on staged_fields.field_id = db_fields.field_id
            where existing_rows.exists = true
        ),
        fields as (
            select
                row_key,
                jsonb_object_agg(
                    (field_id).column_name,
                    value_hash
                ) as fields_obj
            from field_values
            group by 1
        ),
        fields_obj as (
            select jsonb_object_agg(row_key, fields_obj) as obj from fields
        ),
        existing_field_keys as (
            select
                e.key,
                case when e.key like '{%'
                    then e.key::jsonb::meta.row_id
                    else e.key::meta.row_id
                end as row_id
            from bundle.commit c
                cross join lateral jsonb_each(c.jsonb_fields) e
            where c.id = new_commit_id
        ),
        stale_keys as (
            select coalesce(array_agg(distinct existing_field_keys.key), '{}'::text[]) as keys
            from existing_field_keys
                join (select distinct row_id, row_key from field_values) staged_rows
                    on existing_field_keys.row_id = staged_rows.row_id
            where existing_field_keys.key <> staged_rows.row_key
        )
        update bundle.commit set jsonb_fields = coalesce(
            bundle.jsonb_merge_recurse(
                jsonb_fields - stale_keys.keys,
                fields_obj.obj
            ),
            '{}'::jsonb
        )
        from fields_obj, stale_keys
        where commit.id = new_commit_id;

    end if;
end;
$$ language plpgsql;


--
-- commit()
--

create or replace function _commit(
    _repository_id uuid,
    _message text,
    _author_name text,
    _author_email text,
    parent_commit_id uuid default null
) returns uuid as $$
declare
    new_commit_id uuid;
    parent_commit_id uuid;
    commit_relations meta.relation_id[];
    _jsonb_rows jsonb := '[]';
--    _jsonb_fields jsonb := '{}';
--    _jsonb_fields_patch jsonb := '{}';
    first_commit boolean := false;
    start_time timestamp;
begin
    raise notice 'commit() - %', bundle._repository_name(_repository_id);

    start_time := clock_timestamp();

    -- repository exists
    if not bundle._repository_exists(_repository_id) then
        raise exception 'Repository with id % does not exist.', _repository_id;
    end if;

    -- if no parent_commit_id is supplied, use head pointer
    if parent_commit_id is null then
        select head_commit_id from bundle.repository where id = _repository_id into parent_commit_id;
    end if;

    -- if repository has no head commit and one is not supplied, either this is the first
    -- commit, or there is a problem
    if parent_commit_id is null then
        if bundle._repository_has_commits(_repository_id) then
            raise exception 'No parent_commit_id supplied, and repository''s head_commit_id is null.  Please specify a parent commit_id for this commit.';
        else
            raise notice 'First commit!';
            first_commit := true;
        end if;
    end if;

    raise notice '  - parent_commit_id: %', parent_commit_id;

    /*
     * create empty commit with metadata only
     */

    raise notice '  - Creating commit @ %', bundle.clock_diff(start_time);
    insert into bundle.commit (
        repository_id,
        parent_id,
        message,
        author_name,
        author_email
    ) values (
        _repository_id,
        parent_commit_id,
        _message,
        _author_name,
        _author_email
    ) returning id into new_commit_id;

    raise notice '  - New commit with id %', new_commit_id;

    raise notice '    - stage_blobs() @ %', bundle.clock_diff(start_time);
    perform bundle.__commit_stage_blobs(_repository_id, new_commit_id, parent_commit_id);

    raise notice '    - stage_rows() @ %', bundle.clock_diff(start_time);
    select bundle.__commit_stage_rows(_repository_id, new_commit_id, parent_commit_id) into commit_relations;

    raise notice '    - stage_fields() @ %', bundle.clock_diff(start_time);
    perform bundle.__commit_stage_fields(_repository_id, new_commit_id, parent_commit_id, commit_relations);

--    return new_commit_id;

    -- clear this repo's stage
    perform bundle._empty_stage(_repository_id);


    -- update head pointer, checkout pointer
    update bundle.repository set head_commit_id = new_commit_id, checkout_commit_id = new_commit_id where id=_repository_id;

    -- TODO: unset search_path

    raise notice '  - Done @ %', bundle.clock_diff(start_time);
    return new_commit_id;
end;
$$ language plpgsql;


create or replace function commit(
    repository_name text,
    message text,
    author_name text,
    author_email text,
    parent_commit_id uuid default null
) returns uuid as $$
begin
    if not bundle.repository_exists(repository_name) then
        raise exception 'Repository with name % does not exists', repository_name;
    end if;
    return bundle._commit(bundle.repository_id(repository_name), message, author_name, author_email, parent_commit_id);
end;
$$ language plpgsql;





/*
Objective:

- row-order for checkout
- external dependencies and the rows/bundles that satisfy them if any


Approach:
- for each row:
    - if is_meta(row_id)
        - Use pg_depend to get the list of objects this object depends on
        - Are those rows in this bundle?
    - else (it's data)
        - containing table, columns, and foreign keys
            - tables: select distinct meta.row_id_to_relation_id(row_id)
            - columns: select .....?
        - fk_dependency_rows:  What rows does it foreign key to?
            - boolean external: Are those rows in this bundle?
                - internal: affects order
                - external: affects commit dependencies
            - boolean deferrable: Is the foreign key deferrable?
            - on_delete: cascade, set null, set default, do nothing
1. Get the full list of dependant rows that rows on the stage have.  That could include:
  - data: rows that these rows foreign key to
  - data-tables: the tables and columns that the rows are in
  - objects: for any meta stuff, the pg_depend object(s) that it depends on

2. Determine whether or not this is an external dependency
  - is the dependency in this bundle?
    - no:
      - data: row foreign-keys to row not in this bundle
      - data-tables: this row is in a table created by some other bundle, if any.  Which bundle?
      - objects: a DDL object (non-table?) that
    - yes

*/

create or replace function bundle._topological_sort_relations( _relations meta.relation_id[] )
returns meta.relation_id[] as $$
declare
    start_time timestamp := clock_timestamp();
    edges bundle.schema_edge[];
    s meta.relation_id[];
    l meta.relation_id[] = '{}';
    n meta.relation_id;
    m meta.relation_id;
    m_edge bundle.schema_edge;
begin
    -- edges
    raise debug '  - Building edges @ % ...', clock_timestamp() - start_time;
    select array_agg(distinct row(r,meta.make_relation_id(fk.to_schema_name, fk.to_table_name))::bundle.schema_edge)
    from meta.foreign_key fk
        join unnest(_relations) r on (r).schema_name = fk.schema_name and (r).name = fk.table_name
    into edges;


    -- s
    raise debug '  - Building s @ % ...', clock_timestamp() - start_time;
    select array_agg(distinct srr)
    from unnest(_relations) as srr
       left join unnest(edges) as edge on srr = edge.to_relation_id
    where edge.to_relation_id is null
    into s;


    -- topo sort
    raise debug '  - Topological sort @ % ...', clock_timestamp() - start_time;
    while array_length(s, 1) > 0 loop
        n := s[1];
        s := s[2:];
        l := array_append(l, n);

        -- for each node m that n points to
        for m_edge in ( select * from unnest(edges) e where e.from_relation_id = n )
        loop
            m := m_edge.to_relation_id;
            edges := array_remove(edges, m_edge);
            if (select count(*) from unnest(edges) edge where edge.to_relation_id = m) < 1 then
                s := array_append(s, m);
            end if;
        end loop;
    end loop;
    if array_length(edges, 1) > 0 then
        raise exception 'Input graph contains cycles: %', edges;
        -- TODO: break cycles if possible w/ deferrable fks?
    end if;
    return bundle.array_reverse(l);
end
$$ language plpgsql;




/*

failed attempt #20:

create or replace function analyze_stage_deps( _repository_id uuid ) returns void as $$
declare
    start_time timestamp := clock_timestamp();

    stage_row_relations jsonb;
    r record;

    s jsonb = '[]';
    key text;
    value jsonb;
begin
    -- stage_row relations as jsonb object keys, value is empty array
    raise notice '  - Building stage_row_relations @ % ...', clock_timestamp() - start_time;
    select distinct jsonb_object_agg(meta.row_id_to_relation_id(row_id)::text, '[]'::jsonb)
        from bundle.stage_row_to_add
        where repository_id =  _repository_id
    into stage_row_relations;

    -- Add a foreign key object to the value array of stage_row_relations
    raise notice '  - Building stage_row_fts @ % ...', clock_timestamp() - start_time;
    for r in
    select u.rel_key as rel_key, fk.from_column_ids, fk.to_column_ids
        from jsonb_object_keys(stage_row_relations) u(rel_key)
        left join meta.foreign_key fk on u.rel_key = fk.table_id::text
    loop
        -- if this relation doesn't foreign key to anything
        if r.from_column_ids is null then
            raise notice '% fks to NOTHING.', r.rel_key;

        -- otherwise add the key to the stage_row_relations obj
        else
            stage_row_relations := jsonb_set(
                stage_row_relations,
                array[r.rel_key],
                stage_row_relations->(r.rel_key) || jsonb_build_object(
                    'relation_id', r.rel_key,
                    'from_column_ids', r.from_column_ids,
                    'to_column_ids', r.to_column_ids,
                    'to_relation_id', meta.row_id_to_relation_id(r.to_column_ids[1])::text
                )
            );
        end if;
    end loop;

    raise notice 'stage_row_relations: %', jsonb_pretty(stage_row_relations);

    -- build s
    for r in
        select srr.relation_id as from_relation_id, to_cols.props->>relation_id as to_relation_id
        from jsonb_object_keys(stage_row_relations) srr(relation_id)
            join jsonb_path_query(stage_row_relations,'$.*.*') to_cols(props)
                on to_cols.props->>'relation_id' = (srr.relation_id)
    loop
        raise notice 'r: %', r;
        raise notice 'r.from_relation_id: %', r.from_relation_id;
        raise notice 'r.to_relation_id: %', r.to_relation_id;

    end loop;

end
$$ language plpgsql;
*/
------------------------------------------------------------------------------
-- CHECKOUT
------------------------------------------------------------------------------

--
-- checkout_apply_hook
--
-- When a relation has an apply hook registered, after checkout restores rows
-- to that relation, the apply_function is called for each row. This enables
-- spec tables (like meta.function_spec) to apply their DDL to PostgreSQL.
--

create table checkout_apply_hook (
    id uuid not null default public.uuid_generate_v4() primary key,
    relation_id meta.relation_id not null unique,
    relation_pk_column_names text[] not null default '{id}',
    apply_function_id meta.function_id not null
);

create or replace function register_apply_hook(
    _relation_id meta.relation_id,
    _relation_pk_column_names text[],
    _apply_function_id meta.function_id
) returns uuid as $$
    insert into bundle.checkout_apply_hook (relation_id, relation_pk_column_names, apply_function_id)
    values (_relation_id, _relation_pk_column_names, _apply_function_id)
    returning id;
$$ language sql;

create or replace function unregister_apply_hook(_relation_id meta.relation_id) returns void as $$
    delete from bundle.checkout_apply_hook where relation_id = _relation_id;
$$ language sql;


--
-- _maybe_apply_row_hook()
--
-- Called after each row is checked out. If the row's relation has an apply hook,
-- calls the apply function for that row.
--

create or replace function _maybe_apply_row_hook(_row_id meta.row_id) returns void as $$
declare
    hook record;
    apply_stmt text;
begin
    -- Check if this relation has a hook
    select * into hook
    from bundle.checkout_apply_hook
    where (relation_id).schema_name = (_row_id).schema_name
      and (relation_id).name = (_row_id).relation_name;

    if not found then
        return;
    end if;

    -- Build and execute the apply function call
    -- Use type_sig as "column names" so _pk_stmt generates 'value'::type for each arg
    apply_stmt := format('select %I.%I(%s)',
        (hook.apply_function_id).schema_name,
        (hook.apply_function_id).name,
        meta._pk_stmt(
            (hook.apply_function_id).parameters,
            (_row_id).pk_values,
            '%2$L::%1$s',
            ', '
        )
    );

    raise debug '_maybe_apply_row_hook: %', apply_stmt;
    execute apply_stmt;
end;
$$ language plpgsql;


--
-- delete_checkout()
--

create or replace function _delete_checkout( _commit_id uuid ) returns void as $$
declare
    r record;
    pk_comparison_stmt text;
    stmt text;
    start_time timestamp := clock_timestamp();
begin
    -- TODO: check for uncommitted changes?
    -- TODO: there's a whole dependency chain to follow here.
    -- TODO: speed this up by grouping by relation, one delete stmt per relation

    for r in select * from bundle._get_commit_rows(_commit_id) order by _position desc loop
        if r.row_id is null then raise exception '_delete_checkout(): row_id is null'; end if;

        pk_comparison_stmt := meta._pk_stmt(r.row_id, '%1$I::text = %2$L');
        stmt := format ('delete from %I.%I where %s',
            (r.row_id).schema_name,
            (r.row_id).relation_name,
            pk_comparison_stmt);
        -- raise notice 'delete_checkout() stmt: %', stmt;
        execute stmt;
    end loop;

    raise notice '_delete_checkout() ... %s', bundle.clock_diff(start_time);
end;
$$ language plpgsql;

create or replace function delete_checkout( repository_name text ) returns void as $$
    select bundle._delete_checkout(bundle.checkout_commit_id(repository_name));
$$ language sql;


--
-- checkout()
--

create or replace function _checkout( _commit_id uuid, upsert boolean default false ) returns text as $$
declare
    _repository_id uuid;
    _head_commit_id uuid;
    _checkout_commit_id uuid;
    repository_name text;
    commit_message text;

    commit_row record;
    start_time timestamp := clock_timestamp();
begin
    -- commit exists
    if not bundle._commit_exists(_commit_id) then
        raise exception 'Commit with id % does not exist.', _commit_id;
    end if;

    -- propagate vars
    select r.id, r.name, r.head_commit_id, r.checkout_commit_id, c.message
    from bundle.commit c
        join bundle.repository r on r.id = c.repository_id
    where c.id = _commit_id
    into _repository_id, repository_name, _head_commit_id, _checkout_commit_id, commit_message;

    -- repo has no working changes
    /*
    if bundle._repository_has_working_changes(_repository_id) then
        raise exception 'Repository % has working changes (staged or offstage). Commit or reset changes before checkout.', bundle._repository_name(_repository_id);
    end if;
    */

    -- naive.
    -- TODO: single insert stmt per relation, smart dependency traversing etc
    for commit_row in
        select r.row_id, jsonb_object_agg((f.field_id).column_name, f.value_hash) as fields
        from bundle._get_commit_rows(_commit_id) r
            join bundle._get_commit_fields(_commit_id) f on meta.field_id_to_row_id(f.field_id) = r.row_id
        group by r.row_id, r._position
        order by r._position
    loop
        -- raise notice 'CHECKING OUT ROW: % ===> %', (commit_row.row_id)::text, (commit_row.fields)::text;
        perform bundle._checkout_row(commit_row.row_id, commit_row.fields, upsert);
        perform bundle._maybe_apply_row_hook(commit_row.row_id);
    end loop;

    -- Update repository checkout_commit_id
    update bundle.repository set checkout_commit_id = _commit_id where id = _repository_id;

    raise notice '_checkout() ... %s', bundle.clock_diff(start_time);
    return format('Commit %s was checked out.', _commit_id);
end
$$ language plpgsql;


create or replace function checkout( repository_name text, upsert boolean default false ) returns void as $$
declare
    _head_commit_id uuid;
    _repository_id uuid;
begin
    _repository_id := bundle.repository_id(repository_name);
    if _repository_id is null then
        raise notice 'Repository % does not exist.', repository_name;
    end if;

    if not bundle._repository_has_commits(_repository_id) then
        raise notice 'Repository % has no commits.', repository_name;
    end if;

    _head_commit_id = bundle._head_commit_id(_repository_id);
    if _repository_id is null then
        raise notice 'Repository with name % has no head_commit_id.', repository_name;
    end if;

    perform bundle._checkout(_head_commit_id, upsert);
end
$$ language plpgsql;


--
-- _checkout_row()
--
-- Checks out a single row given a row_id and a jsonb fields object
-- Uses jsonb_populate_record() for proper type conversion
-- Optional upsert parameter for conflict handling

create or replace function _checkout_row( row_id meta.row_id, fields jsonb, upsert boolean default false) returns void as $$
declare
    stmt text;
    unhashed_fields jsonb = '{}';
    field_key text;
    field_value text;
    unhashed_value text;
    column_type text;
    target_schema text;
    target_table text;
    cols text;
    pk_columns text[];
    conflict_clause text := '';
begin
    -- Extract schema and table names
    target_schema := (row_id).schema_name;
    target_table := (row_id).relation_name;

    raise debug '_checkout_row(): fields: %', fields;

    -- Unhash all field values to build the JSONB object
    -- Values are stored as JSON-serialized text, so we parse them back
    for field_key, field_value in select key, value from jsonb_each_text(fields) loop
        raise debug '   _checkout_row(): field %: %', field_key, field_value;

        unhashed_value := bundle.unhash(field_value);
        begin
            unhashed_fields := unhashed_fields || jsonb_build_object(field_key, unhashed_value::jsonb);
        exception when others then
            raise exception '_checkout_row(): Failed to parse field "%" value as JSON. Unhashed value: "%". Error: %',
                field_key, unhashed_value, SQLERRM;
        end;
    end loop;

    raise debug '_checkout_row(): unhashed fields: %', unhashed_fields;

    -- Get column list from JSONB keys
    select string_agg(quote_ident(key), ', ') into cols
    from jsonb_object_keys(unhashed_fields) as key;

    -- Build conflict clause if upsert is requested
    if upsert then
        -- Get PK column names directly from row_id
        pk_columns := (row_id).pk_column_names;

        if pk_columns is not null and array_length(pk_columns, 1) > 0 then
            conflict_clause := format(
                ' on conflict (%s) do update set %s',
                array_to_string(array(select quote_ident(col) from unnest(pk_columns) col), ', '),
                -- Build UPDATE SET clause (excluding PK columns)
                (select string_agg(
                    format('%I = excluded.%I', col, col),
                    ', '
                )
                from jsonb_object_keys(unhashed_fields) col
                where not (col = any(pk_columns)))
            );
        else
            raise warning '_checkout_row(): No primary key found in row_id for %.%, using INSERT only', target_schema, target_table;
        end if;
    end if;

    -- Build statement with optional conflict clause
    stmt := format($sql$
        insert into %I.%I (%s)
        select %s from jsonb_populate_record(null::%I.%I, %L)%s
    $sql$,
        target_schema,
        target_table,
        cols,
        cols,
        target_schema,
        target_table,
        unhashed_fields,
        conflict_clause
    );

    raise debug '    _checkout_row(): stmt: %', stmt;

    execute stmt;
    return;
exception
    when others then
        raise exception '_checkout_row() failed for %.%: %',
            target_schema, target_table, SQLERRM;
end
$$ language plpgsql;


--
-- undelete_row()
-- Restore a deleted row from the commit back to the database
--

create or replace function undelete_row(_repository_id uuid, _row_id meta.row_id)
returns void language plpgsql as $$
declare
    _checkout_commit_id uuid;
    _committed_fields jsonb;
begin
    -- Get checkout commit id
    select checkout_commit_id into _checkout_commit_id
    from bundle.repository where id = _repository_id;

    if _checkout_commit_id is null then
        raise exception 'Repository has no checkout commit';
    end if;

    -- Get committed field values for this row
    select jsonb_object_agg(
        (cf.field_id).column_name,
        cf.value_hash
    ) into _committed_fields
    from bundle._get_commit_fields(_checkout_commit_id) cf
    where (cf.field_id).schema_name = (_row_id).schema_name
      and (cf.field_id).relation_name = (_row_id).relation_name
      and (cf.field_id).pk_values = (_row_id).pk_values;

    if _committed_fields is null then
        raise exception 'Row not found in checkout commit';
    end if;

    -- Use _checkout_row with upsert=true to restore the row
    perform bundle._checkout_row(_row_id, _committed_fields, true);
end;
$$;


--
-- revert_row()
-- Restore a row to its committed state by checking out field values
--

create or replace function revert_row(_repository_id uuid, _row_id meta.row_id)
returns void language plpgsql as $$
declare
    _checkout_commit_id uuid;
    _committed_fields jsonb;
begin
    -- Get checkout commit id
    select checkout_commit_id into _checkout_commit_id
    from bundle.repository where id = _repository_id;

    if _checkout_commit_id is null then
        raise exception 'Repository has no checkout commit';
    end if;

    -- Get committed field values for this row
    select jsonb_object_agg(
        (cf.field_id).column_name,
        cf.value_hash
    ) into _committed_fields
    from bundle._get_commit_fields(_checkout_commit_id) cf
    where (cf.field_id).schema_name = (_row_id).schema_name
      and (cf.field_id).relation_name = (_row_id).relation_name
      and (cf.field_id).pk_values = (_row_id).pk_values;

    if _committed_fields is null then
        raise exception 'Row not found in checkout commit';
    end if;

    -- Use _checkout_row with upsert to restore the committed values
    perform bundle._checkout_row(_row_id, _committed_fields, true);
end;
$$;
------------------------------------------------------------------------------
-- BUNDLE STASH
-- Git-stash-like functionality for saving uncommitted changes
------------------------------------------------------------------------------

-- Table to store stashes
create table bundle.stash (
    id uuid primary key default public.uuid_generate_v4(),
    repository_id uuid not null references bundle.repository(id) on delete cascade,
    message text,
    created_at timestamptz not null default now(),

    -- Staged state (from repository.stage_*)
    stage_rows_to_add meta.row_id[] not null default '{}',
    stage_rows_to_remove meta.row_id[] not null default '{}',
    stage_fields_to_change meta.field_id[] not null default '{}',

    -- Offstage state
    offstage_tracked_rows_added meta.row_id[] not null default '{}',
    offstage_deleted_rows meta.row_id[] not null default '{}',
    offstage_updated_fields bundle.stash_field_value[] not null default '{}'
);

create index stash_repository_id_idx on bundle.stash(repository_id);
create index stash_created_at_idx on bundle.stash(created_at);


-- Extract row_id from field_id
create or replace function bundle._field_to_row(_fid meta.field_id)
returns meta.row_id as $$
    select meta.make_row_id(
        _fid->>'schema_name',
        _fid->>'relation_name',
        array(select jsonb_array_elements_text(_fid->'pk_column_names')),
        array(select jsonb_array_elements_text(_fid->'pk_values'))
    );
$$ language sql immutable;


-- Stash all uncommitted changes (staged + offstage)
-- Saves current state, then reverts to committed state
create or replace function bundle._stash(
    _repository_id uuid,
    _message text default null,
    _keep_changes boolean default false
) returns uuid as $$
declare
    _stash_id uuid;
    _repo record;
    _stage_rows_add meta.row_id[] := '{}';
    _stage_rows_remove meta.row_id[] := '{}';
    _stage_fields meta.field_id[] := '{}';
    _offstage_tracked meta.row_id[] := '{}';
    _offstage_deleted meta.row_id[] := '{}';
    _offstage_fields bundle.stash_field_value[] := '{}';
    _field record;
    _row record;
    _field_value text;
    _fid meta.field_id;
    _rid meta.row_id;
begin
    -- Get repository
    select * into _repo from bundle.repository where id = _repository_id;
    if _repo is null then
        raise exception 'Repository not found: %', _repository_id;
    end if;

    -- Convert staged jsonb arrays to typed arrays
    select coalesce(array_agg(r::meta.row_id), '{}')
    into _stage_rows_add
    from jsonb_array_elements(_repo.stage_rows_to_add) r;

    select coalesce(array_agg(r::meta.row_id), '{}')
    into _stage_rows_remove
    from jsonb_array_elements(_repo.stage_rows_to_remove) r;

    select coalesce(array_agg(f::meta.field_id), '{}')
    into _stage_fields
    from jsonb_array_elements(_repo.stage_fields_to_change) f;

    -- Collect offstage updated fields with their current values
    for _field in
        select field_id from bundle._get_offstage_updated_fields(_repository_id)
    loop
        _fid := _field.field_id;

        -- Get current value from database
        execute format(
            'select %I::text from %I.%I where %I = %L',
            _fid->>'column_name',
            _fid->>'schema_name',
            _fid->>'relation_name',
            (_fid->'pk_column_names'->>0),
            (_fid->'pk_values'->>0)
        ) into _field_value;

        _offstage_fields := array_append(
            _offstage_fields,
            row(_fid, _field_value)::bundle.stash_field_value
        );
    end loop;

    -- Collect offstage tracked rows added
    for _row in
        select row_id from bundle._get_tracked_rows_added(_repository_id)
    loop
        _offstage_tracked := array_append(_offstage_tracked, _row.row_id::meta.row_id);
    end loop;

    -- Collect offstage deleted rows
    for _rid in
        select bundle._get_offstage_deleted_rows(_repository_id)
    loop
        _offstage_deleted := array_append(_offstage_deleted, _rid);
    end loop;

    -- Create stash record
    insert into bundle.stash (
        repository_id,
        message,
        stage_rows_to_add,
        stage_rows_to_remove,
        stage_fields_to_change,
        offstage_tracked_rows_added,
        offstage_deleted_rows,
        offstage_updated_fields
    ) values (
        _repository_id,
        _message,
        _stage_rows_add,
        _stage_rows_remove,
        _stage_fields,
        _offstage_tracked,
        _offstage_deleted,
        _offstage_fields
    ) returning id into _stash_id;

    -- Only revert if not keeping changes
    if not _keep_changes then
        -- Revert to committed state (upsert=true to handle existing rows)
        perform bundle.checkout(_repo.name, true);

        -- Clear staging area
        update bundle.repository set
            stage_rows_to_add = '[]',
            stage_rows_to_remove = '[]',
            stage_fields_to_change = '[]'
        where id = _repository_id;
    end if;

    return _stash_id;
end;
$$ language plpgsql;


-- Convenience wrapper that takes repository name
create or replace function bundle.stash(
    _repository_name text,
    _message text default null,
    _keep_changes boolean default false
) returns uuid as $$
    select bundle._stash(
        (select id from bundle.repository where name = _repository_name),
        _message,
        _keep_changes
    );
$$ language sql;


-- Stash only changes for specific rows
-- Does NOT auto-revert (selective checkout would require more work)
create or replace function bundle._stash_rows(
    _repository_id uuid,
    _row_ids meta.row_id[],
    _message text default null,
    _keep_changes boolean default false
) returns uuid as $$
declare
    _stash_id uuid;
    _repo record;
    _stage_rows_add meta.row_id[] := '{}';
    _stage_rows_remove meta.row_id[] := '{}';
    _stage_fields meta.field_id[] := '{}';
    _offstage_tracked meta.row_id[] := '{}';
    _offstage_deleted meta.row_id[] := '{}';
    _offstage_fields bundle.stash_field_value[] := '{}';
    _field record;
    _row record;
    _field_value text;
    _fid meta.field_id;
    _rid meta.row_id;
    _all_stage_rows_add meta.row_id[];
    _all_stage_rows_remove meta.row_id[];
    _all_stage_fields meta.field_id[];
begin
    -- Get repository
    select * into _repo from bundle.repository where id = _repository_id;
    if _repo is null then
        raise exception 'Repository not found: %', _repository_id;
    end if;

    -- Convert staged jsonb arrays to typed arrays
    select coalesce(array_agg(r::meta.row_id), '{}')
    into _all_stage_rows_add
    from jsonb_array_elements(_repo.stage_rows_to_add) r;

    select coalesce(array_agg(r::meta.row_id), '{}')
    into _all_stage_rows_remove
    from jsonb_array_elements(_repo.stage_rows_to_remove) r;

    select coalesce(array_agg(f::meta.field_id), '{}')
    into _all_stage_fields
    from jsonb_array_elements(_repo.stage_fields_to_change) f;

    -- Filter staged rows to add
    select coalesce(array_agg(r), '{}')
    into _stage_rows_add
    from unnest(_all_stage_rows_add) r
    where r = any(_row_ids);

    -- Filter staged rows to remove
    select coalesce(array_agg(r), '{}')
    into _stage_rows_remove
    from unnest(_all_stage_rows_remove) r
    where r = any(_row_ids);

    -- Filter staged fields (by row)
    select coalesce(array_agg(f), '{}')
    into _stage_fields
    from unnest(_all_stage_fields) f
    where bundle._field_to_row(f) = any(_row_ids);

    -- Collect offstage updated fields (filtered) with their current values
    for _field in
        select field_id from bundle._get_offstage_updated_fields(_repository_id)
        where bundle._field_to_row(field_id) = any(_row_ids)
    loop
        _fid := _field.field_id;

        execute format(
            'select %I::text from %I.%I where %I = %L',
            _fid->>'column_name',
            _fid->>'schema_name',
            _fid->>'relation_name',
            (_fid->'pk_column_names'->>0),
            (_fid->'pk_values'->>0)
        ) into _field_value;

        _offstage_fields := array_append(
            _offstage_fields,
            row(_fid, _field_value)::bundle.stash_field_value
        );
    end loop;

    -- Collect offstage tracked rows added (filtered)
    for _row in
        select row_id from bundle._get_tracked_rows_added(_repository_id)
        where row_id::meta.row_id = any(_row_ids)
    loop
        _offstage_tracked := array_append(_offstage_tracked, _row.row_id::meta.row_id);
    end loop;

    -- Collect offstage deleted rows (filtered)
    for _rid in
        select bundle._get_offstage_deleted_rows(_repository_id)
    loop
        if _rid = any(_row_ids) then
            _offstage_deleted := array_append(_offstage_deleted, _rid);
        end if;
    end loop;

    -- Check if there's anything to stash
    if cardinality(_stage_rows_add) = 0 and
       cardinality(_stage_rows_remove) = 0 and
       cardinality(_stage_fields) = 0 and
       cardinality(_offstage_tracked) = 0 and
       cardinality(_offstage_deleted) = 0 and
       cardinality(_offstage_fields) = 0 then
        raise exception 'No changes found for specified rows';
    end if;

    -- Create stash record
    insert into bundle.stash (
        repository_id,
        message,
        stage_rows_to_add,
        stage_rows_to_remove,
        stage_fields_to_change,
        offstage_tracked_rows_added,
        offstage_deleted_rows,
        offstage_updated_fields
    ) values (
        _repository_id,
        _message,
        _stage_rows_add,
        _stage_rows_remove,
        _stage_fields,
        _offstage_tracked,
        _offstage_deleted,
        _offstage_fields
    ) returning id into _stash_id;

    -- Only remove from staging if not keeping changes
    if not _keep_changes then
        -- Remove stashed items from staging area (keep non-stashed items)
        update bundle.repository set
            stage_rows_to_add = (
                select coalesce(jsonb_agg(r), '[]')
                from jsonb_array_elements(stage_rows_to_add) r
                where not (r::meta.row_id = any(_stage_rows_add))
            ),
            stage_rows_to_remove = (
                select coalesce(jsonb_agg(r), '[]')
                from jsonb_array_elements(stage_rows_to_remove) r
                where not (r::meta.row_id = any(_stage_rows_remove))
            ),
            stage_fields_to_change = (
                select coalesce(jsonb_agg(f), '[]')
                from jsonb_array_elements(stage_fields_to_change) f
                where not (f::meta.field_id = any(_stage_fields))
            )
        where id = _repository_id;

        -- Note: Does NOT auto-revert. User must manually revert rows if desired.
        -- Selective checkout would need to restore individual rows from commit.
    end if;

    return _stash_id;
end;
$$ language plpgsql;


-- Convenience wrapper for selective stash (accepts jsonb array for endpoint compatibility)
create or replace function bundle.stash_rows(
    _repository_name text,
    _row_ids jsonb,
    _message text default null,
    _keep_changes boolean default false
) returns uuid as $$
declare
    _row_id_array meta.row_id[];
    _elem jsonb;
begin
    -- Convert jsonb array to meta.row_id[]
    for _elem in select * from jsonb_array_elements(_row_ids)
    loop
        _row_id_array := array_append(_row_id_array, _elem::meta.row_id);
    end loop;

    return bundle._stash_rows(
        (select id from bundle.repository where name = _repository_name),
        _row_id_array,
        _message,
        _keep_changes
    );
end;
$$ language plpgsql;


-- Pop the most recent stash (apply and remove)
create or replace function bundle._stash_pop(
    _repository_id uuid,
    _force boolean default false
) returns uuid as $$
declare
    _stash record;
    _sfv bundle.stash_field_value;
    _rid meta.row_id;
    _field_row_id meta.row_id;
    _conflicts text[];
    _current_value text;
begin
    -- Get most recent stash
    select * into _stash
    from bundle.stash
    where repository_id = _repository_id
    order by created_at desc
    limit 1;

    if _stash is null then
        raise exception 'No stash found for repository';
    end if;

    -- Check for conflicts: stash fields with different values from current uncommitted changes
    if not _force then
        _conflicts := '{}';
        foreach _sfv in array _stash.offstage_updated_fields
        loop
            -- Check if this field is also uncommitted
            if exists (
                select 1 from bundle._get_offstage_updated_fields(_repository_id)
                where field_id::jsonb = (((_sfv).field_id)::text::jsonb)
            ) then
                -- Get current value from database
                execute format(
                    'select %I::text from %I.%I where %I = %L',
                    (_sfv).field_id->>'column_name',
                    (_sfv).field_id->>'schema_name',
                    (_sfv).field_id->>'relation_name',
                    ((_sfv).field_id->'pk_column_names'->>0),
                    ((_sfv).field_id->'pk_values'->>0)
                ) into _current_value;

                -- Only conflict if values differ
                if _current_value is distinct from (_sfv).value then
                    _conflicts := array_append(_conflicts,
                        ((_sfv).field_id->>'schema_name') || '.' ||
                        ((_sfv).field_id->>'relation_name') || '.' ||
                        ((_sfv).field_id->>'column_name')
                    );
                end if;
            end if;
        end loop;

        if array_length(_conflicts, 1) > 0 then
            raise exception 'CONFLICT: You have uncommitted changes to: %. Applying this stash would overwrite them.', array_to_string(_conflicts, ', ');
        end if;
    end if;

    -- Restore offstage updated field values (skip if row no longer exists)
    foreach _sfv in array _stash.offstage_updated_fields
    loop
        -- Build row_id from field_id
        _field_row_id := jsonb_build_object(
            'schema_name', ((_sfv).field_id->>'schema_name'),
            'relation_name', ((_sfv).field_id->>'relation_name'),
            'pk_column_names', ((_sfv).field_id->'pk_column_names'),
            'pk_values', ((_sfv).field_id->'pk_values')
        )::meta.row_id;

        -- Only update if row still exists
        if meta.row_exists(_field_row_id) then
            execute format(
                'update %I.%I set %I = %L where %I = %L',
                ((_sfv).field_id->>'schema_name'),
                ((_sfv).field_id->>'relation_name'),
                ((_sfv).field_id->>'column_name'),
                (_sfv).value,
                (((_sfv).field_id->'pk_column_names'->>0)),
                (((_sfv).field_id->'pk_values'->>0))
            );
        end if;
    end loop;

    -- Restore offstage tracked rows (re-track them if not already tracked and row exists)
    foreach _rid in array _stash.offstage_tracked_rows_added
    loop
        -- Only track if row exists and not already tracked
        if meta.row_exists(_rid) and not bundle._is_newly_tracked(_repository_id, _rid) then
            perform bundle._track_untracked_row(_repository_id, _rid);
        end if;
    end loop;

    -- Remove stash
    delete from bundle.stash where id = _stash.id;

    return _stash.id;
end;
$$ language plpgsql;


-- Convenience wrapper
create or replace function bundle.stash_pop(
    _repository_name text,
    _force boolean default false
) returns uuid as $$
    select bundle._stash_pop(
        (select id from bundle.repository where name = _repository_name),
        _force
    );
$$ language sql;


-- Apply stash without removing (like git stash apply)
-- _force: overwrite all conflicts
-- _skip_conflicts: skip conflicting fields, apply safe ones
create or replace function bundle._stash_apply(
    _repository_id uuid,
    _stash_id uuid default null,
    _force boolean default false,
    _skip_conflicts boolean default false
) returns uuid as $$
declare
    _stash record;
    _sfv bundle.stash_field_value;
    _rid meta.row_id;
    _field_row_id meta.row_id;
    _conflicts text[];
    _conflict_fields jsonb[];
    _current_value text;
    _is_conflict boolean;
begin
    -- Get specified stash or most recent
    if _stash_id is not null then
        select * into _stash
        from bundle.stash
        where id = _stash_id and repository_id = _repository_id;
    else
        select * into _stash
        from bundle.stash
        where repository_id = _repository_id
        order by created_at desc
        limit 1;
    end if;

    if _stash is null then
        raise exception 'Stash not found';
    end if;

    -- Build list of conflicting fields
    _conflicts := '{}';
    _conflict_fields := '{}';
    foreach _sfv in array _stash.offstage_updated_fields
    loop
        -- Check if this field is also uncommitted
        if exists (
            select 1 from bundle._get_offstage_updated_fields(_repository_id)
            where field_id::jsonb = (((_sfv).field_id)::text::jsonb)
        ) then
            -- Get current value from database
            execute format(
                'select %I::text from %I.%I where %I = %L',
                (_sfv).field_id->>'column_name',
                (_sfv).field_id->>'schema_name',
                (_sfv).field_id->>'relation_name',
                ((_sfv).field_id->'pk_column_names'->>0),
                ((_sfv).field_id->'pk_values'->>0)
            ) into _current_value;

            -- Only conflict if values differ
            if _current_value is distinct from (_sfv).value then
                _conflicts := array_append(_conflicts,
                    ((_sfv).field_id->>'schema_name') || '.' ||
                    ((_sfv).field_id->>'relation_name') || '.' ||
                    ((_sfv).field_id->>'column_name')
                );
                _conflict_fields := array_append(_conflict_fields, ((_sfv).field_id)::jsonb);
            end if;
        end if;
    end loop;

    -- Handle conflicts based on mode
    if array_length(_conflicts, 1) > 0 and not _force and not _skip_conflicts then
        raise exception 'CONFLICT: You have uncommitted changes to: %. Applying this stash would overwrite them.', array_to_string(_conflicts, ', ');
    end if;

    -- Restore offstage updated field values (skip if row no longer exists)
    foreach _sfv in array _stash.offstage_updated_fields
    loop
        -- Check if this field is a conflict
        _is_conflict := ((_sfv).field_id)::jsonb = any(_conflict_fields);

        -- Skip conflicts if _skip_conflicts is true
        if _is_conflict and _skip_conflicts then
            continue;
        end if;

        -- Build row_id from field_id
        _field_row_id := jsonb_build_object(
            'schema_name', ((_sfv).field_id->>'schema_name'),
            'relation_name', ((_sfv).field_id->>'relation_name'),
            'pk_column_names', ((_sfv).field_id->'pk_column_names'),
            'pk_values', ((_sfv).field_id->'pk_values')
        )::meta.row_id;

        -- Only update if row still exists
        if meta.row_exists(_field_row_id) then
            execute format(
                'update %I.%I set %I = %L where %I = %L',
                ((_sfv).field_id->>'schema_name'),
                ((_sfv).field_id->>'relation_name'),
                ((_sfv).field_id->>'column_name'),
                (_sfv).value,
                (((_sfv).field_id->'pk_column_names'->>0)),
                (((_sfv).field_id->'pk_values'->>0))
            );
        end if;
    end loop;

    -- Restore offstage tracked rows (re-track them if not already tracked and row exists)
    foreach _rid in array _stash.offstage_tracked_rows_added
    loop
        -- Only track if row exists and not already tracked
        if meta.row_exists(_rid) and not bundle._is_newly_tracked(_repository_id, _rid) then
            perform bundle._track_untracked_row(_repository_id, _rid);
        end if;
    end loop;

    return _stash.id;
end;
$$ language plpgsql;


-- Convenience wrapper
create or replace function bundle.stash_apply(
    _repository_name text,
    _stash_id uuid default null,
    _force boolean default false,
    _skip_conflicts boolean default false
) returns uuid as $$
    select bundle._stash_apply(
        (select id from bundle.repository where name = _repository_name),
        _stash_id,
        _force,
        _skip_conflicts
    );
$$ language sql;


-- List stashes for a repository
create or replace function bundle.stash_list(
    _repository_name text
) returns table (
    id uuid,
    message text,
    created_at timestamptz,
    offstage_fields int,
    offstage_rows int,
    staged_fields int,
    staged_rows int
) as $$
    select
        s.id,
        s.message,
        s.created_at,
        cardinality(s.offstage_updated_fields),
        cardinality(s.offstage_tracked_rows_added) + cardinality(s.offstage_deleted_rows),
        cardinality(s.stage_fields_to_change),
        cardinality(s.stage_rows_to_add) + cardinality(s.stage_rows_to_remove)
    from bundle.stash s
    join bundle.repository r on r.id = s.repository_id
    where r.name = _repository_name
    order by s.created_at desc;
$$ language sql;


-- Show details of a specific stash
create or replace function bundle.stash_show(
    _stash_id uuid
) returns table (
    category text,
    item_type text,
    identifier text,
    value_preview text
) as $$
begin
    -- Offstage updated fields
    return query
    select
        'offstage'::text,
        'field'::text,
        ((sfv).field_id->>'schema_name') || '.' ||
            ((sfv).field_id->>'relation_name') || '.' ||
            ((sfv).field_id->>'column_name'),
        left((sfv).value, 80) || case when length((sfv).value) > 80 then '...' else '' end
    from bundle.stash s,
         unnest(s.offstage_updated_fields) sfv
    where s.id = _stash_id;

    -- Offstage tracked rows added
    return query
    select
        'offstage'::text,
        'row_add'::text,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from bundle.stash s,
         unnest(s.offstage_tracked_rows_added) rid
    where s.id = _stash_id;

    -- Offstage deleted rows
    return query
    select
        'offstage'::text,
        'row_delete'::text,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from bundle.stash s,
         unnest(s.offstage_deleted_rows) rid
    where s.id = _stash_id;

    -- Staged fields
    return query
    select
        'staged'::text,
        'field'::text,
        (fid->>'schema_name') || '.' || (fid->>'relation_name') || '.' || (fid->>'column_name'),
        null::text
    from bundle.stash s,
         unnest(s.stage_fields_to_change) fid
    where s.id = _stash_id;

    -- Staged rows to add
    return query
    select
        'staged'::text,
        'row_add'::text,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from bundle.stash s,
         unnest(s.stage_rows_to_add) rid
    where s.id = _stash_id;

    -- Staged rows to remove
    return query
    select
        'staged'::text,
        'row_remove'::text,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from bundle.stash s,
         unnest(s.stage_rows_to_remove) rid
    where s.id = _stash_id;
end;
$$ language plpgsql;


-- Add rows to an existing stash (captures current state of those rows)
create or replace function bundle.stash_add_rows(
    _stash_id uuid,
    _row_ids meta.row_id[]
) returns void as $$
declare
    _stash record;
    _repo record;
    _new_offstage_fields bundle.stash_field_value[] := '{}';
    _new_offstage_tracked meta.row_id[] := '{}';
    _new_offstage_deleted meta.row_id[] := '{}';
    _new_stage_rows_add meta.row_id[] := '{}';
    _new_stage_rows_remove meta.row_id[] := '{}';
    _new_stage_fields meta.field_id[] := '{}';
    _all_stage_rows_add meta.row_id[];
    _all_stage_rows_remove meta.row_id[];
    _all_stage_fields meta.field_id[];
    _field record;
    _row record;
    _fid meta.field_id;
    _rid meta.row_id;
    _field_value text;
begin
    -- Get stash
    select * into _stash from bundle.stash where id = _stash_id;
    if _stash is null then
        raise exception 'Stash not found: %', _stash_id;
    end if;

    -- Get repository
    select * into _repo from bundle.repository where id = _stash.repository_id;

    -- Convert staged jsonb arrays to typed arrays
    select coalesce(array_agg(r::meta.row_id), '{}')
    into _all_stage_rows_add
    from jsonb_array_elements(_repo.stage_rows_to_add) r;

    select coalesce(array_agg(r::meta.row_id), '{}')
    into _all_stage_rows_remove
    from jsonb_array_elements(_repo.stage_rows_to_remove) r;

    select coalesce(array_agg(f::meta.field_id), '{}')
    into _all_stage_fields
    from jsonb_array_elements(_repo.stage_fields_to_change) f;

    -- Filter staged rows to add (not already in stash)
    select coalesce(array_agg(r), '{}')
    into _new_stage_rows_add
    from unnest(_all_stage_rows_add) r
    where r = any(_row_ids)
      and not (r = any(_stash.stage_rows_to_add));

    -- Filter staged rows to remove (not already in stash)
    select coalesce(array_agg(r), '{}')
    into _new_stage_rows_remove
    from unnest(_all_stage_rows_remove) r
    where r = any(_row_ids)
      and not (r = any(_stash.stage_rows_to_remove));

    -- Filter staged fields (not already in stash)
    select coalesce(array_agg(f), '{}')
    into _new_stage_fields
    from unnest(_all_stage_fields) f
    where bundle._field_to_row(f) = any(_row_ids)
      and not (f = any(_stash.stage_fields_to_change));

    -- Collect offstage updated fields (filtered, not already in stash)
    for _field in
        select field_id from bundle._get_offstage_updated_fields(_stash.repository_id)
        where bundle._field_to_row(field_id) = any(_row_ids)
    loop
        _fid := _field.field_id;

        -- Skip if already in stash
        if exists (
            select 1 from unnest(_stash.offstage_updated_fields) f
            where (f).field_id = _fid
        ) then
            continue;
        end if;

        execute format(
            'select %I::text from %I.%I where %I = %L',
            _fid->>'column_name',
            _fid->>'schema_name',
            _fid->>'relation_name',
            (_fid->'pk_column_names'->>0),
            (_fid->'pk_values'->>0)
        ) into _field_value;

        _new_offstage_fields := array_append(
            _new_offstage_fields,
            row(_fid, _field_value)::bundle.stash_field_value
        );
    end loop;

    -- Collect offstage tracked rows added (filtered, not already in stash)
    for _row in
        select row_id from bundle._get_tracked_rows_added(_stash.repository_id)
        where row_id::meta.row_id = any(_row_ids)
          and not (row_id::meta.row_id = any(_stash.offstage_tracked_rows_added))
    loop
        _new_offstage_tracked := array_append(_new_offstage_tracked, _row.row_id::meta.row_id);
    end loop;

    -- Collect offstage deleted rows (filtered, not already in stash)
    for _rid in
        select bundle._get_offstage_deleted_rows(_stash.repository_id)
    loop
        if _rid = any(_row_ids) and not (_rid = any(_stash.offstage_deleted_rows)) then
            _new_offstage_deleted := array_append(_new_offstage_deleted, _rid);
        end if;
    end loop;

    -- Check if there's anything to add
    if cardinality(_new_stage_rows_add) = 0 and
       cardinality(_new_stage_rows_remove) = 0 and
       cardinality(_new_stage_fields) = 0 and
       cardinality(_new_offstage_tracked) = 0 and
       cardinality(_new_offstage_deleted) = 0 and
       cardinality(_new_offstage_fields) = 0 then
        raise exception 'No new changes found for specified rows';
    end if;

    -- Update stash with new items
    update bundle.stash set
        stage_rows_to_add = stage_rows_to_add || _new_stage_rows_add,
        stage_rows_to_remove = stage_rows_to_remove || _new_stage_rows_remove,
        stage_fields_to_change = stage_fields_to_change || _new_stage_fields,
        offstage_tracked_rows_added = offstage_tracked_rows_added || _new_offstage_tracked,
        offstage_deleted_rows = offstage_deleted_rows || _new_offstage_deleted,
        offstage_updated_fields = offstage_updated_fields || _new_offstage_fields
    where id = _stash_id;

    -- Remove newly stashed items from staging area
    update bundle.repository set
        stage_rows_to_add = (
            select coalesce(jsonb_agg(r), '[]')
            from jsonb_array_elements(stage_rows_to_add) r
            where not (r::meta.row_id = any(_new_stage_rows_add))
        ),
        stage_rows_to_remove = (
            select coalesce(jsonb_agg(r), '[]')
            from jsonb_array_elements(stage_rows_to_remove) r
            where not (r::meta.row_id = any(_new_stage_rows_remove))
        ),
        stage_fields_to_change = (
            select coalesce(jsonb_agg(f), '[]')
            from jsonb_array_elements(stage_fields_to_change) f
            where not (f::meta.field_id = any(_new_stage_fields))
        )
    where id = _stash.repository_id;
end;
$$ language plpgsql;


-- Remove rows from an existing stash
create or replace function bundle.stash_remove_rows(
    _stash_id uuid,
    _row_ids meta.row_id[]
) returns void as $$
declare
    _stash record;
    _removed_count int := 0;
    _new_stage_rows_add meta.row_id[];
    _new_stage_rows_remove meta.row_id[];
    _new_stage_fields meta.field_id[];
    _new_offstage_tracked meta.row_id[];
    _new_offstage_deleted meta.row_id[];
    _new_offstage_fields bundle.stash_field_value[];
begin
    -- Get stash
    select * into _stash from bundle.stash where id = _stash_id;
    if _stash is null then
        raise exception 'Stash not found: %', _stash_id;
    end if;

    -- Filter out specified rows from each array
    select coalesce(array_agg(r), '{}')
    into _new_stage_rows_add
    from unnest(_stash.stage_rows_to_add) r
    where not (r = any(_row_ids));

    select coalesce(array_agg(r), '{}')
    into _new_stage_rows_remove
    from unnest(_stash.stage_rows_to_remove) r
    where not (r = any(_row_ids));

    select coalesce(array_agg(f), '{}')
    into _new_stage_fields
    from unnest(_stash.stage_fields_to_change) f
    where not (bundle._field_to_row(f) = any(_row_ids));

    select coalesce(array_agg(r), '{}')
    into _new_offstage_tracked
    from unnest(_stash.offstage_tracked_rows_added) r
    where not (r = any(_row_ids));

    select coalesce(array_agg(r), '{}')
    into _new_offstage_deleted
    from unnest(_stash.offstage_deleted_rows) r
    where not (r = any(_row_ids));

    select coalesce(array_agg(f), '{}')
    into _new_offstage_fields
    from unnest(_stash.offstage_updated_fields) f
    where not (bundle._field_to_row((f).field_id) = any(_row_ids));

    -- Count removed items
    _removed_count := (cardinality(_stash.stage_rows_to_add) - cardinality(_new_stage_rows_add))
                    + (cardinality(_stash.stage_rows_to_remove) - cardinality(_new_stage_rows_remove))
                    + (cardinality(_stash.stage_fields_to_change) - cardinality(_new_stage_fields))
                    + (cardinality(_stash.offstage_tracked_rows_added) - cardinality(_new_offstage_tracked))
                    + (cardinality(_stash.offstage_deleted_rows) - cardinality(_new_offstage_deleted))
                    + (cardinality(_stash.offstage_updated_fields) - cardinality(_new_offstage_fields));

    if _removed_count = 0 then
        raise exception 'No matching rows found in stash';
    end if;

    -- Update stash
    update bundle.stash set
        stage_rows_to_add = _new_stage_rows_add,
        stage_rows_to_remove = _new_stage_rows_remove,
        stage_fields_to_change = _new_stage_fields,
        offstage_tracked_rows_added = _new_offstage_tracked,
        offstage_deleted_rows = _new_offstage_deleted,
        offstage_updated_fields = _new_offstage_fields
    where id = _stash_id;

    -- If stash is now empty, delete it
    if cardinality(_new_stage_rows_add) = 0 and
       cardinality(_new_stage_rows_remove) = 0 and
       cardinality(_new_stage_fields) = 0 and
       cardinality(_new_offstage_tracked) = 0 and
       cardinality(_new_offstage_deleted) = 0 and
       cardinality(_new_offstage_fields) = 0 then
        delete from bundle.stash where id = _stash_id;
        raise notice 'Stash is now empty and has been deleted';
    end if;
end;
$$ language plpgsql;


-- Drop a stash without applying
create or replace function bundle.stash_drop(
    _stash_id uuid
) returns void as $$
    delete from bundle.stash where id = _stash_id;
$$ language sql;


-- Clear all stashes for a repository
create or replace function bundle.stash_clear(
    _repository_name text
) returns int as $$
declare
    _count int;
begin
    delete from bundle.stash
    where repository_id = (select id from bundle.repository where name = _repository_name);
    get diagnostics _count = row_count;
    return _count;
end;
$$ language plpgsql;


-- Get all uncommitted changes for a repository (for stash row selector UI)
create or replace function bundle.uncommitted_changes(
    _repository_name text
) returns table (
    category text,
    item_type text,
    row_id meta.row_id,
    identifier text,
    value_preview text
) as $$
declare
    _repository_id uuid;
    _repo record;
begin
    select id into _repository_id from bundle.repository where name = _repository_name;
    select * into _repo from bundle.repository where id = _repository_id;

    -- Staged rows to add
    return query
    select
        'staged'::text,
        'row_add'::text,
        rid::meta.row_id,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from jsonb_array_elements(_repo.stage_rows_to_add) rid;

    -- Staged rows to remove
    return query
    select
        'staged'::text,
        'row_remove'::text,
        rid::meta.row_id,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from jsonb_array_elements(_repo.stage_rows_to_remove) rid;

    -- Staged fields to change
    return query
    select
        'staged'::text,
        'field'::text,
        bundle._field_to_row(fid::meta.field_id),
        (fid->>'schema_name') || '.' || (fid->>'relation_name') || '.' || (fid->>'column_name'),
        null::text
    from jsonb_array_elements(_repo.stage_fields_to_change) fid;

    -- Offstage tracked rows added
    return query
    select
        'offstage'::text,
        'row_add'::text,
        r.row_id,
        (r.row_id->>'schema_name') || '.' || (r.row_id->>'relation_name') || ':' || (r.row_id->'pk_values'->>0),
        null::text
    from bundle._get_tracked_rows_added(_repository_id) r;

    -- Offstage deleted rows
    return query
    select
        'offstage'::text,
        'row_delete'::text,
        rid,
        (rid->>'schema_name') || '.' || (rid->>'relation_name') || ':' || (rid->'pk_values'->>0),
        null::text
    from bundle._get_offstage_deleted_rows(_repository_id) rid;

    -- Offstage updated fields
    return query
    select
        'offstage'::text,
        'field'::text,
        bundle._field_to_row(f.field_id),
        (f.field_id->>'schema_name') || '.' || (f.field_id->>'relation_name') || '.' || (f.field_id->>'column_name'),
        null::text
    from bundle._get_offstage_updated_fields(_repository_id) f;
end;
$$ language plpgsql;


-- Export a stash to portable JSON format
create or replace function bundle.stash_to_json(
    _stash_id uuid
) returns jsonb as $$
declare
    _stash record;
    _repo_name text;
    _offstage_fields_json jsonb;
begin
    -- Get stash and repository name
    select s.*, r.name as repository_name
    into _stash
    from bundle.stash s
    join bundle.repository r on r.id = s.repository_id
    where s.id = _stash_id;

    if _stash is null then
        raise exception 'Stash not found: %', _stash_id;
    end if;

    -- Convert stash_field_value array to jsonb array
    select coalesce(jsonb_agg(jsonb_build_object(
        'field_id', sfv.field_id,
        'value', sfv.value
    )), '[]'::jsonb)
    into _offstage_fields_json
    from unnest(_stash.offstage_updated_fields) sfv;

    return jsonb_build_object(
        'version', 1,
        'type', 'bundle.stash',
        'repository_name', _stash.repository_name,
        'message', _stash.message,
        'created_at', _stash.created_at,
        'stage_rows_to_add', to_jsonb(_stash.stage_rows_to_add),
        'stage_rows_to_remove', to_jsonb(_stash.stage_rows_to_remove),
        'stage_fields_to_change', to_jsonb(_stash.stage_fields_to_change),
        'offstage_tracked_rows_added', to_jsonb(_stash.offstage_tracked_rows_added),
        'offstage_deleted_rows', to_jsonb(_stash.offstage_deleted_rows),
        'offstage_updated_fields', _offstage_fields_json
    );
end;
$$ language plpgsql;


-- Import a stash from JSON format
create or replace function bundle.stash_from_json(
    _json jsonb
) returns uuid as $$
declare
    _repository_id uuid;
    _stash_id uuid;
    _offstage_fields bundle.stash_field_value[];
    _elem jsonb;
begin
    -- Validate required fields
    if _json->>'version' is null or (_json->>'version')::int != 1 then
        raise exception 'Unsupported or missing stash version: %', coalesce(_json->>'version', 'NULL');
    end if;

    if _json->>'type' is null or _json->>'type' != 'bundle.stash' then
        raise exception 'Invalid or missing stash type: %', coalesce(_json->>'type', 'NULL');
    end if;

    if _json->>'repository_name' is null then
        raise exception 'Missing repository_name in stash JSON';
    end if;

    -- Find repository by name
    select id into _repository_id
    from bundle.repository
    where name = _json->>'repository_name';

    if _repository_id is null then
        raise exception 'Repository not found: %', _json->>'repository_name';
    end if;

    -- Convert offstage_updated_fields from jsonb to typed array
    _offstage_fields := '{}';
    for _elem in select * from jsonb_array_elements(_json->'offstage_updated_fields')
    loop
        _offstage_fields := array_append(
            _offstage_fields,
            row((_elem->>'field_id')::meta.field_id, _elem->>'value')::bundle.stash_field_value
        );
    end loop;

    -- Insert new stash
    insert into bundle.stash (
        repository_id,
        message,
        created_at,
        stage_rows_to_add,
        stage_rows_to_remove,
        stage_fields_to_change,
        offstage_tracked_rows_added,
        offstage_deleted_rows,
        offstage_updated_fields
    ) values (
        _repository_id,
        _json->>'message',
        coalesce((_json->>'created_at')::timestamptz, now()),
        (select coalesce(array_agg(r::meta.row_id), '{}') from jsonb_array_elements(_json->'stage_rows_to_add') r),
        (select coalesce(array_agg(r::meta.row_id), '{}') from jsonb_array_elements(_json->'stage_rows_to_remove') r),
        (select coalesce(array_agg(f::meta.field_id), '{}') from jsonb_array_elements(_json->'stage_fields_to_change') f),
        (select coalesce(array_agg(r::meta.row_id), '{}') from jsonb_array_elements(_json->'offstage_tracked_rows_added') r),
        (select coalesce(array_agg(r::meta.row_id), '{}') from jsonb_array_elements(_json->'offstage_deleted_rows') r),
        _offstage_fields
    ) returning id into _stash_id;

    return _stash_id;
end;
$$ language plpgsql;


-- Preview what will happen when applying a stash
-- Returns status: 'safe' (no conflict), 'identical' (same value), 'conflict' (different value)
create or replace function bundle.stash_preview_apply(_stash_id uuid)
returns table(
    status text,
    category text,
    item_type text,
    identifier text,
    row_id jsonb,
    field_name text,
    stash_value text,
    working_value text
) language plpgsql as $function$
declare
    _stash record;
    _repo record;
    _repository_id uuid;
begin
    select * into _stash from bundle.stash where id = _stash_id;
    if not found then
        raise exception 'Stash not found: %', _stash_id;
    end if;

    _repository_id := _stash.repository_id;
    select * into _repo from bundle.repository where id = _repository_id;

    -- 1. Offstage field changes
    return query
    with stash_fields as (
        select (sfv).field_id as field_id, (sfv).value as stash_val
        from unnest(_stash.offstage_updated_fields) sfv
    ),
    working_changed_fields as (
        select f.field_id from bundle._get_offstage_updated_fields(_repository_id) f
    )
    select
        case
            when wcf.field_id is null then 'safe'
            when sf.stash_val = meta.field_id_literal_value(sf.field_id::meta.field_id) then 'identical'
            else 'conflict'
        end::text,
        'offstage'::text,
        'field'::text,
        (sf.field_id->>'schema_name') || '.' || (sf.field_id->>'relation_name') || ':' || (sf.field_id->'pk_values'->>0),
        jsonb_build_object('schema_name', sf.field_id->>'schema_name', 'relation_name', sf.field_id->>'relation_name',
            'pk_column_names', sf.field_id->'pk_column_names', 'pk_values', sf.field_id->'pk_values'),
        sf.field_id->>'column_name',
        left(sf.stash_val, 100),
        case when wcf.field_id is not null then left(meta.field_id_literal_value(sf.field_id::meta.field_id), 100) else null end
    from stash_fields sf
    left join working_changed_fields wcf on sf.field_id = wcf.field_id;

    -- 2. Staged field changes
    return query
    with stash_fields as (select fid as field_id from unnest(_stash.stage_fields_to_change) fid),
    working_fields as (select fid as field_id from jsonb_array_elements(_repo.stage_fields_to_change) fid)
    select case when wf.field_id is null then 'safe' else 'identical' end::text, 'staged'::text, 'field'::text,
        (sf.field_id->>'schema_name') || '.' || (sf.field_id->>'relation_name') || ':' || (sf.field_id->'pk_values'->>0),
        jsonb_build_object('schema_name', sf.field_id->>'schema_name', 'relation_name', sf.field_id->>'relation_name',
            'pk_column_names', sf.field_id->'pk_column_names', 'pk_values', sf.field_id->'pk_values'),
        sf.field_id->>'column_name', null::text, null::text
    from stash_fields sf left join working_fields wf on sf.field_id = wf.field_id;

    -- 3. Offstage tracked rows added
    return query
    with stash_rows as (select rid as row_id from unnest(_stash.offstage_tracked_rows_added) rid),
    working_rows as (select r.row_id::jsonb as row_id from bundle._get_tracked_rows_added(_repository_id) r)
    select case when wr.row_id is null then 'safe' else 'identical' end::text, 'offstage'::text, 'row_add'::text,
        (sr.row_id->>'schema_name') || '.' || (sr.row_id->>'relation_name') || ':' || (sr.row_id->'pk_values'->>0),
        sr.row_id::jsonb, null::text, null::text, null::text
    from stash_rows sr left join working_rows wr on sr.row_id::jsonb = wr.row_id;

    -- 4. Staged rows to add
    return query
    with stash_rows as (select rid as row_id from unnest(_stash.stage_rows_to_add) rid),
    working_rows as (select rid as row_id from jsonb_array_elements(_repo.stage_rows_to_add) rid)
    select case when wr.row_id is null then 'safe' else 'identical' end::text, 'staged'::text, 'row_add'::text,
        (sr.row_id->>'schema_name') || '.' || (sr.row_id->>'relation_name') || ':' || (sr.row_id->'pk_values'->>0),
        sr.row_id::jsonb, null::text, null::text, null::text
    from stash_rows sr left join working_rows wr on sr.row_id = wr.row_id;

    -- 5. Offstage deleted rows
    return query
    with stash_rows as (select rid as row_id from unnest(_stash.offstage_deleted_rows) rid),
    working_rows as (select rid::jsonb as row_id from bundle._get_offstage_deleted_rows(_repository_id) rid)
    select case when wr.row_id is null then 'safe' else 'identical' end::text, 'offstage'::text, 'row_delete'::text,
        (sr.row_id->>'schema_name') || '.' || (sr.row_id->>'relation_name') || ':' || (sr.row_id->'pk_values'->>0),
        sr.row_id::jsonb, null::text, null::text, null::text
    from stash_rows sr left join working_rows wr on sr.row_id::jsonb = wr.row_id;

    -- 6. Staged rows to remove
    return query
    with stash_rows as (select rid as row_id from unnest(_stash.stage_rows_to_remove) rid),
    working_rows as (select rid as row_id from jsonb_array_elements(_repo.stage_rows_to_remove) rid)
    select case when wr.row_id is null then 'safe' else 'identical' end::text, 'staged'::text, 'row_remove'::text,
        (sr.row_id->>'schema_name') || '.' || (sr.row_id->>'relation_name') || ':' || (sr.row_id->'pk_values'->>0),
        sr.row_id::jsonb, null::text, null::text, null::text
    from stash_rows sr left join working_rows wr on sr.row_id = wr.row_id;
end;
$function$;


-- Apply only selected items from a stash
-- _selected_items is a jsonb array of objects with: category, item_type, row_id, field_name
create or replace function bundle.stash_apply_selected(
    _stash_id uuid,
    _selected_items jsonb,
    _force boolean default false
) returns void as $function$
declare
    _stash record;
    _repo record;
    _item jsonb;
    _sfv bundle.stash_field_value;
    _rid meta.row_id;
    _field_id meta.field_id;
    _field_row_id meta.row_id;
    _current_value text;
begin
    -- Get stash
    select * into _stash from bundle.stash where id = _stash_id;
    if _stash is null then
        raise exception 'Stash not found: %', _stash_id;
    end if;

    select * into _repo from bundle.repository where id = _stash.repository_id;

    -- Process each selected item
    for _item in select * from jsonb_array_elements(_selected_items)
    loop
        if _item->>'item_type' = 'field' then
            -- Find the matching field in stash
            foreach _sfv in array _stash.offstage_updated_fields
            loop
                _field_row_id := jsonb_build_object(
                    'schema_name', ((_sfv).field_id->>'schema_name'),
                    'relation_name', ((_sfv).field_id->>'relation_name'),
                    'pk_column_names', ((_sfv).field_id->'pk_column_names'),
                    'pk_values', ((_sfv).field_id->'pk_values')
                )::meta.row_id;

                -- Check if this field matches the selected item
                if (_sfv).field_id->>'column_name' = _item->>'field_name' and
                   _field_row_id::jsonb = _item->'row_id' then

                    -- Check for conflict if not forcing
                    if not _force then
                        if exists (
                            select 1 from bundle._get_offstage_updated_fields(_stash.repository_id)
                            where field_id::jsonb = (((_sfv).field_id)::text::jsonb)
                        ) then
                            execute format(
                                'select %I::text from %I.%I where %I = %L',
                                (_sfv).field_id->>'column_name',
                                (_sfv).field_id->>'schema_name',
                                (_sfv).field_id->>'relation_name',
                                ((_sfv).field_id->'pk_column_names'->>0),
                                ((_sfv).field_id->'pk_values'->>0)
                            ) into _current_value;

                            if _current_value is distinct from (_sfv).value then
                                raise exception 'CONFLICT: Field %.%.% has uncommitted changes',
                                    (_sfv).field_id->>'schema_name',
                                    (_sfv).field_id->>'relation_name',
                                    (_sfv).field_id->>'column_name';
                            end if;
                        end if;
                    end if;

                    -- Apply the field value
                    if meta.row_exists(_field_row_id) then
                        execute format(
                            'update %I.%I set %I = %L where %I = %L',
                            (_sfv).field_id->>'schema_name',
                            (_sfv).field_id->>'relation_name',
                            (_sfv).field_id->>'column_name',
                            (_sfv).value,
                            ((_sfv).field_id->'pk_column_names'->>0),
                            ((_sfv).field_id->'pk_values'->>0)
                        );
                    end if;

                    exit; -- Found the field, move to next item
                end if;
            end loop;

        elsif _item->>'item_type' = 'row_add' then
            -- Re-track the row if it exists and not already tracked
            _rid := (_item->'row_id')::meta.row_id;
            if meta.row_exists(_rid) and not bundle._is_newly_tracked(_stash.repository_id, _rid) then
                perform bundle._track_untracked_row(_stash.repository_id, _rid);
            end if;

        elsif _item->>'item_type' in ('row_delete', 'row_remove') then
            -- These are more complex - typically handled by staging area restoration
            -- For now, just note that the row was marked for deletion in the stash
            null;
        end if;
    end loop;
end;
$function$ language plpgsql;
------------------------------------------------------------------------------
-- FILESYSTEM IMPORT / EXPORT
------------------------------------------------------------------------------

--
-- get_repository_hashes()
--
-- Gets all blob hashes for the entire bundle, spanning all commit history
-- regardless of branches etc.
--

create or replace function _get_repository_hashes( _repository_id uuid )
returns table(hash text) as $$

    select distinct f.value_hash
    from bundle.commit c
        join lateral bundle._get_commit_fields(c.id) f on true
    where c.repository_id = _repository_id;

$$ language sql;


--
-- get_repository_blobs()
--
-- Gets all blob hashes and their values
--

create or replace function _get_repository_blobs( _repository_id uuid )
returns table(hash text, value text) as $$

    select b.hash, b.value
    from bundle._get_repository_hashes(_repository_id) h
        join bundle.blob b on h.hash = b.hash;

$$ language sql;

--
-- export_repository_export
--
-- generates a json text string that contains rows from:
--    - repository
--    - commit
--    - blob
-- scoped to a single repository.
--


-- TODO: validate _repository_id etc

create or replace function _get_repository_export( _repository_id uuid ) returns text as $$
select jsonb_pretty(jsonb_build_object(
    'repository', jsonb_build_object(
        'id', r.id,
        'name', r.name,
        'head_commit_id', r.head_commit_id
    ),
    'commits', (
        select jsonb_agg(to_jsonb(c))
        from bundle.commit c
        where c.repository_id = r.id
    ),
    'blobs', (
        select jsonb_agg(jsonb_build_object('hash', b.hash, 'value', b.value))
        from bundle._get_repository_blobs(r.id) b
    )
))
from bundle.repository r
where r.id = _repository_id;

$$ language sql;




create or replace function bundle.import_repository(bundle text, checkout boolean default false)
returns void as $$
declare
    bundle_jsonb jsonb := bundle::jsonb;
    repo_name text;
begin
    -- repository
    insert into bundle.repository (
        id,
        name,
        head_commit_id
    )
    select * from jsonb_to_record(bundle_jsonb->'repository')
    as x(
        id uuid,
        name text,
        head_commit_id uuid
    )
    on conflict (id) do nothing;

    -- blob
    -- Value is JSON-encoded text in the export, extract as text to get the original JSON text
    insert into bundle.blob (
        hash,
        value
    )
    select hash, value from jsonb_to_recordset(bundle_jsonb->'blobs')
    as x(
        hash text,
        value text
    )
    on conflict (hash) do nothing;

    -- commit
    insert into bundle.commit (
        id,
        parent_id,
        merge_parent_id,
        jsonb_rows,
        jsonb_fields,
        author_name,
        author_email,
        message,
        commit_time,
        repository_id
    )
    select * from jsonb_to_recordset(bundle_jsonb->'commits')
    as x(
        id uuid,
        parent_id uuid,
        merge_parent_id uuid,
        jsonb_rows jsonb,
        jsonb_fields jsonb,
        author_name text,
        author_email text,
        message text,
        commit_time timestamptz,
        repository_id uuid
    )
    on conflict (id) do nothing;

    -- perform checkout if requested
    if checkout then
        -- get the repository name from the imported data
        repo_name := bundle_jsonb->'repository'->>'name';
        if repo_name is not null then
            perform bundle.checkout(repo_name);
        end if;
    end if;

end;
$$ language plpgsql;

------------------------------------------------------------------------------
-- REMOTE BUNDLE OPERATIONS
------------------------------------------------------------------------------
-- Functions for pushing/pulling bundles to/from remote databases
------------------------------------------------------------------------------

--
-- push()
-- Push a bundle (repository + commits + data) to a remote database
--

create function push(
    remote_name text,
    repository_name text
) returns jsonb as $$
declare
    repo_id uuid;
    head_id uuid;
    repo_data jsonb;
    commits_data jsonb;
    tracked_rows jsonb;
    result jsonb;
begin
    -- Get repository
    select id, head_commit_id into repo_id, head_id
    from bundle.repository
    where name = repository_name;

    if repo_id is null then
        raise exception 'Repository % not found', repository_name;
    end if;

    if head_id is null then
        raise exception 'Repository % has no commits', repository_name;
    end if;

    -- 1. Get repository metadata as JSON
    select row_to_json(r.*)::jsonb into repo_data
    from bundle.repository r
    where id = repo_id;

    -- 2. Get all commits in history (walk from HEAD to root)
    select jsonb_agg(row_to_json(c.*)::jsonb) into commits_data
    from bundle.commit c
    where c.repository_id = repo_id
    order by c.commit_time asc;

    -- 3. Get all tracked row data
    -- For each row_id in tracked_rows_added, fetch the actual row
    select jsonb_agg(
        jsonb_build_object(
            'row_id', row_id::text,
            'data', (select row_to_json(r.*) from meta.row_select(row_id::meta.row_id) r)
        )
    ) into tracked_rows
    from jsonb_array_elements_text(
        (select tracked_rows_added from bundle.repository where id = repo_id)
    ) as row_id;

    -- 4. Push to remote
    -- Insert repository if it doesn't exist
    perform remote.row_insert(
        remote_name,
        meta.make_relation_id('bundle', 'repository'),
        repo_data
    );

    -- Insert all commits
    perform remote.rows_insert(
        remote_name,
        meta.make_relation_id('bundle', 'commit'),
        commits_data
    );

    -- Insert all tracked rows
    -- TODO: This needs to insert into the actual tables, not bundle tables
    -- We need to extract schema_name and relation_name from row_id

    return jsonb_build_object(
        'status', 'success',
        'repository', repository_name,
        'remote', remote_name,
        'head_commit', head_id,
        'commits_pushed', jsonb_array_length(commits_data),
        'rows_pushed', jsonb_array_length(tracked_rows)
    );
end;
$$ language plpgsql;


--
-- pull()
-- Pull a bundle (repository + commits + data) from a remote database
--

create function pull(
    remote_name text,
    repository_name text
) returns jsonb as $$
declare
    result jsonb;
begin
    -- TODO: Fetch repository metadata from remote
    -- TODO: Fetch all commits
    -- TODO: Fetch all tracked row data
    -- TODO: Fetch dependencies
    -- TODO: Checkout the bundle

    return jsonb_build_object(
        'status', 'success',
        'repository', repository_name,
        'remote', remote_name
    );
end;
$$ language plpgsql;
------------------------------------------------------------------------------
-- COMMIT MERGE
------------------------------------------------------------------------------
------------------------------------------------------------------------------
-- STATUS
------------------------------------------------------------------------------

/*
this would be nice:


                    io.bundle.core.repository
             +----------------------------------------+
             | 12 commits                             |
             +----------------------------------------+
 head commit | "Ignore rules." - 2024-12-25 4:20pm    |
    contents | (4) bundle.ignored_table               |
             | (3) bundle.ignored_schema              |
             +----------------------------------------+
          db | 0 tracked  | 0 deleted   | 0 updated   |
             +----------------------------------------+
       stage | 0 to added | 0 to remove | 0 to change |
             +----------------------------------------+


*/

--
-- _status()
--
-- Returns structured status data for one or all repositories
--

create or replace function _status(_repository_id uuid default null)
returns table (
    -- repository info
    repository_id uuid,
    repository_name text,

    -- commit info
    checkout_commit_id uuid,
    head_commit_id uuid,
    author_name text,
    author_email text,
    message text,
    commit_time timestamptz,

    -- state
    checked_out boolean,
    total_commits integer,
    head_branch_commits integer,
    head_commit_rows integer,

    -- offstage changes
    tracked_rows_added integer,
    offstage_deleted_rows integer,
    offstage_updated_fields integer,

    -- staged changes
    stage_rows_to_add integer,
    stage_rows_to_remove integer,
    stage_fields_to_change integer,

    -- row counts by relation (array of {relation_id, row_count})
    row_count_by_relation jsonb
)
as $$
    select
        r.id as repository_id,
        r.name as repository_name,

        -- commit info
        r.checkout_commit_id,
        r.head_commit_id,
        c.author_name,
        c.author_email,
        c.message,
        c.commit_time,

        -- state
        r.checkout_commit_id is not null as checked_out,
        (select count(*) from bundle.commit where repository_id = r.id) as total_commits,
        (select count(*) from bundle._get_commit_ancestry(r.head_commit_id)) as head_branch_commits,
        (select count(*) from bundle._get_head_commit_rows(r.id)) as head_commit_rows,

        -- offstage changes
        (select count(*) from bundle._get_tracked_rows_added(r.id)) as tracked_rows_added,
        (select count(*) from bundle._get_offstage_deleted_rows(r.id)) as offstage_deleted_rows,
        (select count(*) from bundle._get_offstage_updated_fields(r.id)) as offstage_updated_fields,

        -- staged changes
        (select count(*) from bundle._get_stage_rows_to_add(r.id)) as stage_rows_to_add,
        (select count(*) from bundle._get_stage_rows_to_remove(r.id)) as stage_rows_to_remove,
        (select count(*) from bundle._get_stage_fields_to_change(r.id)) as stage_fields_to_change,

        -- row counts by relation
        (select jsonb_agg(jsonb_build_object('relation_id', relation_id, 'row_count', row_count))
         from bundle._get_commit_row_count_by_relation(r.head_commit_id)
        ) as row_count_by_relation

    from bundle.repository r
        left join bundle.commit c on r.checkout_commit_id = c.id
    where _repository_id is null or r.id = _repository_id
    order by r.name;
$$ language sql;


--
-- status()
--
-- Returns formatted text status by calling _status() for data
--

create or replace function status(_repository_name text default null, detailed boolean default false) returns text as $$
    declare
        _repository_id uuid;
        s record;
        untracked_row_count integer;
        row_count_summary text;
        statii text := '';

        _tracked_rows_added text;
        _offstage_deleted_rows text;
        _offstage_updated_fields text;
        _stage_rows_to_add text;
        _stage_rows_to_remove text;
        _stage_fields_to_change text;
    begin
        -- get repository_id if name provided
        if _repository_name is not null then
            if not bundle.repository_exists(_repository_name) then
                raise exception 'Repository with name % does not exist.', _repository_name;
            end if;
            _repository_id := bundle.repository_id(_repository_name);
        end if;

        -- untracked rows (global count)
        select count(*) from bundle._get_untracked_rows() into untracked_row_count;
        statii := statii || format(E'+ Untracked rows: %s\n', untracked_row_count);
        statii := statii || format(E'+------------------------------------------------------------------------------\n');

        -- iterate over status data from _status()
        for s in select * from bundle._status(_repository_id) loop

            -- format row count summary from jsonb
            select string_agg(
                '(' || (elem->>'row_count') || ') '
                    || (elem->'relation_id'->>'schema_name') || '.'
                    || (elem->'relation_id'->>'name'),
                E'\n+             | '
            )
            from jsonb_array_elements(s.row_count_by_relation) elem
            into row_count_summary;

            -- main status display
            statii := statii || format(
'+ %s
+             +----------------------------------------------------------------
+             | %s commits, %s in this branch
+             +----------------------------------------------------------------
+    contents | %s
+    checkout | %s
+             +----------------------------------------------------------------
+          db | %s tracked %s
+             +----------------------------------------------------------------
+       stage | %s to add  %s
+             +----------------------------------------------------------------
+
',
                -- heading
                s.repository_name, s.total_commits, s.head_branch_commits,

                -- contents summary
                row_count_summary,

                -- checked out status
                case
                    when s.checked_out then
                        format('"%s" -- %s <%s> ', s.message, s.author_name, s.author_email)
                    else
                        'Not checked out.'
                end,

                -- off-stage changes status
                s.tracked_rows_added,
                case when s.checked_out then
                    format('| %s deleted   | %s updated',  s.offstage_deleted_rows, s.offstage_updated_fields)
                end,

                -- staged changes status
                s.stage_rows_to_add,
                case when s.checked_out then
                    format('| %s to remove | %s to change',  s.stage_rows_to_remove, s.stage_fields_to_change)
                end
            );

            -------------- detailed section ---------------------
            if detailed then
                select r.tracked_rows_added from bundle.repository r where r.id = s.repository_id into _tracked_rows_added;
                select string_agg(r::text, ',') from bundle._get_offstage_deleted_rows(s.repository_id) r into _offstage_deleted_rows;
                select string_agg(r::text, ',') from bundle._get_offstage_updated_fields(s.repository_id) r into _offstage_updated_fields;
                select r.stage_rows_to_add from bundle.repository r where r.id = s.repository_id into _stage_rows_to_add;
                select r.stage_rows_to_remove from bundle.repository r where r.id = s.repository_id into _stage_rows_to_remove;
                select r.stage_fields_to_change from bundle.repository r where r.id = s.repository_id into _stage_fields_to_change;

                statii := statii || E'\n OFFSTAGE:';
                statii := statii || E'\n track:' || coalesce(_tracked_rows_added, 'NULL');
                statii := statii || E'\n delete:' || coalesce(_offstage_deleted_rows, 'NULL');
                statii := statii || E'\n update:' || coalesce(_offstage_updated_fields, 'NULL');

                statii := statii || E'\n STAGE:';
                statii := statii || E'\n adds :' || coalesce(_stage_rows_to_add,'NULL');
                statii := statii || E'\n removes :' || coalesce(_stage_rows_to_remove, 'NULL');
                statii := statii || E'\n changes: ' || coalesce(_stage_fields_to_change, 'NULL');
            end if;

        end loop;

        statii := statii || format(E'+------------------------------------------------------------------------------\n');
        return statii;

    end;
$$ language plpgsql;


--
-- _get_commit_row_status()
--
-- Returns a summary of a commit's rows compared to the database state
-- Groups rows by row_id and shows whether they exist in db
--

create or replace function _get_commit_status(_commit_id uuid)
returns table (
    -- row-level
    row_id meta.row_id,
    row_state row_state,
    row_exists boolean,
    row_staged_to_remove boolean,

    -- field-level
    has_field_changes boolean,
    offstage_fields_updated jsonb,
    stage_fields_to_changes jsonb,

    -- schema-level
    has_schema_changes boolean,
    new_columns text[],
    deleted_columns text[]
)
as $$
    with repo as (
        select r.id
        from bundle.commit c
            join bundle.repository r on c.repository_id=r.id
        where c.id = _commit_id
    ),
    -- pre-compute offstage fields per row
    offstage_by_row as (
        select
            meta.field_id_to_row_id(ofu.field_id) as row_id,
            jsonb_object_agg(ofu.field_id::jsonb->>'column_name', true) as fields
        from repo r
        cross join lateral bundle._get_offstage_updated_fields(r.id) ofu
        group by meta.field_id_to_row_id(ofu.field_id)
    ),
    -- pre-compute stage fields per row
    stage_by_row as (
        select
            meta.field_id_to_row_id(sfc) as row_id,
            jsonb_object_agg(sfc::jsonb->>'column_name', true) as fields
        from repo r
        cross join lateral bundle._get_stage_fields_to_change(r.id) sfc
        group by meta.field_id_to_row_id(sfc)
    )


    -- commit


    select
        -- row-level
        dcr.row_id,
        'in_commit'::bundle.row_state as row_state,
        dcr.exists as row_exists,
        srtr.row_id is not null as row_staged_to_remove,

        -- field-level
        jsonb_agg(cf.value_hash) != jsonb_agg(dcf.value_hash) as has_field_changes,
        obr.fields as offstage_fields_updated,
        sbr.fields as stage_fields_to_changes,

        false as has_schema_changes,
        null::text[], -- TODO: compare db_value_hashes with commit_value_hashes for schema changes
        null::text[]

    from repo r,
        bundle._get_db_commit_rows(_commit_id) dcr
        left join bundle._get_stage_rows_to_remove(r.id) srtr
            on dcr.row_id = srtr.row_id
        join bundle._get_commit_fields(_commit_id) cf
            on dcr.row_id = meta.field_id_to_row_id(cf.field_id)
        left join bundle._get_db_commit_fields(_commit_id) dcf
            on cf.field_id = dcf.field_id
        left join offstage_by_row obr on dcr.row_id = obr.row_id
        left join stage_by_row sbr on dcr.row_id = sbr.row_id
    group by dcr.row_id, srtr.row_id, dcr.exists, obr.fields, sbr.fields


    union


    -- stage
    select
        srta.row_id,
        'staged' as row_state,
        srta.row_exists,
        false as row_staged_to_remove,

        null as has_field_changes,
        null::jsonb as offstage_fields_updated,
        null::jsonb as stage_fields_to_change,

        false as has_schema_changes,
        null as new_columns,
        null as deleted_columns

        from repo r,
        bundle._get_db_stage_rows_added(r.id) srta


    union


    -- tracked
    select
        tra.row_id,
        'tracked' as row_state,
        tra.row_exists,
        false as row_staged_to_remove,

        null as has_field_changes,
        null::jsonb as offstage_fields_updated,
        null::jsonb as stage_fields_to_change,

        false as has_schema_changes,
        null as new_columns,
        null as deleted_columns

        from repo r,
        bundle._get_db_tracked_rows_added(r.id) tra

$$ language sql;


--
-- _get_row_ancestry()
--
-- Returns all commits in the ancestry chain that contain a specific row
--

create or replace function _get_row_ancestry(
    _row_id meta.row_id,
    _commit_id uuid default null
)
returns table (
    commit_id uuid,
    parent_id uuid,
    message text,
    author_name text,
    commit_time timestamptz,
    depth integer
)
language sql stable as $$
    -- Walk the commit ancestry and return commits that contain this row
    with ancestry as (
        select
            c.id,
            c.parent_id,
            c.message,
            c.author_name,
            c.commit_time,
            ca.position as depth,
            c.jsonb_rows
        from bundle._get_commit_ancestry(
            coalesce(_commit_id, (
                select r.head_commit_id
                from bundle.commit bc
                join bundle.repository r on r.id = bc.repository_id
                where bc.id = _commit_id
                limit 1
            ), _commit_id)
        ) ca
        join bundle.commit c on c.id = ca.commit_id
    )
    select
        a.id as commit_id,
        a.parent_id,
        a.message,
        a.author_name,
        a.commit_time,
        a.depth
    from ancestry a
    where exists (
        select 1
        from jsonb_array_elements(a.jsonb_rows) as row_data
        where row_data->>'schema_name' = (_row_id::jsonb)->>'schema_name'
          and row_data->>'relation_name' = (_row_id::jsonb)->>'relation_name'
          and row_data->'pk_values' = (_row_id::jsonb)->'pk_values'
    )
    order by a.depth;
$$;
------------------------------------------------------------------------------
-- HISTORY / TIME TRAVEL functions
--
-- Retrieve historical row/field data from any commit.
------------------------------------------------------------------------------

--
-- _get_jsonb_row_at_commit()
--
-- Returns a single row as JSONB, with column names as keys and unhashed values.
--

create or replace function _get_jsonb_row_at_commit(_commit_id uuid, _row_id meta.row_id)
returns jsonb as $$
declare
    row_fields jsonb;
    result jsonb := '{}';
    col_name text;
    col_hash text;
    col_value text;
begin
    -- look up the row's field hashes from the commit
    select jsonb_fields->(_row_id::text)
    into row_fields
    from bundle.commit
    where id = _commit_id;

    -- row not found in commit
    if row_fields is null then
        return null;
    end if;

    -- unhash each field value
    -- values are stored as to_jsonb(val)::text, so parse back to jsonb
    for col_name, col_hash in select * from jsonb_each_text(row_fields) loop
        col_value := bundle.unhash(col_hash);
        if col_value is not null then
            result := result || jsonb_build_object(col_name, col_value::jsonb);
        else
            result := result || jsonb_build_object(col_name, null);
        end if;
    end loop;

    return result;
end;
$$ language plpgsql stable;


--
-- _get_jsonb_rows_at_commit()
--
-- Returns all rows from a relation at a specific commit as setof jsonb.
--

create or replace function _get_jsonb_rows_at_commit(_commit_id uuid, _relation_id meta.relation_id)
returns setof jsonb as $$
    select bundle._get_jsonb_row_at_commit(_commit_id, row_id)
    from bundle._get_commit_rows(_commit_id, _relation_id);
$$ language sql stable;


--
-- _get_jsonb_field_at_commit()
--
-- Returns a single field value (as text) at a specific commit.
--

create or replace function _get_jsonb_field_at_commit(_commit_id uuid, _field_id meta.field_id)
returns text as $$
declare
    _row_id meta.row_id;
    _column_name text;
    _hash text;
    _value text;
begin
    -- extract row_id and column_name from field_id
    _row_id := meta.field_id_to_row_id(_field_id);
    _column_name := _field_id->>'column_name';

    -- look up the hash
    select jsonb_fields->(_row_id::text)->>_column_name
    into _hash
    from bundle.commit
    where id = _commit_id;

    if _hash is null then
        return null;
    end if;

    -- unhash returns to_jsonb(val)::text, so parse back and extract text
    _value := bundle.unhash(_hash);
    if _value is null then
        return null;
    end if;

    return _value::jsonb #>> '{}';
end;
$$ language plpgsql stable;


------------------------------------------------------------------------------
-- RECORD-RETURNING FUNCTIONS
--
-- Use jsonb_populate_record to return actual table row types.
------------------------------------------------------------------------------

--
-- _get_row_at_commit()
--
-- Returns a single row as an actual record type matching the table structure.
-- Pass null::table_name as the third argument to specify the return type.
--
-- Example:
--   select * from bundle._get_row_at_commit(commit_id, row_id, null::widget.widget);
--

create or replace function _get_row_at_commit(
    _commit_id uuid,
    _row_id meta.row_id,
    _record anyelement
)
returns anyelement as $$
    select jsonb_populate_record(
        _record,
        bundle._get_jsonb_row_at_commit(_commit_id, _row_id)
    );
$$ language sql stable;


--
-- _get_rows_at_commit()
--
-- Returns all rows from a relation at a specific commit as actual records.
-- Pass null::table_name as the third argument to specify the return type.
--
-- Example:
--   select * from bundle._get_rows_at_commit(commit_id, relation_id, null::widget.widget);
--

create or replace function _get_rows_at_commit(
    _commit_id uuid,
    _relation_id meta.relation_id,
    _record anyelement
)
returns setof anyelement as $$
    select jsonb_populate_record(
        _record,
        bundle._get_jsonb_row_at_commit(_commit_id, row_id)
    )
    from bundle._get_commit_rows(_commit_id, _relation_id);
$$ language sql stable;


------------------------------------------------------------------------------
-- PUBLIC API
--
-- User-friendly functions that take bundle name + offset or timestamp.
------------------------------------------------------------------------------

--
-- get_row_at_commit() - by offset
--
-- Offset: 0 = HEAD, -1 = parent, -2 = grandparent, etc.
--

create or replace function get_row_at_commit(
    repository_name text,
    _offset int,
    _row_id meta.row_id,
    _record anyelement
)
returns anyelement as $$
declare
    _commit_id uuid;
begin
    if _offset > 0 then
        raise exception 'Offset must be 0 or negative (0 = HEAD, -1 = parent, etc.)';
    end if;

    select commit_id into _commit_id
    from bundle._get_commit_ancestry(bundle.head_commit_id(repository_name))
    where position = (1 - _offset);  -- position 1 = HEAD, 2 = parent, etc.

    if _commit_id is null then
        raise exception 'Commit not found at offset %', _offset;
    end if;

    return bundle._get_row_at_commit(_commit_id, _row_id, _record);
end;
$$ language plpgsql stable;


--
-- get_row_at_commit() - by timestamp
--
-- Returns row as it was at the most recent commit at or before the given time.
--

create or replace function get_row_at_commit(
    repository_name text,
    _time timestamptz,
    _row_id meta.row_id,
    _record anyelement
)
returns anyelement as $$
declare
    _commit_id uuid;
begin
    select c.id into _commit_id
    from bundle.commit c
    join bundle.repository r on c.repository_id = r.id
    where r.name = repository_name
      and c.commit_time <= _time
    order by c.commit_time desc
    limit 1;

    if _commit_id is null then
        raise exception 'No commit found at or before %', _time;
    end if;

    return bundle._get_row_at_commit(_commit_id, _row_id, _record);
end;
$$ language plpgsql stable;


--
-- get_rows_at_commit() - by offset
--

create or replace function get_rows_at_commit(
    repository_name text,
    _offset int,
    _relation_id meta.relation_id,
    _record anyelement
)
returns setof anyelement as $$
declare
    _commit_id uuid;
begin
    if _offset > 0 then
        raise exception 'Offset must be 0 or negative (0 = HEAD, -1 = parent, etc.)';
    end if;

    select commit_id into _commit_id
    from bundle._get_commit_ancestry(bundle.head_commit_id(repository_name))
    where position = (1 - _offset);

    if _commit_id is null then
        raise exception 'Commit not found at offset %', _offset;
    end if;

    return query select * from bundle._get_rows_at_commit(_commit_id, _relation_id, _record);
end;
$$ language plpgsql stable;


--
-- get_rows_at_commit() - by timestamp
--

create or replace function get_rows_at_commit(
    repository_name text,
    _time timestamptz,
    _relation_id meta.relation_id,
    _record anyelement
)
returns setof anyelement as $$
declare
    _commit_id uuid;
begin
    select c.id into _commit_id
    from bundle.commit c
    join bundle.repository r on c.repository_id = r.id
    where r.name = repository_name
      and c.commit_time <= _time
    order by c.commit_time desc
    limit 1;

    if _commit_id is null then
        raise exception 'No commit found at or before %', _time;
    end if;

    return query select * from bundle._get_rows_at_commit(_commit_id, _relation_id, _record);
end;
$$ language plpgsql stable;


--
-- get_field_at_commit() - by offset
--

create or replace function get_field_at_commit(
    repository_name text,
    _offset int,
    _field_id meta.field_id
)
returns text as $$
declare
    _commit_id uuid;
begin
    if _offset > 0 then
        raise exception 'Offset must be 0 or negative (0 = HEAD, -1 = parent, etc.)';
    end if;

    select commit_id into _commit_id
    from bundle._get_commit_ancestry(bundle.head_commit_id(repository_name))
    where position = (1 - _offset);

    if _commit_id is null then
        raise exception 'Commit not found at offset %', _offset;
    end if;

    return bundle._get_jsonb_field_at_commit(_commit_id, _field_id);
end;
$$ language plpgsql stable;


--
-- get_field_at_commit() - by timestamp
--

create or replace function get_field_at_commit(
    repository_name text,
    _time timestamptz,
    _field_id meta.field_id
)
returns text as $$
declare
    _commit_id uuid;
begin
    select c.id into _commit_id
    from bundle.commit c
    join bundle.repository r on c.repository_id = r.id
    where r.name = repository_name
      and c.commit_time <= _time
    order by c.commit_time desc
    limit 1;

    if _commit_id is null then
        raise exception 'No commit found at or before %', _time;
    end if;

    return bundle._get_jsonb_field_at_commit(_commit_id, _field_id);
end;
$$ language plpgsql stable;


------------------------------------------------------------------------------
-- ROW CHANGE ANCESTRY
--
-- Find commits where a specific row was changed.
-- Different from commit ancestry - only includes commits that modified the row.
------------------------------------------------------------------------------

--
-- _get_row_change_ancestry()
--
-- Returns commits where the given row was changed, walking back from a starting commit.
-- A row is "changed" if its field hashes differ from the parent commit
-- (including being added or deleted).
--
-- Returns change_number 1 as most recent change, with full commit metadata.
--

create or replace function _get_row_change_ancestry(
    _row_id meta.row_id,
    _starting_commit_id uuid
) returns table(
    commit_id uuid,
    change_number int,
    commit_time timestamptz,
    message text,
    author_name text,
    author_email text
) as $$
    with recursive ancestry as (
        -- Start with the starting commit
        select
            c.id as commit_id,
            c.parent_id,
            c.jsonb_fields->(_row_id::text) as row_fields,
            c.commit_time,
            c.message,
            c.author_name,
            c.author_email,
            1 as depth
        from bundle.commit c
        where c.id = _starting_commit_id

        union all

        -- Walk back through parents
        select
            c.id,
            c.parent_id,
            c.jsonb_fields->(_row_id::text),
            c.commit_time,
            c.message,
            c.author_name,
            c.author_email,
            a.depth + 1
        from bundle.commit c
        join ancestry a on c.id = a.parent_id
    ),
    changes as (
        -- Find commits where the row changed from its parent
        -- lead() gives the parent's row_fields (next depth = older commit)
        select
            a.commit_id,
            a.row_fields,
            a.commit_time,
            a.message,
            a.author_name,
            a.author_email,
            a.depth,
            lead(a.row_fields) over (order by a.depth) as parent_row_fields
        from ancestry a
    )
    select
        c.commit_id,
        row_number() over (order by c.depth)::int as change_number,
        c.commit_time,
        c.message,
        c.author_name,
        c.author_email
    from changes c
    where c.row_fields is distinct from c.parent_row_fields
    order by c.depth;
$$ language sql stable;


--
-- get_row_at_change()
--
-- Returns a row as it was at the Nth change to that row.
-- change_number 1 = most recent change, 2 = second most recent, etc.
--

create or replace function get_row_at_change(
    _repository_name text,
    _change_number int,
    _row_id meta.row_id,
    _record anyelement
) returns anyelement as $$
declare
    _commit_id uuid;
begin
    if _change_number < 1 then
        raise exception 'change_number must be >= 1 (1 = most recent change)';
    end if;

    select commit_id into _commit_id
    from bundle._get_row_change_ancestry(
        _row_id,
        bundle.head_commit_id(_repository_name)
    )
    where change_number = _change_number;

    if _commit_id is null then
        raise exception 'Change #% not found for this row', _change_number
            using hint = 'The row may not have that many changes in history';
    end if;

    return bundle._get_row_at_commit(_commit_id, _row_id, _record);
end;
$$ language plpgsql stable;


--
-- get_field_at_change()
--
-- Returns a field value as it was at the Nth change to that row.
-- change_number 1 = most recent change, 2 = second most recent, etc.
--

create or replace function get_field_at_change(
    _repository_name text,
    _change_number int,
    _field_id meta.field_id
) returns text as $$
declare
    _row_id meta.row_id;
    _commit_id uuid;
begin
    if _change_number < 1 then
        raise exception 'change_number must be >= 1 (1 = most recent change)';
    end if;

    _row_id := meta.field_id_to_row_id(_field_id);

    select commit_id into _commit_id
    from bundle._get_row_change_ancestry(
        _row_id,
        bundle.head_commit_id(_repository_name)
    )
    where change_number = _change_number;

    if _commit_id is null then
        raise exception 'Change #% not found for this row', _change_number
            using hint = 'The row may not have that many changes in history';
    end if;

    return bundle._get_jsonb_field_at_commit(_commit_id, _field_id);
end;
$$ language plpgsql stable;


------------------------------------------------------------------------------
-- VERSION RESOLVER
--
-- Parse version specifiers and return commit UUIDs.
------------------------------------------------------------------------------

--
-- resolve_version()
--
-- Parses a version specifier and returns the corresponding commit UUID.
--
-- Supported formats:
--   'latest' / 'head'  → HEAD commit
--   'head~3'           → 3 commits back from HEAD
--   '@2024-01-15'      → most recent commit at or before timestamp
--   '{uuid}'           → direct commit UUID (passthrough)
--   '1.0.0' (future)   → semver tag lookup
--

create or replace function resolve_version(
    _repository_name text,
    _version_spec text
) returns uuid as $$
declare
    _commit_id uuid;
    _offset int;
    _timestamp timestamptz;
begin
    -- Normalize to lowercase for keyword matching
    _version_spec := lower(trim(_version_spec));

    -- 'latest' or 'head' → HEAD commit
    if _version_spec in ('latest', 'head') then
        return bundle.head_commit_id(_repository_name);
    end if;

    -- 'head~N' → N commits back
    if _version_spec ~ '^head~[0-9]+$' then
        _offset := substring(_version_spec from 6)::int;

        select commit_id into _commit_id
        from bundle._get_commit_ancestry(bundle.head_commit_id(_repository_name))
        where position = (_offset + 1);  -- position 1 = HEAD, 2 = head~1, etc.

        if _commit_id is null then
            raise exception 'Commit not found at head~%', _offset
                using hint = 'The repository may not have that many commits';
        end if;

        return _commit_id;
    end if;

    -- '@timestamp' → commit at or before timestamp
    if _version_spec ~ '^@' then
        begin
            _timestamp := substring(_version_spec from 2)::timestamptz;
        exception when others then
            raise exception 'Invalid timestamp format: %', substring(_version_spec from 2)
                using hint = 'Use ISO 8601 format, e.g., @2024-01-15 or @2024-01-15T14:30:00Z';
        end;

        select c.id into _commit_id
        from bundle.commit c
        join bundle.repository r on c.repository_id = r.id
        where r.name = _repository_name
          and c.commit_time <= _timestamp
        order by c.commit_time desc
        limit 1;

        if _commit_id is null then
            raise exception 'No commit found at or before %', _timestamp;
        end if;

        return _commit_id;
    end if;

    -- Try parsing as UUID (direct commit reference)
    begin
        _commit_id := _version_spec::uuid;

        -- Verify it exists and belongs to this repository
        if not exists (
            select 1 from bundle.commit c
            join bundle.repository r on c.repository_id = r.id
            where c.id = _commit_id and r.name = _repository_name
        ) then
            raise exception 'Commit % not found in repository %', _version_spec, _repository_name;
        end if;

        return _commit_id;
    exception when invalid_text_representation then
        -- Not a UUID, continue to other formats
        null;
    end;

    -- Semver range: ^X.Y → highest version >= X.Y.0 and < (X+1).0.0
    if _version_spec ~ '^\^[0-9]+\.[0-9]+' then
        declare
            _major int;
            _minor int;
            _repo_id uuid;
        begin
            _major := (regexp_match(_version_spec, '^\^([0-9]+)'))[1]::int;
            _minor := (regexp_match(_version_spec, '^\^[0-9]+\.([0-9]+)'))[1]::int;

            select id into _repo_id from bundle.repository where name = _repository_name;

            -- Find highest version that satisfies ^X.Y (>= X.Y.0, < (X+1).0.0)
            select c.id into _commit_id
            from bundle.commit c
            where c.repository_id = _repo_id
              and c.version is not null
              and bundle.major(c.version) = _major
              and (bundle.major(c.version) > _major
                   or bundle.minor(c.version) >= _minor)
            order by c.version desc
            limit 1;

            if _commit_id is not null then
                return _commit_id;
            end if;
        end;
    end if;

    -- Exact semver: X.Y.Z → specific version
    if _version_spec ~ '^[0-9]+\.[0-9]+\.[0-9]+' then
        declare
            _repo_id uuid;
        begin
            select id into _repo_id from bundle.repository where name = _repository_name;

            select c.id into _commit_id
            from bundle.commit c
            where c.repository_id = _repo_id
              and c.version = _version_spec::bundle.version;

            if _commit_id is not null then
                return _commit_id;
            end if;
        end;
    end if;

    -- 'live' → return NULL (caller uses current database)
    if _version_spec = 'live' then
        return null;
    end if;

    raise exception 'Unknown version specifier: %', _version_spec
        using hint = 'Valid formats: live, latest, head, head~N, @timestamp, ^X.Y, X.Y.Z, or commit UUID';
end;
$$ language plpgsql stable;
--
-- ignore self, system catalogs, internal schemas, public
--

do $$
    declare r record;
    begin
        for r in
            -- ignore all internal tables, except for ignore rules, which are version-controlled.
            select * from meta.table where schema_name = 'bundle' and name not like 'ignored%'
        loop
            insert into bundle.ignored_table(relation_id) values (meta.make_relation_id(r.schema_name, r.name));
        end loop;

        -- ignore system catalogs, pg_temp*, pg_toast*
        for r in
            select * from meta.schema
                where name in ('pg_catalog','information_schema')
                    or name like 'pg_toast%'
                    or name like 'pg_temp%'
        loop
            insert into bundle.ignored_schema(schema_id) values (meta.make_schema_id(r.name));
        end loop;
    end;
$$ language plpgsql;


-- add meta catalog views to trackable nontable relations for schema-as-data version control

/* FIXME: -- one day we will track schema
do $$
    begin
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'schema'), '{id}'::text[]);
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'table'), '{id}'::text[]);
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'column'), '{id}'::text[]);
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'view'), '{id}'::text[]);
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'function'), '{id}'::text[]);
        perform bundle._track_nontable_relation(meta.make_relation_id('meta', 'foreign_key'), '{id}'::text[]);
    end;
$$ language plpgsql;
*/

-- track the ignore rules in the core bundle repo
do $$
    begin
        perform bundle.create_repository('io.bundle.core.repository');
        perform bundle.track_untracked_row('io.bundle.core.repository', meta.make_row_id('bundle','ignored_table','id',id::text)) from bundle.ignored_table;
        perform bundle.track_untracked_row('io.bundle.core.repository', meta.make_row_id('bundle','ignored_schema','id',id::text)) from bundle.ignored_schema;

        perform bundle.stage_tracked_rows('io.bundle.core.repository');
        perform bundle.commit('io.bundle.core.repository', 'Ignore rules.', 'Eric Hanson', 'eric@aquameta.com');
    end;
$$ language plpgsql;
--
-- ignore self, system catalogs, internal schemas, public
--

-- flag all tables as available for pg_dump to dump
select pg_catalog.pg_extension_config_dump('blob','');
select pg_catalog.pg_extension_config_dump('commit','');
select pg_catalog.pg_extension_config_dump('ignored_column','');
select pg_catalog.pg_extension_config_dump('ignored_row','');
select pg_catalog.pg_extension_config_dump('ignored_schema','');
select pg_catalog.pg_extension_config_dump('ignored_table','');
select pg_catalog.pg_extension_config_dump('not_ignored_row_stmt','');
select pg_catalog.pg_extension_config_dump('repository','');
select pg_catalog.pg_extension_config_dump('stage_field_to_change','');
select pg_catalog.pg_extension_config_dump('stage_row_to_add','');
select pg_catalog.pg_extension_config_dump('stage_row_to_remove','');
select pg_catalog.pg_extension_config_dump('trackable_nontable_relation','');
select pg_catalog.pg_extension_config_dump('trackable_relation','');
select pg_catalog.pg_extension_config_dump('tracked_query','');
select pg_catalog.pg_extension_config_dump('tracked_row_added','');
