# D091-D100 : securite des interventions. Donnees fictives uniquement : aucun envoi, aucun annuaire, aucun secret reel.
$script:SfNow=[datetime]::SpecifyKind([datetime]'2026-03-02T09:00:00',[DateTimeKind]::Utc)
$script:SfGuidA='6f1c2d3e-4a5b-4c6d-8e7f-0a1b2c3d4e5f'
$script:SfGuidB='1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d'
$script:SfDnA='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=test'
$script:SfDnB='CN=Jean Dupont,OU=Anciens,DC=example,DC=test'
$script:SfPcA='3a760e2f-315a-4155-a1d0-26a319a64cf2'
$script:SfPcB='9b8c7d6e-5f4a-4b3c-9d2e-1f0a9b8c7d6e'
$script:SfChanges=@([pscustomobject]@{Name='description';Old='Compta';New='Paie'},[pscustomobject]@{Name='telephoneNumber';Old='0102';New='0103'})
$script:SfId={ param([string]$Guid,[string]$Dn,[string]$Name='Jean Dupont',[long]$Epoch=1,[long]$Generation=1,[string]$Type='Utilisateur')
    New-DomeniaSelectionIdentity ([pscustomobject]@{Guid=$Guid;Type=$Type;DN=$Dn;Name=$Name;Login='jdupont'}) 'example.test' 'EX\lecteur' $Epoch $Generation }
$script:SfPlan={ param($Target,[string]$Operation='WriteAttributes',[object[]]$Changes=$script:SfChanges,[bool]$Simulation=$false)
    New-DomeniaInterventionPlan -OperationId $Operation -Target $Target -Server 'DC01.example.test' -Account 'EX\adm-jd' -Changes $Changes -Effects @('Fiche modifiee') -Simulation $Simulation }
$script:SfError={ param([scriptblock]$Body) try { & $Body | Out-Null; '' } catch { $_.Exception.Message } }
$script:SfCheck={ param($Plan,$Current,[object[]]$Changes=$script:SfChanges,[string]$Server='DC01.example.test',[string]$Account='EX\adm-jd',[string]$OperationId='')
    Test-DomeniaPlanStillValid -Plan $Plan -Current $Current -Server $Server -Account $Account -Changes $Changes -OperationId $OperationId -NowUtc $Plan.CreatedUtc.AddMinutes(1) }

Test-Case 'D091' 'Le plan capture cible, GUID, compte, controleur, changements et effets' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    Assert-True ($p -is [Domenia.InterventionPlan])
    Assert-Equal 'WriteAttributes' $p.Operation;Assert-Equal $script:SfGuidA $p.Target.Guid;Assert-Equal 'DC01.example.test' $p.Server;Assert-Equal 'EX\adm-jd' $p.Account
    Assert-Equal 2 $p.Changes.Count;Assert-Equal 'description' $p.Changes[0].Attribute;Assert-Equal 'Compta' $p.Changes[0].Before;Assert-Equal 'Paie' $p.Changes[0].After;Assert-Equal 'Replace' $p.Changes[0].Kind
    Assert-Equal 'Fiche modifiee' $p.Effects[0];Assert-Equal 1 $p.Effects.Count;Assert-True ($p.Fingerprint -cmatch '^[0-9A-F]{64}$');Assert-False $p.Simulation
    $threw=$false;try{$p.Server='DC02'}catch{$threw=$true}
    Assert-True $threw 'Le plan confirme est immuable';Assert-Equal 'DC01.example.test' $p.Server
    $threw=$false;try{$p.Changes.Add($null)}catch{$threw=$true}
    Assert-True $threw 'La liste des changements est figee';Assert-Equal 2 $p.Changes.Count
    Assert-True ((& $script:SfError { New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target ([pscustomobject]@{Guid=$script:SfGuidA}) -Server 'DC01' -Account 'EX\a' -Changes $script:SfChanges }) -match 'Cible non identifi')
    Assert-True ((& $script:SfError { New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server '' -Account 'EX\a' -Changes $script:SfChanges }) -match 'Destinataire')
    Assert-True ((& $script:SfError { New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account '' -Changes $script:SfChanges }) -match 'Compte')
    Assert-True ((& $script:SfError { New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\a' }) -match 'Plan vide')
    Assert-True ((& $script:SfError { New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\a' -Changes @([pscustomobject]@{Name='description';Kind='Merge';New='x'}) }) -match 'Type de changement')
}
Test-Case 'D091' 'Plan inchange : execution admise sur le meme objet' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $again=& $script:SfId $script:SfGuidA.ToUpperInvariant() $script:SfDnA.ToLowerInvariant() 'Jean Dupont' 1 7
    $r=Test-DomeniaPlanStillValid -Plan $p -Current $again -Server 'dc01.example.test' -Account 'ex\ADM-JD' -Changes $script:SfChanges -NowUtc $p.CreatedUtc.AddMinutes(2)
    Assert-True $r.Valid ($r.Reasons -join ' | ');Assert-Equal $p.Fingerprint $r.Fingerprint;Assert-Equal 0 $r.Reasons.Count;Assert-Equal '' $r.Limit
    $lower=@([pscustomobject]@{Name='description';Kind='replace';Old='Compta';New='Paie'},$script:SfChanges[1])
    Assert-True (& $script:SfCheck $p $again $lower).Valid 'La casse du type de changement ne compte pas'
}
Test-Case 'D091' 'Un champ modifie invalide le plan presente' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    Assert-True (& $script:SfCheck $p $target).Valid 'Reference : plan intact'
    $variants=@(
        @([pscustomobject]@{Name='description';Old='Compta';New='Paye'},$script:SfChanges[1]),
        @([pscustomobject]@{Name='description';Old='Comptabilite';New='Paie'},$script:SfChanges[1]),
        @($script:SfChanges[0]),
        @($script:SfChanges[1],$script:SfChanges[0]),
        @($script:SfChanges[0],[pscustomobject]@{Name='telephoneNumber';Old='0102';Clear=$true}),
        @($script:SfChanges[0],$script:SfChanges[1],[pscustomobject]@{Name='title';Old='';New='Chef'})
    )
    foreach($v in $variants){
        $r=& $script:SfCheck $p $target $v
        Assert-False $r.Valid 'Valeurs differentes acceptees'
        Assert-Equal 1 $r.Reasons.Count ($r.Reasons -join ' | ');Assert-True ($r.Reasons[0] -match 'nouvelle confirmation') ($r.Reasons -join ' | ')
    }
    Assert-False (& $script:SfCheck $p $target $script:SfChanges 'DC02.example.test').Valid 'Autre controleur'
    Assert-False (& $script:SfCheck $p $target $script:SfChanges 'DC01.example.test' 'EX\autre').Valid 'Autre compte'
    Assert-False (& $script:SfCheck $p $target $script:SfChanges 'DC01.example.test' 'EX\adm-jd' 'WriteExpiration').Valid 'Autre operation'
    Assert-False (Test-DomeniaPlanStillValid -Plan $p -Current $target -Server 'DC01.example.test' -Account 'EX\adm-jd' -Changes $script:SfChanges -NowUtc $p.CreatedUtc.AddMinutes(16)).Valid 'Plan trop ancien'
}
Test-Case 'D091' 'Sans heure de controle le plan n est pas execute' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $r=Test-DomeniaPlanStillValid -Plan $p -Current $target -Server 'DC01.example.test' -Account 'EX\adm-jd' -Changes $script:SfChanges
    Assert-False $r.Valid 'Age non verifiable sans heure de controle';Assert-Equal 1 $r.Reasons.Count;Assert-True ($r.Reasons[0] -match 'Heure de contrôle absente')
    Assert-True (Test-DomeniaPlanStillValid -Plan $p -Current $target -Server 'DC01.example.test' -Account 'EX\adm-jd' -Changes $script:SfChanges -MaxAgeMinutes 0).Valid 'Controle d age desactive explicitement'
    $back=Test-DomeniaPlanStillValid -Plan $p -Current $target -Server 'DC01.example.test' -Account 'EX\adm-jd' -Changes $script:SfChanges -NowUtc $p.CreatedUtc.AddMinutes(-10)
    Assert-False $back.Valid 'Heure anterieure a la confirmation';Assert-True (($back.Reasons -join ' ') -match 'antérieure')
}
Test-Case 'D091' 'Une autre cible invalide le plan au lieu de l executer ailleurs' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $homonym=& $script:SfId $script:SfGuidB $script:SfDnA
    $r=& $script:SfCheck $p $homonym
    Assert-False $r.Valid 'Un homonyme au meme DN reste une autre cible';Assert-True (($r.Reasons -join ' ') -match 'autre objet');Assert-True ($r.Fingerprint -cne $p.Fingerprint)
    $m=& $script:SfCheck $p (& $script:SfId $script:SfGuidA $script:SfDnB)
    Assert-False $m.Valid 'Objet deplace depuis la confirmation';Assert-True (($m.Reasons -join ' ') -match 'déplacé ou renommé')
    Assert-False (& $script:SfCheck $p (& $script:SfId $script:SfGuidA $script:SfDnA 'Jean Dupont' 2)).Valid 'Session changee'
    $otherDomain=New-DomeniaSelectionIdentity ([pscustomobject]@{Guid=$script:SfGuidA;Type='Utilisateur';DN=$script:SfDnA;Name='Jean Dupont'}) 'other.test' 'EX\lecteur' 1 1
    Assert-False (& $script:SfCheck $p $otherDomain).Valid 'Meme GUID dans un autre domaine'
    Assert-False (& $script:SfCheck $p $null).Valid 'Cible absente'
    Assert-False (Test-DomeniaPlanStillValid -Plan $null -Current $target -NowUtc $script:SfNow).Valid 'Sans plan rien ne part'
}
Test-Case 'D091' 'Aucune valeur secrete n entre dans le plan et la limite est annoncee' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=New-DomeniaInterventionPlan -OperationId 'WriteResetPassword' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';Old='ANCIEN-MARQUEUR';New='NOUVEAU-MARQUEUR'}) -Effects @('password=NOUVEAU-MARQUEUR')
    Assert-Equal '' $p.Changes[0].Before;Assert-False ($p.Changes[0].After -match 'MARQUEUR');Assert-False (($p.Effects -join ' ') -match 'MARQUEUR')
    Assert-True (@($p.Effects) -contains (Get-DomeniaPlanSecretLimit)) 'Limite annoncee sur l ecran de confirmation'
    $other=New-DomeniaInterventionPlan -OperationId 'WriteResetPassword' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';New='AUTRE-MARQUEUR'})
    Assert-Equal $p.Fingerprint $other.Fingerprint 'Limite connue : la valeur secrete est hors de l empreinte'
    $v=Test-DomeniaPlanStillValid -Plan $p -Current $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';New='AUTRE-MARQUEUR'}) -NowUtc $p.CreatedUtc.AddMinutes(1)
    Assert-True $v.Valid ($v.Reasons -join ' | ');Assert-True ($v.Limit -match 'Valeur secrète hors du plan')
    $kindReset=New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='description';Kind='Reset';Old='AVANT-MARQUEUR';New='APRES-MARQUEUR'})
    Assert-False (($kindReset.Changes[0].Before + $kindReset.Changes[0].After) -match 'MARQUEUR') 'Un changement Reset ne garde aucune valeur'
}

