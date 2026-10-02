#requires -Version 5.1
# D014 : static audit of blocking calls reachable from UI event handlers (Dispatcher thread), measured-debt
# catalogue. The reviewed gate of the release is tools/Test-DomeniaUiBlocking.ps1 (engine callbacks included).
# Native AST of Windows PowerShell 5.1 only: no script is executed, no network, no domain, no write except the
# report and, on explicit request, the baseline. Worker here-strings are plain text for the parser: the code they
# carry runs in worker runspaces, outside the Dispatcher, and is therefore never analysed as UI code.
#
# Roots      : .Add_<Event>(handler) (Click, Tick of DispatcherTimer, KeyDown...), .AddHandler(event, handler),
#              <...>.Dispatcher.Invoke/BeginInvoke/InvokeAsync(handler). A handler is an inline script block, a cast
#              script block, a variable or hashtable entry assigned in the same function, a parameter of a
#              registration helper (resolved at each call site), or a [scriptblock]::Create text (constant parts).
# Graph      : calls to functions defined in wad/Domenia-Core.ps1 and wad/modules/*.ps1, transitively (shortest chain).
#              A function defined twice is followed through every definition. A script block registered as a
#              handler inside a function body belongs to that handler, not to the function that registers it.
# Blocking   : network (LDAP FindAll/FindOne/RefreshCache/CommitChanges, CIM/WMI, DNS, ping, AD cmdlets...),
#              waits (WaitOne, Wait, WaitAll, Start-Sleep, Wait-Job; EndInvoke as a heuristic), synchronous SQLite
#              (Invoke-DomeniaDbExec, Invoke-DomeniaDbQuery, Open-DomeniaDatabase, sqlite3_exec/step/open/prepare,
#              backup API sqlite3_backup_init/step/finish, sqlite3_close), disk reads (Get-FileHash, ReadAll* as a
#              heuristic for large files) and disk writes (exports, archives, ZipFile, Add-Content, Set-Content,
#              Out-File, Copy/Move/Remove/Rename-Item, Clear-Content, [IO.File]::Write*/Append*/Copy/Move/Delete/
#              Replace, [IO.Directory]::Delete/Move; writes whose cost depends on size or medium are heuristics).
# Baseline   : tools/ui-blocking-debt-baseline.json holds the measured debt as a multiset of stable keys
#              (handler | blocking site | call), without line numbers. A NEW occurrence fails (exit 1); a removed
#              occurrence is reported and accepted. -UpdateBaseline rewrites the baseline after review.
# Exit codes : 0 no new occurrence, 1 new occurrence (or no baseline), 2 audit impossible (parse error, missing source).
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$ReportPath = '',
    [string]$BaselinePath = '',
    [switch]$UpdateBaseline,
    [switch]$SelfTest,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:UiBlockSeverity = @{ Reseau = 1; Attente = 2; Stockage = 3; Disque = 4 }
$script:UiBlockCategoryText = @{ Reseau = 'appel reseau'; Attente = 'attente'; Stockage = 'SQLite synchrone'; Disque = 'disque' }
# Commands: canonical name -> category, heuristic flag.
$script:UiBlockCommands = @{
    'Get-CimInstance'=@('Reseau',$false);'Get-CimAssociatedInstance'=@('Reseau',$false);'Invoke-CimMethod'=@('Reseau',$false);'New-CimSession'=@('Reseau',$false)
    'Set-CimInstance'=@('Reseau',$false);'Remove-CimInstance'=@('Reseau',$false);'New-CimInstance'=@('Reseau',$false)
    'Get-WmiObject'=@('Reseau',$false);'Invoke-WmiMethod'=@('Reseau',$false);'Set-WmiInstance'=@('Reseau',$false);'Remove-WmiObject'=@('Reseau',$false)
    'Test-Connection'=@('Reseau',$false);'Test-NetConnection'=@('Reseau',$false);'Resolve-DnsName'=@('Reseau',$false);'Test-WSMan'=@('Reseau',$false)
    'Invoke-Command'=@('Reseau',$false);'New-PSSession'=@('Reseau',$false);'Enter-PSSession'=@('Reseau',$false)
    'Invoke-WebRequest'=@('Reseau',$false);'Invoke-RestMethod'=@('Reseau',$false)
    'Start-Sleep'=@('Attente',$false);'Wait-Job'=@('Attente',$false);'Wait-Process'=@('Attente',$false);'Wait-Event'=@('Attente',$false)
    'Invoke-DomeniaDbExec'=@('Stockage',$false);'Invoke-DomeniaDbQuery'=@('Stockage',$false);'Open-DomeniaDatabase'=@('Stockage',$false)
    'Get-FileHash'=@('Disque',$false);'Export-Csv'=@('Disque',$false);'Export-Clixml'=@('Disque',$false);'Compress-Archive'=@('Disque',$false);'Expand-Archive'=@('Disque',$false)
    # Synchronous disk writes: the time depends on the size and on the medium (local disk, profile on a share,
    # locked file), hence heuristic. Remove-Item and Copy-Item with -Recurse are certain (see Get-DomeniaUiBlockCommandRule).
    'Add-Content'=@('Disque',$true);'Set-Content'=@('Disque',$true);'Out-File'=@('Disque',$true);'Clear-Content'=@('Disque',$true)
    'Copy-Item'=@('Disque',$true);'Move-Item'=@('Disque',$true);'Remove-Item'=@('Disque',$true);'Rename-Item'=@('Disque',$true)
}
# Commands of the catalogue that act on a provider path: a constant non-file path (Variable:, Function:, Env:,
# Alias:, registry, certificates, WSMan) is not a disk access.
$script:UiBlockPathCommands = @('Add-Content','Set-Content','Out-File','Clear-Content','Copy-Item','Move-Item','Remove-Item','Rename-Item')
$script:UiBlockNonFilePath = '^(?i)(variable|function|env|alias|cert|wsman|hklm|hkcu|registry)::?'
# ActiveDirectory module cmdlets (Get-ADUser, Set-ADObject...). A function defined in Domenia with such a name wins.
$script:UiBlockAdCmdlet = '^(?i)(Get|Set|New|Remove|Add|Search|Unlock|Enable|Disable|Move|Rename|Clear|Reset|Sync)-AD[A-Z][a-z]'
# Methods: member -> category, heuristic flag, condition.
#   NoArgs   DirectorySearcher.FindAll()/FindOne() take no argument (AST FindAll(predicate, bool) and List.FindAll(match) do).
#   Instance / Static   receiver kind.   Dns / Sqlite / FileSystem / Zip   receiver text must name the type
#   ([Net.Dns], [Domenia.WinSqliteNative], [IO.File] or [IO.Directory], [IO.Compression.ZipFile]).
#   Args   at least one argument.
$script:UiBlockMethods = @{
    'WaitOne'=@('Attente',$false,'Any');'Wait'=@('Attente',$false,'Instance');'WaitAll'=@('Attente',$false,'Static');'WaitAny'=@('Attente',$false,'Static')
    'EndInvoke'=@('Attente',$true,'Instance')
    'FindAll'=@('Reseau',$false,'NoArgs');'FindOne'=@('Reseau',$false,'NoArgs');'RefreshCache'=@('Reseau',$false,'Instance');'CommitChanges'=@('Reseau',$false,'Instance')
    'Send'=@('Reseau',$true,'Args');'Connect'=@('Reseau',$true,'Args')
    'GetHostEntry'=@('Reseau',$false,'Dns');'GetHostAddresses'=@('Reseau',$false,'Dns');'GetHostByName'=@('Reseau',$false,'Dns');'GetHostByAddress'=@('Reseau',$false,'Dns');'Resolve'=@('Reseau',$false,'Dns')
    'GetResponse'=@('Reseau',$false,'Instance');'DownloadString'=@('Reseau',$false,'Instance');'DownloadFile'=@('Reseau',$false,'Instance');'DownloadData'=@('Reseau',$false,'Instance');'UploadString'=@('Reseau',$false,'Instance');'UploadData'=@('Reseau',$false,'Instance')
    'ReadAllBytes'=@('Disque',$true,'Static');'ReadAllText'=@('Disque',$true,'Static');'ReadAllLines'=@('Disque',$true,'Static')
    'sqlite3_exec'=@('Stockage',$false,'Sqlite');'sqlite3_step'=@('Stockage',$false,'Sqlite');'sqlite3_open'=@('Stockage',$false,'Sqlite');'sqlite3_open_v2'=@('Stockage',$false,'Sqlite');'sqlite3_prepare_v2'=@('Stockage',$false,'Sqlite')
    # SQLite online backup (a step loop that waits on a locked database) and close (may checkpoint the journal).
    'sqlite3_backup_init'=@('Stockage',$false,'Sqlite');'sqlite3_backup_step'=@('Stockage',$false,'Sqlite');'sqlite3_backup_finish'=@('Stockage',$false,'Sqlite');'sqlite3_close'=@('Stockage',$false,'Sqlite');'sqlite3_close_v2'=@('Stockage',$false,'Sqlite')
    # Synchronous disk writes through .NET (heuristic: size and medium), whole-directory archives (certain).
    'AppendAllText'=@('Disque',$true,'FileSystem');'AppendAllLines'=@('Disque',$true,'FileSystem');'WriteAllText'=@('Disque',$true,'FileSystem');'WriteAllBytes'=@('Disque',$true,'FileSystem');'WriteAllLines'=@('Disque',$true,'FileSystem')
    'Copy'=@('Disque',$true,'FileSystem');'Move'=@('Disque',$true,'FileSystem');'Delete'=@('Disque',$true,'FileSystem');'Replace'=@('Disque',$true,'FileSystem')
    'CreateFromDirectory'=@('Disque',$false,'Zip');'ExtractToDirectory'=@('Disque',$false,'Zip')
}
# Case-insensitive name -> canonical name (the catalogue keys keep their documented casing in labels).
$script:UiBlockCommandIndex = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($script:UiBlockCommands.Keys)) { $script:UiBlockCommandIndex[$name] = $name }
$script:UiBlockMethodIndex = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @($script:UiBlockMethods.Keys)) { $script:UiBlockMethodIndex[$name] = $name }
$script:UiBlockLimitations = @(
    'Analyse statique : un appel atteignable n est pas forcement execute (branches, conditions IsCompleted, CheckAccess).',
    'Les here-strings de workers sont du texte : leur code tourne hors Dispatcher et n est pas analyse.',
    'Appels dynamiques non suivis : & $variable vers un bloc venu d ailleurs, Invoke-Expression, noms de fonction calcules.',
    'Une fonction definie deux fois est suivie dans chaque definition (l ordre de chargement n est pas modelise).',
    'Heuristiques signalees (Heuristic=true) : EndInvoke, Send, Connect, ReadAll* et les ecritures disque (Add-Content, Set-Content, Out-File, Copy/Move/Remove/Rename-Item, [IO.File]::Write*/Append*/Copy/Move/Delete/Replace) dependent du recepteur, de la taille reelle ou du support ; elles comptent dans la ligne de base comme les autres.',
    'Non catalogues : lectures de metadonnees (Test-Path, Get-Item, Get-ChildItem, Exists), creation de dossier (New-Item, CreateDirectory), flux ouverts par [IO.File]::Open puis lus ou ecrits par methodes d instance (Read, Write, Flush), FileInfo.Delete et autres appels d instance sur des fichiers.',
    'Un bloc passe en argument et execute plus tard (ex. -Action d un element de menu range dans Tag) est rattache a la fonction qui le passe : l evenement affiche peut etre celui qui construit le menu, l appel reste sur le Dispatcher.',
    'Les commandes lancees par leur nom dans un runspace (AddCommand(texte)) tournent hors Dispatcher et ne sont pas suivies.',
    'Le critere D014 (clavier, navigation et annulation libres pendant un stockage verrouille ou une lecture lente) exige de deplacer ces appels hors du Dispatcher ; cet audit mesure et gele la dette, il ne la resorbe pas.'
)

