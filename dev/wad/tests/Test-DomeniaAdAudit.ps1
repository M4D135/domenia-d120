#requires -Version 5.1
<# Points 101 a 110 (lot W12) : preuve de raccordement de l'audit AD et des recettes d'assistance.
   Vrais modules du plan ferme (regles, corps epingles, interface), vraie vue XAML chargee par WPF, vraies fonctions du
   coeur extraites par AST. Start-UiTask, le presse-papiers et les confirmations sont remplaces par des doublures :
   aucune lecture AD, CIM, DNS ni SQLite n'est envoyee. Les gardes des corps epingles sont executees pour de vrai
   (elles refusent avant tout appel reseau). Domaine example.invalid, comptes et GUID inventes.
#>
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
# PF-24 (lot Z04): a catalogued control carries its help in Domenia-UX.help.json only (the XAML keeps it for the
# other controls); this reads the effective tool tip or help text of a node of the main XAML.
$script:TestHelpCatalogue=$null
function Get-TestCatalogueHelp {
    param($Node,[string]$Attribute)
    $value=[string]$Node.GetAttribute($Attribute)
    if($value){return $value}
    if($null -eq $script:TestHelpCatalogue){
        $script:TestHelpCatalogue=@{}
        $catalogue=Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules') 'Domenia-UX.help.json'
        foreach($entry in @([IO.File]::ReadAllText($catalogue,[Text.Encoding]::UTF8)|ConvertFrom-Json)){$script:TestHelpCatalogue[[string]$entry.Name]=$entry}
    }
    $name=[string]$Node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
    if($script:TestHelpCatalogue.ContainsKey($name)){return [string]$script:TestHelpCatalogue[$name].Text}
    return ''
}
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$script:Checks=[Collections.Generic.List[object]]::new()
function Expect {param([bool]$Condition,[string]$Message='Assertion fausse');if(-not $Condition){throw $Message}}
function Case {
    param([string]$Name,[scriptblock]$Body)
    try{& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)})}
}
function Read-SourceAst {
    param([string]$Path)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw ($Path+' ligne '+$errors[0].Extent.StartLineNumber+' : '+$errors[0].Message)}
    return $ast
}
function Get-FunctionText {
    param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $Name)},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0].Extent.Text
}
$script:AuditFiles=@('Domenia-AdAudit.Model.ps1','Domenia-AdAudit.Worker.ps1','Domenia-AdAudit.UI.ps1','Domenia-Assistance.Model.ps1','Domenia-Assistance.UI.ps1')
$script:AuditOperations=@('PasswordPolicyRead','GroupPathRead','DelegationRead','GpoLinksRead','GpoAppliedRead','AdHealthRead','DcServicesRead','AdConsistencyScan','MachineIdentityRead','RelationHistoryRead')
$script:WorkerFunctions=[ordered]@{
    PasswordPolicyRead='Get-DomeniaPasswordPolicyReadWorkerCode';GroupPathRead='Get-DomeniaGroupPathWorkerCode';DelegationRead='Get-DomeniaDelegationReadWorkerCode'
    GpoLinksRead='Get-DomeniaGpoLinksReadWorkerCode';GpoAppliedRead='Get-DomeniaGpoAppliedReadWorkerCode';AdHealthRead='Get-DomeniaAdHealthReadWorkerCode'
    DcServicesRead='Get-DomeniaDcServicesReadWorkerCode';AdConsistencyScan='Get-DomeniaAdConsistencyScanWorkerCode';MachineIdentityRead='Get-DomeniaMachineIdentityReadWorkerCode'
    RelationHistoryRead='Get-DomeniaRelationHistoryReadWorkerCode'
}
$infrastructure=$true
try{
    if(($PSVersionTable.PSEdition -ne 'Desktop') -or ($PSVersionTable.PSVersion.Major -ne 5) -or (-not [Environment]::Is64BitProcess) -or ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')){
        throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous un autre moteur ne vaut pas preuve.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    foreach($file in @($script:AuditFiles+@('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Safety.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Engine.Worker.ps1','Domenia-Access.Model.ps1','Domenia-Membership.Worker.ps1','Domenia-Assist.Model.ps1'))){
        [void](Read-SourceAst (Join-Path $modules $file))
        . (Join-Path $modules $file)
    }
    # Scope of a replacement account (channel AD or machine), taken alone from the access module of the interface.
    . ([scriptblock]::Create((Get-FunctionText (Read-SourceAst (Join-Path $modules 'Domenia-Access.UI.ps1')) 'Get-DomeniaAccessScope')))
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    $script:CoreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Set-DomeniaControlEnabled','Set-DomeniaItemsSource','Get-DomeniaEffectiveWorkerResult','Get-MainXaml')){
        . ([scriptblock]::Create((Get-FunctionText $script:CoreAst $name)))
    }
    $script:Help=@(([IO.File]::ReadAllText((Join-Path $modules 'Domenia-UX.help.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json))
}catch{
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, modules et coeur analyses nativement';Status='Failed';Detail=$_.Exception.ToString()})
}

# Doubles of the application boundaries: no worker, no network, no clipboard, no dialog.
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,$TaskClass)
    $script:Tasks.Add([pscustomobject]@{Name=$Name;OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;Success=$SuccessHandler;Error=$ErrorHandler;TaskClass=$TaskClass;Disable=@($DisableControls);Timeout=[int]$TimeoutSeconds})
    return ('task-'+$script:Tasks.Count)
}
function Set-Status {param($Text,$Level);$script:Statuses.Add([string]$Text)}
function Write-AppLog {param($Text,$Level)}
function Confirm-Action {param($Message,$Title);$script:Confirmations.Add([string]$Message);return [bool]$script:ConfirmAnswer}
function Set-ClipboardSafe {param([string]$Text);$script:Clipboard=$Text}
function Invoke-DomeniaSafeUiAction {param([string]$Operation,[scriptblock]$Action,[switch]$NoPopup);& $Action}
function Get-DomeniaLocalDatabasePathForRead {return [string]$script:DatabasePath}
function Get-LinksForUser {param([string]$UserLogin);foreach($l in @($script:Links)){if([string]$l.UserLogin -ieq $UserLogin){$l}}}
function Get-LinksForComputer {param([string]$Computer);foreach($l in @($script:Links)){if([string]$l.Computer -ieq $Computer){$l}}}

function New-FakeGrid {return [pscustomobject]@{ItemsSource=$null;SelectedItem=$null;SelectedItems=@();IsEnabled=$true;Columns=@()}}
function Reset-AuditFixture {
    $script:Tasks=[Collections.Generic.List[object]]::new();$script:Statuses=[Collections.Generic.List[string]]::new();$script:Confirmations=[Collections.Generic.List[string]]::new()
    $script:ConfirmAnswer=$false;$script:Clipboard='';$script:DatabasePath='C:\Fixture\Domenia.db';$script:Links=@();$script:Relations=$null
    $script:SessionEpoch=5L;$script:SelectedObjectGeneration=1L;$script:SelectedBranchDn=''
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid';User='EXAMPLE\lecteur';Server='dc1.example.invalid'}
    $script:Ctrl=@{}
    $script:AdAuditView=[pscustomobject]@{Name='DomeniaAdAuditView'}
    foreach($name in @('LblAdAuditTarget','LblAdAuditPolicy','LblAdAuditGroups','LblAdAuditGroupPath','LblAdAuditAcl','LblAdAuditAclEstimate','LblAdAuditGpo','LblAdAuditMachineIdentity','LblAdAuditRelationOverview','LblAdAuditHistory','LblAdAuditDc','LblAdAuditScope','LblAdAuditScan')){$script:Ctrl[$name]=[pscustomobject]@{Text=''}}
    foreach($name in @('BtnAdAuditPolicy','BtnAdAuditGroups','BtnAdAuditGroupConfirm','BtnAdAuditAcl','BtnAdAuditAclToken','BtnAdAuditGpoLinks','BtnAdAuditGpoApplied','BtnAdAuditMachineIdentity','BtnAdAuditHistory','BtnAdAuditDcList','BtnAdAuditDcProbe','BtnAdAuditDcServices','BtnAdAuditScan')){$script:Ctrl[$name]=[pscustomobject]@{IsEnabled=$true}}
    foreach($name in @('DgAdAuditPolicy','DgAdAuditGroups','DgAdAuditAcl','DgAdAuditAclEstimate','DgAdAuditGpo','DgAdAuditGpoFacts','DgAdAuditMachineIdentity','DgAdAuditHistory','DgAdAuditDcList','DgAdAuditHealth','DgAdAuditRepl','DgAdAuditServices','DgAdAuditDcFacts','DgAdAuditScan','CmbAdAuditGroupTarget')){$script:Ctrl[$name]=New-FakeGrid}
    $script:Ctrl['ChkAdAuditAclExplicit']=[pscustomobject]@{IsChecked=$false};$script:Ctrl['ChkAdAuditScanSubtree']=[pscustomobject]@{IsChecked=$false}
    $script:Ctrl['TxtAdAuditAclFilter']=[pscustomobject]@{Text=''}
    $script:Ctrl['AdAuditDcResultTabs']=[pscustomobject]@{SelectedItem=$null};$script:Ctrl['TabAdAuditDcServices']=[pscustomobject]@{Name='TabAdAuditDcServices'}
    $script:AdAuditData=$null;$script:AdAuditTarget=$null
    Reset-DomeniaAdAuditData
}
function Select-AuditObject {
    param([string]$Type='Utilisateur',[string]$Name='Jean Dupont',[string]$Dn='CN=Jean Dupont,OU=Support,DC=example,DC=invalid',[string]$Sam='jdupont',[string]$Dns='')
    $script:SelectedObjectGeneration=[long]$script:SelectedObjectGeneration+1
    $props=@{objectSid=@('S-1-5-21-1000-2000-3000-1104');sAMAccountName=@($Sam);primaryGroupID=@('513')}
    if($Dns){$props['dNSHostName']=@($Dns)}
    $script:SelectedObject=[pscustomobject]@{DN=$Dn;Type=$Type;Name=$Name;Guid='11111111-1111-4111-8111-111111111111';Entry=[pscustomobject]@{Properties=$props}}
    Sync-DomeniaAdAuditTarget
}
function Get-LastTask {return $script:Tasks[$script:Tasks.Count-1]}

if($infrastructure){
    Case 'Plan ferme : modules de l audit declares avec leurs fonctions et dependances' {
        . (Join-Path $wad 'Domenia-Modules.ps1')
        $plan=@(Get-DomeniaRuntimeModulePlan)
        foreach($file in $script:AuditFiles){
            $entry=@($plan|Where-Object{$_.File -eq $file})
            Expect ($entry.Count -eq 1) ('Module absent du plan : '+$file)
            $ast=Read-SourceAst (Join-Path $modules $file)
            $declared=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Name})
            Expect ((@($entry[0].Functions) -join ',') -eq ($declared -join ',')) ('Fonctions declarees differentes : '+$file)
        }
        $ui=@($plan|Where-Object{$_.File -eq 'Domenia-AdAudit.UI.ps1'})[0]
        foreach($need in @('Domenia-AdAudit.Model.ps1','Domenia-AdAudit.Worker.ps1','Domenia-Engine.UI.ps1')){Expect (@($ui.Requires) -contains $need) ('Dependance absente : '+$need)}
        Expect (@(@($plan|Where-Object{$_.File -eq 'Domenia-AdAudit.Model.ps1'})[0].Requires) -contains 'Domenia-Directory.Model.ps1')
    }
    Case 'Classification : chaque operation de l audit est une lecture avec son fournisseur et ses comptes' {
        foreach($operation in $script:AuditOperations){Expect ((Get-DomeniaOperationEffect $operation) -eq 'Read') ('Pas une lecture : '+$operation)}
        foreach($operation in @('GpoAppliedRead','MachineIdentityRead','DcServicesRead')){
            Expect ((Get-DomeniaOperationProvider $operation) -eq 'Cim') $operation
            $needs=Get-DomeniaOperationCredentialNeeds $operation
            Expect ($needs.Machine -and $needs.Remote -and (-not $needs.Directory) -and (-not $needs.DirectoryBreaker) -and ($needs.Resource -eq 'Remote')) ('Comptes : '+$operation)
            # A replacement account entered after a refusal goes to the machine channel these workers use.
            Expect ((Get-DomeniaAccessScope $operation) -eq 'Remote') ('Portee du compte de remplacement : '+$operation+' -> '+(Get-DomeniaAccessScope $operation))
        }
        $history=Get-DomeniaOperationCredentialNeeds 'RelationHistoryRead'
        Expect ((Get-DomeniaOperationProvider 'RelationHistoryRead') -eq 'Storage' -and $history.NonDirectory -and (-not $history.DirectoryCredential) -and ($history.Resource -eq 'Local'))
        foreach($operation in @('PasswordPolicyRead','GroupPathRead','DelegationRead','GpoLinksRead','AdHealthRead','AdConsistencyScan')){
            $needs=Get-DomeniaOperationCredentialNeeds $operation
            Expect (((Get-DomeniaOperationProvider $operation) -eq 'Directory') -and $needs.Directory -and $needs.DirectoryCredential -and (-not $needs.Remote)) ('Annuaire : '+$operation)
            Expect ((Get-DomeniaAccessScope $operation) -eq ('AD:'+$operation)) ('Portee annuaire : '+$operation)
            Expect ([bool](Get-DomeniaTaskDedupKey -OperationId $operation -ReaderIdentity 'r' -Payload ([pscustomobject]@{Dn='x'}))) ('Lecture non partageable : '+$operation)
        }
    }
    Case 'Corps epingles : analyses, sans attribut secret ni verbe d ecriture' {
        foreach($pair in $script:WorkerFunctions.GetEnumerator()){
            $code=& $pair.Value
            $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors)
            Expect (@($errors).Count -eq 0) ($pair.Key+' : '+$(if(@($errors).Count){$errors[0].Message}else{''}))
            # Comments may name what is NOT done (no gpresult...): only the executable lines are inspected.
            $body=(@($code -split "`n"|Where-Object{$_.TrimStart() -notmatch '^#'}) -join "`n")
            Expect (-not ($body -match '(?i)unicodePwd|userPassword|ms-Mcs-AdmPwd|msLAPS-Password|msLAPS-Encrypted|msFVE-RecoveryPassword|supplementalCredentials')) ('Attribut secret : '+$pair.Key)
            Expect (-not ($body -match '(?i)CommitChanges|\.Put\(|\.Invoke\(|Invoke-CimMethod|Set-CimInstance|Remove-(?!WDomeniaCimSession)|Set-AD|New-AD|Start-Service|Stop-Service|Restart-|gpupdate|gpresult|repadmin|dcdiag')) ('Verbe d ecriture ou commande : '+$pair.Key)
        }
    }
    Case 'Gardes des corps : refus avant tout appel reseau' {
        $Context=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';PortTimeoutMs=1000}
        $refused=@(
            @('GpoLinksRead',[pscustomobject]@{Containers=@('OU=X,DC=autre,DC=invalid')},'hors du domaine'),
            @('AdConsistencyScan',[pscustomobject]@{BaseDn='DC=example,DC=invalid';Subtree=$true;Limit=5000},'domaine entier'),
            @('AdConsistencyScan',[pscustomobject]@{BaseDn='OU=X,DC=autre,DC=invalid';Subtree=$false;Limit=5000},'hors du domaine'),
            @('AdHealthRead',[pscustomobject]@{Action='Probe';Dcs=@(1..11|ForEach-Object{'dc'+$_+'.example.invalid'})},'1 à 10'),
            @('AdHealthRead',[pscustomobject]@{Action='Probe';Dcs=@('dc1;calc')},'invalide'),
            @('DcServicesRead',[pscustomobject]@{Dcs=@()},'1 à 10'),
            @('DelegationRead',[pscustomobject]@{Action='Token';Sid='S-1-1-0'},'SID de bénéficiaire invalide'),
            @('DelegationRead',[pscustomobject]@{Action='Ecrire'},'inconnue'),
            @('GpoAppliedRead',[pscustomobject]@{Computer='pc 01'},'invalide'),
            @('MachineIdentityRead',[pscustomobject]@{Name='';DnsHostName='a b'},'invalide'),
            @('GroupPathRead',[pscustomobject]@{Dn='CN=X';Mode='Confirm';TargetDn=''},'cible absent'),
            @('PasswordPolicyRead',[pscustomobject]@{Dn=''},'invalide'),
            @('RelationHistoryRead',[pscustomobject]@{Kind='Autre';Key='x'},'sujet inconnu')
        )
        foreach($case in $refused){
            $Payload=$case[1];$message=''
            try{& ([scriptblock]::Create((& $script:WorkerFunctions[$case[0]])))|Out-Null}catch{$message=$_.Exception.Message}
            Expect ($message -match [regex]::Escape($case[2])) ($case[0]+' : '+$message)
        }
        $Payload=[pscustomobject]@{Kind='User';Key='jdupont';Limit=200;Path=(Join-Path ([IO.Path]::GetTempPath()) ('absent-'+[guid]::NewGuid().ToString('N')+'.db'));BusyTimeoutMs=250}
        $missing=& ([scriptblock]::Create((Get-DomeniaRelationHistoryReadWorkerCode)))
        Expect ($missing.Missing -and @($missing.Rows).Count -eq 0) 'Base absente : aucune ligne inventee'
    }
    Case 'XAML principal : onglet Audit AD nomme, aide egale a l infobulle, raccorde par Wire-Events' {
        [xml]$main=Get-MainXaml
        $tab=@($main.SelectNodes('//*[local-name()="TabItem"]')|Where-Object{$_.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq 'WsAdAudit'})
        Expect ($tab.Count -eq 1) 'Onglet WsAdAudit absent'
        $tip=[string](Get-TestCatalogueHelp $tab[0] 'ToolTip')
        Expect ($tip -and ($tip -ceq [string](Get-TestCatalogueHelp $tab[0] 'AutomationProperties.HelpText')) -and [string]$tab[0].GetAttribute('AutomationProperties.Name'))
        Expect ([string]$tab[0].ParentNode.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml') -eq 'ApplicationToolTabs') 'Onglet hors des outils'
        $help=@($script:Help|Where-Object{$_.Name -eq 'WsAdAudit'})
        Expect ($help.Count -eq 1 -and ([string]$help[0].Text -ceq $tip)) 'Aide de l onglet'
        Expect ($script:CoreText.Contains('"WsAdAudit" = "Default"')) 'Politique GUI absente'
        Expect ((Get-FunctionText $script:CoreAst 'Wire-Events') -match 'Register-DomeniaAdAuditTool') 'Wire-Events ne raccorde pas l audit'
    }
    Case 'Vue XAML : chargee par WPF, controles trouves, evenements raccordes, aide egale aux infobulles' {
        $script:Ctrl=@{};$script:AdAuditView=$null
        $script:Tasks=[Collections.Generic.List[object]]::new();$script:Statuses=[Collections.Generic.List[string]]::new();$script:Confirmations=[Collections.Generic.List[string]]::new()
        $tabItem=New-Object Windows.Controls.TabItem;$tabItem.Name='WsAdAudit';$script:Ctrl['WsAdAudit']=$tabItem
        $script:SessionEpoch=5L;$script:SelectedObject=$null;$script:SelectedObjectGeneration=0L
        $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';User='EXAMPLE\lecteur'};$script:SelectedBranchDn=''
        Show-DomeniaAdAuditTool
        Expect ($null -ne $script:AdAuditView -and [object]::ReferenceEquals($tabItem.Content,$script:AdAuditView)) 'Vue non posee dans l onglet'
        [xml]$document=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-AdAudit.xaml'),[Text.Encoding]::UTF8)
        $x='http://schemas.microsoft.com/winfx/2006/xaml'
        foreach($element in $document.SelectNodes('//*')){
            $name=$element.GetAttribute('Name',$x)
            if(-not $name){continue}
            Expect ($script:Ctrl.ContainsKey($name)) ('Controle non enregistre : '+$name)
            $tip=(Get-TestCatalogueHelp $element 'ToolTip')
            if($tip){
                Expect ($tip -ceq (Get-TestCatalogueHelp $element 'AutomationProperties.HelpText')) ('Infobulle et aide divergent : '+$name)
                $entry=@($script:Help|Where-Object{$_.Name -eq $name})
                Expect ($entry.Count -eq 1 -and ([string]$entry[0].Text -ceq $tip)) ('Aide absente ou differente : '+$name)
            }
        }
        foreach($grid in @($document.SelectNodes('//*[local-name()="DataGrid"]'))){Expect ($grid.GetAttribute('IsReadOnly') -eq 'True' -and $grid.GetAttribute('EnableRowVirtualization') -eq 'True') ('Grille modifiable ou non virtualisee : '+$grid.GetAttribute('Name',$x))}
        Expect ($script:Ctrl.LblAdAuditTarget.Text -match 'Aucun objet') $script:Ctrl.LblAdAuditTarget.Text
        Expect (-not $script:Ctrl.BtnAdAuditPolicy.IsEnabled) 'Lecture proposee sans objet'
    }
    Case 'Mot de passe : lecture explicite d un utilisateur, refusee pour un poste, rappel applique a sa cible seulement' {
        Reset-AuditFixture
        Select-AuditObject
        Expect ($script:Ctrl.LblAdAuditTarget.Text -match 'Utilisateur · Jean Dupont') $script:Ctrl.LblAdAuditTarget.Text
        Start-DomeniaAdAuditPolicyRead
        $task=Get-LastTask
        Expect ($task.OperationId -eq 'PasswordPolicyRead' -and $task.Code -ceq (Get-DomeniaPasswordPolicyReadWorkerCode) -and $task.TaskClass -eq 'Explicit' -and $task.Payload.Dn -eq 'CN=Jean Dupont,OU=Support,DC=example,DC=invalid' -and ($task.Disable -contains 'BtnAdAuditPolicy'))
        $read=[pscustomobject]@{Dn=$task.Payload.Dn;User=@{userAccountControl='512';pwdLastSet=[datetime]::UtcNow.AddDays(-3).ToFileTimeUtc()};ResultantPso='';Pso=$null;PsoVisibleCount=2;Domain=@{minPwdLength='12';maxPwdAge=-36288000000000L};Server='dc1.example.invalid';ObservedUtc=[datetime]::UtcNow.ToString('o')}
        Complete-DomeniaAdAuditPolicyRead $read $task.State
        Expect (@($script:Ctrl.DgAdAuditPolicy.ItemsSource).Count -ge 4) 'Grille vide'
        Expect ($script:Ctrl.LblAdAuditPolicy.Text -match 'domaine sʼapplique' -and $script:Ctrl.LblAdAuditPolicy.Text -match 'Aucun mot de passe nʼest lu') $script:Ctrl.LblAdAuditPolicy.Text
        Select-AuditObject -Type 'Machine' -Name 'PC-01' -Dn 'CN=PC-01,OU=Postes,DC=example,DC=invalid' -Sam 'PC-01$' -Dns 'pc-01.example.invalid'
        Expect (@($script:Ctrl.DgAdAuditPolicy.ItemsSource).Count -eq 0) 'Resultat de l ancienne cible conserve'
        Complete-DomeniaAdAuditPolicyRead $read $task.State
        Expect (@($script:Ctrl.DgAdAuditPolicy.ItemsSource).Count -eq 0) 'Rappel d une autre fiche applique'
        $count=$script:Tasks.Count
        Start-DomeniaAdAuditPolicyRead
        Expect ($script:Tasks.Count -eq $count -and $script:Ctrl.LblAdAuditPolicy.Text -match 'compte utilisateur') 'Lecture lancee pour un poste'
        Expect (-not $script:Ctrl.BtnAdAuditPolicy.IsEnabled -and $script:Ctrl.BtnAdAuditGpoApplied.IsEnabled -and $script:Ctrl.BtnAdAuditMachineIdentity.IsEnabled)
        $script:SessionEpoch=6L
        Sync-DomeniaAdAuditTarget
        Expect ([long]$script:AdAuditData.Epoch -eq 6L) 'Nouvelle session : donnees non remises a zero'
    }
    Case 'Groupes : lecture bornee, choix d un groupe, chemin et confirmation par le controleur' {
        Reset-AuditFixture;Select-AuditObject
        Start-DomeniaAdAuditGroupRead
        $task=Get-LastTask
        Expect ($task.OperationId -eq 'GroupPathRead' -and $task.Payload.Mode -eq 'Expand' -and $task.Payload.MaxNodes -eq 2000 -and $task.Payload.MaxDepth -eq 16 -and $task.Payload.Seconds -eq 10)
        $dn=$task.Payload.Dn
        $read=[pscustomobject]@{Dn=$dn;StartParents=@('CN=G1,DC=example,DC=invalid');StartComplete=$true;Nodes=@([pscustomobject]@{Dn='CN=G1,DC=example,DC=invalid';Name='G1';Parents=@('CN=G2,DC=example,DC=invalid')},[pscustomobject]@{Dn='CN=G2,DC=example,DC=invalid';Name='G2';Parents=@()});Unread=@();Truncated=$false;PrimaryGroup=[pscustomobject]@{Sid='S-1-5-21-1000-2000-3000-513';Dn='CN=Domain Users,CN=Users,DC=example,DC=invalid';Name='Domain Users'};Server='dc1';ObservedUtc=[datetime]::UtcNow.ToString('o');ElapsedMs=12}
        Complete-DomeniaAdAuditGroupRead $read $task.State
        Expect (@($script:Ctrl.DgAdAuditGroups.ItemsSource).Count -eq 2 -and @($script:Ctrl.CmbAdAuditGroupTarget.ItemsSource).Count -eq 3) 'Groupes ou choix absents (groupe principal compris)'
        Expect ($script:Ctrl.BtnAdAuditGroupConfirm.IsEnabled)
        $script:Ctrl.CmbAdAuditGroupTarget.SelectedItem=@($script:Ctrl.CmbAdAuditGroupTarget.ItemsSource|Where-Object{$_.Groupe -eq 'G2'})[0]
        Update-DomeniaAdAuditGroupPath
        Expect ($script:Ctrl.LblAdAuditGroupPath.Text -match 'Jean Dupont → G1 → G2') $script:Ctrl.LblAdAuditGroupPath.Text
        Start-DomeniaAdAuditGroupConfirm
        $confirm=Get-LastTask
        Expect ($confirm.Payload.Mode -eq 'Confirm' -and $confirm.Payload.TargetDn -eq 'CN=G2,DC=example,DC=invalid' -and $confirm.ReplaceKey -eq 'adaudit-group-confirm')
        Complete-DomeniaAdAuditGroupConfirm ([pscustomobject]@{Dn=$dn;TargetDn='CN=G2,DC=example,DC=invalid';ServerAnswer=$true;ServerError=''}) $confirm.State
        Expect ($script:Ctrl.LblAdAuditGroupPath.Text -match 'confirmé par le contrôleur') $script:Ctrl.LblAdAuditGroupPath.Text
        # A failure arriving after another group was chosen is not written under that group.
        Start-DomeniaAdAuditGroupConfirm
        $again=Get-LastTask
        $script:Ctrl.CmbAdAuditGroupTarget.SelectedItem=@($script:Ctrl.CmbAdAuditGroupTarget.ItemsSource|Where-Object{$_.Groupe -eq 'G1'})[0]
        Update-DomeniaAdAuditGroupPath
        $shown=$script:Ctrl.LblAdAuditGroupPath.Text
        Fail-DomeniaAdAuditGroupConfirm 'Serveur injoignable' $again.State
        Expect (($script:Ctrl.LblAdAuditGroupPath.Text -eq $shown) -and ($shown -notmatch 'Confirmation du contrôleur impossible')) 'Echec affiche sous un groupe non demande'
        $script:Ctrl.CmbAdAuditGroupTarget.SelectedItem=@($script:Ctrl.CmbAdAuditGroupTarget.ItemsSource|Where-Object{$_.Groupe -eq 'G2'})[0]
        Fail-DomeniaAdAuditGroupConfirm 'Serveur injoignable' $again.State
        Expect ($script:Ctrl.LblAdAuditGroupPath.Text -match 'Confirmation du contrôleur impossible : Serveur injoignable') $script:Ctrl.LblAdAuditGroupPath.Text
    }
    Case 'Delegations : liste lue, filtre local, estimation sans puis avec les groupes du beneficiaire' {
        Reset-AuditFixture;Select-AuditObject
        Start-DomeniaAdAuditAclRead
        $task=Get-LastTask
        Expect ($task.OperationId -eq 'DelegationRead' -and $task.Payload.Action -eq 'Acl' -and $task.Payload.MaxAces -eq 1000)
        $acl=[pscustomobject]@{Action='Acl';Dn=$task.Payload.Dn;State='Read';Total=2;Truncated=$false;MaxAces=1000;OwnerSid='S-1-5-21-1000-2000-3000-512';SidNames=@{'S-1-5-21-1000-2000-3000-1500'='GG-Support'};GuidNames=@{};Server='dc1';ObservedUtc=[datetime]::UtcNow.ToString('o');Aces=@(
            [pscustomobject]@{Sid='S-1-5-21-1000-2000-3000-1500';AccessControlType='Allow';ActiveDirectoryRights='ExtendedRight';ObjectType='00299570-246d-11d0-a768-00aa006e0529';InheritedObjectType='';IsInherited=$false;InheritanceType='None'}
            [pscustomobject]@{Sid='S-1-5-21-1000-2000-3000-1700';AccessControlType='Allow';ActiveDirectoryRights='WriteDacl';ObjectType='';InheritedObjectType='';IsInherited=$true;InheritanceType='All'})}
        Complete-DomeniaAdAuditAclRead $acl $task.State
        Expect (@($script:Ctrl.DgAdAuditAcl.ItemsSource).Count -eq 2) 'Entrees absentes'
        $script:Ctrl.ChkAdAuditAclExplicit.IsChecked=$true;Update-DomeniaAdAuditAclGrid
        Expect (@($script:Ctrl.DgAdAuditAcl.ItemsSource).Count -eq 1) 'Filtre explicite'
        $script:Ctrl.DgAdAuditAcl.SelectedItem=@($script:Ctrl.DgAdAuditAcl.ItemsSource)[0];Update-DomeniaAdAuditEstimate
        Expect (@($script:Ctrl.DgAdAuditAclEstimate.ItemsSource).Count -eq 9 -and $script:Ctrl.LblAdAuditAclEstimate.Text -match 'Groupes du bénéficiaire non lus')
        Expect ($script:Ctrl.BtnAdAuditAclToken.IsEnabled) 'Lecture des groupes non proposee pour un compte du domaine'
        Start-DomeniaAdAuditTokenRead
        $token=Get-LastTask
        Expect ($token.Payload.Action -eq 'Token' -and $token.Payload.Sid -eq 'S-1-5-21-1000-2000-3000-1500')
        Complete-DomeniaAdAuditTokenRead ([pscustomobject]@{Action='Token';Sid='S-1-5-21-1000-2000-3000-1500';State='Read';GroupSids=@('S-1-5-21-1000-2000-3000-1700');Name='GG-Support'}) $token.State
        $dacl=@($script:Ctrl.DgAdAuditAclEstimate.ItemsSource|Where-Object{$_.Droit -eq 'Modifier les autorisations'})[0]
        Expect ($dacl.Resultat -eq 'Autorisé' -and $script:Ctrl.LblAdAuditAclEstimate.Text -match 'tokenGroups') 'Groupes du beneficiaire non comptes'
    }
    Case 'GPO : chaine de conteneurs envoyee, resultat du poste lu a part, echec RSoP non confondu avec une absence' {
        Reset-AuditFixture;Select-AuditObject -Type 'Machine' -Name 'PC-01' -Dn 'CN=PC-01,OU=Postes,DC=example,DC=invalid' -Sam 'PC-01$' -Dns 'pc-01.example.invalid'
        Start-DomeniaAdAuditGpoLinks
        $links=Get-LastTask
        Expect ($links.OperationId -eq 'GpoLinksRead' -and ((@($links.Payload.Containers) -join '|') -eq 'OU=Postes,DC=example,DC=invalid|DC=example,DC=invalid'))
        Complete-DomeniaAdAuditGpoLinks ([pscustomobject]@{Containers=@([pscustomobject]@{Dn='OU=Postes,DC=example,DC=invalid';GpLink='[LDAP://cn={aaaaaaaa-1111-4111-8111-111111111111},cn=policies,cn=system,DC=example,DC=invalid;0]';GpOptions=0;ReadStatus='OK'});Gpos=@();NamesStatus='OK'}) $links.State
        Expect (@($script:Ctrl.DgAdAuditGpo.ItemsSource).Count -eq 1 -and $script:Ctrl.LblAdAuditGpo.Text -match 'non lu') $script:Ctrl.LblAdAuditGpo.Text
        Start-DomeniaAdAuditGpoApplied
        $rsop=Get-LastTask
        Expect ($rsop.OperationId -eq 'GpoAppliedRead' -and $rsop.Payload.Computer -eq 'pc-01.example.invalid')
        Fail-DomeniaAdAuditGpoApplied 'Accès refusé' $rsop.State
        Expect ((@($script:Ctrl.DgAdAuditGpo.ItemsSource)[0].Resultat) -match 'injoignable|refusée') 'Echec RSoP presente comme une absence'
        Expect ($script:Ctrl.LblAdAuditGpo.Text -match 'non obtenu') $script:Ctrl.LblAdAuditGpo.Text
    }
    Case 'Poste : identite comparee sans attribution, historique local borne et vue en trois lignes' {
        Reset-AuditFixture
        $script:Links=@([pscustomobject]@{UserLogin='jdupont';Computer='PC-01';Source='Saisie manuelle';When='2026-09-01T08:00:00Z';ComputerGuid='11111111-1111-4111-8111-111111111111'},[pscustomobject]@{UserLogin='autre';Computer='PC-01';Source='Console CIM/DCOM';When='2026-10-01T08:00:00Z';ComputerGuid='99999999-9999-4999-8999-999999999999'})
        Select-AuditObject -Type 'Machine' -Name 'PC-01' -Dn 'CN=PC-01,OU=Postes,DC=example,DC=invalid' -Sam 'PC-01$' -Dns 'pc-01.example.invalid'
        Expect ($script:Ctrl.LblAdAuditRelationOverview.Text -match 'Affectation déclarée : jdupont' -and $script:Ctrl.LblAdAuditRelationOverview.Text -match 'Aucune session observée') 'Une relation d un autre GUID a ete reprise'
        Start-DomeniaAdAuditMachineIdentity
        $identity=Get-LastTask
        Expect ($identity.OperationId -eq 'MachineIdentityRead' -and $identity.Payload.DnsHostName -eq 'pc-01.example.invalid')
        Complete-DomeniaAdAuditMachineIdentity ([pscustomobject]@{Name='pc-01.example.invalid';Resolution=[pscustomobject]@{Status='OK';Addresses=@('192.0.2.10');PtrName=''};Reported=[pscustomobject]@{Status='OK';ComputerName='PC-02';DnsHostName='';Domain='example.invalid'};ObservedUtc=[datetime]::UtcNow.ToString('o')}) $identity.State
        Expect ($script:Ctrl.LblAdAuditMachineIdentity.Text -match 'Identité incohérente' -and $script:Ctrl.LblAdAuditMachineIdentity.Text -match 'Rien nʼest attribué') $script:Ctrl.LblAdAuditMachineIdentity.Text
        Start-DomeniaAdAuditHistoryRead
        $history=Get-LastTask
        Expect ($history.OperationId -eq 'RelationHistoryRead' -and $history.Payload.Kind -eq 'Computer' -and $history.Payload.Key -eq 'PC-01' -and $history.Payload.Limit -eq 200 -and $history.Payload.Path -eq 'C:\Fixture\Domenia.db')
        Complete-DomeniaAdAuditHistoryRead ([pscustomobject]@{Rows=@([pscustomobject]@{user_login='jdupont';computer='PC-01';source='Registre LogonUI';verified_in_ad=1;observed_at='2026-08-01T08:00:00Z';details=''});Total=7;Busy=$false;Missing=$false;Kind='Computer';Key='PC-01'}) $history.State
        Expect (@($script:Ctrl.DgAdAuditHistory.ItemsSource).Count -eq 1 -and $script:Ctrl.LblAdAuditHistory.Text -match '1 ligne\(s\) affichée\(s\) sur 7') $script:Ctrl.LblAdAuditHistory.Text
        Expect (@($script:Ctrl.DgAdAuditHistory.ItemsSource)[0].Nature -eq 'Historique')
        $script:DatabasePath='';Start-DomeniaAdAuditHistoryRead
        Expect ($script:Ctrl.LblAdAuditHistory.Text -match 'non configurée' -and (Get-LastTask).OperationId -eq 'RelationHistoryRead' -and $script:Tasks.Count -eq 2) 'Lecture sans base locale'
    }
    Case 'Controleurs : liste, choix borne a 10, sonde privilegiee seulement apres confirmation' {
        Reset-AuditFixture
        Start-DomeniaAdAuditDcList
        $list=Get-LastTask
        Expect ($list.OperationId -eq 'AdHealthRead' -and $list.Payload.Action -eq 'List')
        $dcs=@(1..12|ForEach-Object{[pscustomobject]@{Name=('DC'+$_);DnsHostName=('dc'+$_+'.example.invalid');Os='Windows Server 2022';Site='Paris';ReadOnly=($_ -eq 12);Dn=('CN=DC'+$_+',OU=Domain Controllers,DC=example,DC=invalid')}})
        Complete-DomeniaAdAuditDcList ([pscustomobject]@{Action='List';Dcs=$dcs;Truncated=$false;Pdc='dc1.example.invalid';PdcError=''}) $list.State
        $rows=@($script:Ctrl.DgAdAuditDcList.ItemsSource)
        Expect ($rows.Count -eq 12 -and $rows[0].Role -eq 'Émulateur PDC' -and $rows[11].Role -eq 'Lecture seule (RODC)')
        $script:Ctrl.DgAdAuditDcList.SelectedItems=@($rows[0..10]);Start-DomeniaAdAuditDcProbe
        Expect ((Get-LastTask).Payload.Action -eq 'List' -and $script:Ctrl.LblAdAuditDc.Text -match 'borné à 10') 'Plus de 10 controleurs sondes'
        $script:Ctrl.DgAdAuditDcList.SelectedItems=@($rows[0],$rows[2]);Start-DomeniaAdAuditDcProbe
        $probe=Get-LastTask
        Expect ($probe.Payload.Action -eq 'Probe' -and (@($probe.Payload.Dcs) -join ',') -eq 'dc1.example.invalid,dc3.example.invalid' -and $probe.Payload.DomainDns -eq 'example.invalid' -and $probe.Payload.Pdc -eq 'dc1.example.invalid')
        $now=[datetime]::UtcNow
        Complete-DomeniaAdAuditDcProbe ([pscustomobject]@{Action='Probe';SrvState='ModuleMissing';Srv=@();Pdc='dc1.example.invalid';ObservedUtc=$now.ToString('o');Results=@([pscustomobject]@{Dc='dc1.example.invalid';Ldap=$false;Kerberos=$false;RootDse='NotRead';Addresses=@()})}) $probe.State
        Expect (@($script:Ctrl.DgAdAuditHealth.ItemsSource)[0].Verdict -eq 'Non lu')
        $count=$script:Tasks.Count;$script:ConfirmAnswer=$false;Start-DomeniaAdAuditDcServices
        Expect ($script:Tasks.Count -eq $count -and $script:Confirmations.Count -eq 1) 'Sonde privilegiee lancee sans accord'
        $script:ConfirmAnswer=$true;Start-DomeniaAdAuditDcServices
        $services=Get-LastTask
        Expect ($services.OperationId -eq 'DcServicesRead' -and @($services.Payload.Dcs).Count -eq 2)
        # The worker keeps 20 s below a timeout sized by the number of controllers, on its own resource.
        Expect (($services.Timeout -eq 110) -and ([int]$services.Payload.BudgetSeconds -eq 90) -and ([string]$services.Payload.Target -eq 'adaudit-dc-services')) ('Budget : '+[string]$services.Timeout+' / '+[string]$services.Payload.BudgetSeconds)
        Complete-DomeniaAdAuditDcServices ([pscustomobject]@{Results=@([pscustomobject]@{Dc='dc1.example.invalid';State='Refused';Message='Accès refusé';Services=@()},[pscustomobject]@{Dc='dc3.example.invalid';State='NotRead';Message='Budget de temps épuisé (90 s) : contrôleur non interrogé, relancez la lecture pour lui seul.';Services=@()});ObservedUtc=$now.ToString('o')}) $services.State
        Expect (@($script:Ctrl.DgAdAuditServices.ItemsSource).Count -eq 2 -and $script:Ctrl.AdAuditDcResultTabs.SelectedItem.Name -eq 'TabAdAuditDcServices')
        Expect ($script:Ctrl.LblAdAuditDc.Text -match '1 contrôleur\(s\) non interrogé\(s\)') $script:Ctrl.LblAdAuditDc.Text
        # A services read started during a probe does not discard the probe, and the reverse.
        Start-DomeniaAdAuditDcProbe;$probe2=Get-LastTask
        Start-DomeniaAdAuditDcServices;$services2=Get-LastTask
        Expect ($probe2.OperationId -eq 'AdHealthRead' -and $services2.OperationId -eq 'DcServicesRead')
        $script:Ctrl.DgAdAuditHealth.ItemsSource=@()
        Complete-DomeniaAdAuditDcProbe ([pscustomobject]@{Action='Probe';SrvState='ModuleMissing';Srv=@();Pdc='dc1.example.invalid';ObservedUtc=$now.ToString('o');Results=@([pscustomobject]@{Dc='dc3.example.invalid';Ldap=$false;Kerberos=$false;RootDse='NotRead';Addresses=@()})}) $probe2.State
        Expect ((@($script:Ctrl.DgAdAuditHealth.ItemsSource).Count -eq 1) -and (@($script:Ctrl.DgAdAuditHealth.ItemsSource)[0].Controleur -eq 'dc3.example.invalid')) 'Diagnostic jete par la lecture des services'
        $script:Ctrl.DgAdAuditServices.ItemsSource=@()
        Complete-DomeniaAdAuditDcServices ([pscustomobject]@{Results=@([pscustomobject]@{Dc='dc3.example.invalid';State='Refused';Message='Accès refusé';Services=@()});ObservedUtc=$now.ToString('o')}) $services2.State
        Expect (@($script:Ctrl.DgAdAuditServices.ItemsSource).Count -eq 1) 'Services jetes par le diagnostic'
        Start-DomeniaAdAuditDcServices;$services3=Get-LastTask
        Start-DomeniaAdAuditDcProbe;$probe3=Get-LastTask
        $script:Ctrl.DgAdAuditServices.ItemsSource=@()
        Complete-DomeniaAdAuditDcServices ([pscustomobject]@{Results=@([pscustomobject]@{Dc='dc1.example.invalid';State='Refused';Message='Accès refusé';Services=@()});ObservedUtc=$now.ToString('o')}) $services3.State
        Expect (@($script:Ctrl.DgAdAuditServices.ItemsSource).Count -eq 1) 'Services jetes par un diagnostic lance ensuite'
        # Within one kind, only the latest request is applied.
        $script:Ctrl.DgAdAuditServices.ItemsSource=@()
        Complete-DomeniaAdAuditDcServices ([pscustomobject]@{Results=@([pscustomobject]@{Dc='dc1.example.invalid';State='Refused';Message='Accès refusé';Services=@()});ObservedUtc=$now.ToString('o')}) $services2.State
        Expect (@($script:Ctrl.DgAdAuditServices.ItemsSource).Count -eq 0) 'Ancienne lecture des services appliquee apres une plus recente'
        Start-DomeniaAdAuditDcList
        Complete-DomeniaAdAuditDcList ([pscustomobject]@{Action='List';Dcs=@();Pdc=''}) $list.State
        Expect (@($script:Ctrl.DgAdAuditDcList.ItemsSource).Count -eq 12) 'Ancienne liste appliquee apres une demande plus recente'
    }
    Case 'Identites : OU obligatoire, domaine entier refuse, noms compares a la base locale' {
        Reset-AuditFixture
        Start-DomeniaAdAuditScan
        Expect ($script:Tasks.Count -eq 0 -and $script:Ctrl.LblAdAuditScan.Text -match 'Choisissez dʼabord une OU')
        $script:SelectedBranchDn='DC=example,DC=invalid';$script:Ctrl.ChkAdAuditScanSubtree.IsChecked=$true;Start-DomeniaAdAuditScan
        Expect ($script:Tasks.Count -eq 0 -and $script:Ctrl.LblAdAuditScan.Text -match 'domaine entier') 'Domaine entier analyse'
        $script:SelectedBranchDn='OU=Support,DC=example,DC=invalid';Start-DomeniaAdAuditScan
        $scan=Get-LastTask
        Expect ($scan.OperationId -eq 'AdConsistencyScan' -and $scan.Payload.BaseDn -eq 'OU=Support,DC=example,DC=invalid' -and $scan.Payload.Subtree -and $scan.Payload.Limit -eq 5000)
        Expect ($script:Ctrl.LblAdAuditScope.Text -match 'Support') $script:Ctrl.LblAdAuditScope.Text
        $rows=@([pscustomobject]@{Guid='33333333-3333-4333-8333-333333333333';Name='PC-01';Sam='PC-01$';Type='Machine';DnsHostName='pc-01.example.invalid';Uac='4096';Dn='CN=PC-01,OU=Support,DC=example,DC=invalid'})
        Complete-DomeniaAdAuditScan ([pscustomobject]@{BaseDn='OU=Support,DC=example,DC=invalid';Rows=$rows;Truncated=$false;Limit=5000;Server='dc1';ObservedUtc=[datetime]::UtcNow.ToString('o')}) $scan.State
        $index=Get-LastTask
        Expect ($index.OperationId -eq 'LocalIndexRead' -and $index.Payload.Action -eq 'ResolveNames' -and (@($index.Payload.Computers) -join ',') -eq 'PC-01') 'Base locale non consultee'
        Expect ($script:Ctrl.LblAdAuditScan.Text -match 'non consultée') $script:Ctrl.LblAdAuditScan.Text
        Complete-DomeniaAdAuditScanIndex ([pscustomobject]@{Busy=$false;Missing=$false;Users=@();Computers=@([pscustomobject]@{name='PC-01';login='PC-01$';object_guid='99999999-9999-4999-8999-999999999999'})}) $index.State
        Expect (@($script:Ctrl.DgAdAuditScan.ItemsSource|Where-Object{$_.Categorie -eq 'Nom recyclé ou objet recréé'}).Count -eq 1) 'Nom recycle non signale'
        Expect ($script:Ctrl.LblAdAuditScan.Text -match 'Noms comparés avec la base locale') $script:Ctrl.LblAdAuditScan.Text
        # A failed local read is not a busy base.
        Fail-DomeniaAdAuditScanIndex 'Délai dépassé' $index.State
        Expect (($script:Ctrl.LblAdAuditScan.Text -match 'Base locale non lue \(Délai dépassé\)') -and ($script:Ctrl.LblAdAuditScan.Text -notmatch 'occupée')) $script:Ctrl.LblAdAuditScan.Text
        # Beyond 1000 names of a kind, the view says how many were compared.
        Start-DomeniaAdAuditScan
        $big=Get-LastTask
        $many=@(1..1200|ForEach-Object{[pscustomobject]@{Guid=('{0:D8}-0000-4000-8000-000000000000' -f $_);Name=('PC-'+$_);Sam=('PC-'+$_+'$');Type='Machine';DnsHostName='';Uac='4096';Dn=('CN=PC-'+$_+',OU=Support,DC=example,DC=invalid')}})
        Complete-DomeniaAdAuditScan ([pscustomobject]@{BaseDn='OU=Support,DC=example,DC=invalid';Rows=$many;Truncated=$false;Limit=5000;Server='dc1';ObservedUtc=[datetime]::UtcNow.ToString('o')}) $big.State
        $bigIndex=Get-LastTask
        Expect (($bigIndex.OperationId -eq 'LocalIndexRead') -and (@($bigIndex.Payload.Computers).Count -eq 1000)) 'Lecture locale non bornee a 1000 noms'
        Complete-DomeniaAdAuditScanIndex ([pscustomobject]@{Busy=$false;Missing=$false;Users=@();Computers=@()}) $bigIndex.State
        Expect ($script:Ctrl.LblAdAuditScan.Text -match '1000 noms sur 1200 comparés') $script:Ctrl.LblAdAuditScan.Text
    }
    Case 'Relations : historique distinct dans la page, puce de filtre et synthese en trois lignes' {
        [xml]$main=Get-MainXaml
        $x='http://schemas.microsoft.com/winfx/2006/xaml'
        foreach($name in @('ChkAllLinksHistory','LblLinkOverview')){
            $node=@($main.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$x) -eq $name})
            Expect ($node.Count -eq 1) ('Controle absent : '+$name)
            $tip=[string](Get-TestCatalogueHelp $node[0] 'ToolTip')
            Expect ($tip -and ($tip -ceq [string](Get-TestCatalogueHelp $node[0] 'AutomationProperties.HelpText'))) ('Infobulle : '+$name)
            $entry=@($script:Help|Where-Object{$_.Name -eq $name});Expect ($entry.Count -eq 1 -and ([string]$entry[0].Text -ceq $tip)) ('Aide : '+$name)
            Expect ($script:CoreText.Contains('"'+$name+'" = "Default"')) ('Politique GUI : '+$name)
        }
        Expect (@($main.SelectNodes('//*[local-name()="DataTrigger"]')|Where-Object{$_.GetAttribute('Value') -eq 'Historique'}).Count -ge 2) 'Couleur du badge Historique absente'
        $relationsAst=Read-SourceAst (Join-Path $modules 'Domenia-Relations.UI.ps1')
        foreach($name in @('Get-DomeniaAllLinksBadgeFilter','Update-DomeniaLinkOverview')){. ([scriptblock]::Create((Get-FunctionText $relationsAst $name)))}
        Expect ((Get-FunctionText $relationsAst 'Refresh-DomeniaRelationViews') -match 'Update-DomeniaLinkOverview') 'Synthese non rafraichie avec la page'
        Expect ((Get-FunctionText $relationsAst 'Initialize-DomeniaRelationsUi') -match 'ChkAllLinksHistory') 'Puce Historique non raccordee'
        $script:Ctrl=@{ChkAllLinksDeclared=[pscustomobject]@{IsChecked=$false};ChkAllLinksObserved=[pscustomobject]@{IsChecked=$false};ChkAllLinksHistory=[pscustomobject]@{IsChecked=$true};ChkAllLinksConflict=[pscustomobject]@{IsChecked=$false};LblLinkOverview=[pscustomobject]@{Text='';Visibility='Collapsed'}}
        Expect ((@(Get-DomeniaAllLinksBadgeFilter) -join ',') -eq 'Historique')
        $rows=@([pscustomobject]@{UserLogin='jdupont';Computer='PC-01';Source='Saisie manuelle';When='2026-09-01T08:00:00Z'},[pscustomobject]@{UserLogin='ancien';Computer='PC-01';Source='Registre LogonUI';When='2026-08-01T08:00:00Z'})
        Update-DomeniaLinkOverview -Subject ([pscustomobject]@{Type='Machine';Name='PC-01'}) -Rows $rows
        Expect ($script:Ctrl.LblLinkOverview.Visibility -eq 'Visible' -and $script:Ctrl.LblLinkOverview.Text -match 'Affectation déclarée : jdupont' -and $script:Ctrl.LblLinkOverview.Text -match 'Historique : 1 relevé') $script:Ctrl.LblLinkOverview.Text
        Update-DomeniaLinkOverview -Subject $null -Rows @()
        Expect ($script:Ctrl.LblLinkOverview.Visibility -eq 'Collapsed' -and $script:Ctrl.LblLinkOverview.Text -eq '')
        Expect (Test-DomeniaRelationMatchesFilter ([pscustomobject]@{Badge='Historique';UserLogin='ancien'}) '' @('Historique'))
        Expect (-not (Test-DomeniaRelationMatchesFilter ([pscustomobject]@{Badge='Historique';UserLogin='ancien'}) '' @('Observe'))) 'L historique passe encore pour une observation'
    }
    Case 'Assistance : onglet, vue WPF et recettes proposees sans lecture' {
        [xml]$main=Get-MainXaml
        $x='http://schemas.microsoft.com/winfx/2006/xaml'
        $tab=@($main.SelectNodes('//*[local-name()="TabItem"]')|Where-Object{$_.GetAttribute('Name',$x) -eq 'WsAssistance'})
        Expect ($tab.Count -eq 1 -and ([string](Get-TestCatalogueHelp $tab[0] 'ToolTip') -ceq [string](Get-TestCatalogueHelp $tab[0] 'AutomationProperties.HelpText'))) 'Onglet Assistance'
        Expect (@($script:Help|Where-Object{($_.Name -eq 'WsAssistance') -and ([string]$_.Text -ceq [string](Get-TestCatalogueHelp $tab[0] 'ToolTip'))}).Count -eq 1) 'Aide de l onglet Assistance'
        Expect ($script:CoreText.Contains('"WsAssistance" = "Default"') -and ((Get-FunctionText $script:CoreAst 'Wire-Events') -match 'Register-DomeniaAssistanceTool')) 'Assistance non raccordee'
        $script:Ctrl=@{};$script:AssistanceView=$null;$script:AssistanceLaunched=@{};$script:SelectedObject=$null
        $tabItem=New-Object Windows.Controls.TabItem;$tabItem.Name='WsAssistance';$script:Ctrl['WsAssistance']=$tabItem
        Show-DomeniaAssistanceTool
        Expect ([object]::ReferenceEquals($tabItem.Content,$script:AssistanceView)) 'Vue non posee'
        Expect (@($script:Ctrl.CmbAssistanceRecipe.ItemsSource).Count -eq 4 -and $null -eq $script:Ctrl.CmbAssistanceRecipe.SelectedItem) 'Recettes absentes ou choisies a la place de l operateur'
        Expect (-not $script:Ctrl.BtnAssistanceRun.IsEnabled -and $script:Ctrl.LblAssistanceSubject.Text -match 'Aucune sélection')
        [xml]$document=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-Assistance.xaml'),[Text.Encoding]::UTF8)
        foreach($element in $document.SelectNodes('//*')){
            $name=$element.GetAttribute('Name',$x);if(-not $name){continue}
            Expect ($script:Ctrl.ContainsKey($name)) ('Controle non enregistre : '+$name)
            $tip=(Get-TestCatalogueHelp $element 'ToolTip')
            if($tip){$entry=@($script:Help|Where-Object{$_.Name -eq $name});Expect ($entry.Count -eq 1 -and ([string]$entry[0].Text -ceq $tip) -and ($tip -ceq (Get-TestCatalogueHelp $element 'AutomationProperties.HelpText'))) ('Aide : '+$name)}
        }
    }
    Case 'Assistance : une etape, un clic, une seule lecture, pour le bon sujet' {
        $script:Ctrl=@{
            CmbAssistanceRecipe=[pscustomobject]@{SelectedItem=$null;ItemsSource=$null};DgAssistanceSteps=New-FakeGrid
            LblAssistanceSubject=[pscustomobject]@{Text=''};LblAssistanceRecipe=[pscustomobject]@{Text=''};LblAssistanceStep=[pscustomobject]@{Text=''}
            BtnAssistanceRun=[pscustomobject]@{IsEnabled=$false};BtnAssistanceOpen=[pscustomobject]@{IsEnabled=$false}
            WsObject=[pscustomobject]@{Name='WsObject'};TabUser=[pscustomobject]@{Name='TabUser'};WsComputer=[pscustomobject]@{Name='WsComputer'};TabInventory=[pscustomobject]@{Name='TabInventory'}
            TabApplicationTools=[pscustomobject]@{Name='TabApplicationTools'};WsAdAudit=[pscustomobject]@{Name='WsAdAudit'}
        }
        $script:AssistanceView=[pscustomobject]@{Name='DomeniaAssistanceView'};$script:AssistanceLaunched=@{};$script:SessionEpoch=9L
        $script:Calls=[Collections.Generic.List[string]]::new()
        # Engine registry double: a dispatched read is a task of its operation, a shared read one more subscriber.
        $script:AsyncJobs=@{};$script:LockoutDispatch=$false
        function Add-FakeAssistanceJob {param([string]$OperationId);$script:AsyncJobs[('job-'+($script:AsyncJobs.Count+1))]=[pscustomobject]@{OperationId=$OperationId;Subscribers=(New-Object System.Collections.ArrayList)}}
        function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Calls.Add('route:'+$Workspace+'/'+$Inner+'/'+$Tab)}
        # Like the real read, the lockout read returns without dispatching when the fiche target is not loaded.
        function Start-DomeniaLockoutEventRead {$script:Calls.Add('lockouts');if($script:LockoutDispatch){Add-FakeAssistanceJob 'LockoutDiagnosis'}}
        function Start-DomeniaComputerInventory {param([switch]$Deep);$script:Calls.Add('inventory:'+[string][bool]$Deep);Add-FakeAssistanceJob 'ComputerInventory'}
        function Start-DomeniaAdAuditPolicyRead {
            $script:Calls.Add('policy')
            foreach($job in @($script:AsyncJobs.Values)){if($job.OperationId -eq 'PasswordPolicyRead'){[void]$job.Subscribers.Add('abonne');return}}
            Add-FakeAssistanceJob 'PasswordPolicyRead'
        }
        function Show-DomeniaAdAuditTool {$script:Calls.Add('audit-view')}
        $script:SelectedObject=[pscustomobject]@{DN='CN=Jean Dupont,OU=Support,DC=example,DC=invalid';Type='Utilisateur';Name='Jean Dupont'}
        $script:Ctrl.CmbAssistanceRecipe.SelectedItem=Get-DomeniaAssistanceRecipe 'logon'
        Update-DomeniaAssistanceView
        $rows=@($script:Ctrl.DgAssistanceSteps.ItemsSource)
        Expect ($rows.Count -eq 6 -and $script:Ctrl.LblAssistanceSubject.Text -eq 'Pour : Utilisateur · Jean Dupont' -and $script:Ctrl.LblAssistanceRecipe.Text -match 'Aucune étape ne part seule')
        Expect ($script:Calls.Count -eq 0) 'Le choix d une recette a lance une lecture'
        $script:Ctrl.DgAssistanceSteps.SelectedItem=$rows[1];Update-DomeniaAssistanceStepDetail
        Expect ($script:Ctrl.BtnAssistanceRun.IsEnabled) 'Etape du compte non proposee'
        Invoke-DomeniaAssistanceStep
        Expect (($script:Calls -join ',') -eq 'route:WsObject/DetailTabs/TabUser,lockouts') ($script:Calls -join ',')
        Expect (@($script:Ctrl.DgAssistanceSteps.ItemsSource)[1].State -eq 'À lancer') 'Etape marquee lancee alors que rien nʼest parti'
        Expect ($script:Ctrl.LblAssistanceStep.Text -match 'rien nʼa été lancé') $script:Ctrl.LblAssistanceStep.Text
        $script:Calls.Clear();$script:LockoutDispatch=$true
        Invoke-DomeniaAssistanceStep
        Expect (($script:Calls -join ',') -eq 'route:WsObject/DetailTabs/TabUser,lockouts') ($script:Calls -join ',')
        $after=@($script:Ctrl.DgAssistanceSteps.ItemsSource)
        Expect ($after[1].State -match '^Lancée à' -and $after[2].State -eq 'À lancer' -and [object]::ReferenceEquals($script:Ctrl.DgAssistanceSteps.SelectedItem,$after[1])) 'Etat ou selection perdus'
        Expect ($script:Ctrl.LblAssistanceStep.Text -match 'lecture demandée') $script:Ctrl.LblAssistanceStep.Text
        $script:Calls.Clear();$script:Ctrl.DgAssistanceSteps.SelectedItem=$after[3];Invoke-DomeniaAssistanceStep
        Expect ($script:Calls.Count -eq 0 -and $script:Ctrl.LblAssistanceStep.Text -eq 'Sélectionnez le poste concerné.') 'Etape du poste lancee pour un compte'
        # An identical read already running is joined: the step is launched without a second read.
        Add-FakeAssistanceJob 'PasswordPolicyRead'
        $script:Ctrl.DgAssistanceSteps.SelectedItem=$after[2];Invoke-DomeniaAssistanceStep
        Expect (($script:Calls -join ',') -eq 'route:TabApplicationTools/ApplicationToolTabs/WsAdAudit,audit-view,policy') ($script:Calls -join ',')
        Expect ((@($script:Ctrl.DgAssistanceSteps.ItemsSource)[2].State -match '^Lancée à') -and (@($script:AsyncJobs.Values|Where-Object{$_.OperationId -eq 'PasswordPolicyRead'}).Count -eq 1)) 'Lecture partagee non reconnue'
        $script:Calls.Clear();$script:Ctrl.DgAssistanceSteps.SelectedItem=$after[0];Open-DomeniaAssistanceStepView
        Expect (($script:Calls -join ',') -eq 'route:WsObject/DetailTabs/TabUser') 'Vue sans lecture'
        $script:Calls.Clear()
        $script:SelectedObject=[pscustomobject]@{DN='CN=PC-01,OU=Postes,DC=example,DC=invalid';Type='Machine';Name='PC-01'}
        $script:Ctrl.CmbAssistanceRecipe.SelectedItem=Get-DomeniaAssistanceRecipe 'slow';Update-DomeniaAssistanceView
        $slow=@($script:Ctrl.DgAssistanceSteps.ItemsSource)
        Expect (@($slow|Where-Object{$_.State -match '^Lancée'}).Count -eq 0) 'Etat d un autre sujet repris'
        $script:Ctrl.DgAssistanceSteps.SelectedItem=@($slow|Where-Object{$_.Id -eq 'deep'})[0];Invoke-DomeniaAssistanceStep
        Expect (($script:Calls -join ',') -eq 'route:WsComputer/ComputerTabs/TabInventory,inventory:True') ($script:Calls -join ',')
        # X04: the sessions moved into Assistance poste > Intervenir; the former tab name stays a known route (UX-21).
        $script:Calls.Clear()
        Expect (Open-DomeniaAssistanceRoute (@($slow|Where-Object{$_.Id -eq 'sessions'})[0].Step)) 'Vue des sessions refusee'
        Expect (($script:Calls -join ',') -eq 'route:WsComputer/ComputerTabs/TabSessions') ('Route des sessions perdue : '+($script:Calls -join ','))
        $forged=[pscustomobject]@{Id='x';Title='X';Step=[pscustomobject]@{Id='x';Subject='Machine';Action='Remove-Item';Arguments=@{};Workspace='WsComputer'};CanRun=$true;CanOpen=$true}
        $script:Ctrl.DgAssistanceSteps.SelectedItem=$forged;$message=''
        try{Invoke-DomeniaAssistanceStep}catch{$message=$_.Exception.Message}
        Expect ($message -match 'non autorisée') 'Action hors liste executee'
    }
    Case 'Copie : la vue affichee part dans le presse-papiers, sans relecture' {
        Reset-AuditFixture;Select-AuditObject
        $script:Ctrl['AdAuditTabs']=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabAdAuditObject'}}
        $script:Ctrl['AdAuditObjectTabs']=[pscustomobject]@{SelectedItem=[pscustomobject]@{Name='TabAdAuditPolicy'}}
        $script:Ctrl.LblAdAuditPolicy.Text='Résumé de test'
        $script:Ctrl.DgAdAuditPolicy.Columns=@([pscustomobject]@{Header='Élément';Binding=[pscustomobject]@{Path=[pscustomobject]@{Path='Fait'}}})
        $script:Ctrl.DgAdAuditPolicy.ItemsSource=@([pscustomobject]@{Fait='Longueur minimale'})
        $count=$script:Tasks.Count
        Copy-DomeniaAdAuditView
        Expect ($script:Clipboard -match 'Audit AD · Utilisateur · Jean Dupont' -and $script:Clipboard -match 'Résumé de test' -and $script:Clipboard -match 'Longueur minimale' -and $script:Tasks.Count -eq $count) $script:Clipboard
    }
}

$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[ordered]@{
    Suite='Domenia.AdAudit';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition
    DomainContacted=$false;NetworkUsed=$false;Passed=$passed;Failed=$failed;Tests=$script:Checks.ToArray()
    Limitations='Vrais modules, vrais corps epingles (gardes executees), vraie vue WPF ; Start-UiTask, presse-papiers et confirmations doubles. Aucune lecture AD, CIM, DNS ni SQLite reelle.'
}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))}
if(-not $Quiet){
    Write-Host ('Audit AD : '+$passed+' reussis, '+$failed+' en echec.')
    $script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}
}
if(($failed -gt 0) -or ($passed -eq 0)){exit 1}
exit 0
