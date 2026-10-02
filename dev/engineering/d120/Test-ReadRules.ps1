[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$ReportPath)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'rules/Domenia.ReadRules.psm1') -Force
$rows=New-Object 'System.Collections.Generic.List[object]'
function Test-Rule([string]$Name,[scriptblock]$Body){
 try { & $Body; $rows.Add([pscustomobject]@{Name=$Name;Status='PASS'}) }
 catch { $rows.Add([pscustomobject]@{Name=$Name;Status='FAIL';Error=$_.Exception.Message}) }
}
function Assert-Rule([bool]$Value,[string]$Why='Assertion failed'){if(-not $Value){throw $Why}}
Test-Rule 'LDAP literal brackets and star' {Assert-Rule ((ConvertTo-DomeniaLdapLiteral 'a*(b)\c') -ceq 'a\2a\28b\29\5cc')}
Test-Rule 'LDAP literal null' {Assert-Rule ((ConvertTo-DomeniaLdapLiteral ([string][char]0)) -ceq '\00')}
Test-Rule 'LDAP literal apostrophe' {Assert-Rule ((ConvertTo-DomeniaLdapLiteral "O'Neil") -ceq "O'Neil")}
Test-Rule 'User to machine direction' {Assert-Rule ((Get-DomeniaRelationDirection 'Utilisateur').TargetType -eq 'Machine')}
Test-Rule 'Machine to user direction' {Assert-Rule ((Get-DomeniaRelationDirection 'Machine').TargetType -eq 'Utilisateur')}
$script:s=[pscustomobject]@{Domain='example.test';Guid='f4dc5a91-c11b-46b5-893d-9a2cbbad31ad';Type='Utilisateur';Reader='reader';Session='test';Generation='1'}
$script:t=[pscustomobject]@{Domain='example.test';Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2';Type='Machine';Reader='reader';Session='test';Generation='1'}
Test-Rule 'Both identities confirmed' {Assert-Rule (Test-DomeniaRelationConfirmation $s $s $t $t)}
Test-Rule 'Both directions confirmed' {Assert-Rule (Test-DomeniaRelationConfirmation $t $t $s $s)}
Test-Rule 'Null identity rejected' {Assert-Rule (-not (Test-DomeniaSameSubject $s $null))}
foreach($field in @('Domain','Guid','Type','Reader','Session','Generation')){
 $script:field=$field
 Test-Rule ('Identity change '+$field) { $copy=$s.PSObject.Copy();$copy.$field='changed';Assert-Rule (-not (Test-DomeniaSameSubject $s $copy)) }
}
Test-Rule 'Same types do not associate' {Assert-Rule (-not (Test-DomeniaRelationConfirmation $s $s $s $s))}
Test-Rule 'Stale readable not editable' {$r=Get-DomeniaCacheReadPolicy $true $true $false $false $false;Assert-Rule ($r.CanView -and $r.CanCopy -and -not $r.CanEdit)}
Test-Rule 'Offline never editable' {$r=Get-DomeniaCacheReadPolicy $true $true $true $true $false;Assert-Rule (-not $r.CanEdit)}
Test-Rule 'Uncertain write never editable' {$r=Get-DomeniaCacheReadPolicy $true $true $true $false $true;Assert-Rule (-not $r.CanEdit)}
Test-Rule 'Identity mismatch not visible' {$r=Get-DomeniaCacheReadPolicy $true $false $true $false $false;Assert-Rule (-not $r.CanView)}
Test-Rule 'Domain root not silently scanned' {$r=Get-DomeniaDetectionScopePlan -RequestedScope OU -OuDn 'DC=example,DC=test' -DomainDn 'DC=example,DC=test';Assert-Rule (-not $r.Allowed)}
Test-Rule 'No candidate no silent fallback' {$r=Get-DomeniaDetectionScopePlan -RequestedScope Candidates;Assert-Rule (-not $r.Allowed -and $r.Scope -eq 'Candidates')}
Test-Rule 'Candidates deduplicate identity' {$r=Get-DomeniaDetectionScopePlan -RequestedScope Loaded -Candidates @($t,$t);Assert-Rule ($r.Candidates.Count -eq 1)}
Test-Rule 'Unknown proof not percent' {Assert-Rule ((Get-DomeniaEvidenceKind '97') -eq 'Source a verifier')}
Test-Rule 'Manual proof declared' {Assert-Rule ((Get-DomeniaEvidenceKind 'Manuel') -eq 'Declare')}
Test-Rule 'Console proof observed' {Assert-Rule ((Get-DomeniaEvidenceKind 'Console CIM/DCOM') -eq 'Observe')}
Test-Rule 'Counter 100 capped' {Assert-Rule ((Get-DomeniaCounterText 100) -eq '99+')}
Test-Rule 'User columns exclude console' {Assert-Rule ('ConsoleUser' -notin @(Get-DomeniaResultColumns 'Utilisateur'))}
Test-Rule 'Machine columns include console' {Assert-Rule ('ConsoleUser' -in @(Get-DomeniaResultColumns 'Machine'))}
$fail=@($rows|Where-Object Status -eq 'FAIL').Count
$r=[ordered]@{Kind='IsolatedPureRules';PSVersion=$PSVersionTable.PSVersion.ToString();Platform=[Environment]::OSVersion.Platform.ToString();Passed=$rows.Count-$fail;Failed=$fail;ApplicationIntegrated=$false;WpfExecuted=$false;DomainAccessed=$false;Tests=$rows.ToArray()}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($r|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if($fail){exit 1};exit 0