# ---------------------------------------------------------------- AST helpers
function Get-DomeniaUiBlockText {
    param($Node,[int]$Maximum=120)
    if ($null -eq $Node) { return '' }
    $text = ([string]$Node.Extent.Text -replace '\s+',' ').Trim()
    if ($text.Length -gt $Maximum) { $text = $text.Substring(0,$Maximum - 3) + '...' }
    return $text
}

function Get-DomeniaUiBlockVarName {
    # Variable name without scope qualifier, lower-case.
    param($VariableAst)
    $path = [string]$VariableAst.VariablePath.UserPath
    return ($path -replace '^(?i)(script|global|local|private):','').ToLowerInvariant()
}

function Test-DomeniaUiBlockScopedVar {
    param($VariableAst)
    return ([string]$VariableAst.VariablePath.UserPath -match '^(?i)(script|global):')
}

function Get-DomeniaUiBlockScope {
    # Nearest enclosing function definition, or $null for script level.
    param($Node)
    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [Management.Automation.Language.FunctionDefinitionAst]) { return $cursor }
        $cursor = $cursor.Parent
    }
    return $null
}

function Get-DomeniaUiBlockMemberName {
    param($MemberAst)
    if ($MemberAst.Member -is [Management.Automation.Language.StringConstantExpressionAst]) { return [string]$MemberAst.Member.Value }
    return ''
}

function Get-DomeniaUiBlockArguments {
    param($InvokeAst)
    if ($null -eq $InvokeAst.Arguments) { return @() }
    return @($InvokeAst.Arguments)
}

function Get-DomeniaUiBlockFunctionParameters {
    # Ordered parameter descriptors of a function: Name (lower), Switch, Position among non-switch parameters.
    param($FunctionAst)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $parameters = @()
    if ($null -ne $FunctionAst.Parameters) { $parameters = @($FunctionAst.Parameters) }
    elseif ($null -ne $FunctionAst.Body.ParamBlock) { $parameters = @($FunctionAst.Body.ParamBlock.Parameters) }
    $position = 0
    foreach ($parameter in $parameters) {
        $isSwitch = ($parameter.StaticType -eq [switch] -or $parameter.StaticType -eq [Management.Automation.SwitchParameter])
        $index = -1
        if (-not $isSwitch) { $index = $position; $position++ }
        $list.Add([pscustomobject]@{ Name = (Get-DomeniaUiBlockVarName $parameter.Name); Switch = $isSwitch; Position = $index })
    }
    return $list.ToArray()
}

# ---------------------------------------------------------------- sources
function New-DomeniaUiBlockUnit {
    # One parsed source. -Text parses in memory (self-test); -Path parses a file.
    param([Parameter(Mandatory=$true)][string]$Name,[string]$Path='',[string]$Text=$null)
    $tokens = $null; $errors = $null
    if ($Path) { $ast = [Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors) }
    else { $ast = [Management.Automation.Language.Parser]::ParseInput([string]$Text,[ref]$tokens,[ref]$errors) }
    $messages = @(@($errors) | Where-Object { $null -ne $_ } | ForEach-Object { 'ligne ' + $_.Extent.StartLineNumber + ' : ' + $_.Message })
    return [pscustomobject]@{ Name = $Name; Ast = $ast; Errors = $messages; Synthetic = $false }
}

function Get-DomeniaUiBlockSources {
    param([Parameter(Mandatory=$true)][string]$DevRoot)
    $wad = Join-Path $DevRoot 'wad'
    $files = New-Object 'System.Collections.Generic.List[object]'
    $core = Join-Path $wad 'Domenia-Core.ps1'
    if (-not [IO.File]::Exists($core)) { throw ('Source absente : ' + $core) }
    $files.Add([pscustomobject]@{ Name = 'wad/Domenia-Core.ps1'; Path = $core })
    $modules = Join-Path $wad 'modules'
    if ([IO.Directory]::Exists($modules)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $modules -Filter '*.ps1' -File | Sort-Object Name)) {
            $files.Add([pscustomobject]@{ Name = ('wad/modules/' + $file.Name); Path = $file.FullName })
        }
    }
    return $files.ToArray()
}

# ---------------------------------------------------------------- handler resolution
function Get-DomeniaUiBlockHashLabel {
    # Key of the hashtable entry holding $Node, when $Node is the value of a hashtable literal under $Stop.
    param($Node,$Stop)
    $cursor = $Node
    while ($null -ne $cursor -and -not [object]::ReferenceEquals($cursor,$Stop)) {
        $parent = $cursor.Parent
        if ($parent -is [Management.Automation.Language.HashtableAst]) {
            foreach ($pair in @($parent.KeyValuePairs)) {
                if ([object]::ReferenceEquals($pair.Item2,$cursor)) { return (Get-DomeniaUiBlockText $pair.Item1 60).Trim("'",'"') }
            }
        }
        $cursor = $parent
    }
    return ''
}

function Test-DomeniaUiBlockTopLevel {
    # True when no script block expression lies between $Node and $Stop.
    param($Node,$Stop)
    $cursor = $Node.Parent
    while ($null -ne $cursor -and -not [object]::ReferenceEquals($cursor,$Stop)) {
        if ($cursor -is [Management.Automation.Language.ScriptBlockExpressionAst]) { return $false }
        $cursor = $cursor.Parent
    }
    return $true
}

