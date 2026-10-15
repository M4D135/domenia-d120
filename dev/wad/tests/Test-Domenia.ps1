#requires -Version 5.1
<# Offline Windows tests. Does not execute AD writes or use a production database.
   Function definitions are extracted using Microsoft's real PowerShell AST.
   -WpfSmoke additionally runs the application's existing isolated self-test.
#>
[CmdletBinding()]
param([switch]$WpfSmoke,[switch]$SkipNativeCache,[string]$ReportPath='')
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$core=Join-Path $root 'wad\Domenia-Core.ps1'
if ($PSVersionTable.PSEdition -eq 'Core' -or -not [Environment]::Is64BitProcess) {
    throw 'Utiliser Windows PowerShell 5.1 64 bits (powershell.exe), pas pwsh.'
}
$script:TestResults=New-Object 'System.Collections.Generic.List[object]'
$script:TestMessages=New-Object 'System.Collections.Generic.List[string]'
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try { & $Body | Out-Null; $state='PASS';$detail='' }
    catch { $state='FAIL';$detail=$_.Exception.Message }
    $watch.Stop()
    $script:TestResults.Add([pscustomobject]@{Name=$Name;Status=$state;Milliseconds=$watch.ElapsedMilliseconds;Detail=$detail})
    Write-Host (('{0}  {1}  {2}' -f $state,$Name,$detail))
}
function Assert-True { param([bool]$Condition,[string]$Message='Assertion fausse'); if (-not $Condition) {throw $Message} }
function Assert-Throws { param([scriptblock]$Body);$thrown=$false;try {& $Body | Out-Null}catch {$thrown=$true};Assert-True $thrown 'Exception attendue absente.' }
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$parseErrors)
Test-Case 'Parseur natif PowerShell : coeur' {
    if (@($parseErrors).Count -gt 0) { throw (($parseErrors | ForEach-Object {"L$($_.Extent.StartLineNumber): $($_.Message)"}) -join '; ') }
}
if (@($parseErrors).Count -gt 0) { throw 'Le coeur ne passe pas le parseur natif. Aucun test de fonction execute.' }
foreach($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' | Where-Object {$_.FullName -notmatch '[\\/]data[\\/]|[\\/]maintenance[\\/]backups[\\/]'})) {
    $filePath=$file.FullName
    Test-Case ('Parseur natif : '+$file.Name) {
        $sourceBytes=[IO.File]::ReadAllBytes($filePath)
        if(@($sourceBytes|Where-Object{$_ -gt 127}|Select-Object -First 1).Count){
            Assert-True ($sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 239 -and $sourceBytes[1] -eq 187 -and $sourceBytes[2] -eq 191) ('UTF-8 avec BOM requis pour PowerShell 5.1 : '+$file.Name)
        }
        $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseFile($filePath,[ref]$t,[ref]$e)
        Assert-True (@($e).Count -eq 0) (($e | ForEach-Object {$_.Message}) -join '; ')
    }
}
$wanted=@('Write-DomeniaAtomicText','Read-DomeniaPreference','Write-DomeniaPreference','Get-DomeniaPreferencePath','Protect-DomeniaLogText',
    'ConvertTo-DomeniaSpreadsheetCell','ConvertTo-DomeniaSpreadsheetSafeRow','ConvertTo-DomeniaSqlLikeText',
    'Get-DomeniaScopeKey','Assert-DomeniaWmiReadQuery','Update-SecretsGrid','Get-DomeniaSelectedSecretSource',
    'Complete-DomeniaDetachedReadJobs','Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr',
    'Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','ConvertTo-DomeniaSqlLiteral',
    'Get-DomeniaDatabasePath','Get-DomeniaStoreBackupDirectory','Backup-DomeniaDatabase','Search-DomeniaDatabaseRows',
    'Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Assert-DomeniaWorkerOperationCode',
    # L02: Domenia.log writer (FI-08, FI-09, FI-10, PF-09) and the common CSV export (CO-04, UX-02).
    'ConvertTo-DomeniaLogFileLines','Get-DomeniaAppLogFallbackPaths','Write-DomeniaAppLogFile','Start-DomeniaAppLogFlushTimer','Stop-DomeniaAppLogQueue',
    'Invoke-DomeniaAppLogRotation','Flush-DomeniaAppLog','Invoke-DomeniaAppLogFlush','Set-DomeniaAppLogAvailability','Set-Status',
    'Get-DomeniaGridExportColumns','ConvertTo-DomeniaExportRows','Get-DomeniaExportFileName','Export-DomeniaCsv','Get-DomeniaCsvDelimiter',
    # CO-03 : cles de tri des colonnes datees, et le XAML ou elles sont designees.
    'Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys','Get-DomeniaInventoryAgeLabel','Get-DomeniaInventorySummaryText','Get-DomeniaSoftwareWorkerCode','Get-DomeniaInventoryWorkerCode','Get-MainXaml',
    # CO-22 : decodage des options du compte affiche dans la fiche.
    'Get-UacFlagsLabel','Convert-FileTimeLabel','Convert-ADLargeIntegerToInt64',
    # UX-27 : vue d atterrissage de la fiche selon le type d objet.
    'Get-DomeniaLandingView',
    # Portée de la mise à jour de la base autonome : lʼOU choisie, sinon lʼarbre de recherche.
    'Get-DomeniaIndexScope',
    'Get-DomeniaIndexCut')
