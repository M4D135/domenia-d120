#requires -Version 5.1
# D120 D082/D085: integration proofs for activity layout and stale selection views.
# L08: header, menu, read-only switch, search bar and empty pages on the real main window (second part).
# The real rules from Domenia-Shell.Model.ps1 and the real UI functions extracted by AST run
# against a real WPF window carrying the reserved activity geometry and the selection read label.
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Tests=[Collections.Generic.List[object]]::new();$script:Window=$null
$edition=if($PSVersionTable.ContainsKey('PSEdition')){[string]$PSVersionTable.PSEdition}else{'Desktop'}
$script:WindowsExecuted=($env:OS -eq 'Windows_NT' -and $edition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1)

function Expect {param([bool]$Value,[string]$Message='Assertion non verifiee');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Tests.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Tests.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=$_.Exception.ToString()})}
}
function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}
function Click {param($Button);$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}

# ---------------------------------------------------------------- inert doubles of the core
function Get-DomeniaControl {param([string]$Name);if($null -eq $script:Ctrl){return $null};return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
function Write-AppLog {param($Text,$Level);[void]$script:Log.Add([string]$Text)}
function Request-UiTaskStop {param([string]$Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,[string]$Reason);$script:StoppedTasks.Add([pscustomobject]@{Id=$Id;Reason=$Reason})}
function Stop-DomeniaSelectionOpenTimer {}
# FI-05: les minuteries protegees viennent de Domenia-Engine.UI.ps1, que ce banc ne charge pas (il fait tourner le
# produit sur des doubles inertes). Ce double rend le contrat annonce par la fabrique - Start, Stop, IsEnabled,
# Interval, Tag - sans minuteur reel, comme les autres doubles de ce bloc.
function New-DomeniaTimer {
    param(
        [Parameter(Mandatory=$true)][string]$Owner,
        [Parameter(Mandatory=$true)][int]$IntervalMs,
        [scriptblock]$Tick=$null,
        [switch]$Standalone,
        [ValidateSet('Background','Normal','Input','Loaded','Render','ContextIdle','ApplicationIdle')][string]$Priority='Background',
        [int]$IdleIntervalMs=0,
        [scriptblock]$Busy=$null,
        [switch]$SessionBound,
        [switch]$RunWhenHidden,
        [switch]$Transient,
        [int]$MaxFailures=3,
        [switch]$Start,
        $Tag=$null
    )
    $timer = [pscustomobject]@{ Owner=$Owner; IntervalMs=[Math]::Max(1,$IntervalMs); Tag=$Tag; Enabled=$false }
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Start -Value { $this.Enabled=$true }
    Add-Member -InputObject $timer -MemberType ScriptMethod -Name Stop -Value { $this.Enabled=$false }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name IsEnabled -Value { [bool]$this.Enabled }
    Add-Member -InputObject $timer -MemberType ScriptProperty -Name Interval -Value { [TimeSpan]::FromMilliseconds([double]$this.IntervalMs) }
    if ($Start) { $timer.Start() }
    return $timer
}
function Clear-DomeniaCurrentObjectRequest {param([string]$RequestId)}
function Clear-Secrets {}
function Clear-ObjectDetails {}
function Update-DomeniaLinkActionUi {param([int]$RowCount)}
function Reset-DomeniaDeferredViews {}
function Update-DomeniaSecretActionUi {}
function Apply-CurrentPermissionUi {}
function Request-DomeniaDashboardRefresh {}
# FI-19: the secret summary of a workstation is read off the Dispatcher (LocalIndexRead); only the request is recorded.
function Request-DomeniaSecretIndexSummary {param([AllowEmptyString()][string]$Computer='',[AllowEmptyString()][string]$Guid='');if($null -eq $script:SecretSummaryRequests){$script:SecretSummaryRequests=[Collections.Generic.List[string]]::new()};$script:SecretSummaryRequests.Add([string]$Computer)}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Update-DomeniaInventoryCategories {}
function Apply-DomeniaInventoryFilter { [void](Set-DomeniaItemsSource -Name 'DgInventory' -Rows $script:InventoryRows) }
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.ItemsSource=@($Rows)};return $true}
function Apply-DomeniaSoftwareFilter { [void](Set-DomeniaItemsSource -Name 'DgSoftware' -Rows $script:SoftwareRows) }
function Update-DomeniaSoftwareColumnVisibility {}
function Update-DomeniaSoftwareSyntheseVisibility {}
function Update-DomeniaSoftwareAccessSummary {}
function Update-DomeniaSoftwareFilterChip {}
function Update-DomeniaInventoryAgeLine { $script:Spy.Age++ }
function Show-DomeniaCachedInventory { param($Computer); $script:Spy.Restore++; $script:Spy.LastRestoreComputer=[string]$Computer; return $false }
function Normalize-LinkComputer { param([string]$Computer); return ([string]$Computer).Trim().ToUpperInvariant() }
function Get-DomeniaSoftwareAccessSummary {param($Rows);return ''}
function Get-DomeniaSoftwareColumnVisibility {param($Headers,$FromInventory,$ShowTechnical);return @{}}
function Register-DomeniaOperationSample {param([string]$Operation,[string]$Mode,[int]$ItemCount,[long]$DurationMs,[long]$BytesEstimated,[int]$RemoteAttempts,[int]$FallbackTasks,[int]$SuccessCount,[int]$FailureCount)}
function Add-DomeniaUiLog {param([string]$Area,[string]$Text,[string]$Level)}
function Set-DomeniaGridRows {param([string]$Name,$Rows,[string]$KeyProperty);return $true}
function Update-DomeniaExperienceCancelState {}
function Test-DomeniaAccessBusyWrite {return $false}
function Set-VisibleTabsForType {param([string]$Type,[switch]$PreserveWorkspace)}
function Get-DomeniaExperienceTaskRow {param($Job,$Now,[switch]$Detached,[long]$SessionEpoch);return $null}
function Stop-DomeniaSecretReadTasks {}

function Reset-Fixture {
    $script:Status='';$script:Log.Clear();$script:StoppedTasks.Clear();$script:Spy.Counter=0;$script:Spy.Preview=0;$script:Spy.LastPreview=$null
    $script:Spy.Age=0;$script:Spy.Restore=0;$script:Spy.LastRestoreComputer=''
    $script:SelectedObject=$null;$script:SelectionLoad=$null;$script:SelectedObjectGeneration=0L
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:AccessState=[pscustomobject]@{Pending=@()}
    $script:ExperienceInitialized=$true;$script:ExperienceActivitySignature='';$script:WriteState='Unknown'
    $script:InventoryRows=@();$script:InventoryAccess=@();$script:SoftwareRows=@();$script:SoftwareAccess=@()
    $script:ComputerDiagRows=@();$script:PermissionRows=@()
    $script:InventoryCacheByComputer=@{}
    if ($null -ne $script:Window) {
        foreach ($name in @($script:Ctrl.Keys)) {
            $c=$script:Ctrl[$name]
            if ($null -eq $c) { continue }
            if ($c -is [Windows.Controls.Primitives.ButtonBase]) { $c.Visibility='Visible' }
            elseif ($c -is [Windows.Controls.Border]) { $c.Visibility='Hidden' }
            elseif ($c -is [Windows.Controls.ProgressBar]) { $c.Visibility='Hidden';$c.IsIndeterminate=$false }
            elseif ($c -is [Windows.Controls.DataGrid]) { $c.ItemsSource=$null }
            elseif ($c -is [Windows.Controls.ListBox]) { $c.Items.Clear() }
            elseif ($c -is [Windows.Controls.TextBlock]) { $c.Text='' }
        }
    }
}

$script:Ctrl=@{}
$script:Status=''
$script:Log=[Collections.ArrayList]::new()
$script:StoppedTasks=[Collections.ArrayList]::new()
$script:Spy=[pscustomobject]@{Counter=0;Preview=0;LastPreview=$null;Age=0;Restore=0;LastRestoreComputer=''}
$script:SessionEpoch=7L
$script:SelectedObjectGeneration=0L
$script:SelectedObject=$null
$script:SelectionLoad=$null
$script:CurrentObjectRequestId=''
$script:PendingObjectSelection=$null
$script:LastLoadedEntry=$null
$script:DraftState=$null
$script:CurrentCapabilities=@{}
$script:SelectionResetDn=''
$script:ActiveLinkProbeId=''
$script:ActiveLinkProbeComputer=''
$script:AsyncJobs=@{}
$script:DetachedReadJobs=@()
$script:AccessState=[pscustomobject]@{Pending=@()}
$script:ExperienceInitialized=$true
$script:ExperienceActivitySignature=''
$script:WriteState='Unknown'
$script:InventoryRows=@()
$script:InventoryAccess=@()
$script:SoftwareRows=@()
$script:SoftwareAccess=@()
$script:ComputerDiagRows=@()
$script:PermissionRows=@()
$script:InventoryCacheByComputer=@{}
$script:ActualSecretDeniedDn=''
$script:ActiveSecretRequestId=''
$script:LatestTaskId=''
$script:LastTaskUiCount=-1
$script:LastTaskUiSignature=''
$script:LastTaskUiRefresh=(Get-Date).AddYears(-1)

try{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,UIAutomationTypes

    # Pure rules are dot-sourced at script scope.
    . (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Engine.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Cache.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Relations.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Access.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')

    # Spies are installed after the real rules are loaded and before the UI functions are extracted.
    # Keep the original body: a command reference would resolve to the spy below and recurse.
    $script:RealCounter = (Get-Command -Name Get-DomeniaCounterText -CommandType Function).ScriptBlock
    function Get-DomeniaCounterText {
        param([int]$Count,[string]$ZeroText='')
        $script:Spy.Counter++
        & $script:RealCounter -Count $Count -ZeroText $ZeroText
    }

    # Keep the original body: a command reference would resolve to the spy below and recurse.
    $script:RealPreview = (Get-Command -Name Get-DomeniaSelectionPreview -CommandType Function).ScriptBlock
    function Get-DomeniaSelectionPreview {
        param($Selection,[string]$LoadState='Idle',$Detail=$null,[string]$ErrorText='')
        $script:Spy.Preview++
        $r=& $script:RealPreview -Selection $Selection -LoadState $LoadState -Detail $Detail -ErrorText $ErrorText
        $script:Spy.LastPreview=$r
        return $r
    }

    # Real UI/core functions are extracted by AST and dot-sourced at script scope.
    $files = @(
        (Join-Path $wad 'modules\Domenia-Access.UI.ps1'),
        (Join-Path $wad 'modules\Domenia-Experience.UI.ps1'),
        (Join-Path $wad 'modules\Domenia-Selection.UI.ps1'),
        (Join-Path $wad 'Domenia-Core.ps1')
    )
    $functionNames = @(
        'Update-DomeniaAccessButton',
        'Update-DomeniaExperienceActivity',
        'Update-DomeniaSelectionReadUi',
        'Get-DomeniaSelectionCachePolicy',
        'Reset-DomeniaSelectionBoundViews',
        'Enter-DomeniaSelectionContext',
        'Complete-DomeniaInventoryUi',
        'Get-DomeniaInventorySummaryText',
        'Complete-DomeniaSoftwareUi',
        'Get-DomeniaSelectedGridRow'
    )

    foreach ($file in $files) {
        if (-not (Test-Path $file)) { throw ('Fichier absent : '+$file) }
        $parseTokens=$null
        $parseErrors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$parseTokens,[ref]$parseErrors)
        if (($null -ne $parseErrors) -and ($parseErrors.Count -gt 0)) { throw ('Erreur de parse dans '+$file) }
        $functionAst = $ast.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]}, $true)
        foreach ($fn in $functionAst) {
            if ($functionNames -contains $fn.Name) {
                . ([scriptblock]::Create($fn.Extent.Text))
            }
        }
    }

    # Real reserved geometry fragment from the main window: names and sizes are the contract points.
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="900" Height="600" ShowActivated="False">
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Grid x:Name="UxActivityRow" Height="44" VerticalAlignment="Top">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <Grid x:Name="UxActivityStrip" Height="44" Grid.Column="0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="252"/>
          <ColumnDefinition Width="144"/>
          <ColumnDefinition Width="96"/>
        </Grid.ColumnDefinitions>
        <ProgressBar x:Name="PbTop" Grid.Column="0" Width="130" Height="8" HorizontalAlignment="Left" VerticalAlignment="Center"/>
        <TextBlock x:Name="LblTaskElapsed" Grid.Column="1" Height="24" VerticalAlignment="Center"/>
        <Border x:Name="WriteModeBanner" Grid.Column="1" Width="240" Height="32" HorizontalAlignment="Left" VerticalAlignment="Center" Background="Yellow" Visibility="Hidden"/>
        <Button x:Name="BtnCancelTask" Grid.Column="3" Width="96" Height="32"/>
      </Grid>
      <StackPanel Grid.Column="1" Orientation="Horizontal">
        <Button x:Name="BtnAccessRecovery" Width="40" Height="40">
          <Grid>
            <Border x:Name="BadgeAccessRecovery" Width="24" Height="16" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Red" Visibility="Hidden">
              <TextBlock x:Name="LblAccessRecoveryCount" Text=""/>
            </Border>
          </Grid>
        </Button>
        <Button x:Name="BtnSuiteActivity" Width="40" Height="40">
          <Grid>
            <Border x:Name="BadgeSuiteActivity" Width="24" Height="16" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Blue" Visibility="Hidden">
              <TextBlock x:Name="LblSuiteActivityCount" Text=""/>
            </Border>
          </Grid>
        </Button>
      </StackPanel>
    </Grid>
    <Grid Grid.Row="1">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <TextBlock x:Name="LblSelectionReadState" Height="20"/>
      <DataGrid x:Name="DgObjects" Grid.Row="1" Height="100"/>
      <StackPanel Grid.Row="2" Orientation="Horizontal">
        <DataGrid x:Name="DgInventory" Width="100" Height="50"/>
        <DataGrid x:Name="DgInventoryAccess" Width="100" Height="50"/>
        <DataGrid x:Name="DgSoftware" Width="100" Height="50"/>
        <DataGrid x:Name="DgSoftwareAccess" Width="100" Height="50"/>
        <DataGrid x:Name="DgWmiSchema" Width="100" Height="50"/>
        <DataGrid x:Name="DgWmiInstances" Width="100" Height="50"/>
        <ListBox x:Name="LstWmiClasses" Width="100" Height="50"/>
        <ListBox x:Name="LstWmiNamespaces" Width="100" Height="50"/>
      </StackPanel>
      <StackPanel Grid.Row="3" Orientation="Horizontal">
        <TextBlock x:Name="LblInventoryStatus" Height="20"/>
        <TextBlock x:Name="LblSoftwareStatus" Height="20"/>
        <TextBlock x:Name="LblWmiStatus" Height="20"/>
      </StackPanel>
    </Grid>
  </Grid>
