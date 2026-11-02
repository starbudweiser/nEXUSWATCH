# Étude de faisabilité — module « Discord » dans nEXUSWATCH

Date : 02/11/2026 · Auteur : session d'étude (aucun code modifié, rien de commité) · Serveur visé : « mORTEX & Skyrim Mac Tools » (anglais ; forums `support-mortex`, `support-mabbajack`, `support-toolkit`, `support-nexuswatch`, `crash-logs`, `ideas`, `aide-fr` ; salons `#announcements`, `#general`, `#showcase`).

**Verdict : GO, dans nEXUSWATCH, en lecture seule, en 3 étapes.** Voir le résumé en fin de document.

---

## 1. Ce que nEXUSWATCH fait déjà, et où le module s'insère

### Fonctions actuelles (v1.3.0, Swift/SwiftUI, ≈ 4 400 lignes, `swiftc` direct, macOS 14+)

| Domaine | Fonctionnement | Fichier |
|---|---|---|
| Stats et fichiers Nexus | API GraphQL publique (`legacyModsByDomain`, `modFiles`), sans clé ; en-têtes `Application-Name/Version` | `Fetcher.swift` |
| Posts et bug reports | Page du mod chargée dans un `WKWebView` caché (passe Cloudflare), puis widgets Nexus lus en JavaScript ; messages d'un bug relus seulement si sa signature `replies:lastPost` change | `Fetcher.swift` |
| État et non-lus | `ModState` par mod (stats, posts, bugs, `seen`, `follow`, `notes`, `history`, `postTags`…) dans `~/Library/Application Support/nEXUSWATCH/state.json` ; clés non-lu `p:`, `r:`, `b:` ; badge du Dock et notification | `Model.swift`, `Store.swift` |
| Rafraîchissement | `Timer` unique (5 min à 3 h) → `refreshAll()` → file **séquentielle** (le WebView est partagé) ; premier chargement sans notification | `Store.swift` |
| Audit local | `LocalAudit.plan` : priorité critique/haute/moyenne/basse par mots-clés (crash, DLL, logs…), nombre de rapports, récence, version courante, réponse de l'auteur ; rapport A4 et « prompt de correction » | `Report.swift` |
| IA facultative | Export, API compatible OpenAI, Claude, ou MCP ; tri **Jev** (TypeSafe) des posts : bug ? demande ? déjà dans le tracker ? | `AI.swift`, `Jev.swift` |
| Serveur MCP `nexuswatch` | Lancé par `NexusWatch --mcp`, JSON-RPC sur stdin/stdout, **lit `state.json`** (processus distinct, lecture seule). Outils : `list_mods`, `get_mod_report`, `get_bug_reports`, `get_fix_prompt` | `AI.swift` |
| Secrets | Trousseau macOS, service `fr.stephan.nexuswatch.ai`, comptes `openai`, `anthropic`, `typesafe` ; lus **après** l'ouverture de la fenêtre (une demande d'accès bloquerait le lancement) | `AI.swift`, `Store.swift` |
| Interface | Socle (`Socle.swift` copie synchronisée), `SplitLayout` liste/détail, `ListRow`, `Badge`, `Callout`, `MessageBlock`, `StatTile`, onglets `posts / bugs / files / ai`, barre latérale de 230 px listant les mods ; 4 langues (`L10n.swift`) | `App.swift` |

### Ce qui rend l'insertion naturelle

- Un **fil de forum Discord est un `Post` Nexus** : titre/message d'ouverture, auteur, date, réponses (`Message`). Les mécanismes « non lu », « sans réponse de l'auteur », notification, badge, résumé pour agent IA et MCP s'appliquent tels quels.
- `Follow` (À trier → Correctif publié), `notes`, `LocalAudit` (mots-clés crash/DLL/logs/résolu) et le « prompt de correction » se réutilisent pour les fils qui parlent d'un bug.
- Discord se lit en **simple `URLSession`** : il n'a pas la contrainte du WebView partagé, donc il peut tourner **en parallèle** de la file Nexus, sur le même minuteur.

### Où s'accroche le module (sans refonte)

