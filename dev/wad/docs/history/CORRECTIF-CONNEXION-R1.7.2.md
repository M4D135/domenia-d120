# ADCC 1.0 R1.7.2 : conserver l'erreur native de connexion

**Build : `2026.09.22-R1.7.2-NATIVE`**  
**Base : pack complet R1.7.1. Interface R1.7 conservée.**

## Ce que montre le diagnostic fourni

La découverte du domaine a atteint un contrôleur, puis l'appel explicite est arrivé à `Explicit.NativeBind`. Le message `ADCC_AUTH_NATIVE_NULL` et le HRESULT `0x80131509` proviennent du garde-fou `InvalidOperationException` de R1.7.1. Ils ne sont pas le détail d'un refus LDAP renvoyé par le serveur.

Le programme précédent lisait `$baseAdsi.psbase.NativeObject` comme une propriété. PowerShell peut masquer une exception levée par un getter CLR et produire `$null`, y compris avec `ErrorActionPreference = Stop`. Le garde-fou transformait alors cette valeur en une nouvelle exception, qui remplaçait la cause native.

**La cause réelle de l'échec sur le domaine n'est pas encore établie.** Le diagnostic fourni ne prouve ni un mauvais mot de passe, ni la validité du compte, ni un refus de politique particulier. Cette révision corrige le masquage de l'erreur ; elle ne promet pas de lever un refus réel du fournisseur d'authentification.

## Modification ciblée

Les lectures qui peuvent provoquer des opérations ADSI passent par leurs méthodes CLR explicites :

```powershell
# Ancien accès : une exception du getter peut devenir un null silencieux.
$nativeBase = $baseAdsi.psbase.NativeObject

# R1.7.2 : l'exception du getter peut être interceptée par le catch du worker.
$nativeBase = $baseAdsi.psbase.get_NativeObject()
```

La même correction est appliquée au getter de découverte, au getter `Properties` et à l'indexeur `get_Item`. L'accès à la collection et l'attribut restent contrôlés.

Le vrai retour nul reste un échec. Le programme doit encore obtenir l'objet natif, puis réussir `RefreshCache` et lire un `distinguishedName` non vide sur **la même entrée créée avec les identifiants explicites** avant de déclarer la connexion réussie.

Il ne supprime donc pas la validation. Il ne remplace pas le compte explicite par la session Windows et ne tente pas automatiquement un autre contrôleur après cette tentative explicite.

## Diagnostic plus exploitable

Le résultat conserve une liste fixe de 13 champs : étape, serveur, tentative explicite, identifiant d'erreur, type d'exception, HRESULT, ligne du worker, pile, identité de bind, message natif, code étendu, message étendu et code LDAP éventuel.

Le code LDAP reste vide lorsqu'aucune `LdapException` n'a été reçue. Un HRESULT n'est pas présenté comme un code LDAP. Le contrôleur réellement choisi est aussi renvoyé dans le résultat d'échec, au lieu du simple nom de domaine utilisé pour la découverte.

Le classement des erreurs connues repose d'abord sur les codes natifs, pas seulement sur des fragments de messages traduits. Par exemple, les restrictions de poste, comptes verrouillés, refus d'accès et indisponibilités de serveur restent distingués. Un échec de bind inconnu garde la catégorie `Authentication`, sans être automatiquement attribué au DNS ou au mot de passe.

Le code `52e` ne signifie plus « mot de passe seul incorrect » dans le formatteur. Un compte verrouillé ne produit plus l'affirmation non démontrée « le mot de passe n'est pas en cause ». Les correspondances numériques du message court sont bornées : un serveur nommé `dc775` ne suffit pas à déclarer un compte verrouillé.

L'identité qualifiée effectivement utilisée est indiquée. Les nouveaux détails ne sérialisent pas le `PSCredential`, la requête, les lignes sources de l'invocation ni `Exception.Data`. Une occurrence exacte du mot de passe soumis est retirée des textes de diagnostic si un message la réinjecte. **Ce filtrage n'est pas une anonymisation globale : les journaux contiennent des données internes et doivent être relus avant partage.**

## Ce qui ne change pas

Les règles de qualification de l'identifiant, le mot de passe transmis, `AuthenticationTypes.Secure`, le parcours Windows `Negotiate`, les protections d'écriture et le schéma du cache restent en place.

Quatre fonctions principales existantes ont été modifiées. Les **563 autres fonctions principales** conservent leur texte. Aucun nom de fonction principale n'a été supprimé. Deux helpers locaux sont ajoutés à l'intérieur du worker.

Les lanceurs, binaires, DLL, icônes, fichiers de configuration livrés, modules de l'interface et de l'Atelier ainsi que le programme d'aperçu conservent leurs empreintes. Aucun autre réglage visuel n'est ajouté pendant ce dépannage.

