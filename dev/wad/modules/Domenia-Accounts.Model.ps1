# Sign-in and accounts presentation rules (lot X03): wording of a refused sign-in, choice of the sign-in mode, verdict
# of a trial of the workstation account, accounts in use per resource, workstation account pill and intervention
# countdown. Pure decisions: no credential object, no WPF, no network call, no disk and no secret value is handled here.

# ---------------------------------------------------------------- UI-20 sign-in refusal in plain words
function Get-DomeniaLoginFailureText {
    # UI-20: what the sign-in window says after a refusal: a short, polite sentence and the next step. The Active
    # Directory code (52e, 775, 0x80070775...) is returned in Code for the diagnostic copied on request, never in Text.
    # $Category is the worker classification (Credentials, AccountRestriction, Authentication, AccessDenied, Internal,
    # Metadata, DomainUnavailable, Timeout, Input); $Message is the technical text kept for the diagnostic.
    param([AllowNull()][AllowEmptyString()][string]$Category='',[AllowNull()][AllowEmptyString()][string]$Message='')
    $c=([string]$Category).Trim()
    $m=([string]$Message).Trim()
    # Anchored forms only: a controller called dc775 never becomes a locked account.
    $code='';$short=''
    if($m -match '(?i)(?:\bdata|\bcode AD)\s+([0-9a-f]{3,4})\b'){$code=$Matches[1].ToLowerInvariant();$short=$code}
    elseif($m -match '(?i)\b0x8007(0525|052e|052f|0530|0531|0532|0533|0701|0773|0775)\b'){$code='0x8007'+$Matches[1].ToUpperInvariant();$short=$Matches[1].TrimStart('0').ToLowerInvariant()}
    $byCode=@{'525'='UnknownAccount';'52e'='BadCredentials';'52f'='Restricted';'530'='Hours';'531'='Workstation';'532'='PasswordExpired';'533'='Disabled';'701'='AccountExpired';'773'='MustChange';'775'='Locked'}
    $internalText='(?i)NullArray|Indexation impossible dans un tableau Null|Cannot index into a null array|DOMENIA_AUTH_(ENTRY|PROPERTIES|NATIVE)_NULL'
    $credentialText='(?i)logon failure|unknown user name or bad password|user ?name or password is incorrect|nom d.?utilisateur.*mot de passe.*incorrect|identifiant.*mot de passe.*(incorrect|refus)|mot de passe.*incorrect|invalid credentials|credentials.*invalid'
    $kind=''
    if(($c -eq 'Internal') -or ($m -match $internalText)){$kind='Internal'}
    elseif(($short) -and ($byCode.ContainsKey($short))){$kind=[string]$byCode[$short]}
    elseif($c -eq 'Metadata'){$kind='Metadata'}
    elseif($c -eq 'AccessDenied'){$kind='AccessDenied'}
    elseif($c -eq 'Timeout'){$kind='Timeout'}
    elseif($c -eq 'DomainUnavailable'){$kind='Unreachable'}
    elseif($c -eq 'Input'){$kind='Input'}
    elseif($m -match $credentialText){$kind='BadCredentials'}
    elseif($m -match '(?i)account.*locked|compte.*verrouill'){$kind='Locked'}
    elseif($m -match '(?i)account.*disabled|compte.*d[eé]sactiv'){$kind='Disabled'}
    elseif($m -match '(?i)password.*expired|mot de passe.*expir'){$kind='PasswordExpired'}
    elseif($c -eq 'Credentials'){$kind='BadCredentials'}
    elseif($c -eq 'AccountRestriction'){$kind='Restricted'}
    elseif($c -eq 'Authentication'){$kind='Authentication'}
    else{$kind='Unknown'}
    $change='Changez-le (Ctrl+Alt+Suppr, Modifier un mot de passe) puis réessayez.'
    $diagnostic='Copiez le diagnostic ou ouvrez le journal pour voir lʼétape en échec.'
    $network='Vérifiez le réseau, le DNS ou le VPN, puis réessayez.'
    $pair=switch($kind){
        'UnknownAccount'  {@('Compte inconnu de lʼannuaire.','Vérifiez lʼidentifiant et son domaine (DOMAINE\identifiant ou identifiant@domaine).')}
        'BadCredentials'  {@('Identifiant ou mot de passe refusé.','Vérifiez la saisie avant un nouvel essai.')}
        'Restricted'      {@('Connexion refusée par une restriction du compte.','Le mot de passe a souvent expiré : changez-le (Ctrl+Alt+Suppr, Modifier un mot de passe) puis réessayez. Sinon, vérifiez les postes et les horaires autorisés pour ce compte.')}
        'Hours'           {@('Connexion interdite à cette heure pour ce compte.','Réessayez pendant les horaires autorisés ou demandez leur modification.')}
        'Workstation'     {@('Connexion interdite depuis ce poste pour ce compte.','Utilisez un poste autorisé ou demandez lʼajout de celui-ci.')}
        'PasswordExpired' {@('Mot de passe expiré.',$change)}
        'Disabled'        {@('Compte désactivé.','Demandez sa réactivation puis réessayez.')}
        'AccountExpired'  {@('Compte expiré.','Demandez la prolongation de sa date dʼexpiration puis réessayez.')}
        'MustChange'      {@('Mot de passe à changer avant la connexion.',$change)}
        'Locked'          {@('Compte verrouillé.','Demandez son déverrouillage puis réessayez.')}
        'Internal'        {@('Erreur interne pendant la connexion.',('Elle ne prouve pas un mauvais mot de passe. '+$diagnostic))}
        'Metadata'        {@('Lecture des informations du domaine incomplète.',$diagnostic)}
        'AccessDenied'    {@('Accès refusé par lʼannuaire pendant la connexion.','Vérifiez le contexte, les droits du compte et ses restrictions ; le détail est dans le diagnostic.')}
        'Unreachable'     {@('Contrôleur de domaine injoignable.',$network)}
        'Timeout'         {@('Délai dépassé pendant la connexion.',$network)}
        'Authentication'  {@('Authentification refusée sans cause identifiée.','Copiez le diagnostic avant tout nouvel essai.')}
        'Input'           {
            if($m -match '(?i)d[eé]monstration'){@('Identité de démonstration attendue (DEMO\nom).','Saisissez une identité de démonstration.')}
            elseif($m -match '(?i)manquant'){@('Identifiant ou mot de passe manquant.','Complétez les champs demandés.')}
            else{@('Informations de connexion incomplètes.','Complétez les champs demandés.')}
        }
        default           {if($m){@('Connexion non validée.',$diagnostic)}else{@('Échec de validation du compte.',$diagnostic)}}
    }
    return [pscustomobject]@{Kind=$kind;Message=[string]$pair[0];Hint=[string]$pair[1];Text=([string]$pair[0]+' '+[string]$pair[1]);Code=$code}
}

