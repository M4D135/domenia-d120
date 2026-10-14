# Access rules: one credential context per resource and target, structured error decisions,
# coalesced re-authentication, credential lifetime, integrated Windows sign-in, explained capabilities,
# LAPS read versus decryption, BitLocker key selection, secret exposure and transport policy.
# Pure decisions: no credential object, no network call and no secret value is handled here.

# ---------------------------------------------------------------- D051 context per resource and target
function Get-DomeniaOperationResource {
    # Which protected resource an operation talks to. LAPS and BitLocker are distinct from the directory.
    param([Parameter(Mandatory=$true)][string]$OperationId)
    if ($OperationId -eq 'ReadLaps') { return 'Laps' }
    # BitLockerPresence (lot L01) reads the recovery objects of an OU: same account and refusals as the other BitLocker reads.
    if ($OperationId -in @('ReadBitLocker','ReadBitLockerList','ReadBitLockerKey','BitLockerPresence')) { return 'BitLocker' }
    $provider = Get-DomeniaOperationProvider $OperationId
    if ($provider -in @('Cim','Wts')) { return 'Remote' }
    if ($provider -eq 'Storage' -or $provider -eq 'Local') { return 'Local' }
    if ($provider -eq 'Network') { return 'Network' }
    if ($OperationId -in @('ComputerGpUpdate','ComputerRestart','RimotteRun','UserComputerProbe','WakeOnLanSend')) { return 'Remote' }
    return 'Directory'
}

function ConvertTo-DomeniaMachineKey {
    # One key per workstation: the first DNS label in lower case, so PC-01 and pc-01.example.local are the same
    # target. An IP address is kept whole (its first octet is not a host name).
    param([AllowEmptyString()][AllowNull()][string]$Target)
    $value = ([string]$Target).Trim().TrimEnd('.')
    if (-not $value) { return '' }
    if ($value -match '^\d{1,3}(\.\d{1,3}){3}$' -or $value.Contains(':')) { return $value.ToLowerInvariant() }
    return $value.Split('.')[0].ToLowerInvariant()
}

function Test-DomeniaLocalAccountName {
    param([AllowEmptyString()][string]$UserName,[AllowEmptyString()][string]$Target='')
    $identity = ConvertTo-DomeniaAccountIdentity $UserName
    if ($identity.Form -ne 'DownLevel') { return $false }
    if ($identity.Authority -eq '.') { return $true }
    $machine = ConvertTo-DomeniaMachineKey $Target
    return ([bool]$machine -and $identity.Authority -ieq $machine)
}

function Get-DomeniaCredentialScope {
    # The key under which an alternate account is kept. A remote account is always bound to one target.
    param([Parameter(Mandatory=$true)][string]$OperationId,[AllowEmptyString()][string]$Target='')
    $resource = Get-DomeniaOperationResource $OperationId
    if ($resource -eq 'Remote') {
        $machine = ConvertTo-DomeniaMachineKey $Target
        if (-not $machine) { return 'Remote' }
        return ('Remote:' + $machine)
    }
    return $resource
}

