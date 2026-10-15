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
# Point 46 : droit requis par operation et trois causes distinctes (refus d acces, compte rejete, ressource indisponible).
$script:P46Pinned=@('BatchNetworkDiag','BitLockerPresence','CmdletHelp','CmdletInventory','ComputerAdminShare','ComputerDiagnostics','ComputerGpUpdate','ComputerInventory','ComputerLastUser','ComputerPing','ComputerRestart','DemoDirectory','DocumentStore','DomainOverview','EmbeddedDirectoryLookup','EmbeddedPathBrowse','EngineSelfTest','GlobalSearch','IndexBuild','IndexOuList','IsolatedRead','LegacyMigration','LiveCache','LiveConsole','LiveDirectoryCheck','LiveSelectedPing','LocalIndexRead','LocalQuery','LocalStore','LockoutDiagnosis','LogonHarvest','OpenAdObject','OpenLinkedObject','ParkSharedSync','ParkSweep','PermissionAnalysis','PresenceScan','PruneLinks','QueryExport','QueryLibrary','ReadBitLocker','ReadBitLockerKey','ReadBitLockerList','ReadLaps','ReceiptStore','RemoteCredentialCheck','RimotteRun','ScopeReconcile','SelectedPresence','SelfCheck','SessionsList','SoftwareInventory','StartupWarmCache','StorageBackup','StorageMaintenance','StoragePurge','StorageUsage','TreeChildren','UserComputerProbe','WmiClasses','WmiNamespaces','WmiQuery','WriteAccountDisabled','WriteAccountOptions','WriteAttributes','WriteCreateOu','WriteDeleteObject','WriteExpiration','WriteExpirePassword','WriteGroupMember','WriteMoveObject','WriteObjectGroup','WriteRenameComputer','WriteResetPassword','WriteUnlock','AccountAliasRead')
Test-Case 'P46' 'Chaque operation epinglee annonce son compte, son droit et son acces reseau' {
    foreach($op in $script:P46Pinned){
        $r=Get-DomeniaOperationRequirement $op
        Assert-True ([bool]$r.Known) ('Droit non documente : '+$op)
        Assert-True (([string]$r.Right).Length -gt 20) ('Droit trop vague : '+$op)
        Assert-True ([bool]([string]$r.Account)) ('Compte absent : '+$op)
        Assert-True ([bool]([string]$r.Access)) ('Acces reseau absent : '+$op)
    }
    Assert-Equal 'Laps' (Get-DomeniaOperationRequirement 'ReadLaps').Resource
    Assert-True ((Get-DomeniaOperationRequirement 'LockoutDiagnosis').Right -match 'Lecteurs des journaux')
    Assert-True ((Get-DomeniaOperationRequirement 'WriteResetPassword').Right -match 'Réinitialiser le mot de passe')
    Assert-Equal 'Aucun compte' (Get-DomeniaOperationRequirement 'ComputerPing').Account
    # A network diagnostic sends no account: it is never described with the rights of a WMI read.
    $batch=Get-DomeniaOperationRequirement 'BatchNetworkDiag';Assert-Equal 'Aucun compte' $batch.Account;Assert-True ($batch.Access -match '5985') $batch.Access
}
Test-Case 'P46' 'Une operation inconnue ne recoit jamais un droit devine' {
    foreach($op in @('OperationInventee','')){
        $r=Get-DomeniaOperationRequirement $op
        Assert-False ([bool]$r.Known) ('Droit devine pour <'+$op+'>')
        Assert-True ($r.Right -match 'non documenté')
        Assert-Equal '' $r.Account
    }
}
Test-Case 'P46' 'Refus d acces, compte rejete et indisponibilite reseau ne se confondent jamais' {
    $denied=Get-DomeniaOperationFailureGuidance 'ReadLaps' 'AccessDenied'
    $rejected=Get-DomeniaOperationFailureGuidance 'ReadLaps' 'CredentialsRejected'
    $locked=Get-DomeniaOperationFailureGuidance 'ReadLaps' 'AccountState'
    $network=Get-DomeniaOperationFailureGuidance 'ReadLaps' 'Network'
    $timeout=Get-DomeniaOperationFailureGuidance 'ComputerInventory' 'Timeout'
    Assert-Equal 'AccessDenied' $denied.Family;Assert-Equal 'AccountRejected' $rejected.Family;Assert-Equal 'AccountRejected' $locked.Family
    Assert-Equal 'Unavailable' $network.Family;Assert-Equal 'Unavailable' $timeout.Family
    Assert-True ($denied.Text -match 'Droit requis') 'Un refus cite le droit requis'
    Assert-False ($rejected.Text -match 'Droit requis') 'Un compte rejete ne suggere pas un droit manquant'
    Assert-True ($rejected.Text -match 'Compte secrets') 'Un compte rejete nomme le compte de la ressource'
    Assert-False ($network.Text -match 'Droit requis') 'Une indisponibilite ne suggere pas un droit manquant'
    Assert-True ($network.Text -match '389/TCP') 'Une indisponibilite cite l acces reseau necessaire'
    Assert-True ($timeout.Text -match '135/TCP')
    Assert-Equal 'AccessDenied' (Get-DomeniaOperationFailureGuidance 'ReadLaps' 'DecryptionDenied').Family
}
Test-Case 'P46' 'La famille vient du code natif, en francais comme en anglais' {
    $family={param($e,$t) (Get-DomeniaFailureFamily ((Get-DomeniaErrorDecision (Get-DomeniaStructuredError $e) $t).Category)).Family}
    Assert-Equal 'AccessDenied' (& $family ([ComponentModel.Win32Exception]::new(5)) 'Accès refusé')
    Assert-Equal 'AccessDenied' (& $family ([ComponentModel.Win32Exception]::new(5)) 'Access is denied')
    Assert-Equal 'AccountRejected' (& $family ([ComponentModel.Win32Exception]::new(1326)) 'Nom d utilisateur ou mot de passe incorrect')
    Assert-Equal 'AccountRejected' (& $family 'LDAP error 49 data 775' '')
    Assert-Equal 'Unavailable' (& $family ([ComponentModel.Win32Exception]::new(1722)) 'Le serveur RPC n est pas disponible')
}
Test-Case 'P46' 'Une erreur non classee ou sans operation n invente aucune cause' {
    Assert-Equal '' (Get-DomeniaOperationFailureGuidance 'GlobalSearch' 'Unknown').Text
    Assert-Equal '' (Get-DomeniaOperationFailureGuidance 'GlobalSearch' 'Uncertain').Text
    $g=Get-DomeniaOperationFailureGuidance '' 'AccessDenied'
    Assert-Equal 'AccessDenied' $g.Family;Assert-False ($g.Text -match 'Droit requis') 'Sans operation connue, aucun droit n est cite'
}
# Points 44 et 45 : correction d un compte sans reconnexion, alias rapproches par SID. Contextes complets (mode strict).
$script:P45Guard={[hashtable]::Synchronized(@{Epoch=1L;Faults=@{};Revision=0L;NotifiedRevision=0L})}
$script:P45Context={param($Guard,[string]$Directory='',[string]$Remote='',[long]$Generation=0,[string]$Operation='GlobalSearch')
    [pscustomobject]@{CredentialGuard=$Guard;DirectoryAuthKey=$Directory;RemoteAuthKey=$Remote;RemoteAdminAuthKey=$Remote;ActiveRemoteAuthKey=$Remote;LastAuthChannel='';OperationId=$Operation;CredentialGeneration=$Generation}}
