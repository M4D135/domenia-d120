# Points 28 and 29: Schéma AD tab of the query workshop. The schema is read once on an explicit gesture and kept in
# memory for the session, with its controller and date; the filter analysis is local and never sends a request.
$script:DomeniaAdSchemaModuleRoot=$PSScriptRoot
$script:DomeniaAdSchema=$null
$script:DomeniaAdSchemaGeneration=0L
$script:DomeniaAdSchemaFilterTimer=$null

function Initialize-DomeniaDirectorySchemaUi {
    # Loaded with the workshop view, from its own XAML file, in the workshop tabs. No window is created.
    $tabs=Get-DomeniaControl 'QueryWorkspaceTabs'
    if(($null -eq $tabs) -or ($null -ne (Get-DomeniaControl 'TabQueryAdSchema'))){return}
    [xml]$document=[IO.File]::ReadAllText((Join-Path $script:DomeniaAdSchemaModuleRoot 'Domenia-DirectorySchema.xaml'),[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    $controls=@{}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if(-not $name){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de contrôle déjà présent : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Contrôle du schéma introuvable : '+$name)}
        $controls[$name]=$control
    }
    foreach($name in $controls.Keys){$script:Ctrl[$name]=$controls[$name]}
    $tab=New-Object Windows.Controls.TabItem
    $tab.Name='TabQueryAdSchema';$tab.Header='Schéma AD';$tab.Content=$view
    $tab.ToolTip='Schéma Active Directory en lecture seule et analyse locale des filtres LDAP.'
    [Windows.Automation.AutomationProperties]::SetName($tab,'Schéma AD')
    $script:Ctrl['TabQueryAdSchema']=$tab
    [void]$tabs.Items.Add($tab)
    # Event handlers call named functions only: no closure over a local that would expire.
    (Get-DomeniaControl 'BtnAdSchemaRead').Add_Click({Start-DomeniaAdSchemaRead})
    (Get-DomeniaControl 'CmbAdSchemaKind').Add_SelectionChanged({Update-DomeniaAdSchemaList})
    (Get-DomeniaControl 'TxtAdSchemaFilter').Add_TextChanged({Request-DomeniaAdSchemaListUpdate})
    (Get-DomeniaControl 'DgAdSchemaEntries').Add_SelectionChanged({Show-DomeniaAdSchemaSelection})
    (Get-DomeniaControl 'DgAdSchemaClassAttributes').Add_SelectionChanged({Show-DomeniaAdSchemaClassAttribute})
    (Get-DomeniaControl 'BtnAdSchemaAnalyze').Add_Click({Invoke-DomeniaAdSchemaFilterAnalysis})
    (Get-DomeniaControl 'BtnAdSchemaInsert').Add_Click({Add-DomeniaAdSchemaAttributeToFilter})
    (Get-DomeniaControl 'TxtAdSchemaLdapFilter').Add_KeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq [Windows.Input.Key]::Return){$eventArgs.Handled=$true;Invoke-DomeniaAdSchemaFilterAnalysis}})
    Update-DomeniaAdSchemaStatus
}

function Get-DomeniaAdSchemaCatalogForAnalysis {
    # The schema read in this session for the connected domain, or $null: a schema of another session or domain is
    # never used to judge an index.
    $catalog=$script:DomeniaAdSchema
    if($null -eq $catalog){return $null}
    if(([long](Get-DomeniaMember $catalog 'Epoch' -1) -ne [long]$script:SessionEpoch) -or ([string](Get-DomeniaMember $catalog 'DomainDn' '') -ine [string]$script:Conn.BaseDn)){return $null}
    return $catalog
}

function Update-DomeniaAdSchemaStatus {
    $catalog=Get-DomeniaAdSchemaCatalogForAnalysis
    if($null -eq $catalog){[void](Set-DomeniaControlText 'LblAdSchemaStatus' 'Schéma non lu dans cette session. La lecture est explicite et ne modifie rien.');return}
    $observed=ConvertTo-DomeniaUtcDate ([string]$catalog.ObservedUtc)
    $text='Schéma lu le '+$(if($null -ne $observed){$observed.ToLocalTime().ToString('dd/MM/yyyy HH:mm')}else{'(date inconnue)'})+' sur '+[string]$catalog.Server+' : '+[string]$catalog.ClassCount+' classes, '+[string]$catalog.AttributeCount+' attributs.'
    if([bool]$catalog.Truncated){$text+=' Lecture incomplète (limite atteinte) : un attribut absent de la liste peut exister.'}
    [void](Set-DomeniaControlText 'LblAdSchemaStatus' $text)
}

