# DESIGN SYSTEM — « GRAPHITE » · HYBRIDE ARC × macOS 27

> **À déposer à la racine (ou dans `design/`) de chaque projet.** Toute interface, vue ou composant généré dans ce projet applique ce document. Il décrit un langage visuel unique pour toutes mes apps : la matière et la profondeur de macOS 27 (verre, lumière, rayons concentriques), le cadrage d'Arc (contenu en retrait dans la fenêtre), et une retenue professionnelle sur la couleur.
>
> **Seule chose à personnaliser par projet :** la section 0.3 (couleur d'accent, nom, icône). Tout le reste est commun.

---

## 0. PRINCIPES

### 0.1 Les cinq règles qui priment sur tout le reste

1. **La couleur est une information, pas une décoration.** L'interface est graphite (neutres froids) à plus de 90 %. Une seule couleur d'accent par app. Chaque usage de couleur doit répondre à « qu'est-ce que ça signale ? ».
2. **La profondeur vient de la matière, pas de la couleur.** Verre dépoli, ombres douces, liseré spéculaire de 1 px en haut des surfaces. Jamais de halo coloré sous une carte, jamais de dégradé multicolore.
3. **Le natif d'abord.** Si la plateforme fournit le composant (SwiftUI, AppKit), on l'utilise et on le règle ; on ne le redessine pas. Les specs CSS ci-dessous servent aux apps web et de référence visuelle pour le natif (voir section 8).
4. **Les chiffres d'abord.** Ce sont des outils de travail : hiérarchie nette, densité maîtrisée, chiffres en `tabular-nums`, aucune décoration qui concurrence la donnée.
5. **Deux apparences à égalité.** Clair et sombre sont conçus ensemble ; le sombre est l'apparence de référence des maquettes, pas la seule.

### 0.2 Budget couleur (à respecter à l'écran, pas seulement dans le code)

| Usage | Couleur autorisée |
| --- | --- |
| Fonds, cartes, bordures, texte, icônes de navigation | Neutres uniquement |
| Élément de navigation actif | Fond neutre + **icône** en accent (le texte reste neutre) |
| Bouton primaire, focus, interrupteur activé, lien, sélection de ligne | Accent |
| Série principale ou valeur mise en avant d'un graphique | Accent ; les autres séries en neutres |
| Données catégorielles (catégories, modèles, familles) | Palette catégorielle sourdine, 6 teintes max + « Autres » en gris |
| États (succès, alerte, erreur) | Couleurs sémantiques, uniquement pour un état réel |
| Carte « vedette » (une seule par écran au maximum) | Liseré supérieur teinté accent |
| Lumière ambiante | Un halo accent très faible sous la sidebar, rien dans le contenu |

**Repère visuel :** sur une capture d'écran, l'accent occupe moins de 5 % de la surface. Si on le remarque avant les chiffres, il y en a trop.

**Interdits :** liserés de couleurs différentes par carte, `box-shadow` coloré (glow), texte en dégradé, mesh gradients saturés, fonds de carte teintés par catégorie, plus de deux teintes non neutres dans un même composant hors graphique catégoriel.

### 0.3 Personnalisation par projet

**Chamois** : accent **bleu acier**, celui de la montagne de l'icône (`#5B8DEF` en sombre, `#3773EB` en clair : thème Graphite de `UI/ThemeCatalog.swift`) ; nom « Chamois », icône la tête du chamois (`BrandMark`). Graphite pur est la variante « graphite pur » ci-dessous (sans accent, sélection à l'encre).

Dans ce projet, la règle SDK de `CLAUDE.md` passe avant la section 8 : rien au-delà de macOS 15 (la CI compile avec Xcode 16), donc ni `glassEffect` ni `#available(macOS 26, *)`. Le verre vient de `NSVisualEffectView` (fenêtre, panneaux) et des matériaux SwiftUI ; la bulle et les surfaces sont dans `UI/Components/Glass.swift`.

```css
:root {
  --accent-h: 220;    /* teinte de l'accent (HSL) : 220 = bleu acier (Chamois) ; 15 = terracotta (ClaudeStats) */
  --accent-s: 82%;
  --accent-l: 65%;    /* en sombre ; la version claire est dérivée plus bas */
}
```

