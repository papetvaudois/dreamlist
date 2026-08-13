-- ============================================================================
-- DREAMLIST — Schéma complet de la base de données
-- ============================================================================
-- À coller en une fois dans Supabase → SQL Editor → New query → Run.
-- Le script est ré-exécutable : le relancer ne casse rien.
--
-- Contenu :
--   1. Tables
--   2. Index
--   3. Fonctions utilitaires (lecture autorisée ?)
--   4. Création automatique du profil à l'inscription
--   5. Règle des demandes d'abonnement
--   6. RLS — Row Level Security, une policy par table et par action
--   7. Buckets de stockage d'images + leurs policies
--   8. Vue des compteurs publics
-- ============================================================================


-- ============================================================================
-- 1. TABLES
-- ============================================================================

-- Un profil par compte. L'id est CELUI de auth.users : même personne, même id.
-- On ne stocke jamais le mot de passe ici, Supabase Auth s'en occupe seul.
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null default '',
  handle      text not null,
  avatar_url  text,
  bio         text not null default '',
  follow_mode text not null default 'open' check (follow_mode in ('open', 'approval')),
  created_at  timestamptz not null default now()
);

-- Le pseudo est stocké SANS le « @ », en minuscules. L'interface ajoute le @.
alter table public.profiles drop constraint if exists profiles_handle_format;
alter table public.profiles add constraint profiles_handle_format
  check (handle ~ '^[a-z0-9._]{3,30}$');

create unique index if not exists profiles_handle_key on public.profiles (handle);


-- Une wishlist appartient à un et un seul compte.
create table if not exists public.wishlists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles (id) on delete cascade,
  title       text not null default 'Sans titre',
  description text not null default '',
  visibility  text not null default 'public' check (visibility in ('public', 'private')),
  created_at  timestamptz not null default now()
);


-- Un article dans une wishlist.
-- Le prix est en CENTIMES (integer) : 495,00 € = 49500. Jamais de float pour
-- de l'argent, les arrondis flottants finissent toujours par mordre.
create table if not exists public.items (
  id          uuid primary key default gen_random_uuid(),
  wishlist_id uuid not null references public.wishlists (id) on delete cascade,
  brand       text not null default '',
  title       text not null default '',
  price_cents integer not null default 0 check (price_cents >= 0),
  currency    text not null default 'EUR',
  slug        text not null default '',
  image_url   text,
  note        text not null default '',
  link        text,
  position    integer not null default 0,
  created_at  timestamptz not null default now()
);


-- Abonnements. Une ligne = « follower_id suit target_id ».
-- status = 'pending' tant qu'un compte en mode « sur demande » n'a pas accepté.
create table if not exists public.follows (
  follower_id uuid not null references public.profiles (id) on delete cascade,
  target_id   uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'accepted' check (status in ('accepted', 'pending')),
  created_at  timestamptz not null default now(),
  primary key (follower_id, target_id),
  constraint follows_no_self check (follower_id <> target_id)
);


-- Commentaires, sur une liste ou sur un article.
create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('list', 'item')),
  target_id   uuid not null,
  author_id   uuid not null references public.profiles (id) on delete cascade,
  body        text not null check (length(trim(body)) between 1 and 2000),
  created_at  timestamptz not null default now()
);


