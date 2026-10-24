# Heartware : le guide complet

Tout ce que fait l'app, comment elle protège tes données, et comment la compiler toi-même. Pour l'installer, deux lignes suffisent : voir le [README](../README.md).

<p align="center">
  <img src="screenshots/dashboard.png" alt="Tableau de bord : score de santé, stockage, mémoire, processeur, batterie, analyse intelligente, activité en direct, conseils et les outils du profil, les plus utilisés d'abord" width="900">
</p>

<table>
  <tr>
    <th>Lanceur (⌥Espace)</th>
    <th>Convertisseur</th>
  </tr>
  <tr>
    <td valign="top" align="center"><img src="screenshots/launcher-panel.png" alt="Lanceur : la recherche « facture » trouve un dossier et des PDF en un instant, avec l'aperçu du dossier sélectionné à droite"></td>
    <td valign="top"><img src="screenshots/converter.png" alt="Convertisseur : photos HEIC à convertir en JPEG sans localisation, vidéos en cours de compression"></td>
  </tr>
  <tr>
    <th>Traducteur</th>
    <th>Raccourcis</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/translator.png" alt="Traducteur : un texte français traduit en anglais sur le Mac, la liste des langues téléchargées ou à télécharger et l'historique"></td>
    <td valign="top"><img src="screenshots/hotkeys.png" alt="Raccourcis : des apps, un dossier, un site et une action ouverts par ⌃⌥⌘ + une lettre, avec des suggestions"></td>
  </tr>
  <tr>
    <th>Nettoyage du système</th>
    <th>Protection et confidentialité</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/cleanup.png" alt="Nettoyage : fichiers inutiles classés par catégorie, avec le détail des caches d'applications et les éléments verrouillés par une app ouverte"></td>
    <td valign="top"><img src="screenshots/protection.png" alt="Protection : analyse antimalware avec les signatures d'Apple, menaces trouvées (un logiciel publicitaire, un faux lecteur vidéo, un faux agent Apple) prêtes à être neutralisées"></td>
  </tr>
  <tr>
    <th>Mises à jour</th>
    <th>Assistant Claude</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/updates.png" alt="Mises à jour : paquets Homebrew, apps Sparkle, App Store et macOS, avec le journal d'une mise à jour en direct"></td>
    <td valign="top"><img src="screenshots/assistant.png" alt="Assistant : Claude explique pourquoi le Mac rame et propose deux actions à exécuter d'un clic"></td>
  </tr>
  <tr>
    <th>Boîte à outils</th>
    <th>Presse-papiers</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/toolbox.png" alt="Boîte à outils : sélecteur de couleur avec formats HEX, RGB, HSL, SwiftUI et nuances"></td>
    <td valign="top"><img src="screenshots/clipboard.png" alt="Presse-papiers : historique de textes, images et fichiers avec épingles et recherche"></td>
  </tr>
  <tr>
    <th>Réseau</th>
    <th>Fenêtres</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/network.png" alt="Réseau : Wi-Fi, adresses, test de débit et latence"></td>
    <td valign="top"><img src="screenshots/windows.png" alt="Fenêtres : moitiés, quarts, tiers et écrans, chacun avec son raccourci modifiable"></td>
  </tr>
  <tr>
    <th>Automatisations</th>
    <th>Applications</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/automation.png" alt="Automatisations : nettoyage planifié, purge de la Corbeille, rangement de Téléchargements et historique de santé"></td>
    <td valign="top"><img src="screenshots/apps.png" alt="Applications : inventaire avec taille, version, dernière ouverture, apps Intel et apps de l'App Store"></td>
  </tr>
  <tr>
    <th>Espace de stockage</th>
    <th>Optimisation</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/storage.png" alt="Stockage : carte proportionnelle du dossier personnel et liste de son contenu"></td>
    <td valign="top"><img src="screenshots/performance.png" alt="Optimisation : le Boost, température, consommation, fréquences des cœurs, apps passées sur les cœurs économes et diagnostic"></td>
  </tr>
  <tr>
    <th colspan="2">Films et séries</th>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="screenshots/cinema.png" alt="Films et séries : la recherche « marée » liste films et séries, la fiche du film choisi avec sa note, sa bande-annonce sans pub et les plateformes où le regarder en France" width="760"></td>
  </tr>
  <tr>
    <th colspan="2">Menu d'état</th>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="screenshots/menubar-panel.png" alt="Menu d'état : processeur, mémoire, disque, batterie, réseau, apps gourmandes, interrupteurs Caféine, presse-papiers et fenêtres, actions express" width="300"></td>
  </tr>
</table>

<sub>Captures réalisées avec des données fictives (mode `--demo`) : ni les apps, ni les fichiers, ni les personnes montrés n'existent.</sub>

> *English: an all-in-one native macOS app that lives in the background: maintenance (cleanup, security audit, startup items, uninstaller, disk map), a Raycast-like launcher with instant file search and Quick Look previews, a file converter, an on-device or Claude-powered translator, app hotkeys, everyday tools, clipboard history, updates, network tools, window management, automations and a Claude assistant. The interface is in French.*

> Projet personnel et non officiel, sans lien avec Anthropic, MacPaw ni Raycast. « Claude » est une marque d'Anthropic, « CleanMyMac » une marque de MacPaw.

## Ce que fait l'app

### Une app à ta mesure

