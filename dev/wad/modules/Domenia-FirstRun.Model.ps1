# First run guide (point 148). Pure rules: no WPF, no network, no disk.
# Four steps read from what the session already knows: connection to the directory, working OU of the dashboard, first
# read of that OU into the local base, then the overview computed from it. The rare options (account used on the
# workstations, backups of the base) are not steps: they are offered where they are used. Each step button opens its
# screen; the last overview is prepared locally before it is offered (David 2026-10-16).

function Get-DomeniaFirstRunPlan {
    param(
        [AllowEmptyString()][string]$Domain = '',
        [AllowEmptyString()][string]$Account = '',
        [AllowEmptyString()][string]$ScopeDn = '',
        [AllowEmptyString()][string]$ScopeName = '',
        [long]$IndexedObjects = 0,
        [bool]$DashboardSeen = $false
    )
    $connected = [bool]$Domain.Trim()
    $scoped = [bool]$ScopeDn.Trim()
    $read = ($IndexedObjects -gt 0)
    $seen = ($DashboardSeen -and $read)
    $connectionText = 'Se connecter à lʼannuaire avec son compte habituel.'
    if ($connected) {
        $connectionText = 'Connecté à ' + $Domain.Trim()
        if ($Account.Trim()) { $connectionText += ' avec ' + $Account.Trim() }
        $connectionText += '.'
    }
    $ouText = 'Choisir lʼOU de travail du tableau de bord ; Rechercher reste indépendant.'
    if ($scoped) {
        $label = $ScopeName.Trim()
        if (-not $label) { $label = $ScopeDn.Trim() }
        $ouText = 'OU de travail : ' + $label + '.'
    }
    $baseText = 'Faire la première lecture de cette OU dans la base locale (Outils, Base autonome).'
    if ($read) { $baseText = 'Première lecture faite : ' + [string]$IndexedObjects + ' objet(s) dans la base locale.' }
    $dashboardText = 'Préparer le tableau de bord : première actualisation depuis la base locale, puis ouverture de la vue.'
    if ($seen) { $dashboardText = 'Vue dʼensemble calculée depuis la base locale ; une tuile ouvre la liste exacte de ses postes.' }
    $steps = @(
        [pscustomobject]@{ Name = 'Connection'; Number = 1; Done = $connected; Enabled = $true; Text = $connectionText }
        [pscustomobject]@{ Name = 'Ou'; Number = 2; Done = $scoped; Enabled = $connected; Text = $ouText }
        [pscustomobject]@{ Name = 'Base'; Number = 3; Done = $read; Enabled = $connected; Text = $baseText }
        [pscustomobject]@{ Name = 'Dashboard'; Number = 4; Done = $seen; Enabled = $read; Text = $dashboardText }
    )
    $next = ''
    foreach ($step in $steps) { if (-not $step.Done) { $next = $step.Name; break } }
    return [pscustomobject]@{
        Steps = $steps
        Next = $next
        Done = ($next -eq '')
        Deferred = 'Plus tard, au moment où ils servent : le compte pour les postes (Comptes et accès) et les sauvegardes de la base (Outils, Base autonome, Stockage).'
    }
}
