#requires -Version 5.1
<# R40 (fiche dʼappel) : preuve de raccordement de la fiche dʼappel dʼun compte utilisateur.
   Vrais modules du plan ferme (regles, corps epingles, interface), vraie vue XAML chargee par WPF, vraies fonctions du
   coeur extraites par AST. Start-UiTask, la base locale, la presence, le presse-papiers et la navigation sont remplaces
   par des doublures : aucune lecture AD, CIM, WTS ni SQLite n'est envoyee. Domaine example.invalid, comptes et GUID
   inventes. Suite ecrite le 2026-10-21, non executee (phase du 21 octobre : David teste a la main sous Windows).
#>
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here (no-op double).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $wad 'modules'
$x='http://schemas.microsoft.com/winfx/2006/xaml'
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
$script:SheetFiles=@('Domenia-CallSheet.Model.ps1','Domenia-CallSheet.UI.ps1')
$infrastructure=$true
try{
    if(($PSVersionTable.PSEdition -ne 'Desktop') -or ($PSVersionTable.PSVersion.Major -ne 5) -or (-not [Environment]::Is64BitProcess) -or ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA')){
        throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous un autre moteur ne vaut pas preuve.'
    }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    foreach($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Search.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Directory.Model.ps1','Domenia-Workstation.Model.ps1','Domenia-Collection.Model.ps1','Domenia-ProbeCatalog.Model.ps1','Domenia-Probes.Model.ps1','Domenia-Readings.Model.ps1','Domenia-Safety.Model.ps1','Domenia-AdAudit.Model.ps1','Domenia-Storage.Worker.ps1','Domenia-AdAudit.Worker.ps1','Domenia-Lockout.Worker.ps1','Domenia-Lockout.UI.ps1','Domenia-Sessions.UI.ps1')+$script:SheetFiles){
        [void](Read-SourceAst (Join-Path $modules $file))
        . (Join-Path $modules $file)
    }
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    $script:CoreText=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    foreach($name in @('Get-DomeniaControl','Set-DomeniaControlText','Set-DomeniaControlEnabled','Get-DomeniaEffectiveWorkerResult','Normalize-LinkComputer','Assert-DomeniaComputerTarget','Get-DomeniaInventoryWorkerCode','Get-DomeniaSafeObjectPropertyNames')){
        . ([scriptblock]::Create((Get-FunctionText $script:CoreAst $name)))
    }
    $script:Help=@(([IO.File]::ReadAllText((Join-Path $modules 'Domenia-UX.help.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json))
    $script:MainXaml=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Main.xaml'),[Text.Encoding]::UTF8)
}catch{
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, modules et coeur analyses nativement';Status='Failed';Detail=$_.Exception.ToString()})
}

# Doubles of the application boundaries: no worker, no network, no store, no clipboard, no dialog.
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$CallbackState,$ReplaceKey,$DisableControls,$TimeoutSeconds,$SuccessHandler,$ErrorHandler,$TaskClass,$StatusText)
    $id='task-'+($script:Tasks.Count+1)
    $script:Tasks.Add([pscustomobject]@{Id=$id;Name=$Name;OperationId=$OperationId;Code=$Code;Payload=$Payload;State=$CallbackState;ReplaceKey=$ReplaceKey;Success=$SuccessHandler;Error=$ErrorHandler;TaskClass=$TaskClass;Timeout=[int]$TimeoutSeconds})
    $script:AsyncJobs[$id]=[pscustomobject]@{OperationId=$OperationId}
    return $id
}
function Request-DomeniaStoreRead {param($Context,$Query,$SuccessHandler,$ErrorHandler,$CallbackState,[switch]$Preview);$script:StoreReads.Add([pscustomobject]@{Query=$Query;Success=$SuccessHandler;State=$CallbackState});return ('store-'+$script:StoreReads.Count)}
function Initialize-DomeniaRemoteStoreState {
    param($State,[string]$Guid,[string]$DN,[long]$Generation=0)
    $identity=[guid]::Empty
    if((-not [guid]::TryParse($Guid,[ref]$identity)) -or (-not $DN)){throw 'Identite AD de collecte incomplete.'}
    $State|Add-Member -NotePropertyName StoreContext -NotePropertyValue ([pscustomobject]@{StoreId='store-1';SessionEpoch=$script:SessionEpoch;RequestId='r1'}) -Force
    $State|Add-Member -NotePropertyName StoreGuid -NotePropertyValue $Guid -Force
    $State|Add-Member -NotePropertyName StoreDn -NotePropertyValue $DN -Force
    return $State
}
function Test-DomeniaRemoteStoreContext {param($State,$Result);return $true}
function Start-DomeniaCommittedPresence {param([string]$Computer,[string]$Guid,[string]$DN,[string]$DisplayDN,[string]$DisplayKind='Machine',[string]$Suffix='',[switch]$Explicit);$script:Presence.Add([pscustomobject]@{Computer=$Computer;DisplayDN=$DisplayDN;DisplayKind=$DisplayKind;Explicit=[bool]$Explicit})}
function Set-Status {param($Text,$Level);$script:Statuses.Add([string]$Text)}
function Write-AppLog {param($Text,$Level)}
function Set-ClipboardSafe {param([string]$Text);$script:Clipboard=$Text}
function Invoke-DomeniaSafeUiAction {param([string]$Operation,[scriptblock]$Action,[switch]$NoPopup);& $Action}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab);$script:Routes.Add(([string]$Workspace+'/'+[string]$Inner+'/'+[string]$Tab));$tabs=Get-DomeniaControl 'DetailTabs';$target=Get-DomeniaControl ([string]$Tab);if(($null -ne $tabs) -and ($null -ne $target) -and ($target -is [Windows.Controls.TabItem])){$tabs.SelectedItem=$target}}
function Set-DomeniaItemsSource {param([string]$Name,$Rows);$control=Get-DomeniaControl $Name;if($null -eq $control){return $false};$control.ItemsSource=@($Rows);return $true}
function Initialize-DomeniaUxControlHelp {param($Control);$script:HelpApplied++}
function New-DomeniaTimer {param($Owner,$IntervalMs,$Tick,[switch]$Transient);$t=[pscustomobject]@{Owner=$Owner;Running=$false};$t|Add-Member ScriptMethod Start {$this.Running=$true};$t|Add-Member ScriptMethod Stop {$this.Running=$false};return $t}
function Get-LinksForUser {param([string]$UserLogin,[string]$Guid='',$CreatedUtc=$null);foreach($l in @($script:Links)){if([string]$l.UserLogin -ieq $UserLogin){$l}}}
function Find-DomeniaCachedComputerRow {param([string]$Computer,[string]$Guid='');foreach($r in @($script:IndexComputers)){if([string]$r.Name -ieq $Computer){return $r}};return $null}
function Get-CfgValue {param($Section,$Name,$Default=$null);if(($Section -eq 'CallSheet') -and ($Name -eq 'TicketTemplate') -and ($null -ne $script:Template)){return $script:Template};return $Default}
function Get-DomeniaStoredHealthPolicy {param([string]$ScopeDn='');return $null}
function Get-DomeniaBoardThresholds {param($Policy=$null);return [pscustomobject]@{DiskFreeAlert=10;DiskFreeWarn=20;MemoryUsedWarn=90;UptimeDays=30}}
function Get-DomeniaLinkQualification {param($Link);return [pscustomobject]@{Suffix='  Déclaré'}}
function Get-DomeniaCredentialFailureHistory {return ,@()}
function Get-DomeniaLockoutAccountKeys {param([string]$Sam,[string]$Upn);return ,@($Sam)}
function Test-DomeniaReceiptStoreBusy {return $false}
function Start-DomeniaReceiptRefresh {$script:ReceiptRefreshes++}
function Open-AdObject {param([string]$Dn,[string]$Type);$script:Opened.Add($Type+':'+$Dn)}
function Start-OpenLinkedObject {param([string]$Type,[string]$Identity);$script:Opened.Add($Type+':'+$Identity)}
function Queue-DomeniaSelectedObjectOpen {param([switch]$Immediate,[switch]$Force);$script:Queued++}
function Get-DomeniaSelectedGridRow {return $script:GridRow}

