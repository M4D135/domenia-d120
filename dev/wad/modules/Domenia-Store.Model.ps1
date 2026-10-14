# Pure validation and immutable wire format for the committed local store.
function Get-DomeniaStoreValue {
    param($Value,[string]$Name,$Default=$null)
    if($null -eq $Value){return $Default}
    if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return ,$Value[$Name]};return $Default}
    $p=$Value.PSObject.Properties[$Name];if($null -eq $p){return $Default};return ,$p.Value
}
function Get-DomeniaStoreHash {
    param([string]$Text)
    $h=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant()}finally{$h.Dispose()}
}
function Get-DomeniaStoreId {
    param([string]$Path,[string]$DomainDn)
    if([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($DomainDn)){throw 'Contexte de base incomplet.'}
    return Get-DomeniaStoreHash (([IO.Path]::GetFullPath($Path)).ToLowerInvariant()+"`n"+$DomainDn.Trim().ToLowerInvariant())
}
function ConvertTo-DomeniaStoreUtc {
    param($Value,[switch]$Optional)
    if($Optional -and [string]::IsNullOrWhiteSpace([string]$Value)){return ''}
    $date=[datetimeoffset]::MinValue
    if($Value -is [datetime]){$Value=$Value.ToUniversalTime().ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    elseif($Value -is [datetimeoffset]){$Value=$Value.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)}
    if(-not [datetimeoffset]::TryParse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$date)){throw 'Date de collecte invalide.'}
    if($date.UtcDateTime -gt [datetime]::UtcNow.AddMinutes(2)){throw 'Date de collecte dans le futur.'}
    return $date.UtcDateTime.ToString('o',[Globalization.CultureInfo]::InvariantCulture)
}
function Assert-DomeniaStoreSafeData {
    param($Value,[int]$Depth=0)
    if($Depth -gt 16){throw 'Donnees de collecte trop imbriquees.'}
    if($null -eq $Value){return}
    if($Value -is [Security.SecureString] -or $Value -is [Management.Automation.PSCredential]){throw 'Secret interdit dans le stockage de collecte.'}
    if($Value -is [string] -or $Value -is [ValueType]){return}
    if($Value -is [Collections.IDictionary]){$keys=@($Value.Keys)}
    elseif($Value -is [Collections.IEnumerable]){foreach($item in $Value){Assert-DomeniaStoreSafeData $item ($Depth+1)};return}
    else{$keys=@($Value.PSObject.Properties.Name)}
    foreach($name in $keys){
        if([string]$name -match '^(?i:password|passwd|credential|credentials|securestring|accesstoken|refreshtoken|authorization|ms-mcs-admpwd|mslaps-password|mslaps-encryptedpassword|mslaps-encryptedpasswordhistory|msfve-keypackage|unicodepwd|userpassword|supplementalcredentials|dbcspwd|ntpwdhistory|msfve-recoverypassword|recoverypassword|recoverykey|privatekey)$'){throw ('Champ secret interdit : '+$name)}
        Assert-DomeniaStoreSafeData (Get-DomeniaStoreValue $Value ([string]$name)) ($Depth+1)
    }
}
function ConvertTo-DomeniaStoreBatch {
    param($Context,[string]$BatchId,[long]$Sequence,[object[]]$Changes)
    $id=[guid]::Empty
    if(-not [guid]::TryParse($BatchId,[ref]$id) -or $id -eq [guid]::Empty){throw 'Identifiant de lot invalide.'}
    if($Sequence -lt 0 -or @($Changes).Count -lt 1 -or @($Changes).Count -gt 250){throw 'Un lot contient de 1 a 250 changements.'}
    $path=[IO.Path]::GetFullPath([string](Get-DomeniaStoreValue $Context 'Path'))
    $domain=([string](Get-DomeniaStoreValue $Context 'DomainDn')).Trim().ToLowerInvariant()
    if($domain -notmatch '(?i)(^|,)DC=' -or $path.StartsWith('\\')){throw 'Contexte de domaine local invalide.'}
    $storeId=Get-DomeniaStoreId $path $domain
    if([string](Get-DomeniaStoreValue $Context 'StoreId') -cne $storeId){throw 'Identite du stockage incoherente.'}
    $contextCopy=[ordered]@{Version=1;StoreId=$storeId;Path=$path;DomainDn=$domain;SessionEpoch=[long](Get-DomeniaStoreValue $Context 'SessionEpoch');RequestId=[string](Get-DomeniaStoreValue $Context 'RequestId');Generation=[long](Get-DomeniaStoreValue $Context 'Generation');ScopeDn=[string](Get-DomeniaStoreValue $Context 'ScopeDn');Subtree=[bool](Get-DomeniaStoreValue $Context 'Subtree')}
    if(-not $contextCopy.RequestId -or $contextCopy.RequestId.Length -gt 128){throw 'Identifiant de requete invalide.'}
    $list=[Collections.Generic.List[object]]::new()
    foreach($change in $Changes){
        $kind=[string](Get-DomeniaStoreValue $change 'Kind');$guid=[guid]::Empty
        if($kind -notin @('DirectoryObject','Observation','DetailResult','AccountPreference','QueryRecipe','QueryDependency','QueryMigration')){throw 'Type de changement interdit.'}
        if($kind -in @('QueryRecipe','QueryDependency','QueryMigration')){$list.Add((ConvertTo-DomeniaStoreQueryChange -Change $change -Context $contextCopy));continue}
        if($kind -eq 'AccountPreference'){
            $scope=[string](Get-DomeniaStoreValue $change 'Scope');$user=([string](Get-DomeniaStoreValue $change 'UserName')).Trim()
            if($scope -notin @('Directory','Remote','Laps','BitLocker') -and $scope -notmatch '^AD:[A-Za-z][A-Za-z0-9_.-]{0,63}$' -and $scope -cnotmatch '^RemoteLocal:[a-z0-9][a-z0-9._-]{0,252}$'){throw 'Usage du compte invalide.'}
            if($user.Length -gt 256 -or $user -match '[\x00-\x1f]'){throw 'Identifiant de compte invalide.'}
            if([string](Get-DomeniaStoreValue $change 'DomainDn') -ine $domain){throw 'Domaine de preference invalide.'}
            $list.Add([pscustomobject]@{Kind='AccountPreference';Scope=$scope;UserName=$user;DomainDn=$domain;UpdatedAtUtc=(ConvertTo-DomeniaStoreUtc (Get-DomeniaStoreValue $change 'UpdatedAtUtc'))})
            continue
        }
        if(-not [guid]::TryParse([string](Get-DomeniaStoreValue $change 'Guid'),[ref]$guid) -or $guid -eq [guid]::Empty){throw 'GUID de collecte invalide.'}
        $dn=([string](Get-DomeniaStoreValue $change 'DN')).Trim()
        if(-not $dn -or $dn.Length -gt 8192 -or ($dn -ine $domain -and -not $dn.EndsWith(','+$domain,[StringComparison]::OrdinalIgnoreCase))){throw 'DN de collecte invalide.'}
        $data=Get-DomeniaStoreValue $change 'Data';Assert-DomeniaStoreSafeData $data
        $item=[ordered]@{Kind=$kind;Guid=$guid.ToString('D');DN=$dn;Data=$data}
        if($kind -eq 'DirectoryObject'){
            $item.ObservedAtUtc=ConvertTo-DomeniaStoreUtc (Get-DomeniaStoreValue $change 'ObservedAtUtc')
            $item.Source=[string](Get-DomeniaStoreValue $change 'Source');$fields=Get-DomeniaStoreValue $change 'Fields';$item.Fields=@($fields)
            if(-not $item.Fields.Count){throw 'Masque de lecture AD absent.'}
            foreach($field in $item.Fields){if([string]$field -notin @('Type','Name','Login','Upn','Display','Description','Extra','State','WhenChanged','Usn','LastLogon','Details')){throw ('Champ AD non projete : '+$field)};if(($data -is [Collections.IDictionary] -and -not $data.Contains([string]$field)) -or ($data -isnot [Collections.IDictionary] -and $null -eq $data.PSObject.Properties[[string]$field])){throw ('Champ masque absent : '+$field)}}
            $item.Facts=Get-DomeniaStoreValue $change 'Facts';Assert-DomeniaStoreSafeData $item.Facts
        }else{
            $item.Status=[string](Get-DomeniaStoreValue $change 'Status');if($item.Status -notin @('Success','Error')){throw 'Etat de collecte invalide.'}
            $item.AttemptedAtUtc=ConvertTo-DomeniaStoreUtc (Get-DomeniaStoreValue $change 'AttemptedAtUtc')
            $item.ObservedAtUtc=ConvertTo-DomeniaStoreUtc (Get-DomeniaStoreValue $change 'ObservedAtUtc') -Optional:($item.Status -eq 'Error')
            $item.Error=[string](Get-DomeniaStoreValue $change 'Error');if($item.Error.Length -gt 4096){$item.Error=$item.Error.Substring(0,4096)}
            if($item.Status -eq 'Success' -and [string]::CompareOrdinal($item.ObservedAtUtc,$item.AttemptedAtUtc) -gt 0){throw 'Succes posterieur a la tentative.'}
            if($kind -eq 'Observation'){
                $item.Family=[string](Get-DomeniaStoreValue $change 'Family');if($item.Family -notmatch '^(Presence|Console|Inventory|Probe:[A-Za-z0-9_.-]{1,128})$'){throw 'Famille de mesure invalide.'}
                $item.DefinitionHash=[string](Get-DomeniaStoreValue $change 'DefinitionHash')
            }else{
                $item.ResultKind=[string](Get-DomeniaStoreValue $change 'ResultKind');$item.RequestKey=[string](Get-DomeniaStoreValue $change 'RequestKey')
                if($item.ResultKind -notmatch '^[A-Za-z0-9_.:-]{1,128}$' -or $item.RequestKey.Length -gt 256){throw 'Identite de resultat detaille invalide.'}
            }
        }
        # The final wire string is the immutable snapshot. A JSON roundtrip for every
        # item before serializing that snapshot duplicated both traversal and allocation.
        # The enclosing 4 MiB limit also bounds every individual item.
        $list.Add([pscustomobject]$item)
    }
    $envelope=[ordered]@{Version=1;Context=[pscustomobject]$contextCopy;BatchId=$id.ToString('D');Sequence=$Sequence;Changes=$list.ToArray()}
    $json=$envelope|ConvertTo-Json -Depth 24 -Compress;$bytes=[Text.Encoding]::UTF8.GetByteCount($json)
    if($bytes -gt 4194304){throw 'Un lot depasse 4 Mio ; reduisez sa taille.'}
    return [pscustomobject]@{Json=$json;Hash=(Get-DomeniaStoreHash $json);Bytes=$bytes;Count=$list.Count;BatchId=$id.ToString('D');Context=[pscustomobject]$contextCopy}
}

