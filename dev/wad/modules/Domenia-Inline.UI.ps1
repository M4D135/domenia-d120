# D083 / contract C4: confirmation inside the page. No window, no nested modal loop, one continuation at most.
# The decisions are the rules of Domenia-Shell.Model.ps1 (New-DomeniaInlineRequest, Resolve-DomeniaInlineRequest).
# The panel comes from Domenia-Inline.xaml and is laid over the top of the content grid: showing it moves nothing.
$script:DomeniaInline=$null
$script:DomeniaInlineModuleRoot=$PSScriptRoot

function Initialize-DomeniaInlineUi {
    # Lazy: the panel is loaded on the first request, once the main window exists.
    if($null -ne $script:DomeniaInline){return $true}
    $grid=Get-DomeniaControl 'UxContentGrid'
    if($null -eq $grid -or $null -eq $script:Window){return $false}
    $path=Join-Path $script:DomeniaInlineModuleRoot 'Domenia-Inline.xaml'
    [xml]$document=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
    $reader=New-Object Xml.XmlNodeReader $document
    try{$view=[Windows.Markup.XamlReader]::Load($reader)}finally{$reader.Close()}
    foreach($element in $document.SelectNodes('//*')){
        $name=$element.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        if([string]::IsNullOrWhiteSpace($name)){continue}
        if($script:Ctrl.ContainsKey($name)){throw ('Nom de controle deja present : '+$name)}
        $control=if($name -eq [string]$view.Name){$view}else{$view.FindName($name)}
        if($null -eq $control){throw ('Controle de demande introuvable : '+$name)}
        $script:Ctrl[$name]=$control
    }
    [Windows.Controls.Grid]::SetColumn($view,0)
    [void]$grid.Children.Add($view)
    $cancel=Get-DomeniaControl 'BtnInlineRequestCancel'
    $style=$script:Window.TryFindResource('SecondaryButton');if($null -ne $style){$cancel.Style=$style}
    $cancel.Add_Click({Complete-DomeniaInlineRequest -Dismiss})
    (Get-DomeniaControl 'BtnInlineRequestConfirm').Add_Click({Complete-DomeniaInlineRequest -Confirm})
    $view.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq [Windows.Input.Key]::Escape){$eventArgs.Handled=$true;Complete-DomeniaInlineRequest -Dismiss}})
    $script:DomeniaInline=[pscustomobject]@{View=$view;Current=$null}
    # Closing the window withdraws a pending request: its continuation never runs.
    $script:Window.Add_Closed({if($null -ne $script:DomeniaInline){$script:DomeniaInline.Current=$null}})
    return $true
}

function Get-DomeniaInlinePendingRequest {
    if($null -eq $script:DomeniaInline -or $null -eq $script:DomeniaInline.Current){return $null}
    return $script:DomeniaInline.Current.Request
}

function Test-DomeniaInlineBlocks {
    # D083: a pending request holds only the writes and edits of its own target (all of them when it has none).
    param([Parameter(Mandatory=$true)][ValidateSet('Navigate','Read','Select','Write','Edit')][string]$Action,[AllowEmptyString()][string]$Scope='')
    return [bool](Test-DomeniaInlineRequestBlocks -Request (Get-DomeniaInlinePendingRequest) -Action $Action -Scope $Scope)
}

