#requires -Version 5.1
# Static Windows PowerShell 5.1 compatibility gate. No script is executed, no network, no domain.
# Under Windows PowerShell 5.1 the native parser itself rejects 6/7-only syntax.
# Under a newer engine the same constructs are found in the AST, so a preparation host
# cannot let them through. This is a source check: it does not replace a real 5.1 run.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$ReportPath = '',
    [switch]$IncludeHistory,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$rootPath = [IO.Path]::GetFullPath($Root)
$findings = New-Object 'System.Collections.Generic.List[object]'
function Add-Finding {
    param([string]$File,[int]$Line,[string]$Rule,[string]$Severity,[string]$Detail)
    $findings.Add([pscustomobject]@{File=$File;Line=$Line;Rule=$Rule;Severity=$Severity;Detail=$Detail})
}
# AST node types that only exist in PowerShell 6/7.
$forbiddenAst = @{
    'TernaryExpressionAst' = 'Operateur ternaire (PowerShell 7).'
    'PipelineChainAst'     = 'Chainage && / || (PowerShell 7).'
}
$forbiddenVariables = @('IsWindows','IsLinux','IsMacOS','IsCoreCLR','PSStyle','PSNativeCommandArgumentPassing','PSNativeCommandUseErrorActionPreference','EnabledExperimentalFeatures')
$missingCommands = @('Join-String','Test-Json','Get-Error','Start-ThreadJob','ConvertFrom-Markdown','Show-Markdown','Remove-Service','Get-Uptime','Remove-Alias','Get-SecureRandom','Get-ExperimentalFeature','Switch-Process')
$forbiddenParameters = @{
    'ForEach-Object'    = @('Parallel','ThrottleLimit','AsJob')
    'ConvertFrom-Json'  = @('AsHashtable','Depth','NoEnumerate')
    'ConvertTo-Json'    = @('AsArray','EscapeHandling','EnumsAsStrings')
    'Get-Content'       = @('AsByteStream')
    'Set-Content'       = @('AsByteStream')
    'Add-Content'       = @('AsByteStream')
    'Select-String'     = @('Raw','NoEmphasis','Culture')
    'Sort-Object'       = @('Top','Bottom','Stable')
    'Split-Path'        = @('LeafBase','Extension')
    'Join-Path'         = @('AdditionalChildPath')
    'Get-Date'          = @('AsUTC','UnixTimeSeconds')
    'Export-Csv'        = @('UseQuotes','QuoteFields','IncludeTypeInformation')
    'ConvertTo-Csv'     = @('UseQuotes','QuoteFields','IncludeTypeInformation')
    'Invoke-WebRequest' = @('SkipCertificateCheck','SslProtocol','Authentication','Token','AllowUnencryptedAuthentication','SkipHttpErrorCheck','StatusCodeVariable','MaximumRetryCount','RetryIntervalSec','Form','NoProxy','HttpVersion','Resume')
    'Invoke-RestMethod' = @('SkipCertificateCheck','SslProtocol','Authentication','Token','AllowUnencryptedAuthentication','SkipHttpErrorCheck','StatusCodeVariable','ResponseHeadersVariable','MaximumRetryCount','RetryIntervalSec','Form','NoProxy','HttpVersion','Resume')
    'Test-Connection'   = @('TargetName','IPv4','IPv6','Ping','Traceroute','MtuSize','TcpPort','MaxHops','Repeat','TimeoutSeconds')
    'Measure-Object'    = @('AllStats','StandardDeviation')
    'Where-Object'      = @('Not')
    'Get-ChildItem'     = @('FollowSymlink')
    'Start-Job'         = @('WorkingDirectory')
}
$forbiddenEncodings = @('utf8NoBOM','utf8BOM','ansi')
# Static members absent from .NET Framework 4.x (name matched on the member, type shown for context).
$forbiddenStatic = @{
    'Clamp'='[Math]::Clamp';'GetRelativePath'='[IO.Path]::GetRelativePath';'ToHexString'='[Convert]::ToHexString';'FromHexString'='[Convert]::FromHexString'
    'HashData'='::HashData';'ThrowIfNull'='::ThrowIfNull';'ThrowIfNullOrEmpty'='::ThrowIfNullOrEmpty';'IsWindows'='[OperatingSystem]::IsWindows'
    'CreateVersion7'='[Guid]::CreateVersion7';'TrimEndingDirectorySeparator'='[IO.Path]::TrimEndingDirectorySeparator';'EndsInDirectorySeparator'='[IO.Path]::EndsInDirectorySeparator'
    'ReadAllTextAsync'='[IO.File]::*Async';'WriteAllTextAsync'='[IO.File]::*Async';'ReadAllBytesAsync'='[IO.File]::*Async';'WriteAllBytesAsync'='[IO.File]::*Async'
}
$forbiddenStaticProperties = @{'ProcessPath'='[Environment]::ProcessPath';'ProcessId'='[Environment]::ProcessId';'UnixEpoch'='[DateTime]::UnixEpoch';'Shared'='[Random]::Shared';'Latin1'='[Text.Encoding]::Latin1'}
$forbiddenInstance = @('ReplaceLineEndings','AsSpan','EnumerateRunes','DistinctBy','MaxBy','MinBy','TakeLast','SkipLast','Chunk')
$forbiddenTypes = @('System.Text.Json','Text.Json','System.Index','System.Range','System.HashCode','System.Half','System.DateOnly','System.TimeOnly','System.Text.Rune',
    'Collections.Generic.PriorityQueue','System.Collections.Immutable','Collections.Immutable','System.Threading.Channels','Threading.Channels','Runtime.InteropServices.NativeLibrary','System.Formats')