function Test-DomeniaCredentialContext {
    # A local account (POSTE\compte or .\compte) is only accepted for the workstation it belongs to.
    # $KnownDomains: NetBIOS and DNS names of the connected domain. When given, an account offered for a
    # workstation must belong to that domain, to the workstation itself, or use the .\ form: PC-02\admin
    # offered for PC-01 is refused before any network call.
    param([Parameter(Mandatory=$true)][string]$Scope,[AllowEmptyString()][string]$UserName='',[AllowEmptyString()][string]$Target='',[string[]]$KnownDomains=@())
    if ([string]::IsNullOrWhiteSpace($UserName)) { return [pscustomobject]@{Valid=$false;Reason='Compte absent.'} }
    $identity = ConvertTo-DomeniaAccountIdentity $UserName
    $machine = ConvertTo-DomeniaMachineKey $Target
    $isLocalForm = ($identity.Form -eq 'DownLevel' -and ($identity.Authority -eq '.' -or ($machine -and $identity.Authority -ieq $machine)))
    $scopeMachine = ''
    if ($Scope.StartsWith('Remote:',[StringComparison]::Ordinal)) { $scopeMachine = ConvertTo-DomeniaMachineKey $Scope.Substring(7) }
    if ($isLocalForm) {
        if (-not $Scope.StartsWith('Remote',[StringComparison]::Ordinal)) { return [pscustomobject]@{Valid=$false;Reason='Un compte local ne peut pas lire l annuaire, LAPS ou BitLocker.'} }
        if (-not $machine) { return [pscustomobject]@{Valid=$false;Reason='Un compte local exige de designer le poste cible.'} }
        if ($scopeMachine -ne $machine) { return [pscustomobject]@{Valid=$false;Reason='Ce compte local appartient a un autre poste.'} }
        return [pscustomobject]@{Valid=$true;Reason=''}
    }
    $domains = @(@($KnownDomains) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    if ($identity.Form -eq 'DownLevel' -and $scopeMachine -and $domains.Count -gt 0) {
        $authority = [string]$identity.Authority
        $known = $false
        foreach ($domain in $domains) { if ($authority -ieq $domain -or $authority -ieq $domain.Split('.')[0]) { $known = $true } }
        # A trusted domain other than the session one is written compte@domaine (UPN form, not checked here).
        if (-not $known) { return [pscustomobject]@{Valid=$false;Reason='Ce compte appartient a un autre poste ou a un domaine inconnu de cette session. Pour un compte d un autre domaine approuve, saisissez compte@domaine.'} }
    }
    return [pscustomobject]@{Valid=$true;Reason=''}
}

function Set-DomeniaScopeAccount {
    # Changes ONE scope. The other resources keep their account unless the operator asks for them explicitly.
    param([Collections.IDictionary]$Scopes,[Parameter(Mandatory=$true)][string]$Scope,[AllowEmptyString()][string]$Account='')
    $copy = @{}
    if ($null -ne $Scopes) { foreach ($key in @($Scopes.Keys)) { $copy[[string]$key] = $Scopes[$key] } }
    if ([string]::IsNullOrWhiteSpace($Account)) { [void]$copy.Remove($Scope) } else { $copy[$Scope] = $Account }
    return $copy
}

# ---------------------------------------------------------------- D052 structured, explainable errors
function Get-DomeniaErrorDecision {
    # Code first, text last: the same native code leads to the same decision in French and in English.
    # $Structured comes from Get-DomeniaStructuredError; $Text is the raw message (fallback only).
    param($Structured,[AllowEmptyString()][string]$Text='',[AllowEmptyString()][string]$Step='')
    $kind = [string](Get-DomeniaMember $Structured 'Kind' 'Unknown')
    $native = 0L; [void][long]::TryParse([string](Get-DomeniaMember $Structured 'NativeCode' 0),[ref]$native)
    $codeText = [string](Get-DomeniaMember $Structured 'Code' '')
    $code = 0L
    if ($codeText -match '^0x([0-9A-Fa-f]{1,8})$') { $code = [Convert]::ToInt64($Matches[1],16) }
    $category = 'Unknown'
    $timeoutText = '(?i)timeout|timed out|d[eé]lai.*(d[eé]pass|expir)'
    # An explicit decryption refusal, never a missing module or a delay that merely mentions decryption.
    $decryptText = '(?i)d[eé]chiffr\w*.{0,40}(refus|interdit|pas autoris|non autoris)|droit de d[eé]chiffr|not authori[sz]ed to decrypt|authorized decryptor|NCryptUnprotectSecret|DecryptionStatus\W+Unauthori[sz]ed'
    $decryptStep = ($Step -match '(?i)decrypt|dechiffr|déchiffr')
    # Pass 1: the native code and the structured kind decide. The same code gives the same decision in any language.
    if ($kind -eq 'Uncertain') { $category = 'Uncertain' }
    elseif ($decryptStep -and ($kind -eq 'AccessDenied' -or $native -in @(5,8224) -or $code -in @(0x80070005L,0x80090005L,0x8009000BL,0x80090016L,0x80090020L))) { $category = 'DecryptionDenied' }
    elseif ($code -in @(0x8009000BL,0x80090016L,0x80090020L,0x80090005L)) { $category = 'DecryptionDenied' }
    elseif ($kind -eq 'CredentialPaused') { $category = 'CredentialsRejected' }
    elseif ($kind -in @('AccountLocked','AccountUnavailable')) { $category = 'AccountState' }
    elseif ($kind -eq 'LogonFailure' -or $native -in @(1326,49) -or $code -in @(0x8007052EL,0x8009030CL,0x8009030EL)) { $category = 'CredentialsRejected' }
    elseif ($kind -in @('AccountLocked','AccountUnavailable') -or $native -in @(1909,1330,1331,1327,1328) -or $code -in @(0x80070775L,0x80070532L,0x80070533L)) { $category = 'AccountState' }
    elseif ($native -in @(1460,258,121) -or $code -in @(0x800705B4L,0x80070079L)) { $category = 'Timeout' }
    elseif ($kind -eq 'Unavailable' -and $Text -match $timeoutText) { $category = 'Timeout' }
    elseif ($kind -eq 'Unavailable' -or $native -in @(53,64,67,1722,1721,1723,11001,11004,10060,10061,81,91) -or $code -in @(0x800706BAL,0x8007203AL,0x80070035L,0x80072EE7L)) { $category = 'Network' }
    elseif ($kind -eq 'ModuleUnavailable') { $category = 'Prerequisite' }
    elseif ($kind -eq 'Unconfirmed') { $category = 'Unconfirmed' }
    elseif ($kind -eq 'AccessDenied' -or $native -in @(5,50,8344) -or $code -in @(0x80070005L,0x80072098L,0x80041003L)) {
        if ($Text -match $decryptText) { $category = 'DecryptionDenied' } else { $category = 'AccessDenied' }
    }
    # Pass 2: text fallback only when no code was conclusive (old string-only workers).
    if ($category -eq 'Unknown') {
        if ($Text -match '(?i)ETAT INCONNU|resultat.*non confirme') { $category = 'Uncertain' }
        elseif ($Text -match $timeoutText) { $category = 'Timeout' }
        elseif ($Text -match '(?i)module.*(absent|manquant|missing)|service.*(arr[eê]t|stopped|not running)|not installed|non install') { $category = 'Prerequisite' }
        elseif ($Text -match $decryptText) { $category = 'DecryptionDenied' }
        elseif ($Text -match '(?i)user name or password is incorrect|nom d.utilisateur ou (le )?mot de passe (est )?incorrect|logon failure|invalid credentials|identifiants?.{0,20}(rejet|refus|incorrect)') { $category = 'CredentialsRejected' }
        elseif ($Text -match '(?i)account.{0,20}(locked|disabled|expired)|compte.{0,20}(verrouill|d[eé]sactiv|expir)') { $category = 'AccountState' }
        elseif ($Text -match '(?i)access (is )?denied|acc[eè]s (est )?refus|unauthori[sz]ed|insufficient access') { $category = 'AccessDenied' }
    }
    $decision = switch ($category) {
        'Unconfirmed'         { @{Offer=$true;Retry=$false;Text='Aucune valeur visible avec ce compte : publication ou droits a verifier.';Next='Proposer un autre compte pour cette ressource, ou verifier la publication.'} }
        'CredentialsRejected' { @{Offer=$true;Retry=$false;Text='Identifiants rejetes par la ressource.';Next='Fournir un autre compte pour cette ressource. Aucun nouvel essai automatique.'} }
        'AccountState'        { @{Offer=$false;Retry=$false;Text='Compte verrouille, expire ou restreint.';Next='Verifier l etat du compte avant tout nouvel essai.'} }
        'AccessDenied'        { @{Offer=$true;Retry=$false;Text='Droit refuse pour ce compte sur cette ressource.';Next='Utiliser un compte autorise ou demander le droit manquant.'} }
        'DecryptionDenied'    { @{Offer=$true;Retry=$false;Text='Lecture possible, dechiffrement refuse.';Next='Utiliser un compte membre des dechiffreurs autorises.'} }
        'Timeout'             { @{Offer=$false;Retry=$true;Text='Delai depasse : aucune reponse de la ressource.';Next='Relire quand la ressource repond. Ce n est pas un rejet d identifiants.'} }
        'Network'             { @{Offer=$false;Retry=$true;Text='Ressource injoignable (reseau, nom ou service distant).';Next='Verifier le nom, le reseau et le service distant, puis relire.'} }
        'Prerequisite'        { @{Offer=$false;Retry=$false;Text='Prerequis absent sur ce poste ou sur la cible.';Next='Installer ou demarrer le prerequis indique.'} }
        'Uncertain'           { @{Offer=$false;Retry=$false;Text='Issue inconnue apres envoi.';Next='Verifier le resultat avant toute nouvelle action. Aucun rejeu.'} }
        default               { @{Offer=$false;Retry=$false;Text='Erreur non classee.';Next='Consulter le detail technique.'} }
    }
    return [pscustomobject]@{
        Category=$category;OfferCredential=[bool]$decision.Offer;Retryable=[bool]$decision.Retry;Explanation=[string]$decision.Text;NextAction=[string]$decision.Next
        NativeCode=$native;Code=$(if ($codeText) { $codeText } else { '0x00000000' })
        Provider=[string](Get-DomeniaMember $Structured 'Provider' '');Step=$(if ($Step) { $Step } else { [string](Get-DomeniaMember $Structured 'Phase' '') });Target=[string](Get-DomeniaMember $Structured 'Target' '')
    }
}

# ---------------------------------------------------------------- D053 re-authentication without a storm
function New-DomeniaDenialCoalescer {
    param([ValidateRange(5,600)][int]$WindowSeconds=60)
    return [pscustomobject]@{WindowSeconds=$WindowSeconds;Entries=@{}}
}

function Add-DomeniaAccessDenial {
    # Twenty simultaneous refusals for one resource produce one request, not twenty.
    param($Coalescer,[Parameter(Mandatory=$true)][string]$Scope,[string]$Category='AccessDenied',[datetime]$NowUtc=[datetime]::UtcNow,[bool]$Background=$false)
    $entries = $Coalescer.Entries
    if ($entries.ContainsKey($Scope)) {
        $entry = $entries[$Scope]
        $age = ($NowUtc - [datetime]$entry.FirstUtc).TotalSeconds
        if ($entry.State -eq 'Open' -or $age -le $Coalescer.WindowSeconds) {
            $entry.Count = [int]$entry.Count + 1
            return [pscustomobject]@{Prompt=$false;Count=$entry.Count;Scope=$Scope;Reason='Demande deja presentee pour cette ressource.'}
        }
    }
    $entries[$Scope] = [pscustomobject]@{FirstUtc=$NowUtc;Count=1;State='Open';Category=$Category}
    # A refusal that happens in the background is listed, it does not interrupt the operator.
    if ($Background) { return [pscustomobject]@{Prompt=$false;Count=1;Scope=$Scope;Reason='Refus en arriere-plan : signale dans la page, sans interruption.'} }
    return [pscustomobject]@{Prompt=$true;Count=1;Scope=$Scope;Reason=''}
}

function Complete-DomeniaAccessPrompt {
    param($Coalescer,[Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][ValidateSet('Accepted','Cancelled')][string]$Outcome,[datetime]$NowUtc=[datetime]::UtcNow)
    $count = 0
    if ($Coalescer.Entries.ContainsKey($Scope)) { $entry = $Coalescer.Entries[$Scope]; $count = [int]$entry.Count; $entry.State = $Outcome; $entry.FirstUtc = $NowUtc }
    if ($Outcome -eq 'Cancelled') { return [pscustomobject]@{KeepPreviousCredential=$true;RetryReads=0;Grouped=$count;Message='Compte precedent conserve. Aucune nouvelle tentative.'} }
    return [pscustomobject]@{KeepPreviousCredential=$false;RetryReads=1;Grouped=$count;Message='Une seule relance de la lecture demandee. Les autres actions se relancent volontairement.'}
}

function Get-DomeniaReauthPlan {
    param([Parameter(Mandatory=$true)][string]$Category,[bool]$IsWrite=$false,[int]$Attempt=0)
    $offer = ($Category -in @('CredentialsRejected','AccessDenied','DecryptionDenied','Unconfirmed'))
    # After the operator accepted another account: one read may be replayed once. A write never is.
    $retry = ($offer -and -not $IsWrite -and $Attempt -lt 1)
    return [pscustomobject]@{OfferAccount=$offer;RetryOnce=$retry;PasswordCascade=$false}
}

# ---------------------------------------------------------------- D054 identity lifetime
function New-DomeniaCredentialLease {
    param([Parameter(Mandatory=$true)][string]$Scope,[Parameter(Mandatory=$true)][string]$Account,[ValidateSet('OneShot','Session','Inactivity')][string]$Mode='Inactivity',[ValidateRange(1,480)][int]$InactivityMinutes=30,[long]$Epoch=0,[datetime]$NowUtc=[datetime]::UtcNow)
    return [pscustomobject]@{Scope=$Scope;Account=$Account;Mode=$Mode;InactivityMinutes=$InactivityMinutes;Epoch=$Epoch;CreatedUtc=$NowUtc;LastUsedUtc=$NowUtc;Uses=0;Forgotten=$false}
}

function Test-DomeniaCredentialLease {
    # $ForNewCall = a NEW use is requested. An operation already sent keeps running whatever the answer.
    param($Lease,[long]$Epoch=0,[datetime]$NowUtc=[datetime]::UtcNow,[bool]$ForNewCall=$true)
    if ($null -eq $Lease) { return [pscustomobject]@{Usable=$false;Reason='Aucun compte pour cette ressource.';KeepsInFlight=$true} }
    if ([bool]$Lease.Forgotten) { return [pscustomobject]@{Usable=$false;Reason='Compte oublie a la demande de l operateur.';KeepsInFlight=$true} }
    if ([long]$Lease.Epoch -ne $Epoch) { return [pscustomobject]@{Usable=$false;Reason='Compte fourni dans une session precedente.';KeepsInFlight=$true} }
    if ($Lease.Mode -eq 'OneShot' -and [int]$Lease.Uses -ge 1) { return [pscustomobject]@{Usable=$false;Reason='Compte a usage unique deja utilise.';KeepsInFlight=$true} }
    if ($Lease.Mode -eq 'Inactivity') {
        $idle = ($NowUtc - [datetime]$Lease.LastUsedUtc).TotalMinutes
        if ($idle -gt [int]$Lease.InactivityMinutes) { return [pscustomobject]@{Usable=$false;Reason=('Compte expire apres ' + $Lease.InactivityMinutes + ' min sans utilisation.');KeepsInFlight=$true} }
    }
    return [pscustomobject]@{Usable=$true;Reason='';KeepsInFlight=$true}
}

function Use-DomeniaCredentialLease {
    param($Lease,[datetime]$NowUtc=[datetime]::UtcNow)
    if ($null -eq $Lease) { return $null }
    $Lease.Uses = [int]$Lease.Uses + 1; $Lease.LastUsedUtc = $NowUtc
    return $Lease
}

function Clear-DomeniaCredentialLease {
    param($Lease)
    if ($null -ne $Lease) { $Lease.Forgotten = $true }
    return $Lease
}

# ---------------------------------------------------------------- Point 44 correct an account without reconnecting
function Get-DomeniaAccountCorrectionPlan {
    # Point 44: what the correction of one account does to the work in progress. Reads that left with that account
    # before the correction are stopped (a call already sent cannot be recalled); queued reads take the validated
    # account when they leave, since their context is built at dispatch; a write is never stopped nor replayed; the
    # work of the other accounts is untouched. $Jobs: projections {Id, IsWrite, NonCancellable, State, Keys, Generation}.
    param([object[]]$Jobs=@(),[string[]]$Keys=@(),[long]$Generation=0)
    $wanted=@{}
    foreach($key in @($Keys)){if(-not [string]::IsNullOrWhiteSpace([string]$key)){$wanted[([string]$key).Trim().ToLowerInvariant()]=$true}}
    $stop=New-Object 'System.Collections.Generic.List[string]';$writes=0;$current=0
    foreach($job in @($Jobs)){
        if($null -eq $job){continue}
        $match=$false
        foreach($key in @(Get-DomeniaMember $job 'Keys' @())){if($wanted.ContainsKey(([string]$key).Trim().ToLowerInvariant())){$match=$true;break}}
        if(-not $match){continue}
        if([bool](Get-DomeniaMember $job 'IsWrite' $false)){$writes++;continue}
        if([string](Get-DomeniaMember $job 'State' '') -eq 'Queued'){continue}
        if([long](Get-DomeniaMember $job 'Generation' 0) -ge $Generation){$current++;continue}
        if([bool](Get-DomeniaMember $job 'NonCancellable' $false)){continue}
        $stop.Add([string](Get-DomeniaMember $job 'Id' ''))
    }
    $lines=New-Object 'System.Collections.Generic.List[string]'
    if($stop.Count -eq 1){$lines.Add('1 lecture partie avec lʼancien mot de passe est arrêtée : relancez-la.')}
    elseif($stop.Count -gt 1){$lines.Add([string]$stop.Count+' lectures parties avec lʼancien mot de passe sont arrêtées : relancez-les.')}
    if($writes -gt 0){$lines.Add('Une écriture en cours garde son compte : elle nʼest ni interrompue ni rejouée.')}
    $lines.Add('Les opérations en attente partiront avec le compte validé.')
    return [pscustomobject]@{Stop=$stop.ToArray();Writes=$writes;AlreadyCurrent=$current;Text=($lines.ToArray() -join ' ')}
}

# ---------------------------------------------------------------- Point 42 visible use of each account
function Get-DomeniaAccountUsageRows {
    # Point 42: which account each use takes now, where it comes from, and what the protection recorded. The
    # connection account serves every use by default; a specific account is optional. Nothing here is tested: an
    # account without a recorded refusal is not declared valid, only "no refusal recorded".
    # $Temporary: {Scope, UserName} accepted after a refusal; $Faults: {Key} of the shared protection.
    param(
        [AllowEmptyString()][string]$ConnectionUser='',[ValidateSet('Explicit','Windows','None')][string]$ConnectionMode='None',
        [AllowEmptyString()][string]$RemoteUser='',[AllowEmptyString()][string]$SecretsUser='',
        [object[]]$Temporary=@(),[object[]]$Faults=@(),[AllowEmptyString()][string]$Domain='',[AllowEmptyString()][string]$Netbios=''
    )
    $paused=@{}
    foreach($fault in @($Faults)){$key=[string](Get-DomeniaMember $fault 'Key' '');if($key){$paused[$key.ToLowerInvariant()]=$true}}
    $state={
        param([string]$User)
        if(-not $User){return 'Aucun compte'}
        $key=Get-DomeniaCredentialAccountKey $User $Domain $Netbios
        if($key -and $paused.ContainsKey($key)){return 'En pause après un refus : corrigez-le ici ou reconnectez-vous.'}
        return 'Aucun refus enregistré.'
    }
    $connectionSource=switch($ConnectionMode){'Explicit'{'compte de connexion'}'Windows'{'session Windows'}default{'aucune connexion'}}
    $rows=New-Object 'System.Collections.Generic.List[object]'
    $rows.Add([pscustomobject]@{Usage='Annuaire';Account=$ConnectionUser;Source=$connectionSource;State=(& $state $ConnectionUser)})
    foreach($use in @(@('Postes',$RemoteUser,'compte poste'),@('LAPS',$SecretsUser,'compte secrets'),@('BitLocker',$SecretsUser,'compte secrets'))){
        $user=[string]$use[1];$source=[string]$use[2]
        if(-not $user){$user=$ConnectionUser;$source=$connectionSource+' (aucun compte spécifique)'}
        $rows.Add([pscustomobject]@{Usage=[string]$use[0];Account=$user;Source=$source;State=(& $state $user)})
    }
    $labels=@{Remote='Postes';ReadLaps='LAPS';ReadBitLocker='BitLocker';Directory='Annuaire'}
    foreach($item in @($Temporary|Select-Object -First 16)){
        if($null -eq $item){continue}
        $scope=[string](Get-DomeniaMember $item 'Scope' '');$user=[string](Get-DomeniaMember $item 'UserName' '')
        if((-not $scope) -or (-not $user)){continue}
        $usage=$scope
        if($labels.ContainsKey($scope)){$usage=[string]$labels[$scope]}
        elseif($scope.StartsWith('RemoteLocal|')){$usage='Poste '+$scope.Substring(12)}
        elseif($scope.StartsWith('AD:')){$usage='Annuaire ('+$scope.Substring(3)+')'}
        $rows.Add([pscustomobject]@{Usage=$usage;Account=$user;Source='compte temporaire, oublié après inactivité';State=(& $state $user)})
    }
    return ,$rows.ToArray()
}

function Format-DomeniaAccountUsageText {
    # Point 42: one line per use, for the rule panel of the Comptes tab.
    param([object[]]$Rows=@())
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in @($Rows)){
        if($null -eq $row){continue}
        $account=[string]$row.Account;if(-not $account){$account='aucun compte'}
        $lines.Add([string]$row.Usage+' : '+$account+' ('+[string]$row.Source+'). '+[string]$row.State)
    }
    $lines.Add('Chaque usage est indépendant : changer le compte dʼun usage ne change pas les autres.')
    return ($lines.ToArray() -join [Environment]::NewLine)
}

