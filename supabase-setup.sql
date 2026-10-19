-- =============================================================================
-- Générateur de nomenclature — mise en place de Supabase
--
-- À coller en entier dans Supabase > SQL Editor > New query, puis "Run".
-- Le script peut être relancé sans danger (create ... if not exists / or replace).
--
-- Modèle :
--   - un Projet est soit PERSO (team_id vide : visible par son seul créateur),
--     soit rattaché à une ÉQUIPE (visible par tous les membres de l'équipe) ;
--   - une équipe a un propriétaire et deux codes d'invitation :
--       * code "éditeur"  -> le nouveau membre peut modifier les projets
--       * code "lecteur"  -> le nouveau membre peut seulement les consulter
--   - seul le propriétaire de l'équipe peut supprimer un projet d'équipe,
--     gérer les membres, régénérer les codes ou supprimer l'équipe.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Profils (pour afficher l'e-mail des membres d'une équipe)
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- comptes déjà existants
insert into public.profiles (id, email)
select id, email from auth.users
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Équipes, codes d'invitation, membres
-- ---------------------------------------------------------------------------
create table if not exists public.teams (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 1 and 80),
  owner_id   uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- Les codes sont dans une table à part : seul le propriétaire peut les lire
-- (un éditeur ne doit pas pouvoir lire le code "éditeur" pour le redistribuer).
create table if not exists public.team_codes (
  team_id     uuid primary key references public.teams(id) on delete cascade,
  editor_code text not null unique,
  viewer_code text not null unique
);

create table if not exists public.team_members (
  team_id   uuid not null references public.teams(id) on delete cascade,
  user_id   uuid not null references public.profiles(id) on delete cascade,
  role      text not null check (role in ('owner', 'editor', 'viewer')),
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
create index if not exists team_members_user_idx on public.team_members (user_id);

-- ---------------------------------------------------------------------------
-- 3. Projets
-- ---------------------------------------------------------------------------
create table if not exists public.projets (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  team_id    uuid references public.teams(id) on delete cascade,
  title      text not null default '',
  data       jsonb not null default '{}'::jsonb,   -- db, dbGroups, bruts, produits...
  version    integer not null default 1,           -- verrou optimiste (voir trigger)
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists projets_owner_idx on public.projets (owner_id);
create index if not exists projets_team_idx  on public.projets (team_id);

-- ---------------------------------------------------------------------------
-- 4. Fonctions utilitaires (security definer : évitent la récursion des RLS)
-- ---------------------------------------------------------------------------
create or replace function public.team_role(p_team uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.team_members
  where team_id = p_team and user_id = auth.uid()
$$;

create or replace function public.is_team_member(p_team uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.team_members
    where team_id = p_team and user_id = auth.uid()
  )
$$;

create or replace function public.shares_team_with(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.team_members a
    join public.team_members b on a.team_id = b.team_id
    where a.user_id = auth.uid() and b.user_id = p_user
  )
$$;

-- Code de 8 caractères sans ambiguïté (pas de 0/O ni 1/I), tiré de gen_random_uuid()
-- (aléatoire cryptographique). On n'utilise que les 8 premiers octets "libres"
-- de deux UUID v4 (avant le nibble de version) et 256 % 32 = 0 : tirage uniforme.
create or replace function public.gen_team_code()
returns text
language plpgsql
volatile
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  hex text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12)
           || substr(replace(gen_random_uuid()::text, '-', ''), 1, 4);
  code text := '';
  i int;
begin
  for i in 0..7 loop
    code := code || substr(alphabet, 1 + (('x' || substr(hex, 2 * i + 1, 2))::bit(8)::int % 32), 1);
  end loop;
  return code;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Trigger sur projets : propriétaire immuable, version, date, déplacements
-- ---------------------------------------------------------------------------
create or replace function public.projets_before_update()
returns trigger
language plpgsql
as $$
begin
  -- le propriétaire ne change que via transfer_projet(), qui pose ce drapeau
  -- (valable pour ce seul projet et pour la transaction en cours)
  if new.owner_id is distinct from old.owner_id
     and coalesce(current_setting('app.transfer_projet', true), '') <> old.id::text then
    raise exception 'owner_id is immutable';
  end if;
  -- seul le créateur du projet peut le déplacer entre l'espace perso et les équipes
  if new.team_id is distinct from old.team_id and auth.uid() is distinct from old.owner_id then
    raise exception 'only the creator can move this project';
  end if;
  new.version    := old.version + 1;
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists projets_before_update on public.projets;
create trigger projets_before_update
  before update on public.projets
  for each row execute function public.projets_before_update();

-- ---------------------------------------------------------------------------
-- 6. Fonctions appelées par l'application (rpc)
-- ---------------------------------------------------------------------------
create or replace function public.create_team(p_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name';
  end if;
  insert into public.teams (name, owner_id) values (btrim(p_name), auth.uid())
    returning id into v_id;
  insert into public.team_members (team_id, user_id, role) values (v_id, auth.uid(), 'owner');
  insert into public.team_codes (team_id, editor_code, viewer_code)
    values (v_id, public.gen_team_code(), public.gen_team_code());
  return v_id;
end;
$$;

create or replace function public.join_team(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code     text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_team     uuid;
  v_role     text;
  v_existing text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select team_id, 'editor' into v_team, v_role from public.team_codes where editor_code = v_code;
  if v_team is null then
    select team_id, 'viewer' into v_team, v_role from public.team_codes where viewer_code = v_code;
  end if;
  if v_team is null then
    raise exception 'invalid_code';
  end if;

  select role into v_existing from public.team_members
    where team_id = v_team and user_id = auth.uid();

  if v_existing is null then
    insert into public.team_members (team_id, user_id, role) values (v_team, auth.uid(), v_role);
  elsif v_existing = 'viewer' and v_role = 'editor' then
    update public.team_members set role = 'editor'
      where team_id = v_team and user_id = auth.uid();
  else
    v_role := v_existing;  -- jamais de rétrogradation via un code
  end if;

  return json_build_object('team_id', v_team, 'role', v_role);
end;
$$;

create or replace function public.regenerate_team_code(p_team uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := public.gen_team_code();
begin
  if public.team_role(p_team) is distinct from 'owner' then
    raise exception 'forbidden';
  end if;
  if p_kind = 'editor' then
    update public.team_codes set editor_code = v_code where team_id = p_team;
  elsif p_kind = 'viewer' then
    update public.team_codes set viewer_code = v_code where team_id = p_team;
  else
    raise exception 'invalid_kind';
  end if;
  return v_code;
end;
$$;

-- Transfert de propriété d'un projet d'équipe : immédiat (sans acceptation),
-- le projet reste dans l'équipe, l'ancien propriétaire garde son rôle d'équipe
-- (éditeur). Réservé au propriétaire actuel, vers un membre éditeur/propriétaire
-- de la même équipe. p_version : verrou optimiste (null = pas de contrôle).
create or replace function public.transfer_projet(p_projet uuid, p_to uuid, p_version integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_proj    public.projets;
  v_role    text;
  v_version integer;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select * into v_proj from public.projets where id = p_projet for update;
  if not found or v_proj.owner_id is distinct from auth.uid() then
    raise exception 'forbidden';
  end if;
  if v_proj.team_id is null then
    raise exception 'not_a_team_project';
  end if;
  if public.team_role(v_proj.team_id) not in ('owner', 'editor') then
    raise exception 'forbidden';
  end if;
  if p_to is null or p_to = auth.uid() then
    raise exception 'same_owner';
  end if;

  select role into v_role from public.team_members
    where team_id = v_proj.team_id and user_id = p_to;
  if v_role is null then
    raise exception 'not_a_member';
  end if;
  if v_role not in ('owner', 'editor') then
    raise exception 'recipient_cannot_edit';
  end if;

  if p_version is not null and v_proj.version <> p_version then
    raise exception 'version_conflict';
  end if;

  perform set_config('app.transfer_projet', p_projet::text, true);
  update public.projets set owner_id = p_to where id = p_projet
    returning version into v_version;

  return json_build_object('version', v_version, 'owner_id', p_to);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Sécurité au niveau des lignes (RLS)
-- ---------------------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.teams        enable row level security;
alter table public.team_codes   enable row level security;
alter table public.team_members enable row level security;
alter table public.projets      enable row level security;

-- profiles : son propre profil + celui des personnes d'une même équipe
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.shares_team_with(id));

-- teams : visibles par leurs membres ; renommer / supprimer = propriétaire
drop policy if exists teams_select on public.teams;
create policy teams_select on public.teams for select to authenticated
  using (public.is_team_member(id));

drop policy if exists teams_update on public.teams;
create policy teams_update on public.teams for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists teams_delete on public.teams;
create policy teams_delete on public.teams for delete to authenticated
  using (owner_id = auth.uid());

-- team_codes : lecture réservée au propriétaire (écriture uniquement via les fonctions)
drop policy if exists team_codes_select on public.team_codes;
create policy team_codes_select on public.team_codes for select to authenticated
  using (public.team_role(team_id) = 'owner');

-- team_members : visibles par les membres ; le propriétaire change les rôles
-- (editor/viewer uniquement) et retire des membres ; chacun peut quitter l'équipe
-- sauf le propriétaire. Aucune policy d'insertion : on rejoint via join_team().
drop policy if exists team_members_select on public.team_members;
create policy team_members_select on public.team_members for select to authenticated
  using (public.is_team_member(team_id));

drop policy if exists team_members_update on public.team_members;
create policy team_members_update on public.team_members for update to authenticated
  using (public.team_role(team_id) = 'owner' and user_id <> auth.uid())
  with check (public.team_role(team_id) = 'owner' and role in ('editor', 'viewer'));

drop policy if exists team_members_delete on public.team_members;
create policy team_members_delete on public.team_members for delete to authenticated
  using (
    (public.team_role(team_id) = 'owner' and user_id <> auth.uid())
    or (user_id = auth.uid() and role <> 'owner')
  );

-- projets
--   lecture      : mes projets perso + les projets de mes équipes
--   création     : perso, ou dans une équipe où je suis propriétaire/éditeur
--   modification : mes projets perso, ou équipe où je suis propriétaire/éditeur
--   suppression  : mes projets perso, ou propriétaire de l'équipe
drop policy if exists projets_select on public.projets;
create policy projets_select on public.projets for select to authenticated
  using (
    (team_id is null and owner_id = auth.uid())
    or (team_id is not null and public.is_team_member(team_id))
  );

drop policy if exists projets_insert on public.projets;
create policy projets_insert on public.projets for insert to authenticated
  with check (
    owner_id = auth.uid()
    and (team_id is null or public.team_role(team_id) in ('owner', 'editor'))
  );

drop policy if exists projets_update on public.projets;
create policy projets_update on public.projets for update to authenticated
  using (
    (team_id is null and owner_id = auth.uid())
    or (team_id is not null and public.team_role(team_id) in ('owner', 'editor'))
  )
  with check (
    (team_id is null and owner_id = auth.uid())
    or (team_id is not null and public.team_role(team_id) in ('owner', 'editor'))
  );

drop policy if exists projets_delete on public.projets;
create policy projets_delete on public.projets for delete to authenticated
  using (
    (team_id is null and owner_id = auth.uid())
    or (team_id is not null and public.team_role(team_id) = 'owner')
  );

-- ---------------------------------------------------------------------------
-- 8. Droits : uniquement les utilisateurs connectés (jamais anon)
-- ---------------------------------------------------------------------------
revoke all on public.profiles, public.teams, public.team_codes,
              public.team_members, public.projets from anon;

revoke all on function public.create_team(text)               from public, anon;
revoke all on function public.join_team(text)                 from public, anon;
revoke all on function public.regenerate_team_code(uuid, text) from public, anon;
revoke all on function public.transfer_projet(uuid, uuid, integer) from public, anon;
grant execute on function public.create_team(text)               to authenticated;
grant execute on function public.join_team(text)                 to authenticated;
grant execute on function public.regenerate_team_code(uuid, text) to authenticated;
grant execute on function public.transfer_projet(uuid, uuid, integer) to authenticated;

-- =============================================================================
-- 9. Temps réel : les changements de projets/équipes sont poussés aux navigateurs
--    ouverts (les règles RLS ci-dessus s'appliquent : chacun ne reçoit que ce
--    qu'il a le droit de lire).
-- =============================================================================
do $$
begin
  begin
    alter publication supabase_realtime add table public.projets;
  exception when duplicate_object or undefined_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.team_members;
  exception when duplicate_object or undefined_object then null;
  end;
end $$;

-- =============================================================================
-- 10. Accès API (connecteur Claude) : jetons personnels
--
--   - Un jeton est créé depuis l'appli (Mon compte > Accès API), affiché UNE
--     seule fois ; seule son empreinte (sha-256) est stockée.
--   - Il agit avec les droits de son propriétaire : mes projets perso et ceux de
--     mes équipes ; en lecture seule dans une équipe où je suis lecteur.
--   - Portée "read" (consultation) ou "write" (consultation + modification).
--   - Révocable à tout moment, expiration facultative, 10 jetons actifs max.
--   - Les fonctions api_* ne sont appelables QUE par la clé de service, c'est-à-dire
--     par la fonction Edge "mecabench-mcp" (jamais depuis un navigateur).
-- =============================================================================
create table if not exists public.api_tokens (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users(id) on delete cascade,
  name         text not null,
  prefix       text not null,                 -- début du jeton, pour le reconnaître dans la liste
  token_hash   bytea not null unique,         -- sha-256 du jeton complet
  scope        text not null default 'write' check (scope in ('read', 'write')),
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at   timestamptz,
  revoked_at   timestamptz
);
create index if not exists api_tokens_user_idx on public.api_tokens (user_id);

alter table public.api_tokens enable row level security;
drop policy if exists api_tokens_select on public.api_tokens;
create policy api_tokens_select on public.api_tokens for select to authenticated
  using (user_id = auth.uid());

-- le navigateur ne lit que les colonnes d'affichage (jamais l'empreinte)
revoke all on public.api_tokens from anon, authenticated;
grant select (id, name, prefix, scope, created_at, last_used_at, expires_at, revoked_at)
  on public.api_tokens to authenticated;

create or replace function public.create_api_token(p_name text, p_scope text default 'write', p_days integer default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_name  text := btrim(coalesce(p_name, ''));
  v_token text;
  v_n     integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if v_name = '' or length(v_name) > 60 then raise exception 'invalid_name'; end if;
  if p_scope not in ('read', 'write') then raise exception 'invalid_scope'; end if;
  if p_days is not null and (p_days < 1 or p_days > 3650) then raise exception 'invalid_expiry'; end if;
  select count(*) into v_n from public.api_tokens
    where user_id = v_uid and revoked_at is null
      and (expires_at is null or expires_at > now());
  if v_n >= 10 then raise exception 'too_many_tokens'; end if;

  v_token := 'mbk_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.api_tokens (user_id, name, prefix, token_hash, scope, expires_at)
  values (v_uid, v_name, left(v_token, 8), sha256(convert_to(v_token, 'utf8')), p_scope,
          case when p_days is null then null else now() + make_interval(days => p_days) end);
  return v_token;
end;
$$;

create or replace function public.revoke_api_token(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.api_tokens set revoked_at = now()
    where id = p_id and user_id = auth.uid() and revoked_at is null;
  if not found then raise exception 'not_found'; end if;
end;
$$;

-- ---- fonctions internes de l'API (clé de service uniquement) ----------------
create or replace function public.api_auth(p_token text, p_need_write boolean default false)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare r public.api_tokens;
begin
  select * into r from public.api_tokens
    where token_hash = sha256(convert_to(coalesce(p_token, ''), 'utf8'));
  if not found or r.revoked_at is not null or (r.expires_at is not null and r.expires_at < now()) then
    raise exception 'invalid_token';
  end if;
  if p_need_write and r.scope <> 'write' then raise exception 'read_only_token'; end if;
  if r.last_used_at is null or r.last_used_at < now() - interval '1 minute' then
    update public.api_tokens set last_used_at = now() where id = r.id;
  end if;
  return r.user_id;
end;
$$;

-- rôle de p_uid sur un projet : 'owner' (perso), 'owner'/'editor'/'viewer' (équipe) ou null
create or replace function public.api_role(p_uid uuid, p_team uuid, p_owner uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_team is null then (case when p_owner = p_uid then 'owner' end)
    else (select role from public.team_members where team_id = p_team and user_id = p_uid)
  end
$$;

-- vérifie la forme des données d'un projet et complète les listes manquantes
create or replace function public.api_check_data(p_data jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare k text; d jsonb := coalesce(p_data, '{}'::jsonb);
begin
  if jsonb_typeof(d) <> 'object' then raise exception 'invalid_data'; end if;
  foreach k in array array['db', 'dbGroups', 'bruts', 'produits'] loop
    if d ? k then
      if jsonb_typeof(d -> k) <> 'array' then raise exception 'invalid_data'; end if;
    else
      d := d || jsonb_build_object(k, '[]'::jsonb);
    end if;
  end loop;
  if octet_length(d::text) > 4000000 then raise exception 'data_too_large'; end if;
  return d;
end;
$$;

create or replace function public.api_list_projets(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := public.api_auth(p_token, false);
begin
  return coalesce((
    select jsonb_agg(x order by lower(x ->> 'title'))
    from (
      select jsonb_build_object(
        'id', p.id, 'title', p.title, 'team_id', p.team_id, 'team_name', t.name,
        'role', public.api_role(v_uid, p.team_id, p.owner_id), 'owner_id', p.owner_id,
        'version', p.version, 'updated_at', p.updated_at,
        'parts',    case when jsonb_typeof(p.data -> 'db') = 'array' then jsonb_array_length(p.data -> 'db') else 0 end,
        'produits', case when jsonb_typeof(p.data -> 'produits') = 'array' then jsonb_array_length(p.data -> 'produits') else 0 end
      ) as x
      from public.projets p
      left join public.teams t on t.id = p.team_id
      where public.api_role(v_uid, p.team_id, p.owner_id) is not null
    ) s
  ), '[]'::jsonb);
end;
$$;

create or replace function public.api_get_projet(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := public.api_auth(p_token, false); p public.projets; v_role text; v_team text;
begin
  select * into p from public.projets where id = p_id;
  v_role := case when found then public.api_role(v_uid, p.team_id, p.owner_id) end;
  if v_role is null then raise exception 'not_found'; end if;
  select name into v_team from public.teams where id = p.team_id;
  return jsonb_build_object(
    'id', p.id, 'title', p.title, 'team_id', p.team_id, 'team_name', v_team, 'role', v_role,
    'owner_id', p.owner_id, 'version', p.version, 'updated_at', p.updated_at, 'data', p.data);
end;
$$;

create or replace function public.api_create_projet(p_token text, p_title text, p_team uuid, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := public.api_auth(p_token, true); v_title text := btrim(coalesce(p_title, '')); p public.projets;
begin
  if length(v_title) > 200 then raise exception 'invalid_title'; end if;
  if p_team is not null and coalesce(public.api_role(v_uid, p_team, null), '') not in ('owner', 'editor') then
    raise exception 'forbidden';
  end if;
  insert into public.projets (owner_id, team_id, title, data)
  values (v_uid, p_team, v_title, public.api_check_data(p_data))
  returning * into p;
  return jsonb_build_object('id', p.id, 'version', p.version);
end;
$$;

create or replace function public.api_update_projet(p_token text, p_id uuid, p_version integer, p_title text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_uid uuid := public.api_auth(p_token, true); p public.projets; v_role text; v_title text := btrim(p_title);
begin
  select * into p from public.projets where id = p_id for update;
  v_role := case when found then public.api_role(v_uid, p.team_id, p.owner_id) end;
  if v_role is null then raise exception 'not_found'; end if;
  if v_role not in ('owner', 'editor') then raise exception 'forbidden'; end if;
  if p.version is distinct from p_version then raise exception 'version_conflict'; end if;
  if v_title is not null and length(v_title) > 200 then raise exception 'invalid_title'; end if;
  update public.projets
     set title = coalesce(v_title, title),
         data  = case when p_data is null then data else public.api_check_data(p_data) end
   where id = p_id
  returning * into p;
  return jsonb_build_object('id', p.id, 'version', p.version);
end;
$$;

-- droits : jetons créés/révoqués par l'utilisateur connecté ; fonctions api_* réservées
-- à la clé de service (fonction Edge)
revoke all on function public.create_api_token(text, text, integer) from public, anon;
revoke all on function public.revoke_api_token(uuid)                from public, anon;
grant execute on function public.create_api_token(text, text, integer) to authenticated;
grant execute on function public.revoke_api_token(uuid)                to authenticated;

revoke all on function public.api_auth(text, boolean)                                  from public, anon, authenticated;
revoke all on function public.api_role(uuid, uuid, uuid)                               from public, anon, authenticated;
revoke all on function public.api_check_data(jsonb)                                    from public, anon, authenticated;
revoke all on function public.api_list_projets(text)                                   from public, anon, authenticated;
revoke all on function public.api_get_projet(text, uuid)                               from public, anon, authenticated;
revoke all on function public.api_create_projet(text, text, uuid, jsonb)              from public, anon, authenticated;
revoke all on function public.api_update_projet(text, uuid, integer, text, jsonb)      from public, anon, authenticated;
grant execute on function public.api_auth(text, boolean)                               to service_role;
grant execute on function public.api_role(uuid, uuid, uuid)                            to service_role;
grant execute on function public.api_check_data(jsonb)                                 to service_role;
grant execute on function public.api_list_projets(text)                                to service_role;
grant execute on function public.api_get_projet(text, uuid)                            to service_role;
grant execute on function public.api_create_projet(text, text, uuid, jsonb)           to service_role;
grant execute on function public.api_update_projet(text, uuid, integer, text, jsonb)  to service_role;