Test-Case 'D092' 'Un plan de simulation ne part jamais et ne cree aucun recu' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $sim=& $script:SfPlan $target 'WriteAttributes' $script:SfChanges $true
    $reg=New-DomeniaWriteRegistry
    Assert-False (Test-DomeniaWriteAdmission $reg $sim Operator).Admit;Assert-Equal 0 $reg.Entries.Count
    Assert-True ((& $script:SfError { ConvertTo-DomeniaReceiptRecord -Plan $sim -Id ('a'*32) -NowUtc $script:SfNow }) -match 'simulation')
    $v=& $script:SfCheck $sim $target
    Assert-False $v.Valid;Assert-True (($v.Reasons -join ' ') -match 'simulation')
}

Test-Case 'D093' 'Chaque operation de modification a sa regle de relecture dediee' {
    $expected=@{WriteGroupMember='Membership';WriteObjectGroup='Membership';WriteMoveObject='Move';WriteRenameComputer='Move';WriteAttributes='Attribute';WriteExpiration='Attribute';WriteExpirePassword='Attribute';WriteAccountDisabled='State';WriteUnlock='State';WriteAccountOptions='State';WriteResetPassword='PasswordChange';WriteCreateOu='Existence';WriteDeleteObject='Absence';ComputerRestart='Restart';ComputerGpUpdate='PolicyRefresh';RimotteRun='RemoteRun';WakeOnLanSend='Presence'}
    foreach($op in @($expected.Keys)){
        $rule=Get-DomeniaPostconditionRule $op
        Assert-Equal $expected[$op] $rule.Kind $op;Assert-True ([bool]$rule.Check) $op
    }
    Assert-Equal 'Aucune' (Get-DomeniaPostconditionRule 'WriteInconnue').Kind;Assert-False (Get-DomeniaPostconditionRule 'RimotteRun').CanVerify
}
Test-Case 'D093' 'Appartenance : Verifie, Partiel ou A verifier selon la relecture' {
    $rule=Get-DomeniaPostconditionRule 'WriteGroupMember'
    $exp=@{Server='DC01';Add=@('CN=Jean Dupont,OU=U,DC=example,DC=test','CN=Marie Curie,OU=U,DC=example,DC=test');Remove=@('CN=Paul Martin,OU=U,DC=example,DC=test')}
    $all=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Server='DC01';Members=@('cn=jean dupont,ou=u,dc=example,dc=test','CN=Marie Curie, OU=U, DC=example, DC=test')})
    Assert-Equal 'Verifie' $all.Status;Assert-Equal 'Vérifié' $all.Label;Assert-True ($all.Proof -match '3/3');Assert-True ($all.Proof -match 'DC01')
    $part=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Server='DC01';Members=@('CN=Jean Dupont,OU=U,DC=example,DC=test','CN=Paul Martin,OU=U,DC=example,DC=test')})
    Assert-Equal 'Partiel' $part.Status;Assert-True ($part.Proof -match 'ajout non constaté : Marie Curie');Assert-True ($part.Proof -match 'retrait non constaté : Paul Martin')
    $refused=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='Refused';Server='DC01';Members=@()})
    Assert-Equal 'A verifier' $refused.Status;Assert-Equal 'À vérifier' $refused.Label;Assert-True ($refused.Proof -match 'refusée')
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule $exp $null).Status
    $far=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Server='DC02';Members=@()})
    Assert-True ($far.Proof -match 'réplication') 'Relecture sur un autre controleur signalee'
}
Test-Case 'D093' 'Une valeur absente de la relecture n est pas une valeur vide' {
    $rule=Get-DomeniaPostconditionRule 'WriteAttributes'
    $exp=@{Values=@{description=''}}
    $none=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Server='DC01'})
    Assert-Equal 'A verifier' $none.Status 'Relecture sans Values';Assert-True ($none.Proof -match 'description non relu');Assert-Equal 'Inconnu' $none.Details[0].Etat
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Values=@{title='x'}})).Status 'Attribut absent de Values'
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Values=@{description=''}})).Status 'Valeur vide relue explicitement'
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Values=[pscustomobject]@{description=$null}})).Status 'Valeur nulle relue explicitement'
    Assert-Equal 'Partiel' (Resolve-DomeniaPostcondition $rule @{Values=@{description='';title='Chef'}} ([pscustomobject]@{ReadStatus='OK';Values=@{title='Chef'}})).Status
    $state=Get-DomeniaPostconditionRule 'WriteAccountDisabled'
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $state @{Flags=@{Enabled=''}} ([pscustomobject]@{ReadStatus='OK'})).Status 'Etat sans Flags'
    $group=Get-DomeniaPostconditionRule 'WriteGroupMember'
    $remove=@{Remove=@('CN=Paul Martin,OU=U,DC=example,DC=test')}
    $noList=Resolve-DomeniaPostcondition $group $remove ([pscustomobject]@{ReadStatus='OK'})
    Assert-Equal 'A verifier' $noList.Status 'Liste des membres non relue';Assert-True ($noList.Proof -match 'membres non relus')
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $group $remove ([pscustomobject]@{ReadStatus='OK';Members=@()})).Status 'Liste vide relue explicitement'
}
Test-Case 'D093' 'Le retour du processus n est jamais la preuve' {
    $rule=Get-DomeniaPostconditionRule 'WriteAttributes'
    $r=Resolve-DomeniaPostcondition $rule @{Values=@{description='Paie'}} ([pscustomobject]@{ReadStatus='OK';Server='DC01';Values=@{description='Compta'}}) ([pscustomobject]@{ExitCode=0;Message='Operation reussie'})
    Assert-Equal 'A verifier' $r.Status 'Un code 0 ne remplace pas la relecture'
    Assert-True ($r.Proof -match 'pas une preuve');Assert-True ($r.Proof -match 'description relu « Compta »')
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Values=@{description='Paie'}} $null ([pscustomobject]@{ExitCode=0;Message='OK'})).Status 'Sans relecture rien n est verifie'
}
Test-Case 'D093' 'Attribut et etat : la preuve nomme chaque valeur relue' {
    $rule=Get-DomeniaPostconditionRule 'WriteAttributes'
    $r=Resolve-DomeniaPostcondition $rule ([pscustomobject]@{Values=[pscustomobject]@{description='Paie';telephoneNumber='0103'}}) ([pscustomobject]@{ReadStatus='OK';Server='DC01';Values=@{description='Paie';telephoneNumber='0102'}})
    Assert-Equal 'Partiel' $r.Status;Assert-Equal 2 $r.Checked;Assert-Equal 1 $r.Satisfied;Assert-True ($r.Proof -match 'telephoneNumber relu « 0102 »')
    Assert-Equal 2 $r.Details.Count;Assert-Equal 'Constate' $r.Details[0].Etat
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition (Get-DomeniaPostconditionRule 'WriteAccountDisabled') @{Flags=@{Enabled='False'}} ([pscustomobject]@{ReadStatus='OK';Flags=@{Enabled='false'}})).Status
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Values=@{unicodePwd='x'}} ([pscustomobject]@{ReadStatus='OK';Values=@{unicodePwd='x'}})).Status 'Un secret n est jamais compare'
}
Test-Case 'D093' 'Deplacement relu par GUID sous le conteneur choisi' {
    $rule=Get-DomeniaPostconditionRule 'WriteMoveObject'
    $exp=@{Guid=$script:SfGuidA;NewDn=$script:SfDnB}
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA.ToUpperInvariant();DN=$script:SfDnB.ToUpperInvariant()})).Status
    $old=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;DN=$script:SfDnA})
    Assert-Equal 'A verifier' $old.Status;Assert-True ($old.Proof -match 'Utilisateurs')
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidB;DN=$script:SfDnB})).Status 'Un autre objet au bon endroit ne prouve rien'
    $noDn=Resolve-DomeniaPostcondition $rule $exp ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA})
    Assert-Equal 'A verifier' $noDn.Status;Assert-True ($noDn.Proof -match 'emplacement non relu')
}
Test-Case 'D093' 'Presence et absence : seule une reponse booleenne explicite compte' {
    $rule=Get-DomeniaPostconditionRule 'WriteDeleteObject'
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Guid=$script:SfGuidA} ([pscustomobject]@{ReadStatus='OK';Server='DC01'})).Status 'Une relecture muette ne vaut pas absence'
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Guid=$script:SfGuidA} ([pscustomobject]@{ReadStatus='Refused';Exists=$false})).Status 'Un refus ne vaut pas absence'
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $rule @{Guid=$script:SfGuidA} ([pscustomobject]@{ReadStatus='OK';Exists=$false})).Status
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Guid=$script:SfGuidA} ([pscustomobject]@{ReadStatus='OK';Exists=$true})).Status
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $rule @{Guid=$script:SfGuidA} ([pscustomobject]@{ReadStatus='OK';Exists='0'})).Status 'Valeur non booleenne'
    $ou=Get-DomeniaPostconditionRule 'WriteCreateOu'
    $text=Resolve-DomeniaPostcondition $ou @{} ([pscustomobject]@{ReadStatus='OK';Exists='False'})
    Assert-Equal 'A verifier' $text.Status 'Le texte False n est pas une presence';Assert-True ($text.Proof -match 'objet non constaté')
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition $ou @{} ([pscustomobject]@{ReadStatus='OK';Exists='true'})).Status
    foreach($value in @('oui',1,'Vrai')){ Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition $ou @{} ([pscustomobject]@{ReadStatus='OK';Exists=$value})).Status ([string]$value) }
}
Test-Case 'D093' 'Actions distantes : horloges nommees, reveil jamais prouve, execution distante a verifier' {
    $sent=$script:SfNow
    $boot=Resolve-DomeniaPostcondition 'ComputerRestart' $null ([pscustomobject]@{ReadStatus='OK';Server='PC-01';LastBootUtc=$sent.AddMinutes(3)}) $null $sent
    Assert-Equal 'Verifie' $boot.Status;Assert-True ($boot.Proof -match 'PC-01');Assert-True ($boot.Proof -match 'horloge du poste');Assert-True ($boot.Proof -match 'deux horloges')
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition 'ComputerRestart' $null ([pscustomobject]@{ReadStatus='OK';LastBootUtc=$sent.AddDays(-1)}) $null $sent).Status
    $margin=Resolve-DomeniaPostcondition 'ComputerRestart' $null ([pscustomobject]@{ReadStatus='OK';LastBootUtc=$sent.AddSeconds(20)}) $null $sent -ClockSkewSeconds 60
    Assert-Equal 'A verifier' $margin.Status 'Marge d horloge exigee';Assert-True ($margin.Proof -match '60 s')
    $same=Resolve-DomeniaPostcondition 'ComputerRestart' @{PreviousUtc=$sent.AddDays(-2)} ([pscustomobject]@{ReadStatus='OK';LastBootUtc=$sent.AddDays(-2)}) $null $sent
    Assert-Equal 'A verifier' $same.Status 'Valeur identique a celle relue avant l envoi';Assert-True ($same.Proof -match 'même horloge')
    Assert-Equal 'Verifie' (Resolve-DomeniaPostcondition 'ComputerGpUpdate' @{PreviousUtc=$sent.AddHours(-3)} ([pscustomobject]@{ReadStatus='OK';LastPolicyRefreshUtc=$sent.AddSeconds(30)}) $null $null).Status 'Comparaison sur une seule horloge'
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition 'ComputerGpUpdate' $null ([pscustomobject]@{ReadStatus='OK';LastPolicyRefreshUtc=$sent.AddMinutes(1)}) $null $null).Status 'Heure d envoi inconnue'
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition 'RimotteRun' $null ([pscustomobject]@{ReadStatus='OK'}) ([pscustomobject]@{ExitCode=0}) $sent).Status
    $pwdZero=Resolve-DomeniaPostcondition 'WriteResetPassword' $null ([pscustomobject]@{ReadStatus='OK';PwdLastSetUtc='0'}) $null $sent
    Assert-Equal 'A verifier' $pwdZero.Status;Assert-True ($pwdZero.Proof -match 'changement imposé')
    $wake=Resolve-DomeniaPostcondition 'WakeOnLanSend' $null ([pscustomobject]@{ReadStatus='OK';RespondedUtc=$sent.AddSeconds(40)}) $null $sent
    Assert-Equal 'Partiel' $wake.Status 'Une reponse ne prouve pas que le reveil vient de la demande';Assert-True ($wake.Proof -match 'ne prouve pas');Assert-True ($wake.Limit -match 'réveil')
    Assert-Equal 'A verifier' (Resolve-DomeniaPostcondition 'WakeOnLanSend' $null ([pscustomobject]@{ReadStatus='OK';RespondedUtc=$sent.AddMinutes(-5)}) $null $sent).Status
}