function Reset-SheetFixture {
    $script:Tasks=[Collections.Generic.List[object]]::new();$script:StoreReads=[Collections.Generic.List[object]]::new();$script:Presence=[Collections.Generic.List[object]]::new()
    $script:Statuses=[Collections.Generic.List[string]]::new();$script:Routes=[Collections.Generic.List[string]]::new();$script:Opened=[Collections.Generic.List[string]]::new()
    $script:AsyncJobs=@{};$script:Clipboard='';$script:HelpApplied=0;$script:ReceiptRefreshes=0;$script:Queued=0;$script:GridRow=$null;$script:Template=$null
    $script:SessionEpoch=7L;$script:SelectedObjectGeneration=1L;$script:CurrentObjectRequestDn='';$script:GlobalSearchGeneration=1L
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Domain='example.invalid';User='EXAMPLE\lecteur';Server='dc1.example.invalid'}
    $script:Live=$null;$script:FleetObservations=@{};$script:InventoryCacheByComputer=@{};$script:ReceiptViews=$null;$script:ReceiptViewsReadUtc=$null;$script:ReceiptViewsEpoch=-1L
    $script:CallSheetView=$null;$script:CallSheetState=$null;$script:CallSheetFiche=$null;$script:CallSheetPendingDn='';$script:CallSheetBaselines=@{};$script:CallSheetTimer=$null;$script:CallSheetSignature='';$script:CallSheetDrawing=$false
    $script:Links=@([pscustomobject]@{UserLogin='jdupont';Computer='PC-01';Source='Saisie manuelle';Kind='Affectation';When='2026-09-01T08:00:00Z';ComputerDn='CN=PC-01,OU=Postes,DC=example,DC=invalid';ComputerGuid='22222222-2222-4222-8222-222222222222'})
    $script:IndexComputers=@()
    $script:Ctrl=@{}
    $tabs=New-Object Windows.Controls.TabControl;$tabs.Name='DetailTabs'
    foreach($name in @('TabUser','TabUserCallSheet','TabMemberOf')){$item=New-Object Windows.Controls.TabItem;$item.Name=$name;[void]$tabs.Items.Add($item);$script:Ctrl[$name]=$item}
    $script:Ctrl['DetailTabs']=$tabs
    $script:Ctrl['BtnUserCallSheet']=New-Object Windows.Controls.Button
    $script:Window=$null
}
function Select-SheetUser {
    param([hashtable]$Extra=@{})
    $now=[datetime]::UtcNow
    $props=@{
        sAMAccountName=@('jdupont');userPrincipalName=@('jdupont@example.invalid');displayName=@('Jeanne Dupont');objectSid=@('S-1-5-21-1000-2000-3000-1104');objectGUID=@('11111111-1111-4111-8111-111111111111')
        userAccountControl=@('512');'msDS-User-Account-Control-Computed'=@('16');lockoutTime=@([string]$now.AddMinutes(-20).ToFileTimeUtc());badPwdCount=@('5')
        pwdLastSet=@([string]$now.AddDays(-10).ToFileTimeUtc());accountExpires=@('0');'msDS-UserPasswordExpiryTimeComputed'=@([string]$now.AddDays(80).ToFileTimeUtc())
        memberOf=@('CN=Compta,OU=Groupes,DC=example,DC=invalid');primaryGroupID=@('513')
    }
    foreach($key in $Extra.Keys){$props[$key]=$Extra[$key]}
    $script:SelectedObjectGeneration=[long]$script:SelectedObjectGeneration+1
    $script:SelectedObject=[pscustomobject]@{DN='CN=Jeanne Dupont,OU=Support,DC=example,DC=invalid';Type='Utilisateur';Name='Jeanne Dupont';Entry=[pscustomobject]@{Properties=$props};LoadedAt=$now.ToLocalTime()}
    $script:CallSheetFiche=[pscustomobject]@{Dn=$script:SelectedObject.DN;Origin='Live';ObservedUtc=$now;Epoch=$script:SessionEpoch}
}
function Get-SheetRows {param([string]$Name);return @($script:Ctrl[$Name].ItemsSource)}

