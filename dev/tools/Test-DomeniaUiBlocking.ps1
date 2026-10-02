#requires -Version 5.1
# D014: static audit of blocking calls reachable from the Dispatcher. Nothing is executed: the PowerShell AST of
# wad\Domenia-Core.ps1 and wad\modules\*.ps1 is read, worker here-strings are plain strings for the parser.
# Roots: script blocks registered as WPF/timer handlers (Add_<Event>, AddHandler, Dispatcher.BeginInvoke),
# surface handlers, and engine callbacks named by -SuccessHandler / -ErrorHandler / -HandlerName / -Handler.
# Each finding is a chain root > function > ... > function holding a blocking call. A reviewed baseline lists
# the findings that are justified or still assigned to another lot; a finding outside it fails the audit.
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$BaselinePath = '',
    [string]$ReportPath = '',
    [string]$CorePath = '',
    [switch]$WriteBaseline,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = [IO.Path]::GetFullPath($Root)
$wad = Join-Path $Root 'wad'
if (-not $BaselinePath) { $BaselinePath = Join-Path $Root 'tools\ui-blocking-baseline.json' }
if (-not $CorePath) { $CorePath = Join-Path $wad 'Domenia-Core.ps1' }

$blockingCommands = @('Start-Sleep','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','Initialize-DomeniaDatabase','Get-FileHash',
    'New-CimSession','Get-CimInstance','Get-WmiObject','Export-Csv','Set-Content','Move-Item','Copy-Item','Import-Module','Test-Connection',
    'Wait-Job','Receive-Job','Invoke-Command')
$blockingMembers = @('WaitOne','WaitAll','WaitAny','Wait','FindAll','FindOne','DoEvents','PushFrame','ReadAllLines','ReadAllText','ReadAllBytes',
    'WriteAllLines','WriteAllText','WriteAllBytes','AppendAllText','CreateFromDirectory','Send','Open','EndInvoke','ExtractToDirectory')
$deferringMembers = @('AddHandler','BeginInvoke','InvokeAsync')
$deferringCommands = @('Register-DomeniaSurfaceReady','Register-DomeniaSurfaceKeys')
$callbackParameters = @('SuccessHandler','ErrorHandler','HandlerName','Handler')

$files = New-Object 'System.Collections.Generic.List[string]'
$files.Add([IO.Path]::GetFullPath($CorePath))
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File | Sort-Object Name)) { $files.Add($f.FullName) }

$functions = @{}
$roots = New-Object 'System.Collections.Generic.List[object]'
$parseErrors = New-Object 'System.Collections.Generic.List[string]'

function Get-UiBlockingRelative {
    param([string]$Path)
    if ($Path.StartsWith($Root,[StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($Root.Length).TrimStart('\','/') }
    return $Path
}

function Test-UiBlockingDeferredBlock {
    # A script block that runs later (handler, dispatcher callback), not during the call that creates it.
    param($Block)
    $parent = $Block.Parent
    if ($null -eq $parent) { return $false }
    if ($parent -is [System.Management.Automation.Language.ConvertExpressionAst]) { return $true }
    if ($parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $member = ''
        try { $member = [string]$parent.Member.Value } catch { }
        if ($member.StartsWith('Add_') -or $member -in $deferringMembers) { return $true }
        if ($member -eq 'Invoke' -and $parent.Expression.Extent.Text -match 'Dispatcher') { return $true }
        return $false
    }
    if ($parent -is [System.Management.Automation.Language.CommandAst]) {
        $name = [string]$parent.GetCommandName()
        if ($name -in $deferringCommands) { return $true }
        # -OnSuccess / -OnError script blocks of Start-UiTask run from Complete-UiTasks, later.
        $elements = @($parent.CommandElements)
        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ([object]::ReferenceEquals($elements[$i],$Block) -and $i -gt 0 -and $elements[$i - 1] -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ([string]$elements[$i - 1].ParameterName -in @('OnSuccess','OnError')) { return $true }
            }
        }
    }
    return $false
}

function Test-UiBlockingDirect {
    # True when $Node belongs to the synchronous body of $Owner (not to a nested function or a deferred block).
    param($Node,$Owner)
    $current = $Node.Parent
    while ($null -ne $current -and -not [object]::ReferenceEquals($current,$Owner)) {
        if ($current -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
        if ($current -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -and (Test-UiBlockingDeferredBlock $current)) { return $false }
        $current = $current.Parent
    }
    return $true
}

function Get-UiBlockingBodyFacts {
    # Direct callees and blocking patterns of one body.
    param($Owner)
    $callees = New-Object 'System.Collections.Generic.List[string]'
    $patterns = New-Object 'System.Collections.Generic.List[object]'
    $body = $Owner
    if ($Owner -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $body = $Owner.Body }
    elseif ($Owner -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $body = $Owner.ScriptBlock }
    foreach ($node in @($body.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -or ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) },$true))) {
        if (-not (Test-UiBlockingDirect $node $Owner)) { continue }
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $name = [string]$node.GetCommandName()
            if (-not $name) { continue }
            if ($name -in $blockingCommands) { $patterns.Add([pscustomobject]@{Pattern=$name;Line=$node.Extent.StartLineNumber}) }
            else { $callees.Add($name) }
        }
        else {
            $member = ''
            try { $member = [string]$node.Member.Value } catch { }
            if ($member -notin $blockingMembers) { continue }
            $memberArgs = @($node.Arguments)
            $target = [string]$node.Expression.Extent.Text
            if ($member -eq 'Send' -and $target -notmatch '(?i)ping') { continue }
            if ($member -eq 'Open' -and $memberArgs.Count -ne 0) { continue }
            if ($member -eq 'EndInvoke' -and $target -notmatch '(?i)powershell|ps\b|shell') { continue }
            $patterns.Add([pscustomobject]@{Pattern=('.' + $member);Line=$node.Extent.StartLineNumber})
        }
    }
    return [pscustomobject]@{Callees=@($callees | Select-Object -Unique);Patterns=$patterns.ToArray()}
}

