#requires -Version 5.1
# Compile the actual shipped library against the real common DLL; no directory, endpoint or UI access.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$QuerySource)
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
if($QuerySource){Add-Type -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'vendor/m4d-admin-common/src/Query/QueryEngine.cs')}else{Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')}
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new()
function Expect([bool]$Good,[string]$Name){$checks.Add([pscustomobject]@{Name=$Name;Pass=$Good});if(-not $Good){throw $Name}}
$templates=@(Get-DomeniaQueryTemplates)
$fields=@(Get-DomeniaQueryFields);$probes=@(Get-DomeniaProbeCatalog)
Expect ($templates.Count -ge 400 -and $templates.Count -le 700) 'Large bounded catalog of useful operational templates'
Expect (@($templates.Id|Sort-Object -Unique).Count -eq $templates.Count) 'Unique template IDs'
Expect (@($templates.Name|Sort-Object -Unique).Count -eq $templates.Count) 'Distinct user-facing titles'
Expect (@($templates.Category|Sort-Object -Unique).Count -ge 10) 'Operational categories are represented'
foreach($entry in @(Get-DomeniaQueryCatalog)){
    Expect ($entry.Cost -and $entry.Freshness -and $entry.Availability -and $entry.Collection) ('Source, freshness, prerequisites and collection cost '+$entry.Id)
    if($entry.Kind -eq 'Boolean'){Expect ($entry.Choices.Count -eq 2 -and $entry.Choices[0].Value -is [bool] -and $entry.Choices[1].Value -is [bool]) ('Typed Boolean choices '+$entry.Id)}
}
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
    $copy=Copy-DomeniaQueryRecipe $template -Id ('copy.'+$template.Id)
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
$signatures=@{};foreach($template in $templates){$key=($template|Select-Object Junction,Clauses,GroupBy,Parameters,Expression|ConvertTo-Json -Depth 12 -Compress);Expect (-not $signatures.ContainsKey($key)) ('No duplicated recipe with another title '+$template.Id);$signatures[$key]=$true}
# Point 65: parameterised models receive threshold, software, version, OU and period through typed values.
$parameterised=@($templates|Where-Object{$_.Category -ceq 'Modèles paramétrés'})
Expect ($parameterised.Count -eq 7 -and @($parameterised|Where-Object{$_.Format -ceq 'Domenia.Query/2' -and @($_.Parameters).Count -eq 1}).Count -eq 7) 'Seven delivered models carry one typed parameter each'
foreach($field in @('diskFreePercent','ramGB','logonDays','inventoryDays','dn','observedRelease','instance:soft.servicedetails:Name')){Expect (@($parameterised|Where-Object{$_.Parameters[0].Field -ceq $field}).Count -eq 1) ('Parameterised model for '+$field)}
foreach($template in $parameterised){foreach($definition in @($template.Parameters)){Expect ([string]$definition.Label -and $null -ne $definition.Default) ('Parameter has a French label and an editable example '+$template.Id)}}
$disk=$byId['template.param.diskfree']
$records=[Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]]::new()
foreach($free in @(5,15,30)){$values=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal);$values['diskFreePercent']=$free;$records.Add([M4D.Admin.Common.Query.QueryRecord]::new(('disk-'+$free),$values))}
$records.Add([M4D.Admin.Common.Query.QueryRecord]::new('disk-unknown',[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)))
$default=Measure-DomeniaQueryWidget -Records $records -Recipe $disk
Expect ($default.Matched -eq 1 -and $default.Unknown -eq 1 -and $default.NotMatched -eq 2) 'Default threshold 10 % selects one disk and keeps the unknown one apart'
$custom=Copy-DomeniaQueryRecipe $disk;$custom.ParameterValues=@{Seuil='20 %'}
$measured=Measure-DomeniaQueryWidget -Records $records -Recipe $custom
Expect ($measured.Matched -eq 2 -and $measured.Unknown -eq 1) 'A typed value with its unit changes the threshold without editing the conditions'
$resolved=Resolve-DomeniaQueryParameters $custom
Expect ($resolved.Clauses[0].Value -is [decimal] -and $resolved.Clauses[0].Value -eq 20 -and @($resolved.Parameters).Count -eq 0) 'Resolution freezes a typed decimal and removes the parameter list'
$custom.ParameterValues=@{Seuil='150 %'};$failed='';try{[void](ConvertTo-DomeniaCompiledQuery $custom)}catch{$failed=$_.Exception.Message}
Expect ($failed -like 'Espace libre minimal sur C: : valeur attendue inférieure ou égale à 100 %*') 'Bounds are explained with the French label and unit'
$custom.ParameterValues=@{Seuil='8 Go'};$failed=$false;try{[void](ConvertTo-DomeniaCompiledQuery $custom)}catch{$failed=$true}
Expect $failed 'An incompatible unit is refused'
$custom.ParameterValues=@{Seuil=''};$failed='';try{[void](ConvertTo-DomeniaCompiledQuery $custom)}catch{$failed=$_.Exception.Message}
Expect ($failed -like 'Renseignez le paramètre Espace libre minimal sur C:*') 'An empty value names the missing parameter'
$service=Copy-DomeniaQueryRecipe $byId['template.param.service'];$service.ParameterValues=@{Service='WinRM'}
Expect ((Resolve-DomeniaQueryParameters $service).Expression.Children[0].Children[0].Children[0].Clause.Value -ceq 'WinRM') 'A software parameter reaches the nested collection condition'
$bad=Copy-DomeniaQueryRecipe $disk;$bad.Parameters[0]|Add-Member -NotePropertyName Script -NotePropertyValue 'Get-Process'
$failed=$false;try{[void](ConvertTo-DomeniaCompiledQuery $bad)}catch{$failed=$true};Expect $failed 'Unknown parameter properties are refused'
$bad=Copy-DomeniaQueryRecipe $byId['template.param.ou'];$bad.Parameters[0]|Add-Member -NotePropertyName Minimum -NotePropertyValue 1
$failed=$false;try{[void](ConvertTo-DomeniaCompiledQuery $bad)}catch{$failed=$true};Expect $failed 'Bounds on a text parameter are refused'
$tooMany=Copy-DomeniaQueryRecipe $disk;$tooMany.Parameters=@(for($i=0;$i -lt 33;$i++){[pscustomobject]@{Name=('P'+$i);Field='diskFreePercent';Default=10}})
$failed=$false;try{[void](ConvertTo-DomeniaCompiledQuery $tooMany)}catch{$failed=$true};Expect $failed 'More than 32 parameters are refused'
$rows=@(Get-DomeniaQueryParameterRows $custom)
Expect ($rows.Count -eq 1 -and $rows[0].Label -ceq 'Espace libre minimal sur C:' -and $rows[0].Hint -like 'Nombre en % (unités usuelles acceptées), de 0 % à 100 %') 'Typed form row explains the accepted entry'
$rows=@(Get-DomeniaQueryParameterRows $byId['template.param.ou'])
Expect ($rows[0].Kind -ceq 'Text' -and $rows[0].ValueLabel -ceq 'OU=Postes') 'Text parameter shows its editable example'
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
# The delivered models do not consume the 5000 personal recipe slots or weaken that bound.
$personal=@(for($i=0;$i -lt 5001;$i++){New-DomeniaQueryRecipe -Id ('personal.'+$i) -Name ('Personnel '+$i)})
$refused=$false;try{ConvertTo-DomeniaQueryLibraryJson $personal|Out-Null}catch{$refused=$_.Exception.Message -like '*5 000*'}
Expect $refused 'Personal recipe bound is explicit at5000'
$report=[pscustomobject]@{Suite='Domenia.QueryTemplates';PowerShell=[string]$PSVersionTable.PSVersion;Templates=$templates.Count;Categories=@($templates|Group-Object Category|ForEach-Object{[pscustomobject]@{Name=$_.Name;Count=$_.Count}});Pass=$checks.Count;Fail=0;Checks=$checks.ToArray();Scope='Actual shared DLL and adapters; no WPF, AD, WMI or network'}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('Domenia QueryTemplates: '+$templates.Count+' templates; '+$checks.Count+' PASS')