# ---------------------------------------------------------------- UX-28 sign-in: the Windows session first
function Get-DomeniaLoginChoice {
    # UX-28: in a domain session the Windows account is the main action, « Continuer en tant que DOMAINE\nom », and
    # the account and password form comes second (« Utiliser un autre compte »). $WindowsIdentity is the session
    # account already filtered by Get-DomeniaProcessWindowsIdentity (no computer, local or system account).
    # $PreferForm: the operator asked to change account, the form opens directly with the Windows button below it.
    param([AllowNull()][AllowEmptyString()][string]$WindowsIdentity='',[bool]$AllowWindowsSession=$true,[bool]$Demo=$false,[bool]$PreferForm=$false)
    $identity=([string]$WindowsIdentity).Trim()
    $offered=(([bool]$AllowWindowsSession) -and (-not $Demo))
    $available=(($offered) -and ($identity.Length -gt 0))
    $label='Utiliser mon compte Windows';$tip=''
    if($available){
        $label='Continuer en tant que '+$identity
        $tip='Ouvre Domenia avec votre session Windows ('+$identity+'), sans mot de passe. Aucun droit nʼest ajouté.'
    }elseif($offered){
        $tip='Indisponible : Domenia nʼest pas lancé sous un compte utilisateur du domaine.'
    }
    return [pscustomobject]@{Offered=$offered;Available=$available;WindowsFirst=(($available) -and (-not $PreferForm));WindowsLabel=$label;WindowsToolTip=$tip;OtherAccountLabel='Utiliser un autre compte'}
}

