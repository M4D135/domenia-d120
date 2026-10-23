using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Domenia.E2E.Runner;

namespace Domenia.E2E.Driver;

/// <summary>Closed native fixture: only the child process's empty machine-account window, never a Windows credential prompt.</summary>
internal static class NativeCredentialDriver
{
    internal const string SyntheticSecret = "Domenia-E2E-synthetique!";
    private const string Caption = "Domenia — Charger le compte poste";
    private const uint GetText = 0x000D, Character = 0x0102, Click = 0x00F5, Close = 0x0010;

    internal static async Task CheckAsync(int processId, bool use, TimeSpan timeout, Func<CancellationToken, Task> checkPage, CancellationToken token)
    {
        var started = Stopwatch.GetTimestamp();
        nint window = 0;
        while (window == 0 && Stopwatch.GetElapsedTime(started) < timeout)
        {
            token.ThrowIfCancellationRequested();
            var matches = Windows(0).Where(h => Owns(h, processId) && IsWindowVisible(h) && Read(h) == Caption).ToArray();
            Require(matches.Length <= 1, "Plusieurs fenêtres de compte dans le processus piloté.");
            window = matches.SingleOrDefault();
            if (window == 0) { await Task.Delay(100, token).ConfigureAwait(false); }
        }
        Require(window != 0, "Fenêtre native de compte poste absente dans le processus piloté.");
        try
        {
            var controls = Windows(window).Where(h => Owns(h, processId) && IsWindowVisible(h)).ToArray();
            var edits = controls.Where(h => Class(h).StartsWith("WindowsForms10.EDIT.", StringComparison.Ordinal)).ToArray();
            Require(edits.Length == 2, "Les deux champs natifs attendus ne sont pas identifiés.");
            var password = edits.Where(h => (GetWindowLongPtrW(h, -16).ToInt64() & 0x0800) == 0).ToArray();
            Require(password.Length == 1, "Champ secret natif ambigu ou identifiant modifiable.");
            nint Button(string text)
            {
                var matches = controls.Where(h => Class(h).StartsWith("WindowsForms10.BUTTON.", StringComparison.Ordinal) && Read(h) == text).ToArray();
                Require(matches.Length == 1, "Bouton natif attendu absent ou ambigu : " + text);
                return matches[0];
            }
            var accept = Button("Valider"); var reveal = Button("Afficher"); var cancel = Button("Annuler");
            Require(Read(password[0]).Length == 0 && !IsWindowEnabled(accept), "La saisie native doit commencer vide et ne pas pouvoir être validée.");
            foreach (var c in SyntheticSecret) { token.ThrowIfCancellationRequested(); Send(password[0], Character, c); }
            var bullets = new string('●', SyntheticSecret.Length);
            Require(Read(password[0]) == bullets && IsWindowEnabled(accept), "La saisie native ne masque pas le secret synthétique ou reste invalide.");
            await checkPage(token).ConfigureAwait(false);
            Send(reveal, Click);
            Require(Read(password[0]) == SyntheticSecret && !IsWindowEnabled(accept), "Révélation native incorrecte : la validation doit être désactivée.");
            await checkPage(token).ConfigureAwait(false);
            while (Read(password[0]) != bullets && Stopwatch.GetElapsedTime(started) < timeout)
            { await Task.Delay(100, token).ConfigureAwait(false); }
            Require(Read(password[0]) == bullets && IsWindowEnabled(accept), "Le secret natif n’a pas été remasqué automatiquement dans le délai.");
            Send(use ? accept : cancel, Click);
            while (IsWindow(window) && Stopwatch.GetElapsedTime(started) < timeout)
            { await Task.Delay(100, token).ConfigureAwait(false); }
            Require(!IsWindow(window), "La fenêtre native est restée ouverte après le geste demandé.");
            await checkPage(token).ConfigureAwait(false);
        }
        finally
        {
            // A failed assertion must not strand a modal dialog or change another process's desktop.
            if (IsWindow(window) && Owns(window, processId)) { _ = PostMessageW(window, Close, 0, 0); }
        }
    }

    private static void Require(bool value, string reason) { if (!value) { throw new StepFailure(reason); } }
    private static bool Owns(nint handle, int processId) { _ = GetWindowThreadProcessId(handle, out var owner); return owner == processId; }
    private static nint[] Windows(nint parent)
    {
        var result = new List<nint>();
        bool Visit(nint handle, nint unused) { result.Add(handle); return true; }
        if (parent == 0) { _ = EnumWindows(Visit, 0); } else { _ = EnumChildWindows(parent, Visit, 0); }
        return [.. result];
    }
    private static string Class(nint handle) { var text = new StringBuilder(256); _ = GetClassNameW(handle, text, text.Capacity); return text.ToString(); }
    private static string Read(nint handle)
    {
        var text = new StringBuilder(512);
        Require(ReadMessage(handle, GetText, (nuint)text.Capacity, text, 2, 1000, out _) != 0, "Lecture native hors délai ; aucune valeur n’est enregistrée.");
        return text.ToString();
    }
    private static void Send(nint handle, uint message, nuint value = 0) =>
        Require(SendMessageTimeoutW(handle, message, value, 0, 2, 1000, out _) != 0, "Geste natif hors délai.");

    private delegate bool VisitWindow(nint handle, nint argument);
#pragma warning disable SYSLIB1054 // Callback enumeration and bounded StringBuilder output use the framework marshaller.
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumWindows(VisitWindow callback, nint argument);
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EnumChildWindows(nint parent, VisitWindow callback, nint argument);
    [DllImport("user32.dll", ExactSpelling = true)] private static extern uint GetWindowThreadProcessId(nint handle, out uint processId);
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindow(nint handle);
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowVisible(nint handle);
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsWindowEnabled(nint handle);
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint GetWindowLongPtrW(nint handle, int index);
    [DllImport("user32.dll", ExactSpelling = true, CharSet = CharSet.Unicode)] private static extern int GetClassNameW(nint handle, StringBuilder value, int length);
    [DllImport("user32.dll", ExactSpelling = true, CharSet = CharSet.Unicode, EntryPoint = "SendMessageTimeoutW")]
    private static extern nint ReadMessage(nint handle, uint message, nuint wParam, StringBuilder lParam, uint flags, uint timeout, out nuint result);
    [DllImport("user32.dll", ExactSpelling = true)] private static extern nint SendMessageTimeoutW(nint handle, uint message, nuint wParam, nint lParam, uint flags, uint timeout, out nuint result);
    [DllImport("user32.dll", ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool PostMessageW(nint handle, uint message, nuint wParam, nint lParam);
#pragma warning restore SYSLIB1054
}
