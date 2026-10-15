# D011-D020 : moteur. Donnees fictives uniquement.
function New-TestModule { param([string]$File,[string]$Phase='Modules',[string[]]$Requires=@(),[string[]]$Functions=@()) [pscustomobject]@{File=$File;Phase=$Phase;Requires=$Requires;Functions=$Functions} }
Test-Case 'D011' 'Plan valide : ordre respectant les dependances' {
    $plan=Test-DomeniaStartupPlan @((New-TestModule 'B.ps1' 'Modules' @('A.ps1') @('Get-B')),(New-TestModule 'A.ps1' 'Resources' @() @('Get-A')))
    Assert-True $plan.Valid ($plan.Errors -join ';')
    Assert-True ([Array]::IndexOf($plan.Order,'A.ps1') -lt [Array]::IndexOf($plan.Order,'B.ps1'))
}
Test-Case 'D011' 'Dependance absente refusee avant tout import' {
    $plan=Test-DomeniaStartupPlan @((New-TestModule 'B.ps1' 'Modules' @('Absent.ps1')))
    Assert-False $plan.Valid;Assert-True (($plan.Errors -join ' ') -match 'absent')
}
Test-Case 'D011' 'Cycle de dependances refuse' {
    $plan=Test-DomeniaStartupPlan @((New-TestModule 'A.ps1' 'Modules' @('B.ps1')),(New-TestModule 'B.ps1' 'Modules' @('A.ps1')))
    Assert-False $plan.Valid;Assert-True (($plan.Errors -join ' ') -match 'Cycle')
}
Test-Case 'D011' 'Dependance chargee dans une phase ulterieure refusee' {
    $plan=Test-DomeniaStartupPlan @((New-TestModule 'Boot.ps1' 'Bootstrap' @('Ui.ps1')),(New-TestModule 'Ui.ps1' 'Interface'))
    Assert-False $plan.Valid
}
Test-Case 'D011' 'Deux fournisseurs pour une meme fonction refuses' {
    $plan=Test-DomeniaStartupPlan @((New-TestModule 'A.ps1' 'Modules' @() @('Get-X')),(New-TestModule 'B.ps1' 'Modules' @() @('Get-X')))
    Assert-False $plan.Valid
}
Test-Case 'D011' 'Le bootstrap ne peut pas appeler un fournisseur de la phase Modules' {
    Assert-False (Test-DomeniaPhaseCall 'Bootstrap' 'Modules');Assert-True (Test-DomeniaPhaseCall 'Interface' 'Modules');Assert-True (Test-DomeniaPhaseCall 'Modules' 'Modules')
}
$script:RowA=[pscustomobject]@{Type='Utilisateur';Name='Alex Demo';Login='alex.demo';Guid='11111111-1111-1111-1111-111111111111';DN='CN=Alex Demo,DC=example,DC=invalid';Sid='S-1-5-21-1-2-3-1104'}
Test-Case 'D012' 'Identite immuable : aucune propriete modifiable' {
    $id=New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 3 7
    Assert-Equal 'alex.demo' $id.Login
    Assert-Throws { $id.Name='Autre' } 'La propriete Name ne doit pas etre modifiable'
    Assert-Throws { $id.Guid='22222222-2222-2222-2222-222222222222' } 'Le GUID ne doit pas etre modifiable'
}
Test-Case 'D012' 'Changer le libelle ne change pas la cible' {
    $a=New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 3 7
    $renamed=$script:RowA.PSObject.Copy();$renamed.Name='Libelle modifie';$renamed.DN='CN=Autre,DC=example,DC=invalid'
    $b=New-DomeniaSelectionIdentity $renamed 'example.invalid' 'reader' 3 7
    Assert-True $a.SameObject($b);Assert-Equal $a.Key $b.Key
}
Test-Case 'D012' 'GUID absent : aucune identite' {
    $row=$script:RowA.PSObject.Copy();$row.Guid=''
    Assert-True ($null -eq (New-DomeniaSelectionIdentity $row 'example.invalid' 'reader' 1 1))
}
Test-Case 'D012' 'Compte de lecture, session ou generation differents : contexte different' {
    $a=New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 3 7
    Assert-False (Test-DomeniaIdentityCurrent $a (New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'autre' 3 7))
    Assert-False (Test-DomeniaIdentityCurrent $a (New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 4 7))
    Assert-False (Test-DomeniaIdentityCurrent $a (New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 3 8))
    Assert-True (Test-DomeniaIdentityCurrent $a (New-DomeniaSelectionIdentity $script:RowA 'example.invalid' 'reader' 3 7))
}
Test-Case 'D012' 'GUID binaire dans une collection a un element accepte' {
    $row=$script:RowA.PSObject.Copy();$row.Guid=,([guid]'11111111-1111-1111-1111-111111111111').ToByteArray()
    Assert-Equal '11111111-1111-1111-1111-111111111111' (New-DomeniaSelectionIdentity $row 'example.invalid' 'r' 1 1).Guid
}
Test-Case 'D015' 'Classes : ecriture, action explicite, selection, fond' {
    Assert-Equal 'Write' (Get-DomeniaTaskClass 'OpenAdObject' $true)
    Assert-Equal 'Selection' (Get-DomeniaTaskClass 'OpenAdObject' $false 'object')
    Assert-Equal 'Selection' (Get-DomeniaTaskClass 'LiveConsole') 'Meme corps que LiveSelectedPing, choisi apres une selection'
    Assert-Equal 'Selection' (Get-DomeniaTaskClass 'LiveSelectedPing')
    Assert-Equal 'Explicit' (Get-DomeniaTaskClass 'ReadLaps')
}
Test-Case 'D015' 'Classes : vrais identifiants du registre, actions par bouton explicites' {
    foreach($op in @('ScopeReconcile','StartupWarmCache','LiveCache','LiveDirectoryCheck','LocalStore','ReceiptStore','PresenceScan')){Assert-Equal 'Background' (Get-DomeniaTaskClass $op) $op}
    foreach($op in @('IndexBuild','LogonHarvest','ParkSweep','GlobalSearch','TreeChildren')){Assert-Equal 'Explicit' (Get-DomeniaTaskClass $op) $op}
    Assert-Equal 'Background' (Get-DomeniaTaskClass 'IndexBuild' $false '' 'Background') 'L appelant automatique le declare'
    foreach($ghost in @('ReconcileScope','StartupWarmup','IndexRefresh','ObjectChanges')){Assert-Equal 'Explicit' (Get-DomeniaTaskClass $ghost) ('Nom fantome : '+$ghost)}
}
Test-Case 'D015' 'Lectures strictement identiques : meme cle de partage' {
    $p1=[pscustomobject]@{DN='CN=A';Guid='g1'};$p2=[pscustomobject]@{Guid='g1';DN='CN=A'}
    $k1=Get-DomeniaTaskDedupKey 'OpenAdObject' 'reader' 1 2 $p1;$k2=Get-DomeniaTaskDedupKey 'OpenAdObject' 'reader' 1 2 $p2
    Assert-True ($k1 -and $k1 -ceq $k2)
}
Test-Case 'D015' 'Compte, generation ou cible differents : pas de partage' {
    $p=[pscustomobject]@{DN='CN=A'}
    $k=Get-DomeniaTaskDedupKey 'OpenAdObject' 'reader' 1 2 $p
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey 'OpenAdObject' 'autre' 1 2 $p))
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey 'OpenAdObject' 'reader' 1 3 $p))
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey 'OpenAdObject' 'reader' 1 2 ([pscustomobject]@{DN='CN=B'})))
}
Test-Case 'D015' 'Ecriture ou charge utile vivante : jamais partagee' {
    Assert-Equal '' (Get-DomeniaTaskDedupKey 'OpenAdObject' 'r' 1 1 ([pscustomobject]@{DN='x'}) $true)
    $live=[pscustomobject]@{DN='x';Progress=(New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]')}
    Assert-Equal '' (Get-DomeniaTaskDedupKey 'OpenAdObject' 'r' 1 1 $live)
    Assert-Equal '' (Get-DomeniaTaskDedupKey 'ResetPassword' 'r' 1 1 ([pscustomobject]@{DN='x'}))
}
Test-Case 'D015' 'Le fond laisse des places aux actions explicites' {
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 4 -Outstanding 4 -MaxConcurrent 6 -ReservedForeground 2).Decision
    Assert-Equal 'Start' (Test-DomeniaTaskAdmission -Class Explicit -Running 4 -Outstanding 4 -MaxConcurrent 6 -ReservedForeground 2).Decision
    Assert-Equal 'Start' (Test-DomeniaTaskAdmission -Class Selection -Running 5 -Outstanding 5 -MaxConcurrent 6).Decision
}
Test-Case 'D015' 'Saturation : lecture en attente, ecriture jamais mise en file' {
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Explicit -Running 6 -Outstanding 6 -MaxConcurrent 6).Decision
    Assert-Equal 'Start' (Test-DomeniaTaskAdmission -Class Write -Running 6 -Outstanding 6 -MaxConcurrent 6).Decision
    Assert-Equal 'Reject' (Test-DomeniaTaskAdmission -Class Write -Running 7 -Outstanding 7 -MaxConcurrent 6).Decision
    Assert-Equal 'Reject' (Test-DomeniaTaskAdmission -Class Explicit -Running 6 -Outstanding 6 -MaxConcurrent 6 -Queued 32 -MaxQueued 32).Decision
}
Test-Case 'D015' 'File : priorite puis ordre d arrivee' {
    $q=@([pscustomobject]@{Id='b1';Class='Background';Sequence=1},[pscustomobject]@{Id='s1';Class='Selection';Sequence=2},[pscustomobject]@{Id='e1';Class='Explicit';Sequence=3},[pscustomobject]@{Id='e2';Class='Explicit';Sequence=4})
    Assert-Equal 'e1' (Select-DomeniaNextQueuedTask $q -Running 5 -Outstanding 5 -MaxConcurrent 6).Id
    Assert-True ($null -eq (Select-DomeniaNextQueuedTask $q -Running 6 -Outstanding 6 -MaxConcurrent 6))
    Assert-Equal 'b1' (Select-DomeniaNextQueuedTask @($q[0]) -Running 1 -Outstanding 1 -MaxConcurrent 6).Id
    Assert-True ($null -eq (Select-DomeniaNextQueuedTask @($q[0]) -Running 4 -Outstanding 4 -MaxConcurrent 6 -ReservedForeground 2))
}
Test-Case 'D017' 'Etats exacts : attente, execution, arret demande, nettoyage' {
    $running=[pscustomobject]@{State='Running';CancelRequested=$false;Handle=[pscustomobject]@{IsCompleted=$false}}
    $stopping=[pscustomobject]@{State='Running';CancelRequested=$true;Handle=[pscustomobject]@{IsCompleted=$false}}
    $queued=[pscustomobject]@{State='Queued';CancelRequested=$false;Handle=$null}
    $detached=[pscustomobject]@{State='Running';CancelRequested=$true;Handle=[pscustomobject]@{IsCompleted=$false}}
    $s=Get-DomeniaTaskStateSummary @($running,$stopping,$queued) @($detached)
    Assert-Equal 1 $s.Running;Assert-Equal 1 $s.StopRequested;Assert-Equal 1 $s.Queued;Assert-Equal 1 $s.Cleanup
    Assert-Equal 3 $s.Active 'Un appel encore actif reste compte'
}
Test-Case 'D017' 'Un arret demande n est jamais presente comme termine' {
    $text=Get-DomeniaCancelStatusText 'Lecture X' 'StopRequested'
    Assert-True ($text -match 'encore active');Assert-False ($text -match '(?i)termin|annul[ée]e')
    Assert-True ((Get-DomeniaCancelStatusText 'Lecture X' 'Cleanup') -match 'reste compte')
    Assert-True ((Get-DomeniaCancelStatusText 'Ecriture' 'StopRequested' $true) -match 'non annulable')
}
Test-Case 'D017' 'Un worker detache termine n est plus compte' {
    $done=[pscustomobject]@{State='Running';CancelRequested=$true;Handle=[pscustomobject]@{IsCompleted=$true};StopHandle=$null}
    Assert-Equal 0 (Get-DomeniaTaskStateSummary @() @($done)).Active
    $stopDone=[pscustomobject]@{State='Running';CancelRequested=$true;Handle=[pscustomobject]@{IsCompleted=$true};StopHandle=[pscustomobject]@{IsCompleted=$true}}
    Assert-Equal 0 (Get-DomeniaTaskStateSummary @() @($stopDone)).Active
}
Test-Case 'D017' 'Arret encore en cours : le detache reste en nettoyage' {
    $stopping=[pscustomobject]@{State='Running';CancelRequested=$true;Handle=[pscustomobject]@{IsCompleted=$true};StopHandle=[pscustomobject]@{IsCompleted=$false}}
    Assert-Equal 'Cleanup' (Get-DomeniaTaskState $stopping $true)
    Assert-Equal 1 (Get-DomeniaTaskStateSummary @() @($stopping)).Cleanup
}
$script:T0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
Test-Case 'D018' 'Refus d identifiants : aucun nouvel essai, meme explicite' {
    $s=New-DomeniaProviderState
    [void](Register-DomeniaProviderOutcome $s 'Directory' 'dc1' 'CredentialRejected' $script:T0)
    Assert-False (Test-DomeniaProviderAdmission $s 'Directory' 'dc1' 'Explicit' 0 $script:T0.AddHours(2)).Allowed
    Assert-False (Test-DomeniaAutoRetryAllowed $false 'CredentialRejected' 0)
    Reset-DomeniaProviderState $s 'Directory'
    Assert-True (Test-DomeniaProviderAdmission $s 'Directory' 'dc1' 'Explicit' 0 $script:T0).Allowed
}
Test-Case 'D018' 'Pannes repetees : le fond est suspendu, l action explicite reste possible' {
    $s=New-DomeniaProviderState
    foreach($i in 1..2){[void](Register-DomeniaProviderOutcome $s 'Cim' 'pc1' 'Timeout' $script:T0)}
    $bg=Test-DomeniaProviderAdmission $s 'Cim' 'pc1' 'Background' 0 $script:T0.AddSeconds(10)
    Assert-False $bg.Allowed;Assert-True ($null -ne $bg.RetryAfterUtc)
    Assert-True (Test-DomeniaProviderAdmission $s 'Cim' 'pc1' 'Explicit' 0 $script:T0.AddSeconds(10)).Allowed
    Assert-True (Test-DomeniaProviderAdmission $s 'Cim' 'pc2' 'Background' 0 $script:T0.AddSeconds(10)).Allowed 'Une autre cible n est pas penalisee'
    Assert-True (Test-DomeniaProviderAdmission $s 'Cim' 'pc1' 'Background' 0 $script:T0.AddHours(1)).Allowed 'La temporisation expire'
}
Test-Case 'D018' 'Pannes repetees : une lecture causee par une selection reste envoyee' {
    $s=New-DomeniaProviderState
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome $s 'Directory' '' 'Failure' $script:T0)}
    Assert-False (Test-DomeniaProviderAdmission $s 'Directory' '' 'Background' 0 $script:T0.AddSeconds(5)).Allowed 'Fond non suspendu'
    Assert-True (Test-DomeniaProviderAdmission $s 'Directory' '' 'Selection' 0 $script:T0.AddSeconds(5)).Allowed 'Ouverture d objet refusee pendant la temporisation'
    Assert-True (Test-DomeniaProviderAdmission $s 'Directory' '' 'Write' 0 $script:T0.AddSeconds(5)).Allowed
}
Test-Case 'D018' 'Temporisation croissante et bornee' {
    $s=New-DomeniaProviderState
    $prev=[datetime]::MinValue
    foreach($i in 1..12){$e=Register-DomeniaProviderOutcome $s 'Cim' 'pc1' 'Failure' $script:T0}
    Assert-True (($e.BackoffUntilUtc-$script:T0).TotalSeconds -le 600)
    [void](Register-DomeniaProviderOutcome $s 'Cim' 'pc1' 'Success' $script:T0)
    Assert-True (Test-DomeniaProviderAdmission $s 'Cim' 'pc1' 'Background' 0 $script:T0).Allowed
}
Test-Case 'D018' 'Une ecriture n est jamais rejouee' {
    Assert-False (Test-DomeniaAutoRetryAllowed $true 'Timeout' 0);Assert-True (Test-DomeniaAutoRetryAllowed $false 'Timeout' 0);Assert-False (Test-DomeniaAutoRetryAllowed $false 'Timeout' 1)
}
Test-Case 'D018' 'Fournisseurs distincts par operation' {
    Assert-Equal 'Cim' (Get-DomeniaOperationProvider 'ComputerInventory');Assert-Equal 'Wts' (Get-DomeniaOperationProvider 'SessionsList')
    Assert-Equal 'Storage' (Get-DomeniaOperationProvider 'LocalStore');Assert-Equal 'Directory' (Get-DomeniaOperationProvider 'GlobalSearch')
}
Test-Case 'D018' 'Actions distantes sur un poste : jamais budgetees comme l annuaire' {
    foreach($op in @('ComputerGpUpdate','ComputerRestart','RimotteRun','UserComputerProbe','RemoteCredentialCheck')){Assert-Equal 'Cim' (Get-DomeniaOperationProvider $op) $op}
}
Test-Case 'D018' 'Refus d identifiants : bloque ce compte, pas un autre compte choisi explicitement' {
    $s=New-DomeniaProviderState
    [void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target 'pc1' -Outcome 'CredentialRejected' -NowUtc $script:T0 -Identity 'EXAMPLE\poste')
    Assert-False (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc1' -Class 'Explicit' -NowUtc $script:T0 -Identity 'example\POSTE').Allowed
    Assert-False (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc1' -Class 'Explicit' -NowUtc $script:T0).Allowed 'Compte inconnu : refuse'
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc1' -Class 'Explicit' -NowUtc $script:T0 -Identity 'EXAMPLE\autre').Allowed
    [void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target 'pc1' -Outcome 'Success' -NowUtc $script:T0 -Identity 'EXAMPLE\autre')
    Assert-False (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc1' -Class 'Explicit' -NowUtc $script:T0 -Identity 'EXAMPLE\poste').Allowed 'Le compte rejete reste bloque'
}
Test-Case 'D018' 'Issue d un worker : refus, identifiants, delai, annulation' {
    Assert-Equal 'CredentialRejected' (ConvertTo-DomeniaProviderOutcome -ErrorKind 'LogonFailure' -Failed $true)
    Assert-Equal 'CredentialRejected' (ConvertTo-DomeniaProviderOutcome -ErrorKind 'AccountLocked' -Failed $true)
    Assert-Equal 'AccessDenied' (ConvertTo-DomeniaProviderOutcome -ErrorKind 'AccessDenied' -Failed $true)
    Assert-Equal 'Failure' (ConvertTo-DomeniaProviderOutcome -ErrorKind 'Unknown' -Failed $true)
    Assert-Equal 'Timeout' (ConvertTo-DomeniaProviderOutcome -TimedOut $true)
    Assert-Equal 'Cancelled' (ConvertTo-DomeniaProviderOutcome -Cancelled $true -Failed $true)
    Assert-Equal 'Success' (ConvertTo-DomeniaProviderOutcome)
}
# Golden copy of the historical lists of Get-WorkerContext (RC1.10.7).
$script:LegacyRemote=@('SessionsList','ComputerDiagnostics','ComputerLastUser','LiveConsole','ComputerPing','ComputerGpUpdate','ComputerRestart','ComputerInventory','SoftwareInventory','ParkSweep','BatchNetworkDiag','WmiNamespaces','WmiClasses','WmiQuery','RimotteRun')
$script:LegacyMachine=@('SessionsList','ComputerDiagnostics','ComputerInventory','SoftwareInventory','ParkSweep','WmiNamespaces','WmiClasses','WmiQuery','ComputerLastUser','LiveConsole','ComputerGpUpdate','ComputerRestart','UserComputerProbe','RimotteRun')
$script:LegacyNonDirectory=@('CmdletHelp','CmdletInventory','EngineSelfTest','LiveCache','LiveSelectedPing','LocalStore','ReceiptStore','SessionsList','DocumentStore','EmbeddedPathBrowse')+$script:LegacyRemote
$script:RegistryOps=@('CmdletHelp','TreeChildren','GlobalSearch','PermissionAnalysis','SelfCheck','ReadBitLocker','ReadLaps','DomainOverview','BatchNetworkDiag','WmiNamespaces','WmiClasses','WmiQuery','SoftwareInventory','LogonHarvest','ParkSweep','IndexBuild','UserComputerProbe','ComputerInventory','ComputerDiagnostics','ComputerLastUser','CmdletInventory','ComputerPing','ComputerGpUpdate','ComputerRestart','RimotteRun','PruneLinks','OpenLinkedObject','OpenAdObject','WriteAttributes','WriteAccountDisabled','WriteUnlock','WriteResetPassword','WriteAccountOptions','WriteExpiration','WriteExpirePassword','WriteMoveObject','WriteObjectGroup','WriteGroupMember','WriteRenameComputer','WriteCreateOu','WriteDeleteObject','PresenceScan','SelectedPresence','StartupWarmCache','LiveSelectedPing','LiveConsole','LiveCache','LiveDirectoryCheck','SessionsList','RemoteCredentialCheck','ReceiptStore','ScopeReconcile','DocumentStore','LocalStore','EngineSelfTest','EmbeddedDirectoryLookup','EmbeddedPathBrowse')
Test-Case 'D018' 'C3 : table des besoins identique aux listes historiques (57 operations)' {
    Assert-Equal 57 $script:RegistryOps.Count
    foreach($op in $script:RegistryOps){
        $n=Get-DomeniaOperationCredentialNeeds $op
        $legacyDirectory=(($op -in @('ComputerLastUser','LiveConsole')) -or $script:LegacyNonDirectory -notcontains $op)
        Assert-Equal $legacyDirectory ([bool]$n.Directory) ('Directory '+$op)
        Assert-Equal ($legacyDirectory -or $op -eq 'ReceiptStore') ([bool]$n.DirectoryCredential) ('DirectoryCredential '+$op)
        Assert-Equal ($script:LegacyMachine -contains $op) ([bool]$n.Machine) ('Machine '+$op)
        Assert-Equal (($script:LegacyRemote -contains $op) -or ($script:LegacyMachine -contains $op)) ([bool]$n.RemoteAdmin) ('RemoteAdmin '+$op)
        Assert-Equal ($op -in @('ReadBitLocker','ReadLaps')) ([bool]$n.Secrets) ('Secrets '+$op)
        Assert-Equal ($script:LegacyNonDirectory -contains $op) ([bool]$n.NonDirectory) ('NonDirectory '+$op)
    }
}
Test-Case 'D018' 'C3 : un refus WTS ou stockage ne suspend jamais le canal AD' {
    foreach($op in @('SessionsList','LocalStore','ReceiptStore','DocumentStore','EmbeddedPathBrowse','LiveConsole','ComputerLastUser','ComputerGpUpdate')){Assert-False (Get-DomeniaOperationCredentialNeeds $op).DirectoryBreaker $op}
    foreach($op in @('GlobalSearch','OpenAdObject','TreeChildren','UserComputerProbe')){Assert-True (Get-DomeniaOperationCredentialNeeds $op).DirectoryBreaker $op}
    foreach($op in @('DemoDirectory','LocalIndexRead','ParkSharedSync','IsolatedRead')){$n=Get-DomeniaOperationCredentialNeeds $op;Assert-False $n.Directory $op;Assert-False $n.DirectoryCredential $op;Assert-False $n.RemoteAdmin $op}
    # Query packs, scripts and the import journal are local files: never the AD account, never a remote target.
    foreach($op in @('LocalQuery','QueryExport','QueryLibrary','QueryTransfer')){$n=Get-DomeniaOperationCredentialNeeds $op;Assert-False $n.Directory $op;Assert-False $n.DirectoryCredential $op;Assert-False $n.RemoteAdmin $op;Assert-Equal 'Storage' $n.Provider $op;Assert-Equal 'Local' $n.Resource $op}
    Assert-Equal 'Laps' (Get-DomeniaOperationCredentialNeeds 'ReadLaps').Resource;Assert-Equal 'Remote' (Get-DomeniaOperationCredentialNeeds 'SessionsList').Resource
}
Test-Case 'D051' 'C3 : liste et cle BitLocker classees comme ReadBitLocker (compte Secrets, ressource BitLocker)' {
    $ref=Get-DomeniaOperationCredentialNeeds 'ReadBitLocker'
    foreach($op in @('ReadBitLockerList','ReadBitLockerKey')){
        $n=Get-DomeniaOperationCredentialNeeds $op
        foreach($field in @('Directory','DirectoryCredential','Machine','RemoteAdmin','Secrets','NonDirectory','Resource')){Assert-Equal ([string]$ref.$field) ([string]$n.$field) ($field+' '+$op)}
    }
}
Test-Case 'D015' 'File : une lecture qui attend trop longtemps est retiree' {
    Assert-True (Test-DomeniaQueuedTaskExpired -QueuedAt $script:T0 -MaxWaitSeconds 120 -Now $script:T0.AddSeconds(121))
    Assert-False (Test-DomeniaQueuedTaskExpired -QueuedAt $script:T0 -MaxWaitSeconds 120 -Now $script:T0.AddSeconds(30))
    Assert-False (Test-DomeniaQueuedTaskExpired -QueuedAt $null)
}
Test-Case 'D016' 'Isolement : desactive par defaut, jamais pour une ecriture ni un compte explicite' {
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -PayloadDigest 'x').Isolate
    Assert-True (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -Enabled $true -PayloadDigest 'x').Isolate
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -Enabled $true -IsWrite $true -PayloadDigest 'x').Isolate
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -Enabled $true -HasCredential $true -PayloadDigest 'x').Isolate
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -Enabled $true -PayloadDigest '').Isolate 'Charge vivante'
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'WriteAttributes' -Enabled $true -PayloadDigest 'x').Isolate
    Assert-False (Get-DomeniaIsolationDecision -OperationId 'ComputerPing' -Enabled $true -PayloadDigest 'x' -DemoMode $true).Isolate
}
Test-Case 'D019' 'Chaque ressource a un proprietaire et un nettoyage, meme apres une erreur' {
    $r=New-DomeniaResourceRegistry;$script:Freed=0
    [void](Register-DomeniaResource $r 'Relations' 'Timer' 'x' {param($x)$script:Freed++})
    [void](Register-DomeniaResource $r 'Relations' 'CimSession' 'y' {param($x)throw 'liberation impossible'})
    [void](Register-DomeniaResource $r 'Recherche' 'Timer' 'z' {param($x)$script:Freed++})
    $result=Release-DomeniaResources $r 'Relations'
    Assert-Equal 1 $result.Released;Assert-Equal 1 $result.Failed;Assert-Equal 1 (Get-DomeniaResourceSummary $r).Total
    [void](Release-DomeniaResources $r);Assert-Equal 0 (Get-DomeniaResourceSummary $r).Total;Assert-Equal 2 $script:Freed
}
Test-Case 'D019' 'Liberation par nature : les minuteurs sans les jobs actifs' {
    $r=New-DomeniaResourceRegistry;$script:Stopped=0
    [void](Register-DomeniaResource $r 'Timer:A' 'Timer' 'a' {param($x)$script:Stopped++})
    [void](Register-DomeniaResource $r 'job-1' 'PowerShell' 'p' {param($x)throw 'ne doit pas etre libere'})
    $result=Release-DomeniaResources -Registry $r -Kind 'Timer'
    Assert-Equal 1 $result.Released;Assert-Equal 0 $result.Failed;Assert-Equal 1 $script:Stopped
    Assert-Equal 1 (Get-DomeniaResourceSummary $r).Total 'Le job actif reste detenu'
}
Test-Case 'D019' 'Longue session avec annulations : retour a un niveau stable' {
    $r=New-DomeniaResourceRegistry
    foreach($i in 1..200){$id=Register-DomeniaResource $r ('Tache'+$i) 'Abonnement' (New-Object IO.MemoryStream) $null;[void](Release-DomeniaResources $r ('Tache'+$i))}
    Assert-Equal 0 (Get-DomeniaResourceSummary $r).Total;Assert-Equal 200 $r.Released
}
Test-Case 'D020' 'Fenetre inactive ou reduite : aucun rafraichissement de fond' {
    $p=Get-DomeniaIdlePolicy -WindowActive $false -VisiblePage 'WsSearch'
    Assert-False (Test-DomeniaIdleAllows $p 'Presence');Assert-False (Test-DomeniaIdleAllows $p 'Reconcile')
    Assert-False (Test-DomeniaIdleAllows (Get-DomeniaIdlePolicy -Minimized $true) 'Dashboard')
}
Test-Case 'UX-30' 'Fenetre inactive mais visible : la vue affichee reste a jour, les lectures reseau de fond attendent' {
    $p=Get-DomeniaIdlePolicy -WindowActive $false -VisiblePage 'TabDashboard'
    Assert-True (Test-DomeniaIdleAllows $p 'ViewRebuild' 'TabDashboard') 'Accueil visible sur un second ecran non recalcule'
    $dash=Get-DomeniaIdleActivityForSource 'Dashboard';Assert-True (Test-DomeniaIdleAllows $p $dash.Activity $dash.Page)
    Assert-False (Test-DomeniaIdleAllows $p 'Presence') 'Lecture reseau de fond autorisee fenetre inactive'
    Assert-True ([bool]$p.Visible -and -not [bool]$p.AllowBackgroundRefresh)
}
Test-Case 'UX-30' 'Fenetre reduite ou masquee : recalcul de vue suspendu' {
    foreach($p in @((Get-DomeniaIdlePolicy -WindowActive $false -Minimized $true -VisiblePage 'TabDashboard'),(Get-DomeniaIdlePolicy -WindowActive $true -Hidden $true -VisiblePage 'TabDashboard'))){
        Assert-False (Test-DomeniaIdleAllows $p 'ViewRebuild' 'TabDashboard');Assert-False (Test-DomeniaIdleAllows $p 'Presence')
        Assert-True (Test-DomeniaIdleAllows $p 'Storage') 'Sauvegarde suspendue'
    }
}
Test-Case 'FI-03' 'Ecriture admise malgre 12 lectures detachees, sur sa place reservee' {
    $w=Test-DomeniaTaskAdmission -Class Write -Running 0 -Outstanding 12 -MaxConcurrent 6 -MaxOutstanding 12
    Assert-Equal 'Start' $w.Decision;Assert-True ([string]$w.Reason -match 'partira') 'Message de place reservee absent'
    Assert-Equal 'Start' (Test-DomeniaTaskAdmission -Class Write -Running 1 -Outstanding 13 -MaxConcurrent 6 -MaxOutstanding 12).Decision
    Assert-Equal 'Reject' (Test-DomeniaTaskAdmission -Class Write -Running 0 -Outstanding 14 -MaxConcurrent 6 -MaxOutstanding 12).Decision
    Assert-Equal '' ([string](Test-DomeniaTaskAdmission -Class Write -Running 0 -Outstanding 3 -MaxConcurrent 6 -MaxOutstanding 12).Reason)
}
Test-Case 'FI-03' 'Action explicite : une place reservee ; lectures de fond et de selection plafonnees' {
    Assert-Equal 'Start' (Test-DomeniaTaskAdmission -Class Explicit -Running 0 -Outstanding 12 -MaxConcurrent 6 -MaxOutstanding 12).Decision
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Explicit -Running 0 -Outstanding 13 -MaxConcurrent 6 -MaxOutstanding 12).Decision
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Selection -Running 0 -Outstanding 12 -MaxConcurrent 6 -MaxOutstanding 12).Decision
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 0 -Outstanding 12 -MaxConcurrent 6 -MaxOutstanding 12).Decision
}
Test-Case 'MO-05' 'Fournisseur sature : candidat saute et garde en file, un autre fournisseur part' {
    $q=@([pscustomobject]@{Id='cache';Class='Background';Sequence=1;Provider='Storage';ProviderTarget=''},[pscustomobject]@{Id='presence';Class='Background';Sequence=2;Provider='Network';ProviderTarget='pc1'})
    $load=@{Storage=1}
    Assert-Equal 'presence' (Select-DomeniaNextQueuedTask $q -Running 1 -Outstanding 1 -MaxConcurrent 6 -ProviderLoad $load -ProviderState (New-DomeniaProviderState)).Id
    Assert-True ($null -eq (Select-DomeniaNextQueuedTask @($q[0]) -Running 1 -Outstanding 1 -MaxConcurrent 6 -ProviderLoad $load -ProviderState (New-DomeniaProviderState))) 'Candidat sature promu'
    Assert-Equal 'cache' (Select-DomeniaNextQueuedTask @($q[0]) -Running 1 -Outstanding 1 -MaxConcurrent 6 -ProviderLoad @{} -ProviderState (New-DomeniaProviderState)).Id
}
Test-Case 'MO-05' 'Refus durable : le candidat est rendu pour que son depart signale l erreur' {
    $s=New-DomeniaProviderState
    [void](Register-DomeniaProviderOutcome $s 'Directory' '' 'CredentialRejected' $script:T0)
    $q=@([pscustomobject]@{Id='read';Class='Background';Sequence=1;Provider='Directory';ProviderTarget=''})
    $r=Test-DomeniaProviderAdmission $s 'Directory' '' 'Background' 0 $script:T0
    Assert-False $r.Allowed;Assert-True ([bool]$r.Durable)
    Assert-Equal 'read' (Select-DomeniaNextQueuedTask $q -Running 0 -Outstanding 0 -MaxConcurrent 6 -ProviderLoad @{} -ProviderState $s -NowUtc $script:T0).Id
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome $s 'Cim' 'pc1' 'Failure' $script:T0)}
    $b=Test-DomeniaProviderAdmission $s 'Cim' 'pc1' 'Background' 0 $script:T0.AddSeconds(1)
    Assert-False $b.Allowed;Assert-False ([bool]$b.Durable) 'Une temporisation est un refus durable'
}
Test-Case 'PF-04' 'Ordre de traitement : ecriture, action explicite, selection, fond, puis arrivee' {
    $jobs=@([pscustomobject]@{Id='b';Class='Background';Sequence=1},[pscustomobject]@{Id='s';Class='Selection';Sequence=2},[pscustomobject]@{Id='e2';Class='Explicit';Sequence=5},[pscustomobject]@{Id='w';Class='Write';Sequence=9},[pscustomobject]@{Id='e1';Class='Explicit';Sequence=3})
    Assert-Equal 'w,e1,e2,s,b' ((@(Get-DomeniaTaskOrder -Jobs $jobs)|ForEach-Object{$_.Id}) -join ',')
}
Test-Case 'CO-02' 'Seules les taches de premier plan pilotent Annuler et la barre' {
    foreach($c in @('Write','Explicit','Selection')){Assert-True (Test-DomeniaForegroundTaskClass $c) $c}
    Assert-False (Test-DomeniaForegroundTaskClass 'Background');Assert-False (Test-DomeniaForegroundTaskClass '')
    Assert-Equal 'Background' (Get-DomeniaTaskClass -OperationId 'LocalStore')
}
Test-Case 'PF-06' 'Pulsation : aucun abonne actif, aucun reveil ; fenetre reduite, seuls taches et sauvegardes' {
    Assert-Equal -1 (Get-DomeniaPulseDelay -Subscribers @() -NowMs 100)
    Assert-Equal -1 (Get-DomeniaPulseDelay -Subscribers @([pscustomobject]@{Enabled=$false;DueMs=150;IntervalMs=80;RunWhenHidden=$false}) -NowMs 100)
    $live=[pscustomobject]@{Enabled=$true;DueMs=1100;IntervalMs=1000;RunWhenHidden=$false}
    $async=[pscustomobject]@{Enabled=$true;DueMs=1350;IntervalMs=250;RunWhenHidden=$true}
    Assert-Equal 100 (Get-DomeniaPulseDelay -Subscribers @($live,$async) -NowMs 1000)
    Assert-Equal 350 (Get-DomeniaPulseDelay -Subscribers @($live,$async) -NowMs 1000 -Hidden $true)
    Assert-Equal -1 (Get-DomeniaPulseDelay -Subscribers @($live) -NowMs 1000 -Hidden $true)
    Assert-Equal 15 (Get-DomeniaPulseDelay -Subscribers @($live) -NowMs 1200 -MinimumMs 15)
}
Test-Case 'PF-06' 'Pulsation : un abonne proche de son echeance partage le reveil courant' {
    $s=[pscustomobject]@{Enabled=$true;DueMs=1080;IntervalMs=1000;RunWhenHidden=$false}
    Assert-True (Test-DomeniaPulseDue $s 1000) 'Echeance a 80 ms d un abonne de 1 s non regroupee'
    Assert-False (Test-DomeniaPulseDue $s 900)
    Assert-False (Test-DomeniaPulseDue ([pscustomobject]@{Enabled=$true;DueMs=1030;IntervalMs=80;RunWhenHidden=$false}) 1000) 'Abonne rapide regroupe trop tot'
    Assert-False (Test-DomeniaPulseDue $s 1000 $true) 'Abonne suspendu fenetre reduite'
}
Test-Case 'D020' 'Recus et sauvegardes en cours restent suivis' {
    $p=Get-DomeniaIdlePolicy -WindowActive $false -WriteInFlight $true -PendingSaves 3
    Assert-True (Test-DomeniaIdleAllows $p 'Receipts');Assert-True (Test-DomeniaIdleAllows $p 'Storage');Assert-True (Test-DomeniaIdleAllows $p 'Explicit')
}
Test-Case 'D020' 'Une page cachee ne se reconstruit pas et ne lance pas son rafraichissement' {
    $p=Get-DomeniaIdlePolicy -WindowActive $true -VisiblePage 'WsSearch'
    Assert-False (Test-DomeniaIdleAllows $p 'ViewRebuild' 'TabDashboard');Assert-False (Test-DomeniaIdleAllows $p 'Dashboard' 'TabDashboard')
    Assert-True (Test-DomeniaIdleAllows $p 'Presence' 'WsSearch')
}
Test-Case 'D020' 'Sources de travail de fond : correspondance avec la politique de repos' {
    $p=Get-DomeniaIdlePolicy -WindowActive $false -VisiblePage 'WsSearch'
    foreach($src in @('Live','Reconcile','ObjectChanges','Dashboard','Index','Park')){$a=Get-DomeniaIdleActivityForSource $src;Assert-False (Test-DomeniaIdleAllows $p $a.Activity $a.Page) $src}
    $active=Get-DomeniaIdlePolicy -WindowActive $true -VisiblePage 'WsSearch'
    $live=Get-DomeniaIdleActivityForSource 'Live';Assert-True (Test-DomeniaIdleAllows $active $live.Activity $live.Page)
    $dash=Get-DomeniaIdleActivityForSource 'Dashboard';Assert-False (Test-DomeniaIdleAllows $active $dash.Activity $dash.Page) 'Accueil cache : pas de reconstruction'
    $st=Get-DomeniaIdleActivityForSource 'Storage';Assert-True (Test-DomeniaIdleAllows $p $st.Activity $st.Page) 'Sauvegardes toujours suivies'
}

