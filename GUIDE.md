# Guide — la base de données de Dreamlist, expliquée

Ton frère a raison sur un point : brancher une base de données, ce n'est pas
juste « allumer un interrupteur ». Mais ce n'est pas compliqué au sens de
*difficile*. C'est compliqué au sens de *il y a cinq ou six réglages qu'il faut
comprendre, et si on en rate un, tout le monde peut lire les données de tout le
monde*. Ce guide couvre exactement ces réglages.

---

## 1. Le principe : pourquoi il n'y a pas de « backend » à écrire

D'habitude un site avec base de données a trois morceaux :

```
Navigateur   →   Serveur que tu écris   →   Base de données
```

Le serveur du milieu sert de videur : il vérifie qui tu es et ce que tu as le
droit de faire, parce que la base de données, elle, ne fait pas confiance au
navigateur — et elle a raison, n'importe qui peut ouvrir les outils de
développement et envoyer ce qu'il veut.

Supabase supprime le morceau du milieu :

```
Navigateur   →   Supabase (Postgres + Auth + Storage)
```

Le videur n'est plus un serveur séparé, il est **dans la base de données**. Ce
sont les règles RLS (partie 5). C'est pour ça que tu n'as pas de « backend » à
écrire ni à héberger : les règles de sécurité sont écrites une fois en SQL, et
Postgres les applique à chaque requête, quoi qu'envoie le navigateur.

C'est aussi pour ça qu'il faut vraiment comprendre le RLS. C'est la seule
serrure. Il n'y en a pas une deuxième derrière.

---

## 2. Les clés d'API : `anon` et `service_role`

Dans **Project Settings → API**, Supabase donne deux clés. Elles n'ont
absolument pas le même statut.

### La clé `anon` (aussi appelée *publishable*)

- Elle est **faite pour être publique**. Elle sera dans `index.html`, visible
  par n'importe qui fait « afficher le code source ». C'est normal, c'est prévu.
- Elle ne dit pas *qui* tu es, elle dit seulement *à quel projet* tu parles.
- Toute seule, elle ne donne **aucun droit** : dès que RLS est activé sur une
  table, une requête faite avec la clé `anon` ne voit que ce que les policies
  autorisent.
- Quand quelqu'un se connecte, Supabase lui remet en plus un **jeton personnel**
  (un JWT) qui, lui, prouve son identité. C'est ce jeton qui alimente
  `auth.uid()` dans les policies.

> ⚠️ La clé `anon` n'est inoffensive **que si RLS est activé partout**. Une table
> sans RLS + clé `anon` publique = tout le monde peut lire et écrire cette table.
> C'est la fuite de données la plus banale sur les projets Supabase.

### La clé `service_role` (la « clé privée »)

- Elle **ignore complètement le RLS**. Elle a tous les droits sur toutes les
  tables : lire, modifier, vider.
- Elle ne doit **jamais** se trouver dans `index.html`, ni dans du JavaScript, ni
  dans un dépôt GitHub, ni dans une capture d'écran, ni dans un message.
- Elle sert uniquement côté serveur, pour des tâches d'administration
  (import massif, script de maintenance, Edge Function).

**Pour Dreamlist tel qu'on le construit, tu n'as pas besoin de la clé
`service_role`.** Le site n'utilise que la clé `anon`. Si tu la vois traîner
quelque part dans le code, c'est une erreur.

Si elle fuit un jour : Project Settings → API → *Reset* la clé. L'ancienne
devient inutilisable immédiatement.

---

## 3. RLS et les policies — la vraie sécurité

**RLS** = *Row Level Security*, « sécurité au niveau de la ligne ».

Une permission classique, c'est « tu as accès à la table `wishlists` ». RLS
descend d'un cran : « tu as accès **aux lignes** de `wishlists` qui remplissent
telle condition ».

Le fonctionnement est en deux temps :

```sql
alter table public.wishlists enable row level security;
```

À partir de cette ligne, **plus personne ne voit rien** dans cette table. Par
défaut, tout est fermé. Ensuite on rouvre des portes précises, une par action :

```sql
create policy "listes publiques ou les miennes"
  on public.wishlists for select
  using (visibility = 'public' or owner_id = (select auth.uid()));
```

Traduction : *pour un SELECT sur `wishlists`, une ligne n'est visible que si
elle est publique, ou si son propriétaire est la personne connectée.*

Postgres ajoute cette condition à **toutes** les requêtes, automatiquement. Même
si quelqu'un écrit à la main `select * from wishlists`, il ne récupérera que ses
propres listes et les listes publiques. Il n'y a pas de contournement.