function Start-DomeniaAdSchemaRead {
    # Explicit gesture: one bounded read of the schema definitions. Never automatic, never a write.
    try{
        if([bool]$script:DemoMode){throw 'Lecture du schéma indisponible en démonstration : aucun contrôleur réel.'}
        if(-not [string]$script:Conn.BaseDn){throw 'Connectez-vous à un domaine avant de lire son schéma.'}
        $script:DomeniaAdSchemaGeneration=[long]$script:DomeniaAdSchemaGeneration+1
        $state=[pscustomobject]@{Epoch=[long]$script:SessionEpoch;Generation=[long]$script:DomeniaAdSchemaGeneration;DomainDn=[string]$script:Conn.BaseDn}
        [void](Set-DomeniaControlText 'LblAdSchemaStatus' 'Lecture du schéma en cours… (interrompue au-delà de 90 secondes)')
        $job=Start-UiTask -Name 'Lecture du schéma AD' -OperationId 'AdSchemaRead' -Code (Get-DomeniaAdSchemaWorkerCode) -Payload ([pscustomobject]@{Request='Schema'}) -CallbackState $state -SuccessHandler 'Complete-DomeniaAdSchemaRead' -ErrorHandler 'Fail-DomeniaAdSchemaRead' -DisableControls @('BtnAdSchemaRead') -ReplaceKey 'adschema' -TimeoutSeconds 150 -TaskClass 'Explicit'
        if(-not $job){throw 'Lecture non admise par le moteur.'}
    }catch{[void](Set-DomeniaControlText 'LblAdSchemaStatus' ('Lecture du schéma non lancée : '+$_.Exception.Message))}
}

function Test-DomeniaAdSchemaStateCurrent {
    param($State)
    return (($null -ne $State) -and ([long]$State.Epoch -eq [long]$script:SessionEpoch) -and ([long]$State.Generation -eq [long]$script:DomeniaAdSchemaGeneration) -and ([string]$State.DomainDn -ieq [string]$script:Conn.BaseDn))
}

function Complete-DomeniaAdSchemaRead {
    param($Result,$State)
    if(-not (Test-DomeniaAdSchemaStateCurrent $State)){return}
    try{
        $r=Get-DomeniaEffectiveWorkerResult $Result @('Attributes','Classes','SchemaNc')
        if($null -eq $r){throw 'Réponse du schéma absente.'}
        if([string]$r.DomainDn -ine [string]$State.DomainDn){throw 'Schéma lu pour un autre domaine.'}
        $catalog=ConvertTo-DomeniaAdSchemaCatalog -Attributes @($r.Attributes) -Classes @($r.Classes) -Server ([string]$r.Server) -ObservedUtc ([string]$r.ObservedUtc) -Truncated ([bool]$r.Truncated) -DomainDn ([string]$State.DomainDn)
        $catalog|Add-Member -NotePropertyName Epoch -NotePropertyValue ([long]$State.Epoch) -Force
        $script:DomeniaAdSchema=$catalog
        Update-DomeniaAdSchemaStatus
        Update-DomeniaAdSchemaList
        if([string](Get-DomeniaControl 'TxtAdSchemaLdapFilter').Text){Invoke-DomeniaAdSchemaFilterAnalysis}
    }catch{[void](Set-DomeniaControlText 'LblAdSchemaStatus' ('Schéma non exploitable : '+$_.Exception.Message))}
}

function Fail-DomeniaAdSchemaRead {
    param($Message,$State)
    if(-not (Test-DomeniaAdSchemaStateCurrent $State)){return}
    $text='Lecture du schéma impossible : '+[string]$Message
    if($null -ne (Get-DomeniaAdSchemaCatalogForAnalysis)){$text+=' Le schéma lu précédemment reste affiché.'}
    [void](Set-DomeniaControlText 'LblAdSchemaStatus' $text)
}

function Get-DomeniaAdSchemaListKind {
    $combo=Get-DomeniaControl 'CmbAdSchemaKind'
    if(($null -ne $combo) -and ($null -ne $combo.SelectedItem) -and ([string]$combo.SelectedItem.Tag -eq 'Attributes')){return 'Attributes'}
    return 'Classes'
}