function Request-DomeniaInlineConfirmation {
    # Contract C4. Shows the request in the page and returns at once; the answer runs OnConfirm or OnCancel once.
    # A second request withdraws the first one with its safe answer. Without the main window (startup, tests),
    # the historical confirmation box is used so that no caller is left without an answer.
    param(
        [Parameter(Mandatory=$true)][string]$Title,
        [AllowEmptyString()][string]$Message='',
        [AllowEmptyString()][string]$Target='',
        [string]$ConfirmText='Confirmer',
        [string]$CancelText='Annuler',
        [scriptblock]$OnConfirm=$null,
        [scriptblock]$OnCancel=$null,
        [ValidateSet('Normal','Danger')][string]$Risk='Normal'
    )
    $ready=$false
    try{$ready=Initialize-DomeniaInlineUi}catch{Write-AppLog ('Demande dans la page indisponible : '+$_.Exception.Message) 'WARN';$ready=$false}
    if(-not $ready){
        $confirmed=[bool](Confirm-Action -Message ($Title+"`r`n`r`n"+$Message) -Title $Title)
        if($confirmed){if($null -ne $OnConfirm){& $OnConfirm}}elseif($null -ne $OnCancel){& $OnCancel}
        return [pscustomobject]@{Id='';Title=$Title;Target=$Target;Answered=$true;Confirmed=$confirmed;Presentation='Dialog'}
    }
    if($null -ne $script:DomeniaInline.Current){Complete-DomeniaInlineRequest -Dismiss -Reason 'Remplacee par une nouvelle demande.'}
    $request=New-DomeniaInlineRequest -Kind Confirm -HostName 'InlineRequestPanel' -Title $Title -Message $Message -Choices @($ConfirmText,$CancelText) -SafeChoice $CancelText -ConfirmChoice $ConfirmText -ContinuationId ([guid]::NewGuid().ToString('N')) -Scope $Target -Generation ([string]$script:SessionEpoch)
    $script:DomeniaInline.Current=[pscustomobject]@{Request=$request;OnConfirm=$OnConfirm;OnCancel=$OnCancel;Target=$Target}
    [void](Set-DomeniaControlText 'LblInlineRequestTitle' ([string]$request.Title))
    [void](Set-DomeniaControlText 'LblInlineRequestMessage' ([string]$request.Message))
    $confirm=Get-DomeniaControl 'BtnInlineRequestConfirm';$cancel=Get-DomeniaControl 'BtnInlineRequestCancel'
    $confirm.Content=[string]$request.ConfirmChoice;$cancel.Content=[string]$request.SafeChoice
    $styleName=if($Risk -eq 'Danger'){'DangerButton'}else{'RunButton'}
    $style=$script:Window.TryFindResource($styleName);if($null -ne $style){$confirm.Style=$style}
    $script:DomeniaInline.View.Visibility=[Windows.Visibility]::Visible
    # The safe answer has the focus: Enter on an unread request never confirms it.
    try{[void]$cancel.Focus()}catch{}
    return [pscustomobject]@{Id=[string]$request.Id;Title=$Title;Target=$Target;Answered=$false;Confirmed=$false;Presentation='Inline'}
}

function Complete-DomeniaInlineRequest {
    # Answers the pending request once. A request of a former session is withdrawn without running anything.
    param([switch]$Confirm,[switch]$Dismiss,[string]$Reason='')
    if($null -eq $script:DomeniaInline -or $null -eq $script:DomeniaInline.Current){return}
    $current=$script:DomeniaInline.Current
    $request=$current.Request
    $answer=if($Confirm -and -not $Dismiss){Resolve-DomeniaInlineRequest -Request $request -Choice ([string]$request.ConfirmChoice) -CurrentGeneration ([string]$script:SessionEpoch)}else{Resolve-DomeniaInlineRequest -Request $request -Dismiss -CurrentGeneration ([string]$script:SessionEpoch)}
    if(-not $answer.Continue -and [string]$answer.State -eq 'Pending'){return}
    $script:DomeniaInline.Current=$null
    $script:DomeniaInline.View.Visibility=[Windows.Visibility]::Collapsed
    if(-not $answer.Continue){Set-Status ('Demande retiree : '+[string]$answer.Reason) 'INFO';return}
    if($Reason){Write-AppLog ('Demande dans la page : '+[string]$request.Title+' - '+$Reason) 'INFO'}
    try{
        if([bool]$answer.Confirmed){if($null -ne $current.OnConfirm){& $current.OnConfirm}}
        elseif($null -ne $current.OnCancel){& $current.OnCancel}
    }catch{
        Set-Status ([string]$request.Title+' : '+$_.Exception.Message) 'ERROR'
        Write-AppLog ('Suite de la demande dans la page en echec : '+$_.Exception.Message) 'ERROR'
    }
}
