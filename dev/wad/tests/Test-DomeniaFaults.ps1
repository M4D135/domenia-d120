#requires -Version 5.1
<# D007 : injection des vraies classes de panne dans le code livre.
   DNS lent, refus AD, dechiffrement LAPS refuse, disque plein, SQLite verrouille, coupure apres envoi.
   Critere : chaque panne conserve sa categorie et n'aboutit ni a une reussite ni a une suppression inventee.
   Les pannes sont injectees a la frontiere (reseau, annuaire, disque, base) par des doublures ; le code qui les
   traite est le vrai : corps de worker epingles (empreinte verifiee), code commun des workers, enveloppe
   d'ecriture de New-DomeniaWorkerRunspace, gestionnaires d'interface du coeur et modules du plan ferme.
   Aucune connexion AD, aucun acces distant, aucune ecriture hors du dossier temporaire du test.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
# P-CD-09: the catch blocks of the core and of the UI modules trace an ignored error with Write-DomeniaSwallowed, defined
# in the script scope of Domenia-Core.ps1. Functions loaded one by one stay silent here, as before the sweep (no-op double;
# the trace itself is tested in rules/Common.Tests.ps1 and Test-DomeniaFaults.ps1).
function Write-DomeniaSwallowed { param($Category,$Operation,$ErrorRecord,$Now) }
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-faults-'+[guid]::NewGuid().ToString('N'))
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
function Get-FunctionAst {param($Ast,[string]$Name)
    $nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0]
}
function Get-SingleQuotedLiterals {param($Ast)
    return @($Ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString},$true)|Sort-Object {$_.Extent.StartOffset})
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
    # L07: the write handlers record the issue of the request (Set-DomeniaWriteTaskOutcome) and evaluate the compensation.
    foreach($name in @('Get-WorkerContext','Fail-DomeniaWriteTaskUi','Complete-DomeniaWriteTaskUi','Set-DomeniaWriteTaskOutcome','Get-DomeniaWriteCompensationText','ConvertTo-DomeniaErrorInfo','Assert-DomeniaCapability','Assert-WriteAllowed',
        'Set-DomeniaActualCapabilityDenied','Test-DomeniaActualCapabilityDenied','Get-DomeniaCapabilityDenialKey',
        'Complete-DomeniaSecretLoadUi','Test-DomeniaSecretCallbackCurrent','Clear-DomeniaSecretResultValues','Update-SecretsGrid','Get-DomeniaEffectiveWorkerResult',
        'Get-DomeniaControl','Set-DomeniaControlText','Write-DomeniaAtomicText',
        'Initialize-DomeniaWinSqliteNative','New-DomeniaUtf8Ptr','ConvertFrom-DomeniaUtf8Ptr','Open-DomeniaDatabase','Close-DomeniaDatabase','Invoke-DomeniaDbExec','Invoke-DomeniaDbQuery','ConvertTo-DomeniaSqlLiteral',
        'Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode')){
        . ([scriptblock]::Create((Get-FunctionAst $script:CoreAst $name).Extent.Text))
    }
    # L02: incident code, error signature, dispatcher handler, engine fault and fatal report of the shipped core.
    foreach($name in @('Protect-DomeniaLogText','New-DomeniaIncidentCode','Get-DomeniaErrorSignature','Register-DomeniaErrorOccurrence','Invoke-DomeniaDispatcherFault',
        'Register-DomeniaAsyncEngineFault','Get-DomeniaFatalMessage','Test-DomeniaMainHostAvailable','Assert-DomeniaWorkerRegistry','Get-DomeniaWorkerEngineSelfTestCode','Initialize-AsyncEngine',
        'Test-DomeniaOperatorMessage','Test-DomeniaInternalFault','Register-DomeniaSessionShownHook')){
        . ([scriptblock]::Create((Get-FunctionAst $script:CoreAst $name).Extent.Text))
    }
    $assignment=@($script:CoreAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:WorkerCommon' -and $n.Operator -eq [Management.Automation.Language.TokenKind]::Equals},$true))
    if($assignment.Count -ne 1){throw 'Code commun des workers introuvable.'}
    $literal=$assignment[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    $ct=$null;$ce=$null;$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$literal.Value,[ref]$ct,[ref]$ce)
    if(@($ce).Count){throw 'Code commun des workers non analysable.'}
    foreach($name in @('Get-WPropFirst','Get-WAllProperties','Convert-WDirectoryValue','Convert-WGuid','Convert-WSid','Convert-WLargeInteger','Convert-WFileTime','Get-WAdCredential','Get-WDirectoryBindUser')){
        . ([scriptblock]::Create((Get-FunctionAst $commonAst $name).Extent.Text))
    }
    . (Join-Path $PSScriptRoot 'fixtures\Domenia-AdFixtures.ps1')
    # Pinned bodies located through the reviewed DEV contract, never by position guess.
    $contractsJson=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    $script:Contracts=@($contractsJson)
    function Get-PinnedBody {param([string]$Operation)
        # Same literal indexing as tools/update_worker_contracts.py: every here-string of the function, in order.
        $c=@($script:Contracts|Where-Object{$_.Operation -eq $Operation})
        if($c.Count -ne 1){throw ('Contrat absent : '+$Operation)}
        $fileAst=Read-SourceAst (Join-Path $root ([string]$c[0].File))
        $fn=Get-FunctionAst $fileAst ([string]$c[0].Function)
        $here=@($fn.FindAll({param($n)($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Extent.Text.StartsWith('@')},$true)|Sort-Object {$_.Extent.StartOffset})
        $raw=$here[[int]$c[0].LiteralIndex].Extent.Text -replace "`r`n","`n"
        $body=$raw.Substring(3,$raw.Length-6)
        [void](Assert-DomeniaWorkerOperationCode -OperationId $Operation -Code $body)
        return $body
    }
    # Write envelope of New-DomeniaWorkerRunspace: the three fixed literals, identified by their content.
    $runspaceLiterals=@(Get-SingleQuotedLiterals (Get-FunctionAst $script:CoreAst 'New-DomeniaWorkerRunspace')|ForEach-Object{[string]$_.Value})
    $script:EnvelopeStart=@($runspaceLiterals|Where-Object{$_.StartsWith('$DomeniaWriteDispatched=$false')})
    $script:EnvelopeEnd=@($runspaceLiterals|Where-Object{$_.Contains('ETAT INCONNU apres envoi')})
    $script:EnvelopeMarker=@($runspaceLiterals|Where-Object{$_.TrimStart().StartsWith('catch {') -and $_.Contains('[DOMENIA:')})
    if($script:EnvelopeStart.Count -ne 1 -or $script:EnvelopeEnd.Count -ne 1 -or $script:EnvelopeMarker.Count -ne 1){throw 'Enveloppe d ecriture de New-DomeniaWorkerRunspace introuvable.'}
}
catch {
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : Windows PowerShell 5.1, plan ferme et extraction AST';Status='Failed';Detail=$_.Exception.ToString()})
}

# UI boundaries: recorded, never shown; no AD, no network.
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level) $script:StatusLog.Add([string]$Text)}
function Get-CfgValue {param($Section,$Name,$Default);return $Default}
function Apply-CurrentPermissionUi {}
function Show-InfoBox {param($Message,$Details) $script:Dialogs.Add('INFO '+[string]$Message)}
function Show-ErrorBox {param($Message) $script:Dialogs.Add('ERREUR '+[string]$Message)}
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,$CorrelationId,[switch]$NoPopup) $script:Dialogs.Add('OPERATION '+[string]$ErrorRecordOrException)}
function Set-DomeniaItemsSource {param($Name,$Rows) $script:BoundSecrets=@($Rows);return $true}
function Update-DomeniaSecretActionUi {}
function Request-DomeniaDashboardRefresh {param([switch]$Immediate)}
function Invoke-DomeniaWritePostAction {param($Result,$State)}
function Initialize-DomeniaWorkerContextCache {}
function Start-UiTask {$script:Dispatched++;throw 'Aucune operation ne doit etre relancee par ce test.'}
function New-FixtureWindowStub {
    $w=[pscustomobject]@{IsActive=$false}
    Add-Member -InputObject $w -MemberType ScriptMethod -Name Add_Closed -Value {param($Handler)}
    return $w
}
function Reset-FaultFixture {
    $script:StatusLog=[Collections.Generic.List[string]]::new();$script:Dialogs=[Collections.Generic.List[string]]::new();$script:Dispatched=0
    $script:SessionEpoch=1L;$script:SelectedObjectGeneration=1L;$script:ActiveWriteTaskId='';$script:WriteState='Idle';$script:UnknownWriteTargetDn=''
    $script:ReceiptReady=$true;$script:ReceiptPending=0;$script:ReadOnlyMode=$false;$script:CurrentCapabilities=@{};$script:ActualDeniedCapabilities=@{}
    $script:DirectoryCredentialFaulted=$false;$script:DirectoryCredentialFaultMessage='';$script:SecretsCredential=$null;$script:MachineCredential=$null;$script:RemoteAdminCredential=$null
    $script:Conn=[pscustomobject]@{Server='dc1.example.invalid';BaseDn='DC=example,DC=invalid';Domain='example.invalid';Netbios='EXAMPLE';BindUser='EXAMPLE\lecteur';Credential=$null;UseCredential=$false;AuthMode='Windows'}
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC-DEMO-01,OU=Postes,DC=example,DC=invalid';Safety=[pscustomobject]@{Guid=''}}
    $script:SecretRows=@();$script:SecretsVisible=$false;$script:ActiveSecretRequestId='';$script:BoundSecrets=@();$script:ArtifactConsent=$null
    $script:WorkerContextStatic=[pscustomobject]@{AdModuleSources=@();AdRequiredCommands=@();AdTypeNames=@();AdManagementHash='';AdResourceHash='';MissingCriticalFunctions=@();MissingCriticalControls=@();CriticalFunctionCount=0;CriticalControlCount=0;PowerShellVersion='test';IsSta=$true}
    $script:Ctrl=@{LblSecretsStatus=[pscustomobject]@{Text=''}}
    $script:Live=$null;$script:AsyncEngineClosing=$false;$script:AccessCurrentJob=$null
    if($null -ne $script:AccessState -and $null -ne $script:AccessState.PSObject.Properties['Timer'] -and $null -ne $script:AccessState.Timer){$script:AccessState.Timer.Stop()}
    $script:Window=New-FixtureWindowStub;$script:AccessState=$null
    Initialize-DomeniaAccess
    if($null -ne $script:AccessState.PSObject.Properties['Timer'] -and $null -ne $script:AccessState.Timer){$script:AccessState.Timer.Stop()}
}
function Invoke-LiveProbeFault {
    # Real pinned LiveConsole body; network, DNS and CIM are the injected boundaries.
    param([string]$Fault,[int]$DelayMs=0,[string]$User='EXAMPLE\alex.demo')
    $Context=[pscustomobject]@{MachineCredential=$null;Credential=$null;Domain='example.invalid';Netbios='EXAMPLE';BaseDn='DC=example,DC=invalid';UseCim=$true}
    $Payload=[pscustomobject]@{Computer='pc-demo-01.example.invalid';Key='cn=pc-demo-01,ou=postes,dc=example,dc=invalid';Guid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3';MethodSeconds=4}
    $script:ProbeCalls=@{Ping=0;Sessions=0;Reads=0;Ldap=0}
    function Get-WMachineCredential {param($Context) return $Context.MachineCredential}
    function New-Object {
        param($TypeName)
        if($TypeName -ne 'Net.NetworkInformation.Ping'){throw ('Construction inattendue : '+$TypeName)}
        $o=[pscustomobject]@{}
        Add-Member -InputObject $o ScriptMethod Send {
            param($target,$ms)
            $script:ProbeCalls.Ping++
            if($script:FaultDelayMs -gt 0){Start-Sleep -Milliseconds $script:FaultDelayMs}
            if($script:FaultKind -eq 'DnsTimeout'){throw [Net.NetworkInformation.PingException]::new('Une exception s est produite pendant une demande PING.',[Net.Sockets.SocketException]::new(11002))}
            return [pscustomobject]@{Status='Success';RoundtripTime=$script:FaultDelayMs}
        }
        Add-Member -InputObject $o ScriptMethod Dispose { }
        return $o
    }
    function New-CimSessionOption {param($Protocol,$ErrorAction) return [pscustomobject]@{Protocol=$Protocol}}
    function New-CimSession {
        param($ComputerName,$SessionOption,$OperationTimeoutSec,$Credential,$ErrorAction)
        $script:ProbeCalls.Sessions++
        if($script:FaultDelayMs -gt 0){Start-Sleep -Milliseconds $script:FaultDelayMs}
        switch($script:FaultKind){
            'DnsTimeout' {throw [TimeoutException]::new('The operation timed out while resolving the host name (simulation DNS lent).')}
            'AccessDenied' {throw [UnauthorizedAccessException]::new('Acces refuse (simulation).')}
            'LogonFailure' {throw [Runtime.InteropServices.COMException]::new('Nom d utilisateur ou mot de passe incorrect (simulation).',-2147023570)}
        }
        return [pscustomobject]@{Fake=$true}
    }
    function Get-CimInstance {param($CimSession,$ClassName,$Property,$OperationTimeoutSec,$ErrorAction) $script:ProbeCalls.Reads++;return [pscustomobject]@{UserName=$script:FaultUser}}
    function Remove-CimSession {param($CimSession,$ErrorAction)}
    function New-WSearcher {param($Ctx,$BaseDn,$Filter,$Properties,$Scope,$Limit) $script:ProbeCalls.Ldap++;throw 'Aucune lecture annuaire dans ce test.'}
    $script:FaultKind=$Fault;$script:FaultDelayMs=$DelayMs;$script:FaultUser=$User
    & ([scriptblock]::Create((Get-PinnedBody 'LiveConsole')))
}
function New-WriteEnvelopeScript {
    # Same composition as New-DomeniaWorkerRunspace -IsWrite: receipt envelope, business body, marker catch.
    param([string]$Business,[string]$ExtraDefinitions='')
    $body=$Business.Replace('$DomeniaWriteDispatched=$true',"Set-WReceiptStage 'Sent';`$DomeniaWriteDispatched=`$true")
    $composed=$script:EnvelopeStart[0]+"`r`n"+$body+"`r`n"+$script:EnvelopeEnd[0]
    $errorContract="function Get-DomeniaStructuredError {`r`n"+(Get-Command Get-DomeniaStructuredError -CommandType Function).Definition+"`r`n}"
    $text="param(`$Context,`$Payload)`r`n`$ErrorActionPreference='Stop'`r`n"+$errorContract+"`r`n"+(Get-DomeniaReceiptsCommon)+"`r`n"+$ExtraDefinitions+"`r`n"+"try {`r`n"+$composed+"`r`n}"+$script:EnvelopeMarker[0]
    return [scriptblock]::Create($text)
}
function New-WriteContext {param([string]$ReceiptRoot)
    return [pscustomobject]@{ReceiptRoot=$ReceiptRoot;BaseDn='DC=example,DC=invalid';Server='dc1.example.invalid';OperationId='WriteRename';UseCredential=$false;BindUser='';ProcessIdentity='EXAMPLE\technicien'}
}
function Get-ReceiptRecords {param([string]$ReceiptRoot)
    if(-not [IO.Directory]::Exists($ReceiptRoot)){return @()}
    return @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*.json' -File|ForEach-Object{[IO.File]::ReadAllText($_.FullName)|ConvertFrom-Json})
}
function Test-CredentialOffered {param($ErrorValue) return [bool](Get-DomeniaStructuredError $ErrorValue).CanOfferCredential}

if($infrastructure){
try {
    $known=[pscustomobject]@{Key='cn=pc-demo-01,ou=postes,dc=example,dc=invalid';Computer='pc-demo-01.example.invalid';Guid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3';Outcome='Observed';CurrentUser='EXAMPLE\alex.demo';LastUser='EXAMPLE\alex.demo';ObservedUtc='2026-09-30T07:45:12.0000000Z';CheckedUtc='2026-09-30T07:45:12.0000000Z';LastSource='CIM/DCOM';Source='CIM/DCOM';Detail='';Presence='En ligne';PresenceCheckedUtc='2026-09-30T07:45:12.0000000Z';PresenceDetail='';LinkUser='alex.demo';UserDn='';UserGuid='';DirectoryAuthRejected=$false}

    # ------------------------------------------------------------ DNS lent
    Test-Case 'DNS lent puis delai depasse : categorie Delai conservee, aucun compte invente' {
        Reset-FaultFixture
        $r=Invoke-LiveProbeFault -Fault 'DnsTimeout' -DelayMs 250
        Assert-True ($r.Outcome -eq 'Timeout') ('Categorie perdue : '+$r.Outcome)
        Assert-True (-not $r.User -and -not $r.LinkUser -and $script:ProbeCalls.Reads -eq 0 -and $script:ProbeCalls.Ldap -eq 0) 'Compte invente ou lecture poursuivie.'
        Assert-True ($r.Presence -eq 'Erreur de ping' -and $r.PresenceDetail -match 'DNS') ('Presence : '+$r.Presence+' / '+$r.PresenceDetail)
        $o=ConvertTo-DomeniaLiveObservation $r $known '2026-10-02T09:00:00.0000000Z'
        Assert-True ($o.Outcome -eq 'Timeout' -and -not $o.CurrentUser) 'L observation annonce un compte present.'
        Assert-True ($o.LastUser -eq $known.LastUser -and $o.ObservedUtc -eq $known.ObservedUtc) 'Derniere observation effacee ou rajeunie.'
        Assert-True ((Get-DomeniaLiveObservationView $o).State -eq 'Délai dépassé') 'Etat affiche incorrect.'
    }
    Test-Case 'DNS lent avec reponse : observation reelle, pas de panne inventee' {
        Reset-FaultFixture
        $r=Invoke-LiveProbeFault -Fault '' -DelayMs 250
        Assert-True ($r.Outcome -eq 'Observed' -and $r.User -eq 'EXAMPLE\alex.demo' -and $r.Presence -eq 'En ligne') ('Lecture lente classee en panne : '+$r.Outcome)
    }
    Test-Case 'Delai depasse : jamais propose comme mauvais compte' {
        Reset-FaultFixture
        $timeout=[TimeoutException]::new('The operation timed out while resolving the host name (simulation DNS lent).')
        $d=Get-DomeniaStructuredError $timeout
        Assert-True ($d.Kind -eq 'Unavailable' -and $d.Retryable -and -not $d.CanOfferCredential) ('Classement : '+$d.Kind)
        Assert-True (-not (Request-DomeniaAccessRecovery -Operation 'Lecture console' -OperationId 'LiveConsole' -ErrorValue $timeout.Message)) 'Un autre compte est propose pour un delai.'
        Assert-True ($script:AccessState.Pending.Count -eq 0) 'Avis de droits cree pour un delai.'
    }

    # ------------------------------------------------------------ Refus AD
    Test-Case 'Refus d acces (0x80070005) a la lecture console : categorie Refus conservee' {
        Reset-FaultFixture
        $r=Invoke-LiveProbeFault -Fault 'AccessDenied'
        Assert-True ($r.Outcome -eq 'Denied' -and -not $r.User) ('Categorie perdue : '+$r.Outcome)
        $o=ConvertTo-DomeniaLiveObservation $r $known '2026-10-02T09:00:00.0000000Z'
        Assert-True ($o.Outcome -eq 'Denied' -and $o.LastUser -eq $known.LastUser -and $o.ObservedUtc -eq $known.ObservedUtc) 'Refus transforme en absence ou derniere observation perdue.'
        Assert-True ((Get-DomeniaStructuredError ([UnauthorizedAccessException]::new('Acces refuse (simulation).'))).Kind -eq 'AccessDenied') 'Refus mal classe.'
    }
    Test-Case 'Identifiants rejetes (0x8007052E) : categorie conservee et canal AD suspendu' {
        Reset-FaultFixture
        $r=Invoke-LiveProbeFault -Fault 'LogonFailure'
        Assert-True ($r.Outcome -eq 'AuthRejected' -and -not $r.User) ('Categorie perdue : '+$r.Outcome)
        $d=Get-DomeniaStructuredError ([Runtime.InteropServices.COMException]::new('Nom d utilisateur ou mot de passe incorrect (simulation).',-2147023570))
        Assert-True ($d.Kind -eq 'LogonFailure' -and $d.Code -eq '0x8007052E') ('Classement : '+$d.Kind+' '+$d.Code)
        $script:DirectoryCredentialFaulted=$true;$script:DirectoryCredentialFaultMessage='Identifiants AD refuses (simulation).'
        $blocked='';try{[void](Get-WorkerContext -OperationId 'OpenAdObject')}catch{$blocked=$_.Exception.Message}
        Assert-True ($blocked -match 'Canal Active Directory suspendu') ('Nouvelle lecture AD autorisee apres un rejet : '+$blocked)
    }
    Test-Case 'Ecriture refusee par AD : echec certain, capacite verrouillee, aucune reussite' {
        Reset-FaultFixture
        $state=[pscustomobject]@{Name='Renommer';Correlation='f00d';Capability='Edit';TargetDn=$script:SelectedObject.DN}
        $script:ActiveWriteTaskId='w1';$script:WriteState='Running'
        Fail-DomeniaWriteTaskUi '[DOMENIA:AccessDenied;5;0x80070005] Acces refuse : droits insuffisants sur l objet (simulation).' $state
        Assert-True ($script:WriteState -eq 'Idle' -and -not $script:ActiveWriteTaskId) ('Etat apres refus : '+$script:WriteState)
        Assert-True ($script:CurrentCapabilities['Edit'] -eq 'Refuse' -and (Test-DomeniaActualCapabilityDenied -Dn $state.TargetDn -Capability 'Edit')) 'Refus non memorise pour la cible.'
        Assert-True (@($script:Dialogs|Where-Object{$_ -like 'ERREUR*'}).Count -eq 1 -and @($script:StatusLog|Where-Object{$_ -match '(?i)verifi|reussi|succes'}).Count -eq 0) 'Message de reussite ou absence d erreur.'
    }

    # ------------------------------------------------------------ Dechiffrement LAPS refuse
    Test-Case 'Dechiffrement LAPS refuse : refus conserve, aucune valeur ni reussite affichee' {
        Reset-FaultFixture
        $body=Get-PinnedBody 'ReadLaps'
        $script:LapsCalls=0
        function New-WEntry {param($Context,[string]$Dn) return (New-DomeniaFixtureDirectoryEntry @{name=(New-DomeniaFixtureSingleValue 'PC-DEMO-01')})}
        function Get-LapsADPassword {
            [CmdletBinding()]
            param($Identity,[switch]$AsPlainText,$DomainController,$Credential,$DecryptionCredential)
            $script:LapsCalls++
            return [pscustomobject]@{Account='Administrateur';Password=$null;DecryptionStatus='Unauthorized';ExpirationTimestamp='2026-10-30T00:00:00Z';AuthorizedDecryptor='EXAMPLE\Admins LAPS'}
        }
        $Context=[pscustomobject]@{Server='dc1.example.invalid';BaseDn='DC=example,DC=invalid';BindUser='EXAMPLE\lecteur';Credential=$null;UseCredential=$false}
        $Payload=[pscustomobject]@{DN=$script:SelectedObject.DN;Name='PC-DEMO-01'}
        $result=& ([scriptblock]::Create($body))
        Assert-True ($script:LapsCalls -eq 1) 'Un seul appel Windows LAPS attendu, sans variante automatique.'
        Assert-True (-not [bool]$result.Success -and @($result.Rows).Count -eq 0) 'Reussite ou valeur inventee par le worker.'
        Assert-True ([string]$result.ErrorKind -in @('AccessDenied','DecryptionDenied')) ('Categorie perdue : '+[string]$result.ErrorKind)
        # Same result through the real UI completion.
        $script:ActiveSecretRequestId='req-laps'
        $state=[pscustomobject]@{RequestId='req-laps';DN=$script:SelectedObject.DN;ObjectGuid='';Generation=1L;Mode='LAPS';RetryAttempt=1}
        Complete-DomeniaSecretLoadUi $result $state
        Assert-True (@($script:SecretRows).Count -eq 0 -and @($script:BoundSecrets|Where-Object{$_.HasValue}).Count -eq 0) 'Valeur secrete affichee apres un refus.'
        Assert-True (-not ($script:Ctrl.LblSecretsStatus.Text -match '(?i)charg[ée]e|lisible\(s\)')) ('Reussite annoncee : '+$script:Ctrl.LblSecretsStatus.Text)
        Assert-True (-not $script:AccessState.Faults.ContainsKey('ReadLaps')) 'Refus de dechiffrement classe comme mauvais identifiants.'
        Assert-True (@($script:AccessState.Pending.Values|Where-Object{$_.Kind -eq 'LogonFailure'}).Count -eq 0) 'Avis de mot de passe pour un refus de droits.'
        Assert-True (-not (Test-DomeniaSecretDenied 'BitLocker' $script:SelectedObject.DN)) 'BitLocker marque refuse a tort.'
    }

    # ------------------------------------------------------------ Disque plein
    Test-Case 'Disque plein au recu : aucune ecriture AD envoyee, code 0x80070070 conserve' {
        Reset-FaultFixture
        $receipts=Join-Path $temp 'receipts-full'
        $script:BusinessStarted=$false
        $diskFull='function Write-WReceipt { param($Record,[string]$Root) throw [IO.IOException]::new(''Espace insuffisant sur le disque.'',-2147024784) }'
        $worker=New-WriteEnvelopeScript -Business "`$script:BusinessStarted=`$true`r`n`$DomeniaWriteDispatched=`$true`r`n[pscustomobject]@{Verified=`$true}" -ExtraDefinitions $diskFull
        $failure='';try{[void](& $worker (New-WriteContext $receipts) ([pscustomobject]@{DN=$script:SelectedObject.DN;CorrelationId=[guid]::NewGuid().ToString('N')}))}catch{$failure=$_.Exception.Message}
        Assert-True (-not $script:BusinessStarted) 'L ecriture AD est partie sans recu durable.'
        Assert-True ($failure -match '0x80070070' -and $failure -notmatch 'ETAT INCONNU') ('Categorie du disque plein perdue : '+$failure)
        Assert-True (-not (Test-CredentialOffered $failure)) 'Un disque plein propose un autre compte.'
        Assert-True (@(Get-ReceiptRecords $receipts|Where-Object{$_.Stage -in @('Sent','Verified')}).Count -eq 0) 'Recu d envoi invente.'
    }
    Test-Case 'Fichier local protege : version precedente conservee, aucun temporaire restant' {
        $folder=Join-Path $temp 'prefs';[void][IO.Directory]::CreateDirectory($folder)
        $path=Join-Path $folder 'Domenia.settings.json'
        [IO.File]::WriteAllText($path,'{"etat":"precedent"}')
        [IO.File]::SetAttributes($path,[IO.FileAttributes]::ReadOnly)
        try {
            $failure='';try{Write-DomeniaAtomicText $path '{"etat":"nouveau"}' -KeepBackup}catch{$failure=$_.Exception.Message}
            Assert-True ($failure.Length -gt 0) 'Ecriture refusee annoncee reussie.'
            Assert-True ([IO.File]::ReadAllText($path) -ceq '{"etat":"precedent"}') 'Version precedente perdue.'
            Assert-True (@(Get-ChildItem -LiteralPath $folder -Filter '.domenia-*.tmp' -Force).Count -eq 0) 'Fichier temporaire abandonne.'
        } finally { [IO.File]::SetAttributes($path,[IO.FileAttributes]::Normal) }
    }

    # ------------------------------------------------------------ SQLite verrouille
    Test-Case 'SQLite verrouille : echec visible, aucune ligne perdue, reessai volontaire possible' {
        $dbPath=Join-Path $temp 'live-cache.db'
        $scope=Get-DomeniaLiveHash 'fault-scope';$cacheCode=Get-PinnedBody 'LiveCache'
        # Recent timestamps: the cache retention (30 days) must not be what removes a row in this test.
        $firstUtc=[datetime]::UtcNow.AddHours(-1).ToString('o')
        $first=[pscustomobject]@{QueryKey=(Get-DomeniaLiveHash 'q1');ObservedUtc=$firstUtc;Rows=@([pscustomobject]@{DN='CN=A,DC=example,DC=invalid';Name='A'})}
        $Payload=[pscustomobject]@{Mode='Write';Path=$dbPath;Scope=$scope;Observations=@();Query=$first}
        # As Initialize-DomeniaLive does before any cache worker: the pinned body only resolves the native type.
        [void](Initialize-DomeniaWinSqliteNative)
        [void](& ([scriptblock]::Create($cacheCode)))
        $holder=Open-DomeniaDatabase -Path $dbPath
        $failure=''
        try {
            [void](Invoke-DomeniaDbExec 'BEGIN IMMEDIATE;' $holder)
            $second=[pscustomobject]@{QueryKey=(Get-DomeniaLiveHash 'q2');ObservedUtc=[datetime]::UtcNow.ToString('o');Rows=@()}
            $Payload=[pscustomobject]@{Mode='Write';Path=$dbPath;Scope=$scope;Observations=@();Query=$second}
            try{[void](& ([scriptblock]::Create($cacheCode)))}catch{$failure=$_.Exception.Message}
        } finally { try{[void](Invoke-DomeniaDbExec 'ROLLBACK;' $holder)}catch{};Close-DomeniaDatabase $holder }
        Assert-True ($failure -match '(?i)code 5|locked|busy|verrouill') ('Categorie SQLite perdue : '+$failure)
        Assert-True (-not (Test-CredentialOffered $failure)) 'Un verrou SQLite propose un autre compte.'
        $handle=Open-DomeniaDatabase -Path $dbPath
        try{$rows=@(Invoke-DomeniaDbQuery 'SELECT query_key,observed_utc FROM adcc_live_queries;' $handle)}finally{Close-DomeniaDatabase $handle}
        Assert-True ($rows.Count -eq 1 -and [string]$rows[0].observed_utc -eq $firstUtc) ('Lignes apres verrou : '+$rows.Count)
        [void](& ([scriptblock]::Create($cacheCode)))
        $handle=Open-DomeniaDatabase -Path $dbPath
        try{$after=@(Invoke-DomeniaDbQuery 'SELECT query_key FROM adcc_live_queries;' $handle)}finally{Close-DomeniaDatabase $handle}
        Assert-True ($after.Count -eq 2) 'Le reessai volontaire apres liberation a echoue.'
    }

    # ------------------------------------------------------------ Coupure apres envoi
    Test-Case 'Coupure apres envoi : etat inconnu, recu conserve, aucun rejeu' {
        Reset-FaultFixture
        $receipts=Join-Path $temp 'receipts-cut'
        $script:BusinessRuns=0
        $business="`$script:BusinessRuns++`r`n`$DomeniaWriteDispatched=`$true`r`nthrow [IO.IOException]::new('Connexion au controleur interrompue apres envoi (simulation).')"
        $worker=New-WriteEnvelopeScript -Business $business
        $context=New-WriteContext $receipts
        $failure='';try{[void](& $worker $context ([pscustomobject]@{DN=$script:SelectedObject.DN;CorrelationId=[guid]::NewGuid().ToString('N')}))}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'ETAT INCONNU' -and $failure -match 'aucun rejeu') ('Coupure non signalee comme incertaine : '+$failure)
        Assert-True ((Get-DomeniaStructuredError $failure).Kind -eq 'Uncertain') 'Categorie incertaine perdue.'
        $records=@(Get-ReceiptRecords $receipts)
        Assert-True ($records.Count -eq 1 -and $records[0].Stage -eq 'Unknown') ('Recu : '+@($records|ForEach-Object{$_.Stage}) -join ',')
        # A second request, even identical, is refused while the receipt stays to be checked.
        $again='';try{[void](& $worker $context ([pscustomobject]@{DN=$script:SelectedObject.DN;CorrelationId=[guid]::NewGuid().ToString('N')}))}catch{$again=$_.Exception.Message}
        Assert-True ($again -match 'reste a verifier' -and $script:BusinessRuns -eq 1) ('Rejeu possible : '+$again)
        Assert-True (@(Get-ReceiptRecords $receipts).Count -eq 1) 'Recu supprime ou duplique.'
    }
    # ------------------------------------------------------------ Point 49 re-read of an uncertain write
    Test-Case 'Point 49 : recu incertain, etat attendu garde sans secret, heure d envoi notee' {
        Reset-FaultFixture
        $receipts=Join-Path $temp 'receipts-p49-envelope'
        # Runtime-generated synthetic password: nothing secret is stored in the repository.
        $marker=[guid]::NewGuid().ToString('N');$secure=New-Object Security.SecureString;foreach($c in $marker.ToCharArray()){$secure.AppendChar($c)}
        $business="`$DomeniaWriteDispatched=`$true`r`nthrow [IO.IOException]::new('Connexion au controleur interrompue apres envoi (simulation).')"
        $worker=New-WriteEnvelopeScript -Business $business
        $context=New-WriteContext $receipts;$context.OperationId='WriteResetPassword'
        $payload=[pscustomobject]@{DN=$script:SelectedObject.DN;CorrelationId=[guid]::NewGuid().ToString('N');SecurePassword=$secure;Unlock=$false;MustChange=$false;Safety=[pscustomobject]@{ExpectedDn=$script:SelectedObject.DN;ExpectedGuid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3'}}
        $failure='';try{[void](& $worker $context $payload)}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'ETAT INCONNU') ('Issue incertaine non signalee : '+$failure)
        $records=@(Get-ReceiptRecords $receipts)
        Assert-True ($records.Count -eq 1 -and $records[0].Stage -eq 'Unknown') 'Recu incertain absent'
        Assert-True (([string]$records[0].Expectation.Kind -eq 'PasswordChangedAfterSend') -and [bool]$records[0].CanVerify) 'Etat attendu non garde'
        Assert-True ([bool]([string]$records[0].SentUtc)) 'Heure d envoi non notee'
        $raw=(@(Get-ChildItem -LiteralPath $receipts -Filter '*.json' -File|ForEach-Object{[IO.File]::ReadAllText($_.FullName)}) -join '')
        Assert-True (-not $raw.Contains($marker)) 'Le recu porte le mot de passe'
    }
    Test-Case 'Point 49 : verifier relit l etat effectif sur le controleur initial, conforme seulement, aucun rejeu' {
        Reset-FaultFixture
        $root=Join-Path $temp 'receipts-p49-verify';[void][IO.Directory]::CreateDirectory($root)
        $id=[guid]::NewGuid().ToString('N')
        $record=[pscustomobject]@{Format=1;CanVerify=$true;Expectation=[pscustomobject]@{Kind='UacFlags';Flags=@([pscustomobject]@{Name='ACCOUNTDISABLE';Mask=2;Set=$true})};SentUtc=[datetime]::UtcNow.ToString('o');Id=$id;Operation='WriteAccountDisabled';Domain='dc=example,dc=invalid';Server='dc1.example.invalid';Identity='EXAMPLE\technicien';DN='CN=U,DC=example,DC=invalid';Guid='0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3';PlanFingerprint='';Stage='Unknown';CreatedUtc=[datetime]::UtcNow.ToString('o');UpdatedUtc='';Expected=@();Review=''}
        [IO.File]::WriteAllText((Join-Path $root ($id+'.json')),($record|ConvertTo-Json -Depth 5 -Compress))
        # Directory boundary only: the attribute reader of the worker answers from the fixture.
        $override='function Get-WAttributeFirst {param($Context,[string]$Dn,[string]$Name) $script:P49Reads.Add(([string]$Context.Server)+''|''+$Dn+''|''+$Name); if($script:P49Mode -eq ''Denied''){throw [UnauthorizedAccessException]::new(''Acces refuse (simulation).'')}; if($Name -eq ''userAccountControl''){return $script:P49Uac}; return $null}'
        $verify={
            $text="param(`$Context,`$Payload)`r`n`$ErrorActionPreference='Stop'`r`n"+(Get-DomeniaReceiptsCommon)+"`r`n"+$override+"`r`n"+(Get-DomeniaReceiptWorkerCode)
            $ctx=[pscustomobject]@{ReceiptRoot=$root;BaseDn='DC=example,DC=invalid';Server='dc2.example.invalid';OperationId='ReceiptStore'}
            return @(& ([scriptblock]::Create($text)) $ctx ([pscustomobject]@{Action='Verify';Id=$id;Reason=''}))
        }
        $script:P49Reads=[Collections.Generic.List[string]]::new()
        # Not conforming: the receipt stays to verify and nothing is sent again.
        $script:P49Mode='';$script:P49Uac=512
        $failure='';try{[void](& $verify)}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'non confirme' -and $failure -match 'aucun rejeu') ('Etat non conforme accepte : '+$failure)
        Assert-True ((@(Get-ReceiptRecords $root))[0].Stage -eq 'Unknown') 'Recu resolu sans preuve'
        # A refused read proves nothing.
        $script:P49Mode='Denied'
        $failure='';try{[void](& $verify)}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'refus') ('Refus de lecture pris pour une preuve : '+$failure)
        Assert-True ((@(Get-ReceiptRecords $root))[0].Stage -eq 'Unknown') 'Recu resolu apres un refus de lecture'
        # Conforming re-read, on the controller that received the write, of the object found by its GUID.
        $script:P49Mode='';$script:P49Uac=514
        $out=@(& $verify)
        $after=(@(Get-ReceiptRecords $root))[0]
        Assert-True (($after.Stage -eq 'Verified') -and ([string]$after.Review -match 'conforme')) ('Recu : '+[string]$after.Stage+' '+[string]$after.Review)
        Assert-True (@($script:P49Reads|Where-Object{$_ -ne 'dc1.example.invalid|<GUID=0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3>|userAccountControl'}).Count -eq 0) ('Relectures : '+($script:P49Reads -join ' ; '))
        Assert-True ([int]$out[-1].Pending -eq 0) 'Recu encore compte a verifier'
        # An attribute left out of the answer is unread: the receipt stays to verify.
        $script:P49Reads.Clear();$record.Stage='Unknown';$record.Review='';[IO.File]::WriteAllText((Join-Path $root ($id+'.json')),($record|ConvertTo-Json -Depth 5 -Compress))
        $script:P49Uac=$null
        $failure='';try{[void](& $verify)}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -match 'non relu') ('Attribut absent pris pour une valeur : '+$failure)
        Assert-True ((@(Get-ReceiptRecords $root))[0].Stage -eq 'Unknown') 'Recu resolu sans relecture'
    }
    Test-Case 'Recus : compaction des recus termines, recus non resolus conserves' {
        Reset-FaultFixture
        $receipts=Join-Path $temp 'receipts-compact'
        [void][IO.Directory]::CreateDirectory($receipts)
        $base=[datetime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
        for($i=0;$i -lt 400;$i++){
            $id=('{0:x32}' -f $i)
            $json=([pscustomobject]@{Format=1;Id=$id;Operation='WriteRename';Domain='dc=example,dc=invalid';Stage='Delivered';PlanFingerprint=('P'+$i);CreatedUtc=$base.AddMinutes($i).ToString('o');UpdatedUtc=$base.AddMinutes($i).ToString('o')}|ConvertTo-Json -Compress)
            [IO.File]::WriteAllText((Join-Path $receipts ($id+'.json')),$json)
        }
        # Oldest of all, unresolved, in another domain: must never move.
        $openId='ffffffffffffffffffffffffffffffff'
        $open=([pscustomobject]@{Format=1;Id=$openId;Operation='WriteRename';Domain='dc=other,dc=invalid';Stage='Unknown';PlanFingerprint='OPEN';CreatedUtc=$base.AddDays(-1).ToString('o');UpdatedUtc=$base.AddDays(-1).ToString('o')}|ConvertTo-Json -Compress)
        [IO.File]::WriteAllText((Join-Path $receipts ($openId+'.json')),$open)
        $script:BusinessRuns=0
        $business="`$script:BusinessRuns++`r`n`$DomeniaWriteDispatched=`$true`r`n[pscustomobject]@{Delivered=`$true}"
        $worker=New-WriteEnvelopeScript -Business $business
        $failure='';try{[void](& $worker (New-WriteContext $receipts) ([pscustomobject]@{DN=$script:SelectedObject.DN;CorrelationId=[guid]::NewGuid().ToString('N')}))}catch{$failure=$_.Exception.Message}
        Assert-True ($failure -eq '' -and $script:BusinessRuns -eq 1) ('Ecriture bloquee par les recus termines : '+$failure)
        $archive=Join-Path $receipts 'archive'
        $left=@([IO.Directory]::GetFiles($receipts,'*.json'))
        $moved=@([IO.Directory]::GetFiles($archive,'*.json'))
        Assert-True ($left.Count -eq 257 -and $moved.Count -eq 145) ('Repartition : '+$left.Count+' / '+$moved.Count)
        Assert-True ([IO.File]::Exists((Join-Path $receipts ($openId+'.json')))) 'Recu non resolu archive.'
        Assert-True ([IO.File]::Exists((Join-Path $archive (('{0:x32}' -f 0)+'.json'))) -and [IO.File]::Exists((Join-Path $receipts (('{0:x32}' -f 399)+'.json')))) 'Ordre d archivage inattendu.'
    }
    Test-Case 'Coupure apres envoi : interface verrouillee en ecriture, sans message de reussite' {
        Reset-FaultFixture
        $state=[pscustomobject]@{Name='Renommer';Correlation='c0de';Capability='Edit';TargetDn=$script:SelectedObject.DN}
        $script:ActiveWriteTaskId='w2';$script:WriteState='Running'
        Fail-DomeniaWriteTaskUi '[DOMENIA:Uncertain;0;0x80131620] ETAT INCONNU apres envoi au DC. Recu conserve ; aucun rejeu automatique. Connexion interrompue (simulation).' $state
        Assert-True ($script:WriteState -eq 'Unknown' -and $script:UnknownWriteTargetDn -eq $state.TargetDn) ('Etat : '+$script:WriteState)
        Assert-True (Test-DomeniaAccessBusyWrite) 'Les ecritures restent ouvertes apres une issue incertaine.'
        $blocked='';try{Assert-DomeniaCapability 'Edit'}catch{$blocked=$_.Exception.Message}
        Assert-True ($blocked.Length -gt 0) 'Nouvelle ecriture autorisee avant verification.'
        Assert-True (@($script:Dialogs|Where-Object{$_ -match 'Aucun rejeu automatique'}).Count -eq 1 -and $script:Dispatched -eq 0) 'Rejeu ou message manquant.'
        Assert-True (@(@($script:StatusLog)+@($script:Dialogs)|Where-Object{$_ -match '(?i)\breussi|succes|Operation verifiee'}).Count -eq 0) 'Reussite annoncee sur une issue incertaine.'
    }
    # ------------------------------------------------------------ L02 : FI-15 erreur locale prise pour un refus de compte
    Test-Case 'FI-15 : acces fichier refuse hors tache AD, aucune proposition de changer de compte' {
        Reset-FaultFixture
        $local="Access to the path 'C:\DomeniaLab\Exports\liste.csv' is denied."
        $offered=Request-DomeniaAccessRecovery -Operation 'Action demandee' -ErrorValue $local -Interactive
        Assert-True (-not $offered) 'Un autre compte AD est propose pour un fichier local refuse.'
        Assert-True ($script:AccessState.Pending.Count -eq 0) ('Avis de droits cree pour un fichier local : '+$script:AccessState.Pending.Count)
        [void](Request-DomeniaAccessRecovery -Operation 'Operation a verifier' -ErrorValue $local)
        Assert-True ($script:AccessState.Pending.Count -eq 0) 'Un statut WARN/ERROR local alimente le badge d acces.'
    }
    Test-Case 'FI-15 : refus venu d une tache qui exige un compte, reprise toujours proposee' {
        Reset-FaultFixture
        $script:AccessCurrentJob=[pscustomobject]@{OperationId='ReadLaps';SessionEpoch=1L;IsWrite=$false;CallbackState=[pscustomobject]@{DN=$script:SelectedObject.DN;Generation=1L}}
        try { [void](Request-DomeniaAccessRecovery -Operation 'Lecture LAPS' -ErrorValue 'Acces refuse' -Interactive) }
        finally { $script:AccessCurrentJob=$null }
        Assert-True ($script:AccessState.Pending.Count -eq 1) ('Refus AD reel non signale : '+$script:AccessState.Pending.Count)
    }

    # ------------------------------------------------------------ L02 : FI-01, FI-02, FI-07, FI-22
    Test-Case 'FI-01 : exception levee pendant l affichage d une erreur, journalisee et comptee' {
        Reset-FaultFixture
        $script:DomeniaErrorOccurrences=$null;$script:HandlingDispatcherException=$false;$script:CurrentUiProfile='Tech'
        $logs=[Collections.Generic.List[string]]::new()
        function Write-AppLog {param($Text,$Level) $logs.Add([string]$Text)}
        # The box of the first error pumps a frame in which a timer raises a second, different exception.
        $script:SecondFault=[InvalidOperationException]::new('Seconde panne pendant l affichage (simulation).')
        function Show-ErrorBox {param($Message,$Details)
            $script:Dialogs.Add('ERREUR '+[string]$Message)
            if($null -ne $script:SecondFault){$f=$script:SecondFault;$script:SecondFault=$null;$script:Nested=Invoke-DomeniaDispatcherFault -Exception $f}
        }
        $first=Invoke-DomeniaDispatcherFault -Exception ([NullReferenceException]::new('Premiere panne (simulation).'))
        Assert-True ([bool]$script:Nested.Queued -and [bool]$script:Nested.Logged) 'La seconde exception n a pas ete journalisee pendant l affichage.'
        Assert-True (@($logs|Where-Object{$_ -match 'Seconde panne' -and $_ -match [regex]::Escape($script:Nested.Code)}).Count -eq 1) ('Journal : '+($logs -join ' | '))
        Assert-True (@($logs|Where-Object{$_ -match 'Premiere panne' -and $_ -match [regex]::Escape($first.Code)}).Count -eq 1) 'Premiere erreur absente du journal.'
        Assert-True ($first.Shown -and $first.Others -eq 1 -and @($script:Dialogs).Count -eq 1) ('Fenetres : '+@($script:Dialogs).Count+' ; autres : '+$first.Others)
        Assert-True (@($script:StatusLog|Where-Object{$_ -match '1 autre erreur' -and $_ -match [regex]::Escape($first.Code)}).Count -eq 1) ('Statuts : '+($script:StatusLog -join ' | '))
        Assert-True (-not $script:HandlingDispatcherException) 'Drapeau d affichage reste leve.'
        Assert-True (-not ((@($script:Dialogs)+@($script:StatusLog)) -join ' ').Contains('Premiere panne')) 'Message .NET brut affiche en Essentiel (UI-02).'
    }
    Test-Case 'FI-02 : meme erreur repetee, un seul code, une banniere comptee et une ligne par minute' {
        Reset-FaultFixture
        $script:DomeniaErrorOccurrences=$null;$script:HandlingDispatcherException=$false
        $logs=[Collections.Generic.List[string]]::new()
        function Write-AppLog {param($Text,$Level) $logs.Add([string]$Text)}
        $codes=@{}
        for($i=0;$i -lt 12;$i++){$r=Invoke-DomeniaDispatcherFault -Exception ([InvalidOperationException]::new('Panne repetee (simulation).'));$codes[$r.Code]=$true}
        Assert-True ($codes.Count -eq 1) ('Codes differents pour la meme erreur : '+$codes.Count)
        Assert-True (@($logs).Count -eq 1) ('Lignes de journal pour 12 occurrences : '+@($logs).Count)
        # Without the page banner (no main window), a repeated error never opens a new box.
        Assert-True (@($script:Dialogs).Count -eq 1) ('Boites ouvertes : '+@($script:Dialogs).Count)
        $t0=[datetime]'2026-10-08T10:00:00'
        $engine=@(for($i=0;$i -lt 240;$i++){Register-DomeniaErrorOccurrence -Signature 'System.Exception|Moteur (simulation)|Moteur asynchrone' -Now $t0.AddMilliseconds(250*$i)})
        Assert-True (@($engine|Where-Object{$_.Write}).Count -eq 1) ('Lignes en une minute de ticks : '+@($engine|Where-Object{$_.Write}).Count)
        Assert-True ($engine[239].Count -eq 240 -and @($engine|ForEach-Object{$_.Code}|Select-Object -Unique).Count -eq 1) 'Compteur ou code incoherent.'
        Assert-True ((Register-DomeniaErrorOccurrence -Signature 'System.Exception|Moteur (simulation)|Moteur asynchrone' -Now $t0.AddSeconds(121)).Write) 'Aucune ligne apres une minute.'
        $other=Register-DomeniaErrorOccurrence -Signature 'System.Exception|Autre panne|Moteur asynchrone' -Now $t0.AddSeconds(1)
        Assert-True ($other.Write -and $other.New -and $other.Code -ne $engine[0].Code) 'Une autre erreur est masquee par le dedoublonnage.'
    }
    Test-Case 'FI-02 : minuteur du moteur en panne arrete apres 3 echecs, sans boucle de fenetres' {
        Reset-FaultFixture
        $script:DomeniaErrorOccurrences=$null;$script:EngineTicks=0;$script:EngineLogs=[Collections.Generic.List[string]]::new()
        $savedLog=${function:Write-AppLog}
        function script:Write-StartupTrace {param($Stage,$Status,$Detail,$DurationMs)}
        function script:Complete-UiTasks {$script:EngineTicks++;throw [InvalidOperationException]::new('Panne du moteur (simulation).')}
        function script:Write-AppLog {param($Text,$Level) $script:EngineLogs.Add([string]$Text)}
        try {
            $script:AsyncEngineReady=$false;$script:AsyncTimer=$null
            Initialize-AsyncEngine
            Assert-True ($script:AsyncTimer.IsEnabled) 'Moteur non demarre.'
            $frame=[Windows.Threading.DispatcherFrame]::new()
            $stop=[Windows.Threading.DispatcherTimer]::new();$stop.Interval=[TimeSpan]::FromMilliseconds(2600)
            $handler=[EventHandler]({$frame.Continue=$false}.GetNewClosure())
            $stop.Add_Tick($handler)
            try{$stop.Start();[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$stop.Stop();$stop.Remove_Tick($handler)}
            Assert-True ($script:EngineTicks -eq 3) ('Ticks en echec avant arret : '+$script:EngineTicks)
            Assert-True ((-not $script:AsyncTimer.IsEnabled) -and [bool]$script:AsyncEngineFaultStopped) 'Minuteur toujours actif apres 3 echecs.'
            Assert-True (@($script:Dialogs).Count -eq 1) ('Fenetres ouvertes : '+@($script:Dialogs).Count)
            Assert-True (@($script:EngineLogs|Where-Object{$_ -match 'Panne du moteur'}).Count -eq 1) ('Lignes de la meme erreur : '+@($script:EngineLogs|Where-Object{$_ -match 'Panne du moteur'}).Count)
            Assert-True (@($script:StatusLog|Where-Object{$_ -match '3 erreurs'}).Count -eq 1) ('Statuts : '+($script:StatusLog -join ' | '))
            $code=([regex]::Match(($script:Dialogs -join ' '),'INC-[0-9A-F]{4}')).Value
            Assert-True ($code -and @($script:EngineLogs|Where-Object{$_.Contains($code)}).Count -ge 1) 'Code incident de la fenetre absent du journal.'
        } finally {
            if($null -ne $script:AsyncTimer){$script:AsyncTimer.Stop()};$script:AsyncTimer=$null;$script:AsyncEngineReady=$false
            Set-Item -Path function:script:Write-AppLog -Value $savedLog
            Remove-Item -Path function:script:Complete-UiTasks -ErrorAction SilentlyContinue
        }
    }
    Test-Case 'FI-07 : code incident identique a l ecran, au journal lisible, au Support et sur une seule ligne de Domenia.log' {
        Reset-FaultFixture
        $script:DomeniaErrorOccurrences=$null;$script:CurrentUiProfile='Tech'
        # Real chain: Show-DomeniaOperationError, Set-Status, Write-AppLog, Add-DomeniaUiLog, readable journal and
        # Domenia.log writer; the Support collector is observed at its input (Add-DomeniaSupportIncidentFromLog).
        foreach($name in @('Show-DomeniaOperationError','Set-Status','Add-DomeniaUiLog','Write-AppLog','ConvertTo-DomeniaLogFileLines','Get-DomeniaAppLogFallbackPaths','Write-DomeniaAppLogFile',
            'Start-DomeniaAppLogFlushTimer','Stop-DomeniaAppLogQueue','Invoke-DomeniaAppLogRotation','Flush-DomeniaAppLog','Invoke-DomeniaAppLogFlush','Set-DomeniaAppLogAvailability')){
            . ([scriptblock]::Create((Get-FunctionAst $script:CoreAst $name).Extent.Text))
        }
        function Initialize-DomeniaDataStore {}
        $support=[Collections.Generic.List[object]]::new()
        function Add-DomeniaSupportIncidentFromLog {param($Text,$Level,$Area) $support.Add([pscustomobject]@{Text=[string]$Text;Level=[string]$Level;Area=[string]$Area})}
        $script:Window=$null;$script:UiLogLines=$null;$script:UiLogReadableItems=$null;$script:UiLogVisuallyCollapsed=$true;$script:UiLogUnreadErrors=0
        $script:AuditPath=Join-Path $temp 'incident-Domenia.log';$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
        $info=Show-DomeniaOperationError -Operation 'Lecture de test' -ErrorRecordOrException ([TimeoutException]::new('Delai de test depasse.'))
        $code=[string]$info.IncidentCode
        Assert-True ($code -match '^INC-[0-9A-F]{4}$') ('Code : '+$code)
        Assert-True (@($script:Dialogs|Where-Object{$_.Contains('Code incident : '+$code)}).Count -eq 1) ('Ecran : '+($script:Dialogs -join ' | '))
        $readable=@($script:UiLogReadableItems)
        Assert-True (($readable.Count -eq 1) -and $readable[0].Text.Contains('('+$code+')') -and ($readable[0].Level -eq 'ERROR') -and ([int]$script:UiLogUnreadErrors -eq 1)) ('Journal lisible : '+(@($readable|ForEach-Object{$_.Text}) -join ' | '))
        Assert-True (-not $readable[0].Text.Contains('TimeoutException')) 'Texte technique dans le journal lisible.'
        Assert-True (@($support|Where-Object{($_.Level -eq 'ERROR') -and $_.Text.Contains($code)}).Count -ge 1) ('Support : '+(@($support|ForEach-Object{$_.Area+' '+$_.Text}) -join ' | '))
        $lines=@([IO.File]::ReadAllLines($script:AuditPath)|Where-Object{$_.Contains($code)})
        Assert-True (($lines.Count -eq 1) -and $lines[0].Contains('['+$code+'] Lecture de test')) ('Domenia.log : '+($lines -join ' | '))
    }
    Test-Case 'P-CD-09 : erreur ignoree au journal technique (Domenia.log, jamais le journal lisible), echantillonnee, jamais remontee' {
        Reset-FaultFixture
        $script:DomeniaErrorOccurrences=$null;$script:CurrentUiProfile='Tech'
        # Real chain as in FI-07: Write-DomeniaSwallowed of the core around Add-DomeniaSwallowedEntry of the closed plan,
        # then Write-AppLog, Add-DomeniaUiLog, readable journal and Domenia.log writer.
        foreach($name in @('Write-DomeniaSwallowed','Add-DomeniaUiLog','Write-AppLog','ConvertTo-DomeniaLogFileLines','Get-DomeniaAppLogFallbackPaths','Write-DomeniaAppLogFile',
            'Start-DomeniaAppLogFlushTimer','Stop-DomeniaAppLogQueue','Invoke-DomeniaAppLogRotation','Flush-DomeniaAppLog','Invoke-DomeniaAppLogFlush','Set-DomeniaAppLogAvailability')){
            . ([scriptblock]::Create((Get-FunctionAst $script:CoreAst $name).Extent.Text))
        }
        function Initialize-DomeniaDataStore {}
        function Add-DomeniaSupportIncidentFromLog {param($Text,$Level,$Area)}
        $script:Window=$null;$script:UiLogLines=$null;$script:UiLogReadableItems=$null;$script:UiLogVisuallyCollapsed=$true;$script:UiLogUnreadErrors=0
        $script:AuditPath=Join-Path $temp 'swallowed-Domenia.log';$script:AppLogQueue=$null;$script:AppLogUnavailable=$false;$script:AppLogRetryAt=$null;$script:AppLogLastLine=$null
        $script:DomeniaSwallowedState=$null;$script:DomeniaSwallowedWriting=$false
        # A value shown in this session is known to Protect-DomeniaLogText only, not to the Model rule.
        $script:SecretRows=@([pscustomobject]@{Value='Valeur-Affichee-0101'})
        try {
            $t0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
            $err=[InvalidOperationException]::new('copie de Valeur-Affichee-0101 refusee, password=MARQUEUR-SECRET-0102')
            $out=@(Write-DomeniaSwallowed 'Secrets' 'Copy' $err -Now $t0)
            Write-DomeniaSwallowed 'Secrets' 'Copy' $err -Now ($t0.AddSeconds(30))
            Write-DomeniaSwallowed 'Secrets' 'Copy' $err -Now ($t0.AddSeconds(61))
            Assert-True ($out.Count -eq 0) ('Sortie sur le pipeline : '+$out.Count)
            $entries=@(Get-DomeniaSwallowedEntries)
            $outcomes=(@($entries|ForEach-Object{[string]$_.Journal}) -join ',')
            Assert-True ($outcomes -eq 'Logged,Sampled,Logged') ('Issues : '+$outcomes)
            Assert-True ($entries[0].Message.Contains('[SECRET MASQUE]') -and (-not $entries[0].Message.Contains('Valeur-Affichee-0101'))) ('Masquage du coeur absent : '+$entries[0].Message)
            $lines=@([IO.File]::ReadAllLines($script:AuditPath)|Where-Object{$_.Contains('[Secrets] Copy')})
            Assert-True ($lines.Count -eq 2) ('Lignes Domenia.log : '+$lines.Count)
            Assert-True (@($lines|Where-Object{($_ -split "`t")[1] -eq 'DEBUG'}).Count -eq 2) ('Niveau : '+($lines -join ' | '))
            Assert-True ($lines[1].EndsWith('(+1 occurrence(s) depuis la ligne précédente)',[StringComparison]::Ordinal)) ('Regroupement : '+$lines[1])
            Assert-True (@($lines|Where-Object{$_.Contains('Valeur-Affichee-0101') -or $_.Contains('MARQUEUR-SECRET-0102')}).Count -eq 0) 'Secret dans Domenia.log.'
            Assert-True (@($script:UiLogReadableItems).Count -eq 0) 'Ligne technique dans le journal lisible.'
            # Journal in failure that traces its own failure: nothing is thrown, the inner trace is a reentry.
            function Write-AppLog {param([string]$Text,[string]$Level,[string]$Area) Write-DomeniaSwallowed 'Journal' 'Write-AppLog' ([InvalidOperationException]::new('token=MARQUEUR-SECRET-0103'));throw 'journal indisponible'}
            $out=@(Write-DomeniaSwallowed 'Stockage' 'Save' ([InvalidOperationException]::new('disque plein')) -Now $t0)
            Assert-True ($out.Count -eq 0) 'Exception ou sortie remontee par la trace.'
            $tail=@(Get-DomeniaSwallowedEntries|Select-Object -Last 2)
            Assert-True (($tail[0].Category -eq 'Stockage') -and ($tail[0].Journal -eq 'Unavailable')) ('Trace principale : '+$tail[0].Category+' '+$tail[0].Journal)
            Assert-True (($tail[1].Category -eq 'Journal') -and ($tail[1].Journal -eq 'Reentry') -and ($tail[1].Message -eq '')) ('Reentree : '+$tail[1].Category+' '+$tail[1].Journal+' '+$tail[1].Message)
            Assert-True (-not [bool]$script:DomeniaSwallowedWriting) 'Verrou d ecriture du journal non relache.'
        } finally { $script:DomeniaSwallowedState=$null;$script:DomeniaSwallowedWriting=$false;$script:SecretRows=@() }
    }
    Test-Case 'UI-02 : faute interne sans texte .NET a l ecran, message Domenia et refus systeme conserves' {
        $nullFault=try{$o=$null;$o.Methode()}catch{$_}
        $internal=ConvertTo-DomeniaErrorInfo -ErrorRecordOrException $nullFault -Operation 'Lecture de test'
        Assert-True ([bool]$internal.Internal -and $internal.Friendly.Contains('erreur interne de Domenia') -and (-not $internal.Friendly.Contains('Methode'))) $internal.Friendly
        $own=try{throw 'Choisissez dʼabord une OU.'}catch{$_}
        Assert-True (Test-DomeniaOperatorMessage $own) 'Message leve par Domenia non reconnu.'
        Assert-True ((ConvertTo-DomeniaErrorInfo -ErrorRecordOrException $own -Operation 'Lecture de test').Friendly.Contains('Choisissez dʼabord une OU.')) 'Message Domenia masque.'
        $io=ConvertTo-DomeniaErrorInfo -ErrorRecordOrException ([IO.IOException]::new('Le fichier est utilise par un autre processus.')) -Operation 'Export'
        Assert-True ((-not [bool]$io.Internal) -and $io.Friendly.Contains('utilise par un autre processus')) $io.Friendly
        Assert-True ((Test-DomeniaInternalFault ([NullReferenceException]::new('x'))) -and (-not (Test-DomeniaOperatorMessage ([IO.IOException]::new('x'))))) 'Classement des fautes incoherent.'
    }
    Test-Case 'FI-22 : erreur apres affichage annoncee comme arret inattendu, avant comme initialisation' {
        $after=Get-DomeniaFatalMessage -SessionShown $true -Summary 'Object reference not set to an instance of an object.' -Code 'INC-1A2B' -AppLog 'C:\Domenia\Logs\Domenia.log' -StartupLog 'C:\Domenia\Logs\Domenia-startup.log'
        Assert-True ($after.Contains('sʼest arrêté de façon inattendue') -and $after.Contains('INC-1A2B') -and $after.Contains('Domenia.log') -and $after.Contains('Domenia-startup.log')) $after
        Assert-True (-not $after.Contains('Object reference')) 'Message .NET brut affiche hors Expert.'
        Assert-True ((Get-DomeniaFatalMessage -SessionShown $true -Summary 'Object reference' -Code 'INC-1A2B' -AppLog 'C:\x.log' -Expert $true).Contains('Object reference')) 'Detail Expert absent.'
        # Before display: a raw .NET message stays in the journals outside Expert; a Domenia message is shown.
        $raw=Get-DomeniaFatalMessage -SessionShown $false -Summary 'Cannot find type [X].' -Code 'INC-3C4D' -StartupLog 'C:\Domenia\Logs\Domenia-startup.log'
        Assert-True ($raw.Contains('nʼa pas pu terminer son initialisation') -and (-not $raw.Contains('Cannot find type')) -and $raw.Contains('INC-3C4D') -and $raw.Contains('Domenia-startup.log')) $raw
        $own=Get-DomeniaFatalMessage -SessionShown $false -Summary 'Stockage non inscriptible.' -Code 'INC-3C4D' -StartupLog 'C:\Domenia\Logs\Domenia-startup.log' -SummaryForOperator $true
        Assert-True ($own.Contains('Stockage non inscriptible.')) $own
        $none=Get-DomeniaFatalMessage -SessionShown $false -Summary 'Cannot find type [X].' -Code 'INC-3C4D'
        Assert-True ($none.Contains('Cannot find type') -and $none.Contains('conservez ce message')) 'Sans journal, le detail doit rester a l ecran.'
        # The session counts as shown only once the main window has rendered (ContentRendered), never before.
        $w=[Windows.Window]::new()
        try {
            $script:DomeniaSessionShown=$true
            Register-DomeniaSessionShownHook -Window $w
            Assert-True (-not [bool]$script:DomeniaSessionShown) 'Session annoncee affichee avant le rendu.'
            $raise=[Windows.Window].GetMethod('OnContentRendered',[Reflection.BindingFlags]'NonPublic,Instance')
            [void]$raise.Invoke($w,@([EventArgs]::Empty))
            Assert-True ([bool]$script:DomeniaSessionShown) 'Rendu de la fenetre sans bascule en arret inattendu.'
        } finally { $w.Close();$script:DomeniaSessionShown=$false }
        $text=$script:CoreAst.Extent.Text;$text=$text.Substring($text.IndexOf('# Main autoritaire'))
        $hook=$text.IndexOf('Register-DomeniaSessionShownHook -Window $script:Window');$dialog=$text.IndexOf('$null = $script:Window.ShowDialog()')
        Assert-True ($hook -gt 0 -and $dialog -gt $hook) 'Crochet de rendu absent avant ShowDialog dans le bloc principal.'
        Assert-True ($text.Substring(0,$dialog).IndexOf('$script:DomeniaSessionShown = $true') -lt 0) 'Bascule posee avant ShowDialog dans le bloc principal.'
    }
    Test-Case 'Resultat d ecriture sans verification positive : jamais annonce reussi' {
        Reset-FaultFixture
        $state=[pscustomobject]@{Name='Renommer';Correlation='beef';Capability='Edit';TargetDn=$script:SelectedObject.DN}
        $script:ActiveWriteTaskId='w3';$script:WriteState='Running'
        Complete-DomeniaWriteTaskUi ([pscustomobject]@{Verified=$false;Message='Envoye, relecture impossible (simulation).'}) $state
        Assert-True ($script:WriteState -eq 'Unknown' -and (Test-DomeniaAccessBusyWrite)) ('Etat : '+$script:WriteState)
        Assert-True (@($script:StatusLog|Where-Object{$_ -match '(?i)Operation verifiee|reussi'}).Count -eq 0) 'Reussite annoncee sans verification.'
    }
}
finally { if([IO.Directory]::Exists($temp)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue} }
}

$failed=@($script:Checks|Where-Object{$_.Status -eq 'Failed'}).Count
$passed=@($script:Checks|Where-Object{$_.Status -eq 'Passed'}).Count
$report=[ordered]@{
    Kind='FaultInjection';Point='D007';Rule='Chaque panne conserve sa categorie et n aboutit ni a une reussite ni a une suppression inventee.'
    Faults=@('DNS lent','Refus AD','Dechiffrement LAPS refuse','Disque plein','SQLite verrouille','Coupure apres envoi')
    Host=@{PSEdition=[string]$PSVersionTable.PSEdition;PSVersion=$PSVersionTable.PSVersion.ToString()}
    NoADAccess=$true;NoNetwork=$true;Passed=$passed;Failed=$failed;Complete=($failed -eq 0 -and $passed -gt 0);Tests=$script:Checks.ToArray()
}
if(-not $ReportPath){$ReportPath=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-faults-'+[guid]::NewGuid().ToString('N')+'.json')}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
if(-not $Quiet){$script:Checks|Format-Table Name,Status -AutoSize|Out-String|Write-Host;Write-Host ('Rapport : '+$ReportPath)}
if($failed -gt 0 -or $passed -eq 0){exit 1}
exit 0
