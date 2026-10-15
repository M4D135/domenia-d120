# Local data policy view (point 147): Stockage, « Politique des données locales ». Local values only: the saved storage
# policy, the storage layout and the path of the active base. Read-only view; nothing is measured, read or sent.

function Update-DomeniaDataPolicyView {
    $grid = Get-DomeniaControl 'DgStorageDataPolicy'
    $label = Get-DomeniaControl 'LblStorageDataPolicy'
    if (($null -eq $grid) -and ($null -eq $label)) { return }
    $policy = $null
    $unreadable = $false
    try { $policy = Get-DomeniaCurrentStoragePolicy } catch { $unreadable = $true; Write-AppLog ('Politique des données : réglages de stockage illisibles. ' + $_.Exception.Message) 'WARN' }
    $dataRoot = ''
    $receiptRoot = ''
    $areas = @()
    $layout = $script:StorageLayout
    if ($null -ne $layout) {
        $dataRoot = [string]$layout.DataRoot
        $receipt = @(@($layout.Categories) | Where-Object { [string]$_.Category -eq 'Receipt' })
        if ($receipt.Count -eq 1) { $receiptRoot = [string]$receipt[0].Path }
        # Logs, backups, diagnostics, exports, legacy data and bases: the folders the layout itself declares.
        $cache = @(@($layout.Categories) | Where-Object { [string]$_.Category -eq 'Cache' })
        if ($cache.Count -eq 1) { $areas = @(Get-DomeniaMember $cache[0] 'Areas' @()) }
    }
    $view = Get-DomeniaLocalDataPolicy -Policy $policy -DataRoot $dataRoot -ReceiptRoot $receiptRoot -DatabasePath ([string]$script:DatabaseScopedPath) -Areas $areas -PolicyUnreadable:$unreadable
    if ($null -ne $grid) { $grid.ItemsSource = @($view.Rows) }
    if ($null -ne $label) { $label.Text = [string]$view.Statement }
}

function Initialize-DomeniaDataPolicyView {
    # Refreshed when the section opens (the active base may change with the domain) and after each save of the policy.
    $expander = Get-DomeniaControl 'ExpStorageDataPolicy'
    if (($null -ne $expander) -and (-not [bool]$script:DataPolicyViewWired)) {
        $expander.Add_Expanded({ try { Update-DomeniaDataPolicyView } catch { Write-AppLog ('Politique des données non affichée : ' + $_.Exception.Message) 'WARN' } })
        $script:DataPolicyViewWired = $true
    }
    Update-DomeniaDataPolicyView
}
