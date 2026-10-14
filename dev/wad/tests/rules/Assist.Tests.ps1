# X04 (programme du 08/10/2026) : assistance poste. Regles pures de Domenia-Assist.Model.ps1, donnees fictives.
Test-Case 'UX-21' 'Cinq vues dans l ordre : vue d ensemble, intervenir, details, diagnostic, secrets' {
    $views=@(Get-DomeniaComputerViewNames)
    Assert-Equal 5 $views.Count
    Assert-Equal 'TabComputer|TabComputerAdmin|TabComputerDetails|TabComputerHealth|TabSecurity' ($views -join '|')
}
Test-Case 'UX-21' 'Les anciens noms d onglet menent a leur vue et a leur onglet interieur' {
    $expected=@{
        TabComputer='TabComputer||';TabComputerDashboard='TabComputer||';TabComputerAdmin='TabComputerAdmin||';TabSessions='TabComputerAdmin||'
        TabInventory='TabComputerDetails|ComputerDetailTabs|TabInventory';TabSoftware='TabComputerDetails|ComputerDetailTabs|TabSoftware'
        TabComputerHealth='TabComputerHealth|ComputerDiagTabs|TabComputerChecks';TabWmi='TabComputerHealth|ComputerDiagTabs|TabWmi';TabSecurity='TabSecurity||'
    }
    foreach($name in $expected.Keys){
        $r=Resolve-DomeniaComputerViewRoute -Tab $name
        Assert-True $r.Known ('Nom inconnu : '+$name)
        Assert-Equal $expected[$name] ($r.View+'|'+$r.Inner+'|'+$r.Sub) $name
    }
    Assert-Equal 'UxComputerDashboardSection' (Resolve-DomeniaComputerViewRoute 'TabComputerDashboard').Section
    Assert-Equal 'UxCompSessionsSection' (Resolve-DomeniaComputerViewRoute 'TabSessions').Section
    Assert-True (Resolve-DomeniaComputerViewRoute 'TabSessions').Alias 'Un ancien nom est un alias'
    Assert-False (Resolve-DomeniaComputerViewRoute 'TabComputerAdmin').Alias 'Une vue n est pas un alias d elle-meme'
}
Test-Case 'UX-21' 'Un nom inconnu, vide ou d une autre page ne mene a aucune vue' {
    foreach($name in @('','  ','TabUser','TabGuard','tabcomputer','TabComputer;TabSecurity')){
        $r=Resolve-DomeniaComputerViewRoute -Tab $name
        Assert-False $r.Known ('Nom accepte : '+$name)
        Assert-Equal '' $r.View
    }
    Assert-False (Resolve-DomeniaComputerViewRoute $null).Known
}
Test-Case 'DS-08' 'Pastille de presence : etat, couleur et heure du dernier test' {
    $on=Get-DomeniaComputerPresenceBadge -State 'En ligne' -CheckedAt '14:32'
    Assert-Equal 'Online' $on.Tone;Assert-Equal 'Répond au ping · 14:32' $on.Label
    $off=Get-DomeniaComputerPresenceBadge -State 'Sans réponse au ping' -CheckedAt '09:05'
    Assert-Equal 'Offline' $off.Tone;Assert-Equal 'Ne répond pas au ping · 09:05' $off.Label
    Assert-True ($off.Help -match 'pas une preuve') 'Une absence de ping n est pas presentee comme un poste eteint'
    Assert-Equal 'Offline' (Get-DomeniaComputerPresenceBadge 'Hors ligne').Tone
    Assert-Equal 'Pending' (Get-DomeniaComputerPresenceBadge 'Vérification en cours' '10:00').Tone
    Assert-Equal 'Test en cours' (Get-DomeniaComputerPresenceBadge 'Vérification en cours' '10:00').Label 'Un test en cours ne porte pas d heure'
    Assert-Equal 'Error' (Get-DomeniaComputerPresenceBadge 'Erreur de ping').Tone
    foreach($unknown in @('','Non vérifié','Inconnu','autre chose')){Assert-Equal 'Unknown' (Get-DomeniaComputerPresenceBadge $unknown).Tone $unknown;Assert-Equal 'Présence non vérifiée' (Get-DomeniaComputerPresenceBadge $unknown).Label $unknown}
}
Test-Case 'DS-08' 'Une presence reprise de la memoire dit memoire et ne porte jamais d heure' {
    $cached=Get-DomeniaComputerPresenceBadge -State 'En ligne (cache)' -CheckedAt '14:32'
    Assert-Equal 'Remembered' $cached.Tone
    Assert-Equal 'Répond au ping (mémoire)' $cached.Label
    Assert-True $cached.Remembered
    Assert-True ($cached.Help -match 'pas un état actuel') 'La memoire est presentee comme un etat actuel'
}
Test-Case 'DS-08' 'En-tete : nom, systeme, utilisateur associe et age de l inventaire, chacun dit quand il ne sait pas' {
    $v=Get-DomeniaComputerHeaderView -Name 'PC-COMPTA-014' -OperatingSystem 'Windows 11 Entreprise' -Version '10.0 (22631)' -Presence 'En ligne' -PresenceCheckedAt '08:15' -UserDisplay 'Camille Martin' -UserLogin 'cmartin' -InventoryLabel 'Inventaire dʼil y a 3 j'
    Assert-Equal 'PC-COMPTA-014' $v.Name;Assert-Equal 'Windows 11 Entreprise · 10.0 (22631)' $v.SystemText
    Assert-True $v.HasUser;Assert-Equal 'Camille Martin' $v.UserText;Assert-True ($v.UserHelp -match 'cmartin') 'Le login n est pas rappele'
    Assert-Equal 'Inventaire dʼil y a 3 j' $v.InventoryText;Assert-Equal 'Online' $v.Presence.Tone
    $empty=Get-DomeniaComputerHeaderView
    Assert-Equal 'Poste sans nom' $empty.Name;Assert-Equal 'Système non renseigné dans lʼannuaire' $empty.SystemText
    Assert-False $empty.HasUser;Assert-Equal 'Aucun inventaire dans cette session' $empty.InventoryText;Assert-Equal 'Unknown' $empty.Presence.Tone
    Assert-Equal 'cmartin' (Get-DomeniaComputerHeaderView -UserLogin 'cmartin').UserText 'Sans nom affiche, le login'
    Assert-Equal 'Version 10.0' (Get-DomeniaComputerHeaderView -Version '10.0').SystemText
}
Test-Case 'UI-07' 'Un seul bouton de compte selon userAccountControl' {
    $off=Get-DomeniaComputerAccountAction -Uac 4098
    Assert-Equal 'Enable' $off.Action;Assert-True $off.ShowEnable;Assert-False $off.ShowDisable
    $on=Get-DomeniaComputerAccountAction -Uac '4096'
    Assert-Equal 'Disable' $on.Action;Assert-False $on.ShowEnable;Assert-True $on.ShowDisable
    foreach($bad in @($null,'','abc')){$x=Get-DomeniaComputerAccountAction -Uac $bad;Assert-Equal 'Unknown' $x.Action;Assert-False $x.ShowEnable;Assert-False $x.ShowDisable}
}
Test-Case 'SE-08' 'Delai de redemarrage borne de 1 a 60 minutes, 5 minutes par defaut' {
    Assert-Equal 300 (Get-DomeniaRestartDelaySeconds $null);Assert-Equal 300 (Get-DomeniaRestartDelaySeconds 'abc');Assert-Equal 300 (Get-DomeniaRestartDelaySeconds 300)
    Assert-Equal 60 (Get-DomeniaRestartDelaySeconds 5);Assert-Equal 3600 (Get-DomeniaRestartDelaySeconds 99999);Assert-Equal 600 (Get-DomeniaRestartDelaySeconds '600')
    Assert-True ((Get-DomeniaRestartDefaultMessage -DelaySeconds 300) -match 'dans 5 minutes') 'Le message ne dit pas le delai'
    Assert-True ((Get-DomeniaRestartDefaultMessage -DelaySeconds 60) -match 'dans 1 minute ') 'Singulier attendu'
}
Test-Case 'SE-08' 'Redemarrage differe par defaut, avec message ; maintenant sans message' {
    $d=Get-DomeniaRestartPlan -Computer 'PC-01'
    Assert-True $d.Valid;Assert-Equal 'Delayed' $d.Mode;Assert-Equal 300 $d.DelaySeconds;Assert-Equal 5 $d.Minutes
    Assert-True ($d.Message -match 'redémarrer dans 5 minutes') 'Message par defaut absent'
    Assert-Equal 'Redémarrer dans 5 min' $d.ConfirmText
    $n=Get-DomeniaRestartPlan -Computer 'PC-01' -Mode 'Now' -Message 'ignore'
    Assert-True $n.Valid;Assert-Equal 'Now' $n.Mode;Assert-Equal 0 $n.DelaySeconds;Assert-Equal '' $n.Message
    Assert-True ($n.Summary -match 'perdu') 'Le redemarrage immediat ne dit pas la perte du travail'
    Assert-False (Get-DomeniaRestartPlan -Computer '').Valid
    Assert-False (Get-DomeniaRestartPlan -Computer 'PC-01' -Mode 'Plus tard').Valid
}
Test-Case 'SE-08' 'Message du redemarrage : une ligne, sans guillemet double ni barre finale, 400 caracteres au plus' {
    $p=Get-DomeniaRestartPlan -Computer 'PC-01' -Message ("Ligne 1`r`nLigne 2 `"citée`" \")
    Assert-True $p.Valid
    Assert-Equal ("Ligne 1 Ligne 2 'citée'") $p.Message
    Assert-False ($p.Message.Contains([string][char]34)) 'Guillemet double conserve'
    Assert-False (Get-DomeniaRestartPlan -Computer 'PC-01' -Message ('a'*401)).Valid
    Assert-True (Get-DomeniaRestartPlan -Computer 'PC-01' -Message ('a'*400)).Valid
}
Test-Case 'SE-08' 'Sessions lues avant le redemarrage : liste, refus et lecture partielle' {
    $view=[pscustomobject]@{ReadState='Constate';Partial=$false;UserSessions=2;UnreadSessions=0;EmptyText='';Rows=@(
        [pscustomobject]@{Utilisateur='EXAMPLE\cmartin';Protocole='Console';Etat='Actif';Ouverte='08:15';Inactive='12 min'},
        [pscustomobject]@{Utilisateur='EXAMPLE\pdurand';Protocole='RDP';Etat='Déconnecté';Ouverte='';Inactive=''})}
    $s=Get-DomeniaRestartSessionSummary -View $view
    Assert-True $s.Known;Assert-Equal 2 $s.Count;Assert-Equal 2 @($s.Lines).Count
    Assert-Equal 'EXAMPLE\cmartin · Console · Actif · ouverte à 08:15 · inactive depuis 12 min' @($s.Lines)[0]
    Assert-Equal 'EXAMPLE\pdurand · RDP · Déconnecté' @($s.Lines)[1]
    Assert-True ($s.Text -match '^2 sessions ouvertes') $s.Text
    $none=Get-DomeniaRestartSessionSummary -View ([pscustomobject]@{ReadState='Constate';UserSessions=0;UnreadSessions=0;Rows=@()})
    Assert-True $none.Known;Assert-Equal 0 $none.Count;Assert-True ($none.Text -match '^Aucune session') $none.Text
    $refused=Get-DomeniaRestartSessionSummary -View ([pscustomobject]@{ReadState='Refuse';EmptyText='Lecture des sessions refusée pour ce compte : aucune conclusion sur les sessions ouvertes.';Rows=@()})
    Assert-False $refused.Known;Assert-True ($refused.Text -match 'préférez le redémarrage différé') $refused.Text
    $failed=Get-DomeniaRestartSessionSummary -Failure 'Accès refusé.'
    Assert-False $failed.Known;Assert-Equal -1 $failed.Count;Assert-True ($failed.Text -match '^Sessions non lues : Accès refusé') $failed.Text
    $partial=Get-DomeniaRestartSessionSummary -View ([pscustomobject]@{ReadState='Constate';Partial=$true;UserSessions=1;UnreadSessions=1;Rows=@([pscustomobject]@{Utilisateur='Compte non lu';Protocole='RDP';Etat='Actif'})})
    Assert-True ($partial.Text -match 'compte nʼa pas pu être lu') $partial.Text
    Assert-True ($partial.Text -match 'Lecture partielle') $partial.Text
    Assert-False (Get-DomeniaRestartSessionSummary).Known 'Sans lecture, rien n est conclu'
}
Test-Case 'UI-26' 'Executer un programme : deux modes seulement, commande et compte valides' {
    $sys=Get-DomeniaRunProgramPlan -Computer 'PC-01' -Mode 'System' -Command '%SystemRoot%\System32\notepad.exe' -RunUser 'EXAMPLE\cmartin'
    Assert-True $sys.Valid;Assert-Equal '' $sys.RunUser 'Le compte n est pas transmis en mode systeme'
    Assert-True ($sys.Summary -match 'compte système') $sys.Summary
    $user=Get-DomeniaRunProgramPlan -Computer 'PC-01' -Mode 'Interactive' -Command 'calc.exe' -RunUser 'EXAMPLE\cmartin' -Elevated $false
    Assert-True $user.Valid;Assert-Equal 'EXAMPLE\cmartin' $user.RunUser;Assert-False $user.Elevated
    Assert-False (Get-DomeniaRunProgramPlan -Computer 'PC-01' -Mode 'MachineCredential' -Command 'calc.exe').Valid 'Le mode retire est refuse'
    Assert-False (Get-DomeniaRunProgramPlan -Computer 'PC-01' -Mode 'Interactive' -Command 'calc.exe').Valid 'Compte de session vide'
    Assert-False (Get-DomeniaRunProgramPlan -Computer 'PC-01' -Mode 'Interactive' -Command 'calc.exe' -RunUser 'a b').Valid 'Compte avec espace'
    Assert-False (Get-DomeniaRunProgramPlan -Computer 'PC-01' -Command '').Valid
    Assert-False (Get-DomeniaRunProgramPlan -Computer 'PC-01' -Command "a.exe`nb.exe").Valid 'Retour a la ligne'
    Assert-False (Get-DomeniaRunProgramPlan -Computer '' -Command 'calc.exe').Valid
}
Test-Case 'UX-42' 'Commande PowerShell copiee : compte poste nomme, jamais de mot de passe' {
    $plain=Get-DomeniaPsRemoteCommand -Computer 'PC-01'
    Assert-Equal "Enter-PSSession -ComputerName 'PC-01'" $plain.Text;Assert-False $plain.UsesCredential
    $named=Get-DomeniaPsRemoteCommand -Computer 'PC-01' -UserName 'EXAMPLE\adm-poste'
    Assert-Equal "Enter-PSSession -ComputerName 'PC-01' -Credential 'EXAMPLE\adm-poste'" $named.Text;Assert-True $named.UsesCredential
    Assert-True ($named.Status -match 'mot de passe, qui nʼest jamais copié') $named.Status
    $quoted=Get-DomeniaPsRemoteCommand -Computer 'PC-01' -UserName "EXAMPLE\o'brien"
    Assert-Equal "Enter-PSSession -ComputerName 'PC-01' -Credential 'EXAMPLE\o''brien'" $quoted.Text 'Apostrophe non doublee'
}
Test-Case 'UX-38' 'Services : une ligne par service, libelles en francais, automatiques arretes en tete' {
    $cells=@(
        [pscustomobject]@{Instance=1;Property='Name';Value='Spooler'},[pscustomobject]@{Instance=1;Property='DisplayName';Value='Spouleur d impression'},
        [pscustomobject]@{Instance=1;Property='State';Value='Running'},[pscustomobject]@{Instance=1;Property='StartMode';Value='Auto'},
        [pscustomobject]@{Instance=2;Property='Name';Value='wuauserv'},[pscustomobject]@{Instance=2;Property='DisplayName';Value='Windows Update'},
        [pscustomobject]@{Instance=2;Property='State';Value='Stopped'},[pscustomobject]@{Instance=2;Property='StartMode';Value='Auto'},[pscustomobject]@{Instance=2;Property='DelayedAutoStart';Value='True'},
        [pscustomobject]@{Instance=3;Property='Name';Value='Fax'},[pscustomobject]@{Instance=3;Property='State';Value='Stopped'},[pscustomobject]@{Instance=3;Property='StartMode';Value='Disabled'},
        [pscustomobject]@{Instance=4;Property='DisplayName';Value='Sans nom'}
    )
    $rows=@(ConvertTo-DomeniaServiceRows -Instances $cells)
    Assert-Equal 3 $rows.Count 'Une instance sans nom est ecartee'
    Assert-Equal 'wuauserv' $rows[0].Name 'Automatique arrete en tete'
    Assert-True $rows[0].AutoStopped;Assert-Equal 'Automatique (différé)' $rows[0].StartLabel;Assert-Equal 'Arrêté' $rows[0].StateLabel;Assert-True $rows[0].CanStart;Assert-False $rows[0].CanRestart
    $fax=@($rows|Where-Object{$_.Name -eq 'Fax'})[0]
    Assert-Equal 'Fax' $fax.DisplayName 'Sans libelle, le nom';Assert-Equal 'Désactivé' $fax.StartLabel;Assert-False $fax.CanStart;Assert-False $fax.AutoStopped
    $spool=@($rows|Where-Object{$_.Name -eq 'Spooler'})[0]
    Assert-Equal 'En cours' $spool.StateLabel;Assert-True $spool.CanRestart;Assert-False $spool.CanStart
    Assert-Equal 0 @(ConvertTo-DomeniaServiceRows -Instances @()).Count
}
Test-Case 'UX-38' 'Filtre local : automatiques arretes et texte dans le nom ou le libelle' {
    $a=[pscustomobject]@{Name='wuauserv';DisplayName='Windows Update';AutoStopped=$true}
    $b=[pscustomobject]@{Name='Spooler';DisplayName='Spouleur';AutoStopped=$false}
    Assert-True (Test-DomeniaServiceRowMatch $a $true '');Assert-False (Test-DomeniaServiceRowMatch $b $true '')
    Assert-True (Test-DomeniaServiceRowMatch $b $false 'spool');Assert-True (Test-DomeniaServiceRowMatch $a $false 'UPDATE');Assert-False (Test-DomeniaServiceRowMatch $a $false 'spool')
    Assert-False (Test-DomeniaServiceRowMatch $null $false '')
    $text=Get-DomeniaServiceListSummary -Rows @($a,$b) -Shown 1 -ReadAt '10:12' -Computer 'PC-01'
    Assert-True ($text -match '^2 service\(s\) lus sur PC-01 à 10:12 ; 1 automatique\(s\) arrêté\(s\) ; 1 affiché\(s\)') $text
}
Test-Case 'UX-38' 'Commande de service : jamais sur un service desactive, demarrer un arrete, redemarrer un service en cours' {
    $stopped=[pscustomobject]@{Name='wuauserv';DisplayName='Windows Update';State='Stopped';StartMode='Auto'}
    $running=[pscustomobject]@{Name='Spooler';DisplayName='Spouleur';State='Running';StartMode='Auto'}
    $disabled=[pscustomobject]@{Name='Fax';DisplayName='Fax';State='Stopped';StartMode='Disabled'}
    $start=Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $stopped
    Assert-True $start.Valid;Assert-Equal 'wuauserv' $start.Name;Assert-Equal 'Normal' $start.Risk;Assert-True ($start.Title -match 'PC-01') $start.Title
    $restart=Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Restart' -Row $running
    Assert-True $restart.Valid;Assert-Equal 'Danger' $restart.Risk
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $disabled).Valid 'Service desactive demarre'
    Assert-True ((Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $disabled).Reason -match 'type de démarrage')
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $running).Valid
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Restart' -Row $stopped).Valid
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Stop' -Row $running).Valid 'Action hors liste'
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $null).Valid
    Assert-False (Get-DomeniaServiceControlPlan -Computer '' -Action 'Start' -Row $stopped).Valid
    $injected=[pscustomobject]@{Name="x' OR Name='y";DisplayName='x';State='Stopped';StartMode='Auto'}
    Assert-False (Get-DomeniaServiceControlPlan -Computer 'PC-01' -Action 'Start' -Row $injected).Valid 'Nom hors liste blanche'
    $after=Get-DomeniaServiceRowWithState -Row ([pscustomobject]@{Name='wuauserv';DisplayName='Windows Update';State='Stopped';StartMode='Auto';StartLabel='Automatique (différé)'}) -State 'Running'
    Assert-Equal 'En cours' $after.StateLabel;Assert-False $after.AutoStopped;Assert-True $after.CanRestart;Assert-Equal 'Automatique (différé)' $after.StartLabel
}
Test-Case 'UX-19' 'Pastille des operations a verifier : seulement s il en reste' {
    Assert-False (Get-DomeniaPendingOperationsView 0).Visible
    Assert-False (Get-DomeniaPendingOperationsView -5).Visible
    $one=Get-DomeniaPendingOperationsView 1
    Assert-True $one.Visible;Assert-Equal '1 opération à vérifier' $one.Text;Assert-True ($one.Help -match 'rien nʼest rejoué') $one.Help
    Assert-Equal '3 opérations à vérifier' (Get-DomeniaPendingOperationsView 3).Text
}
