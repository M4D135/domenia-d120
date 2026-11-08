#requires -Version 5.1
# D051-D060 (lot acces), UI-18, UI-31 et UX-18 (recus et secrets) : preuves de raccordement. Chaque cas exerce le vrai code livre et echoue si la regle pure
# n'est plus appelee par l'application. Methode du projet : le vrai chargeur ferme Domenia-Modules.ps1 est
# dot-source, les fonctions du coeur sont extraites par AST, seules les frontieres reseau (Start-UiTask, validation
# de compte, recherche LDAP) et modales (Confirm-Action, Show-DomeniaDialog) sont doublees, les controles WPF sont
# ceux du vrai XAML principal. Aucun mot de passe : les valeurs factices sont generees a l'execution.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$native=($PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1 -and [Environment]::Is64BitProcess)
if(-not $native){throw 'Windows PowerShell 5.1 x64 requis ; une execution sous un autre moteur n est pas une preuve.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Utiliser powershell.exe -STA.'}
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
function Assert-True {param([bool]$Value,[string]$Why='Assertion fausse');if(-not $Value){throw $Why}}
function Test-Case {param([string]$Name,[scriptblock]$Body)
    try{Reset-Fixture;& $Body|Out-Null;$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Passed';Detail=''})}
    catch{$script:Checks.Add([pscustomobject]@{Name=$Name;Status='Failed';Detail=($_.Exception.Message+' @ '+$_.ScriptStackTrace)})}
}
function Reset-Fixture {}
function New-TestCredential {param([string]$User)
    # Runtime-generated throw-away value: no secret is stored in the repository.
    $secure=New-Object Security.SecureString
    foreach($c in ([guid]::NewGuid().ToString('N')).ToCharArray()){$secure.AppendChar($c)}
    $secure.MakeReadOnly()
    return [Management.Automation.PSCredential]::new($User,$secure)
}

# ---------------------------------------------------------------- 1. real closed loader
$script:RootDir=$wad
$script:LoaderError=''
try { . (Join-Path $wad 'Domenia-Modules.ps1') }
catch {
    $script:LoaderError=$_.Exception.Message
    # Fallback import so that the behaviour cases still run; the loader case below reports the failure.
    foreach($file in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Relations.Model.ps1','Domenia-Access.Model.ps1','Domenia-Guard.Model.ps1','Domenia-Embedded.UI.ps1','Domenia-UX.UI.ps1','Domenia-Access.UI.ps1','Domenia-Sessions.UI.ps1','Domenia-Accounts.Async.ps1','Domenia-Guard.UI.ps1','Domenia-Secrets.Worker.ps1','Domenia-Secrets.UI.ps1')){
        $path=Join-Path (Join-Path $wad 'modules') $file
        if([IO.File]::Exists($path)){. $path}
    }
}
if($null -eq ('Domenia.SelectionIdentity' -as [type])){try{Add-Type -Path (Join-Path $wad 'modules\Domenia-Identity.Types.cs')}catch{}}

# ---------------------------------------------------------------- 2. real core functions (AST)
$corePath=Join-Path $wad 'Domenia-Core.ps1'
$tokens=$null;$errors=$null
$script:CoreAst=[Management.Automation.Language.Parser]::ParseFile($corePath,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw $errors[0].Message}
$script:CoreText=[IO.File]::ReadAllText($corePath)
function Get-CoreFunctionText {param([string]$Name)
    $nodes=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Fonction du coeur absente ou ambigue : '+$Name)}
    return $nodes[0].Extent.Text
}
$coreNames=@('Update-DomeniaAccountUi','Get-DomeniaCredentialUserName','Protect-DomeniaLogText','ConvertTo-DomeniaErrorInfo','Show-DomeniaOperationError','Write-AppLog','Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Set-DomeniaItemsSource','Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys','Get-DomeniaEffectiveWorkerResult',
    'Update-SecretsGrid','Get-DomeniaSelectedSecretSource','Test-DomeniaSecretCallbackCurrent','Clear-DomeniaSecretResultValues','Complete-DomeniaSecretLoadUi','Fail-DomeniaSecretLoadUi','Start-LoadComputerSecrets',
    'Toggle-SecretsVisibility','Copy-SelectedSecret','Copy-AllSecrets','Update-DomeniaSecretActionUi','Test-DomeniaControlIsBusy','Clear-Secrets',
    'New-DomeniaWorkerRunspace','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerOperationCode',
    'Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme',
    # L02: incident code of Show-DomeniaOperationError and queued Domenia.log writer of Write-AppLog.
    'New-DomeniaIncidentCode','Get-DomeniaErrorSignature','Register-DomeniaErrorOccurrence',
    'ConvertTo-DomeniaLogFileLines','Get-DomeniaAppLogFallbackPaths','Write-DomeniaAppLogFile','Start-DomeniaAppLogFlushTimer','Stop-DomeniaAppLogQueue',
    'Invoke-DomeniaAppLogRotation','Flush-DomeniaAppLog','Invoke-DomeniaAppLogFlush','Set-DomeniaAppLogAvailability','Test-DomeniaInternalFault','Test-DomeniaOperatorMessage',
    # X03 (UX-15): workstation account typed in the side panel of Assistance poste.
    'Set-MachineCredentialFromUi','Clear-MachineCredential','Get-DomeniaMachineOperationAccountText','Apply-DomeniaGuiElementPolicy')
foreach($name in $coreNames){. ([scriptblock]::Create((Get-CoreFunctionText $name)))}
$script:RealAssertWorker=${function:Assert-DomeniaWorkerOperationCode}
$script:RealShowAlternate=${function:Show-DomeniaAlternateCredential}
$script:RealProtectLog=Get-CoreFunctionText 'Protect-DomeniaLogText'
# Real common worker helpers; only the LDAP searcher is replaced (network boundary).
$commonParts=[regex]::Matches($script:CoreText,'(?ms)^\$script:WorkerCommon (?:=|\+=) @''\r?\n(.*?)\r?\n''@')
$script:RealWorkerCommon=(@($commonParts|ForEach-Object{$_.Groups[1].Value}) -join "`r`n")
$script:FakeSearcher=@'
function New-WSearcher {
    param($Context,[string]$BaseDn,[string]$Filter,[string[]]$Properties,[string]$Scope='OneLevel',[int]$Limit=0)
    if([bool]$Context.SearchMustNotRun){throw 'TEST : recherche LDAP lancee alors qu elle devait etre refusee avant envoi.'}
    if($Context.ForbiddenAttribute -and @($Properties) -contains [string]$Context.ForbiddenAttribute){throw ('TEST : attribut interdit demande : '+$Context.ForbiddenAttribute)}
    $results=New-Object Collections.ArrayList
    foreach($item in @($Context.FakeDirectory[$BaseDn])){if($null -ne $item){[void]$results.Add([pscustomobject]@{Properties=$item})}}
    $searcher=[pscustomobject]@{Results=$results}
    $searcher|Add-Member -MemberType ScriptMethod -Name FindAll -Value {return ,$this.Results}
    $searcher|Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
    return $searcher
}
'@

# ---------------------------------------------------------------- 3. doubles (network, modal and timer boundaries only)
function Get-CfgValue {param($Section,$Name,$Default) $key=[string]$Section+'.'+[string]$Name;if($script:Config.ContainsKey($key)){return $script:Config[$key]};return $Default}
function Set-Status {param($Text,$Level='INFO') $script:StatusLines.Add([string]$Text)}
function Add-DomeniaUiLog {param($Text,$Level,$Area) $script:UiLog.Add([string]$Text)}
function Initialize-DomeniaDataStore {}
function Show-ErrorBox {param($Message,$Details) $script:Popups.Add([string]$Message)}
function Show-InfoBox {param($Message,$Details) $script:Popups.Add([string]$Message)}
function Confirm-Action {param($Message,$Title) $script:ConfirmCalls.Add([string]$Message);return [bool]$script:Consent}
function Show-DomeniaDialog {param($Message,$Title,$Kind,$Buttons,$Details) $script:Dialogs.Add([pscustomobject]@{Message=$Message;Details=$Details;Buttons=$Buttons});return $script:DialogAnswer}
function Select-DomeniaWorkspace {param($Workspace,$Inner,$Tab) $script:Routes.Add(([string]$Workspace+'|'+[string]$Inner+'|'+[string]$Tab))}
function Restart-DomeniaSecretLifetime {}
function Save-DomeniaSecretIndexEntry {param($Computer,$BitLockerKeys,$Verdict) return $true}
function Update-DomeniaSecretIndexFromRows {param($Computer,$Mode,$Rows,$Verdict) return $true}
function Get-CurrentSelectedComputerName {return 'PC-01'}
function Apply-CurrentPermissionUi {}
function Clear-DomeniaActualCapabilityDenials {param($Dn)}
function Start-DomeniaAccountRelogin {$script:Relogins++}
function Get-DomeniaEntryFirstString {param($Entry,$Name) if($Name -eq 'dNSHostName'){return [string]$Entry.Dns};return [string]$Entry.Name}
function Test-DomeniaActualCapabilityDenied {param($Dn,$Capability) return $false}
function Get-WriteControlMap {return @{Edit=@('BtnUserSave');Raw=@('BtnRawSet')}}
function Set-DomeniaProtectedClipboard {param([string]$Value,[int]$MaxLength=8192) $script:Clipboard.Add($Value)}
function Start-SecretClipboardAutoClear {param([string]$Value) $script:ClipboardTimers++}
function Clear-DomeniaSecretClipboard {param([switch]$Silent) $script:ClipboardClears++}
function Start-UiTask {
    param($Name,$OperationId,$Code,$Payload,$OnSuccess,$OnError,$SuccessHandler,$ErrorHandler,$DisableControls,$ReplaceKey,$TimeoutSeconds,$HardTimeoutSeconds,$StatusText,[switch]$IsWrite,[switch]$NonCancellable,$CorrelationId,$CallbackState,$TaskClass)
    $script:Tasks.Add([pscustomobject]@{Name=$Name;OperationId=$OperationId;Code=[string]$Code;Payload=$Payload;State=$CallbackState;SuccessHandler=$SuccessHandler;ErrorHandler=$ErrorHandler;StatusText=[string]$StatusText})
    return ('task-'+$script:Tasks.Count)
}
function Show-DomeniaAlternateCredential {
    param([string]$Scope,[string]$Operation,[string]$Target='',[string]$OperationId='')
    if([bool]$script:UseRealDialog){return (& $script:RealShowAlternate -Scope $Scope -Operation $Operation -Target $Target -OperationId $OperationId)}
    $script:DialogCalls.Add([pscustomobject]@{Scope=$Scope;Target=$Target;OperationId=$OperationId})
    return $script:NextCredential
}
# Credential dialog boundaries (used only with the real dialog).
function ConvertFrom-DomeniaXaml {param([string]$XamlText,[string]$Context) $reader=[Xml.XmlNodeReader]::new([xml]$XamlText);try{return [Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}}
function Show-DomeniaEmbeddedWindow {param($Window) $script:DialogWindow=$Window;if($null -ne $script:DialogScript){& $script:DialogScript $Window};return $true}
function Start-DomeniaRemoteCredentialSession {param($User,$Password,$Computer) $script:RemoteValidations.Add([string]$User);return [pscustomobject]@{AsyncResult=[pscustomobject]@{IsCompleted=$false};CancelRequested=$false;Cleaned=$false}}
function New-DomeniaAccountAuthRequest {param($UserName,$Password,$TimeoutSeconds) $script:DirectoryValidations.Add([string]$UserName);return [pscustomobject]@{UserName=$UserName}}
function Start-DomeniaLoginAuthRunspace {param($Request) return [pscustomobject]@{AsyncResult=[pscustomobject]@{IsCompleted=$false};CancelRequested=$false;Cleaned=$false}}
function Stop-DomeniaLoginAuthRunspace {param($Session,[switch]$Terminate)}
function Read-DomeniaAuthRunspaceResult {param($Session) return $null}

# ---------------------------------------------------------------- 4. real main window controls
$script:MainWindow=$null
$xamlReader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)))
try{$script:MainWindow=[Windows.Markup.XamlReader]::Load($xamlReader)}finally{$xamlReader.Close()}
$script:MainControls=@{}
foreach($match in [regex]::Matches((Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot)),'x:Name="([^"]+)"')){
    $control=$script:MainWindow.FindName($match.Groups[1].Value)
    if($null -ne $control){$script:MainControls[$match.Groups[1].Value]=$control}
}

$script:Dn='CN=PC-01,OU=Postes,DC=example,DC=invalid'
# Real handlers of the secrets view, wired once on the real controls (recovery id filter, prerequisite route).
$script:Ctrl=$script:MainControls
Initialize-DomeniaSecretsUi
function Reset-Fixture {
    $script:Config=@{};$script:StatusLines=[Collections.Generic.List[string]]::new();$script:UiLog=[Collections.Generic.List[string]]::new()
    $script:Popups=[Collections.Generic.List[string]]::new();$script:ConfirmCalls=[Collections.Generic.List[string]]::new();$script:Dialogs=[Collections.Generic.List[object]]::new()
    $script:Routes=[Collections.Generic.List[string]]::new();$script:Tasks=[Collections.Generic.List[object]]::new();$script:Clipboard=[Collections.Generic.List[string]]::new()
    $script:DialogCalls=[Collections.Generic.List[object]]::new();$script:RemoteValidations=[Collections.Generic.List[string]]::new();$script:DirectoryValidations=[Collections.Generic.List[string]]::new()
    $script:ClipboardTimers=0;$script:Relogins=0;$script:Consent=$true;$script:DialogAnswer=[Windows.MessageBoxResult]::No;$script:NextCredential=$null;$script:UseRealDialog=$false;$script:DialogScript=$null;$script:DialogWindow=$null
    $script:Clock=[datetime]::SpecifyKind([datetime]'2026-10-02T08:00:00',[DateTimeKind]::Utc)
    $script:SessionEpoch=7L;$script:SelectedObjectGeneration=3L;$script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:AsyncEngineClosing=$false;$script:ReadOnlyMode=$true
    $script:ReceiptReady=$true;$script:ReceiptPending=0;$script:ShowingCachedObject=$false
    $script:Conn=[pscustomobject]@{BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='EXAMPLE\lecteur';AuthMode='Windows';UseCredential=$false;Credential=$null}
    $script:ProcessIdentity='EXAMPLE\lecteur';$script:SecretsCredential=$null;$script:RemoteAdminCredential=$null;$script:MachineCredential=$null
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN=$script:Dn;Name='PC-01';Entry=[pscustomobject]@{Name='PC-01';Dns='pc-01.example.invalid'};Safety=[pscustomobject]@{Guid='11111111-2222-3333-4444-555555555555'}}
    $script:CurrentCapabilities=@{};$script:ControlBusyRef=@{};$script:ArtifactConsent=$null;$script:Live=$null;$script:DomeniaSurfaceState=$null
    $script:SecretRows=@();$script:SecretsVisible=$false;$script:RevealedSecretIndex=-1;$script:BitLockerKeyList=@();$script:BitLockerKeyContext=$null;$script:ActiveSecretRequestId=''
    if($null -ne $script:SecretRevealTimer){try{$script:SecretRevealTimer.Stop()}catch{}};$script:SecretRevealTimer=$null
    # UX-18: no countdown nor card left over from a previous case.
    if($null -ne $script:SecretCountdownTimer){try{$script:SecretCountdownTimer.Stop()}catch{}};$script:SecretReveal=$null
    $script:Ctrl=$script:MainControls;$script:Ctrl.BitLockerKeyCard.Visibility='Collapsed';$script:Ctrl.BitLockerKeyBlocks.ItemsSource=$null
    $script:AccessCurrentJob=$null;$script:DirectoryCredentialFaulted=$false
    # Points 42 to 45: no pause, alias or validation left over from a previous case in « En ce moment ».
    $script:DomeniaCredentialGuard=$null;$script:DomeniaAccountAlias=$null;$script:DomeniaCredentialAliasBook=$null;$script:DomeniaCredentialValidations=$null
    $script:Ctrl=$script:MainControls
    $script:Window=$null;$script:CurrentTheme='Light'
    $script:Ctrl.DgSecrets.ItemsSource=$null;$script:Ctrl.LblSecretsStatus.Text='';$script:Ctrl.TxtBitLockerRecoveryId.Text='';$script:Ctrl.BtnSecretsPrerequisite.Visibility='Collapsed'
    $script:Ctrl.DgTransportPolicy.ItemsSource=$null;$script:Ctrl.LblTransportPolicy.Text=''
    $script:AuditPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-acces-'+[guid]::NewGuid().ToString('N')+'.log')
    $script:AccessState=New-DomeniaAccessState
    $script:Config['Features.BitLockerKeySelection']=$true;$script:Config['Features.SecretSingleCopy']=$true
}
function Get-DomeniaAccessNow {return $script:Clock}
function New-SecretState {param([string]$Mode='LAPS')
    $id=[guid]::NewGuid().ToString('N');$script:ActiveSecretRequestId=$id
    return [pscustomobject]@{RequestId=$id;DN=$script:Dn;ObjectGuid='11111111-2222-3333-4444-555555555555';Generation=[int64]$script:SelectedObjectGeneration;Mode=$Mode;RetryAttempt=0}
}
function New-AccessRecord {param([string]$Op='ReadLaps',[switch]$Write)
    return [pscustomobject]@{Key=((Get-DomeniaAccessScope $Op)+'|'+$script:Dn);Scope=(Get-DomeniaAccessScope $Op);OperationId=$Op;Operation=('Lecture '+$Op);DN=$script:Dn;Target='';Kind='AccessDenied';Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;IsWrite=[bool]$Write;Interactive=$true;At=[datetime]::UtcNow}
}
function Invoke-TestWorker {param([string]$OperationId,[string]$Code,$Context,$Payload)
    $previousCommon=$script:WorkerCommon
    $script:WorkerCommon=$script:RealWorkerCommon+"`r`n"+$script:FakeSearcher
    Set-Item -Path function:script:Assert-DomeniaWorkerOperationCode -Value {param($OperationId,$Code) return 'TEST'}
    $worker=$null;$ps=$null
    try{
        $worker=New-DomeniaWorkerRunspace -OperationId $OperationId -Code $Code
        $ps=[Management.Automation.PowerShell]::Create();$ps.Runspace=$worker.Runspace
        [void]$ps.AddCommand([string]$worker.CommandName);[void]$ps.AddArgument($Context);[void]$ps.AddArgument($Payload)
        $output=$null;$failure=$null
        try{$output=@($ps.EndInvoke($ps.BeginInvoke()))}catch{$failure=$_}
        return [pscustomobject]@{Output=$output;Failure=$failure}
    }finally{
        Set-Item -Path function:script:Assert-DomeniaWorkerOperationCode -Value $script:RealAssertWorker
        $script:WorkerCommon=$previousCommon
        if($null -ne $ps){$ps.Dispose()};if($null -ne $worker -and $null -ne $worker.Runspace){$worker.Runspace.Dispose()}
    }
}

