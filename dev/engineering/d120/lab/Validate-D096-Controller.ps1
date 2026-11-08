$ErrorActionPreference = 'Stop'
# D096 validation on the lab controller, approved by David on 2026-10-04. Run INSIDE CNAMTS-W11-01 only:
#   lab.sh file dev/engineering/d120/lab/Validate-D096-Controller.ps1   (real LDAP writes : ask David before each run)
# Result 2026-10-04 (commit 8e564bd) : 4/4 steps conform (codes 0, 16, 20, 0 ; description restored).
# Scope: OU=Domenia-Lab,DC=cnamts,DC=local and its single disabled user CN=domenia-d096-test, attribute description only.
$server = 'dc01.cnamts.local'
$base = 'DC=cnamts,DC=local'
$ouDn = 'OU=Domenia-Lab,' + $base
$userDn = 'CN=domenia-d096-test,' + $ouDn
$initial = 'Domenia D096 initial'

function Get-Desc {
    $e = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$userDn")
    $s = New-Object System.DirectoryServices.DirectorySearcher($e, '(objectClass=user)')
    $s.SearchScope = 'Base'; [void]$s.PropertiesToLoad.Add('description')
    $r = $s.FindOne()
    if ($null -eq $r) { return '<objet introuvable>' }
    return (@($r.Properties['description']) -join ' | ')
}
function Test-Exists([string]$dn) {
    try { $e = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$dn"); [void]$e.RefreshCache(@('distinguishedName')); return $true }
    catch { if ($_.Exception.InnerException -and [int]$_.Exception.InnerException.HResult -eq -2147016656) { return $false }; if ([int]$_.Exception.HResult -eq -2147016656) { return $false }; throw }
}

"Identite : " + [Security.Principal.WindowsIdentity]::GetCurrent().Name + " | controleur : $server"

# 1. Dedicated OU and user, created only when absent.
if (-not (Test-Exists $ouDn)) {
    $root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$base")
    $ou = $root.Children.Add('OU=Domenia-Lab', 'organizationalUnit')
    $ou.Properties['description'].Value = 'Domenia : objets de validation (D096 et suivants)'
    $ou.CommitChanges()
    "OU creee : $ouDn"
} else { "OU deja presente : $ouDn" }
if (-not (Test-Exists $userDn)) {
    $ouEntry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$server/$ouDn")
    $u = $ouEntry.Children.Add('CN=domenia-d096-test', 'user')
    $u.Properties['sAMAccountName'].Value = 'domenia-d096-test'
    $u.Properties['description'].Value = $initial
    $u.CommitChanges()
    $u.RefreshCache(@('userAccountControl'))
    "Utilisateur cree : $userDn | userAccountControl=" + [string]$u.Properties['userAccountControl'].Value + " (desactive, aucun mot de passe)"
} else { "Utilisateur deja present : $userDn" }
$start = Get-Desc
"Description avant les tests : [$start]"
if ($start -ne $initial) { throw "Description de depart inattendue : [$start]. Arret avant toute requete conditionnelle." }

# 2. Load the real Invoke-WConditionalModify from the Domenia source synced in the VM.
$coreSource = [IO.File]::ReadAllText((Join-Path (Get-Location) 'wad\Domenia-Core.ps1'))
$t = $null; $e = $null
$coreAst = [Management.Automation.Language.Parser]::ParseInput($coreSource, [ref]$t, [ref]$e)
$lit = @($coreAst.FindAll({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst]) -and ($n.StringConstantType -eq [Management.Automation.Language.StringConstantType]::SingleQuotedHereString) -and $n.Value.Contains('function Invoke-WConditionalModify') }, $true))
if ($lit.Count -ne 1) { throw "Bloc Invoke-WConditionalModify introuvable ($($lit.Count))." }
$fnAst = @([Management.Automation.Language.Parser]::ParseInput([string]$lit[0].Value, [ref]$t, [ref]$e).FindAll({ param($n) ($n -is [Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq 'Invoke-WConditionalModify') }, $true))
Set-Item -Path function:script:Invoke-WConditionalModify -Value $fnAst[0].Body.GetScriptBlock()
$context = [pscustomobject]@{ Server = $server; Domain = 'cnamts.local'; UseCredential = $false; Credential = $null }

$results = New-Object System.Collections.Generic.List[object]
function Step([string]$label, [object[]]$mods, [int[]]$expected, [string]$expectedAfter) {
    $r = Invoke-WConditionalModify $context $userDn $mods
    $after = Get-Desc
    $okCode = ($expected -contains [int]$r.ResultCode)
    $okValue = ($after -ceq $expectedAfter)
    $line = "{0} : code={1} envoye={2} attendu={3} -> {4} | description apres=[{5}] attendue=[{6}] -> {7} | message={8}" -f $label, $r.ResultCode, $r.Sent, ($expected -join '/'), $(if ($okCode) { 'OK' } else { 'ECART' }), $after, $expectedAfter, $(if ($okValue) { 'OK' } else { 'ECART' }), ([string]$r.Message -replace '\s+', ' ')
    # Written straight to stdout: the function must return only the boolean.
    [Console]::Out.WriteLine($line)
    $results.Add([pscustomobject]@{ Step = $label; Ok = ($okCode -and $okValue) })
    return ($okCode -and $okValue)
}

$v1 = 'Domenia D096 valeur 1'
$ok = Step '1 ancienne valeur correcte (Delete+Add)' @([pscustomobject]@{Name='description';Op='Delete';Value=$initial}, [pscustomobject]@{Name='description';Op='Add';Value=$v1}) @(0) $v1
if ($ok) {
    $ok2 = Step '2 ancienne valeur fausse (Delete+Add)' @([pscustomobject]@{Name='description';Op='Delete';Value='Domenia D096 valeur fausse'}, [pscustomobject]@{Name='description';Op='Add';Value='Domenia D096 valeur 2'}) @(16) $v1
    if ($ok2) {
        [void](Step '3 ajout sur valeur presente (Add seul)' @([pscustomobject]@{Name='description';Op='Add';Value='Domenia D096 valeur 3'}) @(19, 20) $v1)
    } else { "Arret apres l etape 2 (resultat inattendu)." }
} else { "Arret apres l etape 1 (resultat inattendu)." }

# 3. Restore the initial value whatever happened (conditional on the value currently read).
$now = Get-Desc
if ($now -ceq $initial) { "Restauration : deja a la valeur initiale." }
elseif ($now -ceq $v1) { [void](Step '4 restauration (Delete+Add)' @([pscustomobject]@{Name='description';Op='Delete';Value=$v1}, [pscustomobject]@{Name='description';Op='Add';Value=$initial}) @(0) $initial) }
else { "Restauration NON faite : valeur actuelle inattendue [$now], aucune ecriture supplementaire." }
"Description finale : [" + (Get-Desc) + "]"
"Bilan : " + (@($results | Where-Object { $_.Ok }).Count) + "/" + $results.Count + " etape(s) conformes"
