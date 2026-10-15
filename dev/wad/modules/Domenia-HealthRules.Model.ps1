# Pure dashboard policy. No network, settings or WPF access; a captured policy is passed to both SQL plan and view.
function Get-DomeniaHealthRuleCatalog {
    @'
eos.ended|Windows en fin de service
eos.soon|Windows proche de sa fin de service
stale|Connexion au domaine ancienne
never|Date de connexion au domaine absente
pwdold|Mot de passe du compte machine ancien
laps.none|Expiration LAPS non visible
laps.expired|Expiration LAPS dépassée
bitlocker.none|Protection ou clé BitLocker non visible
bitlocker.suspended|Protection BitLocker suspendue
secureboot|Secure Boot désactivé (UEFI)
certificates|Certificats machine expirés ou proches de lʼéchéance
lowdisk|Disque presque plein
disk.tight|Espace disque à surveiller
uptime|Redémarrage ancien
memory|Mémoire très utilisée
battery|Batterie faible
ad.disabled|Compte ordinateur désactivé
clock|Décalage de lʼhorloge
firewall|Pare-feu désactivé
reboot|Redémarrage en attente
services|Services automatiques arrêtés
devices|Périphériques en erreur
drivers|Pilotes non signés
hotfix|Correctifs anciens
events|Événements système critiques
'@ -split "`n" | ForEach-Object {$p=$_.Trim().Split('|');if($p.Count -eq 2){[pscustomobject]@{Id=$p[0];Name=$p[1]}}}
}
function Get-DomeniaHealthThresholdCatalog {
    @(
        [pscustomobject]@{Id='StaleDays';Name='Connexion AD ancienne (jours, date approximative)';Default=90;Minimum=1;Maximum=3650}
        [pscustomobject]@{Id='PasswordDays';Name='Mot de passe machine ancien (jours)';Default=60;Minimum=1;Maximum=3650}
        [pscustomobject]@{Id='UptimeDays';Name='Redémarrage ancien (jours)';Default=30;Minimum=1;Maximum=365}
        [pscustomobject]@{Id='DiskFreeAlert';Name='Disque critique : espace libre inférieur à (%)';Default=10;Minimum=1;Maximum=99}
        [pscustomobject]@{Id='DiskFreeWarn';Name='Disque à surveiller : espace libre inférieur à (%)';Default=20;Minimum=1;Maximum=100}
        [pscustomobject]@{Id='MemoryUsedWarn';Name='Mémoire utilisée supérieure à (%)';Default=90;Minimum=1;Maximum=100}
        [pscustomobject]@{Id='BatteryWarn';Name='Batterie inférieure à (%)';Default=20;Minimum=1;Maximum=100}
    )
}
function Get-DomeniaHealthValue {
    param($Object,[string]$Name,$Default=$null,[switch]$NoEnumerate)
    if($null -eq $Object){return $Default}
    if($Object -is [Collections.IDictionary]){if($Object.Contains($Name)){if($NoEnumerate){return ,$Object[$Name]};return $Object[$Name]};return $Default}
    $p=$Object.PSObject.Properties[$Name];if($null -ne $p){if($NoEnumerate){return ,$p.Value};return $p.Value};return $Default
}
function ConvertTo-DomeniaHealthPolicy {
    param($Value=$null,[switch]$Strict)
    if($Value -is [string]){try{$Value=$Value|ConvertFrom-Json -ErrorAction Stop}catch{if($Strict){throw 'Regles de sante illisibles.'};$Value=$null}}
    $limits=[ordered]@{};$source=Get-DomeniaHealthValue $Value 'Thresholds'
    foreach($rule in @(Get-DomeniaHealthThresholdCatalog)){
        $n=0;$raw=Get-DomeniaHealthValue $source $rule.Id $rule.Default
        if(-not [int]::TryParse([string]$raw,[ref]$n) -or $n -lt $rule.Minimum -or $n -gt $rule.Maximum){if($Strict){throw ($rule.Name+' : valeur attendue de '+$rule.Minimum+' a '+$rule.Maximum+'.')};$n=$rule.Default}
        $limits[$rule.Id]=$n
    }
    if($limits.DiskFreeAlert -gt $limits.DiskFreeWarn){if($Strict){throw 'Le seuil disque critique doit etre inferieur ou egal au seuil de surveillance.'};$limits.DiskFreeAlert=10;$limits.DiskFreeWarn=20}
    $known=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$known[$r.Id]=$true}
    $disabled=[Collections.Generic.List[string]]::new()
    foreach($id in @(Get-DomeniaHealthValue $Value 'DisabledRules' @())){if($known.ContainsKey([string]$id) -and -not $disabled.Contains([string]$id)){$disabled.Add([string]$id)}}
    $custom=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($r in @(Get-DomeniaHealthValue $Value 'CustomRules' @())){
        $id=[string](Get-DomeniaHealthValue $r 'Id' '');$name=([string](Get-DomeniaHealthValue $r 'Name' '')).Trim();$measure=[string](Get-DomeniaHealthValue $r 'Measure' '');$op=[string](Get-DomeniaHealthValue $r 'Operator' '');$severity=[string](Get-DomeniaHealthValue $r 'Severity' 'Warn');$threshold=0.0
        $valid=$id -cmatch '^custom\.[0-9a-f]{32}$' -and $name.Length -ge 1 -and $name.Length -le 100 -and $name -notmatch '[\p{Cc}]' -and $measure -in @('DiskFree','UptimeDays','MemoryUsed') -and $op -in @('LessThan','GreaterThan') -and $severity -in @('Warn','Alert') -and [double]::TryParse([string](Get-DomeniaHealthValue $r 'Threshold' ''),[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$threshold) -and -not [double]::IsNaN($threshold) -and -not [double]::IsInfinity($threshold) -and $threshold -ge 0 -and $threshold -le $(if($measure -eq 'UptimeDays'){3650}else{100}) -and -not $seen.ContainsKey($id)
        if(-not $valid -or $custom.Count -ge 32){if($Strict){throw 'Regle personnalisee invalide (32 maximum, seuil selon la mesure).'};continue}
        $enabled=Get-DomeniaHealthValue $r 'Enabled' $true
        if($enabled -isnot [bool]){if($Strict){throw 'Activation de regle personnalisee invalide.'};$enabled=$true}
        $custom.Add([pscustomobject]@{Id=$id;Name=$name;Measure=$measure;Operator=$op;Threshold=$threshold;Severity=$severity;Enabled=$enabled});$seen[$id]=$true
    }
    $suspensions=ConvertTo-DomeniaHealthSuspensions (Get-DomeniaHealthValue $Value 'Suspensions' @()) -Strict:$Strict
    $at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $Value 'EvaluatedAtUtc' ''));if($null -eq $at){$at=[datetime]::UtcNow}
    $result=[pscustomobject]@{Version=1;Thresholds=[pscustomobject]$limits;DisabledRules=$disabled.ToArray();CustomRules=$custom.ToArray();Suspensions=$suspensions;EvaluatedAtUtc=$at.ToString('o')}
    $origin=Get-DomeniaHealthValue $Value 'Origin';if($null -ne $origin){$result|Add-Member -NotePropertyName Origin -NotePropertyValue $origin}
    $result.PSObject.TypeNames.Insert(0,'Domenia.HealthPolicy')
    return $result
}
function Test-DomeniaHealthRuleEnabled {
    param($Policy,[string]$RuleId,[switch]$IgnoreSuspension)
    if(-not $IgnoreSuspension -and @(Get-DomeniaHealthValue $Policy 'Suspensions' @()).Count -gt 0 -and $null -ne (Get-DomeniaHealthSuspension $Policy $RuleId)){return $false}
    if(-not $RuleId){return $true}
    if($RuleId.StartsWith('custom.',[StringComparison]::Ordinal)){
        $rules=@((Get-DomeniaHealthValue $Policy 'CustomRules' @())|Where-Object{[string]$_.Id -ceq $RuleId})
        return ($rules.Count -eq 1 -and [bool]$rules[0].Enabled)
    }
    return (@(Get-DomeniaHealthValue $Policy 'DisabledRules' @()) -notcontains $RuleId)
}
function Add-DomeniaCustomHealthAttention {
    param($Data,[object[]]$Measures=@())
    foreach($rule in @($Data.HealthPolicy.CustomRules)){
        if(-not (Test-DomeniaHealthRuleEnabled $Data.HealthPolicy $rule.Id)){continue}
        $matched=[Collections.Generic.List[object]]::new();$seen=@{};$count=0
        foreach($measurement in $Measures){
            $raw=Get-DomeniaHealthValue $measurement $rule.Measure
            if($null -eq $raw){continue}
            $n=0.0;if(-not [double]::TryParse([string]$raw,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$n) -or [double]::IsNaN($n) -or [double]::IsInfinity($n)){continue}
            $hit=if($rule.Operator -eq 'LessThan'){$n -lt $rule.Threshold}else{$n -gt $rule.Threshold}
            if(-not $hit){continue}
            $target=Get-DomeniaHealthValue $measurement 'Target'
            if($null -ne $target){$id=[string]$target.object_guid;if(-not $id -or $seen.ContainsKey($id)){continue};$seen[$id]=$true;$matched.Add($target)}
            $count++
        }
        if($count){Add-DomeniaBoardAttention -Data $Data -Level $rule.Severity -Text ($rule.Name+' : '+$count+' poste(s) concerné(s).') -Point $rule.Id -Machines $matched.ToArray()}
    }
}