$definitions=New-Object 'System.Collections.Generic.List[string]'
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in $wanted) {
    $node=@($nodes | Where-Object {$_.Name -eq $name})
    if ($node.Count -ne 1) { throw "Definition unique attendue : $name ($($node.Count) trouvee)." }
    $definitions.Add($node[0].Extent.Text)
}
# Import definitions only. Never dot-source the application's startup path.
. ([scriptblock]::Create(($definitions -join "`r`n")))
# FI-05 / PF-06: every Dispatcher timer comes from the protected factory of the engine (Domenia-Engine.UI.ps1).
foreach($engineModule in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Engine.UI.ps1')){. (Join-Path (Split-Path -Parent $PSScriptRoot) ('modules\'+$engineModule))}
# SE-03 : les regles MSI et le catalogue ne sont pas recopies dans les gardes. Le banc les charge par AST, comme
# les fonctions du coeur, pour juger les gardes avec la liste reelle du produit.
$guardAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'modules\Domenia-Workstation.Model.ps1'),[ref]$null,[ref]$null)
$guardNodes=@($guardAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$guardDefinitions=@()
foreach($guardName in @('Get-DomeniaMsiProviderClassNames','Test-DomeniaMsiProviderClass')){
    $guardNode=@($guardNodes | Where-Object {$_.Name -eq $guardName})
    if ($guardNode.Count -ne 1) { throw "Definition unique attendue : $guardName ($($guardNode.Count) trouvee)." }
    $guardDefinitions+=$guardNode[0].Extent.Text
}
foreach($guardName in @('Get-DomeniaWmiQueryWorkerCode')){
    $guardNode=@($nodes | Where-Object {$_.Name -eq $guardName})
    if ($guardNode.Count -ne 1) { throw "Definition unique attendue : $guardName ($($guardNode.Count) trouvee)." }
    $guardDefinitions+=$guardNode[0].Extent.Text
}
. ([scriptblock]::Create(($guardDefinitions -join "`r`n")))
$testDirectory=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testDirectory)
$script:DataDir=Join-Path $testDirectory 'data';[void][IO.Directory]::CreateDirectory($script:DataDir)
$script:RootDir=$testDirectory
$script:Conn=[pscustomobject]@{BaseDn=''}
$script:WinSqliteNative=$null;$script:DatabaseScopeIdentity='';$script:DatabaseScopedPath=''
$script:SecretRows=@();$script:SecretClipboardValue='';$script:SecretsVisible=$false
$script:TestGrid=$null;$script:TestBoundRows=@()
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Initialize-DomeniaDataStore { }
function Initialize-DomeniaDatabase { }
function Get-DomeniaIndexAssociationText {param($Row);return ''}
function Write-AppLog {param($Text,$Level);$script:TestMessages.Add([string]$Text)}
function Get-DomeniaControl {param($Name);if($Name -eq 'DgSecrets'){return $script:TestGrid};return $null}
function Set-DomeniaItemsSource {param($Name,$Rows);$script:TestBoundRows=@($Rows);return $true}
function Update-DomeniaSecretActionUi { }
function Add-DomeniaUiLog {param($Text,$Level,$Area)}
try {
    Test-Case 'Ecriture atomique UTF-8 et derniere version valide' {
        $p=Join-Path $script:DataDir 'atomic.json'
        Write-DomeniaAtomicText $p '{"etat":"été"}' -KeepBackup
        Write-DomeniaAtomicText $p '{"etat":"nouveau"}' -KeepBackup
        Assert-True (([IO.File]::ReadAllText($p) | ConvertFrom-Json).etat -ceq 'nouveau')
        Assert-True (([IO.File]::ReadAllText($p+'.bak') | ConvertFrom-Json).etat -ceq 'été')
        Assert-True (@(Get-ChildItem -LiteralPath $script:DataDir -Filter '.domenia-*.tmp').Count -eq 0)
    }
    Test-Case 'D118 : une preference non inscriptible ne se replie pas dans le dossier de l application' {
        $savedRoot=$script:RootDir;$savedDataDir=$script:DataDir;$savedLocalAppData=$env:LOCALAPPDATA;$root=''
        try {
            $root=Join-Path ([IO.Path]::GetTempPath()) ('domenia-root-'+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($root);$script:RootDir=$root
            $env:LOCALAPPDATA=Join-Path $root 'profile';[void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
            $blocker=Join-Path $root 'blocker';[IO.File]::WriteAllText($blocker,'x');$script:DataDir=$blocker
            Assert-True (-not (Write-DomeniaPreference 'no-root-fallback.json' '{}')) 'Ecriture annoncee alors que le dossier utilisateur est inutilisable.'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'no-root-fallback.json'))) 'Repli silencieux dans le dossier de l application.'
            Assert-True (@(Get-ChildItem $env:LOCALAPPDATA -Filter 'no-root-fallback.json' -Recurse).Count -eq 0) 'Repli silencieux dans LOCALAPPDATA.'
        } finally {
            $script:RootDir=$savedRoot;$script:DataDir=$savedDataDir;$env:LOCALAPPDATA=$savedLocalAppData
            if($root){try{[IO.Directory]::Delete($root,$true)}catch{}}
        }
    }
    Test-Case 'Preferences : repli sur JSON .bak valide' {
        $p=Join-Path $script:DataDir 'prefs.json'
        [IO.File]::WriteAllText($p,'{json casse')
        [IO.File]::WriteAllText($p+'.bak','{"ok":true}')
        Assert-True ([bool](Read-DomeniaPreference 'prefs.json' | ConvertFrom-Json).ok)
    }
    Test-Case 'Journal : Bearer, mot de passe, BitLocker, secret connu' {
        $script:SecretRows=@([pscustomobject]@{Value='SecretDeTest#42'})
        $text='Authorization: Bearer abc.123.xyz password="mon-secret" SecretDeTest#42 111111-222222-333333-444444-555555-666666-777777-888888'
        $safe=Protect-DomeniaLogText $text
        foreach($needle in @('abc.123.xyz','mon-secret','SecretDeTest#42','111111-222222')) {
            Assert-True (-not $safe.Contains($needle)) ('Secret present : '+$needle)
        }
        $script:SecretRows=@()
    }
    Test-Case 'CSV : formules, separateurs, textes et nombres' {
        # Baseline 5.1 (r1, r3, VM) failed here with the bare 'Assertion fausse' and no static cause was found
        # (carte-historic-suites, NON_DETERMINE). Every assertion now names itself with value, type and culture,
        # so the next Windows run classifies the failure (code defect or environment) without changing the rule.
        $culture=[Threading.Thread]::CurrentThread.CurrentCulture.Name
        foreach($value in @('=1+1','+cmd','-1+2','@SUM(A1)',"`t=3",'  =5','＝2')) {
            Assert-True ((ConvertTo-DomeniaSpreadsheetCell $value).StartsWith("'")) ('Non neutralise : '+$value)
        }
        # (-42): in argument mode a bare -42 is a string token, which the dash rule would rightly neutralise.
        $number=ConvertTo-DomeniaSpreadsheetCell (-42)
        $numberType=if($null -eq $number){'null'}else{$number.GetType().FullName}
        Assert-True ($number -is [ValueType] -and $number -eq -42) ('Nombre modifie : <'+[string]$number+'> type '+$numberType+' culture '+$culture)
        $text=ConvertTo-DomeniaSpreadsheetCell 'PC-01'
        Assert-True ($text -ceq 'PC-01') ('Texte modifie : <'+[string]$text+'> culture '+$culture)
        $csv=Join-Path $testDirectory 'safe.csv'
        [pscustomobject]@{Name='=2+2';Description='a,"b"';Count=42} | ConvertTo-DomeniaSpreadsheetSafeRow | Export-Csv $csv -NoTypeInformation -Encoding UTF8
        $raw=[IO.File]::ReadAllText($csv)
        $round=@(Import-Csv $csv)
        $roundText=($round|ConvertTo-Json -Compress)
        Assert-True ($round.Count -eq 1) ('Aller-retour CSV : '+$round.Count+' ligne(s) ; brut <'+$raw+'> ; culture '+$culture)
        Assert-True ($round[0].Name -ceq "'=2+2") ('Aller-retour CSV, Name : '+$roundText+' ; brut <'+$raw+'> ; culture '+$culture)
        Assert-True ($round[0].Description -ceq 'a,"b"') ('Aller-retour CSV, Description : '+$roundText+' ; brut <'+$raw+'> ; culture '+$culture)
    }
    # ---------------------------------------------------------------- L02 : Domenia.log et export CSV
    Test-Case 'Journal FI-09 : CR, LF et TAB echappes, pile sur des lignes |' {
        $t=[datetime]'2026-10-08T10:11:12.345'
        $text="Valeur AD`r`n2026-10-08 10:00:00.000`tERROR`tAD=x`tWIN=y`tligne forgee`nSystem.Exception: panne`r`n   at Domenia.Test.Run()`r`n   à Domenia.Test.Start()"
        $lines=@(ConvertTo-DomeniaLogFileLines -Time $t -Level 'ERROR' -AdIdentity 'EXEMPLE\lecteur' -WinIdentity 'EXEMPLE\tech' -Text $text)
        Assert-True ($lines.Count -eq 3) ('Lignes : '+$lines.Count+' <'+($lines -join '|')+'>')
        Assert-True (@($lines|Where-Object{$_.Contains("`r") -or $_.Contains("`n")}).Count -eq 0) 'Retour a la ligne brut dans une ligne du journal.'
        Assert-True ($lines[0].StartsWith("2026-10-08 10:11:12.345`tERROR`tAD=EXEMPLE\lecteur`tWIN=EXEMPLE\tech`t")) $lines[0]
        Assert-True ($lines[0].Split("`t").Count -eq 5) ('Champs : '+$lines[0].Split("`t").Count)
        Assert-True ($lines[0].Contains('Valeur AD\n2026-10-08 10:00:00.000\tERROR\tAD=x\tWIN=y\tligne forgee\nSystem.Exception: panne')) $lines[0]
        Assert-True ($lines[1] -ceq "2026-10-08 10:11:12.345`tERROR`t| at Domenia.Test.Run()") $lines[1]
        Assert-True ($lines[2] -ceq "2026-10-08 10:11:12.345`tERROR`t| à Domenia.Test.Start()") $lines[2]
    }
    Test-Case 'Journal FI-08 : WARN et ERROR de Set-Status ecrits dans Domenia.log' {
        $script:Window=$null;$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
        $script:AuditPath=Join-Path $testDirectory 'statut-Domenia.log'
        Set-Status 'Releve impossible (test FI-08).' 'WARN'
        Set-Status 'Information seulement (test FI-08).'
        Set-Status 'Lecture refusee (test FI-08).' 'ERROR'
        $journal=[IO.File]::ReadAllText($script:AuditPath)
        Assert-True ($journal.Contains("`tWARN`t") -and $journal.Contains('Releve impossible (test FI-08).')) $journal
        Assert-True ($journal.Contains("`tERROR`t") -and $journal.Contains('Lecture refusee (test FI-08).')) $journal
        Assert-True (-not $journal.Contains('Information seulement')) 'Un statut INFO est ecrit dans Domenia.log.'
    }
    Test-Case 'Journal FI-08 : une seule ligne quand Set-Status et Write-AppLog disent la meme phrase' {
        $script:Window=$null;$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
        $script:AuditPath=Join-Path $testDirectory 'doublon-Domenia.log'
        Set-Status 'Detection du dernier utilisateur de PC-01 : refus (test).' 'ERROR'
        Write-DomeniaAppLogFile -Text 'Detection du dernier utilisateur de PC-01 : refus (test).' -Level 'ERROR' -Source 'AppLog'
        Write-DomeniaAppLogFile -Text 'Panne repetee (test).' -Level 'ERROR' -Source 'AppLog'
        Write-DomeniaAppLogFile -Text 'Panne repetee (test).' -Level 'ERROR' -Source 'AppLog'
        Set-Status 'Lecture impossible (INC-1A2B).' 'ERROR' -NoFileLog
        $lines=@([IO.File]::ReadAllLines($script:AuditPath))
        Assert-True (@($lines|Where-Object{$_.Contains('dernier utilisateur de PC-01')}).Count -eq 1) ($lines -join ' | ')
        Assert-True (@($lines|Where-Object{$_.Contains('Panne repetee')}).Count -eq 2) 'Deux lignes Write-AppLog identiques fusionnees.'
        Assert-True (@($lines|Where-Object{$_.Contains('INC-1A2B')}).Count -eq 0) 'Set-Status -NoFileLog ecrit dans Domenia.log.'
    }
    Test-Case 'Journal FI-10 : repli LOCALAPPDATA puis TEMP, puis retour sur Domenia.log' {
        $saved=@{Local=$env:LOCALAPPDATA;Temp=$env:TEMP;Tmp=$env:TMP;Audit=$script:AuditPath}
        try {
            $script:Window=$null;$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
            $blocker=Join-Path $testDirectory 'bloque';[IO.File]::WriteAllText($blocker,'x')
            $script:AuditPath=Join-Path $blocker 'Domenia.log'
            $env:LOCALAPPDATA=Join-Path $testDirectory 'profil-local'
            Write-DomeniaAppLogFile -Text 'Ligne de repli LOCALAPPDATA.' -Level 'WARN'
            $local=Join-Path $env:LOCALAPPDATA 'DOMENIA\Logs\Domenia.log'
            Assert-True ([IO.File]::Exists($local) -and [IO.File]::ReadAllText($local).Contains('Ligne de repli LOCALAPPDATA.')) 'Repli LOCALAPPDATA absent.'
            Assert-True ([bool]$script:AppLogUnavailable -and ([string]$script:AppLogFallbackPath -eq $local)) 'Pastille Journal indisponible non armee.'
            $env:LOCALAPPDATA=Join-Path $blocker 'profil'
            $env:TEMP=Join-Path $testDirectory 'temp-repli';$env:TMP=$env:TEMP
            Write-DomeniaAppLogFile -Text 'Ligne de repli TEMP.' -Level 'WARN'
            $tempLog=Join-Path ([IO.Path]::GetTempPath()) 'DOMENIA\Logs\Domenia.log'
            Assert-True ($tempLog.StartsWith($env:TEMP) -and [IO.File]::Exists($tempLog) -and [IO.File]::ReadAllText($tempLog).Contains('Ligne de repli TEMP.')) ('Repli TEMP absent : '+$tempLog)
            $script:AuditPath=Join-Path $testDirectory 'retour-Domenia.log'
            Write-DomeniaAppLogFile -Text 'Ligne de retour.' -Level 'INFO'
            $back=[IO.File]::ReadAllText($script:AuditPath)
            Assert-True ($back.Contains('Ligne de retour.') -and $back.Contains($tempLog) -and (-not [bool]$script:AppLogUnavailable)) $back
        } finally {
            $env:LOCALAPPDATA=$saved.Local;$env:TEMP=$saved.Temp;$env:TMP=$saved.Tmp;$script:AuditPath=$saved.Audit
            $script:AppLogUnavailable=$false;$script:AppLogFallbackPath=''
        }
    }
    Test-Case 'Journal FI-10 : aucun emplacement inscriptible, lignes gardees en file et pertes comptees' {
        $saved=@{Local=$env:LOCALAPPDATA;Temp=$env:TEMP;Tmp=$env:TMP;Audit=$script:AuditPath}
        try {
            $script:Window=$null;$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null;$script:AppLogDropped=0
            $blocker=Join-Path $testDirectory 'bloque-tout';[IO.File]::WriteAllText($blocker,'x')
            $script:AuditPath=Join-Path $blocker 'Domenia.log'
            $env:LOCALAPPDATA=Join-Path $blocker 'profil';$env:TEMP=Join-Path $blocker 'temp';$env:TMP=$env:TEMP
            Write-DomeniaAppLogFile -Text 'Ligne sans emplacement (test).' -Level 'ERROR'
            Assert-True ($script:AppLogQueue.Count -eq 1 -and [bool]$script:AppLogUnavailable -and (-not [string]$script:AppLogFallbackPath)) ('File : '+$script:AppLogQueue.Count)
            Assert-True (($null -ne $script:AppLogRetryAt) -and ([int]$script:AppLogDropped -eq 0)) 'Ligne perdue au premier refus.'
            # Bounded queue: the oldest lines leave first and are counted.
            $script:AppLogQueue.AddRange([string[]]@(1..5010|ForEach-Object{'ligne en attente '+$_}))
            Write-DomeniaAppLogFile -Text 'Ligne la plus recente (test).' -Level 'WARN'
            Assert-True (($script:AppLogQueue.Count -eq 5000) -and ([int]$script:AppLogDropped -eq 12)) ('File '+$script:AppLogQueue.Count+', perdues '+$script:AppLogDropped)
            $script:AuditPath=Join-Path $testDirectory 'retour-total-Domenia.log'
            Flush-DomeniaAppLog -Force
            $back=[IO.File]::ReadAllText($script:AuditPath)
            Assert-True ($back.Contains('12 ligne(s) de journal perdue(s)') -and $back.Contains('Ligne la plus recente (test).') -and ($script:AppLogQueue.Count -eq 0) -and ([int]$script:AppLogDropped -eq 0)) 'Lignes ou compte des pertes absents apres retour.'
        } finally {
            $env:LOCALAPPDATA=$saved.Local;$env:TEMP=$saved.Temp;$env:TMP=$saved.Tmp;$script:AuditPath=$saved.Audit
            $script:AppLogUnavailable=$false;$script:AppLogFallbackPath='';$script:AppLogRetryAt=$null;$script:AppLogDropped=0;$script:AppLogQueue=$null
        }
    }
    Test-Case 'Journal PF-09 : file videe toutes les 500 ms et a la fermeture de la fenetre' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogFlushTimer=$null;$script:AppLogFlushWindow=$null;$script:AppLogQueueClosed=$false
        $script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
        $script:AuditPath=Join-Path $testDirectory 'file-Domenia.log'
        $script:Window=[Windows.Window]::new()
        try {
            Write-DomeniaAppLogFile -Text 'Ligne en file (test PF-09).' -Level 'INFO'
            Assert-True ($null -ne $script:AppLogFlushTimer -and $script:AppLogQueue.Count -ge 1) 'La ligne n est pas passee par la file.'
            Assert-True (-not [IO.File]::Exists($script:AuditPath)) 'Ecriture disque immediate sur le fil de l interface.'
            # Periodic flush: the Dispatcher runs for 700 ms, the 500 ms timer writes the queue.
            $frame=[Windows.Threading.DispatcherFrame]::new()
            $stop=[Windows.Threading.DispatcherTimer]::new();$stop.Interval=[TimeSpan]::FromMilliseconds(700)
            $handler=[EventHandler]({$frame.Continue=$false}.GetNewClosure())
            $stop.Add_Tick($handler)
            try{$stop.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$stop.Stop();$stop.Remove_Tick($handler)}
            Assert-True ([IO.File]::Exists($script:AuditPath) -and [IO.File]::ReadAllText($script:AuditPath).Contains('Ligne en file (test PF-09).')) 'File non videe par le minuteur de 500 ms.'
            Assert-True ($script:AppLogQueue.Count -eq 0) ('Lignes restees en file : '+$script:AppLogQueue.Count)
            # Closed hook: the window closes before the next tick, its queued line is written.
            Write-DomeniaAppLogFile -Text 'Ligne avant fermeture (test PF-09).' -Level 'INFO'
            Assert-True (-not [IO.File]::ReadAllText($script:AuditPath).Contains('Ligne avant fermeture')) 'Ecriture immediate avant la fermeture.'
            $script:Window.Close()
            Assert-True ([IO.File]::ReadAllText($script:AuditPath).Contains('Ligne avant fermeture (test PF-09).')) 'File non videe par la fermeture de la fenetre.'
            Assert-True ([bool]$script:AppLogQueueClosed -and ($null -eq $script:AppLogFlushTimer)) 'Minuteur du journal actif apres fermeture.'
            Write-DomeniaAppLogFile -Text 'Ligne apres fermeture.' -Level 'INFO'
            Assert-True ([IO.File]::ReadAllText($script:AuditPath).Contains('Ligne apres fermeture.')) 'Ligne perdue apres fermeture.'
        } finally {
            if($null -ne $script:AppLogFlushTimer){$script:AppLogFlushTimer.Stop()}
            $script:AppLogFlushTimer=$null;try{$script:Window.Close()}catch{};$script:Window=$null;$script:AppLogQueueClosed=$false;$script:AppLogFlushWindow=$null
        }
    }
    Test-Case 'CSV CO-04 : separateur point-virgule, BOM, colonnes visibles et en-tetes francais' {
        Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
        $grid=[Windows.Controls.DataGrid]::new()
        foreach($spec in @(@('Nom','Name',$true),@('Interne','Guid',$false),@('Type','Type',$true))){
            $col=[Windows.Controls.DataGridTextColumn]::new();$col.Header=$spec[0];$col.Binding=[Windows.Data.Binding]::new($spec[1])
            if(-not $spec[2]){$col.Visibility='Collapsed'};[void]$grid.Columns.Add($col)
        }
        $template=[Windows.Controls.DataGridTemplateColumn]::new();$template.Header='Présence réseau';$template.SortMemberPath='Presence';[void]$grid.Columns.Add($template)
        # A template column without sort path (Détail of DgSelfCheck): its binding is read from the cell template.
        $cell=[Windows.Markup.XamlReader]::Parse('<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><StackPanel Orientation="Horizontal"><TextBlock Text="{Binding Detail}"/></StackPanel></DataTemplate>')
        $detail=[Windows.Controls.DataGridTemplateColumn]::new();$detail.Header='Détail';$detail.CellTemplate=$cell;[void]$grid.Columns.Add($detail)
        # CO-03b : une colonne modele qui affiche « il y a 3 j » doit exporter la date complete que
        # son Tag designe, ni la cle de tri (un DateTime) que SortMemberPath lui designerait,
        # ni le texte court que son modele affiche.
        $dateCell=[Windows.Markup.XamlReader]::Parse('<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="{Binding ChangedShort}" ToolTip="{Binding Changed}"/></DataTemplate>')
        $dateCol=[Windows.Controls.DataGridTemplateColumn]::new();$dateCol.Header='Modifie';$dateCol.SortMemberPath='ChangedSort';$dateCol.ClipboardContentBinding=[Windows.Data.Binding]::new('Changed');$dateCol.CellTemplate=$dateCell;[void]$grid.Columns.Add($dateCol)
        $columns=@(Get-DomeniaGridExportColumns -Grid $grid)
        Assert-True ((($columns|ForEach-Object{$_.Header}) -join '|') -ceq 'Nom|Type|Présence réseau|Détail|Modifie') ('Colonnes : '+(($columns|ForEach-Object{$_.Header}) -join '|'))
        Assert-True ([string]$columns[3].Property -ceq 'Detail') ('Propriete du modele : '+[string]$columns[3].Property)
        Assert-True ([string]$columns[4].Property -ceq 'Changed') ('Date courte exportee : '+[string]$columns[4].Property)
        $rows=@([pscustomobject]@{Name='=2+2';Type='Machine';Guid='0a1b';Presence='En ligne';PresenceDetail="Multi`r`nligne";Detail='Contrôle réussi';Changed='09/05/2026 08:00:00';ChangedShort='il y a 3 j'},[pscustomobject]@{Name='PC-02';Type='Machine';Guid='0c1d';Presence='Hors ligne';PresenceDetail='';Detail='À vérifier';Changed='03/06/2025 08:00:00';ChangedShort='03/06/2025'})
        $out=Join-Path $testDirectory 'export-co04.csv'
        $result=Export-DomeniaCsv -Rows $rows -Grid $grid -Path $out
        $bytes=[IO.File]::ReadAllBytes($out)
        Assert-True (($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)) 'UTF-8 sans BOM.'
        $text=[IO.File]::ReadAllText($out)
        $first=($text -split "\r?\n")[0]
        Assert-True ($first -ceq '"Nom";"Type";"Présence réseau";"Détail";"Modifie"') ('En-tete : '+$first)
        # Le CSV garde la date complete : « il y a 3 j » ne se relit pas six mois plus tard.
        Assert-True ($text.Contains('09/05/2026 08:00:00') -and (-not $text.Contains('il y a 3 j'))) 'Le CSV a exporte le texte court ou la cle de tri.'
        Assert-True ((-not $text.Contains('0a1b')) -and (-not $text.Contains('Multi'))) 'Colonne masquee ou propriete interne exportee.'
        Assert-True ($text.Contains("""'=2+2""") -and ($result.RowCount -eq 2)) $text
        $round=@(Import-Csv -LiteralPath $out -Delimiter ';' -Encoding UTF8)
        Assert-True (($round.Count -eq 2) -and ($round[1].Nom -ceq 'PC-02')) 'Relecture point-virgule impossible.'
        Assert-True (($round[0].'Présence réseau' -ceq 'En ligne') -and ($round[1].'Présence réseau' -ceq 'Hors ligne')) 'Valeurs de la colonne modele absentes.'
        Assert-True (($round[0].'Détail' -ceq 'Contrôle réussi') -and ($round[1].'Détail' -ceq 'À vérifier')) 'Valeurs de la colonne sans chemin de tri absentes.'
    }
    Test-Case 'CSV UX-02 : nom Domenia-<OU ou poste>-AAAAMMJJ-HHmm, jamais d ecrasement' {
        $name=Get-DomeniaExportFileName -Subject 'Postes / Paris' -Time ([datetime]'2026-10-08T14:30:59')
        Assert-True ($name -ceq 'Domenia-Postes-Paris-20261008-1430.csv') $name
        Assert-True ((Get-DomeniaExportFileName -Subject '' -Time ([datetime]'2026-10-08T14:30:00')) -ceq 'Domenia-export-20261008-1430.csv') 'Sujet vide.'
        $dir=Join-Path $testDirectory 'exports';[void][IO.Directory]::CreateDirectory($dir)
        $one=Export-DomeniaCsv -Rows @([pscustomobject]@{Nom='A'}) -Directory $dir -Subject 'PC-01'
        $two=Export-DomeniaCsv -Rows @([pscustomobject]@{Nom='B'}) -Directory $dir -Subject 'PC-01'
        Assert-True ($one.Path -ne $two.Path -and [IO.File]::Exists($one.Path) -and [IO.File]::ReadAllText($one.Path).Contains('"A"')) ($one.Path+' / '+$two.Path)
        Assert-True ([IO.Path]::GetFileName($one.Path) -match '^Domenia-PC-01-\d{8}-\d{4}\.csv$') $one.Path
    }
    Test-Case 'CSV : import accepte le point-virgule de Domenia et la virgule historique' {
        $semi=Join-Path $testDirectory 'liens-semi.csv';[IO.File]::WriteAllText($semi,"""UserLogin"";""Computer""`r`n""a"";""PC-1""",[Text.UTF8Encoding]::new($true))
        $comma=Join-Path $testDirectory 'liens-comma.csv';[IO.File]::WriteAllText($comma,"""UserLogin"",""Computer""`r`n""a"",""PC-1""")
        Assert-True (((Get-DomeniaCsvDelimiter -Path $semi) -eq ';') -and ((Get-DomeniaCsvDelimiter -Path $comma) -eq ',')) 'Separateur mal detecte.'
    }
    Test-Case 'LIKE : echappement independant du SQL' {
        Assert-True ((ConvertTo-DomeniaSqlLikeText 'pc_20%!') -ceq 'pc!_20!%!!')
        Assert-True ((ConvertTo-DomeniaSqlLiteral "O'Neil") -ceq "'O''Neil'")
    }
    Test-Case 'Perimetres : cle stable et domaines distincts' {
        Assert-True ((Get-DomeniaScopeKey ' DC=Exemple,DC=TEST ') -ceq (Get-DomeniaScopeKey 'dc=exemple,dc=test'))
        Assert-True ((Get-DomeniaScopeKey 'dc=a,dc=test') -cne (Get-DomeniaScopeKey 'dc=b,dc=test'))
    }
    Test-Case 'WMI : filtre borne et fournisseur MSI refuse' {
        Assert-DomeniaWmiReadQuery Win32_OperatingSystem 'root\cimv2' '' 25
        Assert-DomeniaWmiReadQuery Win32_Service 'root\cimv2' "Name='Spooler'" 500
        Assert-Throws {Assert-DomeniaWmiReadQuery Win32_Product 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery 'Bad;Class' 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery Win32_Service 'root\cimv2' '' 501}
        Assert-Throws {Assert-DomeniaWmiReadQuery Win32_Service 'root\cimv2' ([string][char]0) 25}
        # SE-03 : 88 classes passent par le fournisseur MSI, pas seulement Win32_Product.
        Assert-Throws {Assert-DomeniaWmiReadQuery CIM_Product 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery Win32_SoftwareFeature 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery 'CIM_Product.ActsAsComponent' 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery 'root\cimv2:Win32_Product' 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery Win32_Patch 'root\cimv2' '' 25}
        Assert-Throws {Assert-DomeniaWmiReadQuery CIM_Component 'root\cimv2' '' 25}
        # Toute la liste du fournisseur est refusee, pas trois noms choisis a la main.
        foreach($msiClass in @(Get-DomeniaMsiProviderClassNames)){ Assert-Throws {Assert-DomeniaWmiReadQuery $msiClass 'root\cimv2' '' 25} }
        Assert-True ([bool](Test-DomeniaMsiProviderClass 'CIM_Product'))
        Assert-True (-not [bool](Test-DomeniaMsiProviderClass 'Win32_Service'))
    }
    Test-Case 'WMI : le worker refuse le fournisseur MSI sans en recopier la liste' {
        $msiNames=@(Get-DomeniaMsiProviderClassNames)
        Assert-True ($msiNames.Count -ge 80)
        $workerCode=[scriptblock]::Create((Get-DomeniaWmiQueryWorkerCode))
        foreach($blocked in @('Win32_Product','CIM_Product','Win32_SoftwareFeature','CIM_Product.ActsAsComponent','Win32_Patch','CIM_Component')){
            $Payload=[pscustomobject]@{Computer='pc-01.example.invalid';Namespace='root\cimv2';ClassName=$blocked;Where='';Limit=25;MsiClassNames=$msiNames}
            $message=''
            try{ & $workerCode }catch{ $message=[string]$_.Exception.Message }
            Assert-True ($message -match 'fournisseur MSI') ('Classe '+$blocked+' non refusee par le worker : '+$message)
        }
        # Sans liste transmise, le worker ne peut rien juger : il refuse au lieu de laisser passer.
        foreach($sansListe in @('absente','vide','nulle')){
            $Payload=[pscustomobject]@{Computer='pc-01.example.invalid';Namespace='root\cimv2';ClassName='CIM_Product';Where='';Limit=25}
            if($sansListe -eq 'vide'){ $Payload | Add-Member -NotePropertyName MsiClassNames -NotePropertyValue @() }
            if($sansListe -eq 'nulle'){ $Payload | Add-Member -NotePropertyName MsiClassNames -NotePropertyValue @($null) }
            $message=''
            try{ & $workerCode }catch{ $message=[string]$_.Exception.Message }
            Assert-True ($message -match 'Garde MSI absente') ('Worker laisse passer sans liste ('+$sansListe+') : '+$message)
        }
        # Controle positif : une classe saine franchit la garde ; l'echec vient ensuite du transport absent.
        $Payload=[pscustomobject]@{Computer='pc-01.example.invalid';Namespace='root\cimv2';ClassName='Win32_Service';Where='';Limit=25;MsiClassNames=$msiNames}
        $message=''
        try{ & $workerCode }catch{ $message=[string]$_.Exception.Message }
        Assert-True ($message -ne '' -and $message -notmatch 'fournisseur MSI') ('Classe saine refusee par la garde MSI : '+$message)
    }
    Test-Case 'Secrets : masque integral et absence de Value dans la grille' {
        $script:SecretRows=@([pscustomobject]@{Kind='LAPS';Account='test';Value='abcdSecret1234';Timestamp='';Source='test';Detail=''})
        $script:SecretsVisible=$false
        Update-SecretsGrid
        Assert-True ($script:TestBoundRows[0].DisplayValue -ceq '********')
        Assert-True ($null -eq $script:TestBoundRows[0].PSObject.Properties['Value'])
        $script:TestGrid=[pscustomobject]@{SelectedItem=$script:TestBoundRows[0]}
        Assert-True ((Get-DomeniaSelectedSecretSource).Value -ceq 'abcdSecret1234')
        $script:TestGrid.SelectedItem=[pscustomobject]@{SecretIndex=100}
        Assert-True ($null -eq (Get-DomeniaSelectedSecretSource))
        $script:SecretRows=@()
    }
    Test-Case 'Registre ferme : corps du contrat DEV et rejet d un corps modifie' {
        $hashes=Get-DomeniaWorkerOperationHashes
        # Count and files come from tools/operation-contracts.json (two-step parse for 5.1), never a constant (47 at RC1).
        $c=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
        $contracts=@($c)
        Assert-True ((Assert-DomeniaWorkerRegistry) -eq $contracts.Count) ('Registre / contrat : '+$hashes.Count+' / '+$contracts.Count)
        # Search the operation bodies in every file the contract names (core and modules), not only core + Live.Model.
        $literalNodes=@()
        foreach($contractFile in @($contracts|ForEach-Object{[string]$_.File}|Sort-Object -Unique)) {
            $fileTokens=$null;$fileErrors=$null
            $fileAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $contractFile),[ref]$fileTokens,[ref]$fileErrors)
            Assert-True (@($fileErrors).Count -eq 0) ('Analyse impossible : '+$contractFile)
            $literalNodes+=@($fileAst.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString},$true))
        }
        $sha=[Security.Cryptography.SHA256]::Create()
        try {
            foreach($id in $hashes.Keys) {
                $matches=0;$matchedCode=''
                foreach($literal in $literalNodes) {
                    $canonical=ConvertTo-DomeniaCanonicalWorkerCode ([string]$literal.Value)
                    $h=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))).Replace('-','')
                    if($h -ceq $hashes[$id]) {$matches++;$matchedCode=$canonical}
                }
                Assert-True ($matches -ge 1) ('Corps introuvable : '+$id)
                Assert-DomeniaWorkerOperationCode -OperationId $id -Code $matchedCode
                Assert-Throws {Assert-DomeniaWorkerOperationCode -OperationId $id -Code ($matchedCode+"`n# altered")}
            }
        } finally {$sha.Dispose()}
    }
    Test-Case 'Nettoyage reel : runspace local annule et detache' {
        $script:DetachedReadJobs=New-Object Collections.ArrayList
        $rs=[System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace();$rs.ApartmentState='MTA';$rs.Open()
        $ps=[System.Management.Automation.PowerShell]::Create();$ps.Runspace=$rs
        [void]$ps.AddScript('Start-Sleep -Milliseconds 500; 42')
        $handle=$ps.BeginInvoke();$stop=$ps.BeginStop($null,$null)
        [void]$script:DetachedReadJobs.Add([pscustomobject]@{Handle=$handle;StopHandle=$stop;PowerShell=$ps;Runspace=$rs;OnSuccess=$null;OnError=$null;CallbackState=$null})
        $watch=[Diagnostics.Stopwatch]::StartNew()
        do {Complete-DomeniaDetachedReadJobs;if($script:DetachedReadJobs.Count -eq 0){break};Start-Sleep -Milliseconds 20} while($watch.Elapsed.TotalSeconds -lt 5)
        Assert-True ($script:DetachedReadJobs.Count -eq 0) 'Le runspace local est reste detache apres son arret.'
    }
    if (-not $SkipNativeCache) {
        Test-Case 'SQLite Windows : WAL, sauvegarde native et controle de la copie' {
            $dbPath=Get-DomeniaDatabasePath;$db=Open-DomeniaDatabase -Path $dbPath
            try {
                [void](Invoke-DomeniaDbExec "PRAGMA journal_mode=WAL;CREATE TABLE sample(id INTEGER PRIMARY KEY,value TEXT);INSERT INTO sample(value) VALUES('ete'),('test');CREATE TABLE sync_state(scope TEXT PRIMARY KEY,base_dn TEXT);INSERT INTO sync_state VALUES('directory','dc=a,dc=test');" $db)
                $snapshot=Backup-DomeniaDatabase
                Assert-True ([IO.File]::Exists($snapshot))
                $copy=Open-DomeniaDatabase -Path $snapshot -ReadOnly
                try {
                    Assert-True ((Invoke-DomeniaDbQuery 'PRAGMA quick_check;' $copy).quick_check -ceq 'ok')
                    Assert-True ((Invoke-DomeniaDbQuery 'SELECT COUNT(*) AS n FROM sample;' $copy).n -eq 2)
                } finally {Close-DomeniaDatabase $copy}
                [void](Invoke-DomeniaDbExec "INSERT INTO sample(value) VALUES('apres');" $db)
            } finally {Close-DomeniaDatabase $db}
            Assert-True ((Invoke-DomeniaDbQuery 'SELECT COUNT(*) AS n FROM sample;').n -eq 3)
        }
        Test-Case 'SQLite Windows : adoption ancienne base seulement pour le bon perimetre' {
            $script:Conn.BaseDn='DC=A,DC=TEST'
            Assert-True ((Get-DomeniaDatabasePath) -ieq (Join-Path $script:DataDir 'Domenia.db'))
            $script:Conn.BaseDn='DC=B,DC=TEST'
            $other=Get-DomeniaDatabasePath
            Assert-True ($other.Contains('Domains'))
            Assert-True ([IO.File]::Exists((Join-Path $script:DataDir 'Domenia.db')))
            $script:Conn.BaseDn='';$script:DatabaseScopeIdentity='';$script:DatabaseScopedPath=''
        }
        Test-Case 'SQLite Windows : recherche UPN et metacaracteres litteraux' {
            [void](Invoke-DomeniaDbExec 'CREATE TABLE ad_objects(object_type TEXT,name TEXT,login TEXT,upn TEXT,display_name TEXT,description TEXT,extra TEXT,state TEXT,distinguished_name TEXT,when_changed TEXT,usn_changed INTEGER,last_logon TEXT,object_guid TEXT,search_key TEXT);')
            foreach($sample in @(@('sam','sam@a.test'),@('sam','sam@b.test'),@('pc_01','pc_01@a.test'),@('pcX01','pcX01@a.test'),@('pc%02','pc%02@a.test'))) {
                $name=ConvertTo-DomeniaSqlLiteral $sample[0];$upn=ConvertTo-DomeniaSqlLiteral $sample[1];$guid=ConvertTo-DomeniaSqlLiteral ([guid]::NewGuid().ToString())
                [void](Invoke-DomeniaDbExec "INSERT INTO ad_objects VALUES('User',$name,$name,$upn,$name,'','','OK',$upn,'',0,'',$guid,lower($upn));")
            }
            Assert-True (@(Search-DomeniaDatabaseRows 'sam@a.test').Count -eq 1)
            $literal=@(Search-DomeniaDatabaseRows 'pc_01')
            Assert-True ($literal.Count -eq 1 -and $literal[0].Name -ceq 'pc_01')
            Assert-True (@(Search-DomeniaDatabaseRows 'pc%02').Count -eq 1)
        }
    }
    Test-Case 'Base autonome : la coupe du serveur est nommee avec sa propre limite' {
        # Le controleur peut couper une recherche sans que le worker le sache : le motif doit porter le delai du
        # serveur, jamais le budget local, sinon l alerte nomme la cle qu il ne faut pas lever.
        $coupe = Get-DomeniaIndexCut -Effective ([pscustomobject]@{ LimitReason='serveur'; LimitServerSeconds=120; LimitBudgetMs=1200000; LimitMaxObjects=5000000 })
        Assert-True ([string]$coupe.Reason -eq 'serveur') 'Le motif serveur est perdu'
        Assert-True ([string]$coupe.Limit -eq '120') 'Le motif serveur nomme une autre limite que son delai'
        $temps = Get-DomeniaIndexCut -Effective ([pscustomobject]@{ LimitReason='temps'; LimitServerSeconds=120; LimitBudgetMs=1200000; LimitMaxObjects=5000000 })
        Assert-True ([string]$temps.Reason -eq 'temps') 'Le motif temps est perdu'
        Assert-True ([string]$temps.Limit -eq '1200000') 'Le motif temps ne nomme plus Index.BudgetMs'
        $aucune = Get-DomeniaIndexCut -Effective ([pscustomobject]@{ LimitReason='' })
        Assert-True ([string]$aucune.Reason -eq '') 'Une passe sans limite doit rester sans motif'
    }
    Test-Case 'Base autonome : le périmètre choisi est indépendant de Recherche' {
        $script:Conn.BaseDn='DC=EX,DC=TEST'
        try {
            $script:IndexScopeDn=''
            $s=Get-DomeniaIndexScope
            Assert-True ([bool]$s.IsDomain) 'Sans choix explicite, la cible doit être tout le domaine'
            Assert-True ($s.BaseDn -ceq 'DC=EX,DC=TEST') 'La cible domaine est mal définie'
            $script:IndexScopeDn='OU=Ateliers,OU=Site,DC=EX,DC=TEST'
            $s=Get-DomeniaIndexScope
            Assert-True (-not [bool]$s.IsDomain) 'Une OU choisie reste une OU'
            Assert-True ($s.BaseDn -ceq 'OU=Ateliers,OU=Site,DC=EX,DC=TEST') ('Portée : ' + $s.BaseDn)
            Assert-True ($s.Scope -ceq 'Subtree') 'Le sous-arbre est relu, pas un seul niveau'
            $script:IndexScopeDn='DC=EX,DC=TEST'
            $s=Get-DomeniaIndexScope
            Assert-True ([bool]$s.IsDomain) 'La racine choisie vaut tout le domaine'
            Assert-True ($s.BaseDn -ceq 'DC=EX,DC=TEST') 'La racine ne reste pas filtrée'
            $script:IndexScopeDn='OU=Autre,DC=AUTRE,DC=TEST'
            $s=Get-DomeniaIndexScope
            Assert-True ([bool]$s.IsDomain) 'Une OU hors domaine doit revenir au domaine courant'
            Assert-True ($s.BaseDn -ceq 'DC=EX,DC=TEST') 'La cible invalide doit être neutralisée'
        } finally {
            $script:IndexScopeDn=''
            $script:Conn.BaseDn=''
        }
    }
    Test-Case 'CO-03 : les dates et les tailles des grilles se trient par valeur' {
        # Le tri par texte est la faute : il place 09/05/2026 avant 10/01/2026.
        $dates = @('09/05/2026 08:00:00','03/06/2025 08:00:00','10/01/2026 08:00:00') | ForEach-Object {
            [pscustomobject]@{ Name='x'; InstallDate=$_ }
        }
        $typed = @($dates | ForEach-Object { Add-DomeniaGridDateKeys -Row $_ -Fields @('InstallDate') } | Sort-Object InstallDateSort | ForEach-Object { $_.InstallDate })
        Assert-True (($typed -join '|') -eq '03/06/2025 08:00:00|10/01/2026 08:00:00|09/05/2026 08:00:00') ('Ordre par valeur : ' + ($typed -join '|'))
        $textual = @($dates | Sort-Object InstallDate | ForEach-Object { $_.InstallDate })
        Assert-True (($textual -join '|') -eq '03/06/2025 08:00:00|09/05/2026 08:00:00|10/01/2026 08:00:00') ('Le tri par texte a change de sens : ' + ($textual -join '|'))
        # Le poste publie aussi des dates sans heure (Win32_InstallDate) ; tout le reste tombe au plus ancien.
        Assert-True ((Get-DomeniaGridDateSortKey '09/05/2026') -eq [datetime]::new(2026,5,9))
        Assert-True ((Get-DomeniaGridDateSortKey '09/05/2026 08:00') -eq [datetime]::new(2026,5,9,8,0,0))
        foreach ($sansDate in @('', '   ', 'Jamais', 'pas une date', $null)) {
            Assert-True ((Get-DomeniaGridDateSortKey $sansDate) -eq [datetime]::MinValue) ('Date « ' + [string]$sansDate + ' » triee ailleurs qu au plus ancien')
        }
        # Une ligne sans la propriete ne leve pas : elle recoit la cle la plus ancienne.
        $vide = Add-DomeniaGridDateKeys -Row ([pscustomobject]@{ Name='seul' }) -Fields @('Changed')
        Assert-True ($vide.ChangedSort -eq [datetime]::MinValue) 'Cle absente sans lever'
        # CO-03b : l'affiche court, a horloge figee pour que l'ecart mesure reste deterministe.
        $now = [datetime]::new(2026,10,10,12,0,0)
        $courtes = @(
            @('10/10/2026 11:59:30',"à l'instant"),
            @('10/10/2026 11:30:00','il y a 30 min'),
            @('10/10/2026 08:00:00','il y a 4 h'),
            @('07/10/2026 12:00:00','il y a 3 j'),
            @('01/09/2026 12:00:00','01/09/2026'),
            @('11/10/2026 12:00:00','11/10/2026'),
            @('Jamais','Jamais'),
            @('',''),
            @('Inconnu','Inconnu')
        )
        foreach ($courte in $courtes) {
            Assert-True (([string](Get-DomeniaGridDateShortText $courte[0] $now)) -ceq $courte[1]) ('Date courte « ' + $courte[0] + ' » : ' + [string](Get-DomeniaGridDateShortText $courte[0] $now))
        }
        # La ligne emporte les deux : le texte court affiche et la date complete de l'infobulle.
        $ligne = Add-DomeniaGridDateKeys -Row ([pscustomobject]@{ Changed='07/10/2026 12:00:00' }) -Fields @('Changed') -Now $now
        Assert-True (([string]$ligne.ChangedShort) -ceq 'il y a 3 j') ('Texte court : ' + [string]$ligne.ChangedShort)
        Assert-True (([string]$ligne.Changed) -ceq '07/10/2026 12:00:00') 'La date complete a quitte la ligne'
        Assert-True ($ligne.ChangedSort -eq [datetime]::new(2026,10,7,12,0,0))
        # Taille : SizeKb est deja un nombre, c est la colonne qui doit le designer.
        $sizes = @([pscustomobject]@{Name='a';SizeKb=9.0},[pscustomobject]@{Name='b';SizeKb=120.0},[pscustomobject]@{Name='c';SizeKb=1000.0})
        Assert-True ((@($sizes | Sort-Object SizeKb | ForEach-Object { $_.Name }) -join '') -eq 'abc') 'Tailles triees par texte'
        # Les colonnes du XAML reel designent la cle, pas le texte affiche.
        $xaml = [xml](Get-MainXaml)
        $cols = @($xaml.SelectNodes('//*[local-name()="DataGridTextColumn" or local-name()="DataGridTemplateColumn"]'))
        foreach ($want in @(@('Derniere connexion','LastLogonSort'),@('Modifie','ChangedSort'),@('Installe le','InstallDateSort'),@('Taille','SizeKb'))) {
            $hit = @($cols | Where-Object { $_.Header -eq $want[0] -and $_.SortMemberPath -eq $want[1] })
            Assert-True ($hit.Count -ge 1) ('Colonne ' + $want[0] + ' sans SortMemberPath ' + $want[1])
        }
        # CO-03b : la colonne modele affiche le texte court et garde la date complete en infobulle.
        foreach ($tpl in @(@('Derniere connexion','LastLogon','LastLogonSort'),@('Modifie','Changed','ChangedSort'),@('Installe le','InstallDate','InstallDateSort'))) {
            $c = @($cols | Where-Object { $_.Header -eq $tpl[0] })
            Assert-True ($c.Count -eq 1) ('Colonne ' + $tpl[0] + ' : ' + $c.Count + ' occurrence(s)')
            Assert-True (([string]$c[0].ClipboardContentBinding) -ceq ('{Binding ' + $tpl[1] + '}')) ('Colonne ' + $tpl[0] + ' sans valeur exportable ' + $tpl[1] + ' : ' + [string]$c[0].ClipboardContentBinding)
            $tb = $c[0].SelectSingleNode('*[local-name()="DataGridTemplateColumn.CellTemplate"]/*[local-name()="DataTemplate"]/*[local-name()="TextBlock"]')
            Assert-True ($null -ne $tb) ('Colonne ' + $tpl[0] + ' sans TextBlock dans son modele')
            Assert-True (([string]$tb.Text) -ceq ('{Binding ' + $tpl[1] + 'Short}')) ('Colonne ' + $tpl[0] + ' n affiche pas le texte court : ' + [string]$tb.Text)
            Assert-True (([string]$tb.ToolTip) -ceq ('{Binding ' + $tpl[1] + '}')) ('Colonne ' + $tpl[0] + ' sans date complete en infobulle : ' + [string]$tb.ToolTip)
        }
    }
    Test-Case 'CO-27 : creer une OU reste dans l onglet et ne promet pas la protection' {
        # Le menu de l arbre ouvrait une fenetre pour le nom puis la confirmation demandait de taper
        # CREER, et le message promettait une protection que la voie ADSI ne pose pas.
        $fn = @($nodes | Where-Object { $_.Name -eq 'Create-OuUnderSelected' })
        Assert-True ($fn.Count -eq 1) 'Create-OuUnderSelected introuvable dans le coeur'
        $texte = [string]$fn[0].Extent.Text
        Assert-True ($texte -notmatch 'TypedConfirmation') 'La creation d une OU exige encore de taper un mot'
        Assert-True (-not $texte.Contains('protégée contre la suppression accidentelle')) 'Le message promet encore une protection que la voie ADSI ne pose pas'
        Assert-True ($texte.Contains('suppression accidentelle')) 'La condition de la protection a disparu de la confirmation'
        Assert-True ($texte.Contains('ADSI')) 'La confirmation ne dit plus quelle voie pose la protection'
        $menu = @($nodes | Where-Object { $_.Name -eq 'Build-DomeniaTreeContextMenu' })
        Assert-True ($menu.Count -eq 1) 'Build-DomeniaTreeContextMenu introuvable dans le coeur'
        Assert-True (-not ([string]$menu[0].Extent.Text).Contains('Show-DomeniaFormDialog')) 'Le menu de l arbre ouvre encore une fenetre pour creer une OU'
        # La branche cible doit se lire avant de confirmer, en lecture seule.
        $xaml = [xml](Get-MainXaml)
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $champ = @($xaml.SelectNodes('//*[local-name()="TextBox"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'TxtNewOuParent' })
        Assert-True ($champ.Count -eq 1) ('TxtNewOuParent : ' + $champ.Count + ' occurrence(s)')
        Assert-True (([string]$champ[0].GetAttribute('IsReadOnly')) -ceq 'True') 'La branche parente est modifiable'
        Assert-True (-not ([string](Get-MainXaml)).Contains('est créée sous la branche sélectionnée dans lʼarborescence')) "Le texte muet renvoie encore a l arborescence sans montrer la branche"
        # Le fichier d aide est indexe par x:Name : Titre = nom d automation, Text = infobulle.
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        $entree = @($aide | Where-Object { $_.Name -eq 'TxtNewOuParent' })
        Assert-True ($entree.Count -eq 1) 'Entree d aide TxtNewOuParent absente ou dupliquee'
        Assert-True (([string]$entree[0].Title) -ceq [string]$champ[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide different du nom d automation'
        Assert-True (([string]$entree[0].Text) -ceq [string]$champ[0].GetAttribute('ToolTip')) 'Texte de l aide different de l infobulle'
    }
    Test-Case 'CO-23 : la date du mot de passe est nommee et expliquee' {
        # Le champ portait le nom d automation et l infobulle des vraies saisies de mot de passe :
        # un lecteur d ecran annoncait « Mot de passe » la ou l operateur lit une date, et l aide
        # jurait de ne jamais lire une valeur que l ecran affiche en clair.
        $xaml = [xml](Get-MainXaml)
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $champ = @($xaml.SelectNodes('//*[local-name()="TextBox"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'TxtUserPwdLastSet' })
        Assert-True ($champ.Count -eq 1) ('TxtUserPwdLastSet : ' + $champ.Count + ' occurrence(s)')
        $nom = [string]$champ[0].GetAttribute('AutomationProperties.Name')
        Assert-True ($nom.Length -gt 0) 'Le champ a perdu son nom d automation'
        Assert-True ($nom -cne 'Mot de passe') 'Le nom d automation est encore celui d une saisie de mot de passe'
        $bulle = [string]$champ[0].GetAttribute('ToolTip')
        Assert-True (-not $bulle.StartsWith('Saisie')) 'L infobulle parle encore de saisie protegee'
        Assert-True ($bulle -ceq [string]$champ[0].GetAttribute('AutomationProperties.HelpText')) 'Infobulle et aide d automation divergent'
        $texteXaml = Get-MainXaml
        Assert-True (-not $texteXaml.Contains('Pwd last set')) 'Le libelle anglais est reste dans le XAML'
        Assert-True ($texteXaml.Contains('Content="Mot de passe changé le"')) 'Le libelle en francais est absent du XAML'
        # Le fichier d aide est indexe par x:Name : Titre = nom d automation, Text = infobulle.
        # Windows PowerShell 5.1 emet un tableau JSON comme UN seul objet du pipeline : @(... |
        # ConvertFrom-Json) emballe toute la liste dans un element, et les controles qui suivent
        # croient lire une seule entree. Assigner d'abord, enumerer ensuite, comme dans
        # Test-DomeniaStartupLogin.ps1.
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        Assert-True (@($aide | Where-Object { $_.Name -ne 'TxtUserPwdLastSet' }).Count -gt 0) 'La lecture du fichier d aide rend un seul objet : le tableau JSON est niche'
        $entree = @($aide | Where-Object { $_.Name -eq 'TxtUserPwdLastSet' })
        Assert-True ($entree.Count -eq 1) ('Entree d aide TxtUserPwdLastSet : ' + $entree.Count + ' occurrence(s)')
        Assert-True (([string]$entree[0].Title) -ceq $nom) ('Titre de l aide different du nom d automation : ' + [string]$entree[0].Title)
        Assert-True (([string]$entree[0].Text) -ceq $bulle) 'Texte de l aide different de l infobulle'
        Assert-True (([string]$entree[0].Source) -cne 'specific-sensitive') 'La date est encore classee donnee sensible'
        Assert-True (([string]$entree[0].Text).Contains('pwdLastSet')) 'L aide ne dit pas d ou vient la date'
        # « Jamais » vient de Convert-FileTimeLabel sur une valeur a zero : c est le cas que l aide
        # doit expliquer, sinon l operateur croit a un compte qui n a jamais eu de mot de passe.
        Assert-True (([string](Convert-FileTimeLabel 0)) -ceq 'Jamais') ('Valeur a zero rendue : ' + [string](Convert-FileTimeLabel 0))
    }
    Test-Case 'CO-22 : les options du compte se lisent, les identifiants se nomment' {
        # 66048 n'est pas une information, c'est un masque. Le decodage doit nommer les options que
        # l'operateur vient chercher : expiration du mot de passe, carte a puce, compte desactive.
        Assert-True (([string](Get-UacFlagsLabel 66048)) -ceq 'Compte normal · Mot de passe jamais expiré') ('66048 : ' + [string](Get-UacFlagsLabel 66048))
        Assert-True (([string](Get-UacFlagsLabel 512)) -ceq 'Compte normal') ('512 : ' + [string](Get-UacFlagsLabel 512))
        Assert-True (([string](Get-UacFlagsLabel 514)) -ceq 'Compte désactivé · Compte normal') ('514 : ' + [string](Get-UacFlagsLabel 514))
        Assert-True (([string](Get-UacFlagsLabel 262144)) -ceq 'Carte à puce obligatoire') ('262144 : ' + [string](Get-UacFlagsLabel 262144))
        # Un bit que la table ne connait pas doit rester visible : le rendre muet ferait paraitre
        # ordinaire un compte qui ne l'est pas.
        Assert-True (([string](Get-UacFlagsLabel 1024)) -ceq 'Bits non reconnus 0x400') ('1024 : ' + [string](Get-UacFlagsLabel 1024))
        Assert-True (([string](Get-UacFlagsLabel 0)) -ceq 'Aucune option marquée') ('0 : ' + [string](Get-UacFlagsLabel 0))
        Assert-True (([string](Get-UacFlagsLabel $null)) -ceq 'Options non déterminées') ('null : ' + [string](Get-UacFlagsLabel $null))
        Assert-True (([string](Get-UacFlagsLabel 'abc')) -ceq 'Options non déterminées') ('abc : ' + [string](Get-UacFlagsLabel 'abc'))
        # Le masque brut ne doit plus atteindre l'ecran, ni pour l'utilisateur ni pour l'ordinateur.
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        Assert-True (-not $texteCore.Contains('["TxtUserUac"].Text = [string]$uac')) 'TxtUserUac recoit encore le masque brut'
        Assert-True (-not $texteCore.Contains('["TxtCompUac"].Text = [string]$uac')) 'TxtCompUac recoit encore le masque brut'
        # Les deux champs d'identite etaient libelles en anglais alors que tout le reste de la fiche
        # est en francais, infobulle et nom d'automation compris.
        $xaml = Get-MainXaml
        Assert-True ($xaml.Contains('<Label Grid.Row="3" Grid.Column="0" Content="Identifiant"/>')) 'Le champ sAMAccountName est encore libelle en anglais'
        Assert-True ($xaml.Contains('<Label Grid.Row="3" Grid.Column="2" Content="Nom de connexion"/>')) 'Le champ userPrincipalName est encore libelle en anglais'
        Assert-True (-not $xaml.Contains('Content="Login"')) 'Un libelle « Login » est reste dans le XAML'
        Assert-True (-not $xaml.Contains('Content="UPN"')) 'Un libelle « UPN » est reste dans le XAML'
    }
    Test-Case 'CO-01 : deux controles interactifs ne se partagent pas la meme cellule' {
        # Un controle place dans une cellule deja occupee en recouvre un autre a l ecran. « Etat » et
        # « Derniere connexion » etaient tous deux en ligne 8, colonne 3 : le second effacait le
        # premier. La regle est celle de l audit : un controle masque (Collapsed ou Hidden) ne compte
        # pas, un libelle non plus, et une etendue (RowSpan / ColumnSpan) occupe toutes ses cellules.
        $xaml = [xml](Get-MainXaml)
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $interactifs = @('TextBox','ComboBox','CheckBox','Button','PasswordBox','ListBox','DatePicker')
        $cellules = @()
        foreach ($grille in @($xaml.SelectNodes('//*[local-name()="Grid"]'))) {
            $occu = @{}
            foreach ($enfant in @($grille.ChildNodes)) {
                if ($interactifs -notcontains [string]$enfant.LocalName) { continue }
                if (@('Collapsed','Hidden') -contains $enfant.GetAttribute('Visibility')) { continue }
                $l = $enfant.GetAttribute('Grid.Row'); $c = $enfant.GetAttribute('Grid.Column')
                if (-not $l -and -not $c) { continue }
                if (-not ($l -match '^[0-9]+$')) { $l = '0' }
                if (-not ($c -match '^[0-9]+$')) { $c = '0' }
                $lp = $enfant.GetAttribute('Grid.RowSpan'); $cp = $enfant.GetAttribute('Grid.ColumnSpan')
                if (-not ($lp -match '^[0-9]+$')) { $lp = '1' }
                if (-not ($cp -match '^[0-9]+$')) { $cp = '1' }
                $nom = [string]$enfant.LocalName + '/' + $enfant.GetAttribute('Name',$XNS)
                for ($i = [int]$l; $i -lt ([int]$l + [int]$lp); $i++) {
                    for ($j = [int]$c; $j -lt ([int]$c + [int]$cp); $j++) {
                        $cle = [string]$i + ',' + [string]$j
                        if ($occu.ContainsKey($cle)) { $cellules += ($cle + ' : ' + $occu[$cle] + ' + ' + $nom) }
                        else { $occu[$cle] = $nom }
                    }
                }
            }
        }
        Assert-True (@($cellules).Count -eq 0) ('Controles superposes : ' + ((@($cellules) | Select-Object -First 4) -join ' | '))
    }
    # ------------------------------------------------------------ SE-10 : options a haut risque repliees
    Test-Case 'SE-10 : les options a haut risque sont repliees et reservees a Expert' {
        # Les six options qui affaiblissent le compte etaient alignees avec les trois autres, a portee de clic
        # en profil Essentiel. Elles restent dans le meme bloc, repliees dans un Expander que le profil Expert
        # est seul a deplier. L etat du compte reste lisible en Essentiel : Get-UacFlagsLabel les nomme toutes.
        $xaml = [xml](Get-MainXaml)
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $expander = @($xaml.SelectNodes('//*[local-name()="Expander"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'ExpAccountSecurityOptions' })
        Assert-True ($expander.Count -eq 1) ('Expander des options avancees : ' + $expander.Count + ' occurrence(s)')
        Assert-True (([string]$expander[0].GetAttribute('IsExpanded')) -ceq 'False') "Le bloc des options avancees s'ouvre deploye"
        Assert-True (([string]$expander[0].GetAttribute('Visibility')) -ceq 'Collapsed') "Le bloc des options avancees est visible avant le profil Expert"
        $avancees = @('ChkPwdNotRequired','ChkReversiblePwd','ChkNoPreAuth','ChkUseDesOnly','ChkTrustedForDelegation','ChkTrustedToAuthDelegation')
        $courantes = @('ChkPwdNeverExpires','ChkSmartcardRequired','ChkAccountNotDelegated')
        $dedans = @($expander[0].SelectNodes('.//*[local-name()="CheckBox"]') | ForEach-Object { [string]$_.GetAttribute('Name',$XNS) })
        foreach ($nom in $avancees) {
            Assert-True (@($dedans | Where-Object { $_ -ceq $nom }).Count -eq 1) ($nom + ' n est pas repliee dans le bloc avance')
        }
        foreach ($nom in $courantes) {
            Assert-True (@($dedans | Where-Object { $_ -ceq $nom }).Count -eq 0) ($nom + ' est repliee alors qu elle doit rester visible')
        }
        # Le bouton qui enregistre ne doit jamais disparaitre avec le bloc qu il applique.
        Assert-True (@($expander[0].SelectNodes('.//*[local-name()="Button"]')).Count -eq 0) 'Le bouton Appliquer est replie avec les options avancees'
        # Les six cases repliees sont exactement celles qu'Apply-UserAccountOptions classe a haut risque :
        # le bloc masque ne cache rien qui ne soit deja confirme en page avant ecriture.
        $fonc = @($nodes | Where-Object { $_.Name -eq 'Apply-UserAccountOptions' })
        Assert-True ($fonc.Count -eq 1) 'Apply-UserAccountOptions introuvable dans le coeur'
        $corps = [string]$fonc[0].Extent.Text
        foreach ($cle in @('PasswordNotRequired','AllowReversiblePasswordEncryption','DoesNotRequirePreAuth','UseDESKeyOnly','TrustedForDelegation','TrustedToAuthForDelegation')) {
            Assert-True ($corps.Contains('"' + $cle + '"')) ('Le garde-fou a haut risque ne nomme plus ' + $cle)
        }
        # Un compte garde ces bits qu on les voie ou non : la table de decodage doit continuer a les nommer.
        foreach ($masque in @(@{V=32;L='Mot de passe non requis'},@{V=128;L='Mot de passe stocké en clair'},@{V=4194304;L='Pre-authentication Kerberos facultative'},@{V=2097152;L='Chiffrement DES uniquement'},@{V=524288;L='Authentification déléguée'},@{V=16777216;L='Authentification déléguée vers un service'})) {
            Assert-True (([string](Get-UacFlagsLabel $masque.V)).Contains($masque.L)) ([string]$masque.V + ' : ' + [string](Get-UacFlagsLabel $masque.V))
        }
        # Avertissement rouge dans le bloc replie, avec la ressource rouge du theme.
        $avert = @($expander[0].SelectNodes('.//*[local-name()="TextBlock"]'))
        Assert-True ($avert.Count -eq 1) ('Avertissement du bloc avance : ' + $avert.Count + ' occurrence(s)')
        Assert-True (([string]$avert[0].GetAttribute('Foreground')) -ceq '{DynamicResource DangerColor}') "L'avertissement du bloc avance n'est pas rouge"
        Assert-True ((Get-MainXaml).Contains('x:Key="DangerColor"')) 'La ressource DangerColor a disparu du theme'
        # Le fichier d aide est indexe par x:Name : Titre = nom d automation, Text = infobulle, Kind = element.
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        foreach ($noeud in @($expander[0],$avert[0])) {
            $nom = [string]$noeud.GetAttribute('Name',$XNS)
            $entree = @($aide | Where-Object { $_.Name -eq $nom })
            Assert-True ($entree.Count -eq 1) ('Entree d aide ' + $nom + ' : ' + $entree.Count + ' occurrence(s)')
            Assert-True (([string]$entree[0].Title) -ceq [string]$noeud.GetAttribute('AutomationProperties.Name')) ('Titre de l aide ' + $nom + ' different du nom d automation')
            Assert-True (([string]$entree[0].Text) -ceq [string]$noeud.GetAttribute('ToolTip')) ('Texte de l aide ' + $nom + ' different de l infobulle')
            Assert-True (([string]$entree[0].Kind) -ceq [string]$noeud.LocalName) ('Nature de l aide ' + $nom + ' differente de l element XAML')
            Assert-True (([string]$noeud.GetAttribute('AutomationProperties.HelpText')) -ceq [string]$noeud.GetAttribute('ToolTip')) ("L aide d automation ne reprend pas l infobulle pour " + $nom)
        }
        # Les deux nouveaux noms sont declares en Default : la politique ne force pas leur visibilite.
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        foreach ($nom in @('ExpAccountSecurityOptions','LblAccountSecurityWarning')) {
            Assert-True ($texteCore.Contains('"' + $nom + '" = "Default"')) ($nom + ' n est pas declare dans la politique des controles')
        }
        # Le depliage se decide par le profil, pas par l operateur.
        $texteModule = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.UI.ps1') -Raw -Encoding UTF8
        Assert-True ($texteModule.Contains('ExpAccountSecurityOptions=$expert')) "Le bloc avance ne depend pas du profil Expert dans la regle d'affichage"
    }

    # ------------------------------------------------------------ UX-27 : la fiche s'ouvre sur ce qui se lit
    Test-Case 'UX-27 : la fiche souvre sur la vue qui se lit et non sur le resume technique' {
        # Le Resume etait le seul point de chute, quel que soit l objet : un utilisateur y ouvrait Type, Classe,
        # GUID et DN avant de montrer son compte. Il reste la vue des objets que l application ne sait pas nommer.
        foreach ($attendu in @(@('Utilisateur','WsObject','DetailTabs','TabUser'),
                               @('Machine','WsComputer','ComputerTabs','TabComputerDashboard'),
                               @('Groupe','WsObject','DetailTabs','TabGroup'),
                               @('OU','WsObject','DetailTabs','TabContainer'),
                               @('Conteneur','WsObject','DetailTabs','TabContainer'),
                               @('','WsObject','DetailTabs','TabGeneric'),
                               @('Inconnu','WsObject','DetailTabs','TabGeneric'))) {
            $vue = Get-DomeniaLandingView -Type $attendu[0]
            Assert-True (([string]$vue.Workspace) -ceq $attendu[1]) ('Type [' + $attendu[0] + '] : espace ' + [string]$vue.Workspace + ', attendu ' + $attendu[1])
            Assert-True (([string]$vue.Inner) -ceq $attendu[2]) ('Type [' + $attendu[0] + '] : groupes d onglets ' + [string]$vue.Inner + ', attendu ' + $attendu[2])
            Assert-True (([string]$vue.Tab) -ceq $attendu[3]) ('Type [' + $attendu[0] + '] : onglet ' + [string]$vue.Tab + ', attendu ' + $attendu[3])
        }
        # La destination doit exister telle quelle dans la fenetre : un onglet qui n est pas enfant du groupe
        # demande ne se selectionne pas, et Select-DomeniaWorkspace passe alors sans rien signaler.
        $xaml = [xml](Get-MainXaml)
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        foreach ($destination in @(@('WsObject','DetailTabs','TabUser'),@('WsComputer','ComputerTabs','TabComputerDashboard'),
                                   @('WsObject','DetailTabs','TabGroup'),@('WsObject','DetailTabs','TabContainer'),
                                   @('WsObject','DetailTabs','TabGeneric'))) {
            $espace = @($xaml.SelectNodes('//*[local-name()="TabItem"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $destination[0] })
            Assert-True ($espace.Count -eq 1) ('Espace ' + $destination[0] + ' : ' + $espace.Count + ' occurrence(s)')
            $interne = @($xaml.SelectNodes('//*[local-name()="TabControl"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $destination[1] })
            Assert-True ($interne.Count -eq 1) ('Groupes d onglets ' + $destination[1] + ' : ' + $interne.Count + ' occurrence(s)')
            $enfant = @($interne[0].SelectNodes('.//*[local-name()="TabItem"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $destination[2] })
            Assert-True ($enfant.Count -eq 1) ('Onglet ' + $destination[2] + ' enfant de ' + $destination[1] + ' : ' + $enfant.Count + ' occurrence(s)')
        }
        # Les deux points d entree passent par le helper : sinon l un des deux ouvrirait encore le Resume.
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        Assert-True ($texteCore.Contains('$landing = Get-DomeniaLandingView -Type $Type')) 'Set-VisibleTabsForType choisit encore sa vue en dur'
        Assert-True ($texteCore.Contains('-Workspace $landing.Workspace -Inner $landing.Inner -Tab $landing.Tab')) 'Select-DomeniaWorkspace ne suit pas la destination du helper'
        Assert-True ($texteCore.Contains('-Type ([string]$context.Type)')) 'L ouverture immediate choisit encore sa vue en dur'
        # Classe et GUID ne regardent que l Expert : les quatre elements sont nommes et la regle existe.
        foreach ($nom in @('LblObjClass','TxtObjClass','LblObjGuid','TxtObjGuid')) {
            $noeud = @($xaml.SelectNodes('//*[local-name()="Label" or local-name()="TextBox"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $nom })
            Assert-True ($noeud.Count -eq 1) ($nom + ' : ' + $noeud.Count + ' occurrence(s)')
        }
        $texteModule = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.UI.ps1') -Raw -Encoding UTF8
        Assert-True ($texteModule.Contains('LblObjClass=$expert;TxtObjClass=$expert;LblObjGuid=$expert;TxtObjGuid=$expert')) 'Classe et GUID ne dependent pas du profil Expert'
        # Le bouton rouge a quitte la rangee : la suppression se choisit dans « Plus… », et n est plus rouge.
        $texte = Get-MainXaml
        Assert-True (-not $texte.Contains('x:Name="BtnDeleteObject"')) 'Le bouton Supprimer est reste dans la rangee des boutons de lecture'
        $bouton = @($xaml.SelectNodes('//*[local-name()="Button"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'BtnObjectMore' })
        Assert-True ($bouton.Count -eq 1) ('BtnObjectMore : ' + $bouton.Count + ' occurrence(s)')
        Assert-True (-not ([string]$bouton[0].GetAttribute('Style')).Contains('DangerButton')) 'Le bouton d actions est encore un bouton rouge'
        # La suppression garde ses deux confirmations, dont la saisie du nom de l objet.
        $fonc = @($nodes | Where-Object { $_.Name -eq 'Delete-SelectedObject' })
        Assert-True ($fonc.Count -eq 1) 'Delete-SelectedObject introuvable dans le coeur'
        $corps = [string]$fonc[0].Extent.Text
        Assert-True ($corps.Contains('-TypedConfirmation $expected')) 'La saisie du nom de l objet a disparu de la suppression'
        Assert-True ($corps.Contains("-TypedConfirmation 'SUPPRIMER'")) 'La saisie SUPPRIMER a disparu de la suppression'
        # Le menu se construit comme les autres menus de la fiche, et la carte des capacites suit le nouveau nom.
        $apost = [string][char]0x02BC
        Assert-True ($texteCore.Contains('-Header "Supprimer l' + $apost + 'objet"')) "L entree du menu Plus ne nomme pas la suppression"
        Assert-True ($texteCore.Contains('Delete = @("BtnObjectMore")')) 'La capacite Delete ne pilote plus l acces a la suppression'
        Assert-True ($texteCore.Contains('-DisableControls @("BtnObjectMore")')) 'La suppression en cours ne grise plus le bouton d actions'
        Assert-True ($texteCore.Contains('"BtnObjectMore" = "Default"')) 'Le bouton d actions a quitte la politique des controles'
        # Le fichier d aide suit le nom du bouton : Titre = nom d automation, Text = infobulle, Kind = element.
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        $entree = @($aide | Where-Object { $_.Name -eq 'BtnObjectMore' })
        Assert-True ($entree.Count -eq 1) ('Entree d aide BtnObjectMore : ' + $entree.Count + ' occurrence(s)')
        Assert-True (@($aide | Where-Object { $_.Name -eq 'BtnDeleteObject' }).Count -eq 0) "L aide connait encore le bouton supprime"
        Assert-True (([string]$entree[0].Title) -ceq [string]$bouton[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide different du nom d automation'
        Assert-True (([string]$entree[0].Text) -ceq [string]$bouton[0].GetAttribute('ToolTip')) 'Texte de l aide different de l infobulle'
        Assert-True (([string]$entree[0].Kind) -ceq 'Button') 'Nature de l aide BtnObjectMore differente de l element XAML'
    }

    # ------------------------------------------------------------ UX-05 : deplacer un compte
    Test-Case 'UX-05 : la destination du deplacement se choisit dans le selecteur d OU' {
        # Le compte etait le seul objet deplace par un champ ou l on tape le chemin complet de l OU,
        # alors que le poste a deja un selecteur. Le champ disparait : une destination tapee n est pas
        # une destination verifiee, et le selecteur commun cherche, montre l OU actuelle et confirme.
        $texte = Get-MainXaml
        $xaml = [xml]$texte
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        Assert-True (-not $texte.Contains('TxtUserMoveTarget')) 'Le champ libre du chemin complet est reste a l ecran'
        $bouton = @($xaml.SelectNodes('//*[local-name()="Button"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'BtnUserMove' })
        Assert-True ($bouton.Count -eq 1) ('BtnUserMove : ' + $bouton.Count + ' occurrence(s)')
        Assert-True (([string]$bouton[0].GetAttribute('Content')) -ceq 'Choisir l' + [string][char]0x02BC + 'OU de destination…') ('Contenu du bouton : ' + [string]$bouton[0].GetAttribute('Content'))
        Assert-True (-not ([string]$bouton[0].GetAttribute('Style')).Contains('DangerButton')) 'Le bouton de deplacement est un bouton rouge'
        Assert-True (([string]$bouton[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$bouton[0].GetAttribute('ToolTip')) 'L aide d automation ne reprend pas l infobulle'
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        Assert-True (-not $texteCore.Contains('"TxtUserMoveTarget" = "Default"')) 'La politique des controles connait encore le champ supprime'
        Assert-True ($texteCore.Contains('"BtnUserMove" = "Default"')) 'Le bouton a quitte la politique des controles'
        # Le clic ouvre le selecteur, et le selecteur est celui du poste : une seule facon de choisir une OU.
        Assert-True ($texteCore.Contains('Add_Click({ Move-DomeniaSelectedUserWithOuPicker })')) 'Le bouton ne passe pas par le selecteur'
        Assert-True (-not $texteCore.Contains('Move-SelectedObject $script:Ctrl["TxtUserMoveTarget"]')) 'Le bouton relit encore un champ texte'
        $fonc = @($nodes | Where-Object { $_.Name -eq 'Move-DomeniaSelectedUserWithOuPicker' })
        Assert-True ($fonc.Count -eq 1) 'Move-DomeniaSelectedUserWithOuPicker introuvable dans le coeur'
        $corps = [string]$fonc[0].Extent.Text
        Assert-True ($corps.Contains('Show-DomeniaOuPicker -ObjectName $name -CurrentParentDn $currentParent -ObjectLabel')) 'Le selecteur commun n est pas employe'
        Assert-True ($corps.Contains('Move-SelectedObject -TargetDn $targetDn')) 'Le deplacement ne passe plus par l ecriture unique'
        Assert-True ($corps.Contains('Assert-WriteAllowed')) 'Le selecteur s ouvre sans verifier que l ecriture est permise'
        $selecteur = @($nodes | Where-Object { $_.Name -eq 'Show-DomeniaOuPicker' })
        Assert-True ($selecteur.Count -eq 1) 'Show-DomeniaOuPicker introuvable dans le coeur'
        $corpsSelecteur = [string]$selecteur[0].Extent.Text
        Assert-True ($corpsSelecteur.Contains("`$ObjectLabel='Poste'")) 'Le poste a perdu son etiquette par defaut'
        Assert-True ($corpsSelecteur.Contains('-Kind OU')) 'Le selecteur n est plus celui des OU'
        # L ecriture garde ses garde-fous : grisonnement du bouton et capacite.
        Assert-True ($texteCore.Contains('-DisableControls @("BtnUserMove")')) 'Le bouton ne se grise plus pendant le deplacement'
        Assert-True ($texteCore.Contains('Move = @("BtnUserMove","BtnCompRename")')) 'La capacite Move ne pilote plus le bouton'
        # Le fichier d aide suit : plus d entree pour le champ, et le bouton reste fidele a son infobulle.
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        Assert-True (@($aide | Where-Object { $_.Name -eq 'TxtUserMoveTarget' }).Count -eq 0) 'L aide connait encore le champ supprime'
        $entree = @($aide | Where-Object { $_.Name -eq 'BtnUserMove' })
        Assert-True ($entree.Count -eq 1) ('Entree d aide BtnUserMove : ' + $entree.Count + ' occurrence(s)')
        Assert-True (([string]$entree[0].Title) -ceq [string]$bouton[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide different du nom d automation'
        Assert-True (([string]$entree[0].Text) -ceq [string]$bouton[0].GetAttribute('ToolTip')) 'Texte de l aide different de l infobulle'
        Assert-True (([string]$entree[0].Kind) -ceq 'Button') 'Nature de l aide BtnUserMove differente de l element XAML'
    }

    # ------------------------------------------------------------ UX-14 : le responsable
    Test-Case 'UX-14 : le responsable se lit en nom et se choisit, il ne se tape plus' {
        # Les deux champs Responsable etaient des zones libres remplies du DN brut et relues telles
        # quelles a l enregistrement : une phrase saisie partait au DC comme DN. La fiche montre un
        # nom, le DN reste dans la variable script, et le choix passe par le selecteur commun.
        $texte = Get-MainXaml
        $xaml = [xml]$texte
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        foreach ($couple in @(@('TxtUserManager','BtnUserManagerPick','BtnUserManagerOpen','BtnUserManagerClear'),
                              @('TxtCompManagedBy','BtnCompManagedByPick','BtnCompManagedByOpen','BtnCompManagedByClear'))) {
            $nomChamp = $couple[0]
            $champs = @($xaml.SelectNodes('//*[local-name()="TextBox"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $nomChamp })
            Assert-True ($champs.Count -eq 1) ($nomChamp + ' : ' + $champs.Count + ' occurrence(s)')
            Assert-True (([string]$champs[0].GetAttribute('IsReadOnly')) -ceq 'True') ($nomChamp + ' reste modifiable au clavier')
            Assert-True (([string]$champs[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$champs[0].GetAttribute('ToolTip')) ($nomChamp + ' : l aide d automation ne reprend pas l infobulle')
            Assert-True (-not ([string]$champs[0].GetAttribute('ToolTip')).Contains('Chemin complet')) ($nomChamp + ' annonce encore un chemin a recopier')
            Assert-True (-not $texteCore.Contains('([string]$script:Ctrl["' + $nomChamp + '"].Text)')) ($nomChamp + ' est encore relu a l ecriture')
            foreach ($bouton in @($couple[1], $couple[2], $couple[3])) {
                $btns = @($xaml.SelectNodes('//*[local-name()="Button"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq $bouton })
                Assert-True ($btns.Count -eq 1) ($bouton + ' : ' + $btns.Count + ' occurrence(s)')
                Assert-True (-not ([string]$btns[0].GetAttribute('Style')).Contains('DangerButton')) ($bouton + ' est un bouton rouge')
                Assert-True (([string]$btns[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$btns[0].GetAttribute('ToolTip')) ($bouton + ' : l aide d automation ne reprend pas l infobulle')
                Assert-True ($texteCore.Contains($bouton + '"].Add_Click({')) ($bouton + ' n est pas cable')
                $entree = @($aide | Where-Object { $_.Name -eq $bouton })
                Assert-True ($entree.Count -eq 1) ('Entree d aide ' + $bouton + ' : ' + $entree.Count + ' occurrence(s)')
                Assert-True (([string]$entree[0].Title) -ceq [string]$btns[0].GetAttribute('AutomationProperties.Name')) ('Titre de l aide ' + $bouton + ' different du nom d automation')
                Assert-True (([string]$entree[0].Text) -ceq [string]$btns[0].GetAttribute('ToolTip')) ('Texte de l aide ' + $bouton + ' different de l infobulle')
                Assert-True (([string]$entree[0].Kind) -ceq 'Button') ('Nature de l aide ' + $bouton + ' differente de l element XAML')
            }
            $entreeChamp = @($aide | Where-Object { $_.Name -eq $nomChamp })
            Assert-True ($entreeChamp.Count -eq 1) ('Entree d aide ' + $nomChamp + ' : ' + $entreeChamp.Count + ' occurrence(s)')
            Assert-True (([string]$entreeChamp[0].Text) -ceq [string]$champs[0].GetAttribute('ToolTip')) ('Texte de l aide ' + $nomChamp + ' different de l infobulle')
            Assert-True (([string]$entreeChamp[0].Kind) -ceq 'TextBox') ('Nature de l aide ' + $nomChamp + ' differente de l element XAML')
        }
        # Le nom affiche vient de l annuaire, le DN reste interne : c est la tout l ecart avec avant.
        Assert-True ($texteCore.Contains('Set-DomeniaManagerField -Target ' + [char]39 + 'Utilisateur' + [char]39 + ' -Dn ([string](Get-DeProp $Entry "manager" ""))')) 'La fiche du compte n affiche plus le nom du responsable'
        Assert-True ($texteCore.Contains('Set-DomeniaManagerField -Target ' + [char]39 + 'Machine' + [char]39 + ' -Dn ([string](Get-DeProp $Entry "managedBy" ""))')) 'La fiche du poste n affiche plus le nom du responsable'
        Assert-True ($texteCore.Contains('New-DomeniaAttributeChange "manager" ([string]$script:UserManagerDn)')) 'Le manager ne se lit plus dans le DN interne'
        Assert-True ($texteCore.Contains('New-DomeniaAttributeChange "managedBy" ([string]$script:CompManagedByDn)')) 'Le managedBy ne se lit plus dans le DN interne'
        $fonc = @($nodes | Where-Object { $_.Name -eq 'Set-DomeniaManagerField' })
        Assert-True ($fonc.Count -eq 1) 'Set-DomeniaManagerField introuvable dans le coeur'
        $corps = [string]$fonc[0].Extent.Text
        Assert-True ($corps.Contains('Get-DomeniaCnFromDn $dn')) 'Le nom lisible n est pas calcule depuis le DN'
        Assert-True ($corps.Contains('if (-not $nom) { $nom = $dn }')) 'Un DN sans nom lisible laisse la fiche vide'
        Assert-True ($corps.Contains("$script:UserManagerDn = `$dn")) 'Le DN du compte ne reste pas dans la variable script'
        Assert-True ($corps.Contains("$script:CompManagedByDn = `$dn")) 'Le DN du poste ne reste pas dans la variable script'
        $choix = @($nodes | Where-Object { $_.Name -eq 'Show-DomeniaManagerPicker' })
        Assert-True ($choix.Count -eq 1) 'Show-DomeniaManagerPicker introuvable dans le coeur'
        $corpsChoix = [string]$choix[0].Extent.Text
        Assert-True ($corpsChoix.Contains('Show-DomeniaObjectPicker -Kind Utilisateur')) 'Le responsable ne passe pas par le selecteur commun'
        Assert-True ($corpsChoix.Contains('Assert-WriteAllowed')) 'Le selecteur s ouvre sans verifier que l ecriture est permise'
        Assert-True (-not $corpsChoix.Contains('Move-SelectedObject')) 'Le choix du responsable ecrit autre chose que la fiche'
        $retirer = @($nodes | Where-Object { $_.Name -eq 'Clear-DomeniaManagerSelection' })
        Assert-True ($retirer.Count -eq 1) 'Clear-DomeniaManagerSelection introuvable dans le coeur'
        Assert-True (([string]$retirer[0].Extent.Text).Contains('Set-DomeniaManagerField -Target $Target -Dn ' + [char]39 + [char]39)) 'Retirer le responsable n est plus possible'
        $ouvrir = @($nodes | Where-Object { $_.Name -eq 'Open-DomeniaManagerObject' })
        Assert-True ($ouvrir.Count -eq 1) 'Open-DomeniaManagerObject introuvable dans le coeur'
        Assert-True (([string]$ouvrir[0].Extent.Text).Contains("Open-AdObject -Dn `$dn -Type 'Utilisateur'")) 'Ouvrir ne va pas chercher la fiche de l objet'
        $vider = @($nodes | Where-Object { $_.Name -eq 'Clear-ObjectDetails' })
        Assert-True ($vider.Count -eq 1) 'Clear-ObjectDetails introuvable dans le coeur'
        $corpsVider = [string]$vider[0].Extent.Text
        Assert-True ($corpsVider.Contains("Set-DomeniaManagerField -Target 'Utilisateur' -Dn ''")) 'Le DN survit a un changement d objet'
        Assert-True ($corpsVider.Contains("Set-DomeniaManagerField -Target 'Machine' -Dn ''")) 'Le DN du poste survit a un changement d objet'
    }

    # ------------------------------------------------------------ UX-36 : mot de passe temporaire
    Test-Case 'UX-36 : le mot de passe remis par le support se genere et se change' {
        # La case « Changement obligatoire » arrivait decochee et rien ne fabriquait un mot de passe :
        # le support dictait une valeur qui restait valable indefiniment. Elle se coche des la fiche
        # ouverte, et « Generer » place une valeur forte dans les champs existants, sans ecrire.
        $texte = Get-MainXaml
        $xaml = [xml]$texte
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        $cases = @($xaml.SelectNodes('//*[local-name()="CheckBox"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'ChkMustChangeAtLogon' })
        Assert-True ($cases.Count -eq 1) ('ChkMustChangeAtLogon : ' + $cases.Count + ' occurrence(s)')
        Assert-True (([string]$cases[0].GetAttribute('IsChecked')) -ceq 'True') 'Changement obligatoire arrive decoche'
        Assert-True (([string]$cases[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$cases[0].GetAttribute('ToolTip')) 'ChkMustChangeAtLogon : l aide d automation ne reprend pas l infobulle'
        $btns = @($xaml.SelectNodes('//*[local-name()="Button"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'BtnUserGenPassword' })
        Assert-True ($btns.Count -eq 1) ('BtnUserGenPassword : ' + $btns.Count + ' occurrence(s)')
        Assert-True (-not ([string]$btns[0].GetAttribute('Style')).Contains('DangerButton')) 'Generer un mot de passe est un bouton rouge'
        Assert-True (([string]$btns[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$btns[0].GetAttribute('ToolTip')) 'BtnUserGenPassword : l aide d automation ne reprend pas l infobulle'
        Assert-True ($texteCore.Contains('BtnUserGenPassword"].Add_Click({')) 'Generer n est pas cable'
        Assert-True ($texteCore.Contains('Password = @("BtnUserResetPwd","BtnUserGenPassword")')) 'Generer reste cliquable quand la capacite Mot de passe est refusee'
        $entree = @($aide | Where-Object { $_.Name -eq 'BtnUserGenPassword' })
        Assert-True ($entree.Count -eq 1) ('Entree d aide BtnUserGenPassword : ' + $entree.Count + ' occurrence(s)')
        Assert-True (([string]$entree[0].Title) -ceq [string]$btns[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide BtnUserGenPassword different du nom d automation'
        Assert-True (([string]$entree[0].Text) -ceq [string]$btns[0].GetAttribute('ToolTip')) 'Texte de l aide BtnUserGenPassword different de l infobulle'
        Assert-True (([string]$entree[0].Kind) -ceq 'Button') 'Nature de l aide BtnUserGenPassword differente de l element XAML'
        $entreeCase = @($aide | Where-Object { $_.Name -eq 'ChkMustChangeAtLogon' })
        Assert-True ($entreeCase.Count -eq 1) ('Entree d aide ChkMustChangeAtLogon : ' + $entreeCase.Count + ' occurrence(s)')
        Assert-True (([string]$entreeCase[0].Text) -ceq [string]$cases[0].GetAttribute('ToolTip')) 'Texte de l aide ChkMustChangeAtLogon different de l infobulle'
        # Le generateur : quatre octets forts, quatre classes, aucun caractere ambigu, et un plancher.
        $gen = @($nodes | Where-Object { $_.Name -eq 'New-DomeniaTemporaryPassword' })
        Assert-True ($gen.Count -eq 1) 'New-DomeniaTemporaryPassword introuvable dans le coeur'
        $corpsGen = [string]$gen[0].Extent.Text
        Assert-True ($corpsGen.Contains('[System.Security.Cryptography.RandomNumberGenerator]::Create()')) 'Le mot de passe ne se tire pas dans un generateur cryptographique'
        Assert-True ($corpsGen.Contains('ABCDEFGHJKLMNPQRSTUVWXYZ')) 'Les caracteres ambigus ne sont pas ecartes'
        Assert-True ($corpsGen.Contains('if ($Length -lt 14) { $Length = 14 }')) 'Aucun plancher de longueur'
        $tire = @($nodes | Where-Object { $_.Name -eq 'Get-DomeniaRandomBelow' })
        Assert-True ($tire.Count -eq 1) 'Get-DomeniaRandomBelow introuvable dans le coeur'
        Assert-True (([string]$tire[0].Extent.Text).Contains('$Rng.GetBytes($buffer)')) 'Le tirage n utilise pas des octets forts'
        # Generer ne doit rien ecrire : il remplit les champs, la relecture a l enregistrement fait le reste.
        $show = @($nodes | Where-Object { $_.Name -eq 'Show-DomeniaGeneratedPassword' })
        Assert-True ($show.Count -eq 1) 'Show-DomeniaGeneratedPassword introuvable dans le coeur'
        $corpsShow = [string]$show[0].Extent.Text
        Assert-True ($corpsShow.Contains('Assert-WriteAllowed')) 'Generer un mot de passe se tente en lecture seule'
        Assert-True ($corpsShow.Contains('Set-ClipboardSafe $mot')) 'Le mot de passe genere ne part pas dans le presse-papiers'
        Assert-True ($corpsShow.Contains('Start-SecretClipboardAutoClear $mot')) 'Le presse-papiers garde le mot de passe genere'
        Assert-True ($corpsShow.Contains('ChkMustChangeAtLogon"].IsChecked = $true')) 'Generer laisse le changement obligatoire decoche'
        Assert-True (-not $corpsShow.Contains('Start-DomeniaWriteTask')) 'Generer ecrit dans l annuaire'
        # Le reglage : coche par defaut, et l operateur peut decider du contraire.
        Assert-True ($texteCore.Contains('ForcePasswordChangeOnReset = $true')) 'Le reglage du changement obligatoire n a pas de defaut'
        Assert-True ($texteCore.Contains('GeneratedPasswordLength = 16')) 'La longueur generee n a pas de defaut'
        $resto = @($nodes | Where-Object { $_.Name -eq 'Restore-DomeniaUiSettings' })
        Assert-True ($resto.Count -eq 1) 'Restore-DomeniaUiSettings introuvable dans le coeur'
        Assert-True (([string]$resto[0].Extent.Text).Contains('ForcePasswordChangeOnReset')) 'Le reglage du changement obligatoire n est jamais applique'
    }

    # ------------------------------------------------------------ UX-13 : mode edition de la fiche
    Test-Case 'UX-13 : la fiche se verrouille, un crayon la modifie, la page dit ce qui est abandonne' {
        $texte = Get-MainXaml
        $xaml = [xml]$texte
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $cheminAide = Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json'
        # ConvertFrom-Json emet son tableau d'objets sans l'enumerer : @() autour du tube en
        # ferait un tableau d'un element, et les comparaisons d'aide porteraient sur ce tableau.
        $aideBrutee = Get-Content -LiteralPath $cheminAide -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        # Les controles nouveaux, un seul exemplaire chacun, et leur nom pour la suite.
        $nouveaux = @(@('BtnUserEdit','Button'), @('BtnUserCancelEdit','Button'),
                      @('BtnCompEdit','Button'), @('BtnCompCancelEdit','Button'),
                      @('LblUserEditState','TextBlock'), @('LblCompEditState','TextBlock'))
        foreach ($pair in $nouveaux) {
            $chemin = '//*[local-name()="' + $pair[1] + '"]'
            $trouves = @($xaml.SelectNodes($chemin) | Where-Object { $_.GetAttribute('Name',$XNS) -eq $pair[0] })
            Assert-True ($trouves.Count -eq 1) ($pair[0] + ' : ' + $trouves.Count + ' occurrence(s)')
        }
        $nommes = @{}
        foreach ($noeud in @($xaml.SelectNodes('//*'))) {
            $nom = [string]$noeud.GetAttribute('Name', $XNS)
            if ($nom) { $nommes[$nom] = $noeud }
        }
        # La fiche se presente fermee : Annuler et l'alerte ne paraissent qu'avec de quoi.
        foreach ($nom in @('BtnUserCancelEdit','BtnCompCancelEdit','LblUserEditState','LblCompEditState')) {
            Assert-True (([string]$nommes[$nom].GetAttribute('Visibility')) -ceq 'Collapsed') ($nom + ' parait sans modification en cours')
        }
        foreach ($nom in @('BtnUserEdit','BtnCompEdit','BtnUserCancelEdit','BtnCompCancelEdit')) {
            Assert-True (-not ([string]$nommes[$nom].GetAttribute('Style')).Contains('DangerButton')) ($nom + ' est un bouton rouge')
        }
        foreach ($nom in @('BtnUserEdit','BtnCompEdit')) {
            Assert-True (([string]$nommes[$nom].GetAttribute('Content')) -ceq 'Modifier') ($nom + ' ne dit pas Modifier')
        }
        foreach ($nom in @('BtnUserCancelEdit','BtnCompCancelEdit')) {
            Assert-True (([string]$nommes[$nom].GetAttribute('Content')) -ceq 'Annuler') ($nom + ' ne dit pas Annuler')
        }
        foreach ($nom in @('LblUserEditState','LblCompEditState')) {
            Assert-True (([string]$nommes[$nom].GetAttribute('TextWrapping')) -ceq 'Wrap') ($nom + ' tronque ce qui a ete abandonne')
            $couleur = [string]$nommes[$nom].GetAttribute('Foreground')
            Assert-True ($couleur.Contains('MutedColor')) ($nom + ' crie une information secondaire')
        }
        # Les 28 champs que les trois enregistrements de fiche ecrivent, et rien d autre.
        $attendus = @('TxtUserGivenName', 'TxtUserSurname', 'TxtUserDisplayName',
          'TxtUserMail', 'TxtUserPhone', 'TxtUserOffice',
          'TxtUserDescription', 'TxtUserTitle', 'TxtUserDepartment',
          'TxtUserCompany', 'TxtUserStreet', 'TxtUserCity',
          'TxtUserState2', 'TxtUserPostalCode', 'TxtUserCountry',
          'TxtUserHomePhone', 'TxtUserMobile', 'TxtUserFax',
          'TxtUserIpPhone', 'TxtUserWebPage', 'TxtUserEmployeeId',
          'TxtUserProfilePath', 'TxtUserScriptPath', 'TxtUserHomeDirectory',
          'TxtUserHomeDrive', 'TxtUserWorkstations', 'TxtCompDescription',
          'TxtCompLocation')
        $i0 = $texteCore.IndexOf('$script:FicheEditChamps = [ordered]@{')
        Assert-True ($i0 -ge 0) 'La carte des champs gouvernes est absente du coeur'
        $i1 = $texteCore.IndexOf("`n}", $i0)
        $bloc = $texteCore.Substring($i0, $i1 - $i0)
        $gouvernes = @([regex]::Matches($bloc, "Txt[A-Za-z0-9]+") | ForEach-Object { $_.Value } | Select-Object -Unique)
        Assert-True ($gouvernes.Count -eq 28) ('Champs gouvernes : ' + $gouvernes.Count + ' au lieu de 28')
        foreach ($nom in $attendus) {
            Assert-True ($gouvernes -contains $nom) ($nom + ' ne se saisit pas alors qu une fiche l enregistre')
        }
        foreach ($nom in $gouvernes) {
            Assert-True ($attendus -contains $nom) ($nom + ' s ouvre alors qu aucune fiche ne l enregistre')
        }
        foreach ($nom in $attendus) {
            $champ = $nommes[$nom]
            Assert-True ($null -ne $champ) ($nom + ' absent du XAML')
            Assert-True (([string]$champ.GetAttribute('IsReadOnly')) -ceq 'True') ($nom + ' s ouvre sans crayon')
        }
        Assert-True (([string]$nommes['TxtUserUpn'].GetAttribute('IsReadOnly')) -ceq 'True') 'L UPN s ouvre alors que personne ne le saisit'
        # Le crayon est cable, et la carte des ecritures l eteint comme les autres boutons.
        $clics = @('BtnUserEdit"].Add_Click({ Start-DomeniaFicheEdit -Type "Utilisateur" })',
                  'BtnUserCancelEdit"].Add_Click({ Stop-DomeniaFicheEdit -Type "Utilisateur" -Restaurer })',
                  'BtnCompEdit"].Add_Click({ Start-DomeniaFicheEdit -Type "Machine" })',
                  'BtnCompCancelEdit"].Add_Click({ Stop-DomeniaFicheEdit -Type "Machine" -Restaurer })')
        foreach ($clic in $clics) {
            Assert-True ($texteCore.Contains($clic)) ('Cable absent : ' + $clic.Substring(0, $clic.IndexOf('"')))
        }
        Assert-True ($texteCore.Contains('Register-DomeniaFicheEditWatch')) 'Aucune sonde ne surveille ce qui est modifie'
        $carte = 'Edit = @("BtnUserSave","BtnUserEdit","BtnUserSaveContact","BtnCompSave","BtnCompEdit","BtnGroupSave")'
        Assert-True ($texteCore.Contains($carte)) 'Les crayons echappent a la carte des ecritures'
        # La fiche prend sa reference en se remplissant et la perd en changeant d objet.
        $snapU = "Snapshot-DomeniaFicheEdit -Type 'Utilisateur'"
        $snapM = "Snapshot-DomeniaFicheEdit -Type 'Machine'"
        $fill = @($nodes | Where-Object { $_.Name -eq 'Fill-UserObject' })
        Assert-True ($fill.Count -eq 1) 'Fill-UserObject introuvable dans le coeur'
        Assert-True (([string]$fill[0].Extent.Text).Contains($snapU)) 'La fiche utilisateur ne prend pas de reference'
        $fillc = @($nodes | Where-Object { $_.Name -eq 'Fill-ComputerObject' })
        Assert-True ($fillc.Count -eq 1) 'Fill-ComputerObject introuvable dans le coeur'
        Assert-True (([string]$fillc[0].Extent.Text).Contains($snapM)) 'La fiche poste ne prend pas de reference'
        $clear = @($nodes | Where-Object { $_.Name -eq 'Clear-ObjectDetails' })
        Assert-True ($clear.Count -eq 1) 'Clear-ObjectDetails introuvable dans le coeur'
        $corpsClear = [string]$clear[0].Extent.Text
        Assert-True ($corpsClear.Contains('Stop-DomeniaFicheEdit')) 'Changer d objet laisse la fiche en edition'
        Assert-True ($corpsClear.Contains('-Abandon')) 'Rien ne prevoit de dire ce qui a ete abandonne'
        # Le crayon ouvre la saisie et rien d autre : aucun chemin d ecriture ne le traverse.
        $fonctions = @('Get-DomeniaFicheEditControls','Get-DomeniaFicheDirtyControls',
                       'Set-DomeniaFicheFieldLock','Update-DomeniaFicheEditUi',
                       'Start-DomeniaFicheEdit','Stop-DomeniaFicheEdit',
                       'Snapshot-DomeniaFicheEdit','Register-DomeniaFicheEditWatch')
        foreach ($nom in $fonctions) {
            $trouvees = @($nodes | Where-Object { $_.Name -eq $nom })
            Assert-True ($trouvees.Count -eq 1) ($nom + ' introuvable dans le coeur')
        }
        $sansEcriture = @('Start-DomeniaFicheEdit','Stop-DomeniaFicheEdit',
                            'Update-DomeniaFicheEditUi','Set-DomeniaFicheFieldLock')
        $interdits = @('Start-DomeniaWriteTask','Start-DomeniaAttributeWrite',
                        'Save-UserProfile','Save-ComputerProfile','Save-DomeniaUserContact')
        foreach ($nom in $sansEcriture) {
            $corps = [string](@($nodes | Where-Object { $_.Name -eq $nom })[0].Extent.Text)
            foreach ($interdit in $interdits) {
                Assert-True (-not $corps.Contains($interdit)) ($nom + ' ecrit : ' + $interdit)
            }
        }
        $debut = [string](@($nodes | Where-Object { $_.Name -eq 'Start-DomeniaFicheEdit' })[0].Extent.Text)
        Assert-True ($debut.Contains('$script:ReadOnlyMode')) 'Le crayon ouvre la saisie en lecture seule'
        # Fiche d aide : une entree par controle, titre = nom d automation, texte = infobulle.
        foreach ($pair in $nouveaux) {
            $entrees = @($aide | Where-Object { $_.Name -eq $pair[0] })
            Assert-True ($entrees.Count -eq 1) ('Entree d aide ' + $pair[0] + ' : ' + $entrees.Count + ' occurrence(s)')
            Assert-True (([string]$entrees[0].Kind) -ceq $pair[1]) ('Nature de l aide ' + $pair[0] + ' differente de l element XAML')
            $titre = [string]$nommes[$pair[0]].GetAttribute('AutomationProperties.Name')
            Assert-True (([string]$entrees[0].Title) -ceq $titre) ('Titre de l aide ' + $pair[0] + ' different du nom d automation')
        }
        foreach ($nom in @('BtnUserEdit','BtnUserCancelEdit','BtnCompEdit','BtnCompCancelEdit')) {
            $entrees = @($aide | Where-Object { $_.Name -eq $nom })
            $attendu = [string]$nommes[$nom].GetAttribute('ToolTip')
            Assert-True (([string]$entrees[0].Text) -ceq $attendu) ('Texte de l aide ' + $nom + ' different de l infobulle')
        }
        foreach ($nom in @('LblUserEditState','LblCompEditState')) {
            $entrees = @($aide | Where-Object { $_.Name -eq $nom })
            $attendu = [string]$nommes[$nom].GetAttribute('AutomationProperties.HelpText')
            Assert-True (([string]$entrees[0].Text) -ceq $attendu) ('Texte de l aide ' + $nom + ' different de laide du controle')
        }
    }

    # ------------------------------------------------------------ Integrite : deblocage et fins de ligne
    Test-Case 'Integrite : le deblocage tolere les fins de ligne et refuse un contenu modifie' {
        # Le garde lit des octets, pas des scripts. Un clone Windows (core.autocrlf) rend le meme
        # fichier different de son empreinte : le banc ecrit une copie de laboratoire reelle et
        # verifie que cette difference passe, qu'un contenu modifie reste refuse, et que le refus
        # dit quoi, contre quoi et depuis quel build.
        $scriptDepot = Join-Path $root 'wad\Support\Debloquer-Paquet.ps1'
        Assert-True (Test-Path -LiteralPath $scriptDepot) 'Script de deblocage absent du depot'
        $utf8 = New-Object Text.UTF8Encoding($false)
        function Get-EmpreinteOctets([byte[]]$Octets) { [BitConverter]::ToString(([Security.Cryptography.SHA256]::Create()).ComputeHash($Octets)).Replace('-','') }
        $bac = Join-Path ([IO.Path]::GetTempPath()) ('domenia-deblocage-' + [guid]::NewGuid().ToString('N'))
        $racine = Join-Path $bac 'dev'
        try {
            [void][IO.Directory]::CreateDirectory((Join-Path $racine 'wad\Support'))
            # Le script se rattache a son propre dossier (il en deduit la racine du paquet) : sans cette
            # copie, l'invoquer depuis le depot aurait valide le vrai arbre de labo et rien d'autre.
            $scriptDeblocage = Join-Path $racine 'wad\Support\Debloquer-Paquet.ps1'
            Copy-Item -LiteralPath $scriptDepot -Destination $scriptDeblocage
            $corps = "#requires -Version 5.1`nWrite-Host 'paquet de test'`n"
            $lf = $utf8.GetBytes($corps)
            $crlf = $utf8.GetBytes($corps.Replace("`n", "`r`n"))
            $modifie = $utf8.GetBytes($corps.Replace('paquet de test', 'paquet modifie'))
            $cheminCore = Join-Path $racine 'wad\Domenia-Core.ps1'
            $empreinteLf = Get-EmpreinteOctets $lf
            $empreinteModifie = Get-EmpreinteOctets $modifie
            $manifeste = [ordered]@{Format=1; Version='1.0'; Build='2026.10.12-TEST-EMPREINTE'; Edition='dev'; ReleaseStatus='test'; Files=@(
                [pscustomobject]@{Path='wad/Domenia-Core.ps1'; Sha256=$empreinteLf; Bytes=$lf.Length; Runtime=$true; PreserveExisting=$false})}
            [IO.File]::WriteAllText((Join-Path $racine 'wad\package-manifest.json'), ($manifeste | ConvertTo-Json -Depth 5), $utf8)
            [IO.File]::WriteAllBytes($cheminCore, $lf)
            $refus = ''
            try { & $scriptDeblocage -WhatIf | Out-Null } catch { $refus = $_.Exception.Message }
            Assert-True ($refus -eq '') ('Copie conforme refusee : ' + $refus)
            [IO.File]::WriteAllBytes($cheminCore, $crlf)
            $refus = ''
            try { & $scriptDeblocage -WhatIf | Out-Null } catch { $refus = $_.Exception.Message }
            Assert-True ($refus -eq '') ('Difference de fins de ligne refusee : ' + $refus)
            [IO.File]::WriteAllBytes($cheminCore, $modifie)
            $refus = ''
            try { & $scriptDeblocage -WhatIf | Out-Null } catch { $refus = $_.Exception.Message }
            $lu = Get-EmpreinteOctets ([IO.File]::ReadAllBytes($cheminCore))
            Assert-True ($refus -ne '') ('Contenu modifie : le deblocage ne refuse pas (lu=' + $lu + ' attendu=' + $empreinteLf + ' octets=' + (Get-Item -LiteralPath $cheminCore).Length + ')')
            Assert-True ($refus -match 'wad/Domenia-Core\.ps1') 'Le fichier en ecart n est pas nomme'
            Assert-True ($refus -match [regex]::Escape($empreinteLf)) 'L empreinte attendue n est pas donnee'
            Assert-True ($refus -match [regex]::Escape($empreinteModifie)) 'L empreinte lue n est pas donnee'
            Assert-True ($refus -match '2026\.10\.12-TEST-EMPREINTE') 'Le build du manifeste n est pas donne'
            Assert-True ($refus -match 'PasserOutreEmpreintes') 'L echappatoire n est pas annoncee'
            $refus = ''
            try { & $scriptDeblocage -WhatIf -PasserOutreEmpreintes | Out-Null } catch { $refus = $_.Exception.Message }
            Assert-True ($refus -eq '') ('-PasserOutreEmpreintes refuse encore : ' + $refus)
        } finally {
            try { Remove-Item -LiteralPath $bac -Recurse -Force -ErrorAction Stop } catch { Write-Warning 'Bac de test de deblocage non retire.' }
        }
    }

    # ------------------------------------------------------------ FO-06 : bandeau d'etat du compte
    Test-Case 'FO-06 : la fiche annonce verrouillage, echeance et echecs de mot de passe' {
        # Le modele savait dire ces trois-la depuis D061-D063, l'interface ne les a jamais demandés.
        $texte = Get-MainXaml
        $xaml = [xml]$texte
        $XNS = 'http://schemas.microsoft.com/winfx/2006/xaml'
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $aideBrutee = Get-Content -LiteralPath (Join-Path (Split-Path $core -Parent) 'modules/Domenia-UX.help.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $aide = @($aideBrutee)
        $bandes = @($xaml.SelectNodes('//*[local-name()="Border"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'PnlUserSupportBand' })
        Assert-True ($bandes.Count -eq 1) ('PnlUserSupportBand : ' + $bandes.Count + ' occurrence(s)')
        Assert-True (([string]$bandes[0].GetAttribute('Visibility')) -ceq 'Collapsed') 'Le bandeau parait avant meme la lecture du compte'
        Assert-True (([string]$bandes[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$bandes[0].GetAttribute('ToolTip')) 'PnlUserSupportBand : l aide d automation ne reprend pas l infobulle'
        $titres = @($xaml.SelectNodes('//*[local-name()="TextBlock"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'TxtUserSupportBand' })
        Assert-True ($titres.Count -eq 1) ('TxtUserSupportBand : ' + $titres.Count + ' occurrence(s)')
        Assert-True (([string]$titres[0].GetAttribute('TextWrapping')) -ceq 'Wrap') 'Le bandeau tronque ce que le controleur a repondu'
        Assert-True (([string]$titres[0].GetAttribute('AutomationProperties.HelpText')).Length -gt 40) 'TxtUserSupportBand : aucune aide d automation'
        $details = @($xaml.SelectNodes('//*[local-name()="TextBlock"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'TxtUserSupportDetail' })
        Assert-True ($details.Count -eq 1) ('TxtUserSupportDetail : ' + $details.Count + ' occurrence(s)')
        Assert-True (([string]$details[0].GetAttribute('Visibility')) -ceq 'Collapsed') 'Les limites s affichent sans rien a limiter'
        $btns = @($xaml.SelectNodes('//*[local-name()="Button"]') | Where-Object { $_.GetAttribute('Name',$XNS) -eq 'BtnUserSupportUnlock' })
        Assert-True ($btns.Count -eq 1) ('BtnUserSupportUnlock : ' + $btns.Count + ' occurrence(s)')
        Assert-True (([string]$btns[0].GetAttribute('Visibility')) -ceq 'Collapsed') 'Le bouton de deverrouillage parait sur un compte qui ne lest pas'
        Assert-True (-not ([string]$btns[0].GetAttribute('Style')).Contains('DangerButton')) 'Deverrouiller depuis le bandeau est un bouton rouge'
        Assert-True (([string]$btns[0].GetAttribute('AutomationProperties.HelpText')) -ceq [string]$btns[0].GetAttribute('ToolTip')) 'BtnUserSupportUnlock : l aide d automation ne reprend pas l infobulle'
        Assert-True ($texteCore.Contains('BtnUserSupportUnlock"].Add_Click({ Unlock-UserAccount })')) 'Le bouton du bandeau ne mene a aucune action'
        Assert-True ($texteCore.Contains('Account = @("BtnUserUnlock","BtnUserSupportUnlock"')) 'Le bouton du bandeau reste cliquable en lecture seule'
        # L echeance et les echecs ne se lisent que si la fiche les demande au controleur.
        Assert-True ($texteCore.Contains('"msDS-UserPasswordExpiryTimeComputed"')) 'La liste d attributs lus ignore l echeance calculee'
        Assert-True ($texteCore.Contains('"badPasswordTime"')) 'La liste d attributs lus ignore la date du dernier echec'
        # Le bandeau appelle le modele : c est la raison d etre de ces trois fonctions.
        $maj = @($nodes | Where-Object { $_.Name -eq 'Update-DomeniaUserSupportBand' })
        Assert-True ($maj.Count -eq 1) 'Update-DomeniaUserSupportBand introuvable dans le coeur'
        $corps = [string]$maj[0].Extent.Text
        foreach ($app in @('Get-DomeniaLockoutDiagnosis','Resolve-DomeniaPasswordPolicy','Get-DomeniaUserSupportSummary')) {
            Assert-True ($corps.Contains($app)) ('Le bandeau n appelle pas ' + $app)
        }
        Assert-True ($corps.Contains('-EventReadState ' + [char]39 + 'NotRequested' + [char]39)) 'Le bandeau lit le journal sans que personne le lui demande'
        Assert-True (-not $corps.Contains('Start-DomeniaWriteTask')) 'Le bandeau ecrit dans l annuaire de sa propre initiative'
        $fill = @($nodes | Where-Object { $_.Name -eq 'Fill-UserObject' })
        Assert-True ($fill.Count -eq 1) 'Fill-UserObject introuvable dans le coeur'
        Assert-True (([string]$fill[0].Extent.Text).Contains('Update-DomeniaUserSupportBand -Entry $Entry')) 'Le bandeau ne se remplit pas a la lecture de la fiche'
        $clear = @($nodes | Where-Object { $_.Name -eq 'Clear-ObjectDetails' })
        Assert-True ($clear.Count -eq 1) 'Clear-ObjectDetails introuvable dans le coeur'
        Assert-True (([string]$clear[0].Extent.Text).Contains('Update-DomeniaUserSupportBand -Entry $null')) 'Le bandeau survit a un changement d objet'
        # Fiche d aide : une entree par controle nouveau, titre = nom d automation, texte = infobulle.
        foreach ($pair in @(@('PnlUserSupportBand','Border'), @('TxtUserSupportBand','TextBlock'), @('TxtUserSupportDetail','TextBlock'), @('BtnUserSupportUnlock','Button'))) {
            $trouvees = @($aide | Where-Object { $_.Name -eq $pair[0] })
            Assert-True ($trouvees.Count -eq 1) ('Entree d aide ' + $pair[0] + ' : ' + $trouvees.Count + ' occurrence(s)')
            Assert-True (([string]$trouvees[0].Kind) -ceq $pair[1]) ('Nature de l aide ' + $pair[0] + ' differente de l element XAML')
        }
        $entreeBtn = @($aide | Where-Object { $_.Name -eq 'BtnUserSupportUnlock' })
        Assert-True (([string]$entreeBtn[0].Title) -ceq [string]$btns[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide BtnUserSupportUnlock different du nom d automation'
        Assert-True (([string]$entreeBtn[0].Text) -ceq [string]$btns[0].GetAttribute('ToolTip')) 'Texte de l aide BtnUserSupportUnlock different de l infobulle'
        $entreeBand = @($aide | Where-Object { $_.Name -eq 'PnlUserSupportBand' })
        Assert-True (([string]$entreeBand[0].Text) -ceq [string]$bandes[0].GetAttribute('ToolTip')) 'Texte de l aide PnlUserSupportBand different de l infobulle'
        $entreeTitre = @($aide | Where-Object { $_.Name -eq 'TxtUserSupportBand' })
        Assert-True (([string]$entreeTitre[0].Title) -ceq [string]$titres[0].GetAttribute('AutomationProperties.Name')) 'Titre de l aide TxtUserSupportBand different du nom d automation'
        Assert-True (([string]$entreeTitre[0].Text) -ceq [string]$titres[0].GetAttribute('AutomationProperties.HelpText')) 'Texte de l aide TxtUserSupportBand different de son aide d automation'
    }

    Test-Case 'SP-06 : les boutons de l inventaire annoncent la duree que le code paie' {
        $xaml = Get-MainXaml
        $approx = [string][char]0x2248
        $rapide = 'Inventaire rapide (' + $approx + '1 min)'
        $complet = 'Inventaire complet (' + $approx + '3 min)'
        Assert-True ($xaml.Contains('x:Name="BtnRunInventory" Content="' + $rapide + '"')) ('Bouton Rapide : ' + $rapide + ' absent du XAML')
        Assert-True ($xaml.Contains('x:Name="BtnRunInventoryDeep" Content="' + $complet + '"')) ('Bouton Complet : ' + $complet + ' absent du XAML')
        # Le nom d automation porte le meme libelle que l ecran, sinon le lecteur d ecran dit autre chose.
        Assert-True ($xaml.Contains('AutomationProperties.Name="' + $rapide + '"')) 'Nom d automation du bouton rapide fige sur l ancien libelle'
        Assert-True ($xaml.Contains('AutomationProperties.Name="' + $complet + '"')) 'Nom d automation du bouton complet fige sur l ancien libelle'
        # L annonce reste branchee sur le budget reel du worker : 55 s et 150 s. Les deux lignes sont
        # cherchees dans le collecteur : le coeur porte d autres budgets (celui de l index, 1 200 s),
        # et un test qui les compterait tous se plaindrait d une donnee qui n a rien a voir avec l inventaire.
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        Assert-True ($texteCore.Contains('$budget = 55000')) 'Budget de l inventaire rapide (55 s) introuvable dans le collecteur'
        Assert-True ($texteCore.Contains('if ($Deep) { $budget = 150000')) 'Budget de l inventaire complet (150 s) introuvable dans le collecteur'
        # Les correctifs se lisent deja dans le rapide : le complet ne peut plus les promettre.
        foreach ($tip in @([regex]::Matches($xaml, 'ToolTip="([^"]*[Ii]nventaire complet[^"]*)"'))) {
            Assert-True (([string]$tip.Groups[1].Value) -notlike '*correctif*') ('Infobulle du complet : ' + $tip.Groups[1].Value)
        }
    }
    Test-Case 'UX-37 : la grille d inventaire affiche le libelle calcule, la valeur brute reste relisible' {
        $xaml = Get-MainXaml
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $x = [regex]::Match($texteCore, '(?s)function Set-DomeniaItemsSource.*?\r?\n\}')
        Assert-True ($x.Value.Contains('if ($Name -eq ''DgInventory'')')) 'Set-DomeniaItemsSource ne calcule pas ValueText pour DgInventory'
        Assert-True ($x.Value.Contains('Get-DomeniaInventoryValueText')) 'Le libelle n est pas calcule par la table du module poste'
        # Ce que l ecran montre : le libelle. Ce que le presse-papiers et l export emportent : la valeur
        # que CIM a rendue, que l infobulle rappelle. Les deux sont ecrits dans le XAML, pas devines.
        Assert-True ($xaml.Contains('Text="{Binding ValueText}" Style="{StaticResource WrappedCellText}" ToolTip="{Binding Value}"')) 'La colonne Valeur n affiche pas le libelle calcule'
        Assert-True ($xaml.Contains('Header="Valeur" Width="*" ClipboardContentBinding="{Binding Value}"')) 'La valeur brute ne porte plus ce que copient le presse-papiers et l export'
        $uxui = Get-Content (Join-Path (Split-Path $core -Parent) 'modules\Domenia-UX.UI.ps1') -Raw -Encoding UTF8
        Assert-True ($uxui.Contains('if (([string]$column.Header) -eq ''Source'')')) 'La colonne Source de l inventaire n est pas reservee a l Expert'
    }
    Test-Case 'UX-39 : la page des sessions rend la vue testee, plus les lignes brutes du poste' {
        $xaml = Get-MainXaml
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $sessions = Get-Content (Join-Path (Split-Path $core -Parent) 'modules\Domenia-Sessions.UI.ps1') -Raw -Encoding UTF8
        # La vue de D072 etait testee sans jamais etre appelee : le banc epingle l appel, pas la presence
        # de la fonction — c est exactement ce qui avait laisse la page branchee sur les lignes brutes.
        $complete = [regex]::Match($sessions, '(?s)function Complete-DomeniaSessionsRead.*?\r?\n\}')
        Assert-True ($complete.Value.Contains('ConvertTo-DomeniaSessionView $r')) 'La page ne passe pas par la vue des sessions'
        Assert-True ($complete.Value.Contains('@($view.Rows)')) 'La grille ne recoit pas les lignes de la vue'
        Assert-True (-not $complete.Value.Contains('$r.ObservedUtc')) 'L horodatage ISO est encore ecrit dans la page'
        $start = [regex]::Match($sessions, '(?s)function Start-DomeniaSessionsRead.*?\r?\n\}')
        Assert-True (-not $start.Value.Contains('Show-InfoBox')) 'Sans poste choisi, une fenetre bloque encore la page'
        Assert-True ($start.Value.Contains("Set-DomeniaControlText 'LblSessionsState'")) 'Sans poste choisi, la page ne dit rien'
        $grid = [regex]::Match($xaml, '(?s)<DataGrid x:Name="DgSessions".*?</DataGrid>')
        Assert-True ($grid.Value.Contains('Binding="{Binding Utilisateur}"')) 'La colonne Compte ne lie pas la vue'
        Assert-True ($grid.Value.Contains('Header="Ouverte')) 'La colonne Ouverte a manque'
        Assert-True ($grid.Value.Contains('Header="Inactive depuis')) 'La colonne Inactive depuis manque'
        Assert-True (-not $grid.Value.Contains('Binding="{Binding Id}"')) 'La grille lie encore un champ brut du poste'
        Assert-True ($texteCore.Contains('Open-DomeniaSessionFiche -Source $e.OriginalSource')) 'Le double-clic sur une session n ouvre pas la fiche'
        Assert-True ($texteCore.Contains('$sessionGrid.ContextMenu=New-DomeniaSessionsContextMenu')) 'Le menu clic droit des sessions manque'
        # Le collecteur est epingle par le contrat SHA de SessionsList : il n est pas touche. Les classes WTS
        # lues par le transport, si — et c est la qu etait la faute.
        $native = Get-Content (Join-Path (Split-Path $core -Parent) 'modules\Domenia-Sessions.Native.cs') -Raw -Encoding UTF8
        Assert-True ($native.Contains('WTSClientProtocolType=15')) 'Le protocole de session n est pas la classe 15'
        Assert-True ($native.Contains('WTSQuerySessionInformationW(server,s.SessionId,WTSClientProtocolType,out proto,out len)')) 'Le protocole est lu avec une autre classe que WTSClientProtocolType'
        Assert-True ($native.Contains('LogonTicks=Ticks(server,s.SessionId,WTSLogonTime)')) 'L heure d ouverture n est pas lue'
        Assert-True ($native.Contains('IdleTicks=Ticks(server,s.SessionId,WTSIdleTime)')) 'La duree d inactivite n est pas lue'
    }
    Test-Case 'UX-17 : le diagnostic rend sa phrase en francais et garde les codes pour la copie' {
        $xaml = Get-MainXaml
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        $diag = [regex]::Match($xaml, '(?s)<DataGrid x:Name="DgComputerDiag".*?</DataGrid>')
        Assert-True ($diag.Value.Contains('Text="{Binding EtatLibelle}"')) 'La colonne Etat affiche encore le code brut du worker'
        Assert-True ($diag.Value.Contains('<DataTrigger Binding="{Binding Severity}" Value="Echec">')) 'Les echecs ne se distinguent que par le texte'
        Assert-True ($diag.Value.Contains('ToolTip="{Binding Status}"')) 'Le code brut a disparu de l infobulle de la ligne'
        # Le worker est epingle par le contrat SHA de ComputerDiagnostics : il n est pas touche. Le lot
        # ne porte que sur la vue, le rappel de fin et le profil Expert — le banc epingle ces trois-la.
        Assert-True ($texteCore.Contains('ConvertTo-DomeniaDiagVerdict -Rows @($result.Rows) -Computer ([string]$result.Computer)')) 'La page ne passe pas par la vue du diagnostic'
        Assert-True ($texteCore.Contains('-Name "LblComputerDiag" -Text $diagText')) 'Le verdict n est pas ecrit en haut de la page'
        Assert-True (-not $texteCore.Contains('$script:ComputerDiagRows).Count - $ok - $skipped')) 'Les controles facultatifs comptent encore comme des echecs'
        Assert-True ($texteCore.Contains('[int]$diagView.Info')) 'La ligne de statut ne dit pas ce qui etait facultatif'
        $uxui = Get-Content (Join-Path (Split-Path $core -Parent) 'modules\Domenia-UX.UI.ps1') -Raw -Encoding UTF8
        Assert-True ($uxui.Contains("Get-DomeniaControl 'DgComputerDiag'")) 'Methode et Duree ms ne dependent pas du profil Expert'
        # Recherche litterale en chaine simple : en chaine double, $column etait interpole avant de chercher.
        Assert-True ($uxui.Contains('-eq ''Methode'' -or ([string]$column.Header) -eq ''Duree ms''')) 'Les deux colonnes techniques ne sont pas reservees a l Expert'
    }
    Test-Case 'UI-08 : la liste des logiciels passe avant la synthese en graphiques' {
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        # En chaine simple : en chaine double, $script: et $sender seraient interpoles avant la recherche.
        Assert-True ($texteCore.Contains('<ComboBox x:Name="CmbSoftwareView" Width="130" SelectedIndex="0"')) 'Aucun selecteur Liste | Synthese sur la liste'
        Assert-True ($texteCore.Contains('<StackPanel x:Name="PnlSoftwareSynthese" Visibility="Collapsed"')) 'La synthese s affiche avant que l operateur la demande'
        Assert-True (-not $texteCore.Contains('x:Name="ExpSoftwareDashboard"')) 'L expander de synthese reste ouvert par defaut'
        Assert-True ($texteCore.Contains('<ToggleButton x:Name="BtnSoftwareColumns"')) 'Les colonnes techniques n ont pas de bouton'
        Assert-True ($texteCore.Contains('<TextBlock Grid.Row="1" x:Name="LblSoftwareAccessSummary"')) 'Le detail par portee ne tient pas en une ligne'
        Assert-True (-not $texteCore.Contains('x:Name="UxSplitter1"')) 'Le detail par portee occupe encore une rangee de 150 pixels'
        Assert-True ($texteCore.Contains('IsReadOnly="True" MaxHeight="180"')) 'Le detail replie peut avaler l onglet'
        Assert-True ($texteCore.Contains('$script:Ctrl["CmbSoftwareView"].Add_SelectionChanged({')) 'Le selecteur Liste | Synthese ne declenche rien'
        Assert-True ($texteCore.Contains('$script:Ctrl["BtnSoftwareColumns"].Add_Checked({')) 'Le bouton Colonnes ne declenche rien'
        Assert-True (-not $texteCore.Contains('Update-DomeniaSoftwareColumnProvenance')) 'Deux regles distinctes commandent encore les colonnes'
        Assert-True ($texteCore.Contains('Update-DomeniaSoftwareAccessSummary')) 'Le resume du detail par portee n est jamais ecrit'
    }

    Test-Case 'FO-09 : un clic sur une part ou une barre filtre la liste et la pastille le dit' {
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        # En chaine simple : en chaine double, $script: serait interpole avant la recherche.
        Assert-True ($texteCore.Contains('<Border x:Name="UxSoftwareFilterChip" Visibility="Collapsed"')) 'La pastille du filtre se montre avant qu un clic la demande'
        Assert-True ($texteCore.Contains('<TextBlock x:Name="LblSoftwareFilterChip" Text=""')) 'La pastille n a pas de texte a remplir'
        Assert-True ($texteCore.Contains('<Button x:Name="BtnSoftwareFilterClear"')) 'La pastille n a pas de bouton pour la retirer'
        Assert-True ($texteCore.Contains('$script:Ctrl["BtnSoftwareFilterClear"].Add_Click({ Clear-DomeniaSoftwareChartFilter })')) 'Le bouton de la pastille ne declenche rien'
        Assert-True ($texteCore.Contains('"UxSoftwareFilterChip" = "Default"')) 'La pastille echappe a la politique des elements graphiques'
        Assert-True ($texteCore.Contains('Test-DomeniaSoftwareRowMatchesSelect -Row $_ -Select $select')) 'Le critere venu d un graphique ne filtre pas la liste'
        Assert-True ($texteCore.Contains('Update-DomeniaSoftwareFilterChip')) 'La pastille ne se remet jamais a jour avec la liste'
        Assert-True ($texteCore.Contains('Get-DomeniaSoftwareSelectToggle -Current $script:SoftwareChartSelect -Incoming $Select')) 'Le second clic sur la meme part ne retire pas le filtre'
        Assert-True ($texteCore.Contains('Set-DomeniaComboByContent -Name ''CmbSoftwareScope'' -Content $suivant')) 'Le clic sur la portee ne pilote pas le selecteur deja dans l onglet'
        Assert-True ($texteCore.Contains('$script:SoftwareChartSelect = $null')) 'Le filtre venu d un graphique survit a une nouvelle lecture'
    }

    Test-Case 'FO-07 : la derniere lecture du poste est reprise de la session avec son age' {
        # Horloge figee, comme CO-03 : l'ecart mesure doit rester deterministe.
        $now = [datetime]::new(2026,10,10,12,0,0)
        $ages = @(
            @([datetime]::new(2026,10,10,11,59,30),"Inventaire à lʼinstant"),
            @([datetime]::new(2026,10,10,11,30,0),'Inventaire dʼil y a 30 min'),
            @([datetime]::new(2026,10,10,8,0,0),'Inventaire dʼil y a 4 h'),
            @([datetime]::new(2026,10,7,12,0,0),'Inventaire dʼil y a 3 j'),
            @([datetime]::new(2026,9,1,12,0,0),'Inventaire du 01/09/2026')
        )
        foreach ($age in $ages) {
            $lu = [string](Get-DomeniaInventoryAgeLabel -CompletedAt $age[0] -Now $now)
            Assert-True ($lu -ceq $age[1]) ('Age « ' + [string]$age[0] + ' » : obtenu « ' + $lu + ' »')
        }
        Assert-True (([string](Get-DomeniaInventoryAgeLabel -CompletedAt $null -Now $now)) -ceq '') 'Une lecture inconnue affiche un age invente'
        Assert-True (([string](Get-DomeniaInventoryAgeLabel -CompletedAt '10/10/2026 11:30:00' -Now $now)) -ceq '') 'Un age calcule sur une chaine serait un age invente'
        $resume = Get-DomeniaInventorySummaryText -Computer 'POSTE-01' -Rows @([pscustomobject]@{Name='a'},[pscustomobject]@{Name='b'}) -Access @([pscustomobject]@{Status='OK'},[pscustomobject]@{Status='OK'},[pscustomobject]@{Status='REFUSE'},[pscustomobject]@{Status='INDISPONIBLE'},[pscustomobject]@{Status='AUTRE'}) -DurationMs 4210
        Assert-True ($resume -ceq 'POSTE-01 : 2 element(s) sur 2 source(s) accessibles, 1 refusee(s), 1 indisponible(s), 1 autre(s), en 4210 ms.') ('Phrase de resume : ' + $resume)
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        # En chaine simple : en chaine double, $script: serait interpole avant la recherche.
        Assert-True ($texteCore.Contains('<StackPanel x:Name="TxtInventoryAge" Orientation="Horizontal" Visibility="Collapsed"')) 'La ligne d age se montre avant qu une lecture la remplisse'
        Assert-True ($texteCore.Contains('<Hyperlink x:Name="LnkInventoryRefresh">Actualiser</Hyperlink>')) 'La ligne d age n a pas de quoi relancer la lecture'
        Assert-True ($texteCore.Contains('$script:Ctrl["LnkInventoryRefresh"].Add_Click({ Start-DomeniaComputerInventory })')) 'Le lien Actualiser ne relance rien'
        Assert-True ($texteCore.Contains('"TxtInventoryAge" = "Default"')) 'La ligne d age tombe sous la politique des elements graphiques'
        Assert-True ($texteCore.Contains('$script:InventoryCacheByComputer = @{}')) 'Le cache de session n est jamais remis a zero'
        Assert-True ($texteCore.Contains('Normalize-LinkComputer ([string]$State.Computer)')) 'La cle du cache invente sa propre regle de nom de poste'
        $corps = ($texteCore -split 'function Show-DomeniaCachedInventory')[1]
        Assert-True ($corps.Contains('Update-DomeniaInventoryAgeLine')) 'La liste reprise ne dit pas son age'
        Assert-True (-not $corps.Contains('Update-DomeniaComputerDashboard')) 'La reprise rejoue le tableau de bord d une lecture fraiche'
    }

    Test-Case 'MO-09 : les logiciels par utilisateur se lisent par StdRegProv sur HKU, sans WinRM' {
        $code = [string](Get-DomeniaSoftwareWorkerCode)
        # Le corps du worker n'est pas interprete ici : il doit au moins se compiler sous PowerShell 5.1.
        [void]([scriptblock]::Create($code))
        # En chaine simple : en chaine double, $HKU serait interpole avant la recherche.
        Assert-True ($code.Contains('$HKU = [uint32]2147483651')) 'La ruche HKU (0x80000003) n est pas declaree dans le worker'
        Assert-True ($code.Contains('Get-RegSubKeys $HKU')) 'Les ruches chargees ne sont pas enumerees par StdRegProv'
        Assert-True ($code.Contains("-Source 'HKU via StdRegProv'")) 'La portee utilisateur ne dit pas qu elle lit HKU par StdRegProv'
        Assert-True ($code.Contains("'Non lu : '")) 'Un echec de la portee utilisateur ne se rend pas comme non lu'
        Assert-True (-not ($code.Contains("'HKEY_USERS via WinRM'"))) 'La portee utilisateur pretend encore lire par WinRM'
        Assert-True (-not ($code.Contains('La lecture par profil necessite WinRM'))) 'La portee utilisateur exige encore WinRM'
        Assert-True (-not ($code.Contains("Get-ChildItem 'Registry::HKEY_USERS'"))) 'La portee utilisateur parcourt encore les ruches a distance par WinRM'
        Assert-True (-not ($code.Contains('$includePerUser -and @($rows'))) 'Une portee utilisateur vide declenche encore la collecte locale SYSTEM'
        $xaml = Get-MainXaml
        Assert-True ($xaml.Contains('ToolTip="Ajoute les logiciels installés dans le profil des utilisateurs connectés."')) 'L infobulle promet toujours le profil de chaque utilisateur'
        Assert-True (-not ($xaml.Contains('dans le profil de chaque utilisateur'))) 'L infobulle promet encore tous les utilisateurs'
    }

    Test-Case 'Points 91 a 100 : les workers d inventaire lisent registre et CIM sans effet de bord' {
        $software = [string](Get-DomeniaSoftwareWorkerCode)
        # Point 91 : architecture et profil utilisateur font partie de la cle ; un doublon reste une ligne.
        Assert-True ($software.Contains("`$key = (`$Scope + '|' + `$owner + '|' + [string]`$Architecture + '|' + `$clean + '|' + [string]`$Version)")) 'Les doublons par architecture ou profil sont encore fusionnes'
        $code = [string](Get-DomeniaInventoryWorkerCode)
        [void]([scriptblock]::Create($code))
        # Point 93 : REG_MULTI_SZ lu comme tel ; chaque indice ecrit avec sa source.
        Assert-True ($code.Contains("Get-RegMultiString `$HKLM 'SYSTEM\CurrentControlSet\Control\Session Manager' 'PendingFileRenameOperations'")) 'PendingFileRenameOperations lu comme une chaine simple'
        Assert-True ($code.Contains("'obligation confirmee'") -and $code.Contains("'indice partiel'")) 'Obligation confirmee et indice partiel confondus'
        # Point 99 : UEFISecureBootEnabled est un DWORD ; le chiffrement est lu a cote de la protection.
        Assert-True ($code.Contains("Get-RegDword `$HKLM 'SYSTEM\CurrentControlSet\Control\SecureBoot\State' 'UEFISecureBootEnabled'")) 'Secure Boot encore lu comme une chaine'
        Assert-True ($code.Contains("(`$label + ' chiffrement')")) 'Chiffrement BitLocker non distingue de la protection'
        # Point 83 : un etat de sante absent ou inconnu ne devient jamais Sain.
        Assert-True (-not $code.Contains("`$health = 'Sain'`n")) 'Sante du disque initialisee a Sain'
        # Point 100 : magasin Personnel lu dans le registre, propriete 32 seulement, aucune cle privee.
        Assert-True ($code.Contains("'SOFTWARE\Microsoft\SystemCertificates\MY\Certificates'") -and $code.Contains('$propertyId -eq 32')) 'Certificats machine non lus dans le registre'
        Assert-True (-not ($code -match '(?i)PrivateKey|Export\(|ExportCspBlob')) 'Une cle privee peut etre lue ou exportee'
        # Point 95 : deux lectures bornees pour la charge, sans ligne de commande.
        Assert-True ($code.Contains('Start-Sleep -Milliseconds $intervalMs') -and $code.Contains('[Math]::Min(5000,')) 'Intervalle de mesure non borne'
        Assert-True (-not $code.Contains('CommandLine')) 'Ligne de commande collectee'
        # Point 96 : derniere execution et resultat, jamais les actions ni le principal.
        Assert-True ($code.Contains('Get-ScheduledTaskInfo') -and -not ($code -match '\.Actions\b|\.Principal\b')) 'Taches : execution non lue ou parametres exposes'
        # Point 94 : dependances lues, aucune action sur les services.
        Assert-True ($code.Contains("'DependOnService'") -and -not ($code -match '(?i)Start-Service|Stop-Service|StartService|StopService')) 'Dependances absentes ou action sur un service'
    }

    Test-Case 'PF-22 : l onglet Logiciels reprend la liste deja lue par l inventaire' {
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        # En chaine simple : en chaine double, $script: et $name seraient interpoles avant la recherche.
        Assert-True ($texteCore.Contains('ConvertTo-DomeniaSoftwareFromInventory -Items $script:InventoryRows -CompletedAt $script:InventoryCompletedAt')) 'L onglet ne passe pas par la vue qui reprend l inventaire'
        Assert-True ($texteCore.Contains('$script:Ctrl["ComputerTabs"].Add_SelectionChanged({')) 'L ouverture de l onglet ne declenche rien'
        Assert-True ($texteCore.Contains('([string]$onglet.Name) -eq ''TabSoftware''')) 'L ouverture d un autre onglet declencherait la reprise'
        Assert-True ($texteCore.Contains('if ([string]$script:SoftwareSource -ne '''') { return }')) 'La reprise se declencherait pendant une lecture en cours'
        $corpsReprise = ($texteCore -split 'function Show-DomeniaSoftwareFromInventory')[1]
        Assert-True ($corpsReprise.Contains('Update-DomeniaSoftwareColumnVisibility')) 'Les colonnes que l inventaire ne remplit pas restent affichees vides'
        Assert-True ($texteCore.Contains('-logiciels-inventaire')) 'Un CSV repris de l inventaire se revendique comme une lecture complete'
        Assert-True ($texteCore.Contains('$script:SoftwareSource = "Poste"')) 'Une lecture complete ne rend pas les colonnes techniques'
        $modele = Get-Content (Join-Path (Split-Path $core -Parent) 'modules\Domenia-Workstation.Model.ps1') -Raw -Encoding UTF8
        Assert-True ($modele.Contains('if ($name -eq ''Nombre detecte'') { continue }')) 'La ligne « Nombre detecte » de l inventaire deviendrait un logiciel'
    }
    if ($WpfSmoke) {
        Test-Case 'WPF et moteur : autotest interne dans un processus dedie' {
            $selfReport=Join-Path $testDirectory 'self-test.json'
            $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $p=Start-Process -FilePath $exe -ArgumentList @('-NoLogo','-NoProfile','-STA','-File',('"'+$core+'"'),'-DomeniaSelfTest','-DomeniaSelfTestResultPath',('"'+$selfReport+'"')) -WorkingDirectory (Split-Path -Parent $core) -PassThru
            try {
                if(-not $p.WaitForExit(90000)) {try{$p.Kill()}catch{};throw 'Autotest WPF arrete apres 90 s (processus de test uniquement).'}
                Assert-True (Test-Path -LiteralPath $selfReport) ('Rapport WPF absent; code '+$p.ExitCode)
                $nativeReport=Get-Content -LiteralPath $selfReport -Raw | ConvertFrom-Json
                Assert-True ([bool]$nativeReport.Success) (($nativeReport.Checks | Where-Object {-not $_.Success} | ForEach-Object {$_.Name+': '+$_.Detail}) -join '; ')
            } finally {$p.Dispose()}
        }
    }
}
finally {
    if([string]::IsNullOrWhiteSpace($ReportPath)) {$ReportPath=Join-Path $root ('wad\data\TestReports\tests-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json')}
    $reportFull=[IO.Path]::GetFullPath($ReportPath);[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFull))
    $failed=@($script:TestResults | Where-Object {$_.Status -eq 'FAIL'}).Count
    $report=[ordered]@{Generated=(Get-Date).ToString('o');Environment='Windows PowerShell 5.1 x64';PowerShell=[string]$PSVersionTable.PSVersion;Passed=@($script:TestResults | Where-Object {$_.Status -eq 'PASS'}).Count;Failed=$failed;WpfRequested=[bool]$WpfSmoke;Results=$script:TestResults.ToArray();Messages=$script:TestMessages.ToArray()}
    [IO.File]::WriteAllText($reportFull,($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Write-Host ('Rapport : '+$reportFull)
    try {Remove-Item -LiteralPath $testDirectory -Recurse -Force -ErrorAction Stop}catch {Write-Warning 'Le dossier temporaire de tests n a pas pu etre entierement retire.'}
}
if ($failed -gt 0) {exit 1}
exit 0
