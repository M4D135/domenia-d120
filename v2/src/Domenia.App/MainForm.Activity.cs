using System.Runtime.InteropServices;
using System.Text.Json;
using Domenia.Bridge;

namespace Domenia.App;

internal sealed partial class MainForm
{
    private bool windowActive;
    private void PublishWindowActivity(bool force = false)
    {
        if (IsDisposed) { return; }
        var state = new WindowActivityState(Visible && WindowState != FormWindowState.Minimized, windowActive, closingWrites.InFlight);
        var changed = WindowActivityOperations.State != state;
        WindowActivityOperations.Set(state);
        if ((!changed && !force) || webView.CoreWebView2 is null) { return; }
        try
        {
            webView.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new BridgeResponse(null, "event", "shell.window.activity", state), BridgeJson.Options));
        }
        catch (Exception ex) when (ex is InvalidOperationException or COMException)
        { TechnicalLog.Warning("État de fenêtre non transmis (" + ex.GetType().Name + ")."); }
    }
}
