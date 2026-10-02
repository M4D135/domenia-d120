# D008 : courses et selections rapides. Sequences generees (graine fixe, donc reproductibles) A/B/C,
# changement de compte, nouvelle session, nouvelle recherche, renommage, objet recree et navigation.
# Regle verifiee : une reponse preparee dans un ancien contexte n'est jamais acceptee dans le contexte courant ;
# une reponse du contexte courant l'est. Donnees fictives uniquement.

function New-RaceRow {
    param([string]$Letter,[string]$Guid,[string]$Dn)
    return [pscustomobject]@{Type='Utilisateur';Name=('Objet '+$Letter);Login=('objet.'+$Letter.ToLowerInvariant());Guid=$Guid;DN=$Dn;Sid=''}
}
function New-RaceWorld {
    $rows=@{
        A=(New-RaceRow 'A' '11111111-1111-1111-1111-111111111111' 'CN=Objet A,OU=Test,DC=example,DC=invalid')
        B=(New-RaceRow 'B' '22222222-2222-2222-2222-222222222222' 'CN=Objet B,OU=Test,DC=example,DC=invalid')
        C=(New-RaceRow 'C' '33333333-3333-3333-3333-333333333333' 'CN=Objet C,OU=Test,DC=example,DC=invalid')
    }
    return [pscustomobject]@{Rows=$rows;Current='A';Reader='EXAMPLE\lecteur';Epoch=1L;Generation=1L;Domain='example.invalid'}
}
function Get-RaceIdentity {
    param($World)
    return (New-DomeniaSelectionIdentity $World.Rows[$World.Current] $World.Domain $World.Reader $World.Epoch $World.Generation)
}
function Test-RaceOracle {
    # Independent statement of the expected semantics (not a call to the rule under test).
    param($Captured,$World)
    $row=$World.Rows[$World.Current]
    return ([string]$Captured.Guid -ieq [string]$row.Guid -and [string]$Captured.Type -ieq [string]$row.Type -and
        [string]$Captured.Reader -ceq [string]$World.Reader -and [long]$Captured.Epoch -eq [long]$World.Epoch -and
        [long]$Captured.Generation -eq [long]$World.Generation -and [string]$Captured.Domain -ieq [string]$World.Domain)
}
function Invoke-RaceStep {
    param($World,[string]$Step,[int]$Index)
    switch ($Step) {
        'SelectA' { $World.Current='A' }
        'SelectB' { $World.Current='B' }
        'SelectC' { $World.Current='C' }
        'ChangeAccount' { if($World.Reader -ceq 'EXAMPLE\lecteur'){$World.Reader='EXAMPLE\autre-lecteur'}else{$World.Reader='EXAMPLE\lecteur'} }
        'Relogin' { $World.Epoch=[long]$World.Epoch+1 }
        'NewSearch' { $World.Generation=[long]$World.Generation+1 }
        'Rename' {
            # Label and DN change, same GUID: the target is the same object (D012).
            $row=$World.Rows[$World.Current]
            $copy=$row.PSObject.Copy();$copy.Name=('Renomme '+$Index);$copy.DN=('CN=Renomme '+$Index+',OU=Test,DC=example,DC=invalid')
            $World.Rows[$World.Current]=$copy
        }
        'Recreate' {
            # Same DN and name, new GUID: another object that must never receive the old answer.
            $row=$World.Rows[$World.Current]
            $copy=$row.PSObject.Copy();$copy.Guid=([guid]::new(('{0:x8}' -f (4096+$Index))+'-0000-4000-8000-000000000000')).ToString('D')
            $World.Rows[$World.Current]=$copy
        }
        default { }
    }
}

$script:RaceSteps=@('SelectA','SelectB','SelectC','SelectA','SelectB','SelectC','ChangeAccount','Relogin','NewSearch','Rename','Recreate','Navigate','Cancel','Read','Read','Read','Deliver','Deliver','Deliver')