# ================================================================ D051 one account per resource and target
Test-Case 'D051 Plan ferme : Access.Model, Secrets.UI et Secrets.Worker declares, importes et valides' {
    Assert-True (-not $script:LoaderError) ('Chargeur ferme en echec : '+$script:LoaderError)
    $plan=@(Get-DomeniaRuntimeModulePlan)
    foreach($file in @('Domenia-Access.Model.ps1','Domenia-Access.UI.ps1','Domenia-Secrets.UI.ps1','Domenia-Secrets.Worker.ps1','Domenia-Guard.Model.ps1','Domenia-Sessions.UI.ps1')){
        Assert-True (@($plan|Where-Object{$_.File -eq $file}).Count -eq 1) ('Module non declare : '+$file)
        Assert-True (@($script:DomeniaRuntimeImports|Where-Object{$_.File -eq $file -and $_.Validated}).Count -eq 1) ('Module non valide : '+$file)
    }
    foreach($pair in @(@('Get-DomeniaErrorDecision','Domenia-Access.Model.ps1'),@('ConvertTo-DomeniaMachineKey','Domenia-Access.Model.ps1'),@('Test-DomeniaDirectChildDn','Domenia-Access.Model.ps1'),@('Add-DomeniaAccessDenialUi','Domenia-Access.UI.ps1'),@('Use-DomeniaAccessLease','Domenia-Access.UI.ps1'),@('Resolve-DomeniaCapabilityRoute','Domenia-Access.UI.ps1'),@('Request-DomeniaBitLockerKey','Domenia-Secrets.UI.ps1'),@('Get-DomeniaBitLockerKeyWorkerCode','Domenia-Secrets.Worker.ps1'))){
        $fn=Get-Item -LiteralPath ('Function:\'+$pair[0]) -ErrorAction SilentlyContinue
        Assert-True ($null -ne $fn -and [IO.Path]::GetFileName([string]$fn.ScriptBlock.File) -eq $pair[1]) ('Origine attendue '+$pair[1]+' pour '+$pair[0])
        Assert-True (@($plan|Where-Object{$_.File -eq $pair[1] -and @($_.Functions) -contains $pair[0]}).Count -eq 1) ('Fonction absente de la liste fermee : '+$pair[0])
    }
}
Test-Case 'D051 Portee : la cle BitLocker partage le compte BitLocker, une ecriture garde sa portee AD' {
    Assert-True ((Get-DomeniaAccessScope 'ReadBitLockerKey') -eq (Get-DomeniaAccessScope 'ReadBitLocker'))
    Assert-True ((Get-DomeniaAccessScope 'ReadBitLockerList') -eq 'ReadBitLocker')
    Assert-True ((Get-DomeniaAccessScope 'WriteRename') -eq 'AD:WriteRename')
    Assert-True ((Get-DomeniaAccessScope 'ReadLaps') -ne (Get-DomeniaAccessScope 'ReadBitLocker'))
}
Test-Case 'D051 Changer le compte LAPS ne modifie ni le compte AD ni le compte du poste' {
    $laps=New-TestCredential 'EXAMPLE\laps';$script:NextCredential=$laps
    $machine=New-TestCredential 'EXAMPLE\poste';$script:MachineCredential=$machine
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    Assert-True ([object]::ReferenceEquals($script:AccessState.Credentials['ReadLaps'],$laps)) 'Compte LAPS non memorise pour sa ressource'
    Assert-True ($script:AccessState.Credentials.Count -eq 1) 'Une autre ressource a ete modifiee'
    Assert-True ($null -eq (Get-DomeniaRetryCredential 'GlobalSearch') -and $null -eq (Get-DomeniaRetryCredential 'LiveConsole') -and $null -eq (Get-DomeniaRetryCredential 'ReadBitLocker'))
    $ctx=[pscustomobject]@{OperationId='ComputerInventory';Credential=$null;BindUser='';UseCredential=$false;AuthMode='Windows';MachineCredential=$machine;RemoteAdminCredential=$null;RemoteAdminUser=''}
    $ctx=Set-DomeniaTargetCredentialContext -Context (Set-DomeniaRetryWorkerContext -Context $ctx -OperationId 'ComputerInventory') -Payload ([pscustomobject]@{Computer='PC-01'})
    Assert-True ([object]::ReferenceEquals($ctx.MachineCredential,$machine) -and $null -eq $ctx.Credential) 'Le compte LAPS a atteint le poste ou l annuaire'
}
Test-Case 'D051 Compte local refuse pour LAPS : ni memorise, ni lecture relancee' {
    $script:NextCredential=New-TestCredential '.\admin'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    Assert-True ($script:AccessState.Credentials.Count -eq 0) 'Compte local memorise pour LAPS'
    Assert-True (@($script:Tasks).Count -eq 0) 'Lecture relancee avec un compte local'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'compte local'}).Count -ge 1) 'Motif non affiche'
}
Test-Case 'D051 Compte local d un poste : applique a ce poste seulement, jamais a LDAP ni LAPS' {
    $local=New-TestCredential 'PC-01\admin'
    $script:AccessState.Credentials['RemoteLocal|PC-01']=$local
    $script:AccessState.Leases['RemoteLocal|PC-01']=New-DomeniaCredentialLease -Scope 'RemoteLocal|PC-01' -Account 'PC-01\admin' -Mode Inactivity -InactivityMinutes 30 -Epoch 7 -NowUtc $script:Clock
    $make={param($op) [pscustomobject]@{OperationId=$op;Credential=$null;BindUser='';UseCredential=$false;AuthMode='Windows';MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser=''}}
    $same=Set-DomeniaTargetCredentialContext -Context (& $make 'ComputerInventory') -Payload ([pscustomobject]@{Computer='pc-01.example.invalid'})
    Assert-True ([object]::ReferenceEquals($same.MachineCredential,$local)) 'Nom court et FQDN doivent designer le meme poste'
    $other=Set-DomeniaTargetCredentialContext -Context (& $make 'ComputerInventory') -Payload ([pscustomobject]@{Computer='PC-02'})
    Assert-True ($null -eq $other.MachineCredential) 'Compte local transmis a un autre poste'
    foreach($op in @('GlobalSearch','ReadLaps','ReadBitLockerKey')){
        $c=Set-DomeniaTargetCredentialContext -Context (& $make $op) -Payload ([pscustomobject]@{Computer='PC-01'})
        Assert-True ($null -eq $c.MachineCredential -and -not [object]::ReferenceEquals($c.Credential,$local)) ('Compte local transmis a '+$op)
    }
}
Test-Case 'D051 Lecture d une cle BitLocker : compte Secrets de l onglet Comptes, sinon jeton courant' {
    $secrets=New-TestCredential 'EXAMPLE\secrets';$script:SecretsCredential=$secrets
    $ctx=[pscustomobject]@{OperationId='ReadBitLockerKey';Credential=$null;BindUser='EXAMPLE\lecteur';UseCredential=$false;AuthMode='Windows';MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser=''}
    $ctx=Set-DomeniaTargetCredentialContext -Context $ctx -Payload ([pscustomobject]@{DN=$script:Dn;KeyDn='x';KeyGuid='y'})
    Assert-True ([object]::ReferenceEquals($ctx.Credential,$secrets) -and $ctx.UseCredential -and $ctx.BindUser -eq 'EXAMPLE\secrets')
    $search=Set-DomeniaTargetCredentialContext -Context ([pscustomobject]@{OperationId='GlobalSearch';Credential=$null;BindUser='';UseCredential=$false;AuthMode='Windows';MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser=''}) -Payload $null
    Assert-True ($null -eq $search.Credential) 'Le compte Secrets a atteint une lecture de l annuaire'
}
Test-Case 'L01 Presence BitLocker d une OU : compte Secrets, ressource et refus BitLocker, jamais le canal AD' {
    $secrets=New-TestCredential 'EXAMPLE\secrets';$script:SecretsCredential=$secrets
    Assert-True ((Get-DomeniaOperationResource 'BitLockerPresence') -eq 'BitLocker') 'Ressource de la presence BitLocker'
    Assert-True ((Get-DomeniaAccessScope 'BitLockerPresence') -eq (Get-DomeniaAccessScope 'ReadBitLockerList')) 'Refus de la presence hors du compte BitLocker'
    $needs=Get-DomeniaOperationCredentialNeeds 'BitLockerPresence'
    Assert-True ([bool]$needs.Secrets -and [string]$needs.Resource -eq 'BitLocker') 'Besoins de la presence BitLocker'
    $ctx=[pscustomobject]@{OperationId='BitLockerPresence';Credential=$null;BindUser='EXAMPLE\lecteur';UseCredential=$false;AuthMode='Windows';MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser=''}
    $ctx=Set-DomeniaTargetCredentialContext -Context $ctx -Payload ([pscustomobject]@{DN='OU=Postes,DC=example,DC=invalid';Limit=100000})
    Assert-True ([object]::ReferenceEquals($ctx.Credential,$secrets) -and $ctx.UseCredential -and $ctx.BindUser -eq 'EXAMPLE\secrets') 'Le compte Secrets n atteint pas la presence BitLocker de l OU'
    $script:SecretsCredential=$null
}
Test-Case 'D051 WPF : compte d un autre poste refuse dans la page avant tout appel reseau' {
    $script:UseRealDialog=$true
    $script:AccessState.AuthSession=$null
    $password=[guid]::NewGuid().ToString('N')
    $capture=[pscustomobject]@{Status=''}
    $script:DialogScript={param($w)
        $w.FindName('User').Text='PC-02\admin';$w.FindName('Password').Password=$password
        $w.FindName('Connect').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        $capture.Status=[string]$w.FindName('Status').Text
        $w.FindName('User').Text='EXAMPLE\support'
        $w.FindName('Connect').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    }.GetNewClosure()
    $result=Show-DomeniaAlternateCredential -Scope 'Remote' -Operation 'Inventaire' -Target 'PC-01' -OperationId 'ComputerInventory'
    Assert-True ($null -eq $result)
    Assert-True ($capture.Status -match 'autre poste') ('Motif attendu, obtenu : '+$capture.Status)
    Assert-True ($script:RemoteValidations.Count -eq 1 -and $script:RemoteValidations[0] -eq 'EXAMPLE\support') 'Le compte refuse a ete envoye, ou le compte valide ne l a pas ete'
}

# ================================================================ D052 structured, explainable errors
Test-Case 'D052 Memes codes, memes decisions en francais et en anglais' {
    Assert-True ((Get-DomeniaAccessFailureKind 'Accès refusé') -eq 'AccessDenied')
    Assert-True ((Get-DomeniaAccessFailureKind 'Access is denied') -eq 'AccessDenied')
    Assert-True ((Get-DomeniaAccessFailureKind ([Runtime.InteropServices.COMException]::new('x',-2147024891))) -eq 'AccessDenied')
    Assert-True ((Get-DomeniaAccessFailureKind ([Runtime.InteropServices.COMException]::new('x',-2147023570))) -eq 'LogonFailure')
    Assert-True ((Get-DomeniaAccessFailureKind 'The user name or password is incorrect.') -eq 'LogonFailure')
    Assert-True ((Get-DomeniaAccessFailureKind 'Le nom d utilisateur ou le mot de passe est incorrect.') -eq 'LogonFailure')
    Assert-True ((ConvertTo-DomeniaErrorInfo 'Accès refusé' 'Lecture').Kind -eq 'AccessDenied') 'Acces refuse sans HRESULT non classe'
}
Test-Case 'D052 Un delai n est jamais un mauvais mot de passe ; un module absent ne propose pas de compte' {
    Assert-True (-not (Get-DomeniaAccessFailureKind 'RPC timeout serveur injoignable'))
    $info=ConvertTo-DomeniaErrorInfo 'Timeout : identifiant du poste non resolu' 'Lecture'
    Assert-True ($info.Kind -eq 'Timeout') ('Delai classe '+$info.Kind)
    Assert-True (-not (Get-DomeniaAccessFailureKind 'Module Windows LAPS absent. Aucun decryptage possible. Le changement de compte ne remplace pas ce module.'))
    Assert-True ((Get-DomeniaAccessFailureKind 'Le compte ne dispose pas du droit de dechiffrement LAPS.') -eq 'AccessDenied')
    Assert-True ((ConvertTo-DomeniaErrorInfo 'ETAT INCONNU apres envoi au DC.' 'Ecriture').Kind -eq 'Uncertain')
}
Test-Case 'D052 Code natif transporte par le vrai worker jusqu a EndInvoke' {
    $run=Invoke-TestWorker -OperationId 'EngineSelfTest' -Code 'throw [ComponentModel.Win32Exception]::new(1909)' -Context ([pscustomobject]@{OperationId='EngineSelfTest';Server='dc1.example.invalid'}) -Payload $null
    Assert-True ($null -ne $run.Failure) 'Le worker aurait du echouer'
    $structured=Get-DomeniaStructuredError ([string]$run.Failure.Exception.Message)
    Assert-True ($structured.Kind -eq 'AccountLocked' -and -not $structured.CanOfferCredential) ('Code perdu : '+$structured.Kind+' / '+$run.Failure.Exception.Message)
}

# ================================================================ D053 re-authentication without a storm
Test-Case 'D053 Vingt refus simultanes, une seule demande' {
    for($i=0;$i -lt 20;$i++){[void](Request-DomeniaAccessRecovery -Operation 'Lecture LAPS' -OperationId 'ReadLaps' -DN ('CN=PC'+$i+',OU=Postes,DC=example,DC=invalid') -ErrorValue 'Acces refuse' -Interactive)}
    $interactive=@($script:AccessState.Pending.Values|Where-Object{$_.Interactive}).Count
    Assert-True ($interactive -eq 1) ('Demandes interactives : '+$interactive)
    Assert-True ($script:AccessState.Pending.Count -le 16)
}
Test-Case 'D053 Annuler conserve le compte precedent et ne rouvre pas de demande aussitot' {
    $old=New-TestCredential 'EXAMPLE\ancien';$script:AccessState.Credentials['ReadLaps']=$old
    [void](Request-DomeniaAccessRecovery -Operation 'Lecture LAPS' -OperationId 'ReadLaps' -DN $script:Dn -ErrorValue 'Acces refuse' -Interactive)
    $script:Consent=$false
    Invoke-DomeniaAccessRecovery (@($script:AccessState.Pending.Values)[0])
    Assert-True ([object]::ReferenceEquals($script:AccessState.Credentials['ReadLaps'],$old) -and $script:DialogCalls.Count -eq 0)
    $script:Clock=$script:Clock.AddSeconds(10)
    [void](Request-DomeniaAccessRecovery -Operation 'Lecture LAPS' -OperationId 'ReadLaps' -DN 'CN=PC-09,OU=Postes,DC=example,DC=invalid' -ErrorValue 'Acces refuse' -Interactive)
    Assert-True (@($script:AccessState.Pending.Values|Where-Object{$_.Interactive}).Count -eq 0) 'Nouvelle demande juste apres une annulation'
}
Test-Case 'D053 Validation : une seule relance de lecture, jamais d ecriture' {
    $script:NextCredential=New-TestCredential 'EXAMPLE\helper'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    Assert-True (@($script:Tasks|Where-Object{$_.OperationId -eq 'ReadLaps' -and $_.State.RetryAttempt -eq 1}).Count -eq 1) 'Lecture LAPS non relancee une fois'
    Reset-Fixture
    $script:NextCredential=New-TestCredential 'EXAMPLE\helper'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'WriteRename' -Write)
    # Point 45: the validated account may have its other names read (one directory read); no write ever leaves again.
    Assert-True (@($script:Tasks|Where-Object{$_.OperationId -ne 'AccountAliasRead'}).Count -eq 0 -and $script:AccessState.Credentials.ContainsKey('AD:WriteRename')) 'Ecriture rejouee'
    Assert-True (@($script:Tasks|Where-Object{$_.OperationId -eq 'AccountAliasRead'}).Count -le 1) 'Lecture des noms du compte repetee'
}

# ================================================================ D054 identity lifetime
Test-Case 'D054 Delai glissant mesure au depart des workers ; expiration meme pendant une ecriture' {
    $cred=New-TestCredential 'EXAMPLE\helper';$script:NextCredential=$cred
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    $script:Clock=$script:Clock.AddMinutes(25)
    $ctx=Set-DomeniaRetryWorkerContext -Context ([pscustomobject]@{Credential=$null;BindUser='';UseCredential=$false;AuthMode='Windows';MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser=''}) -OperationId 'ReadLaps'
    Assert-True ([object]::ReferenceEquals($ctx.Credential,$cred))
    $script:Clock=$script:Clock.AddMinutes(25)
    Assert-True ([object]::ReferenceEquals((Get-DomeniaRetryCredential 'ReadLaps'),$cred)) 'Le delai doit repartir du dernier usage'
    $script:WriteState='Unknown'
    $script:Clock=$script:Clock.AddMinutes(31)
    Assert-True ($null -eq (Get-DomeniaRetryCredential 'ReadLaps')) 'Compte expire rendu pendant une ecriture incertaine'
    Assert-True ([object]::ReferenceEquals($ctx.Credential,$cred) -and $ctx.Credential.Password.Length -gt 0) 'Le worker deja parti a perdu sa copie'
}
Test-Case 'D054 Une lecture passive ne prolonge pas le compte ; Oublier et nouvelle session le retirent' {
    $cred=New-TestCredential 'EXAMPLE\helper';$script:NextCredential=$cred
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    $start=$script:Clock
    for($m=1;$m -le 29;$m++){$script:Clock=$start.AddMinutes($m);[void](Get-DomeniaRetryCredential 'ReadLaps')}
    $script:Clock=$start.AddMinutes(31)
    Assert-True ([int](Invoke-DomeniaAccessLeaseSweep) -eq 1 -and $null -eq (Get-DomeniaRetryCredential 'ReadLaps')) 'Une lecture passive a prolonge le bail'
    $script:Clock=$start;$script:NextCredential=New-TestCredential 'EXAMPLE\helper2'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadBitLockerKey')
    Clear-DomeniaAccessAccounts -KeepPending
    Assert-True ($null -eq (Get-DomeniaRetryCredential 'ReadBitLockerKey')) 'Oublier sans effet'
    $script:NextCredential=New-TestCredential 'EXAMPLE\helper3'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    $script:SessionEpoch=8L
    Assert-True ($null -eq (Get-DomeniaRetryCredential 'ReadLaps')) 'Compte d une session precedente reutilise'
}

