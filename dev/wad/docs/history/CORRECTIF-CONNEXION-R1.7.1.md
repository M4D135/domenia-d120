# ADCC 1.0 R1.7.1 : correctif du parcours de connexion

**Build : `2026.09.22-R1.7.1-LOGIN`**  
Base : le pack complet R1.7 fourni dans cette conversation. L'interface guidée est conservée.

## Ce qui est établi, et ce qui ne l'est pas

La capture affiche « Indexation impossible dans un tableau Null ». Ce message ne suffit pas à conclure que les identifiants sont incorrects. La partie technique est tronquée à l'écran ; aucun journal du nouvel incident n'a été fourni.

Un défaut concret est présent dans le moteur de R1.7 : après l'échec d'un `RefreshCache` sur la base AD, le bloc `catch` relit directement `Properties["distinguishedName"].Value`, sans protéger la collection. Si cette seconde lecture échoue avec un tableau nul, elle masque la première exception. Les lectures de RootDSE utilisent également des accès adaptés et des doubles index non protégés.

R1.7.1 corrige ce parcours. La capture seule ne permet cependant pas d'établir la ligne exacte qui a échoué sur le domaine, ni la cause sous-jacente d'un éventuel refus AD. Le correctif ne vaut pas validation d'une connexion réelle. Le corps du moteur de connexion était déjà identique dans les archives antérieures : son défaut n'est pas attribué sans preuve à la refonte graphique.

## Modifications du moteur

- Les membres CLR de `DirectoryEntry` sont adressés par `psbase`, pour éviter les ambiguïtés avec les membres adaptés.
- Les objets ADSI et les collections sont contrôlés avant indexation. Une valeur absente n'est jamais assimilée à une connexion réussie.
- Un échec de `RefreshCache` conserve son exception initiale : aucune seconde lecture non protégée ne remplace cette erreur.
- La validation explicite demande toujours un objet natif et une lecture de la base. L'absence du DN lu provoque un échec explicite, pas un faux succès.
- Le résultat d'échec transporte l'étape, le contrôleur utilisé, l'identifiant de l'erreur, son type, le HRESULT, la ligne relative au worker et sa pile d'appels.
- Une erreur interne, des métadonnées incomplètes, un refus de droits et un refus d'identifiants ne sont plus présentés avec le même conseil.
- `LDAP=-1` n'est plus présenté comme un code de réponse LDAP reçu : les exceptions sans code LDAP sont indiquées comme ADSI/PowerShell.

Les étapes du journal permettent notamment de distinguer `Discovery.NativeBind`, `Discovery.RootDSE`, `Explicit.NativeBind` et `Explicit.ReadBase`. La ligne du worker est relative au script exécuté dans le runspace, pas nécessairement au même numéro dans `ADCC-Core.ps1`.

## Aucun contournement de l'authentification

Le choix et la qualification de l'identifiant restent ceux de R1.7. Le mot de passe n'est pas transformé. Le bind explicite conserve `AuthenticationTypes.Secure`, et le chemin Windows conserve `Negotiate`.

Le programme n'ajoute pas d'essais successifs d'autres mots de passe, d'autres identités, d'autres contrôleurs après l'envoi des identifiants explicites, ni de bascule automatique sur le compte Windows. Un échec ne produit pas de session validée artificiellement. Les droits AD, les confirmations et la lecture seule ne sont pas assouplis.

La structure de diagnostic ajoutée utilise une liste fixe de huit champs. Elle ne sérialise ni la requête, ni le PSCredential, ni le contenu des champs de mot de passe. Les journaux restent des informations internes à relire avant partage ; ce ne sont pas des fichiers anonymisés.

## Écran de connexion

Deux boutons deviennent accessibles sans passer en mode Debug : **Ouvrir le journal** et **Copier le diagnostic**. Ils utilisent les actions de diagnostic existantes. Les erreurs et conseils peuvent revenir à la ligne dans une zone agrandie ; la fenêtre standard passe à 612 unités WPF de hauteur.

En cas d'erreur interne, le conseil ne demande plus systématiquement de corriger le mot de passe ou de changer de mode de connexion. Le message technique original reste dans le journal, avec une nouvelle entrée `LOGIN_DIAGNOSTIC` lorsqu'un diagnostic structuré est disponible.

Les thèmes de connexion existants restent utilisés. L'interface principale, les modules d'aide, l'Atelier, les actions distantes et les binaires ne sont pas redessinés ou remplacés.

## Installation complète ou mise à jour

Le ZIP contient l'application complète, ses modules et les tests. Il ne contient **pas** votre base personnelle, vos journaux ni vos préférences enregistrées.

### Mettre à jour une installation existante

