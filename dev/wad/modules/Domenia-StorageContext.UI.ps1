# Switching the local store preserves account identity and fences every previous GUI snapshot.
function Get-DomeniaDatabasePreferenceKey {
    param([string]$DomainDn)
    if([string]::IsNullOrWhiteSpace($DomainDn)){throw 'Domaine requis pour choisir la base.'}
    return 'Storage.Database.'+(Get-DomeniaStoreHash $DomainDn.Trim().ToLowerInvariant())
}
function Switch-DomeniaDatabaseContext {
    # KI-004: the copy is validated before this switch by a read-only maintenance worker (Action ReadRedirect:
    # schema, quick_check, identity row of the domain, absence of marker). Only the pure checks remain here
    # (context guards, local path, identity footprint recomputed), instant, so the switch runs no SQLite read
    # on the interface thread.
    param([string]$Path,[string]$ExpectedPath,[long]$ExpectedEpoch,[string]$StoreId,[long]$Revision)
    if($ExpectedEpoch -ne [long]$script:SessionEpoch -or $ExpectedPath -ine [string]$script:DatabaseScopedPath){throw 'Le contexte actif a changé pendant la maintenance.'}
    if($null -eq $script:StorageMaintenance -or -not $script:StorageMaintenance.Locked){throw 'Une bascule exige une maintenance exclusive confirmée.'}
    $domain=([string]$script:Conn.BaseDn).Trim().ToLowerInvariant()
    $target=Get-DomeniaLocalDatabasePath -Path $Path -Existing
    if($StoreId -cne (Get-DomeniaStoreId $target $domain) -or $Revision -lt 0){throw 'Identité de la base cible invalide.'}
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
    # -ReloadLocalState: another base is now in service (switch confirmed by Switch-DomeniaDatabaseContext). Its figures
    # and its user-workstation associations are read by the LocalIndexRead worker (FI-19), as after a change of account;
    # nothing read from the previous base stays on screen, and the associations of the new base become the reference.
    # The figures of the previous base are forgotten before its schema is opened: a failed opening leaves the page
    # saying that the base could not be read, never the counters of the base that was replaced.
    param([switch]$ReloadLocalState)
    if($ReloadLocalState){
        Reset-DomeniaIndexMetadataState
        $script:LinkLoad=$null
    }
    $opened=$false
    try{
        [void](Initialize-DomeniaDatabase)
        $opened=$true
        if($ReloadLocalState){
            Request-DomeniaIndexMetadata
            Request-DomeniaUserMachineLinks
            try{Update-DomeniaIndexStats}catch{Write-DomeniaSwallowed 'StorageContext' 'Resume-DomeniaDatabaseViews' $_}
        }
        [void](Initialize-DomeniaQueryLibraryStore -Force)
        Request-DomeniaFleetRefresh -Force
        Update-DomeniaIndexLocation
        Set-Status 'Base locale prête. Le dashboard relit les données enregistrées ; les collectes AD, ping et WMI restent explicites.'
    }catch{
        $detail=[string]$_.Exception.Message
        # Only the opening of the new base decides what Base locale says; a later step keeps the reads it started.
        if($ReloadLocalState -and -not $opened){
            $script:IndexMetadataError=$detail
            try{Update-DomeniaIndexStats}catch{Write-DomeniaSwallowed 'StorageContext' 'Resume-DomeniaDatabaseViews' $_}
        }
        Set-Status ('Base sélectionnée, relecture locale à reprendre : '+$detail) 'WARN'
    }
}