function Update-DomeniaFleetHealthPopulation {
    # Build score membership from the enabled rules' exact canonical targets, never from stale pre-filter counters.
    param($Data,[object[]]$Attention=@())
    $groups=@{};foreach($g in @($Data.Last.Groups)){$groups[[string]$g.gid]=$g}
    $problemGroups=@{};$problemIds=@{}
    foreach($point in $Attention){if($point.Level -notin @('Alert','Warn')){continue};foreach($g in @($point.Groups)){$problemGroups[[string]$g]=$true};foreach($m in @($point.Machines)){if($m.object_guid){$problemIds[[string]$m.object_guid]=$true}}}
    $healthy=[Collections.Generic.List[object]]::new();$problems=[Collections.Generic.List[object]]::new();$unknown=[Collections.Generic.List[object]]::new()
    $p=$Data.HealthPolicy
    $rules=@('eos.ended','eos.soon','stale','never','pwdold','laps.none','laps.expired','bitlocker.none','lowdisk','disk.tight','uptime')
    $ruleOn=@{};foreach($id in $rules){$ruleOn[$id]=Test-DomeniaHealthRuleEnabled $p $id}
    $customMeasures=@{};$customCount=0;foreach($rule in @($p.CustomRules)){if(Test-DomeniaHealthRuleEnabled $p $rule.Id){$customMeasures[[string]$rule.Measure]=$true;$customCount++}}
    $enabled=@($ruleOn.Values|Where-Object{$_}).Count+$customCount
    $needLogon=$ruleOn['stale'] -or $ruleOn['never'];$needDisk=$ruleOn['lowdisk'] -or $ruleOn['disk.tight'] -or $customMeasures.ContainsKey('DiskFree');$needBoot=$ruleOn['uptime'] -or $customMeasures.ContainsKey('UptimeDays')
    $groupKnown=@{};$lifecycleKnown=[bool](Get-DomeniaHealthValue $Data 'LifecycleKnown' $false)
    foreach($g in @($Data.Last.Groups)){
        $known=($enabled -gt 0 -and -not $customMeasures.ContainsKey('MemoryUsed')) # Light fleet inventory has no used-memory measure.
        if($ruleOn['eos.ended'] -or $ruleOn['eos.soon']){$known=$known -and [bool]([string]$g.ver) -and [bool]([string]$g.os) -and $lifecycleKnown}
        if($ruleOn['pwdold']){$known=$known -and [string]$g.pw -in @('R','O')}
        if($ruleOn['laps.none'] -or $ruleOn['laps.expired']){$known=$known -and [string]$g.lk -in @('O','E','X')}
        if($ruleOn['bitlocker.none']){$known=$known -and [string]$g.bk -in @('K','X')}
        $groupKnown[[string]$g.gid]=$known
    }
    $knownInventoryMap=Get-DomeniaHealthValue $Data 'HealthInventoryKnown'
    foreach($target in @($Data.Last.Targets)){
        if($target.st -ne 'A'){continue}
        if($problemGroups.ContainsKey([string]$target.gid) -or $problemIds.ContainsKey([string]$target.object_guid)){$problems.Add($target);continue}
        $known=[bool]$groupKnown[[string]$target.gid]
        if($known -and $needLogon){$logon=[datetime]::MinValue;$known=[datetime]::TryParseExact([string]$target.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$logon) -and $logon -le $Data.Freshness.ComputedAtUtc.Date}
        if($known -and ($needDisk -or $needBoot)){
            if($null -ne $knownInventoryMap){
                $validity=$knownInventoryMap[[string]$target.object_guid];$known=($null -ne $validity -and (-not $needDisk -or $validity.Disk) -and (-not $needBoot -or $validity.Boot))
            }else{
            $observation=$Data.Observations[([string]$target.distinguished_name).ToLowerInvariant()];$inventory=Get-DomeniaHealthValue $observation 'Inventory'
            $known=$null -ne $inventory
            if($known -and $needDisk){$size=[double](Get-DomeniaHealthValue $inventory 'DiskSize' 0);$free=Get-DomeniaHealthValue $inventory 'DiskFree';$known=$size -gt 0 -and $null -ne $free -and [double]$free -ge 0 -and [double]$free -le $size}
            if($known -and $needBoot){$boot=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $inventory 'LastBootUtc' ''));$known=$null -ne $boot -and $boot -le $Data.Freshness.ComputedAtUtc}
            if($known){$known=(Test-DomeniaObservationAge -CheckedUtc (Get-DomeniaHealthValue $inventory 'CheckedUtc') -NowUtc $Data.Freshness.ComputedAtUtc) -ne 'Expired'}
            }
        }
        if($known){$healthy.Add($target)}else{$unknown.Add($target)}
    }
    $Data.Population.Healthy=$healthy.Count
    $Data.Population|Add-Member -NotePropertyName Unassessed -NotePropertyValue $unknown.Count -Force
    $Data.Last.HealthyTargets=$healthy.ToArray();$Data.Last.ProblemTargets=$problems.ToArray()
    $Data.Last|Add-Member -NotePropertyName UnknownTargets -NotePropertyValue $unknown.ToArray() -Force
    $Data|Add-Member -NotePropertyName HealthCoverage -NotePropertyValue ([string]($healthy.Count+$problems.Count)+' évalué(s) / '+$Data.Population.Total+' comptes activés ; '+$unknown.Count+' incomplet(s)') -Force
    if($null -ne $Data.PSObject.Properties['Snapshot']){$Data.Snapshot.Figures.Healthy=$healthy.Count;$Data.Snapshot.Figures.Problems=$problems.Count}
}

