using System.Collections.Immutable;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.App.Poste;

/// <summary>
/// Services of the host for the workstation console (docs/ops/poste.md § 6): the secure window of the secrets, the launcher
/// of the Windows and suite tools, the « Enregistrer sous » of the exports. Found by the composition like a screen reader
/// (one public constructor that takes the directory source), on the UI thread: the constructor creates the handle of a
/// hidden marshalling control there, every window is then created on that thread, while the bridge calls come from the
/// thread pool. Nothing here reads the directory, and no value of a secret ever leaves this class towards the page.
/// </summary>
public sealed partial class PosteHostServices : IPosteSecretWindow, IPosteToolLauncher, IPosteFileExport, IDisposable
{
    private const int ClipboardClearMilliseconds = SecretPolicy.ClipboardClearSeconds * 1000;
    private const int WaitForUiMilliseconds = 15_000;

    private readonly Control marshal;
    private readonly Lock gate = new();
    private SecretWindowState state = Closed("Aucune valeur affichée.");

    // UI thread only.
    private SecretWindowForm? window;
    private System.Windows.Forms.Timer? clipboardTimer;
    private string? copied;

    /// <summary>Built by ScreenReaders.Discover during the composition, on the UI thread (before the main window exists).</summary>
    public PosteHostServices(IDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        marshal = new Control();
        marshal.CreateControl();
        _ = marshal.Handle;
    }

    public void Dispose() => marshal.Dispose();

    private static SecretWindowState Closed(string text) => new(false, false, null, null, null, null, 0, text);

