#requires -Version 5.1
# Catalog and deferred-render contracts with in-memory panel ports; no WPF, network or AD.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
$modules=Join-Path (Split-Path -Parent $PSScriptRoot) 'modules'
foreach($name in @('Boards.Model','Widgets.UI','Dashboard.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
Set-StrictMode -Version 2.0
$script:Checks=[Collections.Generic.List[object]]::new()
function Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=[string]$_.Exception.Message})}
}
function Expect([bool]$Ok,[string]$Message='Assertion failed'){if(-not $Ok){throw $Message}}
foreach($board in @('Fleet','Computer','Software')){
    Case ("Catalog order and fields: "+$board) {
        $expected=@($script:DomeniaBoardCatalogText[$board] -split "`n"|Where-Object{$_.Trim()})
        $rows=@(Get-DomeniaBoardCatalog $board)
        Expect ($rows.Count -eq $expected.Count)
        for($i=0;$i -lt $rows.Count;$i++){
            $cells=$expected[$i].Trim() -split '\|'
            Expect ($rows[$i].Key -ceq $cells[0] -and $rows[$i].Title -ceq $cells[2])
            $item=Get-DomeniaBoardCatalogItem $board $rows[$i].Key
            Expect ($item.Description -ceq $rows[$i].Description -and $item.Default -eq $rows[$i].Default)
        }
    }
}
Case 'Repeated lookups reuse one parsed index' {
    $first=Get-DomeniaBoardCatalogCache Fleet
    1..100|ForEach-Object{[void](Get-DomeniaBoardCatalogItem Fleet 'fleet.health')}
    Expect ([object]::ReferenceEquals($first,(Get-DomeniaBoardCatalogCache Fleet)))
}
Case 'Public catalog and item mutations stay isolated' {
    $original=(Get-DomeniaBoardCatalogItem Fleet 'fleet.health').Title
    $rows=@(Get-DomeniaBoardCatalog Fleet);$rows[0].Title='Changed by editor'
    $item=Get-DomeniaBoardCatalogItem Fleet 'fleet.health';$item.Title='Changed by card'
    Expect ((Get-DomeniaBoardCatalogItem Fleet 'fleet.health').Title -ceq $original)
    Expect ((@(Get-DomeniaBoardCatalog Fleet)[0]).Title -ceq $original)
}
Case 'Lookup remains case insensitive and missing key returns null' {
    Expect ((Get-DomeniaBoardCatalogItem Fleet 'FLEET.HEALTH').Key -eq 'fleet.health')
    Expect ($null -eq (Get-DomeniaBoardCatalogItem Fleet 'unknown'))
}
Case 'Catalog source change invalidates its cache only' {
    $source=$script:DomeniaBoardCatalogText.Fleet;$computer=Get-DomeniaBoardCatalogCache Computer;$old=Get-DomeniaBoardCatalogCache Fleet
    try{
        $script:DomeniaBoardCatalogText.Fleet=$source+"`nfixture|Group|Title|Value|Kpi|S|Description|N"
        Expect ((Get-DomeniaBoardCatalogItem Fleet fixture).Default -eq $false)
        Expect (-not [object]::ReferenceEquals($old,(Get-DomeniaBoardCatalogCache Fleet)))
        Expect ([object]::ReferenceEquals($computer,(Get-DomeniaBoardCatalogCache Computer)))
    }finally{$script:DomeniaBoardCatalogText.Fleet=$source}
    Expect ($null -eq (Get-DomeniaBoardCatalogItem Fleet fixture))
}
Set-StrictMode -Off
$script:RealShowBoard=${function:Show-DomeniaBoard}
function Show-DomeniaBoard {param($Board,[switch]$Quiet);$script:RenderCalls++;if($script:RenderThrows){throw 'Fixture render failure'}}
function Get-DomeniaControl {param($Name);return $script:Controls[$Name]}
function Write-AppLog {param($Message,$Level);$script:Warnings.Add([string]$Message)}
function Request-DomeniaSelectedObservation {$script:ObservationReads++;return $true}
function Reset-Fixture {
    $script:SessionEpoch=7;$script:FleetScopeDn='OU=A,DC=example,DC=test';$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test'}
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC,OU=A,DC=example,DC=test';Safety=[pscustomobject]@{Guid='11111111-1111-1111-1111-111111111111'}}
    $script:DomeniaBoardStates=@{};$script:RenderCalls=0;$script:ObservationReads=0;$script:RenderThrows=$false
    $script:Warnings=[Collections.Generic.List[string]]::new()
    $script:Panel=[pscustomobject]@{IsVisible=$false;Handlers=[Collections.Generic.List[scriptblock]]::new();Children=[Collections.Generic.List[object]]::new()}
    $script:Panel|Add-Member -MemberType ScriptMethod -Name Add_IsVisibleChanged -Value {param([scriptblock]$Handler);$this.Handlers.Add($Handler)}
    $script:Panel.Children.Add('Existing UI')
    $script:Controls=@{PnlFleetDashboard=$script:Panel;PnlComputerDashboard=$script:Panel;PnlSoftwareDashboard=$script:Panel}
}
Case 'Hidden board coalesces data, preserves undo and installs one handler' {
    Reset-Fixture;$first=[pscustomobject]@{Value=1};$latest=[pscustomobject]@{Value=2}
    $state=Get-DomeniaBoardState Fleet;$state.UndoStack.Add('Keep undo')|Out-Null
    & $script:RealShowBoard -Board Fleet -Data $first -DeferIfHidden
    & $script:RealShowBoard -Board Fleet -Data $latest -DeferIfHidden
    Expect ($state.RenderPending -and [object]::ReferenceEquals($state.Data,$latest))
    Expect ($script:Panel.Handlers.Count -eq 1 -and $script:Panel.Children.Count -eq 1 -and $state.UndoStack.Count -eq 1)
    Expect ($script:RenderCalls -eq 0)
}
Case 'Invisible notification does not draw; visible notification draws once' {
    Reset-Fixture;& $script:RealShowBoard -Board Fleet -Data ([pscustomobject]@{Value=1}) -DeferIfHidden
    Resume-DomeniaBoardRender Fleet $script:Panel;Expect ($script:RenderCalls -eq 0)
    $script:Panel.IsVisible=$true
    & $script:Panel.Handlers[0] $script:Panel ([pscustomobject]@{NewValue=$true})
    & $script:Panel.Handlers[0] $script:Panel ([pscustomobject]@{NewValue=$true})
    Expect ($script:RenderCalls -eq 1 -and -not (Get-DomeniaBoardState Fleet).RenderPending)
}
Case 'Query refresh without Data retains latest hidden board snapshot' {
    Reset-Fixture;$data=[pscustomobject]@{Value=42}
    & $script:RealShowBoard -Board Fleet -Data $data -DeferIfHidden
    & $script:RealShowBoard -Board Fleet -Quiet -DeferIfHidden
    Expect ([object]::ReferenceEquals((Get-DomeniaBoardState Fleet).Data,$data))
}
foreach($change in @('Session','OU','Object','Guid')){
    Case ('Deferred render refuses changed '+$change) {
        Reset-Fixture;$board=if($change -in @('Object','Guid')){'Computer'}else{'Fleet'}
        & $script:RealShowBoard -Board $board -Data ([pscustomobject]@{Value=1}) -DeferIfHidden
        switch($change){Session{$script:SessionEpoch++}OU{$script:FleetScopeDn='OU=B,DC=example,DC=test'}Object{$script:SelectedObject.DN='CN=Other,OU=A,DC=example,DC=test'}Guid{$script:SelectedObject.Safety.Guid='22222222-2222-2222-2222-222222222222'}}
        $script:Panel.IsVisible=$true;Resume-DomeniaBoardRender $board $script:Panel
        Expect ($script:RenderCalls -eq 0 -and $script:Panel.Children.Count -eq 0 -and $null -eq (Get-DomeniaBoardState $board).Data)
    }
}
Case 'Hidden computer refresh starts no selected-observation read' {
    Reset-Fixture;& $script:RealShowBoard -Board Computer -Data ([pscustomobject]@{Value=1}) -DeferIfHidden
    Expect ($script:ObservationReads -eq 0 -and (Get-DomeniaBoardState Computer).RenderPending)
}
Case 'Render failure remains retryable and reported' {
    Reset-Fixture;& $script:RealShowBoard -Board Fleet -Data ([pscustomobject]@{Value=1}) -DeferIfHidden
    $script:Panel.IsVisible=$true;$script:RenderThrows=$true;Resume-DomeniaBoardRender Fleet $script:Panel
    Expect ((Get-DomeniaBoardState Fleet).RenderPending -and $script:Warnings.Count -eq 1)
    $script:RenderThrows=$false;Resume-DomeniaBoardRender Fleet $script:Panel
    Expect ($script:RenderCalls -eq 2 -and -not (Get-DomeniaBoardState Fleet).RenderPending)
}
Case 'Fleet context includes workshop only while its tools parent is selected' {
    Reset-Fixture;$script:Controls.WorkspaceTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabDashboard'}}
    $script:Controls.ApplicationToolTabs=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='WsQueryWorkshop'}}
    Expect (Test-DomeniaFleetDashboardShown)
    $script:Controls.WorkspaceTabs.SelectedItem.Name='TabApplicationTools';Expect (Test-DomeniaFleetDashboardShown)
    $script:Controls.ApplicationToolTabs.SelectedItem.Name='TabIndex';Expect (-not (Test-DomeniaFleetDashboardShown))
    $script:Controls.ApplicationToolTabs.SelectedItem.Name='WsQueryWorkshop';$script:Controls.WorkspaceTabs.SelectedItem.Name='WsSearch'
    Expect (-not (Test-DomeniaFleetDashboardShown))
}
$failed=@($script:Checks|Where-Object{-not $_.Pass})
$report=[pscustomobject]@{Passed=($failed.Count -eq 0);Cases=$script:Checks.Count;Failed=$failed.Count;Scope='In-memory contracts; no WPF, network or Active Directory';Checks=$script:Checks.ToArray()}
if($ReportPath){$parent=Split-Path -Parent $ReportPath;if($parent){[void][IO.Directory]::CreateDirectory($parent)};[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
$report|ConvertTo-Json -Depth 8
if($failed.Count){exit 1};exit 0
