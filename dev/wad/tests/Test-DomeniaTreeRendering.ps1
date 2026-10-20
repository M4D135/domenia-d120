#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Windows PowerShell STA required.' }
$wad=Split-Path $PSScriptRoot -Parent
. (Join-Path $wad 'modules/Domenia-DirectoryTree.UI.ps1')
Add-DomeniaDirectoryTreeTypes
$core=Join-Path $wad 'Domenia-Core.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($core,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
foreach($name in @('New-DomeniaTreeRowItem','New-DomeniaTreeSystemGroup','Initialize-DomeniaTreeRenderTimer','Stop-DomeniaTreeRenderForNode','Clear-DomeniaTreeRenderJobs','Queue-DomeniaTreeRowsToNode')){
    $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
    if($nodes.Count -ne 1){throw ('Missing real function: '+$name)}
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
# Scheduling and fault injection are isolated; real DTO types and production render functions. No Dispatcher/network.
function Get-CfgValue {param($Section,$Name,$Default);if($Name -eq 'TreeRenderBatchSize'){return $script:Quota};return $Default}
function New-DomeniaTimer {
    param($Owner,$IntervalMs,$Tick)
    $script:TreeTick=$Tick
    $timer=[pscustomobject]@{IsEnabled=$false}
    $timer|Add-Member ScriptMethod Start {$this.IsEnabled=$true}
    $timer|Add-Member ScriptMethod Stop {$this.IsEnabled=$false}
    return $timer
}
function Get-DomeniaTreeRenderRows {param($Node,$Rows);return $Rows}
function New-TreeItem {
    param($Name,$Dn,$Kind)
    if($script:ThrowName -and $Name -like ('*'+$script:ThrowName)){throw 'Injected construction failure'}
    $node=[Domenia.Tree.DomeniaTreeItem]::new();$node.Header=$Name
    $node.Tag=[pscustomobject]@{DN=$Dn;Kind=$Kind;Loaded=$false;RenderId='';Loading=$false}
    return $node
}
function Set-DomeniaControlText {param($Name,$Text)}
function Set-Status {param($Text)}
function Update-DomeniaOuTreeFilter {param([switch]$OnlyWhenActive)}
function Write-AppLog {param($Message,$Level);if($Level -eq 'ERROR'){$script:RenderErrors.Add([string]$Message)}}
function Write-DomeniaSwallowed {param($Area,$Where,$ErrorRecord);$script:RenderErrors.Add([string]$ErrorRecord)}
function Assert-Render {param([bool]$Condition,[string]$Message);if(-not $Condition){throw $Message}}
function Reset-Render {param([bool]$Ordered=$true)
    $script:TreeRenderJobs=if($Ordered){[ordered]@{}}else{@{}}
    $script:TreeRenderTimer=$null;$script:TreeTick=$null;$script:Quota=8;$script:ThrowName=''
    $script:RenderErrors=[Collections.Generic.List[string]]::new()
}
function New-Rows {param([int]$Count,[string]$Prefix)
    for($i=0;$i -lt $Count;$i++){[pscustomobject]@{Name=($Prefix+$i);DN=('CN='+$Prefix+$i);Kind='Conteneur'}}
}
function Count-Nodes {param($Node)
    $count=0
    foreach($child in $Node.Items){if($child -is [Domenia.Tree.DomeniaTreeItem]){$count++;$count+=Count-Nodes $child}}
    return $count
}
function Drain-Render {
    for($i=0;$i -lt 1500 -and $script:TreeRenderJobs.Count;$i++){& $script:TreeTick}
    Assert-Render ($script:TreeRenderJobs.Count -eq 0) 'Render jobs did not finish within the bounded number of slices.'
    Assert-Render (-not $script:TreeRenderTimer.IsEnabled) 'Timer stayed active with no jobs.'
}
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)
    try{& $Body;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.Message})}
}
foreach($ordered in @($true,$false)){
    Case ('Global quota, fair branches and parent completion; ordered='+$ordered) {
        Reset-Render -Ordered $ordered
        $root=New-TreeItem 'Root' 'DC=example' 'domainDNS';$other=New-TreeItem 'Other' 'OU=Other' 'OU'
        $rows=@(New-Rows 300 'System')
        Queue-DomeniaTreeRowsToNode $root @([pscustomobject]@{Kind='SystemGroup';Rows=$rows})
        Queue-DomeniaTreeRowsToNode $other @(New-Rows 300 'Visible')
        Assert-Render (-not $root.Tag.Loaded -and [bool]$root.Tag.RenderId) 'Parent was published before its group.'
        for($i=0;$i -lt 20;$i++){
            $before=(Count-Nodes $root)+(Count-Nodes $other)
            & $script:TreeTick
            $after=(Count-Nodes $root)+(Count-Nodes $other)
            Assert-Render (($after-$before) -le $script:Quota) 'Per-branch quotas exceeded the global quota.'
        }
        Assert-Render ($root.Items.Count -eq 1 -and $root.Items[0].Items.Count -gt 0 -and $other.Items.Count -gt 0) 'One branch starved while the other rendered.'
        $group=$root.Items[0]
        Assert-Render ($group.Items.Count -lt 300 -and -not $group.Tag.Loaded -and -not $root.Tag.Loaded -and [bool]$root.Tag.RenderId) 'System children were built synchronously or parent completed too soon.'
        Drain-Render
        Assert-Render ($root.Tag.Loaded -and -not $root.Tag.RenderId -and $group.Tag.Loaded -and -not $group.Tag.RenderId -and $group.Items.Count -eq 300 -and $other.Items.Count -eq 300) 'Final parent/group state or contents are incomplete.'
        Assert-Render ($script:RenderErrors.Count -eq 0) 'Unexpected render error.'
    }
}
Case 'Cancellation and replacement abandon the pending system group' {
    Reset-Render;$script:Quota=1
    $root=New-TreeItem 'Root' 'DC=example' 'domainDNS'
    Queue-DomeniaTreeRowsToNode $root @([pscustomobject]@{Kind='SystemGroup';Rows=@(New-Rows 300 'Old')})
    for($i=0;$i -lt 20 -and $root.Items.Count -eq 0;$i++){& $script:TreeTick}
    Assert-Render ($root.Items.Count -eq 1) 'Group shell was not rendered.'
    $oldGroup=$root.Items[0];$before=$oldGroup.Items.Count
    Stop-DomeniaTreeRenderForNode $root
    & $script:TreeTick
    Assert-Render ($script:TreeRenderJobs.Count -eq 0 -and -not $root.Tag.RenderId -and -not $root.Tag.Loaded) 'Cancellation retained a job or published completion.'
    Queue-DomeniaTreeRowsToNode $root @(New-Rows 1 'New')
    Drain-Render
    Assert-Render ($oldGroup.Items.Count -eq $before -and $root.Items.Count -eq 1 -and [string]$root.Items[0].Header -like '*New0') 'A cancelled group appended after replacement.'
}
Case 'Failed system child never publishes Loaded and does not block another branch' {
    Reset-Render;$script:ThrowName='Bad0'
    $root=New-TreeItem 'Root' 'DC=example' 'domainDNS';$other=New-TreeItem 'Other' 'OU=Other' 'OU'
    Queue-DomeniaTreeRowsToNode $root @([pscustomobject]@{Kind='SystemGroup';Rows=@(New-Rows 3 'Bad')})
    Queue-DomeniaTreeRowsToNode $other @(New-Rows 3 'Good')
    Drain-Render
    Assert-Render (-not $root.Tag.Loaded -and -not $root.Tag.RenderId -and $root.Items.Count -eq 1 -and [string]$root.Items[0].Tag.Kind -eq 'Placeholder') 'Failed parent was marked Loaded or kept partial containers.'
    Assert-Render ($other.Tag.Loaded -and $other.Items.Count -eq 3 -and $script:RenderErrors.Count -eq 1) 'Failure blocked another branch or was not traced.'
}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaTreeRendering';Passed=($failed -eq 0);Total=$checks.Count;Failed=$failed;PowerShell=$PSVersionTable.PSVersion.ToString();RealWpf=$false;RealDataTypes=$true;SyntheticOnly=$true;CoreSha256=(Get-FileHash $core -Algorithm SHA256).Hash;Cases=$checks.ToArray();Limitations='Cooperative scheduling with production data types; no AD, container virtualization or real-time deadline qualification (separate WPF suite).'}
$json=$report|ConvertTo-Json -Depth 6
if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
$json
if($failed){throw ('Tree rendering failures: '+$failed)}