# ---------------------------------------------------------------- D055 Windows sign-in without elevation
function Get-DomeniaOperationAuthNeed {
    # Reads use the current Windows token when it is accepted. Another account is requested only after a
    # refusal, or for an operation the current token was refused for. No privileged account is ever required up front.
    # $AlternateRefused: the refusal was obtained WITH the alternate account. It never becomes usable again by itself.
    param([Parameter(Mandatory=$true)][string]$OperationId,[bool]$IntegratedSession=$true,[bool]$RefusedForScope=$false,[bool]$AlternateAvailable=$false,[bool]$AlternateRefused=$false)
    if ($AlternateAvailable -and $AlternateRefused) { return [pscustomobject]@{Mode='AskAccount';Prompt=$true;Reason='Le compte fourni pour cette ressource a ete refuse.'} }
    if ($AlternateAvailable) { return [pscustomobject]@{Mode='Alternate';Prompt=$false;Reason='Compte fourni pour cette ressource.'} }
    if ($IntegratedSession -and -not $RefusedForScope) { return [pscustomobject]@{Mode='Integrated';Prompt=$false;Reason='Jeton Windows courant.'} }
    if ($RefusedForScope) { return [pscustomobject]@{Mode='AskAccount';Prompt=$true;Reason='Le jeton courant a ete refuse pour cette ressource.'} }
    return [pscustomobject]@{Mode='Session';Prompt=$false;Reason='Compte de la session Domenia.'}
}