function New-DomeniaUiBlockDynamicBody {
    # [scriptblock]::Create(<text>): the constant parts of the text, joined, are parsed as the handler body.
    param($Audit,$CreateAst)
    $arguments = @(Get-DomeniaUiBlockArguments $CreateAst)
    if ($arguments.Count -ne 1) { return $null }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push($arguments[0])
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node -is [Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -eq 'Plus') { $stack.Push($node.Right); $stack.Push($node.Left); continue }
        if ($node -is [Management.Automation.Language.ParenExpressionAst]) { $parts.Add('X'); continue }
        if ($node -is [Management.Automation.Language.StringConstantExpressionAst]) { $parts.Add([string]$node.Value); continue }
        $parts.Add('X')
    }
    $text = $parts.ToArray() -join ''
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) { return $null }
    $Audit.Synthetic.Add([pscustomobject]@{ Ast = $ast; Origin = $CreateAst })
    return $ast
}

function Resolve-DomeniaUiBlockHandler {
    # Adds to $Into the {Body, Label, Dynamic} entries the expression designates, or a {Param, Function} marker
    # when it is a parameter of a registration helper.
    param($Audit,$Unit,$Expr,$Scope,[int]$Depth,[Parameter(Mandatory=$true)]$Into)
    if ($null -eq $Expr -or $Depth -gt 4) { return }
    if ($Expr -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
        $Into.Add([pscustomobject]@{ Body = $Expr.ScriptBlock; Label = ''; Dynamic = $false; Param = ''; Function = $null })
        return
    }
    if ($Expr -is [Management.Automation.Language.AttributedExpressionAst]) { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Child $Scope ($Depth + 1) $Into; return }
    if ($Expr -is [Management.Automation.Language.ParenExpressionAst]) { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Pipeline $Scope ($Depth + 1) $Into; return }
    if ($Expr -is [Management.Automation.Language.PipelineAst]) {
        $elements = @($Expr.PipelineElements)
        if ($elements.Count -eq 1) { Resolve-DomeniaUiBlockHandler $Audit $Unit $elements[0] $Scope ($Depth + 1) $Into }
        return
    }
    if ($Expr -is [Management.Automation.Language.CommandExpressionAst]) { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Expression $Scope ($Depth + 1) $Into; return }
    if ($Expr -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
        $member = Get-DomeniaUiBlockMemberName $Expr
        if ($member -ieq 'GetNewClosure') { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Expression $Scope ($Depth + 1) $Into; return }
        if ($member -ieq 'Create' -and [bool]$Expr.Static -and [string]$Expr.Expression.Extent.Text -match '(?i)scriptblock') {
            $body = New-DomeniaUiBlockDynamicBody $Audit $Expr
            if ($null -ne $body) { $Into.Add([pscustomobject]@{ Body = $body; Label = ''; Dynamic = $true; Param = ''; Function = $null }) }
        }
        return
    }
    if ($Expr -is [Management.Automation.Language.IndexExpressionAst]) { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Target $Scope ($Depth + 1) $Into; return }
    if ($Expr -is [Management.Automation.Language.MemberExpressionAst]) { Resolve-DomeniaUiBlockHandler $Audit $Unit $Expr.Expression $Scope ($Depth + 1) $Into; return }
    if ($Expr -is [Management.Automation.Language.HashtableAst]) {
        foreach ($pair in @($Expr.KeyValuePairs)) {
            $inner = New-Object 'System.Collections.Generic.List[object]'
            Resolve-DomeniaUiBlockHandler $Audit $Unit $pair.Item2 $Scope ($Depth + 1) $inner
            foreach ($item in $inner) {
                if (-not $item.Label) { $item.Label = (Get-DomeniaUiBlockText $pair.Item1 60).Trim("'",'"') }
                $Into.Add($item)
            }
        }
        return
    }
    if ($Expr -isnot [Management.Automation.Language.VariableExpressionAst]) { return }
    $name = Get-DomeniaUiBlockVarName $Expr
    $assignments = @(Get-DomeniaUiBlockAssignments $Audit $Unit $Scope $name (Test-DomeniaUiBlockScopedVar $Expr))
    $start = $Into.Count
    foreach ($right in $assignments) {
        $before = $Into.Count
        foreach ($block in @($right.FindAll({ param($n) $n -is [Management.Automation.Language.ScriptBlockExpressionAst] },$true))) {
            if (-not (Test-DomeniaUiBlockTopLevel $block $right)) { continue }
            $Into.Add([pscustomobject]@{ Body = $block.ScriptBlock; Label = (Get-DomeniaUiBlockHashLabel $block $right); Dynamic = $false; Param = ''; Function = $null })
        }
        foreach ($create in @($right.FindAll({ param($n) ($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) -and [bool]$n.Static },$true))) {
            if (-not (Test-DomeniaUiBlockTopLevel $create $right)) { continue }
            if ((Get-DomeniaUiBlockMemberName $create) -ieq 'Create' -and [string]$create.Expression.Extent.Text -match '(?i)scriptblock') {
                $body = New-DomeniaUiBlockDynamicBody $Audit $create
                if ($null -ne $body) { $Into.Add([pscustomobject]@{ Body = $body; Label = ''; Dynamic = $true; Param = ''; Function = $null }) }
            }
        }
        if ($Into.Count -eq $before) {
            # Pure forwarding ($body = $actions[$n], $h = [Action]$other): follow the value.
            # The right-hand side of $x = <expression> is a CommandExpressionAst, sometimes inside a one-element pipeline.
            $value = $right
            if ($value -is [Management.Automation.Language.PipelineAst] -and @($value.PipelineElements).Count -eq 1) { $value = $value.PipelineElements[0] }
            if ($value -is [Management.Automation.Language.CommandExpressionAst]) { $value = $value.Expression }
            if (($value -is [Management.Automation.Language.VariableExpressionAst]) -or ($value -is [Management.Automation.Language.IndexExpressionAst]) -or ($value -is [Management.Automation.Language.AttributedExpressionAst]) -or ($value -is [Management.Automation.Language.HashtableAst]) -or (($value -is [Management.Automation.Language.MemberExpressionAst]) -and ($value -isnot [Management.Automation.Language.InvokeMemberExpressionAst]))) {
                Resolve-DomeniaUiBlockHandler $Audit $Unit $value $Scope ($Depth + 1) $Into
            }
        }
    }
    if ($Into.Count -eq $start -and $assignments.Count -eq 0 -and $null -ne $Scope) {
        foreach ($parameter in @(Get-DomeniaUiBlockFunctionParameters $Scope)) {
            if ($parameter.Name -eq $name) { $Into.Add([pscustomobject]@{ Body = $null; Label = ''; Dynamic = $false; Param = $name; Function = $Scope }); break }
        }
    }
}

