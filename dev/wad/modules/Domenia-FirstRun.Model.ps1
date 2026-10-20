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
        [bool]$DashboardSeen = $false,
        [bool]$ScopeRead = $false
    )
    $connected = [bool]$Domain.Trim()
    $scoped = [bool]$ScopeDn.Trim()
    # Coverage proves the read, not the global object count. A fully read empty OU is a valid first read.
    # IndexedObjects remains accepted for callers, but cannot establish coverage of the selected OU.
    $read = ($connected -and $scoped -and $ScopeRead)
    $seen = ($DashboardSeen -and $read)
    $connectionText = 'Se connecter à lʼannuaire avec son compte habituel.'
    if ($connected) {
        $connectionText = 'Connecté à ' + $Domain.Trim()
        if ($Account.Trim()) { $connectionText += ' avec ' + $Account.Trim() }
        $connectionText += '.'
    }
    $ouText = 'Choisir lʼOU racine du domaine. Elle est le défaut des sections qui nʼont pas encore leur propre choix.'
    if ($scoped) {
        $label = $ScopeName.Trim()
        if (-not $label) { $label = $ScopeDn.Trim() }
        $ouText = 'OU de travail : ' + $label + '.'
    }
    $baseText = 'Faire la première lecture de cette OU dans la base locale (Outils, Base autonome).'
    if ($read) { $baseText = 'Première lecture de cette OU enregistrée dans la base locale.' }
    $dashboardText = 'Ouvrir le tableau de bord : le calcul part à ce clic, depuis la base locale, puis la vue sʼaffiche.'
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
