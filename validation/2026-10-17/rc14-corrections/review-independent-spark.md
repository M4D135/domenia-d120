

Revue indépendante en lecture seule. Je ne prends pas les commentaires du diff comme preuves ; je traite uniquement le code ajouté/modifié comme données à auditer.

---

## Constats

### 1. Bloquant — `Source` est posé même quand aucun compte console n’est réellement observé
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.Model.ps1`, hunk `@@ -421,9 +443,13`, lignes ajoutées autour de :
```powershell
$answer.User=([string]$system.UserName).Trim()
$answer.Source='CIM/DCOM · Win32_ComputerSystem.UserName'
$answer.Outcome=if($answer.User){'Observed'}else{'NoConsole'}
```
**Pourquoi :** si `UserName` est vide, `Outcome` devient `NoConsole`, mais `Source` est quand même renseigné. La contrainte projet dit : `Source` posée seulement quand le compte console est lu. Un `UserName` vide n’est pas un compte console observé.  
**Conséquence :** affichage possible d’une source pour une observation sans compte, donc certitude non justifiée.  
**Correction minimale :** ne poser `Source` que si `$answer.User` est non vide, ou séparer clairement “source de la lecture” et “source du compte”.

---

### 2. Majeur — un échec peut conserver `Source`/`Transport` anciens via la fusion `presenceOnly`
**Fichier / ligne diff :**  
- `dev/wad/modules/Domenia-Live.Model.ps1`, hunk `@@ -94,7 +94,7` :
```powershell
Source=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'Source'}else{Get-DomeniaLiveField $Result 'Source'});
Transport=$(if($presenceOnly){Get-DomeniaLiveField $Previous 'Transport'}else{Get-DomeniaLiveField $Result 'Transport'});
```
- `dev/wad/modules/Domenia-Live.UI.ps1`, hunk `@@ -730,7 +730,9` :
```powershell
$result=[pscustomobject]@{... Source='';Transport='';IdentityState=''; ...}
```
**Pourquoi :** `Fail-DomeniaLiveProbe` met bien `Source=''` et `Transport=''` dans le résultat d’échec. Mais `ConvertTo-DomeniaLiveObservation` écrase ces champs par ceux de `$Previous` si `$presenceOnly` est vrai. Si un échec est traité comme `PresenceOnly`, les anciennes valeurs peuvent survivre.  
**Conséquence :** risque de violation directe du point 10 : “échec = Source/Transport vides affichés inconnus”.  
**Correction minimale :** forcer `Source`/`Transport` vides quand le résultat est un échec, ou ne préserver les anciennes valeurs que sur une présence réussie.

---

### 3. Majeur — grille/index/métadonnées de ligne n’utilisent pas `CreatedUtc`, contrairement au résumé/contexte
**Fichier / ligne diff :**  
- `dev/wad/Domenia-Core.ps1`, hunk `@@ -17654,13 +17671,16` :
```powershell
$links = @(Get-LinksForComputer -Computer ([string]$Row.Name) -Guid $rowGuid)
...
Get-DomeniaLinkIdentityNote -Link $_ -Kind 'Computer' -Guid $rowGuid
```
- `dev/wad/Domenia-Core.ps1`, hunk `@@ -17720,9 +17740,11` :
```powershell
$links = @(Get-LinksForComputer -Computer $computerKey -Guid $rowGuid)
...
Get-DomeniaLinkIdentityNote -Link $links[0] -Kind 'Computer' -Guid $rowGuid
```
**Pourquoi :** le résumé et le contexte passent `$selectedCreated` / `whenCreated` lu depuis l’entrée déjà chargée. La grille et l’index ne passent pas `CreatedUtc`. Si la règle d’identité dépend de `whenCreated`, le même lien peut être annoté dans le résumé mais pas dans la grille.  
**Conséquence :** incohérence entre vues ; le point 9 dit que grille/index/résumé/contexte doivent annoter.  
**Correction minimale :** lire `Entry.whenCreated` depuis la ligne si disponible et le passer à `Get-LinksForComputer`/`Get-LinksForUser` et `Get-DomeniaLinkIdentityNote`, ou documenter explicitement que la grille ne peut pas vérifier l’identité.

---

### 4. Majeur — `$selectedGuid` / `$selectedCreated` ne sont pas visibles dans le hunk du contexte
**Fichier / ligne diff :** `dev/wad/Domenia-Core.ps1`, hunks `@@ -17940,7 +17963,8` et `@@ -17958,12 +17982,15`.  
**Pourquoi :** le code utilise :
```powershell
-Guid $selectedGuid -CreatedUtc $selectedCreated
```
mais le diff ne montre pas leur définition dans `Refresh-AssociationContext`. Comme les modules sont dot-sourcés sans `Set-StrictMode`, une variable absente devient silencieusement `$null`/vide.  
**Conséquence :** si ces variables ne sont pas définies plus haut, `Get-DomeniaLinkIdentityNote` retourne `''` et l’annotation est désactivée sans erreur.  
**Correction minimale :** vérifier/ajouter la définition locale dans la fonction, avec test dédié.

---

### 5. Majeur — le diff n’établit pas que `Get-LinksForComputer`/`Get-LinksForUser` renvoient bien les liens `Unknown`
**Fichier / ligne diff :** `dev/wad/Domenia-Core.ps1`, hunk `@@ -17505,13 +17517,18`.  
**Pourquoi :** le résumé fait :
```powershell
$links = @(Get-LinksForComputer -Computer $computer -Guid $selectedGuid -CreatedUtc $selectedCreated)
if ($links.Count -eq 0) { return "Aucun utilisateur lie" }
```
Puis il annote les liens retournés. Si `Get-LinksForComputer` filtre déjà les liens dont l’identité est `Unknown`, le résumé affichera “Aucun utilisateur lie”, ce qui viole la règle “jamais aucun lien” sur `Unknown`.  
**Conséquence :** le point 9 peut être non atteint si la récupération des liens exclut les cas `Unknown`.  
**Correction minimale :** test ciblé : lien existant + identité `Unknown` + résumé doit afficher “identité non vérifiable”, pas “Aucun utilisateur lie”.

---

### 6. Majeur — la préservation de `IdentityState='Incohérente'` et de `Presence` après `throw` n’est pas prouvée par le diff
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.Model.ps1`, hunk `@@ -292,23 +303,32` :
```powershell
function Set-LiveIdentityMismatch{
    $answer.IdentityState='Incohérente'
    if([string]$answer.Presence -like 'En ligne*'){...}
}
```
puis appels :
```powershell
if($hostMismatch){$system=$null;Set-LiveIdentityMismatch;throw $hostMismatch}
```
**Pourquoi :** `Set-LiveIdentityMismatch` modifie `$answer`, puis `throw` sort du bloc. Le `catch` externe n’est pas dans le diff. S’il reconstruit un résultat sans préserver `IdentityState` ou `Presence`, le point 127 échoue.  
**Conséquence :** risque que l’incohérence d’identité soit perdue ou que la présence brute ICMP soit effacée.  
**Correction minimale :** test worker réel : mismatch confirmé → résultat final doit garder `Presence='En ligne'`/détail brut et `IdentityState='Incohérente'`.

