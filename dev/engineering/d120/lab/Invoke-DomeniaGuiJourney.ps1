#requires -Version 5.1
# Point 129: native GUI journey qualification. Drives the real Domenia window from another process, as a user would:
# UI Automation (Invoke, Window, Scroll patterns) and operating system input (SendInput: mouse clicks, wheel, keys,
# Unicode text), journeys read from gui-journeys.json, 1920x1080 captures refused while a tooltip is on screen.
# The report keeps two kinds of evidence apart (rules in wad/tests/fixtures/Domenia-GuiJourney.ps1):
#   SimulatedEvents  what this program sent and what the window did; it is not a person using the application;
#   HumanJourney     the record a person filled while doing the same journeys by hand (-HumanRecord), checked for
#                    completeness only. A run is 'Qualifié' only when both agree and every declared journey ran
#                    (-Journeys runs a subset for diagnosis, reported as 'Partiel').
# Runs in an interactive Windows session whose primary screen has 1920x1080 free of the taskbar (larger resolution or
# auto-hidden taskbar): never in session 0 (VBoxManage
# guestcontrol, services), where neither input nor captures are those of a user. Target Preview starts the offline
# preview (fictitious data, no AD connection). Target Application attaches to a Domenia started and signed in by the
# person who qualifies (-ProcessId): this script never signs in, never types a password and never writes to AD.
# Usage, from <dev> in the VM console:
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-DomeniaGuiJourney.ps1 -DevRoot . -OutDir C:\DomeniaLab\gui -WriteHumanTemplate
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File engineering\d120\lab\Invoke-DomeniaGuiJourney.ps1 -DevRoot . -OutDir C:\DomeniaLab\gui [-HumanRecord C:\DomeniaLab\gui\parcours-humain.json]
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$DevRoot,
    [Parameter(Mandatory=$true)][string]$OutDir,
    [ValidateSet('Preview','Application')][string]$Target='Preview',
    [int]$ProcessId=0,
    [string[]]$Journeys=@(),
    [string]$HumanRecord='',
    [switch]$WriteHumanTemplate,
    [ValidateRange(5,300)][int]$StartTimeoutSeconds=90
)
$ErrorActionPreference='Stop'
$dev=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DevRoot).TrimEnd('\')
$out=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir).TrimEnd('\')
if(($out+'\').StartsWith($dev+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Le dossier de sortie doit être hors de dev\.'}
[void][IO.Directory]::CreateDirectory($out)
. (Join-Path $dev 'wad\tests\fixtures\Domenia-GuiJourney.ps1')
$definition=[IO.File]::ReadAllText((Join-Path $dev 'engineering\d120\lab\gui-journeys.json'),[Text.Encoding]::UTF8)|ConvertFrom-Json
# The rule returns its errors as one array (return ,...): assigned as is, never wrapped in @() (that would nest it).
$definitionErrors=Test-DomeniaGuiJourneyDefinition $definition
if($definitionErrors.Count){throw ('Parcours invalides : '+($definitionErrors -join ' | '))}
$definedIds=@(@($definition.Journeys)|ForEach-Object{[string]$_.Id})
$unknownIds=@($Journeys|Where-Object{$definedIds -cnotcontains [string]$_})
if($unknownIds.Count){throw ('Parcours inconnus : '+($unknownIds -join ', ')+'. Parcours déclarés : '+($definedIds -join ', ')+'.')}
$utf8=New-Object Text.UTF8Encoding($false)
if($WriteHumanTemplate){
    $templatePath=Join-Path $out 'parcours-humain.json'
    [IO.File]::WriteAllText($templatePath,((New-DomeniaGuiHumanTemplate $definition)|ConvertTo-Json -Depth 6),$utf8)
    Write-Host ('Relevé humain à remplir : '+$templatePath)
    exit 0
}
$desktop51=($PSVersionTable.PSEdition -eq 'Desktop') -and ($PSVersionTable.PSVersion.Major -eq 5) -and ($PSVersionTable.PSVersion.Minor -eq 1)
if((-not $desktop51) -or (-not [Environment]::Is64BitProcess)){throw 'Windows PowerShell 5.1 x64 requis.'}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Lancer avec powershell.exe -STA.'}
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing,System.Windows.Forms
if($null -eq ('Domenia.Journey.NativeInput' -as [type])){
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace Domenia.Journey
{
    // Operating system input for the journey harness: the same events a mouse and a keyboard produce.
    public static class NativeInput
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        private struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)]
        private struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)]
        private struct INPUT { public uint type; public INPUTUNION u; }
        [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);
        [DllImport("user32.dll", SetLastError = true)] private static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr handle);
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("kernel32.dll")] private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);
        private const uint InputMouse = 0;
        private const uint InputKeyboard = 1;
        private const uint ExtendedKey = 0x0001;
        private const uint KeyUp = 0x0002;
        private const uint UnicodeKey = 0x0004;
        private const uint LeftDown = 0x0002;
        private const uint LeftUp = 0x0004;
        private const uint WheelMove = 0x0800;

        private static void Send(INPUT[] inputs)
        {
            uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
            if (sent != inputs.Length) { throw new InvalidOperationException("SendInput refused the events (error " + Marshal.GetLastWin32Error() + "): locked session, other desktop or higher integrity window."); }
        }
        private static INPUT KeyInput(ushort virtualKey, ushort scan, uint flags)
        {
            INPUT input = new INPUT();
            input.type = InputKeyboard;
            input.u.ki.wVk = virtualKey;
            input.u.ki.wScan = scan;
            input.u.ki.dwFlags = flags;
            return input;
        }
        private static INPUT MouseInput(uint flags, int data)
        {
            INPUT input = new INPUT();
            input.type = InputMouse;
            input.u.mi.dwFlags = flags;
            input.u.mi.mouseData = unchecked((uint)data);
            return input;
        }
        public static void DpiAware() { SetProcessDPIAware(); }
        public static bool Foreground(IntPtr handle) { return SetForegroundWindow(handle); }
        public static void MoveTo(int x, int y)
        {
            if (!SetCursorPos(x, y)) { throw new InvalidOperationException("SetCursorPos refused (error " + Marshal.GetLastWin32Error() + ")."); }
        }
        public static void Click(int x, int y)
        {
            MoveTo(x, y);
            Send(new INPUT[] { MouseInput(LeftDown, 0), MouseInput(LeftUp, 0) });
        }
        public static void Wheel(int x, int y, int notches)
        {
            MoveTo(x, y);
            Send(new INPUT[] { MouseInput(WheelMove, notches * 120) });
        }
        public static void Key(ushort virtualKey, bool shift, bool control, bool extended)
        {
            List<INPUT> list = new List<INPUT>();
            uint flags = extended ? ExtendedKey : 0;
            if (control) { list.Add(KeyInput(0x11, 0, 0)); }
            if (shift) { list.Add(KeyInput(0x10, 0, 0)); }
            list.Add(KeyInput(virtualKey, 0, flags));
            list.Add(KeyInput(virtualKey, 0, flags | KeyUp));
            if (shift) { list.Add(KeyInput(0x10, 0, KeyUp)); }
            if (control) { list.Add(KeyInput(0x11, 0, KeyUp)); }
            Send(list.ToArray());
        }
        public static void Text(string text)
        {
            foreach (char character in text)
            {
                Send(new INPUT[] { KeyInput(0, (ushort)character, UnicodeKey), KeyInput(0, (ushort)character, UnicodeKey | KeyUp) });
            }
        }
        public static long SessionId(int processId)
        {
            uint session;
            if (!ProcessIdToSessionId((uint)processId, out session)) { return -1; }
            return session;
        }
    }
}
'@
}
[Domenia.Journey.NativeInput]::DpiAware()
$session=[Domenia.Journey.NativeInput]::SessionId($PID)
if(($session -le 0) -or (-not [Environment]::UserInteractive)){throw ('Session interactive requise (session '+$session+') : les parcours natifs ne se qualifient pas en session 0.')}
$screen=[Windows.Forms.Screen]::PrimaryScreen.Bounds
# The capture copies the screen under the window: the taskbar (always on top) must not cover any of the 1920x1080
# window. The working area excludes it; a 1920x1080 screen with a visible taskbar is refused.
$script:WorkArea=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if(($script:WorkArea.Width -lt 1920) -or ($script:WorkArea.Height -lt 1080)){throw ('Zone de travail de lʼécran principal de '+$script:WorkArea.Width+'×'+$script:WorkArea.Height+' (écran '+$screen.Width+'×'+$screen.Height+') : 1920×1080 libres de barre des tâches requis pour les captures. Agrandir la définition de la VM ou masquer automatiquement la barre des tâches.')}

