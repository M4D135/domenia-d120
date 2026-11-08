# D104 : compte rendu de ticket relisible, seule partie des regles Insight conservee (L07, SE-09 du 08/10/2026 :
# les autres regles D101-D110, jamais appelees par l application, sont retirees avec leurs tests). Donnees fictives
# et marqueurs secrets factices uniquement : aucun reseau. Le ticket s appuie sur les regles pures du support.
# Guard.Model stays loaded here as before: the rule files that follow may rely on it.
. (Join-Path $modules 'Domenia-Guard.Model.ps1')
. (Join-Path $modules 'Domenia-Support.Model.ps1')
$script:IN0=[datetime]::SpecifyKind([datetime]'2026-03-01T12:00:00',[DateTimeKind]::Utc)
$script:IG1='0f8fad5b-d9cb-469f-a165-70867728950e'
$script:IG2='7c9e6679-7425-40de-944b-e07fc1f90ae7'
$script:IK1='cle-operateur-D104'
$script:IK2='autre-cle-operateur'
$script:ISM='SECRET_SENTINEL_D1XX'
$script:ITCtx=[pscustomobject]@{Guid=$script:IG1;Name='Jean Dupont';Type='Utilisateur';Aliases=@('jdupont')}
$script:ITSteps=@(
    [pscustomobject]@{TargetGuid=$script:IG1;Status='Confirmed';Label='Deverrouillage verifie par relecture';Reader='EX\support1';WhenUtc=$script:IN0.AddMinutes(-10)}
    [pscustomobject]@{TargetGuid=$script:IG1;Status='Sent';Label='GPUpdate envoye a PC-JDUPONT';Reader='EX\support1';WhenUtc=$script:IN0.AddMinutes(-9)}
    [pscustomobject]@{TargetGuid=$script:IG1;Status='AccessDenied';Label='Lecture LAPS';Detail='Dechiffrement refuse pour jdupont';Reader='EX\support1'}
    [pscustomobject]@{TargetGuid=$script:IG1;Status='NotTested';Label='Session RDP'}
    [pscustomobject]@{TargetGuid=$script:IG1;Status='Success';Label='Reinitialisation';Detail=('nouveau password='+$script:ISM)}
    [pscustomobject]@{TargetGuid=$script:IG1;Status='Confirmed';Label='Note';Detail=('valeur '+$script:ISM);Sensitive=$true}
    [pscustomobject]@{TargetGuid=$script:IG2;Status='Confirmed';Label=('Ouverture fiche voisine '+$script:ISM);Detail='hors perimetre'}
    [pscustomobject]@{Status='Confirmed';Label='Sans rattachement'}
)

