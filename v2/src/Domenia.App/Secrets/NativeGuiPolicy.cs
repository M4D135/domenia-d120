using Domenia.Core;

namespace Domenia.App.Secrets;

/// <summary>One-way restrictions of the secure login controls; native Escape/close/cancellation remain available.</summary>
internal static class NativeGuiPolicy
{
    internal static void Apply(Control control, string element, ShellPolicy policy, bool cancellation = false)
    {
        control.Name = element;
        var mode = GuiElementPolicies.Mode(policy.GuiPolicy, element, cancellation);
        if (mode is not ("Hidden" or "Disabled")) { return; }
        void Restrict()
        {
            if (control.Enabled) { control.Enabled = false; }
            if (mode == "Hidden" && control.Visible) { control.Visible = false; }
        }
        // Intrinsic validity checks can disable a control later; none may undo an administrator restriction.
        control.EnabledChanged += (_, _) => Restrict();
        if (mode == "Hidden") { control.VisibleChanged += (_, _) => Restrict(); control.Visible = false; }
        Restrict();
        control.AccessibleDescription = "Désactivé par l’administrateur (GuiElementPolicy).";
    }
}
