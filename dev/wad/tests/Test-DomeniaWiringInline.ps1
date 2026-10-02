#requires -Version 5.1
# D120 D083 (contract C4): integration proofs of the in-page confirmation. The real module Domenia-Inline.UI.ps1 and
# the real rules of Domenia-Shell.Model.ps1 run against a real WPF window that holds a UxContentGrid, as the main
# window does. No window may be created by a request, and an answer runs its continuation once at most.
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
# ---------------------------------------------------------------- inert doubles of the core
function Get-DomeniaControl {param([string]$Name);if($null -eq $script:Ctrl){return $null};return $script:Ctrl[$Name]}
function Set-DomeniaControlText {param([string]$Name,[string]$Text);$c=Get-DomeniaControl $Name;if($null -ne $c){$c.Text=$Text};return $true}
function Set-Status {param($Text,$Level);$script:Status=[string]$Text}
function Write-AppLog {param($Text,$Level);[void]$script:Log.Add([string]$Text)}
function Confirm-Action {param($Message,$Title);$script:DialogCount++;return [bool]$script:DialogAnswer}
function Pump {param($Window);$Window.UpdateLayout();$Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$Window.UpdateLayout()}
function Click {param($Button);$Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
function Reset-Fixture {
    $script:Status='';$script:Log=[Collections.ArrayList]::new();$script:DialogCount=0;$script:DialogAnswer=$false
    $script:Confirmed=0;$script:Cancelled=0;$script:SessionEpoch=7L
    if($null -ne $script:DomeniaInline -and $null -ne $script:DomeniaInline.Current){$script:DomeniaInline.Current=$null;$script:DomeniaInline.View.Visibility='Collapsed'}
}
try{
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    . (Join-Path $wad 'modules\Domenia-Common.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
    . (Join-Path $wad 'modules\Domenia-Inline.UI.ps1')
    $script:Ctrl=@{}
    Case 'Sans fenetre principale : la confirmation historique repond, la suite part une fois' {
        Reset-Fixture;$script:DialogAnswer=$true
        $r=Request-DomeniaInlineConfirmation -Title 'Supprimer' -Message 'Test' -Target 'relation:a' -ConfirmText 'Supprimer' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++}
        Expect ($r.Presentation -eq 'Dialog' -and $r.Answered -and $r.Confirmed) 'Repli absent'
        Expect ($script:DialogCount -eq 1 -and $script:Confirmed -eq 1 -and $script:Cancelled -eq 0) 'Suite du repli incorrecte'
    }
    $xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Width="900" Height="600" ShowActivated="False">
  <Window.Resources>
    <SolidColorBrush x:Key="InfoBg" Color="#EAF2FF"/><SolidColorBrush x:Key="InfoBorder" Color="#3B82F6"/><SolidColorBrush x:Key="InfoFg" Color="#1E3A8A"/>
    <Style x:Key="RunButton" TargetType="Button"><Setter Property="Tag" Value="Run"/></Style>
    <Style x:Key="DangerButton" TargetType="Button"><Setter Property="Tag" Value="Danger"/></Style>
    <Style x:Key="SecondaryButton" TargetType="Button"><Setter Property="Tag" Value="Secondary"/></Style>
  </Window.Resources>
  <Grid x:Name="UxContentGrid">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
    <Border x:Name="PageProbe" Grid.Column="0" Height="40" VerticalAlignment="Top" Background="White"/>
  </Grid>
</Window>
'@
    [xml]$doc=$xaml;$reader=New-Object Xml.XmlNodeReader $doc
    try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $script:Window=$w;$script:Ctrl['UxContentGrid']=$w.FindName('UxContentGrid')
    $w.Show();Pump $w
    try{
        Case 'Demande dans la page : aucune fenetre creee, rien ne part avant la reponse' {
            Reset-Fixture
            $before=[Windows.Application]::Current
            $r=Request-DomeniaInlineConfirmation -Title 'Supprimer l association' -Message 'Aucun objet AD modifie.' -Target 'relation:a' -ConfirmText 'Supprimer' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++} -Risk Danger
            Pump $w
            Expect ($r.Presentation -eq 'Inline' -and -not $r.Answered) 'Demande non presentee dans la page'
            Expect ($w.OwnedWindows.Count -eq 0 -and $script:DialogCount -eq 0) 'Une fenetre ou une boite a ete ouverte'
            $panel=Get-DomeniaControl 'InlineRequestPanel'
            Expect ([object]::ReferenceEquals($panel.Parent,$w.FindName('UxContentGrid')) -and $panel.IsVisible) 'Panneau absent de la grille de contenu'
            Expect ($script:Confirmed -eq 0 -and $script:Cancelled -eq 0) 'Suite executee avant la reponse'
            Expect ([string](Get-DomeniaControl 'BtnInlineRequestConfirm').Tag -eq 'Danger') 'Style de risque non applique'
        }
        Case 'Le choix sur a le focus : Entree sur une demande non lue ne confirme pas' {
            Expect ((Get-DomeniaControl 'BtnInlineRequestCancel').IsKeyboardFocused -or (Get-DomeniaControl 'BtnInlineRequestCancel').IsFocused) 'Focus hors du choix sur'
        }
        Case 'Confirmer execute la suite une seule fois' {
            Click (Get-DomeniaControl 'BtnInlineRequestConfirm');Click (Get-DomeniaControl 'BtnInlineRequestConfirm');Pump $w
            Expect ($script:Confirmed -eq 1 -and $script:Cancelled -eq 0) ('Confirmations : '+$script:Confirmed)
            Expect (-not (Get-DomeniaControl 'InlineRequestPanel').IsVisible) 'Panneau encore visible'
        }
        Case 'Annuler et Echap prennent la reponse sure' {
            Reset-Fixture
            [void](Request-DomeniaInlineConfirmation -Title 'A' -Target 'x' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++})
            Click (Get-DomeniaControl 'BtnInlineRequestCancel')
            Expect ($script:Cancelled -eq 1 -and $script:Confirmed -eq 0) 'Annuler'
            [void](Request-DomeniaInlineConfirmation -Title 'B' -Target 'x' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++});Pump $w
            $source=[Windows.PresentationSource]::FromVisual($w)
            $key=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,$source,0,[Windows.Input.Key]::Escape)
            $key.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent
            (Get-DomeniaControl 'BtnInlineRequestCancel').RaiseEvent($key)
            Expect ($script:Cancelled -eq 2 -and $script:Confirmed -eq 0) 'Echap'
        }
        Case 'Une nouvelle demande retire la precedente avec sa reponse sure' {
            Reset-Fixture
            [void](Request-DomeniaInlineConfirmation -Title 'Premiere' -Target 'a' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++})
            [void](Request-DomeniaInlineConfirmation -Title 'Seconde' -Target 'b' -OnConfirm {$script:Confirmed+=10} -OnCancel {$script:Cancelled+=10})
            Expect ($script:Cancelled -eq 1 -and $script:Confirmed -eq 0) 'Premiere demande non retiree'
            Click (Get-DomeniaControl 'BtnInlineRequestConfirm')
            Expect ($script:Confirmed -eq 10) 'Seconde demande'
        }
        Case 'Session changee avant la reponse : rien n est execute' {
            Reset-Fixture
            [void](Request-DomeniaInlineConfirmation -Title 'Ancienne session' -Target 'a' -OnConfirm {$script:Confirmed++} -OnCancel {$script:Cancelled++})
            $script:SessionEpoch=8L
            Click (Get-DomeniaControl 'BtnInlineRequestConfirm')
            Expect ($script:Confirmed -eq 0 -and $script:Cancelled -eq 0 -and $script:Status -match 'retiree') ('Statut : '+$script:Status)
        }
        Case 'Une demande en attente ne retient que les ecritures de sa cible' {
            Reset-Fixture
            [void](Request-DomeniaInlineConfirmation -Title 'Cible' -Target 'relation:a' -OnConfirm {} -OnCancel {})
            Expect (Test-DomeniaInlineBlocks -Action Write -Scope 'relation:a') 'Ecriture de la cible non retenue'
            Expect (-not (Test-DomeniaInlineBlocks -Action Write -Scope 'relation:b')) 'Autre cible retenue'
            Expect (-not (Test-DomeniaInlineBlocks -Action Read -Scope 'relation:a')) 'Lecture retenue'
            Complete-DomeniaInlineRequest -Dismiss
            Expect (-not (Test-DomeniaInlineBlocks -Action Write -Scope 'relation:a')) 'Demande repondue encore bloquante'
        }
        Case 'Afficher la demande ne deplace pas la page (D082)' {
            Reset-Fixture;Pump $w
            $probe=$w.FindName('PageProbe');$before=$probe.TranslatePoint([Windows.Point]::new(0,0),$w)
            [void](Request-DomeniaInlineConfirmation -Title 'Disposition' -Message ('Texte long ' * 40) -Target 'a' -OnConfirm {} -OnCancel {});Pump $w
            $after=$probe.TranslatePoint([Windows.Point]::new(0,0),$w)
            Expect ($before.X -eq $after.X -and $before.Y -eq $after.Y -and $probe.ActualHeight -eq 40) ('Deplacement : '+$before+' -> '+$after)
            Complete-DomeniaInlineRequest -Dismiss
        }
        Case 'Choix identiques refuses par la regle' {
            $failed=$false;try{[void](Request-DomeniaInlineConfirmation -Title 'X' -ConfirmText 'Oui' -CancelText 'Oui')}catch{$failed=$true}
            Expect $failed 'Choix ambigus acceptes'
        }
    }finally{$w.Close();$script:Window=$null}
}catch{$script:Tests.Add([pscustomobject]@{Name='Initialisation ou suite interrompue';Status='Failed';Detail=$_.Exception.ToString()})}
$expected=10
$passed=@($script:Tests|Where-Object{$_.Status -eq 'Passed'}).Count;$failed=@($script:Tests|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[ordered]@{Build='RC1.11.0-D120-interface-c4';Suite='Demande dans la page D083 (contrat C4)';Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell=$script:WindowsExecuted;Wpf=$true;MockedNetwork=$true;LiveAD=$false;Expected=$expected;Passed=$passed;Failed=$failed;Skipped=0;Complete=($script:WindowsExecuted -and $failed -eq 0 -and $script:Tests.Count -eq $expected);Tests=$script:Tests.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-inline-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed passed, $failed failed. Rapport : "+$ReportPath);foreach($x in $script:Tests|Where-Object{$_.Status -eq 'Failed'}){Write-Host ($x.Name+': '+$x.Detail)}}
if($failed -or -not $report.Complete){exit 1};exit 0
