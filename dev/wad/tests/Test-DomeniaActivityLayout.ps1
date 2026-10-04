#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$Preview)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
# D082: the activity counters are formatted by the shell rule.
. (Join-Path $wad 'modules\Domenia-Shell.Model.ps1')
$script:Cases=[Collections.Generic.List[object]]::new()
$script:Ctrl=@{};$script:Window=$null
function Expect {param([bool]$Value,[string]$Message='Condition non verifiee');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Cases.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.ToString()})}
}
function Import-UiFunction {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    $code=$nodes[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name)
    . ([scriptblock]::Create($code))
}
function Parse-UiSource {param([string]$Path)
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+' : '+$e[0].Message)}
    return $ast
}
# Fixed doubles: no directory discovery, account validation, file cache or task submission.
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Request-DomeniaDashboardRefresh {}
function Write-AppLog {param($Text,$Level);throw ('Erreur de presentation : '+$Text)}
function Pump {param($Window)
    $Window.UpdateLayout()
    $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle)
    $Window.UpdateLayout()
}
function New-UiWindow {param([string]$Xaml,[string]$Theme='Dark',[double]$Width=1600,[double]$Height=900,[double]$Nav=204)
    $reader=[Xml.XmlNodeReader]::new([xml]$Xaml)
    try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $window.Width=$Width;$window.Height=$Height
    $window.Title='DOMENIA RC1.7 | APERCU LOCAL | activite fictive, sans AD'
    $window.FindName('UxNavColumn').Width=[Windows.GridLength]::new($Nav)
    $showHelp=$Width -ge 1360
    $window.FindName('UxHelpColumn').Width=[Windows.GridLength]::new($(if($showHelp){300}else{0}))
    $window.FindName('UxHelpPanel').Visibility=if($showHelp){'Visible'}else{'Collapsed'}
    $window.FindName('WorkspaceTabs').SelectedItem=$window.FindName('WsSearch')
    $window.FindName('LblUxPageTitle').Text='Rechercher (simulation locale)'
    $window.FindName('LblUxDomain').Text='APERÇU LOCAL · données fictives · aucun accès AD'
    $design=Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw | ConvertFrom-Json
    $palette=$design.Palettes.$Theme
    $converter=[Windows.Media.BrushConverter]::new()
    foreach($property in $palette.PSObject.Properties){$window.Resources[$property.Name]=$converter.ConvertFromInvariantString([string]$property.Value)}
    $script:Ctrl=@{}
    foreach($name in @(Get-DomeniaXamlControlNames -XamlText $Xaml)){
        $c=$window.FindName($name);if($null -ne $c){$script:Ctrl[$name]=$c}
    }
    # Exercise the real header counter; the operation-detail page is outside this isolated test.
    $script:Ctrl.Remove('TabExperience')
    $rows=[Collections.ArrayList]::new()
    for($i=1;$i -le 20;$i++){[void]$rows.Add([pscustomobject]@{Type='Machine';Name=('PC-DEMO-{0:d2}' -f $i);Login=('PC-DEMO-{0:d2}' -f $i);UPN='exemple.invalid';Presence='Non vérifié';DN=('CN=PC-DEMO-'+$i+',DC=example,DC=invalid')})}
    $window.FindName('DgObjects').ItemsSource=$rows
    $script:AsyncJobs=@{};$script:DetachedReadJobs=@();$script:LatestTaskId='';$script:LastTaskUiCount=-1
    $script:LastTaskUiRefresh=[datetime]::MinValue;$script:ExperienceInitialized=$true
    $script:ReadOnlyMode=$true;$script:BaseWindowTitle=$window.Title;$script:Window=$window
    return $window
}
function Set-FakeActivity {param([int]$Count,[string]$Name='Lecture fictive',[int]$Seconds=1)
    $script:AsyncJobs=@{}
    for($i=0;$i -lt $Count;$i++){$script:AsyncJobs['demo'+$i]=[pscustomobject]@{Id='demo'+$i;Name=$Name;Started=(Get-Date).AddSeconds(-$Seconds);IsWrite=$false}}
    $script:LatestTaskId=if($Count){'demo0'}else{''}
    Update-TaskUi -Force
}
function Geometry {param($Window,[string[]]$Names)
    $values=[Collections.Generic.List[double]]::new()
    foreach($name in $Names){
        $c=$Window.FindName($name);if($null -eq $c){throw ('Controle absent : '+$name)}
        $pos=$c.TranslatePoint([Windows.Point]::new(0,0),$Window)
        foreach($v in @($pos.X,$pos.Y,$c.ActualWidth,$c.ActualHeight)){$values.Add([double]$v)}
    }
    return ,$values.ToArray()
}
function Same-Geometry {param($Before,$After)
    Expect ($Before.Count -eq $After.Count)
    for($i=0;$i -lt $Before.Count;$i++){Expect ([Math]::Abs($Before[$i]-$After[$i]) -le 0.5) ('Disposition modifiee a l indice '+$i+': '+$Before[$i]+' -> '+$After[$i])}
}
function Install-PreviewMode {param($Window)
    foreach($c in $script:Ctrl.Values){
        if($c -is [Windows.Controls.Button] -and $c.Name -ne 'BtnCancelTask'){$c.IsEnabled=$false}
    }
    $script:PreviewTimer=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background)
    $script:PreviewTimer.Interval=[TimeSpan]::FromSeconds(2)
    $script:PreviewPhase=0
    $script:PreviewTick=[EventHandler]{
        $counts=@(0,1,9,10,100,0);$n=$counts[$script:PreviewPhase % $counts.Count]
        $script:PreviewPhase++
        $name=if($n -ge 10){'Lecture fictive avec un intitulé volontairement long pour examiner le maintien des axes et du tableau'}else{'Lecture fictive'}
        Set-FakeActivity $n $name ($n*99)
    }
    $script:PreviewTimer.Add_Tick($script:PreviewTick)
    $Window.FindName('BtnCancelTask').Add_Click({$script:PreviewTimer.Stop();Set-FakeActivity 0})
    $Window.FindName('TxtUiLog').Text='APERÇU : les compteurs varient toutes les deux secondes. Annuler arrête uniquement cette simulation. Aucun compte, cache ni poste distant utilisé.'
    Set-FakeActivity 0
    $script:PreviewTimer.Start()
    try{[void]$Window.ShowDialog()}
    finally{$script:PreviewTimer.Stop();$script:PreviewTimer.Remove_Tick($script:PreviewTick);$Window.Close()}
}
$neighbors=@('TxtGlobalSearch','BtnGlobalSearch','BtnAccessRecovery','BtnSuiteActivity','BtnCommandPalette','BtnThemeToggle','BtnUxHelpToggle','UxPageHeader','UxContentGrid','WorkspaceTabs','SearchOuPanel','DgObjects','LogPanel')
try {
    Case 'Windows PowerShell 5.1 x64 STA requis' {
        Expect ($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA')
    }
    if(-not $script:Cases[0].Passed){throw 'Test WPF uniquement sous Windows PowerShell 5.1 x64 STA.'}
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Case 'Extraire les vrais helpers de presentation sans executer le bootstrap' {
        $ast=Parse-UiSource (Join-Path $wad 'Domenia-Core.ps1')
        foreach($n in @('Get-MainXaml','Get-DomeniaXamlControlNames','Get-DomeniaControl','Update-TaskUi','Update-DomeniaWriteModeVisual')){Import-UiFunction $ast $n}
        Import-UiFunction (Parse-UiSource (Join-Path $wad 'modules\Domenia-Experience.UI.ps1')) 'Update-DomeniaExperienceActivity'
        Expect ((Get-MainXaml).Contains('UxActivityStrip'))
    }
    if(-not $script:Cases[1].Passed){throw 'Extraction des fonctions impossible.'}
    $xaml=Get-MainXaml
    if($Preview){$w=New-UiWindow $xaml;Install-PreviewMode $w;return}
    foreach($theme in @('Light','Dark')) {
        Case ($theme+' : reproduire le decalage de la ligne Auto RC1.6') {
            $a=$xaml.IndexOf('          <Grid x:Name="UxPageHeader"');$b=$xaml.IndexOf('          <Grid x:Name="UxContentGrid"',$a)
            Expect ($a -ge 0 -and $b -gt $a)
            $oldHeader=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\RC1.6-PageHeader.xaml.txt'))
            $legacy=$xaml.Substring(0,$a)+$oldHeader+$xaml.Substring($b)
            $w=New-UiWindow $legacy $theme
            try {
                $w.Show();Pump $w
                $before=$w.FindName('UxContentGrid').TranslatePoint([Windows.Point]::new(0,0),$w).Y
                # Reproduce old conditions directly. Do not replace the original legacy XAML triggers.
                $w.FindName('LblTaskElapsed').Text='Une lecture fictive en cours'
                $w.FindName('PbTop').Visibility='Visible';$w.FindName('BtnCancelTask').Visibility='Visible';Pump $w
                $after=$w.FindName('UxContentGrid').TranslatePoint([Windows.Point]::new(0,0),$w).Y
                Expect ($after-$before -gt 10) 'La fixture ne reproduit pas le saut initial ; verifier le test.'
            } finally {$w.Close();$script:Window=$null}
        }
        foreach($dimensions in @(@(1600,960,204),@(1280,800,204),@(960,640,68))) {
            $prefix=$theme+' '+$dimensions[0]+'x'+$dimensions[1]
            $w=New-UiWindow $xaml $theme $dimensions[0] $dimensions[1] $dimensions[2]
            try {
                $w.Show();Set-FakeActivity 0;Pump $w
                $stable=Geometry $w $neighbors
                Case ($prefix+' : emplacement reserve au repos') {
                    Expect ($w.FindName('UxActivityStrip').ActualHeight -eq 44)
                    Expect ($w.FindName('PbTop').Visibility -eq 'Hidden' -and $w.FindName('BtnCancelTask').Visibility -eq 'Hidden')
                    Expect (-not $w.FindName('PbTop').IsIndeterminate)
                }
                Case ($prefix+' : cycles 0 1 9 10 100 0 sans aucun deplacement des voisins') {
                    foreach($n in @(0,1,9,10,100,0)){
                        Set-FakeActivity $n;Pump $w;Same-Geometry $stable (Geometry $w $neighbors)
                        Expect ($w.FindName('PbTop').IsVisible -eq ($n -gt 0))
                        Expect ($w.FindName('PbTop').IsIndeterminate -eq ($n -gt 0))
                        Expect ($w.FindName('BtnCancelTask').IsVisible -eq ($n -gt 0))
                        $badge=if($n -gt 99){'99+'}else{[string]$n}
                        Expect ($w.FindName('LblSuiteActivityCount').Text -ceq $badge)
                    }
                }
                Case ($prefix+' : texte long et temps ecoule sans agrandissement') {
                    Set-FakeActivity 1;Pump $w
                    $slots=Geometry $w @('PbTop','BtnCancelTask','LblTaskElapsed')
                    Set-FakeActivity 100 ('OU et nom fictifs '+('texte très long '*80)) 999999;Pump $w
                    Same-Geometry $stable (Geometry $w $neighbors)
                    Same-Geometry $slots (Geometry $w @('PbTop','BtnCancelTask','LblTaskElapsed'))
                    Expect ($w.FindName('LblTaskElapsed').Text.Length -gt 400 -and $w.FindName('LblTaskElapsed').TextTrimming -eq 'CharacterEllipsis')
                }
                Case ($prefix+' : animation et valeurs 0 50 100 gardent le meme emplacement') {
                    Set-FakeActivity 1;Pump $w;$slots=Geometry $w @('PbTop','BtnCancelTask')
                    foreach($value in @(0,50,100)){$w.FindName('PbTop').IsIndeterminate=$false;$w.FindName('PbTop').Value=$value;Pump $w;Same-Geometry $slots (Geometry $w @('PbTop','BtnCancelTask'));Same-Geometry $stable (Geometry $w $neighbors)}
                    Update-TaskUi -Force;Pump $w;Expect ([bool]$w.FindName('PbTop').IsIndeterminate)
                }
                Case ($prefix+' : masquer meme Collapsed un indicateur ne retire pas la ligne') {
                    foreach($n in @('PbTop','BtnCancelTask','LblTaskElapsed')){$w.FindName($n).Visibility='Collapsed'}
                    Pump $w;Same-Geometry $stable (Geometry $w $neighbors);Expect ($w.FindName('UxActivityStrip').ActualHeight -eq 44)
                    Set-FakeActivity 1;Pump $w
                }
                Case ($prefix+' : avertissement ecriture conserve sans faire sauter le contenu') {
                    foreach($readOnly in @($false,$true)){$script:ReadOnlyMode=$readOnly;Update-DomeniaWriteModeVisual;Pump $w;Same-Geometry $stable (Geometry $w $neighbors);Expect ($w.FindName('WriteModeBanner').IsVisible -eq (-not $readOnly))}
                }
                Case ($prefix+' : arrivee de statut ne recree ni grille ni selection') {
                    $g=$w.FindName('DgObjects');$g.SelectedIndex=4;$source=$g.ItemsSource;$selected=$g.SelectedItem
                    Set-FakeActivity 1;Set-FakeActivity 0;Pump $w
                    Expect ([object]::ReferenceEquals($source,$g.ItemsSource) -and [object]::ReferenceEquals($selected,$g.SelectedItem))
                    Same-Geometry $stable (Geometry $w $neighbors)
                }
                Case ($prefix+' : bouton dans ses limites et inaccessible au repos') {
                    Set-FakeActivity 1;Pump $w
                    $button=$w.FindName('BtnCancelTask');$point=$button.TranslatePoint([Windows.Point]::new(0,0),$w.FindName('UxActivityStrip'))
                    Expect ($button.ActualWidth -eq 96 -and $button.ActualHeight -eq 32 -and $point.Y -ge 0 -and $point.Y+$button.ActualHeight -le 44)
                    Expect ($point.X+$button.ActualWidth -le $w.FindName('UxActivityStrip').ActualWidth+0.5)
                    Set-FakeActivity 0;Pump $w;Expect (-not $button.IsVisible -and -not $w.FindName('PbTop').IsVisible)
                }
            } finally {$w.Close();$script:Window=$null;$script:Ctrl=@{}}
        }
    }
} catch {$script:Cases.Add([pscustomobject]@{Name='Infrastructure WPF';Passed=$false;Detail=$_.Exception.ToString()})}
$failures=@($script:Cases|Where-Object{-not $_.Passed});$expected=52
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.7-FIXEDACTIVITY';Environment='Windows PowerShell 5.1 x64 STA / real WPF layout';Passed=$script:Cases.Count-$failures.Count;Failed=$failures.Count;Expected=$expected;Skipped=0;Complete=($script:Cases.Count -eq $expected -and $failures.Count -eq 0);NoADAccess=$true;NoProductionData=$true;Tests=$script:Cases.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-ActivityLayout-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Cases|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if(-not $report.Complete){throw ('Validation WPF incomplete ou en echec : '+$ReportPath)}
