#requires -Version 5.1
<# R1.2: tests isoles des fonctions REELLES extraites par l AST PowerShell.
   Aucun lancement d DOMENIA, aucune connexion AD/SMB, aucun PsExec/schtasks reel.
   Les executables factices sont vides ; le lanceur de processus est remplace
   par un mock avant tout appel. Tous les fichiers vivent dans TEMP.
   D120 : le Planificateur passe par l API COM depuis RC1.9 ; aucun cas n instancie
   Schedule.Service (les gardes testees refusent avant toute connexion).
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$packageRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$corePath=Join-Path $packageRoot 'wad\Domenia-Core.ps1'
$source=[IO.File]::ReadAllText($corePath)
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw ('Syntaxe du coeur : '+$parseErrors[0].Message) }
$assignments=@($ast.FindAll({param($n)
    $n -is [Management.Automation.Language.AssignmentStatementAst] -and
    $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals
},$true))
if ($assignments.Count -ne 1) { throw 'Code commun des workers introuvable ou duplique.' }
$commonLiteral=$assignments[0].Right.Find({param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
$commonTokens=$null;$commonErrors=$null
$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$commonLiteral.Value,[ref]$commonTokens,[ref]$commonErrors)
if (@($commonErrors).Count -gt 0) { throw ('Syntaxe du code commun : '+$commonErrors[0].Message) }
$commonNames=@('Get-WAdCredential','Get-WDirectoryBindUser','Get-WRemoteAdminCredential','Get-WMachineCredential',
    'Get-WRemoteComputerName','Assert-WRemoteArtifactPermission','ConvertTo-WProcessQuotedArg','Get-WPsExecPath','Invoke-WRemotePsExecScript',
    'Invoke-WSchtasksRemote','New-WAdminShareDrive','Remove-WAdminShareDrive','New-WRunOnceTaskXml',
    'Get-WSchtasksHint','Invoke-WRemoteScheduledTaskScript','Format-WRemoteFailureDetail','Get-WProbeAttemptSummary',
    'Test-WUserInAd','Escape-WLdap','Normalize-WUser')
$commonNodes=@($commonAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$mainNodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
$definitions=New-Object 'System.Collections.Generic.List[string]'
foreach ($name in $commonNames) {
    $found=@($commonNodes | Where-Object {$_.Name -eq $name})
    if ($found.Count -ne 1) { throw ('Fonction commune unique requise : '+$name) }
    $definitions.Add($found[0].Extent.Text)
}
foreach ($name in @('Get-WorkerContext','Get-DomeniaWorkerOperationHashes','Get-DomeniaWorkerCodeHash','ConvertTo-DomeniaCanonicalWorkerCode')) {
    $found=@($mainNodes | Where-Object {$_.Name -eq $name})
    if ($found.Count -ne 1) { throw ('Fonction principale unique requise : '+$name) }
    $definitions.Add($found[0].Extent.Text)
}
# Definitions seules : aucune initialisation WPF ou reseau du projet.
. ([scriptblock]::Create(($definitions.ToArray() -join "`n")))
# D120 resync: Get-WorkerContext relies on the access functions of the closed module plan
# (Get-DomeniaRetryCredential, Get-DomeniaAccessScope, Set-DomeniaRetryWorkerContext). Import the real plan.
. (Join-Path $packageRoot 'wad\Domenia-Modules.ps1')
$lastUserFunction=@($mainNodes | Where-Object {$_.Name -eq 'Start-ComputerUserLinkProbe'})[0]
$workerStrings=@($lastUserFunction.FindAll({param($n)
    $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.StartsWith('$attempts = New-Object')
},$true))
if ($workerStrings.Count -ne 1) { throw 'Corps ComputerLastUser introuvable.' }
$workerText=[string]$workerStrings[0].Value
$workerTokens=$null;$workerErrors=$null
[void][Management.Automation.Language.Parser]::ParseInput($workerText,[ref]$workerTokens,[ref]$workerErrors)
if (@($workerErrors).Count -gt 0) { throw ('Syntaxe du resolver : '+$workerErrors[0].Message) }
$script:Results=New-Object 'System.Collections.Generic.List[object]'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-remote-tests-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'wad'))
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'share\Temp'))
[IO.File]::WriteAllText((Join-Path $testRoot 'wad\PsExec.exe'),'')
if ([string]::IsNullOrWhiteSpace($ReportPath)) { $ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-remote-report-'+[guid]::NewGuid().ToString('N')+'.json') }
function Assert-Test { param([bool]$Condition,[string]$Message='Assertion fausse'); if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action,[string]$Pattern)
    $caught=''
    try { & $Action | Out-Null } catch { $caught=[string]$_.Exception.Message }
    Assert-Test (-not [string]::IsNullOrWhiteSpace($caught)) 'Exception attendue, aucune exception recue.'
    Assert-Test ($caught -match $Pattern) ('Exception inattendue : '+$caught)
}
function Test-Case {
    # The label parameter must not be called $Name: PowerShell variable names ignore case, so a
    # $Name parameter masked the loop variable $name of the target cases and the real function
    # received the case label instead of the target (baseline 'Cible unique valide' failures).
    param([string]$CaseLabel,[scriptblock]$Action)
    try { & $Action | Out-Null; $status='PASS'; $detail='' }
    catch { $status='FAIL'; $detail=$_.Exception.Message }
    $script:Results.Add([pscustomobject]@{Name=$CaseLabel;Status=$status;Detail=$detail})
    if (-not $Quiet -or $status -eq 'FAIL') { Write-Host ("$status | $CaseLabel | $detail") }
}
function New-TestCredential {
    param([string]$User)
    return New-Object Management.Automation.PSCredential -ArgumentList @($User,(ConvertTo-SecureString 'Test only ! " and \' -AsPlainText -Force))
}
$adCred=New-TestCredential 'EXAMPLE\ad-reader'
$remoteCred=New-TestCredential 'EXAMPLE\remote-operator'
$machineCred=New-TestCredential 'EXAMPLE\machine-operator'
$context=[pscustomobject]@{
    RootDir=(Join-Path $testRoot 'wad');ScriptPath=(Join-Path $testRoot 'Domenia.ps1')
    MachineCredential=$null;RemoteAdminCredential=$null;RemoteAdminUser='';Credential=$null;UseCredential=$false
    BindUser='';ProcessIdentity='EXAMPLE\windows-user';BaseDn='DC=example,DC=test'
    UseWinRM=$false;UseCim=$true;UseTaskFallback=$true;UsePsExecFallback=$true;TaskFallbackTimeoutSeconds=30
    # Explicit operator consent for remote artifacts, as built by Get-WorkerContext from $script:ArtifactConsent.
    AllowRemoteArtifacts=$true;ArtifactTarget='TESTPC';ArtifactAliases=@()
}
$script:RemoteAdminCredential=$null
$script:NativeCalls=0;$script:NativeExitCode=0;$script:NativeMode='Success';$script:SentArguments=@()
# MOCK OBLIGATOIRE : ne jamais importer le vrai Invoke-WQuietProcess dans ce test.
function Invoke-WQuietProcess {
    param([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds)
    $script:NativeCalls++
    $script:SentArguments=[string[]]$Arguments.Clone()
    $script:SentExecutable=$FilePath
    $output='SYSINTERNALS SOFTWARE LICENSE TERMS BY USING THE SOFTWARE, YOU ACCEPT THESE TERMS.'
    if ($script:NativeMode -eq 'Success') {
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"Candidates":[],"TestOnly":true}'))
        $output='__DOMENIA_PSEXEC_BEGIN__'+$encoded+'__DOMENIA_PSEXEC_END__'
    }
    return [pscustomobject]@{ExitCode=$script:NativeExitCode;Output=$output}
}
$script:ShareMode='Record';$script:ShareCalls=0;$script:CreatedDriveNames=New-Object 'System.Collections.Generic.List[string]'
function New-PSDrive {
    [CmdletBinding()]
    param([string]$Name,[string]$PSProvider,[string]$Root,$Credential,[string]$Scope)
    $script:ShareCalls++;$script:ShareCredential=$Credential;$script:ShareRoot=$Root;$script:ShareDriveName=$Name
    if ($script:ShareMode -eq 'Denied') { throw 'TEST ONLY: acces refuse (5)' }
    if ($script:ShareMode -eq 'Local') {
        [void](Microsoft.PowerShell.Management\New-PSDrive -Name $Name -PSProvider FileSystem -Root (Join-Path $testRoot 'share') -Scope Script)
        $script:CreatedDriveNames.Add($Name)
    }
    return [pscustomobject]@{Name=$Name;Root=$Root}
}
function Initialize-DomeniaWorkerContextCache {}
function Get-CfgValue { param($Section,$Name,$Default); return $Default }
$script:WorkerContextStatic=[pscustomobject]@{AdModuleSources=@();AdRequiredCommands=@();AdTypeNames=@();AdManagementHash='';AdResourceHash='';MissingCriticalFunctions=@();MissingCriticalControls=@();CriticalFunctionCount=0;CriticalControlCount=0;PowerShellVersion='test';IsSta=$true}
$script:Conn=[pscustomobject]@{Server='dc.example.test';BaseDn='DC=example,DC=test';Domain='example.test';Netbios='EXAMPLE';BindUser=$adCred.UserName;Credential=$adCred;UseCredential=$true;AuthMode='Explicit'}
$script:DirectoryCredentialFaulted=$false;$script:DirectoryCredentialFaultMessage=''
$script:MachineCredential=$null;$script:SecretsCredential=$null;$script:RawAttributeBlockList=@();$script:Ctrl=@{}
$script:LdapMode='Found'
function New-WSearcher {
    param($Context,$BaseDn,$Filter,$Properties,$Scope,$Limit)
    $root=[pscustomobject]@{}
    $root | Add-Member ScriptMethod Dispose { if($script:LdapMode -eq 'DisposeError'){throw 'TEST ONLY dispose'} }
    $searcher=[pscustomobject]@{SearchRoot=$root}
    $searcher | Add-Member ScriptMethod Dispose { if($script:LdapMode -eq 'DisposeError'){throw 'TEST ONLY dispose'} }
    $searcher | Add-Member ScriptMethod FindOne {
        if($script:LdapMode -eq 'Error'){throw 'TEST ONLY LDAP access denied'}
        if($script:LdapMode -eq 'Missing'){return $null}
        return [pscustomobject]@{Name='alice'}
    }
    return $searcher
}
try {
    Test-Case 'Parseur natif: coeur, code commun et resolver' { Assert-Test ($null -ne $ast -and $null -ne $commonAst) }
    Test-Case 'Empreinte du vrai worker ComputerLastUser' {
        $registry=Get-DomeniaWorkerOperationHashes
        Assert-Test ((Get-DomeniaWorkerCodeHash -Code $workerText) -ceq [string]$registry['ComputerLastUser']) 'Empreinte incoherente.'
    }
    Test-Case 'Reproduction de l ancienne concatenation incorrecte (aucun processus)' {
        $Computer='TESTPC';$bad=@('\\'+$Computer,'-accepteula','-nobanner')
        Assert-Test ($bad.Count -eq 1 -and $bad[0] -match 'TESTPC.+accepteula') 'La reproduction du defaut a change.'
    }
    foreach ($remoteTarget in @('TESTPC','pc-01.example.test','192.0.2.10')) {
        Test-Case ('Cible unique valide : '+$remoteTarget) { Assert-Test ((Get-WRemoteComputerName $remoteTarget) -ceq $remoteTarget) ('Cible modifiee ou refusee : '+$remoteTarget) }
    }
    foreach ($remoteTarget in @('','*','PC1,PC2','PC1 -s','\\PC1','-accepteula','PC1;cmd')) {
        Test-Case ('Cible invalide rejetee : '+$remoteTarget) { Assert-Throws {Get-WRemoteComputerName $remoteTarget} 'invalide' }
    }
    foreach ($case in @(
        @{Value='';Expected='""'},@{Value='plain';Expected='plain'},@{Value='EXAMPLE\user';Expected='EXAMPLE\user'},
        @{Value='two words';Expected='"two words"'},@{Value='ab"cd';Expected='"ab\"cd"'},
        @{Value='C:\path with space\';Expected='"C:\path with space\\"'}
    )) {
        Test-Case ('Encodage argument natif : '+$case.Value) { Assert-Test ((ConvertTo-WProcessQuotedArg $case.Value) -ceq $case.Expected) 'Encodage incorrect.' }
    }
    Test-Case 'PsExec: cible et deux options distinctes, contexte Windows' {
        $r=Invoke-WRemotePsExecScript $context 'TESTPC' '[pscustomobject]@{TestOnly=$true}' @{} 10
        Assert-Test ($script:SentArguments[0] -ceq '\\TESTPC') 'Cible concatenee avec les options.'
        Assert-Test ($script:SentArguments[1] -ceq '-accepteula' -and $script:SentArguments[2] -ceq '-nobanner') 'Options absentes ou fusionnees.'
        Assert-Test ($script:SentArguments -notcontains '-u' -and $r.DomeniaTransport -eq 'PsExec')
        Assert-Test ($script:SentArguments -contains '-EncodedCommand')
    }
    # ARCHIVE (docs/history/ARCHIVE-SUITES-RC1.11.md): 'compte poste explicite prioritaire, mot de passe preserve'
    # asserted '-p <password>' in the PsExec arguments; that transport was removed on purpose (no secret in a
    # process argument). The replacement proves the refusal instead.
    Test-Case 'PsExec: compte explicite refuse, aucun mot de passe en ligne de commande' {
        $before=$script:NativeCalls
        try {
            $context.MachineCredential=$machineCred;$context.RemoteAdminCredential=$remoteCred
            Assert-Throws {Invoke-WRemotePsExecScript $context 'TESTPC' '1' @{} 10} 'ne prend pas de mot de passe'
            Assert-Test ($script:NativeCalls -eq $before) 'Un processus a ete lance avec un compte explicite.'
        } finally { $context.MachineCredential=$null;$context.RemoteAdminCredential=$null }
    }
    Test-Case 'Depot distant refuse sans consentement explicite' {
        $before=$script:NativeCalls
        $noConsent=$context.PSObject.Copy();$noConsent.AllowRemoteArtifacts=$false
        Assert-Throws {Invoke-WRemotePsExecScript $noConsent 'TESTPC' '1' @{} 10} 'non autoris(e|é) pour ce poste.*Assistance poste > Intervenir'
        $otherTarget=$context.PSObject.Copy();$otherTarget.ArtifactTarget='AUTREPC'
        Assert-Throws {Invoke-WRemotePsExecScript $otherTarget 'TESTPC' '1' @{} 10} 'non autoris(e|é) pour ce poste.*Assistance poste > Intervenir'
        Assert-Test ($script:NativeCalls -eq $before) 'Un processus a ete lance sans consentement pour cette cible.'
    }
    Test-Case 'PsExec: cible invalide ne lance aucun processus' {
        $before=$script:NativeCalls
        Assert-Throws {Invoke-WRemotePsExecScript $context '*' '1' @{} 10} 'invalide'
        Assert-Test ($script:NativeCalls -eq $before)
    }
    Test-Case 'PsExec: licence interpretee sans recopier son texte' {
        $script:NativeMode='License';$script:NativeExitCode=1
        Assert-Throws {Invoke-WRemotePsExecScript $context 'TESTPC' '1' @{} 10} 'renvoye sa licence'
        $detail=Format-WRemoteFailureDetail ('SYSINTERNALS SOFTWARE LICENSE TERMS '+('x'*2000))
        Assert-Test ($detail.Length -lt 350 -and $detail -notmatch 'LICENSE TERMS')
        $script:NativeMode='Success';$script:NativeExitCode=0
    }
    Test-Case 'PsExec: marqueur valide mais code non nul refuse' {
        $script:NativeExitCode=5
        Assert-Throws {Invoke-WRemotePsExecScript $context 'TESTPC' '1' @{} 10} 'non nul'
        $script:NativeExitCode=0
    }
    # ARCHIVE (docs/history/ARCHIVE-SUITES-RC1.11.md): 'schtasks: meme compte poste et tableau arguments conserve'
    # tested schtasks.exe /u /p arguments; Invoke-WSchtasksRemote now uses the Task Scheduler COM API and the old
    # case opened a real Schedule.Service connection. Both replacements stop before any COM object is created.
    Test-Case 'Planificateur: identifiants en argument refuses' {
        $before=$script:NativeCalls
        Assert-Throws {Invoke-WSchtasksRemote $context 'TESTPC' @('/query','/u','x') 5} 'interdit'
        Assert-Throws {Invoke-WSchtasksRemote $context 'TESTPC' @('/query','/p','x') 5} 'interdit'
        Assert-Test ($script:NativeCalls -eq $before)
    }
    Test-Case 'Planificateur: seules les taches propres a l operation' {
        Assert-Throws {Invoke-WSchtasksRemote $context 'TESTPC' @('/create','/tn','\Autre','/xml','absent.xml','/f') 5} 'propres a cette operation'
        Assert-Throws {Invoke-WSchtasksRemote $context 'TESTPC' @('/delete','/tn','\Microsoft\Windows\Defrag\ScheduledDefrag','/f') 5} 'propres a cette operation'
    }
    Test-Case 'ADMIN$: meme credential que PsExec/schtasks' {
        # State formerly left by the archived PsExec case: explicit machine and remote accounts.
        $context.MachineCredential=$machineCred;$context.RemoteAdminCredential=$remoteCred
        [void](New-WAdminShareDrive $context 'TESTPC')
        Assert-Test ($script:ShareCredential.UserName -ceq $machineCred.UserName -and $script:ShareRoot -ceq '\\TESTPC\ADMIN$')
    }
    Test-Case 'ADMIN$: refus explicite sans repli silencieux sur un autre compte' {
        $script:ShareMode='Denied';$before=$script:ShareCalls
        Assert-Throws {New-WAdminShareDrive $context 'TESTPC'} 'acces refuse'
        Assert-Test ($script:ShareCalls -eq ($before+1))
        $script:ShareMode='Record'
    }
    Test-Case 'Contexte LastUser: conserve le compte AD et le compte distant distincts' {
        $script:RemoteAdminCredential=$remoteCred;$script:MachineCredential=$machineCred
        $ctx=Get-WorkerContext -OperationId 'ComputerLastUser'
        Assert-Test ($ctx.UseCredential -and $ctx.Credential.UserName -ceq $adCred.UserName)
        Assert-Test ($ctx.MachineCredential.UserName -ceq $machineCred.UserName)
        Assert-Test ($ctx.RemoteAdminCredential.UserName -ceq $remoteCred.UserName)
    }
    Test-Case 'Contexte: ping ne recoit pas le credential LDAP' {
        $ctx=Get-WorkerContext -OperationId 'ComputerPing'
        Assert-Test (-not $ctx.UseCredential -and $null -eq $ctx.Credential)
    }
    Test-Case 'Contexte LastUser: compte distant possible avec login Windows' {
        $script:Conn.UseCredential=$false;$script:MachineCredential=$null
        $ctx=Get-WorkerContext -OperationId 'ComputerLastUser'
        Assert-Test (-not $ctx.UseCredential -and $null -eq $ctx.Credential)
        Assert-Test ($ctx.MachineCredential.UserName -ceq $remoteCred.UserName)
        $script:Conn.UseCredential=$true
    }
    Test-Case 'Contexte LastUser: canal AD suspendu reste bloque' {
        $script:DirectoryCredentialFaulted=$true
        Assert-Throws {Get-WorkerContext -OperationId 'ComputerLastUser'} 'suspendu'
        $script:DirectoryCredentialFaulted=$false
    }
    Test-Case 'LDAP: resultat vrai compatible avec les anciens appelants' {
        $script:LdapMode='Found'
        Assert-Test ((Test-WUserInAd $context 'alice') -eq $true)
        $r=Test-WUserInAd $context 'alice' -Detailed
        Assert-Test ($r.Verified -and $r.LookupSucceeded -and $r.Error -eq '')
    }
    Test-Case 'LDAP: compte absent distinct d une erreur de lecture' {
        $script:LdapMode='Missing';$r=Test-WUserInAd $context 'alice' -Detailed
        Assert-Test (-not $r.Verified -and $r.LookupSucceeded)
        $script:LdapMode='Error';$r=Test-WUserInAd $context 'alice' -Detailed
        Assert-Test (-not $r.Verified -and -not $r.LookupSucceeded -and $r.Error -match 'LDAP access denied')
    }
    Test-Case 'LDAP: erreur Dispose ne detruit pas un resultat valide' {
        $script:LdapMode='DisposeError'
        Assert-Test ((Test-WUserInAd $context 'alice') -eq $true)
        $script:LdapMode='Found'
    }
    Test-Case 'Resume des tentatives preserve DCOM et WinRM' {
        $r=Get-WProbeAttemptSummary @([pscustomobject]@{Method='CIM';Status='KO';Detail='Dcom : access denied'},[pscustomobject]@{Method='WinRM';Status='KO';Detail='timeout'})
        Assert-Test ($r -match 'Dcom : access denied' -and $r -match 'WinRM.+timeout')
    }
    # Staging reel dans un PSDrive LOCAL. Le nom/racine distante n est qu une fixture.
    # Layout since RC1.9: a private folder Temp\DOMENIA_<id> holding run.ps1, run.json and run.out.json.
    function Invoke-WSchtasksRemote {
        param($Context,[string]$Computer,[string[]]$Arguments,[int]$TimeoutSeconds)
        $script:TaskCalls.Add([string]$Arguments[0])
        if ($Arguments[0] -eq '/run') {
            $folder=@(Get-ChildItem -LiteralPath ($script:ShareDriveName+':\Temp') -Directory -Filter 'DOMENIA_*')[0]
            $script:StagedText=Get-Content -LiteralPath (Join-Path $folder.FullName 'run.ps1') -Raw -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $folder.FullName 'run.out.json') -Value '{"Candidates":[],"TestOnly":true}' -Encoding UTF8
        }
        return [pscustomobject]@{ExitCode=0;Output='TEST ONLY'}
    }
    # The remote Windows directory is read by CIM/DCOM in production: replaced by a fixed answer here.
    function Get-WRemoteWindowsDirectory { param($Context,[string]$Computer) return 'C:\Windows' }
    # Record the private DACL instead of applying it, so the result does not depend on token elevation.
    function Set-Acl { [CmdletBinding()] param([string]$LiteralPath,$AclObject) $script:StagedSddl=$AclObject.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access) }
    Test-Case 'Staging: ecriture lecture et nettoyage par le PSDrive local' {
        $script:ShareMode='Local';$script:TaskCalls=New-Object 'System.Collections.Generic.List[string]';$script:StagedSddl=''
        $r=Invoke-WRemoteScheduledTaskScript $context 'TESTPC' '[pscustomobject]@{TestOnly=$true}' @{} 15
        Assert-Test ($r.TestOnly -and $r.DomeniaTransport -eq 'ScheduledTask')
        Assert-Test ($script:TaskCalls.Contains('/create') -and $script:TaskCalls.Contains('/run') -and $script:TaskCalls.Contains('/delete'))
        Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'share\Temp') -Filter 'DOMENIA_*').Count -eq 0) 'Fichier de staging non nettoye.'
        Assert-Test ($script:StagedText -match 'Move-Item -LiteralPath') 'Publication atomique absente.'
        Assert-Test ($script:StagedSddl -eq 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)') ('DACL privee inattendue : '+$script:StagedSddl)
    }
    # Resolver reel, transports et annuaire remplaces. Les API reseau ne tournent pas.
    $script:ResolverMode='Found';$script:FallbackCalls=0;$script:PortCalls=0
    function New-WDomeniaCimSession { param($Context,$Computer,$Credential,$TimeoutSeconds); return [pscustomobject]@{TestOnly=$true} }
    function Remove-WDomeniaCimSession { param($Session) }
    function Get-CimInstance {
        [CmdletBinding()]
        param($CimSession,$ClassName,$Property,[int]$OperationTimeoutSec)
        Assert-Test ($OperationTimeoutSec -ge 1 -and $OperationTimeoutSec -le 4) 'Delai de requete CIM absent ou hors budget.'
        if($script:ResolverMode -eq 'CimError'){throw 'TEST ONLY DCOM access denied'}
        if($ClassName -eq 'Win32_UserProfile'){return @()}
        if($script:ResolverMode -in @('NoConsole','RegistryDenied')){return [pscustomobject]@{UserName=''}}
        return [pscustomobject]@{UserName='EXAMPLE\alice'}
    }
    $script:RegistryCalls=0
    function Invoke-CimMethod {
        [CmdletBinding()]
        param($CimSession,$Namespace,$ClassName,$MethodName,$Arguments,[int]$OperationTimeoutSec)
        $script:RegistryCalls++
        Assert-Test ($Namespace -eq 'root\default' -and $ClassName -eq 'StdRegProv' -and $MethodName -eq 'GetStringValue')
        Assert-Test ($OperationTimeoutSec -ge 1 -and $OperationTimeoutSec -le 4)
        Assert-Test ($Arguments.hDefKey -eq [uint32]2147483650)
        if($script:ResolverMode -eq 'RegistryDenied'){return [pscustomobject]@{ReturnValue=[uint32]5;sValue=''}}
        return [pscustomobject]@{ReturnValue=[uint32]0;sValue='EXAMPLE\alice'}
    }
    function Test-WTcpPort { param($Computer,$Port,$Timeout);$script:PortCalls++;return $false }
    function Invoke-Command { throw 'TEST ONLY: appel WinRM reel interdit' }
    function Invoke-WRemoteTaskScript {
        param($Context,$Computer,$ScriptText,$InputObject,$TimeoutSeconds,$ClassicError)
        $script:FallbackCalls++;throw ('TEST ONLY fallback : '+$ClassicError)
    }
    $Payload=[pscustomobject]@{Computer='TESTPC';ClassicTimeoutMs=7000;TaskFallbackTimeoutSeconds=18;MethodTimeoutMs=2500;AllowUnboundedFallbacks=$false;UseRemoteRegistry=$false;UseSecurityLog=$false}
    $Context=$context
    Test-Case 'Resolver: candidat CIM confirme, aucun fallback' {
        $script:LdapMode='Found';$script:ResolverMode='Found';$before=$script:FallbackCalls
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test ($r.Success -and $r.VerifiedInAD -and $r.UserLogin -eq 'alice')
        Assert-Test ($script:FallbackCalls -eq $before)
    }
    Test-Case 'Resolver: erreur CIM exposee, WinRM desactive non sonde' {
        $script:ResolverMode='CimError';$before=$script:PortCalls
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test (-not $r.Success -and $r.Details -match 'DCOM access denied')
        Assert-Test ($script:PortCalls -eq $before)
        Assert-Test (@($r.Attempts | Where-Object {$_.Method -eq 'Comptes effectifs'}).Count -eq 1)
    }
    Test-Case 'Resolver: verification LDAP refusee non confondue avec hors AD' {
        $script:ResolverMode='Found';$script:LdapMode='Error'
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test (-not $r.Success)
        Assert-Test (@($r.Attempts | Where-Object {$_.Status -eq 'VALIDATION AD KO'}).Count -ge 1)
        Assert-Test ($r.Details -match 'LDAP access denied')
    }
    Test-Case 'R1.3: session fermee, LogonUI CIM lu et candidat verifie sans secours' {
        $script:LdapMode='Found';$script:ResolverMode='NoConsole';$Payload.UseRemoteRegistry=$true
        $before=$script:FallbackCalls;$registryBefore=$script:RegistryCalls
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test ($r.Success -and $r.UserLogin -eq 'alice' -and $r.Source -eq 'CIM dernier utilisateur LogonUI')
        Assert-Test ($script:FallbackCalls -eq $before -and $script:RegistryCalls -eq ($registryBefore+1))
    }
    Test-Case 'R1.3: interrogation registre desactivee respectee' {
        $Payload.UseRemoteRegistry=$false;$script:ResolverMode='NoConsole';$before=$script:RegistryCalls
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test (-not $r.Success -and $script:RegistryCalls -eq $before)
    }
    Test-Case 'R1.3: refus de lecture LogonUI jamais transforme en resultat' {
        $Payload.UseRemoteRegistry=$true;$script:ResolverMode='RegistryDenied'
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test (-not $r.Success)
        # The fallback is always attempted since RC1.10 and its detail repeats the attempt summary:
        # count only the two LogonUI registry reads that were refused.
        Assert-Test (@($r.Attempts | Where-Object {$_.Method -eq 'CIM dernier utilisateur LogonUI' -and $_.Status -eq 'KO' -and $_.Detail -match 'StdRegProv.+code 5'}).Count -eq 2) ('Tentatives LogonUI refusees : '+@($r.Attempts | Where-Object {$_.Method -eq 'CIM dernier utilisateur LogonUI'}).Count)
    }
    Test-Case 'R1.3: progression disponible avant le callback final' {
        $script:ResolverMode='Found';$script:LdapMode='Found'
        $queue=New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Add-Member -InputObject $Payload -NotePropertyName Progress -NotePropertyValue $queue -Force
        $r=& ([scriptblock]::Create($workerText))
        Assert-Test ($r.Success -and $queue.Count -ge 4)
        $steps=@($queue.ToArray() | Where-Object {$_.Status -eq 'EN COURS'})
        Assert-Test (@($steps | Where-Object {$_.Method -eq 'CIM utilisateur courant'}).Count -eq 1)
    }
}
finally {
    foreach($name in $script:CreatedDriveNames) { Microsoft.PowerShell.Management\Remove-PSDrive -Name $name -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Test-Case 'SE-07 : une lecture ne bascule jamais seule sur PsExec ou une tache planifiee' {
    # Le banc definit ailleurs un bouchon de Invoke-WRemoteTaskScript : les deux fonctions sont
    # re-extraites du code commun reel pour que ce cas teste la garde, pas le bouchon.
    foreach($fonction in @('Assert-DomeniaReadFallbackPermission','Invoke-WRemoteTaskScript')){
        $node=@($commonNodes | Where-Object {$_.Name -eq $fonction})
        Assert-Test ($node.Count -eq 1) ('Fonction commune unique requise : '+$fonction)
        . ([scriptblock]::Create($node[0].Extent.Text))
    }
    $script:Se07Tente=0
    function Invoke-WRemotePsExecScript { param($Context,$Computer,$ScriptText,$InputObject,$TimeoutSeconds=45) $script:Se07Tente++; return [pscustomobject]@{DomeniaTransport='PsExec';Rows=@()} }
    $sansAccord=[pscustomobject]@{AllowReadFallback=$false;ReadFallbackTarget='';ReadFallbackAliases=@();UsePsExecFallback=$true;UseTaskFallback=$true;TaskFallbackTimeoutSeconds=20}
    $refus=''
    try { [void](Invoke-WRemoteTaskScript -Context $sansAccord -Computer 'TESTPC' -ScriptText 'x' -InputObject ([pscustomobject]@{}) -TimeoutSeconds 20) } catch { $refus=[string]$_.Exception.Message }
    Assert-Test ($refus -match 'refus(e|é) pour cette lecture') ('Aucun refus rendu pour une lecture non demandee : '+$refus)
    Assert-Test ($refus.Contains('Assistance poste > Intervenir')) ('Le refus ne dit pas ou autoriser la lecture : '+$refus)
    Assert-Test ($script:Se07Tente -eq 0) 'Un transport a ete lance malgre le refus.'
    $avecAccord=[pscustomobject]@{AllowReadFallback=$true;ReadFallbackTarget='TESTPC';ReadFallbackAliases=@();UsePsExecFallback=$true;UseTaskFallback=$true;TaskFallbackTimeoutSeconds=20}
    $lu=Invoke-WRemoteTaskScript -Context $avecAccord -Computer 'TESTPC' -ScriptText 'x' -InputObject ([pscustomobject]@{}) -TimeoutSeconds 20
    Assert-Test ([string]$lu.DomeniaTransport -eq 'PsExec') ('La lecture demandee n a pas ete servie par le repli.')
    $autrePoste=''
    try { [void](Invoke-WRemoteTaskScript -Context $avecAccord -Computer 'AUTREPC' -ScriptText 'x' -InputObject ([pscustomobject]@{}) -TimeoutSeconds 20) } catch { $autrePoste=[string]$_.Exception.Message }
    Assert-Test ($autrePoste -match 'AUTREPC') ('L accord de lecture couvre un poste nomme, pas n importe lequel : '+$autrePoste)
    $ecriture=[pscustomobject]@{AllowReadFallback=$false;ReadFallbackTarget='';ReadFallbackAliases=@();UsePsExecFallback=$true;UseTaskFallback=$true;TaskFallbackTimeoutSeconds=20}
    $fait=Invoke-WRemoteTaskScript -Context $ecriture -Computer 'TESTPC' -ScriptText 'x' -InputObject ([pscustomobject]@{}) -TimeoutSeconds 20 -Purpose 'Write'
    Assert-Test ([string]$fait.DomeniaTransport -eq 'PsExec') 'Une ecriture a perdu son repli.'
}
$failed=@($script:Results | Where-Object {$_.Status -ne 'PASS'}).Count
$report=[ordered]@{Build='2026.09.21-R1.3-LASTUSER';Mode='NativePowerShellWithMocksAndLocalFiles';PowerShell=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;RunAt=(Get-Date).ToString('o');NoRemoteAccess=$true;Passed=($script:Results.Count-$failed);Failed=$failed;Tests=$script:Results.ToArray()}
$fullReport=[IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullReport))
[IO.File]::WriteAllText($fullReport,($report | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ('Tests distants isoles : '+$report.Passed+' reussis, '+$failed+' echecs. Rapport : '+$fullReport)
if ($failed -gt 0) { throw 'Correctif non valide par les tests PowerShell isoles. Aucune validation AD reelle revendiquee.' }