Accents conseillés (un seul par app, choisi pour son identité, jamais deux) :
terracotta `#D97757` · bleu acier `#5B8DEF` · vert sauge `#5FA37A` · ambre `#D9A04A` · violet ardoise `#8B7FD1` · graphite pur (pas d'accent, sélection en blanc) pour les outils très sobres.

Option « voix » : une app éditoriale peut utiliser **New York** (serif système) pour les titres de page uniquement. Tout le reste reste en SF Pro.

---

## 1. ARCHITECTURE SPATIALE (ADN ARC + macOS)

L'app se comporte comme une fenêtre macOS 27, pas comme une page web.

1. **Fenêtre (App Shell)**
   - `display: flex; height: 100vh; overflow: hidden;`
   - En web : coins de fenêtre `--radius-window: 22px` (quand la fenêtre est simulée dans une maquette ou une app Electron/Tauri sans cadre).
   - Feux tricolores : `12px` de diamètre, espacés de `8px`, en haut à gauche de la sidebar (`top: 18px; left: 18px`). Couleurs système `#FF5F57`, `#FEBC2E`, `#28C840` avec un anneau intérieur `inset 0 0 0 0.5px rgba(0,0,0,0.2)`. Fenêtre inactive : les trois en `rgba(255,255,255,0.14)` (sombre) / `rgba(0,0,0,0.12)` (clair).
   - En natif : **ne jamais les dessiner**, utiliser ceux du système (voir section 8).

2. **Rail d'espaces (optionnel, apps multi-contextes uniquement)**
   - Rail vertical de `52px` à gauche de la sidebar, icônes `32×32px`, `border-radius: 9px`.
   - Icônes **monochromes** sur fond neutre `--fill-1` ; l'espace actif a un fond `--fill-3` et un point accent de `4px` à gauche. Pas de dégradés.

3. **Sidebar (verre)**
   - `width: 240px` (redimensionnable `200–280px`), transparente : elle laisse voir le matériau de la fenêtre (le fond d'écran flouté).
   - Matériau : `background: var(--glass-sidebar); backdrop-filter: blur(48px) saturate(140%);`
   - En-tête : nom de l'app (`15px`, `600`) + icône de l'app `20px`.
   - Titres de groupe : `11px`, `600`, `var(--text-tertiary)`, `padding: 14px 10px 4px`.
   - Items : `height: 30px; padding: 0 10px; border-radius: 8px; gap: 10px;` icône `16px` en `--text-secondary`, texte `13px` en `--text-secondary`.
   - Survol : fond `var(--fill-1)`.
   - Actif : la **bulle Liquid Glass** de la section 5.I (une seule pour toute la liste, elle glisse d'un item à l'autre), texte `--text-primary` en `500`, **icône en accent**. Les items n'ont pas de fond actif propre.

4. **Scène en retrait (Inset Main Stage) — la signature Arc**
   - Marge périphérique `margin: 8px 8px 8px 0` (`--stage-inset`).
   - **Rayons concentriques** (règle macOS 27) : `rayon intérieur = rayon extérieur − marge`. Fenêtre `22px` − `8px` → scène `14px`.
   - Fond : `var(--bg-stage)` (quasi opaque : la lisibilité prime sur la transparence).
   - Contour : `box-shadow: 0 0 0 1px var(--border-subtle), var(--specular-top), 0 12px 40px rgba(0,0,0,0.35);`
   - Seule la scène défile (`overflow-y: auto`), la sidebar et la toolbar restent fixes.

5. **Toolbar de la scène**
   - `position: sticky; top: 0; z-index: 40; height: 52px; padding: 0 16px;`
   - Matériau : `background: var(--glass-toolbar); backdrop-filter: blur(24px) saturate(160%);` + filet bas `1px var(--border-subtle)` qui n'apparaît qu'une fois le contenu défilé.
   - Gauche : flèches `‹ ›` (boutons `28×28px`, `border-radius: 8px`), puis le titre de la page (`15px`, `600`) une fois l'en-tête défilé.
   - Centre : barre de commande `⌘K` — `width: 320px; height: 30px; border-radius: 9999px; background: var(--fill-1); border: 1px solid var(--border-subtle);` placeholder en `--text-tertiary`, raccourci `⌘K` dans une touche `--fill-2`.
   - Droite : filtres globaux de la vue (contrôle segmenté de période, menu de filtre), puis compte/réglages.

---

## 2. MATIÈRE & LUMIÈRE

1. **Lumière ambiante (version sobre)**
   - En natif, elle vient gratuitement du fond d'écran à travers le verre de la sidebar : **ne rien ajouter**.
   - En web : un fond de fenêtre `--bg-root` + **au plus deux halos** sous la sidebar uniquement : `width: 520px; height: 520px; border-radius: 50%; filter: blur(120px); pointer-events: none;`
     - Halo 1 (haut-gauche) : accent à `opacity: 0.14`.
     - Halo 2 (bas-gauche) : bleu-gris `#5A6B85` à `opacity: 0.12`.
   - **Aucun halo dans la scène.** La scène est un espace de travail calme.

2. **Liseré spéculaire (1px Specular Rim)** — la lumière vient d'en haut
   - Toute surface élevée (scène, carte, popover, bouton en verre) a un reflet neutre sur son bord supérieur : `inset 0 1px 0 0 var(--rim)`.
   - Bords latéraux et inférieur : `1px var(--border-subtle)`.
   - Liseré coloré (accent) : réservé à **une** carte vedette par écran, et à l'élément focalisé.

3. **Niveaux de surface**

| Niveau | Rôle | Sombre | Clair |
| --- | --- | --- | --- |
| 0 | Fond de fenêtre | `#0B0C0E` | `#E6E7EA` |
| 1 | Scène | `rgba(18,18,21,0.94)` | `rgba(246,246,248,0.94)` |
| 2 | Carte | dégradé `rgba(255,255,255,0.045) → 0.025` | `#FFFFFF` |
| 3 | Carte survolée / élément actif | dégradé `0.07 → 0.04` | `#FFFFFF` + ombre plus marquée |
| 4 | Popover, menu, palette ⌘K, module d'état | `rgba(32,32,37,0.78)` + `blur(40px) saturate(160%)` | `rgba(255,255,255,0.80)` + `blur(40px) saturate(180%)` |

Ombre du niveau 4 : `0 24px 64px -12px rgba(0,0,0,0.55), 0 0 0 1px var(--border-subtle), var(--specular-top)`.

---

## 3. TOKENS CSS DE RÉFÉRENCE

```css
:root {
  color-scheme: dark;

  /* Accent (seule valeur à changer par projet, voir 0.3) */
  --accent-h: 15; --accent-s: 62%; --accent-l: 60%;
  --accent:        hsl(var(--accent-h) var(--accent-s) var(--accent-l));
  --accent-strong: hsl(var(--accent-h) var(--accent-s) calc(var(--accent-l) - 8%));
  --accent-soft:   hsl(var(--accent-h) var(--accent-s) var(--accent-l) / 0.14);
  --accent-rim:    hsl(var(--accent-h) var(--accent-s) var(--accent-l) / 0.55);
  --on-accent:     #FFFFFF;

  /* Surfaces */
  --bg-root:        #0B0C0E;
  --glass-sidebar:  rgba(28, 29, 33, 0.55);
  --glass-toolbar:  rgba(18, 18, 21, 0.72);
  --bg-stage:       rgba(18, 18, 21, 0.94);
  --surface-card:       linear-gradient(180deg, rgba(255,255,255,0.045) 0%, rgba(255,255,255,0.025) 100%);
  --surface-card-hover: linear-gradient(180deg, rgba(255,255,255,0.07) 0%, rgba(255,255,255,0.04) 100%);
  --surface-floating:   rgba(32, 32, 37, 0.78);

  /* Remplissages neutres (contrôles, pistes, survols) */
  --fill-1: rgba(255,255,255,0.05);
  --fill-2: rgba(255,255,255,0.08);
  --fill-3: rgba(255,255,255,0.11);

  /* Bordures & lumière */
  --border-subtle: rgba(255,255,255,0.07);
  --border-strong: rgba(255,255,255,0.12);
  --rim:           rgba(255,255,255,0.10);
  --specular-top:  inset 0 1px 0 0 var(--rim);
  --shadow-card:   0 1px 2px rgba(0,0,0,0.25), 0 8px 24px -12px rgba(0,0,0,0.5);

  /* Texte */
  --text-primary:   rgba(255,255,255,0.94);
  --text-secondary: rgba(255,255,255,0.62);
  --text-tertiary:  rgba(255,255,255,0.40);

  /* Sémantique (états réels uniquement) */
  --positive: #4CB782; --warning: #E0A443; --negative: #E5675C;

  /* Graphiques */
  --chart-neutral: rgba(255,255,255,0.26);   /* séries secondaires, barres de classement */
  --chart-track:   rgba(255,255,255,0.06);   /* pistes, cases vides */
  --chart-grid:    rgba(255,255,255,0.06);
  --cat-1: var(--accent); --cat-2: #7F95B2; --cat-3: #8FA58A;
  --cat-4: #C2AE8C;       --cat-5: #A190B8; --cat-6: #6F7A86;
  --cat-other: rgba(255,255,255,0.20);

  /* Rayons (concentriques) & espacements */
  --radius-window: 22px;
  --stage-inset:   8px;
  --radius-stage:  14px;   /* = window − inset */
  --radius-card:   12px;
  --radius-inner:  8px;    /* vignettes, items de liste, boutons carrés */
  --radius-pill:   9999px;
  --space-page:    28px;   /* marge intérieure de la scène */
  --gap-grid:      14px;

  /* Mouvement */
  --spring-apple:    cubic-bezier(0.22, 1, 0.36, 1);
  --duration-fast:   160ms;
  --duration-normal: 280ms;

  /* Bulle Liquid Glass (section 5.I) */
  --spring-bubble:   linear(0, 0.22 7%, 0.62 16%, 0.94 26%, 1.07 34%, 1.09 40%, 1.05 50%, 1 60%, 0.985 70%, 1 85%, 1);
  --duration-bubble: 550ms;   /* glissement + rebond jusqu'au repos */
  --bubble-stretch:  0.16;    /* étirement de goutte au départ (+16 % dans le sens du trajet) */
  --bubble-lift:     4px;     /* croissance par côté quand on la tient */
  --lens-scale:      1.2;     /* grossissement des titres sous la bulle tenue */
}

/* Apparence claire. Pour suivre le système, dupliquer ce bloc dans
   @media (prefers-color-scheme: light) { :root:not([data-theme="dark"]) { … } } */
:root[data-theme="light"] {
  color-scheme: light;
  --accent-l: 52%;
  --on-accent: #FFFFFF;

  --bg-root:        #E6E7EA;
  --glass-sidebar:  rgba(240, 240, 243, 0.62);
  --glass-toolbar:  rgba(246, 246, 248, 0.78);
  --bg-stage:       rgba(246, 246, 248, 0.94);
  --surface-card:       #FFFFFF;
  --surface-card-hover: #FFFFFF;
  --surface-floating:   rgba(255, 255, 255, 0.80);

  --fill-1: rgba(0,0,0,0.04);
  --fill-2: rgba(0,0,0,0.06);
  --fill-3: rgba(0,0,0,0.08);

  --border-subtle: rgba(0,0,0,0.07);
  --border-strong: rgba(0,0,0,0.12);
  --rim:           rgba(255,255,255,0.9);
  --shadow-card:   0 1px 2px rgba(0,0,0,0.04), 0 6px 20px -10px rgba(0,0,0,0.12);

  --text-primary:   rgba(0,0,0,0.88);
  --text-secondary: rgba(0,0,0,0.58);
  --text-tertiary:  rgba(0,0,0,0.38);

  --chart-neutral: rgba(0,0,0,0.22);
  --chart-track:   rgba(0,0,0,0.05);
  --chart-grid:    rgba(0,0,0,0.06);
  --cat-2: #5E7697; --cat-3: #6E8A68; --cat-4: #A8925F; --cat-5: #8371A0; --cat-6: #56606B;
  --cat-other: rgba(0,0,0,0.18);
}
```

---

## 4. TYPOGRAPHIE (SF PRO, échelle macOS)

- **Police :** `font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro Display", "Inter", system-ui, sans-serif;` avec `-webkit-font-smoothing: antialiased;`.
- **Corps de texte macOS = 13 px**, pas 14–16 px : c'est ce qui rend une app « native » plutôt que « site web ».

| Rôle | Taille | Graisse | Interlettrage | Couleur |
| --- | --- | --- | --- | --- |
| Titre de vue (Large Title) | `28px` | `700` | `-0.022em` | primaire |
| Hero (accueil, récap uniquement) | `34px` | `700` | `-0.025em` | primaire |
| Titre de section / carte | `13px` | `600` | `-0.005em` | primaire |
| Sous-titre de carte | `12px` | `400` | `0` | tertiaire |
| Corps | `13px` | `400`, `line-height: 1.45` | `0` | secondaire |
| Sur-titre (eyebrow) | `11px` | `600`, MAJUSCULES | `0.06em` | tertiaire |
| Libellé / légende / badge | `11–12px` | `500` | `0.01em` | tertiaire |
| Valeur KPI | `26px` | `600` | `-0.02em` | primaire |
| Grand chiffre (vedette) | `40px` | `600` | `-0.03em` | primaire |

- Toute donnée chiffrée (KPI, tableaux, axes, durées) : `font-variant-numeric: tabular-nums;`.
- Unités en plus petit que le chiffre (`48 h` → « 48 » `26px`, « h » `17px` secondaire).
- Pas d'ombre portée sur le texte, sauf un titre posé sur une image.

---

## 5. COMPOSANTS

### A. En-tête de vue (remplace le « hero Apple TV »)
- Par défaut : sur-titre optionnel + titre de vue `28px` + une phrase de contexte (`13px`, secondaire, `max-width: 720px`) + actions à droite. `padding: 24px var(--space-page) 20px`.
- **Hero** : réservé à l'accueil, au récap et à l'onboarding. Fond = dégradé radial **de l'accent seul**, très doux, qui se fond dans la scène : `radial-gradient(120% 140% at 0% 0%, var(--accent-soft) 0%, transparent 55%)`. Hauteur `160–220px`. Pas de mesh, pas d'image abstraite multicolore.
- Bouton primaire : `background: var(--accent); color: var(--on-accent); height: 30px; padding: 0 14px; border-radius: 8px; font: 500 13px;` + `box-shadow: inset 0 1px 0 rgba(255,255,255,0.22), 0 1px 2px rgba(0,0,0,0.3)`.
- Bouton secondaire (verre) : `background: var(--fill-2); color: var(--text-primary); box-shadow: var(--specular-top), 0 0 0 1px var(--border-subtle);`
- Boutons pilules (`9999px`) seulement dans la toolbar et le hero ; ailleurs, rayon `8px` (style macOS).

### B. Grille Bento & cartes
- `display: grid; grid-template-columns: repeat(12, 1fr); gap: var(--gap-grid);` — les cartes occupent 3, 4, 6, 8 ou 12 colonnes. Repli `auto-fill, minmax(260px, 1fr)` sous `900px`.
- Carte : `background: var(--surface-card); border-radius: var(--radius-card); padding: 16px 18px; box-shadow: 0 0 0 1px var(--border-subtle), var(--specular-top), var(--shadow-card);`
- En-tête de carte : icône `14px` en `--text-tertiary` + titre `13px/600` + sous-titre `12px` tertiaire ; action discrète à droite (segmenté ou menu `…`).
- **Carte vedette** (une par écran max) : remplacer `var(--specular-top)` par `inset 0 1px 0 0 var(--accent-rim)` et ajouter en fond `radial-gradient(80% 120% at 0% 0%, var(--accent-soft), transparent 60%)`.
- Vignette/icône : conteneur `28×28px` (liste) ou `36×36px` (carte), `border-radius: var(--radius-inner)`, fond `var(--fill-2)`, icône en `--text-secondary`. Pas de fond teinté par catégorie.

### C. Tuile KPI
- Libellé (`12px`, secondaire, icône `13px` tertiaire) → valeur (`26px/600`, tabular) → contexte (`12px`, tertiaire).
- Variation : `▲ 12 %` en `--positive` / `▼` en `--negative` seulement si la comparaison a un sens ; sinon contexte neutre.
- Mini-sparkline optionnelle à droite, trait `1.5px` en `--chart-neutral`, dernier point en accent.

### D. Graphiques (règles communes)
- **Une couleur pour la donnée, l'accent pour l'insight.** Barres et séries en `--chart-neutral` ; l'accent marque la série principale, la valeur max, la période en cours ou la moyenne glissante.
- Cartes de chaleur (calendrier, semaine type) : rampe mono-teinte de l'accent, `5` paliers (`--chart-track`, puis accent à `0.20 / 0.38 / 0.62 / 1`). Cases `border-radius: 3–4px`.
- Classements (top outils, top fichiers) : barre `4px` de haut, `border-radius: 2px`, piste `--chart-track`, barre `--chart-neutral`, n°1 en `--text-secondary` (un neutre plus clair). L'accent sur le n°1 est réservé au **classement principal de la page** : avec plusieurs classements, des leaders tous en accent font une page bariolée.
- Catégoriel (donut, barres empilées) : `--cat-1…6`, triées par valeur, le reste regroupé en « Autres » `--cat-other`. Donut : épaisseur `14%` du rayon, `2px` d'espace entre segments, total au centre.
- Grilles horizontales seulement, `1px --chart-grid`, axes en `11px` tertiaire tabular. Pas de bordure de zone de tracé.
- Survol : infobulle niveau 4 ; les autres séries passent à `opacity: 0.35`.

### E. Module d'état (bas de sidebar)
- **Optionnel** : seulement si l'app a une activité vivante (synchronisation, analyse, tâche, serveur). Sinon, bas de sidebar = profil/réglages.
- `margin: 10px; padding: 10px 12px; border-radius: 12px; background: var(--surface-floating); backdrop-filter: blur(24px); box-shadow: 0 0 0 1px var(--border-subtle), var(--specular-top), 0 8px 24px rgba(0,0,0,0.3);`
- Contenu : point d'état `6px` (accent si en cours, `--positive` si à jour, animé en pulsation lente seulement pendant une activité), deux lignes (`12px/600` + `11px` tertiaire, sous-titre court : `240px` de sidebar laissent ~20 caractères), un bouton `…` `28×28px` qui ouvre un menu (actualiser, sources, réglages ; nom du compte en en-tête de section). Les actions vivent dans le menu et sous leur raccourci clavier, pas en boutons alignés qui tronquent le texte.

### F. Contrôles & formulaires
- **Contrôle segmenté** : conteneur `background: var(--fill-1); padding: 2px; border-radius: 8px; box-shadow: inset 0 0 0 1px var(--border-subtle);` segments `height: 24px; padding: 0 10px; font: 500 12px;` ; segment actif marqué par la **bulle Liquid Glass** (section 5.I, rayon `6px`), texte `--text-primary` ; inactifs en `--text-secondary`. **Pas d'accent** sur le segmenté.
- **Pastilles de filtre** (catégories, statuts) : `height: 26px; border-radius: 7px; background: var(--fill-1); border: 1px solid var(--border-subtle)`, point `6px` de la couleur catégorielle ; la pastille choisie perd fond et bordure et reçoit la bulle Liquid Glass.
- **Champ de saisie** : `height: 30px; background: var(--fill-1); border: 1px solid var(--border-subtle); border-radius: 8px; padding: 0 10px;` focus : `border-color: var(--accent-rim); box-shadow: 0 0 0 3px var(--accent-soft);`
- **Interrupteur, case à cocher, radio** : accent quand actif, `--fill-3` sinon.
- **Tags / badges** : `height: 20px; padding: 0 7px; border-radius: 6px; background: var(--fill-2); font: 500 11px; color: var(--text-secondary);` + éventuel point `6px` de la couleur catégorielle. Jamais de fond coloré plein.

### G. Listes & tableaux
- Lignes `32px` (dense) ou `44px` (avec sous-titre), filets `1px var(--border-subtle)`, pas de zébrage.
- En-têtes de colonnes `11px/600` tertiaires, triables (chevron `10px`).
- Ligne survolée `var(--fill-1)` ; ligne sélectionnée `var(--accent-soft)` + `inset 2px 0 0 var(--accent)`.
- Colonnes numériques alignées à droite, `tabular-nums`.
- Inspecteur (détail à droite) : panneau `320–360px`, même matériau que les cartes, séparé par un filet.

### H. Popovers, menus, palette ⌘K
- Niveau 4. `border-radius: 14px` (palette) / `10px` (menu). Voile derrière une palette modale : `rgba(0,0,0,0.25)` sans flou.
- Palette : champ `50px` sans bordure (texte `16px`), résultats groupés par sur-titres (Sessions récentes / Sessions, Pages, Actions), lignes `38px` avec vignette d'icône `24px` en `--fill-2`, raccourci affiché à droite en touches `--fill-2`. La ligne active porte la bulle Liquid Glass (sans glisser : elle suit les flèches ↑↓ et le survol). ↵ ouvre, esc ou un clic sur le voile ferme. Pied de palette : rappel des touches.
- Une recherche sans résultat exact propose toujours une action de repli (« Toutes les sessions contenant « … » »).

### I. Sélection Liquid Glass (la bulle)
La sélection d'un groupe (segments, sidebar, barre d'onglets, pastilles, lignes de palette) est **une seule bulle de verre** qui se déplace d'un élément à l'autre, comme la barre d'Apple Music. Elle ne s'utilise pas pour les lignes de tableau (sélection en `--accent-soft`, section G).

**Au repos**
- Matière : verre `regular` (macOS 26+ `glassEffect`) sur un voile `--fill-2` (sombre) / `rgba(255,255,255,0.55)` (clair), liseré spéculaire blanc `0.18` / `0.9`, ombre `0 1.5px 3px rgba(0,0,0,0.28)`.
- Rayon : celui de l'élément (`6px` segments, `7px` pastilles, `8px` lignes).

**Changement de sélection (clic, clavier)**
- La bulle glisse vers le nouvel élément sur un ressort rebondi : `var(--spring-bubble)` sur `var(--duration-bubble)` (SwiftUI : `.spring(response: 0.42, dampingFraction: 0.66)`).
- Effet goutte : au départ, `scale` `1 + var(--bubble-stretch)` dans le sens du trajet et `1 − 0.4 × stretch` en travers pendant `120ms`, puis retour à `1` sur un ressort rebondi (`.bouncy(duration: 0.45, extraBounce: 0.2)`).
- Le texte de l'élément devient `--text-primary` en fondu `200ms`.

**Attraper et glisser**
- Appui sur l'élément **déjà sélectionné** : la bulle se soulève tout de suite. Appui sur un **autre** élément : rien ne bouge tant que le pointeur n'a pas parcouru `4px` ; un simple clic reste un clic (l'élément gère sa sélection).
- Soulevée : `+ var(--bubble-lift)` de chaque côté, verre `clear` (plus transparent), ombre `0 4px 8px`. Elle suit le pointeur sur un ressort interactif (`response 0.22, damping 0.78`) et prend progressivement la taille des deux éléments entre lesquels elle se trouve.
- Étirement de vitesse : `stretch = min(0.2, |vitesse| / 3000 px/s)` le long du trajet.
- **Loupe** : sous la bulle tenue, le contenu est flouté par le verre (matériau `regular`) et les titres réapparaissent grossis `× var(--lens-scale)`, centrés sur le pointeur, découpés à la forme de la bulle, avec le liseré spéculaire par-dessus.
- Retour haptique `alignment` (trackpad) à chaque élément franchi.
- Relâchement : la bulle se pose sur l'élément le plus proche (ressort rebondi + effet goutte) et le sélectionne.

**Accessibilité** : avec « Réduire les animations », glissement simple `ease-out 150ms`, ni goutte, ni étirement, ni loupe.

**En web** : un élément `.bubble` en `position: absolute` dans le conteneur, déplacé uniquement par `transform: translate() scale()` (jamais `left/width` animés) avec `transition: transform var(--duration-bubble) var(--spring-bubble)` ; la goutte en `@keyframes` (`scale` étiré à `22%` puis `1`). Glisser : `pointerdown` / `pointermove` / `pointerup` avec `setPointerCapture`, transition coupée pendant le suivi. Verre : `backdrop-filter: blur(20px) saturate(180%)` + voile + liseré. Loupe : clone du rang d'éléments dans la bulle, `transform: scale(var(--lens-scale))` avec `transform-origin` au pointeur, `clip-path` à la forme de la bulle.

---

## 6. MICRO-INTERACTIONS

1. **Survol de carte cliquable** : `transition: background var(--duration-fast) ease, box-shadow var(--duration-normal) var(--spring-apple);` → fond `--surface-card-hover` et `--rim` plus lumineux. **Pas de translation ni de mise à l'échelle** sur les cartes de données (ça bouge les chiffres) ; `translateY(-1px)` toléré sur des tuiles de navigation.
2. **Pression** : boutons uniquement, `:active { transform: scale(0.97); transition-duration: 80ms; }`.
3. **Apparition** : popovers `opacity 0 → 1` + `scale(0.98) → 1`, `var(--duration-fast) var(--spring-apple)`. Changement de vue : fondu `120ms`, jamais de glissement latéral.
4. **Réduction des animations** : `@media (prefers-reduced-motion: reduce)` coupe transitions et pulsations.
5. **Fluidité : jamais d'animation pendant un rendu lourd.** Afficher une nouvelle page coûte souvent `100–200ms` de mise en page sur le fil principal (SwiftUI, gros DOM) ; une animation lancée dans cette même image se fige en plein vol, c'est le « lag » qu'on voit.
   - Changement de page : **la page s'affiche d'abord, l'animation démarre juste après**, sur un fil principal libre (SwiftUI : deux sauts `DispatchQueue.main.async` ; web : deux `requestAnimationFrame`). Un départ décalé de ~`100ms` ne se voit pas, un arrêt en plein vol si.
   - Données recalculées qui redessinent la page (changement de période, de filtre) : les appliquer **une fois la bulle posée** (`~400ms` après l'action), pas pendant son rebond.
   - Ne pas déclencher l'animation dès l'appui de souris si un clic va changer de page : elle serait coupée par le rendu.
   - Mesure : journaliser les intervalles de plus de `30ms` entre deux ticks d'un minuteur du fil principal pendant les changements de vue ; aucune ne doit tomber pendant une animation.
6. **Barres de défilement** : `::-webkit-scrollbar { width: 8px; } ::-webkit-scrollbar-thumb { background: var(--fill-3); border-radius: 9999px; border: 2px solid transparent; background-clip: content-box; } ::-webkit-scrollbar-track { background: transparent; }`

---

## 7. ACCESSIBILITÉ

- Contraste texte ≥ 4.5:1 (le tertiaire n'est jamais utilisé pour une information indispensable).
- L'accent ne porte jamais seul une information : la valeur, la forme ou le libellé la portent aussi.
- Focus clavier visible partout (anneau accent de la section F).
- Graphiques : chaque série a un libellé ou une légende textuelle ; les rampes de chaleur ont une légende « Moins → Plus ».

---

## 8. IMPLÉMENTATION NATIVE (SwiftUI / AppKit, macOS 26+)

Sur Mac, ce système s'obtient d'abord avec les composants du système, puis en réglant les couleurs :

| Concept | SwiftUI |
| --- | --- |
| Fenêtre + feux tricolores | `WindowGroup` standard, `.windowStyle(.hiddenTitleBar)` ou `.windowToolbarStyle(.unified)` — jamais de faux feux |
| Sidebar en verre | `NavigationSplitView` : la colonne latérale reçoit le matériau système (Liquid Glass sur macOS 26+, `.sidebar` avant) ; ne pas lui poser de fond opaque |
| Scène en retrait | contenu de détail avec `.padding(8)` puis `.background(Theme.stage, in: .rect(cornerRadius: 14, style: .continuous))` et un `.overlay` de contour `1px` + reflet supérieur |
| Toolbar | `.toolbar { }` avec `ToolbarItem(placement: .principal)` pour la recherche, `.searchable` si le comportement standard suffit |
| Verre (niveau 4, module d'état) | macOS 26+ : `.glassEffect(.regular, in: .rect(cornerRadius: 12))`, regroupés dans un `GlassEffectContainer` ; repli : `.background(.regularMaterial, in: …)` |
| Boutons | `.buttonStyle(.glassProminent)` (primaire) / `.buttonStyle(.glass)` (secondaire) sur macOS 26+ ; `.borderedProminent` / `.bordered` avant |
| Accent | `.tint(Theme.accent)` à la racine ; une `Color` adaptative clair/sombre |
| Chiffres | `.monospacedDigit()` |
| Graphiques | Swift Charts : `.foregroundStyle(Theme.chartNeutral)` par défaut, `Theme.accent` pour la série mise en avant |
| Rayons | `RoundedRectangle(cornerRadius:style: .continuous)` partout (courbe squircle) |
| Bulle Liquid Glass (5.I) | Chaque élément publie son cadre dans un `coordinateSpace` nommé via une `PreferenceKey` ; le conteneur dessine **une** bulle en `.background` à ce cadre. Glisser : `DragGesture(minimumDistance: 0)` en `.simultaneousGesture` (les boutons gardent le clic). Effet goutte : `.keyframeAnimator(trigger:)` (`CubicKeyframe` puis `SpringKeyframe` `.bouncy`). Verre : `.glassEffect(lifted ? .clear : .regular, in: shape)`. Loupe : copie du contenu en `.overlay`, `.scaleEffect(1.2, anchor: pointeur)`, `.mask` à la forme de la bulle, sur un fond `.regularMaterial`. Haptique : `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, …)`. Pour des lignes librement placées sans glisser (palette) : `matchedGeometryEffect(isSource: false)` |
| Fluidité (6.5) | La bulle affiche une sélection « montrée » mise à jour après le rendu : `.onChange(of: selection) { DispatchQueue.main.async { DispatchQueue.main.async { withAnimation(spring) { shown = new } } } }` ; données recalculées appliquées après `≥ 0.4 s` |
| Historique de navigation | Pile retour / avant dans le modèle, flèches ‹ › de la toolbar, `⌘[` / `⌘]` dans un menu « Aller à » |

Toujours encadrer les API récentes : `if #available(macOS 26, *) { … } else { … }`.

---

## 9. CHECKLIST AVANT DE LIVRER UNE VUE

- [ ] **Graphite d'abord** : sur une capture, l'accent représente moins de 5 % de la surface et on voit les chiffres avant la couleur.
- [ ] **Un seul accent** dans toute l'app ; aucune autre teinte hors sémantique et graphiques catégoriels.
- [ ] **Cadre Arc** : scène détachée de `8px` (haut, droite, bas), rayon `14px` concentrique au rayon de fenêtre.
- [ ] **Verre** : sidebar translucide, popovers niveau 4 ; scène quasi opaque.
- [ ] **Liseré spéculaire** neutre en haut de chaque surface ; liseré accent sur une carte vedette au plus.
- [ ] **Typo macOS** : corps `13px`, titres de vue `28px`, chiffres en `tabular-nums`.
- [ ] **Graphiques** : neutre pour la donnée, accent pour l'insight, palette catégorielle sourdine ≤ 6 + Autres.
- [ ] **Clair et sombre** vérifiés tous les deux.
- [ ] **Natif** : aucun composant système redessiné (feux, sidebar, menus) quand l'app est en SwiftUI.
- [ ] **Bulle Liquid Glass** : une seule bulle par groupe de sélection ; elle glisse, rebondit, s'attrape et grossit les titres comme une loupe ; un clic reste un clic.
- [ ] **Fluidité** : aucune animation ne démarre dans l'image qui construit une nouvelle page ; aucun blocage de plus de `30ms` pendant une animation.
- [ ] **Réduire les animations** respecté (pas de rebond, d'étirement ni de loupe).
