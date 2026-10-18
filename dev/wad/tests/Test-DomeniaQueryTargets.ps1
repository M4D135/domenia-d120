#requires -Version 5.1
# Actual query DLL and adapters, with materialized local fixtures and in-memory UI/settings ports.
# No WPF, AD, WMI, network, endpoint access or writes to production settings.
[CmdletBinding()]
param([string]$ReportPath='')
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot;$modules=Join-Path $wad 'modules'
Add-Type -Path (Join-Path $modules 'M4D.Admin.Common.Query.dll')
Add-Type -Path (Join-Path $modules 'Domenia.Native.dll')
foreach($name in @('Common.Model','HealthRules.Model','Boards.Model','BoardFleet.Model','Probes.Model','QuerySchema.Model','Workstation.Model','Query.Model','QueryLibrary.Model','Query.UI','QueryLibrary.Store.UI','QueryTargets.UI')){. (Join-Path $modules ('Domenia-'+$name+'.ps1'))}
$script:Checks=[Collections.Generic.List[object]]::new()
function Case([string]$Name,[scriptblock]$Body){
    try{& $Body;$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$true;Error=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Pass=$false;Error=[string]$_.Exception.Message})}
}
function Expect([bool]$Ok,[string]$Message='Assertion failed'){if(-not $Ok){throw $Message}}
$script:FixtureLifecycle=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-WindowsLifecycle.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
function Get-DomeniaWindowsLifecycleTable {return $script:FixtureLifecycle}
function Get-DomeniaObservationMaxAgeDays {return 30}
$script:FixtureGuid='11111111-1111-1111-1111-111111111111';$script:OtherGuid='22222222-2222-2222-2222-222222222222'
$script:FixtureDn='CN=PC-FIXTURE,OU=Autre,DC=example,DC=test'
function Select-FixtureComputer([hashtable]$Attributes=@{}){
    $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-FIXTURE';DN=$script:FixtureDn;Safety=[pscustomobject]@{Guid=$script:FixtureGuid};Entry=[pscustomobject]@{Properties=$Attributes}}
    $script:DomeniaComputerQueryRecords=$null
}
function Reset-Fixture {
    $script:FleetLast=$null;$script:FleetObservations=@{};$script:SelectedObject=$null;$script:DomeniaComputerQueryRecords=$null
    $script:Settings=@{};$script:SavedSettings='';$script:UiError='';$script:Starts=0;$script:BoardWrites=0;$script:WidgetCollects=[Collections.Generic.List[string]]::new()
    $script:Layouts=@{Fleet=@();Computer=@()}
    $script:Controls=@{
        CmbQueryWidgetDestination=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Computer'}}
        CmbQueryWidgetVisual=[pscustomobject]@{SelectedItem=[pscustomobject]@{Tag='Pie'}}
        LblQueryStatus=[pscustomobject]@{Text=''}
        LblQueryComputerPreview=[pscustomobject]@{Text=''}
    }
    $script:Draft=New-DomeniaQueryRecipe -Id 'fixture.shared' -Name 'Mémoire du poste' -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8})
    $script:DomeniaQueryState=[pscustomobject]@{Saved=@($script:Draft);Recipe=$script:Draft;Generation=1L;LibraryError='';Widgets=@{};WidgetLibrary='';Timer=$null}
    $script:SessionEpoch=1L;$script:DatabaseScopedPath=Join-Path ([IO.Path]::GetTempPath()) 'domenia-targets-fixture.db';$script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=test'}
    $context=[pscustomobject]@{Version=1;Path=$script:DatabaseScopedPath;StoreId='targets-fixture';DomainDn=$script:Conn.BaseDn;SessionEpoch=1L;Generation=1L}
    $row=New-DomeniaQueryLibraryRecord -Context $context -Recipe $script:Draft -ExpectedRevision 0
    $script:DomeniaQueryLibraryStoreState=[pscustomobject]@{Context=$context;Generation=1L;Loaded=$true;Loading=$false;Saving=$false;Error='';Rows=@{'fixture.shared'=$row};Recipes=@($script:Draft);Categories=@{};ArchivedRows=@();Dependencies=@()}
    $script:ConfirmedRecipeWrites=0;$script:RefuseRecipeWrite=$false

}
function Get-DomeniaControl {param($Name);return $script:Controls[$Name]}
function Set-DomeniaControlText {param($Name,$Text);if($script:Controls.ContainsKey($Name)){$script:Controls[$Name].Text=[string]$Text};return $true}
function Set-Status {param($Text,$Level);$script:UiError=[string]$Text}
function Initialize-DomeniaQueryWorkshop {}
function Update-DomeniaQueryLibraryControls {}
function Get-DomeniaQueryDraft {return $script:Draft}
function Set-DomeniaQueryDraft {param($Recipe);$script:Draft=$Recipe;$script:DomeniaQueryState.Recipe=$Recipe}
function Save-DomeniaSettings {param([switch]$Immediate,[switch]$ThrowOnFailure);$script:SavedSettings=[string]$script:Settings['Query.Library']}
function Show-DomeniaBoard {param($Board,[switch]$Quiet)}
function Get-DomeniaBoardLayout {param($Board);return @($script:Layouts[$Board])}
function Set-DomeniaBoardLayout {
    param($Board,$Layout,$Undo,$Highlight)
    # Real JSON encoding/decoding enforces the production representation whitelist on every save.
    $json=ConvertTo-DomeniaBoardLayoutJson @($Layout)
    $script:Layouts[$Board]=@(ConvertTo-DomeniaBoardLayout -Board $Board -Json $json)
    $script:BoardWrites++
}
# Only the persistence boundary is doubled: real save, receipt validation and UI callbacks execute.
function New-DomeniaStoreContext {param($RequestId);return $script:DomeniaQueryLibraryStoreState.Context}
function Get-DomeniaSearchQueryFavorites {return @()}
function Show-DomeniaDialog {param($Title,$Message,$Details,$Kind,$Buttons);return 'Yes'}
function Submit-DomeniaStoreBatch {
    param($Context,$BatchId,$Sequence,$Changes,$SuccessHandler,$ErrorHandler,$CallbackState)
    if($script:RefuseRecipeWrite){return [pscustomobject]@{Accepted=$false;Reason='Busy'}}
    $record=@($Changes|Where-Object Kind -eq 'QueryRecipe')[0].Record
    $links=@($Changes|Where-Object{$_.Kind -eq 'QueryDependency' -and -not $_.Remove})
    $script:ConfirmedRecipeWrites++
    $script:PendingRecipeWrite=[pscustomobject]@{Handler=$SuccessHandler;Result=[pscustomobject]@{Saved=$true;DataSource='SQLite';StoreId=$Context.StoreId;QueryRecipes=@($record);QueryDependencies=$links};State=$CallbackState}
    return [pscustomobject]@{Accepted=$true;Reason=''}
}
function Complete-FixtureRecipeWrite {$pending=$script:PendingRecipeWrite;$script:PendingRecipeWrite=$null;& $pending.Handler $pending.Result $pending.State}
function Start-DomeniaQueryEvaluation {$script:Starts++}
# A widget just added collects what it misses (decision David 2026-10-14): recorded here, run by the boards suite.
function Start-DomeniaWidgetRefresh {param($Board,$Id,$Reason);$script:WidgetCollects.Add([string]$Board+'|'+[string]$Id+'|'+[string]$Reason);return $true}
function Set-FixtureInventory([string]$Guid=$script:FixtureGuid,[int]$AgeDays=0){
    $at=[datetime]::UtcNow.AddDays(-$AgeDays).ToString('o')
    $script:FleetObservations[$script:FixtureDn.ToLowerInvariant()]=[pscustomobject]@{Guid=$Guid;CheckedUtc=$at;Inventory=[pscustomobject]@{CheckedUtc=$at;RamBytes=4GB;Model='Modèle test';DiskSize=100GB;DiskFree=10GB}}
}
Reset-Fixture
Case 'No selected object returns typed empty population' {$r=Get-DomeniaComputerQueryRecords;Expect ($r -is [Collections.Generic.List[M4D.Admin.Common.Query.QueryRecord]] -and $r.Count -eq 0)}
Case 'User context cannot become a computer query' {Select-FixtureComputer;$script:SelectedObject.Type='Utilisateur';Expect ((Get-DomeniaComputerQueryRecords).Count -eq 0)}
Case 'Invalid GUID context is refused' {Select-FixtureComputer;$script:SelectedObject.Safety.Guid='bad';Expect ((Get-DomeniaComputerQueryRecords).Count -eq 0)}
Case 'Outside fleet computer remains one identity with unknown account state' {
    Reset-Fixture;Select-FixtureComputer;$r=Get-DomeniaComputerQueryRecords
    Expect ($r.Count -eq 1 -and $r[0].Id -eq $script:FixtureGuid -and $r[0].Values['name'] -eq 'PC-FIXTURE')
    Expect (-not $r[0].Values.ContainsKey('active')) 'Missing UAC must not imply active'
}
Case 'Outside fleet inventory accepts only matching GUID' {Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory;$r=Get-DomeniaComputerQueryRecords;Expect ($r.Count -eq 1 -and $r[0].Values['ramGB'] -eq 4)}
Case 'Reused DN rejects former object inventory' {Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory -Guid $script:OtherGuid;$r=Get-DomeniaComputerQueryRecords;Expect (-not $r[0].Values.ContainsKey('ramGB'))}
Case 'Expired inventory remains unknown' {Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory -AgeDays 31;$r=Get-DomeniaComputerQueryRecords;Expect (-not $r[0].Values.ContainsKey('ramGB'))}
Case 'Matching fleet identity retains known disabled state' {
    Reset-Fixture;Select-FixtureComputer
    $script:FleetLast=[pscustomobject]@{Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='D';gid='a';logon=''});Groups=@([pscustomobject]@{gid='a';os='Windows 10';ver='19045';lb=5;cr='O';pw='R';lk='N';bk='N'})}
    $r=Get-DomeniaComputerQueryRecords;Expect ($r.Count -eq 1 -and $r[0].Values['active'] -eq $false -and $r[0].Values['os'] -eq 'Windows 10')
}
Case 'Different GUID at same fleet DN cannot provide state' {
    Reset-Fixture;Select-FixtureComputer
    $script:FleetLast=[pscustomobject]@{Machines=@([pscustomobject]@{name='OLD';object_guid=$script:OtherGuid;distinguished_name=$script:FixtureDn;st='D';gid='a';logon=''});Groups=@()}
    $r=Get-DomeniaComputerQueryRecords;Expect ($r[0].Values['name'] -eq 'PC-FIXTURE' -and -not $r[0].Values.ContainsKey('active'))
}
Case 'Materialized UAC is authoritative' {Reset-Fixture;Select-FixtureComputer @{userAccountControl=@(4098)};$r=Get-DomeniaComputerQueryRecords;Expect ($r[0].Values.ContainsKey('active') -and -not $r[0].Values['active'])}
Case 'Fresh selected OS recomputes derived family and release' {
    Reset-Fixture;Select-FixtureComputer @{operatingSystem=@('Windows Server 2025');operatingSystemVersion=@('10.0 (26100)');userAccountControl=@(4096)}
    $script:FleetLast=[pscustomobject]@{Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='A';gid='a';logon=''});Groups=@([pscustomobject]@{gid='a';os='Windows 10';ver='19045';lb=5;cr='O';pw='R';lk='N';bk='N'})}
    $r=Get-DomeniaComputerQueryRecords;$v=$r[0].Values
    Expect ($v['os'] -eq 'Windows Server 2025' -and $v['osFamily'] -eq 'Serveurs' -and -not $v['win10'] -and $v['release'] -like '*Server 2025*') 'Derived fields must agree with selected object OS/build'
}
Case 'Outside fleet selected OS exposes supported derived fields' {
    Reset-Fixture;Select-FixtureComputer @{operatingSystem=@('Windows 11 Pro');operatingSystemVersion=@('10.0 (26100)')}
    $v=(Get-DomeniaComputerQueryRecords)[0].Values
    Expect ($v['osFamily'] -eq 'Postes de travail' -and $v['release'] -like '*24H2*' -and $v['osLabel'] -eq 'Windows 11 Pro')
}
Case 'Actual DLL evaluates one matching selected workstation' {
    Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory
    $count=Measure-DomeniaQueryWidget (Get-DomeniaComputerQueryRecords) $script:Draft
    Expect ($count.Total -eq 1 -and $count.Matched -eq 1 -and $count.Unknown -eq 0)
    $entry=Get-DomeniaComputerQueryBoardEntry 'fixture.shared';Expect ($entry.Number -eq 1)
}
Case 'Missing measurements produce unknown not false zero' {
    Reset-Fixture;Select-FixtureComputer
    $count=Measure-DomeniaQueryWidget (Get-DomeniaComputerQueryRecords) $script:Draft
    Expect ($count.Total -eq 1 -and $count.Matched -eq 0 -and $count.Unknown -eq 1)
    $entry=Get-DomeniaComputerQueryBoardEntry 'fixture.shared' -Visual Pie
    Expect ($entry.Kind -eq 'Distribution' -and $entry.State -eq 'Warn' -and @($entry.Items|Where-Object{$_.Label -eq 'Inconnus'})[0].Value -eq 1)
}
Case 'Preview states unknown and performs no remote or query job' {
    Reset-Fixture;Select-FixtureComputer;Show-DomeniaWorkshopComputerPreview
    Expect ($script:Controls.LblQueryComputerPreview.Text -like '*inconnu*' -and $script:Starts -eq 0)
}
Case 'Frozen selection never broadens to selected computer' {
    Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory
    $script:Draft=New-DomeniaQueryRecipe -ObjectIds @($script:OtherGuid)
    Show-DomeniaWorkshopComputerPreview;Expect ($script:Controls.LblQueryComputerPreview.Text -like '*hors de la sélection*')
}
Case 'No selected computer prompts to open a record' {Reset-Fixture;Show-DomeniaWorkshopComputerPreview;Expect ($script:Controls.LblQueryComputerPreview.Text -like '*Ouvrez la fiche*')}
Case 'Pie representation survives Computer layout JSON round trip' {
    $item=New-DomeniaBoardItem -Source Query -Key fixture.shared -Visual Pie -Id fixture.tile
    $layout=@(ConvertTo-DomeniaBoardLayout -Board Computer -Json (ConvertTo-DomeniaBoardLayoutJson @($item)))
    Expect ($layout.Count -eq 1 -and $layout[0].Visual -eq 'Pie' -and $layout[0].Source -eq 'Query')
}
Case 'Every supported query visual persists for both boards' {
    foreach($board in @('Fleet','Computer')){foreach($visual in @('Kpi','Text','Bar','Pie','Column')){
        $item=New-DomeniaBoardItem -Source Query -Key fixture.shared -Visual $visual
        $layout=@(ConvertTo-DomeniaBoardLayout -Board $board -Json (ConvertTo-DomeniaBoardLayoutJson @($item)))
        Expect ($layout.Count -eq 1 -and $layout[0].Visual -eq $visual) ($board+'/'+$visual)
    }}
}
Case 'Adding a Computer widget twice is idempotent and keeps visual' {
    Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory
    Add-DomeniaWorkshopWidget;Complete-FixtureRecipeWrite;$id=$script:Layouts.Computer[0].Id
    Add-DomeniaWorkshopWidget;Complete-FixtureRecipeWrite
    Expect ($script:Layouts.Computer.Count -eq 1 -and $script:Layouts.Computer[0].Id -eq $id -and $script:Layouts.Computer[0].Visual -eq 'Pie')
    Expect ($script:Starts -eq 0 -and $script:BoardWrites -eq 2 -and $script:DomeniaQueryState.Saved.Count -eq 1)
    Expect (($script:WidgetCollects.Count -eq 1) -and ($script:WidgetCollects[0] -eq ('Computer|'+$id+'|Add'))) ('Collecte du widget ajoute : '+($script:WidgetCollects -join ','))
    Expect ($script:Controls.LblQueryStatus.Text -like '*Aucune collecte lancée*') 'Une mise a jour du widget existant ne collecte rien'
    Expect ($script:DomeniaQueryLibraryStoreState.Rows.Count -eq 1 -and $script:ConfirmedRecipeWrites -eq 2 -and $script:DomeniaQueryLibraryStoreState.Dependencies.Count -eq 1) 'One canonical recipe and one committed widget link'
}
Case 'A refused recipe write never adds a widget or starts a collection' {
    Reset-Fixture;Select-FixtureComputer;$script:RefuseRecipeWrite=$true
    $refused=$false;try{Add-DomeniaWorkshopWidget}catch{$refused=$true}
    Expect ($refused -and $script:BoardWrites -eq 0 -and $script:WidgetCollects.Count -eq 0 -and $script:ConfirmedRecipeWrites -eq 0) 'No publication before a successful receipt'
}
Case 'Same recipe is usable on Fleet and Computer without duplicate recipe' {
    Reset-Fixture;Select-FixtureComputer;Add-DomeniaWorkshopWidget;Complete-FixtureRecipeWrite
    $script:Controls.CmbQueryWidgetDestination.SelectedItem.Tag='Fleet';Add-DomeniaWorkshopWidget;Complete-FixtureRecipeWrite
    Expect ($script:Layouts.Computer.Count -eq 1 -and $script:Layouts.Fleet.Count -eq 1 -and $script:DomeniaQueryState.Saved.Count -eq 1 -and $script:WidgetCollects.Count -eq 2)
}
Case 'Deleting recipe removes its widgets from both boards and preserves others' {
    Reset-Fixture
    foreach($board in @('Fleet','Computer')){$script:Layouts[$board]=@((New-DomeniaBoardItem -Source Query -Key fixture.shared -Visual Pie),(New-DomeniaBoardItem -Source Query -Key another.recipe -Visual Kpi))}
    # The impact review is exercised separately; this case confirms the explicit archive receipt.
    Save-DomeniaQueryRecipe -Recipe $script:Draft -Archive -ImpactConfirmed -SuccessHandler Complete-DomeniaQueryRecipeArchiveUi | Out-Null;Complete-FixtureRecipeWrite
    Expect (-not $script:UiError) $script:UiError
    Expect ($script:DomeniaQueryState.Saved.Count -eq 0 -and $script:Layouts.Fleet.Count -eq 1 -and $script:Layouts.Computer.Count -eq 1)
    Expect ($script:Layouts.Fleet[0].Key -eq 'another.recipe' -and $script:Layouts.Computer[0].Key -eq 'another.recipe')
}
Case 'Query output follows replacement and in-place observation updates' {
    Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory
    Expect ((Get-DomeniaComputerQueryBoardEntry 'fixture.shared').Number -eq 1)
    $script:FleetObservations[$script:FixtureDn.ToLowerInvariant()].Inventory.RamBytes=16GB
    Expect ((Get-DomeniaComputerQueryBoardEntry 'fixture.shared').Number -eq 0) 'Existing observation mutation must not keep prior QueryRecord'
    Set-FixtureInventory
    Expect ((Get-DomeniaComputerQueryBoardEntry 'fixture.shared').Number -eq 1) 'Replacement observation must be reevaluated'
}
Case 'Query output follows selected identity change without board redraw' {
    Reset-Fixture;Select-FixtureComputer;Set-FixtureInventory
    Expect ((Get-DomeniaComputerQueryBoardEntry 'fixture.shared').Number -eq 1)
    $script:SelectedObject.Safety.Guid=$script:OtherGuid
    $entry=Get-DomeniaComputerQueryBoardEntry 'fixture.shared'
    Expect ($entry.State -eq 'Warn' -and $entry.Number -eq 0) 'Same DN with a new GUID must become unknown'
}
Case 'Snapshot arrays and session changes invalidate bounded identity lookup' {
    Reset-Fixture;Select-FixtureComputer
    $script:FleetLast=[pscustomobject]@{Scope='OU=Autre,DC=example,DC=test';Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='D';gid='a';logon=''});Groups=@()}
    Expect (-not (Get-DomeniaComputerQueryRecords)[0].Values['active'])
    $script:FleetLast.Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='A';gid='b';logon=''})
    Expect ((Get-DomeniaComputerQueryRecords)[0].Values['active'])
    $script:SessionEpoch=99;$script:DatabaseScopedPath='fixture-other-store';[void](Get-DomeniaComputerQueryRecords)
    Expect ($script:DomeniaComputerQueryLookup.Epoch -eq 99 -and $script:DomeniaComputerQueryLookup.Path -eq 'fixture-other-store')
}
Case 'Matching fleet scope keeps the same site grouping' {
    Reset-Fixture;Select-FixtureComputer
    $script:FleetLast=[pscustomobject]@{Scope='DC=example,DC=test';Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='A';gid='a';logon=''});Groups=@()}
    $fleet=ConvertTo-DomeniaQueryRecords -Fleet $script:FleetLast
    $computer=Get-DomeniaComputerQueryRecords
    Expect ($computer[0].Values['site'] -ceq $fleet[0].Values['site'])
}
Case 'New selected attributes never mutate shared fleet group' {
    Reset-Fixture;Select-FixtureComputer @{operatingSystem=@('Windows 11');operatingSystemVersion=@('26100')}
    $script:FleetLast=[pscustomobject]@{Scope='DC=example,DC=test';Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='A';gid='a';logon=''});Groups=@([pscustomobject]@{gid='a';os='Windows 10';ver='19045';lb=5;cr='O';pw='R';lk='N';bk='N'})}
    [void](Get-DomeniaComputerQueryRecords)
    Expect ($script:FleetLast.Groups[0].os -ceq 'Windows 10' -and $script:FleetLast.Groups[0].ver -ceq '19045')
}
Case 'AD-only recipe never schedules endpoint inventory or probes' {
    $recipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='os';Operator='Contains';Value='Windows'})
    $plan=Get-DomeniaQueryCollectionRequirements @($recipe)
    Expect (-not $plan.Remote -and -not $plan.Inventory -and @($plan.ProbeIds).Count -eq 0)
}
Case 'Inventory field requests only required inventory profile' {
    $recipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='ramGB';Operator='Less';Value=8})
    $plan=Get-DomeniaQueryCollectionRequirements @($recipe)
    Expect ($plan.Remote -and $plan.Inventory -and @($plan.ProbeIds).Count -eq 0)
}
Case 'Presence-only field requests a light observation without inventory' {
    $recipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='presence';Operator='Equal';Value='En ligne'})
    $plan=Get-DomeniaQueryCollectionRequirements @($recipe)
    Expect ($plan.Remote -and -not $plan.Inventory -and @($plan.ProbeIds).Count -eq 0)
}
Case 'Probe requests union direct widgets, conditions and grouping without duplicates' {
    $recipe=New-DomeniaQueryRecipe -Clauses @([pscustomobject]@{Field='probe:hw.ram';Operator='Less';Value=8}) -GroupBy 'probe:hw.ram' -Refinements @([pscustomobject]@{Field='probe:hw.cpuload';Operator='Greater';Value=10})
    $plan=Get-DomeniaQueryCollectionRequirements -Recipes @($recipe,$recipe) -ProbeIds @('hw.ram','hw.model')
    Expect ($plan.Remote -and -not $plan.Inventory -and @($plan.ProbeIds).Count -eq 3 -and @($plan.ProbeIds) -contains 'hw.cpuload')
}
Case 'Grouped inventory and presence refinement are included in collection plan' {
    $recipe=New-DomeniaQueryRecipe -GroupBy model -Refinements @([pscustomobject]@{Field='checkedDays';Operator='Greater';Value=7})
    $plan=Get-DomeniaQueryCollectionRequirements @($recipe)
    Expect ($plan.Remote -and $plan.Inventory)
}
Case 'Catalog lifecycle codes describe actual runtime values' {
    $entry=@(Get-DomeniaQueryCatalog|Where-Object{$_.Id -eq 'lifeStatus'})[0]
    Expect ($entry.Name -like '*Ok*' -and $entry.Example -like '*Ok*' -and $entry.Example -notlike '*Supported*')
}
Case 'Explicit old session snapshot cannot supply selected computer state' {
    Reset-Fixture;Select-FixtureComputer;$script:SessionEpoch=101
    $script:FleetLast=[pscustomobject]@{Epoch=100;Scope='DC=example,DC=test';Machines=@([pscustomobject]@{name='PC-FIXTURE';object_guid=$script:FixtureGuid;distinguished_name=$script:FixtureDn;st='D';gid='a';logon=''});Groups=@()}
    $record=(Get-DomeniaComputerQueryRecords)[0]
    Expect (-not $record.Values.ContainsKey('active'))
    $script:FleetLast.Epoch=101
    Expect ((Get-DomeniaComputerQueryRecords)[0].Values['active'] -eq $false)
}
Case 'Missing or invalid selection releases retained fleet snapshot' {
    Reset-Fixture;Select-FixtureComputer;[void](Get-DomeniaComputerQueryRecords)
    Expect ($null -ne $script:DomeniaComputerQueryLookup)
    $script:SelectedObject=$null;[void](Get-DomeniaComputerQueryRecords)
    Expect ($null -eq $script:DomeniaComputerQueryLookup)
    Select-FixtureComputer;[void](Get-DomeniaComputerQueryRecords);$script:SelectedObject.Safety.Guid='bad'
    [void](Get-DomeniaComputerQueryRecords);Expect ($null -eq $script:DomeniaComputerQueryLookup)
}
Case 'Grouped pie center counts only represented matching workstations' {
    $count=[pscustomobject]@{Total=10;Matched=3;Unknown=2;NotMatched=5;GroupBy='os';Items=@([pscustomobject]@{Label='Windows 11';Value=2},[pscustomobject]@{Label='Windows 10';Value=1})}
    $entry=ConvertTo-DomeniaQueryCountEntry -Id 'fixture.grouped' -Title 'Par système' -Count $count -Visual Pie
    Expect ($entry.CenterText -ceq '3 poste(s)' -and $entry.Value -eq '3') 'Grouped chart center must match the sum of its matching categories'
    Expect (($entry.Items|Measure-Object Value -Sum).Sum -eq 3)
}
Case 'Ungrouped pie center counts matches unknowns and nonmatches' {
    $count=[pscustomobject]@{Total=10;Matched=3;Unknown=2;NotMatched=5;GroupBy='';Items=@()}
    $entry=ConvertTo-DomeniaQueryCountEntry -Id 'fixture.ungrouped' -Title 'Résultat' -Count $count -Visual Pie
    Expect ($entry.CenterText -ceq '10 poste(s)' -and $entry.Value -eq '3') 'Ungrouped chart center must represent the complete partition'
    Expect (($entry.Items|Measure-Object Value -Sum).Sum -eq 10)
}
$failed=@($script:Checks|Where-Object{-not $_.Pass})
$report=[pscustomobject]@{Suite='Domenia.QueryTargets';PowerShell=[string]$PSVersionTable.PSVersion;Pass=($script:Checks.Count-$failed.Count);Fail=$failed.Count;Scope='Actual common/native DLLs and PowerShell adapters; local materialized fixtures; no WPF, AD, WMI or network';Checks=$script:Checks.ToArray()}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))}
Write-Output ('Domenia QueryTargets: '+$report.Pass+' PASS, '+$report.Fail+' FAIL')
if($failed.Count){$failed|Format-Table -AutoSize;exit 1}