Au premier lancement (puis sous le nom de l'app, dans la barre latérale), tu coches ce que tu fais avec ton Mac, même plusieurs : **L'essentiel**, **Études**, **Travail**, **Création**, **Loisirs** ou **Touche-à-tout**. L'entretien reste pour tous ; les outils de ton profil sont mis en avant, les autres se rangent dans **Autres outils**, en bas de la barre latérale. Rien ne disparaît : le lanceur trouve tout, et un clic droit garde ou range n'importe quel outil. Sans profil, tout reste affiché.

L'app s'adapte aussi à ce dont tu te sers, sans rien envoyer nulle part : un outil ouvert trois jours sur un mois (ou lancé depuis le lanceur) rejoint la barre, un outil allumé (historique du presse-papiers, automatisations, raccourcis, limite de batterie) y reste, et un outil de ton profil oublié depuis 45 jours se range, jamais dans le mois qui suit ton choix. Le panneau **Ton profil** dit pour chaque outil pourquoi il est là.

<p align="center">
  <img src="screenshots/profile-panel.png" alt="Panneau Ton profil : six profils à cocher (Études coché), puis chaque outil avec la raison de sa place : Pour tous, Études, Tu t'en sers, Activé, Hors profil, Pas ouvert depuis 45 j" width="720">
</p>

### Entretien

| Section | Contenu |
| --- | --- |
| **Tableau de bord** | Score de santé sur 100, stockage, mémoire, processeur, batterie (santé, cycles), activité en direct, **analyse intelligente** qui passe tout en revue en une minute, conseils classés par utilité, et **tes outils** avec leur état, les plus utilisés d'abord |
| **Nettoyage du système** | Caches d'apps et de macOS, journaux, fichiers temporaires, Xcode (données dérivées, appareils, archives, simulateurs), caches npm / Yarn / pip / Homebrew / CocoaPods / Go / Cargo…, dépendances de **projets endormis** (`node_modules`, `.build`, `Pods`, `target`), caches de l'**app Claude** et journaux de **Claude Code**, caches des navigateurs et des apps Electron, Corbeille, pièces jointes Mail, installeurs oubliés, sauvegardes d'iPhone |
| **Protection et confidentialité** | **Antimalware** avec les 572 signatures d'XProtect appliquées à tout ce qui est déjà sur le Mac (analyse rapide ou complète), traces de familles connues, apps modifiées après leur signature, et neutralisation (arrêt puis Corbeille) ; **bilan de 40 points** en sept familles (défenses de macOS, mises à jour, accès, partages, réseau intercepté, secrets laissés en clair, navigation) avec une note sur 100, deux niveaux d'exigence et des **corrections en un clic** ; tout ce qui **démarre seul** (agents, services, ouverture à la connexion, cron, extensions) avec les usurpateurs d'Apple et les téléchargeurs repérés ; **qui t'observe** (programmes qui lisent le clavier, extensions de navigateur, ports ouverts, autorisations) ; **protection en temps réel** (démarrage, Téléchargements, caméra, micro, DNS et proxy) ; effacement des **traces** (éléments récents, téléchargements, vignettes, Terminal, historique et cookies des navigateurs) |
| **Optimisation** | **Boost** (les apps en arrière-plan passent sur les cœurs économes : modes Intelligent, Performance et Fraîcheur, réflexe thermique, mode Jeu de macOS), **capteurs** sans mot de passe (température du processeur et du GPU, consommation du Mac en watts, fréquences des cœurs, ventilateurs), diagnostic « ce qui ralentit ou chauffe ton Mac », **benchmark** (processeur, GPU en images par seconde, mémoire, SSD, réactivité, test du Boost, endurance thermique, historique), réglages de **fluidité** réversibles (animations, Dock, Finder, compteur FPS des jeux, fréquence des écrans), moniteur temps réel, éléments au démarrage, tâches de maintenance |
| **Mises à jour** | **Homebrew** en un clic (sortie en direct, annulable ; les paquets qui demandent un mot de passe sont signalés avec la commande à copier), apps **Sparkle** (lecture de leur flux, l'app s'installe elle-même), **App Store** et **macOS** |
| **Applications** | Inventaire avec taille, version, dernière ouverture, apps **Intel** qui passent par Rosetta, désinstallation **complète** (l'app et tous ses fichiers dans `~/Library`), restes d'apps déjà supprimées |
| **Espace de stockage** | Carte proportionnelle cliquable de n'importe quel dossier, gros fichiers anciens, **doublons** (comparaison du contenu par SHA-256) |

### Outils

| Section | Contenu |
| --- | --- |
| **Lanceur** | `⌥Espace` partout, comme Spotlight ou Raycast : apps classées par fréquence, **fichiers trouvés instantanément** avec leur **aperçu Quick Look** à côté (voir plus bas), parcours des dossiers (`~/Documents/`, ⇥ pour entrer), recherche dans le contenu (`dans devis cuisine`), **calculatrice** (virgule française acceptée), **unités** (`10 km en miles`, `5 Go en Mo`, `100 °F en °C`), **traduction** (`trad bonjour en espagnol`, ou le **Traducteur directement dans le panneau** : tu tapes, la traduction suit, ↩ la copie, ⇥ change de langue, ⌘↩ demande à Claude), heure dans le monde, veille, verrouillage, mode sombre, éjection des disques, `quitter Slack`, recherche web (`g`, `ddg`, `yt`, `gh`, `wiki`, `maps`, `gtrad`), **lien YouTube collé** (aperçu de la vidéo à droite, format, qualité et extrait juste en dessous, ↩ télécharge), réglages système, emoji, et **toutes les actions de l'app** (`caféine 1h`, `mdp 24`, `#ff8800`, `qr …`, `cb …`, `gauche`, `? une question pour Claude`…) |
| **Raccourcis** | Un raccourci clavier pour ouvrir **n'importe quelle app** (appuie de nouveau : elle se masque), un fichier, un dossier, un site ou **n'importe quelle action de l'app** : la liste « Tout associer » les propose toutes, et dans le lanceur **⌘K** donne un raccourci au résultat choisi (affiché ensuite à droite, comme dans Raycast). Un raccourci sur « Traducteur » ou « Traduire le presse-papiers » ouvre directement le panneau de traduction. Un clic sur une suggestion donne `⌃⌥⌘` + une lettre libre du nom, adaptée à ton clavier (AZERTY ou QWERTY). `⌘` seul marche aussi, comme dans Raycast (`⌘Q` pour une capture d'écran) : le raccourci passe alors devant celui des apps, Heartware compris (qui se quitte alors par son menu), et sa ligne le rappelle. Seul `⌘⇥` reste à macOS. Aucune autorisation nécessaire |
| **Convertisseur** | **Aperçu du résultat réel avant d'enregistrer** : l'opération tourne pour de vrai sur le fichier choisi, dans un dossier temporaire, et le rendu s'affiche à côté de l'original (images, PDF page par page, vidéo dans le lecteur de macOS, sur un morceau au choix (10 s, 30 s, 1 min ou tout) à partir du passage voulu, avec la taille estimée ; son et GIF en entier, son, documents, contenu d'une archive, texte reconnu), avec la taille avant et après. Enregistrement dans **Téléchargements** (par défaut), à côté des originaux ou dans un dossier choisi. Glisser-déposer, lanceur, Dock ou clic droit dans le Finder (**Services › Convertir avec Heartware**). Images (HEIC, JPEG, PNG, AVIF, TIFF, GIF, BMP, PDF, JPEG 2000 ; redimensionner, compresser, **retirer le GPS** sans recompresser), vidéo (H.264, HEVC, MOV ↔ MP4 sans réencodage, **vidéo → GIF**, extraction de l'audio), audio (AAC, ALAC, WAV, AIFF, FLAC), PDF (**fusionner** PDF et images dans l'ordre voulu, glissé à la poignée, avec les pages choisies de chacun, un signet par document et ses propres signets dessous, une page blanche pour l'impression recto verso si besoin ; découper, pivoter, alléger, images ↔ PDF), documents (Word, RTF, HTML, TXT, ODT, Markdown → HTML ou PDF), ZIP, **renommage par lot** avec aperçu, **OCR** en français et en anglais, QR codes. MP3, OGG, MKV ou WebM si `ffmpeg` est installé |
| **Remplir et signer** | Ouvre un PDF, un formulaire ou la **photo d'un document** (glisser-déposer, lanceur, ou **⌘K › Remplir et signer…** sur un PDF) : les **champs du formulaire** deviennent des cases où écrire, cocher ou choisir (⇥ passe au suivant), et pour un PDF sans champs ou un scan on écrit **où l'on veut** (texte, coche, croix, point, date du jour, double-clic pour écrire). **Signature et paraphe** dessinés à la souris ou au trackpad, tapés dans une écriture manuscrite ou importés d'une photo (le papier devient transparent), gardés sur ce Mac pour la prochaine fois ; un cadre de signature se remplit d'un clic, un paraphe se recopie sur toutes les pages. Tout se déplace, se redimensionne, s'annule (⌘Z). L'original ne bouge pas : une copie « … – signé.pdf » est enregistrée à côté, en **version finale** (tout intégré aux pages) ou, pour un formulaire sans signature, encore modifiable ; un PDF protégé garde son mot de passe. Mail s'ouvre avec la copie en pièce jointe si tu veux l'envoyer. C'est une signature simple, comme une signature manuscrite scannée |
| **Vidéos YouTube** | Colle un lien (ici ou dans le lanceur) : miniature, titre, chaîne et durée s'affichent, puis tu choisis **MP4** (de 360p à la 4K, en H.264 lisible partout jusqu'en 1080p, avec la taille de chaque qualité), **MP3** ou **M4A** avec la pochette, la vidéo entière ou **un extrait à la seconde** (deux poignées sur la durée, ou le début et la fin tapés). Une file de téléchargements avec la progression (pourcentage et temps restant, extraits compris), l'annulation et « Afficher dans le Finder », suivie aussi depuis n'importe quelle page (en bas de la barre latérale) et depuis la barre des menus, où un anneau se remplit à côté de l'icône ; enregistrement dans **Téléchargements** ou un dossier choisi. S'appuie sur `yt-dlp` et `ffmpeg`, installés et mis à jour d'un clic avec Homebrew |
| **Films et séries** | Tape un titre (ici ou dans le lanceur : `film …`, `série …`, `regarder …`) : la fiche (année, durée, note, réalisation, distribution), la **bande-annonce sans pub** et **où le regarder** dans ton pays, par abonnement, location ou achat. Tes plateformes cochées passent en tête et ↩ ouvre la première. Données de The Movie Database (TMDB) et de Wikidata, avec ta **clé TMDB gratuite**, gardée dans le Trousseau ; seules les offres légales sont listées |
| **Traducteur** | Deux moteurs : **Apple, sur ton Mac**, hors ligne et instantané (les langues se téléchargent une fois depuis la page), ou **Claude** pour le ton (neutre, formel, familier) et les nuances. Détection de la langue, inversion, historique local, et traduction en direct dans le lanceur |
| **Boîte à outils** | Pipette et conversions de couleurs, mots de passe et phrases de passe (copie confidentielle effacée au bout de 90 s), empreintes SHA et MD5 de fichiers, Base64, URL, JSON, casse, compteur de mots, Lorem ipsum, UUID, horodatages, et **Caféine** pour empêcher la veille (aussi depuis le menu d'état) |
| **Presse-papiers** | Historique des textes, images et fichiers copiés, épingles, recherche, rappel depuis le lanceur (`cb …`). **Désactivé tant que tu ne l'actives pas**, il ignore les mots de passe et ce qui est copié depuis un gestionnaire de mots de passe |
| **Réseau** | Wi-Fi (signal, bruit, canal, débit), adresses locales et publique, **test de débit** (`networkQuality` d'Apple), latence en direct, **ports ouverts** et l'app qui les écoute |

### Contrôle et Claude

| Section | Contenu |
| --- | --- |
| **Fenêtres** | Moitiés, tiers, deux tiers, quarts, plein écran, centrer, écran suivant ou précédent, taille précédente, au clavier (`⌃⌥` + flèches…) ou depuis le lanceur. Appuyer de nouveau fait défiler ½, ⅔ et ⅓. Raccourcis modifiables, marge réglable |
| **Automatisations** | Nettoyage planifié (seulement le « sans risque »), purge de la Corbeille au-delà de N jours, **rangement de Téléchargements** par règles, historique de santé du Mac en graphiques, journal. Tout est désactivé au départ et chaque automatisation montre un **aperçu à blanc** avant de s'activer. Elles tournent tant que l'app est ouverte (fenêtre fermée comprise) |
| **Assistant Claude** | Pose tes questions sur ton Mac en langage naturel : Claude explique et propose jusqu'à trois actions de l'app, que tu lances d'un clic. « Demander à Claude » est aussi dans le clic droit d'un processus, d'un agent de démarrage ou d'un dossier, et dans le lanceur (`?`) |
| **Menu d'état** | Dans la barre des menus : le téléchargement YouTube en cours (anneau et pourcentage à côté de l'icône, annulation dans le panneau), processeur, mémoire, disque, réseau, batterie, apps gourmandes, interrupteurs (Caféine, presse-papiers, fenêtres) et actions express. Alertes optionnelles si le disque est presque plein ou la mémoire saturée |

### Le Refuge

Un petit chamois naît d'un buisson de myrtilles et vit dans l'app. Prendre soin du Mac (un passage de l'analyse, un nettoyage, une menace écartée, un outil découvert, la tournée du jour) lui fait cueillir des **myrtilles** : données, elles le font grandir en six stades, de cabri à Chamois d'or ; gardées dans le panier, elles paient la **boutique** (pelages, accessoires, décoration de sa chambre, objets de saison). Il a son humeur, sa maison où chaque outil est une pièce, ses médailles, sa photo souvenir, et peut se promener sur le bureau, en haut des fenêtres (désactivé au départ). Rien ne s'achète avec de l'argent, il ne tombe jamais malade et ne perd rien de ce qu'il a gagné ; tout reste sur ce Mac.

<p align="center">
  <img src="screenshots/refuge-room.png" alt="Le Refuge : la chambre du chamois, ses myrtilles dans le panier et son humeur" width="860">
</p>

## Le Boost, mesuré

macOS range chaque processus dans une bande de priorité. Celle de l'arrière-plan (`PRIO_DARWIN_BG`, celle de `taskpolicy -b`) fait tourner un processus sur les **cœurs économes** de la puce, avec des accès disque et réseau ralentis. Le Boost y place ce que tu ne regardes pas, et rend sa priorité à une app **dès qu'elle revient au premier plan** (sans attendre), dès qu'elle joue ou enregistre du son, ou quand tu changes de mode. Mesuré sur un MacBook Air M2 sans ventilateur, avec huit tâches lourdes en fond :

| | Sans Boost | Avec le Boost |
| --- | --- | --- |
| Vitesse de l'app au premier plan | 70 % de sa vitesse seule | 102 % |
| Consommation du Mac | 17 W | 5,8 W |
| Température du processeur, après quelques secondes | 83 °C et en hausse | 54 °C |
| Attente d'une tâche urgente avant d'avoir un cœur (99 % des cas) | 4,7 ms : des images sautent | 0,1 ms |

Les tâches de fond continuent, plus lentement. L'onglet **Benchmark › Test du Boost** refait cette mesure sur ton Mac en dix secondes.

- **Intelligent** : seules les apps qui s'emballent (plus de 15 % de processeur pendant 20 s) passent sur les cœurs économes ; tout l'arrière-plan quand macOS signale que la puce chauffe, et le mode Performance quand un jeu est au premier plan.
- **Performance** : tout ce qui est en arrière-plan, pour un jeu, un export ou une compilation ; peut forcer le **mode Jeu** de macOS (avec Xcode installé).
- **Fraîcheur** : comme Performance, et l'économie d'énergie de macOS (mot de passe), remise comme avant en quittant ce mode.

Jamais ralentis : l'app au premier plan et ce qu'elle a lancé (une compilation depuis le Terminal), les apps qui jouent ou enregistrent du son (appels, musique), celles qui surveillent le clavier, le Finder, le Dock et tout composant de macOS, ce que macOS garde déjà lui-même en arrière-plan, et une liste d'apps dont le travail en fond compte (OBS, Final Cut Pro, Logic Pro, DaVinci Resolve, HandBrake, Blender, Xcode, machines virtuelles…), modifiable. Chaque processus déplacé est noté avec son heure de démarrage : un numéro de processus réutilisé n'est jamais touché, tout est rétabli quand l'app quitte, et au lancement suivant après un plantage. Le gouverneur ne travaille qu'une dizaine de millisecondes toutes les dix secondes, et pas du tout quand le Boost est désactivé.

## La sécurité, mesurée

**Les signatures d'Apple, partout.** XProtect, l'antimalware intégré à macOS, ne vérifie un fichier qu'au moment où on l'ouvre (et XProtect Remediator, de temps en temps, une liste de familles). Heartware contient un interpréteur YARA écrit en Swift qui applique les propres règles d'Apple (`XProtect.yara` et `XPScripts.yr`, mises à jour par macOS lui-même, rien n'est téléchargé) à tout ce qui est déjà sur le disque : apps, bibliothèques, scripts, installeurs, programmes lancés au démarrage, ce qui tourne en ce moment. Une règle qu'il ne comprendrait pas est ignorée : elle ne peut que manquer une détection, jamais en inventer une.

| Mesuré sur un MacBook (macOS 27.2, XProtect 5367) | Résultat |
| --- | --- |
| Règles d'Apple comprises | 572 sur 572, compilées en 0,13 s |
| Règles reconnaissant leur propre échantillon, fabriqué en mémoire (`--selftest`) | 377 sur 377 |
| Analyse rapide (démarrage, processus, apps, Téléchargements, cachettes habituelles) | 5,8 s |
| Analyse complète : 36 758 programmes, bibliothèques et scripts | 76 s, sur la moitié des cœurs |
| Fausses alertes sur ces 36 758 fichiers | 0 |

À côté des signatures : les fichiers exacts que laissent des familles documentées (EvilQuest, Silver Sparrow, AppleJeus, la porte dérobée d'Atomic Stealer…), les apps dont la signature ne correspond plus au contenu (copies piratées ou infectées), les extensions Safari et les développeurs bloqués par Apple, et les comportements d'intrus : un agent qui se fait passer pour Apple, qui télécharge puis exécute du code, qui se cache dans un dossier partagé, un `~/.zshrc` piégé. **Neutraliser** arrête les services liés, termine les processus et met les fichiers à la Corbeille, où tu peux les reprendre.

**Le bilan** reprend l'esprit des référentiels de sécurité pour macOS (CIS Benchmark, NIST mSCP) en 40 points lisibles sans mot de passe, chacun pesant selon sa gravité dans une **note sur 100**. Au-delà des réglages classiques (FileVault, coupe-feu et mode furtif, Gatekeeper, SIP, volume système scellé, verrouillage, partages, AirDrop), il regarde ce que les logiciels malveillants modifient : **proxy et serveurs DNS** inconnus, **certificats racine** approuvés pour les sites web, fichier hosts, **profils de configuration**, navigateurs **réglés de force** ; et ce que les voleurs de données copient en premier : **clés SSH** sans phrase de passe, identifiants **en clair** (Git, AWS, Docker, npm, GitHub CLI…), clés d'API restées dans l'historique du Terminal. Le niveau **Renforcé** ajoute les recommandations plus strictes (mode furtif, récepteur AirPlay, compte du quotidien sans droits d'administrateur…). Quand c'est sûr, **Corriger** applique la correction après confirmation : une commande fixe, jamais construite à partir d'une donnée du Mac, et macOS demande lui-même le mot de passe quand il le faut.

**En temps réel**, sur les événements de macOS et sans minuterie : un agent ou un service qui s'ajoute au démarrage est vérifié aussitôt, chaque app, script ou installeur qui arrive dans Téléchargements passe aux signatures, la caméra et le micro préviennent quand ils s'allument, un serveur DNS ou un proxy qui apparaît est signalé.

Ce n'est pas un antivirus d'entreprise : rien ne part dans un nuage, une image disque ou une archive n'est pas ouverte pour être analysée, et une famille inconnue d'Apple ne se repère qu'à son comportement.

## Les garde-fous

Un nettoyeur qui supprime trop, c'est pire que pas de nettoyeur. Heartware est prudent par construction :

- **Rien n'est supprimé sans ton accord.** Les analyses sont en lecture seule ; chaque nettoyage passe par une confirmation qui dit ce qui part et comment.
- **Une seule porte de sortie.** Toutes les suppressions passent par `Remover`, qui refuse tout ce qui n'est pas dans ton dossier personnel (et `~/Library` lui-même, les trousseaux, Mail, Messages, iCloud Drive, Photos…). `Heartware --selftest` vérifie ces règles et que le catalogue ne propose jamais un chemin protégé ; le script de build le lance à chaque compilation.
- **La Corbeille d'abord.** Seuls les caches et journaux que les apps recréent sont supprimés directement. Tes fichiers, les apps désinstallées, les doublons partent dans la Corbeille.
- **Jamais d'écrasement.** Conversions, renommages et rangements écrivent toujours un nouveau fichier (`photo 2.jpg` si `photo.jpg` existe) ; tes originaux ne bougent pas.
- **Une seule porte de confirmation.** Les commandes risquées du lanceur ou de l'assistant demandent toujours ton accord ; Claude ne peut proposer que des actions sans danger.
- **Les liens ne décident pas pour toi.** Un lien `heartware://run/…` (une page web, un mail, une autre app) ne lance seul que la navigation et les analyses ; toute autre action te demande, « Annuler » étant la réponse par défaut, et une action risquée ne part jamais d'un lien.
- **Les droits de l'app restent à l'app.** Lancée par un autre programme (`open -a … --args`), elle ignore tous les modes en ligne de commande ; les outils tiers (Claude Code, ffmpeg, Homebrew…) tournent sans hériter de ses autorisations (accès complet au disque, accessibilité) ; leur environnement est nettoyé des variables qui injectent du code.
- **Tes secrets ne s'écrivent pas.** Le presse-papiers ignore les clés d'API, jetons, clés privées, codes à usage unique et mots de passe probables ; ses fichiers ne sont lisibles que par toi et restent hors des sauvegardes. Les réglages des automatisations sont scellés : modifiés hors de l'app, elles se coupent.
- **Les menaces aussi passent par la Corbeille.** `Remover.quarantine` a ses propres garde-fous : jamais macOS, l'app elle-même, ses données, un autre compte ni un dossier comme `~/Documents` ou `/Library/LaunchAgents` en entier.
- **Les apps ouvertes sont respectées.** Les caches de Claude, Chrome, Slack… sont verrouillés tant que l'app tourne.
- **Un journal** de chaque action : `~/Library/Logs/Heartware/actions.log`.

### Rien ne sort sans ton clic

Tes fichiers, ton historique de presse-papiers et l'état de ton Mac restent sur ton Mac. Les connexions partent quand tu cliques, et chacune dit ce qu'elle fait. Une seule exception, que tu peux couper : Heartware demande à GitHub s'il existe une nouvelle version de lui-même (voir plus bas).

| Quand | Vers qui | Quoi |
| --- | --- | --- |
| « Vérifier » dans Mises à jour, bilan de sécurité | Apple (`softwareupdate`, `itunes.apple.com/lookup`), les flux Sparkle de tes apps, Homebrew | Les noms et versions de tes apps |
| « Lancer le test » dans Réseau | Apple (`networkQuality`) | Un test de débit |
| « Afficher » l'IP publique | `api.ipify.org` | Aucune donnée : il te renvoie ton adresse |
| Une question à l'assistant | Anthropic, via ton abonnement Claude ou ta clé API | Ta question ; l'état du Mac (charge, espace, apps gourmandes) seulement si tu actives « Consulter l'état du Mac » |
| « Traduire avec Claude » | Anthropic, via ton abonnement Claude ou ta clé API | Le texte à traduire (la traduction Apple, elle, reste sur ton Mac) |
| Une recherche web dans le lanceur | Ton navigateur | Ce que tu as tapé, comme dans la barre d'adresse |
| Un lien YouTube collé dans le lanceur ou dans Vidéos YouTube, puis « Télécharger » | YouTube (`youtube.com`, `i.ytimg.com`), par l'app et par `yt-dlp` | Le numéro de la vidéo : son titre, sa miniature et ses qualités, puis la vidéo elle-même si tu la télécharges |
| Trois minutes après le lancement, puis toutes les 6 h (désactivable) | GitHub (`api.github.com`) | Rien : l'app lit le numéro de sa dernière version publiée et, s'il est plus récent, la liste des changements |
| « Mettre à jour » dans le panneau de nouvelle version | GitHub (`github.com`) | Rien : l'app télécharge l'archive publiée |

## La recherche de fichiers, en un millième de seconde

Spotlight met une à quatre secondes à répondre à une recherche par nom : trop lent pour suivre la frappe. Le lanceur garde donc **en mémoire les noms des fichiers** de ton dossier personnel et d'iCloud Drive (environ 2 Mo pour 100 000 fichiers), lus une fois en arrière-plan en quelques secondes, puis **tenus à jour en direct** : macOS (FSEvents) signale les dossiers qui changent et seuls ceux-là sont relus.

| Mesuré sur un Mac de 116 000 fichiers | Temps |
| --- | --- |
| Spotlight, nom contenant « facture » | 0,9 s |
| Spotlight, nom contenant « png » | 3,6 s |
| Index du lanceur, n'importe quelle recherche | 1 à 3 ms |
| Construction de l'index (une fois, au lancement) | 2,8 s |

Le classement favorise le nom exact, puis le début du nom, puis le début d'un mot ; ensuite les fichiers modifiés récemment, ceux du Bureau, des Documents, des Téléchargements et d'iCloud Drive, et ceux que tu ouvres souvent. Un mot peut viser un dossier : `edf mars` trouve `Factures/EDF/mars.pdf`. Les dossiers cachés, `~/Library` et les dépendances (`node_modules`, `Pods`…) sont laissés de côté, et l'intérieur des paquets (`.app`, `.photoslibrary`…) n'est pas parcouru. L'index ne quitte jamais la mémoire de ton Mac. Spotlight reste utilisé pour chercher dans le contenu (`dans …`).

Pour emporter plusieurs fichiers d'un coup, **⌘-clic** (ou **⌘↩** au clavier) les coche, même d'une recherche à l'autre ou de dossiers différents ; ⎋ les décoche. Glissés hors de la fenêtre, ils se rassemblent en une pile qui se balance au bout du pointeur, et sont **copiés** là où tu les lâches (Finder, Bureau, Mail…), jamais déplacés. « Afficher dans le Finder » passe alors à **⌘R**.

## Toujours là, sans prendre de place

Comme Raycast, Heartware n'a pas d'icône dans le Dock : il vit dans la barre des menus et derrière `⌥Espace`. Il s'ouvre à l'ouverture de session sans afficher de fenêtre (réglable), et sa fenêtre se rouvre depuis la mascotte de la barre des menus, le lanceur ou en relançant l'app. Les réglages permettent de garder l'icône dans le Dock, toujours ou seulement quand la fenêtre est ouverte. Au repos, fenêtre ouverte et tous les modules actifs : environ 1,7 % de processeur et 93 Mo de mémoire.

## Mises à jour de Heartware

Trois minutes après le lancement (jamais dans les minutes qui suivent un réveil), puis toutes les 6 h tant que l'app tourne en arrière-plan, Heartware demande à GitHub le numéro de sa **dernière version publiée** (la plus récente de la [page des versions](https://github.com/Olima34/Heartware/releases/latest)). Chaque push sur `main` en devient une : une fois la compilation et les autotests réussis sur GitHub, la CI publie l'app sous un nouveau numéro, environ 7 minutes après le push. S'il est plus récent que le tien, la fenêtre de Heartware s'ouvre avec un panneau en son centre, l'app légèrement assombrie derrière : tant que tu n'y as pas répondu (ou fermé avec Échap), le reste de la fenêtre ne réagit plus. Le panneau liste **ce qui a changé**, c'est-à-dire les commits entre ta version et la nouvelle (les fusions sont laissées de côté, les points « - … » des messages deviennent des détails).

<p align="center"><img src="screenshots/selfupdate-window-panel.png" alt="La fenêtre de Heartware assombrie, avec au centre le panneau de nouvelle version : ce qui change, puis Ignorer cette version, Plus tard et Mettre à jour" width="760"></p>

- **Mettre à jour** télécharge `Heartware.zip` depuis la version publiée (seulement depuis les versions de ce dépôt sur GitHub, que l'app interroge par son numéro : changer le nom du dépôt ne coupe pas les mises à jour), vérifie son empreinte SHA-256, obligatoire (celle que GitHub a calculée à la publication), puis sa **signature Ed25519** (voir plus bas), l'ouvre, contrôle que c'est bien Heartware dans la version annoncée et que sa signature est intacte. Rien n'est remplacé avant que tu cliques sur **Installer et relancer** : l'ancienne version part alors à la Corbeille, la nouvelle prend sa place et se rouvre. Le téléchargement s'annule à tout moment ; une erreur dit ce qui s'est passé et ce qui n'a pas changé.
- **Plus tard** (ou ✕, ou Échap) ferme le panneau : il revient au prochain lancement (pas dans les 24 h qui suivent tant que l'app reste ouverte). Pendant un téléchargement, le fermer le masque seulement : il revient quand la nouvelle version est prête.
- **Ignorer cette version** : le panneau ne revient tout seul qu'à la version suivante. La page Mises à jour la montre toujours.
- **Les autorisations de macOS.** Chaque version publiée est signée par le même certificat de publication (auto-signé, pas un certificat de développeur Apple) : macOS reconnaît la nouvelle version comme la même app et garde l'Accessibilité, l'accès complet au disque et l'accès au trousseau, sans rien te demander. Seule la première mise à jour vers une version signée ainsi, depuis une copie qui ne l'est pas (signée « ad hoc »), les redemande une dernière fois ; le panneau le dit avant l'installation. Pour le trousseau, c'est la version en place qui passe ses clés (le sceau des automatisations, la clé d'API) à la nouvelle, juste avant l'installation : sans identifiant d'équipe d'Apple, macOS lie chaque clé au code exact du programme qui l'a créée, et il redemanderait sinon le mot de passe de ta session après chaque mise à jour, même après « Toujours autoriser ». Les clés passent par un canal privé entre les deux versions, jamais par un fichier ; la nouvelle vérifie qu'elle les reçoit bien de Heartware, signé comme elle, puis les réécrit à son nom. Si ce passage échoue, rien n'est perdu : macOS demande une fois, comme avant. Une copie compilée sur ce Mac avec le certificat local de `scripts/setup_signing.sh` (voir [plus bas](#garder-les-autorisations-après-chaque-compilation)) garde le sien : la nouvelle version est re-signée avec lui. Une fois la version vérifiée, le panneau te demande alors le mot de passe du trousseau de signature (celui choisi avec le script, pas celui de ta session) : il est déverrouillé le temps de signer, puis reverrouillé aussitôt. Un mot de passe refusé se ressaisit ; **Installer sans re-signer** garde la signature publiée (macOS redemandera alors les autorisations une fois) ; **Annuler** n'installe rien.
- **Quand la mise à jour sur place est impossible** (app lancée depuis le code source, depuis une image disque, ou dans un dossier qui demande un mot de passe administrateur), le panneau le dit et propose la page de la version ou la commande d'installation à copier.

La vérification automatique se coupe dans **Réglages › Général** ou sur la page **Mises à jour**, où « Vérifier » la relance à la main.

**Les versions sont signées.** L'empreinte de GitHub prouve seulement que l'archive est celle qui a été publiée, pas qui l'a publiée : un jeton GitHub volé suffirait à remplacer l'archive ou à publier une fausse version. La CI signe donc chaque `Heartware.zip` avec une clé Ed25519 qui ne quitte pas les secrets de GitHub (`CMC_UPDATE_KEY`, dans l'environnement `release`, réservé à `main` et aux étiquettes `v*`). Elle publie la signature à côté de l'archive, dans `Heartware.zip.sig`. L'app connaît la clé publique (`UpdatesSelfSignature.publicKey`) et n'installe jamais une archive sans signature valide. `scripts/install.sh` la vérifie aussi quand le Mac a OpenSSL 3 (`brew install openssl` ; l'openssl fourni avec macOS ne connaît pas Ed25519). La signature se fait dans un job qui ne compile rien, et elle est écrite dans le workflow lui-même : pour toucher à ce qui voit la clé, il faut un jeton qui a le droit de modifier les workflows. Elle ne protège pas d'un code piégé poussé sur `main`, qui serait compilé puis signé comme le reste, mais ce code resterait visible dans l'historique.

**Les numéros de version.** Une version porte le numéro de la dernière étiquette `vX.Y.Z` augmenté du nombre de commits faits depuis : la v0.3.0 suivie de 6 commits donne la 0.3.6, puis chaque push avance le dernier chiffre (0.3.7, 0.3.8… 0.3.10). Une copie compilée chez toi avec `./scripts/build_app.sh` porte le même numéro que la version que GitHub publie pour le même commit. Elle n'est donc pas invitée à « se mettre à jour » vers ce qu'elle contient déjà, et une copie compilée sur un commit plus récent non plus. Si plusieurs pushes arrivent pendant qu'une version se publie, seul le dernier est publié : il contient les autres.

## Compiler toi-même

La version prête à l'emploi se télécharge depuis la [page des versions](https://github.com/Olima34/Heartware/releases/latest) (voir le [README](../README.md)). Pour compiler depuis le code :

Prérequis : macOS 14 (Sonoma) ou plus récent, et les outils de développement d'Apple (Xcode 15.3 ou plus, ou simplement `xcode-select --install`).

```bash
git clone https://github.com/Olima34/Heartware.git
cd Heartware
./scripts/build_app.sh
```

Le script compile en release, vérifie les garde-fous, génère l'icône, assemble `Heartware.app` et l'installe dans `~/Applications` (`--no-install` la laisse dans `build/`, `--zip` produit une archive, `--universal` compile pour Apple Silicon et Intel). Le numéro de version vient de `HW_VERSION`, sinon de `scripts/version.sh` (la dernière étiquette `vX.Y.Z` plus les commits depuis) ; le commit compilé est noté dans l'app (`HeartwareCommit`), qui s'en sert pour lister ce qu'une nouvelle version change et pour ne pas proposer une version plus ancienne que ce qu'elle contient.

Publier une version : il suffit de pousser sur `main`. Le workflow `Build` compile l'app universelle (Apple Silicon et Intel) et vérifie ses garde-fous. S'il réussit, il la dépose sur la page des versions sous le numéro suivant, avec en notes la liste des commits depuis la version précédente. Le bouton du README et `scripts/install.sh` vont l'y chercher, et les apps déjà installées la trouvent au lancement ou dans les 6 h. Pour changer de numéro mineur ou majeur, pousse une étiquette avec le commit : `git tag v0.4.0 && git push origin main v0.4.0`. Le workflow `Release` publie alors la 0.4.0, et les pushes suivants donnent 0.4.1, 0.4.2…

Les deux workflows signent d'abord l'app avec le certificat de publication, puis l'archive. Le certificat, auto-signé et valable 20 ans, se crée une fois avec `./scripts/setup_release_signing.sh` (il faut `gh`, connecté) : sa clé privée, créée en mémoire, part directement dans le secret `CMC_CODESIGN_IDENTITY` de l'environnement `release` et n'existe nulle part ailleurs ; son empreinte SHA-1 est écrite dans `UpdatesSelfSigning.swift` (`releaseCertificate`), à commiter. La CI refuse de publier si le secret manque, s'il ne correspond pas à cette empreinte, ou si l'empreinte disparaît alors que la version précédente en avait une. Sans empreinte, l'app est publiée « ad hoc », comme avant. Secret perdu ou supprimé : relance le script, qui en crée un nouveau ; chaque copie installée redemandera alors une fois ses autorisations.

Les deux workflows signent ensuite l'archive avec le secret `CMC_UPDATE_KEY` (voir [Mises à jour](#mises-à-jour-de-heartware)) et refusent de publier si ce secret manque ou s'il ne correspond pas à la clé de la version précédente, celle que vérifient les copies installées. Une copie de la clé privée est rangée dans le trousseau de session du mainteneur, sous « Clean My Claude – clé de signature des versions ». Pour changer de clé, pousse d'abord une version qui embarque la nouvelle clé publique (dans `UpdatesSelf.swift` et `scripts/install.sh`) : la CI la signe encore avec l'ancienne. Remplace ensuite le secret (`gh secret set CMC_UPDATE_KEY --env release < nouvelle_clé.pem`). Une copie restée sur une version antérieure à ce passage, ou une clé perdue, oblige à réinstaller avec la commande d'installation.

### Les autorisations

Aucune n'est obligatoire : chacune est demandée dans la section qui en a besoin, au moment où tu t'en sers. Ou toutes d'un coup : **Réglages › Autorisations › Tout autoriser** (aussi sur l'écran d'accueil). macOS pose alors ses questions l'une après l'autre, puis ouvre Réglages Système au bon endroit pour les deux qui s'activent à la main (accès complet au disque et accessibilité) ; l'app attend que l'interrupteur soit mis, ou que tu cliques sur « Passer ».

| Autorisation | Pour quoi faire |
| --- | --- |
| **Accès complet au disque** (recommandé) | Voir la Corbeille, Mail, Safari et la liste des autorisations de tes apps, et indexer tes fichiers sans que macOS demande dossier par dossier |
| **Accessibilité** | Ranger les fenêtres au clavier, coller directement depuis l'historique du presse-papiers |
| **Bureau, Documents, Téléchargements** | Index des fichiers du lanceur, rangement de Téléchargements, conversions (inutile avec l'accès complet au disque) |
| **Piloter le Finder et Événements système** | Corbeille des apps installées par un administrateur, mode sombre, redémarrer, éteindre depuis le lanceur |
| **Localisation** | Afficher le nom du réseau Wi-Fi (ta position n'est jamais lue) |
| **Réseau local** | Mesurer la latence de ta box et des appareils de ton réseau |
| **Notifications** | Alertes de disque ou de mémoire, bilan des automatisations |

### Garder les autorisations après chaque compilation

Signée « ad hoc » (par défaut), l'app change d'identité à chaque compilation : macOS la prend pour une nouvelle app et oublie ses autorisations. Pour qu'il s'en souvienne, crée une fois pour toutes un certificat de signature local :

```bash
./scripts/setup_signing.sh
```

Le script crée un certificat auto-signé « Clean My Claude Dev » (valable 10 ans, aucun réglage de confiance modifié) et le range dans **un trousseau à part**, `~/Library/Keychains/cleanmyclaude-signing.keychain-db`, protégé par un mot de passe que tu choisis (pas celui de ta session). Ce trousseau se verrouille à la veille et après 5 minutes, et il n'est pas dans la liste des trousseaux que macOS parcourt : aucune app ne le voit. Sa clé privée est créée en mémoire, jamais écrite sur le disque, ne peut pas être exportée, et seul `codesign` peut s'en servir, une fois le trousseau déverrouillé.

Pourquoi pas le trousseau de session ? Il reste déverrouillé tant que ta session est ouverte. N'importe quel programme lancé sous ton compte pourrait alors faire signer par `codesign`, sans aucune fenêtre, une fausse app portant l'identifiant de Heartware. Elle aurait la même identité aux yeux de macOS, hériterait des autorisations que tu as données à Heartware (accès complet au disque, accessibilité) et pourrait lire ses éléments du trousseau, comme la clé d'API.

À chaque compilation, `build_app.sh` demande le mot de passe de ce trousseau dans le Terminal (sans Terminal, il le lit sur son entrée standard), signe l'app, puis reverrouille le trousseau, même si la compilation échoue. Les mises à jour de l'app le demandent dans leur panneau. Le mot de passe passe toujours par l'entrée standard de `security`, jamais par sa ligne de commande, que n'importe quel programme peut lire. Accorde ensuite les autorisations une dernière fois : elles restent acquises après chaque reconstruction et chaque mise à jour. Une autre identité reste possible avec `HW_SIGN_IDENTITY="…" ./scripts/build_app.sh`.

**Si tu avais déjà un certificat** créé par une version précédente du script, dans ton trousseau de session : relance `./scripts/setup_signing.sh`. Sa clé ne peut pas être déplacée. Le script en crée donc une nouvelle dans le trousseau à part, puis te propose de supprimer l'ancienne (rien n'est supprimé sans ton accord). Ta copie installée sera re-signée avec le nouveau certificat à la prochaine compilation ou mise à jour, et macOS te redemandera une dernière fois les autorisations. Tant que l'ancien certificat reste dans le trousseau de session, `build_app.sh` et `Heartware --dump --only updates` le signalent.

Pour tout retirer : `security delete-keychain ~/Library/Keychains/cleanmyclaude-signing.keychain-db`. Mot de passe oublié ? Supprime ce trousseau de la même façon et relance le script : macOS redemandera les autorisations une fois.

### Connecter l'assistant Claude

Deux possibilités, au choix dans la section **Assistant Claude** :

- **Ton abonnement Claude (Pro ou Max), sans clé API.** L'assistant passe par Claude Code, livré avec l'[app Claude](https://claude.ai/download). Clique sur « Connecter Claude » : un Terminal s'ouvre, tu valides dans le navigateur, c'est fait. Claude Code y tourne bridé : aucun outil, aucun accès à tes fichiers, aucune session conservée, une réponse au format imposé. Les messages comptent dans ton quota d'abonnement.
- **Une clé API Anthropic**, rangée dans ton Trousseau, facturée à l'usage (coût affiché après chaque réponse).

Modèles proposés : Opus (par défaut), Sonnet, Haiku et Fable.

### Piloter l'app depuis Raccourcis, Raycast ou le Terminal

```bash
open "heartware://launcher"                 # ouvre le lanceur
open "heartware://page/converter"           # ouvre une section
open "heartware://run/act_smart_scan"       # lance une commande du lanceur (les actions risquées demandent confirmation)
```

## Cinq thèmes, et le tien

Réglages (⌘,) › Apparence change toute l'app d'un clic, fenêtre, lanceur et menu d'état compris :

| Thème | Le style |
| --- | --- |
| **Atelier** | Le thème d'origine : papier chaud, titres à empattements, bleu Claude. Suit le mode clair ou sombre de macOS. |
| **Graphite** | Le contraire d'une app d'IA : gris neutres, une seule encre, angles droits, aucune ombre, ni icônes décoratives, ni mascotte, ni poussière derrière les titres. |
| **Phosphore** | Un vieux terminal : verre noir, lettres vertes, tout en chasse fixe, couleurs ANSI. Toujours sombre. |
| **Sorbet** | Pastel et joueur : police arrondie, angles très ronds, couleurs acidulées, ombres douces. Toujours clair. |
| **Minuit** | Bleu nuit profond, reflets violets et turquoise, titres fins, angles adoucis. Toujours sombre. |

« Créer mon thème » part de n'importe lequel et règle tout : le mode (comme macOS, clair ou sombre), les dix-neuf couleurs de chaque variante et les dix des graphiques (au sélecteur ou en hexadécimal, avec « Harmoniser » qui déduit les nuances du fond, du texte et de l'accent), la police des titres et du texte, leur graisse et leur taille, l'arrondi des angles, l'épaisseur des bordures, les ombres, les icônes décoratives (en couleur, monochromes ou masquées), le motif de caractères et la mascotte. Un thème se copie en JSON pour le sauvegarder ou le partager, et « Coller un thème » le recrée.

<table>
  <tr>
    <th>Graphite</th>
    <th>Phosphore</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/theme-graphite.png" alt="Tableau de bord en thème Graphite : gris neutres, angles droits, sans icônes ni mascotte"></td>
    <td valign="top"><img src="screenshots/theme-phosphore.png" alt="Tableau de bord en thème Phosphore : fond noir, texte vert en chasse fixe"></td>
  </tr>
  <tr>
    <th>Sorbet</th>
    <th>Minuit</th>
  </tr>
  <tr>
    <td valign="top"><img src="screenshots/theme-sorbet.png" alt="Tableau de bord en thème Sorbet : pastels, police arrondie, angles très ronds"></td>
    <td valign="top"><img src="screenshots/theme-minuit.png" alt="Tableau de bord en thème Minuit : bleu nuit, accents violets et turquoise"></td>
  </tr>
  <tr>
    <th colspan="2">Réglages › Apparence</th>
  </tr>
  <tr>
    <td colspan="2" align="center"><img src="screenshots/appearance-panel.png" alt="Réglages › Apparence : les cinq thèmes de base en miniature et la création d'un thème personnel" width="560"></td>
  </tr>
</table>

## Pour les développeurs

```bash
swift build
.build/debug/Heartware --selftest             # garde-fous de suppression et autotests de chaque module
.build/debug/Heartware --dump                 # ce que trouve chaque scanner, sans rien supprimer
.build/debug/Heartware --dump --only cleanup  # cleanup | security | apps | processes, ou le nom d'un module
.build/debug/Heartware --dump --storage ~/Developer --duplicates ~/Downloads
.build/debug/Heartware --snapshot out/        # rend chaque page en PNG (--page, --tab, --light, --theme graphite, --scale 2, --profile etudes,loisirs)
.build/debug/Heartware --ask "Pourquoi mon Mac chauffe ?" --model haiku   # une question à l'assistant
.build/debug/Heartware --translate "Merci pour ton aide" --to en --tone formal   # le traducteur, moteur Claude
.build/debug/Heartware --dump --only launcher # construit l'index des fichiers et chronomètre quelques recherches
.build/debug/Heartware --dump --only performance   # capteurs, énergie, réglages, et ce que chaque mode du Boost ralentirait
.build/release/Heartware --dump --only performance --bench --boost-test   # le benchmark et le test du Boost
.build/debug/Heartware --dump --only performance --boost-live-test   # le mode Performance pour de vrai, 3 s, vérifié dans le noyau
.build/debug/Heartware --update-check --as-version 0.2.0   # ce que GitHub publie, comparé à une version au choix
.build/debug/Heartware --update-install "build/essai/Heartware.app"   # met à jour cette copie de bout en bout, empreinte et signature vérifiées (sans relancer)
.build/debug/Heartware --demo                 # lance l'app avec des données fictives, sans lire le disque
```

`--demo` fonctionne aussi avec `--dump` et `--snapshot`. Les données de démonstration décrivent un Mac inventé : un dossier personnel fictif, des apps aux noms et icônes inventés, leurs caches, processus, agents de démarrage, mises à jour, conversions et historique de presse-papiers. En mode démo, aucun scanner ne lit le disque, aucune commande ni requête n'est lancée et `Remover` refuse toute suppression ; `--selftest --demo` le vérifie sur un fichier témoin. Les captures de ce README en sortent :

```bash
for p in dashboard cleanup protection performance apps storage menubar updates converter translator hotkeys toolbox clipboard network windows automation assistant cinema refuge; do
  .build/debug/Heartware --snapshot docs/screenshots --demo --scale 2 --page $p
done
.build/debug/Heartware --snapshot docs/screenshots --demo --scale 2 --page launcher --tab files --query facture
ffmpeg -loglevel error -y -i docs/screenshots/refuge.png -vf crop=iw:1160:0:12 docs/screenshots/refuge-room.png && rm docs/screenshots/refuge.png   # la chambre, en haut de la page
.build/debug/Heartware --snapshot docs/screenshots --demo --scale 2 --page appearance
for t in graphite phosphore sorbet minuit; do
  .build/debug/Heartware --snapshot /tmp/theme-$t --demo --page dashboard --theme $t && mv /tmp/theme-$t/dashboard.png docs/screenshots/theme-$t.png
done
rm docs/screenshots/menubar.png docs/screenshots/launcher.png docs/screenshots/onboarding-*-panel.png docs/screenshots/sidebar-panel.png docs/screenshots/selfupdate-panel.png \
   docs/screenshots/statusitem-panel.png docs/screenshots/clipboard-window-panel.png docs/screenshots/refuge-ceremony-panel.png
pngquant --quality 80-95 --force --ext .png docs/screenshots/*.png   # optionnel : divise le poids par quatre
```

Pendant `--snapshot`, les menus, champs de texte, interrupteurs, zones de dépôt et de défilement d'AppKit sont remplacés par des équivalents dessinés en SwiftUI : `ImageRenderer` les rendrait en rectangles jaunes ou vides.

Le code, en SwiftUI pur, sans dépendance :

```
Sources/Heartware/
├── App/        point d'entrée, scènes, modèle global, registre des modules, outils en ligne de commande
├── Core/       mesures système, tailles via fts(3), Shell, Remover, FileOps, HTTP, commandes du lanceur,
│               raccourcis globaux, panneaux flottants, stockage, Trousseau, notifications, planificateur
├── Features/   une section par dossier : Dashboard, Cleanup, Protection, Performance, Updates, Apps, Storage,
│               Launcher, Hotkeys, Converter, FillSign, Translator, Toolbox, Clipboard, Network, Windows, Automation,
│               Assistant, MenuBar
└── UI/         thèmes (catalogue, réglages, éditeur) et composants partagés avec ClaudeStats
```

Chaque module de `Features/` se branche sur `App/ModuleRegistry.swift` (commandes du lanceur, données de démo, autotests, captures, interrupteurs du menu d'état). Les règles pour en écrire un sont dans [`CLAUDE.md`](../CLAUDE.md).

Le thème Atelier reprend le design de [ClaudeStats](https://github.com/Olima34/ClaudeStats) : surfaces chaudes, titres en serif, accent bleu. La mascotte, un petit chamois dessiné en pixels, est la même dans tous les thèmes (`MascotFigure`, `UI/Components/Brand.swift`) : son pelage vient de la couleur d'alerte du thème, avec un contour sur les fonds clairs.

## Feuille de route

- Automatisations même quand l'app est fermée (agent de connexion)
- Vue en rayons de soleil pour la carte du disque
- Application notarisée par Apple (plus besoin d'« Ouvrir quand même ») et mises à jour automatiques
- Localisation en anglais

## Licence

[MIT](../LICENSE). Utilise-le à tes risques : relis ce que tu coches avant de nettoyer.
