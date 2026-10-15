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
$script:SettingsFixture=@{}
function Get-DomeniaSetting {param($Name,$Default) if($script:SettingsFixture.ContainsKey([string]$Name)){return $script:SettingsFixture[[string]$Name]};return $Default}
$script:Tests=[Collections.Generic.List[object]]::new()
function Assert-Delivery {param([bool]$Condition,[string]$Message='Assertion en echec') if(-not $Condition){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$ok=$true;$detail=''}catch{$ok=$false;$detail=$_.Exception.Message}
    $script:Tests.Add([pscustomobject]@{Name=$Name;Passed=$ok;Detail=$detail})
    if(-not $Quiet -or -not $ok){Write-Host ("$ok | $Name | $detail")}
}
function Reset-Compatibility {
    $script:CompatibilityModuleRoot=Join-Path $wad 'modules'
    $script:DomeniaCompatibilityMatrix=$null;$script:DomeniaCompatibilityMatrixRead=$false;$script:DomeniaLocalCompatibility=$null;$script:DomeniaAboutCompatibilityHelp=$null
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
    # Screen readers get the same per-dimension detail as the tooltip.
    Assert-Delivery ([Windows.Automation.AutomationProperties]::GetHelpText($script:Ctrl.LblUxAboutCompatibility) -ceq [string]$script:Ctrl.LblUxAboutCompatibility.ToolTip) 'Aide accessible differente de lʼinfobulle'
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

# ---------------------------------------------------------------- point 133 : contrats versionnes entre modules
function Get-DeliveryThrown {param([scriptblock]$Body) try{& $Body|Out-Null;return ''}catch{return [string]$_.Exception.Message}}
Case 'P133 pack de recettes dʼune version plus recente : refuse avec sa version, rien nʼest prepare' {
    $context=[pscustomobject]@{Version=1;StoreId='store-test';DomainDn='DC=example,DC=invalid';Path=(Join-Path ([IO.Path]::GetTempPath()) 'Domenia-test.db')}
    $message=Get-DeliveryThrown {New-DomeniaQueryPackImportPlan -Context $context -Json '{"Format":"Domenia.QueryPack/3","Origin":"test","Recipes":[]}'}
    Assert-Delivery ($message -like 'Pack de recettes : format Domenia.QueryPack/3 produit par une version plus récente de Domenia*') $message
    # W09: version 1 (no identity, no fingerprint) stays readable as a subset of version 2.
    $current=New-DomeniaQueryPackImportPlan -Context $context -Json '{"Format":"Domenia.QueryPack/1","Origin":"test","Recipes":[]}'
    Assert-Delivery (([string]$current.Format -ceq 'Domenia.QueryImportPlan/2') -and ([string]$current.PackFormat -ceq 'Domenia.QueryPack/1') -and (-not [bool]$current.Verified) -and (@($current.Items).Count -eq 0)) 'Pack de version 1 non lu'
}
Case 'P133 recette, bibliotheque et lecture WMI dʼun format futur refusees avant toute evaluation' {
    $recipe=Get-DeliveryThrown {ConvertTo-DomeniaCompiledQuery -Recipe ([pscustomobject]@{Format='Domenia.Query/3';Id='q';Name='Futur'})}
    Assert-Delivery ($recipe -like 'Recette de requête : format Domenia.Query/3 produit par une version plus récente*') $recipe
    $library=Get-DeliveryThrown {ConvertFrom-DomeniaQueryLibrary -Json '{"Format":"Domenia.QueryLibrary/2","Queries":[]}'}
    Assert-Delivery ($library -like 'Bibliothèque de requêtes : format Domenia.QueryLibrary/2 produit*') $library
    Assert-Delivery (@(ConvertFrom-DomeniaQueryLibrary -Json '{"Format":"Domenia.QueryLibrary/1","Queries":[]}').Count -eq 0) 'Bibliotheque courante refusee'
    $wmi=Get-DeliveryThrown {Assert-DomeniaQueryReadDefinition ([pscustomobject]@{Format='Domenia.WmiRead/2'})}
    Assert-Delivery ($wmi -like 'Définition de lecture WMI : format Domenia.WmiRead/2 produit*') $wmi
    $other=Get-DeliveryThrown {Assert-DomeniaQueryReadDefinition ([pscustomobject]@{Format='Domenia.QueryPack/1'})}
    Assert-Delivery ($other -like '*inattendu (Domenia.WmiRead/1 attendu)*') $other
}
Case 'P133 bibliotheque locale : recette et enregistrement dʼune version plus recente refuses avec leur version' {
    # Real validation function of the LocalStore worker, taken from the code composed for it.
    $code=Get-DomeniaQueryLibraryDefinitionValidationCode
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
    $definition=$ast.Find({param($node) ($node -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -ceq 'Assert-WQueryLibraryDefinition')},$true)
    Assert-Delivery ($null -ne $definition) 'Validation de la bibliotheque introuvable'
    . ([scriptblock]::Create($definition.Extent.Text))
    $future=Get-DeliveryThrown {Assert-WQueryLibraryDefinition -DefinitionJson '{"Format":"Domenia.Query/3","Id":"q","Name":"Futur"}' -DefinitionVersion 3 -RecipeId 'q'}
    Assert-Delivery ($future -like 'Recette de requête : format Domenia.Query/3 produit par une version plus récente de Domenia*') $future
    $mismatch=Get-DeliveryThrown {Assert-WQueryLibraryDefinition -DefinitionJson '{"Format":"Domenia.Query/2","Id":"q","Name":"Courante"}' -DefinitionVersion 1 -RecipeId 'q'}
    Assert-Delivery ($mismatch -ceq 'Version ou identite de definition incoherente.') $mismatch
    $context=[pscustomobject]@{Version=1;StoreId='store-test';DomainDn='DC=example,DC=invalid';Path=(Join-Path ([IO.Path]::GetTempPath()) 'Domenia-test.db')}
    $record=[pscustomobject]@{Format='Domenia.QueryLibraryRecord/2';StoreId='store-test';DomainDn='DC=example,DC=invalid';Id='q';Name='Futur';DefinitionJson='{}';DefinitionSHA256=''}
    $stored=Get-DeliveryThrown {ConvertTo-DomeniaStoreQueryChange -Change ([pscustomobject]@{Kind='QueryRecipe';Record=$record}) -Context $context}
    Assert-Delivery ($stored -like 'Enregistrement de recette : format Domenia.QueryLibraryRecord/2 produit par une version plus récente*') $stored
}
Case 'P133 table des fins de service dʼune version plus recente : dates inconnues, version nommee dans le journal' {
    $folder=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-lifecycle-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($folder)
    $savedRoot=$script:DashboardModuleRoot
    try{
        [IO.File]::WriteAllText((Join-Path $folder 'Domenia-WindowsLifecycle.json'),'{"Format":"DomeniaWindowsLifecycle/2","Entries":[{"Build":"26100"}]}',[Text.UTF8Encoding]::new($false))
        $script:DashboardModuleRoot=$folder;$script:DomeniaWindowsLifecycleRead=$false;$script:DomeniaWindowsLifecycle=$null;$script:Logs.Clear()
        Assert-Delivery ($null -eq (Get-DomeniaWindowsLifecycleTable)) 'Table future lue'
        Assert-Delivery (@($script:Logs|Where-Object{$_ -like 'Table des fins de service Windows : format DomeniaWindowsLifecycle/2 produit par une version plus récente*Dates de fin inconnues.'}).Count -eq 1) ([string]::Join(' | ',$script:Logs.ToArray()))
        $script:DashboardModuleRoot=Join-Path $wad 'modules';$script:DomeniaWindowsLifecycleRead=$false;$script:DomeniaWindowsLifecycle=$null
        Assert-Delivery (@((Get-DomeniaWindowsLifecycleTable).Entries).Count -gt 0) 'Table livree non lue'
    }finally{
        $script:DashboardModuleRoot=$savedRoot;$script:DomeniaWindowsLifecycleRead=$false;$script:DomeniaWindowsLifecycle=$null
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Case 'P133 le catalogue charge par lʼapplication est celui des workers (Common.Model)' {
    $command=Get-Command -Name Get-DomeniaContractCatalog -CommandType Function
    Assert-Delivery ([IO.Path]::GetFileName([string]$command.ScriptBlock.File) -ceq 'Domenia-Common.Model.ps1') ([string]$command.ScriptBlock.File)
    $check=Test-DomeniaContractCatalog
    Assert-Delivery ([bool]$check.Valid) ([string]::Join(' | ',[string[]]$check.Problems))
    foreach($worker in @('Domenia-Query.Worker.ps1','Domenia-QuerySchema.Worker.ps1')){
        $source=[IO.File]::ReadAllText((Join-Path $wad ('modules\'+$worker)),[Text.Encoding]::UTF8)
        $lines=@($source -split "`n" | Where-Object {($_ -match 'Model\.ps1') -and ($_ -match 'foreach\(\$file in')})
        Assert-Delivery ($lines.Count -ge 1) ('Chargement des modeles introuvable : '+$worker)
        foreach($line in $lines){
            Assert-Delivery ($line.IndexOf('Domenia-Common.Model.ps1') -ge 0) ('Worker sans Common.Model : '+$worker)
        }
    }
}

# ---------------------------------------------------------------- point 147 : politique des donnees locales
function Reset-DataPolicyFixture {
    param([string]$PolicyJson='')
    $script:SettingsFixture=@{}
    if($PolicyJson){$script:SettingsFixture['Storage.PolicyJson']=$PolicyJson}
    $script:StorageLayout=Get-DomeniaStorageLayout -Mode UserLocal -InstallRoot 'C:\Domenia' -UserLocalRoot 'C:\Users\agent\AppData\Local' -Writable @{Cache=$true;Preference=$true;Receipt=$true}
    $script:DatabaseScopedPath='C:\Users\agent\AppData\Local\Domenia\Data\Domains\cnamts\Domenia.db'
    $script:Ctrl=@{DgStorageDataPolicy=(New-Object Windows.Controls.DataGrid);LblStorageDataPolicy=(New-Object Windows.Controls.TextBlock);ExpStorageDataPolicy=(New-Object Windows.Controls.Expander)}
}
function Get-DataPolicyRow {param([string]$Category) return @(@($script:Ctrl.DgStorageDataPolicy.ItemsSource)|Where-Object{[string]$_.Category -eq $Category})[0]}
Case 'P147 Stockage : politique des donnees avec les reglages enregistres et les dossiers de la disposition' {
    Reset-DataPolicyFixture '{"Version":1,"AutomaticBackup":false,"BackupHours":24,"BackupKeep":7,"PresenceDays":45,"ConsoleDays":90,"InventoryDays":0,"ProbeDays":90,"DetailDays":30}'
    Update-DomeniaDataPolicyView
    Assert-Delivery (@($script:Ctrl.DgStorageDataPolicy.ItemsSource).Count -eq 20) 'Vingt categories attendues'
    foreach($pair in @(@('Export','Exports'),@('Diagnostic','Diagnostics'),@('Legacy','Legacy'),@('Log','Logs'))){
        Assert-Delivery ([string](Get-DataPolicyRow $pair[0]).Location -ceq ('C:\Users\agent\AppData\Local\Domenia\Data\'+$pair[1])) ($pair[0]+' : '+[string](Get-DataPolicyRow $pair[0]).Location)
    }
    Assert-Delivery ([string](Get-DataPolicyRow 'Presence').Retention -like '45 jours, appliqués après prévisualisation*') ([string](Get-DataPolicyRow 'Presence').Retention)
    Assert-Delivery ([string](Get-DataPolicyRow 'Inventory').Retention -ceq 'Sans limite de durée.') ([string](Get-DataPolicyRow 'Inventory').Retention)
    Assert-Delivery ([string](Get-DataPolicyRow 'Receipt').Location -ceq 'C:\Users\agent\AppData\Local\Domenia\Receipts') ([string](Get-DataPolicyRow 'Receipt').Location)
    Assert-Delivery ([string](Get-DataPolicyRow 'Backup').Location -ceq 'C:\Users\agent\AppData\Local\Domenia\Data\Domains\cnamts\Backups') ([string](Get-DataPolicyRow 'Backup').Location)
    Assert-Delivery ([string]$script:Ctrl.LblStorageDataPolicy.Text -like 'Domenia nʼenvoie aucune donnée hors de ce poste*') ([string]$script:Ctrl.LblStorageDataPolicy.Text)
}
Case 'P147 reglages illisibles : conservation inconnue, aucune valeur par defaut presentee comme reglee' {
    Reset-DataPolicyFixture '{illisible'
    $script:Logs.Clear()
    Update-DomeniaDataPolicyView
    Assert-Delivery ([string](Get-DataPolicyRow 'Presence').Retention -ceq 'Réglages de conservation illisibles : durée inconnue.') ([string](Get-DataPolicyRow 'Presence').Retention)
    Assert-Delivery (@($script:Logs|Where-Object{$_ -like 'Politique des données : réglages de stockage illisibles*'}).Count -eq 1) 'Lecture illisible non journalisee'
}
Case 'P147 ouverture de la section : la vue relit les reglages enregistres depuis' {
    Reset-DataPolicyFixture
    $script:DataPolicyViewWired=$false
    Initialize-DomeniaDataPolicyView
    Assert-Delivery ([string](Get-DataPolicyRow 'Presence').Retention -like '30 jours*') 'Valeur par defaut du reglage absent'
    $script:SettingsFixture['Storage.PolicyJson']='{"Version":1,"PresenceDays":7}'
    $script:Ctrl.ExpStorageDataPolicy.IsExpanded=$true
    Assert-Delivery ([string](Get-DataPolicyRow 'Presence').Retention -like '7 jours*') ([string](Get-DataPolicyRow 'Presence').Retention)
    Initialize-DomeniaDataPolicyView
    $script:Ctrl.ExpStorageDataPolicy.IsExpanded=$false
    $script:SettingsFixture['Storage.PolicyJson']='{"Version":1,"PresenceDays":9}'
    $script:Ctrl.ExpStorageDataPolicy.IsExpanded=$true
    Assert-Delivery ([string](Get-DataPolicyRow 'Presence').Retention -like '9 jours*') 'Section rouverte : vue non relue'
}

$bad=@($script:Tests|Where-Object{-not $_.Passed})
$report=[ordered]@{Suite='Test-DomeniaDelivery';Environment='Windows PowerShell 5.1 / WPF sans fenetre';NoNetwork=$true;Passed=$script:Tests.Count-$bad.Count;Failed=$bad.Count;Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-delivery-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host ('Rapport : '+$ReportPath)
if($bad.Count){throw ('Echecs : '+$bad.Count)}
