#requires -Version 5.1
<# R1.2: tests isoles des fonctions REELLES extraites par l AST PowerShell.
   Aucun lancement d DOMENIA, aucune connexion AD/SMB, aucun PsExec/schtasks reel.
   Les executables factices sont vides ; le lanceur de processus est remplace
   par un mock avant tout appel. Tous les fichiers vivent dans TEMP.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
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
    'Get-WRemoteComputerName','ConvertTo-WProcessQuotedArg','Get-WPsExecPath','Invoke-WRemotePsExecScript',
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
    param([string]$Name,[scriptblock]$Action)
    try { & $Action | Out-Null; $status='PASS'; $detail='' }
    catch { $status='FAIL'; $detail=$_.Exception.Message }
    $script:Results.Add([pscustomobject]@{Name=$Name;Status=$status;Detail=$detail})
    if (-not $Quiet -or $status -eq 'FAIL') { Write-Host ("$status | $Name | $detail") }
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
    foreach ($name in @('TESTPC','pc-01.example.test','192.0.2.10')) {
        Test-Case ('Cible unique valide : '+$name) { Assert-Test ((Get-WRemoteComputerName $name) -ceq $name) }
    }
    foreach ($name in @('','*','PC1,PC2','PC1 -s','\\PC1','-accepteula','PC1;cmd')) {
        Test-Case ('Cible invalide rejetee : '+$name) { Assert-Throws {Get-WRemoteComputerName $name} 'invalide' }
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
    Test-Case 'PsExec: compte poste explicite prioritaire, mot de passe preserve' {
        $context.MachineCredential=$machineCred;$context.RemoteAdminCredential=$remoteCred
        [void](Invoke-WRemotePsExecScript $context 'TESTPC' '1' @{} 10)
        $u=[array]::IndexOf($script:SentArguments,'-u');$p=[array]::IndexOf($script:SentArguments,'-p')
        Assert-Test ($u -ge 0 -and $script:SentArguments[$u+1] -ceq $machineCred.UserName)
        Assert-Test ($p -ge 0 -and $script:SentArguments[$p+1] -ceq $machineCred.GetNetworkCredential().Password)
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
    Test-Case 'schtasks: meme compte poste et tableau arguments conserve' {
        [void](Invoke-WSchtasksRemote $context 'TESTPC' @('/query','/fo','LIST') 5)
        Assert-Test ($script:SentArguments[0] -ceq '/s' -and $script:SentArguments[1] -ceq 'TESTPC')
        $u=[array]::IndexOf($script:SentArguments,'/u')
        Assert-Test ($script:SentArguments[$u+1] -ceq $machineCred.UserName)
        Assert-Test ($script:SentArguments[-3] -eq '/query' -and $script:SentArguments[-1] -eq 'LIST')
    }
    Test-Case 'ADMIN$: meme credential que PsExec/schtasks' {
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
    function Invoke-WSchtasksRemote {
        param($Context,[string]$Computer,[string[]]$Arguments,[int]$TimeoutSeconds)
        $script:TaskCalls.Add([string]$Arguments[0])
        if ($Arguments[0] -eq '/run') {
            $scriptFile=@(Get-ChildItem -LiteralPath ($script:ShareDriveName+':\Temp') -Filter 'DOMENIA_*.ps1')[0]
            $script:StagedText=Get-Content -LiteralPath $scriptFile.FullName -Raw -Encoding UTF8
            $resultPath=$script:ShareDriveName+':\Temp\'+$scriptFile.BaseName+'.out.json'
            Set-Content -LiteralPath $resultPath -Value '{"Candidates":[],"TestOnly":true}' -Encoding UTF8
        }
        return [pscustomobject]@{ExitCode=0;Output='TEST ONLY'}
    }
    Test-Case 'Staging: ecriture lecture et nettoyage par le PSDrive local' {
        $script:ShareMode='Local';$script:TaskCalls=New-Object 'System.Collections.Generic.List[string]'
        $r=Invoke-WRemoteScheduledTaskScript $context 'TESTPC' '[pscustomobject]@{TestOnly=$true}' @{} 15
        Assert-Test ($r.TestOnly -and $r.DomeniaTransport -eq 'ScheduledTask')
        Assert-Test ($script:TaskCalls.Contains('/create') -and $script:TaskCalls.Contains('/run') -and $script:TaskCalls.Contains('/delete'))
        Assert-Test (@(Get-ChildItem -LiteralPath (Join-Path $testRoot 'share\Temp') -Filter 'DOMENIA_*').Count -eq 0) 'Fichier de staging non nettoye.'
        Assert-Test ($script:StagedText -match 'Move-Item -LiteralPath') 'Publication atomique absente.'
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
        Assert-Test (@($r.Attempts | Where-Object {$_.Detail -match 'StdRegProv.+code 5'}).Count -eq 2)
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
$failed=@($script:Results | Where-Object {$_.Status -ne 'PASS'}).Count
$report=[ordered]@{Build='2026.09.21-R1.3-LASTUSER';Mode='NativePowerShellWithMocksAndLocalFiles';PowerShell=$PSVersionTable.PSVersion.ToString();Edition=$PSVersionTable.PSEdition;RunAt=(Get-Date).ToString('o');NoRemoteAccess=$true;Passed=($script:Results.Count-$failed);Failed=$failed;Tests=$script:Results.ToArray()}
$fullReport=[IO.Path]::GetFullPath($ReportPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullReport))
[IO.File]::WriteAllText($fullReport,($report | ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
Write-Host ('Tests distants isoles : '+$report.Passed+' reussis, '+$failed+' echecs. Rapport : '+$fullReport)
if ($failed -gt 0) { throw 'Correctif non valide par les tests PowerShell isoles. Aucune validation AD reelle revendiquee.' }