# ---------------------------------------------------------------- CO-31 read-only identity of the directory
function Get-DomeniaDirectoryAccountText {
    # CO-31: the read-only card of the directory account: the identity that really bound (BindUser), how it signed in,
    # the controller and the domain. There is no field to edit: a new account goes through « Changer de compte ».
    param([AllowNull()][AllowEmptyString()][string]$Account='',[AllowNull()][AllowEmptyString()][string]$AuthMode='',[AllowNull()][AllowEmptyString()][string]$Server='',[AllowNull()][AllowEmptyString()][string]$Domain='')
    $identity=([string]$Account).Trim()
    if(-not $identity){
        return [pscustomobject]@{Connected=$false;Identity='Aucune identité active.';Mode='';Detail='Aucune connexion à lʼannuaire : utilisez « Changer de compte ».'}
    }
    $mode=switch(([string]$AuthMode).Trim()){
        'Windows'  {'Session Windows'}
        'Explicit' {'Compte saisi à la connexion'}
        'Demo'     {'Démonstration, annuaire fictif'}
        default    {'Compte de connexion'}
    }
    $parts=New-Object 'System.Collections.Generic.List[string]'
    $parts.Add([string]$mode)
    $controller=([string]$Server).Trim();if($controller){$parts.Add('contrôleur '+$controller)}
    $dns=([string]$Domain).Trim();if($dns){$parts.Add('domaine '+$dns)}
    return [pscustomobject]@{Connected=$true;Identity=$identity;Mode=[string]$mode;Detail=($parts.ToArray() -join ' · ')}
}

# ---------------------------------------------------------------- UX-15 / UI-27 / FO-19 account used for the workstations
function Get-DomeniaMachineAccountLabel {
    # Names the account the next workstation operation takes, from the source found by Get-DomeniaMachineAccountInUse
    # (same order as the worker context): TemporaryLocal, Temporary, Typed, Remote, Connection or Windows.
    # Short feeds the pill of Assistance poste, Long the sentences and the Comptes page. Names only, never a secret.
    param([AllowNull()][AllowEmptyString()][string]$Source='',[AllowNull()][AllowEmptyString()][string]$Account='')
    $name=([string]$Account).Trim()
    $origin=switch(([string]$Source).Trim()){
        'TemporaryLocal' {'compte local temporaire de ce poste'}
        'Temporary'      {'compte temporaire accepté après un refus'}
        'Typed'          {'compte poste saisi, en mémoire seulement'}
        'Remote'         {'compte Postes de la page Comptes'}
        'Connection'     {'compte de connexion'}
        default          {'session Windows'}
    }
    $isWindows=($origin -eq 'session Windows')
    $short=if($isWindows){'session Windows'}elseif($name){$name}else{$origin}
    $long=if($name){$name+' ('+$origin+')'}else{$origin}
    if(($isWindows) -and ($name)){$long='session Windows ('+$name+')'}
    return [pscustomobject]@{Source=$(if($isWindows){'Windows'}else{([string]$Source).Trim()});Account=$name;Origin=$origin;Short=$short;Long=$long;Pill=('Compte poste : '+$short+' '+[string][char]0x25BE)}
}

