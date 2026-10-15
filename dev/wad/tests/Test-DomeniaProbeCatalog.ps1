#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
. (Join-Path $modules 'Domenia-Probes.Model.ps1')
$checks=[Collections.Generic.List[object]]::new()
function Expect($ok,$why){if(-not $ok){throw $why}}
function Case($name,[scriptblock]$body){try{&$body;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
Case 'Every detailed probe has a unique safe class and complete source metadata' {
 $all=@(Get-DomeniaProbeCatalog);$extended=@(Get-DomeniaExtendedProbeCatalog)
 Expect ($extended.Count -eq 32) 'Expected 32 documented detailed probes'
 Expect (@($all.Id|Sort-Object -Unique).Count -eq $all.Count) 'Duplicate ID'
 foreach($p in $extended){Expect ($p.Description -and $p.Rights -and $p.Compatibility -and $p.UnknownMeaning -and $p.Limitations -and $p.SourceUrls.Count) ('Metadata missing '+$p.Id);Expect ($p.ProviderQualification -eq 'À qualifier sous Windows') ('False Windows qualification '+$p.Id);foreach($url in $p.SourceUrls){Expect ($url -match '^https://(learn\.microsoft\.com/|github\.com/(microsoft|MicrosoftDocs)/)') ('Non-primary source '+$p.Id)}}
}
Case 'Property metadata keeps units types arrays and provider field names' {
 foreach($p in @(Get-DomeniaExtendedProbeCatalog)){
  Expect ((@($p.Properties) -join ',') -ceq (@($p.Fields.Name) -join ',')) ('Metadata projection mismatch '+$p.Id)
  foreach($f in $p.Fields){Expect ($f.Kind -in @('Text','Number','Boolean','Timestamp')) ('Unknown query kind '+$f.Name);Expect ([bool]$f.IsArray -eq ([string]$f.CimType).EndsWith('[]')) ('Array flattened '+$f.Name);if($f.IsArray){Expect ($f.Kind -eq 'Text') 'Array fabricated as scalar number'}}
 }
 $array=Get-DomeniaProbe 'hw.memoryarrays';$max=@($array.Fields|Where-Object Name -eq MaxCapacityEx)[0];Expect ($max.CimType -eq 'uint64' -and $max.Unit -eq 'Ko') 'Memory array capacity wrong unit'
 $net=Get-DomeniaProbe 'net.configurations';Expect (@($net.Fields|Where-Object{$_.IsArray}).Count -eq 4) 'Network lists incomplete'
}
Case 'No mutation methods MSI side effects secrets or command arguments in projections' {
 foreach($p in @(Get-DomeniaProbeCatalog)){
  Expect ($p.Class -notmatch '^(Win32_Product|CIM_Product|Win32_SoftwareFeature)$') ('MSI provider '+$p.Id)
  foreach($name in @($p.Properties)){Expect ($name -notmatch '(?i)(Password|RecoveryKey|NumericalPassword|PrivateKey|CommandLine|^Command$|^Actions$|^Principal$)') ('Sensitive property '+$p.Id+':'+$name)}
 }
 Expect ($null -eq (Get-DomeniaProbe 'sec.uac')) 'Fake EnableLUA measure remains'
}
Case 'BitLocker TPM firewall and DeviceGuard do not claim unsupported security state' {
 $bit=Get-DomeniaProbe 'sec.bitlockervolumes';Expect ($bit.Properties -contains 'ProtectionStatus' -and $bit.Properties -contains 'ConversionStatus' -and $bit.Limitations -like '*suspendue*') 'Encryption/protection conflated'
 Expect ((Get-DomeniaProbe 'sec.bitlocker').Name -like 'Protection*') 'Old caption misleading'
 $guard=Get-DomeniaProbe 'sec.deviceguard';Expect ($guard.Limitations -like '*pas une preuve*') 'Secure Boot support treated as enabled'
 $fw=Get-DomeniaProbe 'sec.firewallprofiles';Expect ($fw.Limitations -like '*ne prouve pas*actif*') 'Default provider claimed effective policy'
 Expect ((Get-DomeniaProbe 'sec.tpmdetails').Properties -notcontains 'ManufacturerIdTxt') 'Undocumented TPM property'
}
Case 'Battery zero QFE coverage process sample and task limitations are explicit' {
 Expect ((Get-DomeniaProbe 'hw.batteries').Limitations -like '*zéro*non exposé*') 'Zero battery capacity called measured'
 Expect ((Get-DomeniaProbe 'soft.hotfixdetails').Limitations -like '*pas toutes*mises à jour*') 'QFE claimed complete'
 Expect ((Get-DomeniaProbe 'soft.processdetails').Limitations -like '*échantillon unique*') 'Single sample CPU invented'
 $task=Get-DomeniaProbe 'soft.scheduledtasks';Expect ($task.Properties -notcontains 'LastRunTime' -and $task.Properties -notcontains 'LastTaskResult') 'Nonexistent task properties'
}
Case 'Points 81 to 98: added probes state what they cannot prove' {
 $usage=Get-DomeniaProbe 'hw.memoryusage';Expect (@($usage.Fields|Where-Object{$_.Unit -eq 'Ko'}).Count -eq 4 -and $usage.Mode -eq 'First') 'Memory usage units or mode wrong'
 Expect ($usage.Limitations -like '*instantan*' -and $usage.Limitations -like '*barrettes*') 'Instant memory measure presented as capacity'
 Expect ((Get-DomeniaProbe 'hw.computersystem').Limitations -like '*ne prouve pas une machine virtuelle*') 'Hypervisor flag treated as a virtual machine'
 Expect ((Get-DomeniaProbe 'hw.batterycycles').Limitations -like '*z*ro*non renseign*') 'Zero cycle count treated as a new battery'
 foreach($id in @('hw.batterystatic','hw.batteryfullcharge','hw.batterycycles')){$b=Get-DomeniaProbe $id;Expect ($b.Namespace -eq 'root\wmi' -and $b.Properties -contains 'InstanceName') ('Battery driver class without a join key '+$id)}
 Expect ((Get-DomeniaProbe 'hw.monitorconnections').Limitations -like '*station d*accueil*') 'Docking station identification claimed'
 $profiles=Get-DomeniaProbe 'net.connectionprofiles';Expect ($profiles.Transform -like 'Map:*2=Domaine*' -and $profiles.Properties[0] -eq 'NetworkCategory') 'Network category not mapped'
 Expect ((Get-DomeniaProbe 'sec.avproducts').Limitations -like '*pas document*') 'Undocumented productState decoding presented as fact'
 Expect ((Get-DomeniaProbe 'os.freeram').Limitations -like '*instantan*') 'Covered historical probe lost the documented limitation'
 Expect ((Get-DomeniaProbe 'os.caption').Limitations -notlike '*instantan*') 'Unrelated limitation inherited from another projection of the class'
 Expect (@((Get-DomeniaProbe 'os.caption').SourceUrls).Count -eq 1) 'Class documentation not inherited'
}
Case 'Detailed probes are read only projection payloads and retain one identity per instance' {
 $ids=@('disk.volumes','disk.physical','net.configurations','soft.servicedetails','sec.bitlockervolumes')
 $payload=@(ConvertTo-DomeniaProbePayload -Ids ($ids+$ids))
 Expect ($payload.Count -eq $ids.Count) 'Duplicated collection'
 foreach($p in $payload){Expect ($p.Mode -eq 'All' -and $p.Properties.Count -gt 2) ('Lost detailed projection '+$p.Id);Expect ((@($p.PSObject.Properties.Name) -join ',') -eq 'Id,Namespace,Class,Properties,Filter,Mode,Skip') 'Unreviewed worker code or metadata sent'}
}
Case 'Historical single-field probes inherit documented metadata conservatively' {
 $ram=Get-DomeniaProbe 'hw.batterylevel';Expect ($ram.Fields[0].Kind -eq 'Number' -and $ram.Fields[0].CimType -eq 'uint16') 'Known provider type lost'
 $caption=Get-DomeniaProbe 'os.caption';Expect ($caption.Fields[0].Kind -eq 'Text') 'Undocumented numeric type fabricated'
 Expect ((Get-DomeniaProbe 'sec.shares').Name -notlike '*hors administratifs*') 'Unsupported administrative share exclusion'
}
Case 'Catalogue modules parse and do not invoke providers while loading' {
 foreach($name in @('ProbeCatalog.Model','Probes.Model')){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $modules ('Domenia-'+$name+'.ps1')),[ref]$tokens,[ref]$errors);Expect (@($errors).Count -eq 0) ($name+' '+($errors|Out-String))}
 $source=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-ProbeCatalog.Model.ps1'))
 Expect ($source -notmatch '(?i)\b(Get-CimInstance|Get-WmiObject|Invoke-CimMethod|Invoke-WmiMethod|Invoke-Command)\b') 'Provider invoked by catalog'
}
Case 'Points 135-136 : contrat de chaque sonde affiche dans le selecteur et les details, sonde refusee jamais proposee' {
 . (Join-Path $modules 'Domenia-ProbeContract.Model.ps1')
 $script:DomeniaProbeContracts=$null
 $entry=Get-DomeniaProbeContract 'sec.bitlocker'
 Expect ($null -ne $entry -and $entry.Check.Valid -and $entry.Contract.Privilege.Level -eq 'AdministrateurLocal') 'Contrat de sonde absent ou refuse'
 Expect ((Get-DomeniaProbeContractSummary $entry.Contract) -match '^Droits : administrateur local du poste\. Coût : ') 'Resume du contrat'
 Expect ([object]::ReferenceEquals($entry,(Get-DomeniaProbeContract 'sec.bitlocker'))) 'Contrat recalcule a chaque lecture'
 Expect ($null -eq (Get-DomeniaProbeContract 'sonde.inconnue')) 'Contrat invente pour une sonde absente'
 $widgets=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Widgets.UI.ps1'))
 $sources=$widgets.Substring($widgets.IndexOf('function Get-DomeniaBoardSources'))
 $sources=$sources.Substring(0,$sources.IndexOf('function Get-DomeniaBoardPreviewEntry'))
 Expect ($sources.Contains('Get-DomeniaProbeContract ([string]$probe.Id)') -and $sources.Contains('-not [bool]$contractEntry.Check.Valid') -and $sources.Contains('Get-DomeniaProbeContractSummary $contractEntry.Contract')) 'Selecteur de widgets non raccorde au contrat'
 $details=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-ProbeDetails.UI.ps1'))
 Expect ($details.Contains('Get-DomeniaProbeContractLines') -and $details.Contains('Get-DomeniaProbeIsolationPlan') -and $details.Contains("Header='Contrat de la sonde'")) 'Details de la sonde sans contrat'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='ProbeCatalog';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;ProviderExecuted=$false;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