# ================================================================ D055 Windows sign-in without elevation
Test-Case 'D055 Lecture LAPS avec le jeton Windows courant, sans demande de compte' {
    Start-LoadComputerSecrets -Mode LAPS
    Assert-True ($script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -eq 'ReadLaps') 'Lecture non lancee'
    Assert-True ($script:Tasks[0].StatusText -match 'Jeton Windows courant') ('Identite non expliquee : '+$script:Tasks[0].StatusText)
    Assert-True ($script:AccessState.Pending.Count -eq 0 -and $script:ConfirmCalls.Count -eq 0) 'Saisie demandee sans necessite'
}
Test-Case 'D055 Apres un refus, un autre compte est demande au bon moment et une seule fois' {
    $alternate=New-TestCredential 'EXAMPLE\helper';$script:AccessState.Credentials['ReadLaps']=$alternate
    Set-DomeniaSecretDenied -Mode 'LAPS' -DN $script:Dn
    Start-LoadComputerSecrets -Mode LAPS
    Assert-True ($script:Tasks.Count -eq 0) 'Le compte refuse a ete reutilise'
    Assert-True (@($script:AccessState.Pending.Values|Where-Object{$_.Interactive -and $_.Scope -eq 'ReadLaps'}).Count -eq 1)
}

# ================================================================ D056 explained capabilities
Test-Case 'D056 WPF : bouton grise avec motif et route sure vers le prerequis' {
    $script:SelectedObject=$null
    Update-DomeniaSecretActionUi
    $laps=$script:Ctrl.BtnLoadLaps
    Assert-True (-not $laps.IsEnabled) 'LAPS actif sans poste'
    Assert-True ([string]$laps.ToolTip -match 'Selectionnez d abord un objet') ('Motif : '+[string]$laps.ToolTip)
    $route=$script:Ctrl.BtnSecretsPrerequisite
    Assert-True ($route.Visibility -eq [Windows.Visibility]::Visible -and [string]$route.Content -match 'Rechercher') 'Route vers le prerequis absente'
    $route.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-True (@($script:Routes|Where-Object{$_ -like 'WsSearch|*'}).Count -ge 1) 'La route ne mene pas a Rechercher'
}
Test-Case 'D056 Chaque route des explications se resout vers un controle reel du XAML principal' {
    foreach($state in @('Unknown','Refused','ReadOnly','Busy','NoSelection','Stale')){
        $x=Get-DomeniaCapabilityExplanation -Action 'Test' -State $state
        $target=Resolve-DomeniaCapabilityRoute -Route ([string]$x.Route)
        Assert-True ($null -ne $target) ('Route non resolue : '+$x.Route)
        foreach($n in @($target.Workspace,$target.Inner,$target.Tab,$target.Focus)){if($n){Assert-True ($null -ne $script:MainWindow.FindName($n)) ('Controle absent : '+$n)}}
    }
    $script:SelectedObject=$null;Update-DomeniaSecretActionUi;$lines=Get-DomeniaUnavailableReasonLines
    Assert-True (@($lines.Lines|Where-Object{($_ -match 'Lire le mot de passe LAPS') -and ($_ -match 'Aller a : Rechercher')}).Count -eq 1) 'Bilan sans motif ni route pour LAPS'
    Assert-True (@($lines.Routes) -contains 'WsSearch')
}
Test-Case 'D056 Une estimation ACL ne bloque pas et ne se presente pas comme un droit definitif' {
    $script:CurrentCapabilities['Secrets']='Refuse'
    Update-DomeniaSecretActionUi
    Assert-True ($script:Ctrl.BtnLoadBitLocker.IsEnabled) 'Estimation ACL bloquante'
    Assert-True ([string]$script:Ctrl.BtnLoadBitLocker.ToolTip -match 'connu qu a l execution')
}

# ================================================================ D057 LAPS: read and decryption are distinct
Test-Case 'D057 Dechiffrement refuse : publie et lu, ni mot de passe vide ni panne du compte' {
    $state=New-SecretState 'LAPS'
    $meta=[pscustomobject]@{Source='WindowsLaps';Published=$true;ExpirationUtc=$script:Clock.AddDays(3).ToString('o');Account='Administrateur';Decryptor='EXAMPLE\LAPS-Readers';PasswordPresent=$false;ReadStatus='OK';DecryptStatus='Unauthorized';Reader='EXAMPLE\lecteur'}
    Complete-DomeniaSecretLoadUi ([pscustomobject]@{Rows=@();Mode='LAPS';Success=$false;ErrorKind='DecryptionDenied';ErrorMessage='Le compte ne dispose pas du droit de dechiffrement LAPS.';ModuleState='Disponible';ModuleDetail='';Meta=$meta}) $state
    Assert-True ([string]$script:Ctrl.LblSecretsStatus.Text -match 'publie et lu') ('Texte : '+$script:Ctrl.LblSecretsStatus.Text)
    Assert-True ([string]$script:Ctrl.LblSecretsStatus.Text -match 'LAPS-Readers') 'Dechiffreur autorise non montre'
    Assert-True (-not (Test-DomeniaSecretDenied 'LAPS' $script:Dn) -and -not (Test-DomeniaSecretDenied 'BitLocker' $script:Dn)) 'Refus de lecture deduit d un refus de dechiffrement'
    Assert-True ($script:AccessState.Faults.Count -eq 0) 'Panne globale du compte'
    Assert-True (@($script:AccessState.Pending.Values|Where-Object{$_.Scope -eq 'ReadLaps'}).Count -eq 1) 'Autre compte non propose'
}
Test-Case 'D057 Module absent : prerequis explique, aucun compte propose' {
    $state=New-SecretState 'LAPS'
    Complete-DomeniaSecretLoadUi ([pscustomobject]@{Rows=@();Mode='LAPS';Success=$false;ErrorKind='ModuleMissing';ErrorMessage='Module Windows LAPS absent. Aucun decryptage possible.';ModuleState='Non requis';ModuleDetail='';Meta=[pscustomobject]@{ReadStatus='ModuleMissing';Reader='EXAMPLE\lecteur'}}) $state
    Assert-True ([string]$script:Ctrl.LblSecretsStatus.Text -match 'Module LAPS absent')
    Assert-True ($script:AccessState.Pending.Count -eq 0) 'Un compte est propose pour un module absent'
}
Test-Case 'D057 Corps ReadLaps : metadonnees sans mot de passe et refus de dechiffrement distinct' {
    $fn=@($script:CoreAst.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-LoadComputerSecrets'},$true))[0]
    $bodies=@($fn.FindAll({param($a)$a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.StringConstantType -eq 'SingleQuotedHereString'},$true))
    Assert-True ($bodies.Count -eq 2) 'Deux corps attendus dans Start-LoadComputerSecrets'
    $laps=[string]$bodies[1].Value
    Assert-True ($laps -match "errorKind='DecryptionDenied'" -and $laps -match 'Meta=\$meta') 'Refus de dechiffrement ou metadonnees absents'
    $metaLine=@($laps -split "`n"|Where-Object{$_ -match '^\$meta='})[0]
    Assert-True ($metaLine -notmatch '\$plain|\$legacy|\$o\.p|Value') 'Les metadonnees transportent une valeur'
}

# ================================================================ D058 BitLocker: pick the right key
Test-Case 'D058 Ouvrir BitLocker lit les metadonnees, aucune cle' {
    Start-LoadComputerSecrets -Mode BitLocker
    Assert-True ($script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -eq 'ReadBitLockerList') ('Operation : '+$script:Tasks[0].OperationId)
    Assert-True ($script:Tasks[0].Code -notmatch 'msFVE-RecoveryPassword') 'La liste demande les cles'
    # PF-10: the flags are kept per configuration object; a configuration changed in place starts a new generation.
    $script:Config['Features.BitLockerKeySelection']=$false;$script:DomeniaFeatureFlagCache=$null;$script:Tasks.Clear()
    Start-LoadComputerSecrets -Mode BitLocker
    Assert-True ($script:Tasks[0].OperationId -eq 'ReadBitLocker') 'Interrupteur sans effet'
}
Test-Case 'D058 Recherche par identifiant de recuperation puis lecture d une seule cle' {
    $state=New-SecretState 'BitLocker'
    $k1='CN=2025-03-01T10:22:33-00:00{A1B2C3D4-1111-2222-3333-444455556666},'+$script:Dn
    $k2='CN=2025-06-01T08:00:00-00:00{A1B2FFFF-1111-2222-3333-444455556666},'+$script:Dn
    Complete-DomeniaBitLockerListUi ([pscustomobject]@{Mode='BitLockerList';Success=$true;Entries=@([pscustomobject]@{Name=($k1.Split(',')[0].Substring(3));DN=$k1;RecoveryGuid='a1b2c3d4-1111-2222-3333-444455556666';WhenCreated=$null},[pscustomobject]@{Name=($k2.Split(',')[0].Substring(3));DN=$k2;RecoveryGuid='a1b2ffff-1111-2222-3333-444455556666';WhenCreated=$null});RecoveryObjectsFound=2;ErrorKind='';ErrorMessage='';Reader='EXAMPLE\lecteur'}) $state
    Assert-True (@($script:SecretRows).Count -eq 2 -and @($script:SecretRows|Where-Object{$_.Value}).Count -eq 0) 'Une cle a ete chargee a l ouverture'
    $script:Ctrl.TxtBitLockerRecoveryId.Text='A1B2C3D4'
    [void](Invoke-DomeniaBitLockerRecoveryIdFilter)
    Assert-True ([int]$script:Ctrl.DgSecrets.SelectedItem.SecretIndex -eq 0) 'Identifiant non retrouve'
    Toggle-SecretsVisibility
    Assert-True ($script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -eq 'ReadBitLockerKey' -and $script:Tasks[0].Payload.KeyDn -eq $k1) 'Lecture d une seule cle attendue'
    $value=(1..8|ForEach-Object{Get-Random -Minimum 100000 -Maximum 999999}) -join '-'
    Complete-DomeniaBitLockerKeyUi ([pscustomobject]@{Mode='BitLockerKey';Success=$true;Rows=@([pscustomobject]@{Kind='BitLocker';Account='A1B2C3D4-1111-2222-3333-444455556666';Value=$value;Timestamp='';Source='x';Detail=$k1});KeyDn=$k1;KeyGuid='A1B2C3D4-1111-2222-3333-444455556666';ErrorKind='';ErrorMessage=''}) $script:Tasks[0].State
    $bound=@($script:Ctrl.DgSecrets.ItemsSource)
    # UX-18: the key read is shown in its card, by blocks; the narrow cell of the grid only points to it.
    Assert-True ($bound[0].DisplayValue -ceq 'Affichée dans la carte ci-dessus' -and [string]$bound[1].DisplayValue -eq '') 'Seule la cle choisie doit etre lue et affichee'
    Assert-True ((@($script:Ctrl.BitLockerKeyBlocks.ItemsSource|ForEach-Object{$_.Digits}) -join '-') -ceq $value) 'Cle absente de la carte'
    Assert-True ($script:SecretRevealTimer.Interval.TotalSeconds -eq 30)
}
Test-Case 'D058 Vrais workers : liste sans attribut de cle, cle unique controlee' {
    $k1='CN=K1,'+$script:Dn
    $guid=[guid]'a1b2c3d4-1111-2222-3333-444455556666'
    $directory=@{}
    $marker=[guid]::NewGuid().ToString('N')
    # The fake directory returns the key even when it is not requested: the list worker must still not carry it.
    $directory[$script:Dn]=@(@{name=@('2025{A1B2C3D4-1111-2222-3333-444455556666}');distinguishedname=@($k1);'msfve-recoveryguid'=@(,$guid.ToByteArray());'msfve-recoverypassword'=@($marker);whencreated=@([datetime]'2025-03-01')})
    $directory[$k1]=@(@{distinguishedname=@($k1);'msfve-recoveryguid'=@(,$guid.ToByteArray());'msfve-recoverypassword'=@($marker);whencreated=@([datetime]'2025-03-01')})
    $context=[pscustomobject]@{OperationId='ReadBitLockerList';Server='dc1.example.invalid';BindUser='EXAMPLE\lecteur';ProcessIdentity='EXAMPLE\lecteur';PageSize=100;FakeDirectory=$directory;ForbiddenAttribute='msFVE-RecoveryPassword';SearchMustNotRun=$false}
    $list=Invoke-TestWorker -OperationId 'ReadBitLockerList' -Code (Get-DomeniaBitLockerListWorkerCode) -Context $context -Payload ([pscustomobject]@{DN=$script:Dn})
    Assert-True ($null -eq $list.Failure) ([string]$list.Failure)
    $r=@($list.Output)[-1]
    Assert-True ($r.Success -and @($r.Entries).Count -eq 1 -and $r.Entries[0].RecoveryGuid -eq 'a1b2c3d4-1111-2222-3333-444455556666') ('Liste : '+$r.ErrorMessage)
    Assert-True (-not (($r|ConvertTo-Json -Depth 5) -match $marker)) 'La liste transporte une cle'
    $context.OperationId='ReadBitLockerKey';$context.ForbiddenAttribute=''
    $key=Invoke-TestWorker -OperationId 'ReadBitLockerKey' -Code (Get-DomeniaBitLockerKeyWorkerCode) -Context $context -Payload ([pscustomobject]@{DN=$script:Dn;KeyDn=$k1;KeyGuid='A1B2C3D4-1111-2222-3333-444455556666'})
    $kr=@($key.Output)[-1]
    Assert-True ($kr.Success -and @($kr.Rows).Count -eq 1 -and $kr.Rows[0].Value -ceq $marker) 'Cle choisie non lue'
    $wrong=Invoke-TestWorker -OperationId 'ReadBitLockerKey' -Code (Get-DomeniaBitLockerKeyWorkerCode) -Context $context -Payload ([pscustomobject]@{DN=$script:Dn;KeyDn=$k1;KeyGuid='FFFFFFFF-1111-2222-3333-444455556666'})
    $wr=@($wrong.Output)[-1]
    Assert-True (-not $wr.Success -and $wr.ErrorKind -eq 'Mismatch' -and -not (($wr|ConvertTo-Json -Depth 5) -match $marker)) 'Identifiant different : une valeur est sortie'
    $context.SearchMustNotRun=$true
    $outside=Invoke-TestWorker -OperationId 'ReadBitLockerKey' -Code (Get-DomeniaBitLockerKeyWorkerCode) -Context $context -Payload ([pscustomobject]@{DN=$script:Dn;KeyDn=('CN=K9,CN=PC-02,OU=Postes,DC=example,DC=invalid');KeyGuid='A1B2C3D4-1111-2222-3333-444455556666'})
    Assert-True ($null -ne $outside.Failure -and [string]$outside.Failure.Exception.Message -match 'n appartient pas au poste') 'Cle d un autre poste lue'
}
Test-Case 'D058 Operations ReadBitLockerList, ReadBitLockerKey et ReadLaps epinglees dans le registre' {
    [void](Assert-DomeniaWorkerOperationCode -OperationId 'ReadBitLockerList' -Code (Get-DomeniaBitLockerListWorkerCode))
    [void](Assert-DomeniaWorkerOperationCode -OperationId 'ReadBitLockerKey' -Code (Get-DomeniaBitLockerKeyWorkerCode))
    $fn=@($script:CoreAst.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Start-LoadComputerSecrets'},$true))[0]
    $bodies=@($fn.FindAll({param($a)$a -is [Management.Automation.Language.StringConstantExpressionAst] -and $a.StringConstantType -eq 'SingleQuotedHereString'},$true))
    [void](Assert-DomeniaWorkerOperationCode -OperationId 'ReadLaps' -Code ([string]$bodies[1].Value))
    [void](Assert-DomeniaWorkerOperationCode -OperationId 'ReadBitLocker' -Code ([string]$bodies[0].Value))
}

# ================================================================ D059 secret exposure
Test-Case 'D059 Marqueurs factices absents du journal reel' {
    $m=[guid]::NewGuid().ToString('N')
    foreach($text in @(('secret='+$m),('motdepasse='+$m),('cmd -pass '+$m),('cmd /password '+$m),('{"p":"'+$m+'"}'),('/p '+$m),('-p:'+$m),('Bearer '+$m),('client_secret='+$m),('api-key='+$m),('password="'+$m+'"'))){Write-AppLog $text 'INFO'}
    $bitlocker=(1..8|ForEach-Object{Get-Random -Minimum 100000 -Maximum 999999}) -join '-'
    Write-AppLog ('cle '+$bitlocker) 'INFO'
    $journal=[IO.File]::ReadAllText($script:AuditPath)
    Assert-True (-not (Test-DomeniaTextHasSecret $journal @($m,$bitlocker))) 'Un marqueur est present dans le journal'
    Assert-True (-not (Test-DomeniaTextHasSecret ($script:UiLog -join "`n") @($m,$bitlocker))) 'Un marqueur est present dans le journal d interface'
    Assert-True (-not (Test-DomeniaTextHasSecret ($script:Ctrl.TxtLog.Text) @($m,$bitlocker))) 'Un marqueur est present dans le journal visible'
    Remove-Item -LiteralPath $script:AuditPath -Force -ErrorAction SilentlyContinue
}
Test-Case 'D059 Masquage du journal sans modules charges (amorcage)' {
    $ps=[Management.Automation.PowerShell]::Create()
    try{
        [void]$ps.AddScript($script:RealProtectLog+"`r`nProtect-DomeniaLogText 'password=VALEUR-TEST-AMORCE'")
        $out=@($ps.Invoke())
        Assert-True ($ps.Streams.Error.Count -eq 0) 'Erreur sans modules'
        Assert-True ([string]$out[0] -notmatch 'VALEUR-TEST-AMORCE')
    }finally{$ps.Dispose()}
}
Test-Case 'D059 Une seule valeur revelee, 30 s, copie groupee desactivee et limite du presse-papiers explicite' {
    $a=[guid]::NewGuid().ToString('N');$b=[guid]::NewGuid().ToString('N')
    $script:SecretRows=@([pscustomobject]@{Kind='LAPS';Account='a';Value=$a;Timestamp='';Source='s';Detail=''},[pscustomobject]@{Kind='LAPS';Account='b';Value=$b;Timestamp='';Source='s';Detail=''})
    Update-SecretsGrid
    $script:Ctrl.DgSecrets.SelectedItem=@($script:Ctrl.DgSecrets.Items)[1]
    Toggle-SecretsVisibility
    $bound=@($script:Ctrl.DgSecrets.ItemsSource)
    Assert-True ($bound[0].DisplayValue -ceq '********' -and $bound[1].DisplayValue -ceq $b) 'Plusieurs valeurs revelees'
    Assert-True ($script:SecretRevealTimer.Interval.TotalSeconds -eq 30) 'Duree de revelation'
    Update-DomeniaSecretActionUi
    Assert-True ((-not $script:Ctrl.BtnCopyAllSecrets.IsEnabled) -and ($script:Ctrl.BtnCopyAllSecrets.Visibility -eq [Windows.Visibility]::Collapsed)) 'Copie groupee proposee'
    Copy-AllSecrets
    Assert-True ($script:Clipboard.Count -eq 0) 'Copie groupee executee'
    Copy-SelectedSecret
    Assert-True ($script:Clipboard.Count -eq 1 -and $script:Clipboard[0] -ceq $b) 'Copie de la seule valeur choisie'
    Assert-True (@($script:ConfirmCalls|Where-Object{$_ -match 'historique'}).Count -eq 1) 'Limite du presse-papiers non explicite'
}

# ================================================================ D060 visible transport policy
Test-Case 'D060 Politique de transport affichee dans Comptes, consentement cible visible' {
    [void](Update-DomeniaTransportPolicyView -Force)
    $rows=@($script:Ctrl.DgTransportPolicy.ItemsSource)
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'PsExec' -and $_.Etat -match 'Inactif sans autorisation explicite'}).Count -eq 1) 'PsExec actif sans consentement'
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'CIM / WSMan' -and $_.Regle -match 'jamais'}).Count -eq 1)
    $script:ArtifactConsent=[pscustomobject]@{Target='pc-01.example.invalid';Aliases=@('PC-01');Epoch=[long]$script:SessionEpoch;Expires=[datetime]::UtcNow.AddMinutes(5)}
    [void](Update-DomeniaTransportPolicyView)
    $rows=@($script:Ctrl.DgTransportPolicy.ItemsSource)
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'PsExec' -and $_.Etat -match 'Autorise'}).Count -eq 1) 'Consentement non reflete'
    Assert-True ([string]$script:Ctrl.LblTransportPolicy.Text -match 'pc-01') 'Poste du consentement non indique'
}
Test-Case 'D060 Bilan des indisponibilites : transports et absence de reglage Windows modifie' {
    $lines=@((Get-DomeniaUnavailableReasonLines).Lines)
    Assert-True (@($lines|Where-Object{$_ -match 'WinRM n est jamais active'}).Count -eq 1)
    Assert-True (@($lines|Where-Object{$_ -match 'aucun reglage Windows modifie'}).Count -eq 1)
}