function Get-DomeniaRemoteAccessTrialVerdict {
    # FO-19: what one light CIM read (Win32_OperatingSystem.Caption) on one workstation proves about the account used
    # for the workstations. $Outcome is the LiveConsole answer, $ErrorText the error of the read, $Category its
    # Get-DomeniaErrorDecision category. Only an explicit success says « Accès administrateur OK ».
    param([AllowNull()][AllowEmptyString()][string]$Outcome='',[AllowNull()][AllowEmptyString()][string]$ErrorText='',[AllowNull()][AllowEmptyString()][string]$Category='',[AllowNull()][AllowEmptyString()][string]$Computer='',[AllowNull()][AllowEmptyString()][string]$Account='',[AllowNull()][AllowEmptyString()][string]$Caption='')
    $o=([string]$Outcome).Trim();$e=([string]$ErrorText).Trim();$k=([string]$Category).Trim()
    $target=([string]$Computer).Trim();if(-not $target){$target='ce poste'}
    $who=([string]$Account).Trim();if(-not $who){$who='le compte utilisé pour les postes'}
    $verdict='Unknown'
    if(($o -eq 'AuthRejected') -or ($k -eq 'CredentialsRejected')){$verdict='Rejected'}
    elseif($k -eq 'AccountState'){$verdict='AccountState'}
    elseif(($o -eq 'Denied') -or ($k -in @('AccessDenied','DecryptionDenied'))){$verdict='Denied'}
    elseif(($o -eq 'Timeout') -or ($k -in @('Timeout','Network'))){$verdict='Unreachable'}
    elseif($e -match '(?i)RPC|0x800706BA|unavailable|indisponible|injoignable|not reachable|network path|chemin r[eé]seau'){$verdict='Unreachable'}
    elseif((-not $e) -and ($o -in @('NotRequested','Observed','NoConsole'))){$verdict='AdminOk'}
    $text=switch($verdict){
        'AdminOk'      {'Accès administrateur OK sur '+$target+' avec '+$who+'.'+$(if(([string]$Caption).Trim()){' Système : '+([string]$Caption).Trim()+'.'}else{''})}
        'Denied'       {'Accès refusé sur '+$target+' avec '+$who+' : droit administrateur requis sur ce poste.'}
        'Rejected'     {'Identifiants refusés par '+$target+' pour '+$who+' : vérifiez le compte et son mot de passe.'}
        'AccountState' {'Compte verrouillé, expiré ou restreint ('+$who+') : vérifiez son état avant un nouvel essai.'}
        'Unreachable'  {'Poste '+$target+' injoignable (réseau, nom ou service WMI) : aucun droit nʼa pu être vérifié.'}
        default        {'Essai non concluant sur '+$target+$(if($e){' : '+$(if($e.Length -gt 160){$e.Substring(0,160)+'…'}else{$e})}else{'.'})}
    }
    return [pscustomobject]@{Verdict=$verdict;Success=($verdict -eq 'AdminOk');Text=[string]$text}
}

# ---------------------------------------------------------------- UI-27 accounts in use now
function Get-DomeniaAccessScopeLabel {
    # UI-27: plain name of the resource a temporary account serves (key of the access state), never the internal key.
    param([AllowNull()][AllowEmptyString()][string]$Key='')
    $k=([string]$Key).Trim()
    if($k.StartsWith('RemoteLocal|',[StringComparison]::Ordinal)){return ('Poste '+$k.Substring(12)+' (compte local)')}
    $known=@{'Remote'='Postes';'ReadLaps'='Secrets : LAPS';'ReadBitLocker'='Secrets : BitLocker';'Directory'='Annuaire';'AD:GlobalSearch'='Annuaire : recherche';'AD:UserComputerProbe'='Annuaire : postes dʼun utilisateur';'AD:OpenAdObject'='Annuaire : lecture des fiches';'AD:TreeChildren'='Annuaire : arborescence';'Presence'='Présence des postes';'LocalFile'='Fichiers locaux'}
    foreach($name in @($known.Keys)){if($k -ceq $name){return [string]$known[$name]}}
    if($k.StartsWith('AD:',[StringComparison]::Ordinal)){return ('Annuaire : opération '+$k.Substring(3))}
    return 'Autre ressource'
}

function Get-DomeniaLeaseRemainingText {
    # UI-27: how long a temporary account stays usable, in whole minutes rounded up, so that the text changes once a
    # minute. Same verdict as Test-DomeniaCredentialLease for a new use: another session or a forgotten lease is spent.
    param($Lease,[long]$Epoch=0,[datetime]$NowUtc=[datetime]::UtcNow)
    if($null -eq $Lease){return [pscustomobject]@{Usable=$true;Minutes=-1;Text='jusquʼà la fin de la session'}}
    $check=Test-DomeniaCredentialLease -Lease $Lease -Epoch $Epoch -NowUtc $NowUtc -ForNewCall $true
    if(-not [bool]$check.Usable){return [pscustomobject]@{Usable=$false;Minutes=0;Text='expiré : oublié au prochain contrôle'}}
    if([string]$Lease.Mode -eq 'OneShot'){return [pscustomobject]@{Usable=$true;Minutes=-1;Text='une seule utilisation'}}
    if([string]$Lease.Mode -eq 'Session'){return [pscustomobject]@{Usable=$true;Minutes=-1;Text='jusquʼà la fin de la session'}}
    $left=[double]$Lease.InactivityMinutes-($NowUtc-[datetime]$Lease.LastUsedUtc).TotalMinutes
    $minutes=[int][Math]::Ceiling([Math]::Max(0.0,$left))
    if($minutes -lt 1){$minutes=1}
    return [pscustomobject]@{Usable=$true;Minutes=$minutes;Text=('encore '+$minutes+' min sans utilisation')}
}

