#requires -Version 5.1
<# D005 : une reproduction par regression rencontree.
   Chaque scenario execute DEUX fois la meme verification : sur la version fautive (fixture historique, ou garde
   retiree quand l'historique n'existe plus que dans les notes de version) puis sur le code livre.
   Le scenario n'est reussi que si le defaut se reproduit avec la version fautive ET disparait avec le correctif.
   Fonctions reelles extraites par AST ; aucune connexion AD, aucun processus distant, aucune ecriture hors TEMP.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-regressions-'+[guid]::NewGuid().ToString('N'))
function Assert-True {param([bool]$Value,[string]$Why='Assertion fausse');if(-not $Value){throw $Why}}
function Test-Case {param([string]$CaseLabel,[scriptblock]$Body)
    try { & $Body | Out-Null; $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Passed';Detail=''}) }
    catch { $script:Checks.Add([pscustomobject]@{Name=$CaseLabel;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)}) }
}
function Read-SourceAst {param([string]$Path)
    $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e)
    if(@($e).Count){throw ($Path+' : '+$e[0].Message)}
    return $a
}
function Get-FunctionText {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0].Extent.Text
}
function Get-ParseErrorCount {param([string]$Code)
    $t=$null;$e=$null;[void][Management.Automation.Language.Parser]::ParseInput($Code,[ref]$t,[ref]$e)
    return @($e).Count
}
function Invoke-CleanProbe {
    # Fresh runspace: no function of this suite can hide a missing import.
    param([string]$Script,[object[]]$Arguments=@())
    $rs=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState=[Threading.ApartmentState]::STA
    $rs.Open();$ps=[Management.Automation.PowerShell]::Create();$ps.Runspace=$rs
    try {
        [void]$ps.AddScript($Script)
        foreach($argument in $Arguments){[void]$ps.AddArgument($argument)}
        $items=@($ps.Invoke())
        if($ps.Streams.Error.Count -gt 0){throw ('Erreur non interceptee dans la sonde : '+(($ps.Streams.Error|ForEach-Object{$_.ToString()}) -join ' | '))}
        if($items.Count -ne 1){throw ('Une reponse unique etait attendue ; recu : '+$items.Count)}
        return $items[0]
    } finally {$ps.Dispose();$rs.Dispose()}
}

$infrastructure=$true
try {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or -not [Environment]::Is64BitProcess -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
        throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous PowerShell 7 ne vaut pas preuve.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [void][IO.Directory]::CreateDirectory($temp)
    . (Join-Path $wad 'Domenia-Modules.ps1')
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    foreach($name in @('Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerEngineSelfTestCode','Initialize-AsyncEngine',
        'Get-DomeniaControl','Set-DomeniaControlText','Get-DomeniaSelectedGridRow','Test-DomeniaGridSelectionMatches','Queue-DomeniaSelectedObjectOpen','Get-DomeniaLandingView','Invoke-DomeniaPendingSelectionOpen',
        'Stop-DomeniaSelectionOpenTimer','Clear-DomeniaCurrentObjectRequest','Test-DomeniaObjectCallbackIsCurrent','Open-AdObject','Complete-DomeniaOpenObjectTaskUi','Fail-DomeniaOpenObjectTaskUi')){
        . ([scriptblock]::Create((Get-FunctionText $script:CoreAst $name)))
    }
    $assignment=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals},$true))
    if($assignment.Count -ne 1){throw 'Code commun des workers introuvable.'}
    $literal=$assignment[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    $ct=$null;$ce=$null;$script:CommonAst=[Management.Automation.Language.Parser]::ParseInput([string]$literal.Value,[ref]$ct,[ref]$ce)
    if(@($ce).Count){throw 'Code commun des workers non analysable.'}
    foreach($name in @('Get-WRemoteComputerName','Assert-WRemoteArtifactPermission','Get-WPsExecPath','Get-WMachineCredential','Get-WRemoteAdminCredential','Format-WRemoteFailureDetail','Invoke-WRemotePsExecScript','Get-WPropFirst','Get-WAllProperties','Convert-WDirectoryValue','Convert-WGuid','Convert-WSid','Convert-WLargeInteger')){
        . ([scriptblock]::Create((Get-FunctionText $script:CommonAst $name)))
    }
    . (Join-Path $PSScriptRoot 'fixtures\Domenia-AdFixtures.ps1')
}
catch {
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, plan ferme et extraction AST';Status='Failed';Detail=$_.Exception.ToString()})
}