Test-Case 'D094' 'Ecritures AD, GPUpdate, redemarrage, execution distante et reveil exigent un recu avant l envoi' {
    foreach($op in @('WriteAttributes','WriteGroupMember','WriteResetPassword','WriteDeleteObject','ComputerGpUpdate','ComputerRestart','RimotteRun','WakeOnLanSend','OperationInconnue')){
        $q=Get-DomeniaReceiptRequirement $op
        Assert-True $q.Required $op;Assert-True $q.WriteBeforeDispatch $op;Assert-Equal 'Sent' $q.DispatchAfterStage $op
    }
    foreach($op in @('GlobalSearch','OpenAdObject','ReadLaps','SessionsList','LocalStore')){ $q=Get-DomeniaReceiptRequirement $op;Assert-False $q.Required $op;Assert-Equal '' $q.DispatchAfterStage $op }
}
Test-Case 'D094' 'Une fermeture apres envoi n efface pas l incertitude et ne relance rien' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    foreach($stage in @('Sent','Unknown','Inattendu')){
        $s=Get-DomeniaReceiptResumeState ([pscustomobject]@{Stage=$stage})
        Assert-True $s.Uncertain $stage;Assert-True $s.BlocksTarget $stage;Assert-True ($s.Text -match 'Aucun nouvel envoi') $stage
        $receipt=[pscustomobject]@{Id=('a'*32);Fingerprint=$p.Fingerprint;Operation='WriteAttributes';Stage=$stage;Guid=$script:SfGuidA;DN=$script:SfDnA}
        $reg=New-DomeniaWriteRegistry @($receipt)
        Assert-Equal 'Uncertain' $reg.Entries[$p.Fingerprint].State $stage
        foreach($origin in @('Resume','Startup','AutoRetry','Reconnect')){ Assert-False (Test-DomeniaWriteAdmission $reg $p $origin).Admit ($stage+' '+$origin) }
        Assert-False (Test-DomeniaWriteAdmission $reg (& $script:SfPlan $target) Operator).Admit ($stage+' : l incertitude survit a la fermeture')
        Assert-False (Set-DomeniaWriteOutcome $reg $p.Fingerprint 'NotSent').Accepted ($stage+' : jamais requalifie en non envoye')
        $locks=@(Get-DomeniaReceiptLocks @($receipt))
        Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @($target) $locks).Allowed ($stage+' : cible bloquee a la reprise')
    }
    $prepared=Get-DomeniaReceiptResumeState ([pscustomobject]@{Stage='Prepared'})
    Assert-Equal 'NotSent' $prepared.State;Assert-False $prepared.Uncertain
    Assert-Equal 'Verified' (Get-DomeniaReceiptResumeState ([pscustomobject]@{Stage='Verified'})).State
    Assert-True (Get-DomeniaReceiptResumeState $null).Uncertain 'Recu illisible : incertain'
}
Test-Case 'D094' 'Le recu prepare avant l envoi porte l empreinte et aucune valeur en clair' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $id='0123456789abcdef0123456789abcdef'
    $rec=ConvertTo-DomeniaReceiptRecord -Plan $p -Id $id -NowUtc $script:SfNow -Domain 'DC=Example,DC=Test'
    Assert-Equal 'Prepared' $rec.Stage;Assert-Equal 1 $rec.Format;Assert-Equal $p.Fingerprint $rec.Fingerprint;Assert-Equal $script:SfGuidA $rec.Guid;Assert-Equal 'dc=example,dc=test' $rec.Domain
    Assert-Equal 2 $rec.Expected.Count;Assert-Equal (Get-DomeniaTextHash 'Paie').ToLowerInvariant() $rec.Expected[0].Hash;Assert-False (($rec|ConvertTo-Json -Depth 4) -match 'Paie');Assert-True $rec.CanVerify
    $reset=New-DomeniaInterventionPlan -OperationId 'WriteResetPassword' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';Kind='Reset';New='MARQUEUR-SECRET'})
    $r2=ConvertTo-DomeniaReceiptRecord -Plan $reset -Id $id -NowUtc $script:SfNow
    Assert-Equal 0 $r2.Expected.Count;Assert-False $r2.CanVerify;Assert-False (($r2|ConvertTo-Json -Depth 4) -match 'MARQUEUR')
    Assert-True ((& $script:SfError { ConvertTo-DomeniaReceiptRecord -Plan $p -Id 'pas-un-id' -NowUtc $script:SfNow }) -match 'Identifiant')
    Assert-True ((& $script:SfError { ConvertTo-DomeniaReceiptRecord -Plan $p -Id $id }) -match 'Date')
}

