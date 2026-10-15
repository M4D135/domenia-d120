# D051-D060 : comptes, droits et secrets. Aucune valeur secrete reelle : marqueurs factices uniquement.
. (Join-Path $modules 'Domenia-Guard.Model.ps1')
$script:A0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
Test-Case 'D051' 'LAPS, BitLocker, annuaire et postes ont chacun leur contexte' {
    Assert-Equal 'Laps' (Get-DomeniaCredentialScope 'ReadLaps');Assert-Equal 'BitLocker' (Get-DomeniaCredentialScope 'ReadBitLocker')
    Assert-Equal 'Directory' (Get-DomeniaCredentialScope 'GlobalSearch');Assert-Equal 'Remote:pc-01' (Get-DomeniaCredentialScope 'ComputerInventory' 'PC-01')
    Assert-True ((Get-DomeniaCredentialScope 'ComputerInventory' 'PC-01') -cne (Get-DomeniaCredentialScope 'ComputerInventory' 'PC-02'))
}
Test-Case 'D051' 'Changer le compte LAPS ne modifie ni le compte AD ni le compte du poste' {
    $scopes=@{Directory='EX\lecteur';'Remote:pc-01'='EX\support';BitLocker='EX\bl'}
    $after=Set-DomeniaScopeAccount $scopes 'Laps' 'EX\laps-reader'
    Assert-Equal 'EX\lecteur' $after['Directory'];Assert-Equal 'EX\support' $after['Remote:pc-01'];Assert-Equal 'EX\bl' $after['BitLocker'];Assert-Equal 'EX\laps-reader' $after['Laps']
    Assert-False $scopes.ContainsKey('Laps') 'La table d origine n est pas modifiee'
}
Test-Case 'D051' 'Un compte local exige sa cible et ne sert qu a elle' {
    Assert-False (Test-DomeniaCredentialContext 'Remote' '.\admin' '').Valid
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' '.\admin' 'PC-01').Valid
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' 'PC-01\admin' 'PC-01').Valid
    Assert-False (Test-DomeniaCredentialContext 'Remote:pc-02' 'PC-01\admin' 'PC-01').Valid
    Assert-False (Test-DomeniaCredentialContext 'Laps' '.\admin' 'PC-01').Valid
    Assert-True (Test-DomeniaCredentialContext 'Directory' 'EX\lecteur' '').Valid
}
Test-Case 'D052' 'Memes codes, memes decisions en francais et en anglais' {
    $fr=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(5)) 'Lecture' 'LDAP' 'dc1') 'Accès refusé'
    $en=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(5)) 'Lecture' 'LDAP' 'dc1') 'Access is denied'
    Assert-Equal 'AccessDenied' $fr.Category;Assert-Equal $fr.Category $en.Category;Assert-Equal $fr.OfferCredential $en.OfferCredential
    Assert-Equal 'dc1' $fr.Target;Assert-Equal 'LDAP' $fr.Provider;Assert-Equal 5 $fr.NativeCode
}
Test-Case 'D052' 'Un delai depasse n est jamais un mauvais mot de passe' {
    $t=Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'Timeout apres 30s' 'Lecture' 'CIM' 'pc1') 'Timeout apres 30s'
    Assert-Equal 'Timeout' $t.Category;Assert-False $t.OfferCredential;Assert-True $t.Retryable
    $t2=Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'Le délai d attente est dépassé') 'Le délai d attente est dépassé'
    Assert-Equal 'Timeout' $t2.Category
}
Test-Case 'D052' 'Identifiants rejetes, droit refuse, dechiffrement, reseau et prerequis sont distincts' {
    Assert-Equal 'CredentialsRejected' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(1326)))).Category
    Assert-Equal 'AccountState' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(1909)))).Category
    Assert-Equal 'Network' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(1722)))).Category
    Assert-Equal 'DecryptionDenied' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(5))) 'Access denied' 'Dechiffrement LAPS').Category
    Assert-Equal 'Prerequisite' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'Module LAPS absent') 'Module LAPS absent').Category
    Assert-Equal 'Uncertain' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'ETAT INCONNU apres envoi au DC')).Category
}
Test-Case 'D052' 'Constantes hexadecimales longues interpretees sans signe' {
    Assert-Equal 2147942405 ([long]0x80070005L);Assert-Equal 4294967295 ([long]0xffffffffL)
    $d=Get-DomeniaErrorDecision ([pscustomobject]@{Kind='Unknown';NativeCode=0;Code='0x80070005';Provider='p';Phase='x';Target='t'})
    Assert-Equal 'AccessDenied' $d.Category
}
Test-Case 'D053' 'Vingt refus simultanes ne creent qu une demande' {
    $c=New-DomeniaDenialCoalescer 60;$prompts=0
    foreach($i in 1..20){if((Add-DomeniaAccessDenial $c 'Laps' 'AccessDenied' $script:A0.AddMilliseconds($i)).Prompt){$prompts++}}
    Assert-Equal 1 $prompts;Assert-Equal 20 $c.Entries['Laps'].Count
    Assert-True (Add-DomeniaAccessDenial $c 'BitLocker' 'AccessDenied' $script:A0).Prompt 'Une autre ressource a sa propre demande'
}
Test-Case 'D053' 'Annuler conserve le compte precedent ; accepter relance une seule lecture' {
    $c=New-DomeniaDenialCoalescer 60;[void](Add-DomeniaAccessDenial $c 'Laps' 'AccessDenied' $script:A0)
    $cancel=Complete-DomeniaAccessPrompt $c 'Laps' Cancelled $script:A0;Assert-True $cancel.KeepPreviousCredential;Assert-Equal 0 $cancel.RetryReads
    Assert-False (Add-DomeniaAccessDenial $c 'Laps' 'AccessDenied' $script:A0.AddSeconds(10)).Prompt 'Pas de nouvelle demande juste apres une annulation'
    Assert-Equal 1 (Complete-DomeniaAccessPrompt $c 'Laps' Accepted $script:A0).RetryReads
    Assert-False (Get-DomeniaReauthPlan 'AccessDenied' $true).RetryOnce 'Une ecriture n est jamais rejouee';Assert-True (Get-DomeniaReauthPlan 'AccessDenied' $false).RetryOnce
    Assert-False (Get-DomeniaReauthPlan 'Timeout').OfferAccount;Assert-False (Get-DomeniaReauthPlan 'AccessDenied').PasswordCascade
    Assert-False (Add-DomeniaAccessDenial (New-DomeniaDenialCoalescer) 'Remote:pc1' 'AccessDenied' $script:A0 $true).Prompt 'Un refus de fond n interrompt pas'
}
Test-Case 'D054' 'Usage unique, inactivite glissante et oubli' {
    $one=New-DomeniaCredentialLease 'Laps' 'EX\x' OneShot 30 7 $script:A0
    Assert-True (Test-DomeniaCredentialLease $one 7 $script:A0).Usable;[void](Use-DomeniaCredentialLease $one $script:A0);Assert-False (Test-DomeniaCredentialLease $one 7 $script:A0).Usable
    $idle=New-DomeniaCredentialLease 'Directory' 'EX\x' Inactivity 30 7 $script:A0
    [void](Use-DomeniaCredentialLease $idle $script:A0.AddMinutes(25))
    Assert-True (Test-DomeniaCredentialLease $idle 7 $script:A0.AddMinutes(50)).Usable 'Le delai repart de la derniere utilisation'
    Assert-False (Test-DomeniaCredentialLease $idle 7 $script:A0.AddMinutes(56)).Usable
    [void](Clear-DomeniaCredentialLease $idle);Assert-False (Test-DomeniaCredentialLease $idle 7 $script:A0).Usable
}
Test-Case 'D054' 'Un worker d une ancienne session ne reutilise pas le compte ; une ecriture envoyee n est pas tuee' {
    $l=New-DomeniaCredentialLease 'Directory' 'EX\x' Session 30 7 $script:A0
    $old=Test-DomeniaCredentialLease $l 8 $script:A0;Assert-False $old.Usable;Assert-True $old.KeepsInFlight
    Assert-True (Test-DomeniaCredentialLease $l 7 $script:A0.AddHours(5)).Usable
}
Test-Case 'D055' 'Lire AD utilise le jeton Windows courant sans double saisie' {
    $n=Get-DomeniaOperationAuthNeed 'GlobalSearch' $true $false;Assert-Equal 'Integrated' $n.Mode;Assert-False $n.Prompt
    $refused=Get-DomeniaOperationAuthNeed 'ReadLaps' $true $true;Assert-Equal 'AskAccount' $refused.Mode;Assert-True $refused.Prompt
    Assert-Equal 'Alternate' (Get-DomeniaOperationAuthNeed 'ReadLaps' $true $true $true).Mode
}
Test-Case 'D056' 'Un bouton grise a un motif et une route ; une ACL estimee n est pas un droit definitif' {
    $e=Get-DomeniaCapabilityExplanation 'Reinitialiser le mot de passe' Estimated
    Assert-False $e.Definitive;Assert-True ($e.Text -match 'Estime')
    $r=Get-DomeniaCapabilityExplanation 'Lire LAPS' Refused;Assert-Equal 'TabAccounts' $r.Route
    Assert-Equal 'WsSearch' (Get-DomeniaCapabilityExplanation 'Ouvrir la fiche' NoSelection).Route
    Assert-True (Get-DomeniaCapabilityExplanation 'Deplacer' Tested).Definitive
}
Test-Case 'D057' 'Dechiffrement refuse : ni mot de passe vide ni panne globale du compte' {
    $v=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='WindowsLaps';Published=$true;ReadStatus='OK';DecryptStatus='Unauthorized';PasswordPresent=$false;Reader='EX\lecteur';ExpirationUtc=$script:A0.AddDays(5)}) $script:A0
    Assert-Equal 'DecryptDenied' $v.State;Assert-False $v.HasPassword;Assert-True $v.OfferOtherAccount;Assert-False $v.BlocksBitLocker;Assert-False $v.BlocksDirectoryAccount
    Assert-True ($v.Message -match 'publie') 'Le message dit que le mot de passe existe'
    Assert-True (@($v.Facts|Where-Object{$_.Fait -eq 'Dechiffrement' -and $_.Etat -eq 'Refuse'}).Count -eq 1)
}
Test-Case 'D057' 'Lecture refusee, non publie, prerequis et disponible restent distincts' {
    Assert-Equal 'ReadDenied' (ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='AccessDenied'})).State
    Assert-Equal 'NotPublished' (ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='OK';Published=$false})).State
    Assert-Equal 'Prerequisite' (ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='ModuleMissing'})).State
    $ok=ConvertTo-DomeniaLapsView ([pscustomobject]@{Source='LegacyLaps';ReadStatus='OK';Published=$true;DecryptStatus='NotEncrypted';PasswordPresent=$true});Assert-True ($ok.HasPassword -and $ok.CanReveal)
    Assert-True (@($ok.Facts|Where-Object{$_.Valeur -match 'SECRET'}).Count -eq 0)
}
Test-Case 'D058' 'Recherche par identifiant de recuperation, metadonnees sans cle' {
    $keys=@(ConvertTo-DomeniaBitLockerKeyList @([pscustomobject]@{Name='2025-03-01T10:22:33-00:00{A1B2C3D4-1111-2222-3333-444455556666}';DN='CN=k1';RecoveryPassword='MARQUEUR-SECRET'},[pscustomobject]@{Name='2025-06-01T08:00:00-00:00{A1B2FFFF-1111-2222-3333-444455556666}';DN='CN=k2'},[pscustomobject]@{Name='invalide';DN='CN=k3'}))
    Assert-Equal 2 $keys.Count;Assert-Equal 'A1B2C3D4' $keys[0].RecoveryId
    Assert-False ((($keys|ConvertTo-Json -Depth 4)) -match 'MARQUEUR-SECRET') 'La liste ne transporte aucune cle'
    $one=Find-DomeniaBitLockerKey $keys 'a1b2c3d4';Assert-True $one.Unique;Assert-Equal 'CN=k1' $one.Matches[0].DN
    $two=Find-DomeniaBitLockerKey $keys 'A1B2';Assert-False $two.Unique;Assert-Equal 2 $two.Matches.Count
    Assert-False (Find-DomeniaBitLockerKey $keys 'A1').Unique
}
Test-Case 'D058' 'Ouvrir l onglet ne revele aucune cle' {
    Assert-False (Test-DomeniaSecretRevealAllowed 'TabOpened');Assert-False (Test-DomeniaSecretRevealAllowed 'Selection');Assert-True (Test-DomeniaSecretRevealAllowed 'ExplicitReveal' 1)
    Assert-False (Test-DomeniaSecretRevealAllowed 'ExplicitReveal' 3) 'Une seule cle a la fois'
}
Test-Case 'D059' 'Les marqueurs secrets factices sont masques avant journalisation ou export' {
    $marker='SECRET_SENTINEL_D059'
    foreach($text in @(('psexec \\pc -u adm -p '+$marker+' cmd'),('schtasks /create /rp '+$marker),('password='+$marker),('{"n":"adm","t":"1d","p":"'+$marker+'"}'),('Mot de passe : '+$marker))){
        Assert-False (Test-DomeniaTextHasSecret (Protect-DomeniaSecretText $text) @($marker)) ('Fuite dans : '+$text)
    }
    Assert-True ((Protect-DomeniaSecretText 'cle 111111-222222-333333-444444-555555-666666-777777-888888 fin') -match 'masquee')
    Assert-Equal 'texte sans secret' (Protect-DomeniaSecretText 'texte sans secret')
}
Test-Case 'D059' 'Export par liste blanche : un champ non nomme ne sort pas' {
    $o=Select-DomeniaAllowedFields ([pscustomobject]@{Operation='ReadLaps';Target='pc1';Payload='SECRET_SENTINEL_D059';Detail='password=SECRET_SENTINEL_D059'}) @('Operation','Target','Detail')
    Assert-False (($o|ConvertTo-Json) -match 'SECRET_SENTINEL_D059')
    $p=Get-DomeniaSecretExposurePolicy;Assert-False ($p.InLogs -or $p.InCache -or $p.InSnapshots -or $p.InProcessArguments -or $p.InAutomaticExports);Assert-True ($p.ClipboardLimit.Length -gt 20)
}
Test-Case 'D051' 'Meme poste en nom court et en FQDN ; adresse IP conservee entiere' {
    Assert-Equal 'Remote:pc-01' (Get-DomeniaCredentialScope 'ComputerInventory' 'pc-01.example.local');Assert-Equal 'Remote:pc-01' (Get-DomeniaCredentialScope 'LiveConsole' 'PC-01')
    Assert-Equal 'Remote:10.1.2.3' (Get-DomeniaCredentialScope 'ComputerInventory' '10.1.2.3')
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' 'PC-01\admin' 'pc-01.example.local').Valid
    Assert-Equal 'BitLocker' (Get-DomeniaOperationResource 'ReadBitLockerList');Assert-Equal 'BitLocker' (Get-DomeniaOperationResource 'ReadBitLockerKey')
}
Test-Case 'D051' 'Compte d un autre poste refuse avant tout appel quand le domaine est connu' {
    Assert-False (Test-DomeniaCredentialContext 'Remote:pc-01' 'PC-02\admin' 'PC-01' @('EX','ex.local')).Valid
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' 'EX\support' 'PC-01' @('EX','ex.local')).Valid
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' 'support@ex.local' 'PC-01' @('EX','ex.local')).Valid
    Assert-True (Test-DomeniaCredentialContext 'Remote:pc-01' 'PC-02\admin' 'PC-01').Valid 'Sans domaine connu, aucune deduction'
    Assert-True (Test-DomeniaCredentialContext 'Laps' 'EX\laps' 'PC-01' @('EX')).Valid
}
Test-Case 'D052' 'Module LAPS absent et delai pendant le dechiffrement ne sont pas des refus de dechiffrement' {
    $module='Module Windows LAPS absent. Aucun decryptage possible. Le changement de compte ne remplace pas ce module.'
    $m=Get-DomeniaErrorDecision (Get-DomeniaStructuredError $module) $module;Assert-Equal 'Prerequisite' $m.Category;Assert-False $m.OfferCredential
    $t=Get-DomeniaErrorDecision (Get-DomeniaStructuredError 'Timeout pendant le dechiffrement') 'Timeout pendant le dechiffrement';Assert-Equal 'Timeout' $t.Category
    $d='Le compte ne dispose pas du droit de dechiffrement LAPS.'
    $x=Get-DomeniaErrorDecision (Get-DomeniaStructuredError $d) $d;Assert-Equal 'DecryptionDenied' $x.Category;Assert-True $x.OfferCredential
}
Test-Case 'D052' 'Identifiants rejetes par texte seul, en francais et en anglais' {
    foreach($text in @('The user name or password is incorrect.','Le nom d utilisateur ou le mot de passe est incorrect.')){
        Assert-Equal 'LogonFailure' (Get-DomeniaStructuredError $text).Kind $text
        Assert-Equal 'CredentialsRejected' (Get-DomeniaErrorDecision ([pscustomobject]@{Kind='Unknown';NativeCode=0;Code='0x00000000'}) $text).Category $text
    }
}
Test-Case 'D052' 'Code natif transporte meme enveloppe par EndInvoke' {
    $wrapped='Exception lors de l appel de EndInvoke : "[DOMENIA:AccountLocked;1909;0x80070775] Le compte est verrouille."'
    $s=Get-DomeniaStructuredError $wrapped;Assert-Equal 'AccountLocked' $s.Kind;Assert-Equal 1909 $s.NativeCode;Assert-False $s.CanOfferCredential
    $inner=[InvalidOperationException]::new('[DOMENIA:LogonFailure;1326;0x8007052E] refus',[Exception]::new('detail sans code'))
    Assert-Equal 'LogonFailure' (Get-DomeniaStructuredError $inner).Kind 'Le marqueur reste lu quand une exception interne suit'
}
Test-Case 'D053' 'Valeur absente non confirmee propose un compte et une seule relecture' {
    $p=Get-DomeniaReauthPlan 'Unconfirmed';Assert-True $p.OfferAccount;Assert-True $p.RetryOnce
    Assert-False (Get-DomeniaReauthPlan 'Unconfirmed' $true).RetryOnce
    Assert-Equal 'Unconfirmed' (Get-DomeniaErrorDecision ([pscustomobject]@{Kind='Unconfirmed';NativeCode=0;Code='0x00000000'}) 'aucune valeur').Category
}
Test-Case 'D055' 'Un compte alternatif rejete ne redevient pas utilisable' {
    $n=Get-DomeniaOperationAuthNeed 'ReadLaps' $true $true $true $true;Assert-Equal 'AskAccount' $n.Mode;Assert-True $n.Prompt
    Assert-Equal 'Alternate' (Get-DomeniaOperationAuthNeed 'ReadLaps' $true $false $true $false).Mode
}
Test-Case 'D057' 'Rien de lisible : ni verdict ni refus invente' {
    $v=ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='Unconfirmed';Reader='EX\lecteur'})
    Assert-Equal 'Unconfirmed' $v.State;Assert-True $v.OfferOtherAccount;Assert-False $v.HasPassword
    Assert-True (@($v.Facts|Where-Object{$_.Etat -eq 'Inconnu'}).Count -eq 1);Assert-False ($v.Message -match 'Aucun mot de passe LAPS publie')
    Assert-Equal 'Unknown' (ConvertTo-DomeniaLapsView ([pscustomobject]@{ReadStatus='Failed'})).State
}
Test-Case 'D058' 'Identifiant de recuperation lu sur msFVE-RecoveryGuid et cle enfant direct du poste' {
    $g=[guid]'a1b2c3d4-1111-2222-3333-444455556666'
    $keys=@(ConvertTo-DomeniaBitLockerKeyList @([pscustomobject]@{Name='sans-guid';DN='CN=k,CN=PC1,DC=ex';RecoveryGuid=$g.ToByteArray()}))
    Assert-Equal 1 $keys.Count;Assert-Equal 'A1B2C3D4' $keys[0].RecoveryId
    Assert-True (Test-DomeniaDirectChildDn 'CN=PC1,OU=P,DC=ex' 'CN=2025-03-01T10:22:33-00:00{A1B2C3D4-1111-2222-3333-444455556666},CN=PC1,OU=P,DC=ex')
    Assert-False (Test-DomeniaDirectChildDn 'CN=PC1,OU=P,DC=ex' 'CN=k,CN=X,CN=PC1,OU=P,DC=ex') 'Petit-enfant refuse'
    Assert-False (Test-DomeniaDirectChildDn 'CN=PC1,OU=P,DC=ex' 'CN=k,CN=PC2,OU=P,DC=ex') 'Autre poste refuse'
    Assert-True (Test-DomeniaDirectChildDn 'CN=PC1,DC=ex' 'CN=a\,b,CN=PC1,DC=ex') 'Virgule echappee acceptee'
}
Test-Case 'D059' 'Le masquage des regles couvre toutes les formes du journal' {
    $m='SECRET_SENTINEL_D059'
    foreach($text in @(('/p '+$m),('-p:'+$m),('{"password":"'+$m+'"}'),('Bearer '+$m),('client_secret='+$m),('api-key='+$m),('secret='+$m),('motdepasse='+$m),('cmd -pass '+$m),('cmd /password '+$m),('pwd: '+$m),('token='+$m),('/rp '+$m),('-p '+$m))){
        Assert-False (Test-DomeniaTextHasSecret (Protect-DomeniaSecretText $text) @($m)) ('Fuite dans : '+$text)
    }
}
Test-Case 'D060' 'Politique de transport visible ; intrusif jamais en repli silencieux' {
    $rows=Get-DomeniaTransportPolicy
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'LDAP'}).Count -eq 1);Assert-True ((@($rows|Where-Object{$_.Transport -eq 'CIM / WSMan'})[0].Regle) -match 'jamais')
    Assert-True (@($rows|Where-Object{$_.Intrusif -and $_.Etat -match 'Inactif sans autorisation'}).Count -eq 3)
    Assert-False (Test-DomeniaTransportFallbackAllowed 'PsExec' $true $true $true).Allowed 'Pas pour une lecture, meme avec consentement'
    Assert-True (Test-DomeniaTransportFallbackAllowed -Transport 'PsExec' -Intrusive $true -IsRead $true -ReadConsentGiven $true).Allowed 'La demande propre a la lecture ne debloque rien'
    Assert-False (Test-DomeniaTransportFallbackAllowed -Transport 'PsExec' -Intrusive $true -ConsentGiven $true -IsRead $true).Allowed 'Le consentement d intervention debloque encore une lecture'
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'Partage ADMIN$' -and $_.Regle -match 'repli aux lectures'}).Count -eq 0) 'La politique affichee promet encore un repli pour les lectures'
    Assert-False (Test-DomeniaTransportFallbackAllowed 'PsExec' $true $false $false).Allowed;Assert-True (Test-DomeniaTransportFallbackAllowed 'PsExec' $true $true $false).Allowed
}
Test-Case 'D060' 'Aucun affaiblissement de Windows dans le code livre' {
    Assert-False (Test-DomeniaTransportCodeSafety '[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }').Safe
    Assert-False (Test-DomeniaTransportCodeSafety 'Enable-PSRemoting -Force').Safe;Assert-False (Test-DomeniaTransportCodeSafety 'Set-MpPreference -DisableRealtimeMonitoring $true').Safe
    $root=Split-Path -Parent $wad
    foreach($file in @(Get-ChildItem -LiteralPath $wad -Recurse -File -Include '*.ps1' | Where-Object{$_.FullName -notmatch '[\\/](tests|docs)[\\/]' -and $_.Name -ne 'Domenia-Access.Model.ps1'})){
        $check=Test-DomeniaTransportCodeSafety ([IO.File]::ReadAllText($file.FullName))
        Assert-True $check.Safe ($file.Name+' : '+($check.Findings -join ', '))
    }
}

