#requires -Version 5.1
<# D091/D094/D095 wiring tests.
   Real write envelope, real pinned body, real AST-imported UI functions, pure rules dot-sourced.
   No AD write, no network, no real remote mutation. Boundaries are doubled.
#>
[CmdletBinding()]
param([string]$ReportPath='', [switch]$Quiet)
$ErrorActionPreference='Stop'
$wad=Split-Path -Parent $PSScriptRoot
$root=Split-Path -Parent $wad
$script:Checks=[Collections.Generic.List[object]]::new()
$script:Spy=@{}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('Domenia-wiring-ecritures-'+[guid]::NewGuid().ToString('N'))
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
    $nodes=@($Ast.FindAll({param($n)((($n -is [Management.Automation.Language.FunctionDefinitionAst])) -and (($n.Name -eq $Name)))},$true))
    if($nodes.Count -ne 1){throw ('Fonction absente ou ambigue : '+$Name)}
    return $nodes[0]
}
function Get-SingleQuotedLiterals {param($Ast)
    return @($Ast.FindAll({param($n)((($n -is [Management.Automation.Language.StringConstantExpressionAst])) -and (($n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString)))},$true)|Sort-Object {$_.Extent.StartOffset})
}
function Spy-Function {param([string]$Name)
    $cmd=Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { $script:Spy[$Name]=$cmd.ScriptBlock }
}
function Import-AstFunction {param($Ast,[string]$Name,[switch]$Optional)
    $nodes=@($Ast.FindAll({param($n)((($n -is [Management.Automation.Language.FunctionDefinitionAst])) -and (($n.Name -eq $Name)))},$true))
    # Defined at script scope: a dot-source inside this function would vanish with its scope.
    if ($nodes.Count -eq 1) { Set-Item -Path ('function:script:'+$Name) -Value $nodes[0].Body.GetScriptBlock(); return $true }
    if (-not $Optional) { throw ('Fonction absente ou ambigue : '+$Name) }
    return $false
}
$infrastructure=$true
try {
    if ((($PSVersionTable.PSEdition -ne 'Desktop')) -or ((($PSVersionTable.PSVersion.Major -ne 5))) -or ((-not [Environment]::Is64BitProcess)) -or (([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'))) { throw 'Windows PowerShell 5.1 x64 -STA requis ; une execution sous PowerShell 7 ne vaut pas preuve.' }
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [void][IO.Directory]::CreateDirectory($temp)
    $modulesPath=Join-Path $wad 'Domenia-Modules.ps1'
    if (Test-Path -LiteralPath $modulesPath) { . $modulesPath }
    $modulesDir=Join-Path $wad 'modules'
    if (Test-Path -LiteralPath $modulesDir) {
        if (-not ('Domenia.InterventionPlan' -as [type])) {
            $identityTypes=Join-Path $modulesDir 'Domenia-Identity.Types.cs'
            if (Test-Path -LiteralPath $identityTypes) { Add-Type -Path $identityTypes }
        }
        foreach($m in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Access.Model.ps1','Domenia-Safety.Model.ps1')) { $p=Join-Path $modulesDir $m; if(Test-Path -LiteralPath $p){ . $p } }
        if (-not (Get-Command Get-DomeniaReceiptRequirement -ErrorAction SilentlyContinue)) { foreach($p in @(Get-ChildItem -LiteralPath $modulesDir -Filter '*.Model.ps1' -File | ForEach-Object{$_.FullName})) { . $p } }
    }
    if (-not (Get-Command Protect-DomeniaSecretText -ErrorAction SilentlyContinue)) { function Protect-DomeniaSecretText {param($Text); return [string]$Text} }
    foreach($rule in @('Get-DomeniaMember','Get-DomeniaOperationEffect','Get-DomeniaReceiptRequirement','Get-DomeniaReceiptResumeState','New-DomeniaWriteRegistry','Test-DomeniaWriteAdmission')) { if (-not (Get-Command $rule -ErrorAction SilentlyContinue)) { throw ('Regles absente : '+$rule) } }
    foreach($fn in @('New-DomeniaInterventionPlan','Test-DomeniaPlanStillValid','ConvertTo-DomeniaPlanChanges','Test-DomeniaPlanHasSecret','New-DomeniaSelectionIdentity')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction de regle absente : '+$fn) } }
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    foreach($name in @('Get-WorkerContext','ConvertTo-DomeniaErrorInfo','Get-DomeniaStructuredError','Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode','Assert-DomeniaWorkerRegistry','Start-UiTask','Start-DomeniaWriteTask','Set-ControlsBusy','Get-DomeniaControl','Set-DomeniaControlText','Write-DomeniaAtomicText','Assert-WriteAllowed','Assert-DomeniaRemoteWriteAllowed','Get-DomeniaWriteRoute','New-DomeniaSelectionWritePlan','Format-DomeniaPlanConfirmation','Test-DomeniaPlanDispatch','Set-AccountDisabled')) { [void](Import-AstFunction $script:CoreAst $name -Optional) }
    foreach($fn in @('Start-UiTask','Start-DomeniaWriteTask','Set-ControlsBusy','Get-DomeniaControl','Get-DomeniaStructuredError','Assert-DomeniaWorkerOperationCode','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Get-DomeniaWorkerOperationHashes','Assert-WriteAllowed','Get-DomeniaWriteRoute','New-DomeniaSelectionWritePlan','Format-DomeniaPlanConfirmation','Test-DomeniaPlanDispatch','Set-AccountDisabled')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction absente : '+$fn) } }
    $assignment=@($script:CoreAst.FindAll({param($n)((($n -is [Management.Automation.Language.AssignmentStatementAst])) -and ((($n.Left.Extent.Text -eq '$script:WorkerCommon')) -and (($n.Operator -eq [Management.Automation.Language.TokenKind]::Equals))))},$true))
    if($assignment.Count -ne 1){throw 'Code commun des workers introuvable.'}
    $literal=$assignment[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    if ($null -eq $literal) { throw 'Code commun des workers introuvable.' }
    $ct=$null;$ce=$null;$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$literal.Value,[ref]$ct,[ref]$ce)
    if(@($ce).Count){throw 'Code commun des workers non analysable.'}
    $script:WorkerCommon=[string]$literal.Value
    foreach($fn in @($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    $receiptAst=Read-SourceAst (Join-Path $wad 'modules\Domenia-Receipts.Worker.ps1')
    $receiptLiterals=@(Get-SingleQuotedLiterals $receiptAst | Where-Object { $_.Value.Contains('function New-WReceipt') })
    if ($receiptLiterals.Count -lt 1) { throw 'Code worker recus introuvable.' }
    $rt=$null;$re=$null;$receiptCodeAst=[Management.Automation.Language.Parser]::ParseInput([string]$receiptLiterals[0].Value,[ref]$rt,[ref]$re)
    if(@($re).Count){throw 'Code worker recus non analysable.'}
    foreach($fn in @($receiptCodeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    foreach($fn in @('New-WReceipt','Write-WReceipt','Get-WReceiptRoot')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction worker recus absente : '+$fn) } }
    $runspaceLiterals=@(Get-SingleQuotedLiterals (Get-FunctionAst $script:CoreAst 'New-DomeniaWorkerRunspace')|ForEach-Object{[string]$_.Value})
    $script:EnvelopeStart=@($runspaceLiterals|Where-Object{$_.StartsWith('$DomeniaWriteDispatched=$false')})
    $script:EnvelopeEnd=@($runspaceLiterals|Where-Object{$_.Contains('ETAT INCONNU apres envoi')})
    $script:EnvelopeMarker=@($runspaceLiterals|Where-Object { ((($_.TrimStart().StartsWith('catch {')))) -and ((($_.Contains('[DOMENIA:')))) })
    if ((($script:EnvelopeStart.Count -ne 1)) -or ((($script:EnvelopeEnd.Count -ne 1)))) {throw 'Enveloppe d ecriture introuvable.'}
    $contractsJson=[IO.File]::ReadAllText((Join-Path $root 'tools\operation-contracts.json'))|ConvertFrom-Json
    $script:Contracts=@($contractsJson)
    function Get-PinnedBody {param([string]$Operation)
        $c=@($script:Contracts|Where-Object{$_.Operation -eq $Operation})
        if($c.Count -ne 1){throw ('Contrat absent : '+$Operation)}
        $fileAst=Read-SourceAst (Join-Path $root ([string]$c[0].File))
        $fn=Get-FunctionAst $fileAst ([string]$c[0].Function)
        $allStrings=@($fn.FindAll({param($n)((($n -is [Management.Automation.Language.StringConstantExpressionAst])) -or ((($n -is [Management.Automation.Language.ExpandableStringExpressionAst]))))},$true))
        $here=@($allStrings | Where-Object { $_.Extent.Text.StartsWith('@') } | Sort-Object {$_.Extent.StartOffset})
        $raw=$here[[int]$c[0].LiteralIndex].Extent.Text -replace "`r`n","`n"
        $body=$raw.Substring(3,$raw.Length-6)
        [void](Assert-DomeniaWorkerOperationCode -OperationId $Operation -Code $body)
        return $body
    }
} catch {
    $infrastructure=$false
    $script:Checks.Add([pscustomobject]@{Name='Infrastructure : PS 5.1, regles, AST, enveloppe';Status='Failed';Detail=$_.Exception.ToString()})
}
if ($infrastructure) {
    $realStartUiTaskText=(Get-FunctionAst $script:CoreAst 'Start-UiTask').Extent.Text -replace '^function Start-UiTask','function Invoke-RealStartUiTask'
    . ([scriptblock]::Create($realStartUiTaskText))
    Spy-Function 'Get-DomeniaWorkerOperationHashes'
    $realGetHashes=$script:Spy['Get-DomeniaWorkerOperationHashes']
    function Get-DomeniaWorkerOperationHashes { [CmdletBinding()] param($Registry)
        $h=& $realGetHashes
        if ((($null -ne $h)) -and ((($h -is [System.Collections.IDictionary])))) {
            foreach($op in @('UnknownRead','LocalIndexRead','ParkSharedSync')) { if (-not $h.Contains($op)) { $h[$op]=('0'*64) } }
        }
        return $h
    }
    Spy-Function 'Assert-DomeniaWorkerOperationCode'
    $realAssertCode=$script:Spy['Assert-DomeniaWorkerOperationCode']
    function Assert-DomeniaWorkerOperationCode { [CmdletBinding()] param($OperationId,$Code)
        if ((($Code -eq 'x')) -or ((@('UnknownRead','LocalIndexRead','ParkSharedSync','WriteAccountDisabled','WriteCreateOu') -contains $OperationId))) { return 'test-hash' }
        return & $realAssertCode -OperationId $OperationId -Code $Code
    }
}
foreach($name in @('Start-UiTask','Set-ControlsBusy','Get-DomeniaControl','Set-DomeniaControlText','Write-DomeniaAtomicText','Show-ErrorBox','Show-InfoBox','Show-DomeniaOperationError','Apply-CurrentPermissionUi','Initialize-AsyncEngine','Initialize-DomeniaEngineState','Get-CfgValue','Confirm-Action','Assert-DomeniaCapability','Get-AllWriteControlNames','Assert-DomeniaWorkerRegistry','Get-WMachineCredential','Set-WReceiptStage','Get-DomeniaErrorDecision','Get-DomeniaCancelStatusText','Get-DomeniaOperationCredentialNeeds','Get-DomeniaRetryCredential','Set-DomeniaRetryWorkerContext','Get-DomeniaAccessScope','Get-DomeniaOperationResource','Initialize-DomeniaWorkerContextCache','Test-DomeniaSchedulerEnabled','Add-DomeniaUiLog','Write-AppLog','Set-Status','Update-TaskUi','Request-UiTaskStop','Complete-DomeniaDetachedReadJobs','Show-DomeniaGuard','Start-DomeniaReceiptRefresh','Invoke-DomeniaUiTaskDispatch','Invoke-DomeniaReceiptChoice','Restart-Computer','Invoke-WRemoteTaskScript','Test-DomeniaActualCapabilityDenied','Set-DomeniaActualCapabilityDenied','Get-DomeniaCapabilityDenialKey','Complete-DomeniaWriteTaskUi','Fail-DomeniaWriteTaskUi')) { Spy-Function $name }
if (-not (Get-Command Get-DomeniaFeatureFlag -ErrorAction SilentlyContinue)) { function Get-DomeniaFeatureFlag {param($Name,$Default=$true); return $Default} }
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level) if ($null -eq $script:StatusLog) { $script:StatusLog=[Collections.Generic.List[string]]::new() }; $script:StatusLog.Add([string]$Text) }
function Get-CfgValue {param($Section,$Name,$Default); return $Default}
function Show-ErrorBox {param($Message) if ($null -eq $script:Dialogs) { $script:Dialogs=[Collections.Generic.List[string]]::new() }; $script:Dialogs.Add('ERREUR '+[string]$Message) }
function Show-InfoBox {param($Message,$Details) if ($null -eq $script:Dialogs) { $script:Dialogs=[Collections.Generic.List[string]]::new() }; $script:Dialogs.Add('INFO '+[string]$Message) }
function Show-DomeniaOperationError {param($Operation,$ErrorRecordOrException,$CorrelationId,[switch]$NoPopup) if ($null -eq $script:Dialogs) { $script:Dialogs=[Collections.Generic.List[string]]::new() }; $script:Dialogs.Add('OPERATION '+[string]$ErrorRecordOrException) }
function Apply-CurrentPermissionUi {}
function Initialize-DomeniaEngineState {}
function Initialize-AsyncEngine { if ($script:AllowAsyncEngine) { return }; throw 'SENTINEL_ENGINE' }
function Assert-DomeniaWorkerRegistry {param($Registry) }
function Assert-DomeniaCapability {param($Capability) }
function Get-AllWriteControlNames {return @()}
function Confirm-Action {param($Message,$Title='') if ($null -eq $script:ConfirmCalls) { $script:ConfirmCalls=0 }; $script:ConfirmCalls++; return $true }
$script:DefaultConfirmAction = (Get-Command Confirm-Action -CommandType Function).ScriptBlock
function Complete-DomeniaWriteTaskUi {param($Output,$State) if ($null -eq $script:CompletedWrites) { $script:CompletedWrites=0 }; $script:CompletedWrites++ }
function Fail-DomeniaWriteTaskUi {param($Message,$State) if ($null -eq $script:FailedWrites) { $script:FailedWrites=0 }; $script:FailedWrites++ }
function Test-DomeniaActualCapabilityDenied {param($Dn,$Capability); return $false}
function Set-DomeniaActualCapabilityDenied {param($Dn,$Capability,$Message)}
function Get-DomeniaCapabilityDenialKey {param($Dn,$Capability); return ''}
function Get-DomeniaControl {param([string]$Name) if ((($null -ne $script:Ctrl)) -and ((($script:Ctrl.ContainsKey($Name))))) { return $script:Ctrl[$Name] }; if ((($Name -eq 'BtnTestWrite')) -and ((($null -ne $script:TestButton)))) { return $script:TestButton }; return $null }
function Set-DomeniaControlText {param($Name,$Text,[switch]$Silent); return $true}
function Write-DomeniaAtomicText {param($Path,$Text,$Encoding=''); return $true}
function Set-ControlsBusy { param($Names,$Busy) if ($null -eq $Names) { return }; foreach($name in @($Names)) { if ($null -eq $name) { continue }; $ctrl=Get-DomeniaControl ([string]$name); if ($null -ne $ctrl) { $ctrl.IsEnabled=[bool]$Busy } } }
function Get-WMachineCredential {param($Context) if ($null -ne $Context) { return $Context.MachineCredential }; return $null }
function Restart-Computer { param([string]$ComputerName,[bool]$Force,[string]$ErrorAction,[object]$Credential) if ($null -eq $script:RestartCalls) { $script:RestartCalls=0 }; $script:RestartCalls++; if ($script:D094ReceiptRoot) { $script:D094ReceiptSeenBeforeSend = (@(Get-ChildItem -LiteralPath $script:D094ReceiptRoot -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -gt 0) } }
function Invoke-WRemoteTaskScript { param($Context,$Computer,$Local,$Payload,$TimeoutSeconds,$Err) return [pscustomobject]@{Message='Fallback simule';Transport='TaskFallback';Delivered=$true} }
function Get-DomeniaErrorDecision {param($Structured,$Text); return [pscustomobject]@{Category='Other'}}
function Get-DomeniaCancelStatusText {param($Name,$State,[bool]$IsWrite); return $Name}
function Get-DomeniaOperationCredentialNeeds {param($OperationId); return [pscustomobject]@{Directory=$false;DirectoryBreaker=$false;Resource=''}}
function Get-DomeniaRetryCredential {param($OperationId); return $null}
function Set-DomeniaRetryWorkerContext {param($Context,$OperationId); return $Context}
function Get-DomeniaAccessScope {param($OperationId); return 'Remote'}
function Get-DomeniaOperationResource {param($OperationId); return ''}
function Initialize-DomeniaWorkerContextCache {}
function Test-DomeniaSchedulerEnabled {return $false}
function Add-DomeniaUiLog {param($Area,$Level,$Text)}
function Update-TaskUi {param([switch]$Force)}
function Request-UiTaskStop {param([string]$Id,[switch]$Silent,[switch]$Force,[switch]$Superseded,[string]$Reason='')}
function Complete-DomeniaDetachedReadJobs {}
function Show-DomeniaGuard {}
function Start-DomeniaReceiptRefresh { if ($null -eq $script:ReceiptRefreshCalls) { $script:ReceiptRefreshCalls=0 }; $script:ReceiptRefreshCalls++; $script:ReceiptRefreshNeeded=$false; $script:ReceiptReady=$true }
function Invoke-DomeniaUiTaskDispatch {param($Job); return $true}
function Invoke-DomeniaReceiptChoice {param($Kind)}
function Set-WReceiptStage { [CmdletBinding()] param([string]$Stage)
    if ($null -eq $script:ReceiptRecord) { return }
    $script:ReceiptRecord.Stage=[string]$Stage
    $script:ReceiptRecord.UpdatedUtc=[datetime]::UtcNow.ToString('o')
    $root=[string]$script:ReceiptRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root=[string]$script:D094ReceiptRoot }
    if ([string]::IsNullOrWhiteSpace($root)) { return }
    $path=Join-Path $root ([string]$script:ReceiptRecord.Id+'.json')
    if ([IO.File]::Exists($path)) {
        $json=$script:ReceiptRecord|ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($path,$json,[Text.Encoding]::Unicode)
    }
}
function Get-DomeniaCurrentSelectionIdentity { return $script:FakeIdentity }
function Get-DomeniaOriginalValue { param($Name); return '512' }
function Get-DomeniaSafetyDescriptor { return [pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000';Dn='CN=Demo User,OU=Users,DC=example,DC=invalid'} }
function Get-DomeniaDirectoryBindUser { return 'EXAMPLE\opdemo' }
function New-TestIdentity {
    param(
        [string]$Dn='CN=Demo User,OU=Users,DC=example,DC=invalid',
        [string]$Name='Demo User',
        [string]$Type='Utilisateur'
    )
    return New-DomeniaSelectionIdentity -Row ([pscustomobject]@{Guid=[guid]::NewGuid().ToString();Type=$Type;DN=$Dn;Name=$Name}) -Domain 'example.invalid' -Reader 'r' -Epoch 1 -Generation 1
}
function New-TestChange {
    param(
        [string]$Attribute='description',
        [string]$Kind='Replace',
        [string]$Before='',
        [string]$After='x'
    )
    return [pscustomobject]@{Attribute=$Attribute;Kind=$Kind;Before=$Before;After=$After}
}
function New-TestPlan {
    param(
        [string]$OperationId='WriteTest',
        $Target=$null,
        [object[]]$Changes=@(),
        [string]$Server='dc01.example.invalid',
        [string]$Account='EXAMPLE\opdemo'
    )
    if ($null -eq $Target) { $Target = $script:FakeIdentity }
    return New-DomeniaInterventionPlan -OperationId $OperationId -Target $Target -Server $Server -Account $Account -Changes $Changes -Effects @() -Simulation $false
}
function New-FixtureWindowStub {
    $w=[pscustomobject]@{IsActive=$false}
    $dispatcher=[pscustomobject]@{}
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name Invoke -Value {param($Action) if ($null -ne $Action) { & $Action }}
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name BeginInvoke -Value {param($Action) if ($null -ne $Action) { & $Action }}
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name InvokeAsync -Value {param($Action) if ($null -ne $Action) { & $Action }}
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name CheckAccess -Value { return $true }
    Add-Member -InputObject $dispatcher -MemberType ScriptMethod -Name VerifyAccess -Value {}
    $content=[pscustomobject]@{}
    Add-Member -InputObject $content -MemberType ScriptMethod -Name FindName -Value {param($Name) return $null}
    Add-Member -InputObject $content -MemberType NoteProperty -Name Dispatcher -Value $dispatcher
    Add-Member -InputObject $content -MemberType NoteProperty -Name IsEnabled -Value $true
    Add-Member -InputObject $w -MemberType ScriptMethod -Name Add_Closed -Value {param($Handler)}
    Add-Member -InputObject $w -MemberType ScriptMethod -Name Close -Value {}
    Add-Member -InputObject $w -MemberType ScriptMethod -Name Activate -Value {}
    Add-Member -InputObject $w -MemberType ScriptMethod -Name FindName -Value {param($Name) return $null}
    Add-Member -InputObject $w -MemberType NoteProperty -Name Dispatcher -Value $dispatcher
    Add-Member -InputObject $w -MemberType NoteProperty -Name Content -Value $content
    Add-Member -InputObject $w -MemberType NoteProperty -Name Tag -Value $null
    Add-Member -InputObject $w -MemberType NoteProperty -Name Title -Value ''
    Add-Member -InputObject $w -MemberType NoteProperty -Name Name -Value 'Fixture'
    Add-Member -InputObject $w -MemberType NoteProperty -Name IsVisible -Value $false
    Add-Member -InputObject $w -MemberType NoteProperty -Name IsLoaded -Value $true
    Add-Member -InputObject $w -MemberType NoteProperty -Name Owner -Value $null
    Add-Member -InputObject $w -MemberType NoteProperty -Name IsEnabled -Value $true
    return $w
}
function Reset-WiringFixture {
    $script:StatusLog=[Collections.Generic.List[string]]::new()
    $script:Dialogs=[Collections.Generic.List[string]]::new()
    $script:ConfirmCalls=0
    $script:StartUiTaskCalls=0
    $script:WriteStartUiTaskCalls=0
    $script:CompletedWrites=0
    $script:FailedWrites=0
    $script:ReceiptRefreshCalls=0
    $script:UseDoubleStartUiTask=$true
    $script:SubmittedWritePlans=@{}
    $script:AsyncJobs=@{}
    $script:DetachedReadJobs=@()
    $script:ReceiptRows=@()
    $script:ReceiptReady=$true
    $script:ReceiptPending=0
    $script:ReceiptRefreshNeeded=$false
    $script:ActiveWriteTaskId=''
    $script:WriteState='Idle'
    $script:Continuity=[pscustomobject]@{Mutation=0}
    $script:Ctrl=@{}
    $script:TestButton=$null
    $script:SessionEpoch=1L
    $script:SelectedObjectGeneration=1L
    $script:AsyncEngineClosing=$false
    $script:ReadOnlyMode=$false
    $script:AllowAsyncEngine=$false
    $script:CurrentCapabilities=@{}
    $script:ActualDeniedCapabilities=@{}
    $script:DirectoryCredentialFaulted=$false
    $script:DirectoryCredentialFaultMessage=''
    $script:SecretsCredential=$null
    $script:MachineCredential=$null
    $script:RemoteAdminCredential=$null
    $script:ReceiptRoot=''
    $script:D094ReceiptRoot=''
    $script:D094ReceiptSeenBeforeSend=$false
    $script:RestartCalls=0
    $script:LatestTaskId=''
    $script:Guard=$null
    $script:AccessState=$null
    $script:Persistence=$null
    $script:ArtifactConsent=$null
    $script:DraftState=$null
    $script:Live=$null
    $script:AccessCurrentJob=$null
    $script:DemoMode=$false
    $script:Window=New-FixtureWindowStub
    $script:Conn = [ordered]@{
        Server='dc01.example.invalid'
        BaseDn='DC=example,DC=invalid'
        Domain='example.invalid'
        Netbios='EXAMPLE'
        BindUser='EXAMPLE\opdemo'
        Credential=$null
        UseCredential=$false
        AuthMode='Windows'
    }
    $script:SelectedObject=[pscustomobject]@{Type='Machine';DN='CN=PC-DEMO-01,OU=Postes,DC=example,DC=invalid';Safety=[pscustomobject]@{Guid=''}}
    $script:WorkerContextStatic=[pscustomobject]@{AdModuleSources=@();AdRequiredCommands=@();AdTypeNames=@();AdManagementHash='';AdResourceHash='';MissingCriticalFunctions=@();MissingCriticalControls=@();CriticalFunctionCount=0;CriticalControlCount=0;PowerShellVersion='test';IsSta=$true}
    $script:FakeIdentity = New-TestIdentity
    $script:OtherFakeIdentity = New-TestIdentity -Name 'Other User' -Dn 'CN=Other User,OU=Users,DC=example,DC=invalid'
    $script:SelectedBranchDn = ''
    $script:LastStartWritePlan = $null
    $script:LastStartWritePlanChanges = $null
    $script:LastStartWriteBranchDn = ''
    $script:StartUiTaskPayloads = [Collections.Generic.List[object]]::new()
    Set-Item function:script:Confirm-Action -Value $script:DefaultConfirmAction
}
function New-WriteEnvelopeScript {
    param([string]$Business)
    # Same composition as New-DomeniaWorkerRunspace -IsWrite (and Test-DomeniaFaults): Sent is written right before dispatch,
    # then try { envelope start, business body, envelope end } followed by the marker catch.
    if ($script:EnvelopeMarker.Count -ne 1) { throw 'Enveloppe sans catch.' }
    $businessBody=$Business.Replace('$DomeniaWriteDispatched=$true',"Set-WReceiptStage 'Sent';`$DomeniaWriteDispatched=`$true")
    $body="try {`r`n"+$script:EnvelopeStart[0]+"`r`n"+$businessBody+"`r`n"+$script:EnvelopeEnd[0]+"`r`n}"+$script:EnvelopeMarker[0]
    $errorContract="function Get-DomeniaStructuredError {`r`n"+(Get-Command Get-DomeniaStructuredError -CommandType Function).Definition+"`r`n}"
    $definition='param($Context,$Payload)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$VerbosePreference = "SilentlyContinue"
$DebugPreference = "SilentlyContinue"
$InformationPreference = "SilentlyContinue"
' + $errorContract + "`r`n" + [string]$script:WorkerCommon + "`r`n" + $body
    return [scriptblock]::Create($definition)
}
function New-WriteContext {param([string]$ReceiptRoot,[string]$OperationId='WriteTest',[string]$Server='dc1.example.invalid')
    return [pscustomobject]@{ReceiptRoot=$ReceiptRoot;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Server=$Server;OperationId=$OperationId;Credential=$null;MachineCredential=$null;UseCredential=$false;BindUser='EXAMPLE\lecteur';ProcessIdentity='S-1-5-21-TEST';UseCim=$true;TaskFallbackTimeoutSeconds=15;PortTimeoutMs=1200}
}
function Get-ReceiptRecords {param([string]$Root)
    if ($null -eq $Root) { return @() }
    if (-not [IO.Directory]::Exists($Root)) { return @() }
    return @([IO.Directory]::EnumerateFiles($Root,'*.json')|ForEach-Object{[IO.File]::ReadAllText($_)|ConvertFrom-Json})
}
function Start-UiTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z][A-Za-z0-9]{2,63}$')][string]$OperationId,
        [Parameter(Mandatory=$true)][string]$Code,
        $Payload = $null,
        [scriptblock]$OnSuccess = $null,
        [scriptblock]$OnError = $null,
        [string]$SuccessHandler = "",
        [string]$ErrorHandler = "",
        [string[]]$DisableControls = @(),
        [string]$ReplaceKey = "",
        [int]$TimeoutSeconds = 0,
        [int]$HardTimeoutSeconds = 0,
        [string]$StatusText = "",
        [switch]$IsWrite,
        [switch]$NonCancellable,
        [string]$CorrelationId = "",
        $CallbackState = $null,
        [ValidateSet('','Explicit','Selection','Background')][string]$TaskClass = "",
        [string]$ReaderIdentity = "",
        [long]$Generation = 0
    )
    if ($script:UseDoubleStartUiTask) {
        if ($null -eq $script:StartUiTaskCalls) { $script:StartUiTaskCalls=0 }
        if ($null -eq $script:WriteStartUiTaskCalls) { $script:WriteStartUiTaskCalls=0 }
        if ($null -eq $script:StartUiTaskPayloads) { $script:StartUiTaskPayloads=[Collections.Generic.List[object]]::new() }
        $script:StartUiTaskCalls++
        if ([bool]$IsWrite) { $script:WriteStartUiTaskCalls++ }
        if ($null -ne $Payload) {
            $copy=[pscustomobject]@{}
            foreach($p in @($Payload.PSObject.Properties)) {
                $copy | Add-Member -MemberType NoteProperty -Name ([string]$p.Name) -Value $p.Value -Force | Out-Null
            }
            $script:StartUiTaskPayloads.Add($copy)
        } else {
            $script:StartUiTaskPayloads.Add($null)
        }
        Set-ControlsBusy -Names $DisableControls -Busy $true
        $id='w'+[string]$script:StartUiTaskCalls
        $script:LatestTaskId=$id
        return $id
    }
    Invoke-RealStartUiTask -Name $Name -OperationId $OperationId -Code $Code -Payload $Payload -OnSuccess $OnSuccess -OnError $OnError -SuccessHandler $SuccessHandler -ErrorHandler $ErrorHandler -DisableControls $DisableControls -ReplaceKey $ReplaceKey -TimeoutSeconds $TimeoutSeconds -HardTimeoutSeconds $HardTimeoutSeconds -StatusText $StatusText -IsWrite:$IsWrite -NonCancellable:$NonCancellable -CorrelationId $CorrelationId -CallbackState $CallbackState -TaskClass $TaskClass -ReaderIdentity $ReaderIdentity -Generation $Generation
}
Spy-Function 'Start-DomeniaWriteTask'
$realStartWriteTask = $script:Spy['Start-DomeniaWriteTask']
function Start-DomeniaWriteTask {
    [CmdletBinding()]
    param(
        $Name,
        $OperationId,
        $Code,
        $Payload,
        $PlanFingerprint,
        $Capability,
        $DisableControls,
        $AfterSuccessAction,
        $AfterSuccessState,
        $TimeoutSeconds,
        $Plan,
        $PlanChanges,
        $BranchDn
    )
    if ($null -eq $realStartWriteTask) { throw 'Start-DomeniaWriteTask reel absent.' }
    $script:LastStartWritePlan = $Plan
    $script:LastStartWritePlanChanges = $PlanChanges
    $script:LastStartWriteBranchDn = [string]$BranchDn
    $bound = @{}
    foreach($key in $PSBoundParameters.Keys) { $bound[$key] = $PSBoundParameters[$key] }
    return & $realStartWriteTask @bound
}
if ($infrastructure) {
    Test-Case 'D094 Restart : recu ecrit avant l envoi' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$false
        $receiptRoot=Join-Path $temp ('d094-'+[guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($receiptRoot)
        $script:ReceiptRoot=$receiptRoot
        $script:D094ReceiptRoot=$receiptRoot
        $body=Get-PinnedBody 'ComputerRestart'
        $worker=New-WriteEnvelopeScript -Business $body
        $context=New-WriteContext -ReceiptRoot $receiptRoot -OperationId 'ComputerRestart'
        $correlation=[guid]::NewGuid().ToString('N')
        $payload=[pscustomobject]@{Computer='pc-demo-01';Target='pc-demo-01';DN='CN=PC-DEMO-01,OU=Postes,DC=example,DC=invalid';CorrelationId=$correlation;PlanFingerprint=''}
        $failure=''
        try { [void](& $worker $context $payload) } catch { $failure=$_.Exception.Message }
        Assert-True ($failure -eq '') ('Enveloppe en echec : '+$failure)
        Assert-True ([bool]$script:D094ReceiptSeenBeforeSend) 'Aucun recu ecrit avant Restart-Computer.'
        $records=@(Get-ReceiptRecords $receiptRoot)
        Assert-True ($records.Count -eq 1) ('Nombre de recus : '+$records.Count)
        Assert-True ($records[0].Stage -in @('Delivered','Verified')) ('Stage final : '+$records[0].Stage)
    }
    Test-Case 'D094 Start-UiTask refuse ComputerRestart sans -IsWrite' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$false
        $err=''
        try { [void](Start-UiTask -Name 'Restart' -OperationId 'ComputerRestart' -Code 'x' -Payload ([pscustomobject]@{Computer='pc'})) } catch { $err=$_.Exception.Message }
        Assert-True ($err -match 'durable requis') ('Message : '+$err)
    }
    Test-Case 'D094 operation inconnue sans -IsWrite non refusee par le garde recu' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$false
        $err=''
        try { [void](Start-UiTask -Name 'Unknown' -OperationId 'UnknownRead' -Code 'x' -Payload ([pscustomobject]@{})) } catch { $err=$_.Exception.Message }
        Assert-True ($err -notmatch 'durable requis') ('Message : '+$err)
        Assert-True ($err -match 'SENTINEL_ENGINE') ('Message : '+$err)
    }
    Test-Case 'D095 double clic = une seule demande' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $changes = @(New-TestChange)
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        $payload=[pscustomobject]@{DN=$identity.DN}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True ($script:StartUiTaskPayloads.Count -eq 1) ('Payloads Start-UiTask : '+$script:StartUiTaskPayloads.Count)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('un seul envoi') }).Count -ge 1) 'Refus d admission absent.'
    }
    Test-Case 'D095 demande identique incertaine refusee' {
        Reset-WiringFixture
        $fp=[guid]::NewGuid().ToString('N').ToUpperInvariant()
        $receipt=[pscustomobject]@{Format=1;Id='0123456789abcdef0123456789abcdef';Operation='WriteTest';Domain='dc=example,dc=invalid';Stage='Unknown';CreatedUtc=(Get-Date).ToString('o');UpdatedUtc=(Get-Date).ToString('o');PlanFingerprint=$fp}
        $admission=Test-DomeniaWriteAdmission -Fingerprint $fp -Submitted ([hashtable]@{}) -Receipts @($receipt) -Origin Operator -CheckOnly
        Assert-True (-not [bool]$admission.Admit) 'Admission acceptee.'
        Assert-True (([string]$admission.Reason) -match 'aucun nouvel envoi avant') ('Motif : '+[string]$admission.Reason)
    }
    Test-Case 'D095 NotSent peut etre refaite' {
        Reset-WiringFixture
        $fp=[guid]::NewGuid().ToString('N').ToUpperInvariant()
        $receipt=[pscustomobject]@{Format=1;Id='0123456789abcdef0123456789abcdef';Operation='WriteTest';Domain='dc=example,dc=invalid';Stage='NotSent';CreatedUtc=(Get-Date).ToString('o');UpdatedUtc=(Get-Date).ToString('o');PlanFingerprint=$fp}
        $admission=Test-DomeniaWriteAdmission -Fingerprint $fp -Submitted ([hashtable]@{}) -Receipts @($receipt) -Origin Operator -CheckOnly
        Assert-True ([bool]$admission.Admit) ('Refus : '+[string]$admission.Reason)
    }
    Test-Case 'D095 Delivered terminal non bloquant' {
        Reset-WiringFixture
        $fp=[guid]::NewGuid().ToString('N').ToUpperInvariant()
        $receipt=[pscustomobject]@{Format=1;Id='0123456789abcdef0123456789abcdef';Operation='ComputerRestart';Domain='dc=example,dc=invalid';Stage='Delivered';CreatedUtc=(Get-Date).ToString('o');UpdatedUtc=(Get-Date).ToString('o');PlanFingerprint=$fp}
        $resume=Get-DomeniaReceiptResumeState $receipt
        Assert-True ($resume.State -eq 'Delivered') ('Etat : '+$resume.State)
        Assert-True (-not [bool]$resume.Uncertain) 'Delivered incertain.'
        Assert-True (-not [bool]$resume.BlocksTarget) 'Delivered bloque la cible.'
        $registry=New-DomeniaWriteRegistry @($receipt)
        Assert-True ($registry.Entries.ContainsKey($fp)) 'Empreinte absente du registre.'
        Assert-True ($registry.Entries[$fp].State -eq 'Delivered') ('Etat registre : '+$registry.Entries[$fp].State)
        $admission=Test-DomeniaWriteAdmission -Fingerprint $fp -Submitted ([hashtable]@{}) -Receipts @($receipt) -Origin Operator -CheckOnly
        Assert-True (-not [bool]$admission.Admit) 'Delivered doit refuser le renvoi de la meme empreinte.'
    }
    Test-Case 'D091 ecriture annuaire sans plan refusee' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid'}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('Aucun plan confirme') }).Count -ge 1) 'Refus sans plan absent.'
    }
    Test-Case 'D091 plan valide envoye une fois avec son empreinte' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $changes = @(New-TestChange)
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        $payload=[pscustomobject]@{DN=$identity.DN}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True ($script:StartUiTaskPayloads.Count -eq 1) ('Payloads Start-UiTask : '+$script:StartUiTaskPayloads.Count)
        Assert-True ($script:LastStartWritePlan -is [Domenia.InterventionPlan]) '-Plan absent.'
        $payloadSent = $script:StartUiTaskPayloads[0]
        Assert-True ($null -ne $payloadSent.PSObject.Properties['PlanFingerprint']) 'PlanFingerprint absent du payload.'
        Assert-True ([string]$payloadSent.PlanFingerprint -ceq $plan.Fingerprint.ToUpperInvariant()) ('Empreinte payload : '+[string]$payloadSent.PlanFingerprint)
    }
    Test-Case 'D091 cible changee pendant la confirmation refusee' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $other = $script:OtherFakeIdentity
        $changes = @(New-TestChange)
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        $script:FakeIdentity = $other
        $payload=[pscustomobject]@{DN=$identity.DN}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('La cible a chang') }).Count -ge 1) 'Refus cible changee absent.'
    }
    Test-Case 'D091 valeurs modifiees refusees' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $planChanges = @(New-TestChange -After 'x')
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $planChanges
        $otherChanges = @(New-TestChange -After 'y')
        $payload=[pscustomobject]@{DN=$identity.DN}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $otherChanges -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs).Count -ge 1) 'Refus valeurs modifiees absent.'
    }
    Test-Case 'D091 payload sur un autre DN refuse' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $changes = @(New-TestChange)
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        $payload=[pscustomobject]@{DN='CN=Other User,OU=Users,DC=example,DC=invalid'}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('ne designe pas la cible confirmee') }).Count -ge 1) 'Refus payload DN absent.'
    }
    Test-Case 'D091 destinataire change refuse' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $changes = @(New-TestChange)
        $plan = New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        $script:Conn['Server'] = 'dc02.example.invalid'
        $payload=[pscustomobject]@{DN=$identity.DN}
        [void](Start-DomeniaWriteTask -Name 'Test' -OperationId 'WriteTest' -Code 'x' -Payload $payload -Plan $plan -PlanChanges $changes -DisableControls @('BtnTestWrite'))
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs).Count -ge 1) 'Refus destinataire absent.'
    }
    Test-Case 'D091 site complet : selection changee pendant Confirm-Action' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $script:OtherFakeIdentity = New-TestIdentity -Name 'Other User' -Dn 'CN=Other User,OU=Users,DC=example,DC=invalid'
        $script:SelectedObject = [pscustomobject]@{Type='Utilisateur';DN=$identity.DN}
        $script:FakeIdentity = $identity
        $toggle = {
            param($Message,$Title='')
            $script:ConfirmCalls++
            $script:FakeIdentity = $script:OtherFakeIdentity
            return $true
        }
        Set-Item function:script:Confirm-Action -Value $toggle
        [void](Set-AccountDisabled -Disabled $true)
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True ($script:StartUiTaskPayloads.Count -eq 0) ('Payloads emis : '+$script:StartUiTaskPayloads.Count)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('La cible a chang') }).Count -ge 1) 'Refus cible changee absent.'
    }
    Test-Case 'D091 site complet : selection stable envoyee sur le DN du plan' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity = $script:FakeIdentity
        $script:SelectedObject = [pscustomobject]@{Type='Utilisateur';DN=$identity.DN}
        $script:FakeIdentity = $identity
        [void](Set-AccountDisabled -Disabled $true)
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Appels Start-UiTask : '+$script:StartUiTaskCalls)
        Assert-True ($script:StartUiTaskPayloads.Count -eq 1) ('Payloads emis : '+$script:StartUiTaskPayloads.Count)
        Assert-True ($script:LastStartWritePlan -is [Domenia.InterventionPlan]) '-Plan absent.'
        Assert-True ($script:LastStartWritePlan.Target.DN -ceq $identity.DN) ('DN plan : '+[string]$script:LastStartWritePlan.Target.DN)
        Assert-True ([string]$script:StartUiTaskPayloads[0].DN -ceq $identity.DN) ('DN payload : '+[string]$script:StartUiTaskPayloads[0].DN)
    }
    Test-Case 'D091 creation d OU : branche changee refusee, branche stable acceptee' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $branch='OU=Target,DC=example,DC=invalid'
        $script:SelectedBranchDn='OU=Other,DC=example,DC=invalid'
        $payload=[pscustomobject]@{ParentDn=$branch;Name='TestOu';DN=$branch}
        [void](Start-DomeniaWriteTask -Name 'Creation OU' -OperationId 'WriteCreateOu' -Code 'x' -Payload $payload -BranchDn $branch -Capability 'Create' -DisableControls @('BtnCreateOu') -AfterSuccessAction 'CreateOu')
        Assert-True ($script:StartUiTaskCalls -eq 0) ('Appels branche changee : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs | Where-Object { $_.Contains('La branche cible a change') }).Count -ge 1) 'Refus branche changee absent.'
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $script:SelectedBranchDn=$branch
        $payload=[pscustomobject]@{ParentDn=$branch;Name='TestOu';DN=$branch}
        [void](Start-DomeniaWriteTask -Name 'Creation OU' -OperationId 'WriteCreateOu' -Code 'x' -Payload $payload -BranchDn $branch -Capability 'Create' -DisableControls @('BtnCreateOu') -AfterSuccessAction 'CreateOu')
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Appels branche stable : '+$script:StartUiTaskCalls)
        Assert-True ($script:StartUiTaskPayloads.Count -eq 1) ('Payloads branche stable : '+$script:StartUiTaskPayloads.Count)
        Assert-True ($script:LastStartWritePlan -eq $null) 'Un plan etait passe pour WriteCreateOu.'
        Assert-True ($script:LastStartWriteBranchDn -ceq $branch) ('BranchDn : '+$script:LastStartWriteBranchDn)
        Assert-True ([string]$script:StartUiTaskPayloads[0].ParentDn -ceq $branch) ('ParentDn payload : '+[string]$script:StartUiTaskPayloads[0].ParentDn)
    }
    Test-Case 'D091 confirmation affiche cible, destinataire, compte et empreinte, sans secret' {
        Reset-WiringFixture
        $identity = New-TestIdentity
        $change = [pscustomobject]@{Attribute='unicodePwd';Kind='Reset';Before='';After='MotDePasse!123'}
        $plan = New-TestPlan -OperationId 'WriteResetPassword' -Target $identity -Changes @($change)
        $text = Format-DomeniaPlanConfirmation -Plan $plan
        Assert-True ($text.Contains($identity.DN)) 'DN absent de la confirmation.'
        Assert-True ($text.Contains('dc01.example.invalid')) 'Destinataire absent de la confirmation.'
        Assert-True ($text.Contains('EXAMPLE\opdemo')) 'Compte absent de la confirmation.'
        $fp12 = $plan.Fingerprint.Substring(0,12)
        Assert-True ($text.Contains('Empreinte du plan : ' + $fp12)) 'Empreinte absente de la confirmation.'
        Assert-True (-not $text.Contains('MotDePasse!123')) 'Secret present dans la confirmation.'
    }
    Test-Case 'Lecture seule bloque Restart' {
        Reset-WiringFixture
        $script:ReadOnlyMode=$true
        $script:AllowAsyncEngine=$true
        $thrown=$false
        $err=''
        try { Assert-WriteAllowed } catch { $thrown=$true; $err=$_.Exception.Message }
        Assert-True $thrown ('Aucun blocage en lecture seule : '+$err)
    }
}
$passed=@($script:Checks | Where-Object { $_.Status -eq 'Passed' }).Count
$failed=@($script:Checks | Where-Object { $_.Status -eq 'Failed' }).Count
$report=[pscustomobject]@{Passed=$passed;Failed=$failed;Tests=$script:Checks}
if($ReportPath){
    $dir=Split-Path -Parent $ReportPath
    if($dir){[void][IO.Directory]::CreateDirectory($dir)}
    [IO.File]::WriteAllText($ReportPath, ($report|ConvertTo-Json -Depth 6))
}
if(-not $Quiet){ $report|ConvertTo-Json -Depth 6 }
try { if ([IO.Directory]::Exists($temp)) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
if ($failed -gt 0) { exit 1 }
