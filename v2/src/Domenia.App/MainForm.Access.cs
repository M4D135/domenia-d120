namespace Domenia.App;

internal sealed partial class MainForm
{
    private void AttachLocalAccessExpiry()
    {
        // Only memory already present in the context. This timer never creates services, connects or polls AD.
        var timer = new System.Windows.Forms.Timer { Interval = 1000 };
        timer.Tick += (_, _) =>
        {
            if (closingChecked || hostClosing || IsDisposed) { timer.Stop(); return; }
            composition.SweepLocalAccess();
            timer.Interval = composition.AccessValidationActive ? 500 : 1000;
        };
        Shown += (_, _) => timer.Start();
        Disposed += (_, _) => timer.Dispose();
    }
}