# Engine and UI boundaries (in-memory doubles, never a worker or a network call).
function Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs) $script:Traces.Add([pscustomobject]@{Stage=$Stage;Status=$Status;Detail=$Detail})}
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level)}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Complete-UiTasks {}
function Test-DomeniaAccessBusyWrite {return $false}
function Get-DomeniaSelectedGridRows {return @($script:Ctrl.DgObjects.SelectedItems)}
function Test-DomeniaDraftNavigation {param($DN,[switch]$Refresh);return $true}
function Restore-DomeniaRefusedSelection {param($DN)}
function Clear-Secrets {}
# D085: a new selection purges the views bound to the previous object (core function, inert here).
function Reset-DomeniaSelectionBoundViews {param($Dn,$Type,$Name)}
function Clear-DomeniaLiveProbeIntent {}
function Select-DomeniaLiveResult {param([switch]$Force,[switch]$Manual) $script:ConsoleCalls++}
function Set-DomeniaRelationsGridSelection {}
function Request-UiTaskStop {param($Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,$Reason)}
function Set-VisibleTabsForType {param($Type,[switch]$PreserveWorkspace)}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab)}
function Get-DomeniaSafeObjectPropertyNames {return @('name','objectGUID','distinguishedName')}
function Get-VisitCacheValue {param($Key);return $null}
function Get-DomeniaEffectiveWorkerResult {param($Result,$RequiredProperties);return $Result}
function Complete-DomeniaOpenObjectUi {param($Result,$CacheKey,$Dn,$Type,[switch]$NoNavigate,[switch]$SuppressRemoteProbes)
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Type=$Type};$script:Renders.Add([string]$Dn)
}
function Fail-DomeniaOpenObjectUi {param($Message,$Dn)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException)}
function Start-UiTask {param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$StatusText,$SuccessHandler,$ErrorHandler)
    $job=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');State=$CallbackState}
    $script:Requests.Add($job);$script:AsyncJobs[$job.Id]=$job;return $job.Id
}
function Reset-SelectionFixture {
    if($null -ne $script:SelectionOpenTimer){$script:SelectionOpenTimer.Stop()}
    $script:SelectionOpenTimer=$null;$script:SelectionLoad=$null;$script:PendingObjectSelection=$null
    $script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn='';$script:CurrentObjectRequestState=$null
    $script:SelectedObject=$null;$script:SelectionResetDn='';$script:DraftState=$null;$script:SelectedObjectGeneration=0L
    $script:SessionEpoch=2L;$script:GlobalSearchGeneration=5;$script:AccessState=$null;$script:SuppressGridSelectionEvents=$false;$script:AsyncEngineClosing=$false
    $script:Conn=[pscustomobject]@{Connected=$true;BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';BindUser='EXAMPLE\lecteur';Credential=$null}
    $script:AsyncJobs=@{};$script:ConsoleCalls=0;$script:QueueCalls=0
    $script:Requests=[Collections.Generic.List[object]]::new();$script:Renders=[Collections.Generic.List[string]]::new()
    $script:Ctrl=@{DgObjects=[pscustomobject]@{IsEnabled=$true;SelectedItem=$null;SelectedItems=@();Items=@()};LblSelectionReadState=[pscustomobject]@{Text='';ToolTip=$null}}
}
function Get-RegressionRow {param([string]$Letter)
    $guids=@{A='aaaaaaaa-0000-4000-8000-00000000000a';B='bbbbbbbb-0000-4000-8000-00000000000b'}
    return [pscustomobject]@{DN=('CN=Objet '+$Letter+',DC=example,DC=invalid');Name=('Objet '+$Letter);Type='Utilisateur';Guid=$guids[$Letter]}
}
function Select-RegressionRow {param($Row)
    $script:Ctrl.DgObjects.SelectedItem=$Row;$script:Ctrl.DgObjects.SelectedItems=@($Row)
    Queue-DomeniaSelectedObjectOpen;Stop-DomeniaSelectionOpenTimer;Invoke-DomeniaPendingSelectionOpen
}
function Get-RegressionResult {param($Row) return [pscustomobject]@{DN=$Row.DN;Type=$Row.Type;Live=$true;Properties=@{name=@($Row.Name);objectGUID=@($Row.Guid)}}}

if($infrastructure){
try {
    # ------------------------------------------------------------ RC1.1 : dependances non chargees
    $fixtureRoot=Join-Path $temp 'rc11'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'modules'))
    [IO.File]::Copy((Join-Path $wad 'Domenia-Modules.ps1'),(Join-Path $fixtureRoot 'Domenia-Modules.ps1'))
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -File){[IO.File]::Copy($file.FullName,(Join-Path (Join-Path $fixtureRoot 'modules') $file.Name))}
    [IO.File]::Copy((Join-Path $PSScriptRoot 'fixtures\RC1.1-ModuleImports.ps1'),(Join-Path $fixtureRoot 'BaselineImports.ps1'))
    $probe=@'