1. **Données** — nouveau type `DiscordState`, au niveau de `AppData` mais stocké dans **un fichier à part** (`discord.json`, même mécanique que `Storage`) : le serveur ne se rattache pas à un seul mod (`crash-logs`, `ideas`, `aide-fr` sont transverses), et le volume de messages alourdirait `state.json`, relu à chaque appel MCP.
   ```swift
   struct DiscordState: Codable {
     var guildId, guildName, ownerId: String       // ownerId = Stéphan (équivalent de ModState.isOwn)
     var team: [String]                             // ids dont la réponse compte comme « réponse du support »
     var forums: [DiscordForum]                     // id, name, kind (support/crash/ideas/aide/autre), tags[id→nom], modId: String?
     var threads: [DiscordThread]                   // id, forumId, titre, auteur, dates, tags, archivé/verrouillé, lastMessageId, messages[]
     var seen: Set<String>; var follow: [String: Follow]; var notes: [String: String]
     var lastCheck: Date?
   }
   struct DiscordMessage { id, authorId, author, isTeam, date, text, attachments: [DiscordFile] }
   ```
   `DiscordThread` fournit un adaptateur `asPost` pour réutiliser `AIDigest.postsSection`, `Jev` et `LocalAudit` sans mélanger les sources.
2. **Lien forum → mod** (`DiscordForum.modId`) : `support-mortex` ↔ page Nexus de mORTEX, etc. `support-toolkit` couvre plusieurs outils : lien facultatif, plusieurs mods ou aucun. C'est ce lien qui permet le regroupement avec les bug reports Nexus (§4).
3. **Rafraîchissement** — `refreshAll()` appelle `refreshDiscord()` en parallèle de la file Nexus (pas dans la file). Même intervalle, même minuteur, mêmes règles : premier chargement sans notification, erreurs affichées dans un `Callout`.
4. **Vues** — une entrée « Discord » sous la liste des mods dans la barre latérale (identifiant réservé `discord` dans `data.selected`) : file de tri global. Et, plus tard, un onglet « Discord » dans un mod lié (`Tab.discord`) avec les fils de son forum. Le garde `hasMods` de `RootView` doit être assoupli (Discord sans mod, ou l'inverse).
5. **MCP** — nouveaux outils `list_discord_threads` et `get_discord_thread`, et les fils liés ajoutés à `get_mod_report`. Aucun jeton n'est nécessaire côté MCP (il lit seulement le fichier d'état) : **le jeton ne quitte jamais le processus de l'appli**.

---

## 2. Comparaison avec hERALD (`/Volumes/SKYRIM/TOOLS/MAC/hERALD`)

| | hERALD | nEXUSWATCH |
|---|---|---|
| Sens | **Sortant** : préparer et suivre une campagne (calendrier, brouillons 4 langues, statuts idée → publié) | **Entrant** : surveiller ce que les joueurs écrivent (posts, bugs) et en tirer un plan |
| Règle | « Ne publie jamais » | Lecture seule |
| Veille | GitHub + pages Nexus, **une fois par semaine** au lancement | Toutes les 5 min à 3 h, en arrière-plan, badge du Dock, notifications |
| Retours | Saisis à la main ou import CSV (`comment`, `downloads`, `stars`…) | Récupérés automatiquement |
| Discord | Seulement un **type de canal** (`ChannelKind.discord`) et un message d'exemple | Rien (à créer) |
| Ouverture | **Boîte de dépôt** `Inbox/` : JSON `herald-changes` fusionnés (schéma publié) | Serveur MCP |

**Conclusion : le module a sa place dans nEXUSWATCH.** Le tri de support est de l'entrant : non-lus, badge, notifications, audit des bugs, MCP, IA y existent déjà ; hERALD n'a ni minuteur court, ni notion de non-lu, ni lecture de messages.

**Partage de code : non pour l'instant.** Les deux applis compilent `Sources/*.swift` indépendamment (chacune a sa copie de `Socle.swift`, `L10n.swift`, `SplashScreen.swift`). Deux recommandations :

