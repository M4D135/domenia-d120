# ADCC 1.0 R1.2 : correctif de détection utilisateur distante

**Build : `2026.09.21-R1.2-REMOTE`**  
**Base : R1.1, correctifs du thème sombre conservés.**

## Ce que montre le journal fourni

La recherche LDAP, la lecture de la fiche machine et le ping aboutissent. L'échec arrive pendant la recherche du dernier utilisateur : les méthodes classiques ne donnent pas de résultat, PsExec retourne sa licence avec le code 1, puis l'écriture du script de secours sous `ADMIN$\Temp` est refusée. Ce sont trois observations distinctes. Ce journal ne permet pas de déterminer les erreurs exactes des méthodes classiques, car la version précédente les remplaçait dans le message final par une phrase générique.

La comparaison du code montre que `Invoke-WRemotePsExecScript`, `Invoke-WRemoteScheduledTaskScript` et `New-WAdminShareDrive` étaient déjà identiques dans l'archive d'origine et dans R1.1, après normalisation des fins de ligne. Le corps de détection `ComputerLastUser` était également inchangé. Il serait donc incorrect d'affirmer que le correctif du thème a créé ces défauts ou qu'un changement de droits sur le parc est démontré. La raison de leur apparition maintenant reste à confirmer avec les nouvelles traces. Les tests précédents ne couvraient pas suffisamment ce parcours distant.

## Corrections apportées

### 1. Arguments PsExec réellement séparés

L'expression antérieure `@('\\'+$Computer,'-accepteula','-nobanner',...)` mélangeait la concaténation et la virgule. En PowerShell, la virgule est prioritaire sur le `+` binaire : la construction peut agréger la cible et les options dans un seul argument. La présence du texte `-accepteula` dans le source ne suffisait donc pas à garantir sa transmission comme option.

La cible est maintenant calculée séparément, puis placée dans un tableau de chaînes. La cible et les deux premières options sont vérifiées avant le lancement. L'appel du processus utilise des paramètres nommés. Une cible invalide est refusée sans exécution. Une sortie contenant la licence produit un diagnostic bref au lieu de recopier tout le contrat. Un code de sortie non nul n'est plus accepté comme succès, même en présence d'un marqueur JSON.

### 2. Un compte distant cohérent

CIM, PsExec, le partage administratif et `schtasks` utilisent la même priorité : compte poste explicite, compte distant dédié, compte AD explicite prévu par le contexte, puis session Windows en l'absence de compte explicite. Un refus sur un compte sélectionné ne provoque plus de nouvelles tentatives silencieuses sous d'autres comptes.

La découverte du dernier utilisateur effectue aussi une validation LDAP. Elle conserve maintenant le compte AD nécessaire à cette étape, indépendamment du compte utilisé pour accéder au poste. Un rejet d'authentification AD déjà détecté reste bloquant ; aucun garde-fou n'est retiré.

### 3. Staging via le lecteur PowerShell authentifié

Le lecteur temporaire créé sur `ADMIN$` est utilisé de bout en bout pour écrire, lire et supprimer les fichiers de secours, au lieu de repasser directement par `System.IO.File` sur le chemin UNC. La racine du lecteur est contrôlée. Le résultat distant est publié par un fichier temporaire, puis renommé, pour éviter de lire un JSON en cours d'écriture. Les fichiers temporaires et le lecteur sont nettoyés en sortie.

Cette modification rend le chemin d'accès cohérent avec le lecteur et le compte sélectionnés. Elle ne prouve pas que l'ancien accès .NET était l'unique cause du refus observé. **Un véritable refus SMB/ADMIN$ demeure possible et sera affiché.**

### 4. Erreurs exploitables au lieu d'un message générique

Les erreurs DCOM et WSMan de création de session CIM sont conservées séparément. Le journal Association indique le contexte AD, le contexte poste et les tentatives pertinentes, sans journaliser leurs mots de passe. Un compte utilisateur absent de l'annuaire est distingué d'une validation LDAP refusée. La désactivation de WinRM est respectée avant les sondes de ports ; le mode SSL est sélectionné lorsque seul le port 5986 est disponible.

Un échec de confirmation distante ne supprime pas une association déjà en cache. Le statut reste bref et renvoie aux tentatives détaillées, au lieu de dupliquer la même longue erreur.

## Installer dans ton dossier existant

Fermer ADCC après la fin de toute opération active. Extraire ce ZIP dans **un autre dossier**, puis ouvrir Windows PowerShell 5.1 dans le nouveau dossier `ADCC`. Adapter le chemin de destination :

