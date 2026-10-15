#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';Set-StrictMode -Version 2
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($n in @('Common.Model','HealthRules.Model','HealthRules.UI','Boards.Model','BoardFleet.Model')){. (Join-Path $modules ('Domenia-'+$n+'.ps1'))}
$checks=[Collections.Generic.List[object]]::new();$domain='DC=example,DC=invalid';$ou='OU=Office,'+$domain;$child='OU=Child,'+$ou
function Expect($value,$why){if(-not $value){throw $why}}
function Case($name,[scriptblock]$code){try{&$code;$checks.Add([pscustomobject]@{Name=$name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function Throws([scriptblock]$code){$caught=$false;try{&$code|Out-Null}catch{$caught=$true};Expect $caught 'Expected rejection'}
Case 'Default and OU overrides inherit independently without copying unaffected fields' {
 $book=ConvertTo-DomeniaHealthPolicyBook $null $domain;$p=Resolve-DomeniaHealthPolicy $book $ou;$p.Thresholds.StaleDays=45;$book=Set-DomeniaHealthScopePolicy $book $ou $p
 $p=Resolve-DomeniaHealthPolicy $book $child;$p.Thresholds.UptimeDays=7;$book=Set-DomeniaHealthScopePolicy $book $child $p
 Expect ($book.Scopes[1].Overrides.Thresholds.PSObject.Properties.Name -eq 'UptimeDays') 'Child copied inherited values'
 $p=Resolve-DomeniaHealthPolicy $book $ou;$p.Thresholds.StaleDays=30;$book=Set-DomeniaHealthScopePolicy $book $ou $p;$resolved=Resolve-DomeniaHealthPolicy $book $child
 Expect ($resolved.Thresholds.StaleDays -eq 30 -and $resolved.Thresholds.UptimeDays -eq 7 -and $resolved.Origin.Local -and $resolved.Origin.Ancestors.Count -eq 2) 'Parent change lost or child override overwritten'
 $book=Set-DomeniaHealthScopePolicy $book $child -Remove;$resolved=Resolve-DomeniaHealthPolicy $book $child
 Expect (-not $resolved.Origin.Local -and $resolved.Thresholds.UptimeDays -eq 30 -and $resolved.Origin.SourceDn -eq $ou) 'Reset did not restore inheritance'
}
Case 'Disabled rule inherits; an explicit descendant re-enable overrides only that rule' {
 $book=ConvertTo-DomeniaHealthPolicyBook $null $domain;$p=Resolve-DomeniaHealthPolicy $book $ou;$p.DisabledRules=@('lowdisk');$book=Set-DomeniaHealthScopePolicy $book $ou $p
 $p=Resolve-DomeniaHealthPolicy $book $child;Expect (-not (Test-DomeniaHealthRuleEnabled $p lowdisk)) 'Parent disabled rule ignored';$p.DisabledRules=@();$book=Set-DomeniaHealthScopePolicy $book $child $p
 Expect (Test-DomeniaHealthRuleEnabled (Resolve-DomeniaHealthPolicy $book $child) lowdisk) 'Child cannot enable rule'
}
Case 'Explicit removal of inherited custom rules survives JSON roundtrip' {
 $r=@{Id=('custom.'+('a'*32));Name='Custom';Measure='DiskFree';Operator='LessThan';Threshold=15;Severity='Warn';Enabled=$true}
 $book=ConvertTo-DomeniaHealthPolicyBook @{Default=@{CustomRules=@($r)}} $domain;$p=Resolve-DomeniaHealthPolicy $book $ou;$p.CustomRules=@();$book=Set-DomeniaHealthScopePolicy $book $ou $p
 $book=ConvertTo-DomeniaHealthPolicyBook ($book|ConvertTo-Json -Depth 15 -Compress) $domain -Strict
 Expect ((Resolve-DomeniaHealthPolicy $book $ou).CustomRules.Count -eq 0 -and (Resolve-DomeniaHealthPolicy $book ('OU=Other,'+$domain)).CustomRules.Count -eq 1) 'Empty override vanished or affected sibling'
}
Case 'Foreign domains, escaped separators, duplicate scopes and malformed values are rejected' {
 $book=ConvertTo-DomeniaHealthPolicyBook $null $domain;Throws {Resolve-DomeniaHealthPolicy $book 'OU=Office,DC=foreign,DC=invalid'}
 Throws {ConvertTo-DomeniaHealthPolicyBook @{DomainDn='DC=foreign,DC=invalid'} $domain}
 $p=Resolve-DomeniaHealthPolicy $book $ou;$p.Thresholds.StaleDays=7;$book=Set-DomeniaHealthScopePolicy $book $ou $p
 Expect ((Resolve-DomeniaHealthPolicy $book ('OU=Child\,OU=Office,'+$domain)).Thresholds.StaleDays -eq 90) 'Escaped RDN inherited unrelated OU'
 Throws {ConvertTo-DomeniaHealthPolicyBook @{Scopes=@($book.Scopes[0],$book.Scopes[0])} $domain -Strict}
 Throws {Set-DomeniaHealthScopePolicy $book ('CN=PC,'+$ou) $p}
}
Case 'A parent threshold change cannot make a descendant threshold pair invalid' {
 $book=ConvertTo-DomeniaHealthPolicyBook $null $domain;$p=Resolve-DomeniaHealthPolicy $book $ou;$p.Thresholds.DiskFreeWarn=15;$book=Set-DomeniaHealthScopePolicy $book $ou $p
 $default=Resolve-DomeniaHealthPolicy $book '';$default.Thresholds.DiskFreeAlert=18
 Throws {Set-DomeniaHealthScopePolicy $book '' $default}
 Expect ((Resolve-DomeniaHealthPolicy $book $ou).Thresholds.DiskFreeWarn -eq 15) 'Rejected save mutated original book'
}
$script:Saved=@{};$script:Conn=[pscustomobject]@{BaseDn=$domain}
function Get-DomeniaSetting($Key,$Default){if($script:Saved.ContainsKey($Key)){return $script:Saved[$Key]};return $Default}
function Set-DomeniaSetting($Key,$Value){$script:Saved[$Key]=$Value}
function Save-DomeniaSettings([switch]$Immediate){}
Case 'Preference authority is separated by domain and stores only the explicit OU override' {
 $p=Get-DomeniaStoredHealthPolicy $ou;$p.Thresholds.StaleDays=17;Save-DomeniaHealthPolicy $p $ou
 Expect ((Get-DomeniaStoredHealthPolicy $child).Thresholds.StaleDays -eq 17 -and $script:Saved.Count -eq 1) 'Scoped preference not persisted'
 $script:Conn.BaseDn='DC=other,DC=invalid';Expect ((Get-DomeniaStoredHealthPolicy 'OU=Office,DC=other,DC=invalid').Thresholds.StaleDays -eq 90) 'Foreign domain inherited saved policy'
 $script:Conn.BaseDn=$domain;Save-DomeniaHealthPolicy -ScopeDn $ou -RemoveOverride;Expect ((Get-DomeniaStoredHealthPolicy $ou).Thresholds.StaleDays -eq 90) 'Stored reset failed'
}
Case 'Point 76: the editor sees inherited origins, local exceptions and every exception scope' {
 $p=Get-DomeniaStoredHealthPolicy $ou;$p.Thresholds.StaleDays=21;Save-DomeniaHealthPolicy $p $ou
 $p=Get-DomeniaStoredHealthPolicy $child;$p.Thresholds.UptimeDays=9;Save-DomeniaHealthPolicy $p $child
 $book=Get-DomeniaStoredHealthPolicyBook;$rows=@{};foreach($o in @(Get-DomeniaHealthPolicyOrigins -Book $book -ScopeDn $child)){$rows[$o.Kind+'|'+$o.Id]=$o}
 Expect (($rows['Seuil|StaleDays'].Origin -eq 'Hérité de OU=Office') -and [bool]$rows['Seuil|UptimeDays'].Local -and ($rows['Seuil|DiskFreeAlert'].Origin -eq 'Règles par défaut du domaine')) 'Origins not visible'
 $exceptions=@(Get-DomeniaHealthPolicyExceptions -Book $book)
 Expect (($exceptions.Count -eq 2) -and ($exceptions[1].Changes -match 'Redémarrage ancien \(jours\) : 9 \(hérité : 30\)')) 'Exceptions not listed with their inherited value'
 Expect ((@(Get-DomeniaHealthEditorScopes -Book $book -CurrentDn '')|ForEach-Object{$_.Dn}) -contains $child) 'Exception scope unreachable from the editor'
 Save-DomeniaHealthPolicy -ScopeDn $child -RemoveOverride;Save-DomeniaHealthPolicy -ScopeDn $ou -RemoveOverride
 Expect (@(Get-DomeniaHealthPolicyExceptions -Book (Get-DomeniaStoredHealthPolicyBook)).Count -eq 0) 'Removed exceptions still listed'
}
Case 'Point 77: saving an OU from the editor keeps inheriting suspensions after the purge of ended ones' {
 $now=[datetime]::UtcNow;$ended=[pscustomobject]@{RuleId='lowdisk';Reason='Ancienne campagne';UntilUtc=$now.AddDays(-40).ToString('o')}
 Save-DomeniaHealthPolicy (ConvertTo-DomeniaHealthPolicy @{Suspensions=@($ended)} -Strict) ''
 $p=Get-DomeniaStoredHealthPolicy $ou;$limits=@{};foreach($q in $p.Thresholds.PSObject.Properties){$limits[$q.Name]=[string]$q.Value};$limits.StaleDays='33'
 $editor=New-DomeniaHealthEditorPolicy -Thresholds $limits -DisabledRules @($p.DisabledRules) -CustomRules @($p.CustomRules) -Suspensions @($p.Suspensions) -NowUtc $now
 Expect (@($p.Suspensions).Count -eq 1) 'Ended domain suspension not inherited';Expect (@($editor.Suspensions).Count -eq 0) 'Editor kept a suspension ended 40 days ago'
 Save-DomeniaHealthPolicy $editor $ou
 $record=@(@((Get-DomeniaStoredHealthPolicyBook).Scopes)|Where-Object{[string]$_.ScopeDn -ieq $ou})[0]
 Expect (($null -eq $record.Overrides.Suspensions) -and ($record.Overrides.Thresholds.StaleDays -eq 33)) 'Purge stored a local suspensions exception'
 Save-DomeniaHealthPolicy (ConvertTo-DomeniaHealthPolicy @{Suspensions=@([pscustomobject]@{RuleId='stale';Reason='Migration des comptes';UntilUtc=$now.AddDays(7).ToString('o')})} -Strict) ''
 Expect ($null -ne (Get-DomeniaHealthSuspension (Get-DomeniaStoredHealthPolicy $ou) 'stale' -NowUtc $now)) 'Later domain suspension did not reach the OU'
 Save-DomeniaHealthPolicy -ScopeDn $ou -RemoveOverride;Save-DomeniaHealthPolicy (ConvertTo-DomeniaHealthPolicy $null) ''
 Expect (@((Get-DomeniaStoredHealthPolicyBook).Scopes).Count -eq 0) 'Test policy not reset'
}
Case 'Computer and fleet explanations identify formula and disabled effects' {
 $d=New-DomeniaBoardData Computer;$d.HealthPolicy=ConvertTo-DomeniaHealthPolicy @{DisabledRules=@('memory')};Add-DomeniaBoardAttention $d Alert 'Disk critical' lowdisk;Complete-DomeniaBoardData $d|Out-Null
 Expect ($d.HealthExplanation.Summary -match '25' -and $d.HealthExplanation.DisabledRules -eq 1) 'Computer score unexplained'
 $memory=@($d.HealthExplanation.Rows|Where-Object Id -eq memory)[0];$disk=@($d.HealthExplanation.Rows|Where-Object Id -eq lowdisk)[0]
 Expect ($memory.Status -eq 'Désactivée' -and $memory.Effect -eq 'Exclue du score' -and $disk.Effect -eq '-25 point(s)') 'Rule contribution incorrect'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count;$report=[pscustomobject]@{Suite='HealthPolicies';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;WpfExecuted=$false;NetworkUsed=$false;Checks=$checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$checks|Where-Object{-not $_.Passed}|Format-List|Out-String|Write-Output;Write-Output (($checks.Count-$failed).ToString()+'/'+$checks.Count+' passed');if($failed){exit 1}