Test-Case 'D095' 'Double-clic sur Executer : une seule demande part, sans option a retenir' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $reg=New-DomeniaWriteRegistry
    $check=Test-DomeniaWriteAdmission $reg $p Operator -CheckOnly
    Assert-True $check.Admit;Assert-False $check.Reserved;Assert-Equal 0 $reg.Entries.Count 'Une simple verification ne reserve rien'
    $sent=0
    foreach($click in 1..2){ if((Test-DomeniaWriteAdmission $reg $p Operator).Admit){$sent++} }
    Assert-Equal 1 $sent 'Deux clics, une demande'
    $second=Test-DomeniaWriteAdmission $reg $p Operator
    Assert-False $second.Admit;Assert-True $second.Duplicate;Assert-Equal $p.Fingerprint $second.Key
    Assert-False (Test-DomeniaWriteAdmission $reg (& $script:SfPlan $target) Operator).Admit 'Une confirmation identique pendant l envoi ne part pas'
    Assert-Equal 1 $reg.Entries.Count
}
Test-Case 'D095' 'Au redemarrage aucune ecriture ne part, meme identique et confirmee' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $receipt=[pscustomobject]@{Id=('b'*32);Fingerprint=$p.Fingerprint.ToLowerInvariant();Operation='WriteAttributes';Stage='Sent';Guid=$script:SfGuidA;DN=$script:SfDnA}
    $reg=New-DomeniaWriteRegistry @($receipt)
    foreach($origin in @('Startup','Resume','AutoRetry','Timer','Reconnect')){ Assert-False (Test-DomeniaWriteAdmission $reg $p $origin).Admit $origin }
    Assert-False (Test-DomeniaWriteAdmission (New-DomeniaWriteRegistry) $p Startup).Admit 'Demarrage sans recu : rien ne part non plus'
    $op=Test-DomeniaWriteAdmission $reg $p Operator
    Assert-False $op.Admit 'Une demande incertaine identique attend la verification';Assert-True ($op.Reason -match 'vérification')
    Assert-False (Set-DomeniaWriteOutcome $reg $p.Fingerprint 'NotSent').Accepted 'Une incertitude ne devient pas non envoyee'
    Assert-False (Set-DomeniaWriteOutcome $reg $p.Fingerprint 'Failed' -ControllerResultCode 50).Accepted 'Une incertitude ne devient pas un echec'
    Assert-True (Set-DomeniaWriteOutcome $reg $p.Fingerprint 'Verified').Accepted
    Assert-True (Test-DomeniaWriteAdmission $reg (& $script:SfPlan $target) Operator).Admit 'Nouvelle confirmation explicite apres verification'
}
Test-Case 'D095' 'Un echec apres envoi n est certain que sur refus prouve du controleur' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=& $script:SfPlan $target
    $reg=New-DomeniaWriteRegistry
    $a=Test-DomeniaWriteAdmission $reg $p Operator;Assert-True $a.Admit;Assert-True $a.Reserved
    Assert-True (Set-DomeniaWriteOutcome $reg $a.Key 'Sent').Accepted
    Assert-False (Set-DomeniaWriteOutcome $reg $a.Key 'NotSent').Accepted 'Une demande envoyee ne redevient pas non envoyee'
    $f=Set-DomeniaWriteOutcome $reg $a.Key 'Failed'
    Assert-False $f.Accepted 'Echec du processus apres envoi : rien n est prouve';Assert-True ($f.Reason -match 'a pu sʼappliquer');Assert-Equal 'Sent' $f.State
    Assert-False (Set-DomeniaWriteOutcome $reg $a.Key 'Failed' -ControllerResultCode 85).Accepted 'Delai depasse cote client'
    Assert-False (Set-DomeniaWriteOutcome $reg $a.Key 'Failed' -ControllerResultCode 0).Accepted 'Code de succes'
    Assert-False (Test-DomeniaWriteAdmission $reg (& $script:SfPlan $target) Operator).Admit 'Sans preuve, aucune nouvelle demande identique'
    Assert-True (Set-DomeniaWriteOutcome $reg $a.Key 'Failed' -ControllerResultCode 50).Accepted 'Refus du controleur prouve par son code'
    Assert-False (Set-DomeniaWriteOutcome $reg $a.Key 'Verified').Accepted 'Une issue resolue reste resolue'
    Assert-False (Test-DomeniaWriteAdmission $reg $p Operator).Admit 'Le meme plan ne repart pas'
    Assert-True (Test-DomeniaWriteAdmission $reg (& $script:SfPlan $target) Operator).Admit 'Nouvelle confirmation apres un refus certain'
    $other=& $script:SfPlan (& $script:SfId $script:SfGuidB $script:SfDnB)
    $k=(Test-DomeniaWriteAdmission $reg $other Operator).Key
    Assert-True (Set-DomeniaWriteOutcome $reg $k 'Failed').Accepted 'Jamais envoyee : echec certain'
    $pc=& $script:SfId $script:SfPcA 'CN=PC-01,OU=Postes,DC=example,DC=test' 'PC-01' 1 1 'Ordinateur'
    $restart=New-DomeniaInterventionPlan -OperationId 'ComputerRestart' -Target $pc -Server 'PC-01' -Account 'EX\adm' -Effects @('Redemarrage')
    $rk=(Test-DomeniaWriteAdmission $reg $restart Operator).Key
    Assert-True (Set-DomeniaWriteOutcome $reg $rk 'Sent').Accepted
    Assert-False (Set-DomeniaWriteOutcome $reg $rk 'Failed' -ControllerResultCode 50).Accepted 'Action distante envoyee : jamais un echec certain'
    $read=New-DomeniaInterventionPlan -OperationId 'OpenAdObject' -Target $target -Account 'EX\lecteur'
    $r1=Test-DomeniaWriteAdmission $reg $read Operator;$r2=Test-DomeniaWriteAdmission $reg $read AutoRetry
    Assert-True $r1.Admit;Assert-True $r2.Admit;Assert-True $r2.Retryable
}