    /// <summary>
    /// Runs <paramref name="work"/> on the UI thread and returns its result to the calling thread; bounded unless the work waits
    /// for the operator (<paramref name="interactive"/>: a Windows dialog).
    /// </summary>
    private Task<T> OnUiAsync<T>(Func<T> work, bool interactive = false)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            marshal.BeginInvoke(() =>
            {
                try
                {
                    done.SetResult(work());
                }
                catch (Exception ex)
                {
                    done.SetException(ex);
                }
            });
        }
        catch (Exception ex) when (ex is InvalidOperationException or ObjectDisposedException)
        {
            done.SetException(new DomeniaOperationException(PosteErrors.HostUnavailable, "La fenêtre de Domenia se ferme : rien n’a été ouvert."));
        }
        return interactive ? done.Task : done.Task.WaitAsync(TimeSpan.FromMilliseconds(WaitForUiMilliseconds));
    }

    private static Form? MainWindow() => Application.OpenForms.Cast<Form>().FirstOrDefault(f => f is not SecretWindowForm);

    // ------------------------------------------------------------------ secure window of the secrets

    public async Task<SecretShown> ShowAsync(SecretReading secret, Action<string> note, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(secret);
        ArgumentNullException.ThrowIfNull(note);
        cancellationToken.ThrowIfCancellationRequested();
        var until = await OnUiAsync(() =>
        {
            CloseWindow();
            var form = new SecretWindowForm(secret, value => Copy(value, secret, note), Changed);
            window = form;
            form.FormClosed += (_, _) => OnClosed(form);
            var owner = MainWindow();
            if (owner is not null)
            {
                form.Show(owner);
            }
            else
            {
                form.Show();
            }
            form.Activate();
            Changed(form);
            return form.Until;
        }).ConfigureAwait(false);
        var where = "Fenêtre sécurisée de Domenia, au-dessus de l’application : la valeur n’est jamais affichée dans la page.";
        return new SecretShown(secret.Kind, secret.Computer, secret.Identifier, secret.KeyGuid, where, until, secret.RevealSeconds, secret.ExtensionSeconds,
            secret.Extensions, secret.ClipboardLimit, secret.Notice, secret.Simulated, secret.ReadAt);
    }

    public async Task<bool> HideAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return await OnUiAsync(CloseWindow).ConfigureAwait(false);
    }

    public SecretWindowState State()
    {
        lock (gate)
        {
            return state;
        }
    }

    /// <summary>Closes the window shown, if any (UI thread); its value is wiped by the form itself.</summary>
    private bool CloseWindow()
    {
        var shown = window;
        window = null;
        if (shown is null || shown.IsDisposed)
        {
            return false;
        }
        shown.Close();
        return true;
    }

    private void OnClosed(SecretWindowForm form)
    {
        if (ReferenceEquals(window, form))
        {
            window = null;
        }
        lock (gate)
        {
            state = Closed(form.ExpiredAtDeadline ? "Valeur masquée à l’échéance et effacée." : "Fenêtre sécurisée fermée : la valeur a été effacée.");
        }
    }

    private void Changed(SecretWindowForm form)
    {
        var secret = form.Secret;
        var text = form.Masked
            ? "Valeur masquée (la fenêtre a perdu le focus) : cliquez sur « Réafficher » dans la fenêtre sécurisée."
            : "Valeur affichée dans la fenêtre sécurisée jusqu’à l’échéance.";
        lock (gate)
        {
            state = new SecretWindowState(true, form.Masked, secret.Kind, secret.Computer, secret.Identifier, form.Until, form.ExtensionsLeft, text);
        }
    }

    /// <summary>
    /// Protected copy (Domenia 1 Set-DomeniaProtectedClipboard): excluded from the clipboard history and the cloud clipboard,
    /// emptied after 30 s only when the clipboard still holds this value; journalled with the identifier, never the value.
    /// </summary>
    private bool Copy(string value, SecretReading secret, Action<string> note)
    {
        try
        {
            var data = new DataObject();
            data.SetData(DataFormats.UnicodeText, value);
            data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
            data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
            data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
            Clipboard.SetDataObject(data, copy: true, retryTimes: 5, retryDelay: 100);
        }
        catch (ExternalException ex)
        {
            TechnicalLog.Warning($"Copie protégée refusée par le presse-papiers : {ex.GetType().Name}.");
            return false;
        }
        copied = value;
        clipboardTimer?.Dispose();
        clipboardTimer = new System.Windows.Forms.Timer { Interval = ClipboardClearMilliseconds };
        clipboardTimer.Tick += (_, _) => ClearClipboard();
        clipboardTimer.Start();
        note((secret.Kind == "laps" ? "Mot de passe LAPS copié (compte " : "Clé BitLocker copiée (identifiant ") + secret.Identifier + ") pour " + secret.Computer
            + " : presse-papiers vidé dans 30 s s’il la contient encore (valeur jamais journalisée)");
        return true;
    }

    private void ClearClipboard()
    {
        clipboardTimer?.Dispose();
        clipboardTimer = null;
        var value = copied;
        copied = null;
        if (value is null)
        {
            return;
        }
        try
        {
            // Another copy made by the operator in between is left alone (Domenia 1 Clear-DomeniaSecretClipboard).
            if (Clipboard.ContainsText() && string.Equals(Clipboard.GetText(), value, StringComparison.Ordinal))
            {
                Clipboard.Clear();
            }
        }
        catch (ExternalException ex)
        {
            TechnicalLog.Warning($"Presse-papiers non vidé (occupé par une autre application) : {ex.GetType().Name}.");
        }
    }

    // ------------------------------------------------------------------ Windows tools (Domenia 1 Invoke-ComputerTool)

    [GeneratedRegex(@"^[A-Za-z0-9]([A-Za-z0-9-]{0,62})(\.[A-Za-z0-9]([A-Za-z0-9-]{0,62}))*$", RegexOptions.CultureInvariant, 200)]
    private static partial Regex HostName();

    public async Task<ToolLaunch> OpenToolAsync(ToolRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var host = request.Host.Trim();
        if (host.Length > 253 || !HostName().IsMatch(host))
        {
            throw new DomeniaOperationException(PosteErrors.Refused, "Nom du poste invalide pour un outil Windows : rien n’est lancé.");
        }
        var system = Environment.SystemDirectory;
        (string Label, string File, string[] Arguments, string? Share) tool = request.Tool switch
        {
            "rdp" => ("Bureau à distance", Path.Combine(system, "mstsc.exe"), new[] { "/v:" + host }, null),
            "c" => ("Dossier C$", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), new[] { @"\\" + host + @"\C$" }, @"\\" + host + @"\C$"),
            "compmgmt" => ("Gestion de l’ordinateur", Path.Combine(system, "mmc.exe"), new[] { Path.Combine(system, "compmgmt.msc"), @"/computer:\\" + host }, @"\\" + host + @"\IPC$"),
            "eventvwr" => ("Observateur d’événements", Path.Combine(system, "mmc.exe"), new[] { Path.Combine(system, "eventvwr.msc"), @"/computer:\\" + host }, @"\\" + host + @"\IPC$"),
            "services" => ("Services", Path.Combine(system, "mmc.exe"), new[] { Path.Combine(system, "services.msc"), @"/computer:\\" + host }, @"\\" + host + @"\IPC$"),
            _ => throw new DomeniaOperationException(PosteErrors.Refused, "Outil inconnu : rien n’est lancé."),
        };
        var (label, file, arguments, share) = tool;
        var command = Path.GetFileName(file) + " " + string.Join(" ", arguments.Select(a => a.Contains(' ', StringComparison.Ordinal) ? "\"" + a + "\"" : a));
        if (request.Simulated)
        {
            return new ToolLaunch(false, true, request.Tool, label, command, "Simulation : aucun outil n’est ouvert vers un poste fictif. Commande qui serait lancée : " + command, []);
        }
        var checks = ImmutableArray.CreateBuilder<string>();
        if (share is not null && !string.IsNullOrWhiteSpace(request.OperationsAccount))
        {
            // Connection with the operations account first (Domenia 1 Start-DomeniaAdminShareOpen): Windows asks the password in its
            // own prompt and keeps it; Domenia never sees it.
            var owner = await OnUiAsync(() => MainWindow()?.Handle ?? IntPtr.Zero).ConfigureAwait(false);
            var code = await Task.Run(() => Connect(owner, share, request.OperationsAccount!), cancellationToken).ConfigureAwait(false);
            switch (code)
            {
                case 0:
                    checks.Add("Connexion à " + share + " avec " + request.OperationsAccount + " (mot de passe saisi dans l’invite Windows).");
                    break;
                case ErrorCancelled:
                    return new ToolLaunch(false, false, request.Tool, label, command, "Invite Windows annulée : rien n’est ouvert.", checks.ToImmutable());
                case ErrorSessionCredentialConflict:
                    checks.Add("Une connexion à " + host + " existe déjà avec un autre compte : elle est réutilisée.");
                    break;
                default:
                    TechnicalLog.Warning($"Connexion au partage du poste refusée (code {code}).");
                    return new ToolLaunch(false, false, request.Tool, label, command, "Connexion à " + share + " refusée par Windows (code " + code.ToString(System.Globalization.CultureInfo.InvariantCulture) + ") : rien n’est ouvert.", checks.ToImmutable());
            }
        }
        var start = new ProcessStartInfo(file) { UseShellExecute = false };
        foreach (var argument in arguments)
        {
            start.ArgumentList.Add(argument);
        }
        try
        {
            using var process = Process.Start(start);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            TechnicalLog.Warning($"Outil Windows non lancé : {ex.GetType().Name}.");
            return new ToolLaunch(false, false, request.Tool, label, command, label + " n’a pas pu être lancé sur ce poste d’administration.", checks.ToImmutable());
        }
        return new ToolLaunch(true, false, request.Tool, label, command, label + " ouvert vers " + host + ".", checks.ToImmutable());
    }

    // ------------------------------------------------------------------ suite tools (Domenia 1 Open-DomeniaSuiteTool, PST-020)

    public async Task<ToolLaunch> OpenSuiteAsync(SuiteRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var checks = ImmutableArray.CreateBuilder<string>();
        if (request.Simulated)
        {
            var simulated = PosteRemote.Suite(request.Label, null, request.Context, explicitGesture: true);
            return new ToolLaunch(false, true, request.Tool, request.Label, request.Label, "Simulation : " + request.Label + " n’est pas lancé pour un poste fictif. " + simulated.Reason, []);
        }
        if (string.IsNullOrWhiteSpace(request.Path) || !Path.IsPathFullyQualified(request.Path) || !File.Exists(request.Path))
        {
            return new ToolLaunch(false, false, request.Tool, request.Label, "", "Chemin de " + request.Label + " non configuré ou introuvable : rien n’est lancé.", []);
        }
        if (string.IsNullOrWhiteSpace(request.Sha256))
        {
            return new ToolLaunch(false, false, request.Tool, request.Label, "", "Aucune empreinte SHA-256 déclarée pour " + request.Label + " : rien n’est lancé (exécutable non vérifiable).", []);
        }
        string actual;
        await using (var stream = new FileStream(request.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 81920, useAsync: true))
        {
            actual = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false));
        }
        if (!string.Equals(actual, request.Sha256.Trim(), StringComparison.OrdinalIgnoreCase))
        {
            TechnicalLog.Warning("Outil de la suite refusé : empreinte différente de la configuration.");
            return new ToolLaunch(false, false, request.Tool, request.Label, "", "Empreinte de " + request.Label + " différente de celle déclarée : l’exécutable a changé, rien n’est lancé.", []);
        }
        checks.Add("Empreinte SHA-256 de l’exécutable conforme à la configuration.");
        string? contract = null;
        var contractPath = Path.Combine(Path.GetDirectoryName(request.Path) ?? "", "suite-contract.json");
        if (File.Exists(contractPath))
        {
            var info = new FileInfo(contractPath);
            contract = info.Length <= 16384 ? await File.ReadAllTextAsync(contractPath, Encoding.UTF8, cancellationToken).ConfigureAwait(false) : new string(' ', 16385);
        }
        var plan = PosteRemote.Suite(request.Label, contract, request.Context, explicitGesture: true);
        checks.Add(plan.Mode == "Contract" ? "Contrat suite-contract.json reconnu : champs déclarés seulement." : plan.Reason);
        var start = new ProcessStartInfo(request.Path) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(request.Path) ?? "" };
        foreach (var argument in plan.Arguments)
        {
            start.ArgumentList.Add(argument);
        }
        var command = Path.GetFileName(request.Path) + (plan.Arguments.IsEmpty ? "" : " " + string.Join(" ", plan.Arguments));
        try
        {
            using var process = Process.Start(start);
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            TechnicalLog.Warning($"Outil de la suite non lancé : {ex.GetType().Name}.");
            return new ToolLaunch(false, false, request.Tool, request.Label, command, request.Label + " n’a pas pu être lancé.", checks.ToImmutable());
        }
        return new ToolLaunch(true, false, request.Tool, request.Label, command, request.Label + " ouvert avec le contexte du poste.", checks.ToImmutable());
    }

    // ------------------------------------------------------------------ exports (« Enregistrer sous »)

    public async Task<PosteExportResult> SaveAsync(ExportRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var path = await OnUiAsync(() =>
        {
            using var dialog = new SaveFileDialog
            {
                Title = "Enregistrer l’export de Domenia",
                FileName = request.SuggestedName,
                DefaultExt = "csv",
                Filter = "Fichier CSV (*.csv)|*.csv",
                AddExtension = true,
                OverwritePrompt = true,
                InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
            };
            return dialog.ShowDialog(MainWindow()) == DialogResult.OK ? dialog.FileName : null;
        }, interactive: true).ConfigureAwait(false);
        if (path is null)
        {
            return new PosteExportResult(false, [], "Enregistrement annulé : aucun fichier écrit.");
        }
        var names = ImmutableArray.CreateBuilder<string>();
        var encoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: true);
        try
        {
            for (var i = 0; i < request.Files.Length; i++)
            {
                var file = request.Files[i];
                var target = i == 0 ? path : Path.Combine(Path.GetDirectoryName(path) ?? "", Path.GetFileNameWithoutExtension(path) + "-" + file.Part + ".csv");
                await File.WriteAllTextAsync(target, file.Csv, encoding, cancellationToken).ConfigureAwait(false);
                names.Add(Path.GetFileName(target));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            TechnicalLog.Warning($"Export non enregistré : {ex.GetType().Name}.");
            throw new DomeniaOperationException(PosteErrors.Refused, "Fichier non enregistré (dossier en lecture seule, disque plein ou fichier ouvert ailleurs) : choisissez un autre emplacement.");
        }
        return new PosteExportResult(true, names.ToImmutable(), FrenchText.Count(names.Count, "fichier enregistré", "fichiers enregistrés") + " : " + string.Join(", ", names) + ".");
    }

    // ------------------------------------------------------------------ native

    private const int ResourceTypeDisk = 1;
    private const int ResourceTypeAny = 0;
    private const int ConnectInteractive = 0x8;
    private const int ConnectPrompt = 0x10;
    private const int ErrorCancelled = 1223;
    private const int ErrorSessionCredentialConflict = 1219;

    [StructLayout(LayoutKind.Sequential)]
    private struct NetResource
    {
        public int Scope;
        public int Type;
        public int DisplayType;
        public int Usage;
        public IntPtr LocalName;
        public IntPtr RemoteName;
        public IntPtr Comment;
        public IntPtr Provider;
    }

    [LibraryImport("mpr.dll", EntryPoint = "WNetAddConnection3W", StringMarshalling = StringMarshalling.Utf16)]
    private static partial int WNetAddConnection3(IntPtr owner, ref NetResource resource, string? password, string? userName, int flags);

    /// <summary>Connects to a share of the workstation with the operations account; Windows prompts for the password itself.</summary>
    private static int Connect(IntPtr owner, string share, string account)
    {
        var remote = Marshal.StringToHGlobalUni(share);
        try
        {
            var resource = new NetResource { Type = share.EndsWith("IPC$", StringComparison.OrdinalIgnoreCase) ? ResourceTypeAny : ResourceTypeDisk, RemoteName = remote };
            return WNetAddConnection3(owner, ref resource, null, account, ConnectInteractive | ConnectPrompt);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            TechnicalLog.Error("Connexion au partage impossible : mpr.dll indisponible.", ex);
            return -1;
        }
        finally
        {
            Marshal.FreeHGlobal(remote);
        }
    }
}