- Écrire le client REST dans un fichier **autonome** `DiscordClient.swift` (aucune dépendance à `ModState`), pour pouvoir le recopier plus tard à la manière de Socle (`sync_apps.sh`) si hERALD en a besoin.
- Brancher les deux applis par leur **contrat existant**, pas par du code : en étape 3, nEXUSWATCH peut déposer dans `~/Library/Application Support/hERALD/Inbox` un fichier `herald-changes` qui enregistre, sur la publication « annonce » concernée, un retour `comment` (nombre de réponses/réactions sous un message de `#announcements`). hERALD continue d'ignorer tout ce qui n'est pas son format ; même logique que `crash_events.jsonl` entre sKYCRASH et mORTEX.

---

## 3. Accès technique à Discord

### Principe : un robot Discord officiel, en lecture seule

- **Seul secret : le jeton du robot** (`Authorization: Bot <jeton>`). **Jamais de jeton d'utilisateur, jamais d'automatisation du compte de Stéphan** (contraire aux conditions de Discord). L'appli vérifie à la connexion que `GET /users/@me` renvoie `bot: true` ; un jeton d'utilisateur serait de toute façon refusé (401) avec le préfixe `Bot`.
- **API REST uniquement, pas de passerelle (Gateway).** Une interrogation périodique suffit (pas besoin du temps réel) et il n'y a pas de connexion permanente à maintenir. Conséquence : le robot apparaît « hors ligne » dans la liste des membres, ce qui est discret.
- Base `https://discord.com/api/v10` ; `User-Agent: DiscordBot (https://github.com/starbudweiser/nEXUSWATCH, <version>)` (format documenté `DiscordBot ($url, $versionNumber)`).

### Autorisations minimales

| Besoin | Réglage |
|---|---|
| Portée d'invitation | `bot` seulement (pas de commandes) |
| Permissions | **View Channel** (1 024) + **Read Message History** (65 536) = **66 560**. Aucune permission d'écriture, de gestion ni de modération. |
| Intention privilégiée | **Message Content** à activer dans le portail. Elle concerne aussi l'API REST : sans elle, `content`, `embeds`, `attachments`, `components` reviennent **vides** (hors messages mentionnant le robot). |
| Vérification Discord | **Non requise** : le robot est dans un seul serveur (< 100) ; l'intention s'active par simple interrupteur (drapeau `GATEWAY_MESSAGE_CONTENT_LIMITED`, 1 << 19). La vérification n'est exigée qu'à partir de 100 serveurs. |
| Limites de débit | 50 requêtes/s en global, en-têtes `X-RateLimit-*`, 429 avec `Retry-After` ; blocage IP après 10 000 requêtes invalides en 10 min. Notre usage (≈ 1 à 20 requêtes par cycle de 15 min) est négligeable. Règles : suivre `Retry-After`, **arrêter net sur 401/403** (jeton révoqué), ne jamais boucler. |

### Stockage de la clé

Trousseau macOS, comme les clés IA : nouveau compte `discord` dans le service existant (`Keychain.set(token, "discord")`). Lue après l'ouverture de la fenêtre (comme la clé TypeSafe), jamais écrite dans `state.json` ni `discord.json`, jamais affichée (champ sécurisé ; après enregistrement, seulement « ••••• » et un bouton « Remplacer »), jamais journalisée, jamais passée au processus MCP.

### Création du robot par l'utilisateur (aide à afficher dans les réglages, 4 langues)

