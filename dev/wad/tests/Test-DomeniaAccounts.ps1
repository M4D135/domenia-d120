#requires -Version 5.1
<# R1.4, remis a niveau D120 (contrat asynchrone M15). Tests isoles des vraies fonctions de l'application.
   Les fonctions du coeur sont extraites par AST ; les modules viennent du plan ferme reel
   (wad\Domenia-Modules.ps1), dont Domenia-Accounts.Async.ps1 et Domenia-Access.UI.ps1.
   AUCUN lancement du coeur, AUCUN bind LDAP, AUCUN acces distant, AUCUNE fenetre WPF.
   Le demarrage, la lecture et le nettoyage du worker sont obligatoirement des doublures.
   La validation est asynchrone : un DispatcherTimer (WindowsBase) est cree mais jamais pompe ;
   chaque cas declenche lui-meme Complete-DomeniaAccountValidation, comme le ferait le tick.
   Les identites, domaines et mots de passe sont uniquement des donnees synthetiques.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$root=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$corePath=Join-Path $root 'wad\Domenia-Core.ps1'
Add-Type -AssemblyName WindowsBase
$source=[IO.File]::ReadAllText($corePath)
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if (@($errors).Count -gt 0) { throw ('Syntaxe du coeur : '+$errors[0].Message) }
# Closed module plan first (definitions only, verified origin). If Accounts.Async or Access.UI were
# removed from the plan, the import fails with DOMENIA_MODULE_EXPORT and every case below fails.
. (Join-Path $root 'wad\Domenia-Modules.ps1')
$functionNodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$names=@('New-DomeniaAccountAuthRequest','Test-DomeniaCredentialBind','Test-DomeniaActiveDirectoryCredential','Save-DomeniaSecondaryCredential','Get-WorkerContext','Set-ControlsBusy')
$definitions=New-Object 'System.Collections.Generic.List[string]'
foreach ($name in $names) {
    $found=@($functionNodes | Where-Object {$_.Name -eq $name})
    if ($found.Count -ne 1) { throw ('Fonction unique attendue : '+$name) }
    $definitions.Add($found[0].Extent.Text)
}
# Importer seulement les deux helpers sans reseau du code commun des workers.
$assignments=@($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals
},$true))
if ($assignments.Count -ne 1) { throw 'Code commun introuvable ou duplique.' }
$literal=$assignments[0].Right.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
$ct=$null; $ce=$null
$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$literal.Value,[ref]$ct,[ref]$ce)
if (@($ce).Count -gt 0) { throw 'Syntaxe du code commun invalide.' }
foreach ($name in @('Get-WDirectoryBindUser','Get-WAdCredential')) {
    $wanted=$name
    $found=@($commonAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $wanted},$true))
    if ($found.Count -ne 1) { throw ('Helper unique attendu : '+$name) }
    $definitions.Add($found[0].Extent.Text)
}
. ([scriptblock]::Create(($definitions.ToArray() -join "`n")))
$script:Results=New-Object 'System.Collections.Generic.List[object]'
function Assert-Test { param([bool]$Condition,[string]$Message='Assertion fausse.'); if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action,[string]$Pattern)
    $message=''
    try { & $Action | Out-Null } catch { $message=[string]$_.Exception.Message }
    Assert-Test (-not [string]::IsNullOrWhiteSpace($message)) 'Exception attendue, aucune recue.'
    Assert-Test ($message -match $Pattern) ('Exception inattendue : '+$message)
}
function New-TestPassword { return (ConvertTo-SecureString ' Test-Only ! & " / \ euro  ' -AsPlainText -Force) }
function New-TestCredential { param([string]$User); return [Management.Automation.PSCredential]::new($User,(New-TestPassword)) }
function New-TestPasswordField {
    # Stand-in for a WPF PasswordBox: Password, IsEnabled and the Clear() method used after activation.
    $field=[pscustomobject]@{Password='form-not-cleared';IsEnabled=$true}
    Add-Member -InputObject $field -MemberType ScriptMethod -Name Clear -Value { $this.Password='' }
    return $field
}
function Stop-FixtureValidation {
    # A validation left pending by a previous case keeps its timer: stop it, never pump it.
    if ($null -ne $script:AccountValidation) {
        try { if ($null -ne $script:AccountValidation.Timer) { $script:AccountValidation.Timer.Stop() } } catch { }
    }
    $script:AccountValidation=$null
}
function Reset-Fixture {
    Stop-FixtureValidation
    $script:StartCalls=0; $script:ReadCalls=0; $script:StopCalls=0; $script:WaitCalls=0
    $script:Mode='Success'; $script:WorkerBindUser=''
    $script:LastRequest=$null; $script:LastCredential=$null; $script:LastSession=$null; $script:LastError=''
    $script:Log=New-Object 'System.Collections.Generic.List[string]'
    $script:Settings=@{}; $script:AccountWrites=@{}; $script:UiUpdates=0; $script:SecretUiUpdates=0
    $script:SessionEpoch=1L; $script:AsyncEngineClosing=$false; $script:ActiveWriteTaskId=''; $script:WriteState='Idle'
    $script:ControlBusyRef=@{}; $script:AccessState=$null
    $script:Conn=[pscustomobject]@{
        Server='dc.example.test'; BaseDn='DC=example,DC=test'; Domain='example.test'; Netbios='EXAMPLE'
        BindUser='EXAMPLE\ad-reader'; User='EXAMPLE\ad-reader'; Credential=(New-TestCredential 'EXAMPLE\ad-reader')
        UseCredential=$true; AuthMode='Explicit'
    }
    $script:RemoteAdminCredential=New-TestCredential 'EXAMPLE\old-remote'
    $script:SecretsCredential=New-TestCredential 'EXAMPLE\old-secrets'
    $script:MachineCredential=$null
    $script:Ctrl=@{
        PwdAccountRemote=(New-TestPasswordField)
        PwdAccountSecrets=(New-TestPasswordField)
    }
    $script:DirectoryCredentialFaulted=$false; $script:DirectoryCredentialFaultMessage=''
    $script:RootDir=''; $script:DataDir=''; $script:AuditPath=''; $script:LaunchPath=''
    $script:Version='1.0'; $script:MasterBuild='TEST-ONLY'; $script:ProcessIdentity='EXAMPLE\windows-user'
    $script:AsyncEngineReady=$false; $script:RawAttributeBlockList=@(); $script:ReadOnlyMode=$true
    $script:ArtifactConsent=$null
    $script:WorkerContextStatic=[pscustomobject]@{
        AdModuleSources=@(); AdRequiredCommands=@(); AdTypeNames=@(); AdManagementHash=''; AdResourceHash=''
        MissingCriticalFunctions=@(); MissingCriticalControls=@(); CriticalFunctionCount=0; CriticalControlCount=0
        PowerShellVersion='test'; IsSta=$true
    }
}
function Test-Case {
    param([string]$Name,[scriptblock]$Action)
    Reset-Fixture
    try { & $Action | Out-Null; $status='PASS'; $detail='' }
    catch { $status='FAIL'; $detail=[string]$_.Exception.Message }
    finally { Stop-FixtureValidation }
    $script:Results.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
    if (-not $Quiet -or $status -eq 'FAIL') { Write-Host ("$status | $Name | $detail") }
}
# Mocks des frontieres reseau et UI : aucun worker reel ne peut etre lance.
function Start-DomeniaLoginAuthRunspace {
    param($Request)
    $script:StartCalls++
    if ($script:Mode -eq 'StartFailure') { throw 'TEST ONLY worker startup failed' }
    $script:LastRequest=$Request
    $script:LastCredential=$Request.Credential
    $wait=[pscustomobject]@{}
    # M15: the account path must never wait on the Dispatcher thread. Any WaitOne call fails the case.
    $wait | Add-Member -MemberType ScriptMethod -Name WaitOne -Value { $script:WaitCalls++; throw 'WaitOne interdit (M15) : la validation de compte doit rester asynchrone.' }
    # The native call is always still running when Start returns; Complete-Fixture marks it completed.
    $session=[pscustomobject]@{
        Request=$Request; Cleaned=$false; EndInvoked=$false; CancelRequested=$false
        AsyncResult=[pscustomobject]@{IsCompleted=$false;AsyncWaitHandle=$wait}
    }
    $script:LastSession=$session
    return $session
}
function Read-DomeniaAuthRunspaceResult {
    param($Session)
    $script:ReadCalls++
    if (-not [bool]$Session.AsyncResult.IsCompleted) { throw 'TEST ONLY: lecture d une validation non terminee.' }
    $Session.EndInvoked=$true
    if ($script:Mode -eq 'ReadFailure') { throw 'TEST ONLY worker result failed' }
    if ($script:Mode -eq 'NoResult') { return $null }
    $login=[string]$Session.Request.Login
    if ($script:WorkerBindUser) { $login=$script:WorkerBindUser }
    $success=($script:Mode -ne 'Rejected')
    $authMode='Explicit'; $method='ADSI.DirectoryEntry+ContextDiscovery'
    if ($script:Mode -eq 'NoBindUser') { $login='' }
    if ($script:Mode -eq 'WindowsResult') { $authMode='Windows';$method='LDAP.Protocols.Negotiate' }
    return [pscustomobject]@{
        Success=$success; BindUser=$login; Server=$Session.Request.ConfiguredServer; BaseDn=$Session.Request.ConfiguredBase
        AuthMode=$authMode; AuthMethod=$method; DurationMs=[long]7; Attempts=1
        Error=$(if($success){''}else{'TEST ONLY authentication rejected'})
    }
}
function Stop-DomeniaLoginAuthRunspace {
    # Same observable contract as the core function: cancel once while running, clean up once completed.
    param($Session,[switch]$Terminate)
    $script:StopCalls++
    if ($null -eq $Session -or [bool]$Session.Cleaned) { return }
    if (-not [bool]$Session.AsyncResult.IsCompleted -and $Terminate) { $Session.CancelRequested=$true }
    if ([bool]$Session.AsyncResult.IsCompleted) { $Session.Cleaned=$true; $Session.Request.Credential=$null }
}
function Show-DomeniaOperationError {
    param([string]$Operation,$ErrorRecordOrException,[string]$CorrelationId='',[switch]$NoPopup)
    $script:LastError=[string]$ErrorRecordOrException
    $script:Log.Add('ERREUR '+$Operation+' : '+$script:LastError)
}
function Add-DomeniaUiLog { param($Area,$Level,$Text); $script:Log.Add([string]$Text) }
function Set-Status { param($Text,$Level); $script:Log.Add([string]$Text) }
function Set-DomeniaSetting { param($Name,$Value); $script:Settings[$Name]=$Value }
function Save-DomeniaAccountPreference { param($Scope,$UserName,$Target);$script:AccountWrites[$Scope]=$UserName;return $true }
function Get-DomeniaControl { param($Name); return $script:Ctrl[$Name] }
function Update-DomeniaAccountUi { $script:UiUpdates++ }
function Update-DomeniaSecretActionUi { $script:SecretUiUpdates++ }
function Apply-CurrentPermissionUi { }
function Initialize-DomeniaWorkerContextCache {}
function Get-CfgValue { param($Section,$Name,$Default); return $Default }
function Complete-Fixture {
    # What the 100 ms DispatcherTimer tick does once the native validation has returned.
    param([switch]$StillRunning)
    if ($null -eq $script:AccountValidation) { throw 'Aucune validation en cours.' }
    if (-not $StillRunning) { $script:AccountValidation.Session.AsyncResult.IsCompleted=$true }
    Complete-DomeniaAccountValidation
}
function Get-FixtureLog { return ($script:Log.ToArray() -join "`n") }

