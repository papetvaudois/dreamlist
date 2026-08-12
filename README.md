# Dreamlist

Site de wishlists partagées. Un seul fichier : [`index.html`](index.html).
Tu peux l'ouvrir en double-cliquant dessus, ou le mettre en ligne tel quel.

## Ce qu'il y a dans ce dossier

| Fichier | À quoi ça sert |
|---|---|
| `index.html` | **Le site.** Tout est dedans : le HTML, le CSS, le JavaScript, la police. Aucune dépendance à installer. |
| `supabase/schema.sql` | La base de données, à coller dans Supabase. Rien à faire tourner sur ta machine. |
| `GUIDE.md` | Les explications : les clés, le RLS, l'auth Google, le captcha. À lire avant de brancher Supabase. |

## État actuel

Le site marche **sans base de données**. Les comptes de démonstration, les
listes et les articles sont écrits en dur dans le fichier, et seuls ton compte
et ta photo de profil sont retenus par le navigateur (`localStorage`).

Concrètement : si tu ouvres le site sur ton téléphone, tu ne verras pas ce que
tu as ajouté sur ton ordinateur, et personne d'autre ne voit tes listes. C'est
exactement ce que la base de données va régler.

## Étape suivante — brancher Supabase

1. Créer un compte sur [supabase.com](https://supabase.com) et un projet (région
   *Europe West* pour que ce soit rapide depuis la France).
2. Dans le projet : **SQL Editor** → *New query* → coller tout
   `supabase/schema.sql` → **Run**. Ça crée les 7 tables, les règles d'accès et
   les deux dossiers d'images.
3. Récupérer dans **Project Settings → API** :
   - l'**URL du projet** (`https://xxxx.supabase.co`)
   - la clé **anon / publishable**
4. Me donner ces deux valeurs : elles vont dans `index.html` et le site se met à
   lire et écrire pour de vrai.

Le détail de chaque étape, et surtout *pourquoi*, est dans [`GUIDE.md`](GUIDE.md).

## Corrections déjà faites

- **Photo de profil qui ne s'affichait pas.** Le moteur de rendu du prototype
  découpait la valeur de `style` sur les `;`. Une image lue en base64 commence
  par `data:image/png;base64,…` — le `;` coupait l'adresse en deux et le style
  devenait `background-image:url(data:image/png`, donc une image vide. Les
  images passent maintenant par `URL.createObjectURL` (adresse `blob:`, sans
  `;`), et la photo de profil est en plus redimensionnée en 256×256 avant d'être
  gardée par le navigateur — 6 ko au lieu de plusieurs mégaoctets, ce qui évite
  de saturer le `localStorage`.