---

### 7. Majeur — le test P-CD-09 ajouté ne prouve pas l’annotation “identité non vérifiable”
**Fichier / ligne diff :** `dev/wad/tests/Test-Domenia.ps1`, hunk `@@ -1251,6 +1251,9` :
```powershell
# Point 9: ... the fixtures use no GUID, so the note stays empty and Test-DomeniaLinkIdentity is never reached.
```
**Pourquoi :** le test charge la fonction mais admet lui-même qu’il n’atteint pas `Test-DomeniaLinkIdentity`. Il ne prouve donc pas que l’annotation apparaît sur `Unknown`. De plus, l’extraction AST :
```powershell
@($nodes|Where-Object{$_.Name -eq 'Get-DomeniaLinkIdentityNote'})[0].Extent.Text
```
peut produire un scriptblock vide si la fonction est absente, sans échec explicite.  
**Conséquence :** faux sentiment de couverture sur le point 9.  
**Correction minimale :** ajouter un cas avec `Guid` non vide et `Test-DomeniaLinkIdentity` retournant `Match='Unknown'`, puis vérifier la présence de “identité non vérifiable”. Faire échouer le test si le nœud AST est absent.

---

### 8. Majeur — la table partagée rend le total `Bytes` de la catégorie inconnu, même si d’autres tables sont mesurées
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Storage.Worker.ps1`, hunk `@@ -1534,19 +1534,32` :
```powershell
$rows=[long](@(Invoke-DomeniaDbQuery ('SELECT count(*) AS n FROM '+$table+' '+$sharedTablePredicates[$category]+';') $db)[0].n)
$state='Mesure'
$bytes=-1L
```
et test :
```powershell
Expect (($obsMeta[0].Bytes -eq -1) -and ($idxMeta[0].Bytes -eq -1) -and ($obs.Bytes -eq -1) -and ($idx.Bytes -eq -1)) ...
```
**Pourquoi :** dès que `domenia_domain_metadata` existe, les octets de la table sont mis à `-1`, et le test confirme que le total de catégorie devient `-1`. Si la catégorie contient d’autres tables réellement mesurées, leurs octets sont masqués.  
**Conséquence :** régression d’information : une catégorie peut passer “inconnue” alors que seule une table partagée est inconnue.  
**Correction minimale :** soit documenter explicitement que la catégorie devient inconnue, soit calculer un total partiel mesuré + indicateur “octets incomplets”.

---

### 9. Mineur — la note peut être affichée sans nom d’objet si `UserLogin` ou `Computer` est vide
**Fichier / ligne diff :**  
- `dev/wad/Domenia-Core.ps1`, hunk `@@ -17654,13 +17671,16` :
```powershell
@($links | ForEach-Object { [string]$_.UserLogin + (Get-DomeniaLinkIdentityNote ...) } | Where-Object { $_ } | Sort-Object -Unique)
```
- `dev/wad/Domenia-Core.ps1`, hunk `@@ -17720,9 +17740,11` :
```powershell
@($links | ForEach-Object { [string]$_.Computer + (Get-DomeniaLinkIdentityNote ...) } | Where-Object { $_ } | Sort-Object -Unique)
```
**Pourquoi :** si le nom est vide et que la note est renvoyée, la chaîne résultante est non vide, donc `Where-Object { $_ }` la conserve.  
**Conséquence :** affichage possible d’un simple “ · identité non vérifiable” sans utilisateur/poste.  
**Correction minimale :** filtrer sur le nom avant concaténation, ou n’ajouter la note que si le nom de base est non vide.

---

### 10. Mineur — `Sort-Object -Unique` après ajout de la note peut dupliquer le même objet
**Fichier / ligne diff :** mêmes hunks Core `@@ +17671` et `@@ +17740`.  
**Pourquoi :** l’unicité est calculée sur la chaîne complète. Le même poste peut apparaître une fois sans note et une fois avec note.  
**Conséquence :** liste incohérente ou doublons visuels.  
**Correction minimale :** grouper par nom d’objet, puis décider si une note s’applique.

---

### 11. Mineur — `Get-AssociationForRow` ne regarde que le premier lien
**Fichier / ligne diff :** `dev/wad/Domenia-Core.ps1`, hunk `@@ -17481,19 +17481,31` :
```powershell
$link = @(Get-LinksForComputer ... | Select-Object -First 1)
```
**Pourquoi :** si le premier lien est vérifié et un autre lien est `Unknown`, l’annotation est masquée.  
**Conséquence :** si l’objectif est d’annoncer toute association non vérifiable, le comportement est incomplet.  
**Correction minimale :** évaluer tous les liens ou choisir explicitement le meilleur lien avec règle documentée.

---

### 12. Mineur — les familles non listées de `domenia_domain_metadata` ne sont comptées dans aucune catégorie
**Fichier / ligne diff :**  
- `dev/wad/modules/Domenia-Storage.Worker.ps1`, hunk `@@ -1534,19 +1534,32` :
```powershell
$sharedTablePredicates=@{
    Observations="WHERE family IN ('Presence','Inventory')"
    Index="WHERE family='Directory'"
}
```
- `dev/wad/tests/Test-DomeniaStorageMaintenance.ps1`, hunk `@@ -319,6 +319,28` :
```powershell
Expect ($sharedRows -eq 4) ('the five stored rows are counted once each, the unlisted family in none: '+$sharedRows)
```
**Pourquoi :** une ligne `AdSchema` insérée dans le test n’est comptée nulle part. Le test valide ce comportement.  
**Conséquence :** si une nouvelle famille apparaît, ses lignes disparaissent silencieusement de l’usage.  
**Correction minimale :** ajouter une catégorie “Autres” explicite ou une assertion de couverture des familles connues.

---

### 13. Mineur — les prédicats de famille sont sensibles à la casse et aux valeurs NULL
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Storage.Worker.ps1`, hunk `@@ -1534,19 +1534,32`.  
**Pourquoi :** `WHERE family IN ('Presence','Inventory')` ne compte pas `presence`, `PRESENCE`, ou NULL.  
**Conséquence :** sous-comptage silencieux si la donnée n’est pas exactement normalisée.  
**Correction minimale :** normaliser la famille à l’écriture, ou utiliser une comparaison explicite avec collation/normalisation.