# ================================================================ Point 46 required right and three distinct causes
Test-Case 'P46 Erreur affichee : refus d acces cite le droit, compte rejete et indisponibilite ne le citent pas' {
    $previous=$script:AccessCurrentJob
    try{
        $script:AccessCurrentJob=[pscustomobject]@{OperationId='ReadLaps';SessionEpoch=[long]$script:SessionEpoch;IsWrite=$false;CallbackState=$null}
        $denied=Show-DomeniaOperationError -Operation 'Lecture LAPS' -ErrorRecordOrException ([ComponentModel.Win32Exception]::new(5)) -NoPopup
        Assert-True ([string]$denied.FailureFamily -eq 'AccessDenied') ('Famille : '+[string]$denied.FailureFamily)
        Assert-True ([string]$denied.Friendly -match 'Droit requis') 'Le refus ne cite pas le droit requis'
        Assert-True ([string]$denied.Friendly -match 'LAPS') 'Le droit cite n est pas celui de LAPS'
        $rejected=Show-DomeniaOperationError -Operation 'Lecture LAPS' -ErrorRecordOrException ([ComponentModel.Win32Exception]::new(1326)) -NoPopup
        Assert-True ([string]$rejected.FailureFamily -eq 'AccountRejected') ('Famille : '+[string]$rejected.FailureFamily)
        Assert-True ([string]$rejected.Friendly -notmatch 'Droit requis') 'Un compte rejete est presente comme un droit manquant'
        $script:AccessCurrentJob=$null
        $network=Show-DomeniaOperationError -Operation 'Inventaire poste' -OperationId 'ComputerInventory' -ErrorRecordOrException ([ComponentModel.Win32Exception]::new(1722)) -NoPopup
        Assert-True ([string]$network.FailureFamily -eq 'Unavailable') ('Famille : '+[string]$network.FailureFamily)
        Assert-True ([string]$network.Friendly -match '135/TCP') 'L acces reseau necessaire n est pas cite'
        Assert-True ([string]$network.Friendly -notmatch 'Droit requis')
    }finally{$script:AccessCurrentJob=$previous}
}
Test-Case 'P46 Panneau des operations : chaque ligne annonce l acces requis' {
    $job=[pscustomobject]@{Id='p46';Name='Inventaire';OperationId='ComputerInventory';IsWrite=$false;NonCancellable=$false;CancelRequested=$false;SessionEpoch=[long]$script:SessionEpoch;State='Running';Started=(Get-Date);TimeoutNotified=$false;TimeoutErrorDelivered=$false}
    if($null -eq (Get-Command Get-DomeniaExperienceTaskRow -ErrorAction SilentlyContinue)){. (Join-Path (Join-Path $wad 'modules') 'Domenia-Experience.Model.ps1')}
    $row=Get-DomeniaExperienceTaskRow $job -SessionEpoch ([long]$script:SessionEpoch)
    Assert-True ([string]$row.Detail -match 'Accès requis : Administrateur local') ('Detail : '+[string]$row.Detail)
}

# ================================================================ Points 42, 44, 45 accounts without reconnecting
function New-P44Guard {
    $script:DomeniaCredentialGuard=$null;$script:DomeniaAccountAlias=$null;$script:DomeniaCredentialAliasBook=$null
    return (Initialize-DomeniaCredentialGuard)
}
Test-Case 'P44 Correction sans reconnexion : generation, pause levee pour ce seul compte, lectures anciennes arretees' {
    $script:Stops=[Collections.Generic.List[string]]::new()
    function Request-UiTaskStop {param([string]$Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,[string]$Reason) $script:Stops.Add($Id)}
    $script:DomeniaAccountGeneration=10L
    $guard=New-P44Guard
    $guard.Faults['postes@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
    $guard.Faults['autre@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
    $ctx={param([string]$Key,[long]$Generation)[pscustomobject]@{CredentialGuard=$guard;DirectoryAuthKey='';RemoteAuthKey=$Key;RemoteAdminAuthKey=$Key;ActiveRemoteAuthKey=$Key;OperationId='ComputerInventory';CredentialGeneration=$Generation}}
    $previousJobs=$script:AsyncJobs
    try{
        $script:AsyncJobs=[ordered]@{
            'old'=[pscustomobject]@{Id='old';IsWrite=$false;NonCancellable=$false;State='Running';CredentialGuardContext=(& $ctx 'postes@example.invalid' 10)}
            'write'=[pscustomobject]@{Id='write';IsWrite=$true;NonCancellable=$false;State='Running';CredentialGuardContext=(& $ctx 'postes@example.invalid' 10)}
            'other'=[pscustomobject]@{Id='other';IsWrite=$false;NonCancellable=$false;State='Running';CredentialGuardContext=(& $ctx 'autre@example.invalid' 10)}
        }
        $text=[string](Complete-DomeniaAccountCorrection -UserName 'EXAMPLE\postes' -Scopes @('Remote')).Text
        Assert-True ([long]$script:DomeniaAccountGeneration -eq 11) 'Generation inchangee'
        Assert-True (-not $guard.Faults.ContainsKey('postes@example.invalid')) 'Pause du compte corrige conservee'
        Assert-True ($guard.Faults.ContainsKey('autre@example.invalid')) 'Pause d un autre compte levee'
        Assert-True (($script:Stops -join ',') -eq 'old') ('Arrets : '+($script:Stops -join ','))
        Assert-True ($text -match 'Protection levée pour ce compte seulement') $text
        $blocked=$false;try{Assert-WCredentialAllowed $script:AsyncJobs['old'].CredentialGuardContext Remote}catch{$blocked=$true}
        Assert-True $blocked 'Un travail parti avant la correction peut encore envoyer l ancien mot de passe'
        Assert-WCredentialAllowed (& $ctx 'postes@example.invalid' 11) Remote
        Assert-True (@($script:Tasks|Where-Object{$_.OperationId -eq 'AccountAliasRead'}).Count -eq 1) 'Noms du compte non relus apres validation'
    }finally{$script:AsyncJobs=$previousJobs}
}
Test-Case 'P44 Compte de connexion refuse : correction proposee dans Comptes, sans reconnexion ; session Windows : connexion' {
    $script:Conn.UseCredential=$true;$script:Conn.AuthMode='Explicit';$script:Conn.Credential=New-TestCredential 'EXAMPLE\lecteur'
    $record=[pscustomobject]@{Key='Directory|';Scope='Directory';OperationId='GlobalSearch';Operation='Recherche';DN='';Target='';Kind='LogonFailure';Epoch=[long]$script:SessionEpoch;Generation=[long]$script:SelectedObjectGeneration;IsWrite=$false;Interactive=$true;At=$script:Clock}
    Invoke-DomeniaAccessRecovery $record
    Assert-True ($script:Relogins -eq 0) 'Reconnexion imposee alors que le compte se corrige sur place'
    Assert-True (@($script:Routes|Where-Object{$_ -like 'TabAccounts*'}).Count -eq 1) 'Pas de route vers Comptes'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'Corriger le mot de passe'}).Count -ge 1) 'Geste de correction non indique'
    $script:Conn.UseCredential=$false;$script:Conn.AuthMode='Windows';$script:Conn.Credential=$null
    Invoke-DomeniaAccessRecovery $record
    Assert-True ($script:Relogins -eq 1) 'Session Windows sans fenetre de connexion'
}
Test-Case 'P44 Correction du compte de connexion : identite de la session seulement, une validation, mot de passe remplace en place' {
    $script:Conn.UseCredential=$true;$script:Conn.AuthMode='Explicit';$script:Conn.Credential=New-TestCredential 'EXAMPLE\lecteur'
    # CO-31 x point 44: the Annuaire card has no identity field; the correction always validates the session identity.
    Assert-True (-not $script:Ctrl.ContainsKey('TxtAccountAdUser')) 'Champ d identifiant encore dans la carte Annuaire'
    $failed=$false;try{Start-DomeniaDirectoryCorrection}catch{$failed=([string]$_.Exception.Message -match 'mot de passe actuel')}
    Assert-True $failed 'Correction lancee sans mot de passe'
    Assert-True ($script:DirectoryValidations.Count -eq 0) 'Un essai est parti sans mot de passe'
    # Runtime-generated throw-away value typed in the real PasswordBox: nothing secret is stored in the repository.
    $script:Ctrl.PwdAccountAdCorrection.Password=[guid]::NewGuid().ToString('N')
    $previousCredential=$script:Conn.Credential
    $script:DomeniaAccountGeneration=20L;$guard=New-P44Guard
    $guard.Faults['lecteur@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
    $script:DirectoryCredentialFaulted=$true
    function Set-ControlsBusy {param([string[]]$Names,[bool]$Busy)}
    function Read-DomeniaAuthRunspaceResult {param($Session) return [pscustomobject]@{Success=$true;AuthMode='Explicit';BindUser='EXAMPLE\lecteur';BaseDn='DC=example,DC=invalid';Error=''}}
    try{
        Start-DomeniaDirectoryCorrection
        Assert-True ($script:DirectoryValidations.Count -eq 1 -and $script:DirectoryValidations[0] -eq 'EXAMPLE\lecteur') ('Validations : '+($script:DirectoryValidations -join ','))
        $script:AccountValidation.Session.AsyncResult.IsCompleted=$true
        Complete-DomeniaAccountValidation
        Assert-True (-not [object]::ReferenceEquals($script:Conn.Credential,$previousCredential)) 'Mot de passe de session non remplace'
        Assert-True ([string]$script:Conn.Credential.UserName -eq 'EXAMPLE\lecteur') 'Identite de session changee'
        Assert-True (-not [bool]$script:DirectoryCredentialFaulted) 'Canal AD toujours suspendu'
        Assert-True (-not $guard.Faults.ContainsKey('lecteur@example.invalid')) 'Pause du compte de connexion conservee'
        Assert-True ($script:Ctrl.PwdAccountAdCorrection.SecurePassword.Length -eq 0) 'Champ du mot de passe non vide'
        Assert-True (@($script:StatusLines|Where-Object{$_ -match 'sans reconnecter'}).Count -ge 1) 'Correction non annoncee'
    }finally{
        if($null -ne $script:AccountValidation){try{$script:AccountValidation.Timer.Stop()}catch{};$script:AccountValidation=$null}
        $script:Ctrl.PwdAccountAdCorrection.Clear()
    }
}
Test-Case 'P44 Correction du compte de connexion : une validation qui revient pour une autre identite ne remplace rien' {
    $script:Conn.UseCredential=$true;$script:Conn.AuthMode='Explicit';$script:Conn.Credential=New-TestCredential 'EXAMPLE\lecteur'
    $previousCredential=$script:Conn.Credential
    $script:Ctrl.PwdAccountAdCorrection.Password=[guid]::NewGuid().ToString('N')
    function Set-ControlsBusy {param([string[]]$Names,[bool]$Busy)}
    function Read-DomeniaAuthRunspaceResult {param($Session) return [pscustomobject]@{Success=$true;AuthMode='Explicit';BindUser='EXAMPLE\autre';BaseDn='DC=example,DC=invalid';Error=''}}
    try{
        Start-DomeniaDirectoryCorrection
        Assert-True ($script:DirectoryValidations.Count -eq 1 -and $script:DirectoryValidations[0] -eq 'EXAMPLE\lecteur') ('Validations : '+($script:DirectoryValidations -join ','))
        $script:AccountValidation.Session.AsyncResult.IsCompleted=$true
        Complete-DomeniaAccountValidation
        Assert-True ([object]::ReferenceEquals($script:Conn.Credential,$previousCredential)) 'Mot de passe de session remplace par celui d une autre identite'
        Assert-True (@($script:StatusLines|Where-Object{$_ -match 'sans reconnecter'}).Count -eq 0) 'Correction annoncee pour une autre identite'
    }finally{
        if($null -ne $script:AccountValidation){try{$script:AccountValidation.Timer.Stop()}catch{};$script:AccountValidation=$null}
        $script:Ctrl.PwdAccountAdCorrection.Clear()
    }
}
Test-Case 'P44 Anti-verrouillage : le compte de connexion saisi pour LAPS ne leve pas la pause tant qu il garde l ancien mot de passe' {
    $script:Conn.UseCredential=$true;$script:Conn.AuthMode='Explicit';$script:Conn.Credential=New-TestCredential 'EXAMPLE\lecteur'
    $script:DomeniaAccountGeneration=30L;$guard=New-P44Guard
    $guard.Faults['lecteur@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow;Generation=29L}
    $script:NextCredential=New-TestCredential 'EXAMPLE\lecteur'
    Invoke-DomeniaAccessRecovery (New-AccessRecord 'ReadLaps')
    Assert-True ([object]::ReferenceEquals($script:AccessState.Credentials['ReadLaps'],$script:NextCredential)) 'Compte LAPS non memorise'
    Assert-True ($guard.Faults.ContainsKey('lecteur@example.invalid')) 'Pause levee : le compte de connexion renverrait le mot de passe refuse'
    Assert-True (-not (($guard.ContainsKey('Released')) -and ($guard.Released.ContainsKey('lecteur@example.invalid')))) 'Compte libere pour les operations anciennes'
    Assert-True (@($script:StatusLines|Where-Object{($_ -match 'Pause maintenue') -and ($_ -match 'Corriger le mot de passe')}).Count -ge 1) ('Statut : '+($script:StatusLines -join ' | '))
    Assert-True (@($script:Tasks|Where-Object{$_.OperationId -eq 'AccountAliasRead'}).Count -eq 0) 'Noms relus avec un compte en pause'
    Assert-True (@($script:Tasks|Where-Object{$_.OperationId -eq 'ReadLaps'}).Count -eq 0) 'Lecture LAPS rejouee alors que le compte reste en pause'
}
Test-Case 'P45 Vrai worker : SID et noms d un seul compte, aucune association si plusieurs comptes' {
    $sid=[Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1104');$bytes=[byte[]]::new($sid.BinaryLength);$sid.GetBinaryForm($bytes,0)
    $directory=@{};$directory['DC=example,DC=invalid']=@(@{objectsid=@(,$bytes);samaccountname=@('jdupont');userprincipalname=@('jean.dupont@corp.example.com');distinguishedname=@('CN=Jean Dupont,OU=U,DC=example,DC=invalid')})
    $context=[pscustomobject]@{OperationId='AccountAliasRead';BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';BindUser='EXAMPLE\lecteur';ProcessIdentity='EXAMPLE\lecteur';PageSize=100;FakeDirectory=$directory;ForbiddenAttribute='unicodePwd';SearchMustNotRun=$false}
    $run=Invoke-TestWorker -OperationId 'AccountAliasRead' -Code (Get-DomeniaAccountAliasWorkerCode) -Context $context -Payload ([pscustomobject]@{Sam='jdupont';Upn=''})
    Assert-True ($null -eq $run.Failure) ([string]$run.Failure)
    $r=@($run.Output)[-1]
    Assert-True ($r.State -eq 'Resolved' -and $r.Sid -eq 'S-1-5-21-1-2-3-1104' -and $r.Upn -eq 'jean.dupont@corp.example.com') ('Etat : '+[string]$r.State)
    $directory['DC=example,DC=invalid']+=@(@{objectsid=@(,$bytes);samaccountname=@('jdupont2');userprincipalname=@('x@corp.example.com');distinguishedname=@('CN=X,DC=example,DC=invalid')})
    $two=@((Invoke-TestWorker -OperationId 'AccountAliasRead' -Code (Get-DomeniaAccountAliasWorkerCode) -Context $context -Payload ([pscustomobject]@{Sam='jdupont';Upn=''})).Output)[-1]
    Assert-True ($two.State -eq 'Ambiguous' -and -not $two.Sid) 'Deux comptes : un SID est associe quand meme'
}
Test-Case 'P45 Resultat du worker : alias enregistres et pause etendue, compte autre jamais touche' {
    $guard=New-P44Guard
    $guard.Faults['jdupont@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
    $script:SyncCalls=0
    function Sync-DomeniaCredentialGuardUi {$script:SyncCalls++}
    $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;BaseDn='DC=example,DC=invalid';UserName='EXAMPLE\jdupont';Key='jdupont@example.invalid'}
    $result=[pscustomobject]@{State='Resolved';Count=1;Sid='S-1-5-21-1-2-3-1104';Sam='jdupont';Upn='jean.dupont@corp.example.com';Dn='CN=Jean Dupont,DC=example,DC=invalid';RequestSam='jdupont';RequestUpn='';ObservedUtc=''}
    Complete-DomeniaAccountAliasRead $result $state
    Assert-True ([string]$guard.Aliases['jean.dupont@corp.example.com'] -eq 'sid:S-1-5-21-1-2-3-1104') 'UPN non rapproche'
    Assert-True ($guard.Faults.ContainsKey('jean.dupont@corp.example.com')) 'Pause non etendue a l UPN'
    Assert-True ($script:SyncCalls -eq 1) 'Lectures en file de l alias non retirees'
    Assert-True ((@(Get-DomeniaAccountAliasSummary|ForEach-Object{$_.Text}) -join ' ') -match 'jdupont@example.invalid = jean.dupont@corp.example.com') 'Rapprochement non visible'
    Assert-True (@(Get-DomeniaAccountAliasSummary).Count -eq 1) 'Une entree par compte rapproche attendue'
    # Point 45 in « En ce moment »: the row of the account names its other confirmed names, with its pause.
    $script:Conn.BindUser='EXAMPLE\jdupont'
    Update-DomeniaAccountsInUse -Force
    $directory=@(@($script:Ctrl.DgAccountsInUse.ItemsSource)|Where-Object{$_.Resource -eq 'Annuaire'})[0]
    Assert-True ([string]$directory.State -match '^En pause après un refus') ([string]$directory.State)
    Assert-True ([string]$directory.State -match 'Même compte que jean\.dupont@corp\.example\.com \(SID confirmé par lʼannuaire\)\.') ([string]$directory.State)
    $other=[pscustomobject]@{State='Ambiguous';Count=2;Sid='';Sam='';Upn='';Dn='';RequestSam='x';RequestUpn='';ObservedUtc=''}
    Complete-DomeniaAccountAliasRead $other ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;BaseDn='DC=example,DC=invalid';UserName='EXAMPLE\x';Key='x@example.invalid'})
    Assert-True (-not $guard.Aliases.ContainsKey('x@example.invalid')) 'Association supposee sans compte unique'
}
Test-Case 'P42 Comptes : une seule vue En ce moment, chaque ressource nomme son compte, sa provenance et son etat ; correction pour une connexion explicite seulement' {
    $script:Conn.UseCredential=$true;$script:Conn.AuthMode='Explicit';$script:Conn.Credential=New-TestCredential 'EXAMPLE\lecteur'
    $script:Conn|Add-Member -NotePropertyName Connected -NotePropertyValue $true -Force
    $script:RemoteAdminCredential=New-TestCredential 'EXAMPLE\postes'
    $guard=New-P44Guard
    $guard.Faults['postes@example.invalid']=[pscustomobject]@{Kind='LogonFailure';Code='0x8007052E';AtUtc=[datetime]::UtcNow}
    Update-DomeniaAccountUi
    Update-DomeniaAccountsInUse -Force
    $rows=@($script:Ctrl.DgAccountsInUse.ItemsSource)
    $line={param([string]$Resource) $r=@($rows|Where-Object{$_.Resource -eq $Resource})[0];if($null -eq $r){return ''};return ([string]$r.Account+'|'+[string]$r.Origin+'|'+[string]$r.State)}
    Assert-True ((& $line 'Annuaire') -ceq 'EXAMPLE\lecteur|compte de connexion|Aucun refus enregistré.') (& $line 'Annuaire')
    Assert-True ((& $line 'Postes (WMI, C$, consoles)') -match '^EXAMPLE\\postes\|compte Postes de la page Comptes\|En pause après un refus : ressaisissez son mot de passe puis « Activer »') (& $line 'Postes (WMI, C$, consoles)')
    Assert-True ((& $line 'Secrets : LAPS') -ceq 'EXAMPLE\lecteur|même compte que lʼannuaire|Aucun refus enregistré.') (& $line 'Secrets : LAPS')
    $states=(@($rows|ForEach-Object{[string]$_.State}) -join ' ')
    Assert-True ($states -notmatch 'Même compte que') ('Noms confirmes annonces sans aucun rapprochement : '+$states)
    Assert-True ($states -notmatch '(?i)\bvalid') 'Un compte non teste est presente comme valide'
    # The rule panel keeps its fixed text: the accounts in use live in « En ce moment » only.
    Assert-True ([string]$script:Ctrl.LblAccountRule.Text -match '^Annuaire : compte de connexion\. Postes :') ([string]$script:Ctrl.LblAccountRule.Text)
    Assert-True ([bool]$script:Ctrl.BtnAccountAdCorrect.IsEnabled) 'Correction indisponible pour une connexion explicite'
    Assert-True ($script:Ctrl.BtnAccountAdCorrect.Parent.Visibility -eq [Windows.Visibility]::Visible) 'Correction masquee pour une connexion explicite'
    $script:Conn.UseCredential=$false;$script:Conn.AuthMode='Windows';$script:Conn.Credential=$null
    Update-DomeniaAccountUi
    Assert-True (-not [bool]$script:Ctrl.BtnAccountAdCorrect.IsEnabled) 'Correction proposee pour une session Windows'
    Assert-True ($script:Ctrl.BtnAccountAdCorrect.Parent.Visibility -eq [Windows.Visibility]::Collapsed) 'Carte Annuaire : correction visible en session Windows'
    Update-DomeniaAccountsInUse -Force
    Assert-True ([string](@(@($script:Ctrl.DgAccountsInUse.ItemsSource)|Where-Object{$_.Resource -eq 'Annuaire'})[0]).Origin -eq 'session Windows') 'Origine du compte de session absente'
}

# ================================================================ UI-31 secrets buttons
Test-Case 'UI-31 Copier tout absent en mode valeur unique, libelles poses par une seule fonction, boutons renommes' {
    $a=[guid]::NewGuid().ToString('N')
    $script:SecretRows=@([pscustomobject]@{Kind='Windows LAPS';Account='Administrateur';Value=$a;Timestamp='';Source='s';Detail=''})
    Update-SecretsGrid
    $toggle=$script:Ctrl.BtnToggleSecrets;$copyAll=$script:Ctrl.BtnCopyAllSecrets;$copy=$script:Ctrl.BtnCopySecret
    Assert-True ($copyAll.Visibility -eq [Windows.Visibility]::Collapsed -and -not $copyAll.IsEnabled) 'Copier tout visible en mode valeur unique'
    Assert-True ([string]$toggle.Content -eq 'Afficher la valeur choisie' -and -not $toggle.IsEnabled) ('Avant selection : '+[string]$toggle.Content)
    $script:Ctrl.DgSecrets.SelectedItem=@($script:Ctrl.DgSecrets.Items)[0];Update-DomeniaSecretActionUi
    Assert-True ($toggle.IsEnabled -and [string]$copy.Content -eq 'Copier le mot de passe LAPS' -and $copy.IsEnabled) 'Boutons apres selection'
    Toggle-SecretsVisibility
    Assert-True ([string]$toggle.Content -eq 'Masquer la valeur' -and [string][Windows.Automation.AutomationProperties]::GetName($toggle) -eq 'Masquer la valeur') ('Pendant l affichage : '+[string]$toggle.Content)
    Toggle-SecretsVisibility
    Assert-True ([string]$toggle.Content -eq 'Afficher la valeur choisie') ('Apres masquage : '+[string]$toggle.Content)
    Assert-True ($script:Clipboard.Count -eq 0) 'Copie implicite'
    Clear-Secrets
    Assert-True ([string]$toggle.Content -eq 'Afficher la valeur choisie' -and -not $toggle.IsEnabled -and $copyAll.Visibility -eq [Windows.Visibility]::Collapsed) 'Etat apres Vider'
    Assert-True ([string]$script:Ctrl.LblSecretsStatus.Text -eq 'Aucun secret conservé en mémoire.') ([string]$script:Ctrl.LblSecretsStatus.Text)
    # Previous behaviour, Features.SecretSingleCopy off: "copy all" is shown and active once a value is read.
    $script:Config['Features.SecretSingleCopy']=$false;$script:DomeniaFeatureFlagCache=$null
    $script:SecretRows=@([pscustomobject]@{Kind='Windows LAPS';Account='Administrateur';Value=$a;Timestamp='';Source='s';Detail=''})
    Update-SecretsGrid
    Assert-True ($copyAll.Visibility -eq [Windows.Visibility]::Visible -and $copyAll.IsEnabled -and [string]$toggle.Content -eq 'Afficher les secrets') 'Copier tout absent hors mode valeur unique'
    $script:Config['Features.SecretSingleCopy']=$true;$script:DomeniaFeatureFlagCache=$null;$script:SecretRows=@();Update-SecretsGrid
    # The label of the reveal button is written in one function only, in the core and in the secrets module.
    $writers=[Collections.Generic.List[string]]::new()
    $moduleAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Secrets.UI.ps1'),[ref]$null,[ref]$null)
    foreach($tree in @($script:CoreAst,$moduleAst)){
        foreach($assign in @($tree.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match '(?i)(\$toggle|BtnToggleSecrets.*)\.Content$'},$true))){
            $owner=$assign.Parent;while($null -ne $owner -and $owner -isnot [Management.Automation.Language.FunctionDefinitionAst]){$owner=$owner.Parent}
            $writers.Add($(if($null -ne $owner){$owner.Name}else{'<hors fonction>'}))
        }
    }
    Assert-True ((@($writers|Sort-Object -Unique) -join ',') -eq 'Update-DomeniaSecretActionUi') ('Libelle pose par : '+(@($writers|Sort-Object -Unique) -join ','))
    $xaml=[xml](Get-MainXaml -WadRoot (Split-Path -Parent $PSScriptRoot));$x='http://schemas.microsoft.com/winfx/2006/xaml'
    $bl=@($xaml.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$x) -eq 'BtnLoadBitLocker'})[0];$lp=@($xaml.SelectNodes('//*')|Where-Object{$_.GetAttribute('Name',$x) -eq 'BtnLoadLaps'})[0]
    Assert-True ($bl.GetAttribute('Content') -eq 'Lister les clés BitLocker' -and $lp.GetAttribute('Content') -eq 'Lire le mot de passe LAPS') 'Boutons non renommes'
    $help=(Get-Content -LiteralPath (Join-Path $wad 'modules\Domenia-UX.help.json') -Raw -Encoding UTF8|ConvertFrom-Json)
    foreach($node in @($bl,$lp)){
        $entry=@($help|ForEach-Object{$_}|Where-Object{$_.Name -eq $node.GetAttribute('Name',$x)})
        # PF-24: the catalogue is the only source of the tool tip; the XAML keeps the accessible name only.
        Assert-True (($entry.Count -eq 1) -and ([string]$entry[0].Title -ceq $node.GetAttribute('AutomationProperties.Name')) -and ([bool][string]$entry[0].Text) -and (-not $node.GetAttribute('ToolTip'))) ('Aide divergente : '+$node.GetAttribute('Name',$x))
    }
    $script:SelectedObject=$null;Update-DomeniaSecretActionUi
    Assert-True ([string]$script:Ctrl.BtnLoadLaps.ToolTip -match '^Lire le mot de passe LAPS : ') ([string]$script:Ctrl.BtnLoadLaps.ToolTip)
    Assert-True ([string]$script:Ctrl.BtnLoadBitLocker.ToolTip -match '^Lister les clés BitLocker : ') ([string]$script:Ctrl.BtnLoadBitLocker.ToolTip)
}
Test-Case 'UI-31 Aide contextuelle d un bouton grise : description du catalogue suivie de son motif (D056)' {
    $script:SecretRows=@();Update-SecretsGrid
    $copy=$script:Ctrl.BtnCopySecret;$toggle=$script:Ctrl.BtnToggleSecrets
    foreach($button in @($copy,$toggle)){
        $tip=[string]$button.ToolTip
        Assert-True ((-not $button.IsEnabled) -and ($tip -match '^(Sélectionnez|Lancez dʼabord)')) ($button.Name+' : '+$tip)
        $entry=Get-DomeniaUxHelpEntry -Control $button
        $hint=Get-DomeniaUxControlHelpText -Control $button
        Assert-True (($hint.StartsWith([string]$entry.Text)) -and ($hint.Contains($tip))) ($button.Name+' : motif absent de l aide contextuelle : '+$hint)
    }
    # Once the reason is gone, the hint is the catalogue description alone: no value is reflected.
    $a=[guid]::NewGuid().ToString('N')
    $script:SecretRows=@([pscustomobject]@{Kind='Windows LAPS';Account='Administrateur';Value=$a;Timestamp='';Source='s';Detail=''})
    Update-SecretsGrid
    $script:Ctrl.DgSecrets.SelectedItem=@($script:Ctrl.DgSecrets.Items)[0];Update-DomeniaSecretActionUi
    $hint=Get-DomeniaUxControlHelpText -Control $copy
    Assert-True ($copy.IsEnabled -and ($hint -ceq [string](Get-DomeniaUxHelpEntry -Control $copy).Text) -and (-not $hint.Contains($a))) ('Aide contextuelle d un bouton actif : '+$hint)
}