function Get-DomeniaAccountsInUseRows {
    # UI-27: « En ce moment » of the Comptes page. Now: the account each resource takes for its next operation
    # (directory, each directory operation holding its own temporary account, workstations, LAPS, BitLocker).
    # Memory: what can be forgotten (account typed for the workstations, temporary accounts accepted after a
    # refusal) with the remaining time. The UI layer passes names and leases only: no credential, no secret, no
    # clock read here. $Machine is a Get-DomeniaMachineAccountLabel object;
    # $Temporary holds the usable temporary accounts as @{Key;UserName;Lease}.
    param(
        [AllowNull()][AllowEmptyString()][string]$DirectoryAccount='',
        [AllowNull()][AllowEmptyString()][string]$DirectoryMode='',
        $Machine=$null,
        [AllowNull()][AllowEmptyString()][string]$SecretsAccount='',
        [AllowNull()][AllowEmptyString()][string]$TypedMachineAccount='',
        [object[]]$Temporary=@(),
        [long]$Epoch=0,
        [datetime]$NowUtc=[datetime]::UtcNow
    )
    $temporaryOrigin='compte temporaire accepté après un refus'
    $byKey=@{}
    foreach($item in @($Temporary)){if($null -ne $item){$byKey[[string]$item.Key]=$item}}
    $directory=([string]$DirectoryAccount).Trim()
    $directoryOrigin=switch(([string]$DirectoryMode).Trim()){'Windows'{'session Windows'}'Demo'{'démonstration, annuaire fictif'}''{'aucune connexion'}default{'compte de connexion'}}
    if(-not $directory){$directoryOrigin='aucune connexion'}
    $now=[Collections.Generic.List[object]]::new()
    $now.Add([pscustomobject]@{Resource='Annuaire';Account=$(if($directory){$directory}else{'Aucune identité active'});Origin=$directoryOrigin})
    # A directory operation that received its own temporary account (key AD:<operation>, Get-DomeniaRetryCredential)
    # takes it instead of the connection account: one line per operation, right under the directory.
    foreach($key in @($byKey.Keys|Where-Object{([string]$_).StartsWith('AD:',[StringComparison]::Ordinal)}|Sort-Object)){
        $now.Add([pscustomobject]@{Resource=(Get-DomeniaAccessScopeLabel $key);Account=[string]$byKey[$key].UserName;Origin=$temporaryOrigin})
    }
    if($null -ne $Machine){
        $machineAccount=[string]$Machine.Account;if(-not $machineAccount){$machineAccount=[string]$Machine.Short}
        $now.Add([pscustomobject]@{Resource='Postes (WMI, C$, consoles)';Account=$machineAccount;Origin=[string]$Machine.Origin})
    }
    $secrets=([string]$SecretsAccount).Trim()
    foreach($pair in @(@('Secrets : LAPS','ReadLaps'),@('Secrets : BitLocker','ReadBitLocker'))){
        if($byKey.ContainsKey($pair[1])){$now.Add([pscustomobject]@{Resource=$pair[0];Account=[string]$byKey[$pair[1]].UserName;Origin=$temporaryOrigin})}
        elseif($secrets){$now.Add([pscustomobject]@{Resource=$pair[0];Account=$secrets;Origin='compte Secrets de la page Comptes'})}
        else{$now.Add([pscustomobject]@{Resource=$pair[0];Account=$(if($directory){$directory}else{'Aucune identité active'});Origin='même compte que lʼannuaire'})}
    }
    $memory=[Collections.Generic.List[object]]::new()
    $typed=([string]$TypedMachineAccount).Trim()
    if($typed){$memory.Add([pscustomobject]@{Key='Typed:Machine';Resource='Compte poste saisi';Account=$typed;Remaining='jusquʼà « Revenir au compte de connexion » ou la fin de la session'})}
    foreach($key in @($byKey.Keys|Sort-Object)){
        $item=$byKey[$key]
        $memory.Add([pscustomobject]@{Key=[string]$key;Resource=(Get-DomeniaAccessScopeLabel $key);Account=[string]$item.UserName;Remaining=[string](Get-DomeniaLeaseRemainingText -Lease $item.Lease -Epoch $Epoch -NowUtc $NowUtc).Text})
    }
    return [pscustomobject]@{Now=$now.ToArray();Memory=$memory.ToArray()}
}