---

### 14. Mineur — les suspensions actives ne sont triées que par `RuleId`
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Boards.Model.ps1`, hunk `@@ -1527,7 +1527,9` :
```powershell
ActiveSuspensions=@($p.Suspensions|Where-Object{...}|ForEach-Object{[pscustomobject]@{RuleId=...;Reason=...;UntilUtc=...}}|Sort-Object RuleId)
```
**Pourquoi :** la revendication dit “RuleId/Reason/UntilUtc triés”. Le code trie seulement `RuleId`. Si plusieurs suspensions actives partagent le même `RuleId` ou si l’ordre d’entrée varie, le JSON peut changer sans changement sémantique.  
**Conséquence :** empreinte potentiellement instable.  
**Correction minimale :** `Sort-Object RuleId,Reason,UntilUtc`.

---

### 15. Mineur — `FormatVersion` manquant est traité comme `-1`, donc deux relevés sans `FormatVersion` sont comparés comme même format
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Boards.Model.ps1`, hunk `@@ -1600,7 +1602,11` :
```powershell
$format={param($Figures)$v=0;$raw=[string](Get-DomeniaHealthValue $Figures 'FormatVersion' '');if([int]::TryParse($raw,[ref]$v)){$v}else{-1}}
```
**Pourquoi :** si deux anciens relevés n’ont pas `FormatVersion`, ils sont considérés comme même format et `PolicyHash` est comparé. Si le format réel des tokens n’est pas garanti, cela peut produire une comparaison fausse.  
**Conséquence :** risque limité si `FormatVersion=2` est toujours présent pour l’ancien format, mais le test ne le prouve pas.  
**Correction minimale :** test : deux snapshots sans `FormatVersion` mais tokens différents → comportement attendu explicite.