# ================================================================ UX-18 BitLocker key card
function New-TestRecoveryPassword {return ((1..8|ForEach-Object{'{0:D6}' -f (Get-Random -Minimum 0 -Maximum 999999)}) -join '-')}
function Show-TestBitLockerKey {param([string]$Value)
    # Real path: metadata list, choice of the line, explicit reveal, answer of the key worker.
    $state=New-SecretState 'BitLocker'
    $k1='CN=2025-03-01T10:22:33-00:00{A1B2C3D4-1111-2222-3333-444455556666},'+$script:Dn
    $k2='CN=2025-06-01T08:00:00-00:00{B1B2FFFF-1111-2222-3333-444455556666},'+$script:Dn
    Complete-DomeniaBitLockerListUi ([pscustomobject]@{Mode='BitLockerList';Success=$true;Entries=@([pscustomobject]@{Name=($k1.Split(',')[0].Substring(3));DN=$k1;RecoveryGuid='a1b2c3d4-1111-2222-3333-444455556666';WhenCreated=$null},[pscustomobject]@{Name=($k2.Split(',')[0].Substring(3));DN=$k2;RecoveryGuid='b1b2ffff-1111-2222-3333-444455556666';WhenCreated=$null});RecoveryObjectsFound=2;ErrorKind='';ErrorMessage='';Reader='EXAMPLE\lecteur'}) $state
    $script:Ctrl.DgSecrets.SelectedItem=@($script:Ctrl.DgSecrets.Items)[0]
    Toggle-SecretsVisibility
    $task=@($script:Tasks|Where-Object{$_.OperationId -eq 'ReadBitLockerKey'})[-1]
    Complete-DomeniaBitLockerKeyUi ([pscustomobject]@{Mode='BitLockerKey';Success=$true;Rows=@([pscustomobject]@{Kind='BitLocker';Account='A1B2C3D4-1111-2222-3333-444455556666';Value=$Value;Timestamp='';Source='x';Detail=$k1});KeyDn=$k1;KeyGuid='A1B2C3D4-1111-2222-3333-444455556666';ErrorKind='';ErrorMessage=''}) $task.State
}
Test-Case 'UX-18 Cle BitLocker en carte : huit blocs numerotes, identifiant rappele, compte a rebours, DN retire, aucune copie ni trace' {
    $value=New-TestRecoveryPassword
    Show-TestBitLockerKey $value
    $card=$script:Ctrl.BitLockerKeyCard
    Assert-True ($card.Visibility -eq [Windows.Visibility]::Visible) 'Carte absente'
    $blocks=@($script:Ctrl.BitLockerKeyBlocks.ItemsSource)
    Assert-True ($blocks.Count -eq 8 -and (@($blocks|ForEach-Object{$_.Digits}) -join '-') -ceq $value -and $blocks[0].Label -eq 'Bloc 1' -and $blocks[7].Label -eq 'Bloc 8') 'Huit blocs attendus dans l ordre'
    $id=[string]$script:Ctrl.LblBitLockerKeyCardId.Text
    Assert-True ($id -match 'A1B2C3D4' -and $id -match 'A1B2C3D4-1111-2222-3333-444455556666' -and $id -match 'Vérifiez') ('Identifiant : '+$id)
    Assert-True ([string]$script:Ctrl.LblBitLockerKeyCountdown.Text -match '^(29|30) s$') ('Compte a rebours : '+[string]$script:Ctrl.LblBitLockerKeyCountdown.Text)
    $dash=@($script:Ctrl.BitLockerKeyRing.StrokeDashArray)
    Assert-True ($dash.Count -eq 2 -and [double]$dash[0] -gt 0) 'Anneau non dessine'
    Assert-True ($null -ne $script:SecretCountdownTimer -and $script:SecretCountdownTimer.IsEnabled -and $script:SecretCountdownTimer.Interval.TotalSeconds -eq 1) 'Compte a rebours arrete'
    Assert-True ($script:Ctrl.BtnBitLockerKeyExtend.IsEnabled -and [string]$script:Ctrl.BtnBitLockerKeyExtend.Content -eq 'Prolonger 30 s') 'Prolongation non proposee'
    # The grid keeps the identifier, never the DN, and its cell points to the card instead of a truncated key.
    $column=@($script:Ctrl.DgSecrets.Columns|Where-Object{$_ -is [Windows.Controls.DataGridBoundColumn] -and [string]$_.Binding.Path.Path -eq 'Account'})[0]
    Assert-True ([string]$column.Header -eq 'Identifiant de récupération') ('Colonne : '+[string]$column.Header)
    $bound=@($script:Ctrl.DgSecrets.ItemsSource)
    Assert-True (@($bound|Where-Object{(($_|ConvertTo-Json -Depth 3) -match 'CN=')}).Count -eq 0) 'Un DN reste affiche dans la grille'
    Assert-True ([string]$bound[1].Detail -eq 'Identifiant complet : B1B2FFFF-1111-2222-3333-444455556666') ('Detail : '+[string]$bound[1].Detail)
    Assert-True (@($bound|Where-Object{[string]$_.DisplayValue -ceq $value}).Count -eq 0) 'Cle affichee dans la cellule etroite'
    Assert-True ($script:Clipboard.Count -eq 0 -and $script:ClipboardTimers -eq 0) 'Copie implicite'
    $journal='';if([IO.File]::Exists($script:AuditPath)){$journal=[IO.File]::ReadAllText($script:AuditPath)}
    Assert-True (-not (Test-DomeniaTextHasSecret ($journal+"`n"+($script:UiLog -join "`n")+"`n"+($script:StatusLines -join "`n")+"`n"+[string]$script:Ctrl.TxtLog.Text+"`n"+[string]$script:Ctrl.LblSecretsStatus.Text) @($value))) 'Cle presente dans un journal ou un statut'
}
Test-Case 'UX-18 Prolongation unique de 30 s, puis carte videe et cle masquee a l echeance' {
    $value=New-TestRecoveryPassword
    Show-TestBitLockerKey $value
    Assert-True ($script:SecretRevealTimer.Interval.TotalSeconds -eq 30) 'Duree initiale'
    $script:Ctrl.BtnBitLockerKeyExtend.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    $first=$script:SecretRevealTimer.Interval.TotalSeconds
    Assert-True ($first -gt 58 -and $first -le 60.01 -and [bool]$script:SecretReveal.Extended) ('Echeance prolongee : '+$first)
    Assert-True ((-not $script:Ctrl.BtnBitLockerKeyExtend.IsEnabled) -and [string]$script:Ctrl.BtnBitLockerKeyExtend.Content -eq 'Prolongation utilisée') 'Seconde prolongation proposee'
    Assert-True (-not (Invoke-DomeniaSecretRevealExtension)) 'Seconde prolongation acceptee'
    Assert-True ($script:SecretRevealTimer.Interval.TotalSeconds -eq $first -and @($script:StatusLines|Where-Object{$_ -match 'déjà utilisée'}).Count -eq 1) 'Seconde prolongation appliquee'
    # Expiry: the protected timer of the reveal runs its tick; the card is emptied and the value masked.
    Invoke-DomeniaTimerTick -Timer $script:SecretRevealTimer
    Assert-True ([long]$script:SecretRevealTimer.Errors -eq 0) ('Tick en erreur : '+[string]$script:SecretRevealTimer.LastError)
    Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Collapsed -and $null -eq $script:Ctrl.BitLockerKeyBlocks.ItemsSource -and [string]$script:Ctrl.LblBitLockerKeyCardId.Text -eq '') 'Carte encore remplie apres l echeance'
    Assert-True ((-not $script:SecretsVisible) -and (-not $script:SecretCountdownTimer.IsEnabled)) 'Revelation ou compte a rebours actifs apres l echeance'
    Assert-True ([string]@($script:Ctrl.DgSecrets.ItemsSource)[0].DisplayValue -ceq '********') 'Valeur visible apres l echeance'
    Assert-True ([int]$script:Ctrl.DgSecrets.SelectedItem.SecretIndex -eq 0) 'Ligne choisie perdue a l echeance'
    # The countdown hides the key as well when it finds the deadline past (expiry timer delayed).
    Toggle-SecretsVisibility
    Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Visible) 'Nouvelle revelation absente'
    $script:SecretReveal.DeadlineUtc=[datetime]::UtcNow.AddSeconds(-1)
    Invoke-DomeniaTimerTick -Timer $script:SecretCountdownTimer
    Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Collapsed -and -not $script:SecretsVisible) 'Echeance depassee sans masquage'
    # Masquer maintenant and Vider empty the card too; nothing was copied on the way.
    Toggle-SecretsVisibility
    $script:Ctrl.BtnBitLockerKeyHide.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
    Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Collapsed -and -not $script:SecretsVisible) 'Masquer maintenant sans effet'
    Toggle-SecretsVisibility
    Clear-Secrets
    Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Collapsed -and $null -eq $script:Ctrl.BitLockerKeyBlocks.ItemsSource) 'Vider laisse la carte remplie'
    Assert-True ($script:Clipboard.Count -eq 0 -and $script:ClipboardTimers -eq 0) 'Copie implicite'
}
Test-Case 'UX-18 Une valeur LAPS ou une cle au format inattendu ne passe jamais par la carte' {
    $odd='12345-'+((1..7|ForEach-Object{'123456'}) -join '-')
    $script:SecretRows=@([pscustomobject]@{Kind='BitLocker';Account='C1C2C3C4-1111-2222-3333-444455556666';Value=$odd;Timestamp='';Source='s';Detail=('CN=K,'+$script:Dn)},[pscustomobject]@{Kind='Windows LAPS';Account='Administrateur';Value=[guid]::NewGuid().ToString('N');Timestamp='';Source='s';Detail=''})
    Update-SecretsGrid
    Assert-True ([string]@($script:Ctrl.DgSecrets.ItemsSource)[0].Detail -eq '') 'DN affiche en detail'
    $column=@($script:Ctrl.DgSecrets.Columns|Where-Object{$_ -is [Windows.Controls.DataGridBoundColumn] -and [string]$_.Binding.Path.Path -eq 'Account'})[0]
    Assert-True ([string]$column.Header -eq 'Compte ou identifiant') ('Colonne : '+[string]$column.Header)
    foreach($index in 0,1){
        $script:Ctrl.DgSecrets.SelectedItem=@($script:Ctrl.DgSecrets.Items)[$index]
        Toggle-SecretsVisibility
        Assert-True ($script:Ctrl.BitLockerKeyCard.Visibility -eq [Windows.Visibility]::Collapsed) ('Carte affichee pour la ligne '+$index)
        Assert-True ([string]@($script:Ctrl.DgSecrets.ItemsSource)[$index].DisplayValue -ceq [string]$script:SecretRows[$index].Value) 'Valeur hors carte non affichee'
        Toggle-SecretsVisibility
    }
    $script:SecretRows=@([pscustomobject]@{Kind='Windows LAPS';Account='Administrateur';Value='x';Timestamp='';Source='s';Detail=''});Update-SecretsGrid
    Assert-True ([string]$column.Header -eq 'Compte') ('Colonne LAPS : '+[string]$column.Header)
}