Fermer ADCC après la fin des opérations. Extraire ce ZIP dans un dossier distinct, non imbriqué dans l'installation actuelle. Depuis le nouveau dossier `ADCC` :

```powershell
# Remplacer le chemin par celui de l'installation existante.
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC' -WhatIf
.\INSTALLER-MISE-A-JOUR.ps1 -Destination 'C:\Outils\ADCC'
```

L'installateur conserve `wad\data` et les configurations existantes, vérifie le manifeste et la syntaxe PowerShell, puis lance les suites natives isolées avant de remplacer le code. La nouvelle suite de connexion est exécutée dans un processus séparé, sans connexion à un domaine. Un test en échec ou un rapport incomplet arrête l'installation avant la copie du code. Le chemin du rapport temporaire est affiché.

Ne pas copier uniquement le fichier du cœur : installer le pack avec ses modules et son manifeste. Le mécanisme de sauvegarde et de retour arrière du code est conservé. La restauration ne restaure ni ne remplace la base personnelle :

```powershell
.\INSTALLER-MISE-A-JOUR.ps1 -RestoreBackup 'CHEMIN_EXACT_AFFICHE_PAR_L_INSTALLATEUR'
```

### Nouvelle installation

Extraire entièrement le dossier `ADCC`, conserver `wad` à côté des lanceurs, puis utiliser `LANCER-ADCC.cmd`. Les politiques d'exécution et de sécurité de l'organisation restent applicables.

### Recette sur le poste

Lancer `TESTER-CONNEXION.cmd` pour exécuter les nouveaux scénarios isolés. Puis lancer normalement ADCC et faire un seul essai volontaire avec les identifiants habituels. Vérifier dans le diagnostic le build `2026.09.22-R1.7.1-LOGIN` ou `ADCC 1.0 R1.7.1 CONNEXION`.

En cas de nouvel échec, utiliser **Copier le diagnostic** ou **Ouvrir le journal**. Le journal est habituellement `wad\data\Logs\ADCC-login.log`, avec un éventuel repli vers le dossier de données utilisateur ; le bouton ouvre le chemin choisi par l'application. Ne pas transmettre de mot de passe.

## Vérifications : distinction indispensable

**Exécuté ici : 62 contrôles de source, XML et empreintes, sans échec.** Le rapport se trouve dans `wad\docs\AUDIT-CONNEXION-R1.7.1.json`. Ils comprennent les délimiteurs lexicaux des scripts, la structure XML de la connexion, les gardes d'accès ADSI, la présence des diagnostics, le maintien des paramètres d'authentification et la comparaison du code avec R1.7. Un contrôle de délimiteurs ne remplace pas le parseur PowerShell natif.

Quatre fonctions existantes ont changé, une fonction de conseil a été ajoutée, aucune fonction principale n'a été supprimée. Les 562 autres fonctions principales de R1.7 restent identiques. Les binaires et modules R1.7 ont les mêmes empreintes. Le diff du cœur et les empreintes conservées sont fournis dans `wad\docs`.

**Fourni mais non exécuté ici : 30 scénarios PowerShell natifs** dans `wad\tests\Test-ADCCLogin.ps1`. Ils extraient le code par AST et utilisent des objets C# inertes pour simuler les accès ADSI. Ils couvrent les collections nulles, l'erreur masquée de l'ancien code, la conservation de la première erreur, les collisions simulées de membres, les refus réels simulés, le bind unique, le nettoyage et l'absence de secrets dans le diagnostic. Un scénario vérifie le transport MTA réel avec `SelfTestOnly`, avant toute découverte de domaine.

Les simulations avant/après utilisent une fixture de l'ancienne fonction conservée uniquement pour les tests. Elles ne constituent ni un test réel de l'adaptateur ADSI de Windows, ni une reproduction de l'incident sur votre domaine.

**Non exécuté ici : Windows PowerShell 5.1, WPF, connexion LDAP/ADSI réelle, authentification au domaine, vérification visuelle de la nouvelle fenêtre.** Les tests fournis et ceux de l'installateur doivent encore être exécutés sur Windows. L'affichage des 612 unités doit notamment être vérifié avec le facteur d'échelle du poste.

Les rapports d'audit antérieurs restent dans le pack à titre historique. Certaines anciennes assertions imposaient une empreinte immuable au moteur d'authentification ; elles sont devenues obsolètes pour ce correctif intentionnel. Elles ne sont pas présentées comme des validations nouvelles de R1.7.1.

## Références techniques

Les membres intrinsèques `psbase` sont documentés dans la documentation Microsoft PowerShell, rubrique `about_Intrinsic_Members`. La collection retournée par `DirectoryEntry.Properties` est décrite dans la documentation .NET de `System.DirectoryServices.DirectoryEntry`. Ces références justifient le choix technique, pas la cause exacte de l'incident affiché dans la capture.
