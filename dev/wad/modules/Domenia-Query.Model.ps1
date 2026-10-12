# Typed recipes shared by the fleet workshop, saved widgets and Search. No network access.
function Get-DomeniaQueryFields {
    $fields = [Collections.Generic.List[object]]::new()
    foreach ($line in @(
        'name|Nom du poste|Text','dn|Chemin AD complet|Text','active|Compte actif|Boolean',
        'os|Système déclaré dans AD|Text','version|Version déclarée dans AD|Text',
        'osLabel|Libellé système du dashboard|Text','release|Version Windows du dashboard|Text','osFamily|Famille poste / serveur|Text',
        'site|OU du regroupement dashboard|Text','lifeStatus|Cycle Windows (Ended, Soon, Supported, Unknown)|Text','win10|Windows 10 hors LTSC, LTSB et IoT|Boolean',
        'logonDays|Jours depuis la connexion AD (approximatif)|Number','logonBucket|Tranche de connexion AD|Number',
        'createdRecent|Créé depuis 30 jours|Boolean','passwordOld|Mot de passe machine de plus de 60 jours|Boolean',
        'laps|État LAPS (O valide, E expiré, N absent, X sans schéma)|Text',
        'bitlocker|Clé AD (K présente, N aucune visible, X indisponible)|Text',
        'presenceBucket|Présence regroupée du dashboard|Text','inventoryDays|Ancienneté de lʼinventaire en jours|Number','observedRelease|Windows relevé sur le poste|Text',
        'checkedDays|Ancienneté du relevé en jours|Number','presence|Dernière présence observée|Text',
        'user|Utilisateur console observé|Text','model|Modèle relevé|Text',
        'ramGB|Mémoire relevée en Go|Number','diskFreePercent|Espace libre C: relevé (%)|Number','uptimeDays|Jours depuis le démarrage relevé|Number'
    )) { $p=$line.Split('|'); $fields.Add([pscustomobject]@{Id=$p[0];Name=$p[1];Kind=$p[2];ProbeId='';Category='Données du parc'}) }
    foreach ($probe in @(Get-DomeniaProbeCatalog)) {
        $numeric=([string]$probe.Transform -notlike 'Map:*') -and ([string]$probe.Mode -eq 'Count' -or [string]$probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree|Year)$')
        $fields.Add([pscustomobject]@{Id=('probe:'+[string]$probe.Id);Name=([string]$probe.Category+' · '+[string]$probe.Name);Kind=$(if($numeric){'Number'}else{'Text'});ProbeId=[string]$probe.Id;Category=[string]$probe.Category})
    }
    return $fields.ToArray()
}
function Get-DomeniaQueryOperators {
    param([string]$Kind='Text')
    $ops=[ordered]@{Equal='est égal à';NotEqual='est différent de';IsMissing='est absent';IsPresent='est renseigné'}
    if($Kind -eq 'Text'){$ops.Contains='contient';$ops.StartsWith='commence par';$ops.EndsWith='se termine par'}
    if($Kind -in @('Number','Timestamp')){$ops.Greater='est supérieur à';$ops.GreaterOrEqual='est supérieur ou égal à';$ops.Less='est inférieur à';$ops.LessOrEqual='est inférieur ou égal à'}
    return @(foreach($entry in $ops.GetEnumerator()){[pscustomobject]@{Id=[string]$entry.Key;Name=[string]$entry.Value}})
}
function New-DomeniaQueryRecipe {
    param([string]$Name='Tous les postes recensés',[string]$Id='',[string]$Junction='All',[object[]]$Clauses=@(),[string]$GroupBy='',[object[]]$Refinements=@(),$ProbeSelection=$null,$ObjectIds=$null)
    if(-not $Id){$Id=[guid]::NewGuid().ToString('N')}
    return [pscustomobject]@{Format='Domenia.Query/1';Id=$Id;Name=$Name;Junction=$Junction;Clauses=@($Clauses);GroupBy=$GroupBy;Refinements=@($Refinements);ProbeSelection=$ProbeSelection;ObjectIds=$ObjectIds}
}
function Get-DomeniaQueryIdentitySelection {
    # A frozen alert selection is explicit, GUID-bound and may be saved. Empty never means all.
    param($Recipe)
    $values=Get-DomeniaMemberValue $Recipe 'ObjectIds'
    if($null -eq $values){return $null}
    if($values -is [string] -or @($values).Count -gt 20000){throw 'La sélection accepte au plus 20 000 GUID.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($value in $values){
        $guid=[guid]::Empty
        if(-not [guid]::TryParse([string]$value,[ref]$guid) -or $guid -eq [guid]::Empty){throw 'GUID invalide dans la sélection de postes.'}
        [void]$ids.Add($guid.ToString('D'))
    }
    return ,$ids
}
function ConvertTo-DomeniaCompiledQuery {
    param([Parameter(Mandatory=$true)]$Recipe)
    if([string](Get-DomeniaMember $Recipe 'Format') -cne 'Domenia.Query/1'){throw 'Format de requête non reconnu.'}
    [void](ConvertTo-DomeniaQueryProbeSelection $Recipe)
    [void](Get-DomeniaQueryIdentitySelection $Recipe)
    $name=[string](Get-DomeniaMember $Recipe 'Name');$id=[string](Get-DomeniaMember $Recipe 'Id')
    if(-not $name.Trim() -or $name.Length -gt 120 -or $id -notmatch '^[a-zA-Z0-9_.-]{1,80}$'){throw 'Nom ou identifiant de requête invalide.'}
    $junction=[string](Get-DomeniaMember $Recipe 'Junction')
    if($junction -cnotin @('All','Any')){throw 'Choisir Toutes les conditions ou Au moins une condition.'}
    $definition=[M4D.Admin.Common.Query.QueryDefinition]::new()
    $definition.Junction=[M4D.Admin.Common.Query.QueryJunction]::$junction
    $definitions=[Collections.Generic.List[M4D.Admin.Common.Query.FieldDefinition]]::new();$byId=@{}
    foreach($field in @(Get-DomeniaQueryFields)){$byId[$field.Id]=$field;$definitions.Add([M4D.Admin.Common.Query.FieldDefinition]::new($field.Id,[M4D.Admin.Common.Query.FieldKind]::$($field.Kind)))}
    $clauses=@(Get-DomeniaMember $Recipe 'Clauses' @())
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @());$groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy')
    if($groupBy -and $groupBy -cnotin @($byId.Keys)){throw 'Champ de répartition inconnu.'}
    if($refinements.Count){[void](ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements))}
    if(($clauses.Count+$refinements.Count) -gt 64){throw 'Une requête accepte 64 conditions au maximum.'}
    foreach($clause in $clauses){
        $key=[string](Get-DomeniaMember $clause 'Field');$op=[string](Get-DomeniaMember $clause 'Operator');$value=Get-DomeniaMemberValue $clause 'Value'
        if(-not $byId.ContainsKey($key) -or $key -cnotin @($byId.Keys)){throw ('Champ inconnu : '+$key)}
        if($op -cnotin @(Get-DomeniaQueryOperators -Kind $byId[$key].Kind | ForEach-Object{$_.Id})){throw ('Opérateur invalide pour '+$byId[$key].Name)}
        if($null -ne $value -and $value -is [psobject]){$value=$value.PSObject.BaseObject}
        $definition.Clauses.Add([M4D.Admin.Common.Query.QueryClause]::new($key,[M4D.Admin.Common.Query.QueryOperator]::$op,$value))
    }
    return [M4D.Admin.Common.Query.QueryEngine]::Compile($definitions,$definition)
}
function ConvertTo-DomeniaQueryProbeSelection {
    param($Recipe)
    $selection=Get-DomeniaMemberValue $Recipe 'ProbeSelection'
    if($null -eq $selection){return $null}
    $key=[string](Get-DomeniaMember $selection 'Key');$mode=[string](Get-DomeniaMember $selection 'Mode')
    $probe=Get-DomeniaProbe $key
    if($null -eq $probe -or $mode -cnotin @('Equal','Range','Other')){throw 'Segment de sonde inconnu.'}
    $numeric=([string]$probe.Transform -notlike 'Map:*') -and ($probe.Mode -eq 'Count' -or $probe.Transform -match '^(GB|GBfromKB|MB|Mbps|Number|DaysSince|PercentFree|Year)$')
    $result=[Domenia.Native.ProbeSelection]::new();$result.Key=$key;$result.Mode=$mode;$result.Numeric=$numeric
    if($mode -eq 'Range'){
        $low=Get-DomeniaMemberValue $selection 'Low';$high=Get-DomeniaMemberValue $selection 'High'
        $result.Low=if($null -eq $low){[double]::NegativeInfinity}else{[double]$low};$result.High=if($null -eq $high){[double]::PositiveInfinity}else{[double]$high}
        if(-not $numeric -or [double]::IsNaN($result.Low) -or [double]::IsNaN($result.High) -or $result.Low -ge $result.High){throw 'Bornes de segment invalides.'}
    }elseif($mode -eq 'Equal'){
        $value=Get-DomeniaMemberValue $selection 'Value';if($null -eq $value){throw 'Valeur de segment absente.'}
        $result.Value=[Convert]::ToString($value,[Globalization.CultureInfo]::InvariantCulture)
        if($result.Value.Length -gt 4096 -or ($numeric -and $null -eq (ConvertTo-DomeniaProbeNumber $result.Value))){throw 'Valeur de segment invalide.'}
    }else{
        $excluded=@(Get-DomeniaMember $selection 'Excluded' @())
        if(-not $excluded.Count -or $excluded.Count -gt 64){throw 'Catégories du segment invalides.'}
        $result.Excluded=[string[]]$excluded
    }
    return $result
}
function Get-DomeniaQueryTemplates {
    New-DomeniaQueryRecipe -Id 'template.all' -Name 'Tous les postes recensés'
    New-DomeniaQueryRecipe -Id 'template.stale' -Name 'Comptes actifs sans connexion depuis au moins 90 jours' -Clauses @(
        [pscustomobject]@{Field='active';Operator='Equal';Value=$true},
        [pscustomobject]@{Field='logonBucket';Operator='GreaterOrEqual';Value=3},
        [pscustomobject]@{Field='logonBucket';Operator='LessOrEqual';Value=4})
    foreach($row in @(
        @('active','Comptes actifs','active','Equal',$true),@('disabled','Comptes désactivés','active','Equal',$false),
        @('never','Date de connexion AD non renseignée','logonDays','IsMissing',$null),
        @('created','Créés depuis 30 jours','createdRecent','Equal',$true),
        @('password','Mot de passe machine ancien','passwordOld','Equal',$true),
        @('laps','Expiration LAPS dépassée','laps','Equal','E'),
        @('nolaps','Aucun attribut LAPS lu','laps','Equal','N'),
        @('nokey','Aucune clé BitLocker visible dans AD','bitlocker','Equal','N'),
        @('servers','Système AD contenant Server','os','Contains','Server'),
        @('unchecked','Sans relevé utilisable','checkedDays','IsMissing',$null),
        @('oldcheck','Relevé de plus de 7 jours','checkedDays','Greater',7),
        @('lowdisk','C: moins de 10 % libre','diskFreePercent','Less',10),
        @('ram','Moins de 8 Go de RAM','ramGB','Less',8),
        @('uptime','Sans redémarrage depuis plus de 30 jours','uptimeDays','Greater',30),
        @('cpu','Charge CPU supérieure à 80 %','probe:hw.cpuload','Greater',80),
        @('services','Services automatiques arrêtés','probe:soft.stoppedauto','Greater',0),
        @('syserrors','Erreurs système depuis 24 h','probe:evt.syserrors','Greater',0)
    )) {New-DomeniaQueryRecipe -Id ('template.'+$row[0]) -Name $row[1] -Clauses @([pscustomobject]@{Field=$row[2];Operator=$row[3];Value=$row[4]})}
}
function ConvertFrom-DomeniaQueryLibrary {
    param([string]$Json='')
    if(-not $Json){return @()}
    if([Text.Encoding]::UTF8.GetByteCount($Json) -gt 1048576){throw 'Bibliothèque de requêtes trop volumineuse (1 Mio maximum en UTF-8).'}
    $library=ConvertFrom-Json -InputObject $Json -ErrorAction Stop
    if([string](Get-DomeniaMember $library 'Format') -cne 'Domenia.QueryLibrary/1'){throw 'Bibliothèque de requêtes non reconnue.'}
    $queries=@(Get-DomeniaMember $library 'Queries' @());if($queries.Count -gt 100){throw '100 requêtes enregistrées au maximum.'}
    $ids=@{}
    foreach($recipe in $queries){
        [void](ConvertTo-DomeniaCompiledQuery $recipe)
        if($ids.ContainsKey([string]$recipe.Id) -or [string]$recipe.Id -like 'template.*'){throw 'Identifiant réservé ou dupliqué.'}
        $ids[[string]$recipe.Id]=$true
    }
    return $queries
}
function ConvertTo-DomeniaQueryLibraryJson {
    param([object[]]$Queries=@())
    $json=ConvertTo-Json -InputObject ([pscustomobject]@{Format='Domenia.QueryLibrary/1';Queries=@($Queries)}) -Depth 8 -Compress
    [void](ConvertFrom-DomeniaQueryLibrary $json)
    return $json
}
function Get-DomeniaQueryProbeIds {
    param($Recipe)
    return @(@(@(Get-DomeniaMember $Recipe 'Clauses' @())+@(Get-DomeniaMember $Recipe 'Refinements' @())+@([pscustomobject]@{Field=[string](Get-DomeniaMember $Recipe 'GroupBy')},[pscustomobject]@{Field=$(if($null -ne (Get-DomeniaMemberValue $Recipe 'ProbeSelection')){'probe:'+([string]$Recipe.ProbeSelection.Key)}else{''})})) | ForEach-Object{[string](Get-DomeniaMember $_ 'Field')} | Where-Object{$_ -like 'probe:*'} | ForEach-Object{$_.Substring(6)} | Select-Object -Unique)
}
function ConvertTo-DomeniaQueryRecords {
    param($Fleet,[hashtable]$Observations=@{},[datetime]$NowUtc=[datetime]::UtcNow,[int]$MaxAgeDays=30,$Lifecycle=$null)
    if($null -eq $Observations){$Observations=@{}}
    $groups=@{};foreach($group in @(Get-DomeniaMember $Fleet 'Groups' @())){$groups[[string]$group.gid]=$group}
    $derived=@{}
    foreach($group in $groups.Values){
        $os=([string]$group.os).Trim();if(-not $os){$os='Systeme non renseigne'};$os=$os -replace '^Microsoft ','' -replace 'Professionnel|Professional','Pro'
        $release=Get-DomeniaWindowsRelease -Build ([string]$group.ver) -Caption $os -Lifecycle $Lifecycle -Now $NowUtc
        $derived[[string]$group.gid]=@{osLabel=$os;release=$(if($release.Build){if($release.Label){[string]$release.Label}else{$os+' (build '+[string]$release.Build+')'}}else{'Version non lue'});osFamily=$(if(-not ([string]$group.os).Trim()){'Système non renseigné'}elseif($release.Family -eq 'Server'){'Serveurs'}else{'Postes de travail'});lifeStatus=[string]$release.Status;win10=($os -match '(?i)Windows 10' -and $os -notmatch '(?i)LTSC|LTSB|IoT')}
    }
    $probeFields=@{};foreach($field in @(Get-DomeniaQueryFields | Where-Object{$_.ProbeId})){$probeFields[$field.ProbeId]=$field}
    $probeCatalog=@{};foreach($p in @(Get-DomeniaProbeCatalog)){$probeCatalog[$p.Id]=$p}
    $records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($machine in @(Get-DomeniaMember $Fleet 'Machines' @())){
        $dn=[string]$machine.distinguished_name;$guid=[string]$machine.object_guid
        $v=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $v['presenceBucket']='Non verifie';$v['name']=[string]$machine.name;$v['dn']=$dn;$v['active']=([string]$machine.st -ne 'D')
        $group=$groups[[string]$machine.gid]
        if($null -ne $group){
            foreach($entry in $derived[[string]$group.gid].GetEnumerator()){$v[$entry.Key]=$entry.Value}
            foreach($mapping in @(@('os','os'),@('ver','version'),@('lk','laps'),@('bk','bitlocker'))){$value=[string](Get-DomeniaMember $group $mapping[0]);if($value -and $value -ne 'U'){$v[$mapping[1]]=$value}}
            $v['logonBucket']=[int]$group.lb
            if([string]$group.cr -in @('R','O')){$v['createdRecent']=([string]$group.cr -eq 'R')}
            if([string]$group.pw -in @('R','O')){$v['passwordOld']=([string]$group.pw -eq 'O')}
        }
        $v['site']=Get-DomeniaDnSite -ParentDn (Get-DomeniaRawDnParent $dn) -Scope ([string](Get-DomeniaMember $Fleet 'Scope'))
        $logon=[datetime]::MinValue
        if([datetime]::TryParseExact([string]$machine.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$logon) -and $logon.ToUniversalTime() -le $NowUtc.AddMinutes(5)){$v['logonDays']=[double][Math]::Max(0,($NowUtc-$logon.ToUniversalTime()).TotalDays)}
        $observation=$Observations[$dn.ToLowerInvariant()]
        $observedGuid=[string](Get-DomeniaMember $observation 'Guid')
        # A DN alone cannot attach an observation to a recreated account.
        if($guid -and $observedGuid -and $guid.Trim().Trim('{','}').ToLowerInvariant() -eq $observedGuid.Trim().Trim('{','}').ToLowerInvariant()){
            $checked=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'CheckedUtc'))
            $usable=($null -ne $checked -and $checked -le $NowUtc.AddMinutes(5) -and ($NowUtc-$checked).TotalDays -le $MaxAgeDays)
            if($usable){
                $v['checkedDays']=[double][Math]::Max(0,($NowUtc-$checked).TotalDays)
                $presence=[string](Get-DomeniaMember $observation 'Presence');if($presence){$v['presence']=$presence}
                $v['presenceBucket']=if($presence -eq 'En ligne'){'En ligne'}elseif($presence -match 'Sans|Erreur|Hors'){'Sans reponse'}else{'Non verifie'}
                $userAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $observation 'ObservedUtc'))
                $user=[string](Get-DomeniaMember $observation 'LinkUser')
                if($user -and $null -ne $userAt -and $userAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$userAt).TotalDays -le $MaxAgeDays){$v['user']=$user}

                $inventory=Get-DomeniaMemberValue $observation 'Inventory'
                $inventoryAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'CheckedUtc'))
                if($null -ne $inventoryAt -and $inventoryAt -le $NowUtc.AddMinutes(5) -and ($NowUtc-$inventoryAt).TotalDays -le $MaxAgeDays){
                $v['inventoryDays']=[double][Math]::Max(0,($NowUtc-$inventoryAt).TotalDays)
                $model=[string](Get-DomeniaMember $inventory 'Model');$v['model']=if($model){$model}else{'Modele inconnu'}
                $build=[string](Get-DomeniaMember $inventory 'Build')
                $release=(Get-DomeniaWindowsRelease -Build $build -Caption ([string](Get-DomeniaMember $inventory 'OsCaption')) -Lifecycle $Lifecycle -Now $NowUtc).Name
                $v['observedRelease']=if($release){[string]$release}elseif($build){'Build '+$build}else{'Version inconnue'}
                $ram=Get-DomeniaMember $inventory 'RamBytes';if($null -ne $ram -and [double]$ram -gt 0){$v['ramGB']=[double]$ram/1GB}
                $size=Get-DomeniaMember $inventory 'DiskSize';$free=Get-DomeniaMember $inventory 'DiskFree'
                if($null -ne $size -and $null -ne $free -and [double]$size -gt 0 -and [double]$free -ge 0 -and [double]$free -le [double]$size){$v['diskFreePercent']=100.0*[double]$free/[double]$size}
                $boot=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $inventory 'LastBootUtc'))
                if($null -ne $boot -and $boot -le $NowUtc){$v['uptimeDays']=[double]($NowUtc-$boot).TotalDays}
                }
            }
            # A fresh ping must not freshen an older probe. Every probe has its own timestamp.
            $probes=Get-DomeniaMemberValue $observation 'Probes'
            # Visit only measurements actually present. Scanning every catalog field for every machine
            # makes an uncollected 10,000-machine fleet pay for 780,000 missing member lookups.
            $probeIds=if($observation -is [Domenia.Native.Observation]){@($observation.CopyQueryProbesTo($v,$NowUtc,$MaxAgeDays))}elseif($null -eq $probes){@()}elseif($probes -is [Collections.IDictionary]){$probes.Keys}else{$probes.PSObject.Properties.Name}
            foreach($probeId in $probeIds){
                $field=$probeFields[[string]$probeId];if($null -eq $field){continue}
                $result=Get-DomeniaMemberValue $probes $field.ProbeId
                if($null -eq $result -or [string](Get-DomeniaMember $result 'Error') -or [string](Get-DomeniaMember $result 'Skipped')){continue}
                $probeAt=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaMember $result 'CheckedUtc'))
                if($null -eq $probeAt -or $probeAt -gt $NowUtc.AddMinutes(5) -or ($NowUtc-$probeAt).TotalDays -gt $MaxAgeDays){continue}
                $probe=$probeCatalog[$field.ProbeId]
                if([bool](Get-DomeniaMember $result 'Truncated' $false) -and $probe.Mode -eq 'All'){continue}
                $values=@(Get-DomeniaProbeValues -Probe $probe -Result $result)
                if(-not $values.Count){continue}
                $v['_probe:'+$field.ProbeId]=[object[]]$values
                if($field.Kind -eq 'Number'){$number=ConvertTo-DomeniaProbeNumber $values[0];if($null -ne $number){$v[$field.Id]=[double]$number}}
                else{$v[$field.Id]=[string]($values -join ' ; ')}
            }
        }
        $records.Add([M4D.Admin.Common.Query.QueryRecord]::new($(if($guid){$guid.ToLowerInvariant()}else{$dn.ToLowerInvariant()}),$v))
    }
    return ,$records
}
function ConvertTo-DomeniaQueryGridRows {
    param($Rows,[string[]]$Fields=@())
    foreach($record in $Rows){
        $v=$record.Values
        $row=[ordered]@{Id=$record.Id;PresenceLabel=$v['presenceBucket'];PresenceState=$(switch([string]$v['presenceBucket']){'En ligne'{'●'};'Sans reponse'{'○'};default{'?'}});PresenceBrush=$(switch([string]$v['presenceBucket']){'En ligne'{'#22C55E'};'Sans reponse'{'#F59E0B'};default{'#94A3B8'}});name=$v['name'];StateLabel=$(if($v['active']){'Actif'}else{'Désactivé'});OS=$(if($v.ContainsKey('os')){$v['os']}else{'Non renseigné'});Version=$(if($v.ContainsKey('version')){$v['version']}else{'Non lue'});LogonDays=$(if($v.ContainsKey('logonDays')){[Math]::Floor([double]$v['logonDays'])}else{'Inconnue'});Observation=$(if($v.ContainsKey('checkedDays')){([Math]::Round([double]$v['checkedDays'],1).ToString()+' j')}else{'Non recueillie / expirée'});distinguished_name=$v['dn']}
        $details=[Collections.Generic.List[string]]::new()
        foreach($field in $Fields){$value=if($v.ContainsKey($field)){$v[$field]}else{'Inconnu'};$details.Add($field+' = '+[string]$value)}
        $row['QueryValues']=[string]::Join(' · ',$details.ToArray())
        [pscustomobject]$row
    }
}