---

### 16. Mineur — `Transport` est posé même si la lecture CIM retourne `$null`
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.Model.ps1`, hunk `@@ -380,6 +400,8` :
```powershell
$instance=@(Get-CimInstance @query)[0]
...
$answer.Transport='CIM/DCOM'
if($null -ne $instance){...}
```
**Pourquoi :** si la requête s’exécute mais ne retourne aucune instance, `Transport` est quand même posé. Le commentaire dit “lecture réellement revenue”, mais aucune donnée n’est revenue.  
**Conséquence :** affichage possible d’un transport pour une lecture sans résultat.  
**Correction minimale :** poser `Transport` seulement si `$null -ne $instance`, ou renommer le champ en “transport tenté/executé”.

---

### 17. Mineur — `Fail-DomeniaLiveProbe` qualifie tout échec d’erreur de ping
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.UI.ps1`, hunk `@@ -730,7 +730,9` :
```powershell
$result=[pscustomobject]@{... Presence='Erreur de ping';PresenceDetail=$Message; ...}
```
**Pourquoi :** la fonction semble être un échec de probe général, mais force `Presence='Erreur de ping'`. Si l’échec vient d’un timeout CIM, le fait ICMP peut être mal qualifié.  
**Conséquence :** possible confusion entre panne réseau/ping et échec CIM.  
**Correction minimale :** ne mettre “Erreur de ping” que si l’échec concerne réellement le ping.

---

