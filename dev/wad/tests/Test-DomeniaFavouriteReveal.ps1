#requires -Version 5.1
# Portable state-machine fixtures. This is not a WPF or AD integration test.
[CmdletBinding()]param([string]$ReportPath='')
$ErrorActionPreference='Stop';$wad=Split-Path -Parent $PSScriptRoot
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
foreach($name in @('Common.Model','Continuity.Model','Continuity.UI')){. (Join-Path $wad ('modules/Domenia-'+$name+'.ps1'))}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules/Domenia-Guard.UI.ps1'),[ref]$tokens,[ref]$errors)
$fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Load-DomeniaFavouriteSearch'},$true)
. ([scriptblock]::Create($fn.Extent.Text))
$cases=[Collections.Generic.List[object]]::new()
function Assert {param($Value,[string]$Why='Assertion failed')if(-not $Value){throw $Why}}
function Case {param($Name,[scriptblock]$Body)Reset-Fixture;try{& $Body|Out-Null;$cases.Add([pscustomobject]@{Name=$Name;Passed=$true})}catch{$cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
function New-Node {
 param([string]$Dn,[bool]$Loaded=$true,[string]$Kind='OU')
 $n=[pscustomobject]@{Tag=[pscustomobject]@{DN=$Dn;Kind=$Kind;Loaded=$Loaded;Loading=$false;RenderId=''};Items=[Collections.ArrayList]::new();_Expanded=$false;_Selected=$false;Brought=$false}
 $n|Add-Member ScriptProperty IsExpanded {$this._Expanded} {param($value)$changed=$this._Expanded -ne $value;$this._Expanded=$value;if($changed -and $value -and -not $this.Tag.Loaded){Load-TreeChildren -Node $this}}
 $n|Add-Member ScriptProperty IsSelected {$this._Selected} {param($value)$this._Selected=$value;if($value){$script:SelectedBranchDn=$this.Tag.DN;if(-not $script:SuppressBranchAutoLoad){Stop-DomeniaFavouriteTreeReveal;Invoke-GlobalSearch OU}}}
 $n|Add-Member ScriptMethod BringIntoView {$this.Brought=$true}
 return $n
}
function Reset-Fixture {
 $script:FavouriteTreeReveal=$null;$script:FavouriteTreeRevealTimer=$null
 $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';BindUser='EXAMPLE\reader'}
 $script:SessionEpoch=1L;$script:GlobalSearchGeneration=1;$script:SelectedBranchDn='';$script:AsyncEngineClosing=$false
 $script:SuppressBranchAutoLoad=$false;$script:RestoringSettings=$false;$script:NavSearchLaunching=$false
 $script:Continuity=[pscustomobject]@{Restoring=$true;RestoreSearch='old';RestoreToken='';Dirty=$false}
 $script:Context='context';$script:Searches=0;$script:ScopeUpdates=0;$script:Busy=$false
 $script:Reads=[Collections.Generic.List[object]]::new();$script:Logs=[Collections.Generic.List[string]]::new();$script:Favs=@()
 $script:Root=New-Node $script:Conn.BaseDn
 $script:Tree=[pscustomobject]@{Items=[Collections.ArrayList]::new()};[void]$script:Tree.Items.Add($script:Root)
 $script:Controls=@{TvDirectory=$script:Tree;ChkSubtree=[pscustomobject]@{IsChecked=$false};TxtSuiteResultFilter=[pscustomobject]@{Text=''};LblTreeStatus=[pscustomobject]@{Text=''};TxtBranchSearch=[pscustomobject]@{Text='old'}}
}
function New-DomeniaTimer {param($Owner,$IntervalMs,$Tick)$t=[pscustomobject]@{Running=$false};$t|Add-Member ScriptMethod Start {$this.Running=$true};$t|Add-Member ScriptMethod Stop {$this.Running=$false};return $t}
function Get-DomeniaControl {param($Name)return $script:Controls[$Name]}
function Set-DomeniaControlText {param($Name,$Value)if($script:Controls.ContainsKey($Name)){$script:Controls[$Name].Text=$Value};return $true}
function Set-Status {param($Text,$Level)$script:Logs.Add($Text)}
function Get-CfgValue {param($Section,$Name,$Default)return $Default}
function Get-DomeniaTreeContextKey {return $script:Context}
function Test-DomeniaAccessBusyWrite {return $script:Busy}
function Test-DomeniaDraftNavigation {return $true}
function Update-DomeniaSearchScopeUi {$script:ScopeUpdates++}
function Select-DomeniaWorkspace {param($Workspace)}
function Invoke-GlobalSearch {param($SearchMode,[switch]$KeepLocalFilter)$script:Searches++;$script:GlobalSearchGeneration++;$script:KeptLocalFilter=[bool]$KeepLocalFilter}
function Load-TreeChildren {param($Node)$script:Reads.Add($Node);$Node.Tag.Loading=$true}
function Get-DomeniaFavouriteSearches {return $script:Favs}
function Start-Favourite {param($Dn)$script:Favs=@([pscustomobject]@{DN=$Dn;Name='Target';Subtree=$true;Type='Machines';Term=''});Load-DomeniaFavouriteSearch -Dn $Dn}
function Drain {for($i=0;$i -lt 1000 -and $null -ne $script:FavouriteTreeReveal;$i++){Invoke-DomeniaFavouriteTreeReveal};Assert ($null -eq $script:FavouriteTreeReveal) 'Reveal did not terminate'}
Case 'Deep loaded favourite expands each ancestor and searches only once' {
 $a=New-Node ('OU=A,'+$script:Root.Tag.DN);$b=New-Node ('OU=B,'+$a.Tag.DN);$c=New-Node ('OU=C,'+$b.Tag.DN)
 [void]$script:Root.Items.Add($a);[void]$a.Items.Add($b);[void]$b.Items.Add($c)
 Start-Favourite $c.Tag.DN;Drain
 Assert ($script:Root.IsExpanded -and $a.IsExpanded -and $b.IsExpanded);Assert ($c.IsSelected -and $c.Brought);Assert ($script:Searches -eq 1);Assert ($script:Reads.Count -eq 0)
 # CO-05: the term of a favourite is the filter of its list, kept by the search it launches.
 Assert ([bool]$script:KeptLocalFilter) 'Le favori ne garde pas son filtre de liste'
 Assert (-not $script:Continuity.Restoring);Assert ($null -eq $script:Continuity.RestoreSearch);Assert (-not $script:FavouriteTreeRevealTimer.Running)
}
Case 'Unloaded ancestors wait for existing one-level readers without duplicate content searches' {
 $script:Root.Tag.Loaded=$false;$dn='OU=B,OU=A,'+$script:Root.Tag.DN
 Start-Favourite $dn;Assert ($script:Reads.Count -eq 1)
 Invoke-DomeniaFavouriteTreeReveal;Assert ($script:Reads.Count -eq 1)
 $a=New-Node ('OU=A,'+$script:Root.Tag.DN) $false;[void]$script:Root.Items.Add($a);$script:Root.Tag.Loading=$false;$script:Root.Tag.Loaded=$true
 Invoke-DomeniaFavouriteTreeReveal;Assert ($script:Reads.Count -eq 2)
 $b=New-Node $dn;[void]$a.Items.Add($b);$a.Tag.Loading=$false;$a.Tag.Loaded=$true;Drain
 Assert $b.IsSelected;Assert ($script:Searches -eq 1)
}
Case 'Escaped comma RDN is preserved as a single ancestor' {
 $dn='OU=Help\, Desk,'+$script:Root.Tag.DN;$a=New-Node $dn;[void]$script:Root.Items.Add($a)
 $p=Get-DomeniaTreeRevealPath $dn $script:Root.Tag.DN;Assert ($p.Count -eq 2);Start-Favourite $dn;Drain;Assert $a.IsSelected
}
Case 'No arbitrary 600-node ceiling: target after 20000 siblings is revealed incrementally' {
 for($i=0;$i -lt 20000;$i++){[void]$script:Root.Items.Add((New-Node ('OU=N'+$i+','+$script:Root.Tag.DN)))}
 $a=New-Node ('OU=Target,'+$script:Root.Tag.DN);[void]$script:Root.Items.Add($a)
 Start-Favourite $a.Tag.DN;Assert ($null -ne $script:FavouriteTreeReveal);Assert (-not $a.IsSelected);Drain
 Assert $a.IsSelected;Assert ($script:Searches -eq 1)
}
Case 'System folder grouping is transparent and expanded around the target' {
 $group=New-Node '' $true SystemGroup;$a=New-Node ('CN=Computers,'+$script:Root.Tag.DN)
 [void]$script:Root.Items.Add($group);[void]$group.Items.Add($a);Start-Favourite $a.Tag.DN;Drain
 Assert ($group.IsExpanded -and $a.IsSelected)
}
Case 'Second favourite supersedes pending reveal and keeps its own results' {
 $a=New-Node ('OU=A,'+$script:Root.Tag.DN) $false;$b=New-Node ('OU=B,'+$script:Root.Tag.DN)
 [void]$script:Root.Items.Add($a);[void]$script:Root.Items.Add($b)
 Start-Favourite ('OU=Child,'+$a.Tag.DN);Assert ($null -ne $script:FavouriteTreeReveal)
 Start-Favourite $b.Tag.DN;Drain;Assert $b.IsSelected;Assert (-not $a.IsSelected);Assert ($script:Searches -eq 2)
}
foreach($condition in @('Epoch','Generation','Context','Selection','Closing','RootReplaced')){
 Case ('Stale reveal canceled on '+$condition) {
  $script:Root.Tag.Loaded=$false;Start-Favourite ('OU=Target,'+$script:Root.Tag.DN)
  switch($condition){Epoch{$script:SessionEpoch++}Generation{$script:GlobalSearchGeneration++}Context{$script:Context='other'}Selection{$script:SelectedBranchDn='elsewhere'}Closing{$script:AsyncEngineClosing=$true}RootReplaced{$script:Tree.Items.Clear()}}
  Invoke-DomeniaFavouriteTreeReveal;Assert ($null -eq $script:FavouriteTreeReveal);Assert ($script:Searches -eq 1);Assert (-not $script:Root.IsSelected)
 }
}
Case 'Failed child read never automatically retries authentication or query' {
 $script:Root.Tag.Loaded=$false;Start-Favourite ('OU=Target,'+$script:Root.Tag.DN);$script:Root.Tag.Loading=$false
 Drain;Assert ($script:Reads.Count -eq 1);Assert ($script:Searches -eq 1);Assert ($script:Logs.Count -eq 1)
}
Case 'Missing child never substitutes the domain or destroys results' {
 Start-Favourite ('OU=Missing,'+$script:Root.Tag.DN);Drain
 Assert (-not $script:Root.IsSelected);Assert ($script:Searches -eq 1);Assert ($script:SelectedBranchDn -like 'OU=Missing,*')
}
Case 'Root favourite selects root without enumerating children' {
 $script:Root.Tag.Loaded=$false;Start-Favourite $script:Root.Tag.DN;Drain;Assert $script:Root.IsSelected;Assert ($script:Reads.Count -eq 0)
}
Case 'Empty root waits for tree initialization and handles singleton collection' {
 $script:Tree.Items.Clear();Start-Favourite $script:Root.Tag.DN;Assert ($null -ne $script:FavouriteTreeReveal)
 [void]$script:Tree.Items.Add($script:Root);Drain;Assert $script:Root.IsSelected
}
Case 'Timeout is an unconfirmed tree location, never an AD unavailable claim' {
 $script:Root.Tag.Loaded=$false;Start-Favourite ('OU=Target,'+$script:Root.Tag.DN)
 $script:FavouriteTreeReveal.IdleDeadline=[datetime]::UtcNow.AddSeconds(-1);Drain
 Assert ($script:Logs.Count -eq 1);Assert ($script:Logs[0] -notmatch 'AD.*injoignable|supprim');Assert ($script:Searches -eq 1)
}
Case 'Busy write defers traversal without starting a new read' {
 $script:Root.Tag.Loaded=$false;$script:Busy=$true;$script:SelectedBranchDn='OU=Target,'+$script:Root.Tag.DN
 Start-DomeniaFavouriteTreeReveal $script:SelectedBranchDn;Assert ($script:Reads.Count -eq 0);$script:Busy=$false;Invoke-DomeniaFavouriteTreeReveal;Assert ($script:Reads.Count -eq 1)
}
Case 'Out-of-domain and escaped suffix impostors are rejected' {
 Assert ((Get-DomeniaTreeRevealPath 'OU=A,DC=other,DC=invalid' $script:Root.Tag.DN).Count -eq 0)
 Assert ((Get-DomeniaTreeRevealPath ('OU=A\,'+$script:Root.Tag.DN) $script:Root.Tag.DN).Count -eq 0)
 Assert ((Get-DomeniaTreeRevealPath '' $script:Root.Tag.DN).Count -eq 0)
}
Case 'Programmatic suppression is restored after selection throws' {
 $script:Root|Add-Member ScriptMethod BringIntoView {throw 'fixture failure'} -Force
 $script:SelectedBranchDn=$script:Root.Tag.DN
 try{Start-DomeniaFavouriteTreeReveal $script:Root.Tag.DN;throw 'Expected fixture failure'}catch{Assert ($_.Exception.Message -match 'fixture failure')}
 Assert (-not $script:SuppressBranchAutoLoad)
}
$failed=@($cases|Where-Object{-not $_.Passed});$report=[pscustomobject]@{Suite='FavouriteReveal';Passed=$cases.Count-$failed.Count;Failed=$failed.Count;NativeWpfValidated=$false;NetworkCalls=0;Cases=$cases.ToArray()}
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1}