# ================================================================ UI-18 receipts in plain words, review in the page
# These cases run last: they give the real main window to the in-page confirmation (Domenia-Inline.UI.ps1), which
# then stays laid over its content grid for the rest of the run.
function Invoke-TestClick {param($Button) $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
function New-ReceiptRow {param([string]$Id,[string]$Operation,[string]$Stage,[string]$Updated,[string]$Review='',[bool]$KeptAll=$true)
    # Same shape as a row of the receipt store worker (Get-DomeniaReceiptWorkerCode). CanVerify is its own test: an
    # attribute change whose expected values were all kept ($KeptAll false: a secret or excluded attribute).
    return [pscustomobject]@{Id=$Id;PlanFingerprint='';Operation=$Operation;DN='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid';Identity='EXAMPLE\adm';Server='dc1.example.invalid';Stage=$Stage;UpdatedUtc=$Updated;Review=$Review;CanVerify=(($Operation -eq 'WriteAttributes') -and ($KeptAll))}
}
function Initialize-ReceiptFixture {
    # The real Guard initialisation wires the receipts view on the real controls; its heartbeat timer is stopped.
    $script:Window=$script:MainWindow;$script:AsyncJobs=@{}
    if($null -eq $script:Guard){Initialize-DomeniaGuard}
    if($null -ne $script:Guard.Timer){try{$script:Guard.Timer.Stop()}catch{}}
    $script:Guard.ReceiptJob='';$script:Guard.PendingChoice=$null
    $script:Ctrl.TxtGuardReceiptReason.Text=''
}
function Get-ListState {return [pscustomobject]@{Epoch=[long]$script:SessionEpoch;Action='List';Id=''}}
Test-Case 'UI-18 Recus en clair dans la vraie grille : etat, operation, objet, DN en infobulle, a verifier en premier' {
    Initialize-ReceiptFixture
    Start-DomeniaReceiptRefresh
    $task=@($script:Tasks|Where-Object{$_.OperationId -eq 'ReceiptStore'})[-1]
    Assert-True ($null -ne $task -and $task.Payload.Action -eq 'List' -and $task.SuccessHandler -eq 'Complete-DomeniaReceiptRefresh') 'Lecture des recus non lancee'
    $rows=@((New-ReceiptRow ('a'*32) 'WriteAttributes' 'Verified' '2026-10-01T08:00:00.0000000Z'),(New-ReceiptRow ('b'*32) 'WriteUnlock' 'Sent' '2026-09-30T08:00:00.0000000Z'),(New-ReceiptRow ('c'*32) 'WriteExpiration' 'Delivered' '2026-10-02T08:00:00.0000000Z'))
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=$rows;Pending=1}) $task.State
    $bound=@($script:Ctrl.DgGuardReceipts.ItemsSource)
    Assert-True ($bound.Count -eq 3 -and $script:ReceiptReady -and $script:ReceiptPending -eq 1) 'Lignes ou etat des recus'
    Assert-True ($bound[0].Id -eq ('b'*32) -and $bound[0].Tone -eq 'Pending' -and $bound[1].Id -eq ('c'*32) -and $bound[2].Id -eq ('a'*32)) 'Ordre : a verifier, puis du plus recent au plus ancien'
    Assert-True ($bound[0].StageLabel -eq 'Envoyée, à vérifier' -and $bound[1].StageLabel -eq 'Livrée' -and $bound[2].StageLabel -eq 'Vérifiée') 'Etat brut affiche'
    Assert-True ($bound[0].OperationLabel -eq 'Déverrouillage du compte' -and $bound[0].ObjectName -eq 'Jean Dupont' -and $bound[0].DnToolTip -match 'CN=Jean Dupont,OU=Utilisateurs') 'Operation, objet ou infobulle'
    Assert-True ([string]$script:Ctrl.LblGuardReceipts.Text -match '^Une opération reste à vérifier') ([string]$script:Ctrl.LblGuardReceipts.Text)
    $columns=@($script:Ctrl.DgGuardReceipts.Columns)
    Assert-True ((@($columns|ForEach-Object{[string]$_.Header}) -join '|') -eq 'État|Opération|Objet|Mis à jour|Compte|Contrôleur') 'Colonnes'
    $paths=@($columns|Where-Object{$_ -is [Windows.Controls.DataGridBoundColumn]}|ForEach-Object{[string]$_.Binding.Path.Path})
    Assert-True (($paths -notcontains 'Stage') -and ($paths -notcontains 'DN') -and ($paths -notcontains 'Operation')) ('Colonne brute : '+($paths -join ','))
    # The chip of the real template: the stage in words on a pastel background chosen by its tone.
    $chip=$columns[0].CellTemplate.LoadContent();$chip.DataContext=$bound[0]
    # CD-05: the pill colours are theme tokens; a chip loaded outside the window reads them from the window resources.
    foreach($key in @($script:MainWindow.Resources.Keys)){if([string]$key -like 'Pill*'){$chip.Resources[$key]=$script:MainWindow.Resources[$key]}}
    $chip.Measure([Windows.Size]::new(300,40));[Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::DataBind)
    Assert-True ($chip -is [Windows.Controls.Border] -and [string]$chip.Child.Text -eq 'Envoyée, à vérifier') 'Puce sans libelle'
    Assert-True ([string]$chip.Background.Color -eq '#FFFEF3C7') ('Couleur de la puce a verifier : '+[string]$chip.Background.Color)
    Assert-True ([string]$chip.ToolTip -match 'bloquées') 'Infobulle de la puce sans explication'
}
Test-Case 'UI-18 Revue dans la page : motif controle, confirmation dans la page, aucune fenetre, motif fige, un seul envoi' {
    Initialize-ReceiptFixture
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=@((New-ReceiptRow ('b'*32) 'WriteUnlock' 'Sent' '2026-09-30T08:00:00.0000000Z'),(New-ReceiptRow ('d'*32) 'WriteAttributes' 'Unknown' '2026-09-29T08:00:00.0000000Z'));Pending=2}) (Get-ListState)
    $grid=$script:Ctrl.DgGuardReceipts;$box=$script:Ctrl.TxtGuardReceiptReason
    $grid.SelectedItem=@($grid.Items|Where-Object{$_.Id -eq ('b'*32)})[0]
    Assert-True ([string]$script:Ctrl.LblGuardReceiptSelection.Text -match 'Vérification automatique indisponible') ([string]$script:Ctrl.LblGuardReceiptSelection.Text)
    Assert-True ((-not $script:Ctrl.BtnGuardReceiptVerify.IsEnabled) -and (-not $script:Ctrl.BtnGuardReceiptReview.IsEnabled) -and $box.IsEnabled) 'Etat initial de la zone de revue'
    $box.Text='trop court'
    Assert-True ((-not $script:Ctrl.BtnGuardReceiptReview.IsEnabled) -and ([string]$script:Ctrl.LblGuardReceiptReasonCount.Text -match '12 au minimum')) 'Motif trop court accepte'
    $box.Text='Verifie avec password=Azerty123456'
    Assert-True ((-not $script:Ctrl.BtnGuardReceiptReview.IsEnabled) -and ([string]$script:Ctrl.LblGuardReceiptReasonCount.Text -match 'secret')) 'Secret accepte dans le motif'
    $box.Text='  Compte deverrouille constate dans la console ADUC  '
    Assert-True ($script:Ctrl.BtnGuardReceiptReview.IsEnabled) 'Motif valide refuse'
    $before=$script:Tasks.Count
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptReview
    $panel=Get-DomeniaControl 'InlineRequestPanel'
    Assert-True ($null -ne $panel -and $panel.Visibility -eq [Windows.Visibility]::Visible) 'Confirmation absente de la page'
    Assert-True ($script:ConfirmCalls.Count -eq 0 -and $script:Dialogs.Count -eq 0 -and $script:Popups.Count -eq 0 -and $script:MainWindow.OwnedWindows.Count -eq 0) 'Une fenetre ou une boite a ete ouverte'
    Assert-True ($script:Tasks.Count -eq $before) 'Revue envoyee avant la reponse'
    Assert-True ([string](Get-DomeniaControl 'LblInlineRequestChanges').Text -match 'Compte deverrouille constate dans la console ADUC') 'Motif absent de la confirmation'
    $box.Text='Autre texte saisi apres la demande, ignore'
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestConfirm')
    $task=$script:Tasks[$script:Tasks.Count-1]
    Assert-True ($script:Tasks.Count -eq ($before+1) -and $task.OperationId -eq 'ReceiptStore' -and $task.Payload.Action -eq 'Review' -and $task.Payload.Id -eq ('b'*32)) 'Revue non lancee'
    Assert-True ([string]$task.Payload.Reason -ceq 'Compte deverrouille constate dans la console ADUC') ('Motif envoye : '+[string]$task.Payload.Reason)
    Assert-True (-not $script:Ctrl.BtnGuardReceiptReview.IsEnabled) 'Revue relancable pendant son enregistrement'
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestConfirm')
    Assert-True ($script:Tasks.Count -eq ($before+1)) 'Revue envoyee deux fois'
    $done=@((New-ReceiptRow ('b'*32) 'WriteUnlock' 'Reviewed' '2026-10-02T09:00:00.0000000Z' 'Compte deverrouille constate dans la console ADUC'),(New-ReceiptRow ('d'*32) 'WriteAttributes' 'Unknown' '2026-09-29T08:00:00.0000000Z'))
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=$done;Pending=1}) $task.State
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'Revue consignée'}).Count -eq 1) 'Issue de la revue non annoncee'
    Assert-True ([string]$box.Text -eq '') 'Motif conserve apres la revue'
    Assert-True ([string]$grid.SelectedItem.Id -eq ('b'*32) -and [string]$grid.SelectedItem.StageLabel -eq 'Revue manuelle') 'Selection perdue ou etat brut'
    Assert-True ([string]$script:Ctrl.LblGuardReceiptSelection.Text -match 'Motif consigné') ([string]$script:Ctrl.LblGuardReceiptSelection.Text)
    # A receipt left as it was is never reported as reviewed.
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=@((New-ReceiptRow ('d'*32) 'WriteAttributes' 'Unknown' '2026-09-29T08:00:00.0000000Z'));Pending=1}) ([pscustomobject]@{Epoch=[long]$script:SessionEpoch;Action='Review';Id=('d'*32)})
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'nʼa pas changé'}).Count -eq 1) 'Revue annoncee sans changement du recu'
}
Test-Case 'UI-18 Relecture proposee pour une modification de fiche, annulable, retiree au changement de session, refus explique' {
    Initialize-ReceiptFixture
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=@((New-ReceiptRow ('d'*32) 'WriteAttributes' 'Unknown' '2026-09-29T08:00:00.0000000Z'));Pending=1}) (Get-ListState)
    $grid=$script:Ctrl.DgGuardReceipts
    $grid.SelectedItem=@($grid.Items)[0]
    Assert-True ($script:Ctrl.BtnGuardReceiptVerify.IsEnabled -and (-not $script:Ctrl.BtnGuardReceiptReview.IsEnabled)) 'Relecture non proposee'
    $before=$script:Tasks.Count
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptVerify
    Assert-True ((Get-DomeniaControl 'InlineRequestPanel').Visibility -eq [Windows.Visibility]::Visible -and $script:ConfirmCalls.Count -eq 0) 'Confirmation hors de la page'
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestCancel')
    Assert-True ($script:Tasks.Count -eq $before -and $null -eq $script:Guard.PendingChoice) 'Annulation avec effet'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'annulée'}).Count -eq 1) 'Annulation non annoncee'
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptVerify
    $script:SessionEpoch=8L
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestConfirm')
    Assert-True ($script:Tasks.Count -eq $before) 'Relecture lancee apres un changement de session'
    $script:SessionEpoch=7L
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptVerify
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestConfirm')
    $task=$script:Tasks[$script:Tasks.Count-1]
    Assert-True ($script:Tasks.Count -eq ($before+1) -and $task.Payload.Action -eq 'Verify' -and $task.Payload.Id -eq ('d'*32) -and [string]$task.Payload.Reason -eq '') 'Relecture non lancee'
    Fail-DomeniaReceiptRefresh 'Valeur attendue non confirmee. Aucun rejeu.' $task.State
    Assert-True ([string]$script:Ctrl.LblGuardReceipts.Text -match '^Vérification non aboutie' -and [string]$script:Ctrl.LblGuardReceipts.Text -match 'aucune commande') ([string]$script:Ctrl.LblGuardReceipts.Text)
    Assert-True ((-not $script:ReceiptReady) -and $script:Guard.ReceiptJob -eq '') 'Recus consideres confirmes apres un refus'
}
Test-Case 'UI-18 Relecture jamais promise quand le magasin la refuserait : valeurs non conservees, rien envoye' {
    Initialize-ReceiptFixture
    $rows=@((New-ReceiptRow ('f'*32) 'WriteAttributes' 'Sent' '2026-09-29T08:00:00.0000000Z' '' $false),(New-ReceiptRow ('g'*32) 'WriteAttributes' 'Prepared' '2026-09-28T08:00:00.0000000Z'))
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=$rows;Pending=2}) (Get-ListState)
    $grid=$script:Ctrl.DgGuardReceipts
    $before=$script:Tasks.Count
    foreach($case in @(@{Id=('f'*32);Why='toutes les valeurs attendues'},@{Id=('g'*32);Why='Rien nʼa été envoyé'})){
        $grid.SelectedItem=@($grid.Items|Where-Object{$_.Id -eq $case.Id})[0]
        Assert-True (-not $script:Ctrl.BtnGuardReceiptVerify.IsEnabled) ('Relecture proposee : '+$case.Why)
        $label=[string]$script:Ctrl.LblGuardReceiptSelection.Text
        Assert-True (($label -match $case.Why) -and ($label -notmatch 'Relecture possible')) $label
        # Even when the handler of the greyed button runs, it starts nothing and keeps no pending choice.
        Invoke-DomeniaReceiptChoice -Action Verify
        Assert-True (($script:Tasks.Count -eq $before) -and ($null -eq $script:Guard.PendingChoice)) ('Relecture lancee : '+$case.Why)
    }
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'consignez votre revue'}).Count -eq 2) 'Motif du refus non annonce'
}
Test-Case 'UI-18 Une demande remplacee par une autre ne lance ni n efface la nouvelle : un seul envoi, pour le dernier recu choisi' {
    Initialize-ReceiptFixture
    Complete-DomeniaReceiptRefresh ([pscustomobject]@{Rows=@((New-ReceiptRow ('d'*32) 'WriteAttributes' 'Unknown' '2026-09-29T08:00:00.0000000Z'),(New-ReceiptRow ('e'*32) 'WriteAttributes' 'Sent' '2026-09-28T08:00:00.0000000Z'));Pending=2}) (Get-ListState)
    $grid=$script:Ctrl.DgGuardReceipts
    $before=$script:Tasks.Count
    $grid.SelectedItem=@($grid.Items|Where-Object{$_.Id -eq ('d'*32)})[0]
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptVerify
    $grid.SelectedItem=@($grid.Items|Where-Object{$_.Id -eq ('e'*32)})[0]
    Invoke-TestClick $script:Ctrl.BtnGuardReceiptVerify
    # The safe answer of the replaced request runs (Domenia-Inline.UI) but belongs to the former token.
    Assert-True ($script:Tasks.Count -eq $before) 'Relecture lancee avant la reponse'
    Assert-True ([string]$script:Guard.PendingChoice.Id -eq ('e'*32)) 'Choix remplace efface par la demande precedente'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'annulée'}).Count -eq 0) 'Remplacement annonce comme une annulation'
    Invoke-TestClick (Get-DomeniaControl 'BtnInlineRequestConfirm')
    $task=$script:Tasks[$script:Tasks.Count-1]
    Assert-True (($script:Tasks.Count -eq ($before+1)) -and ($task.Payload.Action -eq 'Verify') -and ($task.Payload.Id -eq ('e'*32))) 'Relecture non lancee pour le dernier recu choisi'
    Assert-True ($null -eq $script:Guard.PendingChoice) 'Choix conserve apres envoi'
    # A continuation that does not carry the token of the pending choice starts nothing.
    $script:Guard.ReceiptJob='';$script:Guard.PendingChoice=[pscustomobject]@{Action='Verify';Id=('d'*32);Reason='';Epoch=[long]$script:SessionEpoch;Token='jeton-courant'}
    Complete-DomeniaReceiptChoice -Token 'jeton-ancien'
    Assert-True (($script:Tasks.Count -eq ($before+1)) -and ([string]$script:Guard.PendingChoice.Token -eq 'jeton-courant')) 'Suite d une ancienne demande executee'
    Cancel-DomeniaReceiptChoice -Token 'jeton-ancien'
    Assert-True ([string]$script:Guard.PendingChoice.Token -eq 'jeton-courant') 'Ancienne demande annulant la nouvelle'
}
Test-Case 'UI-18 Aucune fenetre ni boite dans le parcours des recus (code livre)' {
    # Static proof on the shipped module, alongside the runtime counters of the cases above.
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $wad 'modules\Domenia-Guard.UI.ps1'),[ref]$null,[ref]$null)
    $modals=@('Show-DomeniaFormDialog','Confirm-Action','Confirm-TextAction','Show-InfoBox','Show-ErrorBox','Show-DomeniaDialog','Show-DomeniaEmbeddedWindow')
    foreach($name in @('Start-DomeniaReceiptRefresh','Complete-DomeniaReceiptRefresh','Fail-DomeniaReceiptRefresh','Update-DomeniaReceiptActionUi','Invoke-DomeniaReceiptChoice','Complete-DomeniaReceiptChoice','Cancel-DomeniaReceiptChoice')){
        $fn=@($ast.FindAll({param($n)($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $name)},$true))
        Assert-True ($fn.Count -eq 1) ('Fonction absente : '+$name)
        $calls=@($fn[0].FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object{[string]$_.GetCommandName()})
        $found=@($calls|Where-Object{$modals -contains $_})
        Assert-True ($found.Count -eq 0) ($name+' ouvre une boite : '+($found -join ','))
        Assert-True ($fn[0].Extent.Text -notmatch '(?i)\.ShowDialog\(|New-Object\s+(System\.)?Windows\.Window') ($name+' ouvre une fenetre')
    }
}
# ================================================================ FO-19 (lot X03) essayer le compte des postes sur un poste
function New-TrialResult {param([string]$Outcome='NotRequested',[string]$ProbeError='',[string]$Caption='Windows 11 Pro',[string]$Computer='pc-01.example.invalid')
    $instances=if($ProbeError){@()}else{@([pscustomobject]@{Id='1';Index=1;Values=[pscustomobject]@{Caption=$Caption};IncompleteProperties=@()})}
    return [pscustomobject]@{Outcome=$Outcome;Computer=$Computer;Detail=$(if($Outcome -eq 'NotRequested'){''}else{'Lecture CIM/DCOM non confirmée. '+$ProbeError});Probes=[pscustomobject]@{'os.caption'=[pscustomobject]@{Error=$ProbeError;Instances=$instances;Count=$instances.Count}}}
}
Test-Case 'FO-19 Essayer sur le poste selectionne : une seule lecture CIM, un seul poste, compte des postes' {
    $script:RemoteAdminCredential=New-TestCredential 'EXAMPLE\postes';$script:RemoteAccountTrial=$null;$script:Ctrl.LblAccountRemoteTry.Text=''
    Update-DomeniaRemoteTrialUi
    Assert-True ($script:Ctrl.BtnAccountRemoteTry.IsEnabled) 'Bouton grise alors qu un poste est ouvert'
    Start-DomeniaRemoteAccountTrial
    Assert-True ($script:Tasks.Count -eq 1 -and $script:Tasks[0].OperationId -eq 'LiveConsole') ('Operations : '+(@($script:Tasks|ForEach-Object{$_.OperationId}) -join ','))
    $p=$script:Tasks[0].Payload
    Assert-True ($p.Computer -eq 'pc-01.example.invalid' -and -not $p.CollectPing -and -not $p.ProbeUser -and -not $p.Inventory -and -not $p.ValidateConsoleIdentity) 'Charge utile plus large qu une lecture'
    Assert-True (@($p.Probes).Count -eq 1 -and [string]@($p.Probes)[0].Class -eq 'Win32_OperatingSystem' -and (@($p.AllowedClasses) -join ',') -eq 'Win32_OperatingSystem') 'Requete WMI inattendue'
    Assert-True ($script:Tasks[0].Code -ceq (Get-DomeniaLiveProbeCode)) 'Corps epingle LiveConsole non utilise'
    Assert-True ([string]$script:Ctrl.LblAccountRemoteTry.Text -match 'EXAMPLE\\postes') ('Compte non annonce : '+$script:Ctrl.LblAccountRemoteTry.Text)
    Start-DomeniaRemoteAccountTrial
    Assert-True ($script:Tasks.Count -eq 1 -and -not $script:Ctrl.BtnAccountRemoteTry.IsEnabled) 'Second essai lance pendant le premier'
    Complete-DomeniaRemoteAccountTrial (New-TrialResult) $script:Tasks[0].State
    Assert-True ([string]$script:Ctrl.LblAccountRemoteTry.Text -ceq 'Accès administrateur OK sur pc-01.example.invalid avec EXAMPLE\postes (compte Postes de la page Comptes). Système : Windows 11 Pro.') ('Texte : '+$script:Ctrl.LblAccountRemoteTry.Text)
    Assert-True ($script:Ctrl.BtnAccountRemoteTry.IsEnabled) 'Bouton non rendu apres l essai'
}
Test-Case 'FO-19 Refus classe par la regle Access : droit administrateur, identifiants, poste injoignable' {
    $cases=@(
        @('Denied','Accès refusé. (0x80070005)','Accès refusé sur pc-01.example.invalid'),
        @('AuthRejected','Le nom d utilisateur ou le mot de passe est incorrect.','Identifiants refusés par pc-01.example.invalid'),
        @('NotRequested','Access is denied.','Accès refusé sur pc-01.example.invalid'),
        @('Timeout','Délai dépassé','Poste pc-01.example.invalid injoignable'))
    foreach($c in $cases){
        $script:RemoteAccountTrial=$null;$script:Tasks.Clear()
        Start-DomeniaRemoteAccountTrial
        Complete-DomeniaRemoteAccountTrial (New-TrialResult -Outcome $c[0] -ProbeError $c[1]) $script:Tasks[0].State
        Assert-True (([string]$script:Ctrl.LblAccountRemoteTry.Text).StartsWith($c[2])) ($c[0]+' : '+$script:Ctrl.LblAccountRemoteTry.Text)
        Assert-True ([string]$script:Ctrl.LblAccountRemoteTry.Text -notmatch 'Accès administrateur OK') 'Refus annonce comme un succes'
    }
    $script:RemoteAccountTrial=$null;$script:Tasks.Clear()
    Start-DomeniaRemoteAccountTrial
    Fail-DomeniaRemoteAccountTrial 'Le serveur RPC n est pas disponible. RPC indisponible' $script:Tasks[0].State
    Assert-True (([string]$script:Ctrl.LblAccountRemoteTry.Text).StartsWith('Poste pc-01.example.invalid injoignable')) $script:Ctrl.LblAccountRemoteTry.Text
}
Test-Case 'FO-19 Sans poste ouvert ou apres un changement de session : aucune lecture, aucun resultat recopie' {
    $script:RemoteAccountTrial=$null;$script:SelectedObject=$null
    Update-DomeniaRemoteTrialUi
    Assert-True (-not $script:Ctrl.BtnAccountRemoteTry.IsEnabled) 'Bouton actif sans poste'
    Start-DomeniaRemoteAccountTrial
    Assert-True ($script:Tasks.Count -eq 0 -and [string]$script:Ctrl.LblAccountRemoteTry.Text -match 'Ouvrez') 'Lecture lancee sans poste'
    Reset-Fixture;$script:RemoteAccountTrial=$null
    Start-DomeniaRemoteAccountTrial;$state=$script:Tasks[0].State;$script:Ctrl.LblAccountRemoteTry.Text='avant'
    $script:SessionEpoch=8L
    Complete-DomeniaRemoteAccountTrial (New-TrialResult) $state
    Assert-True ([string]$script:Ctrl.LblAccountRemoteTry.Text -eq 'avant') 'Resultat d une session precedente affiche'
    Assert-True ((@($script:CoreAst.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Wire-Events'},$true))[0].Extent.Text).Contains('Start-DomeniaRemoteAccountTrial')) 'Bouton non raccorde'
    Assert-True (-not $script:CoreText.Contains('x:Name="BtnAccountRemoteTest"')) 'Ancien bouton Tester encore present'
}

# ================================================================ UX-15 (lot X03) compte des postes visible en permanence
function New-AccessLease {param([string]$Key,[string]$Account) return (New-DomeniaCredentialLease -Scope $Key -Account $Account -Mode Inactivity -InactivityMinutes 30 -Epoch ([long]$script:SessionEpoch) -NowUtc $script:Clock)}
function Invoke-TestClick {param($Control) $Control.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
Test-Case 'UX-15 Pastille Compte poste : en-tete d Assistance poste, meme compte que le contexte worker' {
    $pill=$script:Ctrl.BtnCompAccountPill
    Assert-True ($null -ne $pill) 'Pastille absente du XAML principal'
    $names=@();$node=$pill
    while($null -ne $node){$node=[Windows.LogicalTreeHelper]::GetParent($node);if(($node -is [Windows.FrameworkElement]) -and $node.Name){$names+=[string]$node.Name}}
    # X03 x X04: one header for the five views (UxComputerHeader, DS-08) carries the pill, outside every view.
    Assert-True (($names -contains 'UxComputerHeader') -and ($names -contains 'ComputerReadRoot') -and ($names -notcontains 'ComputerTabs')) ('Pastille hors de l en-tete commun aux vues : '+($names -join ' > '))
    $arrow=[string][char]0x25BE
    Update-DomeniaMachineAccountUi -Force
    Assert-True ([string]$pill.Content -ceq ('Compte poste : session Windows '+$arrow)) ('Session Windows : '+$pill.Content)
    Assert-True ([string]$pill.ToolTip -match 'session Windows \(EXAMPLE\\lecteur\)') ('Infobulle : '+$pill.ToolTip)
    $script:RemoteAdminCredential=New-TestCredential 'EXAMPLE\postes'
    Update-DomeniaMachineAccountUi
    Assert-True ([string]$pill.Content -ceq ('Compte poste : EXAMPLE\postes '+$arrow)) ('Compte Postes : '+$pill.Content)
    $script:AccessState.Credentials['Remote']=New-TestCredential 'EXAMPLE\temporaire';$script:AccessState.Leases['Remote']=New-AccessLease 'Remote' 'EXAMPLE\temporaire'
    Update-DomeniaMachineAccountUi
    Assert-True ([string]$pill.Content -ceq ('Compte poste : EXAMPLE\temporaire '+$arrow)) ('Compte temporaire : '+$pill.Content)
    $script:AccessState.Credentials['RemoteLocal|PC-01']=New-TestCredential 'PC-01\admin';$script:AccessState.Leases['RemoteLocal|PC-01']=New-AccessLease 'RemoteLocal|PC-01' 'PC-01\admin'
    Update-DomeniaMachineAccountUi
    Assert-True ([string]$pill.Content -ceq ('Compte poste : PC-01\admin '+$arrow)) ('Compte local du poste : '+$pill.Content)
    # The pill announces the account the worker context really hands to an operation on this workstation.
    $ctx=[pscustomobject]@{OperationId='ComputerInventory';Credential=$null;BindUser='';UseCredential=$false;AuthMode='Windows';MachineCredential=$script:RemoteAdminCredential;RemoteAdminCredential=$null;RemoteAdminUser=''}
    $ctx=Set-DomeniaTargetCredentialContext -Context (Set-DomeniaRetryWorkerContext -Context $ctx -OperationId 'ComputerInventory') -Payload ([pscustomobject]@{Computer='pc-01.example.invalid'})
    Assert-True ([string]$ctx.MachineCredential.UserName -ceq 'PC-01\admin') ('Contexte worker : '+$ctx.MachineCredential.UserName)
    # Another workstation open: the local account of PC-01 is not announced for it.
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC-02,OU=Postes,DC=example,DC=invalid';Name='PC-02';Entry=[pscustomobject]@{Name='PC-02';Dns='pc-02.example.invalid'};Safety=[pscustomobject]@{Guid='22222222-2222-3333-4444-555555555555'}}
    Update-DomeniaMachineAccountUi
    Assert-True ([string]$pill.Content -ceq ('Compte poste : EXAMPLE\temporaire '+$arrow)) ('Autre poste : '+$pill.Content)
    Assert-True ((Get-DomeniaMachineOperationAccountText) -ceq 'Opérations poste : EXAMPLE\temporaire (compte temporaire accepté après un refus).') (Get-DomeniaMachineOperationAccountText)
}
Test-Case 'UX-15 Panneau lateral dans la page : compte saisi en memoire, retour au compte de connexion, fermeture sans changement' {
    $script:Window=$script:MainWindow
    $wire=Get-CoreFunctionText 'Wire-Events'
    Assert-True (-not $script:CoreText.Contains('x:Name="TxtMachineAdminUser"') -and -not $wire.Contains('BtnSetMachineCredential')) 'Champs du compte poste encore dans l onglet Diagnostic'
    Assert-True ($script:CoreText -notmatch 'compte poste dans (l onglet )?Diagnostic') 'Message renvoyant encore vers l onglet Diagnostic'
    Assert-True (-not $script:CoreText.Contains('compte poste saisi dans Diagnostic')) 'Phrase technique encore dans l onglet Actions'
    Initialize-DomeniaAccountsUi
    Invoke-TestClick $script:Ctrl.BtnCompAccountPill
    Assert-True (Test-DomeniaMachineAccountPanelOpen) 'La pastille n ouvre pas le panneau'
    $layer=$script:MainWindow.FindName('DomeniaDialogLayer')
    Assert-True (($layer.Visibility -eq [Windows.Visibility]::Visible) -and $layer.Children.Contains($script:MachineAccountPanel.View)) 'Panneau hors de la couche de la page'
    foreach($n in @('TxtMachineAdminUser','PwdMachineAdmin','BtnRevealMachineAdmin','BtnSetMachineCredential','BtnClearMachineCredential','LblMachineCredential','BtnMachineAccountClose')){Assert-True ($script:Ctrl.ContainsKey($n)) ('Controle du panneau non enregistre : '+$n)}
    Assert-True ($script:Ctrl.PwdMachineAdmin -is [Windows.Controls.PasswordBox]) 'Le mot de passe n est plus saisi dans un PasswordBox'
    $script:Ctrl.TxtMachineAdminUser.Text='EXAMPLE\adm-poste'
    $script:Ctrl.PwdMachineAdmin.Password=[guid]::NewGuid().ToString('N')
    Invoke-TestClick $script:Ctrl.BtnSetMachineCredential
    Assert-True (($null -ne $script:MachineCredential) -and ($script:MachineCredential.UserName -ceq 'EXAMPLE\adm-poste')) 'Compte saisi non utilise'
    Assert-True ($script:MachineCredential.Password.IsReadOnly()) 'SecureString du compte poste encore modifiable'
    Assert-True ([string]$script:Ctrl.PwdMachineAdmin.Password -eq '') 'Mot de passe laisse dans le champ'
    Assert-True ([string]$script:Ctrl.BtnCompAccountPill.Content -ceq ('Compte poste : EXAMPLE\adm-poste '+[string][char]0x25BE)) ('Pastille : '+$script:Ctrl.BtnCompAccountPill.Content)
    Assert-True ([string]$script:Ctrl.LblMachineCredential.Text -ceq 'Opérations poste : EXAMPLE\adm-poste (compte poste saisi, en mémoire seulement).') ('Libelle : '+$script:Ctrl.LblMachineCredential.Text)
    Invoke-TestClick $script:Ctrl.BtnClearMachineCredential
    Assert-True ($null -eq $script:MachineCredential) 'Compte saisi non oublie'
    Assert-True ([string]$script:Ctrl.BtnCompAccountPill.Content -ceq ('Compte poste : session Windows '+[string][char]0x25BE)) ('Retour : '+$script:Ctrl.BtnCompAccountPill.Content)
    # Closing without « Utiliser ce compte » changes nothing and drops the typed password.
    $script:Ctrl.PwdMachineAdmin.Password=[guid]::NewGuid().ToString('N')
    Invoke-TestClick $script:Ctrl.BtnMachineAccountClose
    Assert-True (-not (Test-DomeniaMachineAccountPanelOpen)) 'Panneau encore ouvert'
    Assert-True (($null -eq $script:MachineCredential) -and ([string]$script:Ctrl.PwdMachineAdmin.Password -eq '')) 'Fermer a change le compte ou garde le mot de passe'
    Assert-True ($layer.Visibility -eq [Windows.Visibility]::Collapsed) 'Couche de la page laissee visible'
    Invoke-TestClick $script:Ctrl.BtnCompAccountPill
    Assert-True (Test-DomeniaMachineAccountPanelOpen) 'Le panneau ne se rouvre pas'
    Invoke-TestClick $script:Ctrl.BtnCompAccountPill
    Assert-True (-not (Test-DomeniaMachineAccountPanelOpen)) 'Un second clic sur la pastille ne ferme pas le panneau'
    $script:Window=$null
}

# ================================================================ UI-27 (lot X03) Comptes, section « En ce moment »
Test-Case 'UI-27 En ce moment : compte reellement utilise par ressource, comptes en memoire avec duree, aucun secret' {
    $script:Conn.BindUser='EXAMPLE\lecteur';$script:Conn.AuthMode='Windows'
    $script:RemoteAdminCredential=New-TestCredential 'EXAMPLE\postes';$script:SecretsCredential=New-TestCredential 'EXAMPLE\secrets'
    $typed=New-TestCredential 'EXAMPLE\adm-poste';$script:MachineCredential=$typed
    $laps=New-TestCredential 'EXAMPLE\laps-temp';$script:AccessState.Credentials['ReadLaps']=$laps;$script:AccessState.Leases['ReadLaps']=New-AccessLease 'ReadLaps' 'EXAMPLE\laps-temp'
    $script:Clock=$script:Clock.AddMinutes(4)
    Update-DomeniaAccountsInUse -Force
    $now=@($script:Ctrl.DgAccountsInUse.ItemsSource);$memory=@($script:Ctrl.DgAccountsInMemory.ItemsSource)
    $lines=@($now|ForEach-Object{$_.Resource+'|'+$_.Account+'|'+$_.Origin})
    Assert-True ($lines -contains 'Annuaire|EXAMPLE\lecteur|session Windows') ($lines -join ' ; ')
    Assert-True ($lines -contains 'Postes (WMI, C$, consoles)|EXAMPLE\adm-poste|compte poste saisi, en mémoire seulement') ($lines -join ' ; ')
    Assert-True ($lines -contains 'Secrets : LAPS|EXAMPLE\laps-temp|compte temporaire accepté après un refus') ($lines -join ' ; ')
    Assert-True ($lines -contains 'Secrets : BitLocker|EXAMPLE\secrets|compte Secrets de la page Comptes') ($lines -join ' ; ')
    $kept=@($memory|ForEach-Object{$_.Key+'|'+$_.Account+'|'+$_.Remaining})
    Assert-True ($kept -contains 'ReadLaps|EXAMPLE\laps-temp|encore 26 min sans utilisation') ($kept -join ' ; ')
    Assert-True (@($memory|Where-Object{$_.Key -ceq 'Typed:Machine' -and $_.Account -ceq 'EXAMPLE\adm-poste'}).Count -eq 1) 'Compte poste saisi absent de la memoire'
    Assert-True ($script:Ctrl.DgAccountsInMemory.Visibility -eq [Windows.Visibility]::Visible) 'Liste des comptes en memoire masquee'
    $secretsText=@($typed,$laps,$script:SecretsCredential,$script:RemoteAdminCredential|ForEach-Object{$_.GetNetworkCredential().Password})
    foreach($row in @($now)+@($memory)){foreach($p in $row.PSObject.Properties){
        Assert-True ($p.Value -is [string]) ('Valeur non textuelle dans la section : '+$p.Name)
        Assert-True ($secretsText -notcontains [string]$p.Value) 'Un mot de passe atteint la section En ce moment'
    }}
    # A display never extends a lease: only a worker departure does.
    Assert-True ([datetime]$script:AccessState.Leases['ReadLaps'].LastUsedUtc -lt $script:Clock) 'L affichage a prolonge le bail'
}
Test-Case 'UI-27 Oublier : meme regle que la fenetre Acces, refus pendant une ecriture, section actualisee' {
    $script:Conn.BindUser='EXAMPLE\lecteur';$script:SecretsCredential=New-TestCredential 'EXAMPLE\secrets'
    $script:AccessState.Credentials['ReadLaps']=New-TestCredential 'EXAMPLE\laps-temp';$script:AccessState.Leases['ReadLaps']=New-AccessLease 'ReadLaps' 'EXAMPLE\laps-temp'
    $script:MachineCredential=New-TestCredential 'EXAMPLE\adm-poste'
    # The temporary LAPS account was rejected: the resource carries a fault and a LAPS refusal for this computer.
    $lapsScope=Get-DomeniaAccessScope 'ReadLaps'
    $script:AccessState.Faults[$lapsScope]=$true;$script:AccessState.Faults['Remote']=$true
    Set-DomeniaSecretDenied -Mode 'LAPS' -DN $script:Dn;Set-DomeniaSecretDenied -Mode 'BitLocker' -DN $script:Dn
    Initialize-DomeniaAccountsUi
    $generation=[long]$script:DomeniaAccountGeneration
    $click={param([string]$Key) $b=[Windows.Controls.Button]::new();$b.Tag=$Key;$script:Ctrl.DgAccountsInMemory.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent,$b))}
    $script:WriteState='Running'
    & $click 'ReadLaps'
    Assert-True ($script:AccessState.Credentials.ContainsKey('ReadLaps')) 'Compte oublie pendant une ecriture'
    Assert-True (@($script:Popups|Where-Object{$_ -match 'écriture'}).Count -eq 1) 'Refus non explique'
    Assert-True ($script:AccessState.Faults.ContainsKey($lapsScope)) 'Refus de la ressource efface alors que le compte est garde'
    $script:WriteState='Idle'
    & $click 'ReadLaps'
    Assert-True (-not $script:AccessState.Credentials.ContainsKey('ReadLaps')) 'Compte temporaire non oublie'
    # Same rule as Clear-DomeniaSecondaryCredential: the refusal of the forgotten account goes with it, so the guard of
    # Get-WorkerContext (Faults.ContainsKey(Get-DomeniaAccessScope $OperationId)) lets the configured account through.
    Assert-True (-not $script:AccessState.Faults.ContainsKey($lapsScope)) 'Le compte configure reste bloque par le refus du compte oublie'
    Assert-True (-not (Test-DomeniaSecretDenied 'LAPS' $script:Dn)) 'Refus LAPS du compte oublie conserve'
    Assert-True ((Test-DomeniaSecretDenied 'BitLocker' $script:Dn) -and ($script:AccessState.Faults.ContainsKey('Remote'))) 'Refus d une autre ressource efface'
    Assert-True ($null -eq (Get-DomeniaRetryCredential 'ReadLaps')) 'Compte oublie encore remis aux operations LAPS'
    $context=Get-CoreFunctionText 'Get-WorkerContext'
    Assert-True ($context.Contains('$retryScope=Get-DomeniaAccessScope $OperationId') -and $context.Contains('Faults.ContainsKey($retryScope)')) 'Garde des refus de Get-WorkerContext modifiee : revoir la regle de l oubli'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'reprend sa place'}).Count -eq 1) 'Statut de l oubli absent'
    Assert-True ([long]$script:DomeniaAccountGeneration -gt $generation) 'Generation des comptes inchangee'
    $lines=@(@($script:Ctrl.DgAccountsInUse.ItemsSource)|ForEach-Object{$_.Resource+'|'+$_.Account})
    Assert-True ($lines -contains 'Secrets : LAPS|EXAMPLE\secrets') ('Section non actualisee : '+($lines -join ' ; '))
    & $click 'Typed:Machine'
    Assert-True ($null -eq $script:MachineCredential) 'Compte poste saisi non oublie'
    Assert-True ($script:Ctrl.DgAccountsInMemory.Visibility -eq [Windows.Visibility]::Collapsed -and [string]$script:Ctrl.LblAccountsInMemory.Text -match '^Aucun compte') 'Etat vide non affiche'
    $page=Get-CoreFunctionText 'Update-DomeniaAccountUi'
    Assert-True ($page.Contains('Update-DomeniaAccountsInUse') -and -not $page.Contains('Update-DomeniaAccountsInUse -Force')) 'Page Comptes sans actualisation de la section, ou reconstruction forcee a chaque focus'
}

