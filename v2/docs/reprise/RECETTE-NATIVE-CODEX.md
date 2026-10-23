# Pilote natif explicite — Audit, Opérations et Poste

Ce pilote est compilé avec `Domenia.Tests`, mais aucune méthode de recette n’est marquée `[Test]`. Une suite C# ordinaire ne contacte donc aucun domaine. La recette n’est autorisée qu’en phase finale, après le développement et les compilations Debug/Release dans la VM. Elle doit être lancée séparément sur la VM domaine et la VM Domenia, sans fermer leur session de bureau.

## Préparation vérifiable

Conserver le commit exact et les preuves de compilation. Choisir deux objets **existants et dédiés** sous `OU=Domenia-Tests,DC=cnamts,DC=local` : un utilisateur dont le SAM commence par `domenia-canary` et un groupe. Le poste non contrôleur peut rester dans sa vraie OU ou dans `CN=Computers` du domaine : sa lecture est autorisée, aucune écriture ne le cible. Ne pas déplacer le compte d’une VM pour satisfaire la recette. Le pilote ne crée aucun objet. Le compte opérateur ne peut pas être le canari. Les objets critiques ou protégés sont refusés. La seule écriture AD autorisée est la description de cet utilisateur, puis sa restauration par un nouveau plan de compensation.

Lire le DN, GUID, SID, `whenCreated` UTC, SAM et DNS du poste sur le contrôleur choisi, avec les outils AD déjà présents. Les valeurs du manifeste doivent correspondre exactement à cette lecture ; ne pas remplacer une identité refusée par celle d’un homonyme. `originalDescription` est la valeur initiale exacte, ou `null` quand l’attribut est absent. Les identités sont relues avant l’envoi et avant chaque opération de recette.

Préparer un manifeste par VM et par invocation, de 16 Kio au plus, avec ces noms de propriétés (aucune clé supplémentaire ou dupliquée admise) :

```json
{
  "format": "Domenia.NativeAcceptance/1",
  "runId": "32 caractères hexadécimaux minuscules neufs",
  "machine": "nom exact de cette VM",
  "controller": "nom du contrôleur choisi.cnamts.local",
  "operatorSid": "SID Windows du compte exécutant",
  "sourceCommit": "40 caractères hexadécimaux du commit compilé",
  "assemblySha256": "64 caractères hexadécimaux de Domenia.Tests.dll",
  "canary": {
    "dn": "CN=Canari,OU=Domenia-Tests,DC=cnamts,DC=local",
    "objectGuid": "GUID réel du canari",
    "sid": "SID réel du canari",
    "createdAt": "date réelle whenCreated au format ISO 8601 UTC",
    "sam": "domenia-canary",
    "host": null
  },
  "originalDescription": null,
  "group": {
    "dn": "DN réel du groupe sous Domenia-Tests",
    "objectGuid": "GUID réel du groupe",
    "sid": "SID réel du groupe",
    "createdAt": "date réelle whenCreated au format ISO 8601 UTC",
    "sam": "SAM réel du groupe",
    "host": null
  },
  "computer": {
    "dn": "DN réel du poste dans cnamts.local (lecture seulement)",
    "objectGuid": "GUID réel du poste",
    "sid": "SID réel du poste",
    "createdAt": "date réelle whenCreated au format ISO 8601 UTC",
    "sam": "SAM réel terminé par $",
    "host": "nom DNS réel.cnamts.local"
  }
}
```

Ce modèle contient volontairement des descriptions invalides : il ne peut pas être exécuté sans les vraies identités. Les propriétés d’exécution se calculent dans la VM :

```powershell
[guid]::NewGuid().ToString('N')
$env:COMPUTERNAME
[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
(Get-FileHash -LiteralPath '.\Domenia.Tests.dll' -Algorithm SHA256).Hash.ToLowerInvariant()
```

## Exécution finale

Depuis le dossier compilé dans la VM, avec la session Windows intégrée attendue :

```powershell
.\Domenia.Tests.exe --native-acceptance C:\DomeniaDev\recette-manifeste.json --read-only
```

Cette forme prépare une base locale isolée, lit les objets de l’OU et exerce les 21 contrats du lecteur Audit, les consultations Opérations et les lectures inventaire/logiciels/sessions/diagnostic du poste. Elle ne donne aucun consentement de repli SYSTEM.

Depuis le cockpit SSH, utiliser le relais existant vers le **bureau déjà ouvert**, sur chacune des deux VM, avec le même lot compilé et un manifeste propre à la VM. Ne pas utiliser le jeton SSH pour l’authentification AD ; la lecture LDAP doit partir de la session interactive :