-- Likes. La clé primaire double empêche de liker deux fois le même article.
create table if not exists public.likes (
  item_id    uuid not null references public.items (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (item_id, user_id)
);


-- Mise en page du moodboard. Une ligne par wishlist.
-- « elements » contient les positions du mode libre, en JSON.
create table if not exists public.board_layouts (
  wishlist_id uuid primary key references public.wishlists (id) on delete cascade,
  layout      text not null default 'mosaic' check (layout in ('strict', 'mosaic', 'columns', 'free')),
  elements    jsonb not null default '[]'::jsonb,
  updated_at  timestamptz not null default now()
);


-- ============================================================================
-- 2. INDEX — sans eux, chaque requête relit toute la table
-- ============================================================================

create index if not exists wishlists_owner_idx     on public.wishlists (owner_id, created_at desc);
create index if not exists items_wishlist_idx      on public.items (wishlist_id, position, created_at);
create index if not exists follows_target_idx      on public.follows (target_id, status);
create index if not exists follows_follower_idx    on public.follows (follower_id, status);
create index if not exists comments_target_idx     on public.comments (target_type, target_id, created_at);
create index if not exists comments_author_idx     on public.comments (author_id);
create index if not exists likes_user_idx          on public.likes (user_id);


-- ============================================================================
-- 3. FONCTIONS UTILITAIRES
-- ============================================================================
-- Ces fonctions répondent à « est-ce que l'utilisateur courant a le droit de
-- lire ça ? ». Elles sont appelées par les policies RLS plus bas.
--
-- Elles sont en security invoker : elles s'exécutent avec les droits de la
-- personne qui appelle, donc le RLS s'applique aussi à l'intérieur. C'est le
-- bon réglage ici — aucune de ces fonctions n'interroge la table dont elle
-- sert la policy, il n'y a donc pas de récursion à craindre, et rien ne
-- contourne le RLS. On fixe search_path pour éviter qu'un objet malveillant
-- créé ailleurs se glisse à la place du nôtre.

create or replace function public.can_read_wishlist(w_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1 from public.wishlists w
    where w.id = w_id
      and (w.visibility = 'public' or w.owner_id = (select auth.uid()))
  );
$$;

create or replace function public.owns_wishlist(w_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1 from public.wishlists w
    where w.id = w_id and w.owner_id = (select auth.uid())
  );
$$;

create or replace function public.can_read_item(i_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select exists (
    select 1 from public.items i
    join public.wishlists w on w.id = i.wishlist_id
    where i.id = i_id
      and (w.visibility = 'public' or w.owner_id = (select auth.uid()))
  );
$$;

-- Commentaire posé sur une liste ou sur un article : on aiguille.
create or replace function public.can_read_comment_target(t_type text, t_id uuid)
returns boolean
language sql
stable
security invoker
set search_path = public
as $$
  select case t_type
    when 'list' then public.can_read_wishlist(t_id)
    when 'item' then public.can_read_item(t_id)
    else false
  end;
$$;

grant execute on function public.can_read_wishlist(uuid)            to anon, authenticated;
grant execute on function public.owns_wishlist(uuid)                to anon, authenticated;
grant execute on function public.can_read_item(uuid)                to anon, authenticated;
grant execute on function public.can_read_comment_target(text,uuid) to anon, authenticated;


-- ============================================================================
-- 4. CRÉATION AUTOMATIQUE DU PROFIL À L'INSCRIPTION
-- ============================================================================
-- Quand Supabase Auth crée une ligne dans auth.users, ce trigger crée la ligne
-- correspondante dans profiles. Le pseudo demandé est repris s'il est libre,
-- sinon on lui ajoute un suffixe jusqu'à trouver un pseudo disponible.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  wanted text;
  candidate text;
  n integer := 0;
begin
  wanted := lower(coalesce(new.raw_user_meta_data ->> 'handle', ''));
  -- « é » doit devenir « e » et non disparaître : on translittère avant de
  -- filtrer. Sinon « zoé.m » deviendrait « zo.m », et le pseudo ne ressemble
  -- plus à ce que la personne a tapé.
  wanted := translate(wanted,
    'àáâãäåçèéêëìíîïñòóôõöùúûüýÿœæ',
    'aaaaaaceeeeiiiinooooouuuuyyoa');
  wanted := regexp_replace(wanted, '[^a-z0-9._]+', '.', 'g');
  wanted := regexp_replace(wanted, '\.{2,}', '.', 'g');
  wanted := regexp_replace(wanted, '^[._]+|[._]+$', '', 'g');
  if length(wanted) < 3 then
    wanted := 'user' || substr(replace(new.id::text, '-', ''), 1, 6);
  end if;
  wanted := substr(wanted, 1, 24);
  candidate := wanted;

  while exists (select 1 from public.profiles p where p.handle = candidate) loop
    n := n + 1;
    candidate := wanted || n::text;
  end loop;

  insert into public.profiles (id, name, handle, avatar_url, follow_mode)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'name', ''),
    candidate,
    new.raw_user_meta_data ->> 'avatar_url',
    case when new.raw_user_meta_data ->> 'follow_mode' = 'approval' then 'approval' else 'open' end
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

-- Un trigger n'a pas besoin que le client puisse appeler sa fonction :
-- PostgreSQL verifie ce droit a la creation du trigger, pas a chaque
-- declenchement. On le retire donc, ce qui evite qu'on l'invoque du dehors.
revoke execute on function public.handle_new_user() from public, anon, authenticated;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ============================================================================
-- 5. RÈGLE DES DEMANDES D'ABONNEMENT
-- ============================================================================
-- Le statut d'un nouvel abonnement n'est PAS décidé par le client : il est
-- imposé ici selon le follow_mode de la personne suivie. Sans ça, n'importe
-- qui pourrait envoyer status = 'accepted' et court-circuiter la validation.

create or replace function public.enforce_follow_status()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  mode text;
begin
  select follow_mode into mode from public.profiles where id = new.target_id;
  new.status := case when mode = 'approval' then 'pending' else 'accepted' end;
  return new;
end;
$$;

revoke execute on function public.enforce_follow_status() from public, anon, authenticated;

drop trigger if exists follows_set_status on public.follows;
create trigger follows_set_status
  before insert on public.follows
  for each row execute function public.enforce_follow_status();


-- ============================================================================
-- 6. RLS — ROW LEVEL SECURITY
-- ============================================================================
-- Sans RLS, la clé anon donne accès à TOUTES les lignes de TOUTES ces tables,
-- lecture comme écriture. Avec RLS activé et aucune policy, plus personne ne
-- voit rien. Chaque policy ci-dessous rouvre une porte précise.
--
--   using      = quelles lignes existantes je peux voir / modifier / supprimer
--   with check = à quoi doit ressembler la ligne que j'écris
--   auth.uid() = l'id du compte connecté, extrait du jeton, infalsifiable

alter table public.profiles      enable row level security;
alter table public.wishlists     enable row level security;
alter table public.items         enable row level security;
alter table public.follows       enable row level security;
alter table public.comments      enable row level security;
alter table public.likes         enable row level security;
alter table public.board_layouts enable row level security;


-- --- privilèges de table ---------------------------------------------------
-- Il y a DEUX serrures superposées, qu'on confond souvent :
--   le GRANT ci-dessous = « ce rôle a-t-il le droit de toucher cette table ? »
--   le RLS ci-dessus    = « et quelles LIGNES exactement ? »
--
-- Supabase peut poser ces privilèges tout seul (option « Automatically expose
-- new tables » à la création du projet). On ne s'y fie pas : le script les
-- écrit lui-même, donc il marche quel que soit le réglage choisi.
--
-- anon (visiteur non connecté) n'obtient que la LECTURE. Toute écriture exige
-- un compte connecté — et le RLS restreint encore, ligne par ligne.

grant usage on schema public to anon, authenticated;

grant select on table
  public.profiles, public.wishlists, public.items, public.follows,
  public.comments, public.likes, public.board_layouts
  to anon, authenticated;

grant insert, update, delete on table
  public.profiles, public.wishlists, public.items, public.follows,
  public.comments, public.likes, public.board_layouts
  to authenticated;


-- --- profiles --------------------------------------------------------------
-- Les profils sont un annuaire public : l'écran Explorer doit pouvoir chercher
-- des comptes. En revanche personne ne modifie le profil de quelqu'un d'autre.
-- Note : l'email n'est PAS ici, il reste dans auth.users, invisible aux autres.

drop policy if exists "profils lisibles par tous" on public.profiles;
create policy "profils lisibles par tous"
  on public.profiles for select
  using (true);

drop policy if exists "je crée mon profil" on public.profiles;
create policy "je crée mon profil"
  on public.profiles for insert to authenticated
  with check (id = (select auth.uid()));

drop policy if exists "je modifie mon profil" on public.profiles;
create policy "je modifie mon profil"
  on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));


