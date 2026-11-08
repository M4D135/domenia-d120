# Domenia 1.0 RC1.1 : correction du démarrage et des ACL

Build du moteur : `2026.10.01-DOMENIA-1.0-RC1.1-ACL`.
Base : archives Domenia 1.0 RC1 DEV et PROD fournies dans cette conversation.

## Incident traité

Le journal transmis s'arrête pendant un appel à `SetAccessControl`, avec une
`PrivilegeNotHeldException` mentionnant `SeSecurityPrivilege`. Le bootstrap indique
Windows PowerShell 5.1, en 64 bits. Il n'y a dans ces deux journaux aucune preuve
qu'un compte ou un mot de passe AD ait été rejeté.

Dans RC1, l'initialisation du stockage construit un objet `DirectorySecurity` puis
appelle `SetSecurityDescriptorSddlForm` avec un seul argument. Cette surcharge
vise `AccessControlSections.All`, pas seulement les permissions d'accès. Elle
marque notamment la SACL comme modifiée, même lorsque le SDDL fourni ne contient
pas de section `S:`. L'enregistrement tente alors aussi de traiter la partie
audit et peut exiger le privilège signalé dans le journal.

Le même modèle était employé pour les reçus des opérations et le dossier de dépôt
distant. Ces deux sites ont été corrigés en même temps afin de ne pas déplacer le
même problème vers la première opération utilisant ces fonctions.

## Correction appliquée

Les trois appels emploient maintenant la surcharge à deux arguments :

```powershell
$acl.SetSecurityDescriptorSddlForm(
    ('D:P(A;OICI;FA;;;' + $sid + ')(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'),
    [Security.AccessControl.AccessControlSections]::Access
)
```

Cet exemple correspond au stockage local et aux reçus. Le dépôt distant conserve
sa DACL distincte, restreinte à SYSTEM et au groupe Administrateurs.

Les permissions DACL prévues sont conservées : pas d'ajout de Tout le monde,
pas de suppression de la protection contre l'héritage. Le correctif ne demande
plus de modifier le propriétaire, le groupe principal ou les règles d'audit.
Il n'active aucun privilège, ne modifie aucune GPO, ne désactive aucune protection
Windows et n'ajoute pas d'élévation au démarrage.

Un vrai refus de modification des permissions reste une erreur : il n'est pas
ignoré et le stockage n'est pas déclaré validé. Pour les données et les reçus,
l'erreur expose désormais le chemin concerné et conserve l'exception d'origine,
avec `DOMENIA_STORE_DACL` ou `DOMENIA_RECEIPT_DACL`.

## Périmètre volontairement limité

Seuls deux fichiers du runtime changent :

- `wad/Domenia-Core.ps1` : permissions du stockage, permissions du dépôt distant,
  diagnostic local et affichage du build RC1.1 ;
- `wad/modules/Domenia-Receipts.Worker.ps1` : permissions des reçus et diagnostic.

L'authentification, la recherche LDAP, l'interface, les données, les paramètres
et les autres fonctions de RC1 ne sont pas réécrits. Les 54 corps d'opérations
et leur registre d'empreintes sont inchangés ; le helper commun de dépôt distant
contient toutefois le correctif décrit ci-dessus.

Le lanceur natif `Domenia.exe` est conservé octet pour octet : aucune nouvelle
compilation n'est nécessaire pour ce correctif PowerShell. Les propriétés du
lanceur Windows peuvent donc encore indiquer RC1. Le build du moteur, dans les
journaux et le diagnostic du login, indique bien **Domenia 1.0 RC1.1**.
Les limites et les points partiellement réalisés du plan M01 à M42 restent ceux
du guide RC1. Ce hotfix ne prétend pas clore ce plan ni certifier les accès au parc.

## Installation sans perte de données

### Mettre à jour une installation existante

1. Fermer toutes les instances après la fin de leurs opérations. Ne pas supprimer
   les reçus ou les fichiers d'état pour contourner un verrou.
2. Extraire le pack **DEV RC1.1 dans un dossier distinct**, non imbriqué dans
   l'installation actuelle.
3. Depuis ce nouveau dossier `dev`, lancer Windows PowerShell :

```powershell
# Remplacer la destination par le dossier qui contient actuellement Domenia.exe et wad.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\Domenia'
```

L'installateur conserve `wad\data`, les configurations existantes et les données
locales utilisateur. Il sauvegarde le code remplacé. Il vérifie le manifeste et
la syntaxe, puis exécute les suites `Test-DomeniaCandidate.ps1` et
`Test-DomeniaAcl.ps1` avant toute copie du code. Un test en échec interrompt la mise
à jour ; conserver le rapport indiqué, sans retirer le test pour forcer la copie.

