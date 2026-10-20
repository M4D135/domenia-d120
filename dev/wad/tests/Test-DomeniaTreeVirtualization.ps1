#requires -Version 5.1
[CmdletBinding()]param([string]$ReportPath='',[switch]$PanelDiagnosticOnly)
$ErrorActionPreference='Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Windows PowerShell 5.1 STA required.' }
$wad=Split-Path -Parent $PSScriptRoot
. (Join-Path $wad 'modules/Domenia-DirectoryTree.UI.ps1')
Add-DomeniaDirectoryTreeTypes
. (Join-Path $wad 'modules/Domenia-Common.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Search.Model.ps1')
. (Join-Path $wad 'modules/Domenia-Continuity.Model.ps1')
foreach($source in @(
    [pscustomobject]@{File='Domenia-Core.ps1';Names=@('New-TreeItem','New-DomeniaTreeRowItem','New-DomeniaTreeSystemGroup')},
    [pscustomobject]@{File='modules/Domenia-Search.UI.ps1';Names=@('Get-DomeniaOuTreeNodeName','Update-DomeniaOuTreeFilter','Stop-DomeniaOuTreeFilter','Invoke-DomeniaOuTreeFilterSlice','Find-DomeniaRealizedTreeNode','Select-DomeniaRealizedTreeNode')}
)){
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad $source.File),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw $errors[0].Message}
    foreach($name in $source.Names){
        $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        if($functions.Count -ne 1){throw ('Production function missing: '+$name)}
        . ([scriptblock]::Create($functions[0].Extent.Text))
    }
}
function Assert-Tree {param($Value,[string]$Reason) if(-not $Value){throw $Reason}}
function Get-DomeniaControl {param($Name) return $script:Controls[$Name]}
function Set-DomeniaControlText {param($Name,$Text) $script:Controls[$Name].Text=$Text}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function New-DomeniaTimer {param($Owner,$IntervalMs,$Tick)
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds($IntervalMs);$timer.Add_Tick($Tick);return $timer
}
function Write-DomeniaSwallowed {param($Area,$Name,$ErrorRecord) throw ('Unexpected error '+$Area+'/'+$Name+': '+$ErrorRecord)}
function Load-TreeChildren {param($Node) $script:Reads.Add([string]$Node.Tag.DN);$Node.Tag.Loading=$true}
function Set-SelectedBranch {param($Node)
    $script:SelectedBranchDn=[string]$Node.Tag.DN
    if(-not $script:SuppressBranchAutoLoad){$script:Searches++}
}
function Pump-Tree {
    $frame=[Windows.Threading.DispatcherFrame]::new()
    $exit=[Windows.Threading.DispatcherTimer]::new();$exit.Interval=[TimeSpan]::FromMilliseconds(35)
    $handler={param($sender,$args)$sender.Stop();$frame.Continue=$false}.GetNewClosure()
    $exit.Add_Tick($handler)
    $exit.Start();[Windows.Threading.Dispatcher]::PushFrame($frame);$script:Window.UpdateLayout()
}
function Drain-Reveal {
    $limit=[datetime]::UtcNow.AddSeconds(10)
    while($null -ne $script:DomeniaTreeItemReveal -and [datetime]::UtcNow -lt $limit){Pump-Tree}
    if($null -ne $script:DomeniaTreeItemReveal){
        $pending=$script:DomeniaTreeItemReveal;$details=[Collections.Generic.List[object]]::new()
        $owner=$script:Tree
        foreach($node in $pending.Path){
            if($null -eq $owner){break}
            $container=[Domenia.Tree.DomeniaTreeSupport]::ContainerFromItem($owner,$node)
            $panel=[Domenia.Tree.DomeniaTreeSupport]::FindPanel($owner)
            $details.Add([pscustomobject]@{Node=[string]$node.Header;Index=$owner.Items.IndexOf($node);Container=($null -ne $container);Expanded=[bool]$node.IsExpanded;Panel=$(if($null -ne $panel){$panel.GetType().FullName}else{'missing'});PanelHeight=$(if($null -ne $panel){$panel.ActualHeight}else{-1});Offset=$(if($null -ne $panel){$panel.VerticalOffset}else{-1})})
            $owner=$container
        }
        $diagnostic=[pscustomobject]@{PendingLevel=$pending.Level;Path=$details.ToArray()}
        $script:Measurements.Add($diagnostic)
        throw ('Target reveal did not finish: '+($diagnostic|ConvertTo-Json -Depth 5 -Compress))
    }
    Pump-Tree
}
function Count-Generated {
    # ContainerFromIndex inspects the generator; it does not generate missing containers.
    $count=0;$queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue($script:Tree)
    while($queue.Count){
        $owner=$queue.Dequeue()
        for($i=0;$i -lt $owner.Items.Count;$i++){
            $container=$owner.ItemContainerGenerator.ContainerFromIndex($i)
            if($null -eq $container){continue}
            $count++;$queue.Enqueue($container)
            $identity=[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($container)
            if(-not $script:ContainerRefs.ContainsKey($identity)){$script:ContainerRefs[$identity]=[WeakReference]::new($container)}
        }
    }
    return $count
}
function Get-TreePanelDiagnostic {param($Owner)
    $panels=[Collections.Generic.List[object]]::new();$presenters=[Collections.Generic.List[object]]::new()
    $queue=[Collections.Generic.Queue[object]]::new();$queue.Enqueue($Owner);$visited=0
    while($queue.Count -gt 0 -and $visited -lt 256){
        $visual=$queue.Dequeue();$visited++
        if($visual -is [Windows.Controls.TreeViewItem] -and -not [object]::ReferenceEquals($visual,$Owner)){continue}
        if($visual -is [Windows.Controls.Panel]){
            $itemsOwner=[Windows.Controls.ItemsControl]::GetItemsOwner($visual)
            $panels.Add([pscustomobject]@{Type=$visual.GetType().FullName;IsItemsHost=$visual.IsItemsHost;ItemsOwnerType=$(if($null -ne $itemsOwner){$itemsOwner.GetType().FullName}else{''});OwnPanel=[object]::ReferenceEquals($itemsOwner,$Owner);Height=$visual.ActualHeight})
        }
        if($visual -is [Windows.Controls.ItemsPresenter]){$presenters.Add($visual)}
        for($i=0;$i -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($visual);$i++){$queue.Enqueue([Windows.Media.VisualTreeHelper]::GetChild($visual,$i))}
    }
    $source=[Windows.DependencyPropertyHelper]::GetValueSource($Owner,[Windows.Controls.ItemsControl]::ItemsPanelProperty)
    $panelType='';if($null -ne $Owner.ItemsPanel -and $null -ne $Owner.ItemsPanel.VisualTree){$panelType=$Owner.ItemsPanel.VisualTree.Type.FullName}
    $triggers=[Collections.Generic.List[object]]::new();$style=$Owner.Style;$depth=0
    while($null -ne $style -and $depth -lt 8){
        foreach($trigger in $style.Triggers){
            if($trigger -isnot [Windows.Trigger]){continue}
            foreach($setter in $trigger.Setters){if($setter -is [Windows.Setter] -and $setter.Property -eq [Windows.Controls.ItemsControl]::ItemsPanelProperty){$triggers.Add([pscustomobject]@{Depth=$depth;Property=$trigger.Property.Name;Value=[string]$trigger.Value;PanelType=$setter.Value.VisualTree.Type.FullName})}}
        }
        $style=$style.BasedOn;$depth++
    }
    return [pscustomobject]@{OwnerType=$Owner.GetType().FullName;ItemsPanelType=$panelType;ValueSource=[string]$source.BaseValueSource;Panels=$panels.ToArray();PresenterCount=$presenters.Count;Presenters=$presenters.ToArray();ItemsPanelTriggers=$triggers.ToArray();Visited=$visited}
}
function Select-TestNode {param($Node)
    $script:SelectedBranchDn=[string]$Node.Tag.DN
    Assert-Tree (Start-DomeniaTreeItemReveal -Node $Node -Purpose 'test') 'Reveal refused a loaded data node.'
    Drain-Reveal
    $container=Get-DomeniaTreeContainerForItem -Tree $script:Tree -Node $Node
    Assert-Tree ($null -ne $container -and $container.IsSelected -and [object]::ReferenceEquals($script:Tree.SelectedItem,$Node)) 'Off-screen target was not selected in WPF.'
    $position=$container.TranslatePoint([Windows.Point]::new(0,0),$script:Tree)
    Assert-Tree ($position.Y -ge -2 -and $position.Y -lt $script:Tree.ActualHeight) ('Selected target remains outside viewport: '+$position.Y)
    $generated=Count-Generated
    Assert-Tree ($generated -lt 300) ('Too many WPF containers: '+$generated)
    $script:Measurements.Add([pscustomobject]@{Target=[string]$Node.Tag.DN;Generated=$generated})
}
$script:Controls=@{};$script:Reads=[Collections.Generic.List[string]]::new();$script:Searches=0
$script:ContainerRefs=@{};$script:Measurements=[Collections.Generic.List[object]]::new()
$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';BindUser='reader'}
$script:SessionEpoch=1L;$script:GlobalSearchGeneration=1;$script:AsyncEngineClosing=$false;$script:SuppressBranchAutoLoad=$false
$script:OuFavouriteKeys=@{};$script:SelectedBranchDn=$script:Conn.BaseDn
$script:Tree=[Windows.Controls.TreeView]::new();$script:Controls.TvDirectory=$script:Tree
$script:Controls.TxtOuFilter=[Windows.Controls.TextBox]::new();$script:Controls.LblTreeStatus=[Windows.Controls.TextBlock]::new()
$script:Window=[Windows.Window]::new();$script:Window.Width=480;$script:Window.Height=360;$script:Window.ShowActivated=$false;$script:Window.ShowInTaskbar=$false
$script:Window.Content=$script:Tree
$checks=[Collections.Generic.List[object]]::new()
function Case {param($Name,[scriptblock]$Body)try{& $Body;$checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}catch{$checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=($_.Exception.Message+' '+$_.ScriptStackTrace)})}}
try{
    [void](Initialize-DomeniaDirectoryTree -Tree $script:Tree)
    $root=New-TreeItem 'example.invalid' $script:Conn.BaseDn 'domainDNS';$root.Items.Clear();$root.Tag.Loaded=$true
    for($i=0;$i -lt 10000;$i++){
        $name='item-'+$i.ToString('D5');$node=New-TreeItem $name ('OU='+$name+','+$script:Conn.BaseDn) 'OU'
        $node.Items.Clear();$node.Tag.Loaded=$true;[void]$root.Items.Add($node)
    }
    $group=New-DomeniaTreeSystemGroup -Rows @([pscustomobject]@{Name='SystemTarget';DN=('CN=SystemTarget,'+$script:Conn.BaseDn);Kind='Conteneur'})
    [void]$root.Items.Add($group);$system=$group.Items[0];$system.Items.Clear();$system.Tag.Loaded=$true
    [void]$script:Tree.Items.Add($root);Set-DomeniaTreeItemExpanded -Node $root
    $script:Window.Show();Pump-Tree;Pump-Tree
    if($PanelDiagnosticOnly){
        $owner=Get-DomeniaTreeContainerForItem -Tree $script:Tree -Node $root
        $before=Get-TreePanelDiagnostic -Owner $owner
        foreach($presenter in $before.Presenters){[void]$presenter.ApplyTemplate()}
        $after=Get-TreePanelDiagnostic -Owner $owner
        $before.Presenters=@();$after.Presenters=@()
        $methods=@([Windows.Controls.VirtualizingPanel].GetMethods()|Where-Object{$_.Name -eq 'BringIndexIntoViewPublic'}|ForEach-Object{$_.ToString()})
        $diagnostic=[pscustomobject]@{Suite='DirectoryTreePanelDiagnostic';Before=$before;After=$after;PublicRevealMethods=$methods;Generated=(Count-Generated);Runtime=[Environment]::Version.ToString()}
        $json=$diagnostic|ConvertTo-Json -Depth 8
        if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
        $json;return
    }
    Case 'Programme 8 Ten thousand loaded nodes are data, initial WPF generation is bounded' {
        Assert-Tree ($root.Items.Count -eq 10001 -and @($root.Items|Where-Object{$_ -is [Windows.DependencyObject]}).Count -eq 0) 'Loaded data is missing or contains WPF controls.'
        $count=Count-Generated;Assert-Tree ($count -gt 1 -and $count -lt 300) ('Initial generated count: '+$count)
        $rootContainer=Get-DomeniaTreeContainerForItem -Tree $script:Tree -Node $root
        $childPanel=[Domenia.Tree.DomeniaTreeSupport]::FindPanel($rootContainer)
        Assert-Tree ($null -ne $childPanel) 'The inherited theme trigger replaced the child reveal panel.'

    }
    Case 'Programme 8 Unloaded branch has a chevron and explicit expansion reads exactly once' {
        $unread=New-TreeItem 'unread' ('OU=unread,'+$script:Conn.BaseDn) 'OU'
        Assert-Tree ($unread.Items.Count -eq 1 -and -not $unread.Tag.Loaded -and $unread.Items[0] -isnot [Windows.DependencyObject]) 'Unread placeholder missing or visual.'
        $before=$script:Reads.Count;Set-DomeniaTreeItemExpanded -Node $unread -AllowLoad;Set-DomeniaTreeItemExpanded -Node $unread -AllowLoad
        Assert-Tree ($script:Reads.Count -eq $before+1) 'Explicit expansion did not deduplicate the read.'
        $script:Reads.Clear()
    }
    Case 'Programme 8 Far selection, recycling and favourite survive repeated scrolling with no search/read' {
        $target=$root.Items[9999];$target.FavoriteStatus='Favori'
        foreach($index in @(0,5000,9999,10,9999,100,8000,9999)){Select-TestNode $root.Items[$index]}
        $container=Get-DomeniaTreeContainerForItem $script:Tree $target
        Assert-Tree ([Windows.Automation.AutomationProperties]::GetItemStatus($container) -ceq 'Favori') 'Favourite lost during recycling.'
        Assert-Tree ($script:Searches -eq 0 -and $script:Reads.Count -eq 0) 'Deferred programmatic selection/expansion started I/O.'
    }
    Case 'Programme 8 System-group descendant can be revealed through two virtualized levels' {
        Select-TestNode $system
        Assert-Tree ($group.IsExpanded -and $script:Reads.Count -eq 0) 'System group reveal read the directory.'
    }
    Case 'Programme 8 Filter reaches a far node through data, excludes other children before container generation' {
        $script:Controls.TxtOuFilter.Text='item-09999';Update-DomeniaOuTreeFilter
        $deadline=[datetime]::UtcNow.AddSeconds(15)
        while($null -ne $script:OuTreeFilterWork -and [datetime]::UtcNow -lt $deadline){Pump-Tree}
        Assert-Tree ($null -eq $script:OuTreeFilterWork -and $root.ChildrenView.Count -eq 1) 'Child view did not filter the loaded data.'
        Pump-Tree;Assert-Tree ((Count-Generated) -lt 20) 'Filtered-out children remain realized.'
        Assert-Tree ($script:Reads.Count -eq 0) 'Local filtering started a read.'
        $script:Controls.TxtOuFilter.Text='';Update-DomeniaOuTreeFilter
        while($null -ne $script:OuTreeFilterWork -and [datetime]::UtcNow -lt $deadline){Pump-Tree}
        Assert-Tree ($root.ChildrenView.Count -eq 10001) 'Clearing the filter lost loaded nodes.'
    }
    Case 'Programme 8 Selected unread leaf is found without reading its children' {
        $leaf=New-TreeItem 'not-expanded' ('OU=not-expanded,'+$script:Conn.BaseDn) 'OU';[void]$root.Items.Add($leaf)
        Assert-Tree ([object]::ReferenceEquals((Find-DomeniaRealizedTreeNode -Dn ([string]$leaf.Tag.DN)),$leaf)) 'Unread leaf data lookup failed.'
        Assert-Tree (Select-DomeniaRealizedTreeNode -Dn ([string]$leaf.Tag.DN)) 'An existing unread leaf was incorrectly rejected.'
        Drain-Reveal;Assert-Tree ($leaf.IsSelected -and -not $leaf.Tag.Loaded -and $script:Reads.Count -eq 0) 'Selecting a leaf read its children.'
    }
    Case 'Programme 8 Session replacement cancels a pending reveal without reading' {
        [void](Start-DomeniaTreeItemReveal -Node $root.Items[2000]);$script:SessionEpoch++
        Invoke-DomeniaTreeItemRevealTick
        Assert-Tree ($null -eq $script:DomeniaTreeItemReveal -and $script:Reads.Count -eq 0) 'Stale reveal survived its epoch.'
    }
    Case 'Programme 8 Previously generated containers are not retained in proportion to loaded data' {
        Pump-Tree;[GC]::Collect();[GC]::WaitForPendingFinalizers();[GC]::Collect()
        $alive=@($script:ContainerRefs.Values|Where-Object{$_.IsAlive}).Count
        Assert-Tree ($alive -lt 300) ('Retained generated containers after scrolling: '+$alive)
    }
}finally{Stop-DomeniaTreeItemReveal;Stop-DomeniaOuTreeFilter;$script:Window.Close()}
$failed=@($checks|Where-Object{-not $_.Passed}).Count
$report=[pscustomobject]@{Suite='DomeniaTreeVirtualization';Passed=($failed -eq 0);Failed=$failed;Total=$checks.Count;RealWpf=$true;SyntheticOnly=$true;Cases=$checks.ToArray();Measurements=$script:Measurements.ToArray();Limitations='Real bounded WPF layout and generated-container counts; synthetic directory data, no AD/network and no process-memory benchmark.'}
$json=$report|ConvertTo-Json -Depth 7
if($ReportPath){[IO.File]::WriteAllText($ReportPath,$json,[Text.UTF8Encoding]::new($false))}
$json
if($failed){throw ('Tree virtualization failures: '+$failed)}