function Get-DomeniaUiBlockAssignments {
    # Right-hand sides assigned to $Name in $Scope (or anywhere in the unit for script: and global: variables).
    param($Audit,$Unit,$Scope,[string]$Name,[bool]$Wide)
    $result = New-Object 'System.Collections.Generic.List[object]'
    $index = $Audit.Assignments[$Unit.Name]
    if ($null -eq $index -or -not $index.ContainsKey($Name)) { return }
    foreach ($entry in $index[$Name]) {
        if ($Wide -or $entry.Wide -or [object]::ReferenceEquals($entry.Scope,$Scope)) { $result.Add($entry.Right) }
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------- catalogue
function Get-DomeniaUiBlockCommandRule {
    param($Audit,[string]$Name,$CommandAst)
    $plain = $Name
    if ($plain.Contains('\')) { $plain = $plain.Substring($plain.LastIndexOf('\') + 1) }
    if ($script:UiBlockCommandIndex.ContainsKey($plain)) {
        $canonical = $script:UiBlockCommandIndex[$plain]
        $rule = $script:UiBlockCommands[$canonical]
        $heuristic = [bool]$rule[1]
        $label = $canonical
        if ($script:UiBlockPathCommands -contains $canonical) {
            foreach ($element in @($CommandAst.CommandElements | Select-Object -Skip 1)) {
                # A constant path on another provider (Remove-Item Variable:x, Set-Content Env:X...) is not a disk access.
                if (($element -is [Management.Automation.Language.StringConstantExpressionAst]) -and ([string]$element.Value -match $script:UiBlockNonFilePath)) { return $null }
                if (($element -is [Management.Automation.Language.CommandParameterAst]) -and ([string]$element.ParameterName -ieq 'Recurse') -and (@('Remove-Item','Copy-Item') -contains $canonical)) {
                    # A whole tree: certain, whatever the medium.
                    $heuristic = $false; $label = $canonical + ' -Recurse'
                }
            }
        }
        return [pscustomobject]@{ Category = $rule[0]; Heuristic = $heuristic; Label = $label }
    }
    if ($plain -ieq 'Receive-Job') {
        foreach ($element in @($CommandAst.CommandElements)) {
            if ($element -is [Management.Automation.Language.CommandParameterAst] -and [string]$element.ParameterName -ieq 'Wait') { return [pscustomobject]@{ Category = 'Attente'; Heuristic = $false; Label = 'Receive-Job -Wait' } }
        }
        return $null
    }
    if ($plain -cmatch $script:UiBlockAdCmdlet -and -not $Audit.Functions.ContainsKey($plain.ToLowerInvariant())) {
        return [pscustomobject]@{ Category = 'Reseau'; Heuristic = $false; Label = $plain }
    }
    return $null
}

function Get-DomeniaUiBlockMethodRule {
    param($InvokeAst)
    $member = Get-DomeniaUiBlockMemberName $InvokeAst
    if (-not $member -or -not $script:UiBlockMethodIndex.ContainsKey($member)) { return $null }
    $canonical = $script:UiBlockMethodIndex[$member]
    $rule = $script:UiBlockMethods[$canonical]
    $static = [bool]$InvokeAst.Static
    $count = @(Get-DomeniaUiBlockArguments $InvokeAst).Count
    $receiver = [string]$InvokeAst.Expression.Extent.Text
    $label = '.' + $canonical + '()'
    switch ([string]$rule[2]) {
        'NoArgs'   { if ($static -or $count -ne 0) { return $null } }
        'Instance' { if ($static) { return $null } }
        'Static'   { if (-not $static) { return $null }; $label = '::' + $canonical + '()' }
        'Args'     { if ($static -or $count -lt 1) { return $null } }
        'Dns'      { if (-not $static -or $receiver -notmatch '(?i)Dns\]$') { return $null }; $label = '[Net.Dns]::' + $canonical + '()' }
        'Sqlite'   { if (-not $static -or $receiver -notmatch '(?i)WinSqliteNative\]$') { return $null }; $label = '[WinSqliteNative]::' + $canonical + '()' }
        'FileSystem' {
            # [Array]::Copy, [IO.Path]::... and other homonyms are not disk accesses.
            $kind = [regex]::Match($receiver,'(?i)[\[.](File|Directory)\]$')
            if (-not $static -or -not $kind.Success) { return $null }
            $typeName = 'File'
            if ($kind.Groups[1].Value -ieq 'Directory') { $typeName = 'Directory' }
            $label = '[IO.' + $typeName + ']::' + $canonical + '()'
        }
        'Zip'      { if (-not $static -or $receiver -notmatch '(?i)ZipFile\]$') { return $null }; $label = '[ZipFile]::' + $canonical + '()' }
        default    { }
    }
    return [pscustomobject]@{ Category = [string]$rule[0]; Heuristic = [bool]$rule[1]; Label = $label }
}

# ---------------------------------------------------------------- audit
function New-DomeniaUiBlockAudit {
    return [pscustomobject]@{
        Units = (New-Object 'System.Collections.Generic.List[object]')
        Functions = @{}                 # lower name -> List of owner records
        Owners = (New-Object 'System.Collections.Generic.Dictionary[object,object]')  # ScriptBlockAst -> owner record
        Assignments = @{}               # unit name -> @{ var -> List of {Scope, Right, Wide} }
        Registrations = (New-Object 'System.Collections.Generic.List[object]')
        Helpers = (New-Object 'System.Collections.Generic.List[object]')
        Handlers = (New-Object 'System.Collections.Generic.List[object]')
        Unresolved = (New-Object 'System.Collections.Generic.List[object]')
        Synthetic = (New-Object 'System.Collections.Generic.List[object]')
        Commands = (New-Object 'System.Collections.Generic.List[object]')
        Invokes = (New-Object 'System.Collections.Generic.List[object]')
    }
}

function Add-DomeniaUiBlockUnit {
    # Indexes one parsed unit: functions, assignments, commands, member calls and handler registrations.
    param($Audit,$Unit)
    $Audit.Units.Add($Unit)
    $nodes = $Unit.Ast.FindAll({ param($n) ($n -is [Management.Automation.Language.CommandAst]) -or ($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) -or ($n -is [Management.Automation.Language.FunctionDefinitionAst]) -or ($n -is [Management.Automation.Language.AssignmentStatementAst]) },$true)
    $assignments = @{}
    $Audit.Assignments[$Unit.Name] = $assignments
    foreach ($node in $nodes) {
        if ($node -is [Management.Automation.Language.CommandAst]) { $Audit.Commands.Add([pscustomobject]@{ Unit = $Unit; Node = $node }); continue }
        if ($node -is [Management.Automation.Language.InvokeMemberExpressionAst]) {
            $Audit.Invokes.Add([pscustomobject]@{ Unit = $Unit; Node = $node })
            $member = Get-DomeniaUiBlockMemberName $node
            $arguments = @(Get-DomeniaUiBlockArguments $node)
            $receiver = [string]$node.Expression.Extent.Text
            $addEvent = [regex]::Match($member,'^(?i)Add_(\w+)$')
            if ($addEvent.Success -and -not [bool]$node.Static -and $arguments.Count -ge 1) {
                $Audit.Registrations.Add([pscustomobject]@{ Unit = $Unit; Node = $node; Event = $addEvent.Groups[1].Value; Kind = 'Evenement'; Handlers = @($arguments[0]) })
            } elseif ($member -ieq 'AddHandler' -and $arguments.Count -ge 2) {
                $routedName = Get-DomeniaUiBlockText $arguments[0] 80
                if ($arguments[0] -is [Management.Automation.Language.MemberExpressionAst]) { $routedName = Get-DomeniaUiBlockMemberName $arguments[0] }
                $Audit.Registrations.Add([pscustomobject]@{ Unit = $Unit; Node = $node; Event = $routedName; Kind = 'Routage'; Handlers = @($arguments[1]) })
            } elseif ($member -match '^(?i)(Invoke|BeginInvoke|InvokeAsync)$' -and $receiver -match '(?i)Dispatcher' -and $arguments.Count -ge 1) {
                # Priorities and callback arguments sit beside the delegate: every argument is tried.
                $Audit.Registrations.Add([pscustomobject]@{ Unit = $Unit; Node = $node; Event = ('Dispatcher.' + $member); Kind = 'Dispatcher'; Handlers = $arguments })
            }
            continue
        }
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) {
            $owner = [pscustomobject]@{ Kind = 'Function'; Name = [string]$node.Name; File = $Unit.Name; Line = [int]$node.Extent.StartLineNumber; Calls = (New-Object 'System.Collections.Generic.List[object]'); Sites = (New-Object 'System.Collections.Generic.List[object]') }
            $Audit.Owners[$node.Body] = $owner
            $key = ([string]$node.Name).ToLowerInvariant()
            if (-not $Audit.Functions.ContainsKey($key)) { $Audit.Functions[$key] = New-Object 'System.Collections.Generic.List[object]' }
            $Audit.Functions[$key].Add($owner)
            continue
        }
        # Assignment: index the right-hand side by variable name and scope.
        $left = $node.Left
        while (($left -is [Management.Automation.Language.AttributedExpressionAst]) -or ($left -is [Management.Automation.Language.IndexExpressionAst]) -or (($left -is [Management.Automation.Language.MemberExpressionAst]) -and ($left -isnot [Management.Automation.Language.InvokeMemberExpressionAst]))) {
            if ($left -is [Management.Automation.Language.AttributedExpressionAst]) { $left = $left.Child }
            elseif ($left -is [Management.Automation.Language.IndexExpressionAst]) { $left = $left.Target }
            else { $left = $left.Expression }
        }
        if ($left -isnot [Management.Automation.Language.VariableExpressionAst]) { continue }
        $name = Get-DomeniaUiBlockVarName $left
        if (-not $assignments.ContainsKey($name)) { $assignments[$name] = New-Object 'System.Collections.Generic.List[object]' }
        $assignments[$name].Add([pscustomobject]@{ Scope = (Get-DomeniaUiBlockScope $node); Right = $node.Right; Wide = (Test-DomeniaUiBlockScopedVar $left) })
    }
}

function Add-DomeniaUiBlockHandler {
    param($Audit,$Unit,$Item,$Registration,[string]$EventName,[string]$Kind,[string]$Via,$SiteNode)
    $scope = Get-DomeniaUiBlockScope $SiteNode
    $scopeName = '<script>'
    if ($null -ne $scope) { $scopeName = [string]$scope.Name }
    $label = $Item.Label
    $id = $Unit.Name + '|' + $scopeName + '|' + $Registration
    if ($label) { $id += '[' + $label + ']' }
    $owner = $null
    if ($Audit.Owners.ContainsKey($Item.Body)) { $owner = $Audit.Owners[$Item.Body] }
    if ($null -eq $owner -or $owner.Kind -ne 'Handler') {
        $owner = [pscustomobject]@{ Kind = 'Handler'; Name = '<gestionnaire>'; File = $Unit.Name; Line = [int]$SiteNode.Extent.StartLineNumber; Calls = (New-Object 'System.Collections.Generic.List[object]'); Sites = (New-Object 'System.Collections.Generic.List[object]') }
        $Audit.Owners[$Item.Body] = $owner
    }
    $Audit.Handlers.Add([pscustomobject]@{ Id = $id; Event = $EventName; Kind = $Kind; File = $Unit.Name; Line = [int]$SiteNode.Extent.StartLineNumber; Function = $scopeName; Registration = $Registration; Label = $label; Via = $Via; Dynamic = [bool]$Item.Dynamic; Owner = $owner })
}

function Resolve-DomeniaUiBlockRegistrations {
    param($Audit)
    foreach ($registration in $Audit.Registrations) {
        $scope = Get-DomeniaUiBlockScope $registration.Node
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($candidate in @($registration.Handlers)) { Resolve-DomeniaUiBlockHandler $Audit $registration.Unit $candidate $scope 0 $items }
        $text = Get-DomeniaUiBlockText $registration.Node.Expression 80
        $member = Get-DomeniaUiBlockMemberName $registration.Node
        $registrationText = $text + '.' + $member
        if ($items.Count -eq 0) {
            $Audit.Unresolved.Add([pscustomobject]@{ File = $registration.Unit.Name; Line = [int]$registration.Node.Extent.StartLineNumber; Event = $registration.Event; Text = (Get-DomeniaUiBlockText $registration.Node 160) })
            continue
        }
        foreach ($item in $items) {
            if ($null -eq $item.Body) {
                $Audit.Helpers.Add([pscustomobject]@{ Function = $item.Function; Param = $item.Param; Event = $registration.Event; Kind = $registration.Kind; Unit = $registration.Unit; Node = $registration.Node })
                continue
            }
            Add-DomeniaUiBlockHandler $Audit $registration.Unit $item $registrationText $registration.Event $registration.Kind '' $registration.Node
        }
    }
    # Registration helpers: the handler is the argument bound to the parameter at each call site.
    # A helper forwarding its own parameter to another helper is followed too (bounded).
    for ($h = 0; $h -lt $Audit.Helpers.Count -and $h -lt 500; $h++) {
        $helper = $Audit.Helpers[$h]
        $helperName = [string]$helper.Function.Name
        $parameters = @(Get-DomeniaUiBlockFunctionParameters $helper.Function)
        $target = $null
        foreach ($parameter in $parameters) { if ($parameter.Name -eq $helper.Param) { $target = $parameter } }
        if ($null -eq $target) { continue }
        $calls = 0
        foreach ($command in $Audit.Commands) {
            $name = $command.Node.GetCommandName()
            if (-not $name -or $name -ine $helperName) { continue }
            $argument = Get-DomeniaUiBlockBoundArgument $command.Node $parameters $target
            if ($null -eq $argument) { continue }
            $calls++
            $scope = Get-DomeniaUiBlockScope $command.Node
            $items = New-Object 'System.Collections.Generic.List[object]'
            Resolve-DomeniaUiBlockHandler $Audit $command.Unit $argument $scope 0 $items
            $forwarded = $false
            foreach ($item in $items) {
                if ($null -eq $item.Body) {
                    $already = @($Audit.Helpers | Where-Object { [object]::ReferenceEquals($_.Function,$item.Function) -and $_.Param -eq $item.Param -and $_.Event -eq $helper.Event }).Count
                    if (-not $already) { $Audit.Helpers.Add([pscustomobject]@{ Function = $item.Function; Param = $item.Param; Event = $helper.Event; Kind = $helper.Kind; Unit = $command.Unit; Node = $command.Node }) }
                    $forwarded = $true
                    continue
                }
                Add-DomeniaUiBlockHandler $Audit $command.Unit $item ($helperName + '->' + $helper.Event) $helper.Event $helper.Kind $helperName $command.Node
            }
            if (-not $forwarded -and @($items | Where-Object { $null -ne $_.Body }).Count -eq 0) {
                $Audit.Unresolved.Add([pscustomobject]@{ File = $command.Unit.Name; Line = [int]$command.Node.Extent.StartLineNumber; Event = $helper.Event; Text = (Get-DomeniaUiBlockText $command.Node 160) })
            }
        }
    }
}

function Get-DomeniaUiBlockBoundArgument {
    # Argument bound to $Target at a call site: by name (prefix), else by position among positional arguments.
    param($CommandAst,[object[]]$Parameters,$Target)
    $elements = @($CommandAst.CommandElements)
    $positional = New-Object 'System.Collections.Generic.List[object]'
    $i = 1
    while ($i -lt $elements.Count) {
        $element = $elements[$i]
        if ($element -is [Management.Automation.Language.CommandParameterAst]) {
            $given = ([string]$element.ParameterName).ToLowerInvariant()
            $match = $null
            foreach ($parameter in $Parameters) { if ($parameter.Name.StartsWith($given)) { $match = $parameter; break } }
            $value = $element.Argument
            if ($null -eq $value -and $null -ne $match -and -not $match.Switch -and ($i + 1) -lt $elements.Count) { $i++; $value = $elements[$i] }
            if ($null -ne $match -and $match.Name -eq $Target.Name) { return $value }
            $i++
            continue
        }
        $positional.Add($element)
        $i++
    }
    if ($Target.Position -ge 0 -and $Target.Position -lt $positional.Count) { return $positional[$Target.Position] }
    return $null
}

function Find-DomeniaUiBlockOwner {
    # Nearest enclosing script block that is a function body, a handler body or a synthetic handler.
    param($Audit,$Node)
    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [Management.Automation.Language.ScriptBlockAst] -and $Audit.Owners.ContainsKey($cursor)) { return $Audit.Owners[$cursor] }
        $cursor = $cursor.Parent
    }
    return $null
}

function Add-DomeniaUiBlockEdges {
    # Assigns one command or member call to its owner: a call to a defined function, or a blocking site.
    # The cheap classification runs first; only relevant nodes pay for the walk up to their owner.
    param($Audit,[string]$Unit,$Command,$Invoke,[int]$LineOverride=0)
    $rule = $null; $callee = ''; $node = $Invoke
    if ($null -ne $Command) {
        $node = $Command
        $name = $Command.GetCommandName()
        if (-not $name) { return }
        $rule = Get-DomeniaUiBlockCommandRule $Audit $name $Command
        if ($null -eq $rule) {
            $key = $name.ToLowerInvariant()
            if ($key.Contains('\')) { $key = $key.Substring($key.LastIndexOf('\') + 1) }
            if (-not $Audit.Functions.ContainsKey($key)) { return }
            $callee = $key
        }
    } else {
        $rule = Get-DomeniaUiBlockMethodRule $Invoke
        if ($null -eq $rule) { return }
    }
    $owner = Find-DomeniaUiBlockOwner $Audit $node
    if ($null -eq $owner) { return }
    $line = [int]$node.Extent.StartLineNumber
    if ($LineOverride -gt 0) { $line = $LineOverride }
    if ($callee) { $owner.Calls.Add([pscustomobject]@{ Name = $callee; Line = $line }); return }
    $owner.Sites.Add([pscustomobject]@{ Category = $rule.Category; Heuristic = $rule.Heuristic; Label = $rule.Label; File = $Unit; Line = $line; Text = (Get-DomeniaUiBlockText $node 100); Owner = $owner })
}

function Invoke-DomeniaUiBlockGraph {
    # Indexes owners and edges, then walks the call graph from every handler (breadth first: shortest chain).
    param($Audit)
    foreach ($entry in $Audit.Commands) { Add-DomeniaUiBlockEdges $Audit $entry.Unit.Name $entry.Node $null }
    foreach ($entry in $Audit.Invokes) { Add-DomeniaUiBlockEdges $Audit $entry.Unit.Name $null $entry.Node }
    foreach ($synthetic in $Audit.Synthetic) {
        $originUnit = ''
        foreach ($registration in $Audit.Handlers) { if ([object]::ReferenceEquals($registration.Owner,$Audit.Owners[$synthetic.Ast])) { $originUnit = $registration.File; break } }
        $line = [int]$synthetic.Origin.Extent.StartLineNumber
        foreach ($node in @($synthetic.Ast.FindAll({ param($n) ($n -is [Management.Automation.Language.CommandAst]) -or ($n -is [Management.Automation.Language.InvokeMemberExpressionAst]) },$true))) {
            if ($node -is [Management.Automation.Language.CommandAst]) { Add-DomeniaUiBlockEdges $Audit $originUnit $node $null $line } else { Add-DomeniaUiBlockEdges $Audit $originUnit $null $node $line }
        }
    }
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $memo = New-Object 'System.Collections.Generic.Dictionary[object,object]'
    foreach ($handler in $Audit.Handlers) {
        if (-not $memo.ContainsKey($handler.Owner)) { $memo[$handler.Owner] = Get-DomeniaUiBlockReach $Audit $handler.Owner }
        foreach ($reach in $memo[$handler.Owner]) {
            $site = $reach.Site
            $siteOwner = '<gestionnaire>'
            if ($site.Owner.Kind -eq 'Function') { $siteOwner = $site.Owner.File + ':' + $site.Owner.Name }
            $key = $handler.Id + ' | ' + $siteOwner + ' | ' + $site.Label
            $findings.Add([pscustomobject]@{
                Key = $key; Category = $site.Category; Severity = [int]$script:UiBlockSeverity[$site.Category]; Heuristic = [bool]$site.Heuristic
                Handler = [pscustomobject]@{ Id = $handler.Id; Event = $handler.Event; Kind = $handler.Kind; File = $handler.File; Line = $handler.Line; Function = $handler.Function; Via = $handler.Via; Dynamic = $handler.Dynamic }
                Chain = $reach.Chain; Depth = @($reach.Chain).Count
                Call = [pscustomobject]@{ Label = $site.Label; Text = $site.Text; File = $site.File; Line = $site.Line }
            })
        }
    }
    return ,$findings.ToArray()
}

function Get-DomeniaUiBlockReach {
    # Blocking sites reachable from one handler body, each with its shortest chain of function calls.
    param($Audit,$Start)
    $result = New-Object 'System.Collections.Generic.List[object]'
    $visited = New-Object 'System.Collections.Generic.HashSet[object]'
    $queue = New-Object 'System.Collections.Generic.Queue[object]'
    [void]$visited.Add($Start)
    $queue.Enqueue([pscustomobject]@{ Owner = $Start; Chain = @() })
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        foreach ($site in $current.Owner.Sites) { $result.Add([pscustomobject]@{ Site = $site; Chain = $current.Chain }) }
        foreach ($call in $current.Owner.Calls) {
            foreach ($definition in $Audit.Functions[$call.Name]) {
                if (-not $visited.Add($definition)) { continue }
                $step = $definition.Name + ' (' + $definition.File + ':' + $definition.Line + ')'
                $queue.Enqueue([pscustomobject]@{ Owner = $definition; Chain = @($current.Chain + $step) })
            }
        }
    }
    return ,$result.ToArray()
}

function Invoke-DomeniaUiBlockAudit {
    param([object[]]$Units)
    $audit = New-DomeniaUiBlockAudit
    foreach ($unit in $Units) { Add-DomeniaUiBlockUnit $audit $unit }
    Resolve-DomeniaUiBlockRegistrations $audit
    $findings = Invoke-DomeniaUiBlockGraph $audit
    return [pscustomobject]@{ Audit = $audit; Findings = $findings }
}

# ---------------------------------------------------------------- baseline
function Get-DomeniaUiBlockCounts {
    param([object[]]$Findings)
    $counts = @{}
    foreach ($finding in @($Findings)) { if ($counts.ContainsKey($finding.Key)) { $counts[$finding.Key]++ } else { $counts[$finding.Key] = 1 } }
    return $counts
}

function ConvertTo-DomeniaUiBlockBaseline {
    param([object[]]$Findings)
    $counts = Get-DomeniaUiBlockCounts $Findings
    $byKey = @{}
    foreach ($finding in @($Findings)) { if (-not $byKey.ContainsKey($finding.Key)) { $byKey[$finding.Key] = $finding } }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($counts.Keys | Sort-Object)) {
        $entries.Add([ordered]@{ Key = $key; Count = [int]$counts[$key]; Category = [string]$byKey[$key].Category })
    }
    $total = 0
    foreach ($key in @($counts.Keys)) { $total += [int]$counts[$key] }
    return [ordered]@{
        Kind = 'DomeniaUiBlockingBaseline'; Version = 1; Item = 'D014'
        Note = 'Dette mesuree : appels bloquants atteignables depuis les gestionnaires UI. Une nouvelle occurrence fait echouer tools/Test-DomeniaUiBlockingDebt.ps1 ; une occurrence disparue est signalee. Regenerer avec -UpdateBaseline apres relecture.'
        Total = $total; DistinctKeys = $entries.Count; Entries = $entries.ToArray()
    }
}

function Compare-DomeniaUiBlockBaseline {
    # Multiset comparison: more occurrences of a key than in the baseline = new debt.
    param([object[]]$Findings,$Baseline)
    $counts = Get-DomeniaUiBlockCounts $Findings
    $known = @{}
    if ($null -ne $Baseline) {
        foreach ($entry in @($Baseline.Entries)) { if ($null -ne $entry) { $known[[string]$entry.Key] = [int]$entry.Count } }
    }
    $new = New-Object 'System.Collections.Generic.List[object]'
    $gone = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($counts.Keys | Sort-Object)) {
        $before = 0
        if ($known.ContainsKey($key)) { $before = $known[$key] }
        if ($counts[$key] -gt $before) { $new.Add([pscustomobject]@{ Key = $key; Baseline = $before; Current = [int]$counts[$key] }) }
    }
    foreach ($key in @($known.Keys | Sort-Object)) {
        $now = 0
        if ($counts.ContainsKey($key)) { $now = [int]$counts[$key] }
        if ($now -lt $known[$key]) { $gone.Add([pscustomobject]@{ Key = $key; Baseline = $known[$key]; Current = $now }) }
    }
    $status = 'PASS'
    if ($null -eq $Baseline) { $status = 'NO_BASELINE' } elseif ($new.Count -gt 0) { $status = 'FAIL' }
    return [pscustomobject]@{ Status = $status; New = $new.ToArray(); Gone = $gone.ToArray() }
}