-- --- wishlists -------------------------------------------------------------

drop policy if exists "listes publiques ou les miennes" on public.wishlists;
create policy "listes publiques ou les miennes"
  on public.wishlists for select
  using (visibility = 'public' or owner_id = (select auth.uid()));

drop policy if exists "je crée mes listes" on public.wishlists;
create policy "je crée mes listes"
  on public.wishlists for insert to authenticated
  with check (owner_id = (select auth.uid()));

drop policy if exists "je modifie mes listes" on public.wishlists;
create policy "je modifie mes listes"
  on public.wishlists for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists "je supprime mes listes" on public.wishlists;
create policy "je supprime mes listes"
  on public.wishlists for delete to authenticated
  using (owner_id = (select auth.uid()));


-- --- items -----------------------------------------------------------------
-- Un article suit le sort de sa liste : visible si la liste est visible,
-- modifiable seulement par le propriétaire de la liste.

drop policy if exists "articles des listes visibles" on public.items;
create policy "articles des listes visibles"
  on public.items for select
  using (public.can_read_wishlist(wishlist_id));

drop policy if exists "j'ajoute des articles à mes listes" on public.items;
create policy "j'ajoute des articles à mes listes"
  on public.items for insert to authenticated
  with check (public.owns_wishlist(wishlist_id));