Test-Case 'D008' 'Sequences generees : seule une reponse du contexte courant est acceptee' {
    $random=New-Object Random 20261002
    $accepted=0;$rejected=0;$mismatches=New-Object 'System.Collections.Generic.List[string]'
    for($sequence=0;$sequence -lt 250;$sequence++){
        $world=New-RaceWorld
        $pending=New-Object 'System.Collections.Generic.List[object]'
        $trace=New-Object 'System.Collections.Generic.List[string]'
        for($i=0;$i -lt 14;$i++){
            $step=$script:RaceSteps[$random.Next($script:RaceSteps.Count)]
            $trace.Add($step)
            if($step -eq 'Read'){$pending.Add((Get-RaceIdentity $world));continue}
            if($step -eq 'Cancel'){if($pending.Count -gt 0){$pending.RemoveAt($random.Next($pending.Count))};continue}
            if($step -eq 'Deliver'){
                if($pending.Count -eq 0){continue}
                # Responses arrive in any order, including after newer reads.
                $at=$random.Next($pending.Count);$captured=$pending[$at];$pending.RemoveAt($at)
                $decision=[bool](Test-DomeniaIdentityCurrent $captured (Get-RaceIdentity $world))
                $expected=[bool](Test-RaceOracle $captured $world)
                if($decision){$accepted++}else{$rejected++}
                if($decision -ne $expected){$mismatches.Add(('sequence '+$sequence+' : '+($trace -join '>')+' ; decision '+$decision+' attendu '+$expected))}
                continue
            }
            Invoke-RaceStep $world $step $i
        }
    }
    Assert-True ($mismatches.Count -eq 0) ((@($mismatches) | Select-Object -First 3) -join ' | ')
    # Both outcomes must really occur, otherwise the generator proves nothing.
    Assert-True ($accepted -gt 50 -and $rejected -gt 50) ('Couverture insuffisante : '+$accepted+' acceptees, '+$rejected+' refusees')
}

Test-Case 'D008' 'A puis B puis C : les reponses tardives de A et B sont refusees, celle de C acceptee' {
    $world=New-RaceWorld
    $a=Get-RaceIdentity $world
    Invoke-RaceStep $world 'SelectB' 1;$b=Get-RaceIdentity $world
    Invoke-RaceStep $world 'SelectC' 2;$c=Get-RaceIdentity $world
    $now=Get-RaceIdentity $world
    Assert-False (Test-DomeniaIdentityCurrent $a $now) 'Reponse tardive de A acceptee pour C.'
    Assert-False (Test-DomeniaIdentityCurrent $b $now) 'Reponse tardive de B acceptee pour C.'
    Assert-True (Test-DomeniaIdentityCurrent $c $now) 'Reponse de C refusee.'
}

Test-Case 'D008' 'Retour sur A apres un changement de compte : ancienne reponse de A refusee' {
    $world=New-RaceWorld
    $old=Get-RaceIdentity $world
    Invoke-RaceStep $world 'SelectB' 1;Invoke-RaceStep $world 'ChangeAccount' 2;Invoke-RaceStep $world 'SelectA' 3
    Assert-False (Test-DomeniaIdentityCurrent $old (Get-RaceIdentity $world)) 'Lecture faite sous un autre compte acceptee.'
}

Test-Case 'D008' 'Objet recree au meme DN : ancienne reponse refusee ; renommage : reponse conservee' {
    $world=New-RaceWorld
    $before=Get-RaceIdentity $world
    Invoke-RaceStep $world 'Rename' 1
    Assert-True (Test-DomeniaIdentityCurrent $before (Get-RaceIdentity $world)) 'Un renommage ne change pas la cible.'
    Invoke-RaceStep $world 'Recreate' 2
    Assert-False (Test-DomeniaIdentityCurrent $before (Get-RaceIdentity $world)) 'Un objet recree a recu la reponse de l ancien.'
}

Test-Case 'D008' 'Pages de resultats : une suite preparee pour une autre recherche, un autre compte ou une autre OU est ecartee' {
    $random=New-Object Random 1002
    $readers=@('EXAMPLE\lecteur','EXAMPLE\autre-lecteur');$bases=@('OU=Test,DC=example,DC=invalid','OU=Autre,DC=example,DC=invalid')
    $accepted=0;$rejected=0
    for($n=0;$n -lt 400;$n++){
        $reader=$readers[$random.Next(2)];$generation=[long]$random.Next(1,4);$base=$bases[$random.Next(2)]
        $page=New-DomeniaContinuation -BaseFilter '(objectClass=user)' -LastName 'dupont' -PageSize 100 -Reader $reader -Generation $generation -BaseDn $base
        $nowReader=$readers[$random.Next(2)];$nowGeneration=[long]$random.Next(1,4);$nowBase=$bases[$random.Next(2)]
        $decision=[bool](Test-DomeniaContinuationCurrent $page $nowReader $nowGeneration $nowBase)
        $expected=($reader -ceq $nowReader -and $generation -eq $nowGeneration -and $base -ieq $nowBase)
        Assert-True ($decision -eq $expected) ('Suite '+$reader+'/'+$generation+'/'+$base+' contre '+$nowReader+'/'+$nowGeneration+'/'+$nowBase)
        if($decision){$accepted++}else{$rejected++}
    }
    Assert-True ($accepted -gt 10 -and $rejected -gt 100) ('Couverture insuffisante : '+$accepted+' / '+$rejected)
}