### 18. Observation — la portée de `$answer` dans la here-string du worker est dynamique, pas lexicale
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.Model.ps1`, hunks `@@ -292,23 +303,32` et `@@ -380,6 +400,8`.  
**Pourquoi :** `Set-LiveIdentityMismatch` et `Invoke-WSharedRead` modifient `$answer` depuis une fonction. En PowerShell 5.1, la résolution des variables est dynamique : si `$answer` est visible dans le scope appelant, la mutation de propriété fonctionne. Ce n’est pas de la portée lexicale.  
**Conséquence :** le code actuel est plausible, mais fragile si un appel est déplacé dans un autre scope/runspace.  
**Recommandation :** ajouter un test worker réel qui échoue si `$answer` n’est pas visible.

---

### 19. Observation — sondes seules : si `Win32_ComputerSystem` retourne `$null`, les sondes continuent sans identité vérifiée
**Fichier / ligne diff :** `dev/wad/modules/Domenia-Live.Model.ps1`, hunk `@@ -457,6 +485,19` :
```powershell
$identitySystem=Invoke-WSharedRead $csKey 'Win32_ComputerSystem' '' @('Name','DNSHostName')
$identityCheck=Get-LiveHostIdentityCheck $target $identitySystem
...
if($identityCheck.Comparable){$answer.IdentityState='Vérifiée'}
```
**Pourquoi :** si `$identitySystem` est `$null`, `Get-LiveHostIdentityCheck` retourne `Comparable=$false`, donc pas de `throw`. Les sondes peuvent continuer.  
**Conséquence :** conforme à “comparaison impossible = comportement antérieur”, mais pas forcément conforme à “aucune certitude affichée sans donnée réellement lue” si les sondes sont ensuite présentées comme attribuées au poste.  
**Recommandation :** clarifier l’affichage : identité inconnue, pas vérifiée.

---

### 20. Observation — le test Point 78 dépend de la source de `$NowUtc` dans `Board`
**Fichier / ligne diff :** `dev/wad/tests/Test-DomeniaHealthAdvanced.ps1`, hunk `@@ -96,7 +96,26`.  
**Pourquoi :** le test utilise `$now.AddHours(-1)` et `$now.AddHours(1)`, mais le diff ne montre pas que `Board` utilise ce `$now` fixe. Si `Board` utilise `Get-Date`, les suspensions peuvent ne pas être actives/expirées comme attendu.  
**Conséquence :** test potentiellement faux ou non déterministe.  
**Recommandation :** passer explicitement `NowUtc` à `Board` ou vérifier que `Board` consomme bien `$now`.

---

### 21. Observation — le test Point 78 ne prouve pas le tri complet ni les modifications de `UntilUtc`
**Fichier / ligne diff :** `dev/wad/tests/Test-DomeniaHealthAdvanced.ps1`, hunk `@@ -96,7 +96,26`.  
**Pourquoi :** le test valide une suspension active avec changement de `Reason`, mais ne teste pas :
- plusieurs suspensions actives ;
- même `RuleId` avec champs différents ;
- changement de `UntilUtc` seul ;
- ordre d’entrée différent.  
**Conséquence :** la revendication “RuleId/Reason/UntilUtc triés” n’est pas totalement couverte.  
**Recommandation :** ajouter ces cas.

---

### 22. Observation — le test Storage valide le cas partagé mais pas le total des autres tables
**Fichier / ligne diff :** `dev/wad/tests/Test-DomeniaStorageMaintenance.ps1`, hunk `@@ -319,6 +319,28`.  
**Pourquoi :** le test vérifie `domenia_domain_metadata` et le total catégorie `-1`, mais ne montre pas le comportement quand la catégorie contient d’autres tables mesurées avec `dbstat`.  
**Conséquence :** on ne prouve pas que les octets des autres tables sont correctement conservés ou correctement masqués.  
**Recommandation :** ajouter un cas avec une autre table mesurée et vérifier le total attendu.

---

### 23. Observation — le test Wiring ajoute la fonction sans prouver son comportement
**Fichier / ligne diff :** `dev/wad/tests/Test-DomeniaWiringRelations.ps1`, hunk `@@ -206,7 +206,7`.  
**Pourquoi :** `Get-DomeniaLinkIdentityNote` est ajoutée à la liste des définitions extraites, mais aucun test comportemental n’est ajouté ici.  
**Conséquence :** la présence de la fonction est vérifiée, pas sa règle.  
**Recommandation :** coupler avec un test d’annotation `Unknown`.

---

### 24. Observation — aucune incompatibilité PS 5.1 évidente dans le diff
**Fichier / ligne diff :** global.  
**Pourquoi :** pas de ternaire PS7, pas d’API moderne visible, `[ordered]`, `[pscustomobject]`, `[int]::TryParse`, `ConvertTo-Json -Compress`, syntaxe `Where-Object Property -eq Value` sont compatibles PS 5.1.  
**Conséquence :** sur le plan syntaxe/API, rien de bloquant n’est visible dans le diff.

---

## Verdict

**Corrections requises avant ré-épinglage des contrats worker.**

Le diff contient des améliorations réelles, mais plusieurs points touchent directement les contrats affichés et les faits bruts :

- `Source` peut être posé sans compte console observé ;
- un échec peut potentiellement conserver `Source`/`Transport` anciens via `presenceOnly` ;
- la grille/index ne transmettent pas `CreatedUtc` ;
- la préservation de `IdentityState='Incohérente'` après `throw` n’est pas prouvée ;
- les tests ajoutés ne qualifient pas encore les comportements critiques du point 9 et du point 127.

Les bancs hors-VM sous `pwsh7` Linux ne suffisent pas. Avant ré-épinglage SHA-256 du worker, il faut rejouer sous **PowerShell 5.1 x64 STA** avec tests ciblés sur :

1. `UserName` vide → `Source` vide ou sémantique explicite ;
2. échec `PresenceOnly` → `Source`/`Transport` affichés inconnus ;
3. lien `Unknown` → annotation “identité non vérifiable”, jamais “aucun lien” ;
4. mismatch confirmé → `Presence` brute conservée + `IdentityState='Incohérente'` conservée après `throw` ;
5. grille/index avec `whenCreated` disponible → annotation cohérente avec résumé/contexte.
