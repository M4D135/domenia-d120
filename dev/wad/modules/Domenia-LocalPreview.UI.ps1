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

function Get-DomeniaObjectPresentationDelta {
    # Only plain display fields may bypass the complete fill. Identity, account state, membership,
    # manager links and unknown shapes always take the original path. Build the whole plan before applying it.
    param($Result,[string]$Dn,[string]$Type)
    $previous=$script:SelectedObject
    if($null -eq $previous -or [string]$previous.DN -ine $Dn -or [string]$previous.Type -cne $Type -or
       -not $previous.PSObject.Properties['RenderIdentity'] -or [string]$previous.RenderIdentity -cne (Get-DomeniaObjectReadIdentity) -or -not [string]$previous.Guid){return $null}
    $left=$previous.Entry.Properties;$right=Remove-DomeniaSensitiveProperties -Properties $Result.Properties
    if($left -isnot [Collections.IDictionary] -or $right -isnot [Collections.IDictionary]){return $null}
    $map=@{whenChanged='TxtObjChanged';uSNChanged=''}
    switch($Type){
        'Utilisateur' {
            $map+=@{givenName='TxtUserGivenName';sn='TxtUserSurname';displayName='TxtUserDisplayName';mail='TxtUserMail';telephoneNumber='TxtUserPhone';physicalDeliveryOfficeName='TxtUserOffice';description='TxtUserDescription';title='TxtUserTitle';department='TxtUserDepartment';company='TxtUserCompany';streetAddress='TxtUserStreet';l='TxtUserCity';st='TxtUserState2';postalCode='TxtUserPostalCode';co='TxtUserCountry';homePhone='TxtUserHomePhone';mobile='TxtUserMobile';facsimileTelephoneNumber='TxtUserFax';ipPhone='TxtUserIpPhone';wWWHomePage='TxtUserWebPage';employeeID='TxtUserEmployeeId';profilePath='TxtUserProfilePath';scriptPath='TxtUserScriptPath';homeDirectory='TxtUserHomeDirectory';homeDrive='TxtUserHomeDrive';userWorkstations='TxtUserWorkstations'}
        }
        'Machine' {$map+=@{description='TxtCompDescription';location='TxtCompLocation';operatingSystem='TxtCompOs';operatingSystemVersion='TxtCompOsVersion'}}
        'Groupe' {$map+=@{description='TxtGroupDescription'}}
    }
    $keys=@{};foreach($key in $left.Keys){$keys[[string]$key]=$true};foreach($key in $right.Keys){$keys[[string]$key]=$true}
    $fields=@{};$changed=New-Object 'System.Collections.Generic.List[string]'
    foreach($key in $keys.Keys){
        $a=@($left[$key]);$b=@($right[$key]);$same=($a.Count -eq $b.Count)
        for($i=0;$same -and $i -lt $a.Count;$i++){
            if($null -eq $a[$i] -and $null -eq $b[$i]){continue}
            if($null -eq $a[$i] -or $null -eq $b[$i] -or $a[$i].GetType() -ne $b[$i].GetType()){$same=$false;break}
            if($a[$i] -isnot [string] -and -not $a[$i].GetType().IsPrimitive -and $a[$i] -isnot [datetime] -and $a[$i] -isnot [guid]){return $null}
            $same=$a[$i].Equals($b[$i])
        }
        if($same){continue}
        if(-not $map.ContainsKey($key) -or $b.Count -gt 1){return $null}
        if($b.Count -and $null -ne $b[0] -and $b[0] -isnot [string] -and -not $b[0].GetType().IsPrimitive -and $b[0] -isnot [datetime]){return $null}
        $changed.Add($key);$control=[string]$map[$key]
        if($control){$fields[$control]=$(if($key -ieq 'whenChanged'){Convert-DateLabel $(if($b.Count){$b[0]}else{''})}else{[string]$(if($b.Count){$b[0]}else{''})})}
    }
    return [pscustomobject]@{Fields=$fields;ChangedAttributes=$changed.ToArray()}
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
