# Pilote natif explicite — Audit, Opérations et Poste

Ce pilote est compilé avec `Domenia.Tests`, mais aucune méthode de recette n’est marquée `[Test]`. Une suite C# ordinaire ne contacte donc aucun domaine. La recette n’est autorisée qu’en phase finale, après le développement et les compilations Debug/Release dans la VM. Elle doit être lancée séparément sur la VM domaine et la VM Domenia, sans fermer leur session de bureau.

**Sélection finale du 25/10/2026 : contrôles critiques seulement.** Le mode `--critical-canary` retient `directory.scope`, `audit.machineIdentity`, `operations.history`, `poste.inventory`, ainsi que le canari de description et sa compensation déjà bornés. Il conserve dans un événement `selection` les quatre lectures retenues et les 26 non exécutées ; une sélection vide, inconnue, répétée, incomplète ou un appel hors sélection est refusé. `--critical-read-only` exerce les mêmes quatre lectures sans écriture, mais ne suffit pas au dossier final qui exige les reçus du canari. Les anciens modes complets restent disponibles uniquement pour une demande distincte ; ils ne font pas partie de la recette finale courante. Aucun repli SYSTEM/PsExec, changement de service/runtime/réseau, téléchargement, reboot ou logoff n'est sollicité.

Les deux VM autorisées sont des VM **VirtualBox**. Avant chaque recette, rapprocher côté hôte le nom et l’UUID suivants, puis relever le vrai nom Windows et le SID depuis leur bureau. Le champ `machine` du manifeste contient ce nom Windows, pas un nom de VM supposé identique. Le pilote contrôle le nom Windows ; il n’atteste pas la correspondance VirtualBox à la place de l’opérateur. **PESTO est exclue.**

| VM autorisée | UUID VirtualBox à requalifier côté hôte |
| --- | --- |
| CNAMTS-DC01 | `7625c944-b4fc-4f8b-ac23-c796cc1be791` |
| DOMENIA-FIRSTRUN-20261020 | `bc2f1ac0-9545-49bd-a0f5-cb89d352cf61` |

## Préparation vérifiable

Conserver le commit exact et les preuves de compilation. Choisir deux objets **existants et dédiés** sous `OU=Domenia-Tests,DC=cnamts,DC=local` : un utilisateur dont le SAM commence par `domenia-canary` et un groupe. Le poste non contrôleur peut rester dans sa vraie OU ou dans `CN=Computers` du domaine : sa lecture est autorisée, aucune écriture ne le cible. Ne pas déplacer le compte d’une VM pour satisfaire la recette. Le pilote ne crée aucun objet. Le compte opérateur ne peut pas être le canari. Les objets critiques ou protégés sont refusés. La seule écriture AD autorisée est la description de cet utilisateur, puis sa restauration par un nouveau plan de compensation.

