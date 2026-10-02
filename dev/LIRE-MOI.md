# Domenia 1.0 RC1.10

Relations refondues : associations ciblées, onglet Associer avec Détecter/Rechercher, aucune popup métier dans ce parcours.

# Domenia 1.0 RC1.9

Voir **INTERACTIONS-INTEGREES-RC1.9.md** pour les modifications actuelles et la recette avant distribution. Les sections et rapports plus anciens ci-dessous restent historiques.

# Domenia 1.0 RC1.8

Les correctifs de cette version sont décrits dans **RELATIONS-ALIGNEMENTS-RC1.8.md**.

PROD : Domenia.exe + wad uniquement. Déblocage : wad/Support/DEBLOQUER_TOUT.cmd.
DEV : même runtime, installateur, tests et aperçus.

**Avant mise à jour :** fermer après la fin des opérations, garder la base et extraire DEV dans un autre dossier. Utiliser INSTALLER-MISE-A-JOUR.ps1 avec le dossier existant comme Destination. Ne pas modifier le cœur sans les modules et le manifeste.

**Tests de cette révision :** TESTER-RELATIONS.cmd (65 scénarios Windows isolés) ; APERCU-RELATIONS.cmd (même suite puis interface fictive). Les anciennes suites restent présentes.

Version candidate : les contrôles Python ont été exécutés, pas PowerShell/WPF ou les accès au domaine. L'exécutable reste non signé. Aucun mot de passe, cache personnel ou donnée réelle n'est livré.