Deux mots-clés à distinguer :

| | Question posée | S'applique à |
|---|---|---|
| `using` | « cette ligne qui existe déjà, j'ai le droit de la voir / modifier / supprimer ? » | SELECT, UPDATE, DELETE |
| `with check` | « cette ligne que j'essaie d'écrire, elle a le droit d'exister ? » | INSERT, UPDATE |

Le `with check` est celui qu'on oublie, et c'est le plus dangereux à oublier.
Sans lui, quelqu'un peut créer une wishlist en mettant **ton** id dans
`owner_id`, et fabriquer du contenu à ton nom.

Et une chose à comprendre pour de bon : `auth.uid()` **n'est pas envoyé par le
navigateur**. Il est lu dans le jeton signé par Supabase. Personne ne peut
prétendre être quelqu'un d'autre en modifiant sa requête.

Dans `supabase/schema.sql`, les 7 tables ont RLS activé et 25 policies. Vérifie
après avoir lancé le script :

```sql
select tablename, rowsecurity from pg_tables where schemaname = 'public';
```

`rowsecurity` doit valoir `true` sur chaque ligne. Supabase affiche aussi une
grosse alerte rouge dans **Table Editor** si une table publique n'a pas RLS.

### Le cas particulier des demandes d'abonnement

Une policy ne suffit pas toujours. Pour un compte en mode « sur demande », le
statut de l'abonnement doit naître à `pending` — et surtout, ce n'est pas au
navigateur de le décider, sinon il enverrait `accepted` directement.

Le schéma utilise donc un **trigger** : une petite fonction que Postgres exécute
juste avant chaque insertion, et qui écrase le statut envoyé par le client selon
le `follow_mode` de la personne suivie. La policy dit *qui* peut insérer, le
trigger décide *ce qui* est réellement inséré.

---

## 4. Rate limit et captcha sur l'authentification

Ces deux réglages protègent la **porte d'entrée**, pas les données. Le RLS
empêche de lire ce qui ne te regarde pas ; le rate limit et le captcha empêchent
d'abuser du formulaire de connexion.

### Rate limit (limite de fréquence)

C'est un plafond du type « pas plus de N tentatives par heure et par adresse
IP ». Sans plafond, trois problèmes concrets :

- quelqu'un teste des milliers de mots de passe sur un compte jusqu'à tomber
  juste (attaque par force brute) ;
- un robot crée 10 000 faux comptes, et ta base est inutilisable ;
- chaque inscription déclenche un email de confirmation — un robot te fait donc
  brûler ton quota d'emails et, au passage, salit la réputation de ton domaine
  d'envoi.

Supabase applique déjà des limites par défaut. Elles se règlent dans
**Authentication → Rate Limits**. Les valeurs par défaut conviennent pour
commencer ; le réglage à surveiller est celui des emails, très bas sur le plan
gratuit (quelques envois par heure).

### Captcha

Le rate limit compte les tentatives. Le captcha, lui, demande une preuve que tu
es humain avant même d'essayer. Supabase s'intègre avec **hCaptcha** ou
**Cloudflare Turnstile** (Turnstile est le plus discret : la plupart du temps,
l'utilisateur ne voit rien du tout).

Mise en place : compte gratuit chez Cloudflare Turnstile → tu obtiens une *site
key* (publique, elle va dans le site) et une *secret key* (privée, elle va dans
**Authentication → Attack Protection** de Supabase, jamais dans le code).

Est-ce indispensable tout de suite ? Non. Tant que le site est entre toi et tes
proches, le rate limit par défaut suffit. Le jour où tu le partages largement,
active Turnstile — c'est une demi-heure de travail et ça évite le déluge de faux
comptes.

---

## 5. La connexion avec Google

Trois raisons de la proposer : pas de mot de passe à inventer ni à retenir, pas
d'email de confirmation à envoyer (donc pas de quota qui explose, pas de mail
qui atterrit en spam), et l'adresse est vérifiée par Google.

Le déroulé, sans jargon :

1. Ton site envoie la personne chez Google.
2. Google lui demande « tu autorises *Dreamlist* à connaître ton nom, ton email
   et ta photo ? ».
3. Si elle accepte, Google renvoie vers ton site avec un code à usage unique.
4. Supabase échange ce code contre l'identité vérifiée et crée le compte.

**Ton site ne voit jamais le mot de passe Google.** C'est tout l'intérêt.

Ce qu'il faut faire, une fois :

1. Dans la **Google Cloud Console** → *APIs & Services* → *Credentials* → créer
   un identifiant *OAuth client ID* de type *Web application*.
