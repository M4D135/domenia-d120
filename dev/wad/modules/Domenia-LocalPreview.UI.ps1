# Canonical local previews never confirm AD freshness or permit a write.
function Get-DomeniaLocalSearchPreviewQuery {
    param($State)
    if($null -eq $State -or [string]$State.ViewId -or [string](Get-DomeniaMember $State 'MatchMode' '') -or [string](Get-DomeniaMember $State 'PlanKind' '') -notin @('','Default')){return $null}
    $term=([string]$State.Search).Trim()
    # Complex filters keep their LDAP semantics; do not substitute a broader local query.
    if($term -match '[\s*()]' -or $term.Length -gt 1024){return $null}
    $types=@()
    $known=$false
    foreach($pair in @(@('Tous',''),@('Machines','Machine'),@('Utilisateurs','Utilisateur'),@('Groupes','Groupe'))){
        if([string]$State.TypeFilter -ceq (Get-TypeLdapFilter $pair[0])){$known=$true;if($pair[1]){$types=@($pair[1])};break}
    }
    if(-not $known){return $null}
    return @{Kind='Directory';Projection='List';ScopeDn=[string]$State.BaseDn;Subtree=([string]$State.Scope -eq 'Subtree');Types=$types;Prefix=$term;Limit=[Math]::Min(5000,[Math]::Max(1,[int]$State.Limit))}
}

function Request-DomeniaLocalSearchPreview {
    param($Search)
    try{
        $query=Get-DomeniaLocalSearchPreviewQuery $Search.State
        if($null -eq $query){return}
        [void](Request-DomeniaStoreRead -Context $Search.State.StoreContext -Query $query -Preview -SuccessHandler 'Complete-DomeniaLocalSearchPreview' -ErrorHandler 'Fail-DomeniaLocalSearchPreview' -CallbackState $Search)
    }catch{Fail-DomeniaLocalSearchPreview -Message $_.Exception.Message -State $Search}
}