Test-Case 'D096' 'Texte mono-value : retrait de l ancienne valeur et ajout de la nouvelle dans la meme requete' {
    $s=Get-DomeniaAtomicStrategy -Attribute 'description' -Before 'Compta' -After 'Paie'
    Assert-Equal 'ConditionalReplace' $s.Strategy;Assert-True $s.Atomic;Assert-True $s.SingleRequest
    Assert-Equal 2 $s.Operations.Count;Assert-Equal 'Delete' $s.Operations[0].Op;Assert-Equal 'Compta' $s.Operations[0].Value;Assert-Equal 'Add' $s.Operations[1].Op;Assert-Equal 'Paie' $s.Operations[1].Value
    Assert-True (@($s.ConflictCodes) -contains 16)
    Assert-Equal 'ConditionalAdd' (Get-DomeniaAtomicStrategy -Attribute 'description' -Before '' -After 'Paie').Strategy
    Assert-Equal 'ConditionalDelete' (Get-DomeniaAtomicStrategy -Attribute 'description' -Before 'Compta' -After '').Strategy
    Assert-Equal 'NoChange' (Get-DomeniaAtomicStrategy -Attribute 'description' -Before 'X' -After 'X').Strategy
}
Test-Case 'D096' 'Sans condition atomique : relecture avant et apres, limite exposee, aucune transaction promise' {
    $cases=@((Get-DomeniaAtomicStrategy -Attribute 'otherTelephone' -SingleValued $false -Before 'a' -After 'b'),(Get-DomeniaAtomicStrategy -Attribute 'accountExpires' -Syntax Integer -Before '1' -After '2'),(Get-DomeniaAtomicStrategy -Attribute 'title' -ConditionalSupported $false -Before 'a' -After 'b'))
    foreach($s in $cases){
        Assert-Equal 'ReadBeforeAfter' $s.Strategy;Assert-False $s.Atomic;Assert-True $s.PreRead;Assert-True $s.PostRead
        Assert-True ($s.Limit -match 'pas empêchée');Assert-True ($s.TransactionLimit -match 'Aucune transaction')
    }
    Assert-Equal 'NotApplicable' (Get-DomeniaAtomicStrategy -Attribute 'unicodePwd' -Before '' -After 'x').Strategy
}
Test-Case 'D096' 'Une modification externe n est pas ecrasee silencieusement' {
    $pre=Test-DomeniaPreconditionCurrent -Changes $script:SfChanges -Current @{description=@('Achats');telephoneNumber=@('0102')} -Server 'DC01'
    Assert-False $pre.Current;Assert-Equal 1 $pre.Conflicts.Count;Assert-Equal 'description' $pre.Conflicts[0].Attribute;Assert-True ($pre.Text -match 'rien nʼest écrasé')
    Assert-True (Test-DomeniaPreconditionCurrent -Changes $script:SfChanges -Current @{description='Compta';telephoneNumber='0102'}).Current
    Assert-False (Test-DomeniaPreconditionCurrent -Changes $script:SfChanges -Current $null).Current 'Sans relecture rien ne part'
    $member=@([pscustomobject]@{Attribute='member';Kind='Add';After='CN=Jean,OU=U,DC=example,DC=test'})
    Assert-False (Test-DomeniaPreconditionCurrent -Changes $member -Current @{member=@('cn=jean,ou=u,dc=example,dc=test')}).Current 'Deja ajoute par un autre administrateur'
    $s=Get-DomeniaAtomicStrategy -Attribute 'description' -Before 'Compta' -After 'Paie'
    $c=Resolve-DomeniaConditionalWrite $s 16;Assert-Equal 'Conflict' $c.Outcome;Assert-False $c.OverwroteExternalChange
    $rb=Get-DomeniaAtomicStrategy -Attribute 'accountExpires' -Syntax Integer -Before '1' -After '2'
    $j=Resolve-DomeniaConditionalWrite $rb 0 4 6;Assert-Equal 'ConcurrentWriteSuspected' $j.Outcome;Assert-True $j.OverwroteExternalChange
    Assert-Equal 'Applied' (Resolve-DomeniaConditionalWrite $rb 0 4 5).Outcome
    $u=Resolve-DomeniaConditionalWrite $rb 0;Assert-Equal 'AppliedUnchecked' $u.Outcome;Assert-True ($u.Text -match 'non détectable')
}
Test-Case 'D096' 'Precondition non relue ou reponse absente : rien n est envoye ni annonce applique' {
    $member=@([pscustomobject]@{Attribute='member';Kind='Add';After='CN=Jean,OU=U,DC=example,DC=test'})
    $pre=Test-DomeniaPreconditionCurrent -Changes $member -Current @{} -Server 'DC01'
    Assert-False $pre.Current 'Attribut absent de la relecture';Assert-Equal 'member' @($pre.Unread)[0];Assert-True ($pre.Text -match 'non relues');Assert-Equal 0 $pre.Conflicts.Count
    Assert-True (Test-DomeniaPreconditionCurrent -Changes $member -Current @{member=@()}).Current 'Liste vide relue explicitement'
    $add=@([pscustomobject]@{Name='description';Old='';New='Paie'})
    Assert-False (Test-DomeniaPreconditionCurrent -Changes $add -Current @{telephoneNumber='0102'}).Current 'Valeur vide supposee'
    Assert-True (Test-DomeniaPreconditionCurrent -Changes $add -Current @{description=$null}).Current 'Valeur vide relue explicitement'
    $meta=@((Get-Command Resolve-DomeniaConditionalWrite).Parameters['ResultCode'].Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })
    Assert-True (@($meta | Where-Object { $_.Mandatory }).Count -gt 0) 'Le code du controleur est obligatoire'
    $s=Get-DomeniaAtomicStrategy -Attribute 'description' -Before 'Compta' -After 'Paie'
    $lost=Resolve-DomeniaConditionalWrite $s 85
    Assert-Equal 'Unknown' $lost.Outcome 'Delai depasse cote client';Assert-True ($lost.Text -match 'a pu sʼappliquer');Assert-False ($lost.Text -match 'refusée')
    Assert-Equal 'Unknown' (Resolve-DomeniaConditionalWrite (Get-DomeniaAtomicStrategy -Attribute 'accountExpires' -Syntax Integer -Before '1' -After '2') 81).Outcome 'Serveur injoignable'
    Assert-Equal 'Error' (Resolve-DomeniaConditionalWrite $s 50).Outcome 'Refus du controleur'
}