$script:Steps=New-Object 'System.Collections.Generic.List[object]'
$script:Captures=New-Object 'System.Collections.Generic.List[object]'
$script:WindowElement=$null;$script:Process=$null;$started=$false
$extendedKeys=@(0x21,0x22,0x23,0x24,0x25,0x26,0x27,0x28,0x2D,0x2E)
$tooltipCondition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::ToolTip)

function Get-JourneyWindow {
    # Top-level window of the target process, visible and ready.
    param([int]$Id,[int]$TimeoutSeconds)
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$Id)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds){
        foreach($candidate in @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition))){
            if(($candidate.Current.ControlType -eq [Windows.Automation.ControlType]::Window) -and (-not $candidate.Current.IsOffscreen)){return $candidate}
        }
        Start-Sleep -Milliseconds 250
    }
    throw ('Fenêtre du processus '+$Id+' introuvable en '+$TimeoutSeconds+' s.')
}
function Find-JourneyElement {
    param([string]$Id,[int]$TimeoutMs=8000)
    $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do{
        $element=$script:WindowElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition)
        if($null -ne $element){return $element}
        Start-Sleep -Milliseconds 150
    }while($watch.ElapsedMilliseconds -lt $TimeoutMs)
    throw ('Contrôle introuvable : '+$Id)
}
function Get-JourneyCenter {
    param($Element)
    $rect=$Element.Current.BoundingRectangle
    if($rect.IsEmpty -or ($rect.Width -le 0) -or ($rect.Height -le 0) -or $Element.Current.IsOffscreen){throw ('Contrôle hors écran : '+$Element.Current.AutomationId)}
    return [pscustomobject]@{X=[int]($rect.X+($rect.Width/2));Y=[int]($rect.Y+($rect.Height/2))}
}
function Set-JourneyForeground {
    $handle=[IntPtr]$script:WindowElement.Current.NativeWindowHandle
    [void][Domenia.Journey.NativeInput]::Foreground($handle)
    Start-Sleep -Milliseconds 150
}
function Wait-JourneyIdle {
    # The window answers UI Automation again and declares itself ready for user interaction.
    param([int]$TimeoutMs=5000)
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt $TimeoutMs){
        try{
            $pattern=$null
            if($script:WindowElement.TryGetCurrentPattern([Windows.Automation.WindowPattern]::Pattern,[ref]$pattern)){
                if($pattern.Current.WindowInteractionState -eq [Windows.Automation.WindowInteractionState]::ReadyForUserInteraction){return}
            }else{return}
        }catch{}
        Start-Sleep -Milliseconds 100
    }
    throw 'Fenêtre non prête pour une interaction après 5 s.'
}
function Get-JourneyTooltipCount {
    # Tooltips are top-level popup windows: any one on screen spoils a capture.
    return @([Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$tooltipCondition)).Count
}
function Invoke-JourneyWindowState {
    param([string]$State)
    $window=$script:WindowElement.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern)
    switch($State){
        'Minimize' {$window.SetWindowVisualState([Windows.Automation.WindowVisualState]::Minimized)}
        'Maximize' {$window.SetWindowVisualState([Windows.Automation.WindowVisualState]::Maximized)}
        'Restore' {$window.SetWindowVisualState([Windows.Automation.WindowVisualState]::Normal)}
        'Normal1080' {
            $window.SetWindowVisualState([Windows.Automation.WindowVisualState]::Normal)
            $transform=$script:WindowElement.GetCurrentPattern([Windows.Automation.TransformPattern]::Pattern)
            $transform.Move([double]$script:WorkArea.X,[double]$script:WorkArea.Y);$transform.Resize(1920,1080)
        }
    }
    Start-Sleep -Milliseconds 400
    $expected=switch($State){'Minimize'{[Windows.Automation.WindowVisualState]::Minimized}'Maximize'{[Windows.Automation.WindowVisualState]::Maximized}default{[Windows.Automation.WindowVisualState]::Normal}}
    if($window.Current.WindowVisualState -ne $expected){throw ('État de fenêtre attendu '+$expected+', obtenu '+$window.Current.WindowVisualState)}
    if($State -ne 'Minimize'){Wait-JourneyIdle}
    if($State -eq 'Normal1080'){
        $rect=$script:WindowElement.Current.BoundingRectangle
        if(([int]$rect.Width -ne 1920) -or ([int]$rect.Height -ne 1080)){throw ('Fenêtre de '+[int]$rect.Width+'×'+[int]$rect.Height+' au lieu de 1920×1080.')}
        if(-not $script:WorkArea.Contains([Drawing.Rectangle]::new([int]$rect.X,[int]$rect.Y,[int]$rect.Width,[int]$rect.Height))){throw 'Fenêtre 1920×1080 en partie hors de la zone de travail (barre des tâches).'}
    }
    return ('État '+$State)
}
function Invoke-JourneyCapture {
    param([string]$Journey,[string]$Name)
    $rect=$script:WindowElement.Current.BoundingRectangle
    # Park the pointer on the title bar, away from controls, and let any tooltip close.
    $tooltips=-1
    for($attempt=1;$attempt -le 3;$attempt++){
        [Domenia.Journey.NativeInput]::MoveTo([int]($rect.X+($rect.Width/2)),[int]($rect.Y+8))
        Start-Sleep -Milliseconds (700*$attempt)
        $tooltips=Get-JourneyTooltipCount
        if($tooltips -eq 0){break}
    }
    $width=[int]$rect.Width;$height=[int]$rect.Height
    $folder=Join-Path $out 'captures';[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ($Journey+'-'+$Name+'.png')
    $bitmap=New-Object Drawing.Bitmap $width,$height
    try{
        $graphics=[Drawing.Graphics]::FromImage($bitmap)
        try{$graphics.CopyFromScreen([int]$rect.X,[int]$rect.Y,0,0,$bitmap.Size)}finally{$graphics.Dispose()}
        $bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png)
    }finally{$bitmap.Dispose()}
    $check=Test-DomeniaGuiCapture -Width $width -Height $height -TooltipCount $tooltips
    $script:Captures.Add([pscustomobject]@{Journey=$Journey;Name=$Name;Path=$path;Width=$width;Height=$height;Tooltips=$tooltips;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Valid=$check.Valid;Reasons=$check.Reasons})
    if(-not $check.Valid){throw ('Capture non conforme : '+($check.Reasons -join ' '))}
    return ('Capture '+$width+'×'+$height+', aucune infobulle')
}
function Invoke-JourneyStep {
    # One step; returns a short French description of what was observed. Throws on failure.
    param([string]$Journey,$Step)
    $kind=[string]$Step.Kind
    switch($kind){
        'Window' {return (Invoke-JourneyWindowState ([string]$Step.State))}
        'Click' {
            Set-JourneyForeground
            $element=Find-JourneyElement ([string]$Step.Id);$center=Get-JourneyCenter $element
            [Domenia.Journey.NativeInput]::Click($center.X,$center.Y);Start-Sleep -Milliseconds 300;Wait-JourneyIdle
            return ('Clic souris en '+$center.X+','+$center.Y)
        }
        'Invoke' {
            $element=Find-JourneyElement ([string]$Step.Id);$pattern=$null
            if($element.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
            elseif($element.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select()}
            elseif($element.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern,[ref]$pattern)){$pattern.Toggle()}
            else{throw ('Aucun motif dʼactivation sur '+[string]$Step.Id)}
            Start-Sleep -Milliseconds 300;Wait-JourneyIdle
            return 'Motif UI Automation activé'
        }
        'Focus' {
            Set-JourneyForeground
            $element=Find-JourneyElement ([string]$Step.Id);$element.SetFocus();Start-Sleep -Milliseconds 150
            if(-not $element.Current.HasKeyboardFocus){throw ('Focus clavier refusé par '+[string]$Step.Id)}
            return 'Focus clavier obtenu'
        }
        'Type' {
            $text=Test-DomeniaGuiTypedText ([string]$Step.Text)
            Set-JourneyForeground;[Domenia.Journey.NativeInput]::Text($text);Start-Sleep -Milliseconds 200
            return ([string]$text.Length+' caractère(s) saisi(s) au clavier')
        }
        'Keys' {
            Set-JourneyForeground
            foreach($text in @($Step.Keys)){
                $chord=ConvertTo-DomeniaGuiKeyChord ([string]$text)
                [Domenia.Journey.NativeInput]::Key([uint16]$chord.VirtualKey,[bool]$chord.Shift,[bool]$chord.Control,($extendedKeys -contains [int]$chord.VirtualKey))
                Start-Sleep -Milliseconds 200
            }
            Wait-JourneyIdle
            return ('Touches : '+(@($Step.Keys) -join ', '))
        }
        'Scroll' {
            Set-JourneyForeground
            $element=Find-JourneyElement ([string]$Step.Id);$center=Get-JourneyCenter $element
            $scroll=$null;$before=$null;$scrollable=$false
            if($element.TryGetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern,[ref]$scroll)){$before=[double]$scroll.Current.VerticalScrollPercent;$scrollable=[bool]$scroll.Current.VerticallyScrollable}
            $notches=[int]$Step.Notches
            [Domenia.Journey.NativeInput]::Wheel($center.X,$center.Y,$notches);Start-Sleep -Milliseconds 400
            if(-not $scrollable){return 'Molette envoyée ; contenu non défilable (rien à vérifier)'}
            $after=[double]$scroll.Current.VerticalScrollPercent
            $room=if($notches -lt 0){$before -lt 100}else{$before -gt 0}
            if($room -and ($after -eq $before)){throw ('La molette nʼa pas fait défiler '+[string]$Step.Id+' ('+$before+' %).')}
            return ('Défilement vertical '+[Math]::Round($before,1)+' % → '+[Math]::Round($after,1)+' %')
        }
        'Assert' {
            $element=Find-JourneyElement ([string]$Step.Id)
            if(($null -ne $Step.PSObject.Properties['Enabled']) -and ([bool]$element.Current.IsEnabled -ne [bool]$Step.Enabled)){throw ([string]$Step.Id+' : IsEnabled='+$element.Current.IsEnabled)}
            return ('Contrôle présent, IsEnabled='+$element.Current.IsEnabled)
        }
        'Capture' {return (Invoke-JourneyCapture $Journey ([string]$Step.Name))}
    }
    throw ('Étape inconnue : '+$kind)
}