function Get-DomeniaHealthExplanation {
    # Counts are unique within each rule. A machine can contribute to several rules: rows are never summed.
    param($Data)
    $policy=$Data.HealthPolicy;$names=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$names[$r.Id]=$r.Name}
    $effective=@(Get-DomeniaHealthValue $Data 'EffectiveHealthPolicies' @());if(-not $effective.Count){$effective=@([pscustomobject]@{ScopeDn='';Policy=$policy;Count=0})}
    foreach($e in $effective){foreach($r in @($e.Policy.CustomRules)){$names[$r.Id]=$r.Name}}
    $suspendedIds=@{}
    $rows=[Collections.Generic.List[object]]::new();$fleet=([string]$Data.Board -eq 'Fleet')
    $targets=if($fleet){@(Get-DomeniaHealthValue (Get-DomeniaHealthValue $Data 'Last') 'Targets' @())}else{@()};$byGroup=@{}
    if($fleet){foreach($m in $targets){$key=[string]$m.gid;if(-not $byGroup.ContainsKey($key)){$byGroup[$key]=[Collections.Generic.List[object]]::new()};$byGroup[$key].Add($m)}}
    $points=@{};foreach($point in @($Data.Attention)){
        if($point.Level -notin @('Alert','Warn')){continue};$key=[string]$point.Point;if(-not $key){$key='unspecified'}
        if(-not $names.ContainsKey($key)){$names[$key]=$key}
        if(-not $points.ContainsKey($key)){$points[$key]=[Collections.Generic.List[object]]::new()};$points[$key].Add($point)
    }
    foreach($id in @($names.Keys|Sort-Object)){
        $suspended=Get-DomeniaHealthSuspension $policy $id;$enabled=Test-DomeniaHealthRuleEnabled $policy $id;$ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$alerts=0;$warnings=0
        foreach($point in @($points[$id])){
            if($null -eq $point){continue};if($point.Level -eq 'Alert'){$alerts++}else{$warnings++}
            foreach($target in @($point.Machines)){if($null -ne $target -and [string]$target.object_guid){[void]$ids.Add([string]$target.object_guid)}}
            foreach($gid in @($point.Groups)){foreach($target in @($byGroup[[string]$gid])){if($null -ne $target -and [string]$target.object_guid){[void]$ids.Add([string]$target.object_guid)}}}
        }
        $count=if($fleet){$ids.Count}elseif($alerts -or $warnings){1}else{0}
        $statuses=@{};$reasons=[Collections.Generic.List[string]]::new();$suspendedMachines=0
        foreach($e in $effective){$pause=Get-DomeniaHealthSuspension $e.Policy $id;$on=Test-DomeniaHealthRuleEnabled $e.Policy $id;$status=if($null -ne $pause){'Suspendue'}elseif($on){'Activée'}else{'Désactivée'};$statuses[$status]=$true
            if($null -ne $pause){$suspendedIds[$id]=$true;$suspendedMachines+=[int]$e.Count;$reasons.Add('Jusquʼau '+$pause.UntilUtc+' : '+$pause.Reason)}
        }
        $status=if($statuses.Count -gt 1){'Selon lʼOU'}else{@($statuses.Keys)[0]}
        $effect=if($status -eq 'Désactivée'){'Exclue du score'}elseif($status -eq 'Suspendue'){'Suspendue : '+($reasons -join ' ; ')}elseif($fleet){'Postes concernés (sans cumul)'+$(if($suspendedMachines){' ; '+$suspendedMachines+' poste(s) exempté(s) temporairement'})}else{'-'+(25*$alerts+10*$warnings)+' point(s)'}
        $rows.Add([pscustomobject]@{Id=$id;Rule=[string]$names[$id];Status=$status;Machines=$count;Effect=$effect;Guids=@($ids)})
    }
    $enabledCount=@($rows|Where-Object{$_.Status -in @('Activée','Selon lʼOU')}).Count
    $population=Get-DomeniaHealthValue $Data 'Population';$unknown=[int](Get-DomeniaHealthValue $population 'Unassessed' 0);$total=[int](Get-DomeniaHealthValue $population 'Total' 0);$healthy=[int](Get-DomeniaHealthValue $population 'Healthy' 0)
    $summary=if($fleet){'Score = part des postes évalués sans problème : '+$healthy+' / '+([Math]::Max(0,$total-$unknown))+'. '+$unknown+' poste(s) incomplet(s) exclus du dénominateur, jamais considérés sains. Un poste touché par plusieurs règles compte une fois dans le score.'}else{'Score = 100 − 25 par point critique − 10 par point à surveiller, minimum 0. Un contrôle absent ne prouve pas un bon état ; une évaluation incomplète est signalée.'}
    $suspendedCount=$suspendedIds.Count
    $scopeRows=@($effective|ForEach-Object{$scopePolicy=$_.Policy;[pscustomobject]@{Scope=$(if($_.ScopeDn){$_.ScopeDn}else{'Domaine : règles par défaut'});Machines=$_.Count;Suspended=@($_.Policy.Suspensions|Where-Object{$null -ne (Get-DomeniaHealthSuspension $scopePolicy $_.RuleId)}).Count;Thresholds=('AD '+$_.Policy.Thresholds.StaleDays+' j · mot de passe '+$_.Policy.Thresholds.PasswordDays+' j · disque '+$_.Policy.Thresholds.DiskFreeAlert+'/'+$_.Policy.Thresholds.DiskFreeWarn+' %')}})
    [pscustomobject]@{Summary=$summary;ActiveRules=$enabledCount;DisabledRules=@($rows|Where-Object{$_.Status -eq 'Désactivée'}).Count;SuspendedRules=$suspendedCount;Policies=$scopeRows;Rows=$rows.ToArray();Population=$total;Unknown=$unknown;Scope=([string](Get-DomeniaHealthValue (Get-DomeniaHealthValue $Data 'Last') 'Scope' ''))}
}


