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
    Assert-False (Test-DomeniaIdleAllows $p 'Presence');Assert-False (Test-DomeniaIdleAllows $p 'Reconcile');Assert-False (Test-DomeniaIdleAllows $p 'ViewRebuild' 'WsSearch')
    Assert-False (Test-DomeniaIdleAllows (Get-DomeniaIdlePolicy -Minimized $true) 'Dashboard')
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