# ================================================================ UX-16 (lot X03) autorisation d intervention dans Actions
function Test-InsideNamed {param($Control,[string]$Name) $node=$Control;while($null -ne $node){$node=[Windows.LogicalTreeHelper]::GetParent($node);if(($node -is [Windows.FrameworkElement]) -and ([string]$node.Name -eq $Name)){return $true}};return $false}
Test-Case 'UX-16 Pastille d intervention dans Actions : sans Fiabilite, compte a rebours, poste cible seulement' {
    Assert-True ($script:Ctrl.TabGuard.Visibility -eq [Windows.Visibility]::Collapsed) 'Fiabilite rendue visible pour autoriser'
    foreach($n in @('BtnCompInterventionGrant','UxCompInterventionPill','BtnCompInterventionRevoke','BtnCompReadFallback','LblCompInterventionState')){Assert-True (Test-InsideNamed $script:Ctrl[$n] 'TabComputerAdmin') ($n+' hors de la vue Intervenir')}
    # X03 x X04: one authorisation control; the run panel states it and never grants it.
    Assert-True (-not $script:CoreText.Contains('x:Name="BtnCompRunConsent"')) 'Second bouton d autorisation dans le panneau Executer un programme'
    $guard=${function:Initialize-DomeniaGuard}.ToString()
    foreach($wire in @('BtnCompInterventionGrant={Set-DomeniaArtifactConsent}','BtnCompInterventionRevoke={Clear-DomeniaArtifactConsent}','BtnCompReadFallback={Set-DomeniaReadFallbackConsent}','BtnGuardRemoteOff={Clear-DomeniaArtifactConsent}','try{Update-DomeniaInterventionPill}')){Assert-True ($guard.Contains($wire)) ('Raccordement absent : '+$wire)}
    Update-DomeniaInterventionPill -Force
    Assert-True (($script:Ctrl.UxCompInterventionPill.Visibility -eq [Windows.Visibility]::Collapsed) -and $script:Ctrl.BtnCompInterventionGrant.IsEnabled) 'Etat initial : pastille visible ou accord impossible'
    Assert-True ([string]$script:Ctrl.LblCompInterventionState.Text -match '^Aucune intervention autorisée sur ce poste') $script:Ctrl.LblCompInterventionState.Text
    $script:Consent=$false;Set-DomeniaArtifactConsent
    Assert-True ($null -eq $script:ArtifactConsent) 'Autorisation accordee sans confirmation'
    $script:Consent=$true;Set-DomeniaArtifactConsent
    Assert-True (($null -ne $script:ArtifactConsent) -and ($script:ArtifactConsent.Target -eq 'pc-01.example.invalid') -and (@($script:ArtifactConsent.Aliases) -contains 'PC-01')) 'Autorisation non limitee au poste ouvert'
    Assert-True ($script:Ctrl.UxCompInterventionPill.Visibility -eq [Windows.Visibility]::Visible) 'Pastille absente pendant l autorisation'
    Assert-True ([string]$script:Ctrl.LblCompIntervention.Text -match '^Intervention autorisée [45]:\d\d ·$') ('Pastille : '+$script:Ctrl.LblCompIntervention.Text)
    Assert-True ($script:Ctrl.BtnCompInterventionGrant.Visibility -eq [Windows.Visibility]::Collapsed) 'Second accord propose pendant l autorisation'
    $script:ArtifactConsent.Expires=[datetime]::UtcNow.AddSeconds(61)
    Update-DomeniaInterventionPill
    Assert-True ([string]$script:Ctrl.LblCompIntervention.Text -match '^Intervention autorisée 1:0[01] ·$') ('Compte a rebours : '+$script:Ctrl.LblCompIntervention.Text)
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC-02,OU=Postes,DC=example,DC=invalid';Name='PC-02';Entry=[pscustomobject]@{Name='PC-02';Dns='pc-02.example.invalid'};Safety=[pscustomobject]@{Guid='22222222-2222-3333-4444-555555555555'}}
    Update-DomeniaInterventionPill
    Assert-True (($script:Ctrl.UxCompInterventionPill.Visibility -eq [Windows.Visibility]::Collapsed) -and $script:Ctrl.BtnCompInterventionGrant.IsEnabled) 'Autorisation affichee sur un autre poste'
    Assert-True ([string]$script:Ctrl.LblCompInterventionState.Text -match '^Une intervention est autorisée sur pc-01\.example\.invalid, pas sur ce poste\.') $script:Ctrl.LblCompInterventionState.Text
    Reset-Fixture
    $script:Consent=$true;Set-DomeniaArtifactConsent
    Clear-DomeniaArtifactConsent
    Assert-True (($null -eq $script:ArtifactConsent) -and ($script:Ctrl.UxCompInterventionPill.Visibility -eq [Windows.Visibility]::Collapsed)) 'Retirer sans effet'
    Assert-True (@($script:StatusLines|Where-Object{$_ -match 'Autorisation dʼintervention retirée'}).Count -eq 1) 'Retrait non annonce'
    # SE-07: the one-read consent stays a separate request, announced for its workstation only.
    Set-DomeniaReadFallbackConsent
    Assert-True (($null -ne $script:ReadFallbackConsent) -and ($null -eq $script:ArtifactConsent)) 'La lecture par tache a accorde une intervention'
    Assert-True ([string]$script:Ctrl.LblCompInterventionState.Text -match 'Prochaine lecture de ce poste autorisée par tâche planifiée \(une seule lecture\)\.$') $script:Ctrl.LblCompInterventionState.Text
    $script:SelectedObject=$null
    Update-DomeniaInterventionPill
    Assert-True ((-not $script:Ctrl.BtnCompInterventionGrant.IsEnabled) -and (-not $script:Ctrl.BtnCompReadFallback.IsEnabled)) 'Autorisation possible sans poste ouvert'
    $script:ReadFallbackConsent=$null
}
Test-Case 'UX-16 Refus du worker : renvoi vers Assistance poste > Intervenir, route du bandeau, plus de Fiabilite' {
    $tokens=$null;$errors=$null
    $commonAst=[Management.Automation.Language.Parser]::ParseInput($script:RealWorkerCommon,[ref]$tokens,[ref]$errors)
    foreach($name in @('Assert-WRemoteArtifactPermission','Assert-DomeniaReadFallbackPermission')){
        $node=@($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
        Assert-True ($node.Count -eq 1) ('Garde commune absente : '+$name)
        . ([scriptblock]::Create($node[0].Extent.Text))
    }
    $context=[pscustomobject]@{AllowRemoteArtifacts=$false;ArtifactTarget='';ArtifactAliases=@();AllowReadFallback=$false;ReadFallbackTarget='';ReadFallbackAliases=@()}
    foreach($call in @({Assert-WRemoteArtifactPermission -Context $context -Computer 'pc-01.example.invalid'},{Assert-DomeniaReadFallbackPermission -Context $context -Computer 'pc-01.example.invalid'})){
        $message='';try{& $call}catch{$message=[string]$_.Exception.Message}
        Assert-True ($message.Contains('Assistance poste > Intervenir') -and ($message -notmatch 'Fiabilit')) ('Refus sans renvoi utile : '+$message)
        Assert-True ((Get-DomeniaMessageRoute ('Rimotte PC-01 : '+$message)) -ceq 'TabComputerAdmin') 'Message sans route'
    }
    $route=Resolve-DomeniaCapabilityRoute -Route 'TabComputerAdmin'
    Assert-True (($route.Workspace -eq 'WsComputer') -and ($route.Inner -eq 'ComputerTabs') -and ($route.Tab -eq 'TabComputerAdmin') -and ($route.Label -ceq 'Assistance poste > Intervenir')) 'Route inexacte'
    Assert-True (Invoke-DomeniaCapabilityRoute -Route 'TabComputerAdmin') 'Route non suivie'
    Assert-True ($script:Routes -contains 'WsComputer|ComputerTabs|TabComputerAdmin') ('Navigation : '+($script:Routes -join ','))
    $banner=${function:Show-DomeniaBanner}.ToString();$command=${function:Invoke-DomeniaBannerCommand}.ToString()
    # UX-19 (X04): the route command also closes the banner once its place is open.
    Assert-True ($banner.Contains('Get-DomeniaMessageRoute') -and $command.Contains('Invoke-DomeniaCapabilityRoute -Route ([string]$record.Route)')) 'Bandeau sans action de route'
    [void](Update-DomeniaTransportPolicyView -Force)
    Assert-True ([string]$script:Ctrl.LblTransportPolicy.Text -match 'Assistance poste > Intervenir') ('Politique : '+$script:Ctrl.LblTransportPolicy.Text)
    Assert-True ($script:CoreText -notmatch 'dans Outils > Fiabilite') 'Un refus renvoie encore vers Outils > Fiabilite'
}

if($null -ne $script:SecretRevealTimer){try{$script:SecretRevealTimer.Stop()}catch{}}
if($null -ne $script:SecretCountdownTimer){try{$script:SecretCountdownTimer.Stop()}catch{}}
if($null -ne $script:Guard -and $null -ne $script:Guard.Timer){try{$script:Guard.Timer.Stop()}catch{}}
if($null -ne $script:MainWindow){try{$script:MainWindow.Close()}catch{}}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count;$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-acces-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{Suite='Test-DomeniaWiringAcces';Lot='acces';Points=@('D051','D052','D053','D054','D055','D056','D057','D058','D059','D060','P46','P42','P44','P45','UI-18','UI-31','UX-18');Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell=$native;Wpf=$true;MockedNetwork=$true;LiveAD=$false;LiveCIM=$false;Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$script:Checks.ToArray()}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussis, $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if(-not $report.Complete){exit 1}
exit 0
