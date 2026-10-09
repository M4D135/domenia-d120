#requires -Version 5.1
<# D091/D094/D095/D096 wiring tests.
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
        # L07: Search (DN rules) and Shell (in-page request rules) are the providers of the shared write rules.
        foreach($m in @('Domenia-Common.Model.ps1','Domenia-Engine.Model.ps1','Domenia-Access.Model.ps1','Domenia-Search.Model.ps1','Domenia-Shell.Model.ps1','Domenia-Safety.Model.ps1')) { $p=Join-Path $modulesDir $m; if(Test-Path -LiteralPath $p){ . $p } }
        if (-not (Get-Command Get-DomeniaReceiptRequirement -ErrorAction SilentlyContinue)) { foreach($p in @(Get-ChildItem -LiteralPath $modulesDir -Filter '*.Model.ps1' -File | ForEach-Object{$_.FullName})) { . $p } }
        # The real in-page confirmation: without the main window it answers through Confirm-Action / Confirm-TextAction.
        . (Join-Path $modulesDir 'Domenia-Inline.UI.ps1')
    }
    if (-not (Get-Command Protect-DomeniaSecretText -ErrorAction SilentlyContinue)) { function Protect-DomeniaSecretText {param($Text); return [string]$Text} }
    if (-not (Get-Command Test-DomeniaSecretAttribute -ErrorAction SilentlyContinue)) { function Test-DomeniaSecretAttribute {param($Attribute); return $false} }
    foreach($rule in @('Get-DomeniaMember','Get-DomeniaOperationEffect','Get-DomeniaReceiptRequirement','Get-DomeniaReceiptResumeState','New-DomeniaWriteRegistry','Test-DomeniaWriteAdmission','Get-DomeniaPostconditionRule','Resolve-DomeniaPostcondition')) { if (-not (Get-Command $rule -ErrorAction SilentlyContinue)) { throw ('Regles absente : '+$rule) } }
    foreach($fn in @('New-DomeniaInterventionPlan','Test-DomeniaPlanStillValid','ConvertTo-DomeniaPlanChanges','Test-DomeniaPlanHasSecret','New-DomeniaSelectionIdentity')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction de regle absente : '+$fn) } }
    $script:CoreAst=Read-SourceAst (Join-Path $wad 'Domenia-Core.ps1')
    foreach($name in @('Get-WorkerContext','ConvertTo-DomeniaErrorInfo','Get-DomeniaStructuredError','Get-DomeniaWorkerOperationHashes','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Assert-DomeniaWorkerOperationCode','Assert-DomeniaWorkerRegistry','Start-UiTask','Start-DomeniaWriteTask','Set-ControlsBusy','Get-DomeniaControl','Set-DomeniaControlText','Write-DomeniaAtomicText','Assert-WriteAllowed','Assert-DomeniaRemoteWriteAllowed','Get-DomeniaWriteRoute','New-DomeniaSelectionWritePlan','Format-DomeniaPlanConfirmation','Test-DomeniaPlanDispatch','Set-AccountDisabled','Get-DomeniaWritePostcondition','Complete-DomeniaWriteTaskUi','Fail-DomeniaWriteTaskUi','Get-DomeniaEffectiveWorkerResult','Get-DomeniaAttributeWriteStrategy','Request-DomeniaWriteConfirmation','Get-DomeniaWriteLocks','Set-DomeniaWriteTaskOutcome','Get-DomeniaWriteCompensationText','Format-DomeniaOperationImpact','Request-DomeniaOperationImpact','Format-DomeniaByteEstimate','Get-DomeniaWorkerRulesCommon','AddOrRemoveObjectGroup','AddOrRemoveGroupMember','Set-OrClearRawAttribute','Start-DomeniaAttributeWrite','New-DomeniaAttributeChange')) { [void](Import-AstFunction $script:CoreAst $name -Optional) }
    foreach($fn in @('Start-UiTask','Start-DomeniaWriteTask','Set-ControlsBusy','Get-DomeniaControl','Get-DomeniaStructuredError','Assert-DomeniaWorkerOperationCode','ConvertTo-DomeniaCanonicalWorkerCode','Get-DomeniaWorkerCodeHash','Get-DomeniaWorkerOperationHashes','Assert-WriteAllowed','Get-DomeniaWriteRoute','New-DomeniaSelectionWritePlan','Format-DomeniaPlanConfirmation','Test-DomeniaPlanDispatch','Set-AccountDisabled')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction absente : '+$fn) } }
    $assignment=@($script:CoreAst.FindAll({param($n)((($n -is [Management.Automation.Language.AssignmentStatementAst])) -and ((($n.Left.Extent.Text -eq '$script:WorkerCommon')) -and (($n.Operator -eq [Management.Automation.Language.TokenKind]::Equals))))},$true))
    if($assignment.Count -ne 1){throw 'Code commun des workers introuvable.'}
    $literal=$assignment[0].Right.Find({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst]},$true)
    if ($null -eq $literal) { throw 'Code commun des workers introuvable.' }
    $ct=$null;$ce=$null;$commonAst=[Management.Automation.Language.Parser]::ParseInput([string]$literal.Value,[ref]$ct,[ref]$ce)
    if(@($ce).Count){throw 'Code commun des workers non analysable.'}
    $script:WorkerCommon=[string]$literal.Value
    foreach($fn in @($commonAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    # L07: the appended common blocks too (raw attribute guard, DN resolution, conditional modify), as the runspace has them.
    $appended=@($script:CoreAst.FindAll({param($n)((($n -is [Management.Automation.Language.AssignmentStatementAst])) -and ((($n.Left.Extent.Text -eq '$script:WorkerCommon')) -and (($n.Operator -eq [Management.Automation.Language.TokenKind]::PlusEquals))))},$true))
    foreach($block in $appended){
        $blockLiteral=$block.Right.Find({param($n)((($n -is [Management.Automation.Language.StringConstantExpressionAst])) -and (($n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString)))},$true)
        if ($null -eq $blockLiteral) { continue }
        $bt=$null;$be=$null;$blockAst=[Management.Automation.Language.Parser]::ParseInput([string]$blockLiteral.Value,[ref]$bt,[ref]$be)
        if(@($be).Count){throw 'Bloc commun ajoute non analysable.'}
        foreach($fn in @($blockAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))) { . ([scriptblock]::Create($fn.Extent.Text)) }
    }
    foreach($fn in @('Assert-WAttributeChangesAllowed','Test-WFormAttribute','Test-WRawAttributeAllowed','Resolve-WDirectoryIdentityDn')) { if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw ('Fonction commune absente : '+$fn) } }
    if (-not (Get-Command Invoke-WConditionalModify -ErrorAction SilentlyContinue)) {
        $fnAst=@($commonAst.FindAll({param($n)((($n -is [Management.Automation.Language.FunctionDefinitionAst])) -and (($n.Name -eq 'Invoke-WConditionalModify')))},$true))
        if ($fnAst.Count -eq 1) { . ([scriptblock]::Create($fnAst[0].Extent.Text)) }
    }
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
foreach($name in @('Get-DomeniaWritePostcondition','Get-DomeniaEffectiveWorkerResult','Get-DomeniaPostconditionRule','Resolve-DomeniaPostcondition')) { Spy-Function $name }
$script:RealCompleteWriteTaskUi=$null
$script:RealFailWriteTaskUi=$null
$script:RealGetWritePostcondition=$null
$cmd=Get-Command -Name 'Complete-DomeniaWriteTaskUi' -ErrorAction SilentlyContinue
if ($cmd) { $script:RealCompleteWriteTaskUi=$cmd.ScriptBlock }
$cmd=Get-Command -Name 'Fail-DomeniaWriteTaskUi' -ErrorAction SilentlyContinue
if ($cmd) { $script:RealFailWriteTaskUi=$cmd.ScriptBlock }
$cmd=Get-Command -Name 'Get-DomeniaWritePostcondition' -ErrorAction SilentlyContinue
if ($cmd) { $script:RealGetWritePostcondition=$cmd.ScriptBlock }
foreach($name in @('Get-DomeniaRemotePostconditionText','Complete-DomeniaComputerToolUi')) { [void](Import-AstFunction $script:CoreAst $name) }
if (-not (Get-Command Get-DomeniaFeatureFlag -ErrorAction SilentlyContinue)) { function Get-DomeniaFeatureFlag {param($Name,$Default=$true); return $Default} }
function Write-AppLog {param($Text,$Level)}
function Set-Status {param($Text,$Level) if ($null -eq $script:StatusLog) { $script:StatusLog=[Collections.Generic.List[string]]::new() }; $script:StatusLog.Add([string]$Text) }
function Get-CfgValue {param($Section,$Name,$Default); return $Default}
function Show-ErrorBox {param($Message,$Details) if ($null -eq $script:Dialogs) { $script:Dialogs=[Collections.Generic.List[string]]::new() }; $script:Dialogs.Add('ERREUR '+[string]$Message) }
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
function Confirm-TextAction {param($Message,$Expected,$Title='') if ($null -eq $script:TypedConfirmCalls) { $script:TypedConfirmCalls=[Collections.Generic.List[string]]::new() }; $script:TypedConfirmCalls.Add([string]$Expected); return [bool]$script:TypedConfirmAnswer }
# L07: the in-page confirmation is spied: what the panel would show (sentence, changes, technical details).
$script:RealRequestInline = (Get-Command Request-DomeniaInlineConfirmation -CommandType Function -ErrorAction SilentlyContinue).ScriptBlock
function Request-DomeniaInlineConfirmation { [CmdletBinding()] param($Title,$Message='',$Target='',$ConfirmText='Confirmer',$CancelText='Annuler',$OnConfirm=$null,$OnCancel=$null,$Risk='Normal',[string[]]$Changes=@(),$Details='',$DetailsTitle='Détails techniques',[switch]$DetailsExpertOnly,$TypedConfirmation='',$TypedPrompt='')
    if ($null -eq $script:InlineRequests) { $script:InlineRequests=[Collections.Generic.List[object]]::new() }
    $script:InlineRequests.Add([pscustomobject]@{Title=[string]$Title;Message=[string]$Message;Target=[string]$Target;ConfirmText=[string]$ConfirmText;Risk=[string]$Risk;Changes=@($Changes);Details=[string]$Details;DetailsExpertOnly=[bool]$DetailsExpertOnly;TypedConfirmation=[string]$TypedConfirmation})
    $bound=@{}; foreach($key in $PSBoundParameters.Keys) { $bound[$key]=$PSBoundParameters[$key] }
    return & $script:RealRequestInline @bound
}
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
$script:D093SavedFunctions=@{}
$script:D093Before=[pscustomobject]@{Classes=@('user');Guid='00000000-0000-0000-0000-000000000000';Lockout='0'}
$script:D093AttributeFirstValue='abc'
$script:D093MembershipCalls=0
$script:D093MembershipSecondThrows=$false
$script:D093GuidReadThrows=$false
$script:D093GuidReadException=$null
$script:D093PropertyNames=@()
$script:StatusLines=[Collections.Generic.List[string]]::new()
$script:InfoBoxes=[Collections.Generic.List[string]]::new()
function Begin-D093FunctionOverride {
    param([string]$Name)
    if ($null -eq $script:D093SavedFunctions) { $script:D093SavedFunctions=@{} }
    if (-not $script:D093SavedFunctions.ContainsKey($Name)) {
        $cmd=Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
        if ($null -ne $cmd) { $script:D093SavedFunctions[$Name]=$cmd.ScriptBlock } else { $script:D093SavedFunctions[$Name]=$null }
    }
}
function Set-D093Function {
    param([string]$Name,$Value)
    Begin-D093FunctionOverride -Name $Name
    Set-Item -Path ('function:script:'+$Name) -Value $Value
}
function End-D093FunctionOverrides {
    if ($null -ne $script:D093SavedFunctions) {
        foreach($name in @($script:D093SavedFunctions.Keys)) {
            $sb=$script:D093SavedFunctions[$name]
            if ($null -ne $sb) { Set-Item -Path ('function:script:'+$name) -Value $sb }
            else { Remove-Item -Path ('function:script:'+$name) -ErrorAction SilentlyContinue }
        }
        $script:D093SavedFunctions=@{}
    }
}
function New-D093PropertyValueCollection {
    $pvc=[pscustomobject]@{Value=$null}
    Add-Member -InputObject $pvc -MemberType ScriptMethod -Name Clear -Value { $this.Value=$null } -Force
    return $pvc
}
function Get-D093WorkerBody {
    param([string]$FunctionName)
    $fn=Get-FunctionAst $script:CoreAst $FunctionName
    $literals=@(Get-SingleQuotedLiterals $fn)
    if ($literals.Count -ne 1) { throw ('Here-string worker attendu unique pour '+$FunctionName+' ('+$literals.Count+')') }
    return [string]$literals[0].Value
}
function Invoke-D093WorkerBody {
    param([string]$FunctionName,$Context,$Payload)
    $body=Get-D093WorkerBody -FunctionName $FunctionName
    $sb=[scriptblock]::Create($body)
    & $sb
}
function Invoke-D096WorkerBody {
    param([string]$FunctionName,$Context,$Payload)
    $body=Get-D093WorkerBody -FunctionName $FunctionName
    $wrapper = {
        param($Context,$Payload)
        $DomeniaWriteDispatched=$false
        $err=''
        $errType=''
        $errHResult=0
        $out=$null
        try { $out = . ([scriptblock]::Create($body)) } catch { $err=$_.Exception.Message; $errType=$_.Exception.GetType().FullName; $errHResult=[int]$_.Exception.HResult }
        [pscustomobject]@{Output=$out;Error=$err;ErrorType=$errType;ErrorHResult=$errHResult;Dispatched=$DomeniaWriteDispatched}
    }
    & $wrapper $Context $Payload
}
function New-D093Context {
    param([string]$Server='dc01.example.invalid')
    return [pscustomobject]@{Server=$Server;BaseDn='DC=example,DC=invalid';Domain='example.invalid';Credential=$null;MachineCredential=$null;UseCredential=$false;BindUser='EXAMPLE\lecteur';AllowContainerDelete=$false;ReceiptRoot=''}
}
function Install-D093WHelpers {
    Set-D093Function 'Assert-WObjectFresh' { param($Context,$Safety) return $script:D093Before }
    Set-D093Function 'Get-WWriteBackend' { param($Context,$Commands) return 'ADSI' }
    Set-D093Function 'New-WEntry' { param($Context,[string]$Dn)
        $props=@{}
        if ($null -ne $script:D093PropertyNames) {
            foreach($n in @($script:D093PropertyNames)) {
                if ($null -ne $n) { $props[[string]$n]=New-D093PropertyValueCollection }
            }
        }
        $children=[pscustomobject]@{}
        Add-Member -InputObject $children -MemberType ScriptMethod -Name Remove -Value { param($Child) } -Force
        $entry=[pscustomobject]@{Properties=$props;Children=$children}
        Add-Member -InputObject $entry -MemberType ScriptMethod -Name CommitChanges -Value { } -Force
        Add-Member -InputObject $entry -MemberType ScriptMethod -Name Invoke -Value { param($Method,$Arg) return $null } -Force
        return $entry
    }
    # Before the dispatch the precondition re-read sees the value of the plan; after it, the value written.
    Set-D093Function 'Get-WAttributeFirst' { param($Context,[string]$Dn,[string]$Name) if ((-not $DomeniaWriteDispatched) -and [bool]$script:D093UseBeforeValue) { return $script:D093AttributeBeforeValue }; return $script:D093AttributeFirstValue }
    Set-D093Function 'Get-WObjectSnapshot' { param($Context,[string]$Dn)
        if ([string]::IsNullOrWhiteSpace($Dn)) { return [pscustomobject]@{Exists=$false;DN=''} }
        if ($Dn.StartsWith('<GUID=')) {
            if ($script:D093GuidReadThrows -and ($null -ne $script:D093GuidReadException)) { throw $script:D093GuidReadException }
            return [pscustomobject]@{Exists=$false;DN=$Dn;Guid='00000000-0000-0000-0000-000000000000';Classes=@('user');Lockout='0'}
        }
        return [pscustomobject]@{Exists=$false;DN=$Dn;Guid='00000000-0000-0000-0000-000000000000';Classes=@('user');Lockout='0'}
    }
    Set-D093Function 'Test-WDirectMembership' { param($Context,[string]$GroupDn,[string]$ObjectDn)
        $script:D093MembershipCalls++
        if ($script:D093MembershipCalls -eq 1) { return $false }
        if ($script:D093MembershipSecondThrows) { throw 'Relecture appartenance indisponible.' }
        return $true
    }
    Set-D093Function 'Get-WLdapPath' { param($Context,[string]$Dn) return ('LDAP://' + [string]$Dn) }
    Set-D093Function 'Resolve-WObjectDn' { param($Context,[string]$Value) return [string]$Value }
    Set-D093Function 'Get-WChildCount' { param($Context,[string]$Dn) return 0 }
    Set-D093Function 'Get-WParentDn' { param([string]$Dn) if ($Dn.Contains(',')) { return $Dn.Substring($Dn.IndexOf(',')+1) }; return '' }
}
function Reset-WiringFixture {
    if (Get-Command -Name 'End-D093FunctionOverrides' -ErrorAction SilentlyContinue) { End-D093FunctionOverrides }
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
    $script:D093SavedFunctions=@{}
    $script:D093Before=[pscustomobject]@{Classes=@('user');Guid='00000000-0000-0000-0000-000000000000';Lockout='0'}
    $script:D093AttributeFirstValue='abc'
    $script:D093MembershipCalls=0
    $script:D093MembershipSecondThrows=$false
    $script:D093GuidReadThrows=$false
    $script:D093GuidReadException=$null
    $script:D093PropertyNames=@()
    $script:D096Mods=$null
    $script:D096Answer=$null
    $script:D096Called=0
    $script:StatusLines=[Collections.Generic.List[string]]::new()
    $script:InfoBoxes=[Collections.Generic.List[string]]::new()
    $script:LastWritePostcondition=$null
    $script:UnknownWriteTargetDn=''
    $script:ActiveWriteLock=$null
    $script:CurrentUiProfile='Tech'
    $script:TypedConfirmCalls=[Collections.Generic.List[string]]::new()
    $script:TypedConfirmAnswer=$true
    $script:InlineRequests=[Collections.Generic.List[object]]::new()
    $script:D093UseBeforeValue=$true
    $script:D093AttributeBeforeValue=$null
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
    Test-Case 'D093 attributs : relecture conforme = Verifie' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='abc'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';New='abc';Clear=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D093WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            Assert-True ($r.Postcondition.Expected.Values.description -eq 'abc') ('Expected.Values.description : '+[string]$r.Postcondition.Expected.Values.description)
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.Postcondition.SentUtc)) 'SentUtc vide.'
            $pc=Get-DomeniaWritePostcondition -OperationId 'WriteAttributes' -Result $r
            Assert-True ($null -ne $pc) 'Postcondition resolu nulle.'
            Assert-True ($pc.Status -eq 'Verifie') ('Statut : '+[string]$pc.Status)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 attributs : relecture differente leve (etat inconnu par l enveloppe)' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='xyz'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';New='abc';Clear=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $err=''
            try { [void](Invoke-D093WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload) } catch { $err=$_.Exception.Message }
            Assert-True ($err -match 'Verification post-ecriture echouee') ('Message : '+$err)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 membre de groupe : ajout constate = Verifie, echec de relecture leve' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $context=New-D093Context
            $payload=[pscustomobject]@{GroupDn='CN=Demo Group,OU=Groups,DC=example,DC=invalid';ObjectValue='CN=Demo User,OU=Users,DC=example,DC=invalid';Add=$true;Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $script:D093MembershipCalls=0
            $script:D093MembershipSecondThrows=$false
            $r=Invoke-D093WorkerBody -FunctionName 'AddOrRemoveGroupMember' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            $memberCount=@($r.Postcondition.Observed.Members).Count
            Assert-True ($memberCount -eq 1) ('Membres observes : '+$memberCount)
            $pc=Get-DomeniaWritePostcondition -OperationId 'WriteGroupMember' -Result $r
            Assert-True ($null -ne $pc) 'Postcondition resolu nulle.'
            Assert-True ($pc.Status -eq 'Verifie') ('Statut : '+[string]$pc.Status)
            $script:D093MembershipCalls=0
            $script:D093MembershipSecondThrows=$true
            $err=''
            try { [void](Invoke-D093WorkerBody -FunctionName 'AddOrRemoveGroupMember' -Context $context -Payload $payload) } catch { $err=$_.Exception.Message }
            # The re-read failure itself propagates (the write envelope turns it into ETAT INCONNU).
            Assert-True ($err -match 'Relecture appartenance indisponible') ('Message : '+$err)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 suppression : absence par GUID constatee = Verifie' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D093Before=[pscustomobject]@{Classes=@('user');Guid='11111111-2222-3333-4444-555555555555';Lockout='0'}
            $script:D093GuidReadThrows=$true
            $script:D093GuidReadException=New-Object -TypeName 'System.Runtime.InteropServices.COMException' -ArgumentList @('There is no such object on the server.', -2147016656)
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'};Type='Utilisateur';Name='Demo User'}
            $r=Invoke-D093WorkerBody -FunctionName 'Delete-SelectedObject' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            Assert-True ($r.Postcondition.Observed.Exists -eq $false) ('Exists : '+[string]$r.Postcondition.Observed.Exists)
            Assert-True ($r.Postcondition.Observed.ReadStatus -eq 'OK') ('ReadStatus : '+[string]$r.Postcondition.Observed.ReadStatus)
            $pc=Get-DomeniaWritePostcondition -OperationId 'WriteDeleteObject' -Result $r
            Assert-True ($null -ne $pc) 'Postcondition resolu nulle.'
            Assert-True ($pc.Status -eq 'Verifie') ('Statut : '+[string]$pc.Status)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 suppression : refus de relecture par GUID = A verifier' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D093Before=[pscustomobject]@{Classes=@('user');Guid='11111111-2222-3333-4444-555555555555';Lockout='0'}
            $script:D093GuidReadThrows=$true
            $script:D093GuidReadException=New-Object -TypeName 'System.Runtime.InteropServices.COMException' -ArgumentList @('Access is denied.', -2147024891)
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'};Type='Utilisateur';Name='Demo User'}
            $r=Invoke-D093WorkerBody -FunctionName 'Delete-SelectedObject' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            Assert-True ($r.Postcondition.Observed.ReadStatus -eq 'Refused') ('ReadStatus : '+[string]$r.Postcondition.Observed.ReadStatus)
            $pc=Get-DomeniaWritePostcondition -OperationId 'WriteDeleteObject' -Result $r
            Assert-True ($null -ne $pc) 'Postcondition resolu nulle.'
            Assert-True ($pc.Status -eq 'A verifier') ('Statut : '+[string]$pc.Status)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 interface : Verifie affiche (Verifie) sans boite' {
        Reset-WiringFixture
        try {
            if ($null -eq $script:RealCompleteWriteTaskUi) { throw 'Complete-DomeniaWriteTaskUi reel non importe.' }
            if ($null -eq $script:RealGetWritePostcondition) { throw 'Get-DomeniaWritePostcondition reel non importe.' }
            Set-D093Function 'Complete-DomeniaWriteTaskUi' $script:RealCompleteWriteTaskUi
            Set-D093Function 'Get-DomeniaWritePostcondition' $script:RealGetWritePostcondition
            Set-D093Function 'Get-DomeniaEffectiveWorkerResult' { param($Result,$RequiredProperties) return $Result }
            Set-D093Function 'Invoke-DomeniaWritePostAction' { param($Result,$State) }
            Set-D093Function 'Request-DomeniaDashboardRefresh' { param([switch]$Immediate) }
            Set-D093Function 'Apply-CurrentPermissionUi' { }
            Set-D093Function 'Set-Status' { param($Text,$Level) if ($null -eq $script:StatusLines) { $script:StatusLines=[Collections.Generic.List[string]]::new() }; $script:StatusLines.Add([string]$Text) }
            Set-D093Function 'Show-InfoBox' { param($Message,$Details) if ($null -eq $script:InfoBoxes) { $script:InfoBoxes=[Collections.Generic.List[string]]::new() }; $script:InfoBoxes.Add([string]$Message) }
            $script:StatusLines=[Collections.Generic.List[string]]::new()
            $script:InfoBoxes=[Collections.Generic.List[string]]::new()
            $state=[pscustomobject]@{Name='Deverrouillage';Correlation='c';OperationId='WriteUnlock';TargetDn='CN=Demo User,OU=Users,DC=example,DC=invalid'}
            $result=[pscustomobject]@{
                Verified=$true
                Backend='ADSI'
                Message='Compte deverrouille'
                Postcondition=[pscustomobject]@{
                    SentUtc=(Get-Date).ToString('o')
                    Expected=[pscustomobject]@{Server='dc01.example.invalid';Flags=[pscustomobject]@{Locked='False'}}
                    Observed=[pscustomobject]@{ReadStatus='OK';Server='dc01.example.invalid';ReadUtc=(Get-Date).ToString('o');Flags=[pscustomobject]@{Locked='False'}}
                }
            }
            Complete-DomeniaWriteTaskUi -Result $result -State $state
            $statusCount=@($script:StatusLines | Where-Object { $_.Contains('(Verifie)') }).Count
            Assert-True ($statusCount -ge 1) 'Statut (Verifie) absent.'
            Assert-True ($script:InfoBoxes.Count -eq 0) ('Boites : '+$script:InfoBoxes.Count)
            Assert-True ($script:WriteState -eq 'Idle') ('WriteState : '+[string]$script:WriteState)
            Assert-True ($null -ne $script:LastWritePostcondition) 'LastWritePostcondition nul.'
            Assert-True ($script:LastWritePostcondition.Status -eq 'Verifie') ('Statut : '+[string]$script:LastWritePostcondition.Status)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 interface : sans postcondition = A verifier avec verification a faire' {
        Reset-WiringFixture
        try {
            if ($null -eq $script:RealCompleteWriteTaskUi) { throw 'Complete-DomeniaWriteTaskUi reel non importe.' }
            if ($null -eq $script:RealGetWritePostcondition) { throw 'Get-DomeniaWritePostcondition reel non importe.' }
            Set-D093Function 'Complete-DomeniaWriteTaskUi' $script:RealCompleteWriteTaskUi
            Set-D093Function 'Get-DomeniaWritePostcondition' $script:RealGetWritePostcondition
            Set-D093Function 'Get-DomeniaEffectiveWorkerResult' { param($Result,$RequiredProperties) return $Result }
            Set-D093Function 'Invoke-DomeniaWritePostAction' { param($Result,$State) }
            Set-D093Function 'Request-DomeniaDashboardRefresh' { param([switch]$Immediate) }
            Set-D093Function 'Apply-CurrentPermissionUi' { }
            Set-D093Function 'Set-Status' { param($Text,$Level) if ($null -eq $script:StatusLines) { $script:StatusLines=[Collections.Generic.List[string]]::new() }; $script:StatusLines.Add([string]$Text) }
            Set-D093Function 'Show-InfoBox' { param($Message,$Details) if ($null -eq $script:InfoBoxes) { $script:InfoBoxes=[Collections.Generic.List[string]]::new() }; $script:InfoBoxes.Add([string]$Message) }
            $script:StatusLines=[Collections.Generic.List[string]]::new()
            $script:InfoBoxes=[Collections.Generic.List[string]]::new()
            $state=[pscustomobject]@{Name='Deplacement';Correlation='c';OperationId='WriteMoveObject';TargetDn='CN=Demo User,OU=Users,DC=example,DC=invalid'}
            $result=[pscustomobject]@{Verified=$true;Backend='ADSI';Message='Operation verifiee'}
            Complete-DomeniaWriteTaskUi -Result $result -State $state
            Assert-True ($script:InfoBoxes.Count -eq 1) ('Boites : '+$script:InfoBoxes.Count)
            Assert-True ($script:InfoBoxes[0].Contains('Verification a faire')) ('Boite : '+$script:InfoBoxes[0])
            Assert-True ($null -ne $script:LastWritePostcondition) 'LastWritePostcondition nul.'
            Assert-True ($script:LastWritePostcondition.Status -eq 'A verifier') ('Statut : '+[string]$script:LastWritePostcondition.Status)
            Assert-True ($script:WriteState -eq 'Idle') ('WriteState : '+[string]$script:WriteState)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 interface : echec etat inconnu indique la verification a faire' {
        Reset-WiringFixture
        try {
            if ($null -eq $script:RealFailWriteTaskUi) { throw 'Fail-DomeniaWriteTaskUi reel non importe.' }
            Set-D093Function 'Fail-DomeniaWriteTaskUi' $script:RealFailWriteTaskUi
            Set-D093Function 'ConvertTo-DomeniaErrorInfo' { param($ErrorRecordOrException,$Operation) return @{Kind='Unknown';Friendly='x'} }
            Set-D093Function 'Set-DomeniaActualCapabilityDenied' { param($Dn,$Capability,$Reason) }
            Set-D093Function 'Apply-CurrentPermissionUi' { }
            Set-D093Function 'Set-Status' { param($Text,$Level) if ($null -eq $script:StatusLines) { $script:StatusLines=[Collections.Generic.List[string]]::new() }; $script:StatusLines.Add([string]$Text) }
            Set-D093Function 'Show-InfoBox' { param($Message,$Details) if ($null -eq $script:InfoBoxes) { $script:InfoBoxes=[Collections.Generic.List[string]]::new() }; $script:InfoBoxes.Add([string]$Message) }
            $script:StatusLines=[Collections.Generic.List[string]]::new()
            $script:InfoBoxes=[Collections.Generic.List[string]]::new()
            $state=[pscustomobject]@{Name='Membre groupe';Correlation='c';OperationId='WriteGroupMember';TargetDn='CN=Demo Group,OU=Groups,DC=example,DC=invalid';Capability='Group'}
            Fail-DomeniaWriteTaskUi -Message 'ETAT INCONNU : relecture indisponible' -State $state
            Assert-True ($script:InfoBoxes.Count -eq 1) ('Boites : '+$script:InfoBoxes.Count)
            Assert-True ($script:InfoBoxes[0].Contains('Verification a faire')) ('Boite : '+$script:InfoBoxes[0])
            Assert-True ($script:WriteState -eq 'Unknown') ('WriteState : '+[string]$script:WriteState)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D093 action distante : livraison = A verifier avec verification a faire' {
        Reset-WiringFixture
        try {
            if ($null -eq $script:RealGetWritePostcondition) { throw 'Get-DomeniaWritePostcondition reel non importe.' }
            Set-D093Function 'Get-DomeniaWritePostcondition' $script:RealGetWritePostcondition
            Set-D093Function 'Set-Status' { param($Text,$Level) if ($null -eq $script:StatusLines) { $script:StatusLines=[Collections.Generic.List[string]]::new() }; $script:StatusLines.Add([string]$Text) }
            $script:StatusLines=[Collections.Generic.List[string]]::new()
            Complete-DomeniaComputerToolUi -Result ([pscustomobject]@{Message='Redemarrage demande a PC-DEMO-01.';Delivered=$true}) -State ([pscustomobject]@{Tool='Redemarrage';Computer='PC-DEMO-01'})
            Assert-True ($script:StatusLines.Count -eq 1) ('Statuts : '+$script:StatusLines.Count)
            Assert-True ($script:StatusLines[0].Contains('Verification a faire')) ('Statut : '+$script:StatusLines[0])
            Assert-True ($null -ne $script:LastWritePostcondition) 'LastWritePostcondition nul.'
            Assert-True ($script:LastWritePostcondition.Status -eq 'A verifier') ('Statut : '+[string]$script:LastWritePostcondition.Status)
            Assert-True ($script:LastWritePostcondition.Kind -eq 'Restart') ('Regle : '+[string]$script:LastWritePostcondition.Kind)
            $script:StatusLines=[Collections.Generic.List[string]]::new()
            Complete-DomeniaComputerToolUi -Result ([pscustomobject]@{Message='Reponse en 3 ms.'}) -State ([pscustomobject]@{Tool='Ping';Computer='PC-DEMO-01'})
            Assert-True (-not $script:StatusLines[0].Contains('Verification a faire')) ('Ping : '+$script:StatusLines[0])
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 conditionnel accepte : une requete Delete+Add, backend Conditional' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=0;Message='';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            Assert-True (([string]$r.Error) -eq '') ('Erreur : '+[string]$r.Error)
            $out=$r.Output
            Assert-True ($null -ne $out) 'Output nul.'
            $mods=@($script:D096Mods)
            Assert-True ($mods.Count -eq 2) ('Modifications recues : '+$mods.Count)
            Assert-True ($mods[0].Op -eq 'Delete') ('Op 0 : '+[string]$mods[0].Op)
            Assert-True ($mods[0].Value -eq 'ancien') ('Value 0 : '+[string]$mods[0].Value)
            Assert-True ($mods[1].Op -eq 'Add') ('Op 1 : '+[string]$mods[1].Op)
            Assert-True ($mods[1].Value -eq 'nouveau') ('Value 1 : '+[string]$mods[1].Value)
            Assert-True ($out.Backend -eq 'Conditional') ('Backend : '+[string]$out.Backend)
            Assert-True ($r.Dispatched -eq $true) ('Dispatched : '+[string]$r.Dispatched)
            $pc=Get-DomeniaWritePostcondition -OperationId 'WriteAttributes' -Result $out
            Assert-True ($null -ne $pc) 'Postcondition resolu nulle.'
            Assert-True ($pc.Status -eq 'Verifie') ('Statut : '+[string]$pc.Status)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 conflit 16 : rien d ecrase, envoi annule' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=16;Message='';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error).Contains('Conflit')) ('Erreur : '+[string]$r.Error)
            # SE-09: the controller answer is read by Resolve-DomeniaConditionalWrite (shared rule).
            Assert-True (([string]$r.Error) -match 'rien n.a .t. .cras') ('Erreur : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $false) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 refus 53 : rien applique, envoi annule' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=53;Message='unwilling';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error) -match '(?i)Requ.te refus.e par le contr.leur \(code LDAP 53\)') ('Erreur : '+[string]$r.Error)
            Assert-True (([string]$r.Error).Contains('unwilling')) ('Diagnostic du controleur perdu : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $false) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 refus 50 : acces refuse reconnu, envoi annule' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=50;Message='INSUFF_ACCESS_RIGHTS';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error) -match '(?i)acc[eè]s.*refus') ('Erreur : '+[string]$r.Error)
            Assert-True (([string]$r.Error).Contains('INSUFF_ACCESS_RIGHTS')) ('Diagnostic du controleur perdu : '+[string]$r.Error)
            Assert-True ($r.ErrorType -eq 'System.UnauthorizedAccessException') ('Type : '+[string]$r.ErrorType)
            Assert-True ($r.ErrorHResult -eq -2147024891) ('HResult : '+[string]$r.ErrorHResult)
            Assert-True ($r.Dispatched -eq $false) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 pas de reponse 81 : etat inconnu' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=81;Message='';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error) -match 'Pas de r.ponse du contr.leur \(code client 81\)') ('Erreur : '+[string]$r.Error)
            Assert-True (([string]$r.Error) -match 'issue . v.rifier') ('Erreur : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $true) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 echec avant envoi : non envoye' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=-1;Message='bind';Sent=$false}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error).Contains('non envoyee')) ('Erreur : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $false) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 bind refuse 49 : non envoye, identifiants classables' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=49;Message='invalid credentials';Sent=$false}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='nouveau'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True (([string]$r.Error).Contains('non envoyee')) ('Erreur : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $false) ('Dispatched : '+[string]$r.Dispatched)
            Assert-True ($r.ErrorHResult -eq -2147023570) ('HResult : '+[string]$r.ErrorHResult)
            Assert-True (([string]$r.Error).Contains('code LDAP 49')) ('Erreur : '+[string]$r.Error)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 sans changement conditionnel : chemin d origine' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Mods=$null
            $script:D096Answer=[pscustomobject]@{ResultCode=0;Message='';Sent=$true}
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Mods=@($Modifications | Where-Object { $null -ne $_ }); return $script:D096Answer }
            $script:D093PropertyNames=@('description')
            $script:D093AttributeFirstValue='abc'
            $script:D093AttributeBeforeValue='ancien'
            $context=New-D093Context
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='abc';Clear=$false;Conditional=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $payload
            Assert-True ($null -ne $r) 'Resultat nul.'
            Assert-True (([string]$r.Error) -eq '') ('Erreur : '+[string]$r.Error)
            $modsEmpty = (($null -eq $script:D096Mods) -or (@($script:D096Mods).Count -eq 0))
            Assert-True $modsEmpty 'La doublure Invoke-WConditionalModify a ete appelee.'
            Assert-True ($null -ne $r.Output) 'Output nul.'
            Assert-True ($r.Output.Backend -eq 'ADSI') ('Backend : '+[string]$r.Output.Backend)
            Assert-True ($r.Dispatched -eq $true) ('Dispatched : '+[string]$r.Dispatched)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 strategie : texte connu conditionnel, DN et brut en relecture' {
        Reset-WiringFixture
        try {
            if (-not (Get-Command Get-DomeniaAttributeWriteStrategy -ErrorAction SilentlyContinue)) { throw 'Get-DomeniaAttributeWriteStrategy absente.' }
            if (-not (Get-Command Get-DomeniaAtomicStrategy -ErrorAction SilentlyContinue)) { throw 'Get-DomeniaAtomicStrategy absente.' }
            $s1=Get-DomeniaAttributeWriteStrategy -Change ([pscustomobject]@{Name='description';Old='a';New='b';Clear=$false})
            Assert-True ($null -ne $s1) 'Strategie description nulle.'
            Assert-True ($s1.Strategy -eq 'ConditionalReplace') ('Strategy 1 : '+[string]$s1.Strategy)
            $s2=Get-DomeniaAttributeWriteStrategy -Change ([pscustomobject]@{Name='description';Old='a';New='';Clear=$true})
            Assert-True ($null -ne $s2) 'Strategie description effacee nulle.'
            Assert-True ($s2.Strategy -eq 'ConditionalDelete') ('Strategy 2 : '+[string]$s2.Strategy)
            $s3=Get-DomeniaAttributeWriteStrategy -Change ([pscustomobject]@{Name='manager';Old='a';New='b';Clear=$false})
            Assert-True ($null -ne $s3) 'Strategie manager nulle.'
            Assert-True ($s3.Strategy -eq 'ReadBeforeAfter') ('Strategy 3 : '+[string]$s3.Strategy)
            $s4=Get-DomeniaAttributeWriteStrategy -Change ([pscustomobject]@{Name='extensionAttribute1';Old='a';New='b';Clear=$false})
            Assert-True ($null -ne $s4) 'Strategie extensionAttribute1 nulle.'
            Assert-True ($s4.Strategy -eq 'ReadBeforeAfter') ('Strategy 4 : '+[string]$s4.Strategy)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 plan : limites affichees' {
        Reset-WiringFixture
        try {
            $change=New-TestChange -Attribute 'description' -Kind 'Replace' -Before 'a' -After 'b'
            $planUnlock=New-DomeniaSelectionWritePlan -OperationId 'WriteUnlock' -Changes @($change) -Effects @()
            $textUnlock=Format-DomeniaPlanConfirmation -Plan $planUnlock
            Assert-True ($null -ne $textUnlock) 'Confirmation WriteUnlock nulle.'
            Assert-True ($textUnlock.Contains('Pas de condition atomique')) 'Limite fixe absente du plan WriteUnlock.'
            $planAttrs=New-DomeniaSelectionWritePlan -OperationId 'WriteAttributes' -Changes @($change) -Effects @('X')
            $textAttrs=Format-DomeniaPlanConfirmation -Plan $planAttrs
            Assert-True ($null -ne $textAttrs) 'Confirmation WriteAttributes nulle.'
            Assert-True (-not $textAttrs.Contains('Pas de condition atomique')) 'Limite fixe presente sur WriteAttributes.'
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'D096 bibliotheque LDAP : construction reelle sans serveur' {
        Reset-WiringFixture
        try {
            # The real function lives in its own WorkerCommon += block: load exactly that source, not a stand-in.
            $lit=@(Get-SingleQuotedLiterals $script:CoreAst | Where-Object { $_.Value.Contains('function Invoke-WConditionalModify') })
            if ($lit.Count -ne 1) { throw ('Bloc commun Invoke-WConditionalModify introuvable : '+$lit.Count) }
            $lt=$null;$le=$null;$litAst=[Management.Automation.Language.Parser]::ParseInput([string]$lit[0].Value,[ref]$lt,[ref]$le)
            if (@($le).Count) { throw 'Bloc commun Invoke-WConditionalModify non analysable.' }
            $fnAst=@($litAst.FindAll({param($n)((($n -is [Management.Automation.Language.FunctionDefinitionAst])) -and (($n.Name -eq 'Invoke-WConditionalModify')))},$true))
            if ($fnAst.Count -ne 1) { throw 'Invoke-WConditionalModify absente du bloc commun.' }
            Set-D093Function 'Invoke-WConditionalModify' ($fnAst[0].Body.GetScriptBlock())
            $context=[pscustomobject]@{Server='127.0.0.1';Domain='';UseCredential=$false;Credential=$null}
            $mods=@([pscustomobject]@{Name='description';Op='Replace';Value='x'})
            $res=Invoke-WConditionalModify $context 'CN=x,DC=example,DC=invalid' $mods
            Assert-True ($null -ne $res) 'Reponse LDAP nulle.'
            Assert-True ($res.Sent -eq $false) ('Sent : '+[string]$res.Sent)
            Assert-True ($res.ResultCode -ne 0) ('ResultCode : '+[string]$res.ResultCode)
            Assert-True (-not ([string]$res.Message).Contains('Cannot find type')) ('Type introuvable : '+[string]$res.Message)
            Assert-True (-not ([string]$res.Message -match '(?i)constructor|overload|argument')) ('Construction invalide : '+[string]$res.Message)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'SE-02 worker : attribut brut bloque refuse meme si l interface est contournee' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $script:D096Called=0
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) $script:D096Called++; return [pscustomobject]@{ResultCode=0;Message='';Sent=$true} }
            $script:D093PropertyNames=@('adminCount','info','description')
            $context=New-D093Context
            $context | Add-Member -NotePropertyName AllowRawAttributeWrite -NotePropertyValue $true
            $context | Add-Member -NotePropertyName BlockSensitiveRawAttributes -NotePropertyValue $true
            $context | Add-Member -NotePropertyName RawAttributeBlockList -NotePropertyValue @('adminCount','unicodePwd')
            $blocked=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='adminCount';Old='';New='1';Clear=$false;Conditional=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $blocked
            Assert-True (([string]$r.Error) -match 'sensible') ('Attribut bloque accepte : '+[string]$r.Error)
            Assert-True ($r.Dispatched -eq $false) 'Envoi malgre la garde.'
            Assert-True ($script:D096Called -eq 0) 'Requete LDAP partie.'
            $context.AllowRawAttributeWrite=$false
            $raw=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='info';Old='';New='x';Clear=$false;Conditional=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r2=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $raw
            Assert-True (([string]$r2.Error) -match 'AllowRawAttributeWrite') ('Ecriture brute non refusee : '+[string]$r2.Error)
            Assert-True ($r2.Dispatched -eq $false) 'Ecriture brute envoyee.'
            $flagged=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='';New='x';Clear=$false;Conditional=$false;Raw=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r3=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $flagged
            Assert-True (([string]$r3.Error) -match 'AllowRawAttributeWrite') ('Edition brute d un champ de fiche non refusee : '+[string]$r3.Error)
            $script:D093AttributeFirstValue='x'
            $form=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='';New='x';Clear=$false;Conditional=$false});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000'}}
            $r4=Invoke-D096WorkerBody -FunctionName 'Start-DomeniaAttributeWrite' -Context $context -Payload $form
            Assert-True (([string]$r4.Error) -eq '') ('Champ de fiche refuse : '+[string]$r4.Error)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'SE-02 interface : meme regle, configuration de securite respectee' {
        Reset-WiringFixture
        $script:Ctrl=@{TxtRawAttrName=[pscustomobject]@{Text='adminCount'};TxtRawAttrValue=[pscustomobject]@{Text='1'}}
        $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';DN=$script:FakeIdentity.DN}
        $script:RawAttributeBlockList=@('adminCount')
        $script:CfgOverride=@{AllowRawAttributeWrite=$true;BlockSensitiveRawAttributes=$true}
        try {
            Set-Item function:script:Get-CfgValue -Value { param($Section,$Name,$Default) if (($null -ne $script:CfgOverride) -and $script:CfgOverride.ContainsKey([string]$Name)) { return $script:CfgOverride[[string]$Name] }; return $Default }
            Set-OrClearRawAttribute -Clear $false
            Assert-True (@($script:Dialogs | Where-Object { $_ -match 'sensible' }).Count -eq 1) ('Refus absent : '+($script:Dialogs -join ' | '))
            Assert-True ($script:InlineRequests.Count -eq 0) 'Confirmation proposee pour un attribut bloque.'
            Assert-True ($script:StartUiTaskCalls -eq 0) 'Ecriture lancee.'
        } finally { Set-Item function:script:Get-CfgValue -Value { param($Section,$Name,$Default) return $Default }; $script:CfgOverride=$null }
    }
    Test-Case 'SE-12 DN hors domaine ou sous CN=Configuration refuse avant envoi, nomme par son nom' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $group=New-TestIdentity -Dn 'CN=Comptables,OU=Groupes,DC=example,DC=invalid' -Name 'Comptables' -Type 'Groupe'
        $script:FakeIdentity=$group
        $script:SelectedObject=[pscustomobject]@{Type='Groupe';DN=$group.DN}
        foreach($bad in @('CN=Services,CN=Configuration,DC=example,DC=invalid','CN=Admins,OU=Groupes,DC=autre,DC=invalid')){
            $script:Dialogs=[Collections.Generic.List[string]]::new()
            $script:Ctrl=@{TxtGroupMemberTarget=[pscustomobject]@{Text=$bad}}
            AddOrRemoveGroupMember -Add $true
            $leaf=([string]$bad.Split(',')[0]).Substring(3)
            Assert-True (@($script:Dialogs).Count -eq 1) ('Refus absent pour '+$bad)
            Assert-True ($script:Dialogs[0] -match [regex]::Escape($leaf)) ('Nom lisible absent : '+$script:Dialogs[0])
            Assert-True ($script:Dialogs[0] -notmatch '(?i)\b(CN|OU|DC)=') ('DN dans le message : '+$script:Dialogs[0])
            Assert-True (($script:InlineRequests.Count -eq 0) -and ($script:StartUiTaskCalls -eq 0)) 'Confirmation ou envoi malgre le refus.'
        }
        $script:Ctrl=@{TxtGroupMemberTarget=[pscustomobject]@{Text='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid'}}
        AddOrRemoveGroupMember -Add $true
        Assert-True ($script:InlineRequests.Count -eq 1) 'DN du domaine non propose a la confirmation.'
        $request=$script:InlineRequests[0]
        Assert-True ($request.Message -match 'Jean Dupont') ('Nom lisible absent de la confirmation : '+$request.Message)
        Assert-True ((($request.Message+' '+($request.Changes -join ' ')) -notmatch '(?i)\b(CN|OU|DC)=')) 'DN hors des details techniques.'
        Assert-True ($request.Details -match [regex]::Escape('CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid')) 'DN absent des details techniques.'
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Envoi apres confirmation : '+$script:StartUiTaskCalls)
    }
    Test-Case 'SE-12 worker : DN saisi controle puis resolu par son GUID avant tout envoi' {
        Reset-WiringFixture
        try {
            $script:D093Snapshots=0
            Set-D093Function 'Get-WObjectSnapshot' { param($Context,[string]$Dn)
                $script:D093Snapshots++
                if ($Dn.StartsWith('<GUID=')) { return [pscustomobject]@{Exists=$true;DN='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid';Guid='11111111-2222-3333-4444-555555555555'} }
                return [pscustomobject]@{Exists=$true;DN=$Dn;Guid='11111111-2222-3333-4444-555555555555'}
            }
            $context=New-D093Context
            foreach($bad in @('CN=Services,CN=Configuration,DC=example,DC=invalid','CN=x,DC=DomainDnsZones,DC=example,DC=invalid','CN=Admins,DC=autre,DC=invalid','CN=,DC=example,DC=invalid')){
                $err='';try{[void](Resolve-WObjectDn $context $bad)}catch{$err=$_.Exception.Message}
                Assert-True ($err -match 'rien n|jamais une cible') ('Refus absent pour '+$bad+' : '+$err)
            }
            Assert-True ($script:D093Snapshots -eq 0) 'Lecture AD avant le controle du DN.'
            $dn=Resolve-WObjectDn $context 'cn=jean dupont, ou=utilisateurs,dc=example,dc=invalid'
            Assert-True ($dn -ceq 'CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid') ('DN non canonique : '+$dn)
            Assert-True ($script:D093Snapshots -eq 2) ('Lectures : '+$script:D093Snapshots)
            Set-D093Function 'Get-WObjectSnapshot' { param($Context,[string]$Dn) if ($Dn.StartsWith('<GUID=')) { return [pscustomobject]@{Exists=$true;DN='CN=Autre,OU=Utilisateurs,DC=example,DC=invalid';Guid='99999999-2222-3333-4444-555555555555'} }; return [pscustomobject]@{Exists=$true;DN=$Dn;Guid='11111111-2222-3333-4444-555555555555'} }
            $err='';try{[void](Resolve-WObjectDn $context 'CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=invalid')}catch{$err=$_.Exception.Message}
            Assert-True ($err -match 'GUID') ('GUID different non refuse : '+$err)
        } finally { End-D093FunctionOverrides }
    }
    Test-Case 'SE-09 deux ecritures sur la meme cible : la seconde refusee proprement' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity=$script:FakeIdentity
        $first=@(New-TestChange -After 'premier')
        $second=@(New-TestChange -After 'second')
        $planA=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $first
        $planB=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $second
        [void](Start-DomeniaWriteTask -Name 'A' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $planA -PlanChanges $first)
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Premiere ecriture non partie.'
        Assert-True ($null -ne $script:ActiveWriteLock) 'Verrou de la cible absent.'
        $failure=''
        try { [void](Start-DomeniaWriteTask -Name 'B' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $planB -PlanChanges $second) } catch { $failure=$_.Exception.Message }
        Assert-True ($failure -eq '') ('Exception : '+$failure)
        Assert-True ($script:StartUiTaskCalls -eq 1) ('Seconde ecriture partie : '+$script:StartUiTaskCalls)
        Assert-True (@($script:Dialogs | Where-Object { $_ -match 'cette cible' }).Count -eq 1) ('Refus absent : '+($script:Dialogs -join ' | '))
        $other=$script:OtherFakeIdentity
        $script:FakeIdentity=$other
        $planC=New-TestPlan -OperationId 'WriteTest' -Target $other -Changes $first
        [void](Start-DomeniaWriteTask -Name 'C' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$other.DN}) -Plan $planC -PlanChanges $first)
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Les ecritures ne partent plus une par une.'
        Assert-True (@($script:Dialogs | Where-Object { $_ -match 'une par une' }).Count -eq 1) 'Refus une par une absent.'
        & $script:RealFailWriteTaskUi -Message 'Refus du controleur (code LDAP 53).' -State ([pscustomobject]@{Name='A';OperationId='WriteTest';Correlation='c';Capability='Edit';TargetDn=$identity.DN;PlanKey=$planA.Fingerprint.ToUpperInvariant()})
        Assert-True ($null -eq $script:ActiveWriteLock) 'Verrou conserve apres la fin.'
        [void](Start-DomeniaWriteTask -Name 'C' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$other.DN}) -Plan $planC -PlanChanges $first)
        Assert-True ($script:StartUiTaskCalls -eq 2) 'Ecriture suivante refusee apres la fin.'
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity=$script:FakeIdentity
        $script:ReceiptRows=@([pscustomobject]@{Format=1;Id=('a'*32);Operation='WriteTest';Domain='dc=example,dc=invalid';Stage='Unknown';Guid=$identity.Guid;DN=$identity.DN;PlanFingerprint=('B'*64)})
        $planD=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $first
        [void](Start-DomeniaWriteTask -Name 'D' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $planD -PlanChanges $first)
        Assert-True ($script:StartUiTaskCalls -eq 0) 'Ecriture sur une cible a verifier.'
        Assert-True (@($script:Dialogs | Where-Object { $_ -match 'v.rifier sur cette cible' }).Count -eq 1) ('Refus recu incertain absent : '+($script:Dialogs -join ' | '))
        $script:FakeIdentity=$script:OtherFakeIdentity
        $planE=New-TestPlan -OperationId 'WriteTest' -Target $script:OtherFakeIdentity -Changes $first
        [void](Start-DomeniaWriteTask -Name 'E' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$script:OtherFakeIdentity.DN}) -Plan $planE -PlanChanges $first)
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Une autre cible reste modifiable.'
    }
    Test-Case 'SE-09 code LDAP 81 et plus : recu a verifier, jamais rejoue' {
        Reset-WiringFixture
        try {
            Install-D093WHelpers
            $receiptRoot=Join-Path $temp ('se09-'+[guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($receiptRoot)
            $script:ReceiptRoot=$receiptRoot
            Set-D093Function 'Invoke-WConditionalModify' { param($Context,[string]$Dn,[object[]]$Modifications) return [pscustomobject]@{ResultCode=85;Message='timeout';Sent=$true} }
            $context=New-WriteContext -ReceiptRoot $receiptRoot -OperationId 'WriteAttributes'
            $payload=[pscustomobject]@{DN='CN=Demo User,OU=Users,DC=example,DC=invalid';Changes=@([pscustomobject]@{Name='description';Old='ancien';New='nouveau';Clear=$false;Conditional=$true});Safety=[pscustomobject]@{Guid='00000000-0000-0000-0000-000000000000';ExpectedGuid='00000000-0000-0000-0000-000000000000'};CorrelationId=[guid]::NewGuid().ToString('N');PlanFingerprint=('C'*64)}
            $worker=New-WriteEnvelopeScript -Business (Get-D093WorkerBody -FunctionName 'Start-DomeniaAttributeWrite')
            $failure=''
            try { [void](& $worker $context $payload) } catch { $failure=$_.Exception.Message }
            Assert-True ($failure -match 'ETAT INCONNU') ('Issue : '+$failure)
            Assert-True ($failure -match 'code client 85') ('Lecture du code absente : '+$failure)
            $records=@(Get-ReceiptRecords $receiptRoot)
            Assert-True (($records.Count -eq 1) -and ($records[0].Stage -eq 'Unknown')) ('Recu : '+(@($records|ForEach-Object{$_.Stage}) -join ','))
        } finally { End-D093FunctionOverrides }
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity=$script:FakeIdentity
        $changes=@(New-TestChange -After 'nouveau')
        $plan=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        [void](Start-DomeniaWriteTask -Name 'T' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $plan -PlanChanges $changes)
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Ecriture non partie.'
        $key=$plan.Fingerprint.ToUpperInvariant()
        & $script:RealFailWriteTaskUi -Message ('ETAT INCONNU apres envoi. Recu conserve ; aucun rejeu automatique. '+$failure) -State ([pscustomobject]@{Name='T';OperationId='WriteTest';Correlation='c';Capability='Edit';TargetDn=$identity.DN;PlanKey=$key})
        Assert-True ($script:SubmittedWritePlans[$key].State -eq 'Uncertain') ('Etat : '+[string]$script:SubmittedWritePlans[$key].State)
        Assert-True ($script:WriteState -eq 'Unknown') ('Etat d ecriture : '+$script:WriteState)
        $again=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        [void](Start-DomeniaWriteTask -Name 'T' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $again -PlanChanges $changes)
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Demande incertaine rejouee.'
        Assert-True (@($script:Dialogs | Where-Object { $_ -match 'aucun nouvel envoi' }).Count -ge 1) ('Refus absent : '+($script:Dialogs -join ' | '))
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity=$script:FakeIdentity
        $plan=New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes
        [void](Start-DomeniaWriteTask -Name 'T' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan $plan -PlanChanges $changes)
        $key=$plan.Fingerprint.ToUpperInvariant()
        & $script:RealFailWriteTaskUi -Message 'Requete refusee par le controleur (code LDAP 53) : rien n a ete applique.' -State ([pscustomobject]@{Name='T';OperationId='WriteTest';Correlation='c';Capability='Edit';TargetDn=$identity.DN;PlanKey=$key})
        Assert-True ($script:SubmittedWritePlans[$key].State -eq 'NotSent') ('Refus certain : '+[string]$script:SubmittedWritePlans[$key].State)
        [void](Start-DomeniaWriteTask -Name 'T' -OperationId 'WriteTest' -Code 'x' -Payload ([pscustomobject]@{DN=$identity.DN}) -Plan (New-TestPlan -OperationId 'WriteTest' -Target $identity -Changes $changes) -PlanChanges $changes)
        Assert-True ($script:StartUiTaskCalls -eq 2) 'Nouvelle confirmation apres un refus certain non admise.'
    }
    Test-Case 'UX-08 panneau avant/apres sans DN ni GUID hors Details techniques, aucune fenetre d ecriture' {
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $identity=$script:FakeIdentity
        $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';DN=$identity.DN}
        [void](Set-AccountDisabled -Disabled $true)
        Assert-True ($script:InlineRequests.Count -eq 1) ('Demandes dans la page : '+$script:InlineRequests.Count)
        $request=$script:InlineRequests[0]
        $arrow=[string][char]0x2192
        Assert-True (@($request.Changes) -contains ('Compte : actif '+$arrow+' d'+[char]0xE9+'sactiv'+[char]0xE9)) ('Avant/apres : '+(@($request.Changes) -join ' | '))
        $visible=$request.Title+' '+$request.Message+' '+(@($request.Changes) -join ' ')
        Assert-True ($visible -notmatch '(?i)\b(CN|OU|DC)=') ('DN visible : '+$visible)
        Assert-True ($visible -notmatch [regex]::Escape($identity.Guid)) 'GUID visible.'
        Assert-True ($request.Details.Contains($identity.DN) -and $request.Details.Contains($identity.Guid)) 'DN ou GUID absent des details techniques.'
        Assert-True ($request.Details -match 'Empreinte du plan : ') 'Empreinte absente des details techniques.'
        Assert-True ($request.Details.Contains('dc01.example.invalid')) 'Controleur absent des details techniques.'
        Assert-True ($request.Risk -eq 'Danger') 'Desactivation sans risque affiche.'
        Assert-True ($script:StartUiTaskCalls -eq 1) 'Ecriture non partie apres confirmation.'
        Reset-WiringFixture
        $script:UseDoubleStartUiTask=$true
        $script:SelectedObject=[pscustomobject]@{Type='Utilisateur';DN=$script:FakeIdentity.DN}
        $script:TypedConfirmAnswer=$false
        $script:Ctrl=@{TxtRawAttrName=[pscustomobject]@{Text='info'};TxtRawAttrValue=[pscustomobject]@{Text='note'}}
        $script:CfgOverride=@{AllowRawAttributeWrite=$true;BlockSensitiveRawAttributes=$true}
        try {
            Set-Item function:script:Get-CfgValue -Value { param($Section,$Name,$Default) if (($null -ne $script:CfgOverride) -and $script:CfgOverride.ContainsKey([string]$Name)) { return $script:CfgOverride[[string]$Name] }; return $Default }
            Set-OrClearRawAttribute -Clear $false
            Assert-True ($script:InlineRequests.Count -eq 1) ('Une seule demande pour l ecriture brute : '+$script:InlineRequests.Count+' ; '+(@($script:Dialogs) -join ' | ')+' ; '+(@($script:StatusLog) -join ' | '))
            Assert-True ($script:InlineRequests[0].TypedConfirmation -eq 'MODIFIER') 'Saisie MODIFIER non demandee.'
            Assert-True ($script:StartUiTaskCalls -eq 0) 'Ecriture brute partie sans la saisie exacte.'
            Assert-True ($script:ConfirmCalls -eq 0) 'Confirmation simple a la place de la saisie.'
        } finally { Set-Item function:script:Get-CfgValue -Value { param($Section,$Name,$Default) return $Default }; $script:CfgOverride=$null }
        $sources=@('Set-AccountDisabled','Reset-UserPassword','Apply-UserAccountOptions','Set-UserExpiration','Expire-UserPasswordNow','Move-SelectedObject','AddOrRemoveObjectGroup','AddOrRemoveGroupMember','Rename-ComputerObject','Create-OuUnderSelected','Set-OrClearRawAttribute','Delete-SelectedObject','Start-DomeniaAttributeWrite')
        foreach($fn in $sources){
            $text=(Get-FunctionAst $script:CoreAst $fn).Extent.Text
            $modal=@([regex]::Matches($text,'(?i)\bConfirm-(Warning|Text)?Action\b|Show-Domenia(Form)?Dialog|\.ShowDialog\s*\(|Confirm-DomeniaOperationImpact')|ForEach-Object{$_.Value})
            Assert-True ($modal.Count -eq 0) ($fn+' ouvre encore une fenetre : '+($modal -join ', '))
            Assert-True ($text -match 'Request-Domenia(Write|Inline)Confirmation|Start-DomeniaAttributeWrite') ($fn+' sans confirmation dans la page.')
        }
    }
    Test-Case 'UX-07 confirmation d impact en clair : ni worker, ni RPC, ni req/s' {
        Reset-WiringFixture
        $estimates=@(
            [pscustomobject]@{Operation='IndexBuild';ItemCount=238;DurationMs=120000;Bytes=428400;AdQueries=1;RemoteAttempts=0;FallbackTasks=0;SchedulerRpc=0;Concurrency=1;Impact='Faible';Samples=0;AverageMsPerItem=0;MinMsPerItem=0;MaxMsPerItem=0;SuccessPct=0;AverageBytesPerSecond=3570;AverageMbitPerSecond=0.03;PeakMbitPerSecond=0.03;AdQueriesPerSecond=0.01;Confidence='Initiale'}
            [pscustomobject]@{Operation='LogonHarvest';ItemCount=5000;DurationMs=15000;Bytes=11000000;AdQueries=1;RemoteAttempts=0;FallbackTasks=0;SchedulerRpc=0;Concurrency=1;Impact='Modere';Samples=4;AverageMsPerItem=3;MinMsPerItem=1;MaxMsPerItem=9;SuccessPct=100;AverageBytesPerSecond=733000;AverageMbitPerSecond=5.8;PeakMbitPerSecond=5.8;AdQueriesPerSecond=0.07;Confidence='Moyenne'}
            [pscustomobject]@{Operation='ParkSweep';ItemCount=120;DurationMs=144000;Bytes=2880000;AdQueries=0;RemoteAttempts=120;FallbackTasks=30;SchedulerRpc=120;Concurrency=6;Impact='Modere';Samples=12;AverageMsPerItem=1200;MinMsPerItem=300;MaxMsPerItem=4000;SuccessPct=80;AverageBytesPerSecond=20000;AverageMbitPerSecond=0.16;PeakMbitPerSecond=0.96;AdQueriesPerSecond=0;Confidence='Haute'}
        )
        foreach($e in $estimates){
            $f=Format-DomeniaOperationImpact -Estimate $e
            $all=$f.Sentence+' '+$f.Details
            Assert-True ($all -notmatch '(?i)worker|\bRPC\b|req/s|Fallback|Parallellisme') ($e.Operation+' : '+$all)
            Assert-True ($f.Sentence -notmatch "`n") 'Phrase sur plusieurs lignes.'
        }
        $dot=' '+[string][char]0x00B7+' '
        $first=Format-DomeniaOperationImpact -Estimate $estimates[0]
        Assert-True ($first.Sentence -eq ('Environ 2 min'+$dot+'238 objet(s) lu(s) dans l'+[char]0x02BC+'annuaire'+$dot+'aucun poste contact'+[char]0xE9)) ('Phrase : '+$first.Sentence)
        Assert-True ((Format-DomeniaOperationImpact -Estimate $estimates[2]).Sentence -match '120 poste\(s\) contact') 'Postes contactes absents.'
        $script:ImpactRuns=0
        $script:CurrentUiProfile='Tech'
        [void](Request-DomeniaOperationImpact -Estimate $estimates[0] -Title 'Mettre a jour' -OnConfirm { $script:ImpactRuns++ })
        $request=$script:InlineRequests[0]
        Assert-True (($request.ConfirmText -eq 'Lancer') -and $request.DetailsExpertOnly) 'Lancer ou volet Expert absent.'
        Assert-True ($script:ImpactRuns -eq 1) ('Lancement : '+$script:ImpactRuns)
    }
    Test-Case 'SE-09 regles copiees dans le worker : fermeture complete, memes reponses' {
        Reset-WiringFixture
        $text=Get-DomeniaWorkerRulesCommon
        $ps=[PowerShell]::Create([Management.Automation.RunspaceMode]::NewRunspace)
        try {
            [void]$ps.AddScript($text+"`r`n"+@'
$r85=Resolve-DomeniaConditionalWrite -Strategy ([pscustomobject]@{Strategy='ConditionalReplace'}) -ResultCode 85
$r16=Resolve-DomeniaConditionalWrite -Strategy ([pscustomobject]@{Strategy='ConditionalReplace'}) -ResultCode 16
$pre=Test-DomeniaPreconditionCurrent -Changes @([pscustomobject]@{Attribute='manager';Kind='Replace';Before='CN=A,DC=example,DC=invalid';After='CN=B,DC=example,DC=invalid'}) -Current @{manager=@('cn=a, dc=example,dc=invalid')} -Server 'dc01'
$conf=Test-DomeniaPreconditionCurrent -Changes @([pscustomobject]@{Attribute='description';Kind='Replace';Before='x';After='y'}) -Current @{description=@('z')} -Server 'dc01'
$dn=Test-DomeniaWriteTargetDn -Dn 'CN=Services,CN=Configuration,DC=example,DC=invalid' -BaseDn 'DC=example,DC=invalid'
[pscustomobject]@{R85=[string]$r85.Outcome;R16=[string]$r16.Outcome;Pre=[bool]$pre.Current;Conf=[bool]$conf.Current;Dn=[bool]$dn.Valid;Name=[string]$dn.Name}
'@)
            $out=@($ps.Invoke())
            Assert-True ($ps.Streams.Error.Count -eq 0) ('Erreurs : '+(@($ps.Streams.Error|ForEach-Object{$_.ToString()}) -join ' | '))
            Assert-True ($out.Count -eq 1) ('Sorties : '+$out.Count)
            Assert-True (($out[0].R85 -eq 'Unknown') -and ($out[0].R16 -eq 'Conflict')) ('Codes : '+$out[0].R85+' '+$out[0].R16)
            Assert-True ($out[0].Pre -and (-not $out[0].Conf)) 'Preconditions mal lues dans le worker.'
            Assert-True ((-not $out[0].Dn) -and ($out[0].Name -eq 'Services')) 'Controle du DN absent du worker.'
        } finally { $ps.Dispose() }
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