Test-Case 'P45' 'Formes de nom recherchees : domaine\compte, UPN, nom nu ; compte local et autre domaine exclus' {
    $l=ConvertTo-DomeniaAccountLookup 'CORP\jdupont' 'corp.example' 'CORP';Assert-True $l.Valid;Assert-Equal 'jdupont' $l.Sam;Assert-Equal '' $l.Upn
    $l=ConvertTo-DomeniaAccountLookup 'jean.dupont@corp.example.com' 'corp.example' 'CORP';Assert-True $l.Valid;Assert-Equal '' $l.Sam;Assert-Equal 'jean.dupont@corp.example.com' $l.Upn
    $l=ConvertTo-DomeniaAccountLookup 'jdupont@corp.example' 'corp.example' 'CORP';Assert-Equal 'jdupont' $l.Sam;Assert-Equal 'jdupont@corp.example' $l.Upn
    $l=ConvertTo-DomeniaAccountLookup 'jdupont' 'corp.example' 'CORP';Assert-True $l.Valid;Assert-Equal 'jdupont' $l.Sam
    foreach($bad in @('.\admin','PC-01\admin','OTHER\jdupont','','a*b','x(y)','CORP\a\b')){Assert-False (ConvertTo-DomeniaAccountLookup $bad 'corp.example' 'CORP').Valid ('Forme acceptee : '+$bad)}
}
Test-Case 'P45' 'Cles des noms confirmes : DOMAINE\compte et UPN, sans doublon' {
    $k=@(Get-DomeniaCredentialAliasKeys -Sam 'jdupont' -Upn 'Jean.Dupont@corp.example.com' -Domain 'corp.example' -Netbios 'CORP' -Also @('CORP\JDupont'))
    Assert-Equal 2 $k.Count;Assert-True ($k -contains 'jdupont@corp.example');Assert-True ($k -contains 'jean.dupont@corp.example.com')
}
Test-Case 'P45' 'Un refus sous un nom suspend ses alias confirmes sans nouvel essai, jamais un autre compte' {
    $g=& $script:P45Guard
    Assert-True (Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('jdupont@corp.example','jean.dupont@corp.example.com')).Registered
    Assert-True (Register-WCredentialFailure (& $script:P45Context $g 'jdupont@corp.example') ([ComponentModel.Win32Exception]::new(1326)) Directory)
    Assert-True $g.Faults.ContainsKey('jean.dupont@corp.example.com') 'Alias non suspendu'
    $alias=& $script:P45Context $g '' 'jean.dupont@corp.example.com'
    Assert-Throws {Assert-WCredentialAllowed $alias Remote} 'L alias peut encore envoyer le compte refuse'
    Assert-WCredentialAllowed (& $script:P45Context $g 'reader@corp.example') Directory
}
Test-Case 'P45' 'Une pause deja enregistree couvre les alias confirmes ensuite et retire leurs lectures en file' {
    $g=& $script:P45Guard
    [void](Register-WCredentialFailure (& $script:P45Context $g 'jdupont@corp.example') 'data 52e' Directory)
    $revision=[long]$g.Revision
    $r=Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('jdupont@corp.example','jean.dupont@corp.example.com')
    Assert-Equal 1 ([int]$r.Propagated);Assert-True ([long]$g.Revision -gt $revision) 'Revision inchangee : lectures en file non retirees'
    Assert-True $g.Faults.ContainsKey('jean.dupont@corp.example.com')
}
Test-Case 'P45' 'Un nom lie a un autre SID n est jamais deplace ; SID local refuse' {
    $g=& $script:P45Guard
    [void](Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('a@corp.example','b@corp.example'))
    $r=Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1105' @('b@corp.example','c@corp.example')
    Assert-Equal 'b@corp.example' (@($r.Conflicts) -join ',');Assert-Equal 'sid:S-1-5-21-1-2-3-1104' ([string]$g.Aliases['b@corp.example'])
    Assert-False (Register-DomeniaCredentialAliases $g 'S-1-5-32-544' @('x@corp.example')).Registered
    Assert-False (Register-DomeniaCredentialAliases $null 'S-1-5-21-1-2-3-1104' @('x@corp.example')).Registered
}
Test-Case 'P45' 'Les alias partagent un verrou ; leur refus sans provenance reste attribue' {
    $g=& $script:P45Guard
    [void](Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('jdupont@corp.example','jean.dupont@corp.example.com'))
    $c=& $script:P45Context $g 'jdupont@corp.example' 'jean.dupont@corp.example.com'
    $lease=Enter-WCredentialAttempt $c All
    try{Assert-Equal 1 @($lease.Locks).Count}finally{Exit-WCredentialAttempt $lease}
    [void](Register-WCredentialFailure $c ([ComponentModel.Win32Exception]::new(1326)))
    Assert-False (($g.ContainsKey('AmbiguousOperations')) -and ($g.AmbiguousOperations.Count -gt 0)) 'Refus entre alias declare ambigu'
    Assert-True $g.Faults.ContainsKey('jdupont@corp.example')
}
Test-Case 'P44' 'Corriger un compte leve sa seule pause et celle de ses alias, jamais une operation non attribuee' {
    $g=& $script:P45Guard
    [void](Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('jdupont@corp.example','jean.dupont@corp.example.com'))
    foreach($k in @('jdupont@corp.example','other@corp.example')){[void](Register-WCredentialFailure (& $script:P45Context $g $k) 'data 52e' Directory)}
    $g.AmbiguousOperations=@{Mixed=[pscustomobject]@{Kind='LogonFailure';Code='0x00000000';AtUtc=$script:A0}}
    $removed=@(Clear-DomeniaCredentialGuardFault $g @('JDupont@corp.example') 5)
    Assert-Equal 2 $removed.Count
    Assert-False $g.Faults.ContainsKey('jean.dupont@corp.example.com');Assert-True $g.Faults.ContainsKey('other@corp.example') 'Un autre compte libere'
    Assert-True $g.AmbiguousOperations.ContainsKey('Mixed') 'Operation non attribuee liberee'
    Assert-Equal 5 ([long]$g.Released['jean.dupont@corp.example.com'])
    Assert-Equal 'AtUtc,Key,Kind' ((@($removed[0].PSObject.Properties.Name)|Sort-Object) -join ',')
}
Test-Case 'P44' 'Une operation partie avant la correction ne renvoie plus l ancien mot de passe et son refus ne suspend rien' {
    $g=& $script:P45Guard
    [void](Clear-DomeniaCredentialGuardFault $g @('jdupont@corp.example') 7)
    $old=& $script:P45Context $g 'jdupont@corp.example' '' 6
    $new=& $script:P45Context $g 'jdupont@corp.example' '' 7
    Assert-Throws {Assert-WCredentialAllowed $old Directory} 'Ancien mot de passe encore envoye'
    Assert-WCredentialAllowed $new Directory
    Assert-True (Register-WCredentialFailure $old ([ComponentModel.Win32Exception]::new(1326)) Directory) 'Le refus reste un echec pour l operation'
    Assert-False $g.Faults.ContainsKey('jdupont@corp.example') 'Refus de l ancien mot de passe enregistre'
    Assert-True (Register-WCredentialFailure $new ([ComponentModel.Win32Exception]::new(1326)) Directory)
    Assert-True $g.Faults.ContainsKey('jdupont@corp.example') 'Refus du compte valide ignore'
}
Test-Case 'P45' 'Une validation posterieure au refus d un alias l emporte ; un refus posterieur reprend la pause' {
    $g=& $script:P45Guard
    [void](Register-WCredentialFailure (& $script:P45Context $g 'jdupont@corp.example' '' 3) 'data 52e' Directory)
    [void](Clear-DomeniaCredentialGuardFault $g @('jean.dupont@corp.example.com') 5)
    $r=Register-DomeniaCredentialAliases $g 'S-1-5-21-1-2-3-1104' @('jdupont@corp.example','jean.dupont@corp.example.com')
    Assert-Equal 0 ([int]$r.Propagated) 'Refus anterieur a la validation propage'
    Assert-WCredentialAllowed (& $script:P45Context $g '' 'jean.dupont@corp.example.com' 5) Remote
    Assert-Throws {Assert-WCredentialAllowed (& $script:P45Context $g 'jdupont@corp.example' '' 4) Directory} 'Une operation partie avant la validation reste autorisee'
    [void](Register-WCredentialFailure (& $script:P45Context $g 'jdupont@corp.example' '' 6) 'data 52e' Directory)
    Assert-Throws {Assert-WCredentialAllowed (& $script:P45Context $g '' 'jean.dupont@corp.example.com' 6) Remote} 'Un refus posterieur a la validation ne suspend pas l alias'
}
Test-Case 'P44' 'Une ecriture partie avant la correction garde son compte jusqu a sa fin, sans renvoyer un mot de passe refuse depuis' {
    $g=& $script:P45Guard
    [void](Clear-DomeniaCredentialGuardFault $g @('jdupont@corp.example') 7)
    $write=& $script:P45Context $g '' 'jdupont@corp.example' 6 'RimotteRun'
    $write|Add-Member -NotePropertyName CredentialWrite -NotePropertyValue $true
    # Its next step (the removal of its own scheduled task, say) still takes the lease of its account.
    $lease=Enter-WCredentialAttempt $write Remote 1
    Exit-WCredentialAttempt $lease
    Assert-Throws {Assert-WCredentialAllowed (& $script:P45Context $g '' 'jdupont@corp.example' 6 'ComputerInventory') Remote} 'Une lecture partie avant la correction renvoie l ancien mot de passe'
    Assert-True (Register-WCredentialFailure $write ([ComponentModel.Win32Exception]::new(1326)) Remote) 'Le refus reste un echec pour l ecriture'
    Assert-False $g.Faults.ContainsKey('jdupont@corp.example') 'Le refus de l ancien mot de passe suspend le compte corrige'
    Assert-Throws {Assert-WCredentialAllowed $write Remote} 'L ecriture renvoie un mot de passe refuse depuis la correction'
    Assert-WCredentialAllowed (& $script:P45Context $g '' 'jdupont@corp.example' 7 'ComputerInventory') Remote
    # A write refused before the correction recorded the pause itself; once the account is released, it still never
    # sends the password refused to it.
    $g2=& $script:P45Guard
    $early=& $script:P45Context $g2 '' 'jdupont@corp.example' 6 'RimotteRun'
    $early|Add-Member -NotePropertyName CredentialWrite -NotePropertyValue $true
    Assert-True (Register-WCredentialFailure $early ([ComponentModel.Win32Exception]::new(1326)) Remote)
    Assert-True $g2.Faults.ContainsKey('jdupont@corp.example') 'Refus de l ecriture non enregistre'
    [void](Clear-DomeniaCredentialGuardFault $g2 @('jdupont@corp.example') 7)
    Assert-Throws {Assert-WCredentialAllowed $early Remote} 'L ecriture renvoie le mot de passe qui lui a ete refuse'
    Assert-Equal 'jdupont@corp.example' (@($early.CredentialRefusedKeys) -join ',')
}
Test-Case 'P44' 'Anti-verrouillage : la pause reste tant qu une autre copie du mot de passe refuse envoie le compte' {
    $h={param([string]$Use,[string]$Key,[long]$Generation)[pscustomobject]@{Use=$Use;Key=$Key;Generation=$Generation}}
    $keys=@('jdupont@corp.example','jean.dupont@corp.example.com')
    Assert-True (Get-DomeniaAccountReleaseDecision @((& $h 'Directory' 'jdupont@corp.example' (-1))) $keys (-1)).Release 'Rien en pause : rien a proteger'
    # Validated as the workstation account; the connection account still holds the refused password.
    $d=Get-DomeniaAccountReleaseDecision @((& $h 'Directory' 'jdupont@corp.example' (-1)),(& $h 'Remote' 'jdupont@corp.example' 8),(& $h 'Secrets' 'reader@corp.example' (-1))) $keys 5
    Assert-False $d.Release 'Pause levee alors que le compte de connexion envoie encore l ancien mot de passe'
    Assert-Equal 'Directory' (@($d.Stale) -join ',')
    Assert-True ($d.Text -match 'compte de connexion') $d.Text;Assert-True ($d.Text -match 'Corriger le mot de passe') $d.Text;Assert-True ($d.Text -match 'lʼenvoie encore') $d.Text
    # Another confirmed name of the same account, held by a temporary account, counts as well.
    $d=Get-DomeniaAccountReleaseDecision @((& $h 'Remote' 'jdupont@corp.example' 8),(& $h 'Temporary' 'Jean.Dupont@corp.example.com' 4),(& $h 'Session' 'jdupont@corp.example' (-1))) $keys 5
    Assert-Equal 'Session,Temporary' ((@($d.Stale)|Sort-Object) -join ',');Assert-True ($d.Text -match 'lʼenvoient encore') $d.Text
    # Every copy validated after the refusal: released. A refusal of the validated password itself keeps the pause.
    Assert-True (Get-DomeniaAccountReleaseDecision @((& $h 'Directory' 'jdupont@corp.example' 9),(& $h 'Remote' 'jdupont@corp.example' 8)) $keys 5).Release
    Assert-False (Get-DomeniaAccountReleaseDecision @((& $h 'Remote' 'jdupont@corp.example' 8)) $keys 8).Release
    Assert-True (Get-DomeniaAccountReleaseDecision @((& $h 'Directory' 'reader@corp.example' (-1))) $keys 5).Release 'Un autre compte bloque la liberation'
}
Test-Case 'P44' 'Plan de correction : lectures anciennes arretees, ecritures et autres comptes intacts' {
    $job={param($Id,[bool]$Write,[string]$State,[string]$Key,[long]$Generation,[bool]$Protected=$false)[pscustomobject]@{Id=$Id;IsWrite=$Write;NonCancellable=$Protected;State=$State;Keys=@($Key);Generation=$Generation}}
    $jobs=@((& $job 'read-old' $false 'Running' 'jdupont@corp.example' 3),(& $job 'read-alias' $false 'Running' 'jean.dupont@corp.example.com' 3),(& $job 'write' $true 'Running' 'jdupont@corp.example' 3),
        (& $job 'queued' $false 'Queued' 'jdupont@corp.example' 0),(& $job 'other' $false 'Running' 'reader@corp.example' 3),(& $job 'fresh' $false 'Running' 'jdupont@corp.example' 4),(& $job 'store' $false 'Running' 'jdupont@corp.example' 3 $true))
    $p=Get-DomeniaAccountCorrectionPlan $jobs @('JDupont@corp.example','jean.dupont@corp.example.com') 4
    Assert-Equal 'read-old,read-alias' (@($p.Stop) -join ',')
    Assert-Equal 1 ([int]$p.Writes);Assert-Equal 1 ([int]$p.AlreadyCurrent)
    Assert-True ($p.Text -match 'relancez-les');Assert-True ($p.Text -match 'ni interrompue ni rejouée')
    $none=Get-DomeniaAccountCorrectionPlan @() @('x@corp.example') 1
    Assert-Equal 0 @($none.Stop).Count;Assert-True ($none.Text -match 'en attente partiront avec le compte validé')
}
Test-Case 'P42' 'Usage visible : compte de connexion par defaut, compte specifique facultatif, aucun etat invente' {
    $rows=@(Get-DomeniaAccountUsageRows -ConnectionUser 'CORP\jdupont' -ConnectionMode Explicit -Domain 'corp.example' -Netbios 'CORP')
    Assert-Equal 4 $rows.Count
    Assert-Equal 4 @($rows|Where-Object{$_.Account -eq 'CORP\jdupont'}).Count
    Assert-True ($rows[1].Source -match 'aucun compte spécifique')
    $rows=@(Get-DomeniaAccountUsageRows -ConnectionUser 'CORP\jdupont' -ConnectionMode Explicit -RemoteUser 'CORP\adm-postes' -SecretsUser 'CORP\lecteur-laps' -Temporary @([pscustomobject]@{Scope='RemoteLocal|PC-01';UserName='PC-01\admin'},[pscustomobject]@{Scope='AD:WriteAttributes';UserName='CORP\delegue'}) -Faults @([pscustomobject]@{Key='adm-postes@corp.example'}) -Domain 'corp.example' -Netbios 'CORP')
    Assert-Equal 6 $rows.Count
    Assert-Equal 'CORP\adm-postes' $rows[1].Account;Assert-Equal 'compte poste' $rows[1].Source;Assert-True ($rows[1].State -match 'En pause')
    Assert-True ($rows[0].State -match 'Aucun refus enregistré');Assert-False ($rows[0].State -match 'valid') 'Un compte non teste est presente comme valide'
    Assert-Equal 'CORP\lecteur-laps' $rows[2].Account;Assert-Equal 'CORP\lecteur-laps' $rows[3].Account
    Assert-Equal 'Poste PC-01' $rows[4].Usage;Assert-Equal 'Annuaire (WriteAttributes)' $rows[5].Usage
    $text=Format-DomeniaAccountUsageText $rows
    Assert-True ($text.Contains('Postes : CORP\adm-postes (compte poste).'));Assert-True ($text -match 'indépendant')
    Assert-Equal 'session Windows' (@(Get-DomeniaAccountUsageRows -ConnectionUser 'CORP\jdupont' -ConnectionMode Windows -Domain 'corp.example' -Netbios 'CORP'))[0].Source
}
# Point 50 : exports expurges. Marqueurs generes a l execution, aucun secret reel.
Test-Case 'P50' 'Export : colonne d attribut secret retenue, texte secret masque, valeurs ordinaires intactes' {
    $marker=[guid]::NewGuid().ToString('N')
    $key=((1..8|ForEach-Object{'{0:D6}' -f (100000+$_*111)}) -join '-')
    $when=[datetime]::SpecifyKind([datetime]'2026-05-09T08:00:00',[DateTimeKind]::Utc)
    $r=Protect-DomeniaExportRows @([pscustomobject]@{Nom='PC-01';Description=('password='+$marker);Note=('cle '+$key);'msFVE-RecoveryPassword'=$marker;Taille=12;Vu=$when;Actif=$true})
    $row=$r.Rows[0]
    Assert-False ((($row|ConvertTo-Json -Compress)).Contains($marker)) 'Secret exporte'
    Assert-False (([string]$row.Note).Contains($key)) 'Cle de recuperation exportee'
    Assert-Equal 'PC-01' $row.Nom;Assert-Equal 12 $row.Taille;Assert-Equal $when $row.Vu;Assert-Equal $true $row.Actif
    Assert-Equal 3 ([int]$r.Masked);Assert-Equal 'msFVE-RecoveryPassword' (@($r.Withheld) -join ',')
    $clean=Protect-DomeniaExportRows @([pscustomobject]@{Nom='PC-02';Description='Poste du hall'})
    Assert-Equal 0 ([int]$clean.Masked);Assert-Equal 'Poste du hall' $clean.Rows[0].Description
    Assert-Equal 0 @((Protect-DomeniaExportRows @()).Rows).Count
}
Test-Case 'P50' 'Indice rapide : toute forme masquee par la regle du journal le declenche, une valeur ordinaire jamais' {
    $hint=Get-DomeniaSecretTextHint
    $key=((1..8|ForEach-Object{'{0:D6}' -f (100000+$_*111)}) -join '-')
    $secrets=@($key,'Authorization: Bearer abc.def','Basic dXNlcjpwYXNz','{"p":"x1"}','{"p" : "x1"}','{"token":"abc"}','password=abc','Mot de passe : abc','motdepasse=abc','pwd: abc','secret=abc','token=abc','api-key=abc','apikey: abc','client_secret=abc','cmd -p abc','cmd /pwd:abc','-rp abc','/password=abc','-pass abc')
    foreach($text in $secrets){
        Assert-True ((Protect-DomeniaSecretText $text) -cne $text) ('Forme non masquee par la regle : '+$text)
        Assert-True ($text -match $hint) ('Forme masquee que l indice laisse passer : '+$text)
    }
    foreach($text in @('PC-01','CN=PC-01,OU=Postes,DC=example,DC=test','00000000-0000-0000-0000-000000000001','Windows 11 Entreprise','Non recueillie / expirée','12.5 j')){
        Assert-False ($text -match $hint) ('Valeur ordinaire envoyee a la regle complete : '+$text)
    }
}
Test-Case 'P50' 'Export : une colonne liee a un attribut secret est retenue quel que soit son titre' {
    $marker=[guid]::NewGuid().ToString('N')
    $r=Protect-DomeniaExportRows -Rows @([pscustomobject]@{Poste='PC-01';'Mot de passe LAPS'=$marker},[pscustomobject]@{Poste='PC-02';'Mot de passe LAPS'=''}) -SecretColumns @('Mot de passe LAPS')
    Assert-False (((@($r.Rows))|ConvertTo-Json -Compress).Contains($marker)) 'Valeur de la colonne liee exportee'
    Assert-Equal 1 ([int]$r.Masked);Assert-Equal 'Mot de passe LAPS' (@($r.Withheld) -join ',');Assert-Equal 'PC-02' ([string]$r.Rows[1].Poste)
}
