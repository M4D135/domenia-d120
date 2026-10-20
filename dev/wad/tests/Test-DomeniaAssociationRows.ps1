#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Minor -ne 1 -or -not [Environment]::Is64BitProcess){throw 'Windows PowerShell 5.1 x64 requis.'}
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'modules/Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Live.Model.ps1')
. (Join-Path $wad 'modules/Domenia-AssociationRows.UI.ps1')
$checks=[Collections.Generic.List[object]]::new()
function Assert {param($Condition,[string]$Why)if(-not $Condition){throw $Why}}
function Case {param($Name,[scriptblock]$Body)try{& $Body|Out-Null;$status='Passed';$detail=''}catch{$status='Failed';$detail=$_.Exception.Message+' '+$_.ScriptStackTrace};$checks.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail});if(-not $Quiet -or $status -eq 'Failed'){Write-Host ($Name+': '+$status+' '+$detail)}}
function New-Row {param([string]$Type='Machine',[string]$Name='PC1')return [pscustomobject]@{Type=$Type;Name=$Name;UPN='';Login='';Guid='00000000-0000-0000-0000-000000000001';Association='old';LinkSource='old';LinkConfidence='old'}}
function Get-LinksForComputer {param($Computer,$Guid)$script:Lookup=@($Computer,$Guid);if($script:LookupFails){throw 'local store unavailable'};return $script:Links}
function Get-LinksForUser {param($UserLogin,$Guid)$script:Lookup=@($UserLogin,$Guid);if($script:LookupFails){throw 'local store unavailable'};return $script:Links}
function Get-DomeniaLinkIdentityNote {param($Link,$Kind,$Guid)$script:IdentityCalls.Add([pscustomobject]@{Kind=$Kind;Guid=$Guid});return [string]$Link.Note}
function Select-DomeniaBestLink {param($Links)return @($Links|Sort-Object Confidence -Descending)[0]}
function Write-AppLog {param($Text,$Level)$script:Logs.Add([string]$Text)}
function Write-DomeniaSwallowed {param($Category,$Operation,$ErrorRecord)throw $ErrorRecord}
function Reset-Fixture {$script:Links=@();$script:Lookup=@();$script:LookupFails=$false;$script:Logs=[Collections.Generic.List[string]]::new();$script:IdentityCalls=[Collections.Generic.List[object]]::new()}
Case 'An absent association clears obsolete metadata and preserves row identity and order' {
 Reset-Fixture;$a=New-Row;$b=New-Row Groupe GROUP1;$result=@(Set-RowAssociationMetadata @($a,$null,$b))
 Assert ($result.Count -eq 2 -and [object]::ReferenceEquals($result[0],$a) -and [object]::ReferenceEquals($result[1],$b)) 'row identity/order'
 Assert ($a.Association -eq '' -and $a.LinkSource -eq '' -and $a.LinkConfidence -eq '' -and $b.Association -eq '') 'obsolete association cleared'
}
Case 'User links retain unique sorted names and sources with numeric confidence fallback' {
 Reset-Fixture;$row=New-Row Utilisateur Alice;$row.Login='EXAMPLE\alice'
 $script:Links=@([pscustomobject]@{Computer='PC2';Source='WMI';Confidence='9';When='2026-10-20';Note=''},[pscustomobject]@{Computer='PC1';Source='Manual';Confidence='80';When='2026-10-19';Note=''},[pscustomobject]@{Computer='PC2';Source='WMI';Confidence='9';When='2026-10-18';Note=''})
 [void](Set-RowAssociationMetadata @($row))
 Assert ($row.Association -eq 'PC1, PC2' -and $row.LinkSource -eq 'Manual, WMI' -and $row.LinkConfidence -eq '80') 'user association projection'
 Assert ($script:Lookup[0] -eq 'EXAMPLE\alice' -and $script:Lookup[1] -eq $row.Guid -and $script:IdentityCalls.Count -eq 3) 'lookup and identity proof'
}
Case 'Failed optional enrichment keeps every AD result and bounds the warning volume' {
 Reset-Fixture;$script:LookupFails=$true;$rows=@(1..5|ForEach-Object{New-Row Machine ('PC'+$_)});$result=@(Set-RowAssociationMetadata $rows)
 Assert ($result.Count -eq 5 -and $script:Logs.Count -eq 4) 'all rows retained, three details and one summary'
 Assert ($script:Logs[3] -like '5 enrichissement*' -and $result[4].Association -eq '') 'summary and clean failed row'
}
Case 'Machine lookup carries GUID and qualified identity metadata without replacing the row' {
 Reset-Fixture
 function script:Get-DomeniaLinkQualification {param($Link)return [pscustomobject]@{Value=('Qualified '+[string]$Link.Confidence)}}
 $row=New-Row;$row.UPN='pc1.example.invalid';$script:Links=@([pscustomobject]@{UserLogin='alice';Source='WMI';Confidence='80';Note=' (historique)'})
 $result=@(Set-RowAssociationMetadata @($row))
 Assert ([object]::ReferenceEquals($result[0],$row) -and $row.Association -eq 'alice (historique)' -and $row.LinkSource -eq 'WMI' -and $row.LinkConfidence -eq 'Qualified 80') 'qualified machine projection'
 Assert ($script:Lookup[0] -eq $row.UPN -and $script:Lookup[1] -eq $row.Guid -and $script:IdentityCalls[0].Kind -eq 'Computer' -and $script:IdentityCalls[0].Guid -eq $row.Guid) 'machine key and identity proof'
}
Case 'Qualified user confidence comes from the best link' {
 Reset-Fixture;$row=New-Row Utilisateur Alice
 $script:Links=@([pscustomobject]@{Computer='PC1';Source='WMI';Confidence=20;Note=''},[pscustomobject]@{Computer='PC2';Source='Manual';Confidence=90;Note=''})
 [void](Set-RowAssociationMetadata @($row))
 Assert ($row.LinkConfidence -eq 'Qualified 90' -and $script:Lookup[0] -eq 'Alice') 'qualified user result and name fallback'
}
$failed=@($checks|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[pscustomobject]@{Suite='DomeniaAssociationRows';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;Checks=@($checks)}
if($ReportPath){$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
if(-not $Quiet){$report|Select-Object Suite,Passed,Total,Failed|Format-Table -AutoSize}
if($failed -gt 0){exit 1}