$selected=@($definition.Journeys)
if($Journeys.Count){$selected=@($selected|Where-Object{$Journeys -contains [string]$_.Id})}
try{
    if($Target -eq 'Preview'){
        $preview=Join-Path $dev 'wad\maintenance\Preview-DomeniaUi.ps1'
        $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:Process=Start-Process -FilePath $shell -ArgumentList @('-NoLogo','-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',('"'+$preview+'"')) -PassThru
        $started=$true
    }else{
        if($ProcessId -le 0){throw 'Cible Application : indiquer -ProcessId du Domenia lancé et connecté par la personne qui qualifie.'}
        $script:Process=Get-Process -Id $ProcessId
    }
    $script:WindowElement=Get-JourneyWindow -Id $script:Process.Id -TimeoutSeconds $StartTimeoutSeconds
    foreach($journey in $selected){
        $index=0;$stopped=$false
        foreach($step in @($journey.Steps)){
            $index++
            $row=[ordered]@{Journey=[string]$journey.Id;Step=$index;Action=(Format-DomeniaGuiStep $step);Mode=$(if([string]$step.Kind -in @('Click','Type','Keys','Scroll')){'Simulé : entrée système (SendInput)'}elseif([string]$step.Kind -eq 'Capture'){'Capture écran'}else{'Simulé : UI Automation'});Status='';Observed='';DurationMs=0}
            if($stopped){$row.Status='NonExécuté';$row.Observed='Parcours arrêté à une étape précédente.';$script:Steps.Add([pscustomobject]$row);continue}
            $watch=[Diagnostics.Stopwatch]::StartNew()
            try{$row.Observed=[string](Invoke-JourneyStep ([string]$journey.Id) $step);$row.Status='Réussi'}
            catch{$row.Status='Échec';$row.Observed=$_.Exception.Message;$stopped=$true}
            $row.DurationMs=$watch.ElapsedMilliseconds
            $script:Steps.Add([pscustomobject]$row)
        }
    }
}finally{
    if($started -and ($null -ne $script:Process) -and (-not $script:Process.HasExited)){
        try{if($null -ne $script:WindowElement){$script:WindowElement.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close()}}catch{}
        if(-not $script:Process.WaitForExit(10000)){try{$script:Process.Kill()}catch{}}
    }
}

