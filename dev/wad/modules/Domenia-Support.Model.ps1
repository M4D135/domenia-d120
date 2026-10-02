#requires -Version 5.1
# DOMENIA 1.0 R1.5 : pure local support model. No AD calls, credentials or WPF types.
# Kept separate so the rules, bounds and exports can be tested without a domain.

function Get-DomeniaSupportFieldNames {
    # Positive allowlist, deliberately excluding secrets, certificates and free-text notes.
    @('name','distinguishedName','objectGUID','sAMAccountName','userPrincipalName',
      'displayName','mail','department','company','title','physicalDeliveryOfficeName',
      'manager','managedBy','dNSHostName','operatingSystem','operatingSystemVersion',
      'location','userAccountControl','msDS-User-Account-Control-Computed',
      'lockoutTime','pwdLastSet','accountExpires','whenCreated','whenChanged',
      'uSNChanged','memberOf','primaryGroupID','adminCount','isCriticalSystemObject')
}

function ConvertTo-DomeniaSupportText {
    param([AllowNull()]$Value,[ValidateRange(16,32768)][int]$Limit=1024)
    if ($null -eq $Value) { return '' }
    if ($Value -is [Security.SecureString] -or $Value -is [Management.Automation.PSCredential] -or $Value -is [byte[]]) { return '[valeur exclue]' }
    if ($Value -is [datetime]) { $text=$Value.ToUniversalTime().ToString('o') }
    elseif ($Value -is [string] -or $Value -is [ValueType]) { $text=[string]$Value }
    else { return '[type non pris en charge]' }
    $wasLong=($text.Length -gt $Limit)
    if ($wasLong) { $text=$text.Substring(0,$Limit+1) }
    $text=[regex]::Replace($text,'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]',' ')
    # Defence in depth for accidental secret text in an otherwise allowed field.
    $text=[regex]::Replace($text,'(?i)\b(password|passwd|pwd|mot de passe|secret|token|api[_-]?key)\s*[:=]\s*[^\r\n]+','$1=[masque]')
    $text=[regex]::Replace($text,'(?i)\bBearer\s+[^\s]+','Bearer [masque]')
    $text=[regex]::Replace($text,'(?<!\d)(?:\d{6}-){7}\d{6}(?!\d)','[cle de recuperation masquee]')
    if ($wasLong -or $text.Length -gt $Limit) { return $text.Substring(0,[Math]::Min($Limit,$text.Length))+' [tronque]' }
    return $text
}

function New-DomeniaSupportSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.IDictionary]$Properties,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Dn,
        [string]$Name='', [string]$Type='Objet',
        [ValidateSet('Live','Cache','Unknown')][string]$Source='Unknown',
        [datetime]$ObservedAtUtc=[datetime]::UtcNow,
        [datetime]$CapturedAtUtc=[datetime]::UtcNow
    )
    $fields=[ordered]@{}; $coverage=[ordered]@{}; $count=0
    foreach ($field in (Get-DomeniaSupportFieldNames)) {
        # A ranged memberOf read is partial even if the range is not yet expanded.
        $key=$null; $ranged=$false
        foreach ($candidate in $Properties.Keys) {
            if ([string]$candidate -ieq $field) { $key=$candidate; break }
        }
        if ($null -eq $key -and $field -eq 'memberOf') {
            foreach ($candidate in $Properties.Keys) {
                if ([string]$candidate -imatch '^memberOf;range=') { $key=$candidate; $ranged=$true; break }
            }
        }
        if ($null -eq $key) { $coverage[$field]='NotProvided'; continue }
        $values=New-Object Collections.ArrayList
        $partial=$ranged
        if($field -eq "memberOf" -and $Properties.Contains("__memberOfComplete") -and -not [bool]$Properties["__memberOfComplete"]){$partial=$true}
        foreach ($value in $Properties[$key]) {
            if ($values.Count -ge 128) { $partial=$true; break }
            $clean=ConvertTo-DomeniaSupportText -Value $value
            if ($clean -match '\[(masque|cle de recuperation masquee)\]' -or $clean.EndsWith(' [tronque]') -or $clean -eq '[valeur exclue]' -or $clean -eq '[type non pris en charge]') { $partial=$true }
            if (-not [string]::IsNullOrEmpty($clean)) { [void]$values.Add($clean) }
        }
        $fields[$field]=[string[]]$values.ToArray([string])
        $coverage[$field]=if ($partial) {'Partial'} else {'Provided'}
        $count++
    }
    $identity='dn:'+ $Dn.Trim().ToLowerInvariant()
    if ($fields.Contains('objectGUID') -and @($fields['objectGUID']).Count -gt 0) {
        $guid=[guid]::Empty
        if ([guid]::TryParse([string]$fields['objectGUID'][0],[ref]$guid) -and $guid -ne [guid]::Empty) { $identity='guid:'+$guid.ToString('D') }
    }
    [pscustomobject]@{
        Format=1; Id=[guid]::NewGuid().ToString('N'); Identity=$identity
        Scope=$Scope.Trim().ToLowerInvariant(); Dn=(ConvertTo-DomeniaSupportText $Dn 4096)
        Name=(ConvertTo-DomeniaSupportText $Name 256); Type=(ConvertTo-DomeniaSupportText $Type 64)
        Source=$Source; ObservedAtUtc=$ObservedAtUtc.ToUniversalTime().ToString('o')
        CapturedAtUtc=$CapturedAtUtc.ToUniversalTime().ToString('o')
        Fields=$fields; Coverage=$coverage; FieldCount=$count
    }
}

