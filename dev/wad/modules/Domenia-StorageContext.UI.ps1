# Switching the local store preserves account identity and fences every previous GUI snapshot.
function Get-DomeniaDatabasePreferenceKey {
    param([string]$DomainDn)
    if([string]::IsNullOrWhiteSpace($DomainDn)){throw 'Domaine requis pour choisir la base.'}
    return 'Storage.Database.'+(Get-DomeniaStoreHash $DomainDn.Trim().ToLowerInvariant())
}
function Switch-DomeniaDatabaseContext {
    param([string]$Path,[string]$ExpectedPath,[long]$ExpectedEpoch,[string]$StoreId,[long]$Revision)
    if($ExpectedEpoch -ne [long]$script:SessionEpoch -or $ExpectedPath -ine [string]$script:DatabaseScopedPath){throw 'Le contexte actif a changé pendant la maintenance.'}
    if($null -eq $script:StorageMaintenance -or -not $script:StorageMaintenance.Locked){throw 'Une bascule exige une maintenance exclusive confirmée.'}
    $domain=([string]$script:Conn.BaseDn).Trim().ToLowerInvariant()
    $target=Get-DomeniaLocalDatabasePath -Path $Path -Existing
    if($StoreId -cne (Get-DomeniaStoreId $target $domain) -or $Revision -lt 0){throw 'Identité de la base cible invalide.'}
    $db=[IntPtr]::Zero
    try{
        $db=Open-DomeniaDatabase -Path $target -ReadOnly
        Assert-StoreWDatabaseWritable -Db $db
        $rows=@(Invoke-DomeniaDbQuery 'SELECT store_id,domain_dn,revision FROM domenia_store_state WHERE id=1;' $db)
        if($rows.Count -ne 1 -or [string]$rows[0].store_id -cne $StoreId -or [string]$rows[0].domain_dn -ine $domain -or [long]$rows[0].revision -lt $Revision){throw 'La copie ne confirme pas le reçu de maintenance.'}
    }finally{Close-DomeniaDatabase $db}
    $key=Get-DomeniaDatabasePreferenceKey $domain
    if($null -eq $script:Settings){$script:Settings=Get-DomeniaDefaultSettings}
    $existed=$script:Settings.Contains($key);$old=$script:Settings[$key]
    try{$script:Settings[$key]=$target;Save-DomeniaSettings -Immediate -ThrowOnFailure}
    catch{if($existed){$script:Settings[$key]=$old}else{$script:Settings.Remove($key)};throw}
    # From this point the durable preference is committed. Never pretend it was rolled back after a rendering error.
    $script:DatabaseScopeIdentity=$domain;$script:DatabaseScopedPath=$target
    $script:DomeniaDatabaseReady=$false;$script:DomeniaDatabaseRecoveryAttempted=$false
    $script:SessionEpoch=[long]$script:SessionEpoch+1
    $script:GlobalSearchGeneration++;$script:PresenceScanGeneration++;$script:SelectedObjectGeneration++;$script:LinkIndexGeneration++
    $script:WorkerContextStatic=$null;$script:VisitCache=@{};$script:PresenceCache=@{};$script:ParkState=@{}
    $script:FleetObservations=$null;$script:FleetLast=$null;$script:FleetComputedKey='';$script:FleetStale=$true;$script:FleetQuerySnapshotKey=''
    $script:DomeniaQueryLibraryStoreState=$null;$script:SearchQueryRun=$null;$script:SearchQueryCatalog=@()
    $script:BranchObjects=@();$script:BranchCountLabel='Base changée : relisez la vue locale.'
    $script:SelectedObject=$null;$script:LastLoadedEntry=$null;$script:PendingObjectSelection=$null;$script:CurrentObjectRequestId='';$script:CurrentObjectRequestDn=''
    $script:IndexRows=@();$script:IndexInfo=$null;$script:IndexDirty=$false;$script:LinkBaseline=@{}
    $script:IndexUsersByLogin=@{};$script:IndexUsersByGuid=@{};$script:IndexComputersByName=@{};$script:IndexComputersByGuid=@{}
    $script:UserMachineLinks=@();$script:LinkByComputer=@{};$script:LinksByUser=@{};$script:LinkIndexCount=-1
    $script:InventoryRows=@();$script:InventoryCacheByComputer=@{};$script:InventoryComputer='';$script:InventoryCompletedAt=$null;$script:SoftwareRows=@()
    $script:NavHistory=New-DomeniaNavHistory -Capacity 40;$script:NavHistoryRows=$null;$script:NavHistoryState=$null;$script:NavListShape=$null
    if($null -ne $script:DomeniaQueryState){$q=$script:DomeniaQueryState;$q.Generation++;$q.Records=$null;$q.Result=$null;$q.Widgets=@{};$q.SearchRecipe=$null;$q.SearchRecords=@{};$q.Saved=@()}
    try{
        Stop-DomeniaFavouriteTreeReveal;Stop-DomeniaOuTreeFilter;Stop-DomeniaPendingFilterChange;Stop-DomeniaSelectionOpenTimer
        Clear-DomeniaTreeRenderJobs;Clear-Secrets;Clear-ObjectDetails;Reset-DomeniaLiveIdentity
        foreach($control in @($script:Ctrl.Values)){if($control -is [Windows.Controls.DataGrid]){$control.ItemsSource=$null}}
        $tree=Get-DomeniaControl 'TvDirectory'
        if($null -ne $tree){$tree.Items.Clear();[void]$tree.Items.Add((New-TreeItem -Name ([string]$script:Conn.Domain) -Dn ([string]$script:Conn.BaseDn) -Kind 'domainDNS'))}
        [void](Set-DomeniaControlText 'LblTreeStatus' 'Base changée. Dépliez lʼarbre pour relire les branches ; aucune collecte réseau automatique.')
    }catch{Write-AppLog ('Base changée ; remise à zéro visuelle à compléter : '+$_.Exception.Message) 'WARN'}
    return $true
}
function Resume-DomeniaDatabaseViews {
    # -Reload after a switch (point 32): the context switch emptied the associations and the index counters; they are
    # read again from the new base exactly as at startup (local reads only, no directory or workstation access).
    param([switch]$Reload)
    try{
        [void](Initialize-DomeniaDatabase)
        if($Reload){[void](Load-DomeniaIndexMetadata);Load-UserMachineLinks;try{Update-DomeniaIndexStats}catch{Write-AppLog ('Compteurs de la base différés : '+$_.Exception.Message) 'WARN'}}
        [void](Initialize-DomeniaQueryLibraryStore -Force)
        Request-DomeniaFleetRefresh -Force
        Update-DomeniaIndexLocation
        Set-Status 'Base locale prête. Le dashboard relit les données enregistrées ; les collectes AD, ping et WMI restent explicites.'
    }catch{Set-Status ('Base sélectionnée, relecture locale à reprendre : '+$_.Exception.Message) 'WARN'}
}