</Window>
'@

    [xml]$doc=$xaml
    $reader=New-Object Xml.XmlNodeReader $doc
    try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $script:Window=$w

    $controlNames = @(
        'UxActivityRow','UxActivityStrip','PbTop','LblTaskElapsed','BtnCancelTask','WriteModeBanner',
        'BtnAccessRecovery','BadgeAccessRecovery','LblAccessRecoveryCount',
        'BtnSuiteActivity','BadgeSuiteActivity','LblSuiteActivityCount',
        'LblSelectionReadState','DgObjects','DgInventory','DgInventoryAccess','DgSoftware','DgSoftwareAccess',
        'DgWmiSchema','DgWmiInstances','LstWmiClasses','LstWmiNamespaces',
        'LblInventoryStatus','LblSoftwareStatus','LblWmiStatus'
    )
    foreach ($name in $controlNames) {
        $script:Ctrl[$name]=$w.FindName($name)
        if ($null -eq $script:Ctrl[$name]) { throw ('Controle absent : '+$name) }
    }

    $w.Show();Pump $w

    try{
        Case 'D082 : les tailles reservees du XAML correspondent a la regle' {
            Reset-Fixture;Pump $w
            $slots=Get-DomeniaActivityStripSlots
            $measured=@{}
            foreach ($slot in $slots.Slots) {
                $c=Get-DomeniaControl ([string]$slot.Name)
                if ($null -ne $c) {
                    $measured[[string]$slot.Name]=@{Width=$c.Width;Height=$c.Height;MaxWidth=$c.MaxWidth;MaxHeight=$c.MaxHeight}
                }
            }
            $measured['__StripColumns']=@(foreach ($col in $script:Ctrl['UxActivityStrip'].ColumnDefinitions) { $col.Width.ToString() })
            $measured['__RowHeight']=[double]$script:Ctrl['UxActivityRow'].Height
            $measured['__StripHeight']=[double]$script:Ctrl['UxActivityStrip'].Height
            $issues=Compare-DomeniaReservedSlots -Expected $slots -Measured $measured
            Expect (($issues.Count -eq 0)) ('Dispositions : '+($issues -join '; '))
        }

        Case 'D082 : Update-DomeniaAccessButton utilise la regle et ne deplace pas les voisins' {
            Reset-Fixture;Pump $w
            $cancel=Get-DomeniaControl 'BtnCancelTask'
            $before=$cancel.TranslatePoint([Windows.Point]::new(0,0),$w)
            foreach ($n in @(0,1,100,120)) {
                $pending=@()
                if ($n -gt 0) { $pending=@(1..$n) }
                $script:AccessState=[pscustomobject]@{Pending=$pending}
                Update-DomeniaAccessButton
                $expected=Get-DomeniaCounterText -Count ([int]$n) -ZeroText '0'
                $counter=Get-DomeniaControl 'LblAccessRecoveryCount'
                $badge=Get-DomeniaControl 'BadgeAccessRecovery'
                Expect ($counter.Text -ceq $expected) ('Compteur '+$n+' : '+$counter.Text)
                $wantedVisibility='Hidden'; if ($n -gt 0) { $wantedVisibility='Visible' }
                Expect ([string]$badge.Visibility -ceq $wantedVisibility) ('Badge '+$n+' : '+[string]$badge.Visibility)
            }
            $after=$cancel.TranslatePoint([Windows.Point]::new(0,0),$w)
            Expect (($before.X -eq $after.X) -and ($before.Y -eq $after.Y)) ('Deplacement : '+$before+' -> '+$after)
            Expect ($script:Spy.Counter -gt 0) 'Get-DomeniaCounterText non appelee'
        }

        Case 'D082 : Update-DomeniaExperienceActivity utilise la regle et ne deplace pas les voisins' {
            Reset-Fixture;Pump $w
            $cancel=Get-DomeniaControl 'BtnCancelTask'
            $before=$cancel.TranslatePoint([Windows.Point]::new(0,0),$w)
            foreach ($n in @(0,1,100,120)) {
                $script:AsyncJobs=@{}
                if ($n -gt 0) {
                    for ($i=1; $i -le $n; $i++) {
                        $script:AsyncJobs[[string]$i]=[pscustomobject]@{Id=[string]$i;State='Running';Name='job';Started=(Get-Date)}
                    }
                }
                $script:DetachedReadJobs=@()
                Update-DomeniaExperienceActivity
                $expected=Get-DomeniaCounterText -Count ([int]$n) -ZeroText '0'
                $counter=Get-DomeniaControl 'LblSuiteActivityCount'
                $badge=Get-DomeniaControl 'BadgeSuiteActivity'
                Expect ($counter.Text -ceq $expected) ('Compteur '+$n+' : '+$counter.Text)
                $wantedVisibility='Hidden'; if ($n -gt 0) { $wantedVisibility='Visible' }
                Expect ([string]$badge.Visibility -ceq $wantedVisibility) ('Badge '+$n+' : '+[string]$badge.Visibility)
            }
            $after=$cancel.TranslatePoint([Windows.Point]::new(0,0),$w)
            Expect (($before.X -eq $after.X) -and ($before.Y -eq $after.Y)) ('Deplacement : '+$before+' -> '+$after)
            Expect ($script:Spy.Counter -gt 0) 'Get-DomeniaCounterText non appelee'
        }

        Case 'D085 : Update-DomeniaSelectionReadUi appelle la regle et remplit une ligne et le ToolTip' {
            Reset-Fixture;Pump $w
            $guid='11111111-1111-1111-1111-111111111111'
            $script:SelectedObjectGeneration=1L
            $script:SelectedObject=[pscustomobject]@{DN='CN=A,OU=Users,DC=x';Type='Utilisateur';Name='A';Guid=$guid;Login='a';State='OK';Container='OU=Users'}
            $script:SelectionLoad=[pscustomobject]@{
                Context=[pscustomobject]@{Type='Utilisateur';Name='A';DN='CN=A,OU=Users,DC=x';Guid=$guid}
                Token='t';Phase='Ready';Message='';VisibleType='';SelectionIdentity=[pscustomobject]@{Type='Utilisateur';Name='A'}
            }
            Update-DomeniaSelectionReadUi
            $lbl=Get-DomeniaControl 'LblSelectionReadState'
            Expect ($script:Spy.Preview -gt 0) 'Get-DomeniaSelectionPreview non appelee'
            $expected=ConvertTo-DomeniaSelectionPreviewText -Preview $script:Spy.LastPreview -Maximum 160
            Expect ($lbl.Text -ceq [string]$expected.Line) ('Texte : '+$lbl.Text)
            # D030: the fixture has an uncertain write; the policy reason supplements the preview.
            Expect ([string]$lbl.ToolTip -ceq ([string]$expected.Detail+"`r`nOperation a verifier")) 'ToolTip non aligne avec le contexte et le motif de protection'
            Expect ($lbl.Height -eq 20) ('Height : '+$lbl.Height)
        }

        Case 'D085 : Reset-DomeniaSelectionBoundViews vide les vues inventaire/logiciels/WMI' {
            Reset-Fixture;Pump $w
            [void](Set-DomeniaItemsSource -Name 'DgInventory' -Rows @([pscustomobject]@{Name='old'}))
            [void](Set-DomeniaItemsSource -Name 'DgInventoryAccess' -Rows @([pscustomobject]@{Status='OK'}))
            [void](Set-DomeniaItemsSource -Name 'DgSoftware' -Rows @([pscustomobject]@{Name='old'}))
            [void](Set-DomeniaItemsSource -Name 'DgSoftwareAccess' -Rows @([pscustomobject]@{Status='OK'}))
            [void](Set-DomeniaItemsSource -Name 'DgWmiSchema' -Rows @([pscustomobject]@{Name='old'}))
            [void](Set-DomeniaItemsSource -Name 'DgWmiInstances' -Rows @([pscustomobject]@{Name='old'}))
            $script:Ctrl['LstWmiClasses'].Items.Add('old')
            $script:Ctrl['LstWmiNamespaces'].Items.Add('old')
            [void](Set-DomeniaControlText -Name 'LblInventoryStatus' -Text 'old')
            [void](Set-DomeniaControlText -Name 'LblSoftwareStatus' -Text 'old')
            $script:AsyncJobs=@{
                'inv'=[pscustomobject]@{ReplaceKey='inventory';IsWrite=$false}
                'sw'=[pscustomobject]@{ReplaceKey='software';IsWrite=$false}
                'wmi'=[pscustomobject]@{ReplaceKey='wmi';IsWrite=$false}
            }
            Reset-DomeniaSelectionBoundViews -Dn 'CN=B' -Type 'Machine' -Name 'B'
            foreach ($name in @('DgInventory','DgInventoryAccess','DgSoftware','DgSoftwareAccess','DgWmiSchema','DgWmiInstances')) {
                $c=Get-DomeniaControl $name
                Expect (@($c.ItemsSource).Count -eq 0) ($name+' non vide')
            }
            Expect ($script:Ctrl['LstWmiClasses'].Items.Count -eq 0) 'LstWmiClasses non vide'
            Expect ($script:Ctrl['LstWmiNamespaces'].Items.Count -eq 0) 'LstWmiNamespaces non vide'
            Expect ($script:Ctrl['LblInventoryStatus'].Text -eq 'Aucun inventaire charge pour cette selection.') 'LblInventoryStatus'
            Expect ($script:Ctrl['LblSoftwareStatus'].Text -eq 'Aucun logiciel charge pour cette selection.') 'LblSoftwareStatus'
            $stopped=@($script:StoppedTasks.Id)
            Expect (($stopped -contains 'inv') -and ($stopped -contains 'sw') -and ($stopped -contains 'wmi')) 'Taches inventory/software/wmi non arretes'
        }

        Case 'FI-19 : la fiche poste demande le releve des secrets en arriere-plan' {
            Reset-Fixture;Pump $w
            $script:SecretSummaryRequests=[Collections.Generic.List[string]]::new()
            Reset-DomeniaSelectionBoundViews -Dn 'CN=PC-B,OU=Postes,DC=example,DC=invalid' -Type 'Machine' -Name 'PC-B'
            Expect (($script:SecretSummaryRequests.Count -eq 1) -and ($script:SecretSummaryRequests[0] -ceq 'PC-B')) ('Demandes : '+($script:SecretSummaryRequests -join ','))
            # Another type of object cancels the pending request (empty name) instead of keeping the workstation one.
            Reset-DomeniaSelectionBoundViews -Dn 'CN=Alice,OU=Comptes,DC=example,DC=invalid' -Type 'Utilisateur' -Name 'Alice'
            Expect (($script:SecretSummaryRequests.Count -eq 2) -and ($script:SecretSummaryRequests[1] -ceq '')) ('Demandes : '+($script:SecretSummaryRequests -join ','))
            $tokens=$null;$errors=$null
            $ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$tokens,[ref]$errors)
            $reset=@($ast.FindAll({param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Reset-DomeniaSelectionBoundViews')},$true))
            Expect ($reset.Count -eq 1) 'Reset-DomeniaSelectionBoundViews absente ou ambigue.'
            foreach($forbidden in @('Invoke-DomeniaDbQuery','Get-DomeniaSecretIndexSummary','Initialize-DomeniaDatabase')){Expect (-not $reset[0].Extent.Text.Contains($forbidden)) ('Lecture synchrone encore presente : '+$forbidden)}
        }

        Case 'D085 : Enter-DomeniaSelectionContext arrete inventory/software/wmi et vide les vues' {
            Reset-Fixture;Pump $w
            [void](Set-DomeniaItemsSource -Name 'DgSoftware' -Rows @([pscustomobject]@{Name='old'}))
            [void](Set-DomeniaItemsSource -Name 'DgInventory' -Rows @([pscustomobject]@{Name='old'}))
            $script:AsyncJobs=@{
                'inv'=[pscustomobject]@{ReplaceKey='inventory';IsWrite=$false}
                'sw'=[pscustomobject]@{ReplaceKey='software';IsWrite=$false}
                'wmi'=[pscustomobject]@{ReplaceKey='wmi';IsWrite=$false}
                'obj'=[pscustomobject]@{ReplaceKey='object';IsWrite=$false}
                'secret'=[pscustomobject]@{ReplaceKey='secrets';IsWrite=$false}
                'write'=[pscustomobject]@{ReplaceKey='inventory';IsWrite=$true}
            }
            Enter-DomeniaSelectionContext -Context [pscustomobject]@{DN='CN=B';Type='Machine';Name='B'}
            $stopped=@($script:StoppedTasks.Id)
            Expect (($stopped -contains 'inv') -and ($stopped -contains 'sw') -and ($stopped -contains 'wmi') -and ($stopped -contains 'obj') -and ($stopped -contains 'secret')) 'Taches non arretes'
            Expect (-not ($stopped -contains 'write')) 'Ecriture arretee'
            Expect (@($script:Ctrl['DgSoftware'].ItemsSource).Count -eq 0) 'DgSoftware non vide'
            Expect (@($script:Ctrl['DgInventory'].ItemsSource).Count -eq 0) 'DgInventory non vide'
            Expect ($null -eq $script:SelectedObject) 'SelectedObject non vide'
        }

        Case 'D085 : Complete-DomeniaSoftwareUi ignore un resultat tardif d un autre DN' {
            Reset-Fixture;Pump $w
            foreach($g in @('DgInventory','DgSoftware')){if($script:Ctrl.ContainsKey($g)){$script:Ctrl[$g].ItemsSource=$null}}
            $script:SelectedObject=[pscustomobject]@{DN='CN=B';Type='Machine';Name='B'}
            $late=[pscustomobject]@{
                Rows=@([pscustomobject]@{Scope='Machine';Source='WinRM';Name='old'})
                Access=@([pscustomobject]@{Status='OK';Method='WinRM'})
                DurationMs=10;FallbackTransport='';FallbackTasks=0;TaskBytes=0;Success=$true
            }
            Complete-DomeniaSoftwareUi -Result $late -State ([pscustomobject]@{DN='CN=A';Computer='A'})
            Expect (($null -eq $script:Ctrl['DgSoftware'].ItemsSource) -or (@($script:Ctrl['DgSoftware'].ItemsSource).Count -eq 0)) 'Resultat tardif affiche'
            Expect ($script:SoftwareRows.Count -eq 0) 'SoftwareRows non vide'
            $current=[pscustomobject]@{
                Rows=@([pscustomobject]@{Scope='Machine';Source='WinRM';Name='B'})
                Access=@([pscustomobject]@{Status='OK';Method='WinRM'})
                DurationMs=10;FallbackTransport='';FallbackTasks=0;TaskBytes=0;Success=$true
            }
            Complete-DomeniaSoftwareUi -Result $current -State ([pscustomobject]@{DN='CN=B';Computer='B'})
            Expect (@($script:Ctrl['DgSoftware'].ItemsSource).Count -gt 0) 'Resultat courant non affiche'
            Expect ($script:SoftwareRows.Count -eq 1) 'SoftwareRows'
        }

        Case 'FO-07 : la selection d un poste reprend sa derniere lecture de la session' {
            Reset-Fixture;Pump $w
            Enter-DomeniaSelectionContext -Context ([pscustomobject]@{DN='CN=PC1';Type='Machine';Name='PC-01'})
            Expect ($script:Spy.Restore -eq 1) 'Aucune reprise tentee pour un poste'
            Expect ($script:Spy.LastRestoreComputer -ceq 'PC-01') ('Reprise demandee pour un autre objet : '+$script:Spy.LastRestoreComputer)
            Reset-Fixture;Pump $w
            Enter-DomeniaSelectionContext -Context ([pscustomobject]@{DN='CN=U1';Type='User';Name='jean'})
            Expect ($script:Spy.Restore -eq 0) 'Un utilisateur declenche une reprise d inventaire'
            Reset-Fixture;Pump $w
            $script:SelectedObject=[pscustomobject]@{DN='CN=PC1';Type='Machine';Name='PC-01'}
            $fresh=[pscustomobject]@{Rows=@([pscustomobject]@{Name='a'});Access=@([pscustomobject]@{Status='OK';Category='';Detail=''});DurationMs=10;FallbackTasks=0;TaskBytes=0;Success=$true}
            Complete-DomeniaInventoryUi -Result $fresh -State ([pscustomobject]@{DN='CN=PC1';Computer='PC-01'})
            Expect ($script:Spy.Age -ge 1) 'La ligne d age ne suit pas une lecture fraiche'
            Expect ($script:InventoryCacheByComputer.ContainsKey('PC-01')) 'La lecture fraiche n a pas ete gardee pour la session'
            Expect (@($script:InventoryCacheByComputer['PC-01'].Effective.Rows).Count -eq 1) 'Le cache garde autre chose que la lecture'
        }

        Case 'D085 : Complete-DomeniaInventoryUi ignore un resultat tardif d un autre DN' {
            Reset-Fixture;Pump $w
            foreach($g in @('DgInventory','DgSoftware')){if($script:Ctrl.ContainsKey($g)){$script:Ctrl[$g].ItemsSource=$null}}
            $script:SelectedObject=[pscustomobject]@{DN='CN=B';Type='Machine';Name='B'}
            $late=[pscustomobject]@{
                Rows=@([pscustomobject]@{Name='old'})
                Access=@([pscustomobject]@{Status='OK';Category='';Detail=''})
                DurationMs=10;FallbackTasks=0;TaskBytes=0;Success=$true
            }
            Complete-DomeniaInventoryUi -Result $late -State ([pscustomobject]@{DN='CN=A';Computer='A'})
            Expect (($null -eq $script:Ctrl['DgInventory'].ItemsSource) -or (@($script:Ctrl['DgInventory'].ItemsSource).Count -eq 0)) 'Resultat tardif affiche'
            Expect ($script:InventoryRows.Count -eq 0) 'InventoryRows non vide'
            $current=[pscustomobject]@{
                Rows=@([pscustomobject]@{Name='B'})
                Access=@([pscustomobject]@{Status='OK';Category='';Detail=''})
                DurationMs=10;FallbackTasks=0;TaskBytes=0;Success=$true
            }
            Complete-DomeniaInventoryUi -Result $current -State ([pscustomobject]@{DN='CN=B';Computer='B'})
            Expect (@($script:Ctrl['DgInventory'].ItemsSource).Count -gt 0) 'Resultat courant non affiche'
            Expect ($script:InventoryRows.Count -eq 1) 'InventoryRows'
        }

        Case 'D085 : une selection B vide les vues A et ignore un resultat tardif A' {
            Reset-Fixture;Pump $w
            $script:SelectedObject=[pscustomobject]@{DN='CN=A';Type='Machine';Name='A'}
            $resultA=[pscustomobject]@{
                Rows=@([pscustomobject]@{Scope='Machine';Source='WinRM';Name='A'})
                Access=@([pscustomobject]@{Status='OK';Method='WinRM'})
                DurationMs=10;FallbackTransport='';FallbackTasks=0;TaskBytes=0;Success=$true
            }
            Complete-DomeniaSoftwareUi -Result $resultA -State ([pscustomobject]@{DN='CN=A';Computer='A'})
            Expect (@($script:Ctrl['DgSoftware'].ItemsSource).Count -gt 0) 'A non affiche'
            Enter-DomeniaSelectionContext -Context [pscustomobject]@{DN='CN=B';Type='Machine';Name='B'}
            Expect (@($script:Ctrl['DgSoftware'].ItemsSource).Count -eq 0) 'A reste sous B'
            Complete-DomeniaSoftwareUi -Result $resultA -State ([pscustomobject]@{DN='CN=A';Computer='A'})
            Expect (@($script:Ctrl['DgSoftware'].ItemsSource).Count -eq 0) 'Resultat tardif A affiche sous B'
        }

        Case 'D085 : LblSelectionReadState reste une ligne de 20 unites pendant les phases' {
            Reset-Fixture;Pump $w
            $guid='11111111-1111-1111-1111-111111111111'
            $script:SelectedObjectGeneration=1L
            $script:SelectedObject=[pscustomobject]@{DN='CN=A';Type='Machine';Name='A';Guid=$guid;DnsName='A';State='OK';Container='OU=PC'}
            foreach ($phase in @('Queued','Loading','Ready')) {
                $script:SelectionLoad=[pscustomobject]@{
                    Context=[pscustomobject]@{Type='Machine';Name='A';DN='CN=A';Guid=$guid}
                    Token='t';Phase=$phase;Message='';VisibleType='';SelectionIdentity=[pscustomobject]@{Type='Machine';Name='A'}
                }
                Update-DomeniaSelectionReadUi
                $lbl=Get-DomeniaControl 'LblSelectionReadState'
                Expect ($lbl.Height -eq 20) ('Height '+$phase)
                Expect (-not ($lbl.Text -match "`r`n")) ('Texte multiligne '+$phase)
                Expect ($lbl.Text.Length -gt 0) ('Texte vide '+$phase)
            }
        }
    }finally{
        $w.Close()
        $script:Window=$null
    }

    # ---------------------------------------------------------------- L08: real main window, header, menu and read-only switch
    # The real main XAML (Get-MainXaml) and the real UX, inline-request and core presentation functions run against
    # doubles that read nothing: no directory, no network, no dialog (a dialog double throws), no saved preference.
    $script:L08 = [pscustomobject]@{Settings=@{};SettingWrites=New-Object 'System.Collections.ArrayList';Statuses=New-Object 'System.Collections.ArrayList';Dialogs=0;Searches=0;Tasks=New-Object 'System.Collections.ArrayList';Cfg=@{};Clears=0}
    function Get-CfgValue {param($Section,$Key,$Default);$k=[string]$Section+'.'+[string]$Key;if($script:L08.Cfg.ContainsKey($k)){return $script:L08.Cfg[$k]};return $Default}
    function Get-DomeniaSetting {param([string]$Name,$Default=$null);if($script:L08.Settings.ContainsKey($Name)){return $script:L08.Settings[$Name]};return $Default}
    function Set-DomeniaSetting {param([string]$Name,$Value);$script:L08.Settings[$Name]=$Value;[void]$script:L08.SettingWrites.Add($Name)}
    function Save-DomeniaSettings {param([switch]$Immediate)}
    function Set-Status {param($Text,$Level);[void]$script:L08.Statuses.Add([string]$Text)}
    function Add-DomeniaUiLog {param([string]$Area,[string]$Text,[string]$Level)}
    function Confirm-Action {param($Message,$Title);$script:L08.Dialogs++;throw 'Aucune fenetre de confirmation attendue.'}
    function Confirm-WarningAction {param($Message,$Title);$script:L08.Dialogs++;throw 'Aucune fenetre de confirmation attendue.'}
    function Apply-DomeniaGuiElementPolicy {}
    function Update-Dashboard {}
    function Update-DomeniaSearchScopeUi {}
    function Invoke-GlobalSearch {param([switch]$AllowEmpty,[switch]$SilentError,[string]$SearchMode='');$script:L08.Searches++}
    function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,$TaskClass);[void]$script:L08.Tasks.Add([pscustomobject]@{OperationId=$OperationId;Payload=$Payload;State=$CallbackState;Success=$SuccessHandler});return 'task-l08'}
    function Get-DomeniaLocalDatabasePathForRead {return 'C:\DomeniaTest\Domenia.db'}
    function Get-DomeniaLocalIndexReadWorkerCode {return 'fixture'}
    function Queue-DomeniaSelectedObjectOpen {param([switch]$Immediate);$script:L08.Clears++;$script:SelectedObject=$null;$script:SelectionLoad=$null}
    function Apply-CurrentPermissionUi {param([switch]$StartupFastPath)
        # Read-only part of the real function: the switch is the authority, then the write visuals are refreshed.
        $c=Get-DomeniaControl 'ChkReadOnlyMode';if($null -ne $c){$script:ReadOnlyMode=[bool]$c.IsChecked}
        Update-DomeniaWriteModeVisual
    }
    function Get-DomeniaCredentialUserName {param($Credential);return ''}
    $coreNames=@('Get-MainXaml','Get-DomeniaXamlControlNames','Select-DomeniaWorkspace','Set-VisibleTabsForType','Get-DomeniaLandingView','Set-TabVisibility','Assert-DomeniaWorkspaceSelection','Update-DomeniaWriteModeVisual','Apply-DomeniaUiProfile','Save-DomeniaUiProfile','Set-DomeniaContextHint')
    $parseTokens=$null;$parseErrors=$null
    $coreAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'Domenia-Core.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    foreach($fn in @($coreAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
        if($coreNames -contains $fn.Name){. ([scriptblock]::Create($fn.Extent.Text))}
    }
    . (Join-Path $wad 'modules\Domenia-UX.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-Inline.UI.ps1')
    # X04: the five views of Assistance poste, its fixed header and the pill of the operations to check run with their
    # real rules and coordination; the capability routes come from Domenia-Access.UI.ps1.
    . (Join-Path $wad 'modules\Domenia-Assist.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Assist.UI.ps1')
    $accessAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Access.UI.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    foreach($fn in @($accessAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
        if(@('Resolve-DomeniaCapabilityRoute','Invoke-DomeniaCapabilityRoute') -contains $fn.Name){. ([scriptblock]::Create($fn.Extent.Text))}
    }
    # X04 SE-08 / DS-08: the real Invoke-ComputerTool (core) and Publish-DomeniaCommittedPresence (Park.UI) on the real
    # window. Their guards, the sessions read and the stored observation are doubles: nothing is read or sent.
    foreach($fn in @($coreAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
        if(@('Invoke-ComputerTool') -contains $fn.Name){. ([scriptblock]::Create($fn.Extent.Text))}
    }
    $parkAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Park.UI.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    foreach($fn in @($parkAst.FindAll({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]},$true))){
        if(@('Publish-DomeniaCommittedPresence') -contains $fn.Name){. ([scriptblock]::Create($fn.Extent.Text))}
    }
    $mainXaml=Get-MainXaml
    [xml]$mainDoc=$mainXaml
    $mainReader=New-Object Xml.XmlNodeReader $mainDoc
    try{$main=[Windows.Markup.XamlReader]::Load($mainReader)}finally{$mainReader.Close()}
    $main.ShowActivated=$false;$main.ShowInTaskbar=$false;$main.WindowStartupLocation='Manual';$main.Left=0;$main.Top=0;$main.Width=900;$main.Height=640
    $design=Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $converter=[Windows.Media.BrushConverter]::new()
    foreach($property in $design.Palettes.Light.PSObject.Properties){$main.Resources[$property.Name]=$converter.ConvertFromInvariantString([string]$property.Value)}
    $script:Ctrl=@{}
    foreach($name in @(Get-DomeniaXamlControlNames -XamlText $mainXaml)){$c=$main.FindName($name);if($null -ne $c){$script:Ctrl[$name]=$c}}
    $script:Window=$main;$script:BaseWindowTitle='Domenia';$script:CurrentUiProfile='Tech';$script:CurrentTheme='Light';$script:ReadOnlyMode=$true;$script:DemoMode=$false
    $script:Conn=[pscustomobject]@{Domain='example.local';BindUser='EXAMPLE\technicien';User='';BaseDn='DC=example,DC=local'}
    $script:SessionEpoch=7L;$script:DirectoryReachability=$null;$script:ActiveWriteTaskId='';$script:WriteState='Idle'
    $script:SelectedObject=$null;$script:SelectionLoad=$null;$script:UxRecentEntries=$null;$script:UxRecentLastDn='';$script:UxShellInitialized=$false
    $script:ExperienceInitialized=$true
    $main.Show();Pump $main
    # Wiring of the switch exactly as Wire-Events does it (checked by the AST case below).
    $script:Ctrl['ChkReadOnlyMode'].Add_Checked({ Enter-DomeniaReadOnlyMode })
    $script:Ctrl['ChkReadOnlyMode'].Add_Unchecked({ Request-DomeniaWriteMode })
    $script:Ctrl['BtnReadOnlyResume'].Add_Click({ Exit-DomeniaWriteMode -Reason Manual })
    Initialize-DomeniaUxShell;Initialize-DomeniaUiZoom;Pump $main
    try{
        Case 'L08 : Ctrl+L, menu Explorateur WMI et palette ne modifient jamais le profil enregistre' {
            $script:L08.SettingWrites.Clear();$script:CurrentUiProfile='Tech'
            $wire=@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Register-DomeniaShortcuts'},$true))[0].Extent.Text
            Expect ($wire -match 'Key="L"; Modifiers="Control"; Action=\{ Invoke-DomeniaJournalShortcut \}') 'Ctrl+L ne passe pas par Invoke-DomeniaJournalShortcut'
            $select=@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-DomeniaWorkspace'},$true))[0].Extent.Text
            Expect (-not ($select -match 'Apply-DomeniaUiProfile')) 'Select-DomeniaWorkspace change encore le profil'
            Set-DomeniaExperienceJournalLayout -Collapsed $true -Transient;Pump $main
            Invoke-DomeniaJournalShortcut;Pump $main
            Expect (-not [bool]$script:UiLogVisuallyCollapsed) 'Ctrl+L en Essentiel ne deplie pas le journal de session'
            $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-COMPTA-014';DN='CN=PC-COMPTA-014,DC=example,DC=local'}
            Set-VisibleTabsForType -Type 'Machine' -PreserveWorkspace
            Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab 'TabWmi';Pump $main
            # UX-21 (X04): the WMI explorer is the Expert tab of the Diagnostic view.
            Expect (([string]$script:Ctrl['ComputerTabs'].SelectedItem.Name -eq 'TabComputerHealth') -and ([string]$script:Ctrl['ComputerDiagTabs'].SelectedItem.Name -eq 'TabWmi')) ('Explorateur WMI non affiche : '+[string]$script:Ctrl['ComputerTabs'].SelectedItem.Name)
            Select-DomeniaWorkspace -Workspace 'TabApplicationTools' -Inner 'ApplicationToolTabs' -Tab 'TabLog';Pump $main
            Expect ([string]$script:Ctrl['ApplicationToolTabs'].SelectedItem.Name -eq 'TabLog') 'Journal detaille de la palette non affiche'
            Expect ($script:CurrentUiProfile -eq 'Tech') ('Profil modifie : '+$script:CurrentUiProfile)
            Expect (-not ($script:L08.SettingWrites -contains 'UiProfile')) 'Profil enregistre par un raccourci, un menu ou la palette'
            Expect ([string]$script:Ctrl['LstUiProfile'].SelectedItem.Tag -eq 'Tech') 'Le choix du pied de menu a change'
            Update-DomeniaUxProfileVisibility -ObjectType 'Machine';Pump $main
            Expect ($script:Ctrl['TabWmi'].Visibility -ne 'Visible') 'La vue Expert ponctuelle reste affichee apres la mise a jour du profil'
            $script:L08.Cfg['UI.AllowExpertProfile']=$false
            try{
                Update-DomeniaUxProfileSwitch;Pump $main
                Expect ($script:Ctrl['LstUiProfileExpert'].Visibility -eq 'Collapsed') 'Entree Expert visible alors que UI.AllowExpertProfile vaut faux'
                Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab 'TabWmi';Pump $main
                Expect ($script:Ctrl['TabWmi'].Visibility -ne 'Visible') 'Vue Expert affichee malgre UI.AllowExpertProfile = faux'
                Apply-DomeniaUiProfile -Profile 'Admin'
                Expect ($script:CurrentUiProfile -eq 'Tech') 'Expert applique malgre UI.AllowExpertProfile = faux'
            }finally{$script:L08.Cfg.Remove('UI.AllowExpertProfile');Update-DomeniaUxProfileSwitch}
            $script:SelectedObject=$null
        }

        Case 'L08 : retour en lecture seule apres le delai sans ecriture, jamais pendant une ecriture' {
            $script:L08.Statuses.Clear()
            Enable-DomeniaWriteMode;Pump $main
            Expect ((-not [bool]$script:ReadOnlyMode) -and (-not [bool]$script:Ctrl['ChkReadOnlyMode'].IsChecked)) 'Ecriture non activee'
            Expect ([string]$script:Ctrl['ChkReadOnlyMode'].Content -eq 'Écriture active · 15 min') ('Compte a rebours : '+[string]$script:Ctrl['ChkReadOnlyMode'].Content)
            Expect ($script:Ctrl['WriteModeBanner'].IsVisible -and ($script:Ctrl['WriteModeHalo'].Visibility -eq 'Visible')) 'Repasser en lecture ou cadre absent'
            Expect ($null -eq $script:Ctrl['WriteModeHalo'].Effect -and [double]$script:Ctrl['WriteModeHalo'].BorderThickness.Left -eq 3) 'Cadre flou ou epaisseur differente de 3'
            Expect ($null -ne $script:UxReadOnlyTimer -and $script:UxReadOnlyTimer.IsEnabled) 'Minuteur de retour non demarre'
            Expect (@(Update-DomeniaWriteModeVisual).Count -eq 0 -and @(Apply-CurrentPermissionUi).Count -eq 0) 'Le rafraichissement ecrit dans le pipeline de l appelant'
            $script:UxWriteModeSince=(Get-Date).AddMinutes(-40);$script:UxWriteModeLastWrite=$null
            $script:ActiveWriteTaskId='ecriture-en-cours';$script:WriteState='Running'
            $plan=Invoke-DomeniaReadOnlyReturnTick;Pump $main
            Expect (-not [bool]$script:ReadOnlyMode) 'Retour en lecture seule pendant une ecriture'
            $script:ActiveWriteTaskId='';$script:WriteState='Idle'
            $plan=Invoke-DomeniaReadOnlyReturnTick;Pump $main
            Expect ((-not [bool]$script:ReadOnlyMode) -and ([int]$plan.RemainingMinutes -eq 15)) 'La fin d une ecriture ne relance pas le delai'
            $script:UxWriteModeLastWrite=(Get-Date).AddMinutes(-16)
            [void](Invoke-DomeniaReadOnlyReturnTick);Pump $main
            Expect ([bool]$script:ReadOnlyMode -and [bool]$script:Ctrl['ChkReadOnlyMode'].IsChecked) 'Pas de retour en lecture seule apres 15 min sans ecriture'
            Expect ([string]$script:Ctrl['ChkReadOnlyMode'].Content -eq 'Lecture seule') 'Libelle de l interrupteur'
            Expect (-not $script:Ctrl['WriteModeBanner'].IsVisible -and -not $script:UxReadOnlyTimer.IsEnabled) 'Bandeau ou minuteur encore actifs'
            Expect (@($script:L08.Statuses|Where-Object{$_ -like 'Retour automatique en lecture seule*'}).Count -eq 1) 'Retour automatique non annonce'
            Expect ($script:L08.Dialogs -eq 0) 'Une fenetre a ete ouverte'
        }

        Case 'L08 : confirmation de sortie de lecture seule dans la page, sans fenetre' {
            $script:L08.Statuses.Clear();$script:L08.Dialogs=0
            $switch=$script:Ctrl['ChkReadOnlyMode']
            $switch.IsChecked=$false;Pump $main
            Expect ([bool]$switch.IsChecked -and [bool]$script:ReadOnlyMode) 'L interrupteur quitte la lecture seule avant la reponse'
            $panel=Get-DomeniaControl 'InlineRequestPanel'
            Expect ($null -ne $panel -and $panel.IsVisible) 'Pas de panneau de confirmation dans la page'
            Expect ([string](Get-DomeniaControl 'LblInlineRequestTitle').Text -eq 'Autoriser les modifications ?') 'Titre de la demande'
            $message=[string](Get-DomeniaControl 'LblInlineRequestMessage').Text
            Expect (($message -match '^Vous ') -and (@($message.Split('.')|Where-Object{$_.Trim()}).Count -eq 1)) ('Une phrase vouvoyee attendue : '+$message)
            Click (Get-DomeniaControl 'BtnInlineRequestCancel');Pump $main
            Expect ([bool]$script:ReadOnlyMode -and -not $panel.IsVisible) 'Annuler a quitte la lecture seule'
            $switch.IsChecked=$false;Pump $main
            Click (Get-DomeniaControl 'BtnInlineRequestConfirm');Pump $main
            Expect ((-not [bool]$script:ReadOnlyMode) -and (-not [bool]$switch.IsChecked)) 'La confirmation n autorise pas les modifications'
            Expect ([string]$main.Title -match 'CRITURE AD ACTIVE') ('Titre de fenetre en ecriture : '+[string]$main.Title)
            Click (Get-DomeniaControl 'BtnReadOnlyResume');Pump $main
            Expect ([bool]$script:ReadOnlyMode -and [bool]$switch.IsChecked) 'Repasser en lecture sans effet'
            $script:DemoMode=$true
            try{$switch.IsChecked=$false;Pump $main;Expect ([bool]$switch.IsChecked -and -not $panel.IsVisible) 'Demande proposee en demonstration'}finally{$script:DemoMode=$false}
            Expect ($script:L08.Dialogs -eq 0) 'Une fenetre de confirmation a ete ouverte'
            $wire=@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wire-Events'},$true))[0].Extent.Text
            Expect (($wire -match '(?s)\["ChkReadOnlyMode"\]\.Add_Unchecked\(\{.*?Request-DomeniaWriteMode') -and ($wire -match 'Add_Checked\(\{ Enter-DomeniaReadOnlyMode \}\)') -and -not ($wire -match 'Confirm-WarningAction')) 'Wire-Events ne branche pas l interrupteur de la page'
        }

        Case 'L08 : titre de fenetre « Fiche · nom — Domenia », puce du sujet et desinscription' {
            $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';Name='Camille Martin';DN='CN=Camille Martin,OU=Paris,DC=example,DC=local'}
            Select-DomeniaWorkspace -Workspace 'WsObject';Pump $main
            Expect ([string]$main.Title -ceq 'Fiche · Camille Martin — Domenia') ('Titre de fenetre : '+[string]$main.Title)
            Expect ([string]$script:Ctrl['LblUxPageTitle'].Text -ceq 'Fiche · Camille Martin') ('Titre de page : '+[string]$script:Ctrl['LblUxPageTitle'].Text)
            Expect ($script:Ctrl['UxSubjectChip'].IsVisible -and [string]$script:Ctrl['LblUxSubject'].Text -ceq 'Utilisateur · Camille Martin') 'Puce du sujet'
            Expect (@(Get-DomeniaUxRecentEntries|Where-Object{$_.Kind -eq 'Fiche' -and $_.Text -eq 'Camille Martin'}).Count -eq 1) 'Fiche non retenue dans la memoire locale'
            Click $script:Ctrl['BtnUxSubjectClear'];Pump $main
            Expect ($script:L08.Clears -ge 1 -and -not $script:Ctrl['UxSubjectChip'].IsVisible) 'Le bouton de la puce ne desinscrit pas'
            Expect ([string]$main.Title -ceq 'Fiche · Aucune sélection — Domenia') ('Titre apres desinscription : '+[string]$main.Title)
        }

        Case 'L08 : Fiche et Poste actives sans selection, avec une page vide sans reseau' {
            $script:SelectedObject=$null;$script:SelectionLoad=$null;$script:L08.Tasks.Clear();$script:L08.Searches=0
            Set-VisibleTabsForType -Type '' -PreserveWorkspace;Pump $main
            Expect ($script:Ctrl['BtnUxNavObject'].IsEnabled -and $script:Ctrl['BtnUxNavComputer'].IsEnabled) 'Fiche ou Poste grise sans selection'
            Invoke-DomeniaUxRoute -Route 'WsObject';Pump $main
            Expect ([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'WsObject' -and $script:Ctrl['ObjectEmptyState'].IsVisible) 'Page vide de la fiche absente'
            Expect ($script:Ctrl['LstObjectEmptyRecent'].Items.Count -ge 1) 'Dernieres fiches absentes de la page vide'
            Invoke-DomeniaUxRoute -Route 'WsComputer';Pump $main
            Expect ($script:Ctrl['ComputerEmptyState'].IsVisible) 'Page vide du poste absente'
            Expect ($script:L08.Tasks.Count -eq 0 -and $script:L08.Searches -eq 0) 'Une page vide a lance une lecture'
            $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';Name='Jean';DN='CN=Jean,DC=example,DC=local'}
            Sync-DomeniaUxNavigation;Pump $main
            Expect ($script:Ctrl['ComputerEmptyState'].IsVisible) 'Un utilisateur ouvre la page Poste'
            Invoke-DomeniaUxRoute -Route 'WsObject';Pump $main
            Expect (-not $script:Ctrl['ObjectEmptyState'].IsVisible) 'Page vide affichee devant une fiche ouverte'
            $script:SelectedObject=$null;Sync-DomeniaUxNavigation
            Invoke-DomeniaUxEmptySearch -Text 'camille'
            Expect ($script:L08.Searches -eq 1 -and [string]$script:Ctrl['TxtGlobalSearch'].Text -eq 'camille') 'Entree de la page vide ne lance pas la recherche globale'
        }

        Case 'L08 : badge AD injoignable depuis HH:MM puis retour seul, sans relance' {
            $script:L08.Tasks.Clear()
            $outage=[datetime]::UtcNow.AddMinutes(-3)
            $script:DirectoryReachability=[pscustomobject]@{Epoch=7L;Offline=$true;LastOutageUtc=$outage.ToString('o');LastSuccessUtc=$null}
            Update-DomeniaUxSessionBadge;Pump $main
            $expectedText='AD injoignable depuis '+$outage.ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)+' · données déjà lues seulement'
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq $expectedText) ('Badge : '+[string]$script:Ctrl['LblUxDomain'].Text)
            $script:DirectoryReachability=[pscustomobject]@{Epoch=7L;Offline=$true;LastOutageUtc=[datetime]::UtcNow.ToString('o');LastSuccessUtc=$null}
            Update-DomeniaUxSessionBadge
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq $expectedText) 'L heure de debut de la panne a change'
            $script:DirectoryReachability=[pscustomobject]@{Epoch=7L;Offline=$false;LastOutageUtc=$outage.ToString('o');LastSuccessUtc=[datetime]::UtcNow.ToString('o')}
            Update-DomeniaUxSessionBadge;Pump $main
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq 'Connecté à example.local') ('Retour : '+[string]$script:Ctrl['LblUxDomain'].Text)
            Expect ($script:L08.Tasks.Count -eq 0) 'Une relance a ete lancee'
        }

        Case 'L08 : un delai AD utilise un avertissement sans annoncer une panne ni relancer une lecture' {
            $script:L08.Tasks.Clear()
            $script:DirectoryReachability=[pscustomobject]@{Epoch=7L;Offline=$false;Slow=$true;LastTimeoutUtc=[datetime]::UtcNow.ToString('o');LastOutageUtc=$null;LastSuccessUtc=$null}
            Update-DomeniaUxSessionBadge;Pump $main
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq 'Dernière requête AD : délai dépassé') 'Delai AD presente comme panne generale'
            Expect ($script:Ctrl['LblUxDomain'].Foreground -eq $script:Ctrl['LblUxDomain'].FindResource('StatusWarning')) 'Delai AD sans couleur avertissement'
            Expect ([string]$script:Ctrl['LblUxDomain'].ToolTip -match 'ne confirme pas.*coupure') 'Limite du diagnostic absente de l infobulle'
            $script:DirectoryReachability.Offline=$true;$script:DirectoryReachability.LastOutageUtc=[datetime]::UtcNow.AddMinutes(-2).ToString('o')
            Update-DomeniaUxSessionBadge;Pump $main
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -like 'AD injoignable*') 'Un delai a masque une panne etablie'
            Expect ($script:Ctrl['LblUxDomain'].Foreground -eq $script:Ctrl['LblUxDomain'].FindResource('StatusError')) 'Panne etablie sans couleur erreur'
            $script:DirectoryReachability.Epoch=6L
            Update-DomeniaUxSessionBadge;Pump $main
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq 'Connecté à example.local') 'Ancienne session reprise dans le badge'
            $script:DirectoryReachability=[pscustomobject]@{Epoch=7L;Offline=$false;Slow=$false;LastTimeoutUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o');LastOutageUtc=$null;LastSuccessUtc=[datetime]::UtcNow.ToString('o')}
            Update-DomeniaUxSessionBadge;Pump $main
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq 'Connecté à example.local') 'Lecture reussie ne retablit pas le badge'
            Expect ($script:L08.Tasks.Count -eq 0) 'Une relance a ete lancee'
        }

        Case 'L08 : ItemStatus « Page actuelle » et regions annoncees' {
            Invoke-DomeniaUxRoute -Route 'WsSearch';Pump $main
            Expect ([Windows.Automation.AutomationProperties]::GetItemStatus($script:Ctrl['BtnUxNavSearch']) -eq 'Page actuelle') 'Rubrique active non annoncee'
            foreach($name in @('BtnUxNavHome','BtnUxNavObject','BtnUxNavComputer','BtnUxNavRelations','BtnUxNavAccounts','BtnUxNavTools')){Expect ([string]::IsNullOrEmpty([Windows.Automation.AutomationProperties]::GetItemStatus($script:Ctrl[$name]))) ($name+' annoncee comme page actuelle')}
            foreach($name in @('LblUxPageTitle','LblUiLogLast','ChkReadOnlyMode','LblUxDomain')){Expect ([Windows.Automation.AutomationProperties]::GetLiveSetting($script:Ctrl[$name]) -eq 'Polite') ($name+' sans LiveSetting Polite')}
            Expect ([string]$script:Ctrl['LblUxPageTitle'].Text -ceq 'Rechercher') 'Titre = libelle du menu'
            Expect ([string]$script:Ctrl['LblUxDomain'].Text -ceq 'Connecté à example.local') 'Badge de session'
        }

        Case 'L08 : suggestions de la barre sans requete AD, Entree seule interroge l annuaire' {
            $script:L08.Tasks.Clear();$script:L08.Searches=0
            $script:UxRecentEntries=@(Add-DomeniaRecentEntry -Entries @() -Kind Recherche -Text 'dupont')
            $box=$script:Ctrl['TxtGlobalSearch'];$box.Text=''
            Update-DomeniaUxSearchSuggestions;Pump $main
            Expect ($script:Ctrl['UxSearchSuggest'].IsVisible -and $script:Ctrl['LstSearchSuggest'].Items.Count -eq 1) 'Recherches recentes non proposees'
            $box.Text='dup';Update-DomeniaUxSearchSuggestions -Typing;Pump $main
            Expect ($null -ne $script:UxSuggestTimer -and $script:UxSuggestTimer.IsEnabled -and $script:L08.Tasks.Count -eq 0) 'La frappe a lu quelque chose sans pause'
            $script:UxSuggestTimer.Stop();Start-DomeniaUxLocalSuggestions -Text 'dup'
            Expect ($script:L08.Tasks.Count -eq 1 -and $script:L08.Tasks[0].OperationId -eq 'LocalIndexRead' -and [string]$script:L08.Tasks[0].Payload.Action -eq 'Search') 'Suggestions hors de la base locale'
            $result=[pscustomobject]@{Busy=$false;Rows=@([pscustomobject]@{Type='Utilisateur';Name='Dupont Jean';Login='jdupont';Display=''})}
            Complete-DomeniaUxLocalSuggestionsUi $result $script:L08.Tasks[0].State;Pump $main
            Expect ($script:Ctrl['LstSearchSuggest'].Items.Count -eq 2) 'Ligne de la base locale non ajoutee'
            Expect ($script:L08.Searches -eq 0) 'Une suggestion a interroge l annuaire'
            $down=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($main),0,[Windows.Input.Key]::Down)
            $down.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent
            Invoke-DomeniaUxSearchKey -Box $box -KeyEvent $down;$down.Handled=$false;Invoke-DomeniaUxSearchKey -Box $box -KeyEvent $down
            $enter=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($main),0,[Windows.Input.Key]::Enter)
            $enter.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent
            Invoke-DomeniaUxSearchKey -Box $box -KeyEvent $enter;Pump $main
            Expect ([string]$box.Text -ceq 'Dupont Jean' -and -not $enter.Handled) 'Entree ne recopie pas la suggestion ou bloque la recherche de la barre'
            Expect (-not $script:Ctrl['UxSearchSuggest'].IsVisible) 'Liste encore ouverte apres Entree'
            Expect (@(Get-DomeniaUxRecentEntries|Where-Object{$_.Kind -eq 'Recherche' -and $_.Text -eq 'Dupont Jean'}).Count -eq 1) 'Recherche non retenue'
            $late=$script:L08.Tasks[0].State;$script:UxSuggestWanted=$false
            Complete-DomeniaUxLocalSuggestionsUi $result $late
            Expect (-not $script:Ctrl['UxSearchSuggest'].IsVisible) 'Une reponse tardive rouvre la liste'
            $clear=$script:Ctrl['BtnGlobalSearchClear']
            Expect ($clear.Visibility -eq 'Visible') 'Bouton effacer absent'
            Click $clear;Pump $main
            Expect ([string]$box.Text -eq '' -and $clear.Visibility -eq 'Collapsed' -and $script:L08.Searches -eq 0) 'Effacer ne vide pas seulement le texte'
            Hide-DomeniaUxSearchSuggestions
        }

        # 1280 x 688 is the work area of a 1920 x 1080 screen at 150 %.
        Case 'L08 : a 960, 1280 et 1360 la recherche garde 280, le menu suit le viewport utile, rien n est rogne' {
            # Fixed work area (as Preview-DomeniaUi, TE-08): the lab screen (1024x768) would clamp a real 1280 window.
            $content=$main.Content
            $area=New-Object Windows.Controls.Border;$canvas=New-Object Windows.Controls.Canvas
            $main.Content=$null;$area.Child=$content;[void]$canvas.Children.Add($area);$main.Content=$canvas
            $realWindow=$script:Window;$script:Window=$area
            try{
                foreach($size in @(@(960,700),@(1280,688),@(1360,760))){
                    $area.Width=$size[0];$area.Height=$size[1]
                    $script:UxLayoutSignature='';$script:UxNavLayoutSignature='';$script:UxNavCollapsed=$false
                    $area.Measure([Windows.Size]::new($size[0],$size[1]));$area.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]))
                    Update-DomeniaUxLayout;Pump $main
                    $area.Measure([Windows.Size]::new($size[0],$size[1]));$area.Arrange([Windows.Rect]::new(0,0,$size[0],$size[1]));Pump $main
                    $label=[string]$size[0]+'x'+[string]$size[1]
                    # The shell uses the logical viewport, not outer-window chrome; verify both folded and expanded widths.
                    $scroll=$script:Ctrl['RootScroll'];$logicalWidth=[Math]::Max(900.0,[double]$scroll.ViewportWidth)
                    Expect ($script:DomeniaUiZoomPercent -eq 100) ($label+' : le banc doit verifier le layout a 100 %')
                    Expect ($scroll.ViewportWidth -gt 0 -and $scroll.ViewportWidth -le $size[0]) ($label+' : viewport non mesure')
                    $navWanted=if($logicalWidth -lt 1280){68}else{204}
                    Expect ($script:Ctrl['UxNavColumn'].Width.Value -eq $navWanted) ($label+' : largeur du menu '+$script:Ctrl['UxNavColumn'].Width.Value+' au lieu de '+$navWanted+' ; viewport '+$scroll.ViewportWidth+' ; repli temporaire '+$script:UxShortNavFold)
                    Expect (-not [bool]$script:UxNavCollapsed) ($label+' : preference du menu modifiee')
                    Expect ($script:Ctrl['TxtGlobalSearch'].ActualWidth -ge 280) ($label+' : recherche a '+[Math]::Round($script:Ctrl['TxtGlobalSearch'].ActualWidth))
                    $measured=@{}
                    foreach($slot in (Get-DomeniaActivityStripSlots).Slots){$c=$script:Ctrl[[string]$slot.Name];$measured[[string]$slot.Name]=@{Width=$c.Width;Height=$c.Height;MaxWidth=$c.MaxWidth;MaxHeight=$c.MaxHeight}}
                    $measured['__StripColumns']=@(foreach($col in $script:Ctrl['UxActivityStrip'].ColumnDefinitions){$col.Width.ToString()})
                    $measured['__RowHeight']=44.0;$measured['__StripHeight']=[double]$script:Ctrl['UxActivityStrip'].Height
                    $issues=@(Compare-DomeniaReservedSlots -Expected (Get-DomeniaActivityStripSlots) -Measured $measured)
                    Expect ($issues.Count -eq 0) ($label+' : '+($issues -join '; '))
                    foreach($name in @('BtnGlobalSearch','BtnAccessRecovery','BtnSuiteActivity','BtnThemeToggle','BtnUxHelpToggle','BtnCancelTask','ChkReadOnlyMode','LblUxPageTitle','BtnNavBack','BtnCommandPalette')){
                        $c=$script:Ctrl[$name];$p=$c.TranslatePoint([Windows.Point]::new(0,0),$area)
                        Expect (($p.X -ge -0.5) -and ($p.Y -ge -0.5) -and (($p.X+$c.ActualWidth) -le ($size[0]+0.5)) -and ($c.ActualWidth -ge 8)) ($label+' : '+$name+' rogne ('+[Math]::Round($p.X)+'+'+[Math]::Round($c.ActualWidth)+')')
                    }
                    Expect ($script:Ctrl['ChkReadOnlyMode'].ActualWidth -ge 200) ($label+' : interrupteur rogne')
                    $hostWanted=if(($logicalWidth-$navWanted-40.0) -lt 1000.0){'UxHeaderTools'}else{'UxPageHeaderBar'}
                    Expect ([string]$script:Ctrl['UxReadOnlyHost'].Parent.Name -eq $hostWanted) ($label+' : interrupteur dans '+[string]$script:Ctrl['UxReadOnlyHost'].Parent.Name+' au lieu de '+$hostWanted)
                    Expect ($script:Ctrl['LblUxPageTitle'].ActualWidth -ge 60) ($label+' : titre de page ecrase a '+[Math]::Round($script:Ctrl['LblUxPageTitle'].ActualWidth))
                }
            }finally{
                $area.Child=$null;$main.Content=$null;$main.Content=$content;$script:Window=$realWindow;$script:UxLayoutSignature='';$script:UxNavLayoutSignature=''
            }
        }
        # MO-04: unwired if the count button comes back, if the overview counts the directory again, or if the totals
        # are not read from the local copy (LocalIndexRead, explicit gesture) with their date.
        Case 'MO-04 : Analyser le domaine ne denombre plus l annuaire, les totaux viennent de la copie locale' {
            Expect ($null -eq $main.FindName('BtnCountDomain')) 'Le bouton Analyser et denombrer est revenu.'
            $label=$script:Ctrl['LblDomainLocalTotals']
            Expect ($null -ne $label) 'Libelle des totaux absent de la fenetre principale.'
            Expect ([string]$label.ToolTip -ceq [string][Windows.Automation.AutomationProperties]::GetHelpText($label)) 'Totaux : infobulle et aide divergent.'
            $worker=@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DomeniaDomainWorkerCode'},$true))[0].Extent.Text
            Expect ((-not $worker.Contains('Denombrement')) -and (-not $worker.Contains('$Payload.Count'))) 'Le worker DomainOverview denombre encore lʼannuaire.'
            $overviewAst=@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-DomeniaDomainOverview'},$true))
            Expect ($overviewAst.Count -eq 1) 'Start-DomeniaDomainOverview absent.'
            . ([scriptblock]::Create($overviewAst[0].Extent.Text))
            $dashboardTokens=$null;$dashboardErrors=$null
            $dashboardAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Dashboard.UI.ps1'),[ref]$dashboardTokens,[ref]$dashboardErrors)
            foreach($fn in @($dashboardAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*-DomeniaDomainLocalTotals*'},$true))){. ([scriptblock]::Create($fn.Extent.Text))}
            . (Join-Path $wad 'modules\Domenia-Search.Model.ps1')
            . (Join-Path $wad 'modules\Domenia-Directory.Model.ps1')
            $tasks=New-Object 'System.Collections.ArrayList'
            function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler,$TaskClass);[void]$tasks.Add([pscustomobject]@{OperationId=[string]$OperationId;Payload=$Payload;State=$CallbackState;Disable=@($DisableControls)});return ('task-mo04-'+$tasks.Count)}
            function Initialize-DomeniaWinSqliteNative {return $true}
            function Get-DomeniaFleetQueryPlan {param($ObservationMaxAgeDays,$Now,$HealthPolicy);return [pscustomobject]@{Fixture=$true}}
            function Get-DomeniaObservationMaxAgeDays {return 30}
            function Get-DomeniaDomainWorkerCode {return 'fixture'}
            function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,[switch]$NoPopup);throw ([string]$ErrorRecordOrException)}
            $script:DatabaseScopedPath='C:\DomeniaTest\Domenia.db';$script:DashboardModuleRoot=Join-Path $wad 'modules';$script:DomainTotalsState=$null
            Start-DomeniaDomainOverview
            $overview=@($tasks|Where-Object{$_.OperationId -eq 'DomainOverview'});$local=@($tasks|Where-Object{$_.OperationId -eq 'LocalIndexRead'})
            Expect ($tasks.Count -eq 2) ('Lectures lancees : '+(@($tasks|ForEach-Object{$_.OperationId}) -join ', '))
            Expect (($overview.Count -eq 1) -and ($null -eq $overview[0].Payload.PSObject.Properties['Count']) -and (-not ($overview[0].Disable -contains 'BtnCountDomain'))) 'Analyse : un comptage est encore demande.'
            Expect (($local.Count -eq 1) -and ([string]$local[0].Payload.Action -eq 'FleetStats') -and ([string]$local[0].Payload.Scope -eq [string]$script:Conn.BaseDn) -and (-not [bool]$local[0].Payload.Subtree) -and (-not [bool]$local[0].Payload.ComputeBoard)) 'Totaux : lecture locale attendue.'
            Expect ($label.Text -eq 'Totaux du domaine : lecture de la copie locale…') ('Etat de lecture : '+$label.Text)
            $sync=@{directory=[pscustomobject]@{scope='directory';last_sync='2026-10-14T06:15:00.0000000Z'}}
            $answer=[pscustomobject]@{Busy=$false;Missing=$false;Types=@([pscustomobject]@{t='Utilisateur';s='Actif';n=12},[pscustomobject]@{t='Machine';s='Actif';n=5});SyncStates=$sync}
            Complete-DomeniaDomainLocalTotals -Result $answer -State $local[0].State
            Expect (($label.Text.StartsWith('Totaux de la copie locale au ')) -and ($label.Text.EndsWith(' : 12 utilisateurs · 5 postes.'))) ('Libelle : '+$label.Text)
            $old=$local[0].State;Start-DomeniaDomainOverview
            Complete-DomeniaDomainLocalTotals -Result ([pscustomobject]@{Busy=$false;Missing=$false;Types=@();SyncStates=@{}}) -State $old
            Expect ($label.Text -eq 'Totaux du domaine : lecture de la copie locale…') 'Un ancien resultat a remplace la lecture en cours.'
        }
        # UI-06: unwired if the fiche shows DN lists again, if the grids lose their filter or counter, if « Pourquoi membre ? »
        # reads anything for a group already explained, or if the nested groups are read without the explicit gesture.
        Case 'UI-06 : appartenances en grilles lisibles, filtre local, groupes imbriques et Pourquoi membre au clic' {
            foreach($n in @('LstMemberOf','LstGroupMembers')){Expect ($null -eq $main.FindName($n)) ('Liste de DN revenue : '+$n)}
            foreach($n in @('DgMemberOf','DgGroupMembers','TxtMemberOfFilter','TxtGroupMembersFilter','BtnMemberOfNested','LblMembershipWhy')){
                $c=$script:Ctrl[$n];Expect ($null -ne $c) ('Controle absent : '+$n)
                Expect ([string]$c.ToolTip -ceq [string][Windows.Automation.AutomationProperties]::GetHelpText($c)) ('Infobulle et aide divergent : '+$n)
            }
            foreach($file in @('Domenia-Common.Model.ps1','Domenia-Search.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Membership.Worker.ps1','Domenia-Membership.UI.ps1')){. (Join-Path $wad ('modules\'+$file))}
            foreach($name in @('Get-DomeniaMembershipLabel','New-DomeniaMenuItem')){. ([scriptblock]::Create(@($coreAst.FindAll({param($n)$n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))[0].Extent.Text))}
            $tasks=New-Object 'System.Collections.ArrayList'
            function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler,$TaskClass);[void]$tasks.Add([pscustomobject]@{OperationId=[string]$OperationId;Payload=$Payload;State=$CallbackState;Success=[string]$SuccessHandler});return ('task-ui06-'+$tasks.Count)}
            function Get-DomeniaLocalDatabasePathForRead {return 'C:\DomeniaTest\Domenia.db'}
            function Get-DomeniaLocalIndexReadWorkerCode {return 'fixture'}
            function Start-DomeniaSearchFor {param($Term);$script:SearchedFor=[string]$Term}
            function Set-ClipboardSafe {param($Text);$script:Copied=[string]$Text}
            $user='CN=Jean Dupont,OU=RH,DC=example,DC=local';$g1='CN=GG-Lyon,OU=Groupes,DC=example,DC=local';$g2='CN=GG-RH,OU=Groupes,DC=example,DC=local';$g3='CN=GG-Compta,OU=Groupes,DC=example,DC=local'
            $script:SelectedObjectGeneration=3L;$script:SelectedObject=[pscustomobject]@{DN=$user;Type='Utilisateur';Name='Jean Dupont'};$script:MembershipUiBound=$false
            [void](Register-DomeniaMembershipUi)
            Set-DomeniaMembershipList -Kind MemberOf -Dns @($g1,$g2) -ObjectDn $user;Pump $main
            $grid=$script:Ctrl['DgMemberOf']
            Expect (($grid.Items.Count -eq 2) -and ([string]$grid.Items[0].Name -eq 'GG-Lyon') -and ([string]$grid.Items[0].Ou -eq 'example.local / Groupes')) 'Groupes non lisibles.'
            Expect ([string]$script:Ctrl['LblMemberOf'].Text -eq '2 groupe(s) direct(s)') ('Compteur : '+$script:Ctrl['LblMemberOf'].Text)
            $script:Ctrl['TxtMemberOfFilter'].Text='lyon';Pump $main
            Expect (($grid.Items.Count -eq 1) -and ([string]$script:Ctrl['LblMemberOf'].Text).Contains('1 affiché(s) après le filtre')) ('Filtre : '+$script:Ctrl['LblMemberOf'].Text)
            $script:Ctrl['TxtMemberOfFilter'].Text='';Pump $main
            Expect ($grid.Items.Count -eq 2) 'Le filtre vide ne reaffiche pas tout.'
            $grid.SelectedItem=$grid.Items[0];Invoke-DomeniaMembershipWhy
            Expect (([string]$script:Ctrl['LblMembershipWhy'].Text).Contains('membre direct de « GG-Lyon »') -and ($tasks.Count -eq 0)) ('Pourquoi direct : '+$script:Ctrl['LblMembershipWhy'].Text)
            Click $script:Ctrl['BtnMemberOfNested']
            $read=@($tasks|Where-Object{$_.OperationId -eq 'GroupPathRead'})
            # Same pinned body as the nested groups of the Audit AD (point 103): the worker reads the object's memberOf itself.
            Expect (($read.Count -eq 1) -and ([string]$read[0].Payload.Dn -eq $user) -and ([string]$read[0].Payload.Mode -eq 'Expand') -and ([int]$read[0].Payload.MaxNodes -eq 2000) -and (-not [string]$read[0].Payload.TargetDn)) 'Lecture des groupes imbriques non conforme.'
            $answer=[pscustomobject]@{Dn=$user;Mode='Expand';StartParents=@($g1,$g2);StartComplete=$true;StartNote='';Nodes=@([pscustomobject]@{Dn=$g1;Name='GG-Lyon';Parents=@($g3)},[pscustomobject]@{Dn=$g2;Name='GG-RH';Parents=@()},[pscustomobject]@{Dn=$g3;Name='GG-Compta';Parents=@()});Unread=@([pscustomobject]@{Dn='CN=GU,DC=autre,DC=local';Reason='Autre domaine ou partition : non lu depuis ce contrôleur'});Truncated=$false;TruncatedReason='';PrimaryGroup=[pscustomobject]@{Sid='S-1-5-21-1-2-3-513';Dn='CN=Domain Users,CN=Users,DC=example,DC=local';Name='Domain Users';Error=''};TargetDn='';ServerAnswer=$null;ServerError=''}
            Complete-DomeniaMembershipPathRead -Result $answer -State $read[0].State;Pump $main
            $nested=@($grid.Items|Where-Object{[string]$_.Membership -eq 'Imbriquée'})
            Expect (($grid.Items.Count -eq 3) -and ($nested.Count -eq 1) -and ([string]$nested[0].Name -eq 'GG-Compta') -and ([string]$nested[0].Via -eq 'GG-Lyon')) 'Groupe imbrique absent de la grille.'
            Expect (([string]$script:Ctrl['LblMembershipWhy'].Text).Contains('1 groupe(s) imbriqué(s)') -and ([string]$script:Ctrl['LblMembershipWhy'].Text).Contains('1 autre domaine') -and ([string]$script:Ctrl['LblMembershipWhy'].Text).Contains('Groupe principal : Domain Users')) ('Resume : '+$script:Ctrl['LblMembershipWhy'].Text)
            Expect (([string]$script:Ctrl['LblMemberOf'].Text).Contains('1 groupe(s) imbriqué(s) lu(s)')) ('Compteur : '+$script:Ctrl['LblMemberOf'].Text)
            $grid.SelectedItem=$nested[0];Invoke-DomeniaMembershipWhy
            Expect (([string]$script:Ctrl['LblMembershipWhy'].Text).Contains('Jean Dupont → GG-Lyon → GG-Compta (2 niveaux)') -and (@($tasks|Where-Object{$_.OperationId -eq 'GroupPathRead'}).Count -eq 1)) ('Pourquoi imbrique : '+$script:Ctrl['LblMembershipWhy'].Text)
            $headers=@($grid.ContextMenu.Items|Where-Object{$_ -is [Windows.Controls.MenuItem]}|ForEach-Object{[string]$_.Header})
            Expect (($headers -contains 'Pourquoi membre ?') -and ($headers -contains 'Afficher les groupes imbriqués') -and ($headers -contains 'Copier le DN')) ('Menu : '+($headers -join ', '))
            # A late answer for a fiche replaced since is ignored.
            $script:SelectedObjectGeneration=4L
            Complete-DomeniaMembershipPathRead -Result ([pscustomobject]@{Dn=$user;TargetDn='';StartParents=@();Nodes=@();Unread=@();Truncated=$false}) -State $read[0].State
            Expect ($grid.Items.Count -eq 3) 'Une ancienne reponse a modifie la grille.'
            # Members of a group: readable rows, types read in the local copy (no directory request).
            $group='CN=GG-Postes,OU=Groupes,DC=example,DC=local';$pc='CN=PC-COMPTA-014,OU=Postes,DC=example,DC=local';$other='CN=Inconnu,OU=Postes,DC=example,DC=local'
            Set-DomeniaMembershipList -Kind Members -Dns @($pc,$other) -ObjectDn $group;Pump $main
            $types=@($tasks|Where-Object{$_.OperationId -eq 'LocalIndexRead'})
            Expect (($types.Count -eq 1) -and ([string]$types[0].Payload.Action -eq 'ResolveNames') -and (@($types[0].Payload.Dns).Count -eq 2)) 'Lecture locale des types non demandee.'
            Complete-DomeniaMembershipTypes -Result ([pscustomobject]@{Busy=$false;Missing=$false;Objects=@([pscustomobject]@{distinguished_name=$pc;object_type='Machine';name='PC-COMPTA-014'})}) -State $types[0].State;Pump $main
            $members=$script:Ctrl['DgGroupMembers']
            Expect (([string]$members.Items[0].Type -eq 'Machine') -and ([string]$members.Items[1].Type -eq 'Non lu')) 'Types des membres non appliques.'
            $memberHeaders=@($members.ContextMenu.Items|Where-Object{$_ -is [Windows.Controls.MenuItem]}|ForEach-Object{[string]$_.Header})
            Expect (-not ($memberHeaders -contains 'Pourquoi membre ?')) 'Les membres directs dʼun groupe nʼont pas besoin dʼexplication.'
            Expect (@($tasks|Where-Object{$_.OperationId -notin @('GroupPathRead','LocalIndexRead')}).Count -eq 0) 'Une autre lecture a ete lancee.'
            # A group without members shows no row (never one empty pseudo-row) and reads no type.
            $before=$tasks.Count
            Set-DomeniaMembershipList -Kind Members -Dns @() -ObjectDn $g3;Pump $main
            Expect (($members.Items.Count -eq 0) -and ($tasks.Count -eq $before)) ('Groupe vide : '+$members.Items.Count+' ligne(s), '+($tasks.Count-$before)+' lecture(s).')
            Clear-DomeniaMembershipLists;Pump $main
            Expect (($null -eq $grid.ItemsSource) -and ($null -eq $members.ItemsSource) -and ($script:Ctrl['LblMembershipWhy'].Visibility -eq 'Collapsed')) 'Appartenances de lʼobjet precedent encore affichees.'
            $script:SelectedObject=$null
        }

        # X04 doubles, defined after the L08 cases: the guards of Invoke-ComputerTool, the sessions read, the stored
        # observation and the draft comparison. They only record.
        $script:X04=[pscustomobject]@{Sessions=0;Errors=New-Object 'System.Collections.ArrayList';DraftCompare=0}
        function Get-CurrentSelectedComputerName {return 'PC-COMPTA-014'}
        function Assert-DomeniaComputerTarget {param([string]$Computer);return $Computer}
        function Assert-DomeniaRemoteWriteAllowed {param([string]$Operation)}
        function Assert-WriteAllowed {}
        function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,$CorrelationId,[switch]$NoPopup);[void]$script:X04.Errors.Add([string]$ErrorRecordOrException)}
        function Get-DomeniaSelectedMachineName {return 'pc-compta-014.example.local'}
        function Start-DomeniaSessionsRead {$script:X04.Sessions++}
        function Test-DomeniaControlIsBusy {param([string]$Name);return $false}
        function Get-DomeniaSelectionCachePolicy {return [pscustomobject]@{Offline=$false;CanEdit=$true}}
        function Show-DomeniaDraftComparison {$script:X04.DraftCompare++}
        function Get-DomeniaCommittedObservation {param($Result,$State);return $Result}
        function Set-DomeniaResultRowPresence {param($Dn,$Target,$Observation)}
        function Get-DomeniaLivePresenceView {param($Observation,[switch]$Cached);return [pscustomobject]@{Display=[string]$Observation.Presence;State=[string]$Observation.Presence;Detail=''}}
        function Set-DomeniaPresenceText {param([string]$Name,[AllowEmptyString()][string]$State);[void](Set-DomeniaControlText -Name $Name -Text $State)}
        function Update-DomeniaObjectPresence {param([string]$State,[string]$Target)}
        Case 'X04 UX-21 / DS-08 : cinq vues, anciens noms d onglet resolus, en-tete du poste fixe hors des vues' {
            $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-COMPTA-014';DN='CN=PC-COMPTA-014,DC=example,DC=local'}
            Set-VisibleTabsForType -Type 'Machine' -PreserveWorkspace
            $content=$script:Ctrl['ComputerReadContent'];$content.Visibility='Visible';$content.IsEnabled=$true
            if($null -ne $script:Ctrl['ComputerEmptyState']){$script:Ctrl['ComputerEmptyState'].Visibility='Collapsed'}
            $views=@($script:Ctrl['ComputerTabs'].Items|ForEach-Object{[string]$_.Name})
            Expect (($views -join ',') -ceq ((Get-DomeniaComputerViewNames) -join ',')) ('Vues : '+($views -join ','))
            Expect ([string][Windows.LogicalTreeHelper]::GetParent($script:Ctrl['TabInventory']).Name -eq 'ComputerDetailTabs') 'Inventaire hors de la vue Details'
            Expect ([string][Windows.LogicalTreeHelper]::GetParent($script:Ctrl['TabWmi']).Name -eq 'ComputerDiagTabs') 'WMI hors de la vue Diagnostic'
            $header=$script:Ctrl['UxComputerHeader'];$top=$null
            foreach($old in @('TabComputer','TabComputerDashboard','TabComputerAdmin','TabSessions','TabInventory','TabSoftware','TabComputerHealth','TabSecurity')){
                Select-DomeniaWorkspace -Workspace 'WsComputer' -Inner 'ComputerTabs' -Tab $old;Pump $main
                $route=Resolve-DomeniaComputerViewRoute -Tab $old
                Expect ([string]$script:Ctrl['ComputerTabs'].SelectedItem.Name -eq [string]$route.View) ($old+' ouvre '+[string]$script:Ctrl['ComputerTabs'].SelectedItem.Name)
                if([string]$route.Sub){Expect ([string]$script:Ctrl[[string]$route.Inner].SelectedItem.Name -eq [string]$route.Sub) ($old+' : onglet interieur '+[string]$script:Ctrl[[string]$route.Inner].SelectedItem.Name)}
                Expect ($header.IsVisible) ('En-tete du poste masque dans '+$old)
                $y=$header.TranslatePoint([Windows.Point]::new(0,0),$content).Y
                if($null -eq $top){$top=$y}
                Expect ([Math]::Abs($y-$top) -lt 0.5) ('En-tete deplace dans '+$old+' : '+$y+' au lieu de '+$top)
            }
            $parent=[Windows.Media.VisualTreeHelper]::GetParent($header);$inside=$false
            while($null -ne $parent){if([object]::ReferenceEquals($parent,$script:Ctrl['ComputerTabs'])){$inside=$true;break};$parent=[Windows.Media.VisualTreeHelper]::GetParent($parent)}
            Expect (-not $inside) 'L en-tete du poste appartient a une vue'
            foreach($name in @('BtnCompAccountPill','BtnCompHeaderRdp','BtnCompHeaderC','BtnCompHeaderPing')){Expect ($script:Ctrl[$name].IsVisible) ($name+' masque')}
            # X03 x X04: the « Compte poste » pill lives in this header, the one header of the five views.
            $owner=[Windows.LogicalTreeHelper]::GetParent($script:Ctrl['BtnCompAccountPill']);while(($null -ne $owner) -and (-not [object]::ReferenceEquals($owner,$header))){$owner=[Windows.LogicalTreeHelper]::GetParent($owner)}
            Expect ($null -ne $owner) 'Pastille Compte poste hors de l en-tete du poste'
            foreach($name in @('BtnCompHeaderC','BtnCompC')){
                $button=$script:Ctrl[$name]
                Expect (([string]$button.Content -eq 'Ouvrir le disque C') -and ([string]$button.ToolTip).Contains('C$') -and ([string][Windows.Automation.AutomationProperties]::GetName($button)).Contains('C$')) ($name+' : '+[string]$button.Content)
            }
            $script:SelectedObject=$null
        }

        Case 'X04 UX-19 : pastille des operations a verifier seulement s il en reste, aucun chemin ecrit vers Fiabilite' {
            $script:SelectedObject=$null;$script:ReceiptPending=0;$script:DomeniaAssist=$null
            Initialize-DomeniaAssist;Pump $main
            $pill=$script:Ctrl['BtnPendingOperations']
            Expect ($pill.Visibility -eq 'Collapsed') 'Pastille affichee sans operation a verifier'
            $script:ReceiptPending=2;Update-DomeniaPendingOperationsPill;Pump $main
            Expect (($pill.Visibility -eq 'Visible') -and ([string]$pill.Content -eq '2 opérations à vérifier')) ('Pastille : '+[string]$pill.Content)
            Click $pill;Pump $main
            Expect (([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'TabApplicationTools') -and ([string]$script:Ctrl['ApplicationToolTabs'].SelectedItem.Name -eq 'TabGuard')) 'La pastille n ouvre pas la liste des recus'
            $script:ReceiptPending=0;Update-DomeniaPendingOperationsPill
            Expect ($pill.Visibility -eq 'Collapsed') 'Pastille restee apres la verification'
            Expect ([string](Resolve-DomeniaCapabilityRoute -Route 'TabGuard').Label -eq 'Opérations à vérifier') 'La route des recus parle encore de Fiabilite'
            foreach($name in @('BtnGuardStoreResume','BtnGuardLegacyImport')){
                $node=$script:Ctrl[$name];$owner=''
                while($null -ne $node){if(([string]$node.Name) -in @('TabGuard','TabIndexStorage')){$owner=[string]$node.Name;break};$node=[Windows.LogicalTreeHelper]::GetParent($node)}
                Expect ($owner -eq 'TabIndexStorage') ($name+' dans '+$owner+' au lieu de Base autonome, onglet Stockage')
            }
            # No string shown by the application names a path to the hidden tab.
            $files=@(Join-Path $wad 'Domenia-Core.ps1')+@(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File|ForEach-Object{$_.FullName})
            foreach($file in $files){
                $fileTokens=$null;$fileErrors=$null
                $fileAst=[System.Management.Automation.Language.Parser]::ParseFile($file,[ref]$fileTokens,[ref]$fileErrors)
                foreach($node in @($fileAst.FindAll({param($n) ($n -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or ($n -is [System.Management.Automation.Language.ExpandableStringExpressionAst])},$true))){
                    $value=[string]$node.Extent.Text
                    Expect (-not ($value -match '(?i)Outils\s*>\s*Fiabilit|dans Fiabilit')) ((Split-Path -Leaf $file)+' : '+$value.Substring(0,[Math]::Min(120,$value.Length)))
                }
            }
            # The routes that replace the written paths: Base autonome, onglet Stockage, the button of the action focused.
            foreach($case in @(@('StorageResume','BtnGuardStoreResume'),@('LegacyImport','BtnGuardLegacyImport'))){
                Select-DomeniaWorkspace -Workspace 'WsSearch';Pump $main
                $button=$script:Ctrl[[string]$case[1]];$scope=[Windows.Input.FocusManager]::GetFocusScope($button)
                [Windows.Input.Keyboard]::ClearFocus();[Windows.Input.FocusManager]::SetFocusedElement($scope,$null)
                Expect ([bool](Invoke-DomeniaCapabilityRoute -Route ([string]$case[0]))) ([string]$case[0]+' : route refusee')
                Pump $main
                Expect ([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'TabApplicationTools') ([string]$case[0]+' ouvre '+[string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name)
                Expect ([string]$script:Ctrl['ApplicationToolTabs'].SelectedItem.Name -eq 'TabIndex') ([string]$case[0]+' : outil '+[string]$script:Ctrl['ApplicationToolTabs'].SelectedItem.Name)
                Expect ([string]$script:Ctrl['IndexWorkspaceTabs'].SelectedItem.Name -eq 'TabIndexStorage') ([string]$case[0]+' : onglet '+[string]$script:Ctrl['IndexWorkspaceTabs'].SelectedItem.Name)
                Expect (([object]::ReferenceEquals([Windows.Input.FocusManager]::GetFocusedElement($scope),$button)) -or ($button.IsKeyboardFocused)) ([string]$case[0]+' : '+[string]$case[1]+' sans le focus')
                Expect ([string](Resolve-DomeniaCapabilityRoute -Route ([string]$case[0])).Label -eq 'Base autonome > Stockage') ([string]$case[0]+' : libelle')
            }
            # Comparer les saisies opens the comparison of the fiche in place: no page change.
            Select-DomeniaWorkspace -Workspace 'WsSearch';Pump $main
            $script:X04.DraftCompare=0
            Expect ([bool](Invoke-DomeniaCapabilityRoute -Route 'DraftCompare')) 'DraftCompare refusee'
            Expect (($script:X04.DraftCompare -eq 1) -and ([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'WsSearch')) ('Comparaison : '+$script:X04.DraftCompare+' ; page '+[string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name)
        }

        Case 'X04 SE-08 : Redemarrer depuis Rechercher ouvre le panneau dans Assistance poste > Intervenir, sans rien envoyer' {
            $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-COMPTA-014';DN='CN=PC-COMPTA-014,DC=example,DC=local'}
            Set-VisibleTabsForType -Type 'Machine' -PreserveWorkspace
            $content=$script:Ctrl['ComputerReadContent'];$content.Visibility='Visible';$content.IsEnabled=$true
            if($null -ne $script:Ctrl['ComputerEmptyState']){$script:Ctrl['ComputerEmptyState'].Visibility='Collapsed'}
            Select-DomeniaWorkspace -Workspace 'WsSearch';Pump $main
            Expect ([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'WsSearch') 'Rechercher non affiche avant le clic'
            $script:X04.Sessions=0;$script:X04.Errors.Clear();$tasks=$script:L08.Tasks.Count
            # The entry « Redémarrer le poste… » of the results menu calls exactly this.
            Invoke-ComputerTool 'Restart';Pump $main
            Expect ($script:X04.Errors.Count -eq 0) ('Erreur : '+($script:X04.Errors -join ' | '))
            Expect ([string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name -eq 'WsComputer') ('Page affichee : '+[string]$script:Ctrl['WorkspaceTabs'].SelectedItem.Name)
            Expect ([string]$script:Ctrl['ComputerTabs'].SelectedItem.Name -eq 'TabComputerAdmin') ('Vue : '+[string]$script:Ctrl['ComputerTabs'].SelectedItem.Name)
            Expect ($script:Ctrl['UxCompRestartPanel'].IsVisible) 'Panneau de redemarrage invisible'
            Expect (($script:X04.Sessions -eq 1) -and ($script:L08.Tasks.Count -eq $tasks)) ('Lectures des sessions : '+$script:X04.Sessions+' ; taches : '+($script:L08.Tasks.Count-$tasks))
            Close-DomeniaComputerRestartPanel;Pump $main
            Expect (-not $script:Ctrl['UxCompRestartPanel'].IsVisible) 'Panneau reste ouvert'
            $script:SelectedObject=$null
        }

        Case 'X04 DS-08 : heure de la pastille = heure du test publie, meme si la reponse ne change pas' {
            $script:SelectedObject=[pscustomobject]@{Type='Machine';Name='PC-COMPTA-014';DN='CN=PC-COMPTA-014,DC=example,DC=local'}
            $script:InventoryCompletedAt=$null;$script:Live=$null;$script:RenderingObjectWithoutProbes=$false
            Initialize-DomeniaAssist
            $script:Ctrl['TxtCompPresence'].Text='';$script:Ctrl['TxtCompPresence'].Text='Non verifie';Pump $main
            $label=$script:Ctrl['LblCompHeaderPresence']
            Expect ([string]$label.Text -eq 'Présence non vérifiée') ('Avant le test : '+[string]$label.Text)
            $state=[pscustomobject]@{Computer='pc-compta-014.example.local';DisplayDN=[string]$script:SelectedObject.DN;DisplayKind='Machine';Suffix='';Explicit=$true}
            $first=[datetime]::SpecifyKind([datetime]'2026-10-15 08:00:00',[DateTimeKind]::Utc)
            $second=[datetime]::SpecifyKind([datetime]'2026-10-15 08:30:00',[DateTimeKind]::Utc)
            foreach($at in @($first,$second)){
                $observation=[pscustomobject]@{Key=[string]$script:SelectedObject.DN;Presence='En ligne';PresenceCheckedUtc=$at.ToString('o');PresenceAttemptUtc=$at.ToString('o')}
                Publish-DomeniaCommittedPresence -Result $observation -State $state;Pump $main
                $expected='Répond au ping · '+$at.ToLocalTime().ToString('HH:mm',[Globalization.CultureInfo]::InvariantCulture)
                Expect ([string]$label.Text -eq $expected) ('Pastille : '+[string]$label.Text+' au lieu de '+$expected)
            }
            Expect ([string]$script:Ctrl['TxtCompPresence'].Text -eq 'En ligne') ('Fiche : '+[string]$script:Ctrl['TxtCompPresence'].Text)
            # A state written again without its observation (result list, memory) shows no time.
            $script:Ctrl['TxtCompPresence'].Text='En ligne (cache)';Pump $main
            Expect ([string]$label.Text -eq 'Répond au ping (mémoire)') ('Etat repris : '+[string]$label.Text)
            $script:Ctrl['TxtCompPresence'].Text='Sans réponse au ping';Pump $main
            Expect ([string]$label.Text -eq 'Ne répond pas au ping') ('Etat sans observation : '+[string]$label.Text)
            $script:SelectedObject=$null
        }
    }finally{
        Stop-DomeniaReadOnlyReturnTimer
        if($null -ne $script:UxSuggestTimer){$script:UxSuggestTimer.Stop()}
        $main.Close();$script:Window=$null
    }
}catch{
    $script:Tests.Add([pscustomobject]@{Name='Initialisation ou suite interrompue';Status='Failed';Detail=$_.Exception.ToString()})
}

$expected=28
$passed=@($script:Tests|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Tests|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[ordered]@{
    Build='RC1.11.0-D120-interface-a'
    Suite='Raccordement D082/D085 (interface A)'
    Host=$PSVersionTable.PSVersion.ToString()
    NativeWindowsPowerShell=$script:WindowsExecuted
    Wpf=$true
    MockedNetwork=$true
    LiveAD=$false
    Expected=$expected
    Passed=$passed
    Failed=$failed
    Skipped=0
    Complete=($script:WindowsExecuted -and ($failed -eq 0) -and ($script:Tests.Count -eq $expected))
    Tests=$script:Tests.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-interface-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){
    Write-Host ("$passed passed, $failed failed. Rapport : "+$ReportPath)
    foreach($x in $script:Tests|Where-Object{$_.Status -eq 'Failed'}){Write-Host ($x.Name+': '+$x.Detail)}
}
if($failed -or -not $report.Complete){exit 1}
exit 0
