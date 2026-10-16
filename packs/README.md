# Packs Domenia 1.0

| Pack | Télécharger | Utilisation |
|---|---|---|
| PROD | [Domenia_PROD.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_PROD.zip) | Extraire le dossier `prod`, puis lancer `Domenia.exe` en gardant `wad` à côté. |
| DEV | [Domenia_DEV.zip](https://github.com/M4D135/domenia-d120/raw/refs/heads/master/packs/Domenia_DEV.zip) | Sources et outils ; `dev/FABRIQUER_PROD.cmd` reconstruit une distribution PROD. |

Build actuel : **RC1.17.9**, candidat — [contrôles et portée de validation](../validation/2026-10-16/windows-recovery/README.md).

**RC1.17.9 : un échec d’initialisation a été signalé sur un poste utilisateur.
La cause reste à identifier dans le journal de démarrage ; ne pas considérer ce candidat comme utilisable validé.**

Les contrôles de construction et des essais ciblés sous Windows PowerShell 5.1 passent.
La campagne générale a été interrompue par l’incident VM ; des échecs restent ouverts.
Ces ZIP ne sont pas qualifiés pour la production : la preuve liée aux archives finales et
les parcours interactifs sur AD réel manquent encore. Aucun point de qualification n’est clôturé.

Les deux ZIP contiennent le même runtime. La version et les empreintes sont dans
[manifest.json](manifest.json) et [SHA256SUMS](SHA256SUMS).

Depuis la racine du dépôt : `shasum -a 256 -c packs/SHA256SUMS`.

[Guides Word et PDF](../DOC) · [Bilan et portée des contrôles](../validation/2026-10-16/windows-recovery/README.md)

Pour reconstruire les archives versionnées :
`python3 dev/tools/build_packages.py --output /chemin/vers/un/dossier-hors-dev`.
Copier les ZIP DEV et PROD obtenus sous les noms stables de ce dossier et mettre
à jour leurs empreintes et le manifeste. Les archives restent des fichiers Git ordinaires.