function Test-DomeniaHealthScope {
    param([string]$ScopeDn,[string]$DomainDn)
    if(-not $DomainDn -or $DomainDn.Length -gt 2048 -or $DomainDn -notmatch '^(?i:DC)=' -or $DomainDn -match '[\p{Cc}]'){return $false}
    if(-not $ScopeDn -or $ScopeDn -ieq $DomainDn){return $true}
    if($ScopeDn.Length -gt 4096 -or $ScopeDn -notmatch '^(?i:OU|CN)=' -or $ScopeDn -match '[\p{Cc}]'){return $false}
    $parent=$ScopeDn
    for($depth=0;$parent -and $depth -lt 128;$depth++){if($parent -ieq $DomainDn){return $true};$parent=Get-DomeniaRawDnParent $parent}
    return $false
}
function ConvertTo-DomeniaHealthPolicyBook {
    param($Value,[string]$DomainDn,[switch]$Strict)
    if(-not (Test-DomeniaHealthScope '' $DomainDn)){throw 'Domaine de politique invalide.'}
    if($Value -is [string]){try{$Value=$Value|ConvertFrom-Json -ErrorAction Stop}catch{if($Strict){throw 'Politiques de santé illisibles.'};$Value=$null}}
    $savedDomain=[string](Get-DomeniaHealthValue $Value 'DomainDn' '')
    if($savedDomain -and $savedDomain -ine $DomainDn){throw 'Politique de santé appartenant à un autre domaine.'}
    $default=ConvertTo-DomeniaHealthPolicy (Get-DomeniaHealthValue $Value 'Default') -Strict:$Strict
    $scopes=[Collections.Generic.List[object]]::new();$seen=@{}
    foreach($record in @(Get-DomeniaHealthValue $Value 'Scopes' @())){
        $dn=([string](Get-DomeniaHealthValue $record 'ScopeDn' '')).Trim()
        if(-not $dn -or $dn -notmatch '^(?i:OU)=' -or -not (Test-DomeniaHealthScope $dn $DomainDn) -or $seen.ContainsKey($dn) -or $scopes.Count -ge 512){if($Strict){throw 'Exception dʼOU invalide ou dupliquée (512 maximum).'};continue}
        $overrides=Get-DomeniaHealthValue $record 'Overrides';$thresholds=[ordered]@{};$ruleStates=[ordered]@{}
        foreach($limit in @(Get-DomeniaHealthThresholdCatalog)){$raw=Get-DomeniaHealthValue (Get-DomeniaHealthValue $overrides 'Thresholds') $limit.Id;if($null -ne $raw){$n=0;if(-not [int]::TryParse([string]$raw,[ref]$n) -or $n -lt $limit.Minimum -or $n -gt $limit.Maximum){if($Strict){throw 'Seuil dʼOU invalide.'};continue};$thresholds[$limit.Id]=$n}}
        foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$raw=Get-DomeniaHealthValue (Get-DomeniaHealthValue $overrides 'RuleStates') $rule.Id;if($null -ne $raw){if($raw -isnot [bool]){if($Strict){throw 'Activation dʼOU invalide.'};continue};$ruleStates[$rule.Id]=$raw}}
        $custom=Get-DomeniaHealthValue $overrides 'CustomRules' -NoEnumerate;if($null -ne $custom){$custom=(ConvertTo-DomeniaHealthPolicy @{CustomRules=$custom} -Strict:$Strict).CustomRules}
        $suspensions=Get-DomeniaHealthValue $overrides 'Suspensions' -NoEnumerate;if($null -ne $suspensions){$suspensions=ConvertTo-DomeniaHealthSuspensions $suspensions -Strict:$Strict}
        $scopes.Add([pscustomobject]@{ScopeDn=$dn;Overrides=[pscustomobject]@{Thresholds=[pscustomobject]$thresholds;RuleStates=[pscustomobject]$ruleStates;CustomRules=$custom;Suspensions=$suspensions}});$seen[$dn]=$true
    }
    return [pscustomobject]@{Version=1;DomainDn=$DomainDn.Trim();Default=$default;Scopes=$scopes.ToArray()}
}
function Resolve-DomeniaHealthPolicy {
    param($Book,[string]$ScopeDn='',[switch]$SkipExact)
    if(-not (Test-DomeniaHealthScope $ScopeDn ([string]$Book.DomainDn))){throw 'OU de politique hors du domaine.'}
    $policy=ConvertTo-DomeniaHealthPolicy $Book.Default;$thresholds=[ordered]@{};foreach($p in $policy.Thresholds.PSObject.Properties){$thresholds[$p.Name]=$p.Value}
    $on=@{};foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$on[$rule.Id]=Test-DomeniaHealthRuleEnabled $policy $rule.Id -IgnoreSuspension}
    $custom=$policy.CustomRules;$suspensions=$policy.Suspensions;$parents=[Collections.Generic.List[string]]::new();$cursor=$ScopeDn
    while($cursor -and $cursor -ine $Book.DomainDn){if(-not ($SkipExact -and $cursor -ieq $ScopeDn)){$parents.Add($cursor)};$cursor=Get-DomeniaRawDnParent $cursor}
    $byDn=@{};foreach($record in @($Book.Scopes)){$byDn[[string]$record.ScopeDn]=$record}
    $origins=[Collections.Generic.List[string]]::new();$overrides=[Collections.Generic.List[string]]::new()
    for($i=$parents.Count-1;$i -ge 0;$i--){
        $record=$byDn[$parents[$i]];if($null -eq $record){continue};$origins.Add([string]$record.ScopeDn)
        foreach($p in $record.Overrides.Thresholds.PSObject.Properties){$thresholds[$p.Name]=$p.Value;$overrides.Add($p.Name)}
        foreach($p in $record.Overrides.RuleStates.PSObject.Properties){$on[$p.Name]=[bool]$p.Value;$overrides.Add($p.Name)}
        if($null -ne $record.Overrides.CustomRules){$custom=@($record.Overrides.CustomRules);$overrides.Add('CustomRules')}
        if($null -ne $record.Overrides.Suspensions){$suspensions=@($record.Overrides.Suspensions);$overrides.Add('Suspensions')}
    }
    $resolved=ConvertTo-DomeniaHealthPolicy @{Thresholds=$thresholds;DisabledRules=@($on.Keys|Where-Object{-not $on[$_]});CustomRules=$custom;Suspensions=$suspensions} -Strict
    $resolved|Add-Member -NotePropertyName Origin -NotePropertyValue ([pscustomobject]@{DomainDn=$Book.DomainDn;ScopeDn=$ScopeDn;SourceDn=$(if($origins.Count){$origins[$origins.Count-1]}else{''});Ancestors=$origins.ToArray();OverriddenFields=@($overrides|Sort-Object -Unique);Local=($byDn.ContainsKey($ScopeDn) -and -not $SkipExact)})
    return $resolved
}
function Set-DomeniaHealthScopePolicy {
    # Store only differences against the parent, so later inherited changes remain inherited.
    param($Book,[string]$ScopeDn='',$Policy,[switch]$Remove)
    if(-not (Test-DomeniaHealthScope $ScopeDn ([string]$Book.DomainDn)) -or ($ScopeDn -and $ScopeDn -notmatch '^(?i:OU)=')){throw 'OU de politique invalide.'}
    $next=ConvertTo-DomeniaHealthPolicyBook ($Book|ConvertTo-Json -Depth 15 -Compress) $Book.DomainDn -Strict
    if(-not $ScopeDn){if($Remove){throw 'La politique par défaut ne peut pas être supprimée.'};$next.Default=ConvertTo-DomeniaHealthPolicy $Policy -Strict;foreach($record in @($next.Scopes)){[void](Resolve-DomeniaHealthPolicy $next $record.ScopeDn)};return $next}
    $next.Scopes=@($next.Scopes|Where-Object{$_.ScopeDn -ine $ScopeDn})
    if($Remove){return $next}
    $parent=Resolve-DomeniaHealthPolicy $next $ScopeDn;$value=ConvertTo-DomeniaHealthPolicy $Policy -Strict
    $thresholds=[ordered]@{};foreach($p in $value.Thresholds.PSObject.Properties){if($p.Value -ne $parent.Thresholds.($p.Name)){$thresholds[$p.Name]=$p.Value}}
    $ruleStates=[ordered]@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$v=Test-DomeniaHealthRuleEnabled $value $r.Id -IgnoreSuspension;if($v -ne (Test-DomeniaHealthRuleEnabled $parent $r.Id -IgnoreSuspension)){$ruleStates[$r.Id]=$v}}
    $custom=$null;if(($value.CustomRules|ConvertTo-Json -Depth 8 -Compress) -cne ($parent.CustomRules|ConvertTo-Json -Depth 8 -Compress)){$custom=@($value.CustomRules)}
    $suspensions=$null;if(($value.Suspensions|ConvertTo-Json -Depth 8 -Compress) -cne ($parent.Suspensions|ConvertTo-Json -Depth 8 -Compress)){$suspensions=@($value.Suspensions)}
    if($thresholds.Count -or $ruleStates.Count -or $null -ne $custom -or $null -ne $suspensions){$next.Scopes+=,[pscustomobject]@{ScopeDn=$ScopeDn;Overrides=[pscustomobject]@{Thresholds=[pscustomobject]$thresholds;RuleStates=[pscustomobject]$ruleStates;CustomRules=$custom;Suspensions=$suspensions}}}
    $next=ConvertTo-DomeniaHealthPolicyBook $next $Book.DomainDn -Strict
    foreach($record in @($next.Scopes)){[void](Resolve-DomeniaHealthPolicy $next $record.ScopeDn)}
    return $next
}