function Get-DomeniaUiBlockEventRank {
    # 0 = interactive or repeated (click, key, selection, timer tick), 1 = life cycle (startup, closing, crash).
    param($Handler)
    if ($Handler.Kind -eq 'Dispatcher') { return 1 }
    if (@('Closed','Closing','ContentRendered','Loaded','Activated','Deactivated','UnhandledException','Initialized') -contains [string]$Handler.Event) { return 1 }
    return 0
}

function Select-DomeniaUiBlockTop {
    # Most serious chains: certain before heuristic, then category, interactive before life cycle, shortest chain;
    # one line per blocking site.
    param([object[]]$Findings,[int]$Count=10)
    $seen = @{}
    $top = New-Object 'System.Collections.Generic.List[object]'
    $order = @('Heuristic','Severity',@{ Expression = { Get-DomeniaUiBlockEventRank $_.Handler } },'Depth',@{ Expression = { $_.Handler.Id } },@{ Expression = { $_.Call.Line } })
    foreach ($finding in @(@($Findings) | Sort-Object -Property $order)) {
        $site = $finding.Call.File + ':' + $finding.Call.Line + ':' + $finding.Call.Label
        if ($seen.ContainsKey($site)) { continue }
        $seen[$site] = $true
        $top.Add($finding)
        if ($top.Count -ge $Count) { break }
    }
    return $top.ToArray()
}