if($infrastructure){
    Case 'Plan ferme, coeur et vue principale : modules declares, crochets du coeur et onglet sans infobulle' {
        # The plan function alone, taken from the closed loader: no module is imported a second time here.
        . ([scriptblock]::Create((Get-FunctionText (Read-SourceAst (Join-Path $wad 'Domenia-Modules.ps1')) 'Get-DomeniaRuntimeModulePlan')))
        $plan=@(Get-DomeniaRuntimeModulePlan)
        foreach($file in $script:SheetFiles){
            $entry=@($plan|Where-Object{$_.File -eq $file})
            Expect ($entry.Count -eq 1) ('Module absent du plan : '+$file)
            $ast=Read-SourceAst (Join-Path $modules $file)
            $declared=@($ast.EndBlock.Statements|Where-Object{$_ -is [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{$_.Name})
            Expect ((@($entry[0].Functions) -join ',') -eq ($declared -join ',')) ('Fonctions declarees differentes : '+$file)
        }
        Expect ((Get-FunctionText $script:CoreAst 'Wire-Events') -match 'Register-DomeniaCallSheetUi') 'Enregistrement absent de Wire-Events'
        Expect ((Get-FunctionText $script:CoreAst 'Show-AdObjectResult') -match 'Sync-DomeniaCallSheetAfterOpen') 'Crochet absent de Show-AdObjectResult'
        Expect ((Get-FunctionText $script:CoreAst 'Set-VisibleTabsForType') -match 'TabUserCallSheet') 'Visibilite de lʼonglet absente'
        Expect ((Get-FunctionText $script:CoreAst 'Build-DomeniaObjectsContextMenu') -match 'Open-DomeniaResultRowCallSheet') 'Menu de Rechercher absent'
        Expect (@(Get-DomeniaSafeObjectPropertyNames) -contains 'logonHours') 'logonHours non lu avec la fiche'
        [xml]$main=$script:MainXaml
        foreach($name in @('BtnUserCallSheet','TabUserCallSheet')){
            $node=$main.SelectSingleNode("//*[@*[local-name()='Name']='$name']")
            Expect ($null -ne $node) ('Controle absent de la vue principale : '+$name)
            Expect (-not $node.GetAttribute('ToolTip')) ('Infobulle dans la vue principale : '+$name)
            Expect ($script:CoreText.Contains('"'+$name+'" = "Default"')) ('Politique absente : '+$name)
            Expect (@($script:Help|Where-Object{$_.Name -eq $name}).Count -eq 1) ('Aide absente : '+$name)
        }
    }

    Case 'Vue : chargee une fois par WPF, controles enregistres, aide du catalogue, aucune infobulle ni taille litterale' {
        Reset-SheetFixture
        Initialize-DomeniaCallSheetView
        $view=$script:CallSheetView
        Expect ($null -ne $view) 'Vue non chargee'
        Expect ([object]::ReferenceEquals($script:Ctrl.TabUserCallSheet.Content,$view)) 'Vue non posee dans lʼonglet'
        $text=[IO.File]::ReadAllText((Join-Path $modules 'Domenia-CallSheet.xaml'),[Text.Encoding]::UTF8)
        Expect (-not ($text -match '\sToolTip=')) 'Infobulle dans la vue'
        Expect (-not ($text -match 'FontSize="[0-9]')) 'Taille litterale'
        Expect (-not ($text -match '(Margin|Padding)="[0-9]')) 'Marge litterale'
        [xml]$document=$text
        $named=0
        foreach($element in $document.SelectNodes('//*')){
            $name=$element.GetAttribute('Name',$x);if(-not $name){continue}
            $named++
            Expect ($script:Ctrl.ContainsKey($name)) ('Controle non enregistre : '+$name)
            Expect ($script:CoreText.Contains('"'+$name+'" = "Default"')) ('Politique absente : '+$name)
            if($name -ne 'DomeniaCallSheetView'){Expect (@($script:Help|Where-Object{$_.Name -eq $name}).Count -eq 1) ('Aide absente : '+$name)}
        }
        Expect ($script:HelpApplied -eq $named) ('Aide non appliquee a chaque controle : '+$script:HelpApplied+' / '+$named)
        Initialize-DomeniaCallSheetView
        Expect ([object]::ReferenceEquals($script:CallSheetView,$view)) 'Vue rechargee'
    }

    Case 'Ouverture : rien ne part sur le reseau, une seule lecture locale de lʼinventaire enregistre' {
        Reset-SheetFixture
        Select-SheetUser
        Show-DomeniaCallSheet
        Expect ($script:Routes -contains 'WsObject/DetailTabs/TabUserCallSheet') ('Onglet non ouvert : '+($script:Routes -join ' | '))
        Expect ($script:Tasks.Count -eq 0) ('Lecture reseau a lʼouverture : '+(@($script:Tasks|ForEach-Object{$_.OperationId}) -join ','))
        Expect ($script:StoreReads.Count -eq 1) 'Une lecture locale de lʼinventaire attendue'
        Expect ([string]$script:StoreReads[0].Query.ResultKind -eq 'ClassicInventory') 'Lecture locale inattendue'
        Expect ([string]@($script:StoreReads[0].Query.Guids)[0] -eq '22222222-2222-4222-8222-222222222222') 'Mauvais poste lu'
        Update-DomeniaCallSheet -Force
        Expect ($script:StoreReads.Count -eq 1) 'La lecture locale est repetee'
        $account=Get-SheetRows 'DgCallSheetAccount'
        $lock=@($account|Where-Object{$_.Label -eq 'Verrouillage'})[0]
        Expect ($lock.Value -like 'Verrouillé depuis le *') $lock.Value
        Expect (@($account|Where-Object{($_.Label -eq 'Verrouillages des 7 derniers jours') -and ($_.State -eq 'NotRead')}).Count -eq 1) 'Ligne 4740 absente'
        Expect ($script:Ctrl.LblCallSheetAttention.Text -like 'À noter : *Verrouillage*') $script:Ctrl.LblCallSheetAttention.Text
        $computers=Get-SheetRows 'DgCallSheetComputers'
        Expect (($computers.Count -eq 1) -and ($computers[0].Computer -eq 'PC-01') -and ($computers[0].Qualification -eq 'Déclaré · principal')) 'Poste associe absent'
        Expect ($script:Ctrl.LblCallSheetTriageTarget.Text -match 'PC-01') $script:Ctrl.LblCallSheetTriageTarget.Text
        Expect (@(Get-SheetRows 'DgCallSheetTriage').Count -eq 7) 'Tri : sept mesures attendues'
        Expect ($script:Ctrl.TxtCallSheetTicket.Text -match 'Fiche dʼappel Domenia du') 'Apercu du ticket absent'
        Expect ($script:Ctrl.BtnCallSheetCompareRights.Visibility -ne [Windows.Visibility]::Visible) 'Comparer les droits visible sans sa vue'
    }

    Case 'Lectures explicites : un clic, une operation epinglee, sa cible exacte ; rappel dʼune autre session ignore' {
        Reset-SheetFixture
        Select-SheetUser
        Show-DomeniaCallSheet
        Start-DomeniaCallSheetLockoutRead
        $task=$script:Tasks[$script:Tasks.Count-1]
        Expect (($task.OperationId -eq 'LockoutDiagnosis') -and ($task.Payload.UserSid -eq 'S-1-5-21-1000-2000-3000-1104') -and ([int]$task.Payload.Hours -eq 168) -and ($task.TaskClass -eq 'Explicit')) 'Lecture 4740'
        Start-DomeniaCallSheetLockoutRead
        Expect ($script:Tasks.Count -eq 1) 'Deux lectures 4740 en meme temps'
        $stale=$task.State.PSObject.Copy();$stale.Epoch=99L
        Complete-DomeniaCallSheetLockoutRead -Result ([pscustomobject]@{State='Read';Server='pdc';Events=@();UserSid='S-1-5-21-1000-2000-3000-1104';Hours=168;ServerSource='Emulateur PDC'}) -State $stale
        Expect ($null -eq $script:CallSheetState.Lockout) 'Rappel dʼune autre session pris en compte'
        $script:AsyncJobs.Remove($task.Id)
        Complete-DomeniaCallSheetLockoutRead -Result ([pscustomobject]@{State='Read';Server='pdc';Events=@([pscustomobject]@{TimeUtc=[datetime]::UtcNow.AddMinutes(-21).ToString('o');CallerComputer='PC-07'});UserSid='S-1-5-21-1000-2000-3000-1104';Hours=168;ServerSource='Emulateur PDC';Truncated=$false;MaxEvents=200;ObservedUtc=[datetime]::UtcNow.ToString('o')}) -State $task.State
        $fact=@(Get-SheetRows 'DgCallSheetAccount'|Where-Object{$_.Label -eq 'Verrouillages des 7 derniers jours'})[0]
        Expect (($fact.State -eq 'Known') -and ($fact.Value -match 'PC-07')) $fact.Value
        Expect ($script:Ctrl.TxtCallSheetAccountReads.Text -match 'PC-07') $script:Ctrl.TxtCallSheetAccountReads.Text
        Start-DomeniaCallSheetPolicyRead
        $policy=$script:Tasks[$script:Tasks.Count-1]
        Expect (($policy.OperationId -eq 'PasswordPolicyRead') -and ($policy.Payload.Dn -eq $script:SelectedObject.DN)) 'Lecture de la strategie'
        Fail-DomeniaCallSheetPolicyRead -Message 'Accès refusé' -State $policy.State
        Expect ($script:Ctrl.TxtCallSheetAccountReads.Text -match 'Stratégie de mot de passe non lue') $script:Ctrl.TxtCallSheetAccountReads.Text
        Start-DomeniaCallSheetSessionsRead
        $sessions=$script:Tasks[$script:Tasks.Count-1]
        Expect (($sessions.OperationId -eq 'SessionsList') -and ($sessions.Payload.Computer -eq 'PC-01') -and ($sessions.Success -eq 'Complete-DomeniaSessionsCollected') -and ($sessions.State.PublishHandler -eq 'Complete-DomeniaCallSheetSessions')) 'Lecture des sessions'
        $script:AsyncJobs.Remove($sessions.Id)
        Complete-DomeniaCallSheetSessions -Result ([pscustomobject]@{Rows=@([pscustomobject]@{Id=2;Station='RDP-Tcp#1';User='jdupont';Domain='EXAMPLE';State='Actif';Protocol='RDP';Detail='';LogonTicks=$null;IdleTicks=$null});Computer='PC-01';ObservedUtc=[datetime]::UtcNow.ToString('o');Source='WTS';Identity='EXAMPLE\lecteur'}) -State $sessions.State
        $row=@(Get-SheetRows 'DgCallSheetComputers')[0]
        Expect ($row.SessionValue -like 'Session de ce compte : *') $row.SessionValue
        Start-DomeniaCallSheetTriage
        $triage=$script:Tasks[$script:Tasks.Count-1]
        Expect (($triage.OperationId -eq 'ComputerInventory') -and ($triage.Payload.Computer -eq 'PC-01') -and (-not [bool]$triage.Payload.Deep) -and ($triage.Success -eq 'Complete-DomeniaClassicCollected') -and ($triage.State.PublishHandler -eq 'Complete-DomeniaCallSheetTriage') -and ($triage.ReplaceKey -eq 'callsheet-triage')) 'Tri du poste lent'
        Expect (-not $script:Ctrl.BtnCallSheetTriage.IsEnabled) 'Tri relancable pendant quʼil tourne'
        $script:AsyncJobs.Remove($triage.Id)
        $inventory=[pscustomobject]@{DataSource='SQLite';SourceCompletedUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o');Rows=@();Metrics=[pscustomobject]@{CpuLoad=97;MemoryTotal=8GB;MemoryFree=4GB;Disks=@([pscustomobject]@{Name='C:';Size=100GB;Free=50GB})}}
        Complete-DomeniaCallSheetTriage -Result $inventory -State $triage.State
        $cpu=@(Get-SheetRows 'DgCallSheetTriage'|Where-Object{$_.Label -eq 'Processeur'})[0]
        Expect (($cpu.State -eq 'Known') -and ($cpu.Value -eq '97 % de charge') -and ($cpu.Attention)) $cpu.Value
        Start-DomeniaCallSheetPresence
        Expect (($script:Presence.Count -eq 1) -and ($script:Presence[0].Computer -eq 'PC-01') -and ($script:Presence[0].DisplayKind -eq 'Utilisateur') -and ($script:Presence[0].Explicit)) 'Presence du poste principal'
        Expect (@($script:Tasks|Where-Object{$_.OperationId -notin @('LockoutDiagnosis','PasswordPolicyRead','SessionsList','ComputerInventory')}).Count -eq 0) 'Operation inattendue'
    }

    Case 'Poste sans identite AD : ni sessions ni tri, la raison est dite ; ouverture du poste par son nom' {
        Reset-SheetFixture
        $script:Links=@([pscustomobject]@{UserLogin='jdupont';Computer='PC-09';Source='Console (CIM)';Kind='Console';When='2026-10-18T08:00:00Z'})
        Select-SheetUser
        Show-DomeniaCallSheet
        Expect ($script:StoreReads.Count -eq 0) 'Lecture locale sans GUID'
        Expect (-not $script:Ctrl.BtnCallSheetTriage.IsEnabled) 'Tri possible sans identite'
        Expect (-not $script:Ctrl.BtnCallSheetSessions.IsEnabled) 'Sessions possibles sans identite'
        Expect ($script:Ctrl.LblCallSheetTriageTarget.Text -match 'Identité AD du poste inconnue') $script:Ctrl.LblCallSheetTriageTarget.Text
        Open-DomeniaCallSheetComputer
        Expect ($script:Opened -contains 'Machine:PC-09') ($script:Opened -join ',')
    }

    Case 'Rechercher : menu dʼun utilisateur, fiche ouverte puis fiche dʼappel, aussi apres la lecture AD' {
        Reset-SheetFixture
        Initialize-DomeniaCallSheetView
        $script:SelectedObject=$null
        $script:GridRow=[pscustomobject]@{Type='Utilisateur';DN='CN=Jeanne Dupont,OU=Support,DC=example,DC=invalid';Name='Jeanne Dupont'}
        Open-DomeniaResultRowCallSheet
        Expect (($script:Queued -eq 1) -and ($script:CallSheetPendingDn -eq $script:GridRow.DN)) 'Ouverture de la fiche non demandee'
        Select-SheetUser
        Sync-DomeniaCallSheetAfterOpen -Dn $script:GridRow.DN -Type 'Utilisateur' -IsLive $false -ObservedUtc ([datetime]::UtcNow.AddHours(-3))
        Expect ($script:Routes -contains 'WsObject/DetailTabs/TabUserCallSheet') 'Fiche dʼappel non ouverte sur la fiche du cache'
        Expect ($script:CallSheetPendingDn -eq $script:GridRow.DN) 'Demande perdue avant la lecture AD'
        Expect ($script:Ctrl.LblCallSheetOrigin.Text -match 'base locale') $script:Ctrl.LblCallSheetOrigin.Text
        $script:Routes.Clear()
        Sync-DomeniaCallSheetAfterOpen -Dn $script:GridRow.DN -Type 'Utilisateur' -IsLive $true -ObservedUtc ([datetime]::UtcNow)
        Expect (($script:Routes -contains 'WsObject/DetailTabs/TabUserCallSheet') -and (-not $script:CallSheetPendingDn)) 'Fiche dʼappel non rouverte apres la lecture AD'
        Expect ($script:Ctrl.LblCallSheetOrigin.Text -match 'annuaire') $script:Ctrl.LblCallSheetOrigin.Text
        $script:GridRow=[pscustomobject]@{Type='Machine';DN='CN=PC-01,OU=Postes,DC=example,DC=invalid';Name='PC-01'}
        Open-DomeniaResultRowCallSheet
        Expect ($script:Queued -eq 1) 'Fiche dʼappel demandee pour un poste'
    }

    Case 'Ticket : modele configure, champs inconnus signales, secret masque, presse-papiers' {
        Reset-SheetFixture
        Select-SheetUser @{description=@('password=NePasCopier')}
        $script:Template=@('Appel : {NomAffiche} ({Identifiant})','{PointsAttention}','{Inexistant}','{Compte}','Note password=NePasCopier')
        Initialize-DomeniaCallSheetView
        Copy-DomeniaCallSheetTicket
        Expect ($script:Clipboard.StartsWith('Appel : Jeanne Dupont (jdupont)')) $script:Clipboard
        Expect (-not $script:Clipboard.Contains('NePasCopier')) 'Secret copie'
        Expect ($script:Ctrl.LblCallSheetTicket.Text -match 'Inexistant') $script:Ctrl.LblCallSheetTicket.Text
        Expect ($script:Statuses[$script:Statuses.Count-1] -match 'copiée pour le ticket') ($script:Statuses -join ' | ')
        $script:Template=@('Texte sans champ')
        Update-DomeniaCallSheet -Force
        Expect ($script:Ctrl.LblCallSheetTicket.Text -match 'ignoré') $script:Ctrl.LblCallSheetTicket.Text
        Expect ($script:Ctrl.TxtCallSheetTicket.Text -match 'Fiche dʼappel Domenia du') 'Modele par defaut non applique'
    }

    Case 'Comparer les droits : bouton present seulement avec la vue de comparaison, reçus lus par la fiche' {
        Reset-SheetFixture
        Select-SheetUser
        $diff=New-Object Windows.Controls.TabItem;$diff.Name='TabUserAccessDiff';[void]$script:Ctrl.DetailTabs.Items.Add($diff);$script:Ctrl['TabUserAccessDiff']=$diff
        $script:ReceiptViews=@([pscustomobject]@{DN=$script:SelectedObject.DN;UpdatedUtc=[datetime]::UtcNow.ToString('o');UpdatedLabel='maintenant';OperationLabel='Déverrouillage';StageLabel='Envoyée, à vérifier';Pending=$true;Explanation=''})
        $script:ReceiptViewsReadUtc=[datetime]::UtcNow;$script:ReceiptViewsEpoch=$script:SessionEpoch
        Show-DomeniaCallSheet
        Expect ($script:Ctrl.BtnCallSheetCompareRights.Visibility -eq [Windows.Visibility]::Visible) 'Bouton masque malgre la vue'
        Open-DomeniaCallSheetRightsComparison
        Expect ($script:Routes -contains 'WsObject/DetailTabs/TabUserAccessDiff') 'Comparaison non ouverte'
        Expect ($script:Ctrl.LblCallSheetReceipts.Text -match '1 reçu\(s\) sur ce compte, dont 1 à vérifier') $script:Ctrl.LblCallSheetReceipts.Text
        Start-DomeniaCallSheetReceiptRefresh
        Expect ($script:ReceiptRefreshes -eq 1) 'Relecture des reçus non demandee'
        Expect ($script:Tasks.Count -eq 0) 'Lecture reseau inattendue'
    }
}

$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$report=[ordered]@{
    Suite='Domenia.CallSheet';Platform=[Environment]::OSVersion.VersionString;PowerShell=$PSVersionTable.PSVersion.ToString();Edition=[string]$PSVersionTable.PSEdition
    DomainContacted=$false;NetworkUsed=$false;Passed=$passed;Failed=$failed;Tests=$script:Checks.ToArray()
    Limitations='Vrais modules, vraie vue WPF ; Start-UiTask, base locale, presence, presse-papiers et navigation doubles. Aucune lecture AD, CIM, WTS ni SQLite reelle.'
}
if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))}
if(-not $Quiet){
    Write-Host ('Fiche dʼappel : '+$passed+' reussis, '+$failed+' en echec.')
    $script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}
}
if(($failed -gt 0) -or ($passed -eq 0)){exit 1}
exit 0
