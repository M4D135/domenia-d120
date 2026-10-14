#requires -Version 5.1
# D051-D060 (lot acces), UI-18, UI-31 et UX-18 (recus et secrets) : preuves de raccordement. Chaque cas exerce le vrai code livre et echoue si la regle pure
# n'est plus appelee par l'application. Methode du projet : le vrai chargeur ferme Domenia-Modules.ps1 est
# dot-source, les fonctions du coeur sont extraites par AST, seules les frontieres reseau (Start-UiTask, validation
# de compte, recherche LDAP) et modales (Confirm-Action, Show-DomeniaDialog) sont doublees, les controles WPF sont
# ceux du vrai XAML principal. Aucun mot de passe : les valeurs factices sont generees a l'execution.
[CmdletBinding()]
param([string]$ReportPath='',[switch]$Quiet)
$ErrorActionPreference='Stop'
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
$coreNames=@('Protect-DomeniaLogText','ConvertTo-DomeniaErrorInfo','Show-DomeniaOperationError','Write-AppLog','Get-MainXaml','Get-DomeniaControl','Set-DomeniaControlText','Set-DomeniaItemsSource','Get-DomeniaGridDateSortKey','Get-DomeniaGridDateShortText','Add-DomeniaGridDateKeys','Get-DomeniaEffectiveWorkerResult',
    'Update-SecretsGrid','Get-DomeniaSelectedSecretSource','Test-DomeniaSecretCallbackCurrent','Clear-DomeniaSecretResultValues','Complete-DomeniaSecretLoadUi','Fail-DomeniaSecretLoadUi','Start-LoadComputerSecrets',
    'Toggle-SecretsVisibility','Copy-SelectedSecret','Copy-AllSecrets','Update-DomeniaSecretActionUi','Test-DomeniaControlIsBusy',
    'New-DomeniaWorkerRunspace','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Get-DomeniaWorkerOperationHashes','Assert-DomeniaWorkerOperationCode',
    'Get-DomeniaBootThemePalette','Get-DomeniaBootThemeResources','Convert-DomeniaXamlToBootTheme',
    # L02: incident code of Show-DomeniaOperationError and queued Domenia.log writer of Write-AppLog.
    'New-DomeniaIncidentCode','Get-DomeniaErrorSignature','Register-DomeniaErrorOccurrence',
    'ConvertTo-DomeniaLogFileLines','Get-DomeniaAppLogFallbackPaths','Write-DomeniaAppLogFile','Start-DomeniaAppLogFlushTimer','Stop-DomeniaAppLogQueue',
    'Invoke-DomeniaAppLogRotation','Flush-DomeniaAppLog','Invoke-DomeniaAppLogFlush','Set-DomeniaAppLogAvailability','Test-DomeniaInternalFault','Test-DomeniaOperatorMessage')
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
$xamlReader=[Xml.XmlNodeReader]::new([xml](Get-MainXaml))
try{$script:MainWindow=[Windows.Markup.XamlReader]::Load($xamlReader)}finally{$xamlReader.Close()}
$script:MainControls=@{}
foreach($match in [regex]::Matches((Get-MainXaml),'x:Name="([^"]+)"')){
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
    $script:AccessCurrentJob=$null;$script:DirectoryCredentialFaulted=$false
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
    Assert-True ($script:Tasks.Count -eq 0 -and $script:AccessState.Credentials.ContainsKey('AD:WriteRename')) 'Ecriture rejouee'
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
    Assert-True (@($lines.Lines|Where-Object{$_ -match 'Lire LAPS' -and $_ -match 'Aller a : Rechercher'}).Count -eq 1) 'Bilan sans motif ni route pour LAPS'
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
    Assert-True ($bound[0].DisplayValue -ceq $value -and [string]$bound[1].DisplayValue -eq '') 'Seule la cle choisie doit etre lue et affichee'
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
    Assert-True (-not $script:Ctrl.BtnCopyAllSecrets.IsEnabled) 'Copie groupee active'
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

# ================================================================ UI-18 receipts in plain words, review in the page
# These cases run last: they give the real main window to the in-page confirmation (Domenia-Inline.UI.ps1), which
# then stays laid over its content grid for the rest of the run.
function Invoke-TestClick {param($Button) $Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))}
function New-ReceiptRow {param([string]$Id,[string]$Operation,[string]$Stage,[string]$Updated,[string]$Review='')
    return [pscustomobject]@{Id=$Id;PlanFingerprint='';Operation=$Operation;DN='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid';Identity='EXAMPLE\adm';Server='dc1.example.invalid';Stage=$Stage;UpdatedUtc=$Updated;Review=$Review}
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

if($null -ne $script:SecretRevealTimer){try{$script:SecretRevealTimer.Stop()}catch{}}
if($null -ne $script:MainWindow){try{$script:MainWindow.Close()}catch{}}
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count;$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-acces-'+[guid]::NewGuid().ToString('N')+'.json')}
$report=[ordered]@{Suite='Test-DomeniaWiringAcces';Lot='acces';Points=@('D051','D052','D053','D054','D055','D056','D057','D058','D059','D060','UI-18','UI-31','UX-18');Host=$PSVersionTable.PSVersion.ToString();NativeWindowsPowerShell=$native;Wpf=$true;MockedNetwork=$true;LiveAD=$false;LiveCIM=$false;Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$script:Checks.ToArray()}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){Write-Host ("$passed reussis, $failed en echec. Rapport : "+$ReportPath);$script:Checks|Where-Object{$_.Status -eq 'Failed'}|ForEach-Object{Write-Host ('  ECHEC '+$_.Name+' : '+$_.Detail)}}
if(-not $report.Complete){exit 1}
exit 0