function ConvertTo-DomeniaStoreQueryChange {
    param($Change,$Context)
    $kind=[string](Get-DomeniaStoreValue $Change 'Kind')
    if($kind -eq 'QueryRecipe'){
        $record=Get-DomeniaStoreValue $Change 'Record';Assert-DomeniaStoreSafeData $record
        if([string](Get-DomeniaStoreValue $record 'Format') -cne 'Domenia.QueryLibraryRecord/1' -or [string](Get-DomeniaStoreValue $record 'StoreId') -cne [string]$Context.StoreId -or [string](Get-DomeniaStoreValue $record 'DomainDn') -ine [string]$Context.DomainDn){throw 'Contexte de recette incompatible.'}
        $json=[string](Get-DomeniaStoreValue $record 'DefinitionJson')
        if([Text.Encoding]::UTF8.GetByteCount($json) -gt 1048576 -or (Get-DomeniaStoreHash $json) -cne [string](Get-DomeniaStoreValue $record 'DefinitionSHA256')){throw 'Definition ou empreinte de recette invalide.'}
        $recipe=ConvertFrom-Json -InputObject $json -ErrorAction Stop;Assert-DomeniaStoreSafeData $recipe
        # Revalidate with the real compiler and closed recipe DTO on admission.
        $expected=[long](Get-DomeniaStoreValue $record 'ExpectedRevision' -1)
        $date=ConvertTo-DomeniaStoreUtc (Get-DomeniaStoreValue $record 'UpdatedUtc')
        $validated=New-DomeniaQueryLibraryRecord -Context $Context -Recipe $recipe -ExpectedRevision $expected -Category ([string](Get-DomeniaStoreValue $record 'Category')) -NowUtc ([datetime]$date)
        foreach($name in @('Id','Name','NameFold')){if([string](Get-DomeniaStoreValue $record $name) -cne [string]$validated.$name){throw ('Metadonnee de recette incoherente : '+$name)}}
        if([long](Get-DomeniaStoreValue $record 'Revision') -ne $expected+1 -or [int](Get-DomeniaStoreValue $record 'DefinitionVersion') -ne [int]$validated.DefinitionVersion){throw 'Revision de recette invalide.'}
        if((Get-DomeniaStoreValue $record 'Archived') -isnot [bool]){throw 'Etat archive de recette invalide.'}
        $validated.DefinitionJson=$json;$validated.DefinitionSHA256=Get-DomeniaStoreHash $json;$validated.Archived=[bool](Get-DomeniaStoreValue $record 'Archived')
        return [pscustomobject]@{Kind=$kind;Record=$validated}
    }
    if($kind -eq 'QueryDependency'){
        $id=[string](Get-DomeniaStoreValue $Change 'RecipeId');$consumer=[string](Get-DomeniaStoreValue $Change 'ConsumerKind');$key=[string](Get-DomeniaStoreValue $Change 'ConsumerId');$revision=[long](Get-DomeniaStoreValue $Change 'BoundRevision')
        if($id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $consumer -cnotin @('Fleet','Computer') -or -not $key -or $key.Length -gt 128 -or $key -match '[\p{Cc}]' -or $revision -le 0 -or (Get-DomeniaStoreValue $Change 'Remove') -isnot [bool]){throw 'Dependance de recette invalide.'}
        return [pscustomobject]@{Kind=$kind;RecipeId=$id;ConsumerKind=$consumer;ConsumerId=$key;BoundRevision=$revision;Remove=[bool](Get-DomeniaStoreValue $Change 'Remove')}
    }
    if($kind -eq 'QueryMigration'){
        $hash=[string](Get-DomeniaStoreValue $Change 'SourceHash');$ids=@(Get-DomeniaStoreValue $Change 'RecipeIds' @());$seen=@{}
        if($hash -cnotmatch '^[a-f0-9]{64}$' -or $ids.Count -gt 5000){throw 'Migration de recettes invalide.'}
        foreach($id in $ids){if([string]$id -cnotmatch '^[a-zA-Z0-9_.-]{1,80}$' -or $seen.ContainsKey([string]$id)){throw 'Identite de migration de recettes invalide.'};$seen[[string]$id]=$true}
        return [pscustomobject]@{Kind=$kind;SourceHash=$hash;RecipeIds=$ids}
    }
    throw 'Changement de bibliotheque inconnu.'
}

