# P-CD-09 : partie pure de la trace des erreurs ignorees (Add-DomeniaSwallowedEntry, Domenia-Common.Model). Anneau en
# memoire, masquage, echantillonnage de la ligne due, reentree ; la regle n appelle jamais le journal (Write-AppLog est
# appele par Write-DomeniaSwallowed du coeur, verifie dans Test-DomeniaFaults.ps1). Aucune valeur secrete reelle :
# marqueurs factices uniquement.
$script:Sw0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
Test-Case 'P-CD-09' 'Erreur ignoree : entree masquee et bornee, ligne due rendue, aucune exception' {
    $script:DomeniaSwallowedState=$null
    Assert-Equal 0 (@(Get-DomeniaSwallowedEntries)).Count 'Anneau vide avant la premiere trace'
    $due=@(Add-DomeniaSwallowedEntry 'Theme' 'Set-DomeniaTheme' ([InvalidOperationException]::new("Lecture impossible`r`npassword=MARQUEUR-SECRET-0001 fin")) -Now $script:Sw0)
    Assert-Equal 1 $due.Count 'Une seule sortie : la ligne due'
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 1 $entries.Count
    $e=$entries[0]
    Assert-Equal 'Theme' $e.Category;Assert-Equal 'Set-DomeniaTheme' $e.Operation;Assert-Equal 'System.InvalidOperationException' $e.Type
    Assert-True ($e.Message.StartsWith('Lecture impossible password=',[StringComparison]::Ordinal)) ('Message aplati : '+$e.Message)
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0001')) 'Le secret est masque avant d entrer dans l anneau'
    Assert-Equal $script:Sw0 $e.Time
    Assert-Equal 'Unavailable' $e.Journal 'Sans appelant pour l ecrire, la ligne n est pas journalisee'
    Assert-Equal ('Erreur ignorée [Theme] Set-DomeniaTheme : System.InvalidOperationException : '+$e.Message) ([string]$due[0].Line)
    $due[0].Entry.Journal='Logged'
    Assert-Equal 'Logged' (@(Get-DomeniaSwallowedEntries)[0].Journal) 'La ligne due porte l entree de l anneau : l appelant y inscrit l issue'
    try { throw 'token=MARQUEUR-SECRET-0002 refus' } catch { $null=Add-DomeniaSwallowedEntry 'Fiche' 'Read-DomeniaObject' $_ -Now $script:Sw0 }
    $e=@(Get-DomeniaSwallowedEntries)[1]
    Assert-Equal 'System.Management.Automation.RuntimeException' $e.Type 'ErrorRecord lu comme son exception'
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0002'));Assert-True ($e.Message.Contains('refus'))
    $due=@(Add-DomeniaSwallowedEntry 'Divers' 'Sans-Erreur' -Now $script:Sw0)
    $e=@(Get-DomeniaSwallowedEntries)[2]
    Assert-Equal '' $e.Type;Assert-Equal '' $e.Message
    Assert-Equal 'Erreur ignorée [Divers] Sans-Erreur' ([string]$due[0].Line) 'Ni type ni message : la ligne garde categorie et operation'
    $null=Add-DomeniaSwallowedEntry 'Divers' 'Long' ([InvalidOperationException]::new(('x'*1000))) -Now $script:Sw0
    $e=@(Get-DomeniaSwallowedEntries)[3]
    Assert-True ($e.Message.Length -le 300) ('Message borne : '+$e.Message.Length)
    Assert-Equal 4 ([long]$script:DomeniaSwallowedState.Total)
}
Test-Case 'P-CD-09' 'Ligne due : une par categorie et operation et par minute, la regle n appelle jamais le journal' {
    $script:DomeniaSwallowedState=$null
    $script:SwJournalCalls=0
    function Write-AppLog { param([string]$Text,[string]$Level,[string]$Area) $script:SwJournalCalls++ }
    $err=[InvalidOperationException]::new('secret=MARQUEUR-SECRET-0003 fichier verrouille')
    $lines=New-Object 'System.Collections.Generic.List[string]'
    foreach($call in @(@('Theme',0),@('Theme',10),@('Theme',59),@('Fiche',5),@('Theme',61),@('Theme',200))){
        $due=@(Add-DomeniaSwallowedEntry $call[0] 'Apply' $err -Now ($script:Sw0.AddSeconds([int]$call[1])))
        Assert-True ($due.Count -le 1) 'Au plus une ligne due par appel'
        foreach($d in $due){ $lines.Add([string]$d.Line) }
    }
    Assert-Equal 'Unavailable,Sampled,Sampled,Unavailable,Unavailable,Unavailable' ((@(Get-DomeniaSwallowedEntries)|ForEach-Object{$_.Journal}) -join ',')
    Assert-Equal 4 $lines.Count 'Une ligne par cle et par minute'
    Assert-Equal 0 ([int]$script:SwJournalCalls) 'La regle pure n ecrit ni journal ni disque'
    foreach($line in $lines){ Assert-False ($line.Contains('MARQUEUR-SECRET-0003')) 'Aucun secret dans la ligne due' }
    Assert-True ($lines[0].StartsWith('Erreur ignorée [Theme] Apply : System.InvalidOperationException : ',[StringComparison]::Ordinal)) $lines[0]
    Assert-True ($lines[1].StartsWith('Erreur ignorée [Fiche] Apply',[StringComparison]::Ordinal)) 'Une autre categorie a sa propre cle'
    Assert-True ($lines[2].EndsWith('(+2 occurrence(s) depuis la ligne précédente)',[StringComparison]::Ordinal)) $lines[2]
    Assert-False ($lines[3].Contains('occurrence(s)')) 'Le compteur repart a zero apres chaque ligne'
}
Test-Case 'P-CD-09' 'Anneau borne a 200 entrees, les plus anciennes sortent en premier' {
    $script:DomeniaSwallowedState=$null
    for($i=0;$i -lt 250;$i++){ $null=Add-DomeniaSwallowedEntry 'Charge' ('op-'+$i) ([InvalidOperationException]::new('echec')) -Now $script:Sw0 }
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 200 $entries.Count
    Assert-Equal 'op-50' $entries[0].Operation;Assert-Equal 'op-249' $entries[199].Operation
    Assert-Equal 250 ([long]$script:DomeniaSwallowedState.Total)
    Assert-True ($script:DomeniaSwallowedState.Sampling.Count -le 512) 'Cles d echantillonnage bornees'
    for($i=250;$i -lt 600;$i++){ $null=Add-DomeniaSwallowedEntry 'Charge' ('op-'+$i) 'echec' -Now $script:Sw0 }
    Assert-True ($script:DomeniaSwallowedState.Sampling.Count -le 512) ('Cles d echantillonnage bornees : '+$script:DomeniaSwallowedState.Sampling.Count)
    Assert-Equal 200 (@(Get-DomeniaSwallowedEntries)).Count
}
Test-Case 'P-CD-09' 'Masquage : regle fournie d abord, repli sur Protect-DomeniaSecretText, message abandonne sans regle' {
    $script:DomeniaSwallowedState=$null
    $null=Add-DomeniaSwallowedEntry 'Secrets' 'Copy' ([InvalidOperationException]::new('copie de Valeur-0004 refusee')) -Now $script:Sw0 -Mask { param([string]$Text) $Text.Replace('Valeur-0004','[SECRET MASQUE]') }
    $e=@(Get-DomeniaSwallowedEntries)[0]
    Assert-Equal 'copie de [SECRET MASQUE] refusee' $e.Message 'La regle fournie par l appelant masque le message'
    $null=Add-DomeniaSwallowedEntry 'Stockage' 'Save' ([InvalidOperationException]::new('pwd=MARQUEUR-SECRET-0005 disque plein')) -Now $script:Sw0 -Mask { param([string]$Text) throw 'regle cassee' }
    $e=@(Get-DomeniaSwallowedEntries)[1]
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0005')) 'Repli sur Protect-DomeniaSecretText quand la regle fournie leve'
    Assert-True ($e.Message.Contains('disque plein'))
    Assert-False ([bool]$script:DomeniaSwallowedState.Busy) 'Le verrou de reentree est relache apres un echec'
    function Protect-DomeniaSecretText { param([string]$Text) throw 'regle absente' }
    $out=@(Add-DomeniaSwallowedEntry 'Stockage' 'Load' ([InvalidOperationException]::new('pwd=MARQUEUR-SECRET-0006')) -Now $script:Sw0)
    $e=@(Get-DomeniaSwallowedEntries)[2]
    Assert-Equal 'Stockage' $e.Category;Assert-Equal 'Load' $e.Operation
    Assert-Equal '[message non conservé : aucune règle de masquage chargée]' $e.Message 'Sans regle de masquage le message n est pas conserve'
    Assert-False (([string]$out[0].Line).Contains('MARQUEUR-SECRET-0006')) 'La ligne due ne garde pas le message non masque'
}
Test-Case 'P-CD-09' 'Reentree : la trace emise pendant une trace ne garde que categorie, operation et type' {
    $script:DomeniaSwallowedState=$null
    $script:SwMaskCalls=0
    $mask={ param([string]$Text) $script:SwMaskCalls++; $null=Add-DomeniaSwallowedEntry 'Masque' 'Protect' ([InvalidOperationException]::new('secret=MARQUEUR-SECRET-0007')); return (Protect-DomeniaSecretText $Text) }
    $due=@(Add-DomeniaSwallowedEntry 'Theme' 'Apply' ([InvalidOperationException]::new('echec visible')) -Now $script:Sw0 -Mask $mask)
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 4 $entries.Count 'Trois reentrees depuis le masquage, puis la trace'
    Assert-Equal 'Reentry,Reentry,Reentry,Unavailable' (($entries|ForEach-Object{$_.Journal}) -join ',')
    Assert-Equal 3 ([int]$script:SwMaskCalls) 'Une reentree n appelle pas le masquage'
    foreach($e in @($entries|Where-Object{$_.Journal -eq 'Reentry'})){
        Assert-Equal '' $e.Message 'Message non conserve en reentree';Assert-Equal 'System.InvalidOperationException' $e.Type
        Assert-Equal 'Masque' $e.Category
    }
    Assert-Equal 'echec visible' $entries[3].Message
    Assert-Equal 1 $due.Count 'La trace principale rend sa ligne, les reentrees aucune'
    Assert-False ([bool]$script:DomeniaSwallowedState.Busy)
    $out=@(Add-DomeniaSwallowedEntry 'Journal' 'Write-AppLog' ([InvalidOperationException]::new('token=MARQUEUR-SECRET-0008')) -Now $script:Sw0 -Mask $mask -Reentry)
    Assert-Equal 0 $out.Count 'Une reentree declaree ne rend aucune ligne'
    $last=@(Get-DomeniaSwallowedEntries)[-1]
    Assert-Equal 'Reentry' $last.Journal;Assert-Equal '' $last.Message;Assert-Equal 'Journal' $last.Category
    Assert-Equal 3 ([int]$script:SwMaskCalls) 'Le commutateur -Reentry n appelle pas le masquage'
    foreach($e in @(Get-DomeniaSwallowedEntries)){ Assert-False (($e.Message+$e.Operation+$e.Category).Contains('MARQUEUR-SECRET')) }
    $after=@(Add-DomeniaSwallowedEntry 'Theme' 'Apres' 'texte' -Now $script:Sw0)
    Assert-Equal 1 $after.Count;Assert-Equal 'Unavailable' $after[0].Entry.Journal 'Les appels suivants ne sont plus des reentrees'
    $script:DomeniaSwallowedState=$null
}