function ConvertTo-DomeniaHealthSuspensions {
    param([object[]]$Values=@(),[switch]$Strict)
    $result=[Collections.Generic.List[object]]::new();$seen=@{};$known=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$known[$r.Id]=$true}
    foreach($v in $Values){
        if($null -eq $v){continue};$id=[string](Get-DomeniaHealthValue $v 'RuleId' '');$reason=([string](Get-DomeniaHealthValue $v 'Reason' '')).Trim();$raw=[string](Get-DomeniaHealthValue $v 'UntilUtc' '')
        $until=[datetimeoffset]::MinValue;$valid=($known.ContainsKey($id) -or $id -cmatch '^custom\.[0-9a-f]{32}$') -and $reason.Length -ge 3 -and $reason.Length -le 240 -and $reason -notmatch '[\p{Cc}]' -and $raw -match '(Z|\+00:00)$' -and [datetimeoffset]::TryParse($raw,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$until) -and $until.Year -ge 2000 -and $until.Year -le 9998 -and -not $seen.ContainsKey($id) -and $result.Count -lt 64
        if(-not $valid){if($Strict){throw 'Suspension invalide : contrôle unique, motif de 3 à 240 caractères et échéance UTC obligatoires (64 maximum).'};continue}
        $seen[$id]=$true;$result.Add([pscustomobject]@{RuleId=$id;Reason=$reason;UntilUtc=$until.UtcDateTime.ToString('o')})
    }
    return ,$result.ToArray()
}
function Get-DomeniaHealthSuspension {
    param($Policy,[string]$RuleId,[datetime]$NowUtc=[datetime]::MinValue)
    if($NowUtc -eq [datetime]::MinValue){$at=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $Policy 'EvaluatedAtUtc' ''));$NowUtc=if($null -eq $at){[datetime]::UtcNow}else{$at}}
    foreach($s in @(Get-DomeniaHealthValue $Policy 'Suspensions' @())){if([string]$s.RuleId -cne $RuleId){continue};$until=ConvertFrom-DomeniaUtcText ([string]$s.UntilUtc);if($null -ne $until -and $until -gt $NowUtc){return $s}}
    return $null
}