Test-Case 'Requete : meme identite qualifiee et meme contexte que le login' {
    $p=New-TestPassword
    $r=New-DomeniaAccountAuthRequest -UserName ' EXAMPLE\operator ' -Password $p
    Assert-Test ($r.Login -ceq 'EXAMPLE\operator' -and $r.Credential.UserName -ceq $r.Login)
    Assert-Test ($r.ConfiguredServer -eq $script:Conn.Server -and $r.ConfiguredBase -eq $script:Conn.BaseDn)
    Assert-Test ($r.Netbios -eq 'EXAMPLE' -and $r.MaxServers -eq 1 -and -not $r.UseCurrentCredentials)
    Assert-Test ($script:StartCalls -eq 0)
}
Test-Case 'Requete : UPN conserve sans transformation' {
    $r=New-DomeniaAccountAuthRequest -UserName 'operator@alternate.example.test' -Password (New-TestPassword)
    Assert-Test ($r.Login -ceq 'operator@alternate.example.test' -and $r.Netbios -eq 'EXAMPLE')
}
Test-Case 'SecureString : copie distincte, lecture seule, espaces et caracteres conserves' {
    $p=New-TestPassword
    $r=New-DomeniaAccountAuthRequest -UserName 'EXAMPLE\operator' -Password $p
    Assert-Test (-not [object]::ReferenceEquals($p,$r.Credential.Password))
    Assert-Test ($r.Credential.Password.IsReadOnly())
    Assert-Test ($r.Credential.GetNetworkCredential().Password -ceq [Net.NetworkCredential]::new('',$p).Password)
    $r.Credential.Password.Dispose()
    Assert-Test ($p.Length -gt 0) 'La copie a invalide le mot de passe du formulaire.'
}
Test-Case 'Contexte incomplet refuse avant tout appel au worker' {
    $script:Conn.BaseDn=''
    Assert-Throws {Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword)} 'Contexte AD incomplet'
    Assert-Test ($script:StartCalls -eq 0 -and $null -eq $script:AccountValidation)
}
Test-Case 'Mot de passe vide refuse sans authentification' {
    $empty=New-Object Security.SecureString
    Assert-Throws {Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password $empty} 'mot de passe requis'
    Assert-Test ($script:StartCalls -eq 0 -and $null -eq $script:AccountValidation)
}
Test-Case 'Succes : un seul worker de login, lecture et nettoyage' {
    $r=Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword)
    # The call returns immediately; the result is read later by the tick, never awaited.
    Assert-Test ($r.Started -and $r.Pending -and -not $r.Success) 'La validation doit rester en attente sans bloquer.'
    Assert-Test ($script:StartCalls -eq 1 -and $script:ReadCalls -eq 0 -and $null -ne $script:AccountValidation)
    Assert-Test (-not $script:Ctrl['PwdAccountRemote'].IsEnabled) 'Formulaire non verrouille pendant la validation.'
    Complete-Fixture
    Assert-Test ($script:StartCalls -eq 1 -and $script:ReadCalls -eq 1 -and $script:StopCalls -eq 1)
    Assert-Test ($null -eq $script:AccountValidation -and $script:LastSession.Cleaned)
    Assert-Test ((Get-FixtureLog) -match 'Identite AD validee : EXAMPLE\\operator') (Get-FixtureLog)
    Assert-Test ($script:Ctrl['PwdAccountRemote'].IsEnabled -and -not $script:LastError) 'Formulaire non rendu ou erreur inattendue.'
}
Test-Case 'Aucune attente bloquante (M15)' {
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture -StillRunning
    Complete-Fixture
    Assert-Test ($script:WaitCalls -eq 0 -and -not $script:LastError) ('WaitOne appele '+$script:WaitCalls+' fois ; '+$script:LastError)
}
Test-Case 'Identite canonique du worker retournee telle quelle' {
    $script:WorkerBindUser='EXAMPLE\operator'
    [void](Test-DomeniaCredentialBind -UserName 'operator' -Password (New-TestPassword))
    Assert-Test ($script:LastCredential.UserName -ceq 'operator') 'Le nom saisi a ete transforme avant envoi.'
    Complete-Fixture
    Assert-Test ((Get-FixtureLog) -match 'Identite AD validee : EXAMPLE\\operator') (Get-FixtureLog)
}
Test-Case 'Refus : aucun repli de compte, aucun retry' {
    $script:Mode='Rejected'
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture
    Assert-Test ($script:LastError -match 'Validation non confirmee' -and $script:LastError -match 'authentication rejected') $script:LastError
    Assert-Test ($script:StartCalls -eq 1 -and $script:StopCalls -eq 1 -and $null -eq $script:AccountValidation)
    Assert-Test ($script:Conn.BindUser -eq 'EXAMPLE\ad-reader')
}
Test-Case 'Timeout : resultat non lu, second essai bloque tant que le natif tourne' {
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    $script:AccountValidation.Started=[datetime]::UtcNow.AddSeconds(-13)
    Complete-Fixture -StillRunning
    Assert-Test ($script:AccountValidation.Abandoned -and $script:LastSession.CancelRequested) 'Validation trop longue non abandonnee.'
    Assert-Test ($script:ReadCalls -eq 0 -and $null -ne $script:AccountValidation)
    Assert-Test ((Get-FixtureLog) -match 'Validation trop longue') (Get-FixtureLog)
    Assert-Throws {Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword)} 'deja active'
    Assert-Test ($script:StartCalls -eq 1)
}
Test-Case 'Apres timeout termine : nouvel essai volontaire possible' {
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    $script:AccountValidation.Started=[datetime]::UtcNow.AddSeconds(-13)
    Complete-Fixture -StillRunning
    # The abandoned native call ends: cleaned up, its late result is never read.
    Complete-Fixture
    Assert-Test ($null -eq $script:AccountValidation -and $script:ReadCalls -eq 0) 'Resultat tardif lu ou nettoyage absent.'
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture
    Assert-Test ($script:StartCalls -eq 2 -and $script:ReadCalls -eq 1 -and (Get-FixtureLog) -match 'Identite AD validee')
}
Test-Case 'Echec demarrage : aucun faux etat de test actif' {
    $script:Mode='StartFailure'
    Assert-Throws {Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword)} 'startup failed'
    Assert-Test ($null -eq $script:AccountValidation -and $script:Ctrl['PwdAccountRemote'].IsEnabled)
}
Test-Case 'Resultat vide refuse et worker nettoye' {
    $script:Mode='NoResult'
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture
    Assert-Test ($script:LastError -match 'Validation non confirmee') $script:LastError
    Assert-Test ($script:StopCalls -eq 1 -and $null -eq $script:AccountValidation)
}
Test-Case 'Resultat sans nom valide refuse' {
    $script:Mode='NoBindUser'
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture
    Assert-Test ($script:LastError -match 'Identite AD non confirmee') $script:LastError
    Assert-Test (-not ((Get-FixtureLog) -match 'Identite AD validee'))
}
Test-Case 'Un resultat sous identite Windows ne valide pas le compte saisi' {
    $script:Mode='WindowsResult'
    [void](Test-DomeniaCredentialBind -UserName 'EXAMPLE\operator' -Password (New-TestPassword))
    Complete-Fixture
    Assert-Test ($script:LastError -match 'Identite AD non confirmee') $script:LastError
    Assert-Test (-not ((Get-FixtureLog) -match 'Identite AD validee'))
}
Test-Case 'Activation Remote : nom valide, seul identifiant persiste, AD intact' {
    $originalAd=$script:Conn.Credential
    $script:WorkerBindUser='EXAMPLE\operator'
    $p=New-TestPassword
    Save-DomeniaSecondaryCredential -Scope Remote -UserName 'operator' -Password $p
    Assert-Test ($script:RemoteAdminCredential.UserName -ceq 'EXAMPLE\old-remote') 'Compte remplace avant la fin de la validation.'
    Complete-Fixture
    Assert-Test ($script:RemoteAdminCredential.UserName -ceq 'EXAMPLE\operator')
    Assert-Test ($script:Settings.Count -eq 0 -and $script:AccountWrites['Remote'] -ceq 'EXAMPLE\operator')
    Assert-Test ([object]::ReferenceEquals($originalAd,$script:Conn.Credential))
    Assert-Test ($script:Ctrl['PwdAccountRemote'].Password -eq '' -and $script:UiUpdates -eq 1)
    Assert-Test ($script:RemoteAdminCredential.GetNetworkCredential().Password -ceq [Net.NetworkCredential]::new('',$p).Password)
    Assert-Test ($script:StartCalls -eq 1)
}
Test-Case 'Activation Secrets : identite propre, compte distant inchange' {
    $oldRemote=$script:RemoteAdminCredential
    $script:WorkerBindUser='EXAMPLE\secrets-reader'
    Save-DomeniaSecondaryCredential -Scope Secrets -UserName 'secrets-reader' -Password (New-TestPassword)
    Complete-Fixture
    Assert-Test ($script:SecretsCredential.UserName -ceq 'EXAMPLE\secrets-reader')
    Assert-Test ([object]::ReferenceEquals($oldRemote,$script:RemoteAdminCredential))
    Assert-Test ($script:Settings.Count -eq 0 -and $script:AccountWrites['Secrets'] -ceq 'EXAMPLE\secrets-reader')
    Assert-Test ($script:Ctrl['PwdAccountSecrets'].Password -eq '' -and $script:Ctrl['PwdAccountRemote'].Password -eq 'form-not-cleared')
}
Test-Case 'Activation refusee : ancien compte et formulaire conserves' {
    $oldRemote=$script:RemoteAdminCredential; $p=New-TestPassword; $script:Mode='Rejected'
    Save-DomeniaSecondaryCredential -Scope Remote -UserName 'EXAMPLE\operator' -Password $p
    Complete-Fixture
    Assert-Test ($script:LastError -match 'Validation non confirmee') $script:LastError
    Assert-Test ([object]::ReferenceEquals($oldRemote,$script:RemoteAdminCredential))
    Assert-Test ($script:Settings.Count -eq 0 -and $script:Ctrl['PwdAccountRemote'].Password -eq 'form-not-cleared')
    Assert-Test ($p.Length -gt 0 -and $null -ne $script:LastCredential)
}
Test-Case 'Activation en timeout : aucune modification meme apres retour tardif' {
    $oldRemote=$script:RemoteAdminCredential
    Save-DomeniaSecondaryCredential -Scope Remote -UserName 'EXAMPLE\operator' -Password (New-TestPassword)
    $script:AccountValidation.Started=[datetime]::UtcNow.AddSeconds(-13)
    Complete-Fixture -StillRunning
    Complete-Fixture
    Assert-Test ([object]::ReferenceEquals($oldRemote,$script:RemoteAdminCredential) -and $script:Settings.Count -eq 0)
    Assert-Test ($script:ReadCalls -eq 0 -and $script:Ctrl['PwdAccountRemote'].Password -eq 'form-not-cleared')
}
Test-Case 'Test compte AD : nom modifie refuse sans envoyer le mot de passe actif' {
    Assert-Throws {Test-DomeniaActiveDirectoryCredential -UserName 'EXAMPLE\another-user'} 'champ identifiant AD a ete modifie'
    Assert-Test ($script:StartCalls -eq 0)
}
Test-Case 'Test compte AD : nom court du meme domaine accepte avec identite active exacte' {
    $r=Test-DomeniaActiveDirectoryCredential -UserName 'AD-READER'
    Assert-Test ($r.Pending -and $script:LastCredential.UserName -ceq 'EXAMPLE\ad-reader')
    Complete-Fixture
    Assert-Test ((Get-FixtureLog) -match 'Identite AD validee : EXAMPLE\\ad-reader') (Get-FixtureLog)
}
Test-Case 'Test compte AD : session Windows seule ne remplace pas le compte saisi' {
    $script:Conn.Credential=$null
    Assert-Throws {Test-DomeniaActiveDirectoryCredential -UserName 'EXAMPLE\ad-reader'} 'Aucun compte AD explicite'
    Assert-Test ($script:StartCalls -eq 0)
}
Test-Case 'Worker LAPS : nom et mot de passe du compte Secrets restent ensemble' {
    $ctx=Get-WorkerContext -OperationId 'ReadLaps'
    $cred=Get-WAdCredential $ctx
    Assert-Test ($ctx.BindUser -ceq 'EXAMPLE\old-secrets' -and $cred.UserName -ceq 'EXAMPLE\old-secrets')
    Assert-Test ([object]::ReferenceEquals($cred,$script:SecretsCredential))
}
Test-Case 'Worker BitLocker : compte Secrets explicite et repli AD coherents' {
    $ctx=Get-WorkerContext -OperationId 'ReadBitLocker'
    Assert-Test ($ctx.BindUser -ceq 'EXAMPLE\old-secrets')
    $script:SecretsCredential=$null
    $ctx=Get-WorkerContext -OperationId 'ReadBitLocker'
    Assert-Test ($ctx.BindUser -ceq 'EXAMPLE\ad-reader' -and $ctx.Credential.UserName -ceq $ctx.BindUser)
}
Test-Case 'Dernier utilisateur : compte machine distinct du compte annuaire' {
    $ctx=Get-WorkerContext -OperationId 'ComputerLastUser'
    Assert-Test ($ctx.BindUser -ceq 'EXAMPLE\ad-reader' -and $ctx.Credential.UserName -ceq $ctx.BindUser)
    Assert-Test ($ctx.RemoteAdminUser -ceq 'EXAMPLE\old-remote' -and $ctx.MachineCredential.UserName -ceq 'EXAMPLE\old-remote')
}
Test-Case 'Validation de compte : ne promet pas les droits sur les ressources, pas de secret dans les logs' {
    $p=New-TestPassword
    Save-DomeniaSecondaryCredential -Scope Remote -UserName 'EXAMPLE\operator' -Password $p
    Complete-Fixture
    $log=Get-FixtureLog
    $syntheticSecret=[Net.NetworkCredential]::new('',$p).Password
    Assert-Test (-not $log.Contains($syntheticSecret)) 'Mot de passe synthetique present dans les logs.'
    # Since M15 the status names what is NOT certified instead of the R1.4 sentence about WMI/SMB rights.
    Assert-Test ($log.Contains('Droits sur la ressource non certifies par ce test AD.')) $log
}
Test-Case 'Ecriture en cours : aucun compte ne peut etre change' {
    $script:ActiveWriteTaskId='write-1'
    Assert-Throws {Save-DomeniaSecondaryCredential -Scope Remote -UserName 'EXAMPLE\operator' -Password (New-TestPassword)} 'ecriture'
    Assert-Test ($script:StartCalls -eq 0 -and $null -eq $script:AccountValidation)
}

$failed=@($script:Results | Where-Object {$_.Status -ne 'PASS'}).Count
$report=[ordered]@{
    Build='2026.10.02-DOMENIA-1.0-RC1.11.0-D120-ACCOUNTS'; Mode='NativePowerShellWithMocks'; PowerShell=$PSVersionTable.PSVersion.ToString()
    RunAt=(Get-Date).ToString('o'); LiveAdExecuted=$false; WpfExecuted=$false; DispatcherPumped=$false
    Passed=($script:Results.Count-$failed); Failed=$failed; Tests=$script:Results.ToArray()
}
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-accounts-report-'+[guid]::NewGuid().ToString('N')+'.json') }
$reportDir=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ReportPath)); [void][IO.Directory]::CreateDirectory($reportDir)
[IO.File]::WriteAllText($ReportPath,($report | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Host ('Comptes : '+$report.Passed+' OK, '+$failed+' echec(s). Rapport : '+$ReportPath)
if ($failed -gt 0) { throw ($failed.ToString()+' test(s) comptes en echec. Installation non autorisee.') }