Ne remplacer **ni seulement le cœur ni seulement le module des reçus** : le
manifeste de la distribution doit correspondre aux deux fichiers corrigés.
Le retour arrière du code reste accessible avec `-RestoreBackup` et le chemin
exact fourni par l'installateur ; il ne supprime ni ne restaure les données.

### Nouvelle distribution

Extraire entièrement le pack PROD. Sa racine reste :

```text
prod/
├── Domenia.exe
└── wad/
    └── Support/
        ├── DEBLOQUER_TOUT.cmd
        ├── Debloquer-Paquet.ps1
        └── .lifecycle.lock
```

Les autres composants du moteur restent dans `wad`. Les tests, outils et démos
restent propres à DEV et ne sont pas requis par PROD. Le script de déblocage
reste dans `wad\Support`, pas à la racine. Il ne contourne pas les politiques
AppLocker/WDAC, de signature ou d'antivirus.

## Vérifications réalisées et à réaliser

### Réalisé dans l'environnement de préparation

- Réexécution de l'audit portable : **204 contrôles réussis**, zéro échec.
- Audit ciblé du correctif : **57 contrôles de source et de non-régression
  réussis**, zéro échec.
- Contrôle des trois appels SDDL, des DACL inchangées, des exceptions conservées,
  de l'absence d'activation de privilèges et de la portée limitée du changement.
- Comparaison des fonctions d'authentification, des opérations, des binaires,
  des configurations et des autres composants avec l'archive RC1 originale.
- Vérification finale des CRC, chemins, tailles et empreintes des deux ZIP et de
  l'identité du runtime entre DEV et PROD.

Ces contrôles sont réalisés avec Python sous Linux, pas avec l'API de sécurité
Windows. L'audit général comprend également ses essais SQLite et XML existants.
Les contrôles lexicaux PowerShell ne remplacent pas le parseur natif.

### Test Windows fourni, non exécuté ici

Depuis DEV, lancer **`TESTER-ACL.cmd`**, de préférence avec le compte Windows
habituel, sans le lancer spécifiquement en administrateur. Ce script :

- extrait par AST les expressions réelles du runtime, sans lancer Domenia ;
- vérifie les indicateurs internes .NET Access/Audit/Owner/Group ;
- montre en mémoire la différence avec la surcharge défectueuse RC1 ;
- vérifie que des règles d'audit témoins restent intactes en mémoire ;
- applique la DACL corrigée à des dossiers temporaires de test locaux et vérifie
  leurs permissions, leur propriétaire et leur groupe ;
- appelle le vrai helper des reçus sur une racine temporaire explicitement fournie ;
- vérifie l'écriture d'un fichier témoin, la répétition et le nettoyage.

Aucune lecture ou écriture de SACL sur disque, aucune modification du cache de
production, aucun compte saisi, aucun LDAP, aucune tâche distante et aucun accès
au parc. Les objets SACL témoins restent uniquement en mémoire. Les fichiers
créés sont confinés au dossier temporaire unique de la suite ; le rapport reste
au chemin annoncé. Le script enregistre aussi si le processus de test était élevé.

Un test lancé élevé ne démontre pas le comportement avec un compte standard.
Une exécution locale de cette suite ne valide pas l'accès à `ADMIN$` sur le parc,
ni l'authentification, le rendu WPF ou toutes les opérations du programme.

**Non exécutés ici : Windows PowerShell 5.1, persistance native des ACL sous
Windows, exécution du PE, WPF, authentification et accès distant réels.**
Les rapports RC1 restent historiques et ne sont pas présentés comme nouveaux
résultats Windows. Aucune modification supplémentaire de droits n'est demandée
pour contourner l'incident signalé.

## Sources techniques

- Microsoft .NET Framework Reference Source, `ObjectSecurity`, surcharge SDDL et
  mise à jour des sections :
  https://github.com/microsoft/referencesource/blob/main/mscorlib/system/security/accesscontrol/objectsecurity.cs
- Microsoft Learn, `SetSecurityDescriptorSddlForm(String, AccessControlSections)` :
  https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.objectsecurity.setsecuritydescriptorsddlform?view=netframework-4.8.1
- Microsoft Learn, `AccessControlSections` :
  https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.accesscontrolsections
- Microsoft Learn, accès à la SACL :
  https://learn.microsoft.com/en-us/windows/win32/secauthz/sacl-access-right

Les deux journaux transmis fondent le constat d'échec. La documentation et le
code .NET expliquent la demande de privilège ; les tests Windows fournis servent
à confirmer le comportement corrigé sur l'environnement cible.