# ---------------------------------------------------------------- D056 explained capabilities
function Get-DomeniaCapabilityExplanation {
    # States what is known about an action: tested, estimated from ACLs, unknown, or refused.
    # An ACL estimate is never presented as a definitive effective right.
    param([Parameter(Mandatory=$true)][string]$Action,[Parameter(Mandatory=$true)][ValidateSet('Tested','Estimated','Unknown','Refused','ReadOnly','Busy','NoSelection','Stale')][string]$State,[string]$Detail='',[string]$Route='')
    $label = ''; $definitive = $false; $defaultRoute = $Route
    switch ($State) {
        'Tested'      { $label = 'Verifie : l action a deja abouti avec ce compte.'; $definitive = $true }
        'Estimated'   { $label = 'Estime d apres les permissions lues. Le droit effectif n est connu qu a l execution.' }
        'Unknown'     { $label = 'Inconnu : les permissions n ont pas pu etre lues.'; if (-not $defaultRoute) { $defaultRoute = 'TabPermissions' } }
        'Refused'     { $label = 'Refuse par la ressource pour ce compte.'; if (-not $defaultRoute) { $defaultRoute = 'TabAccounts' } }
        'ReadOnly'    { $label = 'Lecture seule active : les modifications sont desactivees.'; if (-not $defaultRoute) { $defaultRoute = 'ChkReadOnlyMode' } }
        'Busy'        { $label = 'Une ecriture est en cours ou a verifier.'; if (-not $defaultRoute) { $defaultRoute = 'TabGuard' } }
        'NoSelection' { $label = 'Selectionnez d abord un objet.'; if (-not $defaultRoute) { $defaultRoute = 'WsSearch' } }
        'Stale'       { $label = 'Donnees en cache : une relecture AD est necessaire avant de modifier.'; if (-not $defaultRoute) { $defaultRoute = 'BtnObjectReadRetry' } }
    }
    $text = $Action + ' : ' + $label
    if ($Detail) { $text += ' ' + $Detail }
    return [pscustomobject]@{Action=$Action;State=$State;Text=$text;Definitive=$definitive;Route=$defaultRoute}
}

