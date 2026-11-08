#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Domenia-ProbeDetails.Model.ps1')
$checks=[Collections.Generic.List[object]]::new()
function Assert-Detail {param([bool]$Value,[string]$Message) if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Code) try{& $Code;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}}
Case 'Typed values preserve false and zero' {
    $item=ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{Enabled=$false;Free=0}) @('Enabled','Free')
    Assert-Detail ($item.Values.Enabled -is [bool] -and -not $item.Values.Enabled -and $item.Values.Free -eq 0 -and -not $item.IncompleteProperties.Count) 'Types ou couverture perdus.'
}
Case 'Arrays preserve all DNS addresses' {
    $item=ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{DNS=@('10.0.0.1','10.0.0.2')}) @('DNS')
    Assert-Detail ($item.Values.DNS.Count -eq 2 -and $item.Values.DNS[1] -ceq '10.0.0.2') 'Tableau tronqué.'
}
Case 'Missing property remains distinguishable from observed null' {
    $item=ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{Known=$null}) @('Known','Missing')
    Assert-Detail ($item.IncompleteProperties.Count -eq 1 -and $item.IncompleteProperties[0] -ceq 'Missing') 'Champ non lu présenté comme vide.'
}
Case 'Oversized value is marked, never silently clipped' {
    $item=ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{Name=('x'*16385)}) @('Name')
    Assert-Detail ($null -eq $item.Values.Name -and $item.IncompleteProperties -contains 'Name') 'Troncature silencieuse.'
}
Case 'Oversized array is marked' {
    $item=ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{Values=@(1..257)}) @('Values')
    Assert-Detail ($null -eq $item.Values.Values -and $item.IncompleteProperties -contains 'Values') 'Tableau tronqué silencieusement.'
}
Case 'NaN and infinity never masquerade as numeric measurements' {
    foreach($value in @([double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity)){
        $r=ConvertTo-DomeniaProbeDetailValue $value;Assert-Detail (-not $r.Complete -and $null -eq $r.Value) 'Valeur non finie acceptée.'
    }
}
$items=@(for($i=1;$i -le 120;$i++){ConvertTo-DomeniaProbeDetailInstance ([pscustomobject]@{Name=('Service '+$i);State='Running'}) @('Name','State') $i})
Case 'Full details beyond former twenty-row cap' {
    $r=New-DomeniaProbeDetailProjection $items @('Name','State') 120
    Assert-Detail ($r.Instances.Count -eq 120 -and $r.Rows.Count -eq 120 -and -not $r.Truncated) 'Détails perdus après vingt lignes.'
}
Case 'Pages cover every stored instance once' {
    $r=New-DomeniaProbeDetailProjection $items @('Name','State') 120
    $seen=@();foreach($offset in @(0,50,100)){$page=Get-DomeniaProbeDetailPage $r @('Name','State') $offset 50;$seen+=@($page.Rows|ForEach-Object{$_.Ligne})}
    Assert-Detail ($seen.Count -eq 120 -and @($seen|Select-Object -Unique).Count -eq 120 -and $seen[-1] -eq 120) 'Pagination incomplète ou dupliquée.'
}
Case 'Count remains total when detail budget is reached' {
    $r=New-DomeniaProbeDetailProjection $items @('Name','State') 120 -Mode Count -BudgetBytes 2048
    Assert-Detail ($r.Count -eq 120 -and $r.CountComplete -and $r.Truncated -and $r.StoredCount -lt 120 -and $r.LimitReason) 'Total confondu avec détails.'
}
Case 'Interrupted enumeration never claims completeness' {
    $r=New-DomeniaProbeDetailProjection $items @('Name','State') 120 -EnumerationComplete $false
    Assert-Detail ($r.Truncated -and -not $r.CountComplete -and -not $r.EnumerationComplete) 'Énumération partielle acceptée.'
}
Case 'Explicit First is not incomplete because more instances exist' {
    $r=New-DomeniaProbeDetailProjection $items @('Name','State') 120 -Mode First
    Assert-Detail ($r.StoredCount -eq 1 -and -not $r.Truncated) 'Sémantique First incorrecte.'
}
Case 'Invalid paging is rejected' {
    $rejected=$false;try{Get-DomeniaProbeDetailPage ([pscustomobject]@{Instances=@()}) @('Name') -1 100}catch{$rejected=$true}
    Assert-Detail $rejected 'Offset négatif accepté.'
}
Case 'Legacy rows remain readable without claiming complete typed observations' {
    $probe=[pscustomobject]@{Rows=@(@('A','Running'),@('B','Stopped'));Count=2;Truncated=$false}
    $page=Get-DomeniaProbeDetailPage $probe @('Valeur 1','Valeur 2')
    Assert-Detail ($page.Legacy -and -not $page.CountComplete -and $page.StoredCount -eq 2 -and $page.Rows[1].'Valeur 1' -ceq 'B') 'Ancien relevé perdu ou surinterprété.'
}
Case 'Missing count is unknown rather than zero' {
    $page=Get-DomeniaProbeDetailPage ([pscustomobject]@{Instances=@()}) @('Name')
    Assert-Detail ($null -eq $page.ReportedCount -and -not $page.CountComplete) 'Absence convertie en zéro.'
}
$report=[pscustomobject]@{Kind='Pure probe detail model, no WMI or GUI';Passed=@($checks|Where-Object{$_.Passed}).Count;Failed=@($checks|Where-Object{-not $_.Passed}).Count;Checks=$checks.ToArray()}
if($ReportPath){$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$report
if($report.Failed){throw 'Probe detail model failed.'}
