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
  if new.owner_id is distinct from old.owner_id then
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
grant execute on function public.create_team(text)               to authenticated;
grant execute on function public.join_team(text)                 to authenticated;
grant execute on function public.regenerate_team_code(uuid, text) to authenticated;