1. <https://discord.com/developers/applications> → **New Application** (nom libre, par exemple « nEXUSWATCH »).
2. Onglet **Bot** : **Reset Token** → copier le jeton (affiché une seule fois) dans le champ de l'appli ; désactiver **Public Bot** (personne d'autre ne peut l'inviter) ; activer **Message Content Intent**.
3. Coller l'**Application ID** dans l'appli : elle fabrique le lien d'invitation `https://discord.com/oauth2/authorize?client_id=<ID>&scope=bot&permissions=66560` et le copie/ouvre.
4. Dans Discord, choisir le serveur (il faut « Gérer le serveur », ce qu'a le propriétaire) → **Autoriser**.
5. Retour dans l'appli : **Tester la connexion**. Elle appelle `GET /users/@me` (jeton valide, `bot: true`), `GET /applications/@me` (drapeau 1 << 19 présent, sinon message précis « activez Message Content Intent »), `GET /users/@me/guilds` (serveur trouvé automatiquement, plus besoin de copier l'identifiant : à confirmer à l'essai pour un jeton de robot) puis `GET /guilds/{id}/channels` pour lister les forums.
6. Si un forum est privé ou a des permissions propres, donner au rôle du robot **Voir le salon** + **Lire l'historique** sur ce salon.

### Appels nécessaires (tous en lecture)

| Besoin | Appel |
|---|---|
| Salons, forums, étiquettes disponibles | `GET /guilds/{id}/channels` (`type` 15 = forum, `available_tags`) |
| Propriétaire du serveur (= Stéphan) | `GET /guilds/{id}` → `owner_id` |
| Fils actifs (tous forums, 1 requête) | `GET /guilds/{id}/threads/active` — `last_message_id`, `applied_tags`, `message_count`, `thread_metadata` |
| Fils archivés (première synchronisation, puis de temps en temps) | `GET /channels/{forum}/threads/archived/public` (pagination `before`). **À tester** : la documentation ne cite que les salons texte/annonces, l'usage sur un forum est courant mais non garanti. |
| Messages d'un fil | `GET /channels/{thread}/messages?limit=100&after=<dernier lu>` (le message d'ouverture a le même identifiant que le fil) |
| Pièces jointes | champs `attachments[]` : `filename`, `size`, `content_type`, `url` |

Stratégie : à chaque cycle, **une** requête (fils actifs) ; les messages ne sont relus que pour les fils dont `last_message_id` a changé. Les liens de pièces jointes (CDN signé, durée limitée) sont téléchargés **tout de suite**, jamais conservés comme liens.

### Conformité et données de tiers