function ConvertTo-DomeniaStoragePolicy {
    param($Value=$null)
    # Point 37: LinkHistoryDays was added after version 1 shipped. A stored policy without it keeps the default, so
    # the version stays 1 (an additive key with a safe default is not a new format).
    $policy=[ordered]@{Version=1;AutomaticBackup=$false;BackupHours=24;BackupKeep=7;PresenceDays=30;ConsoleDays=90;InventoryDays=180;ProbeDays=90;DetailDays=30;LinkHistoryDays=365}
    if($null -ne $Value){
        foreach($key in @($policy.Keys)){$v=Get-DomeniaStoreValue $Value $key $null;if($null -ne $v){
            if($key -eq 'AutomaticBackup'){if($v -isnot [bool]){throw 'Activation de sauvegarde invalide.'};$policy[$key]=[bool]$v}
            else{$number=0;if(-not [int]::TryParse([string]$v,[ref]$number)){throw ('Reglage de stockage invalide : '+$key)};$policy[$key]=$number}
        }}
    }
    if($policy.Version -ne 1 -or $policy.BackupHours -lt 1 -or $policy.BackupHours -gt 720 -or $policy.BackupKeep -lt 2 -or $policy.BackupKeep -gt 30){throw 'Sauvegarde : frequence 1 a 720 heures, retention 2 a 30 copies.'}
    foreach($key in @(Get-DomeniaStorageRetentionFamilies|ForEach-Object{[string]$_.PolicyKey})){if($policy[$key] -lt 0 -or $policy[$key] -gt 36500){throw 'Conservation : 0 (sans limite) a 36500 jours.'}}
    return [pscustomobject]$policy
}
function Get-DomeniaStorageBackupDecision {
    param($Policy,[string]$LastSuccessUtc='',[string]$LastAttemptUtc='',$DirtyUtc=$null,[bool]$Busy=$false,[datetime]$NowUtc=[datetime]::UtcNow)
    $policy=ConvertTo-DomeniaStoragePolicy $Policy
    if(-not $policy.AutomaticBackup){return [pscustomobject]@{Due=$false;Reason='Disabled'}}
    if($Busy){return [pscustomobject]@{Due=$false;Reason='Busy'}}
    $last=[datetime]::MinValue;$attempt=[datetime]::MinValue
    foreach($value in @($LastSuccessUtc,$LastAttemptUtc)){if($value){$date=[datetime]::MinValue;if(-not [datetime]::TryParse($value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$date) -or $date.ToUniversalTime() -gt $NowUtc.ToUniversalTime().AddMinutes(2)){return [pscustomobject]@{Due=$false;Reason='InvalidClock'}}}}
    if($LastSuccessUtc){$last=([datetime]$LastSuccessUtc).ToUniversalTime()};if($LastAttemptUtc){$attempt=([datetime]$LastAttemptUtc).ToUniversalTime()}
    if($attempt -gt $NowUtc.ToUniversalTime().AddMinutes(-15)){return [pscustomobject]@{Due=$false;Reason='RetryCooldown'}}
    if($last -gt $NowUtc.ToUniversalTime().AddHours(-$policy.BackupHours)){return [pscustomobject]@{Due=$false;Reason='Recent'}}
    if($null -ne $DirtyUtc -and $last -ne [datetime]::MinValue -and ([datetime]$DirtyUtc).ToUniversalTime() -le $last){return [pscustomobject]@{Due=$false;Reason='Unchanged'}}
    return [pscustomobject]@{Due=$true;Reason='Scheduled'}
}