function Get-DomeniaSupportField {
    param($Snapshot,[string]$Name)
    if ($null -eq $Snapshot -or $null -eq $Snapshot.Fields -or -not $Snapshot.Fields.Contains($Name)) { return '' }
    return (@($Snapshot.Fields[$Name]) -join ' ; ')
}

function Get-DomeniaSupportInt64 {
    param($Snapshot,[string]$Name)
    if ($null -eq $Snapshot -or [string]$Snapshot.Coverage[$Name] -ne 'Provided') { return $null }
    $value=Get-DomeniaSupportField $Snapshot $Name
    $number=[long]0
    if ([long]::TryParse($value,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)) { return $number }
    return $null
}

function New-DomeniaSupportFinding {
    param([string]$Code,[string]$Level,[string]$Title,[string]$Evidence,[string]$Next,[string]$Basis='Observation')
    [pscustomobject]@{Code=$Code;Level=$Level;Title=$Title;Evidence=$Evidence;Next=$Next;Basis=$Basis}
}

function Get-DomeniaSupportFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Snapshot,[datetime]$NowUtc=[datetime]::UtcNow)
    $rows=New-Object Collections.ArrayList
    if ($Snapshot.Source -ne 'Live') {
        [void]$rows.Add((New-DomeniaSupportFinding 'DATA_NOT_LIVE' 'A verifier' 'Lecture AD fraiche non etablie' ('Source : '+$Snapshot.Source+'. Age reel des donnees AD non etabli.') 'Actualiser la fiche avant une decision. L heure de capture ne rajeunit pas le cache.' 'Couverture'))
    } else {
        $observed=[datetime]::Parse($Snapshot.ObservedAtUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        $age=($NowUtc.ToUniversalTime()-$observed.ToUniversalTime()).TotalMinutes
        if ($age -gt 15) { [void]$rows.Add((New-DomeniaSupportFinding 'DATA_OLD' 'A verifier' 'Lecture de plus de 15 minutes' ('Derniere lecture : '+$observed.ToUniversalTime().ToString('u')) 'Actualiser pour confirmer les valeurs. Le seuil de 15 minutes est un repere local, pas une regle AD.' 'Couverture')) }
    }
    $uac=Get-DomeniaSupportInt64 $Snapshot 'userAccountControl'
    $computed=Get-DomeniaSupportInt64 $Snapshot 'msDS-User-Account-Control-Computed'
    $account=($Snapshot.Type -in @('Utilisateur','Machine'))
    if ($account -and $null -eq $uac) {
        [void]$rows.Add((New-DomeniaSupportFinding 'UAC_UNKNOWN' 'Non determine' 'Etat du compte non determine' 'userAccountControl absent, partiel ou illisible.' 'Relire les proprietes de la fiche. Une absence de valeur ne signifie pas un compte actif.' 'Couverture'))
    }
    if ($null -ne $uac -and ($uac -band 2) -ne 0) {
        [void]$rows.Add((New-DomeniaSupportFinding 'ACCOUNT_DISABLED' 'Attention' 'Compte desactive dans la lecture' ('userAccountControl='+$uac+' ; bit ACCOUNTDISABLE present.') 'Confirmer le motif de desactivation avant toute intervention. Aucune reactivation automatique.'))
    }
    if ($Snapshot.Type -eq 'Utilisateur') {
        if ($null -ne $computed) {
            if (($computed -band 16) -ne 0) { [void]$rows.Add((New-DomeniaSupportFinding 'ACCOUNT_LOCKED' 'Attention' 'Verrouillage indique par le DC' 'msDS-User-Account-Control-Computed : bit LOCKOUT present dans la lecture.' 'Confirmer par une relecture puis rechercher l origine des tentatives.')) }
            if (($computed -band 8388608) -ne 0) { [void]$rows.Add((New-DomeniaSupportFinding 'PASSWORD_EXPIRED' 'Attention' 'Expiration du mot de passe indiquee par le DC' 'msDS-User-Account-Control-Computed : bit PASSWORD_EXPIRED present.' 'Verifier les modalites de changement de mot de passe avec l utilisateur.')) }
        } else {
            $lock=Get-DomeniaSupportInt64 $Snapshot 'lockoutTime'
            if ($null -ne $lock -and $lock -gt 0) {
                [void]$rows.Add((New-DomeniaSupportFinding 'LOCKOUT_HISTORY' 'A verifier' 'Trace de verrouillage, etat actuel non confirme' ('lockoutTime='+$lock+' ; attribut calcule non fourni.') 'Cette trace seule ne prouve pas un verrouillage actuel. Verifier la politique de duree et l etat calcule du DC.' 'Limite'))
            }
        }
        $pwd=Get-DomeniaSupportInt64 $Snapshot 'pwdLastSet'
        if ($null -ne $pwd -and $pwd -eq 0) {
            if ($null -ne $uac -and ($uac -band 65536) -eq 0) {
                [void]$rows.Add((New-DomeniaSupportFinding 'PASSWORD_CHANGE_REQUIRED' 'Attention' 'Changement du mot de passe demande' 'pwdLastSet=0 et DONT_EXPIRE_PASSWORD absent.' 'Prevoir un parcours permettant le changement au prochain logon. Ne pas conclure a un mauvais mot de passe.'))
            } else {
                [void]$rows.Add((New-DomeniaSupportFinding 'PASSWORD_STATE_REVIEW' 'A verifier' 'pwdLastSet a zero : options a verifier' 'pwdLastSet=0 ; options du compte absentes ou DONT_EXPIRE_PASSWORD present.' 'Verifier ensemble les options et la politique du compte avant de conclure.' 'Limite'))
            }
        }
        if ($null -ne $uac -and ($uac -band 65536) -ne 0) {
            [void]$rows.Add((New-DomeniaSupportFinding 'PASSWORD_NO_EXPIRY' 'Information' 'Option de non-expiration du mot de passe' 'Bit DONT_EXPIRE_PASSWORD present.' 'Verifier que cette option correspond a la politique et a la fonction du compte.'))
        }
        $expires=Get-DomeniaSupportInt64 $Snapshot 'accountExpires'
        if ($null -ne $expires -and $expires -gt 0 -and $expires -ne [long]::MaxValue) {
            try {
                $date=[datetime]::FromFileTimeUtc($expires)
                if ($date -le $NowUtc.ToUniversalTime()) {
                    [void]$rows.Add((New-DomeniaSupportFinding 'ACCOUNT_EXPIRED' 'Attention' 'Date d expiration du compte depassee' ('accountExpires : '+$date.ToString('u')) 'Confirmer le besoin et les autorisations avant de prolonger le compte.'))
                } elseif (($date-$NowUtc.ToUniversalTime()).TotalDays -le 7) {
                    [void]$rows.Add((New-DomeniaSupportFinding 'ACCOUNT_EXPIRING' 'A verifier' 'Compte expirant dans moins de 7 jours' ('accountExpires : '+$date.ToString('u')) 'Anticiper avec le responsable. Le seuil de 7 jours est un repere local.'))
                }
            } catch { [void]$rows.Add((New-DomeniaSupportFinding 'EXPIRY_INVALID' 'Non determine' 'Date d expiration illisible' 'accountExpires hors de la plage de dates exploitable.' 'Relire la valeur brute avant de conclure.' 'Couverture')) }
        }
    }
    if ($Snapshot.Type -eq 'Machine' -and [string]::IsNullOrWhiteSpace((Get-DomeniaSupportField $Snapshot 'dNSHostName'))) {
        [void]$rows.Add((New-DomeniaSupportFinding 'DNS_NOT_PROVIDED' 'A verifier' 'Nom DNS complet non fourni' 'dNSHostName absent ou vide dans la capture.' 'Verifier la fiche et la resolution DNS. Ceci ne prouve ni une panne DNS ni un poste hors ligne.' 'Couverture'))
    }
    $admin=Get-DomeniaSupportInt64 $Snapshot 'adminCount'
    if ($null -ne $admin -and $admin -eq 1) {
        [void]$rows.Add((New-DomeniaSupportFinding 'ADMINCOUNT' 'Information' 'Marqueur de protection a examiner' 'adminCount=1.' 'Ne pas en deduire les droits actuels. Verifier les appartenances et ACL effectives.' 'Limite'))
    }
    if (@($Snapshot.Coverage.Values | Where-Object {$_ -eq 'Partial'}).Count -gt 0) {
        [void]$rows.Add((New-DomeniaSupportFinding 'PARTIAL_CAPTURE' 'A verifier' 'Capture partielle' 'Au moins un attribut est borne, range ou non pris en charge.' 'Les comparaisons de ces attributs restent indeterminees.' 'Couverture'))
    }
    if ($rows.Count -eq 0) {
        [void]$rows.Add((New-DomeniaSupportFinding 'NO_FINDING' 'Information' 'Aucun signal dans les regles appliquees' ('Analyse locale de '+$Snapshot.FieldCount+' attribut(s) fournis.') 'Ce resultat ne valide ni la sante du poste, ni les droits effectifs, ni une session distante.' 'Limite'))
    }
    return $rows.ToArray()
}

