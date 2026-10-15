#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
# Delivery and release-engineering wiring (points 133, 143, 145, 147, 148). Isolated suite: it never starts the
# application, never opens a window and sends no AD, SMB, CIM or network request. It reads this workstation's
# registry and the version of winsqlite3.dll (point 145), exactly as the application does in À propos.
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition -ne 'Desktop' -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Windows PowerShell 5.1 x64 -STA requis.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
# The real closed plan (definitions only, verified origin): a function removed from the plan fails with
# DOMENIA_MODULE_EXPORT instead of being replaced by a local copy.
. (Join-Path $wad 'Domenia-Modules.ps1')
# Explicit doubles for the UI boundaries only, declared after the import.
$script:Ctrl=@{}
$script:Logs=[Collections.Generic.List[string]]::new()
$script:Hints=[Collections.Generic.List[string]]::new()
function Get-DomeniaControl {param($Name) if($script:Ctrl.ContainsKey([string]$Name)){return $script:Ctrl[[string]$Name]};return $null}
function Write-AppLog {param($Text,$Level) $script:Logs.Add([string]$Text)}
function Set-Status {param($Text,$Level)}
function Set-DomeniaContextHint {param($Title,$Text) $script:Hints.Add([string]$Title)}
$script:Tests=[Collections.Generic.List[object]]::new()
function Assert-Delivery {param([bool]$Condition,[string]$Message='Assertion en echec') if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$ok=$true;$detail=''}catch{$ok=$false;$detail=$_.Exception.Message}
    $script:Tests.Add([pscustomobject]@{Name=$Name;Passed=$ok;Detail=$detail})
    if(-not $Quiet -or -not $ok){Write-Host ("$ok | $Name | $detail")}
}
function Reset-Compatibility {
    $script:CompatibilityModuleRoot=Join-Path $wad 'modules'
    $script:DomeniaCompatibilityMatrix=$null;$script:DomeniaCompatibilityMatrixRead=$false;$script:DomeniaLocalCompatibility=$null
}

# ---------------------------------------------------------------- point 145 : compatibilite du poste
Case 'P145 faits du poste lus localement : Windows, PowerShell 5.1 x64, .NET et winsqlite3' {
    Reset-Compatibility
    $facts=Get-DomeniaEnvironmentFacts
    Assert-Delivery (@('Client','Server') -contains [string]$facts.Windows.Product) ('Produit Windows : '+[string]$facts.Windows.Product)
    Assert-Delivery ([int]$facts.Windows.Build -gt 10000) ('Build : '+[string]$facts.Windows.Build)
    Assert-Delivery (([string]$facts.PowerShell.Edition -ceq 'Desktop') -and ([int]$facts.PowerShell.Bitness -eq 64)) 'PowerShell Desktop 64 bits attendu'
    Assert-Delivery ($facts.PowerShell.Version -eq $PSVersionTable.PSVersion) 'Version de PowerShell differente'
    Assert-Delivery ([int]$facts.DotNet.Release -ge 461808) ('Release .NET : '+[string]$facts.DotNet.Release)
    Assert-Delivery ($facts.Sqlite.Present -is [bool]) 'Presence de winsqlite3.dll non relevee'
}
Case 'P145 matrice livree valide ; le poste de qualification nʼest pas declare non pris en charge' {
    Reset-Compatibility
    $state=Get-DomeniaLocalCompatibility -Refresh
    Assert-Delivery ([bool]$state.Verdict.MatrixValid) ([string]::Join(' | ',[string[]]$state.Verdict.Problems))
    Assert-Delivery (@($state.Verdict.Rows).Count -eq 4) 'Quatre dimensions observees attendues'
    Assert-Delivery ([string]$state.Verdict.Overall -cne 'NonPrisEnCharge') ([string]$state.Text)
    Assert-Delivery ([string]$state.Verdict.Overall -cne 'Qualifie') 'Aucune qualification liee au ZIP ne peut etre affirmee par la matrice livree'
}
Case 'P145 À propos : phrase de compatibilite et detail par dimension a lʼouverture' {
    Reset-Compatibility
    $script:Ctrl=@{UxAboutPanel=(New-Object Windows.Controls.Border);LblUxAboutCompatibility=(New-Object Windows.Controls.TextBlock)}
    $script:Ctrl.UxAboutPanel.Visibility=[Windows.Visibility]::Collapsed
    $script:Ctrl.LblUxAboutCompatibility.Text='Compatibilité de ce poste : non évaluée.'
    Switch-DomeniaUxAbout
    Assert-Delivery ($script:Ctrl.UxAboutPanel.Visibility -eq [Windows.Visibility]::Visible) 'Panneau non affiche'
    $text=[string]$script:Ctrl.LblUxAboutCompatibility.Text
    Assert-Delivery ($text.StartsWith('Compatibilité de ce poste : environnement ')) $text
    Assert-Delivery ([string]$script:Ctrl.LblUxAboutCompatibility.ToolTip -like '*Windows*PowerShell*') ([string]$script:Ctrl.LblUxAboutCompatibility.ToolTip)
    Switch-DomeniaUxAbout
    Assert-Delivery ($script:Ctrl.UxAboutPanel.Visibility -eq [Windows.Visibility]::Collapsed) 'Second clic : panneau replie'
}
Case 'P145 dossier technique : versions et statuts seulement, ni nom de poste ni compte ni chemin' {
    Reset-Compatibility
    $fields=Get-DomeniaCompatibilitySupportFields
    foreach($key in @('Compatibility','CompatibilityMatrix','WindowsBuild','WindowsProduct','DotNetRelease','WinSqlite','CompatibilityWindows','CompatibilityPowerShell','CompatibilityDotNet','CompatibilitySqlite')){Assert-Delivery ($fields.Contains($key)) ('Champ absent : '+$key)}
    $json=$fields|ConvertTo-Json -Depth 3
    foreach($private in @($env:COMPUTERNAME,$env:USERNAME,$env:USERDOMAIN)){if($private){Assert-Delivery ($json.IndexOf($private,[StringComparison]::OrdinalIgnoreCase) -lt 0) 'Nom prive dans le dossier'}}
    Assert-Delivery ($json -notmatch '[A-Za-z]:\\\\') 'Chemin dans le dossier'
}
Case 'P145 matrice absente : compatibilite inconnue, jamais compatible par defaut' {
    Reset-Compatibility
    $empty=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-compat-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($empty)
    try{
        $script:CompatibilityModuleRoot=$empty
        $state=Get-DomeniaLocalCompatibility -Refresh
        Assert-Delivery ([string]$state.Verdict.Overall -ceq 'Inconnu') ([string]$state.Verdict.Overall)
        Assert-Delivery ([string]$state.Text -like '*absente ou illisible*') ([string]$state.Text)
        Assert-Delivery (@($script:Logs|Where-Object{$_ -like 'Matrice de compatibilité absente*'}).Count -ge 1) 'Absence non journalisee'
    }finally{Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue;Reset-Compatibility}
}

$bad=@($script:Tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaDelivery';Environment='Windows PowerShell 5.1 / WPF sans fenetre';NoNetwork=$true;Passed=$script:Tests.Count-$bad.Count;Failed=$bad.Count;Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-delivery-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host ('Rapport : '+$ReportPath)
if($bad.Count){throw ('Echecs : '+$bad.Count)}
