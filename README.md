# Domenia 1.0

Application Windows d'administration Active Directory : recherche d'objets, base locale,
inventaire des postes, tableaux de bord et atelier de requêtes.

## Utilisation

Extrayez complètement le pack puis lancez **Domenia.exe**. Le lanceur et son dossier
**wad** doivent rester ensemble. Cible : Windows PowerShell 5.1 x64, WPF et
.NET Framework 4.7.2 ou ultérieur. La fenêtre de connexion reste au-dessus des
autres fenêtres jusqu’à sa fermeture.

Deux distributions sont prévues :

- **PROD** : `Domenia.exe` et le dossier ordinaire `wad`.
- **DEV** : le même runtime, les sources, les outils de fabrication et les tests.

Dans **Outils > Base autonome**, privilégiez **Tout relire dans lʼOU choisie**.
Cette action inclut les sous-OU et conserve les autres branches. **Tout relire dans
le domaine** est une opération longue et occasionnelle, avec confirmation : premier
chargement ou remise à jour globale. Ces lectures mettent à jour la copie locale,
sans modifier l'annuaire.

Les vues indiquent leur périmètre et la fraîcheur des données. Un objet recensé,
un poste actif et un poste joignable sont trois informations distinctes. Les données
absentes ou périmées restent inconnues. Cliquer sur un indicateur ouvre les objets
ou le détail correspondant ; l'atelier permet d'enregistrer des filtres et des sondes.

## Documentation

| Public | Word | PDF |
|---|---|---|
| Technicien | [Guide technicien](DOC/Domenia-1.0-Guide-technicien.docx) | [Guide technicien](DOC/Domenia-1.0-Guide-technicien.pdf) |
| Administrateur | [Guide administrateur](DOC/Domenia-1.0-Guide-administrateur.docx) | [Guide administrateur](DOC/Domenia-1.0-Guide-administrateur.pdf) |

[Installation, mise à jour et fabrication](dev/LIRE-MOI.md) ·
[Sources des guides](guides/LIRE-KIT.md) ·
[Bilan des améliorations et preuves](validation/2026-10-12/README.md)

## Modifier et reconstruire

Modifiez les sources du DEV puis lancez **dev/FABRIQUER_PROD.cmd** sous Windows.
L'outil fabrique un nouveau dossier PROD, vérifie ses composants et régénère les
contrats et manifestes. Il utilise PowerShell 5.1 ; aucun Python ni compilateur
n'est nécessaire pour assembler des DLL déjà construites.

Les sources C# propres à Domenia sont dans `dev/native`. Le moteur de requêtes
commun est épinglé dans `dev/vendor/m4d-admin-common`. Les tests et leur portée
sont conservés avec les sources et dans le dossier de validation. Les essais avec
un parc synthétique et les contrôles WPF en VM restent distincts de la recette
sur un domaine réel.
