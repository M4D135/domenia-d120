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
    # Disabled or suspended rules are evaluated too: Add-DomeniaBoardAttention keeps them out of the score and records
    # what they would flag for the explanation (point 75).
    foreach($rule in @($Data.HealthPolicy.CustomRules)){
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

function Get-DomeniaHealthRuleState {
    # On, Disabled or Suspended for one rule of one policy. A rule both disabled and suspended stays Disabled: the
    # permanent choice wins over the temporary one.
    param($Policy,[string]$RuleId)
    if(-not (Test-DomeniaHealthRuleEnabled $Policy $RuleId -IgnoreSuspension)){return 'Disabled'}
    if($null -ne (Get-DomeniaHealthSuspension $Policy $RuleId)){return 'Suspended'}
    return 'On'
}
function Format-DomeniaHealthSuspensionText {
    # 'jusquʼau 14/10/2026 18:00 : motif', local time of the machine computing the view.
    param($Suspension)
    $until=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $Suspension 'UntilUtc' ''))
    $when=if($null -ne $until){$until.ToLocalTime().ToString('dd/MM/yyyy HH:mm',[Globalization.CultureInfo]::InvariantCulture)}else{'échéance illisible'}
    return ('jusquʼau '+$when+' : '+[string](Get-DomeniaHealthValue $Suspension 'Reason' ''))
}
function Get-DomeniaFleetRuleEligibility {
    # Point 75: for every fleet rule, the active workstations whose data allow the rule to be evaluated, whatever the
    # policy (enabling a rule never changes which data exist). Rules measured only on one workstation are absent.
    # Runs once per active workstation: group facts are prepared once and member reads stay inline.
    param($Data,[datetime]$NowUtc=[datetime]::UtcNow)
    $last=Get-DomeniaHealthValue $Data 'Last'
    $groups=@{};foreach($g in @(Get-DomeniaHealthValue $last 'Groups' @())){if($null -ne $g){$groups[[string]$g.gid]=$g}}
    $inventory=Get-DomeniaHealthValue $Data 'HealthInventoryKnown';if($inventory -isnot [Collections.IDictionary]){$inventory=@{}}
    $eos=Get-DomeniaHealthValue $Data 'EosKnownGroups';if($eos -isnot [Collections.IDictionary]){$eos=@{}}
    $lapsVisible=$false;$bitlockerVisible=$false
    foreach($g in $groups.Values){if([string]$g.st -eq 'A'){if([string]$g.lk -in @('O','E')){$lapsVisible=$true};if([string]$g.bk -eq 'K'){$bitlockerVisible=$true}}}
    $flags=@{}
    foreach($gid in @($groups.Keys)){
        $g=$groups[$gid];$lk=[string](Get-DomeniaHealthValue $g 'lk' '');$bk=[string](Get-DomeniaHealthValue $g 'bk' '')
        $flags[$gid]=[pscustomobject]@{Eos=[bool]$eos[$gid];Password=([string](Get-DomeniaHealthValue $g 'pw' '') -in @('R','O'));LapsNone=($lapsVisible -and ($lk -in @('O','E','N')));LapsExpired=($lk -in @('O','E'));BitLocker=($bitlockerVisible -and ($bk -in @('K','N')))}
    }
    $none=[pscustomobject]@{Eos=$false;Password=$false;LapsNone=$false;LapsExpired=$false;BitLocker=$false}
    $counts=[ordered]@{};foreach($id in @('eos.ended','eos.soon','stale','never','pwdold','laps.none','laps.expired','bitlocker.none','lowdisk','disk.tight','uptime')){$counts[$id]=0}
    $culture=[Globalization.CultureInfo]::InvariantCulture;$styles=[Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    $total=0;$today=$NowUtc.Date
    foreach($target in @(Get-DomeniaHealthValue $last 'Targets' @())){
        if($null -eq $target){continue}
        $properties=$target.PSObject.Properties;$property=$properties['st'];if(($null -ne $property) -and ([string]$property.Value -ne 'A')){continue}
        $total++;$property=$properties['gid'];$flag=$none;if($null -ne $property){$known=$flags[[string]$property.Value];if($null -ne $known){$flag=$known}}
        if($flag.Eos){$counts['eos.ended']++;$counts['eos.soon']++}
        $property=$properties['logon'];$date=[datetime]::MinValue
        if(($null -ne $property) -and [datetime]::TryParseExact([string]$property.Value,'yyyy-MM-dd',$culture,[Globalization.DateTimeStyles]::None,[ref]$date) -and ($date -le $today)){$counts['stale']++}
        $counts['never']++
        $password=$flag.Password
        if(-not $password){$property=$properties['PasswordUtc'];$date=[datetime]::MinValue;if(($null -ne $property) -and [datetime]::TryParse(([string]$property.Value).Trim(),$culture,$styles,[ref]$date) -and ($date -le $NowUtc)){$password=$true}}
        if($password){$counts['pwdold']++}
        if($flag.LapsNone){$counts['laps.none']++};if($flag.LapsExpired){$counts['laps.expired']++};if($flag.BitLocker){$counts['bitlocker.none']++}
        $property=$properties['object_guid'];$facts=if($null -ne $property){$inventory[[string]$property.Value]}else{$null}
        if($null -ne $facts){
            $disk=$facts.PSObject.Properties['Disk'];$boot=$facts.PSObject.Properties['Boot']
            if(($null -ne $disk) -and [bool]$disk.Value){$counts['lowdisk']++;$counts['disk.tight']++}
            if(($null -ne $boot) -and [bool]$boot.Value){$counts['uptime']++}
        }
    }
    return [pscustomobject]@{Total=$total;Counts=$counts;Measures=@{DiskFree=$counts['lowdisk'];UptimeDays=$counts['uptime']}}
}
function Get-DomeniaComputerRuleEvidence {
    # Point 75: whether the workstation board read the data one rule needs. A missing tile or a tile in an unknown
    # state (Off) is not measured; rules that only make sense on a fleet do not apply to one workstation.
    param($Data,[string]$RuleId,[string]$Measure='')
    $keys=@{'eos.ended'='computer.os';'eos.soon'='computer.os';'stale'='computer.ad.lastlogon';'pwdold'='computer.ad.password';'laps.expired'='computer.ad.laps';'bitlocker.none'='computer.bitlocker';'lowdisk'='computer.disk.system';'disk.tight'='computer.disk.system';'uptime'='computer.uptime';'memory'='computer.memory.usage';'battery'='computer.battery';'ad.disabled'='computer.ad.account';'clock'='computer.ad.clock';'firewall'='computer.firewall';'reboot'='computer.reboot';'services'='computer.services.stopped';'devices'='computer.devices';'drivers'='computer.drivers';'hotfix'='computer.hotfix';'events'='computer.events'}
    $measures=@{DiskFree='computer.disk.system';UptimeDays='computer.uptime';MemoryUsed='computer.memory.usage'}
    $key=if($RuleId.StartsWith('custom.',[StringComparison]::Ordinal)){[string]$measures[$Measure]}else{[string]$keys[$RuleId]}
    if(-not $key){return 'NotApplicable'}
    $entries=Get-DomeniaHealthValue $Data 'Entries'
    $entry=$null;if(($entries -is [Collections.IDictionary]) -and $entries.Contains($key)){$entry=$entries[$key]}
    if(($null -eq $entry) -or ([string](Get-DomeniaHealthValue $entry 'State' '') -eq 'Off')){return 'NotMeasured'}
    # The system tile exists without an end date when the lifecycle table has no line for this build.
    if(($RuleId -in @('eos.ended','eos.soon')) -and ([string]$entry.State -notin @('Alert','Warn')) -and ([string](Get-DomeniaHealthValue $entry 'Detail' '') -notmatch '(?i)fin de service')){return 'NotMeasured'}
    return 'Measured'
}
function Get-DomeniaHealthExplanation {
    # Point 75. Per rule: its state, the population whose data allow it to be evaluated, the workstations it flags
    # (unique within the rule, never summed across rules), those flagged by this rule alone, and what a disabled or
    # suspended rule would have flagged (masked: never scored, always shown).
    param($Data)
    $policy=$Data.HealthPolicy;$names=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$names[$r.Id]=$r.Name}
    $catalog=@{};foreach($id in @($names.Keys)){$catalog[$id]=$true}
    $effective=@(Get-DomeniaHealthValue $Data 'EffectiveHealthPolicies' @());if(-not $effective.Count){$effective=@([pscustomobject]@{ScopeDn='';Policy=$policy;Count=0})}
    $measureOf=@{};foreach($e in $effective){foreach($r in @($e.Policy.CustomRules)){$names[$r.Id]=$r.Name;$measureOf[$r.Id]=[string]$r.Measure}}
    $suspendedIds=@{}
    $rows=[Collections.Generic.List[object]]::new();$fleet=([string]$Data.Board -eq 'Fleet')
    $targets=if($fleet){@(Get-DomeniaHealthValue (Get-DomeniaHealthValue $Data 'Last') 'Targets' @())}else{@()};$byGroup=@{}
    if($fleet){foreach($m in $targets){$key=[string]$m.gid;if(-not $byGroup.ContainsKey($key)){$byGroup[$key]=[Collections.Generic.List[object]]::new()};$byGroup[$key].Add($m)}}
    $collect={param([object[]]$Points)
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$alerts=0;$warnings=0
        foreach($point in $Points){
            if($null -eq $point){continue};if($point.Level -eq 'Alert'){$alerts++}else{$warnings++}
            foreach($target in @($point.Machines)){if(($null -ne $target) -and [string]$target.object_guid){[void]$ids.Add([string]$target.object_guid)}}
            foreach($gid in @($point.Groups)){foreach($target in @($byGroup[[string]$gid])){if(($null -ne $target) -and [string]$target.object_guid){[void]$ids.Add([string]$target.object_guid)}}}
        }
        return [pscustomobject]@{Ids=$ids;Alerts=$alerts;Warnings=$warnings}
    }
    $points=@{};foreach($point in @($Data.Attention)){
        if($point.Level -notin @('Alert','Warn')){continue};$key=[string]$point.Point;if(-not $key){$key='unspecified'}
        if(-not $names.ContainsKey($key)){$names[$key]=$key}
        if(-not $points.ContainsKey($key)){$points[$key]=[Collections.Generic.List[object]]::new()};$points[$key].Add($point)
    }
    $hidden=@{};foreach($point in @(Get-DomeniaHealthValue $Data 'SuppressedAttention' @())){
        if(($null -eq $point) -or ($point.Level -notin @('Alert','Warn'))){continue};$key=[string]$point.Point;if(-not $key){continue}
        if(-not $names.ContainsKey($key)){$names[$key]=$key}
        if(-not $hidden.ContainsKey($key)){$hidden[$key]=[Collections.Generic.List[object]]::new()};$hidden[$key].Add($point)
    }
    $eligibility=Get-DomeniaHealthValue $Data 'HealthEligibility'
    $eligibleTotal=[int](Get-DomeniaHealthValue $eligibility 'Total' 0)
    $flagged=@{};$prepared=[Collections.Generic.List[object]]::new()
    foreach($id in @($names.Keys|Sort-Object)){
        $hit=& $collect @($points[$id]);$masked=& $collect @($hidden[$id])
        $statuses=@{};$reasons=[Collections.Generic.List[string]]::new();$suspendedMachines=0
        foreach($e in $effective){$state=Get-DomeniaHealthRuleState $e.Policy $id;$status=switch($state){'Disabled'{'Désactivée'}'Suspended'{'Suspendue'}default{'Activée'}};$statuses[$status]=$true
            if($state -eq 'Suspended'){$suspendedIds[$id]=$true;$suspendedMachines+=[int]$e.Count;$reasons.Add((Format-DomeniaHealthSuspensionText (Get-DomeniaHealthSuspension $e.Policy $id)))}
        }
        $status=if($statuses.Count -gt 1){'Selon lʼOU'}else{@($statuses.Keys)[0]}
        if($fleet){foreach($guid in $hit.Ids){$flagged[$guid]=1+[int]$flagged[$guid]}}
        $prepared.Add([pscustomobject]@{Id=$id;Status=$status;Hit=$hit;Masked=$masked;Reasons=$reasons;SuspendedMachines=$suspendedMachines})
    }
    foreach($item in $prepared){
        $id=$item.Id;$hit=$item.Hit;$masked=$item.Masked;$status=$item.Status
        $count=if($fleet){$hit.Ids.Count}elseif($hit.Alerts -or $hit.Warnings){1}else{0}
        $maskedCount=if($fleet){$masked.Ids.Count}elseif($masked.Alerts -or $masked.Warnings){1}else{0}
        $exclusive=0;if($fleet){foreach($guid in $hit.Ids){if([int]$flagged[$guid] -eq 1){$exclusive++}}}
        # Eligible population: data present for this rule. Diagnostics of the view are not rules.
        $eligibleCount=$null
        if($fleet){
            $counts=Get-DomeniaHealthValue $eligibility 'Counts'
            if($catalog.ContainsKey($id)){if(($counts -is [Collections.IDictionary]) -and $counts.Contains($id)){$eligibleCount=[int]$counts[$id]}}
            elseif($measureOf.ContainsKey($id)){$measureCounts=Get-DomeniaHealthValue $eligibility 'Measures';if(($measureCounts -is [Collections.IDictionary]) -and $measureCounts.Contains($measureOf[$id])){$eligibleCount=[int]$measureCounts[$measureOf[$id]]}}
            $eligibleText=if(-not ($catalog.ContainsKey($id) -or $measureOf.ContainsKey($id))){'Diagnostic de la vue'}elseif($null -eq $eligibility){'Non calculé'}elseif($null -ne $eligibleCount){[string]$eligibleCount+' / '+$eligibleTotal}else{'Non mesuré sur le parc'}
        }else{
            $evidence=if($catalog.ContainsKey($id) -or $measureOf.ContainsKey($id)){Get-DomeniaComputerRuleEvidence -Data $Data -RuleId $id -Measure ([string]$measureOf[$id])}else{''}
            $eligibleText=switch($evidence){'Measured'{'Mesuré'}'NotMeasured'{'Non mesuré'}'NotApplicable'{'Contrôle du parc'}default{'Diagnostic du poste'}}
            if($evidence -eq 'Measured'){$eligibleCount=1}elseif($evidence -eq 'NotMeasured'){$eligibleCount=0}
        }
        $suspension=if($item.Reasons.Count){'Suspendue '+($item.Reasons -join ' ; ')}else{''}
        if($status -eq 'Désactivée'){$effect='Exclue du score'}
        elseif($status -eq 'Suspendue'){$effect=$suspension}
        elseif($fleet){
            $effect=if($count){[string]$count+' poste(s) retiré(s) des postes sains, dont '+$exclusive+' par ce seul contrôle'}else{'Aucun poste signalé'}
            if($status -eq 'Selon lʼOU'){$effect+=' ; selon les règles de chaque OU';if($item.SuspendedMachines){$effect+=' ; '+$item.SuspendedMachines+' poste(s) exempté(s) temporairement'}}
        }
        else{$effect='-'+(25*$hit.Alerts+10*$hit.Warnings)+' point(s)'}
        $consequence=''
        if($maskedCount){
            $why=if($status -eq 'Suspendue'){'pendant la suspension'}elseif($status -eq 'Désactivée'){'si la règle était activée'}else{'là où la règle est désactivée ou suspendue'}
            $consequence=if($fleet){[string]$maskedCount+' poste(s) seraient signalés '+$why}else{'Signalerait ce poste '+$why+' (−'+(25*$masked.Alerts+10*$masked.Warnings)+' point(s))'}
        }elseif(($status -in @('Désactivée','Suspendue')) -and ($eligibleText -notin @('Contrôle du parc','Diagnostic du poste','Diagnostic de la vue'))){
            $consequence=if(($null -ne $eligibleCount) -and ($eligibleCount -gt 0)){'Aucun poste concerné dans les données disponibles'}else{'Donnée non mesurée : effet inconnu'}
        }
        $rows.Add([pscustomobject]@{Id=$id;Rule=[string]$names[$id];Status=$status;Machines=$count;Effect=$effect;Guids=@($hit.Ids);Eligible=$eligibleText;EligibleCount=$eligibleCount;Exclusive=$exclusive;Masked=$maskedCount;MaskedGuids=@($masked.Ids);Consequence=$consequence})
    }
    $enabledCount=@($rows|Where-Object{$_.Status -in @('Activée','Selon lʼOU')}).Count
    $population=Get-DomeniaHealthValue $Data 'Population';$unknown=[int](Get-DomeniaHealthValue $population 'Unassessed' 0);$total=[int](Get-DomeniaHealthValue $population 'Total' 0);$healthy=[int](Get-DomeniaHealthValue $population 'Healthy' 0)
    $maskedAll=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($row in $rows){foreach($guid in @($row.MaskedGuids)){[void]$maskedAll.Add([string]$guid)}}
    $summary=if($fleet){'Score = part des postes évalués sans problème : '+$healthy+' / '+([Math]::Max(0,$total-$unknown))+'. '+$unknown+' poste(s) incomplet(s) exclus du dénominateur, jamais considérés sains. Un poste touché par plusieurs règles compte une fois dans le score. La colonne « Évaluables » donne, pour chaque règle, les postes dont la donnée est connue. Une règle désactivée ou suspendue ne retire aucun poste du score ; ce quʼelle aurait signalé reste affiché.'}else{'Score = 100 − 25 par point critique − 10 par point à surveiller, minimum 0. Un contrôle absent ne prouve pas un bon état ; une évaluation incomplète est signalée. Une règle désactivée ou suspendue ne pénalise pas le score ; ce quʼelle aurait signalé reste affiché.'}
    $suspendedCount=$suspendedIds.Count
    $scopeRows=@($effective|ForEach-Object{$scopePolicy=$_.Policy;[pscustomobject]@{Scope=$(if($_.ScopeDn){$_.ScopeDn}else{'Domaine : règles par défaut'});Machines=$_.Count;Suspended=@($_.Policy.Suspensions|Where-Object{$null -ne (Get-DomeniaHealthSuspension $scopePolicy $_.RuleId)}).Count;Thresholds=('AD '+$_.Policy.Thresholds.StaleDays+' j · mot de passe '+$_.Policy.Thresholds.PasswordDays+' j · disque '+$_.Policy.Thresholds.DiskFreeAlert+'/'+$_.Policy.Thresholds.DiskFreeWarn+' %')}})
    [pscustomobject]@{Summary=$summary;ActiveRules=$enabledCount;DisabledRules=@($rows|Where-Object{$_.Status -eq 'Désactivée'}).Count;SuspendedRules=$suspendedCount;MaskedMachines=$(if($fleet){$maskedAll.Count}else{@($rows|Where-Object{$_.Masked}).Count});Policies=$scopeRows;Rows=$rows.ToArray();Population=$total;Unknown=$unknown;Assessed=[Math]::Max(0,$total-$unknown);Scope=([string](Get-DomeniaHealthValue (Get-DomeniaHealthValue $Data 'Last') 'Scope' ''))}
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

function Format-DomeniaHealthScopeLabel {
    # Short label of a policy scope: the OU path without the domain suffix, or the domain defaults.
    param([string]$ScopeDn,[string]$DomainDn)
    if(-not $ScopeDn -or $ScopeDn -ieq $DomainDn){return 'Règles par défaut du domaine'}
    $suffix=','+$DomainDn
    if($DomainDn -and $ScopeDn.EndsWith($suffix,[StringComparison]::OrdinalIgnoreCase)){return $ScopeDn.Substring(0,$ScopeDn.Length-$suffix.Length)}
    return $ScopeDn
}
function Get-DomeniaHealthPolicyOrigins {
    # Point 76: where each effective setting of one OU comes from: the domain defaults, an ancestor OU, or the OU
    # itself (local exception). Thresholds and rule states inherit one by one; custom alerts and suspensions inherit
    # as whole lists, exactly as Resolve-DomeniaHealthPolicy applies them.
    param($Book,[string]$ScopeDn='')
    $domain=[string]$Book.DomainDn
    if(-not (Test-DomeniaHealthScope $ScopeDn $domain)){throw 'OU de politique hors du domaine.'}
    if($ScopeDn -ieq $domain){$ScopeDn=''}
    $policy=Resolve-DomeniaHealthPolicy $Book $ScopeDn
    $chain=[Collections.Generic.List[string]]::new();$cursor=$ScopeDn
    for($depth=0;$cursor -and ($cursor -ine $domain) -and ($depth -lt 128);$depth++){$chain.Insert(0,$cursor);$cursor=Get-DomeniaRawDnParent $cursor}
    $byDn=@{};foreach($record in @($Book.Scopes)){$byDn[[string]$record.ScopeDn]=$record}
    $source=@{}
    foreach($dn in $chain){
        $record=$byDn[$dn];if($null -eq $record){continue}
        foreach($p in $record.Overrides.Thresholds.PSObject.Properties){$source['Threshold:'+$p.Name]=[string]$record.ScopeDn}
        foreach($p in $record.Overrides.RuleStates.PSObject.Properties){$source['Rule:'+$p.Name]=[string]$record.ScopeDn}
        if($null -ne $record.Overrides.CustomRules){$source['CustomRules']=[string]$record.ScopeDn}
        if($null -ne $record.Overrides.Suspensions){$source['Suspensions']=[string]$record.ScopeDn}
    }
    $row={param([string]$Kind,[string]$Id,[string]$Name,[string]$Value,[string]$Key)
        $from=[string]$source[$Key];$local=[bool]($from -and $ScopeDn -and ($from -ieq $ScopeDn))
        $origin=if($local){'Exception locale'}elseif($from){'Hérité de '+(Format-DomeniaHealthScopeLabel $from $domain)}else{'Règles par défaut du domaine'}
        [pscustomobject]@{Kind=$Kind;Id=$Id;Name=$Name;Value=$Value;SourceDn=$from;Local=$local;Origin=$origin}
    }
    $rows=[Collections.Generic.List[object]]::new()
    foreach($limit in @(Get-DomeniaHealthThresholdCatalog)){$rows.Add((& $row 'Seuil' $limit.Id $limit.Name ([string]$policy.Thresholds.($limit.Id)) ('Threshold:'+$limit.Id)))}
    foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$rows.Add((& $row 'Contrôle' $rule.Id $rule.Name $(if(Test-DomeniaHealthRuleEnabled $policy $rule.Id -IgnoreSuspension){'Activé'}else{'Désactivé'}) ('Rule:'+$rule.Id)))}
    $rows.Add((& $row 'Liste' 'CustomRules' 'Alertes personnalisées' ([string]@($policy.CustomRules).Count+' alerte(s)') 'CustomRules'))
    $rows.Add((& $row 'Liste' 'Suspensions' 'Suspensions' ([string]@($policy.Suspensions|Where-Object{$null -ne (Get-DomeniaHealthSuspension $policy $_.RuleId)}).Count+' active(s) sur '+@($policy.Suspensions).Count) 'Suspensions'))
    return $rows.ToArray()
}
function Get-DomeniaHealthPolicyExceptions {
    # Point 76: every local exception of the domain, with its readable differences against what it would inherit.
    param($Book,[datetime]$NowUtc=[datetime]::UtcNow)
    $domain=[string]$Book.DomainDn
    $thresholdNames=@{};foreach($limit in @(Get-DomeniaHealthThresholdCatalog)){$thresholdNames[$limit.Id]=$limit.Name}
    $ruleNames=@{};foreach($rule in @(Get-DomeniaHealthRuleCatalog)){$ruleNames[$rule.Id]=$rule.Name}
    $rows=[Collections.Generic.List[object]]::new()
    $ordered=@($Book.Scopes|Sort-Object @{Expression={@(Split-DomeniaRawDn ([string]$_.ScopeDn)).Count}},@{Expression={[string]$_.ScopeDn}})
    foreach($record in $ordered){
        $dn=[string]$record.ScopeDn;$inherited=Resolve-DomeniaHealthPolicy $Book $dn -SkipExact;$changes=[Collections.Generic.List[string]]::new()
        foreach($p in $record.Overrides.Thresholds.PSObject.Properties){$old=[string]$inherited.Thresholds.($p.Name);$changes.Add([string]$thresholdNames[$p.Name]+' : '+[string]$p.Value+$(if($old -ceq [string]$p.Value){' (identique à la valeur héritée)'}else{' (hérité : '+$old+')'}))}
        foreach($p in $record.Overrides.RuleStates.PSObject.Properties){$changes.Add([string]$ruleNames[$p.Name]+' : '+$(if([bool]$p.Value){'activé'}else{'désactivé'}))}
        if($null -ne $record.Overrides.CustomRules){$changes.Add('Alertes personnalisées propres : '+@($record.Overrides.CustomRules).Count+' (remplacent la liste héritée)')}
        if($null -ne $record.Overrides.Suspensions){
            $list=@($record.Overrides.Suspensions);$active=0
            foreach($item in $list){$until=ConvertFrom-DomeniaUtcText ([string]$item.UntilUtc);if(($null -ne $until) -and ($until -gt $NowUtc)){$active++}}
            $changes.Add('Suspensions propres : '+$list.Count+' dont '+$active+' active(s)')
        }
        $rows.Add([pscustomobject]@{ScopeDn=$dn;Label=(Format-DomeniaHealthScopeLabel $dn $domain);Changes=($changes -join ' · ');Count=$changes.Count})
    }
    return $rows.ToArray()
}
function Get-DomeniaHealthEditorScopes {
    # Point 76: scopes offered by the rules editor: domain defaults, every ancestor OU of the current one, the current
    # OU, then every other OU that already holds an exception, each listed once.
    param($Book,[string]$CurrentDn='')
    $domain=[string]$Book.DomainDn;$items=[Collections.Generic.List[object]]::new();$seen=@{}
    $items.Add([pscustomobject]@{Name='Règles par défaut du domaine';Dn='';Kind='Domain'});$seen['']=$true
    $chain=[Collections.Generic.List[string]]::new();$cursor=$CurrentDn
    for($depth=0;$cursor -and ($cursor -ine $domain) -and ($depth -lt 128);$depth++){if($cursor -match '^(?i:OU)='){$chain.Insert(0,$cursor)};$cursor=Get-DomeniaRawDnParent $cursor}
    foreach($dn in $chain){
        if($seen.ContainsKey($dn.ToLowerInvariant())){continue};$seen[$dn.ToLowerInvariant()]=$true
        $current=($dn -ieq $CurrentDn)
        $items.Add([pscustomobject]@{Name=$(if($current){'Cette OU et ses sous-OU : '}else{'OU parente : '})+(Format-DomeniaHealthScopeLabel $dn $domain);Dn=$dn;Kind=$(if($current){'Current'}else{'Ancestor'})})
    }
    foreach($record in @($Book.Scopes|Sort-Object @{Expression={[string]$_.ScopeDn}})){
        $dn=[string]$record.ScopeDn;if($seen.ContainsKey($dn.ToLowerInvariant())){continue};$seen[$dn.ToLowerInvariant()]=$true
        $items.Add([pscustomobject]@{Name=('Autre exception : '+(Format-DomeniaHealthScopeLabel $dn $domain));Dn=$dn;Kind='Exception'})
    }
    return $items.ToArray()
}
function Optimize-DomeniaHealthSuspensions {
    # Point 77: an ended suspension stays listed for RetentionDays as the trace of its reactivation, then leaves the
    # policy so the 64-entry bound never blocks a new suspension. An active suspension is never removed here.
    param([object[]]$Suspensions=@(),[datetime]$NowUtc=[datetime]::UtcNow,[ValidateRange(0,365)][int]$RetentionDays=30)
    $kept=[Collections.Generic.List[object]]::new()
    foreach($item in @($Suspensions)){
        if($null -eq $item){continue}
        $until=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $item 'UntilUtc' ''))
        if(($null -ne $until) -and ($until -gt $NowUtc.AddDays(-$RetentionDays))){$kept.Add($item)}
    }
    return $kept.ToArray()
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
    # Every rule is evaluated: an enabled rule scores, a disabled or suspended one only feeds the masked list of the
    # explanation (point 75), so the operator sees what it would have flagged without any effect on the score.
    param($Data,$Book,[datetime]$NowUtc,$Lifecycle)
    $byGroup=@{};foreach($group in $Data.Last.Groups){$byGroup[[string]$group.gid]=$group}
    $names=@{};foreach($r in @(Get-DomeniaHealthRuleCatalog)){$names[$r.Id]=$r.Name}
    $rules=@('eos.ended','eos.soon','stale','never','pwdold','laps.none','laps.expired','bitlocker.none','lowdisk','disk.tight','uptime')
    $parentPolicies=@{};$policies=@{};$preparedGroups=@{};$releaseCache=@{};$hits=@{};$hiddenHits=@{}
    $healthy=[Collections.Generic.List[object]]::new();$problem=[Collections.Generic.List[object]]::new();$unknown=[Collections.Generic.List[object]]::new()
    $lapsVisible=$false;$bitlockerVisible=$false
    foreach($group in $Data.Last.Groups){if($group.st -eq 'A'){if($group.lk -in @('O','E')){$lapsVisible=$true};if($group.bk -eq 'K'){$bitlockerVisible=$true}}}
    foreach($target in $Data.Last.Targets){
        if($target.st -ne 'A'){continue};$guid=[string]$target.object_guid;$parent=Get-DomeniaRawDnParent ([string]$target.distinguished_name)
        if(-not $parentPolicies.ContainsKey($parent)){
            $policy=Resolve-DomeniaHealthPolicy $Book $parent;$policy.EvaluatedAtUtc=$NowUtc.ToString('o');$key=[string]$policy.Origin.SourceDn
            if(-not $policies.ContainsKey($key)){
                $state=@{};foreach($id in $rules){$state[$id]=Get-DomeniaHealthRuleState $policy $id}
                foreach($rule in @($policy.CustomRules)){$state[[string]$rule.Id]=Get-DomeniaHealthRuleState $policy ([string]$rule.Id)}
                $on=@{};foreach($id in $rules){$on[$id]=($state[$id] -eq 'On')}
                $custom=@($policy.CustomRules|Where-Object{$state[[string]$_.Id] -eq 'On'});$needMemory=$false;$needDisk=$on.lowdisk -or $on['disk.tight'];$needBoot=$on.uptime
                foreach($rule in @($policy.CustomRules)){$names[$rule.Id]=$rule.Name}
                foreach($rule in $custom){if($rule.Measure -eq 'DiskFree'){$needDisk=$true};if($rule.Measure -eq 'UptimeDays'){$needBoot=$true};if($rule.Measure -eq 'MemoryUsed'){$needMemory=$true}}
                $policies[$key]=[pscustomobject]@{ScopeDn=$key;Policy=$policy;Count=0;On=$on;State=$state;Custom=$custom;AllCustom=@($policy.CustomRules);NeedDisk=$needDisk;NeedBoot=$needBoot;NeedMemory=$needMemory;EnabledCount=(@($on.Values|Where-Object{$_}).Count+$custom.Count)}
            }
            $parentPolicies[$parent]=$policies[$key]
        }
        $effective=$parentPolicies[$parent];$effective.Count++;$p=$effective.Policy;$on=$effective.On;$state=$effective.State;$limits=$p.Thresholds;$group=$byGroup[[string]$target.gid]
        $cacheKey=$effective.ScopeDn+'|'+[string]$target.gid
        if(-not $preparedGroups.ContainsKey($cacheKey)){
            # Group facts are shared by every workstation of the group: evaluate them once per policy and group.
            $groupHits=[Collections.Generic.List[object]]::new();$known=($effective.EnabledCount -gt 0) -and (-not $effective.NeedMemory)
            $rk=[string]$group.os+'|'+[string]$group.ver
            if(-not $releaseCache.ContainsKey($rk)){$releaseCache[$rk]=Get-DomeniaWindowsRelease -Caption ([string]$group.os) -Build ([string]$group.ver) -Lifecycle $Lifecycle -Now $NowUtc}
            $release=$releaseCache[$rk]
            if($on['eos.ended'] -or $on['eos.soon']){$known=$known -and [bool]$Data.LifecycleKnown -and [bool]([string]$group.os) -and [bool]([string]$group.ver) -and [bool]([string]$release.End)}
            if($release.Status -eq 'Ended'){$groupHits.Add(@('eos.ended','Alert'))}
            if($release.Status -eq 'Soon'){$groupHits.Add(@('eos.soon','Warn'))}
            if($on['laps.none'] -or $on['laps.expired']){$known=$known -and ($group.lk -in @('O','E','X'))}
            if($lapsVisible -and ($group.lk -eq 'N')){$groupHits.Add(@('laps.none','Warn'))}
            if($group.lk -eq 'E'){$groupHits.Add(@('laps.expired','Warn'))}
            if($on['bitlocker.none']){$known=$known -and ($group.bk -in @('K','X'))}
            if($bitlockerVisible -and ($group.bk -eq 'N')){$groupHits.Add(@('bitlocker.none','Warn'))}
            $preparedGroups[$cacheKey]=[pscustomobject]@{Known=$known;Hits=$groupHits.ToArray()}
        }
        $prepared=$preparedGroups[$cacheKey];$known=[bool]$prepared.Known;$allHits=[Collections.Generic.List[object]]::new();foreach($hit in $prepared.Hits){$allHits.Add($hit)}
        $date=[datetime]::MinValue;$valid=([datetime]::TryParseExact([string]$target.logon,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)) -and ($date -le $NowUtc.Date)
        if($on.stale -or $on.never){$known=$known -and $valid}
        if($valid -and ($date -le $NowUtc.Date.AddDays(-$limits.StaleDays))){$allHits.Add(@('stale','Warn'))}
        if(-not $valid){$allHits.Add(@('never','Warn'))}
        $date=ConvertFrom-DomeniaUtcText ([string](Get-DomeniaHealthValue $target 'PasswordUtc' ''));$valid=($null -ne $date) -and ($date -le $NowUtc)
        if($on.pwdold){$known=$known -and $valid}
        if($valid -and ($date -lt $NowUtc.AddDays(-$limits.PasswordDays))){$allHits.Add(@('pwdold','Warn'))}
        $inventory=$Data.HealthInventoryKnown[$guid]
        if($effective.NeedDisk){$known=$known -and ($null -ne $inventory) -and [bool]$inventory.Disk}
        if($effective.NeedBoot){$known=$known -and ($null -ne $inventory) -and [bool]$inventory.Boot}
        if($null -ne $inventory){
            if($inventory.Disk){
                # Same precedence as the score: a critical disk is lowdisk when that rule is on, else disk.tight.
                $critical=$inventory.DiskPercent -lt $limits.DiskFreeAlert;$tight=$inventory.DiskPercent -lt $limits.DiskFreeWarn
                if($critical){$allHits.Add(@('lowdisk','Alert'))}
                if($tight -and (-not ($critical -and $on.lowdisk))){$allHits.Add(@('disk.tight','Warn'))}
            }
            if($inventory.Boot -and ($inventory.UptimeDays -gt $limits.UptimeDays)){$allHits.Add(@('uptime','Warn'))}
            foreach($rule in $effective.AllCustom){
                $value=if(($rule.Measure -eq 'DiskFree') -and $inventory.Disk){$inventory.DiskPercent}elseif(($rule.Measure -eq 'UptimeDays') -and $inventory.Boot){$inventory.UptimeDays}else{$null}
                if($null -eq $value){continue};$hit=if($rule.Operator -eq 'LessThan'){$value -lt $rule.Threshold}else{$value -gt $rule.Threshold};if($hit){$allHits.Add(@([string]$rule.Id,[string]$rule.Severity))}
            }
        }
        $scored=0
        foreach($hit in $allHits){
            $id=[string]$hit[0];$ruleState=[string]$state[$id];if(-not $ruleState){$ruleState='Disabled'}
            $map=if($ruleState -eq 'On'){$hits}else{$hiddenHits};$key=$id+'|'+[string]$hit[1]+'|'+$ruleState
            if(-not $map.ContainsKey($key)){$map[$key]=[pscustomobject]@{Id=$id;Level=[string]$hit[1];Reason=$ruleState;Targets=[Collections.Generic.List[object]]::new()}};$map[$key].Targets.Add($target)
            if($ruleState -eq 'On'){$scored++}
        }
        if($scored){$problem.Add($target)}elseif($known){$healthy.Add($target)}else{$unknown.Add($target)}
    }
    # Keep global data-quality diagnostics, never old parent-policy health alerts.
    $attention=[Collections.ArrayList]::new();foreach($old in $Data.Attention){if(-not $names.ContainsKey([string]$old.Point) -and -not ([string]$old.Point).StartsWith('custom.')){[void]$attention.Add($old)}}
    $ruleTargets=@{}
    foreach($item in $hits.Values){
        $rows=$item.Targets.ToArray();$title=[string]$names[$item.Id];if(-not $title){$title=$item.Id}
        [void]$attention.Add([pscustomobject]@{Level=$item.Level;Text=($title+' : '+$rows.Count+' poste(s), selon les règles de leur OU.');Point=$item.Id;Groups=@();Machines=$rows;Action=$null})
        if(-not $ruleTargets.ContainsKey($item.Id)){$ruleTargets[$item.Id]=[Collections.Generic.List[object]]::new()};$ruleTargets[$item.Id].AddRange($rows)
    }
    # The parent-policy pass recorded masked points against one policy only: replace them by the per-OU evaluation.
    $suppressed=[Collections.ArrayList]::new()
    foreach($item in $hiddenHits.Values){
        $rows=$item.Targets.ToArray();$title=[string]$names[$item.Id];if(-not $title){$title=$item.Id}
        [void]$suppressed.Add([pscustomobject]@{Level=$item.Level;Text=($title+' : '+$rows.Count+' poste(s) masqué(s), règle '+$(if($item.Reason -eq 'Suspended'){'suspendue'}else{'désactivée'})+' dans leur OU.');Point=$item.Id;Groups=@();Machines=$rows;Route='';RouteText='';Reason=$item.Reason})
    }
    $Data.Attention=$attention;$Data.Population.Healthy=$healthy.Count;$Data.Population|Add-Member -NotePropertyName Unassessed -NotePropertyValue $unknown.Count -Force
    $Data|Add-Member -NotePropertyName SuppressedAttention -NotePropertyValue $suppressed -Force
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