drop policy if exists "je modifie les articles de mes listes" on public.items;
create policy "je modifie les articles de mes listes"
  on public.items for update to authenticated
  using (public.owns_wishlist(wishlist_id))
  with check (public.owns_wishlist(wishlist_id));

drop policy if exists "je supprime les articles de mes listes" on public.items;
create policy "je supprime les articles de mes listes"
  on public.items for delete to authenticated
  using (public.owns_wishlist(wishlist_id));


-- --- follows ---------------------------------------------------------------
-- Les abonnements acceptés sont publics (compteur « 1240 ABONNÉS »).
-- Une demande en attente ne regarde que les deux personnes concernées.

drop policy if exists "abonnements acceptés visibles" on public.follows;
create policy "abonnements acceptés visibles"
  on public.follows for select
  using (
    status = 'accepted'
    or follower_id = (select auth.uid())
    or target_id = (select auth.uid())
  );

-- Le status envoyé par le client est ignoré : le trigger du bloc 5 l'impose.
drop policy if exists "je m'abonne pour moi-même" on public.follows;
create policy "je m'abonne pour moi-même"
  on public.follows for insert to authenticated
  with check (follower_id = (select auth.uid()));

-- Seule la personne suivie peut accepter une demande, et uniquement vers
-- 'accepted' — impossible de se faire passer soi-même de pending à accepted.
drop policy if exists "j'accepte mes demandes" on public.follows;
create policy "j'accepte mes demandes"
  on public.follows for update to authenticated
  using (target_id = (select auth.uid()))
  with check (target_id = (select auth.uid()) and status = 'accepted');

-- Se désabonner (follower) ou retirer/refuser un abonné (target).
drop policy if exists "je me désabonne ou je retire un abonné" on public.follows;
create policy "je me désabonne ou je retire un abonné"
  on public.follows for delete to authenticated
  using (follower_id = (select auth.uid()) or target_id = (select auth.uid()));


-- --- comments --------------------------------------------------------------

drop policy if exists "commentaires des contenus visibles" on public.comments;
create policy "commentaires des contenus visibles"
  on public.comments for select
  using (public.can_read_comment_target(target_type, target_id));

drop policy if exists "je commente ce que je peux voir" on public.comments;
create policy "je commente ce que je peux voir"
  on public.comments for insert to authenticated
  with check (
    author_id = (select auth.uid())
    and public.can_read_comment_target(target_type, target_id)
  );

drop policy if exists "je modifie mes commentaires" on public.comments;
create policy "je modifie mes commentaires"
  on public.comments for update to authenticated
  using (author_id = (select auth.uid()))
  with check (author_id = (select auth.uid()));

-- L'auteur supprime son commentaire ; le propriétaire du contenu peut aussi
-- faire le ménage chez lui.
drop policy if exists "je supprime mes commentaires ou ceux chez moi" on public.comments;
create policy "je supprime mes commentaires ou ceux chez moi"
  on public.comments for delete to authenticated
  using (
    author_id = (select auth.uid())
    or (target_type = 'list' and public.owns_wishlist(target_id))
    or (target_type = 'item' and exists (
          select 1 from public.items i
          where i.id = comments.target_id and public.owns_wishlist(i.wishlist_id)
       ))
  );