function Compare-DomeniaSupportSnapshots {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Before,[Parameter(Mandatory)]$After,[switch]$DifferencesOnly)
    if ([string]$Before.Scope -ine [string]$After.Scope) { throw 'Comparaison refusee : perimetres AD differents.' }
    if ([string]$Before.Type -ine [string]$After.Type) { throw 'Comparaison refusee : types d objets differents.' }
    $rows=New-Object Collections.ArrayList
    foreach ($field in (Get-DomeniaSupportFieldNames)) {
        $leftState=[string]$Before.Coverage[$field]; $rightState=[string]$After.Coverage[$field]
        if ($leftState -eq 'NotProvided' -and $rightState -eq 'NotProvided') { continue }
        $left=Get-DomeniaSupportField $Before $field; $right=Get-DomeniaSupportField $After $field
        $status='Identique'; $added=''; $removed=''
        if ($leftState -ne 'Provided' -or $rightState -ne 'Provided') {
            $status='Indetermine'
            if ($leftState -eq 'NotProvided') { $left='[non fourni]' }
            if ($rightState -eq 'NotProvided') { $right='[non fourni]' }
            if ($leftState -eq 'Partial') { $left+=' [partiel]' }
            if ($rightState -eq 'Partial') { $right+=' [partiel]' }
        } elseif ($field -eq 'memberOf') {
            # Direct memberships only. Case and returned order are not a change.
            $a=@{}; $b=@{}
            foreach ($v in @($Before.Fields[$field])) { $a[[string]$v]=$true }
            foreach ($v in @($After.Fields[$field])) { $b[[string]$v]=$true }
            $adds=@($b.Keys | Where-Object {-not $a.ContainsKey($_)} | Sort-Object)
            $removes=@($a.Keys | Where-Object {-not $b.ContainsKey($_)} | Sort-Object)
            $added=$adds -join ' ; '; $removed=$removes -join ' ; '
            if ($adds.Count -gt 0 -or $removes.Count -gt 0) { $status='Different' }
        } elseif ($left -cne $right) { $status='Different' }
        if ($DifferencesOnly -and $status -eq 'Identique') { continue }
        [void]$rows.Add([pscustomobject]@{Attribute=$field;Status=$status;Before=$left;After=$right;Added=$added;Removed=$removed})
    }
    return $rows.ToArray()
}