function Update-DomeniaFleetScopedHealth {
    # Resolve once per parent OU; then assess each canonical GUID against its own inherited policy.
    # Base distributions remain population facts; health lists and score use these exact target assignments.
    param($Data,$Book,[datetime]$NowUtc,$Lifecycle)
    $byGroup=@{};foreach($group in $Data.Last.Groups){$byGroup[[string]$group.gid]=$group}
    $names=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$names[$r.Id]=$r.Name}
    $rules=@('eos.ended','eos.soon','stale','never','pwdold','laps.none','laps.expired','bitlocker.none','lowdisk','disk.tight','uptime')
    $parentPolicies=@{};$policies=@{};$preparedGroups=@{};$releaseCache=@{};$hits=@{}
    $healthy=[Collections.Generic.List[object]]::new();$problem=[Collections.Generic.List[object]]::new();$unknown=[Collections.Generic.List[object]]::new()
    $lapsVisible=$false;$bitlockerVisible=$false
    foreach($group in $Data.Last.Groups){if($group.st -eq 'A'){if($group.lk -in @('O','E')){$lapsVisible=$true};if($group.bk -eq 'K'){$bitlockerVisible=$true}}}
    foreach($target in $Data.Last.Targets){
        if($target.st -ne 'A'){continue};$guid=[string]$target.object_guid;$parent=Get-DomeniaRawDnParent ([string]$target.distinguished_name)
        if(-not $parentPolicies.ContainsKey($parent)){
            $policy=Resolve-DomeniaHealthPolicy $Book $parent;$policy.EvaluatedAtUtc=$NowUtc.ToString('o');$key=[string]$policy.Origin.SourceDn
            if(-not $policies.ContainsKey($key)){
                $on=@{};foreach($id in $rules){$on[$id]=Test-DomeniaHealthRuleEnabled $policy $id}
                $custom=@($policy.CustomRules|Where-Object{Test-DomeniaHealthRuleEnabled $policy $_.Id});$needMemory=$false;$needDisk=$on.lowdisk -or $on['disk.tight'];$needBoot=$on.uptime
                foreach($rule in $custom){$names[$rule.Id]=$rule.Name;if($rule.Measure -eq 'DiskFree'){$needDisk=$true};if($rule.Measure -eq 'UptimeDays'){$needBoot=$true};if($rule.Measure -eq 'MemoryUsed'){$needMemory=$true}}
                $policies[$key]=[pscustomobject]@{ScopeDn=$key;Policy=$policy;Count=0;On=$on;Custom=$custom;NeedDisk=$needDisk;NeedBoot=$needBoot;NeedMemory=$needMemory;EnabledCount=(@($on.Values|Where-Object{$_}).Count+$custom.Count)}
            }
            $parentPolicies[$parent]=$policies[$key]
        }
        $effective=$parentPolicies[$parent];$effective.Count++;$p=$effective.Policy;$on=$effective.On;$limits=$p.Thresholds;$group=$byGroup[[string]$target.gid]
        $cacheKey=$effective.ScopeDn+'|'+[string]$target.gid
        if(-not $preparedGroups.ContainsKey($cacheKey)){
            $groupHits=[Collections.Generic.List[object]]::new();$known=$effective.EnabledCount -gt 0 -and -not $effective.NeedMemory
            if($on['eos.ended'] -or $on['eos.soon']){
                $rk=[string]$group.os+'|'+[string]$group.ver
                if(-not $releaseCache.ContainsKey($rk)){$releaseCache[$rk]=Get-DomeniaWindowsRelease -Caption ([string]$group.os) -Build ([string]$group.ver) -Lifecycle $Lifecycle -Now $NowUtc}
                $release=$releaseCache[$rk];$known=$known -and $Data.LifecycleKnown -and [bool]([string]$group.os) -and [bool]([string]$group.ver) -and [bool]([string]$release.End)
                if($on['eos.ended'] -and $release.Status -eq 'Ended'){$groupHits.Add(@('eos.ended','Alert'))}
                if($on['eos.soon'] -and $release.Status -eq 'Soon'){$groupHits.Add(@('eos.soon','Warn'))}
            }
            if($on['laps.none'] -or $on['laps.expired']){$known=$known -and $group.lk -in @('O','E','X');if($on['laps.none'] -and $lapsVisible -and $group.lk -eq 'N'){$groupHits.Add(@('laps.none','Warn'))};if($on['laps.expired'] -and $group.lk -eq 'E'){$groupHits.Add(@('laps.expired','Warn'))}}
            if($on['bitlocker.none']){$known=$known -and $group.bk -in @('K','X');if($bitlockerVisible -and $group.bk -eq 'N'){$groupHits.Add(@('bitlocker.none','Warn'))}}
            $preparedGroups[$cacheKey]=[pscustomobject]@{Known=$known;Hits=$groupHits.ToArray()}
        }
        $prepared=$preparedGroups[$cacheKey];$known=[bool]$prepared.Known;$targetHits=[Collections.Generic.List[object]]::new();foreach($hit in $prepared.Hits){$targetHits.Add($hit)}
        if($on.stale -or $on.never){
            $date=[datetime]::MinValue;$valid=[datetime]::TryParseExact([string]$target.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date) -and $date -le $NowUtc.Date
            $known=$known -and $valid
            if($valid -and $on.stale -and $date -le $NowUtc.Date.AddDays(-$limits.StaleDays)){$targetHits.Add(@('stale','Warn'))}
            if(-not $valid -and $on.never){$targetHits.Add(@('never','Warn'))}
        }
        if($on.pwdold){
            $date=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $target 'PasswordUtc' ''));$valid=$null -ne $date -and $date -le $NowUtc
            $known=$known -and $valid
            if($valid -and $date -lt $NowUtc.AddDays(-$limits.PasswordDays)){$targetHits.Add(@('pwdold','Warn'))}
        }
        $inventory=$Data.HealthInventoryKnown[$guid]
        if($effective.NeedDisk){$known=$known -and $null -ne $inventory -and [bool]$inventory.Disk}
        if($effective.NeedBoot){$known=$known -and $null -ne $inventory -and [bool]$inventory.Boot}
        if($null -ne $inventory){
            if($inventory.Disk){
                if($on.lowdisk -and $inventory.DiskPercent -lt $limits.DiskFreeAlert){$targetHits.Add(@('lowdisk','Alert'))}
                elseif($on['disk.tight'] -and $inventory.DiskPercent -lt $limits.DiskFreeWarn){$targetHits.Add(@('disk.tight','Warn'))}
            }
            if($inventory.Boot -and $on.uptime -and $inventory.UptimeDays -gt $limits.UptimeDays){$targetHits.Add(@('uptime','Warn'))}
            foreach($rule in $effective.Custom){
                $value=if($rule.Measure -eq 'DiskFree' -and $inventory.Disk){$inventory.DiskPercent}elseif($rule.Measure -eq 'UptimeDays' -and $inventory.Boot){$inventory.UptimeDays}else{$null}
                if($null -eq $value){continue};$hit=if($rule.Operator -eq 'LessThan'){$value -lt $rule.Threshold}else{$value -gt $rule.Threshold};if($hit){$targetHits.Add(@($rule.Id,$rule.Severity))}
            }
        }
        foreach($hit in $targetHits){$key=[string]$hit[0]+'|'+[string]$hit[1];if(-not $hits.ContainsKey($key)){$hits[$key]=[pscustomobject]@{Id=[string]$hit[0];Level=[string]$hit[1];Targets=[Collections.Generic.List[object]]::new()}};$hits[$key].Targets.Add($target)}
        if($targetHits.Count){$problem.Add($target)}elseif($known){$healthy.Add($target)}else{$unknown.Add($target)}
    }
    # Keep global data-quality diagnostics, never old parent-policy health alerts.
    $attention=[Collections.ArrayList]::new();foreach($old in $Data.Attention){if(-not $names.ContainsKey([string]$old.Point) -and -not ([string]$old.Point).StartsWith('custom.')){[void]$attention.Add($old)}}
    $ruleTargets=@{}
    foreach($item in $hits.Values){
        $rows=$item.Targets.ToArray();$title=[string]$names[$item.Id];if(-not $title){$title=$item.Id}
        [void]$attention.Add([pscustomobject]@{Level=$item.Level;Text=($title+' : '+$rows.Count+' poste(s), selon les règles de leur OU.');Point=$item.Id;Groups=@();Machines=$rows;Action=$null})
        if(-not $ruleTargets.ContainsKey($item.Id)){$ruleTargets[$item.Id]=[Collections.Generic.List[object]]::new()};$ruleTargets[$item.Id].AddRange($rows)
    }
    $Data.Attention=$attention;$Data.Population.Healthy=$healthy.Count;$Data.Population|Add-Member -NotePropertyName Unassessed -NotePropertyValue $unknown.Count -Force
    $Data.Last.HealthyTargets=$healthy.ToArray();$Data.Last.ProblemTargets=$problem.ToArray();$Data.Last|Add-Member -NotePropertyName UnknownTargets -NotePropertyValue $unknown.ToArray() -Force
    $Data|Add-Member -NotePropertyName HealthCoverage -NotePropertyValue (($healthy.Count+$problem.Count).ToString()+' évalué(s) / '+$Data.Population.Total+' comptes activés ; '+$unknown.Count+' incomplet(s) · '+$policies.Count+' politique(s) dʼOU appliquée(s)') -Force
    $Data|Add-Member -NotePropertyName EffectiveHealthPolicies -NotePropertyValue @($policies.Values) -Force
    $Data|Add-Member -NotePropertyName ScopedHealthEvaluated -NotePropertyValue $true -Force
    foreach($map in @(@('fleet.stale','stale'),@('fleet.pwdold','pwdold'),@('fleet.lowdisk','lowdisk'),@('fleet.uptime','uptime'))){
        $rows=@();if($ruleTargets.ContainsKey($map[1])){$rows=$ruleTargets[$map[1]].ToArray()};$Data.Last.WidgetTargets[$map[0]]=$rows
        $entry=$Data.Entries[$map[0]];if($null -ne $entry){$entry.Value=[string]$rows.Count;$entry.Number=$rows.Count;$entry.Detail='Selon les règles et suspensions de chaque OU.'}
    }
    $Data.Snapshot.Figures.Healthy=$healthy.Count;$Data.Snapshot.Figures.Problems=$problem.Count
}
