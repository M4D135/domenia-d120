# D081-D090 : coque de l interface (titre, disposition, demandes dans la page, vues de colonnes, apercu,
# resume, etats vides, aides, premier plan, contraste et restauration). Donnees fictives uniquement.
Test-Case 'D081' 'Le titre montre toujours la page active et la cible' {
    $t=Get-DomeniaPageTitle -Page 'WsObject' -TargetName 'Jean Dupont' -TargetType 'Utilisateur'
    Assert-Equal 'Fiche · Jean Dupont' $t.Header;Assert-True $t.HasTarget
    Assert-True ($t.WindowTitle.StartsWith('Fiche · Jean Dupont',[StringComparison]::Ordinal)) 'La barre de titre reprend la page et la cible'
    foreach($page in @(Get-DomeniaShellPages)){
        $p=Get-DomeniaPageTitle -Page $page.Id -TargetName 'PC-0042' -TargetType 'Machine'
        Assert-Equal ($page.Label+' · PC-0042') $p.Header ('Page '+$page.Id)
        Assert-True ($p.WindowTitle.IndexOf('PC-0042',[StringComparison]::Ordinal) -ge 0) ('Titre de fenetre '+$page.Id)
    }
}
Test-Case 'D081' 'Sans cible le titre le dit ; un utilisateur n est pas la cible de l assistance poste' {
    $none=Get-DomeniaPageTitle -Page 'WsSearch';Assert-Equal 'Rechercher · Aucune sélection' $none.Header;Assert-False $none.HasTarget
    $wrong=Get-DomeniaPageTitle -Page 'WsComputer' -TargetName 'Jean Dupont' -TargetType 'Utilisateur'
    Assert-False $wrong.HasTarget;Assert-Equal 'Poste · Aucun poste sélectionné' $wrong.Header
    Assert-False ($wrong.WindowTitle -match 'Dupont') 'Le nom d une autre cible ne reste pas dans le titre'
    Assert-True ((Get-DomeniaPageTitle -Page 'WsObject' -TargetName 'x' -WriteEnabled $true).WindowTitle.EndsWith('[ÉCRITURE AD ACTIVE]',[StringComparison]::Ordinal))
    Assert-False ((Get-DomeniaPageTitle -Page 'WsObject' -TargetName 'x').WindowTitle -match 'CRITURE AD')
    $long=Get-DomeniaPageTitle -Page 'WsObject' -TargetName ("Nom`r`n"+('x'*300))
    Assert-True ($long.Target.Length -le 80) 'Cible bornee';Assert-False ($long.Header -match "[`r`n]") 'Titre sur une ligne'
}
Test-Case 'D081' 'Aucun deuxieme selecteur de sujet hors Rechercher et Parcourir' {
    $pickers=@(Get-DomeniaShellPages|Where-Object{Test-DomeniaSelectorAllowed $_.Id 'Subject'}|ForEach-Object{$_.Id}|Sort-Object)
    Assert-Equal 'TabDirectory,WsSearch' ($pickers -join ',')
    Assert-False (Test-DomeniaSelectorAllowed 'WsObject' 'Subject');Assert-False (Test-DomeniaSelectorAllowed 'TabRelations' 'Subject')
    Assert-True (Test-DomeniaSelectorAllowed 'TabRelations' 'AssociationTarget') 'Relations cherche une cible d association, pas un second sujet'
    Assert-False (Test-DomeniaSelectorAllowed 'TabAccounts' 'AssociationTarget');Assert-False (Test-DomeniaSelectorAllowed 'PageInconnue' 'Subject')
}
Test-Case 'D082' 'Compteur : vide a zero, nombre jusqu a 99, puis 99+' {
    Assert-Equal '' (Get-DomeniaCounterText 0);Assert-Equal '1' (Get-DomeniaCounterText 1);Assert-Equal '10' (Get-DomeniaCounterText 10);Assert-Equal '99' (Get-DomeniaCounterText 99)
    Assert-Equal '99+' (Get-DomeniaCounterText 100);Assert-Equal '99+' (Get-DomeniaCounterText 2147483647)
    Assert-Throws { Get-DomeniaCounterText -1 } 'Un compteur negatif est refuse'
}
Test-Case 'D082' 'Transitions 0/1/10/100 taches et message long : aucun voisin ne bouge' {
    $sig={param($l) '{0}|{1}|{2}|{3}|{4}' -f $l.Activity.Width,$l.Counter.Width,$l.Message.Width,$l.Actions.Width,$l.TotalWidth}
    $long='Lecture des postes : '+('reponse tres longue du fournisseur '*40)
    foreach($available in @(0,1600,600)){
        $reference=& $sig (Get-DomeniaReservedLayout -TaskCount 0 -Message '' -AvailableWidth $available)
        foreach($count in @(0,1,10,100)){foreach($text in @('','OK',$long)){
            $l=Get-DomeniaReservedLayout -TaskCount $count -Message $text -AvailableWidth $available
            Assert-Equal $reference (& $sig $l) ('Taches '+$count+', largeur '+$available)
            Assert-True ($l.Counter.Text.Length -le $l.Counter.MaxChars) 'Compteur borne';Assert-True ($l.Message.Text.Length -le $l.Message.MaxChars) 'Message borne'
            Assert-True (($l.Activity.Visibility -ne 'Collapsed') -and ($l.Counter.Visibility -ne 'Collapsed')) 'Un emplacement vide reste reserve'
        }}
    }
    Assert-Equal 'Hidden' (Get-DomeniaReservedLayout -TaskCount 0).Activity.Visibility;Assert-Equal 'Visible' (Get-DomeniaReservedLayout -TaskCount 1).Activity.Visibility
    Assert-Equal '99+' (Get-DomeniaReservedLayout -TaskCount 100).Counter.Text;Assert-Equal 'Hidden' (Get-DomeniaReservedLayout -TaskCount 0).Counter.Visibility
    $l=Get-DomeniaReservedLayout -Message $long;Assert-True ($l.Message.ToolTip.Length -gt $l.Message.Text.Length) 'Le texte complet reste en infobulle'
}
Test-Case 'D082' 'Fenetre etroite : rien n est rogne jusqu a la largeur minimale, rogne annonce en dessous' {
    $narrow=Get-DomeniaReservedLayout -AvailableWidth 100
    Assert-True $narrow.Clipped 'A 100 px la barre ne tient pas : rognage annonce';Assert-Equal 292 $narrow.MinimumWidth 'Largeur minimale a l echelle 1'
    Assert-True ($narrow.TotalWidth -gt 100) 'Le cas rogne est bien celui ou la largeur reservee depasse'
    foreach($scale in @(1.0,1.5,2.0)){
        $minimum=(Get-DomeniaReservedLayout -Scale $scale).MinimumWidth
        Assert-True ([Math]::Abs($minimum-(292.0*$scale)) -lt 0.001) ('Largeur minimale proportionnelle a l echelle '+$scale)
        foreach($count in @(1,3,8)){
            for($width=$minimum;$width -le ($minimum+1400);$width+=37){
                $l=Get-DomeniaReservedLayout -Scale $scale -ActionCount $count -AvailableWidth $width
                $why='echelle '+$scale+', '+$count+' actions, largeur '+$width
                Assert-False $l.Clipped $why;Assert-True ($l.TotalWidth -le ($width+0.001)) ('Aucun debordement : '+$why)
                Assert-True ($l.Message.Width -ge ((160.0*$scale)-0.001)) ('Message au moins a sa largeur minimale : '+$why)
                Assert-Equal $count ($l.Actions.Visible+$l.Actions.InOverflow) ('Chaque action reste atteignable : '+$why)
            }
            foreach($width in @(1,50,($minimum-1))){Assert-True (Get-DomeniaReservedLayout -Scale $scale -ActionCount $count -AvailableWidth $width).Clipped ('Sous la largeur minimale : '+$width)}
        }
    }
    Assert-False (Get-DomeniaReservedLayout).Clipped 'Largeur inconnue : rien n est annonce rogne'
}
Test-Case 'D082' 'Recherche : texte indicatif et saisie alignes a toute echelle' {
    foreach($scale in @(1.0,1.25,1.5,2.0)){$s=(Get-DomeniaReservedLayout -Scale $scale).Search;Assert-Equal $s.TextLeft $s.HintLeft ([string]$scale);Assert-Equal 'Center' $s.VerticalContentAlignment}
    Assert-True ((Get-DomeniaReservedLayout -Scale 2.0).Search.TextLeft -gt (Get-DomeniaReservedLayout -Scale 1.0).Search.TextLeft) 'Le decalage suit l echelle'
}
Test-Case 'D083' 'Confirmation dans la page : choix par defaut nommes, roles fixes' {
    $r=New-DomeniaInlineRequest -Kind Associate -HostName 'TabRelations' -Title 'Associer PC-0042 a Jean Dupont ?' -ContinuationId 'assoc-1' -Scope 'user:f4dc' -Generation '7'
    Assert-Equal 'Inline' $r.Presentation;Assert-Equal 'Annuler' $r.SafeChoice;Assert-Equal 'Associer' $r.ConfirmChoice
    Assert-Equal 'Pending' $r.State;Assert-Equal 'TabRelations' $r.HostName;Assert-Equal 16 $r.Id.Length
    Assert-Equal $r.Id (New-DomeniaInlineRequest -Kind Associate -HostName 'TabRelations' -Title 'autre' -ContinuationId 'assoc-1' -Scope 'user:f4dc' -Generation '7').Id 'Meme demande, meme identifiant'
    $acc=New-DomeniaInlineRequest -Kind AccountChange -HostName 'TabAccounts' -Title 'Changer de compte' -ContinuationId 'acc'
    Assert-Equal 'Conserver le compte actuel' $acc.SafeChoice;Assert-Equal 'Utiliser ce compte' $acc.ConfirmChoice
    Assert-Throws { New-DomeniaInlineRequest -Kind Choice -HostName 'x' -Title 't' -ContinuationId 'c' } 'Un choix sans options est refuse'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Oui','Non') -SafeChoice 'Peut-etre' -ConfirmChoice 'Oui' } 'Le choix sur doit etre propose'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Oui','Non') -SafeChoice 'Non' -ConfirmChoice 'Peut-etre' } 'Le choix qui confirme doit etre propose'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -SafeChoice 'Confirmer' } 'Les choix par defaut ne s inversent pas'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Non','Non') -SafeChoice 'Non' -ConfirmChoice 'Non' } 'Deux choix identiques refuses'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Annuler','annuler') -SafeChoice 'Annuler' -ConfirmChoice 'annuler' } 'Choix sur et confirmation confondus refuses'
}
Test-Case 'D083' 'Annuler en premier : le choix sur est nomme, jamais devine par la position' {
    $new={New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Supprimer le lien ?' -Choices @('Annuler','Supprimer') -SafeChoice 'Annuler' -ConfirmChoice 'Supprimer' -ContinuationId 'del-1' -Scope 'obj:1'}
    $cancel=Resolve-DomeniaInlineRequest (& $new) 'Annuler'
    Assert-True $cancel.Continue;Assert-False $cancel.Confirmed 'Cliquer Annuler ne confirme pas';Assert-Equal 'Annuler' $cancel.Choice
    $esc=Resolve-DomeniaInlineRequest (& $new) -Dismiss
    Assert-False $esc.Confirmed 'Echap ne choisit jamais la suppression';Assert-Equal 'Annuler' $esc.Choice
    $ok=Resolve-DomeniaInlineRequest (& $new) 'Supprimer';Assert-True $ok.Confirmed;Assert-Equal 'Supprimer' $ok.Choice
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Annuler','Supprimer') } 'Choix personnalises sans choix sur nomme : refuse'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Annuler','Supprimer','Archiver') -ConfirmChoice 'Supprimer' } 'Choix qui confirme nomme, choix sur absent : refuse'
    Assert-Throws { New-DomeniaInlineRequest -Kind Choice -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Garder','Remplacer') } 'Choix libre sans choix sur nomme : refuse'
    Assert-Throws { New-DomeniaInlineRequest -Kind Confirm -HostName 'x' -Title 't' -ContinuationId 'c' -Choices @('Annuler','Supprimer') -SafeChoice 'Annuler' } 'Choix personnalises sans choix qui confirme : refuse'
    $three=New-DomeniaInlineRequest -Kind Choice -HostName 'WsObject' -Title 'Doublon' -Choices @('Garder','Remplacer','Fusionner') -SafeChoice 'Garder' -ContinuationId 'dup'
    $pick=Resolve-DomeniaInlineRequest $three 'Remplacer';Assert-True $pick.Continue;Assert-Equal 'Remplacer' $pick.Choice;Assert-False $pick.Confirmed 'Sans choix qui confirme, aucune reponse ne vaut confirmation'
    Assert-Equal 'Garder' (Resolve-DomeniaInlineRequest (New-DomeniaInlineRequest -Kind Choice -HostName 'h' -Title 't' -Choices @('Remplacer','Garder') -SafeChoice 'Garder' -ContinuationId 'd2') -Dismiss).Choice 'Echap suit le nom, pas la position'
}
Test-Case 'D083' 'La suite s execute une seule fois ; un contexte change ou non verifie la retire' {
    $r=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Deplacer ?' -ContinuationId 'move-1' -Scope 'obj:1' -Generation '3'
    $first=Resolve-DomeniaInlineRequest $r 'Confirmer' -CurrentGeneration '3'
    Assert-True $first.Continue;Assert-True $first.Confirmed;Assert-Equal 'move-1' $first.ContinuationId;Assert-Equal 'Answered' $r.State
    Assert-False (Resolve-DomeniaInlineRequest $r 'Confirmer' -CurrentGeneration '3').Continue 'Double clic : pas de seconde suite'
    $old=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Deplacer ?' -ContinuationId 'move-2' -Scope 'obj:1' -Generation '3'
    $expired=Resolve-DomeniaInlineRequest $old 'Confirmer' -CurrentGeneration '4'
    Assert-False $expired.Continue;Assert-Equal 'Expired' $old.State;Assert-False (Resolve-DomeniaInlineRequest $old 'Confirmer' -CurrentGeneration '3').Continue
    $blind=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Deplacer ?' -ContinuationId 'move-3' -Scope 'obj:1' -Generation '7'
    $unchecked=Resolve-DomeniaInlineRequest $blind 'Confirmer'
    Assert-False $unchecked.Continue 'Generation courante non fournie : la suite ne part pas';Assert-False $unchecked.Confirmed;Assert-Equal 'Expired' $unchecked.State;Assert-Equal 'Expired' $blind.State
    $blindEsc=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Deplacer ?' -ContinuationId 'move-4' -Scope 'obj:1' -Generation '7'
    Assert-False (Resolve-DomeniaInlineRequest $blindEsc -Dismiss).Continue 'Meme Echap ne lance pas la suite d une demande non verifiee'
    $esc=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Retirer le lien ?' -ContinuationId 'x'
    $d=Resolve-DomeniaInlineRequest $esc -Dismiss;Assert-True $d.Continue;Assert-False $d.Confirmed 'Echap choisit le choix sur';Assert-Equal 'Annuler' $d.Choice
    $bad=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 't' -ContinuationId 'y'
    Assert-False (Resolve-DomeniaInlineRequest $bad 'Peut-etre').Continue;Assert-Equal 'Pending' $bad.State
    Assert-False (Resolve-DomeniaInlineRequest $bad '').Continue 'Reponse vide : la demande reste affichee';Assert-Equal 'Pending' $bad.State
    Assert-False (Resolve-DomeniaInlineRequest $null 'Confirmer').Continue
}
Test-Case 'D083' 'Une demande en attente ne bloque que les ecritures de sa cible ; sans cible elle les retient toutes' {
    $r=New-DomeniaInlineRequest -Kind AccountChange -HostName 'TabAccounts' -Title 'Compte LAPS' -ContinuationId 'laps' -Scope 'Laps'
    Assert-False (Test-DomeniaInlineRequestBlocks $r Navigate);Assert-False (Test-DomeniaInlineRequestBlocks $r Read 'Laps');Assert-False (Test-DomeniaInlineRequestBlocks $r Select 'Laps')
    Assert-True (Test-DomeniaInlineRequestBlocks $r Write 'Laps');Assert-True (Test-DomeniaInlineRequestBlocks $r Edit 'laps')
    Assert-False (Test-DomeniaInlineRequestBlocks $r Write 'Directory') 'Les autres cibles restent disponibles'
    [void](Resolve-DomeniaInlineRequest $r 'Conserver le compte actuel');Assert-False (Test-DomeniaInlineRequestBlocks $r Write 'Laps') 'Repondue, la demande ne bloque plus'
    $open=New-DomeniaInlineRequest -Kind Confirm -HostName 'WsObject' -Title 'Supprimer ?' -ContinuationId 'u1'
    Assert-True (Test-DomeniaInlineRequestBlocks $open Write 'obj:1') 'Sans portee, la cible confirmee reste protegee';Assert-True (Test-DomeniaInlineRequestBlocks $open Edit 'obj:2')
    Assert-True (Test-DomeniaInlineRequestBlocks $open Write '') 'Portee vide demandee : retenue aussi'
    Assert-False (Test-DomeniaInlineRequestBlocks $open Navigate) 'La navigation reste libre';Assert-False (Test-DomeniaInlineRequestBlocks $open Read 'obj:1') 'Les lectures restent libres'
}
Test-Case 'D083' 'Un gestionnaire metier qui ouvre une fenetre ou un modal est refuse' {
    $unsafe=@(
        '$w=[Windows.Window]::new();$w.Content=$panel','$w=New-Object System.Windows.Window','[void]$sheet.ShowDialog()','[Windows.Threading.Dispatcher]::PushFrame($frame)'
        'Show-DomeniaDialog -Title x -Message y','[System.Windows.MessageBox]::Show(''x'')','$x=[xml]''<Window xmlns="p" Title="Associer"/>'';$w=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $x))'
        '$w=[System.Windows.Window]@{Title=''x''};$w.Show()','$f=New-Object System.Windows.Forms.Form;$f.Show()','[Microsoft.VisualBasic.Interaction]::MsgBox(''x'')','''<wpf:Window xmlns:wpf="p"/>'''
        '$w=[Activator]::CreateInstance([System.Windows.Window])','''<Window/>''','$n=[System.Windows.Navigation.NavigationWindow]::new()','$frame=New-Object Windows.Threading.DispatcherFrame'
        '[System.Windows.Forms.Application]::Run($form)','$c=Get-Credential -Message ''Compte''','$rows|Out-GridView','[Microsoft.VisualBasic.Interaction]::InputBox(''Nom'')'
        'if(Confirm-Action ''Supprimer ?''){Remove-Thing}','Show-InfoBox ''Termine''','Show-DomeniaEmbeddedWindow -Window $w','[void](Confirm-TextAction -Message m)'
    )
    foreach($code in $unsafe){Assert-False (Test-DomeniaInlineCodeSafe $code).Safe $code}
    Assert-True (Test-DomeniaInlineCodeSafe '$panel.Visibility=''Visible'';$script:PendingRequest=$request').Safe
    Assert-True (Test-DomeniaInlineCodeSafe '$w.WindowState=''Normal'';$grid=''<Grid x:Name="PnlInline"/>''').Safe 'WindowState et un panneau XAML ne sont pas des fenetres'
    Assert-True (Test-DomeniaInlineCodeSafe '$owner=[Windows.Window]::GetWindow($Control);$b.FormBorderStyle=[System.Windows.Forms.FormBorderStyle]::None').Safe 'Retrouver la fenetre hote ne cree rien'
    Assert-True (Test-DomeniaInlineCodeSafe '$scope=Get-CredentialScope $op;Confirm-DomeniaRelationAssociationState $s;''<WindowsFormsHost/>''').Safe 'Noms voisins non confondus'
    Assert-Equal 'Nouvelle fenetre WPF,Boucle modale imbriquee' ((Test-DomeniaInlineCodeSafe '$w=New-Object Windows.Window;$w.ShowDialog()').Findings -join ',')
    Assert-Equal 'Formulaire WinForms' ((Test-DomeniaInlineCodeSafe '$f=New-Object System.Windows.Forms.Form').Findings -join ',')
}
Test-Case 'D084' 'Une liste utilisateur ne porte aucune colonne de console machine' {
    $console=@('SessionDisplay','SessionState','Presence')
    $user=@(Get-DomeniaResultColumns 'Utilisateur');foreach($c in $console){Assert-True ($c -notin $user) $c}
    Assert-True ('OS' -notin $user) 'Systeme du poste masque pour une liste utilisateur'
    $machine=@(Get-DomeniaResultColumns 'Machine');foreach($c in $console){Assert-True ($c -in $machine) $c}
    Assert-True ('Mail' -notin $machine) 'Pas de messagerie pour une liste de postes'
    $all=@(Get-DomeniaResultColumns -ColumnProfile 'Mixte')
    Assert-Equal 18 $all.Count 'La vue mixte garde les 18 colonnes de la grille'
    Assert-Equal 'Type,Name,SessionDisplay,SessionState,DirectoryState,Login,UPN,Association,LinkSource,LinkConfidence,Presence,State,OS,LastLogon,Mail,Description,Changed,DN' ($all -join ',') 'Cles reelles de DgObjects'
    foreach($c in @($user+$machine)){Assert-True ($c -cin $all) ('Cle connue de la grille : '+$c)}
    Assert-Equal 'Type,Name' ((@(Get-DomeniaResultColumns -Profile 'Utilisateur')|Select-Object -First 2) -join ',') 'Alias -Profile'
    Assert-Throws { Get-DomeniaResultColumns 'Groupe' } 'Vue inconnue refusee'
    Assert-Equal 'Mixte,Utilisateur,Machine' ((@((Get-DomeniaResultProfileLabels).Keys)) -join ',') 'Ordre du selecteur'
}
Test-Case 'D084' 'Largeur, ordre et tri conserves d une vue a l autre' {
    $prefs=@{SessionDisplay=@{Width=300;Order=0};Name=@{Width=180;Order=1};Type=@{Width=5}}
    $sort=[pscustomobject]@{Column='SessionDisplay';Direction='Descending'}
    $machine=Resolve-DomeniaColumnPreferences 'Machine' $prefs $sort
    Assert-Equal 'SessionDisplay' $machine.Columns[0].Id;Assert-Equal 300 $machine.Columns[0].Width;Assert-Equal 'Name' $machine.Columns[1].Id;Assert-Equal 180 $machine.Columns[1].Width
    Assert-Equal 'Type' $machine.Columns[2].Id 'Les colonnes sans ordre enregistre gardent leur ordre de vue'
    Assert-Equal 105 $machine.Columns[2].Width 'Largeur invalide : largeur par defaut'
    Assert-Equal 'SessionDisplay' $machine.Sort.Column;Assert-Equal 'Descending' $machine.Sort.Direction
    $user=Resolve-DomeniaColumnPreferences 'Utilisateur' $prefs $sort
    Assert-Equal 'Name' $user.Columns[0].Id;Assert-Equal 180 $user.Columns[0].Width;Assert-True ($null -eq $user.Sort) 'Tri sur une colonne absente de la vue : non applique'
    Assert-Equal 0 @($user.Columns|Where-Object{$_.Id -eq 'SessionDisplay'}).Count
    Assert-Equal 300 $prefs['SessionDisplay'].Width 'La preference d une colonne masquee est conservee'
    $back=Resolve-DomeniaColumnPreferences 'Machine' $prefs $sort
    Assert-Equal 300 @($back.Columns|Where-Object{$_.Id -eq 'SessionDisplay'})[0].Width;Assert-Equal 'SessionDisplay' $back.Sort.Column
    Assert-Equal 520 @((Resolve-DomeniaColumnPreferences 'Mixte').Columns|Where-Object{$_.Id -eq 'DN'})[0].Width 'Largeur par defaut de la grille reelle'
}
Test-Case 'D084' 'Aucun changement de vue pendant une saisie ou l arrivee d un lot' {
    Assert-True (Test-DomeniaProfileChangeAllowed -Trigger Explicit -CurrentProfile Utilisateur -RequestedProfile Machine).Allowed
    $typing=Test-DomeniaProfileChangeAllowed -Trigger Explicit -Typing $true -CurrentProfile Utilisateur -RequestedProfile Machine
    Assert-False $typing.Allowed;Assert-True $typing.Deferred
    $batch=Test-DomeniaProfileChangeAllowed -Trigger Explicit -BatchArriving $true -CurrentProfile Utilisateur -RequestedProfile Machine
    Assert-False $batch.Allowed;Assert-True $batch.Deferred
    $auto=Test-DomeniaProfileChangeAllowed -Trigger Automatic -CurrentProfile Utilisateur -RequestedProfile Mixte
    Assert-False $auto.Allowed;Assert-False $auto.Deferred 'Une vue se choisit explicitement'
    Assert-False (Test-DomeniaProfileChangeAllowed -Trigger Explicit -CurrentProfile Machine -RequestedProfile Machine).Allowed
    Assert-False (Test-DomeniaProfileChangeAllowed -Trigger Explicit -CurrentProfile Machine -RequestedProfile 'Groupes').Allowed
}
$script:SU=[pscustomobject]@{Type='Utilisateur';Name='Jean Dupont';Guid='f4dc5a91-c11b-46b5-893d-9a2cbbad31ad';Generation='4'}
$script:SM=[pscustomobject]@{Type='Machine';Name='PC-0042';Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2';Generation='5'}
$script:DU=[pscustomobject]@{Guid='f4dc5a91-c11b-46b5-893d-9a2cbbad31ad';Generation='4';Login='jdupont';Upn='jdupont@example.test';State='Actif';Container='OU=Utilisateurs,DC=example,DC=test'}
$script:DM=[pscustomobject]@{Guid='3a760e2f-315a-4155-a1d0-26a319a64cf2';Generation='5';DnsName='pc-0042.example.test';OperatingSystem='Windows 11';State='Actif';Container='OU=Postes,DC=example,DC=test'}
Test-Case 'D085' 'Utilisateur et poste suivent le meme contrat' {
    foreach($load in @('Idle','Loading','Loaded','Error','Refused')){
        $detailU=$null;$detailM=$null;if($load -eq 'Loaded'){$detailU=$script:DU;$detailM=$script:DM}
        $u=Get-DomeniaSelectionPreview $script:SU $load $detailU -ErrorText 'Serveur indisponible'
        $m=Get-DomeniaSelectionPreview $script:SM $load $detailM -ErrorText 'Serveur indisponible'
        Assert-Equal $load $u.State ('Utilisateur '+$load);Assert-Equal $u.State $m.State ('Etat '+$load)
        Assert-Equal $u.ShowDetail $m.ShowDetail ('Detail '+$load);Assert-Equal $u.CanRetry $m.CanRetry ('Relance '+$load);Assert-Equal $u.Stale $m.Stale ('Perime '+$load)
        Assert-Equal ($u.StateText.Replace('Jean Dupont','<cible>')) ($m.StateText.Replace('PC-0042','<cible>')) ('Texte d etat '+$load)
        Assert-Equal ((@($u.Destinations|ForEach-Object{$_.Route})) -join ',') ((@($m.Destinations|ForEach-Object{$_.Route})) -join ',') ('Memes destinations, meme ordre '+$load)
        foreach($route in @('WsObject','TabRelations')){
            $du=@($u.Destinations|Where-Object{$_.Route -eq $route})[0];$dm=@($m.Destinations|Where-Object{$_.Route -eq $route})[0]
            Assert-Equal $du.Enabled $dm.Enabled ($load+' '+$route+' active');Assert-Equal $du.Reason $dm.Reason ($load+' '+$route+' motif')
            Assert-Equal ($load -eq 'Loaded') $du.Enabled ($load+' '+$route+' : active seulement une fois la fiche lue')
        }
    }
    $u=Get-DomeniaSelectionPreview $script:SU Loaded $script:DU;$m=Get-DomeniaSelectionPreview $script:SM Loaded $script:DM
    $common=@('Identifiant','Etat','Emplacement')
    foreach($p in @($u,$m)){Assert-Equal ($common -join ',') ((@($p.Lines|ForEach-Object{$_.Label}|Where-Object{$_ -in $common})) -join ',') ($p.Type+' : libelles communs, meme ordre')}
    Assert-Equal 'jdupont' @($u.Lines|Where-Object{$_.Label -eq 'Identifiant'})[0].Value;Assert-Equal 'pc-0042.example.test' @($m.Lines|Where-Object{$_.Label -eq 'Identifiant'})[0].Value
    Assert-Equal 'Actif' @($m.Lines|Where-Object{$_.Label -eq 'Etat'})[0].Value;Assert-Equal 'OU=Utilisateurs,DC=example,DC=test' @($u.Lines|Where-Object{$_.Label -eq 'Emplacement'})[0].Value
    Assert-Equal 'Non verifiee' @($m.Lines|Where-Object{$_.Label -eq 'Presence'})[0].Value 'Presence non lue : jamais supposee'
    $uc=@($u.Destinations|Where-Object{$_.Route -eq 'WsComputer'})[0];Assert-False $uc.Enabled;Assert-True ($uc.Reason.Length -gt 5) 'Destination non applicable expliquee'
    Assert-True @($m.Destinations|Where-Object{$_.Route -eq 'WsComputer'})[0].Enabled
}
Test-Case 'D085' 'L ancienne fiche ne reste pas visible sous une nouvelle selection' {
    $p=Get-DomeniaSelectionPreview $script:SM Loaded $script:DU
    Assert-False $p.ShowDetail;Assert-True $p.Stale;Assert-Equal 'Loading' $p.State;Assert-Equal 0 @($p.Lines).Count
    Assert-False (($p|ConvertTo-Json -Depth 5) -match 'jdupont') 'Aucune valeur de l ancienne fiche'
    foreach($d in @($p.Destinations)){Assert-False $d.Enabled $d.Route;Assert-True ($d.Reason -match 'Chargement') $d.Route}
    $nextGeneration=[pscustomobject]@{Type='Utilisateur';Name='Jean Dupont';Guid=$script:SU.Guid;Generation='5'}
    Assert-False (Get-DomeniaSelectionPreview $nextGeneration Loaded $script:DU).ShowDetail 'Une lecture d une generation precedente n est pas affichee'
    Assert-False (Get-DomeniaSelectionPreview ([pscustomobject]@{Type='Utilisateur';Name='Sans GUID';Generation='4'}) Loaded $script:DU).ShowDetail 'Sans identite confirmee rien n est affiche'
}
Test-Case 'D085' 'Chargement, erreur et refus sont explicites' {
    $loading=Get-DomeniaSelectionPreview $script:SU Loading;Assert-Equal 'Loading' $loading.State;Assert-True ($loading.StateText -match 'Chargement')
    $e=Get-DomeniaSelectionPreview $script:SU Error -ErrorText 'Serveur indisponible password=SECRET_SENTINEL_D085'
    Assert-Equal 'Error' $e.State;Assert-True ($e.StateText -match 'erreur');Assert-True $e.CanRetry;Assert-False (($e|ConvertTo-Json -Depth 5) -match 'SECRET_SENTINEL_D085') 'Erreur masquee'
    $r=Get-DomeniaSelectionPreview $script:SM Refused;Assert-Equal 'Refused' $r.State;Assert-True ($r.StateText -match 'refusee');Assert-True (Test-DomeniaNoAbsenceClaim $r.StateText)
    $n=Get-DomeniaSelectionPreview $null;Assert-Equal 'None' $n.State;Assert-False $n.ShowDetail;Assert-Equal 3 @($n.Destinations|Where-Object{-not $_.Enabled}).Count
}
Test-Case 'D086' 'Les valeurs qui influencent l operation figurent au resume meme repliees' {
    $options=@(
        [pscustomobject]@{Name='Target';Label='Poste';Value='PC-0042';Default='';Influences=$true;Advanced=$false}
        [pscustomobject]@{Name='Server';Label='Controleur interroge';Value='DC02';Default='';Influences=$true;Advanced=$true}
        [pscustomobject]@{Name='Force';Label='Forcer la mise a jour';Value=$true;Default=$false;Influences=$true;Advanced=$true}
        [pscustomobject]@{Name='ShowTrace';Label='Afficher le detail technique';Value=$false;Default=$false;Influences=$false;Advanced=$true}
    )
    $folded=Get-DomeniaOperationSummary 'GPUpdate' $options $true;$open=Get-DomeniaOperationSummary 'GPUpdate' $options $false
    Assert-Equal $open.Text $folded.Text 'Replier ne change pas le resume'
    Assert-True ($folded.Text -match 'Poste : PC-0042');Assert-True ($folded.Text -match 'Controleur interroge : DC02');Assert-True ($folded.Text -match 'Forcer la mise a jour : Oui')
    Assert-False ($folded.Text -match 'detail technique') 'Une option sans effet laissee par defaut ne charge pas le resume'
    Assert-Equal 2 $folded.FoldedListed;Assert-Equal 0 $open.FoldedListed
}
Test-Case 'D086' 'Une option modifiee reste visible ; un secret ne l est jamais' {
    $s=Get-DomeniaOperationSummary 'Reinitialiser' @([pscustomobject]@{Name='Log';Label='Journal detaille';Value=$true;Default=$false;Influences=$false;Advanced=$true},[pscustomobject]@{Name='Pwd';Label='Mot de passe';Value='SECRET_SENTINEL_D086';Default='';Advanced=$true;Sensitive=$true},[pscustomobject]@{Name='Note';Label='Commentaire';Value='token=SECRET_SENTINEL_D086';Default=''})
    Assert-True ($s.Text -match 'Journal detaille : Oui');Assert-True ($s.Text -match 'Mot de passe : \(masque\)')
    Assert-False (($s|ConvertTo-Json -Depth 5) -match 'SECRET_SENTINEL_D086') 'Aucune valeur secrete dans le resume'
    Assert-True ((Get-DomeniaOperationSummary 'Lire' @()).Text -match 'aucune option')
}
Test-Case 'D086' 'Un mot de passe non signale reste masque ; une option oui/non ou ordinaire reste lisible' {
    $s=Get-DomeniaOperationSummary 'Reinitialiser' @(
        [pscustomobject]@{Name='NewPassword';Label='Nouveau mot de passe';Value='SECRET_SENTINEL_D086B';Default=''}
        [pscustomobject]@{Name='AdmPwd';Label='Valeur';Value='SECRET_SENTINEL_D086C';Default=''}
        [pscustomobject]@{Name='Recovery';Label='Cle de recuperation';Value='SECRET_SENTINEL_D086D';Default=''}
        [pscustomobject]@{Name='ApiToken';Label='Jeton';Value='SECRET_SENTINEL_D086E';Default=''}
        [pscustomobject]@{Name='msLAPS-Password';Label='Compte local';Value='SECRET_SENTINEL_D086F';Default=''}
        [pscustomobject]@{Name='MustChange';Label='Changer le mot de passe a la prochaine ouverture';Value=$true;Default=$false}
        [pscustomobject]@{Name='Target';Label='Compte';Value='jdupont';Default=''}
        [pscustomobject]@{Name='Cycle';Label='Article de cycle';Value='Hebdomadaire';Default=''}
    )
    Assert-False (($s|ConvertTo-Json -Depth 5) -match 'SECRET_SENTINEL_D086') 'Aucune valeur secrete, meme sans indicateur Sensitive'
    Assert-Equal 5 @($s.Lines|Where-Object{$_.Value -eq '(masque)'}).Count 'Chaque secret reste liste, valeur masquee'
    Assert-True ($s.Text -match 'Nouveau mot de passe : \(masque\)')
    Assert-True ($s.Text -match 'Changer le mot de passe a la prochaine ouverture : Oui') 'Une option oui/non qui influence reste lisible'
    Assert-True ($s.Text -match 'Compte : jdupont') 'Une valeur ordinaire reste lisible';Assert-True ($s.Text -match 'Article de cycle : Hebdomadaire') 'Pas de faux secret sur un mot voisin'
    $secure=New-Object Security.SecureString
    Assert-True ((Get-DomeniaOperationSummary 'Definir' @([pscustomobject]@{Name='Valeur';Label='Valeur';Value=$secure;Default=''})).Text -match 'Valeur : \(masque\)') 'Une SecureString n est jamais affichee'
}
Test-Case 'D087' 'Six etats vides distincts, chacun avec sa prochaine action' {
    $kinds=@('NoResult','LocalFilterEmpty','NoSource','NothingQueried','Refused','Partial')
    $states=@(foreach($k in $kinds){Get-DomeniaEmptyState $k -Query 'dupont' -Scope 'OU=Paris' -LocalFilter 'desactive' -Answered 3 -Total 5})
    Assert-Equal 6 @($states|ForEach-Object{$_.Text}|Select-Object -Unique).Count 'Textes distincts'
    Assert-Equal 6 @($states|ForEach-Object{$_.NextAction.Command}|Select-Object -Unique).Count 'Actions distinctes'
    foreach($s in $states){Assert-True (($s.Title.Length -gt 3) -and ($s.NextAction.Label.Length -gt 5)) $s.Kind;Assert-False $s.ProvesAbsence $s.Kind;Assert-False $s.NextAction.Automatic $s.Kind}
    Assert-Equal 'Refuse' @($states|Where-Object{$_.Kind -eq 'Refused'})[0].Etat;Assert-Equal 'TabAccounts' @($states|Where-Object{$_.Kind -eq 'Refused'})[0].NextAction.Route
    Assert-True (@($states|Where-Object{$_.Kind -eq 'Partial'})[0].Text -match '3 source\(s\) sur 5')
    Assert-True (@($states|Where-Object{$_.Kind -eq 'NoResult'})[0].Text -match 'dupont');Assert-True (@($states|Where-Object{$_.Kind -eq 'LocalFilterEmpty'})[0].Text -match '5 resultat')
    Assert-Equal 'ClearLocalFilter' @($states|Where-Object{$_.Kind -eq 'LocalFilterEmpty'})[0].NextAction.Command
    Assert-Equal 'ReadRdpSessions' (Get-DomeniaEmptyState NoResult -Subject Session).NextAction.Command 'Console vide : proposer la lecture RDP'
}
Test-Case 'D087' 'Jamais n existe pas, ni pour un objet ni pour une session' {
    $claims=@(
        'Cet objet n existe pas.','La session nʼexiste plus','Compte introuvable','Il n y a pas de session','Objet absent de l annuaire'
        'Ce compte n est pas dans l annuaire','Le poste n est plus present','Compte inconnu dans l annuaire','Objet inconnu de l annuaire'
        'Le poste ne figure pas dans l annuaire','Compte supprime','Utilisatrice supprimee','User not found','The account no longer exists','Session missing'
    )
    foreach($claim in $claims){Assert-False (Test-DomeniaNoAbsenceClaim $claim) ('Le controle detecte : '+$claim)}
    $neutral=@('Aucun resultat dans ce perimetre','Lecture refusee pour ce compte : la fiche n est pas affichee.','le contenu reel est inconnu.','Une session RDP peut ne pas figurer dans cette lecture.','Supprimer le lien')
    foreach($text in $neutral){Assert-True (Test-DomeniaNoAbsenceClaim $text) ('Texte neutre accepte : '+$text)}
    foreach($subject in @('Objet','Session')){foreach($k in @('NoResult','LocalFilterEmpty','NoSource','NothingQueried','Refused','Partial')){
        $s=Get-DomeniaEmptyState $k -Subject $subject -Query 'x' -Scope 'OU=Paris' -LocalFilter 'actif' -Answered 1 -Total 4
        Assert-True (Test-DomeniaNoAbsenceClaim ($s.Title+' '+$s.Text+' '+$s.NextAction.Label)) ($subject+'/'+$k)
    }}
}
Test-Case 'D088' 'Chaque controle grise a un motif court, lisible a la souris et au clavier' {
    $reasons=@('ReadOnly','NoSelection','WrongType','Busy','Refused','Stale','Offline','Prerequisite','Pending');$texts=@()
    foreach($reason in $reasons){
        $h=Get-DomeniaDisabledHelp 'Deplacer' $reason -ControlName 'BtnMove'
        Assert-True (($h.Short.Length -gt 12) -and ($h.Short.Length -le 160)) $reason;Assert-True ($h.Short -match 'Deplacer') $reason
        Assert-True ($h.HelpText.StartsWith($h.Short,[StringComparison]::Ordinal)) $reason;Assert-Equal $h.Short $h.ToolTip $reason
        Assert-True (Test-DomeniaNoAbsenceClaim $h.Short) ('Un motif ne pretend pas a une absence : '+$reason);$texts+=$h.Short
    }
    Assert-Equal $reasons.Count @($texts|Select-Object -Unique).Count 'Un motif propre a chaque cause'
    Assert-Equal 'WsSearch' (Get-DomeniaDisabledHelp 'Ouvrir' NoSelection).Route;Assert-Equal 'TabGuard' (Get-DomeniaDisabledHelp 'Enregistrer' Pending).Route
    $missing=@(Get-DomeniaMissingDisabledHelp @([pscustomobject]@{Name='BtnA';IsEnabled=$false;ToolTip='';ShowOnDisabled=$true},[pscustomobject]@{Name='BtnB';IsEnabled=$false;ToolTip='Motif';ShowOnDisabled=$false},[pscustomobject]@{Name='BtnC';IsEnabled=$false;ToolTip='Motif';ShowOnDisabled=$true},[pscustomobject]@{Name='BtnD';IsEnabled=$true;ToolTip=''}))
    Assert-Equal 'BtnA,BtnB' ($missing -join ',') 'Controles grises sans motif visible'
}
Test-Case 'D088' 'L aide ne recopie aucun contenu de champ : detail pris dans un catalogue fixe' {
    Assert-Throws { Get-DomeniaDisabledHelp 'Copier' Refused 'Hunter2-Plain!' } 'Une valeur libre en troisieme position est refusee'
    $message='';try{[void](Get-DomeniaDisabledHelp 'Copier' Refused -DetailCode 'SECRET_SENTINEL_D088')}catch{$message=$_.Exception.Message}
    Assert-True ($message.Length -gt 0) 'Code hors catalogue refuse';Assert-False ($message -match 'SECRET_SENTINEL_D088') 'Le refus ne repete pas la valeur rejetee'
    Assert-Throws { Get-DomeniaDisabledHelp 'Copier' Refused -DetailCode 'needsuser' } 'Code exact uniquement'
    $common=@([Management.Automation.PSCmdlet]::CommonParameters)+@([Management.Automation.PSCmdlet]::OptionalCommonParameters)
    $own=@((Get-Command Get-DomeniaDisabledHelp).Parameters.Keys|Where-Object{$_ -notin $common}|Sort-Object)
    Assert-Equal 'Action,ControlName,DetailCode,Reason' ($own -join ',') 'Aucun parametre de texte libre en dehors du libelle d action'
    $catalogue=Get-DomeniaDisabledHelpDetails
    Assert-True (@($catalogue.Keys).Count -ge 10) 'Catalogue de motifs detailles'
    foreach($code in @($catalogue.Keys)){
        $h=Get-DomeniaDisabledHelp 'Deplacer' Busy -DetailCode $code -ControlName 'SECRET_SENTINEL_D088N'
        Assert-True ($h.Short.EndsWith([string]$catalogue[$code],[StringComparison]::Ordinal)) ('Texte fixe du code '+$code);Assert-Equal $code $h.DetailCode
        Assert-False (($h.Short+' '+$h.ToolTip+' '+$h.HelpText+' '+$h.KeyboardHint) -match 'SECRET_SENTINEL_D088N') ('Le nom de controle n entre pas dans les textes : '+$code)
        Assert-True (Test-DomeniaNoAbsenceClaim $h.Short) $code
    }
    $long=Get-DomeniaDisabledHelp ("Copier`r`nle mot de passe "+('x'*200)) Refused -DetailCode 'OtherAccountNeeded'
    Assert-True ($long.Short.Length -le 160) 'Motif borne';Assert-False ($long.Short -match "[`r`n]") 'Motif sur une ligne';Assert-True ($long.Short -match 'Copier le mot de passe') 'Le motif reste lisible'
}
Test-Case 'D089' 'Activation au lancement explicite et au passage login vers principal uniquement' {
    Assert-True (Get-DomeniaActivationDecision ExplicitLaunch).Activate;Assert-True (Get-DomeniaActivationDecision LoginToMain).Activate
    foreach($t in @('TaskCompleted','Background','Notification')){$d=Get-DomeniaActivationDecision $t;Assert-False $d.Activate $t;Assert-False $d.FlashTaskbar $t;Assert-True ($d.Reason -match 'page') $t}
    foreach($t in @('ExplicitLaunch','LoginToMain','TaskCompleted','Background','Notification')){$d=Get-DomeniaActivationDecision $t;Assert-False $d.Topmost $t;Assert-False $d.Retry $t}
}
Test-Case 'D089' 'Une tentative par moment : le lancement ne consomme pas celle du passage vers principal' {
    $log=@{}
    Assert-True (Get-DomeniaActivationDecision ExplicitLaunch -AttemptsByTrigger $log).Activate;$log['ExplicitLaunch']=1
    $main=Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger $log
    Assert-True $main.Activate 'Le passage login vers principal garde sa tentative';Assert-Equal 0 $main.AttemptsForTrigger;$log['LoginToMain']=1
    $again=Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger $log;Assert-False $again.Activate 'Seconde demande au meme moment refusee';Assert-Equal 1 $again.AttemptsForTrigger
    Assert-False (Get-DomeniaActivationDecision ExplicitLaunch -AttemptsByTrigger $log).Activate
    Assert-True (Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger ([pscustomobject]@{ExplicitLaunch=3})).Activate 'Journal objet accepte, seul ce moment compte'
    Assert-False (Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger @{LoginToMain='illisible'}).Activate 'Compte illisible : aucune nouvelle demande'
    Assert-False (Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger @{LoginToMain=-2}).Activate 'Compte negatif : aucune nouvelle demande'
}
Test-Case 'D089' 'Alt-Tab volontaire respecte ; un refus de Windows ne relance pas de forcage' {
    $away=Get-DomeniaActivationDecision LoginToMain -UserSwitchedAway $true;Assert-False $away.Activate;Assert-True $away.FlashTaskbar
    $activations=0;$attempts=0;$refused=$false
    for($i=0;$i -lt 10;$i++){$d=Get-DomeniaActivationDecision ExplicitLaunch -AttemptsByTrigger @{ExplicitLaunch=$attempts} -PreviousRefused $refused;Assert-False $d.Retry;if($d.Activate){$activations++;$attempts++;$refused=$true}}
    Assert-Equal 1 $activations 'Une seule tentative, meme refusee'
    Assert-True (Get-DomeniaActivationDecision ExplicitLaunch -AttemptsByTrigger @{ExplicitLaunch=1} -PreviousRefused $true).FlashTaskbar 'Refus : simple signal'
    Assert-False (Get-DomeniaActivationDecision ExplicitLaunch -AttemptsByTrigger @{ExplicitLaunch=1} -PreviousRefused $false).FlashTaskbar 'Tentative acceptee : aucun signal'
    Assert-False (Get-DomeniaActivationDecision LoginToMain -AttemptsByTrigger @{LoginToMain=1} -PreviousRefused $false).Activate
}
Test-Case 'D090' 'Formule WCAG : bornes connues et cas reel ChkRemember refuse' {
    Assert-True ([Math]::Abs((Get-DomeniaContrastRatio '#000000' '#FFFFFF') - 21.0) -lt 0.001) 'Noir sur blanc 21:1'
    Assert-True ([Math]::Abs((Get-DomeniaContrastRatio '#FFFFFF' '#FFFFFF') - 1.0) -lt 0.001) 'Blanc sur blanc 1:1'
    $chk=Get-DomeniaContrastRatio '#EDF4FF' '#FFFFFF';Assert-True (($chk -gt 1.05) -and ($chk -lt 1.15)) ('ChkRemember attendu vers 1,1:1, obtenu '+$chk)
    $r=Test-DomeniaPaletteContrast @{TextColor='#EDF4FF'} @([pscustomobject]@{Name='ChkRemember login sombre';Foreground='TextColor';Background='#FFFFFF';Kind='Text'})
    Assert-False $r.Passed;Assert-Equal 1 @($r.Failures).Count;Assert-True ($r.Failures[0].Display -match '^1,1') $r.Failures[0].Display;Assert-True ($r.Failures[0].Reason -match '4,5')
    Assert-True ((Get-DomeniaContrastRatio '#777777' '#FFFFFF') -lt 4.5) '#777777 echoue de peu';Assert-True ((Get-DomeniaContrastRatio '#767676' '#FFFFFF') -ge 4.5) '#767676 passe de peu'
    Assert-Equal (Get-DomeniaContrastRatio '#123456' '#ABCDEF') (Get-DomeniaContrastRatio '#ABCDEF' '#123456') 'Symetrique'
    Assert-Equal (Get-DomeniaContrastRatio '#FFF' '#000') (Get-DomeniaContrastRatio '#FFFFFFFF' '#FF000000') 'Formes courte et ARGB'
    Assert-True ([Math]::Abs((Get-DomeniaContrastRatio ([pscustomobject]@{R=0;G=0;B=0}) ([pscustomobject]@{A=255;R=255;G=255;B=255})) - 21.0) -lt 0.001) 'Objet couleur accepte'
}
Test-Case 'D090' 'Seuils 4,5:1 texte normal et 3:1 grand texte ou element graphique' {
    $pairs=@([pscustomobject]@{Foreground='#949494';Background='#FFFFFF';Kind='Text'},[pscustomobject]@{Foreground='#949494';Background='#FFFFFF';Kind='LargeText'},[pscustomobject]@{Foreground='#949494';Background='#FFFFFF';Kind='Graphic'})
    $r=Test-DomeniaPaletteContrast @{} $pairs
    Assert-False $r.Results[0].Passed;Assert-True $r.Results[1].Passed;Assert-True $r.Results[2].Passed;Assert-Equal 4.5 $r.Results[0].Required;Assert-Equal 3.0 $r.Results[1].Required
    Assert-False (Test-DomeniaPaletteContrast @{} @([pscustomobject]@{Foreground='Absente';Background='#FFFFFF'})).Passed 'Une couleur absente n est jamais ignoree'
    Assert-False (Test-DomeniaPaletteContrast @{} @([pscustomobject]@{Foreground='#FFFFFF';Background='#80000000'})).Passed 'Fond non opaque refuse'
    Assert-False (Test-DomeniaPaletteContrast @{} @()).Passed 'Aucun couple : aucun succes'
    Assert-Throws { Get-DomeniaContrastRatio '#FFFFFF' '#80000000' } 'Fond non opaque';Assert-Throws { Get-DomeniaContrastRatio 'bleu' '#FFFFFF' } 'Couleur invalide'
    Assert-True ([Math]::Abs((Get-DomeniaContrastRatio '#80000000' '#FFFFFF') - (Get-DomeniaContrastRatio '#7F7F7F' '#FFFFFF')) -lt 0.01) 'Texte translucide compose sur son fond'
}
Test-Case 'D090' 'Ratio affiche tronque : un contraste juste sous le seuil ne s affiche jamais au seuil' {
    $near=Get-DomeniaContrastRatio '#767776' '#FFFFFF';Assert-True (($near -ge 4.495) -and ($near -lt 4.5)) ('Couleur d essai juste sous 4,5 : '+$near)
    $text=Test-DomeniaPaletteContrast @{} @([pscustomobject]@{Foreground='#767776';Background='#FFFFFF';Kind='Text'})
    Assert-False $text.Passed;Assert-Equal '4,49' $text.Results[0].Display 'Tronque, jamais arrondi a 4,50';Assert-True ($text.Results[0].Reason -match '4,49:1')
    $large=Test-DomeniaPaletteContrast @{} @([pscustomobject]@{Foreground='#67A367';Background='#FFFFFF';Kind='LargeText'})
    Assert-False $large.Passed;Assert-Equal '2,99' $large.Results[0].Display 'Grand texte juste sous 3:1'
}
Test-Case 'D090' 'Palettes livrees : textes principaux au moins 4,5:1 dans les deux themes' {
    $design=[IO.File]::ReadAllText((Join-Path $modules 'SupportSuite.UI.json'))|ConvertFrom-Json
    foreach($theme in @('Dark','Light')){
        $palette=$design.Palettes.$theme;$pairs=New-Object 'System.Collections.Generic.List[object]'
        foreach($fg in @('TextColor','MutedColor','AccentText','StatusError','StatusWarning','StatusSuccess')){foreach($bg in @('WindowBg','BgCard','BgInput','DataGridBg','DataGridAlt')){$pairs.Add([pscustomobject]@{Foreground=$fg;Background=$bg;Kind='Text'})}}
        foreach($p in @(@('BtnFg','BtnBg'),@('RowSelFg','RowSelBg'),@('InfoFg','InfoBg'),@('LogFg','LogBg'))){$pairs.Add([pscustomobject]@{Foreground=$p[0];Background=$p[1];Kind='Text'})}
        $r=Test-DomeniaPaletteContrast $palette $pairs.ToArray()
        Assert-Equal 34 @($r.Results).Count $theme
        Assert-True $r.Passed ($theme+' : '+((@($r.Failures)|ForEach-Object{$_.Name+' '+$_.Display}) -join ', '))
    }
    Assert-False (Test-DomeniaPaletteContrast $design.Palettes.Dark @([pscustomobject]@{Name='ChkRemember';Foreground='TextColor';Background='#FFFFFF'})).Passed 'Texte du theme sombre sur fond blanc fixe : refuse'
}
$script:Primary=[pscustomobject]@{Left=0;Top=0;Width=1920;Height=1040;Primary=$true}
Test-Case 'D090' 'Restauration multi-ecrans : position valide conservee, ecran absent ou trou ramenes' {
    $ok=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=100;Top=80;Width=1200;Height=800}) @($script:Primary)
    Assert-False $ok.Adjusted;Assert-Equal 100 $ok.Left;Assert-Equal 80 $ok.Top;Assert-Equal 1200 $ok.Width;Assert-Equal 800 $ok.Height
    $leftScreen=[pscustomobject]@{Left=-1600;Top=0;Width=1600;Height=860;Primary=$false}
    $neg=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=-1500;Top=40;Width=1200;Height=700}) @($script:Primary,$leftScreen)
    Assert-False $neg.Adjusted 'Un ecran a gauche a des coordonnees negatives valides';Assert-Equal 1 $neg.Monitor;Assert-Equal (-1500) $neg.Left
    $gone=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=2100;Top=100;Width=1200;Height=800}) @($script:Primary)
    Assert-True $gone.Adjusted;Assert-Equal 0 $gone.Monitor;Assert-True ($gone.Reason -match 'absent')
    Assert-True (($gone.Left -ge 0) -and (($gone.Left+$gone.Width) -le 1920) -and ($gone.Top -ge 0) -and (($gone.Top+$gone.Height) -le 1040)) 'Ramenee entierement sur l ecran principal'
    $rightScreen=[pscustomobject]@{Left=1920;Top=0;Width=1280;Height=720;Primary=$false}
    $hole=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=2000;Top=800;Width=600;Height=200}) @($script:Primary,$rightScreen)
    Assert-True $hole.Adjusted 'Le trou d une disposition en L n est pas une position visible';Assert-Equal 0 $hole.Monitor
    $edge=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=2000;Top=600;Width=800;Height=600}) @($script:Primary,$rightScreen)
    Assert-Equal 1 $edge.Monitor;Assert-Equal 120 $edge.Top 'Fenetre a cheval ramenee dans son ecran';Assert-Equal 2000 $edge.Left;Assert-True $edge.Adjusted
}
Test-Case 'D090' 'Fenetre a cheval sur deux ecrans : restauree sur celui qui en porte la plus grande part' {
    $second=[pscustomobject]@{Left=1920;Top=0;Width=1920;Height=1040;Primary=$false}
    $mostRight=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=1800;Top=100;Width=1200;Height=700}) @($script:Primary,$second)
    Assert-Equal 1 $mostRight.Monitor 'Le second ecran porte 1080 px sur 1200';Assert-Equal 1920 $mostRight.Left;Assert-Equal 100 $mostRight.Top;Assert-Equal 1200 $mostRight.Width;Assert-True $mostRight.Adjusted
    $mostLeft=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=1000;Top=100;Width=1200;Height=700}) @($script:Primary,$second)
    Assert-Equal 0 $mostLeft.Monitor 'Le premier ecran porte 920 px sur 1200';Assert-Equal 720 $mostLeft.Left
    $swapped=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=1800;Top=100;Width=1200;Height=700}) @($second,$script:Primary)
    Assert-Equal 0 $swapped.Monitor 'L ordre des ecrans ne change pas le choix';Assert-Equal 1920 $swapped.Left
}
Test-Case 'D090' 'A 200 % la fenetre et ses actions restent atteignables' {
    $small=[pscustomobject]@{Left=0;Top=0;Width=960;Height=520;Primary=$true}
    $r=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=300;Top=200;Width=1400;Height=900}) @($small) -MinWidth 1100 -MinHeight 700
    Assert-True (($r.Width -le 960) -and ($r.Height -le 520) -and ($r.Left -ge 0) -and ($r.Top -ge 0) -and (($r.Left+$r.Width) -le 960) -and (($r.Top+$r.Height) -le 520)) 'Fenetre entierement visible'
    $l=Get-DomeniaReservedLayout -TaskCount 100 -Message ('x'*400) -Scale 2.0 -AvailableWidth 960
    Assert-True ($l.TotalWidth -le 960) ('Largeur reservee '+$l.TotalWidth);Assert-False $l.Clipped 'Rien n est rogne a 200 %';Assert-True ($l.MinimumWidth -le 960)
    Assert-True $l.Actions.Overflow;Assert-Equal $l.Actions.Count ($l.Actions.Visible+$l.Actions.InOverflow) 'Chaque action reste atteignable'
    Assert-False (Get-DomeniaReservedLayout -AvailableWidth 1600).Actions.Overflow 'Pleine largeur : aucune action deplacee'
    $bad=Get-DomeniaBoundedWindowRect ([pscustomobject]@{Left=0;Top=0;Width=0;Height=0}) @($small);Assert-True $bad.Adjusted 'Taille enregistree invalide';Assert-True ($bad.Width -le 960)
    Assert-True (Get-DomeniaBoundedWindowRect $null @()).UseSystemPlacement 'Aucun ecran connu'
}
Test-Case 'D090' 'Un statut ne repose pas seulement sur une couleur' {
    $names=@('Success','Observed','Estimated','Warning','Partial','Error','Refused','Uncertain','Pending','Unknown','Unavailable','Empty','NoChange','Info')
    $all=@(foreach($n in $names){Get-DomeniaStatusGlyph $n})
    foreach($g in $all){Assert-True (($g.Glyph.Length -ge 1) -and ($g.Text.Length -ge 3)) $g.Status;Assert-Equal $g.Text $g.AutomationName $g.Status;Assert-True $g.Recognized $g.Status}
    Assert-Equal ($names -join ',') ((@($all|ForEach-Object{$_.Status})) -join ',') 'Chaque statut du catalogue se retrouve'
    Assert-Equal $names.Count @($all|ForEach-Object{$_.Glyph}|Select-Object -Unique).Count 'Glyphes distincts'
    Assert-Equal $names.Count @($all|ForEach-Object{$_.Text}|Select-Object -Unique).Count 'Mots distincts'
    $e=Get-DomeniaStatusGlyph 'Error';$x=Get-DomeniaStatusGlyph 'Refused'
    Assert-Equal $e.ColorKey $x.ColorKey;Assert-True (($e.Glyph -cne $x.Glyph) -and ($e.Text -cne $x.Text)) 'Meme couleur, statuts distingues sans elle'
    $odd=Get-DomeniaStatusGlyph 'Inattendu';Assert-Equal 'Unknown' $odd.Status 'Statut inconnu : jamais un succes';Assert-False $odd.Recognized 'Statut non reconnu signale'
    Assert-Equal 'Unknown' (Get-DomeniaStatusGlyph '').Status;Assert-False (Get-DomeniaStatusGlyph '').Recognized
    Assert-Equal 'Refused' (Get-DomeniaStatusGlyph 'Refuse').Status;Assert-Equal 'Observed' (Get-DomeniaStatusGlyph 'constate').Status
    Assert-False ((Get-DomeniaStatusGlyph 'Uncertain').Text -match '(?i)reussi|confirme') 'Une issue incertaine n est pas annoncee reussie'
}
Test-Case 'D090' 'Le vocabulaire reel des modeles est reconnu et jamais rendu Inconnu' {
    $g1='CN=G1,DC=example,DC=test';$g2='CN=G2,DC=example,DC=test';$g3='CN=G3,DC=example,DC=test'
    $delta=[pscustomobject]@{Operations=@([pscustomobject]@{Label='Ajouter a G1';GroupDn=$g1;Expected=$true},[pscustomobject]@{Label='Retirer de G2';GroupDn=$g2;Expected=$false},[pscustomobject]@{Label='Ajouter a G3';GroupDn=$g3;Expected=$true})}
    $mixed=Test-DomeniaGroupDeltaPostcondition $delta @{$g1=$true;$g2=$true}
    $produced=@($mixed.Rows|ForEach-Object{$_.Status})+@($mixed.Overall)
    $produced+=(Test-DomeniaGroupDeltaPostcondition $delta @{$g1=$true;$g2=$false;$g3=$true}).Overall
    $produced+=(Test-DomeniaGroupDeltaPostcondition $delta @{$g1=$true;$g2=$false}).Overall
    $produced+=(Test-DomeniaGroupDeltaPostcondition ([pscustomobject]@{Operations=@()}) @{}).Overall
    $expected=@{'Verifie'='Success';'Echec'='Error';'A verifier'='Uncertain';'Partiel'='Partial';'Aucun changement'='NoChange'}
    foreach($word in @($expected.Keys)){Assert-True ($produced -contains $word) ('Statut produit par la postcondition : '+$word)}
    foreach($word in $produced){$g=Get-DomeniaStatusGlyph $word;Assert-True $g.Recognized $word;Assert-Equal $expected[$word] $g.Status $word}
    $etats=@((Get-Command New-DomeniaFact).Parameters['Etat'].Attributes|Where-Object{$_ -is [Management.Automation.ValidateSetAttribute]}|ForEach-Object{$_.ValidValues})
    Assert-True ($etats.Count -ge 5) 'Etats de New-DomeniaFact lus'
    foreach($etat in $etats){Assert-True (Get-DomeniaStatusGlyph $etat).Recognized ('Etat de fait : '+$etat)}
    Assert-Equal 'Unknown' (Get-DomeniaStatusGlyph 'Inconnu').Status;Assert-Equal 'Unavailable' (Get-DomeniaStatusGlyph 'Indisponible').Status
    # Words of the core collectors (Domenia-Core.ps1) and of the continuity reader (Domenia-Continuity.Model.ps1).
    $core=@{OK='Success';VIDE='Empty';PARTIEL='Partial';ERREUR='Error';REFUSE='Refused';INDISPONIBLE='Unavailable';Unconfirmed='Uncertain';Incertain='Uncertain';Reussi='Success'}
    foreach($word in @($core.Keys)){Assert-Equal $core[$word] (Get-DomeniaStatusGlyph $word).Status $word}
    Assert-Equal 'Success' (Get-DomeniaStatusGlyph ('V'+[char]0xE9+'rifi'+[char]0xE9)).Status 'Accents ignores'
    Assert-Equal 'Refused' (Get-DomeniaStatusGlyph ('Acc'+[char]0xE8+'s refus'+[char]0xE9)).Status 'Libelle du lecteur de sessions'
    Assert-Equal 'Uncertain' (Get-DomeniaStatusGlyph '  A  VERIFIER ').Status 'Casse et espaces ignores'
    Assert-Equal 'Error' (Get-DomeniaStatusGlyph 'Echec').Status 'Un echec confirme n est jamais Inconnu'
}
# ---------------------------------------------------------------- L08 header, menu, read-only return, profile and session badge
Test-Case 'L08-UI01' 'Titre de fenetre « Fiche · nom — Domenia », libelles du menu et puce du sujet' {
    $t=Get-DomeniaPageTitle -Page 'WsObject' -TargetName 'Camille Martin' -TargetType 'Utilisateur'
    Assert-Equal 'Fiche · Camille Martin — Domenia' $t.WindowTitle
    Assert-Equal 'Utilisateur · Camille Martin' $t.Chip
    $p=Get-DomeniaPageTitle -Page 'WsComputer' -TargetName 'PC-COMPTA-014' -TargetType 'Machine'
    Assert-Equal 'Poste · PC-COMPTA-014' $p.Header;Assert-Equal 'Poste · PC-COMPTA-014' $p.Chip
    Assert-Equal 'Poste · PC-COMPTA-014 — Domenia' $p.WindowTitle
    Assert-Equal 'Utilisateurs et postes' (Get-DomeniaPageTitle -Page 'TabRelations').PageLabel
    Assert-Equal '' (Get-DomeniaPageTitle -Page 'WsObject').Chip 'Sans sujet, aucune puce'
    $demo=Get-DomeniaPageTitle -Page 'TabDashboard' -ApplicationName 'Domenia 1.0 · DÉMONSTRATION'
    Assert-True ($demo.WindowTitle.EndsWith('— Domenia 1.0 · DÉMONSTRATION',[StringComparison]::Ordinal)) 'Le bandeau de demonstration reste dans le titre'
    $labels=@(Get-DomeniaShellPages|ForEach-Object{$_.Label})
    Assert-True ($labels -contains 'Poste') 'Assistance poste devient Poste';Assert-False ($labels -contains 'Assistance poste')
    $preview=Get-DomeniaSelectionPreview ([pscustomobject]@{Type='Machine';Name='PC-1';Guid='11111111-1111-1111-1111-111111111111';Generation='1'})
    Assert-Equal 'Ouvrir la fiche,Utilisateurs et postes,Poste' ((@($preview.Destinations|ForEach-Object{$_.Label})) -join ',')
}
Test-Case 'L08-SE06' 'Retour en lecture seule apres le delai sans ecriture, jamais pendant une ecriture' {
    $t0=[datetime]'2026-10-09T10:00:00'
    $off=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $false -Now $t0
    Assert-Equal 'Lecture seule' $off.Label;Assert-False $off.Expired;Assert-False $off.Deferred
    $p=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -Now $t0.AddMinutes(3)
    Assert-Equal 15 $p.DelayMinutes 'Delai par defaut';Assert-Equal 'Écriture active · 12 min' $p.Label;Assert-False $p.Expired
    $p=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -Now $t0.AddMinutes(14).AddSeconds(30)
    Assert-Equal 'Écriture active · 1 min' $p.Label;Assert-False $p.Expired
    $p=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -Now $t0.AddMinutes(15)
    Assert-True $p.Expired 'Retour au bout de 15 min sans ecriture';Assert-Equal 0 $p.RemainingSeconds
    $p=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -Now $t0.AddMinutes(40) -WriteInProgress $true
    Assert-False $p.Expired 'Une ecriture en cours n est jamais interrompue';Assert-True $p.Deferred;Assert-True ($p.Label -match 'en cours')
    $p=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -LastWriteAt $t0.AddMinutes(10) -Now $t0.AddMinutes(20)
    Assert-False $p.Expired 'La derniere ecriture relance le delai';Assert-Equal 5 $p.RemainingMinutes
    Assert-True (Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -EnabledAt $t0 -LastWriteAt $t0.AddMinutes(10) -Now $t0.AddMinutes(25)).Expired
    Assert-Equal 5 (Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -DelayMinutes 1 -Now $t0).DelayMinutes 'Borne basse'
    Assert-Equal 120 (Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -DelayMinutes 500 -Now $t0).DelayMinutes 'Borne haute'
    Assert-Equal 15 (Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -DelayMinutes 'abc' -Now $t0).DelayMinutes 'Valeur illisible'
    $unknown=Get-DomeniaReadOnlyReturnPlan -WriteEnabled $true -Now $t0
    Assert-False $unknown.Expired 'Sans date connue, le delai part de maintenant';Assert-Equal 15 $unknown.RemainingMinutes
    Assert-True ($p.ToolTip -match 'jamais interrompue') 'L infobulle le dit'
}
Test-Case 'L08-DS10' 'Icone du theme vise, meme dessin dans la fenetre et la connexion' {
    $light=Get-DomeniaThemeToggleIcon 'Light';$dark=Get-DomeniaThemeToggleIcon 'Dark'
    Assert-Equal 'Moon' $light.Glyph;Assert-Equal 'Dark' $light.Target;Assert-Equal 'Passer au thème sombre' $light.Name
    Assert-Equal 'Sun' $dark.Glyph;Assert-Equal 'Light' $dark.Target;Assert-Equal 'Passer au thème clair' $dark.Name
    Assert-Equal 'Moon' (Get-DomeniaThemeToggleIcon 'autre').Glyph 'Theme inconnu traite comme clair'
    Assert-Equal 'Sun' (Get-DomeniaThemeToggleIcon ' dark ').Glyph 'Casse et espaces ignores'
    $core=[IO.File]::ReadAllText((Join-Path $wad 'Domenia-Core.ps1'),[Text.Encoding]::UTF8)
    foreach($data in @($light.SunData,$light.MoonData)){
        $count=([regex]::Matches($core,[regex]::Escape('Data="'+$data+'"'))).Count
        Assert-True ($count -ge 2) ('Dessin partage par la fenetre principale et la connexion : '+$count)
    }
    Assert-False ($core -match 'ThemeIconGlyph') 'Plus d emoji de theme'
}
Test-Case 'L08-SP04' 'Badge de session : connecte, AD injoignable depuis HH:MM, demonstration' {
    Assert-Equal 'Connecté à example.local' (Get-DomeniaSessionBadge -Domain 'example.local').Text
    $off=Get-DomeniaSessionBadge -Domain 'example.local' -Offline $true -OfflineSince ([datetime]'2026-10-09T09:05:00')
    Assert-Equal 'AD injoignable depuis 09:05 · données déjà lues seulement' $off.Text;Assert-Equal 'Offline' $off.State
    Assert-True ($off.ToolTip -match 'Aucune relance') 'Aucune relance automatique annoncee'
    Assert-Equal 'AD injoignable · données déjà lues seulement' (Get-DomeniaSessionBadge -Domain 'x' -Offline $true).Text
    Assert-Equal 'Connecté à example.local' (Get-DomeniaSessionBadge -Domain 'example.local' -Offline $false -OfflineSince ([datetime]'2026-10-09T09:05:00')).Text 'Retour seul au premier succes'
    Assert-Equal 'Pending' (Get-DomeniaSessionBadge).State
    Assert-Equal 'DÉMO' (Get-DomeniaSessionBadge -Domain 'x' -Demo $true -DemoText 'DÉMO').Text
}
Test-Case 'L08-SP04' 'Un delai AD a son propre badge sans annoncer une panne generale' {
    $slow=Get-DomeniaSessionBadge -Domain 'example.local' -Slow $true
    Assert-Equal 'Slow' $slow.State
    Assert-Equal 'Dernière requête AD : délai dépassé' $slow.Text
    Assert-True ($slow.ToolTip -match 'ne confirme pas.*coupure')
    Assert-True ($slow.ToolTip -match 'incomplet')
    Assert-True ($slow.ToolTip -match 'lecture.*réussie')
    Assert-Equal 'Offline' (Get-DomeniaSessionBadge -Domain 'x' -Slow $true -Offline $true).State
    Assert-Equal 'Demo' (Get-DomeniaSessionBadge -Domain 'x' -Slow $true -Offline $true -Demo $true -DemoText 'DÉMO').State
    Assert-Equal 'Connected' (Get-DomeniaSessionBadge -Domain 'example.local' -Slow $false).State
}
Test-Case 'L08-FO03' 'Recherches et fiches recentes : 8 au plus, sans doublon, memoire locale lisible' {
    $list=@()
    for($i=1;$i -le 10;$i++){$list=@(Add-DomeniaRecentEntry -Entries $list -Kind Recherche -Text ('dupont'+$i))}
    Assert-Equal 8 @($list|Where-Object{$_.Kind -eq 'Recherche'}).Count 'Huit recherches au plus'
    Assert-Equal 'dupont10' $list[0].Text 'La plus recente en tete'
    $list=@(Add-DomeniaRecentEntry -Entries $list -Kind Recherche -Text 'DUPONT5')
    Assert-Equal 'DUPONT5' $list[0].Text;Assert-Equal 1 @($list|Where-Object{$_.Text -ieq 'dupont5'}).Count 'Sans doublon, casse ignoree'
    $list=@(Add-DomeniaRecentEntry -Entries $list -Kind Fiche -Text 'Camille Martin' -Type 'Utilisateur' -Dn 'CN=Camille Martin,DC=example,DC=local')
    $list=@(Add-DomeniaRecentEntry -Entries $list -Kind Fiche -Text 'Camille Martin (Paris)' -Type 'Utilisateur' -Dn 'cn=camille martin,dc=example,dc=local')
    Assert-Equal 1 @($list|Where-Object{$_.Kind -eq 'Fiche'}).Count 'Une fiche par DN'
    Assert-Equal 8 @($list|Where-Object{$_.Kind -eq 'Recherche'}).Count 'Les fiches ne chassent pas les recherches'
    $same=@(Add-DomeniaRecentEntry -Entries $list -Kind Recherche -Text '   ')
    Assert-Equal $list.Count $same.Count 'Un texte vide n est pas retenu'
    $json=ConvertTo-Json -InputObject @($list) -Depth 3 -Compress
    $back=@(ConvertFrom-DomeniaRecentJson -Json $json)
    Assert-Equal $list.Count $back.Count 'Relecture JSON';Assert-Equal 'Camille Martin (Paris)' @($back|Where-Object{$_.Kind -eq 'Fiche'})[0].Text
    Assert-Equal 0 @(ConvertFrom-DomeniaRecentJson -Json '{pas du json').Count 'JSON illisible : liste vide'
    Assert-Equal 0 @(ConvertFrom-DomeniaRecentJson -Json '[{"Kind":"Secret","Text":"x"}]').Count 'Type inconnu ignore'
    $long=@(Add-DomeniaRecentEntry -Entries @() -Kind Recherche -Text ("a`r`n"+('b'*300)))
    Assert-True ($long[0].Text.Length -le 80) 'Texte borne';Assert-False ($long[0].Text -match "[`r`n]") 'Une ligne'
    $pc=@(Add-DomeniaRecentEntry -Kind Fiche -Text 'PC-1' -Type 'Machine' -Dn 'CN=PC-1')[0]
    $user=@(Add-DomeniaRecentEntry -Kind Fiche -Text 'Jean' -Type 'Utilisateur' -Dn 'CN=Jean')[0]
    $machines=@(Select-DomeniaRecentEntries -Entries @($pc,$user) -Kind @('Fiche') -Type 'Machine')
    Assert-Equal 1 $machines.Count 'La page Poste ne propose que des postes';Assert-Equal 'PC-1' $machines[0].Text
    $found=@(Select-DomeniaRecentEntries -Entries $list -Text 'DUPONT1')
    Assert-Equal 1 $found.Count 'Filtre par texte contenu, casse ignoree';Assert-Equal 'dupont10' $found[0].Text
}
Test-Case 'L08-FO03' 'Suggestions de la barre : recentes puis base locale, sans doublon, aucune requete AD' {
    $recent=@([pscustomobject]@{Kind='Recherche';Text='dupont';Type='';Dn=''},[pscustomobject]@{Kind='Fiche';Text='PC-COMPTA-014';Type='Machine';Dn='CN=PC'})
    $local=@([pscustomobject]@{Type='Utilisateur';Name='Dupont Jean';Login='jdupont';Display='Jean Dupont'},[pscustomobject]@{Type='Machine';Name='pc-compta-014';Login='PC$';Display=''},[pscustomobject]@{Type='Utilisateur';Name='';Login='duponta';Display=''})
    $items=@(Get-DomeniaSearchSuggestionItems -Recent $recent -LocalRows $local)
    Assert-Equal 'dupont,PC-COMPTA-014,Dupont Jean,duponta' ((@($items|ForEach-Object{$_.Text})) -join ',') 'Recentes d abord, doublon local retire'
    Assert-Equal 'Recherche récente' $items[0].Detail;Assert-Equal 'Fiche récente · Machine' $items[1].Detail;Assert-Equal 'Base locale · Utilisateur · Jean Dupont' $items[2].Detail
    Assert-True (@($items|Where-Object{$_.Source -notin @('Recent','Local')}).Count -eq 0) 'Aucune source annuaire'
    $many=@(for($i=0;$i -lt 20;$i++){[pscustomobject]@{Type='Machine';Name=('PC-'+$i)}})
    Assert-Equal 8 @(Get-DomeniaSearchSuggestionItems -LocalRows $many).Count 'Huit lignes au plus'
}
Test-Case 'L08-CO06' 'Une vue Expert demandee par raccourci, menu ou palette ne change jamais le profil' {
    $d=Get-DomeniaExpertTabDecision -Tab 'TabLog' -Profile 'Tech'
    Assert-True $d.Show;Assert-True $d.Temporary 'Affichee seule, pour cette consultation';Assert-False $d.ChangesProfile
    $d=Get-DomeniaExpertTabDecision -Tab 'TabWmi' -Profile 'Tech' -ObjectType 'Machine'
    Assert-True ($d.Show -and $d.Temporary -and -not $d.ChangesProfile) 'Explorateur WMI depuis le menu contextuel'
    $d=Get-DomeniaExpertTabDecision -Tab 'TabWmi' -Profile 'Tech' -ObjectType 'Utilisateur'
    Assert-False $d.Show 'WMI refuse sur un utilisateur';Assert-True ($d.Reason.Length -gt 5) 'Refus explique'
    $d=Get-DomeniaExpertTabDecision -Tab 'TabLog' -Profile 'Tech' -AllowExpert $false
    Assert-False $d.Show 'Profil Expert masque par l administrateur';Assert-True ($d.Reason -match 'administrateur')
    $d=Get-DomeniaExpertTabDecision -Tab 'TabRaw' -Profile 'Admin' -ObjectType 'Utilisateur'
    Assert-True ($d.Show -and -not $d.Temporary) 'Expert : vue normale'
    $d=Get-DomeniaExpertTabDecision -Tab 'TabGeneric' -Profile 'Tech'
    Assert-True ($d.Show -and -not $d.Expert) 'Vue ordinaire non concernee'
    foreach($tab in @('TabRaw','TabPermissions','TabWmi','TabSelfCheck','TabCmdlets','TabLog')){Assert-False (Get-DomeniaExpertTabDecision -Tab $tab -Profile 'Tech' -ObjectType 'Machine').ChangesProfile $tab}
}
Test-Case 'L08-DS01' 'Boutons-icones de 40 et pastilles fixes dans les emplacements D082' {
    $slots=Get-DomeniaActivityStripSlots
    foreach($name in @('BtnAccessRecovery','BtnSuiteActivity')){$s=@($slots.Slots|Where-Object{$_.Name -eq $name})[0];Assert-Equal 40 ([int]$s.Width) $name;Assert-Equal 40 ([int]$s.Height) $name}
    foreach($name in @('BadgeAccessRecovery','BadgeSuiteActivity')){$s=@($slots.Slots|Where-Object{$_.Name -eq $name})[0];Assert-Equal 24 ([int]$s.Width) $name}
    Assert-Equal '*,252,144,96' ($slots.StripColumns -join ',') 'Bandeau d activite inchange'
    Assert-Equal 'Hidden' $slots.EmptySlotVisibility
}
Test-Case 'SP-05' 'Pour un ticket : une ligne lisible par objet, sans GUID ni DN, OU lisible et secret masque' {
    $pc=[pscustomobject]@{Type='Machine';Name='PC-0042';Login='PC-0042';Association='jdupont';Presence='En ligne';PresenceAge='il y a 5 min';SessionDisplay='EXAMPLE\jdupont';DN='CN=PC-0042,OU=Postes,OU=Lyon,DC=example,DC=test';Guid='0f8fad5b-d9cb-469f-a165-70867728950e';PresenceDetail='Réponse ICMP · 3 ms · 10.0.0.5';PresenceState='Online';Rank='0';Admin=''}
    $line=ConvertTo-DomeniaTicketLine $pc
    Assert-Equal 'Poste · PC-0042 · Compte : jdupont · Présence : En ligne (il y a 5 min) · Utilisateur console : EXAMPLE\jdupont · OU : Lyon / Postes' $line
    Assert-False ($line -match '0f8fad5b') 'Le GUID ne part pas dans un ticket'
    Assert-False ($line -match 'CN=|DC=|OU=') 'Le DN brut ne part pas dans un ticket'
    Assert-False ($line -match '10\.0\.0\.5|Online|Rank') 'Aucun champ interne de la grille'
    $user=[pscustomobject]@{Type='Utilisateur';Name='Dupont, Jean';Login='jdupont';DN='CN=Dupont\, Jean,OU=Utilisateurs,DC=example,DC=test';Presence='Sans objet';SessionDisplay='Non déterminé'}
    Assert-Equal 'Utilisateur · Dupont, Jean · Compte : jdupont · OU : Utilisateurs' (ConvertTo-DomeniaTicketLine $user)
    $unknown=[pscustomobject]@{Type='Machine';Name='PC-0043';Presence='Non vérifié';SessionDisplay='Non déterminé';DN='CN=PC-0043,OU=Postes\2C Etage 2,DC=example,DC=test'}
    Assert-Equal 'Poste · PC-0043 · Présence : Non vérifié · OU : Postes, Etage 2' (ConvertTo-DomeniaTicketLine $unknown)
    $text=ConvertTo-DomeniaTicketText -Rows @($pc,$null,[pscustomobject]@{Type='Groupe';Name="GG`r`npassword=Secret123";Login='gg';DN='CN=GG,DC=example,DC=test'})
    $lines=@($text -split "`r`n")
    Assert-Equal 2 $lines.Count 'Une ligne par objet, jamais une valeur sur plusieurs lignes'
    Assert-False ($text -match 'Secret123') 'Le texte passe par le masquage des secrets'
    Assert-True ($lines[1].StartsWith('Groupe · GG password=***')) $lines[1]
}