$files = @(Get-ChildItem -LiteralPath $rootPath -Recurse -File | Where-Object { $_.Extension -in '.ps1','.psm1','.psd1' })
if (-not $IncludeHistory) { $files = @($files | Where-Object { $_.FullName -notmatch '[\\/]docs[\\/]history[\\/]' }) }
if ($files.Count -eq 0) { throw 'Aucune source PowerShell trouvee.' }
foreach ($file in $files) {
    $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\','/').Replace('\','/')
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $nonAscii = $false
    foreach ($b in $bytes) { if ($b -gt 127) { $nonAscii = $true; break } }
    # Windows PowerShell 5.1 reads a BOM-less file with the ANSI code page: accents become mojibake.
    if ($nonAscii -and -not $hasBom) { Add-Finding $relative 1 'Encoding.NoBomNonAscii' 'Error' 'Caracteres non ASCII sans BOM UTF-8 : lu en ANSI par Windows PowerShell 5.1.' }
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach ($e in @($errors)) { Add-Finding $relative $e.Extent.StartLineNumber 'Parser' 'Error' ([string]$e.Message) }
    if (@($errors).Count -gt 0) { continue }
    $suppressed = @{}
    foreach ($t in @($tokens)) {
        if ([string]$t.Kind -eq 'Comment' -and [string]$t.Text -match 'ps51-ok') { $suppressed[[int]$t.Extent.StartLineNumber] = $true }
        if ([string]$t.Kind -in @('QuestionQuestion','QuestionQuestionEquals','QuestionDot','QuestionLBracket')) {
            Add-Finding $relative $t.Extent.StartLineNumber 'Syntax.NullOperators' 'Error' ('Operateur ' + $t.Text + ' reserve a PowerShell 7.')
        }
    }
    if ($null -ne $ast.ScriptRequirements -and $null -ne $ast.ScriptRequirements.RequiredPSVersion) {
        $required = $ast.ScriptRequirements.RequiredPSVersion
        if ($required.Major -gt 5 -or ($required.Major -eq 5 -and $required.Minor -gt 1)) { Add-Finding $relative 1 'Requires.Version' 'Error' ('#requires -Version ' + $required + ' depasse 5.1.') }
    }
    $assigned = @{}
    foreach ($assignment in @($ast.FindAll({ param($n) $n.GetType().Name -eq 'AssignmentStatementAst' }, $true))) {
        $left = $assignment.Left
        if ($left.GetType().Name -eq 'VariableExpressionAst') { $assigned[[string]$left.VariablePath.UserPath] = $true }
    }
    foreach ($node in @($ast.FindAll({ param($n) $true }, $true))) {
        $line = [int]$node.Extent.StartLineNumber
        if ($suppressed.ContainsKey($line)) { continue }
        $typeName = $node.GetType().Name
        if ($forbiddenAst.ContainsKey($typeName)) { Add-Finding $relative $line ('Syntax.' + $typeName) 'Error' $forbiddenAst[$typeName]; continue }
        switch ($typeName) {
            'PipelineAst' {
                $background = $node.PSObject.Properties['Background']
                if ($null -ne $background -and [bool]$background.Value) { Add-Finding $relative $line 'Syntax.Background' 'Error' 'Operateur & de tache de fond (PowerShell 6+).' }
            }
            'VariableExpressionAst' {
                $name = [string]$node.VariablePath.UserPath
                if ($forbiddenVariables -contains $name -and -not $assigned.ContainsKey($name)) { Add-Finding $relative $line 'Variable.CoreOnly' 'Error' ('$' + $name + ' n existe pas sous Windows PowerShell 5.1.') }
            }
            'CommandAst' {
                $command = [string]$node.GetCommandName()
                if (-not $command) { break }
                if ($missingCommands -contains $command) { Add-Finding $relative $line 'Command.Missing' 'Error' ($command + ' absent de Windows PowerShell 5.1.') }
                $elements = @($node.CommandElements)
                for ($i = 0; $i -lt $elements.Count; $i++) {
                    $element = $elements[$i]
                    if ($element.GetType().Name -ne 'CommandParameterAst') { continue }
                    $parameter = [string]$element.ParameterName
                    if ($forbiddenParameters.ContainsKey($command)) {
                        foreach ($bad in $forbiddenParameters[$command]) {
                            # Exact name only: -Leaf is valid in 5.1 although it is a prefix of -LeafBase.
                            if ($parameter -ieq $bad) {
                                Add-Finding $relative $line 'Parameter.CoreOnly' 'Error' ($command + ' -' + $bad + ' absent de Windows PowerShell 5.1.')
                            }
                        }
                    }
                    if ('Encoding'.StartsWith($parameter,[StringComparison]::OrdinalIgnoreCase) -and $parameter.Length -ge 3) {
                        $value = ''
                        if ($null -ne $element.Argument) { $value = [string]$element.Argument.Extent.Text }
                        elseif ($i + 1 -lt $elements.Count) { $value = [string]$elements[$i + 1].Extent.Text }
                        $value = $value.Trim("'",'"')
                        if ($forbiddenEncodings -contains $value) { Add-Finding $relative $line 'Parameter.Encoding' 'Error' ('-Encoding ' + $value + ' absent de Windows PowerShell 5.1.') }
                    }
                }
            }
            'BinaryExpressionAst' {
                if ([string]$node.Operator -match '^(I|C)?replace$') {
                    $right = $node.Right
                    if ($right.GetType().Name -eq 'ArrayLiteralAst' -and @($right.Elements).Count -ge 2 -and $right.Elements[1].GetType().Name -eq 'ScriptBlockExpressionAst') {
                        Add-Finding $relative $line 'Operator.ReplaceScriptBlock' 'Error' '-replace avec bloc de script (PowerShell 6+).'
                    }
                }
            }
            'InvokeMemberExpressionAst' {
                $member = ''
                if ($node.Member.GetType().Name -eq 'StringConstantExpressionAst') { $member = [string]$node.Member.Value }
                if (-not $member) { break }
                $arguments = @($node.Arguments)
                if ([bool]$node.Static -and $forbiddenStatic.ContainsKey($member)) { Add-Finding $relative $line 'Api.CoreOnly' 'Error' ($forbiddenStatic[$member] + ' absent de .NET Framework 4.x.') }
                if (-not [bool]$node.Static -and $forbiddenInstance -contains $member) { Add-Finding $relative $line 'Api.CoreOnly' 'Error' ('.' + $member + '() absent de .NET Framework 4.x.') }
                if ($member -in @('Contains','Replace','IndexOf') -and $arguments.Count -ge 2) {
                    $last = [string]$arguments[$arguments.Count - 1].Extent.Text
                    if ($member -eq 'Contains' -and $last -match 'StringComparison') { Add-Finding $relative $line 'Api.StringComparisonOverload' 'Error' '.Contains(valeur, StringComparison) absent de .NET Framework 4.x.' }
                    if ($member -eq 'Replace' -and $arguments.Count -eq 3 -and $last -match 'StringComparison') { Add-Finding $relative $line 'Api.StringComparisonOverload' 'Error' '.Replace(a, b, StringComparison) absent de .NET Framework 4.x.' }
                }
                if ($member -eq 'Split' -and $arguments.Count -eq 1 -and $arguments[0].GetType().Name -eq 'StringConstantExpressionAst' -and ([string]$arguments[0].Value).Length -gt 1) {
                    Add-Finding $relative $line 'Api.SplitSemantics' 'Warning' '.Split(chaine) : decoupe par caractere sous .NET Framework, par chaine sous .NET moderne. Preferer -split.'
                }
                if ($member -eq 'Move' -and [bool]$node.Static -and $arguments.Count -eq 3 -and [string]$node.Expression.Extent.Text -match 'File\]$') {
                    Add-Finding $relative $line 'Api.CoreOnly' 'Error' '[IO.File]::Move(a, b, overwrite) absent de .NET Framework 4.x.'
                }
            }
            'MemberExpressionAst' {
                if ([bool]$node.Static -and $node.Member.GetType().Name -eq 'StringConstantExpressionAst') {
                    $member = [string]$node.Member.Value
                    if ($forbiddenStaticProperties.ContainsKey($member)) {
                        $target = [string]$node.Expression.Extent.Text
                        if (($member -eq 'ProcessPath' -or $member -eq 'ProcessId') -and $target -notmatch 'Environment') { break }
                        if ($member -eq 'UnixEpoch' -and $target -notmatch 'DateTime') { break }
                        if ($member -eq 'Shared' -and $target -notmatch 'Random') { break }
                        if ($member -eq 'Latin1' -and $target -notmatch 'Encoding') { break }
                        Add-Finding $relative $line 'Api.CoreOnly' 'Error' ($forbiddenStaticProperties[$member] + ' absent de .NET Framework 4.x.')
                    }
                }
            }
            'TypeExpressionAst' {
                $full = [string]$node.TypeName.FullName
                foreach ($bad in $forbiddenTypes) {
                    # Whole type name, or a namespace prefix followed by a dot or a generic bracket.
                    if ($full -match ('(^|\.)' + [regex]::Escape($bad) + '($|[.\[`])') -or $full -ieq $bad) { Add-Finding $relative $line 'Type.CoreOnly' 'Error' ('[' + $full + '] absent de .NET Framework 4.x.'); break }
                }
            }
        }
    }
}
$errorCount = @($findings | Where-Object { $_.Severity -eq 'Error' }).Count
$warningCount = @($findings | Where-Object { $_.Severity -eq 'Warning' }).Count
$edition = if ($PSVersionTable.ContainsKey('PSEdition')) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }
$report = [ordered]@{
    Kind = 'Ps51StaticCompatibility'
    Host = @{ PSEdition = $edition; PSVersion = $PSVersionTable.PSVersion.ToString(); Platform = $(if ($env:OS -eq 'Windows_NT') { 'Windows' } else { 'NonWindows' }) }
    Files = $files.Count; Errors = $errorCount; Warnings = $warningCount
    Status = $(if ($errorCount) { 'FAIL' } else { 'PASS' })
    Limitation = 'Controle de source. Ne remplace pas une execution sous Windows PowerShell 5.1.'
    Findings = $findings.ToArray()
}
if ($ReportPath) { [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false))) }
if (-not $Quiet) {
    Write-Host ('Compatibilite 5.1 : ' + $files.Count + ' fichiers, ' + $errorCount + ' erreur(s), ' + $warningCount + ' avertissement(s).')
    $findings | Where-Object { $_.Severity -eq 'Error' } | Select-Object -First 40 | ForEach-Object { Write-Host ('  ' + $_.File + ':' + $_.Line + ' [' + $_.Rule + '] ' + $_.Detail) }
}
if ($errorCount) { exit 1 }
exit 0