foreach ($path in $files) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if (@($errors).Count) { $parseErrors.Add((Get-UiBlockingRelative $path) + ' : ' + $errors[0].Message); continue }
    $relative = Get-UiBlockingRelative $path
    foreach ($fn in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] },$true))) {
        $key = ([string]$fn.Name).ToLowerInvariant()
        if ($functions.ContainsKey($key)) { continue }
        $facts = Get-UiBlockingBodyFacts $fn
        $functions[$key] = [pscustomobject]@{Name=[string]$fn.Name;File=$relative;Line=$fn.Extent.StartLineNumber;Callees=$facts.Callees;Patterns=$facts.Patterns}
    }
    foreach ($block in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] },$true))) {
        if (-not (Test-UiBlockingDeferredBlock $block)) { continue }
        $label = $relative + ':' + $block.Extent.StartLineNumber
        $kind = 'bloc'
        $parent = $block.Parent
        if ($parent -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) { $kind = [string]$parent.Member.Value; $label += ' ' + ($parent.Expression.Extent.Text -replace '\s+',' ') + '.' + $kind }
        elseif ($parent -is [System.Management.Automation.Language.CommandAst]) { $kind = [string]$parent.GetCommandName(); $label += ' ' + $kind }
        # Stable owner for a pattern written directly in a handler (line numbers move with every edit).
        $owner = '<' + $kind + '@' + ($relative -replace '\\','/') + '>'
        $facts = Get-UiBlockingBodyFacts $block
        $roots.Add([pscustomobject]@{Label=$label;Owner=$owner;Callees=$facts.Callees;Patterns=$facts.Patterns})
    }
    foreach ($command in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] },$true))) {
        $elements = @($command.CommandElements)
        for ($i = 0; $i -lt $elements.Count - 1; $i++) {
            if ($elements[$i] -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ([string]$elements[$i].ParameterName -notin $callbackParameters) { continue }
            $value = $elements[$i + 1]
            if ($value -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$value.Value) {
                $roots.Add([pscustomobject]@{Label=('callback ' + [string]$value.Value + ' (' + $relative + ':' + $command.Extent.StartLineNumber + ')');Owner='';Callees=@([string]$value.Value);Patterns=@()})
            }
        }
    }
}

# Breadth-first walk from every root: the first (shortest) chain of each finding is kept.
$findings = @{}
foreach ($rootItem in $roots) {
    $visited = @{}
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    foreach ($p in @($rootItem.Patterns)) {
        $key = [string]$rootItem.Owner + '|' + $p.Pattern
        if (-not $findings.ContainsKey($key)) { $findings[$key] = [pscustomobject]@{Function=[string]$rootItem.Owner;Pattern=$p.Pattern;Chain=$rootItem.Label;Line=$p.Line;File='';Roots=0} }
        $findings[$key].Roots = [int]$findings[$key].Roots + 1
    }
    foreach ($callee in @($rootItem.Callees)) { $queue.Enqueue([pscustomobject]@{Name=[string]$callee;Chain=($rootItem.Label + ' > ' + $callee);Depth=1}) }
    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $fkey = ([string]$item.Name).ToLowerInvariant()
        if ($visited.ContainsKey($fkey) -or -not $functions.ContainsKey($fkey)) { continue }
        $visited[$fkey] = $true
        $fn = $functions[$fkey]
        foreach ($p in @($fn.Patterns)) {
            $key = $fn.Name + '|' + $p.Pattern
            if (-not $findings.ContainsKey($key)) { $findings[$key] = [pscustomobject]@{Function=$fn.Name;Pattern=$p.Pattern;Chain=[string]$item.Chain;Line=$p.Line;File=$fn.File;Roots=0} }
            $findings[$key].Roots = [int]$findings[$key].Roots + 1
        }
        if ([int]$item.Depth -ge 14) { continue }
        foreach ($callee in @($fn.Callees)) { $queue.Enqueue([pscustomobject]@{Name=[string]$callee;Chain=([string]$item.Chain + ' > ' + $callee);Depth=([int]$item.Depth + 1)}) }
    }
}

