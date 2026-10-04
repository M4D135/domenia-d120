#requires -Version 5.1
# D120 D082/D085: integration proofs for activity layout and stale selection views.
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
function Clear-DomeniaCurrentObjectRequest {param([string]$RequestId)}
function Clear-Secrets {}
function Clear-ObjectDetails {}
function Update-DomeniaLinkActionUi {param([int]$RowCount)}
function Reset-DomeniaDeferredViews {}
function Update-DomeniaSecretActionUi {}
function Apply-CurrentPermissionUi {}
function Request-DomeniaDashboardRefresh {}
function Get-DomeniaSecretIndexSummary {param([string]$Computer);return ''}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Update-DomeniaInventoryCategories {}
function Apply-DomeniaInventoryFilter { [void](Set-DomeniaItemsSource -Name 'DgInventory' -Rows $script:InventoryRows) }
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.ItemsSource=@($Rows)};return $true}
function Apply-DomeniaSoftwareFilter { [void](Set-DomeniaItemsSource -Name 'DgSoftware' -Rows $script:SoftwareRows) }
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
    $script:SelectedObject=$null;$script:SelectionLoad=$null;$script:SelectedObjectGeneration=0L
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:AccessState=[pscustomobject]@{Pending=@()}
    $script:ExperienceInitialized=$true;$script:ExperienceActivitySignature='';$script:WriteState='Unknown'
    $script:InventoryRows=@();$script:InventoryAccess=@();$script:SoftwareRows=@();$script:SoftwareAccess=@()
    $script:ComputerDiagRows=@();$script:PermissionRows=@()
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
$script:Spy=[pscustomobject]@{Counter=0;Preview=0;LastPreview=$null}
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
        'Reset-DomeniaSelectionBoundViews',
        'Enter-DomeniaSelectionContext',
        'Complete-DomeniaInventoryUi',
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
        <Button x:Name="BtnAccessRecovery" Width="108" Height="40">
          <Grid>
            <Border x:Name="BadgeAccessRecovery" Width="30" Height="22" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Red" Visibility="Hidden">
              <TextBlock x:Name="LblAccessRecoveryCount" Text=""/>
            </Border>
          </Grid>
        </Button>
        <Button x:Name="BtnSuiteActivity" Width="144" Height="40">
          <Grid>
            <Border x:Name="BadgeSuiteActivity" Width="30" Height="22" HorizontalAlignment="Right" VerticalAlignment="Top" Background="Blue" Visibility="Hidden">
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
            Expect ([string]$lbl.ToolTip -ceq [string]$expected.Detail) 'ToolTip non aligne'
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
}catch{
    $script:Tests.Add([pscustomobject]@{Name='Initialisation ou suite interrompue';Status='Failed';Detail=$_.Exception.ToString()})
}

$expected=10
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
