# nEXUSWATCH

Surveille un mod Nexus Mods sans ouvrir sa page : stats, posts, bugs et fichiers. Réglé par défaut sur
[Skyrim Mac Toolkit](https://www.nexusmods.com/skyrimspecialedition/mods/196272).

- **Stats** : endorsements, téléchargements, DL uniques (somme des fichiers), version, progression sur 24 h.
- **Posts** : derniers fils (3 pages) avec leurs réponses ; badge « Nouveau », vos propres messages sont lus d'office.
- **Bugs** : tous les rapports avec statut Nexus, messages complets, suivi local (À trier → Correctif publié),
  notes de test et « Copier pour correctif » (rapport Markdown dans le presse-papiers).
- **Fichiers** : téléchargements par fichier et état du contrôle antivirus Nexus (quarantaine signalée).
- Vérification automatique (5 min à 3 h), notification macOS et badge du Dock ; la fenêtre fermée, l'appli continue.

Aucune clé API ni connexion : stats et fichiers viennent de l'API GraphQL publique de Nexus ; posts et bugs sont lus
dans un WKWebView invisible qui charge la page publique du mod (widgets `CommentContainer`, `ModBugsTab`,
`ModBugReplyList`). État local : `~/Library/Application Support/nEXUSWATCH/state.json`.

## Compilation

```bash
./build_app.sh
```

Xcode Command Line Tools suffisent (SwiftUI, macOS 14+, binaire universel). Signature stable par `../_tools/sign_app.sh`.
Interface : design system Socle (`Sources/Socle.swift`, recopié par `Socle/sync_apps.sh`).
