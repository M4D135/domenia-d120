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
    $policy=[ordered]@{Version=1;AutomaticBackup=$false;BackupHours=24;BackupKeep=7;PresenceDays=30;ConsoleDays=90;InventoryDays=180;ProbeDays=90;DetailDays=30}
    if($null -ne $Value){
        # Snapshot of the keys: writing a value while enumerating .Keys throws under Windows PowerShell 5.1.
        foreach($key in @($policy.Keys)){$v=Get-DomeniaStoreValue $Value $key $null;if($null -ne $v){
            if($key -eq 'AutomaticBackup'){if($v -isnot [bool]){throw 'Activation de sauvegarde invalide.'};$policy[$key]=[bool]$v}
            else{$number=0;if(-not [int]::TryParse([string]$v,[ref]$number)){throw ('Reglage de stockage invalide : '+$key)};$policy[$key]=$number}
        }}
    }
    if($policy.Version -ne 1 -or $policy.BackupHours -lt 1 -or $policy.BackupHours -gt 720 -or $policy.BackupKeep -lt 2 -or $policy.BackupKeep -gt 30){throw 'Sauvegarde : frequence 1 a 720 heures, retention 2 a 30 copies.'}
    foreach($key in @('PresenceDays','ConsoleDays','InventoryDays','ProbeDays','DetailDays')){if($policy[$key] -lt 0 -or $policy[$key] -gt 36500){throw 'Conservation : 0 (sans limite) a 36500 jours.'}}
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
