#requires -Version 5.1
# Compile the actual shipped library against the real common DLL; no directory, endpoint or UI access.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','Boards.Model','Probes.Model','Query.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
function Expect([bool]$Good,[string]$Name){$checks.Add([pscustomobject]@{Name=$Name;Pass=$Good});if(-not $Good){throw $Name}}
$templates=@(Get-DomeniaQueryTemplates)
$fields=@(Get-DomeniaQueryFields);$probes=@(Get-DomeniaProbeCatalog)
Expect ($templates.Count -ge 150) 'At least 150 operational templates'
Expect (@($templates.Id|Sort-Object -Unique).Count -eq $templates.Count) 'Unique template IDs'
Expect (@($templates.Name|Sort-Object -Unique).Count -eq $templates.Count) 'Distinct user-facing titles'
Expect (@($templates.Category|Sort-Object -Unique).Count -ge 10) 'Operational categories are represented'
$empty=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
$one=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
$one.Add([M4D.Admin.Common.Query.QueryRecord]::new('11111111-1111-1111-1111-111111111111',[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)))
$byId=@{}
foreach($template in $templates){
    $byId[[string]$template.Id]=$template
    Expect ($template.Id -cmatch '^template\.[a-z0-9.]+$') ('Stable reserved ID '+$template.Id)
    Expect ($template.Category -and $template.Description.Length -ge 80 -and $template.Name.Length -le 120) ('Useful metadata '+$template.Id)
    $compiled=ConvertTo-DomeniaCompiledQuery $template
    Expect ($null -ne $compiled) ('Actual DLL compile '+$template.Id)
    foreach($clause in @($template.Clauses)){
        Expect ([string]$clause.Field -cin @($fields.Id)) ('Supported field '+$template.Id+'/'+$clause.Field)
        if($clause.Operator -in @('IsMissing','IsPresent')){Expect ($null -eq $clause.Value) ('Missing operator has no synthetic value '+$template.Id)}
    }
    if($template.GroupBy){Expect ([string]$template.GroupBy -cin @($fields.Id)) ('Supported grouping '+$template.Id)}
    foreach($probeId in @(Get-DomeniaQueryProbeIds $template)){Expect ($probeId -cin @($probes.Id)) ('Supported probe '+$template.Id+'/'+$probeId)}
    $plan=Get-DomeniaQueryCollectionRequirements @($template)
    Expect ((@($plan.ProbeIds|Where-Object{$_ -cnotin @($probes.Id)}).Count) -eq 0) ('Collection plan is catalog-bound '+$template.Id)
    $result=$compiled.Execute($empty,$null)
    Expect ($result.Total -eq 0 -and $result.Matched -eq 0 -and $result.Unknown -eq 0) ('Empty fleet stays empty '+$template.Id)
    $result=$compiled.Execute($one,$null)
    Expect ($result.Total -eq 1 -and ($result.Matched+$result.Unknown+$result.NotMatched) -eq 1) ('Single computer partitions exactly once '+$template.Id)
    # A user saving a delivered model obtains the existing recipe schema and can load it again.
    $copy=New-DomeniaQueryRecipe -Id ('copy.'+$template.Id) -Name $template.Name -Junction $template.Junction -Clauses @($template.Clauses) -GroupBy $template.GroupBy
    $loaded=@(ConvertFrom-DomeniaQueryLibrary (ConvertTo-DomeniaQueryLibraryJson @($copy)))
    Expect ($loaded.Count -eq 1 -and $loaded[0].Id -ceq $copy.Id -and $null -eq $loaded[0].PSObject.Properties['Category']) ('User copy round trip keeps original recipe schema '+$template.Id)
}
# Compatibility: the original 19 IDs, names and condition semantics remain unchanged.
$legacy=@'
active|Comptes actifs|active|Equal|True
disabled|Comptes désactivés|active|Equal|False
never|Date de connexion AD non renseignée|logonDays|IsMissing|
created|Créés depuis 30 jours|createdRecent|Equal|True
password|Mot de passe machine ancien|passwordOld|Equal|True
laps|Expiration LAPS dépassée|laps|Equal|E
nolaps|Aucun attribut LAPS lu|laps|Equal|N
nokey|Aucune clé BitLocker visible dans AD|bitlocker|Equal|N
servers|Système AD contenant Server|os|Contains|Server
unchecked|Sans relevé utilisable|checkedDays|IsMissing|
oldcheck|Relevé de plus de 7 jours|checkedDays|Greater|7
lowdisk|C: moins de 10 % libre|diskFreePercent|Less|10
ram|Moins de 8 Go de RAM|ramGB|Less|8
uptime|Sans redémarrage depuis plus de 30 jours|uptimeDays|Greater|30
cpu|Charge CPU supérieure à 80 %|probe:hw.cpuload|Greater|80
services|Services automatiques arrêtés|probe:soft.stoppedauto|Greater|0
syserrors|Erreurs système depuis 24 h|probe:evt.syserrors|Greater|0
'@
foreach($line in ($legacy -split "`r?`n")){
    $p=$line.Split('|');$template=$byId['template.'+$p[0]]
    Expect ($null -ne $template -and $template.Name -ceq $p[1] -and @($template.Clauses).Count -eq 1 -and $template.Clauses[0].Field -ceq $p[2] -and $template.Clauses[0].Operator -ceq $p[3] -and [Convert]::ToString($template.Clauses[0].Value,[Globalization.CultureInfo]::InvariantCulture) -ceq $p[4]) ('Legacy template preserved '+$p[0])
}
Expect ($byId['template.all'].Name -ceq 'Tous les postes recensés' -and @($byId['template.all'].Clauses).Count -eq 0) 'Original all template unchanged'
$stale=$byId['template.stale'];Expect ($stale.Name -ceq 'Comptes actifs sans connexion depuis au moins 90 jours' -and $stale.Clauses.Count -eq 3) 'Original stale template identity preserved'
foreach($row in @(@(2,$true,$false),@(3,$true,$true),@(4,$true,$true),@(5,$true,$false),@(3,$false,$false))){
    $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$values['active']=$row[1];$values['logonBucket']=$row[0]
    $result=(ConvertTo-DomeniaCompiledQuery $stale).Evaluate($values)
    Expect (($result -eq [M4D.Admin.Common.Query.MatchState]::Match) -eq [bool]$row[2]) ('Stale boundary '+$row[0]+'/'+$row[1])
}
$values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
Expect ((ConvertTo-DomeniaCompiledQuery $byId['template.lowdisk']).Evaluate($values) -eq [M4D.Admin.Common.Query.MatchState]::Unknown) 'Missing disk is not a disk full match'
$values['diskFreePercent']=0
Expect ((ConvertTo-DomeniaCompiledQuery $byId['template.lowdisk']).Evaluate($values) -eq [M4D.Admin.Common.Query.MatchState]::Match) 'Measured zero disk remains a known value'
Expect ($byId['template.resource.review'].Junction -eq 'Any' -and $byId['template.active.lowdisk'].Junction -eq 'All') 'Operational AND and OR examples remain distinct'
foreach($pair in @(@('template.hw.batterypresent','hw.battery'),@('template.net.wifi','net.wifi'))){
    $probe=Get-DomeniaProbe $pair[1];$compiled=ConvertTo-DomeniaCompiledQuery $byId[$pair[0]]
    foreach($count in @(0,1,2,3)){
        $mapped=@(Get-DomeniaProbeValues -Probe $probe -Result ([pscustomobject]@{Count=$count;Rows=@();Error='';Truncated=$false}))
        $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$values['probe:'+$pair[1]]=[string]$mapped[0]
        Expect (($compiled.Evaluate($values) -eq [M4D.Admin.Common.Query.MatchState]::Match) -eq ($count -gt 0)) ('Mapped count includes all positive cardinalities '+$pair[1]+'/'+$count)
    }
    $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    Expect ($compiled.Evaluate($values) -eq [M4D.Admin.Common.Query.MatchState]::Unknown) ('Missing mapped count remains unknown '+$pair[1])
}
$signatures=@{};foreach($template in $templates){$key=($template|Select-Object Junction,Clauses,GroupBy|ConvertTo-Json -Depth 6 -Compress);Expect (-not $signatures.ContainsKey($key)) ('No duplicated recipe with another title '+$template.Id);$signatures[$key]=$true}
# A 5,000-workstation park can have 5,000 distinct console identities. Aggregate the complete set before top ten.
$large=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
for($i=0;$i -lt 5000;$i++){
    $values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$values['user']='user-'+$i
    $large.Add([M4D.Admin.Common.Query.QueryRecord]::new(('pc-'+$i),$values))
}
$distribution=Measure-DomeniaQueryWidget -Records $large -Recipe $byId['template.by.user']
Expect ($distribution.Total -eq 5000 -and $distribution.Matched -eq 5000 -and @($distribution.Items).Count -eq 11) '5000 distinct users aggregate into ten groups and Other'
$sum=0L;foreach($item in $distribution.Items){$sum+=[long]$item.Value}
Expect ($sum -eq 5000 -and @($distribution.Items|Where-Object{$_.Label -eq 'Autres valeurs'})[0].Value -eq 4990) 'No users lost beyond displayed categories'
$large.Add([M4D.Admin.Common.Query.QueryRecord]::new('unknown-user',[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)))
$distribution=Measure-DomeniaQueryWidget -Records $large -Recipe $byId['template.by.user']
Expect ($distribution.Total -eq 5001 -and @($distribution.Items).Count -eq 12 -and @($distribution.Items|Where-Object{$_.Label -eq 'Valeur inconnue'})[0].Value -eq 1) 'Unknown grouping remains separate without exceeding twelve segments'
$allJson=ConvertTo-Json -InputObject $templates -Depth 8 -Compress
Expect ($allJson -notmatch 'Win32_Product|probe:sec\.uac') 'Library never offers unsupported or MSI repair probes'
# The delivered models do not consume the 100 personal recipe slots or weaken that bound.
$personal=@(for($i=0;$i -lt 101;$i++){New-DomeniaQueryRecipe -Id ('personal.'+$i) -Name ('Personnel '+$i)})
$refused=$false;try{ConvertTo-DomeniaQueryLibraryJson $personal|Out-Null}catch{$refused=$_.Exception.Message -like '*100*'}
Expect $refused 'Personal recipe bound stays at 100'
$report=[pscustomobject]@{Suite='Domenia.QueryTemplates';PowerShell=[string]$PSVersionTable.PSVersion;Templates=$templates.Count;Categories=@($templates|Group-Object Category|ForEach-Object{[pscustomobject]@{Name=$_.Name;Count=$_.Count}});Pass=$checks.Count;Fail=0;Checks=$checks.ToArray();Scope='Actual shared DLL and adapters; no WPF, AD, WMI or network'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('Domenia QueryTemplates: '+$templates.Count+' templates; '+$checks.Count+' PASS')