$baseline = @{}
if ([IO.File]::Exists($BaselinePath)) {
    $parsed = Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($entry in @($parsed.Entries | ForEach-Object { $_ })) {
        if ($null -eq $entry) { continue }
        $baseline[([string]$entry.Function + '|' + [string]$entry.Pattern).ToLowerInvariant()] = $entry
    }
}
$current = @($findings.Values | Sort-Object Function,Pattern)
$new = @($current | Where-Object { -not $baseline.ContainsKey(([string]$_.Function + '|' + [string]$_.Pattern).ToLowerInvariant()) })
$seen = @{}
foreach ($f in $current) { $seen[([string]$f.Function + '|' + [string]$f.Pattern).ToLowerInvariant()] = $true }
$stale = @($baseline.Keys | Where-Object { -not $seen.ContainsKey($_) } | Sort-Object)

if ($WriteBaseline) {
    $entries = foreach ($f in $current) {
        $known = $baseline[([string]$f.Function + '|' + [string]$f.Pattern).ToLowerInvariant()]
        $reason = 'A justifier'; $status = 'AFaire'; $owner = ''
        if ($null -ne $known) { $reason = [string]$known.Reason; $status = [string]$known.Status; $owner = [string]$known.Owner }
        [ordered]@{Function=$f.Function;Pattern=$f.Pattern;Status=$status;Owner=$owner;Reason=$reason;Chain=$f.Chain}
    }
    $document = [ordered]@{Schema='DomeniaUiBlockingBaseline/1';Generated=(Get-Date).ToUniversalTime().ToString('o');Entries=@($entries)}
    [IO.File]::WriteAllText($BaselinePath,($document | ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
}

$tests = New-Object 'System.Collections.Generic.List[object]'
$tests.Add([pscustomobject]@{Name='Analyse syntaxique des sources';Status=$(if($parseErrors.Count){'Failed'}else{'Passed'});Detail=($parseErrors.ToArray() -join ' | ')})
$tests.Add([pscustomobject]@{Name='Racines trouvees (gestionnaires et rappels)';Status=$(if($roots.Count -gt 50){'Passed'}else{'Failed'});Detail=([string]$roots.Count + ' racine(s)')})
foreach ($f in $new) { $tests.Add([pscustomobject]@{Name=('Attente hors ligne de base : ' + $f.Function + ' ' + $f.Pattern);Status='Failed';Detail=$f.Chain}) }
$tests.Add([pscustomobject]@{Name='Aucune attente nouvelle atteignable depuis le Dispatcher';Status=$(if($new.Count){'Failed'}else{'Passed'});Detail=([string]$current.Count + ' constat(s), ' + $new.Count + ' hors ligne de base, ' + $stale.Count + ' entree(s) de base sans constat')})
$failed = @($tests | Where-Object { $_.Status -eq 'Failed' }).Count
$report = [ordered]@{Kind='UiBlockingAudit';Static=$true;Executed=$false;Roots=$roots.Count;Functions=$functions.Count;Findings=$current;New=$new;Stale=$stale;Passed=(@($tests | Where-Object { $_.Status -eq 'Passed' }).Count);Failed=$failed;Tests=$tests.ToArray()}
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-uiblocking-' + [guid]::NewGuid().ToString('N') + '.json') }
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report | ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
if (-not $Quiet) {
    Write-Host ('Audit D014 : ' + $current.Count + ' constat(s), ' + $new.Count + ' nouveau(x), ' + $stale.Count + ' obsolete(s). Rapport : ' + $ReportPath)
    foreach ($f in $new) { Write-Host ('  NOUVEAU ' + $f.Function + ' ' + $f.Pattern + ' : ' + $f.Chain) }
}
if ($failed -gt 0) { exit 1 }
exit 0
