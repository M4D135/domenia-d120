#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
# Inert UI ports only. Execute the actual counter expressions and live-search completion/error
# callbacks extracted from the module. No WPF, LDAP, cache database, network or timer is started.
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Domenia-DirectoryStore.UI.ps1')
$source=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Domenia-Live.UI.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw ('Live.UI parse error: '+$errors[0].Message)}
$script:Sites=@{}
foreach($name in @('Update-DomeniaLiveFilter','Invoke-DomeniaLiveTick')){
    $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($functions.Count -ne 1){throw ('Missing or ambiguous function: '+$name)}
    $calls=@($functions[0].Body.FindAll({param($n)
        $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-DomeniaControlText' -and
        $n.CommandElements.Count -ge 3 -and $n.CommandElements[1].Value -eq 'LblSuiteResultCount'
    },$true))
    if($calls.Count -ne 1){throw ('Expected exactly one result counter in '+$name)}
    $script:Sites[$name]=[scriptblock]::Create($calls[0].Extent.Text)
}
foreach($name in @('Complete-DomeniaLiveSearch','Fail-DomeniaLiveSearch','Stop-DomeniaLiveJob')){
    $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($functions.Count -ne 1){throw ('Missing or ambiguous function: '+$name)}
    . ([scriptblock]::Create($functions[0].Extent.Text))
}
function New-DomeniaTimer {param($Owner,$IntervalMs,[switch]$RunWhenHidden,$Tick);$t=[pscustomobject]@{};$t|Add-Member ScriptMethod Start {};$t|Add-Member ScriptMethod Stop {};return $t}
function Test-DomeniaLiveSearchActive {return $true}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties)return $Result}
function Write-AppLog {param($Text,$Level)}
function Get-DomeniaSearchMode {return $script:Mode}
function Set-DomeniaControlText {param($Name,$Text)$script:Label=[string]$Text;return $true}
$script:Checks=[Collections.Generic.List[object]]::new();$script:Assertions=0
function Expect {param([bool]$Condition,[string]$Message)$script:Assertions++;if(-not $Condition){throw $Message}}
function Reset-Fixture {
    $script:DomeniaDirectoryReads=@{};$script:DomeniaDirectoryStoreTimer=$null
    $script:Mode='OU';$script:Label=''
    # Collections are represented only by their Count property, preserving the exact production reads.
    $script:grid=[pscustomobject]@{Items=[pscustomobject]@{Count=746}}
    $script:s=[pscustomobject]@{Rows=[pscustomobject]@{Count=746};Error='';Ended=$false;Finalized=$false;Final=$null;Stop=[Threading.CancellationTokenSource]::new();CacheProgress=[Collections.Concurrent.ConcurrentQueue[object]]::new()}
    $pipe=New-DomeniaDirectoryReadPipe -Context ([pscustomobject]@{RequestId='fixture'}) -Search $script:s
    $script:s|Add-Member NoteProperty DirectoryPipe $pipe
    $script:Live=[pscustomobject]@{Search=$script:s}
    $script:State=[pscustomobject]@{BaseDn='OU=Site,DC=example,DC=invalid';Scope='Subtree';LiveState=$script:s}
}
function Case {param([string]$Name,[scriptblock]$Body)
    Reset-Fixture
    try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
    finally{$script:s.Stop.Dispose()}
}
function Check-Counters {param([string]$Prefix,[int]$Visible=746,[int]$Loaded=746)
    Invoke-DomeniaDirectoryStoreTick
    $script:grid.Items.Count=$Visible;$script:s.Rows.Count=$Loaded
    # CO-05: one wording for every list, the filter of the list applies to global searches too.
    $expected=$Prefix+"$Visible / $Loaded lignes visibles · filtre de la liste"
    foreach($entry in $script:Sites.GetEnumerator()){
        $script:Label='';[void](& $entry.Value)
        Expect ($script:Label -ceq $expected) ($entry.Key+' produced: '+$script:Label+'; expected: '+$expected)
    }
}
function Complete-Fixture {param([bool]$Partial=$false,[string]$Failure='',[bool]$Limited=$false)
    Complete-DomeniaLiveSearch ([pscustomobject]@{Rows=@();BaseDn=$script:State.BaseDn;Scope=$script:State.Scope;Partial=$Partial;Failure=$Failure;LimitReached=$Limited}) $script:State
}
Case 'Running search never presents its loaded fraction as a complete list' {Check-Counters 'Chargement… · '}
Case 'Empty cache preview remains loading' {Check-Counters 'Chargement… · ' 0 0}
Case 'Timeout marks both counters partial before UI queue finalization' {
    Fail-DomeniaLiveSearch 'Timeout apres 45s : Recherche dans l annuaire' $script:State
    Invoke-DomeniaDirectoryStoreTick
    Expect ($script:s.Stop.IsCancellationRequested -and $script:s.Ended) 'Actual failure callback did not end/cancel the read'
    Check-Counters 'Liste partielle · '
}
Case 'Finalized timeout retains the partial marker with all loaded rows visible' {
    Fail-DomeniaLiveSearch 'Timeout apres 45s : Recherche dans l annuaire' $script:State
    $script:s.Finalized=$true;Check-Counters 'Liste partielle · '
}
Case 'Local filtering cannot hide that the source list is partial' {
    Fail-DomeniaLiveSearch 'LDAP read failed' $script:State
    $script:s.Finalized=$true;Check-Counters 'Liste partielle · ' 12 746
}
Case 'Explicit cancellation uses the existing live stop marker' {
    Stop-DomeniaLiveJob ([pscustomobject]@{OperationId='GlobalSearch';CallbackState=$script:State;Superseded=$false})
    Invoke-DomeniaDirectoryStoreTick
    Expect ($script:s.Error -like 'Lecture interrompue*') 'Actual cancellation callback lost its partial marker'
    Check-Counters 'Liste partielle · '
}
Case 'Partial LDAP result is visibly partial even without a supplied reason' {
    Complete-Fixture -Partial $true
    Invoke-DomeniaDirectoryStoreTick
    Expect ($script:s.Error -ceq 'Résultat LDAP partiel.') 'Fallback partial-result reason missing'
    $script:s.Finalized=$true;Check-Counters 'Liste partielle · '
}
Case 'Partial LDAP reason takes priority over a reached display limit' {
    Complete-Fixture -Partial $true -Failure 'Server time limit reached' -Limited $true
    $script:s.Finalized=$true;Check-Counters 'Liste partielle · '
}
Case 'A successful result still draining the UI queue remains loading' {
    Complete-Fixture;Check-Counters 'Chargement… · '
}
Case 'A successful finalized full list keeps the ordinary visible fraction' {
    Complete-Fixture;$script:s.Finalized=$true;Check-Counters ''
}
Case 'The result limit has its own marker and is never labelled a timeout' {
    Complete-Fixture -Limited $true;$script:s.Finalized=$true;Check-Counters 'Limite atteinte · ' 10000 10000
}
Case 'Global search counter keeps the partial marker and reads like any filtered list (CO-05)' {
    $script:Mode='Global';Fail-DomeniaLiveSearch 'Timeout apres 45s' $script:State
    $script:s.Finalized=$true;Check-Counters 'Liste partielle · '
}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$report=[pscustomobject]@{Status=$(if($failed.Count){'FAIL'}else{'PASS'});Scope='Actual production counter expressions and callbacks through inert ports; no Windows GUI or AD validation';PowerShell=$PSVersionTable.PSVersion.ToString();SourceSha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant();Cases=$script:Checks.Count;Assertions=$script:Assertions;Failed=$failed.Count;Results=$script:Checks.ToArray()}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent -and -not (Test-Path -LiteralPath $parent)){[void](New-Item -ItemType Directory -Path $parent -Force)};$report|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