# ---------------------------------------------------------------- UX-16 authorisation of an intervention, visible in Intervenir
function Test-DomeniaConsentCovers {
    # UX-16: a consent (intervention or one read) covers the open workstation only: its target or one of its aliases,
    # in the current session and before its expiry. Same comparison as the worker guards (name lists).
    param($Consent,[AllowNull()][AllowEmptyString()][string]$Target='',[AllowNull()][AllowEmptyString()][string]$Short='',[long]$Epoch=0,[datetime]$NowUtc=[datetime]::UtcNow)
    if($null -eq $Consent){return $false}
    if(([long]$Consent.Epoch -ne $Epoch) -or ([datetime]$Consent.Expires -le $NowUtc)){return $false}
    $names=@(@([string]$Consent.Target)+@($Consent.Aliases)|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)}|ForEach-Object{([string]$_).Trim()})
    foreach($candidate in @(([string]$Target).Trim(),([string]$Short).Trim())){if(($candidate) -and ($names -icontains $candidate)){return $true}}
    return $false
}

function Get-DomeniaInterventionPillState {
    # UX-16: what the top of the Intervenir view of Assistance poste shows about the authorisation of an intervention (5 min, one
    # workstation, explicit click) and about the separate one-read consent (SE-07). Pure: the caller passes the two
    # consents, the open workstation and the clock. Remaining time as m:ss, rounded up to the second.
    param($ArtifactConsent=$null,$ReadConsent=$null,[AllowNull()][AllowEmptyString()][string]$Target='',[AllowNull()][AllowEmptyString()][string]$Short='',[long]$Epoch=0,[datetime]$NowUtc=[datetime]::UtcNow)
    $target=([string]$Target).Trim()
    $active=Test-DomeniaConsentCovers -Consent $ArtifactConsent -Target $target -Short $Short -Epoch $Epoch -NowUtc $NowUtc
    $read=Test-DomeniaConsentCovers -Consent $ReadConsent -Target $target -Short $Short -Epoch $Epoch -NowUtc $NowUtc
    $elsewhere=''
    if((-not $active) -and ($null -ne $ArtifactConsent) -and ([long]$ArtifactConsent.Epoch -eq $Epoch) -and ([datetime]$ArtifactConsent.Expires -gt $NowUtc)){$elsewhere=([string]$ArtifactConsent.Target).Trim()}
    $remaining='';$seconds=0
    if($active){
        $seconds=[int][Math]::Ceiling(([datetime]$ArtifactConsent.Expires-$NowUtc).TotalSeconds)
        $remaining=([string][Math]::Floor($seconds/60))+':'+($seconds%60).ToString('00')
    }
    if(-not $target){$state='Ouvrez un poste pour autoriser une intervention sur lui seul.'}
    elseif($active){$state='Intervention autorisée sur '+[string]$ArtifactConsent.Target+' pendant encore '+$remaining+', pour ce poste seulement et pour vos actions volontaires.'}
    elseif($elsewhere){$state='Une intervention est autorisée sur '+$elsewhere+', pas sur ce poste. « Exécuter un programme » et les replis PsExec ou tâche planifiée la demandent ici.'}
    else{$state='Aucune intervention autorisée sur ce poste. « Exécuter un programme » et les replis PsExec ou tâche planifiée la demandent.'}
    if(($target) -and ($read)){$state+=' Prochaine lecture de ce poste autorisée par tâche planifiée (une seule lecture).'}
    return [pscustomobject]@{Active=[bool]$active;Seconds=$seconds;Remaining=$remaining;PillText=$(if($active){'Intervention autorisée '+$remaining+' ·'}else{''});StateText=$state;ReadPending=[bool](($target) -and ($read));CanGrant=[bool](($target) -and (-not $active))}
}

function Get-DomeniaMessageRoute {
    # UX-16: a message that sends the operator to « Assistance poste > Intervenir » (intervention or one-read consent)
    # gets a route button in its banner. Text only: the route opens the view, it authorises or starts nothing.
    param([AllowNull()][AllowEmptyString()][string]$Text='')
    if(([string]$Text).Contains('Assistance poste > Intervenir')){return 'TabComputerAdmin'}
    return ''
}