$human=$null
if($HumanRecord){$human=Test-DomeniaGuiHumanRecord ([IO.File]::ReadAllText($HumanRecord,[Text.Encoding]::UTF8)|ConvertFrom-Json) $definition}
$passed=@($script:Steps|Where-Object{$_.Status -eq 'Réussi'}).Count;$failed=@($script:Steps|Where-Object{$_.Status -ne 'Réussi'}).Count
$selectedIds=@($selected|ForEach-Object{[string]$_.Id})
$verdict=Get-DomeniaGuiJourneyVerdict -SimulatedPassed $passed -SimulatedFailed $failed -CapturesValid @($script:Captures|Where-Object{$_.Valid}).Count -CapturesInvalid @($script:Captures|Where-Object{-not $_.Valid}).Count -Human $human -Selected $selectedIds -Defined $definedIds
$report=[ordered]@{
    Kind='DomeniaGuiJourneyQualification';Qualifying=$false;Target=$Target
    Verdict=$verdict
    Journeys=[ordered]@{Defined=$definedIds;Selected=$selectedIds;NotRun=@($definedIds|Where-Object{$selectedIds -cnotcontains $_})}
    Environment=[ordered]@{Computer=[string]$env:COMPUTERNAME;Domain=$(try{[string][Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName}catch{''});Session=$session;Screen=($screen.Width.ToString()+'x'+$screen.Height.ToString());WorkingArea=($script:WorkArea.Width.ToString()+'x'+$script:WorkArea.Height.ToString());PowerShell=$PSVersionTable.PSVersion.ToString();OS=[Environment]::OSVersion.VersionString}
    SimulatedEvents=[ordered]@{Note='Événements envoyés par ce programme (UI Automation et SendInput) : ils ne valent pas un parcours humain.';Passed=$passed;Failed=$failed;Steps=$script:Steps.ToArray()}
    Captures=$script:Captures.ToArray()
    HumanJourney=$(if($null -eq $human){[ordered]@{Status='NonRelevé';Note='Aucun relevé humain fourni (-HumanRecord) : le parcours à la main reste à faire.'}}else{[ordered]@{Status=$(if($human.Complete){'Relevé complet'}else{'Relevé incomplet'});Declared=$true;Note='Contenu déclaré par la personne qui a testé ; ce programme vérifie seulement sa complétude.';Tester=$human.Tester;Date=$human.Date;Passed=$human.Passed;Failed=$human.Failed;Errors=$human.Errors}})
}
$reportPath=Join-Path $out ('parcours-natifs-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'.json')
[IO.File]::WriteAllText($reportPath,(([pscustomobject]$report)|ConvertTo-Json -Depth 8),$utf8)
Write-Host ('Verdict : '+$verdict.Status+' — '+$verdict.Text)
Write-Host ('Rapport : '+$reportPath)
if($verdict.Qualified){exit 0};exit 1
