# Definition-only presentation module. Business panels use the existing main window.
$script:DomeniaSurfaceState=$null
$script:DomeniaSurfaceRecords=@{}
function Test-DomeniaEmbeddedHost {
    return ($null -ne $script:Window -and $script:Window.IsVisible -and $script:Window.Content -is [Windows.Controls.Grid])
}
function Get-DomeniaSurfaceRecord {
    param($Window)
    if(-not $script:DomeniaSurfaceRecords.ContainsKey($Window)){
        $script:DomeniaSurfaceRecords[$Window]=[pscustomobject]@{Window=$Window;Ready=$null;Keys=$null;Embedded=$false;Done=$false;Accepted=$false;Frame=$null;Status=$null;Cleanup=$null}
    }
    return $script:DomeniaSurfaceRecords[$Window]
}
function Register-DomeniaSurfaceReady {
    param($Window,[scriptblock]$Handler)
    if(Test-DomeniaEmbeddedHost){(Get-DomeniaSurfaceRecord $Window).Ready=$Handler}
    else{$Window.Add_ContentRendered($Handler)}
}
function Register-DomeniaSurfaceKeys {
    param($Window,[scriptblock]$Handler)
    if(Test-DomeniaEmbeddedHost){(Get-DomeniaSurfaceRecord $Window).Keys=$Handler}
    else{$Window.Add_KeyDown($Handler)}
}
function Get-DomeniaOwningDialog {
    param($Control)
    $active=$script:DomeniaSurfaceState
    if($null -ne $active -and -not $active.Done){return $active.Window}
    return [Windows.Window]::GetWindow($Control)
}
function Set-DomeniaSurfaceResult {
    param($Window,[bool]$Result)
    if($script:DomeniaSurfaceRecords.ContainsKey($Window) -and $script:DomeniaSurfaceRecords[$Window].Embedded){
        $r=$script:DomeniaSurfaceRecords[$Window];$r.Accepted=$Result;$Window.Close()
    }else{$Window.DialogResult=$Result}
}
function Get-DomeniaLogicalControls {
    param($Root)
    if($null -eq $Root){return}
    $queue=[Collections.Queue]::new();$queue.Enqueue($Root)
    $seen=[Collections.Generic.HashSet[object]]::new()
    while($queue.Count){
        $c=$queue.Dequeue();if($null -eq $c -or -not $seen.Add($c)){continue}
        if($c -isnot [Windows.DependencyObject]){continue}
        Write-Output -NoEnumerate $c
        foreach($child in [Windows.LogicalTreeHelper]::GetChildren($c)){if($child -is [Windows.DependencyObject]){$queue.Enqueue($child)}}
    }
}
function Set-DomeniaEmbeddedTheme {
    param($Root)
    foreach($c in @(Get-DomeniaLogicalControls $Root)){
        if($c -is [Windows.Controls.Primitives.TextBoxBase] -or $c -is [Windows.Controls.PasswordBox] -or $c -is [Windows.Controls.Primitives.Selector]){
            $c.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'BgInput')
            $c.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'TextColor')
            $c.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty,'BorderColor')
        }elseif($c -is [Windows.Controls.Button]){
            $style=if($c.IsDefault){'RunButton'}else{'BaseButton'}
            $c.SetResourceReference([Windows.FrameworkElement]::StyleProperty,$style)
            # Drop legacy local colors so the shared style controls the palette.
            $c.ClearValue([Windows.Controls.Control]::BackgroundProperty)
            $c.ClearValue([Windows.Controls.Control]::ForegroundProperty)
            $c.ClearValue([Windows.Controls.Control]::BorderBrushProperty)
        }elseif($c -is [Windows.Controls.TextBlock]){
            $c.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'TextColor')
        }elseif($c -is [Windows.Controls.Control]){
            $c.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'TextColor')
        }elseif($c -is [Windows.Controls.Border] -and $null -ne $c.Background -and $c.Background -is [Windows.Media.SolidColorBrush] -and $c.Background.Color.A -ne 0){
            $c.SetResourceReference([Windows.Controls.Border]::BackgroundProperty,'BgCard')
            $c.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty,'BorderColor')
        }
        if($c -is [Windows.Controls.Control]){
            [Windows.Controls.ToolTipService]::SetShowOnDisabled($c,$true)
            [Windows.Controls.ToolTipService]::SetInitialShowDelay($c,350)
            if($null -eq $c.ToolTip){
                $hint=switch($c.GetType().Name){
                    'PasswordBox'{'Mot de passe de cette demande. Jamais enregistré dans les préférences.'}
                    'TextBox'{'Saisie de ce panneau. Annuler ne valide aucune modification.'}
                    'DataGrid'{'Sélectionnez une ligne. Le choix doit être confirmé avec le bouton du panneau.'}
                    'ListBox'{'Sélectionnez un élément puis confirmez votre choix.'}
                    'Button'{'Action de ce panneau. Les contrôles de droits restent applicables.'}
                    default{'Contrôle du panneau intégré.'}
                }
                $c.ToolTip=$hint
            }
            [Windows.Automation.AutomationProperties]::SetHelpText($c,[string]$c.ToolTip)
            if(-not [Windows.Automation.AutomationProperties]::GetName($c)) {
                $role=if($c.Name){[string]$c.Name}else{[string]$c.ToolTip}
                [Windows.Automation.AutomationProperties]::SetName($c,$role)
            }
        }
    }
}
function Show-DomeniaEmbeddedWindow {
    param([Parameter(Mandatory=$true)]$Window,[switch]$ManagedCancel,[switch]$PreserveTheme)
    if(-not (Test-DomeniaEmbeddedHost)){
        if($null -ne $script:Window -and $script:Window.IsLoaded){$Window.Close();return $false}
        # Only the initial login or a fatal startup report can exist without the main host.
        return $Window.ShowDialog()
    }
    $parent=$script:DomeniaSurfaceState
    if($null -ne $parent -and -not $parent.Done){
        # An asynchronous warning must not open another sheet over a pending decision.
        $parent.Status.Text='Une autre demande attend. Terminez ou annulez ce panneau avant de la relancer.'
        try{Write-AppLog ('Demande intégrée reportée : '+[string]$Window.Title) 'WARN'}catch{}
        $Window.Close();[void]$script:DomeniaSurfaceRecords.Remove($Window);return $false
    }
    $main=$script:Window;$root=$main.Content
    $layer=$main.FindName('DomeniaDialogLayer')
    if($null -eq $layer){throw 'Hôte intégré absent du XAML principal. Réinstallez le pack complet.'}
    if(-not $main.Dispatcher.CheckAccess()){throw 'Un panneau métier doit être demandé depuis le Dispatcher.'}
    $r=Get-DomeniaSurfaceRecord $Window;$r.Embedded=$true;$r.Done=$false;$r.Accepted=$false
    $r.Frame=[Windows.Threading.DispatcherFrame]::new()
    $epoch=[long]$script:SessionEpoch;$base=[string]$script:Conn.BaseDn
    $body=$Window.Content;$Window.Content=$null
    if($null -eq $body){throw 'Le panneau demandé est vide.'}
    if($PreserveTheme){$body.Resources.MergedDictionaries.Add($Window.Resources)}else{Set-DomeniaEmbeddedTheme $body}
    $layer.Children.Clear();$layer.Visibility='Visible';$layer.Background='#66000000'
    [Windows.Input.KeyboardNavigation]::SetTabNavigation($layer,'Cycle')
    [Windows.Input.KeyboardNavigation]::SetControlTabNavigation($layer,'Cycle')
    $card=[Windows.Controls.Border]::new();$card.CornerRadius='16';$card.BorderThickness='1';$card.Margin='16'
    $card.HorizontalAlignment='Right';$card.VerticalAlignment='Stretch';$card.Padding='18'
    $card.MaxWidth=if([double]::IsNaN($Window.Width)){720.0}else{[Math]::Max(480.0,[Math]::Min(900.0,$Window.Width))}
    $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty,'BgCard')
    $card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty,'BorderColor')
    $layout=[Windows.Controls.Grid]::new()
    foreach($h in @('Auto','*','Auto')){[void]$layout.RowDefinitions.Add([Windows.Controls.RowDefinition]::new());$layout.RowDefinitions[$layout.RowDefinitions.Count-1].Height=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($h)}
    $header=[Windows.Controls.Grid]::new();$header.Margin='0,0,0,12'
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    [void]$header.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$header.ColumnDefinitions[1].Width='Auto'
    $title=[Windows.Controls.TextBlock]::new();$title.Text=[string]$Window.Title;$title.FontSize=18;$title.FontWeight='SemiBold';$title.TextWrapping='Wrap';$title.VerticalAlignment='Center';$title.Margin='0,0,12,0'
    $title.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'TextColor')
    [void]$header.Children.Add($title)
    $close=[Windows.Controls.Button]::new();$close.Name='EmbeddedClose';$close.Content='Fermer';$close.Width=84;$close.Height=36;$close.Margin='0'
    $close.ToolTip='Fermer ce panneau sans valider. La sélection principale est conservée.'
    [Windows.Automation.AutomationProperties]::SetName($close,'Fermer le panneau intégré')
    [Windows.Controls.Grid]::SetColumn($close,1);[void]$header.Children.Add($close)
    [void]$layout.Children.Add($header)
    [Windows.Controls.Grid]::SetRow($body,1);[void]$layout.Children.Add($body)
    $r.Status=[Windows.Controls.TextBlock]::new();$r.Status.TextWrapping='Wrap';$r.Status.MaxHeight=72;$r.Status.Margin='0,8,0,0';$r.Status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedColor')
    [Windows.Controls.Grid]::SetRow($r.Status,2);[void]$layout.Children.Add($r.Status)
    $card.Child=$layout;[void]$layer.Children.Add($card)
    $saved=@();$bindings=@($main.InputBindings);$previousFocus=[Windows.Input.Keyboard]::FocusedElement
    foreach($item in @($root.Children)){
        if($item -ne $layer){$saved+=,[pscustomobject]@{Control=$item;Enabled=$item.IsEnabled};$item.IsEnabled=$false}
    }
    $main.InputBindings.Clear()
    $buttonStates=@();$cancel=$null;$defaults=@()
    foreach($b in @(Get-DomeniaLogicalControls $body|Where-Object{$_ -is [Windows.Controls.Button]})){
        if($b.IsCancel -or $b.IsDefault){$buttonStates+=,[pscustomobject]@{Control=$b;Cancel=$b.IsCancel;Default=$b.IsDefault}}
        if($b.IsCancel){$cancel=$b;$b.IsCancel=$false
            if(-not $ManagedCancel){$cancelSource=$Window;$b.Add_Click({$cancelSource.Close()}.GetNewClosure())}
        }
        if($b.IsDefault){$defaults+=,$b;$b.IsDefault=$false}
    }
    $cancelAction={
        if($ManagedCancel -and $null -ne $cancel -and $cancel.IsEnabled){$cancel.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))}
        else{$Window.Close()}
    }.GetNewClosure()
    $close.Add_Click($cancelAction)
    $r.Cleanup={
        if($r.Done){return};$r.Done=$true;$r.Frame.Continue=$false
        [void]$layout.Children.Remove($body);$layer.Children.Clear();$layer.Visibility='Collapsed'
        foreach($s in $saved){$s.Control.IsEnabled=$s.Enabled}
        foreach($binding in $bindings){[void]$main.InputBindings.Add($binding)}
        foreach($b in $buttonStates){$b.Control.IsCancel=$b.Cancel;$b.Control.IsDefault=$b.Default}
        if($null -ne $previousFocus -and $previousFocus -is [Windows.UIElement] -and $previousFocus.IsVisible -and $previousFocus.IsEnabled){[void]$previousFocus.Focus()}
    }.GetNewClosure()
    $onClosed={& $r.Cleanup}.GetNewClosure();$Window.Add_Closed($onClosed)
    $keys={param($sender,$e)
        if($e.Key -eq [Windows.Input.Key]::Escape){& $cancelAction;$e.Handled=$true;return}
        if($null -ne $r.Keys){& $r.Keys $Window $e}
        if(-not $e.Handled -and $e.Key -eq [Windows.Input.Key]::Enter){
            $multiline=($e.OriginalSource -is [Windows.Controls.TextBox] -and $e.OriginalSource.AcceptsReturn)
            if(-not $multiline){$d=@($defaults|Where-Object{$_.IsEnabled -and $_.IsVisible}|Select-Object -First 1);if($d.Count){$d[0].RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent));$e.Handled=$true}}
        }
        # Prevent an application shortcut from acting on the disabled page underneath. Never inside a text or
        # password field (Shift and AltGr = Ctrl+Alt type characters, Ctrl+C/V/A edit the field), and Shift alone
        # is not a shortcut (field report 2026-10-05: uppercase and AltGr characters could not be typed).
        $focused=[Windows.Input.Keyboard]::FocusedElement
        $inText=(($e.OriginalSource -is [Windows.Controls.Primitives.TextBoxBase]) -or ($e.OriginalSource -is [Windows.Controls.PasswordBox]) -or ($focused -is [Windows.Controls.Primitives.TextBoxBase]) -or ($focused -is [Windows.Controls.PasswordBox]))
        $shortcut=(([Windows.Input.Keyboard]::Modifiers -band ([Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Alt)) -ne [Windows.Input.ModifierKeys]::None)
        if((-not $inText) -and $shortcut -and $e.Key -ne [Windows.Input.Key]::Tab){$e.Handled=$true}
    }.GetNewClosure()
    $layer.Add_KeyDown($keys)
    # GetNewClosure binds these handlers to a module linked to the global scope only: the application functions they
    # call are captured here (same rule as Domenia-Access.UI), never looked up by name (field report 2026-10-05).
    $fnCapsLock=${function:Update-DomeniaExperienceCapsLock};$fnContext=${function:Get-DomeniaEmbeddedContext}
    $keyUp={param($sender,$e)
        if($PreserveTheme -and $null -ne $fnCapsLock -and $null -ne $Window.FindName('LblSuiteCapsLock')){& $fnCapsLock $Window}
    }.GetNewClosure()
    $layer.Add_PreviewKeyUp($keyUp)
    $tick=[Windows.Threading.DispatcherTimer]::new([Windows.Threading.DispatcherPriority]::Background);$tick.Interval=[timespan]::FromMilliseconds(150)
    $guard={
        $current=& $fnContext
        if(-not $main.IsVisible -or $current.Closing -or $current.Epoch -ne $epoch -or $current.BaseDn -ine $base){$r.Accepted=$false;$Window.Close()}
    }.GetNewClosure();$tick.Add_Tick($guard)
    $script:DomeniaSurfaceState=$r;$watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $tick.Start()
        if($null -ne $r.Ready){& $r.Ready $Window $null|Out-Null}
        else{[void]$close.Focus()}
        if(-not $r.Done){[Windows.Threading.Dispatcher]::PushFrame($r.Frame)}
        return [bool]$r.Accepted
    }finally{
        $tick.Stop();$tick.Remove_Tick($guard);$layer.Remove_KeyDown($keys);$layer.Remove_PreviewKeyUp($keyUp);$Window.Remove_Closed($onClosed)
        & $r.Cleanup
        foreach($c in @(Get-DomeniaLogicalControls $body)){if($c -is [Windows.Controls.PasswordBox]){$c.Clear()}}
        $watch.Stop();$script:ModalBlockedMs=[long]$script:ModalBlockedMs+$watch.ElapsedMilliseconds
        if($script:DomeniaSurfaceState -eq $r){$script:DomeniaSurfaceState=$null}
        [void]$script:DomeniaSurfaceRecords.Remove($Window)
    }
}
function Get-DomeniaEmbeddedLookupCode {
@'
$kind=[string]$Payload.Kind
if($kind -notin @('Machine','Utilisateur','OU')){throw 'Type de recherche non autorisé.'}
$term=([string]$Payload.Term).Trim()
$verify=[bool]$Payload.Verify
$properties=@('name','sAMAccountName','displayName','givenName','sn','mail','userPrincipalName','dNSHostName','description','distinguishedName','objectGUID')
$category=switch($kind){'Machine'{'(objectCategory=computer)'}'Utilisateur'{'(&(objectCategory=person)(objectClass=user))'}'OU'{'(objectClass=organizationalUnit)'}}
$root=[string]$Context.BaseDn;$scope='Subtree';$maximum=100
if($verify){
    $root=[string]$Payload.DN;$scope='Base';$maximum=2;$filter=$category
    if(-not $root.EndsWith(','+[string]$Context.BaseDn,[StringComparison]::OrdinalIgnoreCase)){throw 'Cible hors du domaine courant.'}
}else{
    if($kind -ne 'OU' -and $term.Length -lt 2){throw 'Saisissez au moins deux caractères.'}
    if($term.Length -gt 160){throw 'Recherche trop longue (160 caractères maximum).'}
    $escaped=Escape-WLdap $term
    $filter=if(-not $term){$category}else{'(&'+$category+'(|(name=*'+$escaped+'*)(sAMAccountName='+$escaped+'*)(displayName=*'+$escaped+'*)(givenName='+$escaped+'*)(sn='+$escaped+'*)(mail='+$escaped+'*)(userPrincipalName='+$escaped+'*)(dNSHostName='+$escaped+'*)))'}
}
$s=$null;$owned=$null;$set=$null;$rows=[Collections.Generic.List[object]]::new()
try{
    $s=New-WSearcher $Context $root $filter $properties $scope ($maximum+1);$owned=$s.SearchRoot
    $s.PageSize=40;$s.CacheResults=$false;$s.ServerTimeLimit=[timespan]::FromSeconds(8);$s.ClientTimeout=[timespan]::FromSeconds(10)
    $set=$s.FindAll()
    foreach($item in $set){
        if($rows.Count -gt $maximum){break}
        $p=$item.Properties;$guid=Convert-WGuid (Get-WPropFirst $p 'objectguid' $null)
        if(-not $guid){throw 'GUID AD non lisible ; aucun choix ne sera validé.'}
        $name=[string](Get-WPropFirst $p 'name' '');$dn=[string](Get-WPropFirst $p 'distinguishedname' '')
        $login=[string](Get-WPropFirst $p 'samaccountname' '');$second=if($kind -eq 'Utilisateur'){$login}elseif($kind -eq 'OU'){$dn}else{[string](Get-WPropFirst $p 'dnshostname' '')}
        $rows.Add([pscustomobject]@{Type=$kind;Name=$name;Login=$login;Second=$second;DN=$dn;Guid=$guid;Description=[string](Get-WPropFirst $p 'description' '')})
    }
    if($verify){
        if($rows.Count -ne 1 -or $rows[0].Guid -ine [string]$Payload.Guid -or $rows[0].DN -ine $root){throw 'Objet déplacé, recréé ou devenu inaccessible. Relancez la recherche.'}
    }
    [pscustomobject]@{Rows=@($rows.ToArray()|Select-Object -First $maximum);Capped=($rows.Count -gt $maximum);Verified=$verify;RequestId=[string]$Payload.RequestId;Server=[string]$Context.Server}
}finally{if($null -ne $set){$set.Dispose()};if($null -ne $s){$s.Dispose()};if($null -ne $owned){$owned.Dispose()}}
'@
}
function Complete-DomeniaEmbeddedLookup {
    param($Result,$State)
    $r=$State.Owner
    if($r.Closed -or $r.RequestId -cne $State.RequestId -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.BaseDn -ine [string]$script:Conn.BaseDn){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','RequestId','Verified')
    if($null -eq $data -or $data.RequestId -cne $State.RequestId){Fail-DomeniaEmbeddedLookup 'Retour de recherche incohérent.' $State;return}
    $r.Job='';$r.Go.IsEnabled=$true;$r.Box.IsEnabled=$true;$r.Grid.IsEnabled=$true;$r.Busy.Visibility='Hidden'
    if([bool]$data.Verified -ne [bool]$State.Verify){Fail-DomeniaEmbeddedLookup 'Phase de recherche incohérente.' $State;return}
    if($data.Verified){
        $verified=@($data.Rows)
        if($verified.Count -ne 1 -or $verified[0].DN -ine $State.DN -or $verified[0].Guid -ine $State.Guid){Fail-DomeniaEmbeddedLookup 'Le choix vérifié ne correspond plus à la demande.' $State;return}
        $r.Selected=$verified[0];Set-DomeniaSurfaceResult $r.Window $true;return
    }
    $list=[Collections.ArrayList]::new();foreach($row in @($data.Rows)){[void]$list.Add($row)};$r.Grid.ItemsSource=$list
    $r.Accept.IsEnabled=$false
    $r.Status.Text=if($list.Count){$list.Count.ToString()+' résultat(s). Sélectionnez une ligne, puis confirmez.'}else{'Aucun résultat dans le domaine. Les filtres de la page principale ne sont pas utilisés.'}
    if($data.Capped){$r.Status.Text+=' Limite atteinte : affinez la recherche.'}
}
function Fail-DomeniaEmbeddedLookup {
    param($Message,$State)
    $r=$State.Owner
    if($r.Closed -or $r.RequestId -cne $State.RequestId -or $State.Epoch -ne [long]$script:SessionEpoch){return}
    $r.Job='';$r.Go.IsEnabled=$true;$r.Box.IsEnabled=$true;$r.Grid.IsEnabled=$true;$r.Accept.IsEnabled=$false;$r.Busy.Visibility='Hidden'
    $r.Status.Text='Lecture non confirmée : '+[string]$Message
}
function Show-DomeniaInlinePicker {
    param([ValidateSet('Machine','Utilisateur','OU')][string]$Kind,[string]$Title,[string]$Prompt,[string]$InitialTerm='')
    if(-not (Test-DomeniaEmbeddedHost)){throw 'Ouvrez la fenêtre principale avant de sélectionner un objet.'}
    $w=[Windows.Window]::new();$w.Title=$Title;$w.Width=820;$w.Height=600
    $root=[Windows.Controls.Grid]::new();$root.Name='IntegratedObjectPicker'
    foreach($h in @('Auto','Auto','*','64','Auto')){$rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($h);[void]$root.RowDefinitions.Add($rd)}
    $hint=[Windows.Controls.TextBlock]::new();$hint.Text=$Prompt;$hint.TextWrapping='Wrap';$hint.Margin='0,0,0,12';[void]$root.Children.Add($hint)
    $search=[Windows.Controls.Grid]::new();[void]$search.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$col=[Windows.Controls.ColumnDefinition]::new();$col.Width='Auto';[void]$search.ColumnDefinitions.Add($col)
    $box=[Windows.Controls.TextBox]::new();$box.Text=$InitialTerm;$box.Name='EmbeddedObjectTerm';$box.MaxLength=160;$box.MinHeight=40;$box.Margin='0,0,10,0';$box.ToolTip='Rechercher ce type d''objet sur tout le domaine, sans filtre OU. Les caractères spéciaux sont littéraux.'
    [void]$search.Children.Add($box)
    $go=[Windows.Controls.Button]::new();$go.Name='EmbeddedObjectSearch';$go.ToolTip='Rechercher dans tout le domaine. La liste principale et ses filtres restent inchangés.';$go.Content='Rechercher';$go.Width=124;$go.Height=40;$go.Margin='0';[Windows.Controls.Grid]::SetColumn($go,1);[void]$search.Children.Add($go)
    $search.Margin='0,0,0,12';[Windows.Controls.Grid]::SetRow($search,1);[void]$root.Children.Add($search)
    $grid=[Windows.Controls.DataGrid]::new();$grid.Name='EmbeddedObjectResults';$grid.AutoGenerateColumns=$false;$grid.IsReadOnly=$true;$grid.SelectionMode='Single';$grid.EnableRowVirtualization=$true;$grid.CanUserAddRows=$false
    foreach($spec in @(@('Nom','Name','160'),@('Identifiant / DNS','Second','200'),@('Description','Description','*'))){$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$spec[0];$c.Binding=[Windows.Data.Binding]::new($spec[1]);$c.Width=[Windows.Controls.DataGridLengthConverter]::new().ConvertFromInvariantString($spec[2]);[void]$grid.Columns.Add($c)}
    [Windows.Controls.Grid]::SetRow($grid,2);[void]$root.Children.Add($grid)
    $status=[Windows.Controls.TextBlock]::new();$status.Name='EmbeddedObjectStatus';$status.Text=if($Kind -eq 'OU'){'Rechercher affiche les OU ; saisir un nom permet d affiner.'}else{'Saisissez au moins deux caractères, puis Rechercher.'};$status.TextWrapping='Wrap';$status.Margin='0,10,0,6';$status.MaxHeight=52
    [Windows.Controls.Grid]::SetRow($status,3);[void]$root.Children.Add($status)
    $foot=[Windows.Controls.Grid]::new();[void]$foot.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$col=[Windows.Controls.ColumnDefinition]::new();$col.Width='Auto';[void]$foot.ColumnDefinitions.Add($col)
    $busy=[Windows.Controls.ProgressBar]::new();$busy.IsIndeterminate=$true;$busy.Width=120;$busy.Height=4;$busy.Visibility='Hidden';$busy.HorizontalAlignment='Left';[void]$foot.Children.Add($busy)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';[Windows.Controls.Grid]::SetColumn($buttons,1);[void]$foot.Children.Add($buttons)
    $cancel=[Windows.Controls.Button]::new();$cancel.Name='EmbeddedObjectCancel';$cancel.ToolTip='Fermer sans choisir ni enregistrer une association.';$cancel.Content='Annuler';$cancel.Width=108;$cancel.Height=40;$cancel.IsCancel=$true;[void]$buttons.Children.Add($cancel)
    $accept=[Windows.Controls.Button]::new();$accept.Name='EmbeddedObjectAccept';$accept.ToolTip='Revérifier l objet choisi et le transmettre au formulaire. Une association ou un déplacement demande encore sa confirmation.';$accept.Content='Choisir';$accept.Width=130;$accept.Height=40;$accept.Margin='0';$accept.IsEnabled=$false;$accept.IsDefault=$true;[void]$buttons.Children.Add($accept)
    [Windows.Controls.Grid]::SetRow($foot,4);[void]$root.Children.Add($foot);$w.Content=$root
    $r=[pscustomobject]@{Window=$w;Kind=$Kind;Box=$box;Grid=$grid;Go=$go;Accept=$accept;Busy=$busy;Status=$status;RequestId='';Closed=$false;Job='';Selected=$null}
    # GetNewClosure binds these handlers to a module linked to the global scope only: the application functions they
    # call are captured here (same rule as Domenia-Access.UI), never looked up by name (field report 2026-10-05).
    $fnContext=${function:Get-DomeniaEmbeddedContext};$fnStartTask=${function:Start-UiTask};$fnLookupCode=${function:Get-DomeniaEmbeddedLookupCode}
    $run={param([bool]$Verify=$false)
        try{
            if($r.Job){return}
            $term=([string]$r.Box.Text).Trim();$row=$r.Grid.SelectedItem
            if(-not $Verify -and $r.Kind -ne 'OU' -and $term.Length -lt 2){$r.Status.Text='Saisissez au moins deux caractères.';return}
            if($Verify -and $null -eq $row){return}
            $r.RequestId=[guid]::NewGuid().ToString('N');$r.Accept.IsEnabled=$false;$r.Go.IsEnabled=$false;$r.Box.IsEnabled=$false;$r.Grid.IsEnabled=$false;$r.Busy.Visibility='Visible'
            if(-not $Verify){$r.Grid.ItemsSource=$null}
            $r.Status.Text=if($Verify){'Vérification de l''objet sélectionné…'}else{'Recherche dans le domaine…'}
            $ctx=& $fnContext
            $state=[pscustomobject]@{Owner=$r;RequestId=$r.RequestId;Epoch=$ctx.Epoch;BaseDn=$ctx.BaseDn;Verify=$Verify;DN=$(if($null -ne $row){[string]$row.DN}else{''});Guid=$(if($null -ne $row){[string]$row.Guid}else{''})}
            $payload=[pscustomobject]@{Kind=$r.Kind;Term=$term;Verify=$Verify;RequestId=$r.RequestId;DN=$(if($null -ne $row){[string]$row.DN}else{''});Guid=$(if($null -ne $row){[string]$row.Guid}else{''})}
            $r.Job=& $fnStartTask -Name 'Choix intégré dans AD' -OperationId 'EmbeddedDirectoryLookup' -Code (& $fnLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'embedded:lookup' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaEmbeddedLookup' -ErrorHandler 'Fail-DomeniaEmbeddedLookup'
        }catch{$r.Job='';$r.Go.IsEnabled=$true;$r.Box.IsEnabled=$true;$r.Grid.IsEnabled=$true;$r.Busy.Visibility='Hidden';$r.Status.Text='Recherche non confirmée : '+$_.Exception.Message}
    }.GetNewClosure()
    $go.Add_Click({& $run $false}.GetNewClosure());$accept.Add_Click({& $run $true}.GetNewClosure())
    $box.Add_KeyDown({param($s,$e) if($e.Key -eq 'Return'){$e.Handled=$true;& $run $false}}.GetNewClosure())
    $grid.Add_SelectionChanged({$r.Accept.IsEnabled=($null -ne $r.Grid.SelectedItem -and -not $r.Job)}.GetNewClosure())
    $box.Add_TextChanged({$r.Accept.IsEnabled=$false;$r.Grid.ItemsSource=$null}.GetNewClosure())
    Register-DomeniaSurfaceReady $w ({ [void]$box.Focus() }.GetNewClosure())
    try{[void](Show-DomeniaEmbeddedWindow $w);return $r.Selected}
    finally{$r.Closed=$true;if($r.Job){Request-UiTaskStop -Id $r.Job -Silent -Force -Superseded -Reason 'Sélecteur fermé'|Out-Null};$grid.ItemsSource=$null;$w.Close()}
}
function Select-DomeniaRelationsUser {
    # D045: no separate window to associate. The user is searched in Relations > Associer > Rechercher, in the
    # page, from a selected workstation (or a user is selected in Rechercher). Nothing is probed here.
    $workspace=Get-DomeniaControl 'WorkspaceTabs';$relations=Get-DomeniaControl 'TabRelations';if($null -ne $workspace -and $null -ne $relations){$workspace.SelectedItem=$relations}
    $tabs=Get-DomeniaControl 'RelationTabs';$associate=Get-DomeniaControl 'TabLinksAssociate';if($null -ne $tabs -and $null -ne $associate){$tabs.SelectedItem=$associate}
    $modes=Get-DomeniaControl 'RelationAssociateModeTabs';$search=Get-DomeniaControl 'TabRelationSearch';if($null -ne $modes -and $null -ne $search){$modes.SelectedItem=$search}
    Refresh-DomeniaRelationViews
    $s=Get-DomeniaRelationsSubject
    $text=if($null -ne $s -and [string]$s.Type -eq 'Machine'){'Recherchez dans cette page lʼutilisateur à associer à '+[string]$s.Name+'.'}else{'Sélectionnez un utilisateur dans Rechercher, ou un poste puis recherchez ici lʼutilisateur à lui associer.'}
    [void](Set-DomeniaControlText 'LblRelationAssociateHint' $text)
    $box=Get-DomeniaControl 'TxtRelationComputerSearch';if($null -ne $box -and $box.IsEnabled){[void]$box.Focus()}
}
function Get-DomeniaEmbeddedContext {
    return [pscustomobject]@{Epoch=[long]$script:SessionEpoch;BaseDn=[string]$script:Conn.BaseDn;Closing=[bool]$script:AsyncEngineClosing}
}
function New-DomeniaFileRequest {
    param([ValidateSet('Open','Save')][string]$Mode)
    $request=[pscustomobject]@{Mode=$Mode;Title='Choisir un fichier';FileName='';Filter='Tous les fichiers (*.*)|*.*';InitialDirectory='';OverwritePrompt=$true;CheckFileExists=$true;DefaultExt='';AddExtension=$true}
    $request|Add-Member -MemberType ScriptMethod -Name ShowDialog -Value {param($Owner);return (Show-DomeniaInlineFilePicker -Request $this)}
    return $request
}
function Get-DomeniaEmbeddedPathCode {
@'
$action=[string]$Payload.Action
$path=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$Payload.Path))
if($action -eq 'Validate'){
    $parent=[IO.Path]::GetDirectoryName($path)
    $parentInfo=Get-Item -LiteralPath $parent -ErrorAction Stop
    if($parentInfo -isnot [IO.DirectoryInfo]){throw 'Le dossier de destination n''existe pas.'}
    $item=$null
    try { $item=Get-Item -LiteralPath $path -ErrorAction Stop }
    catch [Management.Automation.ItemNotFoundException] { $item=$null }
    if($null -ne $item -and $item -isnot [IO.FileInfo]){throw 'Sélectionnez un fichier, pas un dossier.'}
    if($Payload.Mode -eq 'Open' -and $null -eq $item){throw 'Fichier introuvable ou inaccessible.'}
    $signature=if($null -ne $item){$item.Length.ToString()+'|'+$item.LastWriteTimeUtc.Ticks.ToString()}else{'absent'}
    [pscustomobject]@{Action=$action;RequestId=$Payload.RequestId;Path=$path;Exists=($null -ne $item);Signature=$signature;Rows=@();Capped=$false}
}elseif($action -eq 'Browse'){
    $dir=Get-Item -LiteralPath $path -ErrorAction Stop
    if($dir -isnot [IO.DirectoryInfo]){throw 'Saisissez un dossier existant.'}
    $rows=[Collections.Generic.List[object]]::new();$capped=$false
    foreach($item in (Get-ChildItem -LiteralPath $path -ErrorAction Stop | Select-Object -First 501)){
        if($rows.Count -ge 500){$capped=$true;break}
        $rows.Add([pscustomobject]@{Name=$item.Name;Path=$item.FullName;IsDirectory=[bool]$item.PSIsContainer;Kind=$(if($item.PSIsContainer){'Dossier'}else{'Fichier'});Length=$(if($item.PSIsContainer){''}else{[string]$item.Length})})
    }
    [pscustomobject]@{Action=$action;RequestId=$Payload.RequestId;Path=$path;Exists=$true;Signature='';Rows=@($rows.ToArray()|Sort-Object @{Expression='IsDirectory';Descending=$true},Name);Capped=$capped}
}else{throw 'Action de fichier non autorisée.'}
'@
}
function Complete-DomeniaEmbeddedPath {
    param($Result,$State)
    $r=$State.Owner
    if($r.Closed -or $State.RequestId -cne $r.RequestId){return}
    $ctx=Get-DomeniaEmbeddedContext
    if($ctx.Epoch -ne $State.Epoch){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Action','RequestId','Path','Rows')
    if($null -eq $data -or $data.RequestId -cne $State.RequestId){Fail-DomeniaEmbeddedPath 'Retour de fichiers incohérent.' $State;return}
    $r.Job='';$r.Busy.Visibility='Hidden';$r.Go.IsEnabled=$true;$r.Accept.IsEnabled=$true;$r.Folder.IsEnabled=$true;$r.File.IsEnabled=$true;$r.Up.IsEnabled=$true
    if($data.Action -eq 'Browse'){
        $r.Path=$data.Path;$r.Folder.Text=$data.Path
        $list=[Collections.ArrayList]::new();foreach($row in @($data.Rows)){[void]$list.Add($row)};$r.Grid.ItemsSource=$list
        $r.Status.Text=$list.Count.ToString()+' entrée(s). Double-cliquez un dossier pour le parcourir. Aucune création de dossier automatique.'
        if($data.Capped){$r.Status.Text+=' Affichage limité à 500 entrées ; saisissez le nom exact si nécessaire.'}
    }else{
        if($r.Request.Mode -eq 'Save' -and $data.Exists -and $r.Request.OverwritePrompt -and $r.Overwrite -cne ($data.Path+'|'+$data.Signature)){
            $r.Overwrite=$data.Path+'|'+$data.Signature;$r.Accept.Content='Remplacer';$r.Status.Text='Ce fichier existe. Cliquez explicitement sur Remplacer pour confirmer, ou Annuler.';return
        }
        $r.Request.FileName=$data.Path;Set-DomeniaSurfaceResult $r.Window $true
    }
}
function Fail-DomeniaEmbeddedPath {
    param($Message,$State)
    $r=$State.Owner
    if($r.Closed -or $State.RequestId -cne $r.RequestId){return}
    $r.Job='';$r.Busy.Visibility='Hidden';$r.Go.IsEnabled=$true;$r.Accept.IsEnabled=$true;$r.Folder.IsEnabled=$true;$r.File.IsEnabled=$true;$r.Up.IsEnabled=$true
    $r.Status.Text='Accès au fichier non confirmé : '+[string]$Message
}
function Show-DomeniaInlineFilePicker {
    param($Request)
    if(-not (Test-DomeniaEmbeddedHost)){throw 'Le choix de fichier nécessite la fenêtre principale.'}
    $w=[Windows.Window]::new();$w.Width=860;$w.Height=620;$w.Title=[string]$Request.Title
    $grid=[Windows.Controls.Grid]::new();$grid.Name='IntegratedFilePicker'
    foreach($h in @('Auto','Auto','*','Auto','68','Auto')){$rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($h);[void]$grid.RowDefinitions.Add($rd)}
    $info=[Windows.Controls.TextBlock]::new();$info.Text=if($Request.Mode -eq 'Open'){'Ouvrir un fichier. La lecture métier commence seulement après validation.'}else{'Choisir où enregistrer. Aucun envoi automatique ni création de dossier.'};$info.TextWrapping='Wrap';$info.Margin='0,0,0,10';[void]$grid.Children.Add($info)
    $bar=[Windows.Controls.Grid]::new();[void]$bar.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());foreach($i in 1..2){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width='Auto';[void]$bar.ColumnDefinitions.Add($c)}
    $folder=[Windows.Controls.TextBox]::new();$folder.Name='EmbeddedFolder';$folder.MinHeight=40;$folder.Margin='0,0,8,0';$folder.ToolTip='Chemin du dossier à parcourir. Un partage réseau n''est interrogé que sur votre demande.';[void]$bar.Children.Add($folder)
    $go=[Windows.Controls.Button]::new();$go.Name='EmbeddedBrowse';$go.ToolTip='Lire les fichiers et dossiers de ce seul emplacement, en arrière-plan (maximum 500 entrées).';$go.Content='Parcourir';$go.Width=110;$go.Height=40;[Windows.Controls.Grid]::SetColumn($go,1);[void]$bar.Children.Add($go)
    $up=[Windows.Controls.Button]::new();$up.ToolTip='Afficher le dossier parent dans ce même panneau.';$up.Content='Parent';$up.Width=86;$up.Height=40;$up.Margin='0';[Windows.Controls.Grid]::SetColumn($up,2);[void]$bar.Children.Add($up)
    $bar.Margin='0,0,0,10';[Windows.Controls.Grid]::SetRow($bar,1);[void]$grid.Children.Add($bar)
    $list=[Windows.Controls.DataGrid]::new();$list.Name='EmbeddedFileResults';$list.AutoGenerateColumns=$false;$list.IsReadOnly=$true;$list.SelectionMode='Single';$list.CanUserAddRows=$false
    foreach($s in @(@('Nom','Name','*'),@('Type','Kind','90'),@('Octets','Length','100'))){$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$s[0];$c.Binding=[Windows.Data.Binding]::new($s[1]);$c.Width=[Windows.Controls.DataGridLengthConverter]::new().ConvertFromInvariantString($s[2]);[void]$list.Columns.Add($c)}
    [Windows.Controls.Grid]::SetRow($list,2);[void]$grid.Children.Add($list)
    $filePanel=[Windows.Controls.StackPanel]::new();$filePanel.Margin='0,10,0,0'
    $label=[Windows.Controls.TextBlock]::new();$label.Text='Nom du fichier';$label.Margin='0,0,0,4';[void]$filePanel.Children.Add($label)
    $file=[Windows.Controls.TextBox]::new();$file.Name='EmbeddedFileName';$file.MinHeight=40;$file.ToolTip='Nom du fichier. Un chemin complet est aussi accepté.';[void]$filePanel.Children.Add($file)
    [Windows.Controls.Grid]::SetRow($filePanel,3);[void]$grid.Children.Add($filePanel)
    $status=[Windows.Controls.TextBlock]::new();$status.Margin='0,10,0,6';$status.TextWrapping='Wrap';$status.MaxHeight=60;[Windows.Controls.Grid]::SetRow($status,4);[void]$grid.Children.Add($status)
    $foot=[Windows.Controls.Grid]::new();[void]$foot.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$col=[Windows.Controls.ColumnDefinition]::new();$col.Width='Auto';[void]$foot.ColumnDefinitions.Add($col)
    $busy=[Windows.Controls.ProgressBar]::new();$busy.Width=120;$busy.Height=4;$busy.IsIndeterminate=$true;$busy.Visibility='Hidden';$busy.HorizontalAlignment='Left';[void]$foot.Children.Add($busy)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';[Windows.Controls.Grid]::SetColumn($buttons,1);[void]$foot.Children.Add($buttons)
    $cancel=[Windows.Controls.Button]::new();$cancel.Content='Annuler';$cancel.Height=40;$cancel.Width=100;$cancel.IsCancel=$true;[void]$buttons.Children.Add($cancel)
    $accept=[Windows.Controls.Button]::new();$accept.Name='EmbeddedFileAccept';$accept.ToolTip='Vérifier ce chemin puis le transmettre à la commande. Un fichier existant à remplacer exige une confirmation.';$accept.Content=if($Request.Mode -eq 'Open'){'Ouvrir'}else{'Enregistrer'};$accept.Height=40;$accept.Width=135;$accept.Margin='0';$accept.IsDefault=$true;[void]$buttons.Children.Add($accept)
    [Windows.Controls.Grid]::SetRow($foot,5);[void]$grid.Children.Add($foot);$w.Content=$grid
    $r=[pscustomobject]@{Window=$w;Request=$Request;Folder=$folder;File=$file;Grid=$list;Go=$go;Up=$up;Accept=$accept;Busy=$busy;Status=$status;Path='';RequestId='';Closed=$false;Job='';Overwrite=''}
    $folder.Text=if($Request.InitialDirectory){$Request.InitialDirectory}else{[Environment]::GetFolderPath('UserProfile')}
    $file.Text=[string]$Request.FileName
    # GetNewClosure binds these handlers to a module linked to the global scope only: the application functions they
    # call are captured here (same rule as Domenia-Access.UI), never looked up by name (field report 2026-10-05).
    $fnContext=${function:Get-DomeniaEmbeddedContext};$fnStartTask=${function:Start-UiTask};$fnPathCode=${function:Get-DomeniaEmbeddedPathCode}
    $submit={param([string]$Action='Browse')
        if($r.Job){return}
        try{
            $ctx=& $fnContext
            if($Action -eq 'Browse'){$path=$r.Folder.Text.Trim()}
            else{
                $name=$r.File.Text.Trim();if(-not $name){$r.Status.Text='Saisissez un nom de fichier.';return}
                if($r.Request.Mode -eq 'Save' -and $r.Request.AddExtension -and -not [IO.Path]::GetExtension($name)){
                    $ext=$r.Request.DefaultExt
                    if(-not $ext -and $r.Request.Filter -match '\*\.(\w+)'){$ext='.'+$Matches[1]}
                    if($ext){if(-not $ext.StartsWith('.')){$ext='.'+$ext};$name+=$ext}
                }
                $path=if([IO.Path]::IsPathRooted($name)){$name}else{Join-Path $r.Folder.Text.Trim() $name}
            }
            if(-not [IO.Path]::IsPathRooted($path)){throw 'Utilisez un chemin complet de dossier.'}
            $r.RequestId=[guid]::NewGuid().ToString('N');$r.Accept.IsEnabled=$false;$r.Go.IsEnabled=$false;$r.Up.IsEnabled=$false;$r.Folder.IsEnabled=$false;$r.File.IsEnabled=$false;$r.Busy.Visibility='Visible'
            $r.Status.Text='Lecture du dossier…'
            $payload=[pscustomobject]@{Action=$Action;Path=$path;Mode=$r.Request.Mode;RequestId=$r.RequestId}
            $state=[pscustomobject]@{Owner=$r;RequestId=$r.RequestId;Epoch=$ctx.Epoch}
            $r.Job=& $fnStartTask -Name 'Choix du fichier' -OperationId 'EmbeddedPathBrowse' -Code (& $fnPathCode) -Payload $payload -CallbackState $state -ReplaceKey 'embedded:files' -TimeoutSeconds 15 -SuccessHandler 'Complete-DomeniaEmbeddedPath' -ErrorHandler 'Fail-DomeniaEmbeddedPath'
        }catch{$r.Job='';$r.Go.IsEnabled=$true;$r.Up.IsEnabled=$true;$r.Accept.IsEnabled=$true;$r.Folder.IsEnabled=$true;$r.File.IsEnabled=$true;$r.Busy.Visibility='Hidden';$r.Status.Text=$_.Exception.Message}
    }.GetNewClosure()
    $go.Add_Click({& $submit 'Browse'}.GetNewClosure());$accept.Add_Click({& $submit 'Validate'}.GetNewClosure())
    $folder.Add_KeyDown({param($s,$e) if($e.Key -eq 'Return'){$e.Handled=$true;& $submit 'Browse'}}.GetNewClosure())
    $up.Add_Click({try{$parent=[IO.Directory]::GetParent($r.Folder.Text.Trim());if($null -ne $parent){$r.Folder.Text=$parent.FullName;& $submit 'Browse'}}catch{$r.Status.Text=$_.Exception.Message}}.GetNewClosure())
    $list.Add_SelectionChanged({$row=$r.Grid.SelectedItem;if($null -ne $row -and -not $row.IsDirectory){$r.File.Text=$row.Name}}.GetNewClosure())
    $list.Add_MouseDoubleClick({param($s,$e)
        $origin=$e.OriginalSource;$container=[Windows.Controls.ItemsControl]::ContainerFromElement($r.Grid,$origin)
        if($container -isnot [Windows.Controls.DataGridRow]){return}
        $row=$container.Item;if($row.IsDirectory -and -not $r.Job){$r.Folder.Text=$row.Path;& $submit 'Browse'}
    }.GetNewClosure())
    $reset={ $r.Overwrite='';$r.Accept.Content=if($r.Request.Mode -eq 'Open'){'Ouvrir'}else{'Enregistrer'} }.GetNewClosure()
    $file.Add_TextChanged($reset);$folder.Add_TextChanged($reset)
    Register-DomeniaSurfaceReady $w ({[void]$folder.Focus();$folder.SelectAll()}.GetNewClosure())
    $status.Text='Parcourir lit ce dossier en arrière-plan. Vous pouvez aussi saisir directement un chemin de fichier. Format attendu : '+$Request.Filter
    try{return (Show-DomeniaEmbeddedWindow $w)}
    finally{$r.Closed=$true;if($r.Job){Request-UiTaskStop -Id $r.Job -Silent -Force -Superseded -Reason 'Choix de fichier fermé'|Out-Null};$list.ItemsSource=$null;$w.Close()}
}
