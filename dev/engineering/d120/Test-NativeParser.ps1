# Native syntax validation only. No domain access and no application bootstrap.
# D001: every PowerShell file, and with -ContractsPath every pinned worker body (alone and as the definition really
# assembled by the core function New-DomeniaWorkerRunspace), is parsed by this engine; with -CompileCSharp every C#
# primitive of wad/modules is compiled by Add-Type in its own child process. Worker code is never executed: the
# assembled definition is read from the InitialSessionState entry of an empty, never invoked runspace.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SourceRoot,
      [Parameter(Mandatory=$true)][string]$ReportPath,
      [switch]$RequireWindows51,
      [string]$ContractsPath='',
      [switch]$CompileCSharp,
      [ValidateRange(10,900)][int]$CompileTimeoutSeconds=180)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SourceRoot)
$started = [DateTime]::UtcNow.ToString('o')
$edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
$isNativeWindows51 = ($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)
$rows = New-Object 'System.Collections.Generic.List[object]'
$failures = 0
function Get-NativeParserErrors {
    param([string]$Text)
    $t = $null; $e = $null
    [void][Management.Automation.Language.Parser]::ParseInput($Text,[ref]$t,[ref]$e)
    return @($e)
}
function Get-NativeWorkerLiteral {
    # Same literal selection as tools/update_worker_contracts.py: the N-th here-string of the function text (LF).
    param([string]$FunctionText,[int]$Index)
    $normalized = $FunctionText.Replace("`r`n","`n")
    $options = [Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::Singleline
    $found = [regex]::Matches($normalized,"@(['""])\n(.*?)\n^\1@",$options)
    if ($Index -lt 0 -or $Index -ge $found.Count) { return $null }
    return [string]$found[$Index].Groups[2].Value
}
function Get-NativeTextSha256 {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','') } finally { $sha.Dispose() }
}
function Get-NativeFunctionText {
    param($Ast,[string]$Name)
    $nodes = @($Ast.FindAll({ param($n) ($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name) },$true))
    if ($nodes.Count -ne 1) { throw ('Fonction absente ou ambigue : ' + $Name + ' (' + $nodes.Count + ')') }
    return [string]$nodes[0].Extent.Text
}
$paths = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.psd1' })
if ($paths.Count -eq 0) { throw 'No PowerShell source found.' }
foreach ($file in $paths) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    $detail = @($errors | ForEach-Object { [pscustomobject]@{ ErrorId=$_.ErrorId;Line=$_.Extent.StartLineNumber;Message=$_.Message } })
    if ($detail.Count -gt 0) { $failures++ }
    $rows.Add([pscustomobject]@{ File=$file.FullName.Substring($root.Length).TrimStart('\','/');Status=$(if($detail.Count){'FAIL'}else{'PASS'});SHA256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash;Errors=$detail })
}
$fixtures = @(
    @{Name='bare-command-after-or';Code='if ($false -or Test-Example) { 1 }';ExpectFailure=$true},
    @{Name='parenthesized-command-after-or';Code='if ($false -or (Test-Example)) { 1 }';ExpectFailure=$false},
    @{Name='unterminated-string';Code="Write-Output 'unfinished";ExpectFailure=$true},
    @{Name='balanced-scriptblock';Code='param($x) if ($null -ne $x) { return @($x) }';ExpectFailure=$false},
    # A here-string is opaque to the file parser: only the worker check sees a syntax error inside a pinned body.
    @{Name='worker-literal-bare-command';Code=("function Get-ExampleWorkerCode {`n    return @'`nif (`$false -or Test-Example) { 1 }`n'@`n}");ExpectFailure=$true;Worker=$true},
    @{Name='worker-literal-valid';Code=("function Get-ExampleWorkerCode {`n    return @'`nif (`$false -or (Test-Example)) { 1 }`n'@`n}");ExpectFailure=$false;Worker=$true}
)
$fixtureRows = New-Object 'System.Collections.Generic.List[object]'
foreach($fixture in $fixtures) {
    $code = [string]$fixture.Code
    if ($fixture.ContainsKey('Worker')) {
        $fileErrors = @(Get-NativeParserErrors $code)
        $literal = Get-NativeWorkerLiteral $code 0
        $hasError = (($fileErrors.Count -gt 0) -or ($null -eq $literal) -or (@(Get-NativeParserErrors $literal).Count -gt 0))
    } else {
        $hasError = @(Get-NativeParserErrors $code).Count -gt 0
    }
    $ok=$hasError -eq $fixture.ExpectFailure
    if(-not $ok){$failures++}
    $fixtureRows.Add([pscustomobject]@{Name=$fixture.Name;Status=$(if($ok){'PASS'}else{'FAIL'});Rejected=$hasError})
}
# ---------------------------------------------------------------- D001 worker bodies as really assembled
$workerRows = New-Object 'System.Collections.Generic.List[object]'
$workersParsed = 0
$workerFailures = 0
$workerSetup = ''
$workersRequested = -not [string]::IsNullOrWhiteSpace($ContractsPath)
if ($workersRequested) {
    try {
        $contractsFile = $ContractsPath
        if (-not [IO.Path]::IsPathRooted($contractsFile)) { $contractsFile = Join-Path $root $contractsFile }
        $contracts = @((([IO.File]::ReadAllText($contractsFile)) | ConvertFrom-Json) | ForEach-Object { $_ })
        if ($contracts.Count -eq 0) { throw 'Contrats worker vides.' }
        $coreFile = Join-Path $root 'wad\Domenia-Core.ps1'
        $tokens = $null; $errors = $null
        $coreAst = [Management.Automation.Language.Parser]::ParseFile($coreFile,[ref]$tokens,[ref]$errors)
        if (@($errors).Count -gt 0) { throw 'Coeur illisible par le parseur natif.' }
        # The real assembly function of the core, dot-sourced at script scope; nothing else of the core is loaded but the
        # trace its catch blocks call (P-CD-09: Write-DomeniaSwallowed, defined in the core script scope; it never throws).
        . ([scriptblock]::Create((Get-NativeFunctionText $coreAst 'Write-DomeniaSwallowed')))
        . ([scriptblock]::Create((Get-NativeFunctionText $coreAst 'New-DomeniaWorkerRunspace')))
        $moduleAsts = @{}
        foreach ($module in @(Get-ChildItem -LiteralPath (Join-Path $root 'wad\modules') -Filter '*.ps1' -File)) {
            $tokens = $null; $errors = $null
            $moduleAsts[$module.Name] = [Management.Automation.Language.Parser]::ParseFile($module.FullName,[ref]$tokens,[ref]$errors)
        }
        foreach ($helper in @('Get-DomeniaStructuredError','Get-DomeniaReceiptsCommon')) {
            $helperText = ''
            foreach ($moduleName in @($moduleAsts.Keys | Sort-Object)) {
                $hits = @($moduleAsts[$moduleName].FindAll({ param($n) ($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $helper) },$true))
                if ($hits.Count -eq 1) { $helperText = [string]$hits[0].Extent.Text }
            }
            if (-not $helperText) { $helperText = Get-NativeFunctionText $coreAst $helper }
            . ([scriptblock]::Create($helperText))
        }
        # $script:WorkerCommon: top-level assignments of the core, in order, then the receipts helper added by the
        # main block ("`r`n" + Get-DomeniaReceiptsCommon), exactly as at application start.
        $script:WorkerCommon = ''
        $commonParts = 0
        foreach ($statement in @($coreAst.EndBlock.Statements)) {
            if ($statement -isnot [Management.Automation.Language.AssignmentStatementAst]) { continue }
            if ([string]$statement.Left.Extent.Text -ne '$script:WorkerCommon') { continue }
            $value = $statement.Right
            if ($value -is [Management.Automation.Language.CommandExpressionAst]) { $value = $value.Expression }
            if ($value -isnot [Management.Automation.Language.StringConstantExpressionAst]) { throw 'Fragment WorkerCommon non litteral.' }
            if ([string]$statement.Operator -eq 'Equals') { $script:WorkerCommon = [string]$value.Value } else { $script:WorkerCommon += [string]$value.Value }
            $commonParts++
        }
        if ($commonParts -lt 1) { throw 'WorkerCommon introuvable dans le coeur.' }
        $coreText = [IO.File]::ReadAllText($coreFile)
        if ($coreText.IndexOf('$script:WorkerCommon += "`r`n"+(Get-DomeniaReceiptsCommon)') -lt 0) { throw 'Assemblage WorkerCommon du bloc principal modifie : mettre a jour Test-NativeParser.' }
        $script:WorkerCommon += "`r`n" + (Get-DomeniaReceiptsCommon)
        # Parse-only stand-in for the registry check (the registry itself is verified by the worker.contracts scenario).
        function Assert-DomeniaWorkerOperationCode { param([string]$OperationId,[string]$Code) return ('PARSE-ONLY-' + $OperationId) }
        $workerSetup = 'WorkerCommon=' + $commonParts + ' fragments + recus'
        $fileAsts = @{}
        foreach ($contract in $contracts) {
            $operation = [string]$contract.Operation
            $forms = New-Object 'System.Collections.Generic.List[string]'
            $problems = New-Object 'System.Collections.Generic.List[string]'
            $hashMatches = $false
            try {
                $relative = ([string]$contract.File).Replace('/','\')
                if (-not $fileAsts.ContainsKey($relative)) {
                    $tokens = $null; $errors = $null
                    $fileAsts[$relative] = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative),[ref]$tokens,[ref]$errors)
                }
                $literal = Get-NativeWorkerLiteral (Get-NativeFunctionText $fileAsts[$relative] ([string]$contract.Function)) ([int]$contract.LiteralIndex)
                if ($null -eq $literal) { throw 'Litteral du worker introuvable.' }
                $hashMatches = ((Get-NativeTextSha256 $literal) -ceq ([string]$contract.Sha256).ToUpperInvariant())
                if (-not $hashMatches) { $problems.Add('Empreinte du corps differente du contrat.') }
                foreach ($e in @(Get-NativeParserErrors $literal)) { $problems.Add('Corps ligne ' + $e.Extent.StartLineNumber + ' : ' + $e.Message) }
                $writeForms = @($false)
                if ($literal.IndexOf('$DomeniaWriteDispatched') -ge 0) { $writeForms = @($false,$true) }
                foreach ($isWrite in $writeForms) {
                    $form = 'Lecture'
                    if ($isWrite) { $form = 'Ecriture' }
                    $script:LiveWorkerPools = @{}
                    $record = New-DomeniaWorkerRunspace -OperationId $operation -Code $literal -IsWrite:$isWrite
                    try {
                        $state = $null
                        if ($null -ne $record.PSObject.Properties['Pool'] -and $null -ne $record.Pool) { $state = $record.Pool.InitialSessionState } else { $state = $record.Runspace.InitialSessionState }
                        $entry = @($state.Commands | Where-Object { $_.Name -eq [string]$record.CommandName })
                        if ($entry.Count -ne 1) { throw 'Definition assemblee introuvable.' }
                        foreach ($e in @(Get-NativeParserErrors ([string]$entry[0].Definition))) { $problems.Add($form + ' assemblee ligne ' + $e.Extent.StartLineNumber + ' : ' + $e.Message) }
                        $forms.Add($form)
                    }
                    finally {
                        if ($null -ne $record.PSObject.Properties['Pool'] -and $null -ne $record.Pool) { try { $record.Pool.Dispose() } catch { } }
                        if ($null -ne $record.PSObject.Properties['Runspace'] -and $null -ne $record.Runspace) { try { $record.Runspace.Dispose() } catch { } }
                    }
                }
            }
            catch { $problems.Add('Analyse impossible : ' + $_.Exception.Message) }
            $ok = ($problems.Count -eq 0)
            if ($ok) { $workersParsed++ } else { $workerFailures++; $failures++ }
            $workerRows.Add([pscustomobject]@{Operation=$operation;File=[string]$contract.File;Function=[string]$contract.Function;Forms=$forms.ToArray();Sha256Matches=$hashMatches;Status=$(if($ok){'PASS'}else{'FAIL'});Errors=$problems.ToArray()})
        }
    }
    catch {
        $failures++
        $workerFailures++
        $workerSetup = 'ECHEC : ' + $_.Exception.Message
    }
}
# ---------------------------------------------------------------- D001 C# primitives compiled by Windows PowerShell 5.1
$csharpRows = New-Object 'System.Collections.Generic.List[object]'
$csharpCompiled = 0
if ($CompileCSharp) {
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($source in @(Get-ChildItem -LiteralPath (Join-Path $root 'wad\modules') -Filter '*.cs' -File | Sort-Object Name)) {
        # Add-Type cannot unload a type: one child process per file. The path is not a secret.
        $command = "`$ErrorActionPreference='Stop'; Add-Type -Path '" + $source.FullName.Replace("'","''") + "'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $errFile = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-csc-' + [guid]::NewGuid().ToString('N') + '.txt')
        $outFile = $errFile + '.out'
        $status = 'FAIL'; $detail = ''; $code = $null
        try {
            $process = Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -PassThru -NoNewWindow -RedirectStandardError $errFile -RedirectStandardOutput $outFile
            # Windows PowerShell 5.1 only exposes ExitCode when the handle was read before the exit.
            $null = $process.Handle
            if (-not $process.WaitForExit($CompileTimeoutSeconds * 1000)) { try { $process.Kill() } catch { }; $detail = 'Delai de compilation depasse.' }
            else {
                $process.WaitForExit(); $code = $process.ExitCode
                if ($code -eq 0) { $status = 'PASS'; $csharpCompiled++ }
                elseif ([IO.File]::Exists($errFile)) { $detail = ([IO.File]::ReadAllText($errFile)).Trim() }
            }
        }
        catch { $detail = $_.Exception.Message }
        finally { foreach ($temp in @($errFile,$outFile)) { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } } }
        if ($status -ne 'PASS') { $failures++ }
        if ($detail.Length -gt 4000) { $detail = $detail.Substring(0,4000) }
        $csharpRows.Add([pscustomobject]@{File=$source.FullName.Substring($root.Length).TrimStart('\','/');Status=$status;ExitCode=$code;SHA256=(Get-FileHash -LiteralPath $source.FullName -Algorithm SHA256).Hash;Detail=$detail})
    }
    if ($csharpRows.Count -eq 0) { $failures++ }
}
$qualifying = $isNativeWindows51 -and $failures -eq 0
$report=[ordered]@{
    Kind='NativeParser';StartedUtc=$started;EndedUtc=[DateTime]::UtcNow.ToString('o')
    Host=@{Platform=$(if($env:OS -eq 'Windows_NT'){'Windows'}else{'NonWindows'});PSEdition=$edition;PSVersion=$PSVersionTable.PSVersion.ToString()}
    Status=$(if($failures){'FAIL'}else{'PASS'});Files=$rows.ToArray();RegressionFixtures=$fixtureRows.ToArray()
    WorkersRequested=$workersRequested;WorkersParsed=$workersParsed;WorkerFailures=$workerFailures;WorkerSetup=$workerSetup;Workers=$workerRows.ToArray()
    CSharpRequested=[bool]$CompileCSharp;CSharpCompiled=$csharpCompiled;CSharp=$csharpRows.ToArray()
    Windows51Qualification=$qualifying;WorkersExecuted=$false;WpfExecuted=$false;DomainAccessed=$false
    Limitations=@('Parser success does not execute the module loader, application or UI.','PowerShell 7 parsing is not Windows PowerShell 5.1 qualification.','Worker bodies are parsed, never executed: runtime behaviour needs the worker and qualification tests.')
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if($failures -gt 0){exit 1}
if($RequireWindows51 -and -not $qualifying){exit 2}
exit 0