## Installation sans perdre les données

Fermer ADCC après la fin des opérations. Extraire le nouveau ZIP dans un dossier **distinct** de l'installation actuelle. Depuis le nouveau dossier `ADCC`, lancer :

```powershell
# Adapter cette destination au dossier existant.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

L'installateur conserve `wad\data` et les configurations existantes, sauvegarde le code remplacé et vérifie les fichiers du manifeste. Les tests natifs isolés précèdent la copie du code. Un échec ou un rapport incomplet arrête la mise à jour.

**Ne pas supprimer l'ancien dossier.** Le ZIP complet ne contient ni la base personnelle ni les journaux ou préférences de l'utilisateur. Ne pas empiler les versions en copiant seulement des fragments de code.

Pour une nouvelle installation, extraire tout le dossier et lancer `LANCER-ADCC.cmd`, avec `wad` à côté des lanceurs. Les politiques de sécurité de l'organisation restent applicables.

La restauration du code reste disponible avec le dossier de sauvegarde exact affiché par l'installateur :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'CHEMIN_DE_SAUVEGARDE_AFFICHE'
```

## Vérifications réellement réalisées et limites

**Exécuté ici : 84 contrôles statiques de source, XML et empreintes, aucun échec.** Ils comprennent les délimiteurs lexicaux des scripts, cinq fenêtres XML littérales, le XAML du module Atelier, les appels de getters, les gardes de validation, le branchement du diagnostic, les empreintes conservées et les assertions de présence des tests. Un contrôle lexical n'est pas une exécution du parseur PowerShell natif.

Rapport courant : `wad\docs\AUDIT-CONNEXION-R1.7.2.json`. Diff du cœur et empreintes comparées : `wad\docs\ADCC-R1.7.2-CONNEXION.patch` et `CHANGEMENTS-CONNEXION-R1.7.2.json`.

**Fourni mais non exécuté ici : 47 scénarios PowerShell dans `TESTER-CONNEXION.cmd`.** Ils utilisent le code extrait par AST et des classes C# inertes. Ils comparent notamment le getter de propriété de R1.7.1 au getter appelé comme méthode, simulent des erreurs COM au message opaque, vérifient le vrai HRESULT, les collections et indexeurs défaillants, l'identité et le contrôleur choisis, le nettoyage et l'absence de répétition de tentative explicite. Le test de transport MTA utilise `SelfTestOnly`, avant toute découverte AD.

La suite interdit les constructeurs DirectoryServices non simulés et remplace la découverte de domaine du système dans les fixtures seulement. Elle ne teste pas les droits réels, les stratégies du domaine ou le comportement du fournisseur ADSI sur le poste de l'utilisateur.

**Non exécuté ici : Windows PowerShell 5.1, compilation C# des fixtures sous Windows, WPF, authentification LDAP/ADSI réelle et connexion à votre domaine.** Aucun résultat Windows n'est inventé. L'installateur attend 47 scénarios réussis et aucun échec avant la copie ; leur exécution reste à effectuer sous Windows.

Les rapports et audits Python des anciennes révisions sont conservés à titre historique. `audit_login.py` concerne R1.7.1, pas cette nouvelle version. Pour refaire les contrôles statiques courants :

```text
python wad/tests/audit_login_native.py --report rapport-statique.json
```

## Vérification sur le poste

Après installation, contrôler le build `ADCC 1.0 R1.7.2 CONNEXION`, puis effectuer une tentative volontaire avec le compte habituel. Le diagnostic doit mentionner `ADSI get_NativeObject` et l'identité réellement utilisée.

En cas d'échec, copier le diagnostic depuis le login, sans ajouter de mot de passe. Les champs `Stage`, `HResult`, `NativeMessage`, `ExtendedCode`, `ExtendedMessage` et `BindIdentity` permettront de distinguer la cause native d'un défaut local. Si le getter renvoie réellement null sans exception, le garde-fou reste bloquant : ce cas n'est pas considéré comme une authentification réussie.

## Références techniques consultées

Les sources suivantes expliquent le comportement du langage et des API, pas la cause du refus particulier sur le domaine.

```text
MicrosoftDocs/PowerShell-Docs, issue #12803, comportement des getters CLR.
https://github.com/MicrosoftDocs/PowerShell-Docs/issues/12803

dotnet/runtime, DirectoryEntry.cs : NativeObject/Bind et RefreshCache.
https://github.com/dotnet/runtime/blob/main/src/libraries/System.DirectoryServices/src/System/DirectoryServices/DirectoryEntry.cs

Microsoft Learn, codes WinError 1300-1699 et 1700-3999.
https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1300-1699-
https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1700-3999-

Microsoft Learn, codes Directory Services 8200-8999.
https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--8200-8999-
```