function Format-DomeniaUiBlockFinding {
    param($Finding)
    $chain = @($Finding.Chain | ForEach-Object { ([string]$_ -replace ' \(.*$','') })
    $path = @('[' + $Finding.Handler.Event + '] ' + $Finding.Handler.File + ':' + $Finding.Handler.Line) + $chain + @($Finding.Call.Label + ' (' + $Finding.Call.File + ':' + $Finding.Call.Line + ')')
    return ($Finding.Category + ' : ' + ($path -join ' -> '))
}

function Write-DomeniaUiBlockBaseline {
    # One entry per line: compact and readable in a diff. Same content as ConvertTo-Json would give.
    param([Parameter(Mandatory=$true)][string]$Path,$Baseline)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('{')
    foreach ($name in @('Kind','Version','Item','Note','Total','DistinctKeys')) {
        $lines.Add('  "' + $name + '": ' + (ConvertTo-Json -InputObject $Baseline[$name] -Compress) + ',')
    }
    $lines.Add('  "Entries": [')
    $entries = @($Baseline['Entries'])
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $suffix = ','
        if ($i -eq $entries.Count - 1) { $suffix = '' }
        $lines.Add('    ' + (ConvertTo-Json -InputObject $entries[$i] -Compress) + $suffix)
    }
    $lines.Add('  ]')
    $lines.Add('}')
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),(($lines.ToArray() -join "`n") + "`n"),(New-Object Text.UTF8Encoding($false)))
}

function Write-DomeniaUiBlockJson {
    param([Parameter(Mandatory=$true)][string]$Path,$Value)
    $json = ($Value | ConvertTo-Json -Depth 8) -replace "`r`n","`n"
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$json + "`n",(New-Object Text.UTF8Encoding($false)))
}