```powershell
# Prévisualiser le plan : aucune copie et aucun test créant des fichiers.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf

# Vérifier puis installer.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

Le manifeste et la syntaxe sont contrôlés. L'installateur exécute ensuite les tests PowerShell isolés du correctif **avant de remplacer le code**. Si un test échoue, il s'arrête avant cette copie et affiche le chemin du rapport JSON créé dans `%TEMP%`. L'option `-WhatIf` n'exécute pas ces tests, car ils utilisent des fichiers temporaires locaux.

Le journal fourni indiquait également zéro association chargée et aucune base locale reconnue. Cela ne suffit pas à expliquer le défaut, mais justifie de vérifier que tu utilises bien ton installation existante plutôt qu’une copie neuve sans cache.

Le code remplacé est sauvegardé. **Les fichiers déjà présents de configuration et de préférences, ainsi que `wad\data`, ne sont pas remplacés.** Ne pas supprimer ton ancienne installation pour lancer une copie neuve : le paquet livré ne contient ni ta base de parc ni tes journaux. La procédure de restauration du code reste décrite dans `LIRE-MOI.md`.

Le test autonome est `TESTER-DISTANT.cmd`. Il ne lance pas ADCC et ne contacte aucune machine : les lanceurs de processus, LDAP, CIM et le partage distant sont remplacés par des doublures de test. Le test du staging utilise un vrai lecteur PowerShell pointant uniquement vers un dossier temporaire local. Aucun PsExec ou `schtasks` réel n'est exécuté par cette suite. Le rapport est enregistré dans `%TEMP%`, et son chemin est affiché à la fin.

## Validation effectuée et limites

**Résultats sur le poste de préparation : 29 contrôles ciblés, 14 contrôles de thème et 43 contrôles généraux réussis ; aucun échec.** Ces catégories mêlent assertions statiques, parsing XML, vérifications d’empreintes et essais SQLite sous Python. Ce ne sont pas 86 essais de fonctionnement sur Windows.

Les rapports séparés sont dans `wad/docs/AUDIT-REMOTE-R1.2.json`, `AUDIT-THEME-R1.2.json` et `AUDIT-GENERAL-R1.2.json`.

- `audit_remote.py` : contrôles statiques du code réellement livré, des arguments, des chemins, des comptes, des diagnostics et de l'intégration des tests.
- `audit_theme.py` : contrôles statiques des préférences, des ressources et des contrastes calculés ; pas un rendu WPF.
- `audit_project.py` : structure et délimiteurs, XML, empreintes des workers et des binaires, requêtes SQL extraites exécutées sur des données synthétiques, essais de sauvegarde SQLite via Python, manifeste et absence de données personnelles dans le paquet.

**PowerShell natif, WPF et accès AD/SMB réels n'ont pas été exécutés dans l'environnement Linux de préparation.** Les tests PowerShell fournis constituent une validation supplémentaire à exécuter sur Windows, pas un succès déjà obtenu ici. Les tests avec doublures ne valident pas les permissions, le réseau, l'antivirus, WinRM ou la stratégie de sécurité de ton organisation.

Les fonctions de thème et les exécutables/DLL sont conservés depuis R1.1. Une seule empreinte de corps worker change : `ComputerLastUser`. Le détail de la comparaison figure dans `wad/docs/CHANGEMENTS-R1.2.json`, et le diff du cœur dans `wad/docs/ADCC-R1.2-REMOTE.patch`.

## Recette ciblée après installation

Relancer ADCC avec le même mode de connexion que précédemment et vérifier le thème des trois écrans. Rechercher une machine autorisée, ouvrir sa fiche puis rafraîchir l'association utilisateur. Contrôler le contexte des comptes dans le journal Association et le résultat de chaque méthode. Un utilisateur annoncé comme vérifié doit avoir passé la validation LDAP ; un refus doit rester un refus explicite.

Si l'accès est encore refusé, conserver les nouvelles lignes Association depuis « Comptes effectifs » jusqu'au résultat final : elles distinguent les erreurs classiques de celles des deux secours. Ne pas désactiver le pare-feu, l'UAC, les GPO ou l'antivirus pour faire disparaître le message.

## Périmètre de sécurité inchangé

Le correctif n'accorde aucun droit administrateur, ne modifie pas les ACL ou les paramètres de sécurité et ne force pas l'activation d'un service. Les mécanismes distants PsExec et tâche planifiée existaient déjà dans ADCC ; lorsqu'ils sont utilisés dans l'application réelle, ils nécessitent les autorisations correspondantes et créent des éléments temporaires distants. Les qualifier d'opérations sans effet sur le poste serait inexact.

Le risque historique des mots de passe explicites passés en arguments à PsExec ou `schtasks` reste présent. Les références locales au tableau sont libérées après appel et le mot de passe n'est pas ajouté au journal, mais cela ne garantit pas son effacement de la mémoire ou son invisibilité aux outils d'inspection de processus autorisés.

## Références techniques

Documentation Microsoft consultée pour les règles de langage et les commandes :

- [Priorité des opérateurs PowerShell 5.1](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_operator_precedence?view=powershell-5.1).
- [PsExec et ses options](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec).
- [New-PSDrive, chemins UNC et Credential](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/new-psdrive?view=powershell-5.1).

Les conclusions sur les défauts et les modifications proviennent de la comparaison des archives et du code, pas de ces pages documentaires. Aucun contenu personnel du journal n'est recopié dans les fixtures de test ou dans ce rapport.
