# MecaBench

Boîte à outils web pour la mécanique, en ligne sur <https://mecabench.com>. Premier outil : un générateur de nomenclatures (arbre pack / produits), d'autres suivront.

## Générateur de nomenclatures

Petit outil web (HTML/JS, sans backend) qui génère un CSV prêt à importer dans draw.io (`Arrange > Insert > Advanced > CSV`), avec les colonnes `left`/`top` calculées automatiquement à partir de la hiérarchie `id`/`parent`.

## Utiliser en local

Ouvrir `index.html` dans un navigateur. Aucune installation, aucune dépendance : sans configuration Supabase, tout reste enregistré dans le navigateur (localStorage), comme avant.

## Comptes, équipes et synchronisation (Supabase, optionnel)

Avec Supabase, on peut se connecter (e-mail + mot de passe, ou compte Google), retrouver ses projets sur plusieurs appareils et partager des projets en équipe.

- **Perso** : un projet n'est visible que par son créateur.
- **Équipe** : un projet d'équipe est visible par tous les membres. On rejoint une équipe avec un code d'invitation. Chaque équipe a deux codes : un code **éditeur** (peut modifier) et un code **lecteur** (consultation seule, les modifications ne sont jamais enregistrées).
- Seul le **propriétaire** de l'équipe peut supprimer un projet d'équipe, gérer les membres, régénérer les codes ou supprimer l'équipe. Seul le créateur d'un projet peut le déplacer entre « perso » et une équipe.
- Si deux personnes modifient le même projet, la seconde à enregistrer est prévenue et choisit : prendre la version du cloud ou écraser avec la sienne.
- Hors connexion, les modifications restent sur l'appareil et partent dès que le réseau revient.

### Mise en place

1. Créer un projet sur <https://supabase.com> (offre gratuite suffisante).
2. **SQL Editor > New query** : coller tout le contenu de `supabase-setup.sql`, puis **Run**.
3. **Project Settings > API** : copier l'URL du projet et la clé publique (`anon` / `publishable`).
4. Dans `index.html`, tout en haut, renseigner `SUPABASE_URL` et `SUPABASE_ANON_KEY`. La clé publique est faite pour être visible : la sécurité repose sur les règles du script SQL, pas sur le secret de la clé.
5. **Authentication > URL Configuration** : mettre l'adresse du site (par ex. `https://mecabench.com`) dans *Site URL* et dans *Redirect URLs*.
6. (Optionnel) **Authentication > Providers > Google** : activer Google avec un *client ID* / *secret* créés dans Google Cloud Console (URI de redirection autorisée : celle affichée par Supabase). La connexion Google ne fonctionne que depuis l'adresse en ligne, pas depuis un fichier ouvert en local.
7. **Authentication > Providers > Email** : par défaut Supabase demande de confirmer l'e-mail à l'inscription ; on peut le désactiver pour tester.

Les projets existants dans le navigateur ne sont pas perdus : à la première connexion, l'outil propose de les envoyer vers le compte (ou de les garder en local).

## Mettre en ligne avec GitHub Pages

1. Créer un nouveau repo sur GitHub (public ou privé), par exemple `csv-generator`.
2. Depuis ce dossier, initialiser et pousser :

   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/<ton-user>/<ton-repo>.git
   git push -u origin main
   ```

3. Sur GitHub : aller dans **Settings > Pages**.
4. Dans **Build and deployment > Source**, choisir **Deploy from a branch**.
5. Choisir la branche `main` et le dossier `/ (root)`, puis **Save**.
6. Après une minute ou deux, le site est accessible à :

   ```
   https://<ton-user>.github.io/<ton-repo>/
   ```

## Structure

```
.
├── index.html           # l'outil complet (interface + logique de génération du CSV)
├── supabase-setup.sql   # tables, règles de sécurité et fonctions à exécuter dans Supabase
└── README.md
```

## Modifier l'outil

Tout le code (HTML, CSS, JS) est dans `index.html`, sans build. Les bibliothèques (PDF, Excel, Supabase) sont chargées depuis un CDN. Toute modification est visible directement en rechargeant le fichier dans le navigateur.
