# Explicit, documented read-only catalogue. No provider discovery or network access occurs here.
function Get-DomeniaExtendedProbeCatalog {
    $cached=Get-Variable -Name DomeniaExtendedProbeCatalog -Scope Script -ErrorAction SilentlyContinue
    if($null -ne $cached -and $null -ne $cached.Value){return $cached.Value}
    $path=Join-Path $PSScriptRoot 'Domenia-ProbeCatalog.json'
    $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    if([Text.Encoding]::UTF8.GetByteCount($text) -gt 1048576){throw 'Catalogue de sondes trop volumineux.'}
    $data=ConvertFrom-Json $text
    if([int]$data.SchemaVersion -ne 1 -or @($data.Probes).Count -gt 256){throw 'Version ou taille du catalogue de sondes invalide.'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($p in @($data.Probes)){
        if([string]$p.Id -cnotmatch '^[a-z][a-z0-9_.-]{1,127}$' -or -not $ids.Add([string]$p.Id)){throw 'Identifiant de sonde invalide ou répété.'}
        if([string]$p.Namespace -notmatch '^[A-Za-z0-9_\\]+$' -or [string]$p.Class -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or [string]$p.Class -match '^(?i:Win32_Product|CIM_Product|Win32_SoftwareFeature)$'){throw 'Fournisseur du catalogue refusé.'}
        if([string]$p.Mode -cnotin @('First','All','Count') -or @($p.Properties).Count -lt 1 -or @($p.Properties).Count -gt 64){throw 'Projection du catalogue invalide.'}
        $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($f in @($p.Fields)){
            if([string]$f.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or -not $names.Add([string]$f.Name) -or [string]$f.Kind -cnotin @('Text','Number','Boolean','Timestamp')){throw 'Champ du catalogue invalide.'}
            if([string]$f.CimType -cnotmatch '^(string|datetime|boolean|uint8|uint16|uint32|uint64|sint8|sint16|sint32|sint64|real32|real64)(\[\])?$'){throw 'Type CIM du catalogue invalide.'}
        }
        foreach($name in @($p.Properties)){if(-not $names.Contains([string]$name)){throw 'Métadonnées de propriété manquantes.'}}
        foreach($url in @($p.SourceUrls)){if([string]$url -notmatch '^https://(learn\.microsoft\.com/|github\.com/(microsoft|MicrosoftDocs)/)'){throw 'Référence documentaire non autorisée.'}}
        if(-not [string]$p.Description -or -not [string]$p.Rights -or -not [string]$p.Compatibility -or -not [string]$p.UnknownMeaning -or -not [string]$p.Limitations -or @($p.SourceUrls).Count -eq 0){throw 'Documentation de sonde incomplète.'}
        Assert-DomeniaCustomProbeDeclaration $p
    }
    $script:DomeniaExtendedProbeCatalog=@($data.Probes)
    return $script:DomeniaExtendedProbeCatalog
}

function Assert-DomeniaCustomProbeDeclaration {
    # Point 136: an entry flagged Personnalisée declares its behaviour, privileges and cost itself (Domenia.ProbeContract/1).
    # It reads CIM only, carries no code and calls no method, runs on an explicit collection and never on a controller.
    # Self-contained: also evaluated in the query library validator, where only this file's functions are loaded.
    param($Probe)
    if($null -eq $Probe){throw 'Sonde absente.'}
    $originProperty=$Probe.PSObject.Properties['Origin']
    $origin=if($null -ne $originProperty){[string]$originProperty.Value}else{''}
    if(($origin) -and ($origin -cnotin @('Catalogue détaillé','Personnalisée'))){throw 'Origine de sonde inconnue.'}
    if($origin -cne 'Personnalisée'){return}
    $declared=@{}
    foreach($name in @('Behavior','Privilege','Cost','Slow','SkipOnDc')){$member=$Probe.PSObject.Properties[$name];if(($null -ne $member) -and ($null -ne $member.Value)){$declared[$name]=$member.Value}}
    if(-not (($declared.ContainsKey('Behavior')) -and ($declared.ContainsKey('Privilege')) -and ($declared.ContainsKey('Cost')))){throw ('Sonde personnalisée sans comportement, privilèges ou coût déclarés : '+[string]$Probe.Id)}
    $behavior=$declared['Behavior'];$reads=$behavior.PSObject.Properties['Reads'];$writes=$behavior.PSObject.Properties['Writes'];$code=$behavior.PSObject.Properties['Code'];$methods=$behavior.PSObject.Properties['Methods']
    $readOnly=(($null -ne $reads) -and ([string]$reads.Value -ceq 'CIM') -and ($null -ne $writes) -and ($writes.Value -is [bool]) -and (-not [bool]$writes.Value) -and ($null -ne $code) -and ([string]$code.Value -ceq 'Aucun'))
    if((-not $readOnly) -or (($null -ne $methods) -and (@($methods.Value).Count -gt 0))){throw ('Comportement de sonde personnalisée refusé : '+[string]$Probe.Id)}
    if((-not $declared.ContainsKey('Slow')) -or (-not [bool]$declared['Slow']) -or (-not $declared.ContainsKey('SkipOnDc')) -or (-not [bool]$declared['SkipOnDc'])){throw ('Sonde personnalisée : collecte explicite et exclusion des contrôleurs requises : '+[string]$Probe.Id)}
}

function Add-DomeniaProbeMetadata {
    # Existing small probes reuse the documented class properties from the detailed catalogue.
    # Undocumented scalar types remain text: no numeric meaning is guessed from the property name.
    param($Probe)
    if($null -eq $Probe){return}
    $classPeers=@(Get-DomeniaExtendedProbeCatalog|Where-Object{$_.Class -ieq $Probe.Class -and $_.Namespace -ieq $Probe.Namespace})
    # Rights, compatibility and sources describe the class; limitations describe one projection. A historical probe
    # only inherits the limitations of a detailed probe that reads every one of its properties.
    $classPeer=if($classPeers.Count){$classPeers[0]}else{$null}
    $covering=@($classPeers|Where-Object{$peerProperties=@($_.Properties);@(@($Probe.Properties)|Where-Object{$peerProperties -notcontains $_}).Count -eq 0})
    $peer=if($covering.Count){$covering[0]}else{$null}
    $fieldsByName=@{};foreach($item in $classPeers){foreach($field in @($item.Fields)){$fieldsByName[[string]$field.Name]=$field}}
    $fields=@(foreach($name in @($Probe.Properties)){
        if($fieldsByName.ContainsKey([string]$name)){$fieldsByName[[string]$name]}
        else{[pscustomobject]@{Name=[string]$name;CimType='';Kind='Text';IsArray=$false;Unit='Valeur brute';Description='Propriété du fournisseur ; type détaillé à qualifier.'}}
    })
    $description=[string]$Probe.Name+'. Source : '+[string]$Probe.Class+'.'
    $limits=if($null -ne $peer){[string]$peer.Limitations}else{'Disponibilité selon fournisseur et droits. La lecture conserve une date ; elle ne prouve pas un état courant après expiration.'}
    if([string]$Probe.Mode -eq 'First'){$limits+=' Résumé fondé sur la première instance ; le choix de cette instance dépend du fournisseur.'}
    if([bool]$Probe.SkipOnDc){$limits+=' Lecture exclue sur les contrôleurs de domaine.'}
    $meta=@{
        Description=$description
        Rights=$(if($null -ne $classPeer){$classPeer.Rights}else{'Lecture distante du namespace WMI/CIM ; compte et accès au poste autorisés.'})
        Compatibility=$(if($null -ne $classPeer){$classPeer.Compatibility}else{'Fournisseur Windows requis ; présence et version à qualifier sur la cible.'})
        UnknownMeaning='Absence, refus, erreur, donnée périmée ou incomplète restent inconnus ; un résultat vide n''est zéro qu''après une énumération complète.'
        Limitations=$limits
        SourceUrls=$(if($null -ne $classPeer){@($classPeer.SourceUrls)}else{@()})
        Fields=$fields
        ProviderQualification='À qualifier sous Windows'
    }
    foreach($key in $meta.Keys){if($null -eq $Probe.PSObject.Properties[$key]){$Probe|Add-Member -NotePropertyName $key -NotePropertyValue $meta[$key]}}
    return $Probe
}
