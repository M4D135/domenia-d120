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
    # UX-06: an error raised while this sheet is open stays readable and closable in its banner, above the sheet.
    $bannerHost=$main.FindName('DomeniaBannerHost')
    foreach($item in @($root.Children)){
        if(($item -ne $layer) -and ($item -ne $bannerHost)){$saved+=,[pscustomobject]@{Control=$item;Enabled=$item.IsEnabled};$item.IsEnabled=$false}
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
    # FI-05: protected heartbeat timer of the sheet; it also runs minimized or hidden (it closes a stale sheet).
    $tick=New-DomeniaTimer -Owner 'Timer:EmbeddedSheet' -IntervalMs 150 -RunWhenHidden
    $guard={
        $current=& $fnContext
        if(-not $main.IsVisible -or $current.Closing -or $current.Epoch -ne $epoch -or $current.BaseDn -ine $base){$r.Accepted=$false;$Window.Close()}
    }.GetNewClosure();$tick.Tick=$guard
    $script:DomeniaSurfaceState=$r;$watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        $tick.Start()
        if($null -ne $r.Ready){& $r.Ready $Window $null|Out-Null}
        else{[void]$close.Focus()}
        if(-not $r.Done){[Windows.Threading.Dispatcher]::PushFrame($r.Frame)}
        return [bool]$r.Accepted
    }finally{
        $tick.Stop();$tick.Tick=$null;$layer.Remove_KeyDown($keys);$layer.Remove_PreviewKeyUp($keyUp);$Window.Remove_Closed($onClosed)
        & $r.Cleanup
        foreach($c in @(Get-DomeniaLogicalControls $body)){if($c -is [Windows.Controls.PasswordBox]){$c.Clear()}}
        $watch.Stop();$script:ModalBlockedMs=[long]$script:ModalBlockedMs+$watch.ElapsedMilliseconds
        if($script:DomeniaSurfaceState -eq $r){$script:DomeniaSurfaceState=$null}
        [void]$script:DomeniaSurfaceRecords.Remove($Window)
    }
}
# UX-06: information and errors as banners in the page (DomeniaBannerHost of the main XAML), never a window.
# Handlers are plain script blocks reading their banner from Tag: no closure, application functions resolve
# in the application scope like every other handler of this module.
$script:DomeniaBanners=$null
function Get-DomeniaBannerPlan {
    # Pure: what a banner shows and how long it stays. Information and success close after 5 s unless they carry
    # a detail or several paragraphs (a write outcome to read); warnings and errors stay until closed.
    param([string]$Kind='Info',[AllowEmptyString()][string]$Message='',[AllowEmptyString()][string]$Details='')
    $text=([string]$Message).Trim()
    $code='';$match=[regex]::Match($text,'\bINC-[0-9A-F]{4}\b');if($match.Success){$code=$match.Value}
    $paragraphs=@([regex]::Split($text,'(?:\r?\n[ \t]*){2,}')|Where-Object{([string]$_).Trim()})
    $headline=if($paragraphs.Count){([string]$paragraphs[0]).Trim()}else{''}
    $body=if($paragraphs.Count -gt 1){(@($paragraphs|Select-Object -Skip 1)|ForEach-Object{([string]$_).Trim()}) -join "`r`n`r`n"}else{''}
    $sticky=(($Kind -in @('Error','Warning')) -or ($paragraphs.Count -gt 1) -or (-not [string]::IsNullOrWhiteSpace($Details)))
    return [pscustomobject]@{Kind=$Kind;Headline=$headline;Body=$body;Details=[string]$Details;Code=$code;AutoCloseSeconds=$(if($sticky){0}else{5})}
}
function New-DomeniaBannerButton {
    param([string]$Text,[string]$Command,$Record,[string]$Help)
    $b=[Windows.Controls.Button]::new();$b.Content=$Text;$b.MinHeight=28;$b.Height=28;$b.Padding='10,2';$b.Margin='0,6,6,0'
    $b.SetResourceReference([Windows.FrameworkElement]::StyleProperty,'BaseButton')
    $b.ToolTip=$Help;[Windows.Automation.AutomationProperties]::SetName($b,$Text);[Windows.Automation.AutomationProperties]::SetHelpText($b,$Help)
    $b.Tag=[pscustomobject]@{Banner=$Record;Command=$Command}
    $b.Add_Click({param($sender,$eventArgs) Invoke-DomeniaBannerCommand -Sender $sender})
    return $b
}
function Show-DomeniaBanner {
    # Returns $false when the page cannot host a banner (no main window yet): the caller keeps its modal box.
    # UX-19 (X04): -RouteText/-Route add a button that opens the place of the action (Invoke-DomeniaCapabilityRoute)
    # instead of a written path; the route only navigates, nothing is read or written by it.
    param([ValidateSet('Info','Success','Warning','Error')][string]$Kind='Info',[AllowEmptyString()][string]$Message='',[AllowEmptyString()][string]$Details='',[string]$Key='',[string]$ActionText='',[string]$ActionPath='',[string]$RouteText='',[string]$Route='')
    if(-not (Test-DomeniaEmbeddedHost)){return $false}
    $hostPanel=$script:Window.FindName('DomeniaBannerHost')
    if(($null -eq $hostPanel) -or (-not $hostPanel.Dispatcher.CheckAccess())){return $false}
    if($null -eq $script:DomeniaBanners){$script:DomeniaBanners=[System.Collections.Generic.List[object]]::new()}
    $plan=Get-DomeniaBannerPlan -Kind $Kind -Message $Message -Details $Details
    if(-not $Key){$Key=if($plan.Code){$plan.Code}else{$Kind+'|'+([string]$Message).Trim()}}
    foreach($open in @($script:DomeniaBanners)){
        if((-not [bool]$open.Closed) -and ([string]$open.Key -ceq $Key)){
            # FI-02: the same incident updates its banner (counter, time, latest detail) instead of stacking one more.
            Update-DomeniaBannerOccurrence -Record $open -Plan $plan -Message $Message
            return $true
        }
    }
    $record=[pscustomobject]@{Key=$Key;Kind=$Kind;Message=([string]$Message).Trim();Details=[string]$Details;Code=$plan.Code;Occurrences=1;At=(Get-Date);ActionPath=$ActionPath;Route=$Route;Closed=$false;Pinned=$false;Border=$null;Counter=$null;DetailBox=$null;DetailButton=$null;Actions=$null;Stack=$null;Timer=$null;Panel=$hostPanel}
    $border=[Windows.Controls.Border]::new();$border.CornerRadius='12';$border.BorderThickness=[Windows.Thickness]::new(4,1,1,1);$border.Padding='12,10,8,10';$border.Margin='0,0,0,8';$border.MinWidth=380.0
    $accent=switch($Kind){'Error'{'DangerColor'}'Warning'{'StatusWarning'}'Success'{'StatusSuccess'}default{'AccentColor'}}
    $border.SetResourceReference([Windows.Controls.Border]::BackgroundProperty,'BgCard')
    $border.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty,$accent)
    $shadow=[Windows.Media.Effects.DropShadowEffect]::new();$shadow.BlurRadius=16;$shadow.ShadowDepth=2;$shadow.Opacity=0.22;$border.Effect=$shadow
    $kindLabel=switch($Kind){'Error'{'Erreur'}'Warning'{'Attention'}'Success'{'Terminé'}default{'Information'}}
    [Windows.Automation.AutomationProperties]::SetName($border,$kindLabel+' : '+$plan.Headline)
    $grid=[Windows.Controls.Grid]::new()
    foreach($w in @('Auto','*','Auto')){$c=[Windows.Controls.ColumnDefinition]::new();$c.Width=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($w);[void]$grid.ColumnDefinitions.Add($c)}
    $icon=[Windows.Controls.TextBlock]::new();$icon.FontFamily='Segoe UI Symbol';$icon.FontSize=18;$icon.Margin='0,0,10,0';$icon.VerticalAlignment='Top'
    $icon.Text=switch($Kind){'Error'{[string][char]0x2715}'Warning'{[string][char]0x26A0}'Success'{[string][char]0x2713}default{'i'}}
    $icon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,$(if($Kind -eq 'Info'){'AccentText'}elseif($Kind -eq 'Error'){'DangerColor'}else{$accent}))
    [void]$grid.Children.Add($icon)
    $stack=[Windows.Controls.StackPanel]::new();[Windows.Controls.Grid]::SetColumn($stack,1)
    $head=[Windows.Controls.TextBlock]::new();$head.Text=$plan.Headline;$head.TextWrapping='Wrap';$head.FontWeight='SemiBold'
    $head.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'TextColor');[void]$stack.Children.Add($head)
    if($plan.Body){
        $body=[Windows.Controls.TextBlock]::new();$body.Text=$plan.Body;$body.TextWrapping='Wrap';$body.Margin='0,4,0,0'
        $body.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedColor')
        $scroll=[Windows.Controls.ScrollViewer]::new();$scroll.MaxHeight=180;$scroll.VerticalScrollBarVisibility='Auto';$scroll.Content=$body
        [void]$stack.Children.Add($scroll)
    }
    $counter=[Windows.Controls.TextBlock]::new();$counter.FontSize=11;$counter.Margin='0,4,0,0';$counter.Visibility='Collapsed'
    $counter.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty,'MutedColor');[void]$stack.Children.Add($counter)
    $detail=[Windows.Controls.TextBox]::new();$detail.Text=$plan.Details;$detail.IsReadOnly=$true;$detail.TextWrapping='Wrap';$detail.AcceptsReturn=$true
    $detail.MaxHeight=200;$detail.VerticalScrollBarVisibility='Auto';$detail.Margin='0,6,0,0';$detail.Visibility='Collapsed'
    $detail.SetResourceReference([Windows.Controls.Control]::BackgroundProperty,'BgInput');$detail.SetResourceReference([Windows.Controls.Control]::ForegroundProperty,'TextColor')
    $detail.ToolTip='Détail du message. Sélectionnez le texte pour le copier.';[Windows.Automation.AutomationProperties]::SetName($detail,'Détail du message')
    [void]$stack.Children.Add($detail)
    $record.Border=$border;$record.Counter=$counter;$record.DetailBox=$detail
    $actions=[Windows.Controls.WrapPanel]::new();$actions.Margin='0,2,0,0'
    if($Kind -in @('Error','Warning')){
        [void]$actions.Children.Add((New-DomeniaBannerButton -Text 'Copier pour le support' -Command 'Support' -Record $record -Help 'Copie le code incident, lʼheure, le message et son détail. Les secrets connus sont masqués.'))
        [void]$actions.Children.Add((New-DomeniaBannerButton -Text 'Ouvrir le journal' -Command 'Journal' -Record $record -Help 'Déplie le journal de session en bas de la page.'))
    }
    if($plan.Details){
        $record.DetailButton=New-DomeniaBannerButton -Text 'Voir le détail' -Command 'Detail' -Record $record -Help 'Affiche ou masque le détail de ce message.'
        [void]$actions.Children.Add($record.DetailButton)
    }
    if($ActionText -and $ActionPath){[void]$actions.Children.Add((New-DomeniaBannerButton -Text $ActionText -Command 'Folder' -Record $record -Help ('Ouvre lʼExplorateur sur '+$ActionPath)))}
    if(($RouteText) -and ($Route)){[void]$actions.Children.Insert(0,(New-DomeniaBannerButton -Text $RouteText -Command 'Route' -Record $record -Help ('Ouvre lʼendroit de lʼaction : '+$RouteText+'. Rien nʼest lancé par ce clic.')))}
    $record.Actions=$actions;$record.Stack=$stack
    if($actions.Children.Count){[void]$stack.Children.Add($actions)}
    [void]$grid.Children.Add($stack)
    $close=New-DomeniaBannerButton -Text ([string][char]0x00D7) -Command 'Close' -Record $record -Help 'Ferme ce message. Il reste dans le journal de session.'
    $close.Margin='8,0,0,0';$close.Padding='8,0';$close.VerticalAlignment='Top';[Windows.Automation.AutomationProperties]::SetName($close,'Fermer le message')
    [Windows.Controls.Grid]::SetColumn($close,2);[void]$grid.Children.Add($close)
    $border.Child=$grid;$border.Tag=$record
    [void]$hostPanel.Children.Insert(0,$border);$script:DomeniaBanners.Add($record);$hostPanel.Visibility='Visible'
    # Three banners at most: the oldest leaves first; its text stays in the session journal.
    while(@($script:DomeniaBanners|Where-Object{-not $_.Closed}).Count -gt 3){Close-DomeniaBanner -Record @($script:DomeniaBanners|Where-Object{-not $_.Closed})[0]}
    if([int]$plan.AutoCloseSeconds -gt 0){
        # FI-05: protected one-shot heartbeat timer; a closed banner leaves the registry (-Transient).
        $timer=New-DomeniaTimer -Owner ('Timer:Banner:'+[guid]::NewGuid().ToString('N')) -IntervalMs ([int]$plan.AutoCloseSeconds*1000) -Transient -Tag $record -Tick {param($sender,$eventArgs) Close-DomeniaBanner -Record $sender.Tag}
        $record.Timer=$timer
        # Pointer over the banner: it stays while it is read.
        $border.Add_MouseEnter({param($sender,$eventArgs) $r=$sender.Tag;if(($null -ne $r) -and ($null -ne $r.Timer)){$r.Timer.Stop()}})
        $border.Add_MouseLeave({param($sender,$eventArgs) $r=$sender.Tag;if(($null -ne $r) -and ($null -ne $r.Timer) -and (-not $r.Closed) -and (-not $r.Pinned)){$r.Timer.Start()}})
        $timer.Start()
    }
    return $true
}
function Show-DomeniaRouteNotice {
    # UX-19 (X04): a status message whose place is a button (route of Invoke-DomeniaCapabilityRoute), never a
    # written path to a page. Without the main window, the status line alone carries the message and the action name.
    param([ValidateSet('Info','Warning','Error')][string]$Kind='Warning',[Parameter(Mandatory=$true)][string]$Text,[Parameter(Mandatory=$true)][string]$RouteText,[Parameter(Mandatory=$true)][string]$Route,[string]$Key='')
    $level=switch($Kind){'Error'{'ERROR'}'Warning'{'WARN'}default{'INFO'}}
    $shown=$false
    try{$shown=[bool](Show-DomeniaBanner -Kind $Kind -Message $Text -Key $Key -RouteText $RouteText -Route $Route)}catch{$shown=$false}
    if($shown){Set-Status $Text $level}else{Set-Status ($Text+' Action : « '+$RouteText+' ».') $level}
    return $shown
}
function Update-DomeniaBannerOccurrence {
    # FI-02: a repeated message keeps one banner. Errors and warnings count their occurrences; an information
    # (« État du moteur ») shows its refresh time. The latest detail replaces the first one, for the support copy too.
    param($Record,$Plan,[AllowEmptyString()][string]$Message='')
    $Record.Occurrences=[int]$Record.Occurrences+1
    $Record.At=Get-Date
    $Record.Message=([string]$Message).Trim()
    $Record.Details=[string]$Plan.Details
    if($null -ne $Record.DetailBox){$Record.DetailBox.Text=[string]$Plan.Details}
    if($Plan.Details -and ($null -eq $Record.DetailButton) -and ($null -ne $Record.Actions)){
        $Record.DetailButton=New-DomeniaBannerButton -Text 'Voir le détail' -Command 'Detail' -Record $Record -Help 'Affiche ou masque le détail de ce message.'
        [void]$Record.Actions.Children.Add($Record.DetailButton)
        if(($null -ne $Record.Stack) -and (-not $Record.Stack.Children.Contains($Record.Actions))){[void]$Record.Stack.Children.Add($Record.Actions)}
    }
    if($null -ne $Record.DetailButton){$Record.DetailButton.Visibility=if($Plan.Details){'Visible'}else{'Collapsed'}}
    if((-not $Plan.Details) -and ($null -ne $Record.DetailBox)){$Record.DetailBox.Visibility='Collapsed'}
    $Record.Counter.Text=switch([string]$Record.Kind){
        'Error'{'même erreur ×'+[string]$Record.Occurrences}
        'Warning'{'même avertissement ×'+[string]$Record.Occurrences}
        default{'Mis à jour à '+([datetime]$Record.At).ToString('HH:mm:ss')}
    }
    $Record.Counter.Visibility='Visible'
    if($null -eq $Record.Timer){return}
    # A detail to read now keeps the banner; otherwise the 5 s restart, except under the pointer or once pinned.
    if([int]$Plan.AutoCloseSeconds -le 0){$Record.Timer.Stop();$Record.Pinned=$true;return}
    if((-not [bool]$Record.Pinned) -and (-not $Record.Border.IsMouseOver)){$Record.Timer.Stop();$Record.Timer.Start()}
}
function Close-DomeniaBanner {
    param($Record)
    if(($null -eq $Record) -or [bool]$Record.Closed){return}
    $Record.Closed=$true
    if($null -ne $Record.Timer){try{$Record.Timer.Stop()}catch{}}
    $hostPanel=$Record.Panel
    if($null -ne $hostPanel){
        try{[void]$hostPanel.Children.Remove($Record.Border)}catch{}
        if($hostPanel.Children.Count -eq 0){$hostPanel.Visibility='Collapsed'}
    }
    if($null -ne $script:DomeniaBanners){[void]$script:DomeniaBanners.Remove($Record)}
}
function Get-DomeniaBannerSupportText {
    # FI-07: what the technician sends to the support: code, time, message and detail, secrets masked.
    param($Record)
    $lines=[System.Collections.Generic.List[string]]::new()
    $lines.Add('Domenia - incident '+$(if($Record.Code){[string]$Record.Code}else{'sans code'}))
    $lines.Add('Date : '+([datetime]$Record.At).ToString('yyyy-MM-dd HH:mm:ss'))
    if([int]$Record.Occurrences -gt 1){$lines.Add('Occurrences : '+[int]$Record.Occurrences)}
    $lines.Add('Message : '+[string]$Record.Message)
    if([string]$Record.Details){$lines.Add('Détail :');$lines.Add([string]$Record.Details)}
    if([string]$script:AuditPath){$lines.Add('Journal : '+[string]$script:AuditPath+' (rechercher le code)')}
    $text=[string]::Join("`r`n",$lines.ToArray())
    try{$text=Protect-DomeniaLogText $text}catch{}
    return $text
}
function Invoke-DomeniaBannerCommand {
    param($Sender)
    $tag=$Sender.Tag;if($null -eq $tag){return}
    $record=$tag.Banner;if($null -eq $record){return}
    switch([string]$tag.Command){
        'Close'{Close-DomeniaBanner -Record $record}
        'Detail'{
            $shown=($record.DetailBox.Visibility -eq [Windows.Visibility]::Visible)
            $record.DetailBox.Visibility=if($shown){'Collapsed'}else{'Visible'}
            if($null -ne $record.DetailButton){$record.DetailButton.Content=if($shown){'Voir le détail'}else{'Masquer le détail'}}
            # A detail being read keeps its banner open.
            $record.Pinned=$true;if($null -ne $record.Timer){$record.Timer.Stop()}
        }
        'Support'{
            Set-ClipboardSafe (Get-DomeniaBannerSupportText -Record $record)
            Set-Status ('Incident '+$(if($record.Code){[string]$record.Code}else{'sans code'})+' copié pour le support.')
        }
        'Journal'{Open-DomeniaExperienceJournal}
        'Route'{
            # UX-19 (X04): navigation only; the banner closes once its place is open.
            if([bool](Invoke-DomeniaCapabilityRoute -Route ([string]$record.Route))){Close-DomeniaBanner -Record $record}
            else{Set-Status ('Destination indisponible : '+[string]$record.Route) 'WARN'}
        }
        'Folder'{
            $path=[string]$record.ActionPath
            if([IO.File]::Exists($path)){Start-Process -FilePath 'explorer.exe' -ArgumentList @('/select,"'+$path+'"')}
            elseif([IO.Directory]::Exists($path)){Start-Process -FilePath 'explorer.exe' -ArgumentList @('"'+$path+'"')}
            else{Set-Status ('Dossier introuvable : '+$path) 'WARN'}
        }
    }
}
function Get-DomeniaEmbeddedLookupCode {
@'
$kind=[string]$Payload.Kind
if($kind -notin @('Machine','Utilisateur','OU')){throw 'Type de recherche non autorisé.'}
$term=([string]$Payload.Term).Trim()
$verify=[bool]$Payload.Verify
$mode=[string]$Payload.Mode;if(-not $mode){$mode='Search'}
if($mode -notin @('Search','Children') -or ($mode -eq 'Children' -and $kind -ne 'OU')){throw 'Mode du sélecteur non autorisé.'}
$properties=@('name','sAMAccountName','displayName','givenName','sn','mail','userPrincipalName','dNSHostName','description','distinguishedName','objectGUID','objectClass')
$category=switch($kind){'Machine'{'(objectCategory=computer)'}'Utilisateur'{'(&(objectCategory=person)(objectClass=user))'}'OU'{'(objectClass=organizationalUnit)'}}
$root=[string]$Context.BaseDn;$scope='Subtree';$maximum=100
if($verify){
    $root=[string]$Payload.DN;$scope='Base';$maximum=2;$filter=$category
    if(-not $root.EndsWith(','+[string]$Context.BaseDn,[StringComparison]::OrdinalIgnoreCase)){throw 'Cible hors du domaine courant.'}
}elseif($mode -eq 'Children'){
    $root=([string]$Payload.DN).Trim();$scope='OneLevel';$maximum=1000
    if(-not $root -or ($root -ine [string]$Context.BaseDn -and -not $root.EndsWith(','+[string]$Context.BaseDn,[StringComparison]::OrdinalIgnoreCase))){throw 'Branche hors du domaine courant.'}
    $filter='(|(objectClass=organizationalUnit)(objectClass=container)(objectClass=builtinDomain))'
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
    # AD supports server-side name sorting: the bounded page starts alphabetically, not in provider order.
    # A refusal stays an explicit error; never turn a failed sorted query into an empty branch.
    if($kind -eq 'OU' -and -not $verify){$s.Sort.PropertyName='name';$s.Sort.Direction='Ascending'}
    $set=$s.FindAll()
    foreach($item in $set){
        if($rows.Count -gt $maximum){break}
        $p=$item.Properties;$guid=Convert-WGuid (Get-WPropFirst $p 'objectguid' $null)
        if(-not $guid){throw 'GUID AD non lisible ; aucun choix ne sera validé.'}
        $name=[string](Get-WPropFirst $p 'name' '');$dn=[string](Get-WPropFirst $p 'distinguishedname' '')
        $login=[string](Get-WPropFirst $p 'samaccountname' '');$second=if($kind -eq 'Utilisateur'){$login}elseif($kind -eq 'OU'){$dn}else{[string](Get-WPropFirst $p 'dnshostname' '')}
        $rowKind=$kind
        if($kind -eq 'OU' -and $mode -eq 'Children' -and -not $verify){$rowKind=if(@($p['objectclass']) -contains 'organizationalUnit'){'OU'}else{'Conteneur'}}
        $rows.Add([pscustomobject]@{Type=$rowKind;Name=$name;Login=$login;Second=$second;DN=$dn;Guid=$guid;Description=[string](Get-WPropFirst $p 'description' '')})
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
    if($r.Kind -eq 'OU' -and $null -ne $r.PSObject.Properties['Tree']){Complete-DomeniaOuPickerRead $Result $State;return}
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
    $rows=@($data.Rows)
    if($r.Kind -eq 'OU'){$rows=@($rows|Sort-Object -Property Name,DN -Culture 'fr-FR')}
    $list=[Collections.ArrayList]::new();foreach($row in $rows){[void]$list.Add($row)};$r.Grid.ItemsSource=$list
    $r.Accept.IsEnabled=$false
    $r.Status.Text=if($list.Count){$list.Count.ToString()+' résultat(s). Sélectionnez une ligne, puis confirmez.'}else{'Aucun résultat dans le domaine. Les filtres de la page principale ne sont pas utilisés.'}
    if($data.Capped){$r.Status.Text+=' Limite atteinte : affinez la recherche.'}
}
function Fail-DomeniaEmbeddedLookup {
    param($Message,$State)
    $r=$State.Owner
    if($r.Kind -eq 'OU' -and $null -ne $r.PSObject.Properties['Tree']){Fail-DomeniaOuPickerRead $Message $State;return}
    if($r.Closed -or $r.RequestId -cne $State.RequestId -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.BaseDn -ine [string]$script:Conn.BaseDn){return}
    $r.Job='';$r.Go.IsEnabled=$true;$r.Box.IsEnabled=$true;$r.Grid.IsEnabled=$true;$r.Accept.IsEnabled=$false;$r.Busy.Visibility='Hidden'
    $r.Status.Text='Lecture non confirmée : '+[string]$Message
}
function New-DomeniaOuPickerNode {
    param($Owner,[string]$Dn,[string]$Name,$Row=$null,[switch]$Context)
    $node=[Windows.Controls.TreeViewItem]::new();$node.Header=$Name;$node.ToolTip=$Dn
    $node.Tag=[pscustomobject]@{DN=$Dn;Row=$Row;Loaded=[bool]$Context;Context=[bool]$Context;Loading=$false}
    [Windows.Automation.AutomationProperties]::SetName($node,$Name)
    if(-not $Context){[void]$node.Items.Add('Développer pour lire les sous-branches…')}
    $load=${function:Start-DomeniaOuPickerRead};$ownerState=$Owner;$item=$node
    $node.Add_Expanded({param($sender,$eventArgs)
        if($eventArgs.OriginalSource -ne $item -or $ownerState.Closed -or $ownerState.Mode -ne 'Navigation' -or $item.Tag.Context -or $item.Tag.Loaded -or $ownerState.Job){return}
        & $load -Owner $ownerState -Mode Children -Node $item
    }.GetNewClosure())
    return $node
}
function Stop-DomeniaOuPickerRead {
    param($Owner)
    # Invalidate first: a completed callback racing cancellation cannot repopulate the tree.
    $Owner.RequestId=[guid]::NewGuid().ToString('N')
    $job=[string]$Owner.Job;$Owner.Job=''
    if($null -ne $Owner.ActiveNode){$Owner.ActiveNode.Tag.Loading=$false;if(-not $Owner.ActiveNode.Tag.Loaded){$Owner.ActiveNode.IsExpanded=$false};$Owner.ActiveNode=$null}
    if($job){Request-UiTaskStop -Id $job -Silent -Force -Superseded -Reason 'Périmètre du sélecteur modifié'|Out-Null}
    $Owner.Busy.Visibility='Hidden';$Owner.Tree.IsEnabled=$true;$Owner.Go.IsEnabled=$true;$Owner.Accept.IsEnabled=$false
}
function Start-DomeniaOuPickerRead {
    param($Owner,[ValidateSet('Children','Search','Verify')][string]$Mode,$Node=$null)
    if($Owner.Closed -or $Owner.Job){return}
    $ctx=Get-DomeniaEmbeddedContext
    if($ctx.Closing -or $ctx.Epoch -ne $Owner.Epoch -or $ctx.BaseDn -ine $Owner.BaseDn){$Owner.Status.Text='La connexion a changé. Fermez puis rouvrez le sélecteur.';return}
    $row=$null
    if($Mode -eq 'Verify'){
        $selected=$Owner.Tree.SelectedItem
        if($null -eq $selected -or $null -eq $selected.Tag.Row -or [string]$selected.Tag.Row.Type -ne 'OU' -or -not [string]$selected.Tag.Row.Guid){return}
        $row=$selected.Tag.Row
    }
    $term=([string]$Owner.Box.Text).Trim()
    if($Mode -eq 'Search' -and -not $term){Show-DomeniaOuPickerNavigation $Owner;return}
    $Owner.RequestId=[guid]::NewGuid().ToString('N');$Owner.Accept.IsEnabled=$false;$Owner.Tree.IsEnabled=$false;$Owner.Go.IsEnabled=$false;$Owner.Busy.Visibility='Visible'
    $Owner.ActiveNode=$Node
    if($null -ne $Node){$Node.Tag.Loading=$true}
    if($Mode -eq 'Search'){$Owner.Mode='Search';$Owner.Tree.Items.Clear();$Owner.Path.Text=''}
    $dn=if($Mode -eq 'Children'){[string]$Node.Tag.DN}elseif($null -ne $row){[string]$row.DN}else{''}
    $Owner.Status.Text=switch($Mode){'Children'{'Lecture des sous-branches directes…'}'Search'{'Recherche des OU par nom…'}default{'Vérification de lʼOU sélectionnée…'}}
    $state=[pscustomobject]@{Owner=$Owner;RequestId=$Owner.RequestId;Epoch=$ctx.Epoch;BaseDn=$ctx.BaseDn;Verify=($Mode -eq 'Verify');Mode=$Mode;Node=$Node;DN=$dn;Guid=$(if($null -ne $row){[string]$row.Guid}else{''})}
    $payload=[pscustomobject]@{Kind='OU';Mode=$(if($Mode -eq 'Children'){'Children'}else{'Search'});Term=$term;Verify=($Mode -eq 'Verify');RequestId=$Owner.RequestId;DN=$dn;Guid=$state.Guid}
    try{
        $Owner.Job=Start-UiTask -Name 'Choisir une OU' -OperationId 'EmbeddedDirectoryLookup' -Code (Get-DomeniaEmbeddedLookupCode) -Payload $payload -CallbackState $state -ReplaceKey 'embedded:lookup' -TimeoutSeconds 18 -SuccessHandler 'Complete-DomeniaEmbeddedLookup' -ErrorHandler 'Fail-DomeniaEmbeddedLookup'
        if(-not $Owner.Job){throw 'Lecture non admise ; réessayez.'}
    }catch{Fail-DomeniaOuPickerRead $_.Exception.Message $state}
}
function Show-DomeniaOuPickerNavigation {
    param($Owner)
    if($Owner.Closed){return}
    Stop-DomeniaOuPickerRead $Owner
    $Owner.Mode='Navigation';$Owner.Tree.Items.Clear();$Owner.Path.Text=''
    [void]$Owner.Tree.Items.Add($Owner.RootNode)
    $Owner.Status.Text='Développez une branche, puis choisissez une OU. Les conteneurs servent uniquement à naviguer.'
    if(-not $Owner.RootNode.Tag.Loaded){Start-DomeniaOuPickerRead -Owner $Owner -Mode Children -Node $Owner.RootNode}
    $Owner.RootNode.IsExpanded=$true
}
function Complete-DomeniaOuPickerRead {
    param($Result,$State)
    $r=$State.Owner
    if($r.Closed -or $r.RequestId -cne $State.RequestId -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.BaseDn -ine [string]$script:Conn.BaseDn){return}
    $data=Get-DomeniaEffectiveWorkerResult $Result @('Rows','RequestId','Verified')
    if($null -eq $data -or $data.RequestId -cne $State.RequestId -or [bool]$data.Verified -ne [bool]$State.Verify){Fail-DomeniaOuPickerRead 'Retour du sélecteur incohérent.' $State;return}
    $r.Job='';$r.ActiveNode=$null;$r.Go.IsEnabled=$true;$r.Tree.IsEnabled=$true;$r.Busy.Visibility='Hidden';$r.Accept.IsEnabled=$false
    $rows=@($data.Rows|Sort-Object -Property Name,DN -Culture 'fr-FR')
    if($State.Verify){
        if($rows.Count -ne 1 -or $rows[0].Type -ne 'OU' -or $rows[0].DN -ine $State.DN -or $rows[0].Guid -ine $State.Guid){Fail-DomeniaOuPickerRead 'LʼOU choisie a changé ; relancez la recherche.' $State;return}
        $r.Selected=$rows[0];Set-DomeniaSurfaceResult $r.Window $true;return
    }
    if($State.Mode -eq 'Children'){
        $node=$State.Node;$node.Items.Clear();$node.Tag.Loading=$false;$node.Tag.Loaded=$true
        foreach($row in $rows){
            if([string]$row.Type -notin @('OU','Conteneur') -or (Get-DomeniaRawDnParent ([string]$row.DN)) -ine [string]$node.Tag.DN){continue}
            [void]$node.Items.Add((New-DomeniaOuPickerNode -Owner $r -Dn ([string]$row.DN) -Name ([string]$row.Name) -Row $row))
        }
        $r.Status.Text=([string]$node.Items.Count+' sous-branche(s) directe(s), classées par nom. Choisissez une OU ou développez une branche.')
        if(-not $node.Items.Count){$r.Status.Text='Aucune sous-branche lisible. Une OU déjà sélectionnée peut être choisie.'}
        $selected=$r.Tree.SelectedItem
        $r.Accept.IsEnabled=($null -ne $selected -and $null -ne $selected.Tag.Row -and [string]$selected.Tag.Row.Type -eq 'OU' -and [bool][string]$selected.Tag.Row.Guid)
    }else{
        # Ancestors provide context only. Only an actual OU search result has the GUID needed to choose it.
        $r.Tree.Items.Clear();$nodes=@{};$matched=0
        $domainNode=New-DomeniaOuPickerNode -Owner $r -Dn $r.BaseDn -Name $r.BaseDn -Context
        $nodes[$r.BaseDn]=$domainNode;[void]$r.Tree.Items.Add($domainNode)
        foreach($row in $rows){
            if([string]$row.Type -ne 'OU' -or -not [string]$row.Guid){continue}
            $chain=[Collections.Generic.List[string]]::new();$current=[string]$row.DN
            while($current -and $current -ine $r.BaseDn){$chain.Add($current);$current=Get-DomeniaRawDnParent $current}
            if($current -ine $r.BaseDn){continue}
            for($i=$chain.Count-1;$i -ge 0;$i--){
                $dn=$chain[$i];$parent=Get-DomeniaRawDnParent $dn
                if(-not $nodes.ContainsKey($dn)){
                    $rdn=@(Split-DomeniaRawDn $dn)[0];$label=ConvertFrom-DomeniaDnLabel (($rdn -split '=',2)[1])
                    $new=New-DomeniaOuPickerNode -Owner $r -Dn $dn -Name $label -Context
                    $nodes[$dn]=$new;[void]$nodes[$parent].Items.Add($new)
                }
            }
            $nodes[[string]$row.DN].Tag.Row=$row;$nodes[[string]$row.DN].Header=[string]$row.Name;$nodes[[string]$row.DN].FontWeight='SemiBold';$matched++
        }
        foreach($node in $nodes.Values){
            $children=@($node.Items|Sort-Object -Property @{Expression={[string]$_.Header}},@{Expression={[string]$_.Tag.DN}} -Culture 'fr-FR')
            $node.Items.Clear();foreach($child in $children){[void]$node.Items.Add($child)}
            $node.IsExpanded=$true
        }
        $r.Status.Text=([string]$matched+' OU trouvée(s). Choisissez un résultat ; ses parents donnent le contexte. Effacez la recherche pour naviguer.')
    }
    if($data.Capped){$r.Status.Text+=' Limite atteinte : recherchez un nom plus précis.'}
}
function Fail-DomeniaOuPickerRead {
    param($Message,$State)
    $r=$State.Owner
    if($r.Closed -or $r.RequestId -cne $State.RequestId -or $State.Epoch -ne [long]$script:SessionEpoch -or $State.BaseDn -ine [string]$script:Conn.BaseDn){return}
    $r.Job='';$r.ActiveNode=$null;$r.Go.IsEnabled=$true;$r.Tree.IsEnabled=$true;$r.Accept.IsEnabled=$false;$r.Busy.Visibility='Hidden'
    if($null -ne $State.Node){$State.Node.Tag.Loading=$false;$State.Node.Tag.Loaded=$false;$State.Node.Items.Clear();[void]$State.Node.Items.Add('Lecture non confirmée ; repliez puis développez pour réessayer.')}
    $r.Status.Text='Lecture non confirmée : '+[string]$Message
}
function Show-DomeniaOuTreePicker {
    param([string]$Title,[string]$Prompt,[string]$InitialTerm='')
    if(-not (Test-DomeniaEmbeddedHost)){throw 'Ouvrez la fenêtre principale avant de sélectionner une OU.'}
    $ctx=Get-DomeniaEmbeddedContext
    if(-not $ctx.BaseDn -or $ctx.Closing){throw 'Connectez-vous avant de sélectionner une OU.'}
    $w=[Windows.Window]::new();$w.Title=$Title;$w.Width=820;$w.Height=640
    $root=[Windows.Controls.Grid]::new();$root.Name='IntegratedObjectPicker'
    foreach($height in @('Auto','Auto','*','Auto','Auto','Auto')){$rd=[Windows.Controls.RowDefinition]::new();$rd.Height=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($height);[void]$root.RowDefinitions.Add($rd)}
    $hint=[Windows.Controls.TextBlock]::new();$hint.Text=$Prompt;$hint.TextWrapping='Wrap';$hint.Margin='0,0,0,12';[void]$root.Children.Add($hint)
    $search=[Windows.Controls.Grid]::new()
    foreach($width in @('*','Auto','Auto')){$col=[Windows.Controls.ColumnDefinition]::new();$col.Width=[Windows.GridLengthConverter]::new().ConvertFromInvariantString($width);[void]$search.ColumnDefinitions.Add($col)}
    $box=[Windows.Controls.TextBox]::new();$box.Name='EmbeddedObjectTerm';$box.Text=$InitialTerm;$box.MaxLength=160;$box.MinHeight=40;$box.Margin='0,0,8,0';$box.ToolTip='Nom dʼOU : Entrée lance la recherche. Vider ce champ retrouve lʼarbre.';[void]$search.Children.Add($box)
    $go=[Windows.Controls.Button]::new();$go.Name='EmbeddedObjectSearch';$go.Content='Rechercher';$go.MinHeight=40;$go.MinWidth=112;$go.Margin='0,0,8,0';$go.ToolTip='Rechercher des OU et afficher leurs branches parentes.';[Windows.Controls.Grid]::SetColumn($go,1);[void]$search.Children.Add($go)
    $clear=[Windows.Controls.Button]::new();$clear.Name='EmbeddedOuClear';$clear.Content='Effacer';$clear.MinHeight=40;$clear.MinWidth=84;$clear.Margin='0';$clear.ToolTip='Retrouver lʼarbre sans modifier lʼOU de la page principale.';[Windows.Controls.Grid]::SetColumn($clear,2);[void]$search.Children.Add($clear)
    $search.Margin='0,0,0,10';[Windows.Controls.Grid]::SetRow($search,1);[void]$root.Children.Add($search)
    $tree=[Windows.Controls.TreeView]::new();$tree.Name='EmbeddedObjectResults';$tree.MinHeight=180;$tree.MaxHeight=520;$tree.ToolTip='Développez les branches. Seules les OU peuvent être choisies ; les conteneurs servent à naviguer.'
    [Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($tree,'Visible');[Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($tree,'Auto');[Windows.Controls.ScrollViewer]::SetCanContentScroll($tree,$true)
    [Windows.Controls.VirtualizingPanel]::SetIsVirtualizing($tree,$true);[Windows.Controls.VirtualizingPanel]::SetVirtualizationMode($tree,'Recycling')
    [Windows.Controls.Grid]::SetRow($tree,2);[void]$root.Children.Add($tree)
    $path=[Windows.Controls.TextBox]::new();$path.Name='EmbeddedOuPath';$path.IsReadOnly=$true;$path.MinHeight=30;$path.Margin='0,8,0,0';$path.ToolTip='Chemin AD complet de la branche sélectionnée ; copiable.';[Windows.Controls.Grid]::SetRow($path,3);[void]$root.Children.Add($path)
    $status=[Windows.Controls.TextBlock]::new();$status.Name='EmbeddedObjectStatus';$status.TextWrapping='Wrap';$status.MaxHeight=68;$status.Margin='0,8,0,8';[Windows.Controls.Grid]::SetRow($status,4);[void]$root.Children.Add($status)
    $foot=[Windows.Controls.Grid]::new();[void]$foot.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new());$col=[Windows.Controls.ColumnDefinition]::new();$col.Width='Auto';[void]$foot.ColumnDefinitions.Add($col)
    $busy=[Windows.Controls.ProgressBar]::new();$busy.IsIndeterminate=$true;$busy.Width=120;$busy.Height=4;$busy.Visibility='Hidden';$busy.HorizontalAlignment='Left';[void]$foot.Children.Add($busy)
    $buttons=[Windows.Controls.StackPanel]::new();$buttons.Orientation='Horizontal';[Windows.Controls.Grid]::SetColumn($buttons,1);[void]$foot.Children.Add($buttons)
    $cancel=[Windows.Controls.Button]::new();$cancel.Name='EmbeddedObjectCancel';$cancel.Content='Annuler';$cancel.Width=108;$cancel.Height=40;$cancel.IsCancel=$true;$cancel.ToolTip='Fermer sans choisir dʼOU.';[void]$buttons.Children.Add($cancel)
    $accept=[Windows.Controls.Button]::new();$accept.Name='EmbeddedObjectAccept';$accept.Content='Choisir';$accept.Width=130;$accept.Height=40;$accept.Margin='0';$accept.IsEnabled=$false;$accept.IsDefault=$true;$accept.ToolTip='Revérifier le DN et le GUID de cette OU avant de la choisir.';[void]$buttons.Children.Add($accept)
    [Windows.Controls.Grid]::SetRow($foot,5);[void]$root.Children.Add($foot);$w.Content=$root
    $r=[pscustomobject]@{Window=$w;Kind='OU';Tree=$tree;Grid=$tree;Box=$box;Go=$go;Accept=$accept;Busy=$busy;Path=$path;Status=$status;RequestId='';Closed=$false;Job='';Selected=$null;RootNode=$null;ActiveNode=$null;Mode='Navigation';Epoch=$ctx.Epoch;BaseDn=$ctx.BaseDn}
    $r.RootNode=New-DomeniaOuPickerNode -Owner $r -Dn $ctx.BaseDn -Name $ctx.BaseDn
    $read=${function:Start-DomeniaOuPickerRead};$navigate=${function:Show-DomeniaOuPickerNavigation};$stop=${function:Stop-DomeniaOuPickerRead}
    $go.Add_Click({if(-not $r.Job){if(([string]$box.Text).Trim()){& $read -Owner $r -Mode Search}else{& $navigate $r}}}.GetNewClosure())
    $accept.Add_Click({& $read -Owner $r -Mode Verify}.GetNewClosure())
    $clear.Add_Click({if([string]$box.Text){$box.Text=''}else{& $navigate $r}}.GetNewClosure())
    $box.Add_KeyDown({param($sender,$eventArgs)if($eventArgs.Key -eq 'Return'){$eventArgs.Handled=$true;if(-not $r.Job){if(([string]$box.Text).Trim()){& $read -Owner $r -Mode Search}else{& $navigate $r}}}}.GetNewClosure())
    $box.Add_TextChanged({
        & $stop $r;$r.Path.Text=''
        if(-not ([string]$box.Text).Trim()){& $navigate $r}else{$r.Mode='Draft';$r.Tree.Items.Clear();$r.Status.Text='Appuyez sur Entrée ou Rechercher pour afficher les OU correspondantes.'}
    }.GetNewClosure())
    $tree.Add_SelectedItemChanged({param($sender,$eventArgs)
        $item=$eventArgs.NewValue;$r.Path.Text=$(if($null -ne $item -and $null -ne $item.Tag){[string]$item.Tag.DN}else{''})
        $r.Accept.IsEnabled=($null -ne $item -and $null -ne $item.Tag.Row -and [string]$item.Tag.Row.Type -eq 'OU' -and [bool][string]$item.Tag.Row.Guid -and -not $r.Job -and $r.Mode -ne 'Draft')
        if($null -ne $item -and $r.Mode -eq 'Search' -and $null -eq $item.Tag.Row){$r.Status.Text='Branche de contexte : choisissez une OU en gras, ou effacez la recherche pour naviguer dans cette branche.'}
    }.GetNewClosure())
    Register-DomeniaSurfaceReady $w ({[void]$box.Focus();if(([string]$box.Text).Trim()){& $read -Owner $r -Mode Search}else{& $navigate $r}}.GetNewClosure())
    try{[void](Show-DomeniaEmbeddedWindow $w);return $r.Selected}
    finally{$r.Closed=$true;Stop-DomeniaOuPickerRead $r;$tree.Items.Clear();$w.Close()}
}
function Show-DomeniaInlinePicker {
    param([ValidateSet('Machine','Utilisateur','OU')][string]$Kind,[string]$Title,[string]$Prompt,[string]$InitialTerm='')
    if($Kind -eq 'OU'){return (Show-DomeniaOuTreePicker -Title $Title -Prompt $Prompt -InitialTerm $InitialTerm)}
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
    # Explicit scrolling overrides application DataGrid defaults and keeps the footer reachable.
    [Windows.Controls.ScrollViewer]::SetVerticalScrollBarVisibility($grid,'Visible')
    [Windows.Controls.ScrollViewer]::SetHorizontalScrollBarVisibility($grid,'Auto')
    [Windows.Controls.ScrollViewer]::SetCanContentScroll($grid,$true)
    [Windows.Controls.VirtualizingPanel]::SetVirtualizationMode($grid,'Recycling')
    $grid.EnableColumnVirtualization=$true;$grid.MaxHeight=520
    foreach($spec in @(@('Nom','Name','160'),@('Identifiant / DNS','Second','200'),@('Description','Description','*'))){$c=[Windows.Controls.DataGridTextColumn]::new();$c.Header=$spec[0];$c.Binding=[Windows.Data.Binding]::new($spec[1]);$c.Width=[Windows.Controls.DataGridLengthConverter]::new().ConvertFromInvariantString($spec[2]);[void]$grid.Columns.Add($c)}
    if($Kind -eq 'OU'){$grid.Columns[1].Header='Chemin AD';$grid.Columns[1].Width=[Windows.Controls.DataGridLength]::new(1,'Star');$grid.Columns[0].SortDirection='Ascending'}
    [Windows.Controls.Grid]::SetRow($grid,2);[void]$root.Children.Add($grid)
    $status=[Windows.Controls.TextBlock]::new();$status.Name='EmbeddedObjectStatus';$status.Text=if($Kind -eq 'OU'){'OU classées par nom. Rechercher affiche la liste ; saisissez un nom pour affiner.'}else{'Saisissez au moins deux caractères, puis Rechercher.'};$status.TextWrapping='Wrap';$status.Margin='0,10,0,6';$status.MaxHeight=52
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
            if($r.Closed -or $r.Job){return}
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
            if(-not [string]$r.Job){throw 'Lecture non admise ; réessayez lorsque les tâches en cours sont terminées.'}
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
    # D045: no separate window to associate. The user is searched in Relations, panel Ajouter > Rechercher, in the
    # page, from a selected workstation (or a user is selected in Rechercher). Nothing is probed here.
    $workspace=Get-DomeniaControl 'WorkspaceTabs';$relations=Get-DomeniaControl 'TabRelations';if($null -ne $workspace -and $null -ne $relations){$workspace.SelectedItem=$relations}
    $tabs=Get-DomeniaControl 'RelationTabs';$associate=Get-DomeniaControl 'TabLinksSelected';if($null -ne $tabs -and $null -ne $associate){$tabs.SelectedItem=$associate}
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