# ---------------------------------------------------------------- Point 46 required right of each operation
function Get-DomeniaOperationRequirement {
    # Point 46: the account, the right and the network access an operation needs, stated before any call and quoted
    # after a failure. Derived from the reviewed classification (Get-DomeniaOperationProvider, Get-DomeniaOperationEffect);
    # an operation outside it says that its right is not documented, it is never given a guessed one.
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$OperationId)
    $id = ([string]$OperationId).Trim()
    $ldap = 'LDAP 389/TCP vers le contrôleur de domaine (signature et scellement).'
    $cim = 'CIM/DCOM : 135/TCP puis ports RPC dynamiques du poste ; WSMan 5985/5986 seulement sʼil est déjà en service.'
    $eventLog = 'Journal dʼévénements à distance : 135/TCP puis ports RPC dynamiques du contrôleur.'
    $connection = 'Compte de connexion'
    $machine = 'Compte poste, sinon compte de connexion'
    $secrets = 'Compte secrets, sinon compte de connexion'
    $directoryRead = 'Lecture de lʼannuaire : tout compte authentifié du domaine lit les attributs ordinaires ; un attribut confidentiel exige un droit délégué.'
    $workstationRead = 'Administrateur local du poste, ou droits WMI délégués (activation DCOM à distance et lecture de root\cimv2).'
    # Resource, account, right, access. One row per operation whose right differs from its family.
    $specific = @{
        'PermissionAnalysis'    = @('Directory',$connection,'Lecture du descripteur de sécurité de lʼobjet (Lire les autorisations).',$ldap)
        'LogonHarvest'          = @('Directory',$connection,'Lecture du journal Sécurité du contrôleur : membre du groupe Lecteurs des journaux dʼévénements du contrôleur, ou administrateur du domaine.',$eventLog)
        'LockoutDiagnosis'      = @('Directory',$connection,'Lecture du journal Sécurité de lʼémulateur PDC : membre du groupe Lecteurs des journaux dʼévénements du contrôleur, ou administrateur du domaine.',$eventLog)
        'ReadLaps'              = @('Laps',$secrets,'Lecture de lʼattribut du mot de passe LAPS de lʼordinateur (ms-LAPS-Password ou ms-Mcs-AdmPwd) ; pour Windows LAPS chiffré, membre des déchiffreurs autorisés.',$ldap)
        'ReadBitLocker'         = @('BitLocker',$secrets,'Lecture des objets de récupération BitLocker sous lʼordinateur (droit délégué ; réservé par défaut aux administrateurs du domaine).',$ldap)
        'ReadBitLockerList'     = @('BitLocker',$secrets,'Lecture des objets de récupération BitLocker sous lʼordinateur (droit délégué ; réservé par défaut aux administrateurs du domaine).',$ldap)
        'BitLockerPresence'     = @('BitLocker',$secrets,'Lecture des objets de récupération BitLocker de lʼOU (droit délégué ; réservé par défaut aux administrateurs du domaine).',$ldap)
        'ReadBitLockerKey'      = @('BitLocker',$secrets,'Lecture de lʼattribut confidentiel msFVE-RecoveryPassword de la clé choisie (droit de contrôle dʼaccès étendu).',$ldap)
        'UserComputerProbe'     = @('Remote',$machine,'Annuaire lu avec le compte de connexion ; consoles des postes : administrateur local ou droits WMI délégués ; journal Sécurité du contrôleur, sur demande : Lecteurs des journaux dʼévénements.',$cim)
        'RemoteCredentialCheck' = @('Remote','Compte proposé','Ouverture dʼune session CIM/DCOM sur le poste avec le compte proposé : administrateur local ou droits WMI délégués.',$cim)
        'SessionsList'          = @('Remote',$machine,'Énumération des sessions Windows du poste : administrateur local.','RPC et SMB 445/TCP vers le poste.')
        'ComputerAdminShare'    = @('Remote',$machine,'Accès au partage administratif du poste : administrateur local.','SMB 445/TCP vers le poste.')
        'ComputerGpUpdate'      = @('Remote',$machine,'Exécution distante sur le poste : administrateur local, WinRM déjà en service sur le poste.','WinRM 5985/TCP ou 5986/TCP vers le poste.')
        'ComputerRestart'       = @('Remote',$machine,'Redémarrage à distance : administrateur local du poste (privilège Forcer lʼarrêt à partir dʼun système distant).',$cim)
        'RimotteRun'            = @('Remote',$machine,'Intervention scriptée : administrateur local du poste et autorisation explicite et temporaire dans Domenia (Outils > Fiabilité).','SMB 445/TCP (ADMIN$) et Planificateur de tâches par RPC.')
        'WakeOnLanSend'         = @('Network','Aucun compte','Aucun droit : paquet de réveil diffusé sur le réseau local ; la carte réseau du poste doit accepter le réveil.','Diffusion UDP sur le réseau local.')
        'ParkSharedSync'        = @('Network','Session Windows','Lecture et écriture du fichier partagé configuré (droits NTFS et de partage de votre session Windows).','SMB 445/TCP vers le partage, ou disque local.')
        'ConnectorRead'         = @('Network','Session Windows','Lecture du connecteur configuré avec votre session Windows.','Selon le connecteur configuré.')
        'ReceiptStore'          = @('Local','Aucun compte distant','Reçus locaux dʼécriture dans votre profil Windows : aucun droit dans lʼannuaire ni sur les postes.','Aucun accès réseau.')
        'WriteAttributes'       = @('Directory',$connection,'Écriture de chaque attribut modifié sur lʼobjet (Écrire la propriété, délégué ou hérité).',$ldap)
        'WriteResetPassword'    = @('Directory',$connection,'Droit étendu Réinitialiser le mot de passe sur lʼobjet ; écriture de pwdLastSet quand le changement est imposé.',$ldap)
        'WriteUnlock'           = @('Directory',$connection,'Écriture de lockoutTime sur le compte (droit délégué de déverrouillage).',$ldap)
        'WriteAccountDisabled'  = @('Directory',$connection,'Écriture de userAccountControl sur le compte.',$ldap)
        'WriteAccountOptions'   = @('Directory',$connection,'Écriture de userAccountControl sur le compte.',$ldap)
        'WriteExpiration'       = @('Directory',$connection,'Écriture de accountExpires sur le compte.',$ldap)
        'WriteExpirePassword'   = @('Directory',$connection,'Écriture de pwdLastSet sur le compte.',$ldap)
        'WriteGroupMember'      = @('Directory',$connection,'Écriture de lʼattribut member du groupe (Écrire les membres).',$ldap)
        'WriteObjectGroup'      = @('Directory',$connection,'Écriture de lʼattribut member de chaque groupe modifié (Écrire les membres).',$ldap)
        'WriteMoveObject'       = @('Directory',$connection,'Supprimer lʼobjet dans son OU dʼorigine et créer ce type dʼobjet dans lʼOU cible.',$ldap)
        'WriteRenameComputer'   = @('Directory',$connection,'Renommer lʼobjet ordinateur (écriture de son nom) dans son OU.',$ldap)
        'WriteCreateOu'         = @('Directory',$connection,'Créer des objets unité dʼorganisation dans lʼOU parente.',$ldap)
        'WriteDeleteObject'     = @('Directory',$connection,'Supprimer lʼobjet (droit Supprimer sur lʼobjet, ou Supprimer lʼenfant sur lʼOU parente).',$ldap)
    }
    $directoryReads = @('GlobalSearch','TreeChildren','OpenAdObject','OpenLinkedObject','LiveDirectoryCheck','ScopeReconcile','ReconcileScope','IndexBuild','IndexRefresh','IndexOuList','DomainOverview','SelfCheck','EmbeddedDirectoryLookup','StartupWarmCache','StartupWarmup','PruneLinks','ObjectChanges','PasswordPolicyRead','GroupPathRead','GpoLinksRead','DcCompareRead','AdConsistencyScan','AccountAliasRead')
    $row = $null
    if (-not $id) { $row = $null }
    elseif ($specific.ContainsKey($id)) { $row = $specific[$id] }
    elseif ($directoryReads -contains $id) { $row = @('Directory',$connection,$directoryRead,$ldap) }
    else {
        $provider = Get-DomeniaOperationProvider $id
        $effect = Get-DomeniaOperationEffect $id
        if ($provider -in @('Cim','Wts')) { $row = @('Remote',$machine,$workstationRead,$cim) }
        elseif ($provider -eq 'Network') { $row = @('Network','Aucun compte','Aucun droit : écho ICMP vers le poste ; son pare-feu doit le laisser passer.','ICMP écho vers le poste.') }
        elseif ($provider -in @('Storage','Local')) { $row = @('Local','Aucun compte distant','Fichiers locaux de votre profil Windows : aucun droit dans lʼannuaire ni sur les postes.','Aucun accès réseau.') }
        elseif ($effect -eq 'Read') { $row = @('Directory',$connection,$directoryRead,$ldap) }
        elseif ($effect -eq 'DirectoryWrite') { $row = @('Directory',$connection,'Écriture sur lʼobjet : droit délégué correspondant à chaque attribut modifié.',$ldap) }
    }
    if ($null -eq $row) {
        return [pscustomobject]@{OperationId=$id;Known=$false;Resource='';Account='';Right='Droit non documenté pour cette opération : lisez le code dʼerreur natif.';Access=''}
    }
    return [pscustomobject]@{OperationId=$id;Known=$true;Resource=[string]$row[0];Account=[string]$row[1];Right=[string]$row[2];Access=[string]$row[3]}
}