param([string]$Root,[string]$Entry)
$ErrorActionPreference='Stop'
$script:RootDir=$Root
try { . (Join-Path $Root $Entry); [pscustomobject]@{Imported=$true;Reconcile=($null -ne (Get-Command Initialize-DomeniaReconcile -CommandType Function -ErrorAction SilentlyContinue));Message=''} }
catch { [pscustomobject]@{Imported=$false;Reconcile=$false;Message=$_.Exception.Message} }
'@
    Test-Case 'RC1.1 dependances non chargees : graphe fautif reproduit, chargeur ferme corrige' {
        $faulty=Invoke-CleanProbe $probe @($fixtureRoot,'BaselineImports.ps1')
        Assert-True ($faulty.Imported -and -not $faulty.Reconcile) ('Version fautive non reproduite : '+$faulty.Message)
        $fixed=Invoke-CleanProbe $probe @($fixtureRoot,'Domenia-Modules.ps1')
        Assert-True ($fixed.Imported -and $fixed.Reconcile) ('Chargeur ferme : '+$fixed.Message)
    }

    # ------------------------------------------------------------ RC1.4 : compteur 55 sur 54
    Test-Case 'RC1.4 compteur 55 sur 54 : refus reproduit, registre epingle accepte sans compteur' {
        $script:Traces=[Collections.Generic.List[object]]::new()
        $script:BaselineRegistry=Get-DomeniaWorkerOperationHashes
        $legacy=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures\RC1.4-Initialize-AsyncEngine.txt')) -replace '^function Initialize-AsyncEngine','function Initialize-LegacyAsyncEngine'
        . ([scriptblock]::Create($legacy))
        $script:AsyncTimer=$null;$script:AsyncEngineReady=$false
        function Get-DomeniaWorkerOperationHashes {
            $r=[ordered]@{};foreach($k in $script:BaselineRegistry.Keys){$r.Add([string]$k,[string]$script:BaselineRegistry[$k])}
            foreach($k in @(@($r.Keys)|Where-Object{$_ -ne 'EngineSelfTest'}|Sort-Object -Descending)){if($r.Count -le 55){break};$r.Remove($k)}
            return ,$r
        }
        $failure='';try{Initialize-LegacyAsyncEngine}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match '55/54' -and -not $script:AsyncEngineReady) ('Version fautive non reproduite : '+$failure)
        # The shipped initializer does not count: the same 55-entry registry is refused by its fingerprint.
        $failure='';try{Initialize-AsyncEngine}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'non conforme' -and -not $script:AsyncEngineReady) ('Registre incomplet accepte : '+$failure)
        Remove-Item Function:\Get-DomeniaWorkerOperationHashes
        try {
            Initialize-AsyncEngine
            Assert-True ($script:AsyncEngineReady -and $script:AsyncTimer.IsEnabled) 'Le vrai registre est refuse.'
        } finally { if($null -ne $script:AsyncTimer){$script:AsyncTimer.Stop()};$script:AsyncTimer=$null;$script:AsyncEngineReady=$false }
    }

    # ------------------------------------------------------------ RC1.10.x : expressions invalides
    Test-Case 'RC1.10 expression invalide : commande nue apres -or refusee, forme parenthesee acceptee' {
        Assert-True ((Get-ParseErrorCount 'if ($false -or Test-Example) { 1 }') -gt 0) 'Version fautive analysee sans erreur.'
        Assert-True ((Get-ParseErrorCount 'if ($false -or (Test-Example)) { 1 }') -eq 0) 'Forme corrigee refusee.'
        $runtime=@(Get-ChildItem -LiteralPath $wad -Filter '*.ps1' -File)+@(Get-ChildItem -LiteralPath (Join-Path $wad 'modules') -Filter '*.ps1' -File)
        foreach($file in $runtime){$null=Read-SourceAst $file.FullName}
        Assert-True ($runtime.Count -gt 3) 'Aucun script runtime analyse.'
    }
    Test-Case 'R1.2 concatenation PsExec : cible et options fusionnees reproduites, arguments distincts livres' {
        $Computer='TESTPC'
        $faulty=@('\\'+$Computer,'-accepteula','-nobanner')
        Assert-True ($faulty.Count -eq 1 -and $faulty[0] -match 'TESTPC.+accepteula') 'Precedence de la virgule non reproduite.'
        $rootDir=Join-Path $temp 'psexec';[void][IO.Directory]::CreateDirectory($rootDir);[IO.File]::WriteAllText((Join-Path $rootDir 'PsExec.exe'),'')
        $script:SentArguments=@()
        function Invoke-WQuietProcess {param([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds)
            $script:SentArguments=[string[]]$Arguments.Clone()
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"TestOnly":true}'))
            return [pscustomobject]@{ExitCode=0;Output=('__DOMENIA_PSEXEC_BEGIN__'+$encoded+'__DOMENIA_PSEXEC_END__')}
        }
        $context=[pscustomobject]@{RootDir=$rootDir;ScriptPath=(Join-Path $rootDir 'Domenia.ps1');MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser='';AllowRemoteArtifacts=$true;ArtifactTarget='TESTPC';ArtifactAliases=@()}
        $r=Invoke-WRemotePsExecScript $context 'TESTPC' '[pscustomobject]@{TestOnly=$true}' @{} 10
        Assert-True ($script:SentArguments[0] -ceq '\\TESTPC' -and $script:SentArguments[1] -ceq '-accepteula' -and $script:SentArguments[2] -ceq '-nobanner') ('Arguments livres : '+($script:SentArguments -join ' | '))
        Assert-True ($r.TestOnly) 'Resultat distant non lu.'
    }
    Test-Case 'Tableau d octets renvoye sans la virgule : deroulement reproduit, valeur entiere livree' {
        $bytes=New-DomeniaFixtureGuidBytes ([guid]'5f0c8a3e-1d2b-4c6a-9e7f-102030405060')
        $faulty=[scriptblock]::Create('param($Value) return $Value')
        $unrolled=@(& $faulty $bytes)
        Assert-True ($unrolled.Count -eq 16) 'Deroulement non reproduit.'
        $p=New-DomeniaFixtureProperties @{objectguid=(New-DomeniaFixtureSingleValue $bytes)}
        $fixed=Get-WPropFirst $p 'objectguid'
        Assert-True ($fixed -is [byte[]] -and $fixed.Length -eq 16) 'Le code livre deroule encore le GUID binaire.'
    }

    # ------------------------------------------------------------ PF-27 : appartenances telechargees deux fois
    Test-Case 'PF-27 appartenances : premier RefreshCache et plage de 1000 reproduits, plage de 1500 livree' {
        $livre=Get-FunctionText $script:CommonAst 'Get-WAllProperties'
        $garde='$Entry.psbase.RefreshCache([string[]]$initial)'
        Assert-True ($livre.Contains($garde)) 'Le premier RefreshCache du code livre ne filtre plus les appartenances.'
        $fautif=$livre.Replace($garde,'$Entry.psbase.RefreshCache([string[]]$requested)').Replace("'-'+(`$start+1499)","'-'+(`$start+999)")
        $fautif=$fautif.Replace('function Get-WAllProperties','function Get-WAllPropertiesFautive')
        Assert-True ($fautif.Contains('($start+999)') -and $fautif.Contains('[string[]]$requested)')) 'Version fautive non reconstituee.'
        . ([scriptblock]::Create($fautif))
        $dns=@()
        for($i=1;$i -le 2500;$i++){$dns+=('CN=Membre '+[string]$i+',OU=Groupes,DC=example,DC=invalid')}
        foreach($variant in @(@{Nom='fautive';Commande='Get-WAllPropertiesFautive';Plage='memberOf;range=0-999';AllersRetours=3;Filtre=$false},
                              @{Nom='livree';Commande='Get-WAllProperties';Plage='memberOf;range=0-1499';AllersRetours=2;Filtre=$true})){
            $entree=New-DomeniaFixtureRangedDirectoryEntry @{name=(New-DomeniaFixtureSingleValue 'Groupe Demo');memberOf=(New-DomeniaFixtureValues $dns)}
            $lu=& $variant.Commande -Entry $entree -PropertyNames @('name','memberOf')
            $lots=@($entree.Batches)
            Assert-True ($lots.Count -ge 2) ('Version '+$variant.Nom+' : '+$lots.Count+' RefreshCache.')
            $filtre=(-not $lots[0].Contains('member') -and -not $lots[0].Contains('memberOf'))
            Assert-True ($filtre -eq $variant.Filtre) ('Version '+$variant.Nom+' : le premier RefreshCache demande ['+$lots[0]+'].')
            Assert-True ($lots[1] -eq $variant.Plage) ('Version '+$variant.Nom+' : la premiere plage demandee est ['+$lots[1]+'].')
            $plages=@($entree.Refreshed|Where-Object{$_ -like '*;range=*'}).Count
            Assert-True ($plages -eq $variant.AllersRetours) ('Version '+$variant.Nom+' : '+$plages+' plages demandees.')
            $valeurs=@($lu['memberOf'])
            Assert-True ($valeurs.Count -eq 2500 -and [bool]$lu['__memberOfComplete'][0] -and [string]$lu['__memberOfNote'][0] -eq '') ('Version '+$variant.Nom+' : '+$valeurs.Count+' valeurs, complete = '+[string]$lu['__memberOfComplete'][0]+', note = ['+[string]$lu['__memberOfNote'][0]+'].')
        }
    }

    # ------------------------------------------------------------ RC1.10.6 -> RC1.10.7 : prechargement debranche
    Test-Case 'RC1.10.6 prechargement debranche : clic console seul reproduit, gestionnaire reel raccorde' {
        $wire=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wire-Events'},$true))[0]
        $calls=@($wire.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'Add_SelectionChanged' -and $n.Expression.Extent.Text -match 'DgObjects'},$true))
        Assert-True ($calls.Count -eq 1) 'Gestionnaire de selection de DgObjects introuvable.'
        $real=$calls[0].Arguments[0].ScriptBlock.GetScriptBlock()
        # RC1.10.6 (PRECHARGEMENT-RC1.10.7.md): the real handler only fed the console probe circuit.
        $faulty=[scriptblock]::Create('param($sender,$e) if($e.OriginalSource -eq $sender){Select-DomeniaLiveResult}')
        foreach($variant in @(@{Name='fautive';Handler=$faulty;Preloaded=$false},@{Name='livree';Handler=$real;Preloaded=$true})){
            Reset-SelectionFixture
            # Real WPF grid, real selection event; the real Queue-DomeniaSelectedObjectOpen records the pending read.
            $grid=[Windows.Controls.DataGrid]::new();$script:Ctrl.DgObjects=$grid
            $row=Get-RegressionRow 'A';[void]$grid.Items.Add($row)
            $grid.Add_SelectionChanged($variant.Handler);$grid.SelectedItem=$row
            $preloaded=($null -ne $script:PendingObjectSelection -and [string]$script:PendingObjectSelection.Dn -eq $row.DN)
            Assert-True ($preloaded -eq $variant.Preloaded) ('Version '+$variant.Name+' : prechargement = '+$preloaded+', appels console = '+$script:ConsoleCalls)
            if($null -ne $script:SelectionOpenTimer){$script:SelectionOpenTimer.Stop()}
        }
    }

    # ------------------------------------------------------------ RC1.3 / RC1.10.7 : retours tardifs
    Test-Case 'Retour tardif : garde retiree reproduit A affiche sur B, garde livree le refuse' {
        $source=Get-FunctionText $script:CoreAst 'Complete-DomeniaOpenObjectTaskUi'
        $guard='(Test-DomeniaObjectCallbackIsCurrent $State)'
        Assert-True ($source.Contains($guard)) 'Garde de rappel absente du code livre.'
        $mutant=$source.Replace($guard,'($true)').Replace('function Complete-DomeniaOpenObjectTaskUi','function Complete-DomeniaOpenObjectTaskUiSansGarde')
        . ([scriptblock]::Create($mutant))
        foreach($variant in @(@{Name='fautive';Command='Complete-DomeniaOpenObjectTaskUiSansGarde';LateShown=$true},@{Name='livree';Command='Complete-DomeniaOpenObjectTaskUi';LateShown=$false})){
            Reset-SelectionFixture
            $a=Get-RegressionRow 'A';$b=Get-RegressionRow 'B'
            Select-RegressionRow $a;$late=$script:Requests[0]
            Select-RegressionRow $b;$currentId=$script:CurrentObjectRequestId
            & $variant.Command (Get-RegressionResult $a) $late.State
            $shown=($script:Renders -contains $a.DN)
            Assert-True ($shown -eq $variant.LateShown) ('Version '+$variant.Name+' : reponse tardive de A affichee = '+$shown)
            if(-not $variant.LateShown){Assert-True ($script:CurrentObjectRequestId -ceq $currentId -and $null -eq $script:SelectedObject) 'La lecture courante de B a ete modifiee.'}
        }
    }

    # ------------------------------------------------------------ Harnais Windows PowerShell 5.1 (lot D120)
    Test-Case 'Harnais 5.1 : tableau JSON lu en un seul objet reproduit, lecture en deux temps corrigee' {
        $json=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))
        $faulty=@($json|ConvertFrom-Json)
        $parsed=$json|ConvertFrom-Json;$fixed=@($parsed)
        Assert-True ($faulty.Count -eq 1) ('Comportement 5.1 non reproduit : '+$faulty.Count+' element(s).')
        Assert-True ($fixed.Count -gt 1 -and $fixed.Count -eq (Get-DomeniaWorkerOperationHashes).Count) ('Lecture corrigee : '+$fixed.Count)
    }
    Test-Case 'Harnais : parametre $Name masquant $name reproduit, libelle $CaseLabel corrige' {
        $name='TESTPC'
        function Invoke-FaultyCase {param([string]$Name,[scriptblock]$Action) & $Action}
        function Invoke-FixedCase {param([string]$CaseLabel,[scriptblock]$Action) & $Action}
        $faultyError='';try{[void](Invoke-FaultyCase 'Cible unique valide : TESTPC' {Get-WRemoteComputerName $name})}catch{$faultyError=$_.Exception.Message}
        Assert-True ($faultyError -match 'invalide') 'Masquage de variable non reproduit.'
        Assert-True ((Invoke-FixedCase 'Cible unique valide : TESTPC' {Get-WRemoteComputerName $name}) -ceq 'TESTPC') 'Cible correcte refusee apres correction.'
    }

    # ------------------------------------------------------------ Conservation des reproductions existantes
    $catalog=@(
        @{Suite='wad\tests\Test-DomeniaModules.ps1';Label='Regression RC1.1 reproduite : commande Initialize-DomeniaReconcile absente';Fixture='RC1.1-ModuleImports.ps1'},
        @{Suite='wad\tests\Test-DomeniaStartupLogin.ps1';Label='Le vrai initialiseur RC1.4 reproduit le refus 55 sur 54';Fixture='RC1.4-Initialize-AsyncEngine.txt'},
        @{Suite='wad\tests\Test-DomeniaActivityLayout.ps1';Label=' : reproduire le decalage de la ligne Auto RC1.6';Fixture='RC1.6-PageHeader.xaml.txt'},
        @{Suite='wad\tests\Test-DomeniaLogin.ps1';Label='R1.7 simulee : erreur de refresh masquee par NullArray';Fixture='AuthProbe-R1.7.ps1'},
        @{Suite='wad\tests\Test-DomeniaLogin.ps1';Label='R1.7.1 : getter COM refusant masque par NATIVE_NULL';Fixture='AuthProbe-R1.7.1.ps1'},
        @{Suite='wad\tests\Test-DomeniaRemote.ps1';Label='Reproduction de l ancienne concatenation incorrecte (aucun processus)';Fixture=''},
        @{Suite='wad\tests\Test-DomeniaPreload.ps1';Label='Real selection event calls preload, not only the console probe';Fixture=''},
        @{Suite='wad\tests\Test-DomeniaPreload.ps1';Label='Late A cannot fill B';Fixture=''},
        @{Suite='engineering\d120\Test-NativeParser.ps1';Label='bare-command-after-or';Fixture=''}
    )
    foreach($entry in $catalog){
        $entrySuite=[string]$entry.Suite;$entryLabel=[string]$entry.Label;$entryFixture=[string]$entry.Fixture
        Test-Case ('Reproduction conservee : '+$entryLabel.Trim()) {
            $path=Join-Path $root $entrySuite
            Assert-True ([IO.File]::Exists($path)) ('Suite absente : '+$entrySuite)
            $null=Read-SourceAst $path
            $text=[IO.File]::ReadAllText($path)
            Assert-True ($text.Contains($entryLabel)) ('Cas de reproduction retire : '+$entryLabel)
            if($entryFixture){
                Assert-True ([IO.File]::Exists((Join-Path $PSScriptRoot ('fixtures\'+$entryFixture)))) ('Fixture absente : '+$entryFixture)
                Assert-True ($text.Contains($entryFixture)) ('Fixture non utilisee par sa suite : '+$entryFixture)
            }
        }
    }
    Test-Case 'Chaque fixture de regression est utilisee par au moins une suite' {
        $sources=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File|ForEach-Object{[IO.File]::ReadAllText($_.FullName)})
        $orphans=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixtures') -File|Where-Object{$fixtureName=$_.Name;@($sources|Where-Object{$_.Contains($fixtureName)}).Count -eq 0}|ForEach-Object{$_.Name})
        Assert-True ($orphans.Count -eq 0) ('Fixtures orphelines : '+($orphans -join ', '))
    }
}
finally { if([IO.Directory]::Exists($temp)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue} }
}

$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$report=[ordered]@{
    Kind='Regressions';Point='D005';Rule='Chaque scenario echoue avec sa version fautive et reussit avec son correctif.'
    Host=@{PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString()}
    NoADAccess=$true;NoNetwork=$true;Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$script:Checks.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-regressions-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Status -AutoSize|Out-String|Write-Host;Write-Host ('Rapport : '+$ReportPath)}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