Test-Case 'D097' 'Une ecriture incertaine bloque les ecritures et l edition de sa cible seulement' {
    $locks=@(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('c'*32);Operation='WriteAttributes';Stage='Unknown';Guid=$script:SfGuidA;DN=$script:SfDnA}))
    Assert-Equal 1 $locks.Count;Assert-Equal 'Uncertain' $locks[0].State
    $w=Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidA) $locks
    Assert-False $w.Allowed;Assert-True ($w.Reason -match 'Les lectures restent possibles')
    Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfDnA.ToUpperInvariant()) $locks -Action Edit).Allowed 'Edition bloquee, cible donnee par DN'
    Assert-True (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidB,$script:SfDnB) $locks).Allowed 'Une autre cible reste modifiable'
    Assert-True (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidB) $locks -Action Edit).Allowed
}
Test-Case 'D097' 'Les lectures restent possibles sur la cible incertaine comme sur les autres' {
    $locks=@(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('c'*32);Operation='WriteAttributes';Stage='Sent';Guid=$script:SfGuidA;DN=$script:SfDnA}))
    foreach($op in @('OpenAdObject','GlobalSearch','ReadLaps','SessionsList')){
        Assert-True (Test-DomeniaOperationAllowed $op @($script:SfGuidA) $locks).Allowed ($op+' sur la cible')
        Assert-True (Test-DomeniaOperationAllowed $op @($script:SfGuidB) $locks).Allowed ($op+' ailleurs')
    }
    $running=New-DomeniaOperationLock 'WriteGroupMember' @($script:SfGuidA) Running
    Assert-True (Test-DomeniaOperationAllowed 'OpenAdObject' @($script:SfGuidB) @($running)).Allowed 'Une ecriture en cours ne bloque pas les lectures'
    Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidB) @($running)).Allowed 'Ecritures une par une'
    Assert-True ([bool](Test-DomeniaOperationAllowed 'OpenAdObject' @($script:SfGuidA) @($running)).Note)
}
Test-Case 'D097' 'Cible inconnue : verrou prudent sur les ecritures, jamais sur les lectures' {
    $locks=@(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('d'*32);Operation='WriteAttributes';Stage='Unknown'}))
    Assert-Equal '*' @($locks[0].Targets)[0]
    Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidB) $locks).Allowed
    Assert-True (Test-DomeniaOperationAllowed 'GlobalSearch' @() $locks).Allowed
    Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @() @()).Allowed 'Modification sans cible refusee'
    Assert-Equal 0 @(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('e'*32);Operation='WriteAttributes';Stage='Verified';Guid=$script:SfGuidA})).Count
    $byName=New-DomeniaOperationLock 'WriteAttributes' @('Jean Dupont') Uncertain
    Assert-Equal '*' @($byName.Targets)[0] 'Verrou sur une cible non reconnue : toutes les cibles'
    $readReceipt=@(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('f'*32);Operation='OpenAdObject';Stage='Sent';Guid=$script:SfGuidA}))
    Assert-Equal 'Write' $readReceipt[0].Class 'Un recu incertain reste un verrou d ecriture'
}
Test-Case 'D097' 'Cible donnee par identite, nom ou prefixe : jamais d ouverture par defaut' {
    $identity=& $script:SfId $script:SfGuidA $script:SfDnA
    $locks=@(Get-DomeniaReceiptLocks @([pscustomobject]@{Id=('c'*32);Operation='WriteAttributes';Stage='Unknown';Guid=$script:SfGuidA;DN=$script:SfDnA}))
    $r=Test-DomeniaOperationAllowed 'WriteAttributes' @($identity) $locks
    Assert-False $r.Allowed 'Identite d une cible verrouillee'
    $keys=@((Resolve-DomeniaTargetKeys @($identity)).Keys)
    Assert-Equal 2 $keys.Count;Assert-True ($keys -contains ('guid:'+$script:SfGuidA));Assert-True ($keys -contains 'dn:cn=jean dupont,ou=utilisateurs,dc=example,dc=test')
    Assert-True (Test-DomeniaOperationAllowed 'WriteAttributes' @((& $script:SfId $script:SfGuidB $script:SfDnB)) $locks).Allowed 'Identite d une autre cible'
    foreach($bad in @('Jean Dupont','S-1-5-21-1-2-3-1105','jdupont',[string]$identity)){
        $x=Test-DomeniaOperationAllowed 'WriteAttributes' @($bad) @()
        Assert-False $x.Allowed $bad;Assert-True ($x.Reason -match 'Cible non reconnue') $bad
    }
    Assert-True (Test-DomeniaOperationAllowed 'OpenAdObject' @('Jean Dupont') $locks).Allowed 'Une lecture n est jamais bloquee'
    Assert-Equal 1 @((Resolve-DomeniaTargetKeys @('dn:CN=X, DC=Y','DN:cn=x,dc=y','cn = X,dc=Y')).Keys).Count 'Prefixes et espaces normalises'
    Assert-Equal ('guid:'+$script:SfGuidA) @((Resolve-DomeniaTargetKeys @('GUID:'+$script:SfGuidA.ToUpperInvariant())).Keys)[0]
    $guidOnly=New-DomeniaOperationLock 'WriteAttributes' @($script:SfGuidA) Uncertain
    $dnOnly=Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfDnB) @($guidOnly)
    Assert-False $dnOnly.Allowed 'DN seul face a un verrou par GUID';Assert-True ($dnOnly.Reason -match 'sans GUID')
    Assert-True (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfGuidB) @($guidOnly)).Allowed 'Autre GUID : autre objet'
}
Test-Case 'D097' 'Une mutation en cours ou incertaine bloque toute mutation de sa cible, jamais les lectures' {
    foreach($lockOp in @('WriteRenameComputer','RimotteRun')){
        foreach($state in @('Running','Uncertain')){
            $lock=New-DomeniaOperationLock $lockOp @($script:SfPcA) $state
            $tag=$lockOp+' '+$state+' : '
            foreach($op in @('ComputerRestart','ComputerGpUpdate','WakeOnLanSend','RimotteRun','WriteDeleteObject','WriteAttributes')){
                Assert-False (Test-DomeniaOperationAllowed $op @($script:SfPcA) @($lock)).Allowed ($tag+$op)
            }
            Assert-False (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfPcA) @($lock) -Action Edit).Allowed ($tag+'edition')
            foreach($op in @('ComputerInventory','OpenAdObject','LocalStore')){ Assert-True (Test-DomeniaOperationAllowed $op @($script:SfPcA) @($lock)).Allowed ($tag+$op) }
            foreach($op in @('ComputerRestart','RimotteRun')){ Assert-True (Test-DomeniaOperationAllowed $op @($script:SfPcB) @($lock)).Allowed ($tag+$op+' ailleurs') }
            Assert-True (Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfPcB) @($lock) -Action Edit).Allowed ($tag+'edition ailleurs')
            $serial=(Test-DomeniaOperationAllowed 'WriteAttributes' @($script:SfPcB) @($lock)).Allowed
            Assert-Equal (-not (($lockOp -like 'Write*') -and ($state -eq 'Running'))) $serial ($tag+'ecriture ailleurs')
        }
    }
}

Test-Case 'D100' 'Aucune annulation universelle : une compensation porte sur une seule operation AD' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $all=Get-DomeniaCompensation @((& $script:SfPlan $target),(& $script:SfPlan $target)) 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description='Paie';telephoneNumber='0103'}})
    Assert-False $all.Offered;Assert-True ($all.Reason -match 'annulation globale')
    $one=Get-DomeniaCompensation (& $script:SfPlan $target) 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description='Paie';telephoneNumber='0103'}})
    Assert-True $one.Offered $one.Reason;Assert-True ($one.NotCovered -match 'cache');Assert-Equal 'Annuaire' $one.Scope;Assert-False $one.Automatic
}
Test-Case 'D100' 'Un mot de passe change ou une suppression ne sont jamais presentes comme restaurables' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $current=[pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;DN=$script:SfDnA;Values=@{unicodePwd=$null}}
    $reset=New-DomeniaInterventionPlan -OperationId 'WriteResetPassword' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';Kind='Reset';New='MARQUEUR'})
    $c=Get-DomeniaCompensation $reset 'Verifie' $current
    Assert-False $c.Offered;Assert-True ($c.Reason -match 'pas restaurable');Assert-Equal 0 @($c.Changes).Count
    $viaAttr=New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='unicodePwd';Old='';New='MARQUEUR'})
    $v=Get-DomeniaCompensation $viaAttr 'Verifie' $current
    Assert-False $v.Offered 'Secret ecrit par attribut';Assert-True ($v.Reason -match 'pas restaurable')
    $del=New-DomeniaInterventionPlan -OperationId 'WriteDeleteObject' -Target $target -Server 'DC01' -Account 'EX\adm' -Effects @('Suppression')
    Assert-False (Get-DomeniaCompensation $del 'Verifie' $current).Offered 'Suppression'
    $restart=New-DomeniaInterventionPlan -OperationId 'ComputerRestart' -Target $target -Server 'PC-01' -Account 'EX\adm' -Effects @('Redemarrage')
    Assert-False (Get-DomeniaCompensation $restart 'Verifie' $current).Offered 'Action distante'
}
Test-Case 'D100' 'Compensation proposee seulement si ses preconditions restent verifiables' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $p=New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='description';Old='Compta';New='Paie'})
    $ok=Get-DomeniaCompensation $p 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description='Paie'}})
    Assert-True $ok.Offered;Assert-Equal 'Paie' $ok.Changes[0].Before;Assert-Equal 'Compta' $ok.Changes[0].After
    Assert-False (Get-DomeniaCompensation $p 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description='Achats'}})).Offered 'Une valeur changee depuis n est pas ecrasee'
    Assert-False (Get-DomeniaCompensation $p 'Verifie' ([pscustomobject]@{ReadStatus='Refused';Guid=$script:SfGuidA})).Offered 'Preconditions non verifiables'
    Assert-False (Get-DomeniaCompensation $p 'Verifie' $null).Offered 'Sans relecture'
    Assert-False (Get-DomeniaCompensation $p 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidB;Values=@{description='Paie'}})).Offered 'Autre objet'
    Assert-False (Get-DomeniaCompensation $p 'A verifier' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description='Paie'}})).Offered 'Issue d origine incertaine'
}
Test-Case 'D100' 'Une precondition non relue n est jamais prise pour une valeur vide' {
    $target=& $script:SfId $script:SfGuidA $script:SfDnA
    $clear=New-DomeniaInterventionPlan -OperationId 'WriteAttributes' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='description';Old='Compta';Clear=$true})
    $c=Get-DomeniaCompensation $clear 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA})
    Assert-False $c.Offered 'Relecture sans Values';Assert-True ($c.Reason -match 'non relue');Assert-Equal 'non relu' $c.Preconditions[0].Observed
    Assert-False (Get-DomeniaCompensation $clear 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{title='x'}})).Offered 'Attribut absent de Values'
    $ok=Get-DomeniaCompensation $clear 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{description=$null}})
    Assert-True $ok.Offered ('Valeur vide relue explicitement : '+$ok.Reason);Assert-Equal 'Compta' $ok.Changes[0].After
    $mv=New-DomeniaInterventionPlan -OperationId 'WriteMoveObject' -Target $target -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='distinguishedName';Kind='Move';Old=$script:SfDnA;New=$script:SfDnB})
    $nodn=Get-DomeniaCompensation $mv 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;OriginalParentExists=$true})
    Assert-False $nodn.Offered 'Emplacement non relu';Assert-True ($nodn.Reason -match 'non relue')
}
Test-Case 'D100' 'Appartenance et deplacement : inverse exact, conteneur d origine verifie' {
    $group=& $script:SfId $script:SfGuidA 'CN=Comptables,OU=Groupes,DC=example,DC=test' 'Comptables' 1 1 'Groupe'
    $g=New-DomeniaInterventionPlan -OperationId 'WriteGroupMember' -Target $group -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='member';Kind='Add';New='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=test'})
    $c=Get-DomeniaCompensation $g 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;Values=@{member=@('cn=jean dupont,ou=utilisateurs,dc=example,dc=test')}})
    Assert-True $c.Offered ('DN relu dans une autre casse : '+$c.Reason);Assert-Equal 'Remove' $c.Changes[0].Kind
    $mv=New-DomeniaInterventionPlan -OperationId 'WriteMoveObject' -Target (& $script:SfId $script:SfGuidA $script:SfDnA) -Server 'DC01' -Account 'EX\adm' -Changes @([pscustomobject]@{Name='distinguishedName';Kind='Move';Old=$script:SfDnA;New=$script:SfDnB})
    $back=Get-DomeniaCompensation $mv 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;DN=$script:SfDnB;OriginalParentExists=$true})
    Assert-True $back.Offered;Assert-Equal 'Move' $back.Changes[0].Kind;Assert-Equal $script:SfDnA $back.Changes[0].After
    Assert-False (Get-DomeniaCompensation $mv 'Verifie' ([pscustomobject]@{ReadStatus='OK';Guid=$script:SfGuidA;DN=$script:SfDnB;OriginalParentExists=$false})).Offered 'Conteneur d origine non verifie'
}

