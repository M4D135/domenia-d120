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
$wanted=@('Write-DomeniaAtomicText','Read-DomeniaPreference','Get-DomeniaPreferencePath','Protect-DomeniaLogText',
    'ConvertTo-DomeniaSpreadsheetCell','ConvertTo-DomeniaSpreadsheetSafeRow','ConvertTo-DomeniaSqlLikeText',
    'Get-DomeniaScopeKey','Assert-DomeniaWmiReadQuery','Update-SecretsGrid','Get-DomeniaSelectedSecretSource',
    'Complete-DomeniaDetachedReadJobs','Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr',
    'Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','ConvertTo-DomeniaSqlLiteral',
    'Get-DomeniaDatabasePath','Get-DomeniaStoreBackupDirectory','Backup-DomeniaDatabase','Search-DomeniaDatabaseRows',
    'Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode','Assert-DomeniaWorkerOperationCode')
$definitions=New-Object 'System.Collections.Generic.List[string]'
$nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in $wanted) {
    $node=@($nodes | Where-Object {$_.Name -eq $name})
    if ($node.Count -ne 1) { throw "Definition unique attendue : $name ($($node.Count) trouvee)." }
    $definitions.Add($node[0].Extent.Text)
}
# Import definitions only. Never dot-source the application's startup path.
. ([scriptblock]::Create(($definitions -join "`r`n")))
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
try {
    Test-Case 'Ecriture atomique UTF-8 et derniere version valide' {
        $p=Join-Path $script:DataDir 'atomic.json'
        Write-DomeniaAtomicText $p '{"etat":"été"}' -KeepBackup
        Write-DomeniaAtomicText $p '{"etat":"nouveau"}' -KeepBackup
        Assert-True (([IO.File]::ReadAllText($p) | ConvertFrom-Json).etat -ceq 'nouveau')
        Assert-True (([IO.File]::ReadAllText($p+'.bak') | ConvertFrom-Json).etat -ceq 'été')
        Assert-True (@(Get-ChildItem -LiteralPath $script:DataDir -Filter '.domenia-*.tmp').Count -eq 0)
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
        $number=ConvertTo-DomeniaSpreadsheetCell -42
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
