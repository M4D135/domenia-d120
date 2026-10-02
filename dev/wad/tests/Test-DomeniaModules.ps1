#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$SkipWpf)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$wad=Join-Path $root 'wad'
$script:ModuleTests=[Collections.Generic.List[object]]::new()
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-modules-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)

function Case {
    param([string]$CaseLabel,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:ModuleTests.Add([pscustomobject]@{Name=$CaseLabel;Status='Passed';Error=''}) }
    catch { $script:ModuleTests.Add([pscustomobject]@{Name=$CaseLabel;Status='Failed';Error=$_.Exception.Message}) }
}
function Expect { param([bool]$Value,[string]$Reason); if(-not $Value){throw $Reason} }
function New-Fixture {
    param([string]$Name)
    $path=Join-Path $temp $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $path 'modules'))
    [IO.File]::Copy((Join-Path $wad 'Domenia-Modules.ps1'),(Join-Path $path 'Domenia-Modules.ps1'))
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File){
        [IO.File]::Copy($file.FullName,(Join-Path (Join-Path $path 'modules') $file.Name))
    }
    return $path
}
function Replace-FixtureText {
    param([string]$Path,[string]$Old,[string]$New)
    $text=[IO.File]::ReadAllText($Path)
    if(-not $text.Contains($Old)){throw ('Fixture non applicable : '+$Path)}
    [IO.File]::WriteAllText($Path,$text.Replace($Old,$New),[Text.UTF8Encoding]::new($true))
}