function Select-DomeniaQueryPopulation {
    param($Records,$Recipe)
    # PowerShell conditionals/pipelines can unwrap a generic list into Object[].
    # The shared DLL requires IEnumerable<QueryRecord>, including empty/singleton
    # populations. Preserve an already typed list and adapt other enumerables once.
    if ($Records -isnot [Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]) {
        $typed=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
        foreach ($record in $Records) { $typed.Add($record) }
        $Records=$typed
    }
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $probeSelection=ConvertTo-DomeniaQueryProbeSelection $Recipe
    $identities=Get-DomeniaQueryIdentitySelection $Recipe
    if(-not $refinements.Count -and $null -eq $probeSelection -and $null -eq $identities){return ,$Records}
    $compiled=ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements)
    $selected=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
    foreach($record in $Records){
        if($null -ne $identities -and -not $identities.Contains($record.Id.Trim().Trim('{','}'))){continue}
        if(($null -eq $probeSelection -or $probeSelection.Matches($record.Values)) -and $compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$selected.Add($record)}
    }
    return ,$selected
}
function Get-DomeniaQueryMatchIds {
    param($Records,$Recipe)
    $compiled=ConvertTo-DomeniaCompiledQuery $Recipe
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @())
    $refined=if($refinements.Count){ConvertTo-DomeniaCompiledQuery (New-DomeniaQueryRecipe -Clauses $refinements)}else{$null}
    $ids=@{}
    $population=Select-DomeniaQueryPopulation $Records $Recipe
    foreach($record in $population){
        if($null -ne $refined -and $refined.Evaluate($record.Values) -ne [M4D.Admin.Common.Query.MatchState]::Match){continue}
        if($compiled.Evaluate($record.Values) -eq [M4D.Admin.Common.Query.MatchState]::Match){$ids[$record.Id.Trim().Trim('{','}').ToLowerInvariant()]=$true}
    }
    return $ids
}
function Measure-DomeniaQueryWidget {
    param($Records,$Recipe)
    $population=Select-DomeniaQueryPopulation $Records $Recipe
    $query=ConvertTo-DomeniaCompiledQuery $Recipe
    $counts=$query.Execute($population,[M4D.Admin.Common.Query.QueryOptions]@{Limit=0})
    $groupBy=[string](Get-DomeniaMember $Recipe 'GroupBy');$items=@()
    if($groupBy){
        # Bounded distinct categories. Exceeding the bound is explicit, never a silently sampled chart.
        $buckets=@($query.CountBy($population,$groupBy,1024));$known=@($buckets|Where-Object{-not $_.Missing}|Sort-Object Count -Descending)
        $top=@($known|Select-Object -First 10);$items=@(foreach($bucket in $top){[pscustomobject]@{Label=[string]$bucket.Value;Value=[double]$bucket.Count;Select=[pscustomobject]@{Label=[string]$bucket.Value;Field=$groupBy;Missing=$false;Value=$bucket.Value;Excluded=@()}}})
        $others=0L;foreach($bucket in @($known|Select-Object -Skip 10)){$others+=$bucket.Count}
        if($others){$items+=@([pscustomobject]@{Label='Autres valeurs';Value=[double]$others;Select=[pscustomobject]@{Label='Autres valeurs';Field=$groupBy;Missing=$false;Value=$null;Excluded=@($top|ForEach-Object{$_.Value})}})}
        foreach($bucket in @($buckets|Where-Object{$_.Missing})){$items+=@([pscustomobject]@{Label='Valeur inconnue';Value=[double]$bucket.Count;Select=[pscustomobject]@{Label='Valeur inconnue';Field=$groupBy;Missing=$true;Value=$null;Excluded=@()}})}
    }
    return [pscustomobject]@{Total=$counts.Total;Matched=$counts.Matched;Unknown=$counts.Unknown;NotMatched=$counts.NotMatched;GroupBy=$groupBy;Items=$items;Error=''}
}
function New-DomeniaQuerySegmentRecipe {
    param($Recipe,$Selection)
    $refinements=@(Get-DomeniaMember $Recipe 'Refinements' @());$field=[string]$Selection.Field
    if([bool]$Selection.Missing){$refinements+=@([pscustomobject]@{Field=$field;Operator='IsMissing';Value=$null})}
    elseif(@($Selection.Excluded).Count){
        $refinements+=@([pscustomobject]@{Field=$field;Operator='IsPresent';Value=$null})
        foreach($value in @($Selection.Excluded)){$refinements+=@([pscustomobject]@{Field=$field;Operator='NotEqual';Value=$value})}
    }else{$refinements+=@([pscustomobject]@{Field=$field;Operator='Equal';Value=$Selection.Value})}
    $name=[string]$Recipe.Name+' · '+[string]$Selection.Label;if($name.Length -gt 120){$name=$name.Substring(0,120)}
    $result=New-DomeniaQueryRecipe -Name $name -Junction $Recipe.Junction -Clauses @($Recipe.Clauses) -Refinements $refinements -GroupBy ([string](Get-DomeniaMember $Recipe 'GroupBy')) -ProbeSelection (Get-DomeniaMemberValue $Recipe 'ProbeSelection') -ObjectIds (Get-DomeniaMemberValue $Recipe 'ObjectIds')
    [void](ConvertTo-DomeniaCompiledQuery $result)
    return $result
}