Test-Case 'D029' 'Mesure et purge locales ne recoivent aucun compte annuaire' {
    foreach($operation in @('StorageUsage','StoragePurge')){
        $needs=Get-DomeniaOperationCredentialNeeds $operation
        Assert-False $needs.Directory;Assert-False $needs.DirectoryCredential
        Assert-False $needs.RemoteAdmin;Assert-False $needs.Machine;Assert-False $needs.Secrets
        Assert-True $needs.NonDirectory;Assert-Equal 'Local' $needs.Resource
        Assert-Equal 'Storage' (Get-DomeniaOperationProvider $operation)
    }
}

# ---------------------------------------------------------------- points 12, 15, 16, 17 et 160 (collecte adaptee)
$script:ET0=[datetime]::SpecifyKind([datetime]'2026-10-14T10:00:00',[DateTimeKind]::Utc)
Test-Case 'P12' 'Partage : un autre compte, un autre délai ou une autre classe ne partagent jamais la lecture' {
    $r1=Get-DomeniaTaskReaderIdentity -BindUser 'EXAMPLE\lecteur' -ProcessIdentity 'EXAMPLE\op' -AccountGeneration 3
    $r2=Get-DomeniaTaskReaderIdentity -BindUser 'EXAMPLE\lecteur' -ProcessIdentity 'EXAMPLE\op' -AccountGeneration 4
    Assert-True ($r1 -cne $r2) 'Changement de compte distant ou secret : nouvelle génération'
    Assert-Equal $r1 (Get-DomeniaTaskReaderIdentity -BindUser 'example\LECTEUR' -ProcessIdentity 'EXAMPLE\op' -AccountGeneration 3) 'Casse du compte sans effet'
    Assert-Equal $r1 (Get-DomeniaTaskReaderIdentity -Reader 'EXAMPLE\lecteur' -BindUser 'EXAMPLE\autre' -ProcessIdentity 'EXAMPLE\op' -AccountGeneration 3) 'Le lecteur nommé par lʼappelant prime'
    $q1=Get-DomeniaTaskRequirements -TimeoutSeconds 30 -TaskClass 'Selection'
    $k=Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r1 -Epoch 1 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements $q1
    Assert-True ([bool]$k)
    Assert-Equal $k (Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r1 -Epoch 1 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements $q1) 'Lecture strictement identique : même clé'
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r2 -Epoch 1 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements $q1)) 'Autre compte'
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r1 -Epoch 1 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements (Get-DomeniaTaskRequirements -TimeoutSeconds 60 -TaskClass 'Selection'))) 'Autre délai'
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r1 -Epoch 1 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements (Get-DomeniaTaskRequirements -TimeoutSeconds 30 -TaskClass 'Background'))) 'Autre classe'
    Assert-True ($k -cne (Get-DomeniaTaskDedupKey -OperationId 'OpenAdObject' -ReaderIdentity $r1 -Epoch 2 -Generation 2 -Payload ([pscustomobject]@{DN='CN=A'}) -Requirements $q1)) 'Autre session'
}
Test-Case 'P16' 'Fond en longue attente : une place réservée lui est accordée, jamais au-delà du plafond' {
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 5 -Outstanding 5 -MaxConcurrent 6 -ReservedForeground 2 -WaitedSeconds 31 -BackgroundRunning 1).Decision 'Un autre travail de fond tourne déjà'
    $aged=Test-DomeniaTaskAdmission -Class Background -Running 5 -Outstanding 5 -MaxConcurrent 6 -ReservedForeground 2 -WaitedSeconds 31 -BackgroundRunning 0
    Assert-Equal 'Start' $aged.Decision; Assert-True ([bool]$aged.Aged)
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 6 -Outstanding 6 -MaxConcurrent 6 -WaitedSeconds 300 -BackgroundRunning 0).Decision 'Jamais au-delà du plafond'
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 5 -Outstanding 5 -MaxConcurrent 6 -WaitedSeconds 10 -BackgroundRunning 0).Decision 'Attente trop courte'
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 5 -Outstanding 5 -MaxConcurrent 6 -WaitedSeconds 300).Decision 'Sans mesure : décision historique'
    Assert-Equal 'Queue' (Test-DomeniaTaskAdmission -Class Background -Running 4 -Outstanding 12 -MaxConcurrent 6 -MaxOutstanding 12 -WaitedSeconds 300 -BackgroundRunning 0).Decision 'Limite physique respectée'
}
Test-Case 'P16' 'File : le travail de fond le plus ancien passe devant après son attente, sinon lʼaction explicite garde la priorité' {
    $now=[datetime]'2026-10-14T10:00:00'
    $q=@([pscustomobject]@{Id='b1';Class='Background';Sequence=1;QueuedAt=$now.AddSeconds(-45)},[pscustomobject]@{Id='e1';Class='Explicit';Sequence=2;QueuedAt=$now.AddSeconds(-1)})
    Assert-Equal 'b1' (Select-DomeniaNextQueuedTask $q -Running 5 -Outstanding 5 -MaxConcurrent 6 -BackgroundRunning 0 -Now $now).Id
    Assert-Equal 'e1' (Select-DomeniaNextQueuedTask $q -Running 5 -Outstanding 5 -MaxConcurrent 6 -BackgroundRunning 1 -Now $now).Id
    Assert-Equal 'e1' (Select-DomeniaNextQueuedTask $q -Running 5 -Outstanding 5 -MaxConcurrent 6 -Now $now).Id 'Sans mesure : priorité historique'
    Assert-Equal 'e1' (Select-DomeniaNextQueuedTask $q -Running 2 -Outstanding 2 -MaxConcurrent 6 -BackgroundRunning 0 -Now $now.AddSeconds(-20)).Id 'Attente encore courte'
}
Test-Case 'P16' 'Fond en longue attente : départ malgré le budget du fournisseur ou du site occupé, jamais par-dessus une pause' {
    $now=[datetime]'2026-10-14T10:00:00'
    $bg=[pscustomobject]@{Id='fond';Class='Background';Sequence=1;Provider='Directory';ProviderTarget='';ProviderGroup='dc01.example.test';QueuedAt=$now.AddSeconds(-45)}
    $load=@{Directory=4};$sources=@{'Directory|'=4;'Directory|group:dc01.example.test'=4}
    $entry=Select-DomeniaNextQueuedEntry @($bg) -Running 5 -Outstanding 5 -MaxConcurrent 6 -ProviderLoad $load -ProviderState (New-DomeniaProviderState) -BackgroundRunning 0 -Now $now -SourceLoad $sources
    Assert-True ($null -ne $entry) 'Fournisseur occupé par des actions explicites : le fond attend sans fin'
    Assert-Equal 'fond' $entry.Task.Id;Assert-True ([bool]$entry.Aged) 'Démarrage non attribué à lʼattente'
    Assert-True ($null -eq (Select-DomeniaNextQueuedEntry @($bg) -Running 5 -Outstanding 5 -MaxConcurrent 6 -ProviderLoad $load -ProviderState (New-DomeniaProviderState) -BackgroundRunning 1 -Now $now -SourceLoad $sources)) 'Un autre travail de fond tourne : pas dʼexception'
    $full=Select-DomeniaNextQueuedEntry @($bg) -Running 5 -Outstanding 5 -MaxConcurrent 6 -ProviderLoad @{Directory=5} -ProviderState (New-DomeniaProviderState) -BackgroundRunning 0 -Now $now -SourceLoad @{'Directory|'=5;'Directory|group:dc01.example.test'=5}
    Assert-True (($null -ne $full) -and [bool]$full.Aged) 'Actions explicites au-delà du budget du fournisseur : le fond attend sans fin'
    $paused=New-DomeniaProviderState
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome -State $paused -Provider 'Directory' -Target '' -Outcome 'Failure' -NowUtc $now.ToUniversalTime())}
    Assert-True ($null -eq (Select-DomeniaNextQueuedEntry @($bg) -Running 1 -Outstanding 1 -MaxConcurrent 6 -ProviderLoad @{} -ProviderState $paused -NowUtc $now.ToUniversalTime().AddSeconds(5) -BackgroundRunning 0 -Now $now -SourceLoad @{})) 'Pause du fournisseur contournée'
    $fresh=Select-DomeniaNextQueuedEntry @($bg) -Running 1 -Outstanding 1 -MaxConcurrent 6 -ProviderLoad @{} -ProviderState (New-DomeniaProviderState) -BackgroundRunning 0 -Now $now -SourceLoad @{}
    Assert-False ([bool]$fresh.Aged) 'Place libre : départ ordinaire, non compté comme exception'
    $within=Test-DomeniaProviderAdmission -State (New-DomeniaProviderState) -Provider 'Cim' -Target 'pc1' -Class 'Background' -RunningForProvider 3 -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 2 -Aged $true
    Assert-True $within.Allowed;Assert-True ([bool]$within.Aged)
    Assert-False (Test-DomeniaProviderAdmission -State (New-DomeniaProviderState) -Provider 'Cim' -Target 'pc1' -Class 'Background' -RunningForProvider 3 -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 2).Allowed 'Sans attente : budget du fournisseur appliqué'
    Assert-False ([bool](Test-DomeniaProviderAdmission -State (New-DomeniaProviderState) -Provider 'Cim' -Target 'pc1' -Class 'Background' -RunningForProvider 0 -Aged $true).Aged) 'Exception signalée sans être utilisée'
}
Test-Case 'P16' 'Charge simulée : sous une rafale dʼactions explicites, le travail de fond démarre après son attente et pas avant' {
    # Six places, cinq lectures explicites longues, puis une nouvelle lecture explicite par seconde de trois secondes.
    $simulate={param([int]$BackgroundRunningMode)
        $start=[datetime]'2026-10-14T10:00:00'
        $running=New-Object System.Collections.ArrayList;$queue=New-Object System.Collections.ArrayList
        for($i=0;$i -lt 5;$i++){[void]$running.Add([pscustomobject]@{Class='Explicit';EndsAt=$start.AddSeconds(500)})}
        [void]$queue.Add([pscustomobject]@{Id='fond';Class='Background';Sequence=0;QueuedAt=$start})
        $sequence=1;$startedAt=-1
        for($t=0;$t -lt 90;$t++){
            $clock=$start.AddSeconds($t)
            foreach($job in @($running.ToArray())){if($job.EndsAt -le $clock){[void]$running.Remove($job)}}
            [void]$queue.Add([pscustomobject]@{Id=('e'+$sequence);Class='Explicit';Sequence=$sequence;QueuedAt=$clock});$sequence++
            for($guard=0;$guard -lt 10;$guard++){
                $background=@($running|Where-Object{$_.Class -eq 'Background'}).Count
                if($BackgroundRunningMode -lt 0){$background=-1}
                $next=Select-DomeniaNextQueuedTask -Queued @($queue.ToArray()) -Running $running.Count -Outstanding $running.Count -MaxConcurrent 6 -MaxOutstanding 12 -ReservedForeground 2 -BackgroundRunning $background -AgingSeconds 30 -Now $clock
                if($null -eq $next){break}
                [void]$queue.Remove($next)
                if($next.Class -eq 'Background'){if($startedAt -lt 0){$startedAt=$t};[void]$running.Add([pscustomobject]@{Class='Background';EndsAt=$clock.AddSeconds(5)})}
                else{[void]$running.Add([pscustomobject]@{Class='Explicit';EndsAt=$clock.AddSeconds(3)})}
            }
        }
        return $startedAt
    }
    $withAging=& $simulate 0
    Assert-True (($withAging -ge 30) -and ($withAging -le 34)) ('Démarrage du fond à '+$withAging+' s')
    Assert-Equal -1 (& $simulate -1) 'Sans vieillissement, le fond resterait bloqué'
}
Test-Case 'P17' 'Délais : une lecture de campagne qui progresse continue, une lecture bloquée sʼarrête, la durée totale borne tout' {
    $job={param($progress,[double]$Idle=25,[double]$Total=90)[pscustomobject]@{OperationId='LiveConsole';Name='Console du parc : PC-1';State='Running';IsWrite=$false;CancelRequested=$false;Superseded=$false;TimeoutSeconds=$Idle;HardTimeoutSeconds=$Total;ReadProgress=$progress}}
    $p=[hashtable]::Synchronized(@{StartedTimestamp=100000L;LastRowTimestamp=160000L;RowsRead=5L})
    Assert-False (Get-DomeniaReadTimeoutState -Job (& $job $p) -ElapsedSeconds 70 -NowTimestamp 170000 -TimestampFrequency 1000).Expired 'Lecture qui progresse arrêtée'
    $idle=Get-DomeniaReadTimeoutState -Job (& $job $p) -ElapsedSeconds 86 -NowTimestamp 186000 -TimestampFrequency 1000
    Assert-True $idle.Expired;Assert-Equal 'Idle' $idle.Reason;Assert-True ($idle.Message -match 'aucune étape terminée');Assert-True ($idle.Message -match '5 étape')
    $busy=[hashtable]::Synchronized(@{StartedTimestamp=100000L;LastRowTimestamp=195000L;RowsRead=12L})
    $total=Get-DomeniaReadTimeoutState -Job (& $job $busy) -ElapsedSeconds 96 -NowTimestamp 196000 -TimestampFrequency 1000
    Assert-True $total.Expired;Assert-Equal 'Total' $total.Reason;Assert-True ($total.Message -match 'durée totale')
    $legacy=[pscustomobject]@{OperationId='LiveConsole';Name='x';State='Running';IsWrite=$false;CancelRequested=$false;Superseded=$false;TimeoutSeconds=20}
    Assert-False (Get-DomeniaReadTimeoutState -Job $legacy -ElapsedSeconds 19).Expired
    Assert-Equal 'Timeout' (Get-DomeniaReadTimeoutState -Job $legacy -ElapsedSeconds 21).Reason 'Sans canal : règle historique'
    $broken=[hashtable]::Synchronized(@{StartedTimestamp=0L;LastRowTimestamp=0L;RowsRead=0L})
    Assert-Equal 'Timeout' (Get-DomeniaReadTimeoutState -Job (& $job $broken) -ElapsedSeconds 26 -NowTimestamp 200000 -TimestampFrequency 1000).Reason 'Canal jamais initialisé : délai historique, pas de prolongation'
}
Test-Case 'P15' 'Sites : des délais répétés suspendent le fond de ce site seulement, ni les autres ni lʼannuaire' {
    $s=New-DomeniaProviderState
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target ('pc'+$i) -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')}
    $slow=Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc9' -Class 'Background' -NowUtc $script:ET0.AddSeconds(5) -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 0
    Assert-False $slow.Allowed;Assert-True ($slow.Reason -match '10\.1\.2\.0/24');Assert-True ($null -ne $slow.RetryAfterUtc)
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc9' -Class 'Background' -NowUtc $script:ET0.AddSeconds(5) -Group '10.9.9.0/24' -RunningForTarget 0 -RunningForGroup 0).Allowed 'Un autre site continue'
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc9' -Class 'Explicit' -NowUtc $script:ET0.AddSeconds(5) -Group '10.1.2.0/24').Allowed 'Une action explicite reste possible'
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Directory' -Target '' -Class 'Background' -NowUtc $script:ET0.AddSeconds(5) -Group 'dc01.example.test' -RunningForTarget 0 -RunningForGroup 0).Allowed 'Annuaire non déclaré inaccessible'
    Assert-False (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc9' -Class 'Background' -NowUtc $script:ET0 -Group '10.9.9.0/24' -RunningForTarget 0 -RunningForGroup 2).Allowed 'Budget du site atteint'
    $s2=New-DomeniaProviderState
    foreach($i in 1..2){[void](Register-DomeniaProviderOutcome -State $s2 -Provider 'Cim' -Target ('pc'+$i) -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')}
    [void](Register-DomeniaProviderOutcome -State $s2 -Provider 'Cim' -Target 'pc3' -Outcome 'AccessDenied' -NowUtc $script:ET0 -Group '10.1.2.0/24')
    [void](Register-DomeniaProviderOutcome -State $s2 -Provider 'Cim' -Target 'pc4' -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')
    Assert-True (Test-DomeniaProviderAdmission -State $s2 -Provider 'Cim' -Target 'pc9' -Class 'Background' -NowUtc $script:ET0.AddSeconds(5) -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 0).Allowed 'Une réponse du site remet le compte à zéro'
}
Test-Case 'P160' 'Reprise progressive : après la pause, une lecture de fond à la fois, une de plus par réponse' {
    $s=New-DomeniaProviderState
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target ('pc'+$i) -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')}
    $after=$script:ET0.AddSeconds(61)
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc9' -Class 'Background' -NowUtc $after -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 0).Allowed 'Lecture dʼessai'
    Assert-False (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc8' -Class 'Background' -NowUtc $after -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 1).Allowed 'Une seule à la fois'
    [void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target 'pc9' -Outcome 'Success' -NowUtc $after -Group '10.1.2.0/24')
    Assert-True (Test-DomeniaProviderAdmission -State $s -Provider 'Cim' -Target 'pc8' -Class 'Background' -NowUtc $after -Group '10.1.2.0/24' -RunningForTarget 0 -RunningForGroup 1).Allowed 'Une de plus après une réponse'
    $t=New-DomeniaProviderState
    foreach($i in 1..2){[void](Register-DomeniaProviderOutcome -State $t -Provider 'Cim' -Target 'pc1' -Outcome 'Failure' -NowUtc $script:ET0)}
    Assert-False (Test-DomeniaProviderAdmission -State $t -Provider 'Cim' -Target 'pc1' -Class 'Background' -NowUtc $script:ET0.AddSeconds(61) -RunningForTarget 1).Allowed 'Poste en reprise : une lecture à la fois'
    Assert-True (Test-DomeniaProviderAdmission -State $t -Provider 'Cim' -Target 'pc1' -Class 'Background' -NowUtc $script:ET0.AddSeconds(61) -RunningForTarget 0).Allowed
    $lines=@(Get-DomeniaProviderStateSummary -State $s -NowUtc $script:ET0.AddSeconds(5))
    Assert-False (($lines -join ' ') -match '(?i)annuaire.{0,20}inaccessible') 'Jamais tout lʼannuaire déclaré inaccessible'
    $paused=New-DomeniaProviderState
    foreach($i in 1..3){[void](Register-DomeniaProviderOutcome -State $paused -Provider 'Cim' -Target ('pc'+$i) -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')}
    Assert-Equal 1 @(Get-DomeniaProviderStateSummary -State $paused -NowUtc $script:ET0.AddSeconds(5) | Where-Object { $_ -match 'site 10\.1\.2\.0/24 : lectures de fond suspendues' }).Count
}
Test-Case 'P160' 'Panneau : les postes en pause ou en reprise sont regroupés par fournisseur, les sites restent nommés' {
    # A campaign over a slow site: forty workstations with two time-outs each.
    $s=New-DomeniaProviderState
    foreach($i in 1..40){foreach($n in 1..2){[void](Register-DomeniaProviderOutcome -State $s -Provider 'Cim' -Target ('pc'+$i) -Outcome 'Timeout' -NowUtc $script:ET0 -Group '10.1.2.0/24')}}
    $later=@(Get-DomeniaProviderStateSummary -State $s -NowUtc $script:ET0.AddHours(1))
    Assert-Equal 2 $later.Count ($later -join ' | ')
    Assert-Equal 1 @($later | Where-Object { $_ -match '^WMI · 40 cibles \(pc1, pc10, pc11 et 37 autre\(s\)\) : reprise progressive' }).Count ($later -join ' | ')
    Assert-Equal 1 @($later | Where-Object { $_ -match '^WMI · site 10\.1\.2\.0/24 : reprise progressive' }).Count
    $paused=@(Get-DomeniaProviderStateSummary -State $s -NowUtc $script:ET0.AddSeconds(5))
    Assert-Equal 2 $paused.Count ($paused -join ' | ')
    Assert-Equal 1 @($paused | Where-Object { $_ -match '^WMI · 40 cibles .* lectures de fond suspendues' }).Count
    $one=New-DomeniaProviderState
    foreach($n in 1..2){[void](Register-DomeniaProviderOutcome -State $one -Provider 'Cim' -Target 'pc1' -Outcome 'Timeout' -NowUtc $script:ET0)}
    Assert-True ((@(Get-DomeniaProviderStateSummary -State $one -NowUtc $script:ET0.AddHours(1)) -join ' ') -match '^WMI · pc1 : reprise progressive') 'Un seul poste reste nommé'
}

# Point 122 : temps de reponse mesures (mediane, 95e centile) par categorie, sans mesure inventee.
Test-Case 'P122' 'Percentiles : la recherche locale garde sa propre serie' {
    Assert-Equal 'LocalIndexRead:Search' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' ([pscustomobject]@{Action='Search'}))
    Assert-Equal 'LocalIndexRead:FleetStats' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' @{Action='FleetStats'})
    Assert-Equal 'LocalIndexRead:OperationStats' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' ([pscustomobject]@{Action='OperationStats'}))
    # W05 (points 22, 24, 30): the Contrôles tab read and the comparison of two snapshots keep their own series.
    Assert-Equal 'LocalIndexRead:DirectorySync' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' ([pscustomobject]@{Action='DirectorySync'}))
    Assert-Equal 'LocalIndexRead:SnapshotCompare' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' ([pscustomobject]@{Action='SnapshotCompare'}))
    Assert-Equal 'LocalIndexRead' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' ([pscustomobject]@{Action='Inconnue'})) 'Action hors liste fermee'
    Assert-Equal 'LocalIndexRead' (Get-DomeniaRuntimeMetricOperationKey 'LocalIndexRead' $null) 'Charge absente'
    Assert-Equal 'LocalQuery:Search' (Get-DomeniaRuntimeMetricOperationKey 'LocalQuery' ([pscustomobject]@{SearchOutput=$true}))
    Assert-Equal 'LocalQuery' (Get-DomeniaRuntimeMetricOperationKey 'LocalQuery' ([pscustomobject]@{SearchOutput=$false}))
    Assert-Equal 'OpenAdObject' (Get-DomeniaRuntimeMetricOperationKey 'OpenAdObject' ([pscustomobject]@{Action='Search'})) 'Autre operation inchangee'
}
Test-Case 'P122' 'Percentiles : categories disjointes, aucune mesure comptee deux fois' {
    $series=@{}
    $series['Sqlite|LocalIndexRead:Search']=[double[]]@(10,20)
    $series['Sqlite|LocalQuery:Search']=[double[]]@(30)
    $series['Sqlite|LocalIndexRead:FleetStats']=[double[]]@(400)
    $series['Sqlite|LocalStore']=[double[]]@(50)
    $series['Dispatcher|Callback:LocalQuery']=[double[]]@(5)
    $series['Dispatcher|Pulse']=[double[]]@(2)
    $series['Dispatcher|RunspaceOpen:LocalQuery']=[double[]]@(3)
    $series['Ldap|OpenAdObject']=[double[]]@(120)
    $series['Cim|ComputerInventory']=[double[]]@(900,-4,[double]::NaN)
    $series['Queue|Wait:Explicit']=[double[]]@(1)
    $series['Ldap|Write:ResetPassword']=[double[]]@(300)
    $series['Cim|Write:ComputerRestart']=[double[]]@(2000,[double]::PositiveInfinity)
    $queue=New-Object 'System.Collections.Generic.Queue[double]'
    foreach($value in @(15,[double]::NaN,-2,[double]::NegativeInfinity)){$queue.Enqueue([double]$value)}
    $series['Ldap|SearchUsers']=$queue
    $series['Ldap|Legacy']=@('25','x')
    $counts=@{}
    foreach($category in @(Get-DomeniaResponseTimeCategories)){$samples=Select-DomeniaResponseTimeSamples $series $category;$counts[[string]$category.Id]=$samples.Count}
    Assert-Equal 3 $counts['LocalSearch'] 'Recherche locale : index et atelier'
    Assert-Equal 2 $counts['Sqlite'] 'Vue du parc et ecriture locale, recherche exclue'
    Assert-Equal 1 $counts['Render'] 'Battement et ouverture de runspace exclus'
    Assert-Equal 3 $counts['Directory'] 'Lectures seulement : file typee filtree, texte invariant lu, ecriture exclue'
    Assert-Equal 1 $counts['Computers'] 'Valeur negative et NaN ecartees, redemarrage exclu'
    Assert-Equal 2 $counts['Writes'] 'Ecriture et action distante dans leur propre categorie, infini ecarte'
    $total=0;foreach($value in $counts.Values){$total+=[int]$value}
    Assert-Equal 12 $total 'Aucune mesure comptee deux fois'
    $empty=Select-DomeniaResponseTimeSamples $null (@(Get-DomeniaResponseTimeCategories)[0])
    Assert-Equal 0 $empty.Count 'Aucune serie : tableau vide'
    $labels=@(Get-DomeniaResponseTimeCategories|ForEach-Object{[string]$_.Label})
    Assert-True ($labels -contains 'Traitement des résultats dans lʼinterface') 'Libelle du traitement dans l interface'
}
Test-Case 'P122' 'Percentiles : rang le plus proche, 95e centile seulement a partir de 20 mesures' {
    $s=Get-DomeniaLatencySummary -Samples ([double[]](1..20))
    Assert-Equal 20 ([int]$s.Count);Assert-Equal 10 ([int]$s.P50);Assert-Equal 19 ([int]$s.P95);Assert-Equal 20 ([int]$s.Max);Assert-True $s.P95Stated
    $few=Get-DomeniaLatencySummary -Samples ([double[]]@(551,100))
    Assert-False $few.P95Stated;Assert-True ($null -eq $few.P95) '95e centile invente sur deux mesures'
    Assert-Equal 100 ([int]$few.P50);Assert-Equal 551 ([int]$few.Max)
    $none=Get-DomeniaLatencySummary -Samples ([double[]]@())
    Assert-Equal 0 ([int]$none.Count);Assert-True (($null -eq $none.P50) -and ($null -eq $none.Max)) 'Zero invente sans mesure'
    $dirty=Get-DomeniaLatencySummary -Samples ([double[]]@(5,[double]::NaN,-1,[double]::PositiveInfinity))
    Assert-Equal 1 ([int]$dirty.Count) 'Valeurs non mesurees ecartees'
}
Test-Case 'P122' 'Percentiles : texte honnete, aucune mesure ne devient 0 ms' {
    Assert-Equal 'Recherche locale : aucune mesure dans cette session.' (Format-DomeniaLatencySummaryText 'Recherche locale' (Get-DomeniaLatencySummary -Samples ([double[]]@())))
    Assert-Equal 'Recherche locale : médiane 100 ms ; maximum 551 ms (2 mesures, trop peu pour un 95e centile).' (Format-DomeniaLatencySummaryText 'Recherche locale' (Get-DomeniaLatencySummary -Samples ([double[]]@(100,551))))
    Assert-Equal 'Recherche locale : médiane 7 ms ; maximum 7 ms (1 mesure, trop peu pour un 95e centile).' (Format-DomeniaLatencySummaryText 'Recherche locale' (Get-DomeniaLatencySummary -Samples ([double[]]@(7))))
    Assert-Equal 'Recherche locale : médiane 10 ms ; 95 % sous 19 ms ; maximum 20 ms (20 mesures).' (Format-DomeniaLatencySummaryText 'Recherche locale' (Get-DomeniaLatencySummary -Samples ([double[]](1..20))))
}

# ---------------------------------------------------------------- P-CD-07 one declarative table of the operations
Test-Case 'P-CD-07' 'Table des opérations : une ligne par opération épinglée du registre, et réciproquement' {
    $parsed = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $wad) 'tools/operation-contracts.json'),[Text.Encoding]::UTF8) | ConvertFrom-Json
    $contracts = @(@($parsed) | ForEach-Object { [string]$_.Operation })
    Assert-True ($contracts.Count -gt 50) ('Contrat des opérations illisible : ' + $contracts.Count)
    $rows = @((Get-DomeniaOperationTable).Values)
    foreach ($operation in $contracts) {
        $mine = @($rows | Where-Object { [string]$_.OperationId -ceq $operation })
        Assert-Equal 1 $mine.Count ('Ligne de la table pour ' + $operation)
        Assert-True ([bool]$mine[0].Pinned) ($operation + ' est épinglée mais déclarée Unpinned')
    }
    foreach ($row in $rows) {
        $id = [string]$row.OperationId
        if ([bool]$row.Pinned) { Assert-True ($contracts -ccontains $id) ($id + ' déclarée Pinned sans corps épinglé') }
        else { Assert-False ($contracts -contains $id) ($id + ' déclarée Unpinned alors quʼelle est épinglée') }
        # A directory write is recognised by its name only (Get-DomeniaOperationEffect): the table never contradicts it.
        Assert-Equal ($id -cmatch '^Write[A-Za-z0-9]{2,59}$') ([string]$row.Effect -ceq 'DirectoryWrite') ('Effet DirectoryWrite de ' + $id)
        Assert-True (Test-DomeniaContractValue -Family 'Domenia.Provider' -Value ([string]$row.Provider)) ('Fournisseur non déclaré pour ' + $id)
    }
    Assert-Equal $contracts.Count @($rows | Where-Object { [bool]$_.Pinned }).Count 'Nombre de lignes épinglées'
}
Test-Case 'P-CD-07' 'Table des opérations : lue une fois, sans distinction de casse, inconnue = aucune ligne' {
    Assert-True ([object]::ReferenceEquals((Get-DomeniaOperationTable),(Get-DomeniaOperationTable))) 'Table reconstruite à chaque appel'
    Assert-Equal 'ComputerPing' ([string](Get-DomeniaOperationRow 'computerping').OperationId)
    Assert-True ($null -eq (Get-DomeniaOperationRow 'OperationInconnue'))
    Assert-True ($null -eq (Get-DomeniaOperationRow ''))
    Assert-True ($null -eq (Get-DomeniaOperationRow ' ReadLaps ')) 'Espaces : aucun rapprochement implicite'
    # Only the effect rule trims the identifier, as before the table.
    Assert-Equal 'Read' (Get-DomeniaOperationEffect ' ReadLaps ')
    Assert-Equal 'Directory' (Get-DomeniaOperationProvider ' ReadLaps ')
    Assert-Equal 'Unknown' (Get-DomeniaOperationEffect '')
    # SessionsList: remote and machine account; it is no longer listed as local too (that listing changed no answer).
    $sessions = Get-DomeniaOperationRow 'SessionsList'
    Assert-Equal 'Remote,Machine' ((@($sessions.Accounts)) -join ',')
}
Test-Case 'P-CD-07' 'Table des opérations : chaque règle répond comme les anciennes listes pour chaque identifiant' {
    # Reference captured before P-CD-07 (commit b00c409) from the former lists of Get-DomeniaOperationProvider,
    # Get-DomeniaOperationCredentialNeeds, Get-DomeniaTaskClass, Get-DomeniaTaskDedupKey, Get-DomeniaIsolationDecision,
    # New-DomeniaWorkerRunspace (pool), Get-DomeniaOperationEffect and Get-DomeniaOperationResource: every pinned
    # operation, every identifier those lists named, unknown identifiers and case variants (the lists ignored case,
    # the name rule of the directory writes does not). Columns: identifier, provider, effect, class, class for the
    # replace key 'object', shared, isolable, pooled, access resource, then the credential needs: directory, directory
    # account, remote, machine, remote admin, secrets, non directory, directory breaker, resource.
    $reference = @'
AccountAliasRead|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
AdConsistencyScan|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
AdHealthRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
AdSchemaRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
BatchNetworkDiag|Cim|Read|Explicit|Explicit|0|0|0|Remote|0|0|1|0|1|0|1|0|Remote
BitLockerPresence|Directory|Unknown|Explicit|Explicit|0|0|0|BitLocker|1|1|0|0|0|1|0|1|BitLocker
CmdletHelp|Local|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
CmdletInventory|Local|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
ComputerAdminShare|Network|Read|Explicit|Explicit|0|0|0|Network|0|0|1|1|1|0|1|0|Remote
ComputerDiagnostics|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
ComputerEventsRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|1|1|0|0|0|0|0|1|Directory
ComputerGpUpdate|Cim|RemoteMutation|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
ComputerInventory|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
ComputerLastUser|Cim|Read|Explicit|Explicit|0|0|0|Remote|1|1|1|1|1|0|1|0|Remote
ComputerPing|Network|Read|Explicit|Explicit|0|1|1|Network|0|0|1|0|1|0|1|0|Remote
ComputerQuickDiag|Cim|Read|Explicit|Explicit|1|0|0|Remote|1|1|0|0|0|0|0|1|Directory
ComputerRestart|Cim|RemoteMutation|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
ComputerServiceControl|Cim|RemoteMutation|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
ConnectorRead|Network|Read|Explicit|Explicit|0|0|0|Network|1|1|0|0|0|0|0|1|Network
DcCompareRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
DcServicesRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|0|0|1|1|1|0|1|0|Remote
DelegationRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
DemoDirectory|Local|Read|Explicit|Explicit|0|0|1|Local|0|0|0|0|0|0|1|0|Local
DirectoryAbsenceCheck|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
DocumentStore|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
DomainOverview|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
EmbeddedDirectoryLookup|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
EmbeddedPathBrowse|Local|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
EngineSelfTest|Local|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
GlobalSearch|Directory|Read|Explicit|Explicit|0|0|1|Directory|1|1|0|0|0|0|0|1|Directory
GpoAppliedRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|0|0|1|1|1|0|1|0|Remote
GpoLinksRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
GroupPathRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
IndexBuild|Directory|LocalWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
IndexOuList|Directory|Unknown|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
IndexRefresh|Directory|LocalWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
IsolatedRead|Local|Unknown|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
JoinStateRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|1|1|0|0|0|0|0|1|Directory
LegacyMigration|Storage|Unknown|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
LinkHistoryStore|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|1|1|0|0|0|0|0|1|Directory
LiveCache|Storage|LocalWrite|Background|Background|0|0|1|Local|0|0|0|0|0|0|1|0|Local
LiveConsole|Cim|Read|Selection|Selection|0|0|1|Remote|1|1|1|1|1|0|1|0|Remote
LiveDirectoryCheck|Directory|Read|Background|Background|0|0|1|Directory|1|1|0|0|0|0|0|1|Directory
LiveSelectedPing|Network|Read|Selection|Selection|0|0|1|Network|0|0|0|0|0|0|1|0|Network
LocalAssistant|Local|Unknown|Explicit|Explicit|0|0|0|Local|1|1|0|0|0|0|0|1|Directory
LocalIndexRead|Storage|Unknown|Explicit|Explicit|0|0|1|Local|0|0|0|0|0|0|1|0|Local
LocalQuery|Storage|Unknown|Explicit|Explicit|0|0|1|Local|0|0|0|0|0|0|1|0|Local
LocalStore|Storage|LocalWrite|Background|Background|0|0|1|Local|0|0|0|0|0|0|1|0|Local
LockoutDiagnosis|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
LogonByDcRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
LogonHarvest|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
MachineIdentityRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|0|0|1|1|1|0|1|0|Remote
ObjectChanges|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
OfflineDossier|Local|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
OpenAdObject|Directory|Read|Explicit|Selection|1|0|1|Directory|1|1|0|0|0|0|0|1|Directory
OpenLinkedObject|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
ParkPing|Network|Read|Explicit|Explicit|0|0|0|Network|0|0|0|0|0|0|1|0|Network
ParkSharedSync|Network|Unknown|Background|Background|0|0|0|Network|0|0|0|0|0|0|1|0|Network
ParkSweep|Cim|Read|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
PasswordPolicyRead|Directory|Read|Explicit|Explicit|1|0|0|Directory|1|1|0|0|0|0|0|1|Directory
PermissionAnalysis|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
PresenceScan|Network|Read|Background|Background|0|0|0|Network|1|1|0|0|0|0|0|1|Network
PruneLinks|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
QueryExport|Storage|Unknown|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
QueryLibrary|Storage|Unknown|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
QuerySchema|Cim|Read|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
QueryTransfer|Storage|Unknown|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
ReadBitLocker|Directory|Read|Explicit|Explicit|0|0|0|BitLocker|1|1|0|0|0|1|0|1|BitLocker
ReadBitLockerKey|Directory|Read|Explicit|Explicit|0|0|0|BitLocker|1|1|0|0|0|1|0|1|BitLocker
ReadBitLockerList|Directory|Unknown|Explicit|Explicit|0|0|0|BitLocker|1|1|0|0|0|1|0|1|BitLocker
ReadLaps|Directory|Read|Explicit|Explicit|0|0|0|Laps|1|1|0|0|0|1|0|1|Laps
ReceiptStore|Storage|LocalWrite|Background|Background|0|0|0|Local|0|1|0|0|0|0|1|0|Local
ReconcileScope|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
RelationHistoryRead|Storage|Read|Explicit|Explicit|1|0|0|Local|0|0|0|0|0|0|1|0|Local
RemoteCredentialCheck|Cim|Read|Explicit|Explicit|0|0|0|Remote|1|1|0|0|0|0|0|1|Remote
RimotteRun|Cim|RemoteMutation|Explicit|Explicit|0|0|0|Remote|0|0|1|1|1|0|1|0|Remote
ScopeReconcile|Directory|Read|Background|Background|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
SelectedPresence|Network|Read|Selection|Selection|0|0|1|Network|1|1|0|0|0|0|0|1|Network
SelfCheck|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
SessionsList|Wts|Read|Explicit|Explicit|1|0|0|Remote|0|0|1|1|1|0|1|0|Remote
SoftwareInventory|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
StartupWarmCache|Directory|Read|Background|Background|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
StartupWarmup|Directory|Read|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
StorageBackup|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
StorageIntegrity|Storage|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
StorageMaintenance|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
StoragePurge|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
StorageRetention|Storage|LocalWrite|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
StorageUsage|Storage|Read|Explicit|Explicit|0|0|0|Local|0|0|0|0|0|0|1|0|Local
TreeChildren|Directory|Read|Explicit|Explicit|0|1|1|Directory|1|1|0|0|0|0|0|1|Directory
UpdateStateRead|Cim|Read|Explicit|Explicit|1|0|0|Remote|1|1|0|0|0|0|0|1|Directory
UserComputerProbe|Cim|Read|Explicit|Explicit|0|0|0|Remote|1|1|0|1|1|0|0|1|Remote
WakeOnLanSend|Network|RemoteMutation|Explicit|Explicit|0|0|0|Network|1|1|0|0|0|0|0|1|Network
WmiClasses|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
WmiNamespaces|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
WmiQuery|Cim|Read|Explicit|Explicit|0|1|0|Remote|0|0|1|1|1|0|1|0|Remote
WriteAccountDisabled|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteAccountOptions|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteAttributes|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteCreateOu|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteDeleteObject|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteExpiration|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteExpirePassword|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteGroupMember|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteMoveObject|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteObjectGroup|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteRenameComputer|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteResetPassword|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteUnlock|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
UnknownOperation|Directory|Unknown|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
WriteSomethingNew|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
computerping|Network|Read|Explicit|Explicit|0|1|1|Network|0|0|1|0|1|0|1|0|Remote
READLAPS|Directory|Read|Explicit|Explicit|0|0|0|Laps|1|1|0|0|0|1|0|1|Laps
openAdObject|Directory|Read|Explicit|Selection|1|0|1|Directory|1|1|0|0|0|0|0|1|Directory
writeAttributes|Directory|Unknown|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
livecache|Storage|LocalWrite|Background|Background|0|0|1|Local|0|0|0|0|0|0|1|0|Local
Writeattributes|Directory|DirectoryWrite|Explicit|Explicit|0|0|0|Directory|1|1|0|0|0|0|0|1|Directory
'@
    $count = 0
    foreach ($line in ($reference -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $c = $line.Split('|')
        Assert-Equal 18 $c.Count ('Référence illisible : ' + $line)
        $id = $c[0]; $count++
        $flag = @{ '1' = $true; '0' = $false }
        Assert-Equal $c[1] (Get-DomeniaOperationProvider $id) ($id + ' : fournisseur')
        Assert-Equal $c[2] (Get-DomeniaOperationEffect $id) ($id + ' : effet')
        Assert-Equal $c[3] (Get-DomeniaTaskClass -OperationId $id) ($id + ' : classe')
        Assert-Equal $c[4] (Get-DomeniaTaskClass -OperationId $id -ReplaceKey 'object') ($id + ' : classe de l objet sélectionné')
        Assert-Equal $flag[$c[5]] ([bool](Get-DomeniaTaskDedupKey -OperationId $id -ReaderIdentity 'r' -Payload ([pscustomobject]@{Dn='x'}))) ($id + ' : partage')
        Assert-Equal $flag[$c[6]] ([bool](Get-DomeniaIsolationDecision -OperationId $id -Enabled $true -PayloadDigest 'd').Isolate) ($id + ' : isolement')
        $row = Get-DomeniaOperationRow $id
        Assert-Equal $flag[$c[7]] (($null -ne $row) -and ([bool]$row.Pooled)) ($id + ' : pool')
        Assert-Equal $c[8] (Get-DomeniaOperationResource $id) ($id + ' : ressource dʼaccès')
        $needs = Get-DomeniaOperationCredentialNeeds $id
        $i = 9
        foreach ($name in @('Directory','DirectoryCredential','Remote','Machine','RemoteAdmin','Secrets','NonDirectory','DirectoryBreaker')) {
            Assert-Equal $flag[$c[$i]] ([bool]$needs.$name) ($id + ' : ' + $name); $i++
        }
        Assert-Equal $c[17] ([string]$needs.Resource) ($id + ' : ressource du compte')
        Assert-Equal $c[1] ([string]$needs.Provider) ($id + ' : fournisseur des besoins')
    }
    Assert-True ($count -ge 117) ('Référence incomplète : ' + $count)
}

# F01 follow-up: reviewed effects, including the dynamic wrapper which must remain fail closed.
Test-Case 'D018' 'Effets des operations de lecture et de stockage classes apres revue' {
    $expected=@{
        'BitLockerPresence'='Read'
        'IndexOuList'='Read'
        'IsolatedRead'='Unknown'
        'LegacyMigration'='LocalWrite'
        'LocalIndexRead'='Read'
        'LocalQuery'='Read'
        'ParkSharedSync'='RemoteMutation'
        'QueryExport'='LocalWrite'
        'QueryLibrary'='Read'
        'QueryTransfer'='LocalWrite'
        'ReadBitLockerList'='Read'
    }
    foreach($id in $expected.Keys){Assert-Equal $expected[$id] (Get-DomeniaOperationRow $id).Effect $id}
}
