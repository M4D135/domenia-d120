#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
# Pure display rules and state tests: no WPF window, directory, password or remote call.
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$path=Join-Path $wad 'modules\Domenia-UX.UI.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
$names=@('ConvertTo-DomeniaUxFlag','Get-DomeniaUxLayoutPlan','Get-DomeniaUxOuDisplay','Update-DomeniaUxOuScope','Save-DomeniaUxLayoutSettings')
foreach($name in $names){
    $found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($found.Count -ne 1){throw ('Helper absent : '+$name)}
    Invoke-Expression $found[0].Extent.Text
}
function Assert-Ui {param([bool]$Value) if(-not $Value){throw 'Condition non verifiee'}}
function Get-DomeniaControl {param($Name) if($script:Controls.ContainsKey($Name)){return $script:Controls[$Name]};return $null}
function Set-DomeniaSetting {param($Name,$Value) $script:Saved[$Name]=$Value}
function Save-DomeniaSettings {param([switch]$Immediate) $script:Immediate=[bool]$Immediate}
$script:Checks=New-Object 'System.Collections.Generic.List[object]'
function Test-UiCase {
    param($Name,[scriptblock]$Code)
    try{& $Code;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
Test-UiCase 'Boolean false preserved' {Assert-Ui (-not (ConvertTo-DomeniaUxFlag $false))}
Test-UiCase 'String false is not cast to true' {Assert-Ui (-not (ConvertTo-DomeniaUxFlag 'false'))}
Test-UiCase 'Invalid preference uses fallback' {Assert-Ui (ConvertTo-DomeniaUxFlag 'bad' -Default $true)}
Test-UiCase 'Expanded navigation width' {Assert-Ui ((Get-DomeniaUxLayoutPlan -Width 1600).NavWidth -eq 204)}
Test-UiCase 'Icon rail width' {Assert-Ui ((Get-DomeniaUxLayoutPlan -Width 1600 -NavCollapsed $true).NavWidth -eq 68)}
Test-UiCase 'Wide help consumes one column' {$p=Get-DomeniaUxLayoutPlan -Width 1600;Assert-Ui ($p.HelpShown -and -not $p.Compact -and $p.ColumnWidth -eq 300)}
Test-UiCase 'Hidden help releases column and gutter' {$p=Get-DomeniaUxLayoutPlan -Width 1600 -HelpVisible $false;Assert-Ui ($p.ColumnWidth -eq 0 -and $p.WorkspaceGap -eq 0 -and -not $p.HelpShown)}
Test-UiCase 'Small window keeps results width' {$p=Get-DomeniaUxLayoutPlan -Width 1100;Assert-Ui ($p.Compact -and -not $p.HelpShown -and $p.ColumnWidth -eq 0)}
Test-UiCase 'Help opens as overlay on small window' {$p=Get-DomeniaUxLayoutPlan -Width 1100 -CompactHelpOpen $true;Assert-Ui ($p.HelpShown -and $p.Compact -and $p.ColumnWidth -eq 0)}
Test-UiCase 'Collapsing menu can free space for docked help' {$a=Get-DomeniaUxLayoutPlan -Width 1200;$b=Get-DomeniaUxLayoutPlan -Width 1200 -NavCollapsed $true;Assert-Ui ($a.Compact -and -not $b.Compact)}
Test-UiCase 'Domain readable' {$d=Get-DomeniaUxOuDisplay 'DC=example,DC=invalid' $true;Assert-Ui ($d.Name -eq 'Tout le domaine' -and $d.FullPath -eq 'example.invalid')}
Test-UiCase 'OU name and ancestry' {$d=Get-DomeniaUxOuDisplay 'OU=STAGING,OU=Postes,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'STAGING' -and $d.FullPath -eq 'example.invalid / Postes / STAGING')}
Test-UiCase 'Long ancestry shortened only in breadcrumb' {$d=Get-DomeniaUxOuDisplay 'OU=Leaf,OU=C,OU=B,OU=A,DC=example,DC=invalid';Assert-Ui ($d.Breadcrumb.StartsWith('… / ') -and $d.FullPath.Contains(' / A / B / C / Leaf'))}
Test-UiCase 'Escaped comma is not a parent separator' {$d=Get-DomeniaUxOuDisplay 'OU=Paris\, Centre,OU=Sites,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'Paris, Centre')}
Test-UiCase 'Escaped backslash before comma ends RDN correctly' {$d=Get-DomeniaUxOuDisplay 'OU=Back\\,OU=Sites,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'Back\')}
Test-UiCase 'UTF8 escaped display name' {$d=Get-DomeniaUxOuDisplay 'OU=\C3\89quipe,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'Équipe')}
Test-UiCase 'Hex escaped comma' {$d=Get-DomeniaUxOuDisplay 'OU=Help\2CDesk,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'Help,Desk')}
Test-UiCase 'CN container readable' {$d=Get-DomeniaUxOuDisplay 'CN=Computers,DC=example,DC=invalid';Assert-Ui ($d.Name -eq 'Computers')}
Test-UiCase 'Display helper preserves raw search DN exactly' {$raw='OU=Paris\, Centre,OU=Sites,DC=example,DC=invalid';$d=Get-DomeniaUxOuDisplay $raw;Assert-Ui ($d.DistinguishedName -ceq $raw)}
Test-UiCase 'Empty display is handled' {$d=Get-DomeniaUxOuDisplay '';Assert-Ui ($d.Name -eq 'Tout le domaine' -and $d.FullPath -eq '')}
Test-UiCase 'Display updates never mutate filters' {
    $script:Controls=@{};foreach($n in @('LblOuScopeName','LblOuScopePath','LblSearchScope')){$script:Controls[$n]=[pscustomobject]@{Text='';ToolTip=''}}
    $scope=[pscustomobject]@{BaseDn='OU=STAGING,OU=Postes,DC=example,DC=invalid';Scope='OneLevel';IsDomain=$false}
    $before=$scope|ConvertTo-Json -Compress
    Update-DomeniaUxOuScope -Scope $scope
    Assert-Ui (($scope|ConvertTo-Json -Compress) -ceq $before)
    Assert-Ui ($script:Controls.LblOuScopeName.Text -eq 'STAGING' -and $script:Controls.LblSearchScope.Text.Contains('Enfants directs'))
    Assert-Ui ($script:Controls.LblSearchScope.ToolTip.Contains($scope.BaseDn))
}
Test-UiCase 'Panel preferences saved as booleans and flushed' {
    $script:Saved=@{};$script:Immediate=$false;$script:UxNavCollapsed=$true;$script:UxHelpVisible=$false;$script:UxHelpCompactOpen=$false
    Save-DomeniaUxLayoutSettings
    Assert-Ui ($script:Saved.Count -eq 3 -and $script:Saved.UxNavCollapsed -is [bool] -and $script:Saved.UxNavCollapsed -and -not $script:Saved.UxHelpVisible -and $script:Immediate)
}
$bad=@($script:Checks|Where-Object{-not $_.Passed})
$report=[ordered]@{Build='2026.09.30-R1.10-COMPACT';Runtime=$PSVersionTable.PSVersion.ToString();Passed=$script:Checks.Count-$bad.Count;Failed=$bad.Count;NoADAccess=$true;WpfExecuted=$false;Tests=$script:Checks.ToArray()}
if([string]::IsNullOrWhiteSpace($ReportPath)){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-compact-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if($bad.Count){throw ('Tests interface compacte en echec : '+$bad.Count)}