Test-Case 'D104' 'Pseudonymes stables, lies a la cle de l operateur, refuses sans cle' {
    $a=ConvertTo-DomeniaPseudonym 'Jean Dupont' $script:IK1 'Utilisateur'
    Assert-True ($a -cmatch '^Utilisateur-[0-9A-F]{8}$') $a
    Assert-Equal $a (ConvertTo-DomeniaPseudonym 'JEAN DUPONT' $script:IK1 'Utilisateur') 'Stable et insensible a la casse'
    Assert-True ($a -cne (ConvertTo-DomeniaPseudonym 'Jean Dupont' $script:IK2 'Utilisateur')) 'Une autre cle donne un autre pseudonyme'
    Assert-True ($a -cne (ConvertTo-DomeniaPseudonym 'Jeanne Dupont' $script:IK1 'Utilisateur'));Assert-False ($a -match 'Jean|Dupont')
    Assert-Throws { ConvertTo-DomeniaPseudonym 'Jean Dupont' '' 'Utilisateur' } 'Sans cle'
    Assert-Throws { ConvertTo-DomeniaPseudonym 'Jean Dupont' 'court' 'Utilisateur' } 'Cle trop courte'
}
Test-Case 'D104' 'Le ticket classe tente, confirme, refuse et non teste ; un succes non verifie reste tente' {
    $r=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -NowUtc $script:IN0
    Assert-True $r.Ready;Assert-Equal 2 $r.Counts.Confirme;Assert-Equal 2 $r.Counts.Tente;Assert-Equal 1 $r.Counts.Refuse;Assert-Equal 1 $r.Counts.NonTeste
    Assert-True ($r.Text -match '\[TENTE \(sans confirmation\)\] 2');Assert-True ($r.Text -match 'GPUpdate envoye a PC-JDUPONT \(.*\) \[Envoye, issue non confirmee\]')
    Assert-True ($r.Text -match 'Reinitialisation \(date inconnue\) \[Issue non confirmee\]');Assert-False ($r.Text -match '(?i)reussi') 'Aucun reussi sur une issue incertaine'
    Assert-True $r.RequiresPreview;Assert-Equal 'Local' $r.Destination;Assert-False $r.MapInText
}
Test-Case 'D104' 'Rubriques selectionnables' {
    $r=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Sections @('Refuse') -NowUtc $script:IN0
    Assert-True ($r.Text -match '\[REFUSE\] 1');Assert-False ($r.Text -match '\[CONTEXTE\]|\[CONFIRME\]|\[TENTE|\[NON TESTE\]|\[LIMITES\]')
    Assert-False ($r.Text -match 'Deverrouillage') 'Une rubrique non choisie ne sort pas';Assert-Equal 'Refuse' (@($r.Sections) -join ',')
}
Test-Case 'D104' 'Ni secret ni objet hors contexte dans le ticket' {
    $r=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -NowUtc $script:IN0
    Assert-False ($r.Text -match $script:ISM) 'Marqueur secret absent';Assert-True ($r.Text -match 'detail sensible retire')
    Assert-False ($r.Text -match 'fiche voisine|hors perimetre|Sans rattachement') 'Objets hors contexte absents'
    Assert-Equal 1 $r.Excluded.AutreObjet;Assert-Equal 1 $r.Excluded.NonRattache;Assert-True ($r.Text -match '2 element\(s\) ecarte\(s\)')
    $none=New-DomeniaTicketReport -Context ([pscustomobject]@{Name='Sans guid'}) -Steps $script:ITSteps -NowUtc $script:IN0
    Assert-False $none.Ready;Assert-Equal '' $none.Text
}
Test-Case 'D104' 'Pseudonymisation controlable : cle, familles et table de correspondance hors du texte' {
    $r=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Pseudonymize $true -PseudonymKey $script:IK1 -NowUtc $script:IN0
    Assert-True $r.Ready;Assert-True $r.Pseudonymized;Assert-False $r.MapInText
    Assert-False ($r.Text -match 'Jean Dupont|jdupont|support1') 'Nom, alias et compte remplaces';Assert-False ($r.Text -match $script:IG1) 'GUID remplace'
    Assert-False ($r.Text -match [regex]::Escape($script:IK1)) 'La cle ne sort pas'
    Assert-True ($r.Text -match [regex]::Escape((ConvertTo-DomeniaPseudonym 'Jean Dupont' $script:IK1 'Utilisateur')))
    Assert-Equal 1 @($r.Map|Where-Object{$_.Original -eq 'jdupont'}).Count 'Table de correspondance pour l apercu local'
    Assert-Equal $r.Text (New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Pseudonymize $true -PseudonymKey $script:IK1 -NowUtc $script:IN0).Text 'Stable'
    Assert-True ($r.Text -cne (New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Pseudonymize $true -PseudonymKey $script:IK2 -NowUtc $script:IN0).Text) 'Autre cle, autres pseudonymes'
    $users=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Pseudonymize $true -PseudonymKey $script:IK1 -PseudonymKinds @('Utilisateur') -NowUtc $script:IN0
    Assert-True ($users.Text -match 'EX\\support1') 'Famille Compte laissee en clair a la demande';Assert-False ($users.Text -match 'Jean Dupont')
    $nokey=New-DomeniaTicketReport -Context $script:ITCtx -Steps $script:ITSteps -Pseudonymize $true -NowUtc $script:IN0;Assert-False $nokey.Ready;Assert-Equal '' $nokey.Text
}
Test-Case 'D104' 'Un nom coupe par la limite de longueur ne reste pas en clair' {
    $ctx=[pscustomobject]@{Guid=$script:IG1;Name='Jean Dupont';Type='Utilisateur'}
    $steps=@(
        [pscustomobject]@{TargetGuid=$script:IG1;Status='Sent';Label=(('x'*150)+' Jean Dupont')}
        [pscustomobject]@{TargetGuid=$script:IG1;Status='Confirmed';Label='Detail long';Detail=(('y'*392)+' Jean Dupont')}
        [pscustomobject]@{TargetGuid=$script:IG1;Status='Refused';Label=('Nom coupe par une ligne Jean'+[char]10+'Dupont')}
    )
    $plain=New-DomeniaTicketReport -Context $ctx -Steps $steps -NowUtc $script:IN0
    Assert-True ($plain.Text -match ('x{150} Jean Dup'+[char]0x2026)) 'La coupe tombe bien au milieu du nom';Assert-True ($plain.Text -match 'y{392} Jean D')
    $r=New-DomeniaTicketReport -Context $ctx -Steps $steps -Pseudonymize $true -PseudonymKey $script:IK1 -NowUtc $script:IN0
    Assert-True $r.Ready;Assert-False ($r.Text -match '(?i)jean|dupont|\bdup') 'Aucune partie du nom en clair'
    Assert-True ($r.Text -match 'x{150} Utilisa') 'Le pseudonyme est ecrit avant la coupe';Assert-True ($r.Text -match 'y{392} Utilis')
    Assert-True ($r.Text -match ('Nom coupe par une ligne '+[regex]::Escape((ConvertTo-DomeniaPseudonym 'Jean Dupont' $script:IK1 'Utilisateur')))) 'Un nom coupe par un saut de ligne est reconnu'
}
Test-Case 'D104' 'Le ticket et sa fermeture d appels restent charges, le reste des regles Insight est retire' {
    $kept=@('New-DomeniaTicketReport','Test-DomeniaInsightPseudonymKey','ConvertTo-DomeniaPseudonym','Get-DomeniaInsightKeyedHash','ConvertTo-DomeniaInsightText','ConvertTo-DomeniaInsightMaskedNames','ConvertTo-DomeniaInsightStepStatus','ConvertTo-DomeniaInsightSubjectKind','ConvertTo-DomeniaInsightOutcomeText')
    foreach($name in $kept){ Assert-True ($null -ne (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) ('Regle absente : '+$name) }
    Assert-True (Test-DomeniaInsightPseudonymKey 'cle-operateur') 'Cle valide refusee';Assert-False (Test-DomeniaInsightPseudonymKey 'court') 'Cle courte acceptee'
    $loader=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $modules) 'Domenia-Modules.ps1'))
    $entry=[regex]::Match($loader,'(?s)File=''Domenia-Insight\.Model\.ps1''.*?\)\s*\}')
    Assert-True $entry.Success 'Entree Insight absente du chargeur'
    foreach($name in $kept){ Assert-True ($entry.Value -match ("'"+[regex]::Escape($name)+"'")) ('Regle non declaree au chargeur : '+$name) }
    foreach($name in @('Get-DomeniaTimeline','Group-DomeniaIncidents','New-DomeniaReproFixture','New-DomeniaAssistantRequest','Get-DomeniaTroubleshootingJourneys','ConvertTo-DomeniaInsightPseudoGuid')){
        Assert-False ($entry.Value -match ("'"+[regex]::Escape($name)+"'")) ('Regle retiree encore declaree : '+$name)
        Assert-True ($null -eq (Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue)) ('Regle retiree encore chargee : '+$name)
    }
}
