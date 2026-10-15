# P-CD-09 : trace des erreurs ignorees (Write-DomeniaSwallowed, Domenia-Common.Model). Anneau en memoire, masquage,
# echantillonnage du journal, reentree. Aucune valeur secrete reelle : marqueurs factices uniquement.
$script:Sw0=[datetime]::SpecifyKind([datetime]'2026-01-01T10:00:00',[DateTimeKind]::Utc)
Test-Case 'P-CD-09' 'Erreur ignoree : entree masquee et bornee, aucune sortie ni exception' {
    $script:DomeniaSwallowedState=$null
    Assert-Equal 0 (@(Get-DomeniaSwallowedEntries)).Count 'Anneau vide avant la premiere trace'
    $out=@(Write-DomeniaSwallowed 'Theme' 'Set-DomeniaTheme' ([InvalidOperationException]::new("Lecture impossible`r`npassword=MARQUEUR-SECRET-0001 fin")) -Now $script:Sw0)
    Assert-Equal 0 $out.Count 'Rien sur le pipeline'
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 1 $entries.Count
    $e=$entries[0]
    Assert-Equal 'Theme' $e.Category;Assert-Equal 'Set-DomeniaTheme' $e.Operation;Assert-Equal 'System.InvalidOperationException' $e.Type
    Assert-True ($e.Message.StartsWith('Lecture impossible password=',[StringComparison]::Ordinal)) ('Message aplati : '+$e.Message)
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0001')) 'Le secret est masque avant d entrer dans l anneau'
    Assert-Equal $script:Sw0 $e.Time
    Assert-Equal 'Unavailable' $e.Journal 'Sans le coeur, aucun journal applicatif'
    try { throw 'token=MARQUEUR-SECRET-0002 refus' } catch { Write-DomeniaSwallowed 'Fiche' 'Read-DomeniaObject' $_ -Now $script:Sw0 }
    $e=@(Get-DomeniaSwallowedEntries)[1]
    Assert-Equal 'System.Management.Automation.RuntimeException' $e.Type 'ErrorRecord lu comme son exception'
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0002'));Assert-True ($e.Message.Contains('refus'))
    Write-DomeniaSwallowed 'Divers' 'Sans-Erreur' -Now $script:Sw0
    $e=@(Get-DomeniaSwallowedEntries)[2]
    Assert-Equal '' $e.Type;Assert-Equal '' $e.Message
    Write-DomeniaSwallowed 'Divers' 'Long' ([InvalidOperationException]::new(('x'*1000))) -Now $script:Sw0
    $e=@(Get-DomeniaSwallowedEntries)[3]
    Assert-True ($e.Message.Length -le 300) ('Message borne : '+$e.Message.Length)
    Assert-Equal 4 ([long]$script:DomeniaSwallowedState.Total)
}
Test-Case 'P-CD-09' 'Journal applicatif : une ligne DEBUG Technique par categorie et operation et par minute' {
    $script:DomeniaSwallowedState=$null
    $lines=New-Object 'System.Collections.Generic.List[object]'
    function Write-AppLog { param([string]$Text,[string]$Level='INFO',[string]$Area='Journal') $lines.Add([pscustomobject]@{Text=$Text;Level=$Level;Area=$Area}) }
    function Protect-DomeniaLogText { param([string]$Text) return (Protect-DomeniaSecretText $Text) }
    $err=[InvalidOperationException]::new('secret=MARQUEUR-SECRET-0003 fichier verrouille')
    Write-DomeniaSwallowed 'Theme' 'Apply' $err -Now $script:Sw0
    Write-DomeniaSwallowed 'Theme' 'Apply' $err -Now ($script:Sw0.AddSeconds(10))
    Write-DomeniaSwallowed 'Theme' 'Apply' $err -Now ($script:Sw0.AddSeconds(59))
    Write-DomeniaSwallowed 'Fiche' 'Apply' $err -Now ($script:Sw0.AddSeconds(5))
    Write-DomeniaSwallowed 'Theme' 'Apply' $err -Now ($script:Sw0.AddSeconds(61))
    Write-DomeniaSwallowed 'Theme' 'Apply' $err -Now ($script:Sw0.AddSeconds(200))
    Assert-Equal 'Logged,Sampled,Sampled,Logged,Logged,Logged' ((@(Get-DomeniaSwallowedEntries)|ForEach-Object{$_.Journal}) -join ',')
    Assert-Equal 4 $lines.Count 'Une ligne par cle et par minute'
    foreach($line in $lines){
        Assert-Equal 'DEBUG' $line.Level;Assert-Equal 'Technique' $line.Area
        Assert-False ($line.Text.Contains('MARQUEUR-SECRET-0003')) 'Aucun secret dans le journal'
    }
    Assert-True ($lines[0].Text.StartsWith('Erreur ignorée [Theme] Apply : System.InvalidOperationException : ',[StringComparison]::Ordinal)) $lines[0].Text
    Assert-True ($lines[1].Text.StartsWith('Erreur ignorée [Fiche] Apply',[StringComparison]::Ordinal)) 'Une autre categorie a sa propre cle'
    Assert-True ($lines[2].Text.EndsWith('(+2 occurrence(s) depuis la ligne précédente)',[StringComparison]::Ordinal)) $lines[2].Text
    Assert-False ($lines[3].Text.Contains('occurrence(s)')) 'Le compteur repart a zero apres chaque ligne'
}
Test-Case 'P-CD-09' 'Anneau borne a 200 entrees, les plus anciennes sortent en premier' {
    $script:DomeniaSwallowedState=$null
    function Write-AppLog { param([string]$Text,[string]$Level,[string]$Area) }
    function Protect-DomeniaLogText { param([string]$Text) return $Text }
    for($i=0;$i -lt 250;$i++){ Write-DomeniaSwallowed 'Charge' ('op-'+$i) ([InvalidOperationException]::new('echec')) -Now $script:Sw0 }
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 200 $entries.Count
    Assert-Equal 'op-50' $entries[0].Operation;Assert-Equal 'op-249' $entries[199].Operation
    Assert-Equal 250 ([long]$script:DomeniaSwallowedState.Total)
    Assert-True ($script:DomeniaSwallowedState.Sampling.Count -le 512) 'Cles d echantillonnage bornees'
    for($i=250;$i -lt 600;$i++){ Write-DomeniaSwallowed 'Charge' ('op-'+$i) 'echec' -Now $script:Sw0 }
    Assert-True ($script:DomeniaSwallowedState.Sampling.Count -le 512) ('Cles d echantillonnage bornees : '+$script:DomeniaSwallowedState.Sampling.Count)
    Assert-Equal 200 (@(Get-DomeniaSwallowedEntries)).Count
}
Test-Case 'P-CD-09' 'Jamais d exception : journal en echec, masquage absent, reentree depuis le masquage' {
    $script:DomeniaSwallowedState=$null
    function Write-AppLog { param([string]$Text,[string]$Level,[string]$Area) throw 'journal indisponible' }
    function Protect-DomeniaLogText { param([string]$Text) throw 'regle cassee' }
    Write-DomeniaSwallowed 'Stockage' 'Save' ([InvalidOperationException]::new('pwd=MARQUEUR-SECRET-0004 disque plein')) -Now $script:Sw0
    $e=@(Get-DomeniaSwallowedEntries)[0]
    Assert-Equal 'Unavailable' $e.Journal 'Un journal qui leve ne remonte pas'
    Assert-False ($e.Message.Contains('MARQUEUR-SECRET-0004')) 'Repli sur Protect-DomeniaSecretText'
    Assert-False ([bool]$script:DomeniaSwallowedState.Busy) 'Le verrou de reentree est relache apres un echec'
    function Protect-DomeniaSecretText { param([string]$Text) throw 'regle absente' }
    Write-DomeniaSwallowed 'Stockage' 'Load' ([InvalidOperationException]::new('pwd=MARQUEUR-SECRET-0005')) -Now $script:Sw0
    $e=@(Get-DomeniaSwallowedEntries)[1]
    Assert-Equal 'Stockage' $e.Category;Assert-Equal 'Load' $e.Operation
    Assert-Equal '[message non conservé : aucune règle de masquage chargée]' $e.Message 'Sans regle de masquage le message n est pas conserve'
}
Test-Case 'P-CD-09' 'Reentree : la trace emise pendant une trace ne garde que categorie, operation et type' {
    $script:DomeniaSwallowedState=$null
    $lines=New-Object 'System.Collections.Generic.List[string]'
    function Write-AppLog { param([string]$Text,[string]$Level,[string]$Area) Write-DomeniaSwallowed 'Journal' 'Write-AppLog' ([InvalidOperationException]::new('token=MARQUEUR-SECRET-0006')); $lines.Add($Text) }
    function Protect-DomeniaLogText { param([string]$Text) Write-DomeniaSwallowed 'Masque' 'Protect' ([InvalidOperationException]::new('secret=MARQUEUR-SECRET-0007')); return (Protect-DomeniaSecretText $Text) }
    Write-DomeniaSwallowed 'Theme' 'Apply' ([InvalidOperationException]::new('echec visible')) -Now $script:Sw0
    $entries=@(Get-DomeniaSwallowedEntries)
    Assert-Equal 5 $entries.Count 'Trois reentrees du masquage, la trace, une reentree du journal'
    Assert-Equal 'Reentry,Reentry,Reentry,Logged,Reentry' (($entries|ForEach-Object{$_.Journal}) -join ',')
    foreach($e in @($entries|Where-Object{$_.Journal -eq 'Reentry'})){
        Assert-Equal '' $e.Message 'Message non conserve en reentree';Assert-Equal 'System.InvalidOperationException' $e.Type
    }
    Assert-Equal 'Masque' $entries[0].Category;Assert-Equal 'Journal' $entries[4].Category
    Assert-Equal 'echec visible' $entries[3].Message
    Assert-Equal 1 $lines.Count 'La trace principale atteint le journal une fois'
    foreach($e in $entries){ Assert-False (($e.Message+$e.Operation+$e.Category).Contains('MARQUEUR-SECRET')) }
    Assert-False ([bool]$script:DomeniaSwallowedState.Busy)
    Write-DomeniaSwallowed 'Theme' 'Apres' 'texte' -Now $script:Sw0
    $after=@(@(Get-DomeniaSwallowedEntries)|Where-Object{$_.Operation -eq 'Apres'})
    Assert-Equal 1 $after.Count;Assert-Equal 'Logged' $after[0].Journal 'Les appels suivants ne sont plus des reentrees'
    $script:DomeniaSwallowedState=$null
}
