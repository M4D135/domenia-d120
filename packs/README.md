# Packs Domenia 1.0

| Pack | Télécharger | Utilisation |
|---|---|---|
| PROD | [Domenia_PROD.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_PROD.zip) | Extraire le dossier `prod`, puis lancer `Domenia.exe` en gardant `wad` à côté. |
| DEV | [Domenia_DEV.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_DEV.zip) | Sources et outils ; `dev/FABRIQUER_PROD.cmd` reconstruit une distribution PROD. |

Build actuel : **RC1.17.6** — [contrôles et portée de validation](../validation/2026-10-13/search-progress/qualification.json).

Les contrôles locaux passent. Cette révision est livrée à la demande de l’utilisateur
sans nouvelle campagne Windows ; il effectuera les essais sur son poste. La recette Windows,
le stockage SQLite natif et les parcours sur AD réel restent à vérifier.

Les deux ZIP contiennent le même runtime. La version et les empreintes sont dans
[manifest.json](manifest.json) et [SHA256SUMS](SHA256SUMS).

Depuis la racine du dépôt : `shasum -a 256 -c packs/SHA256SUMS`.

[Guides Word et PDF](../DOC) · [Bilan et portée des contrôles](../validation/2026-10-13/README.md)

Pour reconstruire les archives versionnées :
`python3 dev/tools/build_packages.py --output /chemin/vers/un/dossier-hors-dev`.
Copier les ZIP DEV et PROD obtenus sous les noms stables de ce dossier et mettre
à jour leurs empreintes et le manifeste. Les archives restent des fichiers Git ordinaires.