Test-Case 'P127' 'Pannes reseau : resolution, refus, coupure et appel RPC interrompu restent des pannes reseau' {
    foreach($native in @(11001,11002,11003,11004,10051,10053,10054,10060,10061,10064,10065)){
        $d=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([Net.Sockets.SocketException]::new($native)) 'Lecture' 'CIM' 'pc1')
        Assert-Equal 'Network' $d.Category ('Code socket '+$native)
        Assert-False $d.OfferCredential ('Autre compte propose pour le code '+$native)
        Assert-True $d.Retryable ('Relecture refusee pour le code '+$native)
    }
    foreach($hresult in @(-2147023170,-2147023169)){
        $rpc=Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([Runtime.InteropServices.COMException]::new('Appel de procedure distante interrompu (fixture).',$hresult)))
        Assert-Equal 'Network' $rpc.Category ('Appel RPC coupe '+$hresult);Assert-False $rpc.OfferCredential
    }
    Assert-Equal 'Network' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([ComponentModel.Win32Exception]::new(1726)))).Category
    Assert-Equal 'AccessDenied' (Get-DomeniaErrorDecision (Get-DomeniaStructuredError ([UnauthorizedAccessException]::new('Acces refuse (fixture).')))).Category 'Un refus d acces reste un refus'
}
