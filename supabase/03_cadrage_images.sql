-- ============================================================================
-- DREAMLIST — Point de cadrage des images
-- ============================================================================
-- À coller dans Supabase → SQL Editor → New query → Run.
-- Ré-exécutable sans risque.
--
-- Pourquoi : une image est affichée en « cover », c'est-à-dire recadrée pour
-- remplir sa tuile sans se déformer. Par défaut le recadrage part du centre —
-- ce qui coupe l'abat-jour d'une lampe dès que la tuile est large et basse.
--
-- On stocke donc, par article, le point de l'image qui doit rester visible :
-- deux pourcentages, 0 à 100, horizontal et vertical. 50/50 = le centre,
-- c'est-à-dire le comportement actuel.
--
-- Ces deux colonnes suffisent parce que le navigateur sait déjà faire le
-- reste : `background-position: 30% 20%` cale l'image sur ce point quelle que
-- soit la forme de la tuile. Une même valeur marche donc pour la grille, les
-- vignettes du fil, les couvertures du profil et le moodboard.
-- ============================================================================

alter table public.items
  add column if not exists focus_x smallint not null default 50,
  add column if not exists focus_y smallint not null default 50;

-- Un pourcentage hors bornes n'aurait aucun sens et casserait l'affichage.
alter table public.items drop constraint if exists items_focus_bounds;
alter table public.items add constraint items_focus_bounds
  check (focus_x between 0 and 100 and focus_y between 0 and 100);


-- ============================================================================
-- VÉRIFICATION
-- ============================================================================
-- select column_name, data_type, column_default
-- from information_schema.columns
-- where table_schema = 'public' and table_name = 'items'
--   and column_name in ('focus_x', 'focus_y');
-- ============================================================================