# ---------------------------------------------------------------- Points 31-40: local store assistant, health and limits
# Pure decisions and wording for the Stockage tab. Workers measure; these functions never read a disk, a setting or the
# clock (every time-dependent rule takes NowUtc). An unknown measure stays unknown and is written as such.
function ConvertFrom-DomeniaStorageUtc {
    # Strict reading of a stored or measured date. $null when absent or unreadable, never a guessed date.
    param([AllowEmptyString()][AllowNull()][string]$Value)
    if([string]::IsNullOrWhiteSpace($Value)){return $null}
    $date=[datetime]::MinValue
    if(-not [datetime]::TryParse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$date)){return $null}
    return $date.ToUniversalTime()
}
function Format-DomeniaStorageDate {
    # Local display of a UTC date; '' when unknown, so that the caller says « inconnue » in its own sentence.
    param([AllowEmptyString()][AllowNull()][string]$Value,[switch]$Seconds)
    $date=ConvertFrom-DomeniaStorageUtc $Value
    if($null -eq $date){return ''}
    $format='dd/MM/yyyy HH:mm';if($Seconds){$format='dd/MM/yyyy HH:mm:ss'}
    return $date.ToLocalTime().ToString($format,[Globalization.CultureInfo]::InvariantCulture)
}
function Get-DomeniaStorageCopyReserve {
    # Points 31 and 32. Free space a verified copy needs on its destination volume: twice the source (file and WAL)
    # plus 32 MiB. The maintenance and retention workers apply the same rule again just before they write.
    param([long]$SourceBytes)
    if($SourceBytes -lt 0){throw 'Taille de la base inconnue : réserve de copie non calculable.'}
    return [long](2L*$SourceBytes+33554432L)
}
function Test-DomeniaStorageUnreadableMessage {
    # Point 36. True only for proven SQLite corruption (SQLITE_CORRUPT 11, SQLITE_NOTADB 26, failed quick_check). A
    # lock, a schema or a domain mismatch is never an unreadable base. Same pattern as Test-MaintWUnreadable (worker).
    param([AllowEmptyString()][AllowNull()][string]$Message)
    return ([string]$Message -match '(?i)Integrite SQLite non confirmee|quick_check|malformed|not a database|disk image|SQLite (?:prepare |step )?code (?:11|26)\b|impossible : SQLite (?:11|26)\b')
}
function Get-DomeniaStorageSchemaExpectation {
    # Point 36. Tables and columns every opened base exposes after the forward-only schema step of this version. The
    # StorageIntegrity worker carries the same constant lists (rule Storage.Tests compares both).
    return [pscustomobject]@{
        Version='11';Revision='1'
        Tables=@('schema_info','ad_objects','user_machine_links','user_machine_history','park_state','presence_cache','sync_state','user_scan_history','secret_state','operation_runs','domenia_provenance','ad_computer_facts','fleet_snapshots','domenia_store_state','domenia_store_batches','domenia_directory_data','domenia_observations','domenia_legacy_observation_imports','domenia_account_preferences','domenia_details','domenia_domain_metadata','domenia_query_recipes','domenia_query_recipe_revisions','domenia_query_migrations','domenia_query_recipe_dependencies')
        Columns=[ordered]@{
            domenia_observations=@('object_guid','family','dn','attempt_at','status','success_at','payload','attempt_payload','summary_payload','attempt_summary','revision')
            domenia_details=@('object_guid','result_kind','request_key','dn','attempt_at','status','success_at','payload','attempt_payload','summary_payload','attempt_summary','revision')
            domenia_store_state=@('id','store_id','domain_dn','revision')
            domenia_store_batches=@('batch_id','payload_hash','request_id','sequence','revision','committed_at','changes_json')
        }
    }
}
function Get-DomeniaStorageSchemaGaps {
    # Point 36. Missing tables and columns against the expectation. Input: table names and a map table -> column names.
    param([string[]]$Tables=@(),$Columns=$null)
    $expected=Get-DomeniaStorageSchemaExpectation;$present=@{};foreach($name in @($Tables)){$present[([string]$name).ToLowerInvariant()]=$true}
    $gaps=New-Object 'System.Collections.Generic.List[string]'
    foreach($table in $expected.Tables){if(-not $present.ContainsKey($table)){$gaps.Add('table '+$table)}}
    foreach($table in @($expected.Columns.Keys)){
        if(-not $present.ContainsKey($table)){continue}
        $have=@{};foreach($column in @(Get-DomeniaMember $Columns $table @())){$have[([string]$column).ToLowerInvariant()]=$true}
        foreach($column in @($expected.Columns[$table])){if(-not $have.ContainsKey($column)){$gaps.Add('colonne '+$table+'.'+$column)}}
    }
    # Unrolled on purpose: callers wrap the call in @() to count the gaps.
    return $gaps.ToArray()
}
function Format-DomeniaStorageContent {
    # Counts reported by a read-only inspection; a missing counter is unknown, never zero.
    param($Counts)
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach($pair in @(@('ad_objects','objet(s) AD'),@('domenia_observations','mesure(s)'),@('domenia_details','détail(s)'),@('user_machine_links','association(s)'),@('domenia_query_recipes','requête(s)'),@('domenia_store_batches','reçu(s)'))){
        $value=Get-DomeniaMember $Counts ([string]$pair[0]) $null;$number=0L
        if($null -ne $value -and [long]::TryParse([string]$value,[ref]$number) -and $number -ge 0){$parts.Add([string]$number+' '+[string]$pair[1])}else{$parts.Add([string]$pair[1]+' : nombre inconnu')}
    }
    return ($parts -join ', ')
}
function Get-DomeniaStorageMaintenancePreview {
    # Points 31, 32 and 34. The assistant text shown before any copy: what is copied, from where to where, what the
    # destination offers, what changes for the active base and how to go back. Built only from the read-only inspection
    # of the StorageMaintenance worker; an unknown value is written as unknown, never estimated.
    param([ValidateSet('Move','Restore')][string]$Mode,$Inspection)
    $source=Get-DomeniaMember $Inspection 'Source'
    if(($null -eq $source) -or ([string](Get-DomeniaMember $source 'Integrity' '') -cne 'ok')){throw 'Inspection de la source non confirmée.'}
    $target=Get-DomeniaMember $Inspection 'Target'
    if(($null -eq $target) -or (-not [bool](Get-DomeniaMember $target 'Writable' $false))){throw 'Destination non vérifiée : écriture non testée.'}
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $sourcePath=[string](Get-DomeniaMember $source 'Path' '');$sourceBytes=[long](Get-DomeniaMember $source 'Bytes' -1)
    if($Mode -eq 'Move'){
        $lines.Add('Base à déplacer : '+$sourcePath+' ('+(Format-DomeniaSize $sourceBytes)+', révision '+[string](Get-DomeniaMember $source 'Revision' '?')+').')
    }else{
        $written=Format-DomeniaStorageDate ([string](Get-DomeniaMember $source 'LastWriteUtc' ''))
        $commit=Format-DomeniaStorageDate ([string](Get-DomeniaMember $source 'LastCommitUtc' ''))
        $measure=Format-DomeniaStorageDate ([string](Get-DomeniaMember $source 'LastObservationUtc' ''))
        if(-not $written){$written='date inconnue'};if(-not $commit){$commit='aucun reçu daté'};if(-not $measure){$measure='aucune'}
        $lines.Add('Sauvegarde choisie : '+$sourcePath+' ('+(Format-DomeniaSize $sourceBytes)+'), fichier écrit le '+$written+'. Révision '+[string](Get-DomeniaMember $source 'Revision' '?')+'.')
        $lines.Add('Dernier lot enregistré dans cette sauvegarde : '+$commit+' ; dernière mesure : '+$measure+'.')
    }
    $lines.Add('Domaine : '+[string](Get-DomeniaMember $source 'DomainDn' '')+'. Contenu : '+(Format-DomeniaStorageContent (Get-DomeniaMember $source 'Counts' $null))+'. Intégrité SQLite vérifiée.')
    if($Mode -eq 'Restore'){
        $active=Get-DomeniaMember $Inspection 'Active'
        if(($null -ne $active) -and [bool](Get-DomeniaMember $active 'Readable' $false)){
            $info=Get-DomeniaMember $active 'Info'
            $lines.Add('Base active : '+(Format-DomeniaStorageContent (Get-DomeniaMember $info 'Counts' $null))+', révision '+[string](Get-DomeniaMember $info 'Revision' '?')+'.')
            $differences=New-Object 'System.Collections.Generic.List[string]'
            foreach($pair in @(@('ad_objects','objet(s) AD'),@('domenia_observations','mesure(s)'),@('user_machine_links','association(s)'))){
                $a=0L;$b=0L
                if([long]::TryParse([string](Get-DomeniaMember (Get-DomeniaMember $source 'Counts' $null) ([string]$pair[0]) ''),[ref]$a) -and [long]::TryParse([string](Get-DomeniaMember (Get-DomeniaMember $info 'Counts' $null) ([string]$pair[0]) ''),[ref]$b) -and ($a -ne $b)){
                    $differences.Add([string][Math]::Abs($a-$b)+' '+[string]$pair[1]+$(if($a -lt $b){' de moins'}else{' de plus'}))
                }
            }
            if($differences.Count){$lines.Add('Écart avec la base active : '+($differences -join ', ')+'. Les écritures postérieures à la sauvegarde ne seront plus visibles ; la base active est conservée.')}
            else{$lines.Add('Mêmes volumes que la base active pour les objets, les mesures et les associations ; la base active est conservée.')}
        }elseif($null -ne $active){
            $lines.Add('Base active illisible ('+[string](Get-DomeniaMember $active 'Problem' 'raison inconnue')+') : elle reste en place, intacte, et ne reçoit aucune marque de bascule.')
        }
    }
    $free=[long](Get-DomeniaMember $target 'FreeBytes' -1);$required=[long](Get-DomeniaMember $target 'RequiredBytes' -1)
    $freeText=if($free -ge 0){Format-DomeniaSize $free}else{'inconnu (volume non prêt)'}
    $lines.Add('Destination : '+[string](Get-DomeniaMember $target 'Path' '')+'. Espace libre : '+$freeText+' ; réserve exigée : '+(Format-DomeniaSize $required)+' (deux copies et 32 Mo de marge). Écriture testée dans le dossier.')
    $lines.Add('Étapes : 1. vérification (faite) ; 2. suspension des nouvelles collectes, enregistrement de la file, copie puis contrôle ; 3. bascule vers la copie vérifiée.')
    if($Mode -eq 'Move'){$lines.Add('Retour arrière : le fichier dʼorigine est conservé en lecture seule ; « Revenir à la base précédente » reste possible tant que la nouvelle base nʼa reçu aucune écriture.')}
    else{$lines.Add('La sauvegarde choisie nʼest jamais modifiée et la base active nʼest jamais écrasée : la base restaurée est un nouveau fichier.')}
    $title=if($Mode -eq 'Restore'){'Restaurer cette sauvegarde'}else{'Déplacer la base locale'}
    return [pscustomobject]@{Title=$title;ConfirmText='Copier, vérifier puis utiliser la nouvelle base';Lines=$lines.ToArray();Text=($lines -join [Environment]::NewLine)}
}
function Get-DomeniaStorageMaintenanceControlState {
    # Point 32. Which assistant buttons may act now. A drain or a running step blocks everything; a pending switch only
    # offers resume or rollback; a base declared unreadable at startup only accepts a restore (then a resume).
    param($Maintenance=$null,[bool]$DemoMode=$false,[bool]$HasDatabase=$true)
    $locked=[bool](Get-DomeniaMember $Maintenance 'Locked' $false)
    $draining=[bool](Get-DomeniaMember $Maintenance 'Draining' $false)
    $job=-not [string]::IsNullOrEmpty([string](Get-DomeniaMember $Maintenance 'Job' ''))
    $id=[string](Get-DomeniaMember $Maintenance 'Id' '')
    $recovery=(($id -ceq 'recovery-unreadable') -or [bool](Get-DomeniaMember $Maintenance 'Recovery' $false))
    $discovering=($id -ceq 'recovery-pending')
    $target=-not [string]::IsNullOrEmpty([string](Get-DomeniaMember $Maintenance 'TargetPath' ''))
    $receipt=($null -ne (Get-DomeniaMember $Maintenance 'Receipt' $null))
    $idle=((-not $DemoMode) -and $HasDatabase -and (-not $draining) -and (-not $job))
    $text='La base active reste sur un disque local. Chaque déplacement ou restauration conserve le fichier dʼorigine.'
    if($DemoMode){$text='Déplacement et restauration indisponibles en démonstration.'}
    elseif(-not $HasDatabase){$text='Aucune base locale active.'}
    elseif($draining){$text='Copie en attente : les nouvelles collectes sont suspendues le temps dʼenregistrer la file.'}
    elseif($job){$text='Étape de maintenance en cours ; les autres actions attendent sa fin.'}
    elseif($recovery -and (-not $receipt)){$text='Base locale illisible : restaurez une sauvegarde vérifiée. Les collectes restent suspendues.'}
    elseif($locked -and $discovering){$text='Lecture de la bascule interrompue en cours.'}
    elseif($locked){$text='Bascule à terminer : reprenez-la ou revenez à la base précédente. Aucun fichier ne sera supprimé.'}
    return [pscustomobject]@{
        Move=($idle -and (-not $locked))
        Restore=($idle -and ((-not $locked) -or ($recovery -and (-not $receipt))))
        Resume=($idle -and $locked -and $target -and (-not $discovering) -and ((-not $recovery) -or $receipt))
        Rollback=($idle -and $locked -and $target -and (-not $discovering) -and (-not $recovery))
        Text=$text
    }
}
function Get-DomeniaStorageBackupSchedule {
    # Point 33. What the automatic backup will do and what it last proved. A success comes from the verified receipt of
    # the StorageBackup worker (quick_check then SHA-256 of the produced file); failures are those of this session.
    param($Policy=$null,[AllowEmptyString()][string]$LastSuccessUtc='',[AllowEmptyString()][string]$LastAttemptUtc='',$LastDetail=$null,$LastFailure=$null,[bool]$Busy=$false,[datetime]$NowUtc=[datetime]::UtcNow)
    $policy=ConvertTo-DomeniaStoragePolicy $Policy
    $lines=New-Object 'System.Collections.Generic.List[string]'
    if($policy.AutomaticBackup){$lines.Add('Sauvegarde automatique : toutes les '+$policy.BackupHours+' h tant que Domenia est ouvert ; '+$policy.BackupKeep+' copies conservées dans le dossier Backups.')}
    else{$lines.Add('Sauvegarde automatique : désactivée. « Sauvegarder maintenant » reste disponible.')}
    $last=ConvertFrom-DomeniaStorageUtc $LastSuccessUtc
    if($null -ne $last){
        $proof='contrôle SQLite réussi';$bytes=[long](Get-DomeniaMember $LastDetail 'Bytes' -1);$sha=[string](Get-DomeniaMember $LastDetail 'Sha256' '')
        if($bytes -ge 0){$proof+=', '+(Format-DomeniaSize $bytes)}
        if($sha -cmatch '^[a-f0-9]{64}$'){$proof+=', empreinte SHA-256 '+$sha.Substring(0,12)+'…'}
        $lines.Add('Dernière sauvegarde vérifiée : '+(Format-DomeniaStorageDate $LastSuccessUtc)+' ('+$proof+').')
    }else{$lines.Add('Aucune sauvegarde vérifiée enregistrée pour cette base.')}
    $decision=Get-DomeniaStorageBackupDecision -Policy $policy -LastSuccessUtc $LastSuccessUtc -LastAttemptUtc $LastAttemptUtc -Busy $Busy -NowUtc $NowUtc
    $next=$null
    switch([string]$decision.Reason){
        'Scheduled' {$lines.Add('Prochaine sauvegarde : à la prochaine vérification (une par minute), dès quʼaucune opération locale nʼest en cours.')}
        'Busy' {$lines.Add('Prochaine sauvegarde : différée tant quʼune opération ou un enregistrement local est en cours.')}
        'RetryCooldown' {$next=(ConvertFrom-DomeniaStorageUtc $LastAttemptUtc).AddMinutes(15);$lines.Add('Nouvel essai au plus tôt le '+(Format-DomeniaStorageDate $next.ToString('o'))+'.')}
        'Recent' {$next=$last.AddHours($policy.BackupHours);$lines.Add('Prochaine sauvegarde : au plus tôt le '+(Format-DomeniaStorageDate $next.ToString('o'))+', si Domenia est ouvert.')}
        'InvalidClock' {$lines.Add('Dernière sauvegarde datée après lʼhorloge du poste : planification arrêtée, vérifiez la date du poste.')}
    }
    $failureAt=[string](Get-DomeniaMember $LastFailure 'AtUtc' '')
    if($failureAt){$lines.Add('Dernier échec (cette session) : '+(Format-DomeniaStorageDate $failureAt)+' : '+([string](Get-DomeniaMember $LastFailure 'Message' '')).TrimEnd('.')+'.')}
    $nextText='';if($null -ne $next){$nextText=$next.ToString('o')}
    return [pscustomobject]@{Enabled=[bool]$policy.AutomaticBackup;Due=[bool]$decision.Due;Reason=[string]$decision.Reason;NextUtc=$nextText;Lines=$lines.ToArray();Text=($lines -join [Environment]::NewLine)}
}
function Get-DomeniaStorageSpaceState {
    # Point 35. Reading of the last free-space measure of the base volume, taken by a storage worker. Writes keep their
    # own hard reserve in the LocalStore worker (32 MiB plus four times the incoming batch); new collections stop
    # earlier, under 512 MiB plus four times what is already queued, so that collected data can still be written.
    # Without a measure the state is Unknown: nothing is blocked here and nothing is claimed.
    param([long]$FreeBytes=-1,[AllowEmptyString()][string]$MeasuredUtc='',[long]$QueuedBytes=0,[datetime]$NowUtc=[datetime]::UtcNow)
    $queued=[Math]::Max(0L,$QueuedBytes)
    $write=33554432L+4L*$queued;$suspend=536870912L+4L*$queued;$warn=2147483648L+4L*$queued
    $measured=ConvertFrom-DomeniaStorageUtc $MeasuredUtc
    $state='Unknown';$stale=$false
    if(($FreeBytes -ge 0) -and ($null -ne $measured)){
        $stale=(($NowUtc.ToUniversalTime()-$measured) -gt [timespan]::FromMinutes(30))
        if($FreeBytes -lt $write){$state='Critical'}elseif($FreeBytes -lt $suspend){$state='Suspend'}elseif($FreeBytes -lt $warn){$state='Low'}else{$state='Ok'}
    }
    $when='';$measuredText='';if($null -ne $measured){$when=Format-DomeniaStorageDate $MeasuredUtc;$measuredText=$measured.ToString('o')}
    switch($state){
        'Unknown' {$text='Espace libre du volume de la base : non mesuré dans cette session. Chaque enregistrement contrôle sa propre réserve ; « Mesurer » donne lʼétat du disque.'}
        'Critical' {$text='Espace disque critique : '+(Format-DomeniaSize $FreeBytes)+' libres (mesure du '+$when+'). Écritures refusées sous '+(Format-DomeniaSize $write)+' et nouvelles collectes suspendues. Libérez de la place puis cliquez sur « Mesurer ».'}
        'Suspend' {$text='Espace disque insuffisant : '+(Format-DomeniaSize $FreeBytes)+' libres (mesure du '+$when+'). Nouvelles collectes suspendues sous '+(Format-DomeniaSize $suspend)+' ; ce qui est déjà collecté continue de sʼenregistrer. Libérez de la place puis cliquez sur « Mesurer ».'}
        'Low' {$text='Espace disque à surveiller : '+(Format-DomeniaSize $FreeBytes)+' libres (mesure du '+$when+'). Les nouvelles collectes seront suspendues sous '+(Format-DomeniaSize $suspend)+'.'}
        default {$text='Espace libre du volume de la base : '+(Format-DomeniaSize $FreeBytes)+' (mesure du '+$when+').'}
    }
    if($stale){$text+=' Mesure ancienne : cliquez sur « Mesurer » pour lʼactualiser.'}
    return [pscustomobject]@{State=$state;FreeBytes=$FreeBytes;MeasuredUtc=$measuredText;Stale=$stale;WriteReserveBytes=$write;SuspendBelowBytes=$suspend;WarnBelowBytes=$warn;BlocksCollections=($state -in @('Critical','Suspend'));Text=$text}
}
function Format-DomeniaStorageUnsaved {
    # Point 35. What is still only in memory, from Get-DomeniaPersistenceState. Nothing pending is said plainly.
    param($Persistence)
    $pending=[int](Get-DomeniaMember $Persistence 'Pending' 0);$changes=[long](Get-DomeniaMember $Persistence 'QueuedChanges' 0);$bytes=[long](Get-DomeniaMember $Persistence 'QueuedBytes' 0)
    if(($pending -le 0) -and ($changes -le 0)){return 'Aucune donnée en attente dʼenregistrement.'}
    $text='Non enregistré, en mémoire : '+$pending+' élément(s) en file'
    if($changes -gt 0){$text+=', dont '+$changes+' changement(s) collecté(s) ('+(Format-DomeniaSize $bytes)+')'}
    if([bool](Get-DomeniaMember $Persistence 'Suspended' $false)){$text+=' ; enregistrement suspendu, reprise dans Fiabilité'}
    return $text+'.'
}
function Get-DomeniaStorageIntegrityVerdict {
    # Point 36. Reading of the StorageIntegrity report. Every expected check is present once with a known status; one
    # failed check makes the verdict « Défaut » and points to the restore assistant. Nothing is repaired automatically.
    param($Result)
    if(($null -eq $Result) -or ([string](Get-DomeniaMember $Result 'Kind' '') -cne 'StorageIntegrity') -or ((Get-DomeniaMember $Result 'ReadOnly' $null) -isnot [bool]) -or (-not [bool](Get-DomeniaMember $Result 'ReadOnly' $false))){throw 'Contrôle dʼintégrité non confirmé.'}
    $labels=[ordered]@{Open='Ouverture';Schema='Schéma';Tables='Tables et colonnes';Identity='Identité de la base';Redirect='Bascule';Receipts='Reçus';ForeignKeys='Références';QuickCheck='Contrôle SQLite';Wal='Journal SQLite'}
    $readable=[bool](Get-DomeniaMember $Result 'Readable' $false)
    $seen=@{};$details=New-Object 'System.Collections.Generic.List[string]';$failed=0;$warned=0;$unknown=0
    foreach($check in @(Get-DomeniaMember $Result 'Checks' @())){
        $id=[string](Get-DomeniaMember $check 'Id' '');$status=[string](Get-DomeniaMember $check 'Status' '')
        if((-not $labels.Contains($id)) -or $seen.ContainsKey($id) -or ($status -cnotin @('Ok','Warning','Failed','Unknown'))){throw 'Rapport dʼintégrité incohérent.'}
        $seen[$id]=$true
        if($status -eq 'Failed'){$failed++}elseif($status -eq 'Warning'){$warned++}elseif($status -eq 'Unknown'){$unknown++}
        $mark=switch($status){'Ok'{'conforme'}'Warning'{'à surveiller'}'Failed'{'défaut'}default{'non vérifié'}}
        $detail=[string](Get-DomeniaMember $check 'Detail' '')
        $details.Add($labels[$id]+' : '+$mark+$(if($detail){' ('+$detail.TrimEnd('.')+')'}else{''})+'.')
    }
    if($readable){foreach($id in @($labels.Keys)){if(-not $seen.ContainsKey($id)){throw 'Rapport dʼintégrité incomplet.'}}}
    elseif((-not $seen.ContainsKey('Open')) -or ($failed -lt 1)){throw 'Rapport dʼintégrité incomplet.'}
    $verdict='Sain';if($failed -gt 0){$verdict='Défaut'}elseif($warned -gt 0){$verdict='À surveiller'}elseif($unknown -gt 0){$verdict='Incomplet'}
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $when=Format-DomeniaStorageDate ([string](Get-DomeniaMember $Result 'CheckedUtc' '')) -Seconds
    $lines.Add('Contrôle du '+$(if($when){$when}else{'moment inconnu'})+' en '+[string][long](Get-DomeniaMember $Result 'DurationMs' 0)+' ms : '+$verdict+'.')
    foreach($line in $details){$lines.Add($line)}
    if($failed -gt 0){$lines.Add('Restaurez une sauvegarde vérifiée avec « Restaurer une sauvegarde… » : la base actuelle reste en place, sans modification.')}
    $lines.Add('Ce contrôle lit la base sans la modifier ; aucune réparation automatique.')
    return [pscustomobject]@{Verdict=$verdict;Failed=$failed;Warnings=$warned;Unknown=$unknown;Readable=$readable;Lines=$lines.ToArray();Text=($lines -join [Environment]::NewLine)}
}
function Get-DomeniaStorageRetentionFamilies {
    # Point 37. Closed list of retention families: policy key, label and what is lost. The StorageRetention worker uses
    # the same identifiers and refuses any other. LinkHistory compacts (repeated identical observations only).
    return @(
        [pscustomobject]@{Family='Presence';PolicyKey='PresenceDays';Label='Présence ping';Kind='LastState';Loss='ces postes perdront leur dernier état de présence connu et apparaîtront non relevés'}
        [pscustomobject]@{Family='Console';PolicyKey='ConsoleDays';Label='Utilisateur connecté';Kind='LastState';Loss='ces postes perdront le dernier utilisateur connecté relevé'}
        [pscustomobject]@{Family='Inventory';PolicyKey='InventoryDays';Label='Inventaire';Kind='LastState';Loss='ces postes perdront leur dernier inventaire léger (modèle, mémoire, disque, système)'}
        [pscustomobject]@{Family='Probe';PolicyKey='ProbeDays';Label='Sondes';Kind='LastState';Loss='les résultats de sondes WMI correspondants seront à relire sur les postes'}
        [pscustomobject]@{Family='Detail';PolicyKey='DetailDays';Label='Détails';Kind='LastState';Loss='les résultats détaillés (logiciels, instances) seront à relire sur les postes'}
        [pscustomobject]@{Family='LinkHistory';PolicyKey='LinkHistoryDays';Label='Historique des associations';Kind='Compaction';Loss='seules les observations identiques répétées sont retirées ; chaque changement dʼutilisateur et la première et la dernière observation de chaque période sont gardés'}
    )
}
function Get-DomeniaStorageRetentionCutoffs {
    # Point 37. One UTC cutoff per family from the policy; '' keeps the family without time limit.
    param($Policy=$null,[datetime]$NowUtc=[datetime]::UtcNow)
    $policy=ConvertTo-DomeniaStoragePolicy $Policy;$cutoffs=[ordered]@{}
    foreach($family in @(Get-DomeniaStorageRetentionFamilies)){
        $days=[int]$policy.([string]$family.PolicyKey)
        $cutoffs[[string]$family.Family]=if($days -gt 0){$NowUtc.ToUniversalTime().AddDays(-$days).ToString('o')}else{''}
    }
    return [pscustomobject]$cutoffs
}
function Get-DomeniaStorageRetentionLines {
    # Point 37. Announces, before anything is deleted, what each family loses and what is always kept.
    param([object[]]$Counts=@(),$Cutoffs=$null,[long]$SkippedLegacyRows=0,[bool]$DryRun=$true)
    $byFamily=@{};foreach($row in @($Counts)){if($null -ne $row){$byFamily[[string](Get-DomeniaMember $row 'Family' '')]=$row}}
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($family in @(Get-DomeniaStorageRetentionFamilies)){
        $cutoff=[string](Get-DomeniaMember $Cutoffs ([string]$family.Family) '')
        if(-not $cutoff){$lines.Add([string]$family.Label+' : conservé sans limite de durée.');continue}
        if(-not $byFamily.ContainsKey([string]$family.Family)){throw 'Famille absente du comptage de conservation.'}
        $rows=0L;[void][long]::TryParse([string](Get-DomeniaMember $byFamily[[string]$family.Family] 'Rows' ''),[ref]$rows)
        $date=Format-DomeniaStorageDate $cutoff
        if($rows -le 0){$lines.Add([string]$family.Label+' : rien dʼantérieur au '+$date+'.');continue}
        $verb='à retirer';if(-not $DryRun){$verb='retirée(s)'}
        $what='mesure(s)';if($family.Kind -eq 'Compaction'){$what='observation(s) répétée(s)'}
        $lines.Add([string]$family.Label+' : '+$rows+' '+$what+' antérieure(s) au '+$date+' '+$verb+' ; '+[string]$family.Loss+'.')
    }
    if($SkippedLegacyRows -gt 0){$lines.Add([string]$SkippedLegacyRows+' mesure(s) dʼanciens relevés non migrés conservée(s).')}
    $lines.Add('Toujours conservés : objets AD, comptes, associations actuelles et déclarées, requêtes, journaux et reçus ; dates illisibles et tentatives récentes.')
    $lines.Add('La suppression libère de la place réutilisable dans la base ; elle ne réduit pas immédiatement la taille du fichier.')
    return $lines.ToArray()
}
function Get-DomeniaStorageLimitLines {
    # Point 40. The explicit bounds of local storage, memory and retention, with the measured values when a measure
    # exists. No unlimited storage is promised: each queue, cache and series has a stated limit.
    param($Policy=$null,$Engine=$null,$Usage=$null,$Space=$null)
    $policy=ConvertTo-DomeniaStoragePolicy $Policy
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('Le stockage local nʼest pas illimité : chaque file, cache et série a une limite, et la base grandit avec ce qui est conservé.')
    $lines.Add('Mémoire : file dʼécriture de 4 096 changements ou 32 Mo au plus (lots de 250 changements ou 4 Mo), 256 éléments en attente ; recherches et vues de 20 000 lignes au plus ; cache de recherche de 20 requêtes, chacune de 20 000 lignes et 32 Mo au plus.')
    if($null -ne $Engine){$lines.Add('Moteur : '+[string](Get-DomeniaMember $Engine 'MaxConcurrent' '?')+' tâches simultanées et '+[string](Get-DomeniaMember $Engine 'MaxQueued' '?')+' en attente au plus.')}
    $measured=Format-DomeniaStorageDate ([string](Get-DomeniaMember $Usage 'MeasuredUtc' ''))
    if($measured){$lines.Add('Disque : base de '+(Format-DomeniaSize ([long](Get-DomeniaMember $Usage 'DatabaseBytes' -1)))+', journal SQLite de '+(Format-DomeniaSize ([long](Get-DomeniaMember $Usage 'WalBytes' -1)))+', mesurés le '+$measured+'.')}
    else{$lines.Add('Disque : taille de la base non mesurée dans cette session (« Mesurer »).')}
    $suspend=[long](Get-DomeniaMember $Space 'SuspendBelowBytes' 536870912L);$write=[long](Get-DomeniaMember $Space 'WriteReserveBytes' 33554432L)
    $lines.Add('Espace disque : nouvelles collectes suspendues sous '+(Format-DomeniaSize $suspend)+' libres, écritures refusées sous '+(Format-DomeniaSize $write)+' (seuils relevés de quatre fois la file en attente).')
    $retention=New-Object 'System.Collections.Generic.List[string]'
    foreach($family in @(Get-DomeniaStorageRetentionFamilies)){$days=[int]$policy.([string]$family.PolicyKey);$retention.Add([string]$family.Label+' '+$(if($days -gt 0){[string]$days+' j'}else{'sans limite'}))}
    $lines.Add('Conservation : '+($retention -join ', ')+'. Mesures de performance : 10 000 dernières ; instantanés du parc : 400 jours ; sauvegardes : '+$policy.BackupKeep+' copies. Reçus gardés sans limite, détail compacté après chaque lot.')
    $categories=@(Get-DomeniaMember $Usage 'Categories' @()|Where-Object{$null -ne $_})
    if($categories.Count){
        $byBytes=[bool](Get-DomeniaMember $Usage 'DbstatAvailable' $false)
        $labels=@{Observations='Observations';Snapshots='Instantanés';History='Historique';Index='Index';ManualLinks='Associations';Secrets='Métadonnées de secrets'}
        $sorted=@($categories|Sort-Object -Descending -Property @{Expression={if($byBytes){[long](Get-DomeniaMember $_ 'Bytes' -1)}else{[long](Get-DomeniaMember $_ 'Rows' -1)}}}|Select-Object -First 3)
        $top=@(foreach($category in $sorted){$name=[string](Get-DomeniaMember $category 'Category' '');$label=if($labels.ContainsKey($name)){$labels[$name]}else{$name};$size='';if($byBytes){$size=(Format-DomeniaSize ([long](Get-DomeniaMember $category 'Bytes' -1)))+', '};$label+' ('+$size+[string](Get-DomeniaMember $category 'Rows' '?')+' ligne(s))'})
        $lines.Add('Collections les plus volumineuses à la dernière mesure : '+($top -join ', ')+'.')
    }
    return $lines.ToArray()
}
function Format-DomeniaStorageReadProbes {
    # Point 39. Reading of the measured reads of the usage worker: time on this base, rows, and how SQLite served them
    # (index, full sort in memory or full scan) according to the plan SQLite itself returned. No probe, no line.
    param([object[]]$Probes=@())
    $labels=[ordered]@{DirectoryPage='page de lʼindex par type';ActiveMachines='postes actifs triés';FamilyPage='page de mesures dʼune famille';TextSearch='recherche de texte'}
    $parts=New-Object 'System.Collections.Generic.List[string]'
    foreach($probe in @($Probes)){
        if($null -eq $probe){continue}
        $name=[string](Get-DomeniaMember $probe 'Name' '');if(-not $labels.Contains($name)){continue}
        $plan=[string](Get-DomeniaMember $probe 'Plan' '')
        $how='plan inconnu'
        if($plan -match 'USE TEMP B-TREE FOR ORDER BY'){$how='tri complet en mémoire'}
        elseif($plan -match 'USING (COVERING )?INDEX'){$how='index'}
        elseif($plan -match '(^|\| )SCAN '){$how='parcours complet'}
        $ms=0.0;[void][double]::TryParse([string](Get-DomeniaMember $probe 'Ms' ''),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$ms)
        $parts.Add([string]$labels[$name]+' ('+[string](Get-DomeniaMember $probe 'Rows' '?')+' ligne(s)) : '+$ms.ToString('0.##',[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))+' ms, '+$how)
    }
    if(-not $parts.Count){return ''}
    return 'Lectures mesurées sur cette base : '+($parts -join ' ; ')+'.'
}
