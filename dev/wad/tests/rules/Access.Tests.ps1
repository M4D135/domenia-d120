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
Test-Case 'D060' 'Politique de transport visible ; intrusif jamais en repli silencieux' {
    $rows=Get-DomeniaTransportPolicy
    Assert-True (@($rows|Where-Object{$_.Transport -eq 'LDAP'}).Count -eq 1);Assert-True ((@($rows|Where-Object{$_.Transport -eq 'CIM / WSMan'})[0].Regle) -match 'jamais')
    Assert-True (@($rows|Where-Object{$_.Intrusif -and $_.Etat -match 'Inactif sans autorisation'}).Count -eq 3)
    Assert-False (Test-DomeniaTransportFallbackAllowed 'PsExec' $true $true $true).Allowed 'Pas pour une lecture, meme avec consentement'
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