function Get-DomeniaSupportIncidentRules {
    # Fixed-size regular expressions against a bounded string, never user-supplied regex.
    @(
        [pscustomobject]@{Code='SMB_SESSION_CONFLICT';Pattern='(?i)(\b1219\b|multiple connections|connexions multiples)';Title='Conflit de sessions SMB';Evidence='Code 1219 ou message de connexions multiples.';Next='Verifier les sessions SMB vers cette cible et le compte choisi. Ne pas deconnecter globalement les lecteurs de l utilisateur.';Route='accounts'},
        [pscustomobject]@{Code='CANCELLED';Pattern='(?i)(annul|superseded|beginstop|cancel|detachee du GUI)';Title='Operation interrompue ou remplacee';Evidence='Le message mentionne une annulation ou un remplacement.';Next='Attendre le nettoyage puis relancer une seule fois sur la cible. Une interruption ne signifie pas utilisateur absent.';Route='health'},
        [pscustomobject]@{Code='AUTH_CONTEXT';Pattern='(?i)(0x8007052e|\b1326\b|invalid credentials|identification fournies ne sont pas valides|logon failure|echec.*ouverture de session)';Title='Authentification refusee dans ce contexte';Evidence='Le message contient un refus d authentification.';Next='Verifier identite complete, domaine, cible et compte effectif. Un login AD reussi ne valide pas automatiquement WMI/SMB. Ne pas multiplier les essais.';Route='accounts'},
        [pscustomobject]@{Code='ACCESS_DENIED';Pattern='(?i)(0x80070005|0x80041003|access.*denied|acces.*refus|accès.*refus|unauthorized)';Title='Acces refuse a la ressource';Evidence='Refus d acces signale par une methode ou une ressource.';Next='Verifier le compte de la methode concernee, les droits et la cible. Ne pas conclure automatiquement a un mauvais mot de passe.';Route='accounts'},
        [pscustomobject]@{Code='RPC_UNAVAILABLE';Pattern='(?i)(0x800706ba|\b1722\b|rpc.*(unavailable|indisponible))';Title='Transport RPC indisponible';Evidence='Code ou message RPC indisponible.';Next='Verifier resolution, chemin reseau, services et filtrage RPC. Un ping seul ne valide pas RPC.';Route='computer'},
        [pscustomobject]@{Code='TIMEOUT';Pattern='(?i)(timeout|timed out|delai.*(depass|expir)|délai.*(dépass|expir))';Title='Delai de lecture depasse';Evidence='Le message signale une attente expiree.';Next='Identifier la methode et le temps ecoule. Une absence de reponse ne prouve ni compte invalide ni absence de session.';Route='health'},
        [pscustomobject]@{Code='DNS_NETWORK';Pattern='(?i)(no such host|hote inconnu|hôte inconnu|name.*resolv|network path.*not found|chemin reseau.*introuvable|0x80070035)';Title='Nom ou chemin reseau non resolu';Evidence='Le message mentionne un nom ou chemin introuvable.';Next='Verifier le FQDN et le chemin sur la cible concernee. Ne pas modifier automatiquement DNS ou le pare-feu.';Route='computer'},
        [pscustomobject]@{Code='ENGINE_BUSY';Pattern='(?i)(limite physique|workers.*annulation|execute deja.*tache|exécute déjà.*tâche)';Title='Moteur occupe ou workers en nettoyage';Evidence='Le moteur signale sa limite de concurrence.';Next='Attendre la fin des lectures et consulter Etat moteur. Ne pas augmenter les limites pour masquer une lecture bloquee.';Route='health'},
        [pscustomobject]@{Code='PSEXEC_LICENSE';Pattern='(?i)(SYSINTERNALS SOFTWARE LICENSE|PsExec.*code 1)';Title='Echec de lancement PsExec a examiner';Evidence='Licence PsExec ou code 1 mentionne.';Next='Verifier les arguments, la version executee et la sortie. Le code 1 seul ne permet pas d attribuer la cause a la licence.';Route='computer'}
    )
}