Test-Case 'SE-02' 'Ecriture brute : meme regle que le worker, configuration et liste bloquee respectees' {
    $list=@('unicodePwd','adminCount','userAccountControl')
    $off=Test-DomeniaRawAttributeAllowed -Attribute 'info' -AllowRaw $false -BlockSensitive $true -BlockList $list
    Assert-False $off.Allowed 'Ecriture brute desactivee';Assert-True ($off.Reason -match 'AllowRawAttributeWrite')
    Assert-True (Test-DomeniaRawAttributeAllowed -Attribute 'info' -AllowRaw $true -BlockSensitive $true -BlockList $list).Allowed
    $blocked=Test-DomeniaRawAttributeAllowed -Attribute 'ADMINCOUNT' -AllowRaw $true -BlockSensitive $true -BlockList $list
    Assert-False $blocked.Allowed 'Liste bloquee insensible a la casse';Assert-True ($blocked.Reason -match 'sensible')
    Assert-True (Test-DomeniaRawAttributeAllowed -Attribute 'adminCount' -AllowRaw $true -BlockSensitive $false -BlockList $list).Allowed 'BlockSensitiveRawAttributes desactive : la liste ne bloque plus'
    Assert-False (Test-DomeniaRawAttributeAllowed -Attribute 'info;range=0-1' -AllowRaw $true).Allowed 'Nom invalide'
    Assert-False (Test-DomeniaRawAttributeAllowed -Attribute '' -AllowRaw $true).Allowed 'Nom vide'
}
Test-Case 'SE-12' 'DN saisi : syntaxe, domaine connecte et partitions de configuration controles avant envoi' {
    $base='DC=example,DC=test'
    $ok=Test-DomeniaWriteTargetDn -Dn 'CN=Comptables, OU=Groupes,DC=Example,DC=Test' -BaseDn $base
    Assert-True $ok.Valid $ok.Reason;Assert-Equal 'Comptables' $ok.Name
    Assert-True (Test-DomeniaWriteTargetDn -Dn 'DC=example,DC=test' -BaseDn $base).Valid 'Racine du domaine'
    $out=Test-DomeniaWriteTargetDn -Dn 'CN=Admins,OU=Groupes,DC=autre,DC=test' -BaseDn $base
    Assert-False $out.Valid 'Hors domaine';Assert-True ($out.Reason -match 'hors du domaine');Assert-True ($out.Reason -match 'Admins')
    Assert-False ($out.Reason -match 'DC=autre') 'Le refus nomme la cible, pas son DN'
    foreach($dn in @('CN=Services,CN=Configuration,DC=example,DC=test','CN=Schema,CN=Configuration,DC=example,DC=test','DC=example.test,CN=MicrosoftDNS,DC=DomainDnsZones,DC=example,DC=test','CN=x,DC=ForestDnsZones,DC=example,DC=test')){
        $r=Test-DomeniaWriteTargetDn -Dn $dn -BaseDn $base
        Assert-False $r.Valid $dn;Assert-True ($r.Reason -match 'configuration de la for') $dn
    }
    Assert-Equal 'Services' (Test-DomeniaWriteTargetDn -Dn 'CN=Services,CN=Configuration,DC=example,DC=test' -BaseDn $base).Name
    Assert-False (Test-DomeniaWriteTargetDn -Dn 'CN=x\,DC=example,DC=test' -BaseDn $base).Valid 'Virgule echappee : DC=example appartient au premier nom'
    Assert-False (Test-DomeniaWriteTargetDn -Dn 'CN=,OU=Groupes,DC=example,DC=test' -BaseDn $base).Valid 'Valeur vide'
    Assert-False (Test-DomeniaWriteTargetDn -Dn 'Comptables' -BaseDn $base).Valid 'Pas un DN'
    Assert-False (Test-DomeniaWriteTargetDn -Dn 'CN=x,DC=example,DC=test' -BaseDn '').Valid 'Domaine inconnu'
    Assert-Equal ([string][char]0xC9+'quipe, Paris') (Test-DomeniaWriteTargetDn -Dn 'CN=\C3\89quipe\, Paris,OU=G,DC=example,DC=test' -BaseDn $base).Name 'Nom lisible decode'
}
Test-Case 'UX-08' 'Avant et apres en clair : ni DN ni GUID, aucun secret' {
    $changes=@(
        [pscustomobject]@{Attribute='userAccountControl';Kind='Replace';Before='Active';After='Desactive'}
        [pscustomobject]@{Attribute='lockoutTime';Kind='Clear';Before='133000000000000000';After=''}
        [pscustomobject]@{Attribute='unicodePwd';Kind='Reset';Before='';After='MARQUEUR-SECRET'}
        [pscustomobject]@{Attribute='pwdLastSet';Kind='Replace';Before='133000000000000000';After='0'}
        [pscustomobject]@{Attribute='PasswordNeverExpires';Kind='Replace';Before='False';After='True'}
        [pscustomobject]@{Attribute='distinguishedName';Kind='Move';Before=$script:SfDnA;After=$script:SfDnB}
        [pscustomobject]@{Attribute='name';Kind='Move';Before='PC-01';After='PC-02'}
        [pscustomobject]@{Attribute='memberOf';Kind='Add';Before='';After='CN=Comptables,OU=Groupes,DC=example,DC=test'}
        [pscustomobject]@{Attribute='member';Kind='Remove';Before='CN=Jean Dupont,OU=Utilisateurs,DC=example,DC=test';After=''}
        [pscustomobject]@{Name='manager';Old='CN=Marie Curie,OU=Utilisateurs,DC=example,DC=test';New='';Clear=$true}
        [pscustomobject]@{Name='description';Old='';New=('Salle B'+[char]10+'2e etage')}
        [pscustomobject]@{Name='extensionAttribute1';Old=$script:SfGuidA;New='x'}
    )
    $lines=@(Get-DomeniaPlanChangeText -Changes $changes)
    Assert-Equal 12 $lines.Count ($lines -join ' | ')
    $arrow=' '+[string][char]0x2192+' '
    $e=[string][char]0xE9
    Assert-Equal ('Compte : actif'+$arrow+'d'+$e+'sactiv'+$e) $lines[0];Assert-Equal ('Compte : verrouill'+$e+$arrow+'d'+$e+'verrouill'+$e) $lines[1]
    Assert-True ($lines[2] -match '^Mot de passe : remplac') $lines[2];Assert-True ($lines[3] -match 'prochaine connexion : impos') $lines[3]
    Assert-Equal ('Mot de passe sans expiration : non'+$arrow+'oui') $lines[4]
    Assert-Equal ('Emplacement : '+[char]0xAB+' example.test / Utilisateurs '+[char]0xBB+$arrow+[char]0xAB+' example.test / Anciens '+[char]0xBB) $lines[5]
    Assert-Equal ('Nom : '+[char]0xAB+' PC-01 '+[char]0xBB+$arrow+[char]0xAB+' PC-02 '+[char]0xBB) $lines[6]
    Assert-Equal ('Groupes : ajout '+[char]0xE0+' '+[char]0xAB+' Comptables '+[char]0xBB) $lines[7]
    Assert-Equal ('Membres : retrait de '+[char]0xAB+' Jean Dupont '+[char]0xBB) $lines[8]
    Assert-Equal ('Responsable : '+[char]0xAB+' Marie Curie '+[char]0xBB+$arrow+'(vide)') $lines[9]
    Assert-Equal ('Description : (vide)'+$arrow+[char]0xAB+' Salle B 2e etage '+[char]0xBB) $lines[10]
    Assert-True ($lines[11] -match '^extensionAttribute1 : ') 'Attribut sans libelle : nom technique conserve'
    $all=$lines -join ' '
    Assert-False ($all -match '(?i)\b(CN|OU|DC)\s*=') 'Un DN apparait'
    Assert-False ($all -match 'MARQUEUR') 'Secret visible'
    Assert-False ($all -match '(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') 'Un GUID apparait hors des details techniques'
}
# Point 49 : relecture ulterieure d une ecriture incertaine. Etat attendu sans secret, decision par la seule relecture.
Test-Case 'P49' 'Etat attendu garde par le recu pour chaque ecriture, jamais un secret' {
    $marker=[guid]::NewGuid().ToString('N')
    $secure=New-Object Security.SecureString;foreach($c in $marker.ToCharArray()){$secure.AppendChar($c)}
    $reset=Get-DomeniaReceiptExpectation 'WriteResetPassword' ([pscustomobject]@{DN=$script:SfDnA;SecurePassword=$secure;MustChange=$false;Unlock=$false})
    Assert-Equal 'PasswordChangedAfterSend' $reset.Kind
    Assert-False (($reset|ConvertTo-Json -Depth 4 -Compress).Contains($marker)) 'Le mot de passe entre dans le recu'
    Assert-Equal 'PwdLastSetZero' (Get-DomeniaReceiptExpectation 'WriteResetPassword' ([pscustomobject]@{SecurePassword=$secure;MustChange=$true})).Kind
    $disabled=Get-DomeniaReceiptExpectation 'WriteAccountDisabled' ([pscustomobject]@{Disabled=$true})
    Assert-Equal 'UacFlags' $disabled.Kind;Assert-Equal 2 ([int]$disabled.Flags[0].Mask);Assert-True ([bool]$disabled.Flags[0].Set)
    $options=Get-DomeniaReceiptExpectation 'WriteAccountOptions' ([pscustomobject]@{TargetUac=66048;Masks=[pscustomobject]@{PasswordNeverExpires=65536;PasswordNotRequired=32}})
    Assert-Equal 2 @($options.Flags).Count;Assert-True ([bool]($options.Flags|Where-Object{$_.Name -eq 'PasswordNeverExpires'}).Set);Assert-False ([bool]($options.Flags|Where-Object{$_.Name -eq 'PasswordNotRequired'}).Set)
    Assert-Equal '2026-11-01' (Get-DomeniaReceiptExpectation 'WriteExpiration' ([pscustomobject]@{Never=$false;Date='2026-11-01T00:00:00.0000000'})).Day
    Assert-Equal 'Jamais' (Get-DomeniaReceiptExpectation 'WriteExpiration' ([pscustomobject]@{Never=$true;Date=''})).Day
    Assert-Equal 'Parent' (Get-DomeniaReceiptExpectation 'WriteMoveObject' ([pscustomobject]@{TargetDn='OU=Anciens,DC=example,DC=test'})).Kind
    Assert-Equal 'Name' (Get-DomeniaReceiptExpectation 'WriteRenameComputer' ([pscustomobject]@{NewName='PC-02'})).Kind
    $member=Get-DomeniaReceiptExpectation 'WriteGroupMember' ([pscustomobject]@{GroupDn='CN=G,DC=example,DC=test';ObjectValue='jdupont';Add=$true})
    Assert-Equal 'Membership' $member.Kind;Assert-True ([bool]$member.Member);Assert-Equal 'jdupont' $member.MemberValue
    Assert-Equal 'Existence' (Get-DomeniaReceiptExpectation 'WriteCreateOu' ([pscustomobject]@{ParentDn='DC=example,DC=test';Name='Paie'})).Kind
    Assert-Equal 'Absence' (Get-DomeniaReceiptExpectation 'WriteDeleteObject' ([pscustomobject]@{DN=$script:SfDnA})).Kind
    Assert-True ($null -eq (Get-DomeniaReceiptExpectation 'RimotteRun' ([pscustomobject]@{}))) 'Regle inventee pour une action distante'
    Assert-True ($null -eq (Get-DomeniaReceiptExpectation 'WriteMoveObject' ([pscustomobject]@{TargetDn=''}))) 'Cible absente acceptee'
}
Test-Case 'P49' 'Decision par la relecture seule : conforme, contraire, refusee ou incomplete' {
    $ok=[pscustomobject]@{ReadStatus='OK'}
    $flag=[pscustomobject]@{Kind='UacFlags';Flags=@([pscustomobject]@{Name='ACCOUNTDISABLE';Mask=2;Set=$true})}
    Assert-True (Resolve-DomeniaReceiptCheck $flag ([pscustomobject]@{ReadStatus='OK';Uac='514'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck $flag ([pscustomobject]@{ReadStatus='OK';Uac='512'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck $flag ([pscustomobject]@{ReadStatus='Refused';Uac='514'})).Verified 'Un refus de lecture devient une preuve'
    Assert-False (Resolve-DomeniaReceiptCheck $flag ([pscustomobject]@{ReadStatus='OK';Uac=''})).Verified 'Valeur non relue acceptee'
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Unlocked'}) ([pscustomobject]@{ReadStatus='OK';Lockout='0'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Unlocked'}) ([pscustomobject]@{ReadStatus='OK';Lockout='133000000000000000'})).Verified
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='PwdLastSetZero'}) ([pscustomobject]@{ReadStatus='OK';PwdLastSet='0'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='PwdLastSetZero'}) ([pscustomobject]@{ReadStatus='OK';PwdLastSet=''})).Verified 'pwdLastSet non relu pris pour 0'
    $sent=$script:SfNow.ToString('o')
    $after=[string]$script:SfNow.AddMinutes(1).ToFileTimeUtc();$before=[string]$script:SfNow.AddHours(-2).ToFileTimeUtc()
    $change=[pscustomobject]@{Kind='PasswordChangedAfterSend'}
    Assert-True (Resolve-DomeniaReceiptCheck $change ([pscustomobject]@{ReadStatus='OK';PwdLastSet=$after}) $sent).Verified
    Assert-False (Resolve-DomeniaReceiptCheck $change ([pscustomobject]@{ReadStatus='OK';PwdLastSet=$before}) $sent).Verified
    Assert-False (Resolve-DomeniaReceiptCheck $change ([pscustomobject]@{ReadStatus='OK';PwdLastSet=$after}) '').Verified 'Heure d envoi absente acceptee'
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='AccountExpires';Day='2026-11-01'}) ([pscustomobject]@{ReadStatus='OK';AccountExpiresDay='2026-11-01'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='AccountExpires';Day='Jamais'}) ([pscustomobject]@{ReadStatus='OK';AccountExpiresDay='2026-11-01'})).Verified
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Parent';ParentDn='OU=Anciens,DC=example,DC=test'}) ([pscustomobject]@{ReadStatus='OK';ParentDn='ou=anciens,dc=example,dc=test'})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Parent';ParentDn='OU=Anciens,DC=example,DC=test'}) ([pscustomobject]@{ReadStatus='OK';ParentDn=''})).Verified
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Membership';Member=$false}) ([pscustomobject]@{ReadStatus='OK';Member=$false})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Membership';Member=$true}) ([pscustomobject]@{ReadStatus='OK';Member=$null})).Verified 'Appartenance non relue acceptee'
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Absence'}) ([pscustomobject]@{ReadStatus='OK';Exists=$false})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Absence'}) ([pscustomobject]@{ReadStatus='OK';Exists=$null})).Verified 'Absence supposee sans reponse'
    Assert-False (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Absence'}) ([pscustomobject]@{ReadStatus='Refused';Exists=$false})).Verified 'Refus pris pour une absence'
    Assert-True (Resolve-DomeniaReceiptCheck ([pscustomobject]@{Kind='Existence'}) ([pscustomobject]@{ReadStatus='OK';Exists=$true})).Verified
    Assert-False (Resolve-DomeniaReceiptCheck $null $ok).Verified 'Operation sans regle verifiee'
}
