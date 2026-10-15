#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet, [switch]$Preview)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Results=[Collections.Generic.List[object]]::new()
$script:Finished=$false;$script:Window=$null;$script:TestPhase='Setup'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-Embedded-'+[guid]::NewGuid().ToString('N'))
function Expect {param([bool]$Value,[string]$Why='Assertion non verifiee');if(-not $Value){throw $Why}}
function Case {param([string]$Name,[scriptblock]$Body)
    try {& $Body|Out-Null;$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$true;Error=''})}
    catch {$script:Results.Add([pscustomobject]@{Name=$Name;Passed=$false;Error=$_.Exception.ToString()})}
}
function Parse-Text {param([string]$Text)
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    Expect (@($errors).Count -eq 0) ($errors|Out-String);return $ast
}
function Import-Function {param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n)(($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name))},$true))
    Expect ($found.Count -eq 1) ('Fonction absente/ambigue : '+$Name)
    . ([scriptblock]::Create(($found[0].Extent.Text -replace ('^function\s+'+[regex]::Escape($Name)+'\b'),('function script:'+$Name))))
}
function Must-Fail {param([scriptblock]$Body)
    $failure=$null;try{& $Body|Out-Null}catch{$failure=$_};Expect ($null -ne $failure) 'Un refus explicite etait attendu.'
}
function Get-DomeniaControl {param($Name);if($null -ne $script:Window){return $script:Window.FindName($Name)}}
function Get-DomeniaStoredTheme {return $script:Theme}
function Get-CfgValue {param($Section,$Key,$Default);return $Default}
function Write-AppLog {param($Text,$Level);$script:Trace.Add([string]$Text)}
function Set-Status {param($Text,$Level);$script:Trace.Add([string]$Text)}
function Set-AppWindowIcon {param($Window)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$TimeoutSeconds,$SuccessHandler,$ErrorHandler)
    $id='fixture-'+[guid]::NewGuid().ToString('N')
    $script:Submissions.Add([pscustomobject]@{Id=$id;Name=$Name;OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;Success=$SuccessHandler;Failure=$ErrorHandler})
    return $id
}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason);$script:Stops.Add([string]$Id)}
function Set-DomeniaRelationsSelection {param($Row);$script:PickedSubject=$Row}
function Refresh-DomeniaRelationViews {}
function New-CimSession {throw 'CIM interdit dans la recette integree.'}
function Test-Connection {throw 'Ping interdit dans la recette integree.'}
function Get-WMachineCredential {param($Context);return $null}
function Get-WAdCredential {param($Context);return $null}
function New-WSearcher {param($Context,$Root,$Filter,$Properties,$SearchScope,$Limit)
    $script:SearchTrace.Add([pscustomobject]@{Root=$Root;Filter=$Filter;Scope=$SearchScope;Limit=$Limit})
    if($script:DirectoryDenied){throw [UnauthorizedAccessException]::new('Refus de lecture fictif')}
    $s=[Domenia.EmbeddedTests.Searcher]::new([object[]]$script:MockRows);$script:Searchers.Add($s);return $s
}
function Reset-FakeDirectory {
    $script:DirectoryDenied=$false;$script:SearchTrace=[Collections.Generic.List[object]]::new();$script:Searchers=[Collections.Generic.List[object]]::new()
    $script:MockRows=@([pscustomobject]@{Properties=@{
        name=@('PC-A');samaccountname=@('PC-A$');dnshostname=@('pc-a.example.invalid');distinguishedname=@('CN=PC-A,DC=example,DC=invalid');
        objectguid=@(,([guid]'11223344-5566-7788-99aa-bbccddeeff00').ToByteArray());description=@('Poste fictif')
    }})
}
function Run-Lookup {param([string]$Term='pc',[bool]$Verify=$false,[string]$Guid='11223344-5566-7788-99aa-bbccddeeff00',[string]$DN='CN=PC-A,DC=example,DC=invalid',[string]$Kind='Machine')
    $Context=$script:Conn;$Payload=[pscustomobject]@{Kind=$Kind;Term=$Term;Verify=$Verify;Guid=$Guid;DN=$DN;RequestId='test'}
    return (& ([scriptblock]::Create((Get-DomeniaEmbeddedLookupCode))))
}
function Run-Path {param([string]$Path,[string]$Action='Browse',[string]$Mode='Open')
    $Payload=[pscustomobject]@{Action=$Action;Path=$Path;Mode=$Mode;RequestId='files'}
    return (& ([scriptblock]::Create((Get-DomeniaEmbeddedPathCode))))
}
function Load-Host {param([string]$Theme)
    $script:Theme=$Theme;$reader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml))
    try{$w=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $w.Title='DOMENIA RC1.9 | TEST LOCAL SANS RESEAU';$w.Width=1350;$w.Height=850;$w.ShowInTaskbar=$false
    $palette=(Get-Content -LiteralPath (Join-Path $wad 'modules\SupportSuite.UI.json') -Raw|ConvertFrom-Json).Palettes.$Theme
    $convert=[Windows.Media.BrushConverter]::new();foreach($p in $palette.PSObject.Properties){$w.Resources[$p.Name]=$convert.ConvertFromInvariantString([string]$p.Value)}
    $script:Window=$w;$w.FindName('WorkspaceTabs').SelectedItem=$w.FindName('TabRelations');$w.Show();$w.UpdateLayout();return $w
}
function Geometry {param($Window)
    $values=[Collections.Generic.List[double]]::new()
    foreach($n in @('TxtGlobalSearch','BtnGlobalSearch','UxPageHeader','WorkspaceTabs','LogPanel')){
        $c=$Window.FindName($n);$p=$c.TranslatePoint([Windows.Point]::new(0,0),$Window)
        $values.Add($p.X);$values.Add($p.Y);$values.Add($c.ActualWidth);$values.Add($c.ActualHeight)
    };return ,$values.ToArray()
}
function Exercise-Sheet {param([bool]$Accept=$false,[bool]$ChangeEpoch=$false)
    $w=[Windows.Window]::new();$w.Title='Choix de recette';$w.Width=640;$w.Height=480
    $root=[Windows.Controls.Grid]::new();$input=[Windows.Controls.TextBox]::new();$input.Name='TestSecretLikeText';$input.Text='MARQUEUR-NE-PAS-REFLETER';$input.VerticalAlignment='Top';$input.Height=40;$root.Children.Add($input)|Out-Null
    $w.Content=$root
    $t=[pscustomobject]@{Window=$w;Main=$script:Window;Input=$input;Layer=$script:Window.FindName('DomeniaDialogLayer');Ticks=0;Error='';Visible=$false;Hwnd=[intptr]::Zero;Disabled=$false;Help='';Brush='';OldEpoch=$script:SessionEpoch;Measured=$null}
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[timespan]::FromMilliseconds(100)
    $handler={
        try{
            $t.Ticks++;$t.Main.UpdateLayout();$t.Visible=$t.Layer.IsVisible
            $t.Hwnd=([Windows.Interop.WindowInteropHelper]::new($t.Window)).Handle
            $t.Disabled=-not $t.Main.FindName('TxtGlobalSearch').IsEnabled
            $t.Help=[string]$t.Input.ToolTip;$t.Brush=[string]$t.Input.Foreground;$t.Measured=Geometry $t.Main
            if($t.Ticks -ge 2){$timer.Stop();if($ChangeEpoch){Set-TestEpoch ($t.OldEpoch+1)}else{Set-DomeniaSurfaceResult $t.Window $Accept}}
        }catch{$t.Error=$_.Exception.ToString();$timer.Stop();$t.Window.Close()}
    }.GetNewClosure()
    $timer.Add_Tick($handler)
    Register-DomeniaSurfaceReady $w ({$timer.Start()}.GetNewClosure())
    try{$accepted=Show-DomeniaEmbeddedWindow $w}finally{$timer.Stop();$timer.Remove_Tick($handler);$w.Close()}
    Expect (-not $t.Error) $t.Error
    return [pscustomobject]@{Data=$t;Accepted=$accepted}
}
function Set-TestEpoch {param([long]$Value);$script:SessionEpoch=$Value}
# L02 (UX-06): the real Show-InfoBox/Show-ErrorBox of the core; a modal box would be counted here.
function Show-DomeniaDialog {param($Message,$Title,$Kind,$Buttons,$Details);$script:DialogCalls++;return 'OK'}
# UX-19 (X04): the route of a banner button is recorded; the navigation itself is proved in Test-DomeniaWiringInterface.
$script:RouteCalls=[Collections.Generic.List[string]]::new();$script:RouteAnswer=$true
function Invoke-DomeniaCapabilityRoute {param([string]$Route);$script:RouteCalls.Add([string]$Route);return [bool]$script:RouteAnswer}
function Exercise-BannerSheet {
    # An error raised while a sheet is open: its banner is shown above the sheet and stays usable.
    $w=[Windows.Window]::new();$w.Title='Panneau de recette';$w.Width=520;$w.Height=300;$w.Content=[Windows.Controls.Grid]::new()
    $script:BannerTrial=[pscustomobject]@{Window=$w;HostEnabled=$false;Shown=$false;SearchEnabled=$true;Error=''}
    Register-DomeniaSurfaceReady $w {
        $t=$script:BannerTrial
        try{
            Show-ErrorBox ("Erreur pendant le panneau.`r`n`r`nCode incident : INC-5E6F.")
            $t.Shown=(@($script:DomeniaBanners|Where-Object{$_.Code -eq 'INC-5E6F'}).Count -eq 1)
            $t.HostEnabled=$script:Window.FindName('DomeniaBannerHost').IsEnabled
            $t.SearchEnabled=$script:Window.FindName('TxtGlobalSearch').IsEnabled
        }catch{$t.Error=$_.Exception.ToString()}
        finally{$t.Window.Close()}
    }
    try{[void](Show-DomeniaEmbeddedWindow $w)}finally{$w.Close()}
    Expect (-not $script:BannerTrial.Error) $script:BannerTrial.Error
    return $script:BannerTrial
}
function Tick-Picker {param($Trial)
    $Trial.Ticks++
    if($Trial.Ticks -gt 25){$Trial.Error='Panneau de recette non termine.';$Trial.Timer.Stop();if($script:DomeniaSurfaceState){$script:DomeniaSurfaceState.Window.Close()};return}
    try{
        $active=$script:DomeniaSurfaceState;if($null -eq $active){return}
        $controls=@(Get-DomeniaLogicalControls $script:Window.FindName('DomeniaDialogLayer'))
        $box=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectTerm'})[0]
        $go=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectSearch'})[0]
        $grid=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectResults'})[0]
        $accept=@($controls|Where-Object{$_.Name -eq 'EmbeddedObjectAccept'})[0]
        if($Trial.Step -eq 0){
            $Trial.InitialJobs=$script:Submissions.Count
            if($Trial.Mode -eq 'Cancel'){$active.Window.Close();$Trial.Timer.Stop();return}
            $box.Text='PC-A';$go.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$Trial.Step=1;return
        }
        $job=$script:Submissions[$script:Submissions.Count-1];$Trial.LastJob=$job
        if($Trial.Step -eq 1){
            Expect ($job.OperationId -eq 'EmbeddedDirectoryLookup' -and -not $job.Payload.Verify)
            if($Trial.Mode -eq 'ClosePending'){$active.Window.Close();$Trial.Timer.Stop();return}
            $row=[pscustomobject]@{Name='PC-A';Type='Machine';DN='CN=PC-A,DC=example,DC=invalid';Guid='11223344-5566-7788-99aa-bbccddeeff00';Second='pc-a.example.invalid';Login='PC-A$';Description='Fixture'}
            & $job.Success ([pscustomobject]@{Rows=@($row);RequestId=$job.State.RequestId;Verified=$false;Capped=$false}) $job.State
            $Trial.NoAutoSelection=($null -eq $grid.SelectedItem -and -not $accept.IsEnabled)
            $grid.SelectedItem=$row;$Trial.Row=$row;$accept.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$Trial.Step=2;return
        }
        if($Trial.Step -eq 2){
            Expect ($job.Payload.Verify -and $job.Payload.Guid -eq $Trial.Row.Guid)
            if($Trial.Mode -eq 'Reject'){
                & $job.Failure 'Refus de recette' $job.State
                $Trial.ErrorShown=([string]$job.State.Owner.Status.Text).Contains('Refus de recette')
                $active.Window.Close()
            }else{& $job.Success ([pscustomobject]@{Rows=@($Trial.Row);RequestId=$job.State.RequestId;Verified=$true;Capped=$false}) $job.State}
            $Trial.Timer.Stop()
        }
    }catch{$Trial.Error=$_.Exception.ToString();$Trial.Timer.Stop();if($script:DomeniaSurfaceState){$script:DomeniaSurfaceState.Window.Close()}}
}
function Exercise-Picker {param([string]$Mode='Choose')
    $trial=[pscustomobject]@{Mode=$Mode;Step=0;Ticks=0;Timer=[Windows.Threading.DispatcherTimer]::new();Error='';ErrorShown=$false;InitialJobs=-1;NoAutoSelection=$false;Row=$null;LastJob=$null;Selected=$null}
    $script:Submissions.Clear();$script:Stops.Clear();$trial.Timer.Interval=[timespan]::FromMilliseconds(100)
    $tick={Tick-Picker $trial}.GetNewClosure();$trial.Timer.Add_Tick($tick);$trial.Timer.Start()
    try{$trial.Selected=Show-DomeniaInlinePicker -Kind Machine -Title 'Associer un poste (recette)' -Prompt 'Données fictives. Aucune lecture AD.'}
    finally{$trial.Timer.Stop();$trial.Timer.Remove_Tick($tick)}
    Expect (-not $trial.Error) $trial.Error;return $trial
}
try {
    Expect ($env:OS -eq 'Windows_NT' -and $PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and [Environment]::Is64BitProcess -and [Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') 'Windows PowerShell 5.1 x64 STA requis.'
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    Add-Type -TypeDefinition @'
using System; using System.Collections;
namespace Domenia.EmbeddedTests {
 public sealed class Rows : IEnumerable, IDisposable { public object[] Items; public bool Disposed; public Rows(object[] a){Items=a;} public IEnumerator GetEnumerator(){return Items.GetEnumerator();} public void Dispose(){Disposed=true;} }
 public sealed class Root : IDisposable {public bool Disposed;public void Dispose(){Disposed=true;}}
 public sealed class Searcher : IDisposable {public Rows Results;public Root SearchRoot=new Root();public bool Disposed;public int PageSize;public bool CacheResults;public TimeSpan ServerTimeLimit;public TimeSpan ClientTimeout;public Searcher(object[] r){Results=new Rows(r);}public Rows FindAll(){return Results;}public void Dispose(){Disposed=true;}}
}
'@
    [void][IO.Directory]::CreateDirectory($temp)
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc.example.invalid';Domain='example.invalid';Netbios='EXAMPLE'}
    $script:SessionEpoch=4L;$script:AsyncEngineClosing=$false;$script:ModalBlockedMs=0L
    $script:Trace=[Collections.Generic.List[string]]::new();$script:Submissions=[Collections.Generic.List[object]]::new();$script:Stops=[Collections.Generic.List[string]]::new()
    $coreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'));$ast=Parse-Text $coreText
    . (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    # FI-05 / PF-06: every Dispatcher timer comes from the protected factory of the engine (Domenia-Engine.UI.ps1).
    foreach($engineModule in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Engine.UI.ps1')){. (Join-Path $wad ('modules\'+$engineModule))}
    foreach($n in @('Get-MainXaml','Get-DomeniaEffectiveWorkerResult','Show-InfoBox','Show-ErrorBox','Show-WarningBox','Show-DomeniaPageBanner','Test-DomeniaMainHostAvailable',
        'Add-DomeniaErrorIncidentCode','Register-DomeniaErrorOccurrence','New-DomeniaIncidentCode')){Import-Function $ast $n}
    $m=[regex]::Match($coreText,'(?ms)^\$script:WorkerCommon\s*=\s*@''\r?\n(.*?)\r?\n''@')
    Expect $m.Success 'WorkerCommon introuvable.';$commonAst=Parse-Text $m.Groups[1].Value
    foreach($n in @('Get-WPropFirst','Convert-WGuid','Escape-WLdap')){Import-Function $commonAst $n}
    Case 'Parseur natif de tous les scripts runtime' {foreach($f in Get-ChildItem -LiteralPath $wad -Filter '*.ps1' -File -Recurse|Where-Object{$_.FullName -notlike '*\tests\*' -and $_.FullName -notlike '*\docs\*'}){Parse-Text ([IO.File]::ReadAllText($f.FullName))|Out-Null}}
    Case 'UI-26 (X04) : Executer un programme dans la page, aux couleurs du theme, sans fenetre ni nom Rimotte affiche' {
        Expect (@($ast.FindAll({param($n)(($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Show-DomeniaRimotteDialog'))},$true)).Count -eq 0) 'La fenetre Rimotte existe encore.'
        Expect ($coreText.Contains('$script:Ctrl["BtnCompRimotte"].Add_Click({ Show-DomeniaRunProgramPanel })')) 'Le bouton n ouvre pas le panneau dans la page.'
        $assistAst=Parse-Text ([IO.File]::ReadAllText((Join-Path $wad 'modules\Domenia-Assist.UI.ps1')))
        foreach($fn in @('Show-DomeniaRunProgramPanel','Submit-DomeniaRunProgram','Confirm-DomeniaRunProgram','Close-DomeniaRunProgramPanel','Request-DomeniaComputerRestart','Submit-DomeniaComputerRestart','Request-DomeniaComputerToolConfirmation','Request-DomeniaComputerServiceControl')){
            $found=@($assistAst.FindAll({param($n)(($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $fn))},$true))
            Expect ($found.Count -eq 1) ('Fonction absente : '+$fn)
            Expect (-not ($found[0].Extent.Text -match 'Windows\.Window|<Window|ShowDialog|Invoke-DomeniaHostWindow|ConvertFrom-DomeniaXaml|Confirm-Action|Show-InfoBox')) ($fn+' ouvre une fenetre.')
        }
        foreach($fn in @('Start-DomeniaRimotteRun','Complete-DomeniaRimotteUi','Fail-DomeniaRimotteUi','Get-DomeniaRimotteWorkerCode')){
            $found=@($ast.FindAll({param($n)(($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $fn))},$true))
            Expect ($found.Count -eq 1) ('Fonction absente : '+$fn)
            $shown=(($found[0].Extent.Text -replace 'RimotteRun','') -replace 'DomeniaRimotte','')
            Expect (-not $shown.Contains('Rimotte')) ($fn+' affiche encore le nom Rimotte.')
        }
        Expect (([regex]::Matches((@($ast.FindAll({param($n)(($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Start-DomeniaRimotteRun'))},$true))[0].Extent.Text),'-OperationId "RimotteRun"')).Count -eq 1) 'L operation epinglee RimotteRun a change de nom.'
        [xml]$main=Get-MainXaml
        $x='http://schemas.microsoft.com/winfx/2006/xaml'
        $panel=@($main.SelectNodes('//*') | Where-Object { $_.GetAttribute('Name',$x) -eq 'UxCompRunPanel' })
        Expect ($panel.Count -eq 1) 'Panneau d execution absent du XAML principal.'
        Expect (($panel[0].GetAttribute('Background') -like '{DynamicResource *}') -and ($panel[0].GetAttribute('BorderBrush') -like '{DynamicResource *}')) 'Couleurs du panneau ecrites en dur.'
        Expect (@($panel[0].SelectNodes('.//*[local-name()="ComboBox"]')).Count -eq 0) 'Le choix abandonne du compte avec mot de passe reste propose.'
        $modes=@($panel[0].SelectNodes('.//*[local-name()="RadioButton"]') | ForEach-Object { $_.GetAttribute('Content') })
        Expect (($modes -join '|') -ceq 'En arrière-plan (compte système)|Dans la session de lʼutilisateur') ('Modes : '+($modes -join '|'))
        $owner=$panel[0].ParentNode
        while(($null -ne $owner) -and ($owner.GetAttribute('Name',$x) -ne 'TabComputerAdmin')){$owner=$owner.ParentNode;if($owner -is [Xml.XmlDocument]){$owner=$null}}
        Expect ($null -ne $owner) 'Le panneau n est pas dans la vue Intervenir.'
    }
    Case 'UX-19 (X04) : sans fenetre principale, le message de route reste sur la ligne d etat avec le nom de l action' {
        $script:Trace.Clear();$script:RouteCalls.Clear()
        $shown=Show-DomeniaRouteNotice -Kind Warning -Text 'Stockage suspendu : les lots restent en mémoire.' -RouteText 'Reprendre les sauvegardes' -Route 'StorageResume' -Key 'x04-route-fallback'
        Expect (-not $shown) 'Bandeau annonce sans fenetre principale.'
        Expect (@($script:Trace|Where-Object{$_ -ceq 'Stockage suspendu : les lots restent en mémoire. Action : « Reprendre les sauvegardes ».'}).Count -eq 1) ('Ligne d etat : '+($script:Trace -join ' | '))
        Expect ($script:RouteCalls.Count -eq 0) 'Une navigation est partie sans clic.'
        Expect (-not (($script:Trace -join ' ') -match 'Fiabilit')) 'Chemin ecrit vers Fiabilite.'
    }
    $g=[guid]'11223344-5566-7788-99aa-bbccddeeff00';$bytes=$g.ToByteArray()
    Case 'GUID binaire retourne comme byte array unique' {$p=@{objectguid=@(,$bytes)};$value=Get-WPropFirst $p 'objectguid' $null;Expect ($value -is [byte[]] -and $value.Length -eq 16)}
    Case 'GUID binaire converti au format D' {Expect ((Convert-WGuid $bytes) -ceq $g.ToString('D'))}
    Case 'Ancien tableau de bytes deroule encore convertible' {Expect ((Convert-WGuid ([object[]]$bytes)) -ceq $g.ToString('D'))}
    Case 'GUID deja type conserve' {Expect ((Convert-WGuid $g) -ceq $g.ToString('D'))}
    Case 'GUID texte normalise' {Expect ((Convert-WGuid $g.ToString('B').ToUpperInvariant()) -ceq $g.ToString('D'))}
    Case 'GUID court non invente' {Expect (-not (Convert-WGuid ([byte[]](1,2))))}
    Case 'GUID hors bornes refuse' {Expect (-not (Convert-WGuid ([int[]](0..14 + 999))))}
    Case 'GUID texte invalide refuse' {Expect (-not (Convert-WGuid 'pas-un-guid'))}
    Case 'Attribut absent retourne le defaut' {Expect ((Get-WPropFirst @{} 'objectguid' 'absent') -ceq 'absent')}
    Case 'Valeur string AD conservee' {Expect ((Get-WPropFirst @{name=@('Alice')} 'name' '') -ceq 'Alice')}
    Case 'Regression avant correction : GUID deroule ne correspond pas' {function Legacy-Get {param($v);return $v};$old=Legacy-Get $bytes;Expect ($old -is [object[]] -and [string]$old -cne $g.ToString('D'))}
    Reset-FakeDirectory
    Case 'Recherche AD reelle en code, transport double uniquement' {$script:Lookup=Run-Lookup;Expect ($script:Lookup.Rows.Count -eq 1 -and $script:Lookup.Rows[0].Guid -ceq $g.ToString('D'))}
    Case 'Selecteur recherche sur le domaine et pas une OU' {Expect ($script:SearchTrace[0].Root -ceq $script:Conn.BaseDn -and $script:SearchTrace[0].Scope -ceq 'Subtree')}
    Case 'Ressources de recherche liberees' {foreach($s in $script:Searchers){Expect ($s.Disposed -and $s.Results.Disposed -and $s.SearchRoot.Disposed)}}
    Case 'Deuxieme lecture exacte avant choix' {$r=Run-Lookup -Verify $true;Expect ($r.Verified -and $script:SearchTrace[$script:SearchTrace.Count-1].Scope -eq 'Base')}
    Case 'Objet recree refuse a la verification' {Must-Fail {Run-Lookup -Verify $true -Guid ([guid]::NewGuid().ToString())}}
    Case 'Objet hors domaine refuse avant lecture' {$before=$script:SearchTrace.Count;Must-Fail {Run-Lookup -Verify $true -DN 'CN=PC-A,DC=other,DC=invalid'};Expect ($script:SearchTrace.Count -eq $before)}
    Case 'Recherche courte refusee' {Must-Fail {Run-Lookup -Term 'p'}}
    Case 'Recherche borne a 160 caracteres' {Must-Fail {Run-Lookup -Term ('a'*161)}}
    Case 'Jokers LDAP echappes' {$null=Run-Lookup -Term 'a*(b)';Expect ($script:SearchTrace[$script:SearchTrace.Count-1].Filter.Contains('a\2a\28b\29'))}
    Case 'Categorie utilisateur incluse explicitement' {$null=Run-Lookup -Kind Utilisateur;Expect ($script:SearchTrace[$script:SearchTrace.Count-1].Filter.Contains('(objectClass=user)'))}
    Case 'Erreur AD ne devient pas une liste vide valide' {$script:DirectoryDenied=$true;Must-Fail {Run-Lookup};$script:DirectoryDenied=$false}
    Case 'Liste complete vide reste un resultat vide' {$script:MockRows=@();$r=Run-Lookup;Expect ($r.Rows.Count -eq 0 -and -not $r.Verified)}
    Reset-FakeDirectory
    Case 'Plafond annonce et applique' {$script:MockRows=@(1..105|ForEach-Object{$script:MockRows[0]});$r=Run-Lookup;Expect ($r.Rows.Count -eq 100 -and $r.Capped)}
    Reset-FakeDirectory
    [IO.File]::WriteAllText((Join-Path $temp 'fichier.json'),'{}')
    Case 'Dossier vide de reseau parcouru localement' {$r=Run-Path $temp;Expect ($r.Rows.Count -eq 1 -and $r.Rows[0].Name -ceq 'fichier.json')}
    Case 'Validation ouverture existante' {$r=Run-Path (Join-Path $temp 'fichier.json') -Action Validate;Expect $r.Exists}
    Case 'Validation enregistrement absent sans creer' {$p=Join-Path $temp 'nouveau.json';$r=Run-Path $p -Action Validate -Mode Save;Expect (-not $r.Exists -and -not [IO.File]::Exists($p))}
    Case 'Ouverture inexistante refusee' {Must-Fail {Run-Path (Join-Path $temp 'absent.json') -Action Validate}}
    Case 'Dossier ne devient pas fichier' {Must-Fail {Run-Path $temp -Action Validate -Mode Save}}
    Case 'Repertoire parent absent non cree' {$p=Join-Path $temp 'absent\a.json';Must-Fail {Run-Path $p -Action Validate -Mode Save};Expect (-not [IO.Directory]::Exists((Join-Path $temp 'absent')))}
    Case 'Action de fichier inconnue refusee' {Must-Fail {Run-Path $temp -Action Delete}}
    Case 'Changement de fichier modifie sa signature' {$p=Join-Path $temp 'fichier.json';$old=Run-Path $p -Action Validate;[IO.File]::WriteAllText($p,'{"nouveau":true}');$new=Run-Path $p -Action Validate;Expect ($old.Signature -cne $new.Signature)}
    Case 'Aucun selecteur de fichier hors fenetre principale' {$r=New-DomeniaFileRequest Open;Must-Fail {$r.ShowDialog()}}
    Case 'Bandeau : information courte 5 s, erreur ou detail jusqu a fermeture' {
        $info=Get-DomeniaBannerPlan -Kind Info -Message 'Export terminé.'
        $long=Get-DomeniaBannerPlan -Kind Info -Message "Écriture acceptée en partie.`r`n`r`nVérifiez les étapes en échec."
        $err=Get-DomeniaBannerPlan -Kind Error -Message "Lecture impossible.`r`n`r`nCode incident : INC-9A0B. Le détail est enregistré."
        Expect (($info.AutoCloseSeconds -eq 5) -and ($long.AutoCloseSeconds -eq 0) -and ($err.AutoCloseSeconds -eq 0) -and ((Get-DomeniaBannerPlan -Kind Info -Message 'x' -Details 'y').AutoCloseSeconds -eq 0))
        Expect (($err.Code -eq 'INC-9A0B') -and ($err.Headline -eq 'Lecture impossible.') -and $err.Body.StartsWith('Code incident'))
    }
    $script:TestPhase='WPF'
    foreach($theme in @('Light','Dark')){
        $w=Load-Host $theme
        try{
            $w.FindName('TxtGlobalSearch').Text='terme-conserve';$before=Geometry $w
            $sheet=Exercise-Sheet
            Case ($theme+' : cadre integre dans le vrai XAML') {Expect $sheet.Data.Visible}
            Case ($theme+' : aucun HWND cree pour le formulaire') {Expect ($sheet.Data.Hwnd -eq [intptr]::Zero)}
            Case ($theme+' : Dispatcher actif pendant la decision') {Expect ($sheet.Data.Ticks -ge 2)}
            Case ($theme+' : page desactivee pendant le choix') {Expect $sheet.Data.Disabled}
            Case ($theme+' : annulation ne valide pas') {Expect (-not $sheet.Accepted)}
            Case ($theme+' : aucune valeur saisie dans aide') {Expect (-not $sheet.Data.Help.Contains('MARQUEUR-NE-PAS-REFLETER'))}
            Case ($theme+' : foreground du theme commun') {Expect ($sheet.Data.Brush -ceq [string]$w.Resources['TextColor'])}
            Case ($theme+' : panneaux principaux immobiles') {for($i=0;$i -lt $before.Count;$i++){Expect ([Math]::Abs($before[$i]-$sheet.Data.Measured[$i]) -le 0.5)}}
            Case ($theme+' : retour sans effacer la saisie') {Expect ($w.FindName('TxtGlobalSearch').Text -ceq 'terme-conserve' -and $w.FindName('TxtGlobalSearch').IsEnabled)}
            Case ($theme+' : hote et registre nettoyes') {Expect ($w.FindName('DomeniaDialogLayer').Visibility -eq 'Collapsed' -and $script:DomeniaSurfaceRecords.Count -eq 0 -and $null -eq $script:DomeniaSurfaceState)}
            $sheet=Exercise-Sheet -Accept $true
            Case ($theme+' : validation explicite conservee') {Expect $sheet.Accepted}
            $sheet=Exercise-Sheet -ChangeEpoch $true
            Case ($theme+' : changement de session ferme sans valider') {Expect (-not $sheet.Accepted)}
            $script:SessionEpoch=4L
            $trial=Exercise-Picker Choose
            Case ($theme+' : aucun LDAP au simple affichage') {Expect ($trial.InitialJobs -eq 0)}
            Case ($theme+' : selection premiere ligne non automatique') {Expect $trial.NoAutoSelection}
            Case ($theme+' : recherche puis verification exacte') {Expect ($script:Submissions.Count -eq 2 -and $trial.Selected.Guid -ceq $g.ToString('D'))}
            $trial=Exercise-Picker Reject
            Case ($theme+' : refus visible dans panneau sans choix') {Expect ($trial.ErrorShown -and $null -eq $trial.Selected)}
            $trial=Exercise-Picker ClosePending
            Case ($theme+' : fermeture annule la lecture passee') {Expect ($script:Stops.Count -eq 1 -and $null -eq $trial.Selected)}
            Case ($theme+' : callback tardif ignore') {& $trial.LastJob.Success ([pscustomobject]@{Rows=@();Verified=$false;RequestId=$trial.LastJob.State.RequestId}) $trial.LastJob.State;Expect ($null -eq $trial.Selected)}
            $trial=Exercise-Picker Cancel
            Case ($theme+' : annulation sans aucune recherche') {Expect ($script:Submissions.Count -eq 0 -and $null -eq $trial.Selected)}
            # L02 (UX-06, FI-02, FI-07): information and errors in page banners once the main window is shown.
            $script:DialogCalls=0;$bannerHost=$w.FindName('DomeniaBannerHost')
            Show-InfoBox 'Export terminé.'
            Case ($theme+' : information en bandeau, aucune fenetre') {Expect (($script:DialogCalls -eq 0) -and ($bannerHost.Children.Count -eq 1) -and ($bannerHost.Visibility -eq 'Visible'))}
            Case ($theme+' : information courte fermee apres 5 s') {$r=$script:DomeniaBanners[$script:DomeniaBanners.Count-1];Expect (($null -ne $r.Timer) -and ($r.Timer.Interval.TotalSeconds -eq 5) -and $r.Timer.IsEnabled)}
            $incident="Lecture impossible.`r`n`r`nCode incident : INC-1A2B. Le détail technique est enregistré dans le journal Domenia."
            Show-ErrorBox $incident;Show-ErrorBox $incident
            Case ($theme+' : erreur en bandeau, meme incident compte') {
                $r=@($script:DomeniaBanners|Where-Object{$_.Code -eq 'INC-1A2B'})
                Expect (($script:DialogCalls -eq 0) -and ($r.Count -eq 1) -and ($r[0].Occurrences -eq 2) -and ($r[0].Counter.Text -match '2$') -and ($null -eq $r[0].Timer) -and ($bannerHost.Children.Count -eq 2))
            }
            Case ($theme+' : copie pour le support avec le code') {
                $t=Get-DomeniaBannerSupportText -Record @($script:DomeniaBanners|Where-Object{$_.Code -eq 'INC-1A2B'})[0]
                Expect ($t.Contains('incident INC-1A2B') -and $t.Contains('Lecture impossible.') -and $t.Contains('Occurrences : 2'))
            }
            Show-WarningBox 'Préférences non enregistrées.';Show-InfoBox 'Liste copiée.'
            Case ($theme+' : trois bandeaux au plus') {Expect (($bannerHost.Children.Count -eq 3) -and ($script:DialogCalls -eq 0))}
            $bannerSheet=Exercise-BannerSheet
            Case ($theme+' : bandeau lisible pendant un panneau modal') {Expect ($bannerSheet.Shown -and $bannerSheet.HostEnabled -and (-not $bannerSheet.SearchEnabled))}
            foreach($b in @($script:DomeniaBanners)){Close-DomeniaBanner -Record $b}
            Case ($theme+' : fermeture des bandeaux vide l hote') {Expect (($bannerHost.Children.Count -eq 0) -and ($bannerHost.Visibility -eq 'Collapsed') -and (@($script:DomeniaBanners).Count -eq 0))}
            # UX-19 (X04): a message whose place is a button: the first action opens it (route), then the banner closes.
            Case ($theme+' : bouton de route du bandeau, destination ouverte au seul clic puis bandeau ferme') {
                $script:RouteCalls.Clear();$script:RouteAnswer=$true;$script:Trace.Clear()
                Expect ([bool](Show-DomeniaRouteNotice -Kind Warning -Text 'Stockage suspendu : les lots restent en mémoire.' -RouteText 'Reprendre les sauvegardes' -Route 'StorageResume' -Key 'x04-route')) 'Bandeau de route absent.'
                $r=@($script:DomeniaBanners|Where-Object{$_.Key -eq 'x04-route'})
                Expect (($r.Count -eq 1) -and ([string]$r[0].Route -eq 'StorageResume')) 'Bandeau de route non enregistre.'
                $first=$r[0].Actions.Children[0]
                Expect (($first -is [Windows.Controls.Button]) -and ([string]$first.Content -eq 'Reprendre les sauvegardes') -and ([string]$first.Tag.Command -eq 'Route')) ('Premier bouton : '+[string]$first.Content)
                Expect ($script:RouteCalls.Count -eq 0) 'Une navigation est partie sans clic.'
                Expect (@($script:Trace|Where-Object{$_ -ceq 'Stockage suspendu : les lots restent en mémoire.'}).Count -eq 1) ('Ligne d etat : '+($script:Trace -join ' | '))
                $first.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                Expect (($script:RouteCalls -join ',') -eq 'StorageResume') ('Routes : '+($script:RouteCalls -join ','))
                Expect (([bool]$r[0].Closed) -and (@($script:DomeniaBanners|Where-Object{$_.Key -eq 'x04-route'}).Count -eq 0)) 'Bandeau reste ouvert apres la navigation.'
                # A destination that cannot open keeps the banner and says so.
                $script:RouteAnswer=$false
                [void](Show-DomeniaRouteNotice -Kind Warning -Text 'Reprise des anciennes données bloquée.' -RouteText 'Voir la simulation' -Route 'LegacyImport' -Key 'x04-route-ko')
                $ko=@($script:DomeniaBanners|Where-Object{$_.Key -eq 'x04-route-ko'})[0]
                $ko.Actions.Children[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                Expect ((-not [bool]$ko.Closed) -and (@($script:Trace|Where-Object{$_ -ceq 'Destination indisponible : LegacyImport'}).Count -eq 1)) ('Echec de route : '+($script:Trace -join ' | '))
                Close-DomeniaBanner -Record $ko;$script:RouteAnswer=$true
            }
            # L02 review (FI-07, FI-02): an error box without code gets one and its journal line; a repeated
            # message updates its banner (latest detail, counter label of its kind, timer kept while pinned).
            $script:DomeniaErrorOccurrences=$null;$script:Trace.Clear()
            Show-ErrorBox 'Export impossible : dossier refusé.'
            Case ($theme+' : erreur sans code, code incident et ligne de journal') {
                $r=@($script:DomeniaBanners|Where-Object{([string]$_.Message).StartsWith('Export impossible')})
                Expect (($r.Count -eq 1) -and ([string]$r[0].Code -match '^INC-[0-9A-F]{4}$') -and (@($script:Trace|Where-Object{$_.Contains('['+[string]$r[0].Code+'] Export impossible')}).Count -eq 1)) ('Trace : '+($script:Trace -join ' | '))
            }
            Show-ErrorBox 'Export impossible : dossier refusé.'
            Case ($theme+' : meme erreur sans code, un bandeau et une ligne') {
                $r=@($script:DomeniaBanners|Where-Object{([string]$_.Message).StartsWith('Export impossible')})
                Expect (($r.Count -eq 1) -and ($r[0].Occurrences -eq 2) -and ($r[0].Counter.Text -ceq 'même erreur ×2') -and (@($script:Trace|Where-Object{$_.Contains('Export impossible')}).Count -eq 1) -and ($script:DialogCalls -eq 0))
            }
            Show-InfoBox -Message 'État du moteur Domenia' -Details 'Mémoire : 100 Mo';Show-InfoBox -Message 'État du moteur Domenia' -Details 'Mémoire : 140 Mo'
            Case ($theme+' : information repetee, detail du dernier appel') {
                $r=@($script:DomeniaBanners|Where-Object{$_.Message -eq 'État du moteur Domenia'})
                Expect (($r.Count -eq 1) -and ($r[0].Details -ceq 'Mémoire : 140 Mo') -and ($r[0].DetailBox.Text -ceq 'Mémoire : 140 Mo') -and ([string]$r[0].Counter.Text).StartsWith('Mis à jour à') -and (Get-DomeniaBannerSupportText -Record $r[0]).Contains('140 Mo'))
            }
            Show-WarningBox 'Préférences non enregistrées.';Show-WarningBox 'Préférences non enregistrées.'
            Case ($theme+' : avertissement repete, libelle avertissement') {
                $r=@($script:DomeniaBanners|Where-Object{$_.Kind -eq 'Warning'})
                Expect (($r.Count -eq 1) -and ($r[0].Counter.Text -ceq 'même avertissement ×2'))
            }
            foreach($b in @($script:DomeniaBanners)){Close-DomeniaBanner -Record $b}
            Show-InfoBox 'Liste copiée.'
            $pinned=@($script:DomeniaBanners)[0];$pinned.Pinned=$true;$pinned.Timer.Stop()
            Show-InfoBox 'Liste copiée.'
            Case ($theme+' : bandeau epingle, minuteur non relance') {Expect ((-not $pinned.Timer.IsEnabled) -and ($pinned.Occurrences -eq 2))}
            foreach($b in @($script:DomeniaBanners)){Close-DomeniaBanner -Record $b}
        }finally{$w.Close();$script:Window=$null}
    }
    $script:Finished=$true
    if($Preview){
        $w=Load-Host Dark;$w.ShowInTaskbar=$true;$w.ShowActivated=$true
        $script:Submissions.Clear();$script:PreviewTimer=[Windows.Threading.DispatcherTimer]::new();$script:PreviewTimer.Interval=[timespan]::FromMilliseconds(500)
        $script:PreviewTimer.Add_Tick({
            if(-not $script:Submissions.Count){return}
            $job=$script:Submissions[0];$script:Submissions.RemoveAt(0)
            if($job.OperationId -ne 'EmbeddedDirectoryLookup'){& $job.Failure 'Aucun accès fichier ou réseau dans cet aperçu.' $job.State;return}
            $row=[pscustomobject]@{Type=$job.Payload.Kind;Name='PC-DEMO';Login='demo';DN='CN=PC-DEMO,DC=example,DC=invalid';Guid='11223344-5566-7788-99aa-bbccddeeff00';Second='pc-demo.example.invalid';Description='DONNEES FICTIVES'}
            & $job.Success ([pscustomobject]@{Rows=@($row);Verified=[bool]$job.Payload.Verify;RequestId=$job.State.RequestId;Capped=$false}) $job.State
        })
        try{$script:PreviewTimer.Start();Show-DomeniaInlinePicker Machine 'APERCU LOCAL : associer un poste' 'Données fictives. Saisissez deux caractères et lancez Rechercher. Aucun compte ou poste réel interrogé.'|Out-Null}
        finally{$script:PreviewTimer.Stop();$w.Close();$script:Window=$null}
    }
}catch{Case ('Suite interrompue : '+$script:TestPhase) {throw $_}}
finally{
    if($null -ne $script:Window){$script:Window.Close()}
    if([IO.Directory]::Exists($temp)){Remove-Item -LiteralPath $temp -Recurse -Force}
    $fail=@($script:Results|Where-Object{-not $_.Passed}).Count
    $report=[ordered]@{Build='Domenia 1.0 RC1.9';Host=$PSVersionTable.PSVersion.ToString();Platform=$env:OS;Passed=($script:Results.Count-$fail);Failed=$fail;Skipped=0;Complete=(($script:Finished) -and ($script:Results.Count -eq 101));LiveADExecuted=$false;MockedLDAP=$true;WpfExecuted=($script:TestPhase -eq 'WPF');Tests=$script:Results.ToArray()}
    if($ReportPath){[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))}
    if(-not $Quiet){$report|ConvertTo-Json -Depth 8}
}
if(-not $script:Finished -or $fail -gt 0 -or -not $report.Complete){exit 1};exit 0