function Get-DomeniaSupportIncidentHints {
    param([AllowEmptyString()][string]$Text)
    if ($null -eq $Text) { $Text='' }
    if ($Text.Length -gt 8192) { $Text=$Text.Substring(0,8192) }
    $found=New-Object Collections.ArrayList
    foreach ($rule in (Get-DomeniaSupportIncidentRules)) {
        if ([regex]::IsMatch($Text,$rule.Pattern,[Text.RegularExpressions.RegexOptions]::None,[timespan]::FromMilliseconds(100))) {
            [void]$found.Add($rule)
        }
    }
    if ($found.Count -eq 0) {
        [void]$found.Add([pscustomobject]@{Code='UNCLASSIFIED';Title='Message non classe';Evidence='Aucune regle locale ne correspond.';Next='Consulter le detail et sa source. Aucune cause automatique proposee.';Route='log'})
    }
    return $found.ToArray()
}

function New-DomeniaSupportIncident {
    param([string]$Text,[string]$Level='WARN',[string]$Area='Application',[datetime]$AtUtc=[datetime]::UtcNow)
    $hints=@(Get-DomeniaSupportIncidentHints -Text $Text)
    [pscustomobject]@{
        Id=[guid]::NewGuid().ToString('N'); AtUtc=$AtUtc.ToUniversalTime().ToString('o'); At=$AtUtc.ToLocalTime().ToString('HH:mm:ss')
        Level=(ConvertTo-DomeniaSupportText $Level 32); Area=(ConvertTo-DomeniaSupportText $Area 64)
        Title=($hints.Title -join ' / '); Codes=($hints.Code -join ', '); Hints=$hints
        # Raw text is for the local detail view only and is never included by the report builder.
        Detail=(ConvertTo-DomeniaSupportText $Text 4096)
    }
}