Le SHA du manifeste est vérifié sur `Domenia.Tests.dll`. `sourceCommit` reste une déclaration à rapprocher des preuves de compilation et des empreintes du lot complet : le pilote n’établit pas à lui seul l’identité de toutes les DLL copiées. Conserver le même lot complet et ses empreintes sur les deux VM.

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
.\Domenia.Tests.exe --native-acceptance C:\DomeniaDev\recette-manifeste.json --critical-read-only
```

Cette forme prépare une base locale isolée, lit les objets de l’OU et exerce les quatre lectures critiques citées ci-dessus. Elle ne donne aucun consentement d’écriture ni de repli SYSTEM.

Depuis le cockpit SSH, utiliser le relais existant vers le **bureau déjà ouvert**, sur chacune des deux VM, avec le même lot compilé et un manifeste propre à la VM. Ne pas utiliser le jeton SSH pour l’authentification AD ; la lecture LDAP doit partir de la session interactive :

```powershell
& C:\DomeniaDev\src\LOT\v2\tools\desktop-run.ps1 -Script native-acceptance-vm.ps1 -Session desktop -TimeoutSeconds 7200 -Arguments @{
  Manifest = 'C:\DomeniaDev\recette-manifeste.json'
  Mode = 'critical-read-only'
  Configuration = 'Release'
  FinalValidation = $true
}
```

Le wrapper et l’entrée C# directe refusent la session 0 ; le wrapper refuse aussi l’absence du runtime local. Il ne compile, ne télécharge et n’installe rien. Copier le lot compilé dans la VM Domenia vers la VM domaine si nécessaire ; conserver ses empreintes. Pour le canari critique, choisir `Mode = 'critical-canary'` avec son nouveau manifeste. L’option `FinalValidation` doit être absente de toute étape de développement. Le relais exige `-Session desktop` pour ce pilote et accepte aussi l’appel depuis le bureau déjà ouvert. Son délai d’arrêt ne doit pas être réduit à quelques secondes autour d’une écriture : une interruption impose de relire les reçus, jamais de réessayer l’envoi.

Le canari est une invocation distincte avec un **nouveau** `runId`, un manifeste relu et l’option explicite :

```powershell
.\Domenia.Tests.exe --native-acceptance C:\DomeniaDev\recette-manifeste-canari.json --critical-canary
```

Le plan de description est contrôlé puis exécuté une seule fois via `WriteCircuit`. Un reçu `Applied/Verified` et une lecture indépendante de la valeur sont exigés avant le nouveau plan inverse. La compensation passe par `CompensationPlanner` et le même circuit ; le GUID, le DN, le contrôleur, le compte et les valeurs avant/après restent contrôlés. Une dernière lecture indépendante doit retrouver la description initiale. Aucun jeton de confirmation n’est enregistré.

Les preuves sont conservées dans `%LOCALAPPDATA%\Domenia\E2E\NativeAcceptance\<runId>\evidence.jsonl`, chaque événement étant vidé sur disque. L’ouverture `CreateNew` interdit de rejouer une invocation interrompue. Le journal de reçus durable commun est `%LOCALAPPDATA%\Domenia\E2E\NativeAcceptance\receipts-native-acceptance.jsonl` avec sa protection et ses archives. Ne jamais le supprimer pour contourner un refus : toute incertitude bloque la prochaine recette. Un échec de compensation laisse les reçus et le plan ; aucune restauration aveugle ne suit.

Le chemin du journal est affiché dès son ouverture. Une exception après cette ouverture ajoute `aborted` avec le type de l’erreur et la dernière opération connue, sans recopier un message d’exception arbitraire. La fin normale ajoute `finished` avec `ProtocolCompleted` ou `ProtocolCompletedWithErrors`. Un arrêt du processus ou une panne disque peut laisser une dernière ligne incomplète ou aucun événement terminal : conserver ces octets, ne pas les tronquer. Le SHA-256 et la longueur sont relus depuis le même handle et affichés avant sa fermeture. Les événements sont limités à 2 Mio, le journal à 64 Mio et 128 événements ordinaires, avec une réserve pour l’événement terminal ; un refus de borne conserve ce qui a déjà été écrit.

Le wrapper conserve aussi un journal de lancement `launches\<id neuf>.log` sous la même racine, y compris les refus avant l’ouverture d’`evidence.jsonl`. Il est borné à 4 Mio et signale toute troncature, sans interrompre le processus natif pour ce seul motif. Lorsqu’une tâche interactive est nécessaire, le relais conserve son dossier `C:\DomeniaDev\tasks\Domenia-native-recipe-<lot>-<id>`, son `output.log`, son wrapper et, s’il existe, `exit-code.txt`. Ces dossiers ne sont pas balayés par les lancements génériques suivants. Si aucun code final n’a été observé, la tâche est conservée pour examen et bloque une nouvelle invocation via ce relais. Un timeout demande l’arrêt de cette seule tâche, sans arrêter d’autres processus du lot ; il ne prouve pas l’arrêt distant d’une écriture. Examiner l’état de la tâche, les événements et les reçus avant toute décision manuelle. Aucun nettoyage ou rejeu de recette n’est automatique.

Pour la collecte finale, conserver séparément pour **chaque** VM :

1. Correspondance VirtualBox nom/UUID, nom Windows, SID, session, commit et empreintes du lot compilé.
2. Manifeste exact, journal de lancement et traces de relais, sans remplacer un fichier interrompu.
3. `evidence.jsonl`, sa longueur et son SHA recalculé après fermeture ; journal durable des reçus et ses archives.
4. Pour le canari, les deux reçus `Applied/Verified` et l’événement de relecture indépendante `canary.restored`. Leur absence interdit de déclarer la restauration prouvée.
5. Qualification explicite de chaque résultat brut, captures de l’interface et scénarios complémentaires réellement exercés. Une case non exercée reste non validée.

## Qualification

Un retour de méthode n’est pas une preuve de résultat sain. Les preuves portent `Returned` et `qualified:false` : examiner les états refusé, inconnu, incomplet et les valeurs natives de chaque résultat. Un code processus 0 indique que le protocole a terminé sans exception, pas que la recette métier entière est validée. Une exception produit un code 1 et conserve les preuves antérieures ; un usage invalide produit 2.

Les tests `NativeAcceptanceGuardTests` et `NativeAcceptanceEvidenceTests` utilisent des identités et fichiers locaux de fixture ; ils ne se connectent à aucune VM ni à AD. Ils contrôlent le refus de session de service, les gardes avant/après lecture, l’abandon durable, les bornes, la relecture de l’empreinte et l’absence de faux succès. Leur présence ou leur compilation ne vaut ni exécution des tests ni validation des deux VM. Le relais PowerShell reste à qualifier dans la session interactive autorisée.

Le pilote critique ne couvre pas à lui seul les scénarios d’interface, la reprise de relevé après interruption, les écritures autres que description, ni le repli SYSTEM réel et son nettoyage. Les parcours UI critiques sont qualifiés séparément ; les autres contrôles non exécutés restent explicitement non vérifiés, sans rétablir l'ancienne exigence exhaustive. L’exécuteur PsExec est raccordé et compilé depuis la capture 090 ; sa recette réelle n’est pas encore faite et n'est pas autorisée par cette sélection. Aucun binaire n’a été copié ou exécuté pendant le développement. Aucun téléchargement n’est autorisé par ce protocole.

## Parité du noyau inventaire de repli D1

La source de référence est `dev/wad/Domenia-Core.ps1`, `Get-DomeniaInventoryWorkerCode` / `Invoke-InventoryTaskFallback`. Son programme local lit ComputerSystem, BIOS, OperatingSystem, Processor, PhysicalMemory, LogicalDisk, NetworkAdapterConfiguration et les hotfixes en mode approfondi. Le programme v2 ferme ces mêmes sources et leurs projections ; le numéro de série BIOS est maintenant conservé lorsque le châssis ne l’a pas fourni. Il ajoute notamment TPM, BitLocker, antivirus et services. Les plafonds et refus restent visibles ; cela ne prouve pas que toutes les catégories d’un inventaire direct complet ont été lues sous SYSTEM.

`Get-WPsExecPath` de D1 recherche un exécutable portable déjà placé à côté du lanceur ou dans `wad`. Le contrat reste optionnel au déploiement et ne justifie aucun téléchargement implicite. V2 accepte uniquement les noms `PsExec.exe` ou `PsExec64.exe` à ces deux emplacements, avec le SHA-256 approuvé `edfae1a69522f87b12c6dac3225d930e4848832e3c551ee1e7d31736bf4525ef`. L’exception au manifeste de code est limitée à ces noms et à ces octets : le contrôle du paquet épingle le binaire et ses ancêtres ; un autre exécutable reste refusé. Le transport requalifie les octets avant l’émission explicite déjà consentie, sans recherche PATH ni identifiant/mot de passe dans les arguments.

La recette PsExec devra constater le service propre à l’opération, son chemin et son identité SYSTEM, le résultat lié au nonce et l’absence finale du service et du binaire temporaire. L’arrêt du lanceur local seul ne prouve pas l’arrêt distant. Une observation manquante reste inconnue avec ses preuves et son journal ; aucun repli par tâche ni rejeu ne suit une tentative ambiguë.