# ---------------------------------------------------------------- self-test (synthetic sources, in memory)
function Invoke-DomeniaUiBlockSelfTest {
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $check = {
        param([string]$Name,[bool]$Ok,[string]$Detail='')
        $checks.Add([pscustomobject]@{ Id = 'D014'; Name = $Name; Status = $(if ($Ok) { 'Passed' } else { 'Failed' }); Detail = $Detail })
    }
    $core = @'
function Invoke-SelfA { Invoke-SelfB }
function Invoke-SelfB { Start-Sleep -Milliseconds 1 }
function Get-SelfWorkerCode {
    return @~
$searcher.FindAll()
Get-CimInstance Win32_OperatingSystem
~@
}
function Invoke-SelfWorkerStart { $code = Get-SelfWorkerCode; $ps = [powershell]::Create(); [void]$ps.AddScript($code); [void]$ps.BeginInvoke() }
function Initialize-SelfUi {
    $script:Ctrl['BtnA'].Add_Click({ Invoke-SelfA })
    $script:Ctrl['BtnWorker'].Add_Click({ Invoke-SelfWorkerStart })
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Add_Tick({ Get-CimInstance Win32_Service })
    $saver = { Invoke-DomeniaDbExec -Sql 'UPDATE t SET v=1;' }
    $script:Ctrl['BtnSave'].Add_Click($saver)
    $actions = @{ BtnHash = { Get-FileHash -LiteralPath 'x' }; BtnFine = { Set-SelfText } }
    foreach ($n in $actions.Keys) { $body = $actions[$n]; $script:Ctrl[$n].Add_Click($body) }
    $script:Window.Dispatcher.BeginInvoke([Action]{ [Net.Dns]::GetHostEntry('pc01') }) | Out-Null
    Register-SelfKeys $script:Window { $searcher.FindOne() }
    $script:Ctrl['BtnInit'].Add_Click({ Initialize-SelfLate })
    $script:Ctrl['BtnAst'].Add_Click({ $ast.FindAll({ $true }, $true) | Out-Null; [string]::Join(',', @('a')) | Out-Null })
    $journal = New-Object System.Windows.Threading.DispatcherTimer
    $journal.Add_Tick({ Write-SelfLog 'tick' })
    $script:Ctrl['BtnBackup'].Add_Click({ Backup-SelfStore })
    $script:Ctrl['BtnExport'].Add_Click({ Export-SelfSupport })
    $script:Ctrl['BtnIcon'].Add_Click({ [IO.File]::WriteAllBytes('i.ico', $bytes); 'x' | Out-File -FilePath 'o.txt' })
    $script:Ctrl['BtnMem'].Add_Click({ Set-SelfMemory })
}
function Write-SelfLog {
    param([string]$Text)
    if ($script:Big) { Move-Item -LiteralPath 'a.log' -Destination 'a.log.1' -Force }
    [System.IO.File]::AppendAllText('a.log', $Text)
}
function Backup-SelfStore { $rc = [Domenia.WinSqliteNative]::sqlite3_backup_step($b, 256); [void][Domenia.WinSqliteNative]::sqlite3_backup_finish($b) }
function Export-SelfSupport { 'x' | Set-Content -LiteralPath 'r.json'; [IO.Compression.ZipFile]::CreateFromDirectory('w', 'z.zip'); Remove-Item -LiteralPath 'w' -Recurse -Force }
function Set-SelfMemory { Remove-Item Variable:selfTemp -ErrorAction SilentlyContinue; Add-Content -Path 'Env:SELF' -Value 1; [Array]::Copy($a, $b, 1); [IO.Path]::GetFileName('x') | Out-Null }
function Set-SelfText { $script:Status = 'ok' }
function Initialize-SelfLate { $script:Ctrl['BtnLate'].Add_Click({ Test-Connection pc01 -Count 1 }) }
function Register-SelfKeys { param($Window,[scriptblock]$Handler) $Window.Add_KeyDown($Handler) }
'@
    # The worker code is a here-string inside the synthetic source: its markers are restored after quoting.
    $core = $core.Replace('@~',"@'").Replace('~@',"'@")
    $unit = New-DomeniaUiBlockUnit -Name 'self/Core.ps1' -Text $core
    & $check 'Source synthetique analysee sans erreur' ($unit.Errors.Count -eq 0) ($unit.Errors -join '; ')
    $run = Invoke-DomeniaUiBlockAudit @($unit)
    $findings = @($run.Findings)
    $lines = @($findings | ForEach-Object { $_.Key })
    $has = { param([string]$Handler,[string]$Label) @($findings | Where-Object { $_.Handler.Id -like $Handler -and $_.Call.Label -eq $Label }).Count -gt 0 }
    & $check 'Attente atteinte par une chaine transitive' (& $has '*BtnA''*' 'Start-Sleep') ($lines -join '; ')
    $chain = @($findings | Where-Object { $_.Handler.Id -like '*BtnA''*' -and $_.Call.Label -eq 'Start-Sleep' } | Select-Object -First 1)
    & $check 'Chaine complete gestionnaire -> Invoke-SelfA -> Invoke-SelfB' (($chain.Count -eq 1) -and (@($chain[0].Chain).Count -eq 2) -and ([string]$chain[0].Chain[1] -like 'Invoke-SelfB*'))
    & $check 'Code de worker en here-string ignore' (@($findings | Where-Object { $_.Handler.Id -like '*BtnWorker*' }).Count -eq 0) ($lines -join '; ')
    & $check 'Gestionnaire Tick de DispatcherTimer' (& $has '*timer.Add_Tick*' 'Get-CimInstance') ($lines -join '; ')
    & $check 'Gestionnaire passe par variable : SQLite synchrone' (& $has '*BtnSave*' 'Invoke-DomeniaDbExec') ($lines -join '; ')
    & $check 'Gestionnaire tire d une table : hachage disque' (& $has '*BtnHash*' 'Get-FileHash') ($lines -join '; ')
    & $check 'Entree de table sans appel bloquant : aucun constat' (@($findings | Where-Object { $_.Handler.Id -like '*BtnFine*' }).Count -eq 0)
    & $check 'Dispatcher.BeginInvoke : resolution DNS' (& $has '*Dispatcher.BeginInvoke*' '[Net.Dns]::GetHostEntry()') ($lines -join '; ')
    & $check 'Gestionnaire transmis a une fonction d enregistrement' (& $has '*Register-SelfKeys->KeyDown*' '.FindOne()') ($lines -join '; ')
    & $check 'Une fonction qui enregistre un gestionnaire ne l execute pas' (@($findings | Where-Object { $_.Handler.Id -like '*BtnInit*' }).Count -eq 0) ($lines -join '; ')
    & $check 'Le gestionnaire enregistre plus tard est audite' (& $has '*BtnLate*' 'Test-Connection') ($lines -join '; ')
    & $check 'FindAll d AST et String.Join ne sont pas des appels reseau' (@($findings | Where-Object { $_.Handler.Id -like '*BtnAst*' }).Count -eq 0) ($lines -join '; ')
    $heuristicOf = { param([string]$Handler,[string]$Label) @($findings | Where-Object { $_.Handler.Id -like $Handler -and $_.Call.Label -eq $Label } | ForEach-Object { [bool]$_.Heuristic } | Select-Object -First 1) }
    & $check 'Tick de journal : ajout au fichier par une fonction appelee' ((& $has '*journal.Add_Tick*' '[IO.File]::AppendAllText()') -and (@(& $heuristicOf '*journal.Add_Tick*' '[IO.File]::AppendAllText()') -contains $true)) ($lines -join '; ')
    & $check 'Tick de journal : rotation par Move-Item' (& $has '*journal.Add_Tick*' 'Move-Item') ($lines -join '; ')
    & $check 'Sauvegarde SQLite en ligne : backup_step et backup_finish certains' ((& $has '*BtnBackup*' '[WinSqliteNative]::sqlite3_backup_step()') -and (& $has '*BtnBackup*' '[WinSqliteNative]::sqlite3_backup_finish()') -and (@(& $heuristicOf '*BtnBackup*' '[WinSqliteNative]::sqlite3_backup_step()') -contains $false)) ($lines -join '; ')
    & $check 'Export : Set-Content, ZipFile et suppression recursive certaine' ((& $has '*BtnExport*' 'Set-Content') -and (& $has '*BtnExport*' '[ZipFile]::CreateFromDirectory()') -and (& $has '*BtnExport*' 'Remove-Item -Recurse') -and (@(& $heuristicOf '*BtnExport*' 'Remove-Item -Recurse') -contains $false)) ($lines -join '; ')
    & $check 'Ecritures directes : WriteAllBytes et Out-File' ((& $has '*BtnIcon*' '[IO.File]::WriteAllBytes()') -and (& $has '*BtnIcon*' 'Out-File')) ($lines -join '; ')
    & $check 'Homonymes hors disque : [Array]::Copy, [IO.Path], Variable:, Env:' (@($findings | Where-Object { $_.Handler.Id -like '*BtnMem*' }).Count -eq 0) ($lines -join '; ')
    # Same round trip as the baseline file: JSON text read back by ConvertFrom-Json.
    $baseline = (ConvertTo-DomeniaUiBlockBaseline $findings | ConvertTo-Json -Depth 6) | ConvertFrom-Json
    $same = Compare-DomeniaUiBlockBaseline $findings $baseline
    & $check 'Ligne de base identique : reussite' ($same.Status -eq 'PASS' -and $same.New.Count -eq 0 -and $same.Gone.Count -eq 0)
    $reduced = [pscustomobject]@{ Entries = @($baseline.Entries | Where-Object { $_.Key -notlike '*BtnSave*' }) }
    $more = Compare-DomeniaUiBlockBaseline $findings $reduced
    & $check 'Nouvelle occurrence : echec' ($more.Status -eq 'FAIL' -and @($more.New | Where-Object { $_.Key -like '*BtnSave*' }).Count -eq 1)
    $extra = [pscustomobject]@{ Entries = @($baseline.Entries) + @([pscustomobject]@{ Key = 'self/Core.ps1|<script>|ancien | <gestionnaire> | Start-Sleep'; Count = 1; Category = 'Attente' }) }
    $less = Compare-DomeniaUiBlockBaseline $findings $extra
    & $check 'Occurrence disparue : signalee sans echec' ($less.Status -eq 'PASS' -and $less.Gone.Count -eq 1)
    $doubled = @($findings) + @($findings | Where-Object { $_.Key -like '*BtnSave*' })
    & $check 'Deuxieme appel identique : nouvelle occurrence' ((Compare-DomeniaUiBlockBaseline $doubled $baseline).Status -eq 'FAIL')
    & $check 'Sans ligne de base : echec' ((Compare-DomeniaUiBlockBaseline $findings $null).Status -eq 'NO_BASELINE')
    return $checks.ToArray()
}