# Each probe gets a fresh PowerShell session. Functions previously imported by a
# test or the caller must never conceal the missing-import regression.
$script:ProbeCode=@'
param([string]$Wad,[string]$Scenario)
$ErrorActionPreference='Stop'
$script:RootDir=$Wad
try {
    Set-Location ([IO.Path]::GetTempPath())
    if($Scenario -eq 'Baseline') {
        . (Join-Path $Wad 'BaselineImports.ps1')
        Initialize-DomeniaReconcile
        throw 'La regression de reference n a pas ete reproduite.'
    }
    if($Scenario -eq 'ForeignOrigin'){. (Join-Path $Wad 'Foreign.ps1')}
    . (Join-Path $Wad 'Domenia-Modules.ps1')
    $plan=@(Get-DomeniaRuntimeModulePlan)
    $exports=[Collections.Generic.List[object]]::new()
    foreach($module in $plan){foreach($name in @($module.Functions)){
        $fn=Get-Item -LiteralPath ('Function:\'+$name)
        $exports.Add([pscustomobject]@{Name=$name;File=[IO.Path]::GetFileName($fn.ScriptBlock.File)})
    }}
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $reconcile=Get-DomeniaReconcileWorkerCode
        $document=Get-DomeniaDocumentWorkerCode
        $rh=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($reconcile -replace "`r`n","`n").Trim())))).Replace('-','')
        $dh=([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($document -replace "`r`n","`n").Trim())))).Replace('-','')
    } finally {$hash.Dispose()}
    $pure=($null -eq $script:Reconcile -and $null -eq $script:Guard -and $null -eq $script:Persistence -and $null -eq $script:AccountValidation -and $null -eq $script:SupportTimer)
    $wpf=$null
    if($Scenario -eq 'Wpf') {
        Add-Type -AssemblyName PresentationFramework
        $script:Window=[Windows.Window]::new()
        $script:Window.ShowActivated=$false
        $script:Window.ShowInTaskbar=$false
        $script:Window.Width=1; $script:Window.Height=1; $script:Window.Opacity=0
        $script:Window.Show()
        $script:AsyncEngineClosing=$false
        # No search is active. These guards fail the test if a timer tries I/O.
        function Test-DomeniaLiveSearchActive { return $false }
        function Start-UiTask { throw 'Aucune operation distante autorisee dans ce test.' }
        function Write-AppLog { param($Text,$Level); throw $Text }
        try {
            Initialize-DomeniaReconcile
            $first=$script:Reconcile
            $started=$first.Timer.IsEnabled
            $noSearch=($first.Events.Count -eq 0 -and -not $first.Job)
            Initialize-DomeniaReconcile
            $same=[object]::ReferenceEquals($first,$script:Reconcile)
            Invoke-DomeniaReconcileTick
            $future=($first.Next -gt [datetime]::UtcNow)
            $script:Window.Close()
            $wpf=[pscustomobject]@{TimerStarted=$started;NoSearch=$noSearch;Idempotent=$same;Deferred=$future;Stopped=(-not $first.Timer.IsEnabled)}
        } finally {
            if($null -ne $script:Reconcile){$script:Reconcile.Timer.Stop();$script:Reconcile.Events.Clear()}
            if($null -ne $script:Window){$script:Window.Close()}
        }
    }
    [pscustomobject]@{Success=$true;Modules=$script:DomeniaRuntimeImports;Exports=$exports.ToArray();Pure=$pure;ReconcileHash=$rh;DocumentHash=$dh;Wpf=$wpf;Message='';ErrorId='';Imported=$true}
} catch {
    [pscustomobject]@{Success=$false;Message=$_.Exception.Message;ErrorId=$_.FullyQualifiedErrorId;Imported=($null -ne (Get-Item -LiteralPath Function:\Initialize-DomeniaUxShell -ErrorAction SilentlyContinue))}
}
'@
function Probe {
    param([string]$Path,[string]$Scenario='Normal')
    $rs=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    if($env:OS -eq 'Windows_NT'){$rs.ApartmentState=[Threading.ApartmentState]::STA}
    $rs.Open();$ps=[Management.Automation.PowerShell]::Create();$ps.Runspace=$rs
    try {
        [void]$ps.AddScript($script:ProbeCode).AddArgument($Path).AddArgument($Scenario)
        $items=@($ps.Invoke())
        if($ps.HadErrors){throw ($ps.Streams.Error|Out-String)}
        if($items.Count -ne 1){throw ('Une reponse unique etait attendue ; recu : '+$items.Count)}
        return $items[0]
    } finally {$ps.Dispose();$rs.Dispose()}
}
try {
    foreach($file in @('Domenia-Core.ps1','Domenia-Start.ps1','Domenia-Modules.ps1')) {
        Case ('Parseur PowerShell : '+$file) {
            $t=$null;$e=$null
            [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $wad $file),[ref]$t,[ref]$e)
            Expect (@($e).Count -eq 0) (($e|Out-String).Trim())
        }
    }
    $normal=Probe $wad
    Case 'Import reel a froid, depuis un autre repertoire courant' {Expect $normal.Success $normal.Message}
    Case '22 modules verifies, sans scanner les scripts supplementaires' {Expect (@($normal.Modules).Count -eq 22) 'Modules incomplets.'}
    Case '255 fonctions disponibles dans la portee appelante' {Expect (@($normal.Exports).Count -eq 255) 'Fonctions incompletes.'}
    Case 'Import sans initialisation WPF, authentification, cache ou timers' {Expect $normal.Pure 'Un composant actif a ete initialise par l import.'}
    foreach($name in @('Initialize-DomeniaReconcile','Get-DomeniaReconcileWorkerCode','Complete-DomeniaReconcile','Fail-DomeniaReconcile','Invoke-DomeniaReconcileTick',
        'ConvertTo-DomeniaStoredCapture','Get-DomeniaDocumentWorkerCode','Start-DomeniaDocumentTask','Complete-DomeniaDocumentTask','Fail-DomeniaDocumentTask',
        'Use-DomeniaCaptureFile','Export-DomeniaTechnicalDossier','Initialize-DomeniaLive','Initialize-DomeniaGuard','Initialize-DomeniaExperience')) {
        Case ('Fonction raccordee : '+$name) {Expect (@($normal.Exports|Where-Object{$_.Name -ceq $name}).Count -eq 1) ('Fonction manquante : '+$name)}
    }
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'))
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($coreText,[ref]$tokens,[ref]$errors)
    $init=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-DomeniaPresentation'},$false)
    $cmds=@($init.Body.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{$_.GetCommandName()})
    Case 'Etat Live initialise avant le timer de reconciliation' {Expect ([array]::IndexOf($cmds,'Initialize-DomeniaLive') -lt [array]::IndexOf($cmds,'Initialize-DomeniaReconcile')) 'Ordre invalide.'}
    Case 'Point d entree partage raccorde au vrai demarrage' {Expect ($coreText.Contains(". (Join-Path `$PSScriptRoot 'Domenia-Modules.ps1')")) 'Bootstrap non raccorde.'}
    $contracts=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    Case 'Corps ScopeReconcile toujours conforme au contrat' {Expect ($normal.ReconcileHash -ieq [string]($contracts|Where-Object{$_.Operation -eq 'ScopeReconcile'}).Sha256) 'Contrat reconciliation different.'}
    Case 'Corps DocumentStore toujours conforme au contrat' {Expect ($normal.DocumentHash -ieq [string]($contracts|Where-Object{$_.Operation -eq 'DocumentStore'}).Sha256) 'Contrat document different.'}

    $fixture=New-Fixture 'reference RC1.1'
    $legacy=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\RC1.1-ModuleImports.ps1'))
    [IO.File]::WriteAllText((Join-Path $fixture 'BaselineImports.ps1'),$legacy,[Text.UTF8Encoding]::new($true))
    $before=Probe $fixture 'Baseline'
    Case 'Regression RC1.1 reproduite : commande Initialize-DomeniaReconcile absente' {Expect (-not $before.Success -and $before.Message -match 'Initialize-DomeniaReconcile' -and $before.ErrorId -match 'CommandNotFound') $before.Message}
    $after=Probe $fixture
    Case 'Memes fichiers, imports corriges : commande disponible' {Expect $after.Success $after.Message}

    foreach($missing in @('Domenia-Reconcile.UI.ps1','Domenia-Dossier.Model.ps1','Domenia-Dossier.UI.ps1','Domenia-Experience.Model.ps1')) {
        $fixture=New-Fixture ('missing-'+$missing)
        [IO.File]::Delete((Join-Path (Join-Path $fixture 'modules') $missing))
        $bad=Probe $fixture
        Case ('Fichier absent detecte avant imports : '+$missing) {Expect (-not $bad.Success -and -not $bad.Imported -and $bad.Message -match 'DOMENIA_MODULE_MISSING' -and $bad.Message.Contains($missing)) $bad.Message}
    }
    $fixture=New-Fixture 'syntax'
    [IO.File]::WriteAllText((Join-Path $fixture 'modules\Domenia-Dossier.UI.ps1'),'function Bad {',[Text.UTF8Encoding]::new($true))
    $bad=Probe $fixture
    Case 'Erreur de syntaxe detectee avant tout chargement partiel' {Expect (-not $bad.Success -and -not $bad.Imported -and $bad.Message -match 'DOMENIA_MODULE_PARSE') $bad.Message}

    $fixture=New-Fixture 'export'
    Replace-FixtureText (Join-Path $fixture 'modules\Domenia-Reconcile.UI.ps1') 'function Initialize-DomeniaReconcile {' 'function Initialize-DomeniaReconcile_TestRename {'
    $bad=Probe $fixture
    Case 'Fichier present mais fonction manquante refusee' {Expect (-not $bad.Success -and $bad.Message -match 'DOMENIA_MODULE_EXPORT' -and $bad.Message -match 'Initialize-DomeniaReconcile') $bad.Message}

    [IO.File]::WriteAllText((Join-Path $fixture 'Foreign.ps1'),'function Initialize-DomeniaReconcile { }',[Text.UTF8Encoding]::new($true))
    $bad=Probe $fixture 'ForeignOrigin'
    Case 'Fonction homonyme externe ne masque pas un import absent' {Expect (-not $bad.Success -and $bad.Message -match 'DOMENIA_MODULE_ORIGIN') $bad.Message}

    $fixture=New-Fixture 'portee'
    Replace-FixtureText (Join-Path $fixture 'Domenia-Modules.ps1') '. $domeniaModulePath' '& $domeniaModulePath'
    $bad=Probe $fixture
    Case 'Invocation en portee enfant refusee : dot-sourcing obligatoire' {Expect (-not $bad.Success -and $bad.Message -match 'DOMENIA_MODULE_EXPORT') $bad.Message}

    $fixture=New-Fixture 'extra'
    [IO.File]::WriteAllText((Join-Path $fixture 'modules\Extra.ps1'),"throw 'Ne doit jamais etre importe.'",[Text.UTF8Encoding]::new($true))
    $good=Probe $fixture
    Case 'Un script non declare n est pas charge automatiquement' {Expect $good.Success $good.Message}

    $fixture=New-Fixture 'import failure'
    $file=Join-Path $fixture 'modules\Domenia-Dossier.UI.ps1'
    [IO.File]::AppendAllText($file,"`r`nthrow 'Erreur de chargement injectee.'`r`n")
    $bad=Probe $fixture
    Case 'Erreur d import conserve le module et le message natif' {Expect (-not $bad.Success -and $bad.Message -match 'DOMENIA_MODULE_IMPORT' -and $bad.Message -match 'Erreur de chargement injectee') $bad.Message}

    if($env:OS -eq 'Windows_NT' -and -not $SkipWpf) {
        $w=Probe $wad 'Wpf'
        Case 'Initialisation reelle du module Reconcile sous WPF' {Expect $w.Success $w.Message}
        foreach($property in @('TimerStarted','NoSearch','Idempotent','Deferred','Stopped')) {
            Case ('Cycle de vie WPF : '+$property) {Expect ($null -ne $w.Wpf -and [bool]$w.Wpf.$property) ('Cycle de vie non confirme : '+$property)}
        }
    } else {
        $script:ModuleTests.Add([pscustomobject]@{Name='Cycle de vie WPF';Status='Skipped';Error='Necessite Windows/WPF ; non execute, pas un succes.'})
    }
} finally {
    if([IO.Directory]::Exists($temp)){Remove-Item -LiteralPath $temp -Recurse -Force}
}
$passed=@($script:ModuleTests|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:ModuleTests|Where-Object{$_.Status -eq 'Failed'}).Count
$skipped=@($script:ModuleTests|Where-Object{$_.Status -eq 'Skipped'}).Count
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.4-SEARCH';PowerShell=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;OS=[Environment]::OSVersion.VersionString;Passed=$passed;Failed=$failed;Skipped=$skipped;Complete=($failed -eq 0 -and $skipped -eq 0);ADAccess=$false;CredentialValidation=$false;ProductionDataAccess=$false;Tests=$script:ModuleTests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-modules-results-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ($passed.ToString()+' passes ; '+$failed+' echecs ; '+$skipped+' non executes. Rapport : '+$ReportPath);$script:ModuleTests|Where-Object{$_.Status -ne 'Passed'}|Format-Table -AutoSize}
if($failed){exit 1}