function Get-DomeniaFailureFamily {
    # Point 46: three causes never confused. Refused access: the account was accepted, the right is missing. Rejected
    # account: the identity itself was refused, or is locked, disabled or expired. Unavailable resource: no usable
    # answer, so neither the account nor the right is in question yet. The other categories keep their own wording.
    param([AllowEmptyString()][string]$Category='')
    switch ([string]$Category) {
        'AccessDenied'        { return [pscustomobject]@{Family='AccessDenied';Label='Refus dʼaccès';Meaning='Le compte a été accepté, mais il nʼa pas le droit demandé sur cette ressource.'} }
        'DecryptionDenied'    { return [pscustomobject]@{Family='AccessDenied';Label='Refus dʼaccès';Meaning='La lecture est permise, le déchiffrement est refusé à ce compte.'} }
        'Unconfirmed'         { return [pscustomobject]@{Family='Unconfirmed';Label='Accès non confirmé';Meaning='Aucune valeur visible : publication absente ou droit de lecture manquant, indiscernables ici.'} }
        'CredentialsRejected' { return [pscustomobject]@{Family='AccountRejected';Label='Compte rejeté';Meaning='Lʼidentifiant ou le mot de passe a été refusé : ce nʼest pas un manque de droit.'} }
        'AccountState'        { return [pscustomobject]@{Family='AccountRejected';Label='Compte rejeté';Meaning='Le compte est verrouillé, désactivé ou expiré : ce nʼest pas un manque de droit.'} }
        'Network'             { return [pscustomobject]@{Family='Unavailable';Label='Ressource indisponible';Meaning='La ressource ne répond pas : ni le compte ni le droit ne sont en cause à ce stade.'} }
        'Timeout'             { return [pscustomobject]@{Family='Unavailable';Label='Ressource indisponible';Meaning='Aucune réponse dans le délai : ni le compte ni le droit ne sont en cause à ce stade.'} }
        'Prerequisite'        { return [pscustomobject]@{Family='Prerequisite';Label='Prérequis absent';Meaning='Un composant manque sur ce poste ou sur la cible.'} }
        'Uncertain'           { return [pscustomobject]@{Family='Uncertain';Label='Issue inconnue';Meaning='La demande est partie sans résultat confirmé : à vérifier avant toute nouvelle action.'} }
    }
    return [pscustomobject]@{Family='Unknown';Label='Erreur non classée';Meaning='La cause nʼest pas déterminée par le code renvoyé.'}
}

function Get-DomeniaOperationFailureGuidance {
    # Point 46: one sentence added to an error: the family of the failure and what the operation needed. The right is
    # quoted for a refusal, the account for a rejection, the network access for an unavailable resource; an
    # unclassified failure adds nothing, so that no cause is suggested without a code.
    param([AllowEmptyString()][string]$OperationId='',[AllowEmptyString()][string]$Category='')
    $family = Get-DomeniaFailureFamily $Category
    $need = $null
    if (([string]$OperationId).Trim()) { $need = Get-DomeniaOperationRequirement $OperationId }
    $text = ''
    switch ([string]$family.Family) {
        'AccessDenied' {
            $text = $family.Label + ' : ' + $family.Meaning
            if (($null -ne $need) -and ([bool]$need.Known)) { $text += ' Droit requis : ' + $need.Right }
        }
        'Unconfirmed' {
            $text = $family.Label + ' : ' + $family.Meaning
            if (($null -ne $need) -and ([bool]$need.Known)) { $text += ' Droit requis : ' + $need.Right }
        }
        'AccountRejected' {
            $text = $family.Label + ' : ' + $family.Meaning
            if (($null -ne $need) -and ([bool]$need.Known) -and ([string]$need.Account)) { $text += ' Compte concerné : ' + $need.Account + '.' }
        }
        'Unavailable' {
            $text = $family.Label + ' : ' + $family.Meaning
            if (($null -ne $need) -and ([bool]$need.Known) -and ([string]$need.Access)) { $text += ' Accès réseau nécessaire : ' + $need.Access }
        }
        'Prerequisite' { $text = $family.Label + ' : ' + $family.Meaning }
    }
    $right = ''; if ($null -ne $need) { $right = [string]$need.Right }
    return [pscustomobject]@{Family=[string]$family.Family;Label=[string]$family.Label;Text=$text;Right=$right}
}

# ---------------------------------------------------------------- D057 LAPS: read and decryption are distinct
function ConvertTo-DomeniaLapsView {
    # $Result: {Source, Published, ExpirationUtc, Account, Decryptor, PasswordPresent, ReadStatus, DecryptStatus, Reader}.
    # The password itself is never passed to this function.
    param($Result,[datetime]$NowUtc=[datetime]::UtcNow)
    $read = [string](Get-DomeniaMember $Result 'ReadStatus' 'Unknown')
    $decrypt = [string](Get-DomeniaMember $Result 'DecryptStatus' 'NotAttempted')
    $present = [bool](Get-DomeniaMember $Result 'PasswordPresent' $false)
    $source = [string](Get-DomeniaMember $Result 'Source' '')
    $reader = [string](Get-DomeniaMember $Result 'Reader' '')
    $expiry = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $Result 'ExpirationUtc' $null)
    $facts = New-Object 'System.Collections.Generic.List[object]'
    $sourceLabel = switch ($source) { 'WindowsLaps' { 'Windows LAPS' } 'LegacyLaps' { 'LAPS historique (ms-Mcs-AdmPwd)' } default { 'Source non determinee' } }
    $facts.Add((New-DomeniaFact -Fait 'Source' -Valeur $sourceLabel -Source 'Attributs AD du poste' -Lecteur $reader))
    $state = 'Unknown'; $message = ''
    if ($read -eq 'AccessDenied') {
        $state = 'ReadDenied'; $message = 'Lecture des attributs LAPS refusee pour ce compte.'
        $facts.Add((New-DomeniaFact -Fait 'Lecture' -Valeur 'Refusee' -Etat Refuse -Limite 'Un refus de lecture ne dit pas si un mot de passe est publie.' -Lecteur $reader))
    } elseif ($read -eq 'ModuleMissing') {
        $state = 'Prerequisite'; $message = 'Module LAPS absent sur ce poste d administration.'
        $facts.Add((New-DomeniaFact -Fait 'Lecture' -Valeur 'Prerequis absent' -Etat Indisponible -Lecteur $reader))
    } elseif ($read -eq 'Unconfirmed') {
        # Nothing readable: a confidential attribute that cannot be read looks absent. No verdict either way.
        $state = 'Unconfirmed'; $message = 'Aucune valeur LAPS visible avec ce compte : publication ou droits a verifier.'
        $facts.Add((New-DomeniaFact -Fait 'Publication' -Valeur 'Non confirmee' -Etat Inconnu -Limite 'Un attribut confidentiel illisible parait absent : ce n est pas une preuve d absence.' -Lecteur $reader))
    } elseif ($read -eq 'Failed') {
        $state = 'Unknown'; $message = 'Lecture LAPS non aboutie : aucun constat sur la publication.'
        $facts.Add((New-DomeniaFact -Fait 'Lecture' -Valeur 'Non aboutie' -Etat Indisponible -Lecteur $reader))
    } elseif ($read -eq 'NotPublished' -or ($read -eq 'OK' -and -not [bool](Get-DomeniaMember $Result 'Published' $false))) {
        $state = 'NotPublished'; $message = 'Aucun mot de passe LAPS publie pour ce poste, d apres les attributs lisibles.'
        $facts.Add((New-DomeniaFact -Fait 'Publication' -Valeur 'Aucune' -Limite 'Constat valable pour le compte de lecture utilise.' -Lecteur $reader))
    } elseif ($read -eq 'OK') {
        $facts.Add((New-DomeniaFact -Fait 'Publication' -Valeur 'Publie' -Lecteur $reader))
        if ($null -ne $expiry) {
            $value = $expiry.ToLocalTime().ToString('dd/MM/yyyy HH:mm')
            if ($expiry -lt $NowUtc) { $value += ' (echue)' }
            $facts.Add((New-DomeniaFact -Fait 'Expiration' -Valeur $value -Lecteur $reader))
        }
        $account = [string](Get-DomeniaMember $Result 'Account' '')
        if ($account) { $facts.Add((New-DomeniaFact -Fait 'Compte gere' -Valeur $account -Lecteur $reader)) }
        $decryptor = [string](Get-DomeniaMember $Result 'Decryptor' '')
        if ($decryptor) { $facts.Add((New-DomeniaFact -Fait 'Dechiffreur autorise' -Valeur $decryptor -Lecteur $reader)) }
        switch ($decrypt) {
            'OK'           { if ($present) { $state = 'Available'; $message = 'Mot de passe lu. Revelation et copie a la demande.' } else { $state = 'Empty'; $message = 'Lecture aboutie mais valeur absente.' } }
            'NotEncrypted' { if ($present) { $state = 'Available'; $message = 'Mot de passe lu (non chiffre dans l annuaire). Revelation et copie a la demande.' } else { $state = 'Empty'; $message = 'Lecture aboutie mais valeur absente.' } }
            'Unauthorized' {
                # Not an empty password, and not a failure of the whole account either.
                $state = 'DecryptDenied'; $message = 'Mot de passe publie et lu, mais ce compte n est pas autorise a le dechiffrer.'
                $facts.Add((New-DomeniaFact -Fait 'Dechiffrement' -Valeur 'Refuse' -Etat Refuse -Limite 'Le mot de passe existe : seul le dechiffrement est refuse a ce compte.' -Lecteur $reader))
            }
            default        { $state = 'DecryptPending'; $message = 'Mot de passe publie ; dechiffrement non tente.' }
        }
    } else {
        $message = 'Etat LAPS non determine.'
    }
    return [pscustomobject]@{
        State=$state;Message=$message;Facts=$facts.ToArray()
        HasPassword=($state -eq 'Available');CanReveal=($state -eq 'Available')
        OfferOtherAccount=($state -in @('ReadDenied','DecryptDenied','Unconfirmed'))
        BlocksBitLocker=$false;BlocksDirectoryAccount=$false
    }
}

