-- ============================================================================
-- DREAMLIST — Correctif des avertissements du Security Advisor
-- ============================================================================
-- À coller dans Supabase → SQL Editor → New query → Run.
-- Ré-exécutable sans risque.
--
-- Ce que corrige ce script :
--
--   1. Les quatre fonctions d'aide à la lecture repassent en SECURITY INVOKER.
--      Elles étaient en SECURITY DEFINER, c'est-à-dire qu'elles s'exécutaient
--      avec les droits de leur créateur et voyaient donc TOUTES les lignes,
--      RLS ignoré. C'était un excès de prudence de ma part : je craignais une
--      récursion entre policies. Il n'y en a pas — aucune de ces fonctions
--      n'interroge la table dont elle sert la policy.
--
--      En SECURITY INVOKER, elles s'exécutent avec les droits de la personne
--      qui appelle, donc le RLS s'applique à l'intérieur aussi. Le résultat
--      est identique (la policy de wishlists pose déjà la même condition que
--      la fonction), mais il n'y a plus de chemin qui contourne le RLS.
--
--   2. Les deux fonctions de trigger perdent le droit d'être appelées par les
--      clients. Un trigger n'a pas besoin de cette permission : PostgreSQL la
--      vérifie à la création du trigger, pas à chaque déclenchement. Elles
--      restent en SECURITY DEFINER, ce qui est indispensable : handle_new_user
--      écrit dans profiles au moment où le compte n'existe pas encore.
--
-- Ce que ce script NE corrige pas :
--
--   - « Leaked Password Protection Disabled » : la vérification des mots de
--     passe déjà fuités est réservée au plan payant de Supabase. Rien à faire
--     tant qu'on est sur le plan gratuit.
--
--   - rls_auto_enable() : cette fonction ne vient pas de nous. Elle a été
--     créée par l'option « Enable automatic RLS » cochée à la création du
--     projet. Le script tente de lui retirer le droit d'exécution, et passe
--     son chemin sans échouer si elle ne nous appartient pas.
-- ============================================================================


-- ============================================================================
-- 1. LES AIDES DE LECTURE PASSENT EN SECURITY INVOKER
-- ============================================================================

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

-- Elles doivent rester exécutables : les policies RLS les appellent, et une
-- policy s'évalue avec les droits de la personne qui fait la requête.
grant execute on function public.can_read_wishlist(uuid)            to anon, authenticated;
grant execute on function public.owns_wishlist(uuid)                to anon, authenticated;
grant execute on function public.can_read_item(uuid)                to anon, authenticated;
grant execute on function public.can_read_comment_target(text,uuid) to anon, authenticated;


-- ============================================================================
-- 2. LES FONCTIONS DE TRIGGER NE SONT PLUS APPELABLES PAR LES CLIENTS
-- ============================================================================
-- Elles gardent SECURITY DEFINER — elles en ont besoin — mais plus personne
-- ne peut les invoquer directement depuis l'extérieur.

revoke execute on function public.handle_new_user()      from public, anon, authenticated;
revoke execute on function public.enforce_follow_status() from public, anon, authenticated;


-- ============================================================================
-- 3. LA FONCTION DE SUPABASE, SI ELLE NOUS APPARTIENT
-- ============================================================================
-- rls_auto_enable() vient de l'option « Enable automatic RLS » du projet.
-- On tente de retirer le droit d'exécution ; si elle ne nous appartient pas,
-- on n'insiste pas et le script continue.

do $$
begin
  execute 'revoke execute on function public.rls_auto_enable() from public, anon, authenticated';
  raise notice 'rls_auto_enable : droit d''exécution retiré.';
exception
  when insufficient_privilege then
    raise notice 'rls_auto_enable : appartient à Supabase, laissée telle quelle.';
  when undefined_function then
    raise notice 'rls_auto_enable : absente, rien à faire.';
end;
$$;


-- ============================================================================
-- VÉRIFICATION
-- ============================================================================
-- Après exécution, cette requête doit lister les quatre aides en « invoker »
-- et les deux triggers en « definer » :
--
--   select p.proname,
--          case when p.prosecdef then 'definer' else 'invoker' end as securite,
--          array_to_string(p.proacl, ' ')                          as droits
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public'
--     and p.proname in ('can_read_wishlist','owns_wishlist','can_read_item',
--                       'can_read_comment_target','handle_new_user',
--                       'enforce_follow_status')
--   order by p.proname;
-- ============================================================================