- Les messages sont des données personnelles de tiers : **tout reste sur le Mac**, rien n'est republié, rien n'est envoyé ailleurs par défaut. À écrire dans la section Confidentialité du README (en/fr) et à retirer du « sans compte ni clé API » actuel pour le seul module Discord (le module est **désactivé par défaut**, sans jeton il n'apparaît pas).
- **À vérifier avant d'activer toute IA externe sur Discord** : la Politique développeur de Discord (page `support-dev.discord.com`, inaccessible à cette étude : erreur 403) et le traitement des données par TypeSafe. Discord indique ne pas autoriser l'entraînement de modèles d'IA sur les messages des utilisateurs ; je n'ai pas pu lire la clause exacte de la politique développeur. Par prudence : **classement local par défaut**, tri Jev ou agent IA sur Discord en option séparée, désactivée, avec avertissement.
- Les journaux de plantage contiennent souvent le nom d'utilisateur du joueur dans les chemins (`C:\Users\...`) : ne les afficher que localement.

---

## 4. Fonctions proposées, par ordre de valeur

Rappel : la **modération reste à l'AutoMod de Discord** ; le module ne modère pas, ne répond pas, n'écrit rien (comme hERALD : « il prépare et suit »).

| # | Fonction | Valeur pour le temps de Stéphan | Comment |
|---|---|---|---|
| 1 | **Nouveaux fils par forum/appli** : liste « non lus » par forum, badge, notification groupée | Voir tout ce qui arrive sans ouvrir Discord | `threads/active` + non-lu (`d:<fil>` / `m:<message>`) |
| 2 | **Fils sans réponse du support**, avec ancienneté (« 26 h sans réponse ») | C'est la file de tri elle-même | Aucun message de `ownerId`/`team` après l'ouverture |
| 3 | **Étiquettes** (Solved, Needs info, Bug, Crash…) lues depuis `applied_tags` : filtres « À compléter », « Résolus », « Résolu probable mais pas étiqueté » (le dernier message de l'auteur dit « fixed/thanks »; l'étiquette se pose à la main sur Discord) | Nettoyage rapide | `LocalAudit.solvedWords` réutilisé |
| 4 | **Journaux de plantage de `crash-logs`** : pièces jointes `.log/.txt` téléchargées dans `~/Library/Application Support/nEXUSWATCH/Discord/crash-logs/<fil>/`, bouton « Analyser dans sKYCRASH » | Le diagnostic le plus long à faire à la main | Voir dépendance sKYCRASH ci-dessous |
| 5 | **Regroupement avec les bug reports Nexus** : un fil lié à un mod rejoint le plan de `LocalAudit` (comptage « N rapports » = Nexus + Discord), même problème détecté par mots-clés (puis Jev en option), fils Discord ajoutés au `get_mod_report`/`get_fix_prompt` | Un seul plan de correction par mod | Adaptateur `asPost`, `forum.modId` |
| 6 | **Tri par priorité, en local** : critique/haute/moyenne/basse + action proposée (répondre, demander les logs, analyser le crash, marquer résolu, suivre). Score = mots-clés crash/DLL/lancement (déjà dans `LocalAudit`), journal joint, nombre de participants distincts (« moi aussi »), version courante du mod citée, ancienneté sans réponse, étiquette Bug/Crash. Langue détectée avec `NLLanguageRecognizer` (Apple, local, gratuit) pour repérer FR/ES/IT | Ordonner la file sans service payant | Réutilise l'algorithme existant ; aucun appel réseau |
| 7 | **Réponses types** à copier dans le presse-papiers (« merci de joindre votre crash log », « précisez votre version de macOS/CrossOver »), en anglais et en français ; l'utilisateur colle lui-même sur Discord | Gagne du temps sans que l'appli écrive | Texte local, aucune écriture Discord |
| 8 | **Notifications discrètes** : une seule notification récapitulative par cycle (« 3 fils sans réponse depuis plus de 24 h »), niveau d'interruption `.passive`, sans son, seuils réglables, jamais pour le premier chargement ; badge du Dock en option | Informer sans harceler | Extension de `notify()` |
| 9 | `ideas` : classement des idées par nombre de participants/réactions ; `aide-fr` filtré par langue | Moindre | Plus tard |
| 10 | **Pont hERALD** : dépôt `herald-changes` dans `Inbox` pour les annonces | Moindre | Étape 3, facultatif |

Modération (suppression, exclusion, verrouillage, pose d'étiquettes) : **hors périmètre**. Si un jour on veut poser une étiquette « Solved » depuis l'appli, il faudra ajouter la permission « Manage Threads » au robot : décision à prendre à part, jamais par défaut.

### Dépendance : sKYCRASH et les journaux de tiers

sKYCRASH n'a pas d'interface en ligne de commande ni de schéma d'URL (je n'y ai trouvé que `QApplication(sys.argv)`, sans traitement d'argument de fichier) ; il analyse les journaux de ses dossiers configurés. Surtout, il **recoupe le journal avec l'installation et la dernière sauvegarde de l'utilisateur** : appliqué au journal d'un autre joueur, la « fiche d'installation vérifiée » serait fausse. Il faut donc, côté sKYCRASH, un mode « journal de tiers » (ouvrir un fichier sans recoupement local), ou sinon une simple copie/ouverture du fichier avec un avertissement. C'est un petit chantier séparé, à planifier avec l'étape 3. En attendant, nEXUSWATCH peut déjà : télécharger le journal, extraire en local les repères utiles (version du jeu, DLL en cause citées dans la pile) avec les mots-clés de `LocalAudit`, et ouvrir le dossier dans Finder.

### Quelques réglages Discord qui rendent le tri presque gratuit (sans code)

- Dans chaque forum de support : étiquettes `Bug`, `Crash`, `Question`, `Needs info`, `Solved`, **« exiger une étiquette »** à la création, et un **guide de publication** qui demande version de l'appli, version de macOS/CrossOver, étapes, journal. Classer par étiquette est plus fiable que par mots-clés.
- Étiquette appliquée par l'auteur du fil ou par Stéphan : le module la lit, il ne la pose pas.

---

## 5. Effort, risques, coût, découpage

### Estimation

Environ 1 400 lignes de Swift (+ 30 % de l'appli) : client REST ≈ 250, modèle/stockage/rafraîchissement ≈ 300, vues ≈ 500, MCP ≈ 60, textes ≈ 60 clés × 4 langues, plus la mise à jour du README/CHANGELOG (en/fr) et la section « À propos » déjà en place. Estimation : **7 à 9 jours de travail au total** (3 + 3 + 3), hors chantier sKYCRASH (1 à 2 jours). Modèle conseillé : Sonnet pour toute l'exécution, Opus seulement pour valider l'architecture de l'étape 1 et le mode « journal de tiers » de sKYCRASH.

### Coût

**Gratuit** : API Discord gratuite, aucun service payant, aucun compte de plus que le portail développeur (gratuit). Tri local par défaut ; seule option payante : Jev/agent IA (clé de l'utilisateur), désactivée par défaut.

### Risques

| Risque | Gravité | Parade |
|---|---|---|
| Message Content Intent non activé : textes vides | Moyenne | Détection par `GET /applications/@me` + message d'aide précis |
| `threads/archived/public` non garanti pour les forums | Faible | Test en étape 1 ; repli : fils actifs seuls (les fils archivés se rouvrent dès qu'on y répond et reviennent dans la liste active) |
| Fuite du jeton | Moyenne | Trousseau seulement ; robot sans permission d'écriture ; « Reset Token » en cas de doute |
| Politique développeur de Discord et IA externe | Moyenne | Local par défaut ; lecture de la politique avant d'ouvrir Jev/IA aux messages Discord |
| Données personnelles de tiers (messages, noms, journaux de plantage) | Moyenne | Stockage local uniquement, rien de republié, README mis à jour, purge des fils anciens (90 jours), bouton « Effacer les données Discord » |
| Bruit : un module qui ajoute du travail au lieu d'en enlever | Moyenne | Notifications récapitulatives, seuils, file « à traiter » en haut, rien d'autre au premier plan |
| Journaux de tiers analysés avec l'installation de Stéphan (faux diagnostics) | Haute si ignoré | Mode « journal de tiers » dans sKYCRASH avant d'automatiser |
| Taille de l'état | Faible | `discord.json` séparé, messages tronqués, purge |
| Appli générique : ne pas coder le serveur de Stéphan en dur (règle « build vierge ») | Moyenne | Aucun identifiant, lien ni nom de salon dans le code ; correspondance forum → mod saisie dans les réglages, suggestion par nom (`support-<nom>`) |
| Promesse actuelle « ni clé API ni connexion » | Faible | Module facultatif, décrit à part ; le reste de l'appli reste sans compte |

### Interface (règles Socle à respecter)

À relire dans le README de Socle avant de dessiner : totalement plat (ni ombre ni dégradé), un seul bouton principal ambre par écran (« Actualiser » ; « Ouvrir sur Discord » en secondaire), cartes de synthèse sur une ligne avec « … » (À traiter · Sans réponse · Journaux · Nouveaux), 24 px de marge intérieure, liste/détail avec `SplitLayout` existant, états vides et erreurs utiles (« Impossible de joindre Discord… »), fenêtre par défaut sans rien de tronqué dans les 4 langues, bulles d'aide pour le guide de création du robot, filigrane de la colonne de gauche inchangé. Dans tous les textes, les noms d'applis (mORTEX, sKYCRASH, nEXUSWATCH…) prennent la couleur du logo pour leur initiale (aide existante : `Socle.brand`) ; la couleur de chaque autre appli est à définir dans une petite table (seules celles de nEXUSWATCH et de mORTEX sont connues ici). Aucune écriture sur Discord : l'appli propose « Répondre sur Discord » qui ouvre le fil (`https://discord.com/channels/<serveur>/<fil>`), comme « Répondre sur Nexus ».

### Découpage en 3 étapes livrables

**Étape 1 — « Voir » (≈ 3 jours, v1.4.0).** Test de faisabilité réel d'abord (une demi-journée : créer le robot, vérifier `users/@me/guilds`, l'intention de contenu et les fils archivés d'un forum). Puis : réglages (jeton au Trousseau, aide à la création, test de connexion, choix du serveur et des forums), `DiscordClient.swift` autonome, `discord.json`, rafraîchissement parallèle, entrée « Discord » dans la barre latérale avec liste/détail des fils (non lu, auteur, étiquettes, sans-réponse), notification récapitulative discrète, 4 langues, README/CHANGELOG. Valeur : fonctions 1, 2, 3 et 8. Livrable seul, utile dès ce jour.

**Étape 2 — « Trier » (≈ 3 jours, v1.5.0).** Lien forum → mod, onglet Discord par mod, classement local par priorité avec action proposée, suivi local (`Follow`) et notes, réponses types, fils Discord dans l'audit, le rapport A4, `get_mod_report`/`get_fix_prompt` et nouveaux outils MCP. Valeur : fonctions 5, 6, 7.

**Étape 3 — « Diagnostiquer » (≈ 3 jours + 1 à 2 jours côté sKYCRASH, v1.6.0).** Téléchargement des journaux de `crash-logs`, repères extraits en local, ouverture dans sKYCRASH (mode journal de tiers), regroupement des crashs identiques entre fils, option Jev/agent IA pour Discord (après lecture de la politique développeur), pont hERALD (`Inbox`), `ideas` et `aide-fr`. Valeur : fonctions 4, 9, 10.

---

## Résultats du test réel (02/11/2026, robot « nEXUSWATCH », lecture seule)

Script jetable hors dépôt, jeton lu dans `~/.config/nexuswatch/discord.env` (droits 600), aucun contenu de message affiché.

| Point | Résultat |
|---|---|
| `GET /users/@me` | 200, `bot: true` |
| `GET /applications/@me` | 200 ; drapeau `GATEWAY_MESSAGE_CONTENT_LIMITED` (1 << 19) **présent**, `bot_public: false` |
| `GET /users/@me/guilds` avec jeton de robot | **200** : le serveur est trouvé tout seul (plus besoin de copier son identifiant) |
| `GET /guilds/{id}` | 200, `owner_id` présent |
| `GET /guilds/{id}/channels` | 200 : 7 forums (type 15), étiquettes visibles : `Question`/`Solved` sur les forums de support, `Solved`/`Needs info` sur `crash-logs`, aucune sur `ideas` et `aide-fr` |
| `GET /guilds/{id}/threads/active` | 200, 0 fil (serveur vide pour l'instant) |
| `GET /channels/{forum}/threads/archived/public` | **200 sur les 7 forums** (donc l'appel fonctionne sur un forum ; 0 fil, contenu non vérifié) |

| Fil de test publié dans `support-nexuswatch` | vu dans `threads/active` (1 fil, bon forum) |
| `GET /channels/{fil}/messages` | 200 ; message d'utilisateur reçu **avec son texte** (intention de contenu effective en REST) |

Seul point non testé : une pièce jointe réelle (champs documentés : `id`, `filename`, `size`, `url`, `content_type`). À vérifier au premier journal posté dans `crash-logs`.

---

## Constats annexes (hors sujet, à traiter à part)

- Le README de nEXUSWATCH dit toujours « Python 3.12 avec PyQt6 et PyInstaller » pour la compilation, alors que `build_app.sh` compile du Swift avec `swiftc` : texte obsolète à corriger.

---

## Résumé en 5 lignes et recommandation

1. nEXUSWATCH a déjà tout ce qu'il faut (non-lus, badge, audit par priorité, MCP, Trousseau, Socle) : un fil de forum Discord se comporte comme un post Nexus.
2. Accès par un **robot officiel en lecture seule** (View Channel + Read Message History = 66 560, Message Content Intent par simple interrupteur sous 100 membres, API REST sans passerelle) ; le jeton reste dans le Trousseau, jamais de jeton d'utilisateur.
3. Valeur maximale pour peu de temps : fils nouveaux, **fils sans réponse**, étiquettes, puis classement local par priorité fusionné avec les bug reports Nexus ; journaux de plantage vers sKYCRASH ensuite (qui demande un mode « journal de tiers »).
4. hERALD n'est pas le bon endroit (sortant, sans suivi en continu) : pas de code partagé, seulement son `Inbox` en option ; client Discord écrit à part pour être recopiable.
5. Coût nul, 7 à 9 jours en 3 étapes (Voir → Trier → Diagnostiquer) ; risques maîtrisables (données de tiers, politique développeur avant toute IA externe).

**Recommandation : GO dans nEXUSWATCH**, en commençant par un test d'une demi-journée (robot de test + les trois points à confirmer), puis l'étape 1 seule ; décider des étapes 2 et 3 après quelques semaines d'usage réel.