# ---------------------------------------------------------------- main
$edition = 'Desktop'
if ($PSVersionTable.ContainsKey('PSEdition')) { $edition = [string]$PSVersionTable.PSEdition }
$hostInfo = [ordered]@{ Platform = $(if ($env:OS -eq 'Windows_NT') { 'Windows' } else { 'NonWindows' }); PSEdition = $edition; PSVersion = $PSVersionTable.PSVersion.ToString() }
$native51 = ($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)

if ($SelfTest) {
    $selfChecks = @(Invoke-DomeniaUiBlockSelfTest)
    $selfFailed = @($selfChecks | Where-Object { $_.Status -ne 'Passed' }).Count
    if ($ReportPath) { Write-DomeniaUiBlockJson $ReportPath ([ordered]@{ Kind = 'UiBlockingSelfTest'; Host = $hostInfo; NativeWindowsPowerShell51 = $native51; Passed = ($selfChecks.Count - $selfFailed); Failed = $selfFailed; Tests = $selfChecks }) }
    if (-not $Quiet) {
        Write-Host ('Auto-test D014 : ' + ($selfChecks.Count - $selfFailed) + ' reussis, ' + $selfFailed + ' en echec.')
        foreach ($item in $selfChecks) { if ($item.Status -ne 'Passed') { Write-Host ('  ECHEC ' + $item.Name + ' : ' + $item.Detail) } }
    }
    if ($selfFailed -gt 0) { exit 1 }
    exit 0
}

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$devRoot = [IO.Path]::GetFullPath($Root)
if (-not $BaselinePath) { $BaselinePath = Join-Path (Join-Path $devRoot 'tools') 'ui-blocking-debt-baseline.json' }
if (-not $ReportPath) { $ReportPath = Join-Path ([IO.Path]::GetTempPath()) ('Domenia-ui-blocking-' + [guid]::NewGuid().ToString('N') + '.json') }
$watch = [Diagnostics.Stopwatch]::StartNew()
try { $sources = @(Get-DomeniaUiBlockSources $devRoot) }
catch { Write-Host ('Audit impossible : ' + $_.Exception.Message); exit 2 }
$units = New-Object 'System.Collections.Generic.List[object]'
$parseErrors = New-Object 'System.Collections.Generic.List[string]'
foreach ($source in $sources) {
    $unit = New-DomeniaUiBlockUnit -Name $source.Name -Path $source.Path
    foreach ($message in $unit.Errors) { $parseErrors.Add($source.Name + ' ' + $message) }
    $units.Add($unit)
}
if ($parseErrors.Count -gt 0) {
    Write-Host ('Audit impossible : erreurs d analyse (' + $parseErrors.Count + ').')
    $parseErrors | Select-Object -First 20 | ForEach-Object { Write-Host ('  ' + $_) }
    exit 2
}
$run = Invoke-DomeniaUiBlockAudit $units.ToArray()
$findings = @($run.Findings)
$baseline = $null
$baselineState = 'Absente'
if ([IO.File]::Exists($BaselinePath)) {
    try { $baseline = [IO.File]::ReadAllText($BaselinePath,[Text.Encoding]::UTF8) | ConvertFrom-Json; $baselineState = 'Lue' }
    catch { Write-Host ('Ligne de base illisible : ' + $_.Exception.Message); exit 2 }
}
if ($UpdateBaseline) {
    Write-DomeniaUiBlockBaseline $BaselinePath (ConvertTo-DomeniaUiBlockBaseline $findings)
    $baseline = [IO.File]::ReadAllText($BaselinePath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    $baselineState = 'Regeneree'
}
$comparison = Compare-DomeniaUiBlockBaseline $findings $baseline
$top = @(Select-DomeniaUiBlockTop $findings 10)
$byCategory = [ordered]@{}
foreach ($category in @('Reseau','Attente','Stockage','Disque')) { $byCategory[$category] = @($findings | Where-Object { $_.Category -eq $category }).Count }
$handlersWithFindings = @($findings | ForEach-Object { $_.Handler.Id } | Sort-Object -Unique).Count
$report = [ordered]@{
    Kind = 'UiBlockingAudit'; Item = 'D014'; Host = $hostInfo; NativeWindowsPowerShell51 = $native51
    Root = $devRoot; Sources = @($sources | ForEach-Object { $_.Name }); ElapsedMs = [int]$watch.ElapsedMilliseconds
    Handlers = $run.Audit.Handlers.Count; HandlersWithBlockingCalls = $handlersWithFindings; UnresolvedRegistrations = $run.Audit.Unresolved.Count
    Functions = $run.Audit.Functions.Count; Occurrences = $findings.Count; ByCategory = $byCategory
    Baseline = [ordered]@{ Path = $BaselinePath; State = $baselineState; Total = $(if ($null -ne $baseline) { [int]$baseline.Total } else { 0 }) }
    Status = $comparison.Status; New = $comparison.New; Gone = $comparison.Gone
    Top = @($top | ForEach-Object { [ordered]@{ Text = (Format-DomeniaUiBlockFinding $_); Key = $_.Key; Category = $_.Category; Heuristic = $_.Heuristic; Handler = $_.Handler; Chain = $_.Chain; Call = $_.Call } })
    Limitations = $script:UiBlockLimitations
    Unresolved = $run.Audit.Unresolved.ToArray()
    Findings = @($findings | ForEach-Object { [ordered]@{ Key = $_.Key; Category = $_.Category; Heuristic = $_.Heuristic; Handler = $_.Handler; Chain = $_.Chain; Call = $_.Call } })
}
Write-DomeniaUiBlockJson $ReportPath $report
if (-not $Quiet) {
    Write-Host ('Audit D014 : ' + $run.Audit.Handlers.Count + ' gestionnaires, ' + $findings.Count + ' occurrences bloquantes (' + (@($byCategory.Keys | ForEach-Object { $_ + ' ' + $byCategory[$_] }) -join ', ') + '), ' + $run.Audit.Unresolved.Count + ' enregistrements non resolus.')
    Write-Host ('Ligne de base : ' + $baselineState + ' ; nouvelles : ' + $comparison.New.Count + ' ; disparues : ' + $comparison.Gone.Count + ' ; statut ' + $comparison.Status + '. Rapport : ' + $ReportPath)
    $index = 0
    foreach ($item in $top) { $index++; Write-Host ('  ' + $index + '. ' + (Format-DomeniaUiBlockFinding $item)) }
    foreach ($item in @($comparison.New | Select-Object -First 20)) { Write-Host ('  NOUVEAU ' + $item.Key + ' (' + $item.Baseline + ' -> ' + $item.Current + ')') }
}
if ($comparison.Status -ne 'PASS') { exit 1 }
exit 0