```powershell
& C:\DomeniaDev\src\LOT\v2\tools\desktop-run.ps1 -Script native-acceptance-vm.ps1 -Session desktop -TimeoutSeconds 7200 -Arguments @{
  Manifest = 'C:\DomeniaDev\recette-manifeste.json'
  Mode = 'read-only'
  Configuration = 'Release'
  FinalValidation = $true
}
```

Le wrapper refuse la session 0 et l’absence du runtime local. Il ne compile, ne télécharge et n’installe rien. Copier le lot compilé dans la VM Domenia vers la VM domaine si nécessaire ; conserver ses empreintes. Pour le canari, choisir `Mode = 'canary'` avec son nouveau manifeste. L’option `FinalValidation` doit être absente de toute étape de développement. Le relais de bureau dispose d’un délai d’arrêt : ne pas le réduire à quelques secondes autour d’une écriture ; une interruption impose de relire les reçus, jamais de réessayer l’envoi.

Le canari est une invocation distincte avec un **nouveau** `runId`, un manifeste relu et l’option explicite :

```powershell
.\Domenia.Tests.exe --native-acceptance C:\DomeniaDev\recette-manifeste-canari.json --canary
```

Le plan de description est contrôlé puis exécuté une seule fois via `WriteCircuit`. Un reçu `Applied/Verified` et une lecture indépendante de la valeur sont exigés avant le nouveau plan inverse. La compensation passe par `CompensationPlanner` et le même circuit ; le GUID, le DN, le contrôleur, le compte et les valeurs avant/après restent contrôlés. Une dernière lecture indépendante doit retrouver la description initiale. Aucun jeton de confirmation n’est enregistré.

Les preuves sont conservées dans `%LOCALAPPDATA%\Domenia\E2E\NativeAcceptance\<runId>\evidence.jsonl`, chaque événement étant vidé sur disque. L’ouverture `CreateNew` interdit de rejouer une invocation interrompue. Le journal de reçus durable commun est `%LOCALAPPDATA%\Domenia\E2E\NativeAcceptance\receipts-native-acceptance.jsonl` avec sa protection et ses archives. Ne jamais le supprimer pour contourner un refus : toute incertitude bloque la prochaine recette. Un échec de compensation laisse les reçus et le plan ; aucune restauration aveugle ne suit.

## Qualification

Un retour de méthode n’est pas une preuve de résultat sain. Les preuves portent `Returned` et `qualified:false` : examiner les états refusé, inconnu, incomplet et les valeurs natives de chaque résultat. Un code processus 0 indique que le protocole a terminé sans exception, pas que la recette métier entière est validée. Une exception produit un code 1 et conserve les preuves antérieures ; un usage invalide produit 2.

Le pilote ne couvre pas à lui seul les scénarios d’interface, la reprise de relevé après interruption, les écritures autres que description, ni le repli SYSTEM réel et son nettoyage. Leur recette complémentaire reste requise. Aucun transport PsExec n’est qualifié : aucun binaire n’est livré, aucun exécuteur approuvé n’est raccordé dans v2, et l’inventaire VM initial ne l’a pas trouvé. Aucun téléchargement n’est autorisé par ce protocole.

## Parité du noyau inventaire de repli D1

La source de référence est `dev/wad/Domenia-Core.ps1`, `Get-DomeniaInventoryWorkerCode` / `Invoke-InventoryTaskFallback`. Son programme local lit ComputerSystem, BIOS, OperatingSystem, Processor, PhysicalMemory, LogicalDisk, NetworkAdapterConfiguration et les hotfixes en mode approfondi. Le programme v2 ferme ces mêmes sources et leurs projections ; le numéro de série BIOS est maintenant conservé lorsque le châssis ne l’a pas fourni. Il ajoute notamment TPM, BitLocker, antivirus et services. Les plafonds et refus restent visibles ; cela ne prouve pas que toutes les catégories d’un inventaire direct complet ont été lues sous SYSTEM.

`Get-WPsExecPath` de D1 recherche un exécutable portable déjà placé à côté du lanceur ou dans `wad`. Le contrat est donc optionnel au déploiement et ne justifie aucun téléchargement implicite. En v2, `UsePsExecFallback` existe mais aucun chemin ou fournisseur approuvé n’est raccordé : le transport reste un écart réel, distinct de la couverture du programme par tâche planifiée.