-- --- likes -----------------------------------------------------------------

drop policy if exists "likes des articles visibles" on public.likes;
create policy "likes des articles visibles"
  on public.likes for select
  using (public.can_read_item(item_id));

drop policy if exists "je like en mon nom" on public.likes;
create policy "je like en mon nom"
  on public.likes for insert to authenticated
  with check (user_id = (select auth.uid()) and public.can_read_item(item_id));

drop policy if exists "je retire mon like" on public.likes;
create policy "je retire mon like"
  on public.likes for delete to authenticated
  using (user_id = (select auth.uid()));


-- --- board_layouts ---------------------------------------------------------

drop policy if exists "mise en page des listes visibles" on public.board_layouts;
create policy "mise en page des listes visibles"
  on public.board_layouts for select
  using (public.can_read_wishlist(wishlist_id));

drop policy if exists "je compose mes moodboards" on public.board_layouts;
create policy "je compose mes moodboards"
  on public.board_layouts for insert to authenticated
  with check (public.owns_wishlist(wishlist_id));

drop policy if exists "je réarrange mes moodboards" on public.board_layouts;
create policy "je réarrange mes moodboards"
  on public.board_layouts for update to authenticated
  using (public.owns_wishlist(wishlist_id))
  with check (public.owns_wishlist(wishlist_id));

drop policy if exists "je supprime mes moodboards" on public.board_layouts;
create policy "je supprime mes moodboards"
  on public.board_layouts for delete to authenticated
  using (public.owns_wishlist(wishlist_id));


-- ============================================================================
-- 7. STOCKAGE DES IMAGES
-- ============================================================================
-- Deux buckets publics en lecture (une image de wishlist n'a pas à être
-- secrète, et une URL publique s'affiche sans jeton, donc sans latence).
-- L'écriture, elle, est cloisonnée : chaque compte n'écrit que dans le dossier
-- qui porte son propre id. Chemin attendu : avatars/<uid>/photo.jpg

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars', 'avatars', true, 5242880,  array['image/jpeg','image/png','image/webp','image/gif']),
  ('images',  'images',  true, 10485760, array['image/jpeg','image/png','image/webp','image/gif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "images lisibles par tous" on storage.objects;
create policy "images lisibles par tous"
  on storage.objects for select
  using (bucket_id in ('avatars', 'images'));

drop policy if exists "j'envoie dans mon dossier" on storage.objects;
create policy "j'envoie dans mon dossier"
  on storage.objects for insert to authenticated
  with check (
    bucket_id in ('avatars', 'images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "je remplace mes fichiers" on storage.objects;
create policy "je remplace mes fichiers"
  on storage.objects for update to authenticated
  using (
    bucket_id in ('avatars', 'images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists "je supprime mes fichiers" on storage.objects;
create policy "je supprime mes fichiers"
  on storage.objects for delete to authenticated
  using (
    bucket_id in ('avatars', 'images')
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );


-- ============================================================================
-- 8. VUE DES COMPTEURS
-- ============================================================================
-- « 02 LISTES · 1240 ABONNÉS » sans télécharger toutes les lignes côté client.
-- security_invoker = on : la vue applique les policies RLS de celui qui la
-- lit, elle ne sert donc jamais de porte dérobée vers les listes privées.

create or replace view public.profile_stats
with (security_invoker = on) as
select
  p.id,
  p.handle,
  (select count(*) from public.wishlists w where w.owner_id = p.id)                         as lists_count,
  (select count(*) from public.items i
     join public.wishlists w on w.id = i.wishlist_id where w.owner_id = p.id)               as items_count,
  (select count(*) from public.follows f where f.target_id = p.id and f.status = 'accepted') as followers_count,
  (select count(*) from public.follows f where f.follower_id = p.id and f.status = 'accepted') as following_count
from public.profiles p;

grant select on public.profile_stats to anon, authenticated;


-- ============================================================================
-- FIN. Vérification rapide :
--   select tablename, rowsecurity from pg_tables where schemaname = 'public';
-- rowsecurity doit valoir true partout.
-- ============================================================================
