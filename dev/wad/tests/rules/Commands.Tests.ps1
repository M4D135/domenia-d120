# W13 (points 115, 117, 120) : palette de commandes, raccourcis, annulation de presentation. Donnees fictives.
function New-PaletteContext {
    param([bool]$Connected=$true,[string]$Type='',[int]$Rows=0,[bool]$ReadOnly=$false,[bool]$Demo=$false,[hashtable]$Controls=@{},[bool]$Undo=$false,[string]$UndoText='')
    return [pscustomobject]@{Connected=$Connected;SelectionType=$Type;MachineRows=$Rows;ReadOnly=$ReadOnly;Demo=$Demo;UndoAvailable=$Undo;UndoText=$UndoText;Controls=$Controls}
}
function New-PaletteControls {
    param([bool]$Enabled=$true,[bool]$Reachable=$true,[string]$ToolTip='')
    $map=@{}
    foreach($command in @(Get-DomeniaCommandCatalogue)){if([string]$command.Target){$map[[string]$command.Target]=[pscustomobject]@{Reachable=$Reachable;Enabled=$Enabled;ToolTip=$ToolTip}}}
    return $map
}
function Get-PaletteEntry { param([object[]]$Entries,[string]$Id) return @($Entries|Where-Object{$_.Id -ceq $Id})[0] }
Test-Case 'P117' 'Catalogue ferme : identifiants uniques, effets connus, ecritures et secrets portes par leur bouton' {
    $catalogue=@(Get-DomeniaCommandCatalogue)
    Assert-Equal $catalogue.Count @($catalogue|ForEach-Object{$_.Id}|Select-Object -Unique).Count 'Identifiants dupliques'
    $shortcuts=@(Get-DomeniaKeyboardShortcuts|ForEach-Object{$_.Id})
    foreach($c in $catalogue){
        Assert-True ($c.Effect -in @('Navigate','Local','Read','Sensitive','PrepareWrite')) $c.Id
        if($c.Effect -in @('PrepareWrite','Sensitive')){Assert-True ([string]$c.Target -match '^Btn[A-Za-z]+$') ('Ecriture ou secret sans bouton : '+$c.Id)}
        if([string]$c.Shortcut){Assert-True ($shortcuts -contains [string]$c.Shortcut) ('Raccourci inconnu : '+$c.Id)}
        Assert-True ($c.Label.Length -gt 6) $c.Id
    }
    Assert-True (@($catalogue|Where-Object{$_.Effect -eq 'PrepareWrite'}).Count -ge 10) 'Les ecritures courantes sont trouvables'
}
Test-Case 'P117' 'Aucune ecriture n est lancee depuis la palette : le bouton est seulement amene a l ecran' {
    $entries=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur' -Controls (New-PaletteControls)))
    foreach($e in $entries){
        $d=Get-DomeniaPaletteDecision -Entry $e
        if($e.Effect -in @('PrepareWrite','Sensitive')){
            if($e.Available){Assert-Equal 'Focus' $d.Action $e.Id}else{Assert-Equal 'None' $d.Action $e.Id}
            Assert-False ($d.Action -in @('Click','Run')) ('Ecriture ou secret declenche : '+$e.Id)
        }
    }
    $unlock=Get-PaletteEntry $entries 'unlock'
    Assert-True $unlock.Available;Assert-Equal 'BtnUserUnlock' (Get-DomeniaPaletteDecision -Entry $unlock).Target
    Assert-True ((Get-DomeniaPaletteDecision -Entry $unlock).Status.Contains('rien nʼest encore écrit'))
    Assert-True ($unlock.EffectText.Contains('confirmation'))
    $lock=Get-PaletteEntry $entries 'lockouts'
    Assert-Equal 'Click' (Get-DomeniaPaletteDecision -Entry $lock).Action 'Une lecture d un bouton actif part sur Entree'
    Assert-Equal 'Run' (Get-DomeniaPaletteDecision -Entry (Get-PaletteEntry $entries 'search')).Action
    Assert-Equal 'None' (Get-DomeniaPaletteDecision -Entry $null).Action
}
Test-Case 'P117' 'Selon la selection : une action d un autre type d objet dit quoi selectionner' {
    $entries=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Machine' -Controls (New-PaletteControls)))
    $unlock=Get-PaletteEntry $entries 'unlock'
    Assert-False $unlock.Available;Assert-Equal 'Sélectionnez un utilisateur.' $unlock.Reason
    Assert-True (Get-PaletteEntry $entries 'sessions').Available
    Assert-Equal 'Sélectionnez un groupe.' (Get-PaletteEntry $entries 'groupadd').Reason
    $none=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Controls (New-PaletteControls)))
    Assert-Equal 'Ouvrez dʼabord une fiche.' (Get-PaletteEntry $none 'summary').Reason
    Assert-Equal 'Sélectionnez au moins un poste dans la liste.' (Get-PaletteEntry $none 'batch').Reason
    Assert-True (Get-PaletteEntry (@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Rows 3))) 'batch').Available
}
Test-Case 'P117' 'Selon les droits et le mode : lecture seule, demonstration, connexion, bouton grise avec son motif' {
    $ro=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur' -ReadOnly $true -Controls (New-PaletteControls)))
    Assert-True ((Get-PaletteEntry $ro 'resetpassword').Reason.StartsWith('Lecture seule')) 'Lecture seule annoncee'
    Assert-True (Get-PaletteEntry $ro 'lockouts').Available 'Une lecture reste possible en lecture seule'
    $demo=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur' -Demo $true -Controls (New-PaletteControls)))
    Assert-True ((Get-PaletteEntry $demo 'unlock').Reason.Contains('démonstration'))
    $off=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Connected $false -Type 'Utilisateur' -Controls (New-PaletteControls)))
    Assert-Equal 'Connexion à lʼannuaire requise.' (Get-PaletteEntry $off 'lockouts').Reason;Assert-True (Get-PaletteEntry $off 'journal').Available
    $grey=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur' -Controls (New-PaletteControls -Enabled $false -ToolTip 'Deverrouiller : droit insuffisant pour ce compte.')))
    $u=Get-PaletteEntry $grey 'unlock'
    Assert-False $u.Available;Assert-Equal 'Deverrouiller : droit insuffisant pour ce compte.' $u.Reason;Assert-True ($u.Detail.StartsWith('Indisponible : '))
    $hidden=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur' -Controls (New-PaletteControls -Reachable $false)))
    Assert-True ((Get-PaletteEntry $hidden 'unlock').Reason.Contains('non affichée'))
    $absent=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Utilisateur'))
    Assert-Equal 'Action absente de cette page.' (Get-PaletteEntry $absent 'unlock').Reason
}
Test-Case 'P117' 'Recherche sans accents ni majuscules, disponibles d abord, tous les mots requis' {
    $entries=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Type 'Machine' -Controls (New-PaletteControls)))
    $found=@(Select-DomeniaPaletteEntries -Entries $entries -Query 'DETECTER')
    Assert-Equal 'lastuser' $found[0].Id
    Assert-Equal 'index' @(Select-DomeniaPaletteEntries -Entries $entries -Query 'lʼindex')[0].Id
    Assert-Equal 'index' @(Select-DomeniaPaletteEntries -Entries $entries -Query "l'index")[0].Id
    $both=@(Select-DomeniaPaletteEntries -Entries $entries -Query 'compte desactiver')
    Assert-Equal 1 $both.Count;Assert-Equal 'userdisable' $both[0].Id
    Assert-Equal 0 @(Select-DomeniaPaletteEntries -Entries $entries -Query 'xyzzy').Count
    $all=@(Select-DomeniaPaletteEntries -Entries $entries -Query '' -Maximum 200)
    Assert-Equal $entries.Count $all.Count
    $firstUnavailable=[Array]::IndexOf(@($all|ForEach-Object{[bool]$_.Available}),$false)
    Assert-True (@($all|Select-Object -Skip $firstUnavailable|Where-Object{$_.Available}).Count -eq 0) 'Les actions disponibles viennent en premier'
    Assert-Equal 'theme' @(Select-DomeniaPaletteEntries -Entries $entries -Query 'theme')[0].Id 'Le debut du libelle passe avant les mots cles'
    Assert-Equal 5 @(Select-DomeniaPaletteEntries -Entries $entries -Query '' -Maximum 5).Count
}
Test-Case 'P115' 'Raccourcis decouvrables : liste unique, Echap et palette, annonces dans la palette' {
    $shortcuts=@(Get-DomeniaKeyboardShortcuts)
    Assert-Equal $shortcuts.Count @($shortcuts|ForEach-Object{$_.Text}|Select-Object -Unique).Count 'Deux actions sur la meme touche'
    foreach($id in @('Palette','Escape','Search','Undo')){Assert-True (@($shortcuts|Where-Object{$_.Id -eq $id}).Count -eq 1) $id}
    $text=Get-DomeniaShortcutListText
    foreach($s in $shortcuts){Assert-True ($text.Contains([string]$s.Text+' : ')) $s.Id}
    Assert-True ($text.Contains('(dans la liste de résultats)'))
    $entries=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext))
    Assert-Equal 'Ctrl+F' (Get-PaletteEntry $entries 'search').Shortcut
    Assert-True ((Get-PaletteEntry $entries 'shortcuts').Detail.Contains('Échap'))
    Assert-Equal 'Run' (Get-DomeniaPaletteDecision -Entry (Get-PaletteEntry $entries 'shortcuts')).Action
}
function New-P120State {
    param([string]$Sort='',[string]$Filter='',[string]$Presence='Tous',[int]$TypeIndex=1)
    $sorts=@();if($Sort){$sorts=@([pscustomobject]@{Field=$Sort;Direction='Ascending'})}
    return [pscustomobject]@{Columns=@([pscustomobject]@{Key='Nom';Index=0;Width='200';Unit='Pixel'},[pscustomobject]@{Key='Type';Index=$TypeIndex;Width='90';Unit='Pixel'});Sort=$sorts;LocalFilter=$Filter;Presence=$Presence}
}
Test-Case 'P120' 'Annulation de presentation : point de depart, une etape par changement, rien pour un etat identique' {
    $h=New-DomeniaPresentationHistory
    Assert-False (Add-DomeniaPresentationState -History $h -State (New-P120State)) 'Le premier etat est la reference'
    Assert-Equal '' (Get-DomeniaPresentationUndoText $h)
    Assert-False (Add-DomeniaPresentationState -History $h -State (New-P120State))
    Assert-True (Add-DomeniaPresentationState -History $h -State (New-P120State -Sort 'Name'))
    Assert-Equal 'tri' (Get-DomeniaPresentationUndoText $h)
    Assert-True (Add-DomeniaPresentationState -History $h -State (New-P120State -Sort 'Name' -Filter 'compta' -Presence 'En ligne'))
    Assert-Equal 'filtre de la liste, filtre de présence' (Get-DomeniaPresentationUndoText $h)
    $step=Undo-DomeniaPresentationState -History $h
    Assert-Equal '' ([string]$step.State.LocalFilter);Assert-Equal 'Tous' ([string]$step.State.Presence);Assert-Equal 1 $step.Remaining
    $step=Undo-DomeniaPresentationState -History $h
    Assert-Equal 0 @($step.State.Sort).Count;Assert-Equal 'tri' $step.Text
    Assert-True ($null -eq (Undo-DomeniaPresentationState -History $h)) 'Rien a annuler'
}
Test-Case 'P120' 'Dix etapes au plus ; une nouvelle liste devient la reference sans etape' {
    $h=New-DomeniaPresentationHistory -Maximum 10
    [void](Add-DomeniaPresentationState -History $h -State (New-P120State))
    for($i=0;$i -lt 15;$i++){[void](Add-DomeniaPresentationState -History $h -State (New-P120State -Filter ('f'+$i)))}
    Assert-Equal 10 $h.Undo.Count
    Reset-DomeniaPresentationCurrent -History $h -State (New-P120State -Sort 'Rank' -TypeIndex 0)
    Assert-Equal 10 $h.Undo.Count 'Les etapes anterieures restent'
    Assert-False (Add-DomeniaPresentationState -History $h -State (New-P120State -Sort 'Rank' -TypeIndex 0))
    Assert-True (Add-DomeniaPresentationState -History $h -State (New-P120State -Sort 'Rank' -TypeIndex 1))
    Assert-Equal 'colonnes' (Get-DomeniaPresentationUndoText $h)
    $entries=@(Get-DomeniaPaletteEntries -Context (New-PaletteContext -Undo $true -UndoText 'colonnes'))
    Assert-True (Get-PaletteEntry $entries 'undo').Available;Assert-True ((Get-PaletteEntry $entries 'undo').Label.Contains('(colonnes)'))
    Assert-Equal 'Aucune présentation de la liste à annuler.' (Get-PaletteEntry @(Get-DomeniaPaletteEntries -Context (New-PaletteContext)) 'undo').Reason
}
