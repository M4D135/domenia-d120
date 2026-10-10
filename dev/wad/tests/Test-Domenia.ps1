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
    'Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys','Get-MainXaml')
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
    Test-Case 'PF-22 : l onglet Logiciels reprend la liste deja lue par l inventaire' {
        $texteCore = Get-Content $core -Raw -Encoding UTF8
        # En chaine simple : en chaine double, $script: et $name seraient interpoles avant la recherche.
        Assert-True ($texteCore.Contains('ConvertTo-DomeniaSoftwareFromInventory -Items $script:InventoryRows -CompletedAt $script:InventoryCompletedAt')) 'L onglet ne passe pas par la vue qui reprend l inventaire'
        Assert-True ($texteCore.Contains('$script:Ctrl["ComputerTabs"].Add_SelectionChanged({')) 'L ouverture de l onglet ne declenche rien'
        Assert-True ($texteCore.Contains('([string]$onglet.Name) -eq ''TabSoftware''')) 'L ouverture d un autre onglet declencherait la reprise'
        Assert-True ($texteCore.Contains('if ([string]$script:SoftwareSource -ne '''') { return }')) 'La reprise se declencherait pendant une lecture en cours'
        Assert-True ($texteCore.Contains('Update-DomeniaSoftwareColumnProvenance -FromInventory $true')) 'Les colonnes que l inventaire ne remplit pas restent affichees vides'
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
