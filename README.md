# nEXUSWATCH

**For mod authors: keeps an eye on your Nexus Mods page — stats, posts, bug reports and files — without opening it.**  
*Pour les auteurs de mods : surveille votre page Nexus Mods — stats, posts, rapports de bugs et fichiers — sans l'ouvrir.*

🇬🇧 [English](#-english) · 🇫🇷 [Français](#-français)

---
## 🇬🇧 English

### What it does

Publishing a mod means checking its page again and again for new comments, bug reports or a file stuck in the virus scan. nEXUSWATCH does it for you in the background and notifies you when something new comes in. No API key, no login: it only reads the mod's public pages.

### Features

- **Stats**: endorsements, downloads, unique downloads, version and 24-hour progress.
- **Posts**: latest threads with their replies, "New" badge, your own messages marked as read.
- **Bugs**: every report with its Nexus status and full messages, local tracking (To triage → Fix released), test notes and **Copy for a fix** (Markdown report to the clipboard).
- **Files**: downloads per file and Nexus virus-scan status (quarantined files flagged).
- Automatic check (5 min to 3 h), macOS notification and Dock badge; keeps running when the window is closed.
- Interface in **English, French, Italian and Spanish** (follows your Mac's language).

### Screenshots

![Mod stats, quarantine alert and posts](docs/screenshots/01_home.png)
*Mod stats, quarantine alert and posts*

### Requirements

A Mac with **Apple Silicon** (M1 or later), **macOS 14 Sonoma** or later. No Python, no Wine, no virtual machine needed.

### Installation

1. Download the zip from Nexus Mods (or from the GitHub releases) and unzip it.
2. Move **nEXUSWATCH.app** to your **Applications** folder.
3. First launch: the app is signed with a personal certificate but **not notarized by Apple**, so macOS blocks it. Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to nEXUSWATCH, then confirm. On macOS 14 or earlier you can also right-click the app → **Open** → **Open**.
4. Still blocked? In Terminal: `xattr -dr com.apple.quarantine /Applications/nEXUSWATCH.app`

### How to use

1. Open nEXUSWATCH, click the gear icon and paste the URL of your mod page.
2. Pick the check interval and turn on notifications.
3. Read new posts and bugs in their tabs; **Reply on Nexus** opens the right page.

### FAQ

**"The mod page is not responding".**  
Nexus sometimes shows a Cloudflare check: wait a moment and click **Refresh**.

### Privacy

Only the mod's public pages and the public Nexus Mods GraphQL API are read, without account or API key. Read status, bug tracking and notes stay on your Mac (~/Library/Application Support/nEXUSWATCH).

### Building from source

Requires Python 3.12 with PyQt6 and PyInstaller. From the repository folder:

```bash
./build_app.sh
```

### License

Released under the **MIT License**: free to use, modify and share. Part of the **Skyrim Mac Toolkit**, a set of modding tools built for Skyrim players on Mac.

---

## 🇫🇷 Français

### À quoi ça sert

Publier un mod, c'est retourner sans cesse sur sa page pour guetter un commentaire, un rapport de bug ou un fichier bloqué par l'antivirus. nEXUSWATCH s'en charge en arrière-plan et vous prévient dès qu'il y a du nouveau. Ni clé API ni connexion : il ne lit que les pages publiques du mod.

### Fonctions

- **Stats** : endorsements, téléchargements, DL uniques, version et progression sur 24 h.
- **Posts** : derniers fils avec leurs réponses, badge « Nouveau », vos propres messages lus d'office.
- **Bugs** : tous les rapports avec leur statut Nexus et leurs messages complets, suivi local (À trier → Correctif publié), notes de test et **Copier pour correctif** (rapport Markdown dans le presse-papiers).
- **Fichiers** : téléchargements par fichier et état du contrôle antivirus Nexus (quarantaine signalée).
- Vérification automatique (5 min à 3 h), notification macOS et badge du Dock ; l'appli continue fenêtre fermée.
- Interface en **français, anglais, italien et espagnol** (suit la langue du Mac).

### Captures d'écran

![Stats du mod, alerte de quarantaine et posts](docs/screenshots/01_home.png)
*Stats du mod, alerte de quarantaine et posts*

### Configuration requise

Un Mac **Apple Silicon** (M1 ou plus récent), **macOS 14 Sonoma** ou plus récent. Ni Python, ni Wine, ni machine virtuelle.

### Installation

1. Téléchargez le zip sur Nexus Mods (ou dans les releases GitHub) et décompressez-le.
2. Placez **nEXUSWATCH.app** dans votre dossier **Applications**.
3. Premier lancement : l'appli est signée avec un certificat personnel mais **pas notarisée par Apple**, macOS la bloque donc. Ouvrez **Réglages Système → Confidentialité et sécurité**, descendez et cliquez sur **Ouvrir quand même** à côté de nEXUSWATCH, puis confirmez. Sous macOS 14 ou antérieur, vous pouvez aussi faire clic droit sur l'appli → **Ouvrir** → **Ouvrir**.
4. Toujours bloquée ? Dans le Terminal : `xattr -dr com.apple.quarantine /Applications/nEXUSWATCH.app`

### Utilisation

1. Ouvrez nEXUSWATCH, cliquez sur la roue dentée et collez l'URL de la page de votre mod.
2. Choisissez l'intervalle de vérification et activez les notifications.
3. Lisez les nouveaux posts et bugs dans leurs onglets ; **Répondre sur Nexus** ouvre la bonne page.

### Questions fréquentes

**« La page du mod ne répond pas ».**  
Nexus affiche parfois un contrôle Cloudflare : patientez un instant puis cliquez sur **Actualiser**.

### Confidentialité

Seules les pages publiques du mod et l'API GraphQL publique de Nexus Mods sont lues, sans compte ni clé API. L'état lu, le suivi des bugs et les notes restent sur votre Mac (~/Library/Application Support/nEXUSWATCH).

### Compiler depuis les sources

Nécessite Python 3.12 avec PyQt6 et PyInstaller. Depuis le dossier du dépôt :

```bash
./build_app.sh
```

### Licence

Publié sous **licence MIT** : libre d'utilisation, de modification et de partage. Fait partie du **Skyrim Mac Toolkit**, un ensemble d'outils de modding pensés pour les joueurs de Skyrim sur Mac.