function Request-DomeniaAdSchemaListUpdate {
    # Typing in the filter waits for a short pause (250 ms) before the list is filtered again: one pass per pause, not
    # one per keystroke. FI-05: protected, session-bound timer owned by the factory.
    if($null -eq $script:DomeniaAdSchemaFilterTimer){
        $script:DomeniaAdSchemaFilterTimer=New-DomeniaTimer -Owner 'Timer:AdSchemaFilter' -IntervalMs 250 -SessionBound -Tick {param($sender,$eventArgs) $sender.Stop();Update-DomeniaAdSchemaList}
    }
    $script:DomeniaAdSchemaFilterTimer.Stop();$script:DomeniaAdSchemaFilterTimer.Start()
}

function Update-DomeniaAdSchemaList {
    $grid=Get-DomeniaControl 'DgAdSchemaEntries'
    if($null -eq $grid){return}
    $catalog=Get-DomeniaAdSchemaCatalogForAnalysis
    if($null -eq $catalog){$grid.ItemsSource=$null;return}
    $kind=Get-DomeniaAdSchemaListKind
    $found=Find-DomeniaAdSchemaEntries -Catalog $catalog -Text ([string](Get-DomeniaControl 'TxtAdSchemaFilter').Text) -Kind $kind -Limit 500
    $grid.ItemsSource=@($found.Rows)
    $label=if($kind -eq 'Classes'){'classe(s)'}else{'attribut(s)'}
    $text=[string]$found.Total+' '+$label+' trouvé(s)'
    if([int]$found.Total -gt [int]$found.Shown){$text+=', '+[string]$found.Shown+' affiché(s) : précisez le filtre'}
    [void](Set-DomeniaControlText 'LblAdSchemaDetail' ($text+'.'))
}

function Format-DomeniaAdSchemaAttributeDetail {
    param($Attribute)
    if($null -eq $Attribute){return 'Attribut inconnu du schéma lu.'}
    $hint=Get-DomeniaAdAttributeQueryHint $Attribute
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string]$Attribute.Name+' · '+[string]$Attribute.SyntaxLabel+' · '+$(if([bool]$Attribute.SingleValued){'une valeur'}else{'plusieurs valeurs'})+' · '+(Get-DomeniaAdAttributeIndexText $Attribute)+' · '+$(if([bool]$Attribute.InGlobalCatalog){'dans le catalogue global'}else{'hors catalogue global'}))
    if([string]$Attribute.Description){$lines.Add([string]$Attribute.Description)}
    if([string]$hint.Example){$lines.Add('Exemple de critère : '+[string]$hint.Example)}
    foreach($note in @($hint.Notes)){$lines.Add([string]$note)}
    return ($lines.ToArray() -join [Environment]::NewLine)
}

function Show-DomeniaAdSchemaSelection {
    $catalog=Get-DomeniaAdSchemaCatalogForAnalysis
    $row=(Get-DomeniaControl 'DgAdSchemaEntries').SelectedItem
    $members=Get-DomeniaControl 'DgAdSchemaClassAttributes'
    $insert=Get-DomeniaControl 'BtnAdSchemaInsert'
    if(($null -eq $catalog) -or ($null -eq $row)){if($null -ne $insert){$insert.IsEnabled=$false};return}
    if([string]$row.Kind -eq 'Class'){
        $result=Get-DomeniaAdClassAttributes -Catalog $catalog -ClassName ([string]$row.Nom)
        if($null -ne $members){$members.ItemsSource=@($result.Rows)}
        $class=$catalog.Classes[([string]$row.Nom).ToLowerInvariant()]
        $text=[string]$row.Nom+' · classe '+([string]$class.Category).ToLowerInvariant()+' · chaîne : '+(@($result.Chain) -join ' → ')+' · '+@($result.Rows).Count+' attribut(s) possible(s).'
        if([string]$class.Description){$text+=[Environment]::NewLine+[string]$class.Description}
        if(@($result.Missing).Count){$text+=[Environment]::NewLine+'Absents du schéma lu : '+(@($result.Missing) -join ', ')+'.'}
        $text+=[Environment]::NewLine+'Filtre sur cette classe : (objectClass='+[string]$row.Nom+'). Les classes dérivées en font partie (un poste est aussi de classe user) : ajoutez un critère objectCategory pour cibler. Choisissez un attribut pour son détail.'
        [void](Set-DomeniaControlText 'LblAdSchemaDetail' $text)
        if($null -ne $insert){$insert.IsEnabled=$false}
        return
    }
    if($null -ne $members){$members.ItemsSource=$null}
    $attribute=Get-DomeniaAdSchemaAttribute $catalog ([string]$row.Nom)
    [void](Set-DomeniaControlText 'LblAdSchemaDetail' (Format-DomeniaAdSchemaAttributeDetail $attribute))
    if($null -ne $insert){$insert.IsEnabled=(($null -ne $attribute) -and (-not [bool]$attribute.Constructed) -and (-not [bool]$attribute.Defunct))}
}