function Complete-DomeniaLocalSearchPreview {
    param($Result,$State)
    if(-not (Test-DomeniaLiveSearchActive) -or -not [object]::ReferenceEquals($State,$script:Live.Search)){return}
    if([string]$State.State.StoreContext.Path -ine [string]$script:DatabaseScopedPath -or ($State.Ended -and -not $State.Error)){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy','Missing')
    if($null -eq $data -or $data.Busy -or $data.Missing -or [string]$data.DataSource -cne 'SQLite' -or [string]$data.StoreId -cne [string]$State.State.StoreContext.StoreId){return}
    foreach($row in @($data.Rows)){
        # Rendering/conversion is sliced by the live timer, even for a large local result.
        $State.CacheProgress.Enqueue([pscustomobject]@{Kind='Cached';DataSource='SQLite';StoredRow=$row;ObservedUtc=[string]$row.ObservedAtUtc})
    }
    if($State.CacheProgress.Count){Invoke-DomeniaTimerSoon -Owner 'Timer:Live'}
}

function Fail-DomeniaLocalSearchPreview {
    param($Message,$State)
    # A missing/busy local preview never cancels the independent directory refresh.
    Write-DomeniaTrace -Area 'Recherche' -Text ('Aperçu local indisponible, lecture AD maintenue : '+[string]$Message)
}

function Request-DomeniaLocalObjectPreview {
    param($State)
    $State | Add-Member NoteProperty LocalPreviewPending $true -Force
    $State | Add-Member NoteProperty DeferredReadError '' -Force
    try{
        $query=@{Kind='Directory';DN=[string]$State.Dn;Limit=1}
        if($State.ExpectedGuid){$query.Guids=@([string]$State.ExpectedGuid)}
        $job=Request-DomeniaStoreRead -Context $State.StoreContext -Query $query -Preview -SuccessHandler 'Complete-DomeniaLocalObjectPreview' -ErrorHandler 'Fail-DomeniaLocalObjectPreview' -CallbackState $State
        if(-not $job){Fail-DomeniaLocalObjectPreview -Message 'Lecture locale non admise.' -State $State}
    }catch{Fail-DomeniaLocalObjectPreview -Message $_.Exception.Message -State $State}
}

function Complete-DomeniaLocalObjectPreview {
    param($Result,$State)
    try{
        if(-not (Test-DomeniaObjectCallbackIsCurrent $State) -or [string]$State.StoreContext.Path -ine [string]$script:DatabaseScopedPath){return}
        $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','Busy','Missing')
        if($null -eq $data -or $data.Busy -or $data.Missing -or [string]$data.DataSource -cne 'SQLite' -or [string]$data.StoreId -cne [string]$State.StoreContext.StoreId -or @($data.Rows).Count -ne 1){return}
        $row=@($data.Rows)[0];$stored=ConvertFrom-DomeniaDirectoryCommittedRow $row
        $observed=ConvertTo-DomeniaUtcDate ([string]$row.ObservedAtUtc)
        if($null -eq $observed){return}
        $effective=[pscustomobject]@{Properties=$stored.Properties;DN=$stored.DN;Type=$stored.Type;Live=$false;DataSource='SQLite';ObservedUtc=$observed.ToString('o');StoreRevision=$data.SnapshotRevision}
        Assert-DomeniaObjectResultIdentity -Result $effective -State $State
        $script:ShowingCachedObject=$true;$script:ShowingCachedObjectCreated=$observed.ToLocalTime()
        try{Show-AdObjectResult -Result $effective -Dn $State.Dn -Type $stored.Type -NoNavigate:([bool]$State.NoNavigate) -SuppressRemoteProbes}
        finally{$script:ShowingCachedObject=$false;$script:ShowingCachedObjectCreated=$null}
        if($State.SelectionBound){Update-DomeniaSelectionReadUi -Phase Cached}
    }catch{Write-DomeniaTrace -Area 'Objet' -Text ('Aperçu local ignoré : '+$_.Exception.Message)}
    finally{Complete-DomeniaLocalObjectPreviewWait $State}
}

function Complete-DomeniaLocalObjectPreviewWait {
    param($State)
    $State.LocalPreviewPending=$false
    if([string]$State.DeferredReadError -and (Test-DomeniaObjectCallbackIsCurrent $State)){
        Fail-DomeniaOpenObjectTaskUi -Message ([string]$State.DeferredReadError) -State $State
    }
}

function Fail-DomeniaLocalObjectPreview {
    param($Message,$State)
    Complete-DomeniaLocalObjectPreviewWait $State
}

function Test-DomeniaObjectPresentationUnchanged {
    # Compare only canonical scalar attribute values. Unknown shapes fall back to a complete render.
    param($Result,[string]$Dn,[string]$Type)
    $previous=$script:SelectedObject
    if($null -eq $previous -or [string]$previous.DN -ine $Dn -or [string]$previous.Type -cne $Type){return $false}
    if(-not $previous.PSObject.Properties['RenderIdentity'] -or [string]$previous.RenderIdentity -cne (Get-DomeniaObjectReadIdentity)){return $false}
    $left=$previous.Entry.Properties;$right=Remove-DomeniaSensitiveProperties -Properties $Result.Properties
    if($left -isnot [Collections.IDictionary] -or $right -isnot [Collections.IDictionary] -or $left.Count -ne $right.Count){return $false}
    if(-not [string]$previous.Guid){return $false}
    foreach($key in $left.Keys){
        if(-not $right.Contains($key)){return $false}
        $a=@($left[$key]);$b=@($right[$key])
        if($a.Count -ne $b.Count){return $false}
        for($i=0;$i -lt $a.Count;$i++){
            if($null -eq $a[$i] -and $null -eq $b[$i]){continue}
            if($null -eq $a[$i] -or $null -eq $b[$i] -or $a[$i].GetType() -ne $b[$i].GetType()){return $false}
            if($a[$i] -isnot [string] -and $a[$i].GetType().IsPrimitive -eq $false -and $a[$i] -isnot [datetime] -and $a[$i] -isnot [guid]){return $false}
            if(-not $a[$i].Equals($b[$i])){return $false}
        }
    }
    return $true
}