# ---------------------------------------------------------------- D058 BitLocker: pick the right key
function ConvertTo-DomeniaBitLockerKeyList {
    # $Entries: msFVE-RecoveryInformation objects as {Name, DN, WhenCreated}. Name = "<ISO date>{<key GUID>}".
    # Metadata only: the recovery password is not requested, not carried and not displayed here.
    param([object[]]$Entries=@())
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $name = [string](Get-DomeniaMember $entry 'Name' '')
        $guid = ''
        # msFVE-RecoveryGuid read by the list worker first; the GUID embedded in the object name otherwise.
        $recoveryGuid = ConvertTo-DomeniaGuidText (Get-DomeniaMember $entry 'RecoveryGuid' $null)
        if ($recoveryGuid) { $guid = $recoveryGuid.ToUpperInvariant() }
        elseif ($name -match '\{(?<guid>[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\}') { $guid = $Matches['guid'].ToUpperInvariant() }
        if (-not $guid) { continue }
        $created = ConvertTo-DomeniaUtcDate (Get-DomeniaMember $entry 'WhenCreated' $null)
        if ($null -eq $created -and $name -match '^(?<date>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[-+]\d{2}:\d{2})') { $created = ConvertTo-DomeniaUtcDate $Matches['date'] }
        [pscustomobject]@{
            RecoveryId=$guid.Substring(0,8);KeyGuid=$guid;DN=[string](Get-DomeniaMember $entry 'DN' '')
            Created=$(if ($null -ne $created) { $created.ToLocalTime().ToString('dd/MM/yyyy HH:mm') } else { 'date inconnue' });CreatedUtc=$created
        }
    }
}

function Find-DomeniaBitLockerKey {
    # The recovery screen shows the first eight characters of the key identifier.
    param([object[]]$Keys=@(),[AllowEmptyString()][string]$RecoveryId='')
    $wanted = (([string]$RecoveryId).Trim().Trim('{','}') -replace '\s','').ToUpperInvariant()
    if ($wanted.Length -lt 4) { return [pscustomobject]@{Matches=@();Unique=$false;Message='Saisissez au moins les quatre premiers caracteres de l identifiant de recuperation.'} }
    $found = @(@($Keys) | Where-Object { $null -ne $_ -and ([string]$_.KeyGuid).StartsWith($wanted,[StringComparison]::OrdinalIgnoreCase) })
    $message = 'Aucune cle ne porte cet identifiant pour ce poste.'
    if ($found.Count -eq 1) { $message = 'Cle identifiee. Revelez-la ou copiez-la a la demande.' }
    elseif ($found.Count -gt 1) { $message = [string]$found.Count + ' cles correspondent : completez l identifiant.' }
    return [pscustomobject]@{Matches=$found;Unique=($found.Count -eq 1);Message=$message}
}

