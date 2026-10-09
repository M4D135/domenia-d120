#requires -Version 5.1
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Value,[string]$Message='Assertion non verifiee');if(-not $Value){throw $Message}}
function Case {param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$true;Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Passed=$false;Detail=$_.Exception.Message})}
}
function Expect-Failure {param([scriptblock]$Body,[string]$Pattern='')
    $failure=$null;try{& $Body|Out-Null}catch{$failure=$_}
    Expect ($null -ne $failure) 'Une erreur etait attendue.'
    if($Pattern){Expect ($failure.Exception.Message -match $Pattern) ('Erreur inattendue : '+$failure.Exception.Message)}
}
function Read-Ast {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+' : '+$e[0].Message)}
    return $a
}
function Find-FunctionAst {param($Ast,[string]$Name)
    $found=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($found.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $found[0]
}
function Stop-FixtureEngine {
    if($null -ne $script:AsyncTimer){$script:AsyncTimer.Stop()}
    $script:AsyncTimer=$null;$script:AsyncEngineReady=$false;$script:AsyncEngineClosing=$false
}
# All observable services below are in-memory doubles, no domain or credential access.
function Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs) $script:Traces.Add([pscustomobject]@{Stage=$Stage;Status=$Status;Detail=$Detail})}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function Get-CfgValue {param($Section,$Name,$Default) return $Default}
function Complete-UiTasks {$script:PollTicks++}
function Get-DomeniaStoredTheme {return $script:TestTheme}
function Save-DomeniaTheme {param($Theme) $script:TestTheme=$Theme}
function Pump-FixtureDispatcher {param([int]$Milliseconds=350)
    $frame=[Windows.Threading.DispatcherFrame]::new()
    $stop=[Windows.Threading.DispatcherTimer]::new();$stop.Interval=[TimeSpan]::FromMilliseconds($Milliseconds)
    $handler=[EventHandler]({$frame.Continue=$false}.GetNewClosure())
    $stop.Add_Tick($handler)
    try{$stop.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$stop.Stop();$stop.Remove_Tick($handler)}
}
try{
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Tests requis sous Windows PowerShell 5.1 x64 STA, pas PowerShell 7.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $core=Read-Ast (Join-Path $wad 'Domenia-Core.ps1')
    foreach($name in @('Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerEngineSelfTestCode','Initialize-AsyncEngine','Get-DomeniaStandardLoginXaml','Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme','Assert-DomeniaXamlPreflight')){
        . ([scriptblock]::Create((Find-FunctionAst $core $name).Extent.Text))
    }
    # Only definition-only UI modules are imported. The application entrypoint is not executed.
    . (Join-Path $wad 'modules\Domenia-Embedded.UI.ps1')
    . (Join-Path $wad 'modules\Domenia-UX.UI.ps1')
    # FI-05 / PF-06: the real initializer takes its poll timer from the protected factory of the engine heartbeat.
    foreach($engineModule in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Engine.UI.ps1')){. (Join-Path $wad ('modules\'+$engineModule))}
    $script:TestTheme='Light';$script:Traces=[Collections.Generic.List[object]]::new();$script:PollTicks=0
    $registry=Get-DomeniaWorkerOperationHashes
    $script:BaselineRegistry=$registry
    # Windows PowerShell 5.1: ConvertFrom-Json emits a JSON array as ONE pipeline object.
    # Assign first, then enumerate with @(); @(... | ConvertFrom-Json) would give a single element.
    $parsedContracts=Get-Content -LiteralPath (Join-Path $wad '..\tools\operation-contracts.json') -Raw|ConvertFrom-Json
    $expected=@($parsedContracts)
    $registryFunction=(Find-FunctionAst $core 'Get-DomeniaWorkerOperationHashes').Extent.Text
    function Clone-Registry {$r=[ordered]@{};foreach($k in $script:BaselineRegistry.Keys){$r.Add([string]$k,[string]$script:BaselineRegistry[$k])};return ,$r}
    Case 'Le registre et le contrat DEV declarent les memes operations' {
        $left=@($registry.Keys|Sort-Object);$right=@($expected|ForEach-Object{$_.Operation}|Sort-Object)
        Expect ($left.Count -eq $right.Count -and (@(Compare-Object $left $right).Count -eq 0))
        # The count is the reviewed DEV contract, never a constant (57 before the D120 additions).
        Expect ($registry.Contains('LiveSelectedPing') -and $registry.Count -eq $expected.Count) ('Registre '+$registry.Count+' / contrat '+$expected.Count)
    }
    Case 'La verification du registre complet accepte la livraison' {Expect ((Assert-DomeniaWorkerRegistry) -eq $expected.Count)}
    Case 'L ordre de declaration ne change pas le controle' {$r=[ordered]@{};foreach($k in @($registry.Keys|Sort-Object -Descending)){$r.Add($k,$registry[$k])};Expect ((Assert-DomeniaWorkerRegistry $r) -eq $expected.Count)}
    Case 'Un registre nul est refuse' {Expect-Failure {Assert-DomeniaWorkerRegistry -Registry $null} 'absent|vide'}
    Case 'Un registre vide est refuse' {Expect-Failure {Assert-DomeniaWorkerRegistry -Registry ([ordered]@{})} 'absent|vide'}
    Case 'Retirer LiveSelectedPing est refuse' {$r=Clone-Registry;$r.Remove('LiveSelectedPing');Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'non conforme'}
    Case 'Ajouter une operation non autorisee est refuse' {$r=Clone-Registry;$r.Add('UnexpectedOperation',('A'*64));Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'non conforme'}
    Case 'Remplacer une operation en conservant le nombre d entrees est refuse' {$r=Clone-Registry;$r.Remove('LiveSelectedPing');$r.Add('UnexpectedOperation',('A'*64));Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'non conforme'}
    Case 'Modifier une empreinte valide est refuse' {$r=Clone-Registry;$r['LiveSelectedPing']='A'*64;Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'non conforme'}
    Case 'Une empreinte de mauvaise longueur est refusee' {$r=Clone-Registry;$r['ReadLaps']='A';Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'Empreinte'}
    Case 'Une empreinte en minuscules est refusee' {$r=Clone-Registry;$r['ReadLaps']=$r['ReadLaps'].ToLowerInvariant();Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'Empreinte'}
    Case 'Un identifiant avec caracteres interdits est refuse' {$r=Clone-Registry;$r.Add('Bad-Operation',('A'*64));Expect-Failure {Assert-DomeniaWorkerRegistry $r} 'Identifiant'}
    Case 'Le corps de chaque operation correspond a son empreinte sans execution' {
        $asts=@{}
        foreach($item in $expected){
            $path=Join-Path (Split-Path -Parent $wad) $item.File
            if(-not $asts.ContainsKey($path)){$asts[$path]=Read-Ast $path}
            $fn=Find-FunctionAst $asts[$path] $item.Function
            $here=@($fn.FindAll({param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Extent.Text.StartsWith('@')},$true)|Sort-Object {$_.Extent.StartOffset})
            $raw=$here[[int]$item.LiteralIndex].Extent.Text -replace "`r`n","`n"
            # Parse the literal spelling; never evaluate an operation to obtain its body.
            $body=$raw.Substring(3,$raw.Length-6)
            $hash=Assert-DomeniaWorkerOperationCode -OperationId $item.Operation -Code $body
            Expect ($hash -ceq $item.Sha256) $item.Operation
        }
    }
    Case 'Un corps modifie est refuse sans etre execute' {Expect-Failure {Assert-DomeniaWorkerOperationCode -OperationId 'EngineSelfTest' -Code 'throw "not executed"'} 'Integrite'}
    Case 'Une operation inconnue est refusee avant execution' {Expect-Failure {Assert-DomeniaWorkerOperationCode -OperationId 'UnexpectedOperation' -Code 'test'} 'non autorisee'}
    Case 'Le vrai initialiseur RC1.4 reproduit le refus 55 sur 54' {
        Stop-FixtureEngine
        $old=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\RC1.4-Initialize-AsyncEngine.txt'))
        $old=$old -replace '^function Initialize-AsyncEngine','function Initialize-LegacyAsyncEngine'
        . ([scriptblock]::Create($old))
        # Reproduce the RC1.4 situation exactly: 55 registered operations against the old literal 54.
        # The removal count is derived from the real registry, so new pinned operations keep this regression valid.
        function Get-DomeniaWorkerOperationHashes {
            $r=Clone-Registry
            foreach($k in @(@($r.Keys)|Where-Object{$_ -ne 'EngineSelfTest'}|Sort-Object -Descending)){if($r.Count -le 55){break};$r.Remove($k)}
            return ,$r
        }
        try { Expect-Failure {Initialize-LegacyAsyncEngine} '55/54' } finally { Remove-Item Function:\Get-DomeniaWorkerOperationHashes }
        Expect (-not $script:AsyncEngineReady -and $null -eq $script:AsyncTimer)
    }
    Case 'Le vrai initialiseur corrige demarre son DispatcherTimer' {
        Stop-FixtureEngine;Initialize-AsyncEngine
        Expect ($script:AsyncEngineReady -and $script:AsyncTimer.IsEnabled)
        Expect ($script:Traces[$script:Traces.Count-1].Detail -match ('\b'+[string]$expected.Count+' operations')) ('Trace : '+$script:Traces[$script:Traces.Count-1].Detail)
    }
    Case 'Les ticks continuent sur le Dispatcher sans operation reseau' {
        $script:PollTicks=0;Pump-FixtureDispatcher 500;Expect ($script:PollTicks -gt 0)
    }
    Case 'Une seconde initialisation ne cree pas un second timer' {$first=$script:AsyncTimer;Initialize-AsyncEngine;Expect ([object]::ReferenceEquals($first,$script:AsyncTimer))}
    Case 'Un registre incomplet bloque le vrai initialiseur' {
        Stop-FixtureEngine
        function Get-DomeniaWorkerOperationHashes {$r=Clone-Registry;$r.Remove('LiveSelectedPing');return ,$r}
        try{Expect-Failure {Initialize-AsyncEngine} 'non conforme';Expect (-not $script:AsyncEngineReady -and $null -eq $script:AsyncTimer)}finally{Remove-Item Function:\Get-DomeniaWorkerOperationHashes}
    }
    Stop-FixtureEngine
    foreach($theme in @('Light','Dark')){
        $script:TestTheme=$theme;$window=$null
        try{
            $xaml=Get-DomeniaStandardLoginXaml;Assert-DomeniaXamlPreflight -XamlText $xaml -Context 'Test login FILPRO/Domenia'
            $reader=[Xml.XmlNodeReader]::new([xml]$xaml)
            try{$window=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
            Initialize-DomeniaUxLoginPresentation $window
            $window.Title='DOMENIA RC1.6 TEST LOCAL : aucun acces AD'
            $window.FindName('TxtLogin').Text='EXAMPLE\test';$window.FindName('PwdLogin').Password='FICTIF-NE-PAS-ENREGISTRER'
            # All authentication/diagnostic business events are deliberately not wired.
            $window.Show();$window.UpdateLayout()
            Case ($theme+' : disposition et largeur FILPRO conservees') {Expect ($window.Width -eq 480 -and $window.ResizeMode -eq 'NoResize' -and $window.SizeToContent -eq 'Height')}
            Case ($theme+' : champs de 40 et hotes natifs disponibles') {
                foreach($n in @('TxtLogin','PwdLogin')){$c=$window.FindName($n);$c.ApplyTemplate()|Out-Null;Expect ($c.ActualHeight -ge 40 -and $null -ne $c.Template.FindName('PART_ContentHost',$c))}
            }
            Case ($theme+' : libelles associes aux champs') {$doc=[xml]$xaml;Expect ($xaml.Contains('ElementName=TxtLogin') -and $xaml.Contains('ElementName=PwdLogin'))}
            Case ($theme+' : formulaire seul defilant, actions hors du scroll') {
                $form=$window.FindName('LoginFormScroll');$actions=$window.FindName('LoginActions');Expect ($form.Content -eq $window.FindName('LoginFields'))
                Expect ([Windows.Controls.Grid]::GetRow($actions) -eq 2 -and [Windows.Controls.Grid]::GetRow($form) -eq 1)
            }
            Case ($theme+' : pas de diagnostic encombrant au repos') {Expect (-not $window.FindName('UxLoginFeedback').IsVisible -and -not $window.FindName('TxtLoginTechnical').IsVisible)}
            Case ($theme+' : actions principales alignees et larges') {
                $cancel=$window.FindName('BtnCancel');$connect=$window.FindName('BtnLogin');$sso=$window.FindName('BtnWindowsLogin')
                Expect ($connect.ActualHeight -ge 40 -and $cancel.ActualHeight -ge 40 -and $sso.ActualHeight -ge 36 -and $sso.ActualWidth -gt $connect.ActualWidth)
            }
            Case ($theme+' : textes et champs suivent le theme') {Expect ($window.FindName('TxtLogin').Foreground.ToString() -eq $window.Resources['DomeniaBootText'].ToString())}
            Case ($theme+' : theme sans perte de saisie ni authentification') {
                $saved=$script:TestTheme;Switch-DomeniaExperienceLoginTheme $window
                Expect ($saved -ne $script:TestTheme -and $window.FindName('TxtLogin').Text -eq 'EXAMPLE\test' -and $window.FindName('PwdLogin').Password -eq 'FICTIF-NE-PAS-ENREGISTRER')
                Switch-DomeniaExperienceLoginTheme $window
            }
            Case ($theme+' : pas de mot de passe dans les aides') {
                foreach($n in @('TxtLogin','PwdLogin','ChkRemember','BtnLogin','BtnWindowsLogin','BtnCancel','BtnSuiteLoginTheme')){Expect (([string]$window.FindName($n).ToolTip).IndexOf('FICTIF-NE-PAS-ENREGISTRER',[StringComparison]::Ordinal) -lt 0)}
            }
            Case ($theme+' : erreur longue et diagnostic externe accessible') {
                $window.FindName('LblLoginError').Text=('Erreur de test. '*100);$window.FindName('LblLoginStage').Text='Details disponibles.'
                $window.UpdateLayout();$window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::ApplicationIdle);$window.UpdateLayout()
                Expect ($window.FindName('UxLoginFeedback').IsVisible -and $window.FindName('BtnLoginLog').IsVisible -and $window.FindName('BtnCopyLoginDiag').IsVisible -and -not $window.FindName('TxtLoginTechnical').IsVisible)
            }
            Case ($theme+' : actions restent dans la fenetre limitee a 480 de haut') {
                $window.MaxHeight=480;$window.Height=480;$window.SizeToContent='Manual';$window.UpdateLayout()
                foreach($n in @('BtnCancel','BtnLogin','BtnWindowsLogin')){$c=$window.FindName($n);$p=$c.TranslatePoint([Windows.Point]::new(0,0),$window);Expect ($c.IsVisible -and $p.Y -ge 0 -and ($p.Y+$c.ActualHeight) -le ($window.ActualHeight+1))}
            }
            Case ($theme+' : memorisation et theme accessibles au clavier') {Expect ($window.FindName('ChkRemember').IsTabStop -and $window.FindName('BtnSuiteLoginTheme').IsTabStop)}
        }finally{if($null -ne $window){$window.Close()}}
    }
}catch{$script:Checks.Add([pscustomobject]@{Name='Infrastructure native requise';Passed=$false;Detail=$_.Exception.ToString()})}
finally{Stop-FixtureEngine}
$failed=@($script:Checks|Where-Object{-not $_.Passed})
$expectedCases=44
$report=[ordered]@{Build='2026.10.01-DOMENIA-1.0-RC1.6-BOOTLOGIN';Environment='Windows PowerShell 5.1 x64 STA';Passed=$script:Checks.Count-$failed.Count;Failed=$failed.Count;Skipped=0;Complete=($script:Checks.Count -eq $expectedCases -and $failed.Count -eq 0);Expected=$expectedCases;NoADAccess=$true;NoProductionData=$true;Tests=$script:Checks.ToArray()}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-RC1.6-tests-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Passed -AutoSize;Write-Host ('Rapport : '+$ReportPath)}
if(-not $report.Complete){throw ('Verification RC1.6 en echec ou incomplete : '+$ReportPath)}