function Get-DomeniaAdSchemaSelectedAttribute {
    $catalog=Get-DomeniaAdSchemaCatalogForAnalysis
    if($null -eq $catalog){return $null}
    $member=(Get-DomeniaControl 'DgAdSchemaClassAttributes').SelectedItem
    if($null -ne $member){return (Get-DomeniaAdSchemaAttribute $catalog ([string]$member.Attribut))}
    $row=(Get-DomeniaControl 'DgAdSchemaEntries').SelectedItem
    if(($null -ne $row) -and ([string]$row.Kind -eq 'Attribute')){return (Get-DomeniaAdSchemaAttribute $catalog ([string]$row.Nom))}
    return $null
}

function Show-DomeniaAdSchemaClassAttribute {
    $attribute=Get-DomeniaAdSchemaSelectedAttribute
    $insert=Get-DomeniaControl 'BtnAdSchemaInsert'
    if($null -eq (Get-DomeniaControl 'DgAdSchemaClassAttributes').SelectedItem){return}
    [void](Set-DomeniaControlText 'LblAdSchemaDetail' (Format-DomeniaAdSchemaAttributeDetail $attribute))
    if($null -ne $insert){$insert.IsEnabled=(($null -ne $attribute) -and (-not [bool]$attribute.Constructed) -and (-not [bool]$attribute.Defunct))}
}

function Add-DomeniaAdSchemaAttributeToFilter {
    # Builds a draft only: the operator completes the value; nothing is executed from here.
    $attribute=Get-DomeniaAdSchemaSelectedAttribute
    if($null -eq $attribute){[void](Set-DomeniaControlText 'LblAdSchemaAnalysis' 'Choisissez dʼabord un attribut du schéma lu.');return}
    $hint=Get-DomeniaAdAttributeQueryHint $attribute
    if(-not [string]$hint.Example){[void](Set-DomeniaControlText 'LblAdSchemaAnalysis' ([string]@($hint.Notes)[0]));return}
    $box=Get-DomeniaControl 'TxtAdSchemaLdapFilter'
    $current=([string]$box.Text).Trim()
    # A filter typed without its outer parentheses is completed first, exactly as the analysis reads it.
    if($current -and (-not $current.StartsWith('('))){$current='('+$current+')'}
    $parsed=$null;if($current){$parsed=ConvertFrom-DomeniaLdapFilter $current}
    if(-not $current){$box.Text=[string]$hint.Example}
    elseif(($null -ne $parsed) -and ([bool]$parsed.Valid) -and ([string]$parsed.Root.Kind -eq 'And')){$box.Text=$current.Substring(0,$current.Length-1)+[string]$hint.Example+')'}
    else{$box.Text='(&'+$current+[string]$hint.Example+')'}
    Invoke-DomeniaAdSchemaFilterAnalysis
}

function Invoke-DomeniaAdSchemaFilterAnalysis {
    $text=[string](Get-DomeniaControl 'TxtAdSchemaLdapFilter').Text
    if(-not $text.Trim()){[void](Set-DomeniaControlText 'LblAdSchemaAnalysis' 'Saisissez un filtre LDAP à analyser.');return}
    $analysis=Get-DomeniaLdapFilterAnalysis -Filter $text -Catalog (Get-DomeniaAdSchemaCatalogForAnalysis)
    $lines=New-Object 'System.Collections.Generic.List[string]'
    $lines.Add([string]$analysis.Text)
    if(([bool]$analysis.Valid) -and (@($analysis.Attributes).Count -gt 0)){$lines.Add('Attributs du filtre : '+(@($analysis.Attributes) -join ', ')+'.')}
    [void](Set-DomeniaControlText 'LblAdSchemaAnalysis' ($lines.ToArray() -join [Environment]::NewLine))
}