function Test-DomeniaDirectChildDn {
    # True when $ChildDn is exactly one RDN below $ParentDn (escaped commas allowed in that RDN).
    # A recovery key is only requested for an object directly under the selected computer.
    param([AllowEmptyString()][string]$ParentDn,[AllowEmptyString()][string]$ChildDn)
    $parent = ([string]$ParentDn).Trim(); $child = ([string]$ChildDn).Trim()
    if (-not $parent -or -not $child -or $child.Length -le $parent.Length + 1) { return $false }
    if (-not $child.EndsWith(',' + $parent,[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $rdn = $child.Substring(0,$child.Length - $parent.Length - 1)
    if (-not $rdn -or $rdn.EndsWith('\')) { return $false }
    return (($rdn -replace '\\.','') -notmatch ',')
}

function Test-DomeniaSecretRevealAllowed {
    # Opening a tab or selecting a line never reveals a secret. Only an explicit gesture on ONE secret does.
    param([Parameter(Mandatory=$true)][string]$Trigger,[int]$SelectedCount=1)
    if ($Trigger -notin @('ExplicitReveal','ExplicitCopy')) { return $false }
    return ($SelectedCount -eq 1)
}

# ---------------------------------------------------------------- D059 secret exposure
function Get-DomeniaSecretExposurePolicy {
    return [pscustomobject]@{
        InProcessArguments=$false;InLogs=$false;InCache=$false;InSnapshots=$false;InAutomaticExports=$false;InReceipts=$false
        RevealSeconds=30;CopyOneAtATime=$true
        ClipboardLimit='Les gestionnaires de presse-papiers tiers et l historique Windows peuvent conserver une copie hors de Domenia.'
    }
}

function Protect-DomeniaSecretText {
    # Masks what looks like a secret before a text reaches a log, a trace or an export.
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $masked = $Text
    # BitLocker recovery password: eight groups of six digits.
    $masked = [regex]::Replace($masked,'(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)','[cle de recuperation masquee]')
    # HTTP authorization schemes.
    $masked = [regex]::Replace($masked,'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9_.~+/=-]+','$1 ***')
    # JSON members, LAPS payload {"n":"account","t":"...","p":"password"} included.
    $masked = [regex]::Replace($masked,'(?i)("(?:password|passwd|pwd|pass|p|motdepasse|secret|token|api[_-]?key|apikey|client[_-]?secret)"\s*:\s*)("(?:\\.|[^"\\])*"|[^,}\s]+)','$1"***"')
    # key=value and key: value forms, in French and in English.
    $masked = [regex]::Replace($masked,'(?i)\b(password|passwd|pwd|pass|motdepasse|mot\s+de\s+passe|secret|token|authorization|api[_-]?key|apikey|client[_-]?secret)(\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s;,]+)','$1$2***')
    # Password switches of command lines, at the start of the text too, with a blank, ':' or '=' separator.
    $masked = [regex]::Replace($masked,'(?i)(^|\s)([-/](?:p|rp|pass|password|pwd))(?:\s+|[:=])("[^"]*"|''[^'']*''|\S+)','$1$2 ***')
    return $masked
}

function Test-DomeniaTextHasSecret {
    # Used by the secret-marker test campaign: true when one of the planted markers is present.
    param([AllowEmptyString()][AllowNull()][string]$Text,[string[]]$Markers=@())
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($marker in @($Markers)) { if ($marker -and $Text.IndexOf($marker,[StringComparison]::Ordinal) -ge 0) { return $true } }
    return $false
}

function Protect-DomeniaExportRows {
    # Point 50: an export never carries a secret. A column named after a secret attribute is withheld whatever it
    # holds; every text cell goes through the masking rule of the journal (recovery passwords, key=value secrets,
    # authorization headers). Numbers, dates and booleans are kept as they are. Returns the rows and what was masked.
    param([object[]]$Rows=@())
    $masked=0;$withheld=New-Object 'System.Collections.Generic.List[string]';$out=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in @($Rows)){
        if($null -eq $row){continue}
        $safe=[ordered]@{}
        foreach($property in $row.PSObject.Properties){
            if($property.MemberType -notin @('NoteProperty','Property','AliasProperty','ScriptProperty')){continue}
            $name=[string]$property.Name;$value=$property.Value
            if(Test-DomeniaSecretAttribute $name){
                if(($null -ne $value) -and ([string]$value)){$masked++}
                if(-not $withheld.Contains($name)){$withheld.Add($name)}
                $safe[$name]='[valeur secrète non exportée]'
                continue
            }
            if($value -is [string]){
                $clean=Protect-DomeniaSecretText $value
                if($clean -cne $value){$masked++}
                $safe[$name]=$clean
            }else{$safe[$name]=$value}
        }
        $out.Add([pscustomobject]$safe)
    }
    return [pscustomobject]@{Rows=$out.ToArray();Masked=$masked;Withheld=$withheld.ToArray()}
}

function Select-DomeniaAllowedFields {
    # Allow-list projection: a field that is not named is not exported, whatever it contains.
    param($Record,[Parameter(Mandatory=$true)][string[]]$Allowed)
    $result = [ordered]@{}
    foreach ($name in $Allowed) {
        $value = Get-DomeniaMember $Record $name $null
        if ($null -ne $value) { $result[$name] = Protect-DomeniaSecretText ([string]$value) }
    }
    return [pscustomobject]$result
}

# ---------------------------------------------------------------- D060 visible transport policy
function Get-DomeniaTransportPolicy {
    # What Domenia uses, what stays off, and why. Nothing here changes a Windows setting.
    param([bool]$UseCim=$true,[bool]$UseWinRM=$true,[bool]$UsePsExecFallback=$true,[bool]$UseTaskFallback=$true,[bool]$ArtifactConsent=$false)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $rows.Add([pscustomobject]@{Transport='LDAP';Usage='Lectures et ecritures de l annuaire';Ports='389/TCP (signature et scellement Kerberos/NTLM)';Etat='Actif';Regle='Authentification securisee Windows. Aucun certificat n est accepte a l aveugle.';Intrusif=$false})
    $rows.Add([pscustomobject]@{Transport='CIM / DCOM';Usage='Lectures sur les postes';Ports='135/TCP puis ports RPC dynamiques';Etat=$(if ($UseCim) { 'Actif' } else { 'Desactive par configuration' });Regle='Lecture seule par defaut. Aucun reglage du poste n est modifie.';Intrusif=$false})
    $rows.Add([pscustomobject]@{Transport='CIM / WSMan';Usage='Repli des lectures CIM';Ports='5985/TCP ou 5986/TCP';Etat=$(if ($UseWinRM) { 'Autorise si deja en service sur le poste' } else { 'Desactive par configuration' });Regle='WinRM n est jamais active ni configure par Domenia.';Intrusif=$false})
    $rows.Add([pscustomobject]@{Transport='WTS';Usage='Lecture des sessions Windows';Ports='RPC / 445/TCP';Etat='A la demande';Regle='Consultation uniquement : aucune deconnexion.';Intrusif=$false})
    $rows.Add([pscustomobject]@{Transport='Partage ADMIN$';Usage='Depot temporaire d un script d intervention';Ports='445/TCP';Etat=$(if ($ArtifactConsent) { 'Autorise pour le poste et la duree consentis' } else { 'Inactif sans autorisation explicite' });Regle='Jamais utilisé sans autorisation explicite d intervention sur le poste. Une lecture exige une autorisation distincte, demandée pour cette lecture.';Intrusif=$true})
    $rows.Add([pscustomobject]@{Transport='Planificateur (COM)';Usage='Execution ponctuelle d une intervention';Ports='RPC';Etat=$(if (-not $UseTaskFallback) { 'Desactive par configuration' } elseif ($ArtifactConsent) { 'Autorise pour le poste et la duree consentis' } else { 'Inactif sans autorisation explicite' });Regle='Aucun mot de passe en argument. Aucun repli silencieux.';Intrusif=$true})
    $rows.Add([pscustomobject]@{Transport='PsExec';Usage='Execution ponctuelle d une intervention';Ports='445/TCP';Etat=$(if (-not $UsePsExecFallback) { 'Desactive par configuration' } elseif ($ArtifactConsent) { 'Autorise, contexte Windows integre uniquement' } else { 'Inactif sans autorisation explicite' });Regle='Aucun compte explicite converti en argument.';Intrusif=$true})
    return $rows.ToArray()
}

function Test-DomeniaTransportFallbackAllowed {
    # An intrusive transport is never used as a silent fallback of a read. SE-07: the five-minute
    # intervention consent is not a read consent; a read is allowed only when it was asked for
    # that read alone (-ReadConsentGiven). This function is the real decision of the fallback path.
    param([Parameter(Mandatory=$true)][string]$Transport,[bool]$Intrusive=$false,[bool]$ConsentGiven=$false,[bool]$IsRead=$true,[bool]$ReadConsentGiven=$false)
    if (-not $Intrusive) { return [pscustomobject]@{Allowed=$true;Reason=''} }
    if ($IsRead -and -not $ReadConsentGiven) { return [pscustomobject]@{Allowed=$false;Reason=($Transport + ' n est pas utilise pour une lecture ou une detection.')} }
    if ($IsRead) { return [pscustomobject]@{Allowed=$true;Reason=''} }
    if (-not $ConsentGiven) { return [pscustomobject]@{Allowed=$false;Reason=($Transport + ' exige une autorisation explicite pour ce poste.')} }
    return [pscustomobject]@{Allowed=$true;Reason=''}
}

function Test-DomeniaTransportCodeSafety {
    # Static check of a source text: constructs that weaken Windows are refused by the test campaign.
    param([AllowEmptyString()][string]$SourceText)
    $patterns = [ordered]@{
        'Validation de certificat neutralisee'='(?i)ServerCertificateValidationCallback\s*=|ServerCertificateCustomValidationCallback|-SkipCertificateCheck|-SkipCACheck|-SkipCNCheck|-SkipRevocationCheck|VerifyServerCertificate\s*=\s*\{'
        'Activation ou configuration de WinRM'='(?i)\bEnable-PSRemoting\b|\bSet-WSManQuickConfig\b|winrm\s+quickconfig|Set-Item\s+["'']?WSMan:'
        'Modification de l antivirus'='(?i)\bSet-MpPreference\b|\bAdd-MpPreference\b|DisableRealtimeMonitoring'
        'Modification du pare-feu'='(?i)netsh\s+advfirewall|\bSet-NetFirewallProfile\b|\bNew-NetFirewallRule\b|\bDisable-NetFirewallRule\b'
        'Modification de strategie'='(?i)\bSet-GPRegistryValue\b|\bSet-ExecutionPolicy\b\s+(?!.*-Scope\s+Process)'
    }
    $findings = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $patterns.Keys) { if ([regex]::IsMatch([string]$SourceText,$patterns[$name])) { $findings.Add($name) } }
    return [pscustomobject]@{Safe=($findings.Count -eq 0);Findings=$findings.ToArray()}
}