function Add-DomeniaSupportBoundedItem {
    param([Parameter(Mandatory)][AllowEmptyCollection()][Collections.ArrayList]$Items,[Parameter(Mandatory)]$Item,[ValidateRange(1,1000)][int]$Limit=200)
    [void]$Items.Add($Item)
    if ($Items.Count -gt $Limit) { $Items.RemoveRange(0,$Items.Count-$Limit) }
}

function Test-DomeniaSupportLiteralMatch {
    param([string]$Text,[string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $true }
    if ($null -eq $Text) { return $false }
    return ($Text.IndexOf($Query.Trim(),[StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function New-DomeniaSupportReport {
    [CmdletBinding()]
    param($Snapshot,$Before,$After,$Incident,[datetime]$NowUtc=[datetime]::UtcNow,[string]$Build='DOMENIA 1.0 R1.5')
    $lines=New-Object Collections.Generic.List[string]
    $lines.Add('DOMENIA | DOSSIER SUPPORT')
    $lines.Add('Build : '+(ConvertTo-DomeniaSupportText $Build 128))
    $lines.Add('Genere : '+$NowUtc.ToUniversalTime().ToString('u'))
    $lines.Add('Analyse locale, aucune ecriture AD ni sonde reseau lancee par ce dossier.')
    $lines.Add('Document interne : contient des identifiants et metadonnees du parc. Relire avant partage.')
    if ($null -ne $Snapshot) {
        $lines.Add('');$lines.Add('OBJET OBSERVE')
        $lines.Add('Nom : '+$Snapshot.Name+' | Type : '+$Snapshot.Type)
        $lines.Add('Perimetre : '+$Snapshot.Scope)
        $lines.Add('DN : '+$Snapshot.Dn)
        $lines.Add('Source : '+$Snapshot.Source+' | Lecture/affichage : '+$Snapshot.ObservedAtUtc+' | Capture : '+$Snapshot.CapturedAtUtc)
        $lines.Add('');$lines.Add('CONSTATS ET VERIFICATIONS')
        foreach ($finding in @(Get-DomeniaSupportFindings -Snapshot $Snapshot -NowUtc $NowUtc)) {
            $lines.Add('['+$finding.Level+'] '+$finding.Title+' ('+$finding.Code+')')
            $lines.Add('  Element observe : '+$finding.Evidence)
            $lines.Add('  Suite proposee : '+$finding.Next)
        }
        $lines.Add('');$lines.Add('ATTRIBUTS FOURNIS (LISTE LIMITEE)')
        foreach ($field in (Get-DomeniaSupportFieldNames)) {
            if ($Snapshot.Fields.Contains($field)) { $lines.Add($field+' = '+(Get-DomeniaSupportField $Snapshot $field)+' ['+$Snapshot.Coverage[$field]+']') }
        }
    }
    if ($null -ne $Before -and $null -ne $After) {
        $lines.Add('');$lines.Add('COMPARAISON A / B')
        $same=([string]$Before.Identity -ieq [string]$After.Identity)
        $lines.Add($(if ($same) {'Meme objet : comparaison entre deux captures.'} else {'Objets differents : comparaison de reference, PAS un historique de modification.'}))
        $lines.Add('A : '+$Before.Name+' | '+$Before.CapturedAtUtc+' | source='+$Before.Source)
        $lines.Add('B : '+$After.Name+' | '+$After.CapturedAtUtc+' | source='+$After.Source)
        $diff=@(Compare-DomeniaSupportSnapshots -Before $Before -After $After -DifferencesOnly)
        if ($diff.Count -eq 0) { $lines.Add('Aucune difference sur les attributs fournis et comparables.') }
        foreach ($row in $diff) {
            $lines.Add('['+$row.Status+'] '+$row.Attribute)
            $lines.Add('  A : '+$row.Before);$lines.Add('  B : '+$row.After)
            if ($row.Added) {$lines.Add('  Groupes directs presents seulement en B : '+$row.Added)}
            if ($row.Removed) {$lines.Add('  Groupes directs presents seulement en A : '+$row.Removed)}
        }
        $lines.Add('memberOf : groupes directs fournis uniquement, hors groupe principal, imbrications et droits effectifs.')
        $lines.Add('Un attribut manquant ou partiel reste indetermine, jamais traite comme une suppression certaine.')
    }
    if ($null -ne $Incident) {
        $lines.Add('');$lines.Add('INCIDENT DE SESSION CHOISI MANUELLEMENT')
        $lines.Add('Cet incident n est pas automatiquement attribue a l objet ci-dessus.')
        $lines.Add('Date : '+$Incident.AtUtc+' | Zone : '+$Incident.Area+' | Niveau : '+$Incident.Level)
        foreach ($hint in @($Incident.Hints)) {
            $lines.Add($hint.Code+' : '+$hint.Title)
            $lines.Add('  Indice : '+$hint.Evidence)
            $lines.Add('  Verification : '+$hint.Next)
        }
        $lines.Add('Le message brut et la pile technique ne sont pas exportes.')
    }
    $lines.Add('');$lines.Add('LIMITES')
    $lines.Add('Les regles signalent des indices, pas une cause racine certaine. Aucune reparation automatique.')
    $lines.Add('Pas de mots de passe LAPS, de cles BitLocker ou de credentials exportes par les champs dedies.')
    return [string]::Join([Environment]::NewLine,$lines.ToArray())
}

function ConvertTo-DomeniaSupportHtml {
    param([Parameter(Mandatory)][string]$Report)
    $escaped=[Net.WebUtility]::HtmlEncode($Report)
    return @"
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>DOMENIA | Dossier support</title>
<style>html{color-scheme:light dark}body{font-family:Segoe UI,Arial,sans-serif;max-width:1100px;margin:40px auto;padding:0 24px;background:#f5f7fb;color:#172033}header{border-bottom:4px solid #087fff;padding-bottom:18px;margin-bottom:24px}h1{font-size:28px;margin:0 0 8px}pre{background:#fff;border:1px solid #cbd5e1;border-radius:12px;padding:24px;white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.65 Consolas,monospace}small{color:#475569}@media(prefers-color-scheme:dark){body{background:#0f172a;color:#f8fafc}pre{background:#111827;border-color:#475569}small{color:#cbd5e1}}@media print{body{background:white;color:black;margin:0;max-width:none}pre{background:white;color:black;border:0;padding:0;font-size:10pt}small{color:#333}}</style></head>
<body><header><h1>DOMENIA | Atelier support</h1><small>Document local et autonome. Aucune ressource externe ni script. Usage interne.</small></header><pre>$escaped</pre></body></html>
"@
}
