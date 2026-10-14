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
    if($c -eq 'Internal' -or $m -match $internalText){$kind='Internal'}
    elseif($short -and $byCode.ContainsKey($short)){$kind=[string]$byCode[$short]}
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
    $offered=($AllowWindowsSession -and (-not $Demo))
    $available=($offered -and ($identity.Length -gt 0))
    $label='Utiliser mon compte Windows';$tip=''
    if($available){
        $label='Continuer en tant que '+$identity
        $tip='Ouvre Domenia avec votre session Windows ('+$identity+'), sans mot de passe. Aucun droit nʼest ajouté.'
    }elseif($offered){
        $tip='Indisponible : Domenia nʼest pas lancé sous un compte utilisateur du domaine.'
    }
    return [pscustomobject]@{Offered=$offered;Available=$available;WindowsFirst=($available -and (-not $PreferForm));WindowsLabel=$label;WindowsToolTip=$tip;OtherAccountLabel='Utiliser un autre compte'}
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
