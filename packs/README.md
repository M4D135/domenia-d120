# Packs Domenia 1.0

| Pack | Télécharger | Utilisation |
|---|---|---|
| PROD | [Domenia_PROD.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_PROD.zip) | Extraire le dossier `prod`, puis lancer `Domenia.exe` en gardant `wad` à côté. |
| DEV | [Domenia_DEV.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_DEV.zip) | Sources et outils ; `dev/FABRIQUER_PROD.cmd` reconstruit une distribution PROD. |

Build actuel : **RC1.17.12**, candidat — [corrections et contrôles ciblés](../validation/2026-10-16/final-corrections/README.md).

Accueil simplifié, Santé en dernier par défaut, déplacement des sections et tailles de widgets stables.
Le bandeau suit le lot complet, y compris les attentes et lʼenregistrement ; le panneau détaille les lectures.
La collecte WMI conserve le poste suivant pendant une saturation du moteur après un délai dépassé.
Chaque widget affiche la source et les dates des données, avec un petit ↻ permanent qui relit la source. La première configuration prépare automatiquement sa vue après la lecture de la base.

Des contrôles ciblés sous Windows PowerShell 5.1 passent, avec données fictives et réseau simulé.
La campagne générale nʼest pas relancée à la demande de David. Des échecs antérieurs et la qualification
complète sur AD restent ouverts ; aucun point de qualification nʼest clôturé.

Les deux ZIP contiennent le même runtime. La version et les empreintes sont dans
[manifest.json](manifest.json) et [SHA256SUMS](SHA256SUMS).

Depuis la racine du dépôt : `shasum -a 256 -c packs/SHA256SUMS`.

[Guides Word et PDF](../DOC) · [Bilan et portée des contrôles](../validation/2026-10-16/final-corrections/README.md)

Pour reconstruire les archives versionnées :
`python3 dev/tools/build_packages.py --output /chemin/vers/un/dossier-hors-dev`.
Copier les ZIP DEV et PROD obtenus sous les noms stables de ce dossier et mettre
à jour leurs empreintes et le manifeste. Les archives restent des fichiers Git ordinaires.