2. Y déclarer l'URL de retour donnée par Supabase, de la forme
   `https://<ton-projet>.supabase.co/auth/v1/callback`. Google refuse toute URL
   non déclarée — c'est la source d'erreur numéro un (`redirect_uri_mismatch`).
3. Coller le *Client ID* et le *Client Secret* dans Supabase →
   **Authentication → Providers → Google**.
4. Dans Supabase → **Authentication → URL Configuration**, mettre l'adresse de
   ton site en *Site URL* et dans *Redirect URLs*, sinon la personne est renvoyée
   sur `localhost` après connexion.

Côté code, ça tient en trois lignes :

```js
await supabase.auth.signInWithOAuth({
  provider: 'google',
  options: { redirectTo: window.location.origin }
})
```

Bon à savoir : Google fournit la photo de profil dans les données du compte. On
peut la reprendre comme avatar par défaut à l'inscription — un écran de moins à
remplir.

---

## 6. Le stockage des images

Une image n'a rien à faire dans une base de données. On la range dans le
**Storage** (des fichiers), et on garde seulement son **adresse** dans la table.

Le schéma crée deux dossiers (« buckets ») :

- `avatars` — les photos de profil, 5 Mo maximum
- `images` — les visuels des articles, 10 Mo maximum

Les deux sont **publics en lecture** : une image de wishlist n'a pas à être
secrète, et une adresse publique s'affiche instantanément, sans jeton à demander
à chaque fois.

L'**écriture**, elle, est cloisonnée par une policy : chaque compte ne peut
écrire que dans le sous-dossier qui porte son propre identifiant.

```
avatars/6f2c…-8a1b/photo.jpg      ← je peux écrire ici (c'est mon id)
avatars/9d7e…-4c22/photo.jpg      ← refusé
```

Personne ne peut donc remplacer la photo de profil de quelqu'un d'autre, ni
remplir ton quota de stockage.

Et le prototype garde son bon réflexe : la photo est redimensionnée en 256×256
dans le navigateur **avant** l'envoi. Une photo d'iPhone fait 4 Mo, l'avatar
final en fait 15 ko. C'est 250 fois moins de stockage, et un affichage immédiat.

---

## 7. Ce que ça change concrètement dans le site

| Aujourd'hui (`localStorage`) | Avec Supabase |
|---|---|
| Les données vivent dans **ton** navigateur | Elles vivent sur un serveur, accessibles partout |
| Vider le cache = tout est perdu | Rien ne se perd |
| Personne ne voit tes listes | Le lien de partage marche vraiment |
| Les 6 comptes sont écrits en dur | Ce sont de vrais comptes |
| Le mot de passe n'est pas vérifié | Vraie authentification |
| Tout est instantané | Il faut gérer l'attente et les erreurs réseau |

La dernière ligne est celle qui demande le plus de travail : aujourd'hui, un
clic modifie l'écran tout de suite. Avec un serveur, il y a un aller-retour, qui
peut être lent ou échouer. Chaque écran a besoin d'un état « ça charge » et d'un
état « ça a raté ».

---

## 8. L'ordre dans lequel avancer

1. ✅ **Le bug de la photo de profil** — corrigé, expliqué dans le `README.md`.
2. **Créer le projet Supabase** et lancer `supabase/schema.sql`. ← à toi
3. Me donner l'**URL du projet** et la clé **anon**.
4. Brancher l'inscription et la connexion (email + mot de passe d'abord).
5. Brancher les wishlists et les articles.
6. Brancher les images vers le Storage.
7. Abonnements, commentaires, likes, notifications.
8. Google, puis Turnstile quand le site s'ouvre à plus de monde.

Chaque étape marche toute seule : à aucun moment le site n'est cassé en
attendant la suivante.

---

## Un mot sur les « skills » qu'on t'a envoyées

Les commandes `npx skills add …` installent des paquets de consignes
supplémentaires pour Claude Code, publiés par des tiers sur npm. Deux remarques
factuelles :

- **Elles ne peuvent pas tourner ici : `node` et `npm` ne sont pas installés sur
  cette machine.** `npx` n'existe pas.
- Elles portent sur le **design** et l'**animation** (GSAP, Three.js, Remotion,
  guides de style). Rien à voir avec Supabase, les bases de données ou la
  sécurité. Pour ce qu'on fait là, elles n'apportent rien.

Ce n'est pas une raison de s'en méfier — celles d'Anthropic, de Vercel et de
GreenSock viennent d'éditeurs identifiables. Mais installer du code de tiers en
global sur ta machine, ça se décide en connaissance de cause, et ce n'est
clairement pas la priorité tant que la base de données n'est pas debout.
