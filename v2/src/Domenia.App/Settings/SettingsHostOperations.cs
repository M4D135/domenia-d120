using System.Collections.Immutable;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App.Settings;

/// <summary>
/// Operations of the Paramètres screen that only the host can serve (docs/ops/parametres.md): À propos (identity,
/// compatibility, inventory, locations), effective configuration, technical journal, data policy, preferences document
/// (keys, export, import), « Ouvrir l’emplacement », zoom and window (native zoom of WebView2, remembered geometry),
/// destinations of a copy or a move (proposed name, proposed folders, local folders, check of the volume). Local reads of
/// the files of the application and of the local disks only; the import and the zoom write local preferences (LocalWrite).
/// The pure rules are in Domenia.Core (tested there).
/// </summary>
public sealed class SettingsHostOperations : IOperationModule
{
    public const string FolderUnavailable = "settings.folderUnavailable";
    public const string WindowUnavailable = "settings.windowUnavailable";

    /// <summary>Most sub-folders listed by settings.folders.browse.</summary>
    public const int MaxFolders = 500;

    private static readonly string[] FolderArguments = ["folder"];
    private static readonly string[] TextArguments = ["text"];
    private static readonly string[] ImportArguments = ["text", "fingerprint"];
    private static readonly string[] ZoomArguments = ["percent"];
    private static readonly string[] BrowseArguments = ["path"];
    private static readonly string[] CheckArguments = ["destination", "purpose"];

    /// <summary>Start of this run: the errors of the journal written since then light the badge of the page.</summary>
    private static readonly DateTimeOffset SessionStart = ReadSessionStart();

    private static DateTimeOffset ReadSessionStart()
    {
        try
        {
            using var process = Process.GetCurrentProcess();
            return new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException or System.ComponentModel.Win32Exception)
        {
            TechnicalLog.Warning($"Début de la session illisible ({ex.GetType().Name}) : heure du premier affichage retenue.");
            return DateTimeOffset.UtcNow;
        }
    }

    public string Screen => "settings";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var mode = context.Mode;
        var preferences = context.Preferences;
        var memoryPreferences = !preferences.Persistent || HostFacts.Unattended;
        // Zoom and window of the main window: applied at the first idle moment of the UI thread (never in capture or E2E).
        HostWindow.Attach(preferences);

        JsonElement? Read(string key) => preferences.TryGet(key, out var value) ? value : null;

        WindowSettingsView WindowView()
        {
            var reason = HostWindow.Unavailable;
            var placement = reason is null ? HostWindow.Remembered : WindowRules.ReadPlacement(Read(PreferenceApproval.WindowKey));
            var zoom = reason is null ? HostWindow.Zoom : WindowRules.ReadZoom(Read(PreferenceApproval.ZoomKey));
            return new WindowSettingsView(zoom, PreferenceApproval.ZoomMinimum, PreferenceApproval.ZoomMaximum, WindowRules.ZoomStep, true, reason is null, reason, placement is not null,
                WindowRules.Describe(placement),
                "Zoom de toute la fenêtre (menu, barre du haut et écrans), comme celui de Domenia 1 ; les dispositions suivent la largeur zoomée. Ctrl + molette, Ctrl +, Ctrl − et Ctrl 0 le règlent aussi, de 80 à 150" + FrenchText.Nbsp + "%.");
        }

        // Values of the document of the mode: the file when it is the store of the session, else the known keys in memory.
        ImmutableDictionary<string, JsonElement> Values()
        {
            if (!memoryPreferences)
            {
                var document = PreferenceDocument.Inspect(AppPaths.Preferences(mode));
                if (document.Readable)
                {
                    return document.Values;
                }
            }
            var known = ImmutableDictionary.CreateBuilder<string, JsonElement>(StringComparer.Ordinal);
            foreach (var key in new[] { DashboardService.DisabledWidgetsPreference, CollectionSettingsRules.PreferenceKey, StoragePolicyRules.PreferenceKey, SettingsViewRules.ConnectionKey, PreferenceApproval.ZoomKey, PreferenceApproval.WindowKey })
            {
                if (Read(key) is JsonElement value)
                {
                    known[key] = value;
                }
            }
            return known.ToImmutable();
        }

        return
        [
            new OperationDefinition("settings.about", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                var facts = HostFacts.ReadEnvironment();
                var (webMode, webVersion) = (facts.WebViewMode ?? "windows", facts.WebViewVersion);
                var identity = new AboutIdentity(
                    ProductInfo.Name,
                    ProductInfo.Version,
                    HostFacts.InformationalVersion(),
                    System.Environment.Version.ToString(),
                    System.Runtime.InteropServices.RuntimeInformation.RuntimeIdentifier,
                    System.Environment.Is64BitProcess,
                    webMode,
                    webMode == "embarque" ? "Moteur fixe du pack" : "Moteur WebView2 de Windows",
                    webVersion,
                    Compatibility.Observed("windows", facts),
                    mode == AppMode.Simulation ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText,
                    mode == AppMode.Simulation ? ModeTexts.SimulationLabel : ModeTexts.DirectoryLabel,
                    context.Decision.Detail);
                var view = new AboutView(identity, Compatibility.Verdict(Compatibility.Matrix, facts), HostFacts.Components(), HostFacts.Locations(mode, memoryPreferences),
                [
                    "Aucune donnée n’est envoyée hors de ce poste : ni télémétrie, ni service en ligne, ni mise à jour automatique.",
                    "Pack autonome : .NET et le moteur WebView2 sont livrés dans le dossier de l’application ; rien n’est installé.",
                    "La matrice de compatibilité est livrée avec Domenia, jamais téléchargée.",
                ]);
                return Task.FromResult<object?>(view);
            }, "Identité de Domenia, de ses moteurs et du poste ; compatibilité, composants livrés et emplacements."),

            new OperationDefinition("settings.config", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                byte[]? bytes = null;
                var path = Path.Combine(AppPaths.AppDirectory, LegacyConfiguration.FileName);
                try
                {
                    var info = new FileInfo(path);
                    if (info.Exists)
                    {
                        bytes = info.Length > LegacyConfiguration.MaxBytes ? new byte[LegacyConfiguration.MaxBytes + 1] : File.ReadAllBytes(path);
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    TechnicalLog.Warning($"{LegacyConfiguration.FileName} illisible pour Paramètres ({ex.GetType().Name}).");
                    bytes = [0xFF];
                }
                return Task.FromResult<object?>(ConfigurationRules.Read(bytes, LegacyConfiguration.FileName + " (à côté de Domenia.exe)"));
            }, "Configuration effective : valeur, défaut et provenance de chaque réglage lu par Domenia."),

            new OperationDefinition("settings.logs", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var path = TechnicalLog.FilePath;
                var lines = ImmutableArray<LogLine>.Empty;
                long bytes = 0;
                DateTimeOffset? modified = null;
                var exists = false;
                var truncated = false;
                if (path is not null)
                {
                    try
                    {
                        var info = new FileInfo(path);
                        exists = info.Exists;
                        if (exists)
                        {
                            bytes = info.Length;
                            modified = new DateTimeOffset(info.LastWriteTimeUtc, TimeSpan.Zero);
                            var text = await ReadTailAsync(path, cancellationToken).ConfigureAwait(false);
                            truncated = bytes > TechnicalLogTail.TailBytes;
                            lines = TechnicalLogTail.Parse(text, truncated, out var cut);
                            truncated |= cut;
                        }
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        TechnicalLog.Warning($"Journal technique illisible pour Paramètres ({ex.GetType().Name}).");
                    }
                }
                var (sessionErrors, sessionWarnings) = TechnicalLogTail.Since(lines, SessionStart);
                var file = new LogFileView(HostFacts.Display(path), path, exists, bytes, SettingsFormat.Size(bytes), modified, truncated, lines.Length,
                    lines.Count(l => l.Level == "ERREUR"), lines.Count(l => l.Level == "ATTENTION"), SessionStart, sessionErrors, sessionWarnings);
                return new LogsView(file, lines, context.Journal.Snapshot(),
                [
                    "Affichage seulement : tous les niveaux restent enregistrés dans le journal, quels que soient les filtres.",
                    "Le journal ne reçoit jamais une saisie de la page ni un secret ; la copie peut contenir des noms (masquage proposé).",
                    "Domenia lit la fin du fichier (256 Ko au plus) ; le fichier entier reste dans le dossier des journaux.",
                    "La pastille de l’écran ne compte que les erreurs de cette session ; celles des lancements précédents restent lisibles ici.",
                ]);
            }, "Fin du journal technique et journal des opérations de la session ; lecture seule."),

            new OperationDefinition("settings.dataPolicy", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                var policy = StoragePolicyRules.Read(Read(StoragePolicyRules.PreferenceKey), out var unreadable);
                var logs = TechnicalLog.FilePath is string log ? Path.GetDirectoryName(log) : null;
                var data = AppPaths.UserData;
                var locations = new DataLocations(
                    data is null ? null : HostFacts.Display(data),
                    memoryPreferences ? "En mémoire pour cette session" : HostFacts.Display(AppPaths.Preferences(mode)),
                    HostFacts.Unattended ? "En mémoire pour cette session" : HostFacts.Display(AppPaths.Receipts(mode)),
                    logs is null ? null : HostFacts.Display(logs),
                    HostFacts.Display(AppPaths.WebViewUserData(mode)),
                    data is null ? null : HostFacts.Display(Path.Combine(data, "Data", "Domains")) + @"\<domaine>\Domenia.db (vague 3)",
                    data is null ? null : HostFacts.Display(Path.Combine(data, "Data", "Domains")) + @"\<domaine>\Backups",
                    mode == AppMode.Simulation,
                    memoryPreferences);
                var view = DataPolicyRules.Build(policy, unreadable, locations);
                // « Ouvrir le dossier » only for folders that exist, and never in an unattended run.
                var rows = view.Rows.Select(r => r with
                {
                    Folder = r.Category switch
                    {
                        "log" => logs is not null && Directory.Exists(logs) && !HostFacts.Unattended ? "logs" : null,
                        "preference" or "receipt" or "webProfile" => data is not null && Directory.Exists(data) && !HostFacts.Unattended ? "data" : null,
                        _ => null,
                    },
                });
                return Task.FromResult<object?>(view with { Rows = [.. rows] });
            }, "Politique des données locales : contenu, emplacement, durée, export et suppression de chaque donnée."),

            new OperationDefinition("settings.folder.open", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, FolderArguments);
                var folder = BridgeArguments.GetString(values, "folder");
                if (SettingsFolders.Refusal(folder, HostFacts.Unattended, mode == AppMode.Simulation) is { } refusal)
                {
                    if (refusal.Code == DomeniaErrors.ArgumentsInvalid)
                    {
                        throw BridgeArguments.Invalid(refusal.Message);
                    }
                    throw new DomeniaOperationException(refusal.Code, refusal.Message);
                }
                var file = SettingsFolders.IsFile(folder);
                var path = folder switch
                {
                    "app" => AppPaths.AppDirectory.TrimEnd('\\'),
                    "data" => AppPaths.UserData,
                    "logs" => TechnicalLog.FilePath is string log ? Path.GetDirectoryName(log) : null,
                    "preferences" => memoryPreferences ? null : AppPaths.Preferences(mode),
                    "receipts" => AppPaths.Receipts(mode),
                    _ => AppPaths.WebViewUserData(mode),
                };
                if (path is null || !(file ? File.Exists(path) : Directory.Exists(path)))
                {
                    throw new DomeniaOperationException(FolderUnavailable, "Emplacement absent sur ce poste" + FrenchText.Colon + "rien à ouvrir.");
                }
                HostFacts.Open(path, file);
                return Task.FromResult<object?>(new { opened = folder, display = HostFacts.Display(path) });
            }, "Ouvre l’Explorateur Windows sur un dossier local de Domenia (geste explicite ; rien n’est lu ni écrit)."),

            new OperationDefinition("settings.preferences", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                var path = memoryPreferences ? null : AppPaths.Preferences(mode);
                var document = PreferenceDocument.Inspect(path);
                var values = document.Readable && !memoryPreferences ? document.Values : Values();
                var owners = PreferenceTransfer.Owners(values);
                var state = memoryPreferences ? "memory" : document.State;
                return Task.FromResult<object?>(new PreferencesView(
                    !memoryPreferences,
                    memoryPreferences ? "En mémoire seulement pour cette session" : HostFacts.Display(path),
                    path,
                    document.Exists,
                    document.Bytes,
                    document.ModifiedAt,
                    document.Readable,
                    state,
                    owners,
                    owners.Sum(o => o.Keys),
                    PreferenceTransfer.ResetGroups,
                    [
                        "Chaque écran ne lit et n’écrit que ses propres clés ; aucun mot de passe, jeton ou secret n’est jamais enregistré.",
                        "Écriture atomique sous un verrou commun à toutes les instances de Domenia ; un document illisible est mis de côté, jamais écrasé.",
                        mode == AppMode.Simulation ? "Simulation : document distinct du mode annuaire (preferences-simulation.json), jamais partagé." : "Mode annuaire : preferences.json ; la simulation garde son propre document.",
                        "La lecture seule et les filtres de présence ne sont jamais restaurés d’une session à l’autre.",
                    ]));
            }, "Document des préférences du mode : clés par écran, état, groupes de réinitialisation."),

            new OperationDefinition("settings.preferences.export", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult<object?>(PreferenceTransfer.Export(Values(), mode == AppMode.Simulation ? AppInfoBuilder.SimulationModeText : AppInfoBuilder.DirectoryModeText, context.Clock.GetUtcNow()));
            }, "Texte d’export des préférences approuvées (sans identité de connexion ni secret)."),

            new OperationDefinition("settings.preferences.import.preview", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, TextArguments);
                var text = BridgeArguments.GetString(values, "text");
                return Task.FromResult<object?>(PreferenceTransfer.Preview(text, Read));
            }, "Aperçu d’un import de préférences : changements, refus et empreinte exigée ; rien n’est écrit."),

            new OperationDefinition("settings.preferences.import", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ImportArguments);
                var text = BridgeArguments.GetString(values, "text");
                var fingerprint = BridgeArguments.GetString(values, "fingerprint");
                var preview = PreferenceTransfer.Preview(text, Read);
                if (!preview.Valid)
                {
                    throw new DomeniaOperationException("settings.importInvalid", preview.Problem ?? "Export illisible.");
                }
                if (!string.Equals(preview.Fingerprint, fingerprint, StringComparison.Ordinal))
                {
                    throw new DomeniaOperationException(StorageWritePlans.PreviewStale, "Les préférences ont changé depuis l’aperçu" + FrenchText.Colon + "refaites l’aperçu de l’import ; rien n’a été changé.");
                }
                var keys = preview.Changes.Select(c => c.Key).ToList();
                var failed = new List<string>();
                foreach (var (key, value) in PreferenceTransfer.Values(text, keys))
                {
                    try
                    {
                        await preferences.SetAsync(key, value, cancellationToken).ConfigureAwait(false);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        TechnicalLog.Warning($"Préférence importée non enregistrée ({ex.GetType().Name}) : elle vaut pour la session.");
                        failed.Add(key);
                    }
                }
                var summary = "Préférences importées" + FrenchText.Colon + FrenchText.Count(keys.Count, "clé changée", "clés changées")
                    + (preview.Refused.Length > 0 ? ", " + FrenchText.Count(preview.Refused.Length, "refusée", "refusées") : "")
                    + ". Les widgets et l’OU de travail importés s’appliquent au prochain démarrage." + (failed.Count > 0 ? " Non enregistrées sur le disque" + FrenchText.Colon + string.Join(", ", failed) + "." : "");
                context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), summary, failed.Count > 0 ? Tone.Warn : Tone.Info));
                return new PreferenceApplyResult(keys.Count, [.. keys], [.. failed], summary);
            }, "Applique un import de préférences prévisualisé (même empreinte) ; jamais l’identité de connexion."),

            // ----- Zoom and window (PAR-009, PAR-051) -----
            new OperationDefinition("settings.window", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult<object?>(WindowView());
            }, "Zoom de l’interface et fenêtre mémorisée."),

            new OperationDefinition("settings.window.zoom.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ZoomArguments);
                if (!values.TryGetValue("percent", out var raw) || raw.ValueKind != JsonValueKind.Number || !raw.TryGetInt32(out var percent)
                    || percent < PreferenceApproval.ZoomMinimum || percent > PreferenceApproval.ZoomMaximum)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("percent") + " doit être un entier de 80 à 150.");
                }
                if (HostWindow.Unavailable is string reason)
                {
                    throw new DomeniaOperationException(WindowUnavailable, reason);
                }
                HostWindow.SetZoom(percent);
                try
                {
                    await preferences.SetAsync(PreferenceApproval.ZoomKey, JsonSerializer.SerializeToElement(percent), cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    TechnicalLog.Warning($"Zoom non enregistré ({ex.GetType().Name}) : il vaut pour la session.");
                    context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Préférences non enregistrées" + FrenchText.Colon + "zoom de l’interface", Tone.Warn));
                }
                return WindowView();
            }, "Règle le zoom de toute la fenêtre (80 à 150 %), mémorisé pour ce poste."),

            new OperationDefinition("settings.window.forget", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                HostWindow.Forget();
                try
                {
                    await preferences.SetAsync(PreferenceApproval.WindowKey, null, cancellationToken).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    TechnicalLog.Warning($"Fenêtre mémorisée non oubliée sur le disque ({ex.GetType().Name}).");
                }
                context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Fenêtre mémorisée oubliée" + FrenchText.Colon + "taille et position par défaut au prochain démarrage", Tone.Info));
                return WindowView();
            }, "Oublie la taille et la position mémorisées de la fenêtre (défaut au prochain démarrage)."),

            // ----- Destinations of a copy or a move (PAR-016, PAR-035) -----
            new OperationDefinition("settings.storage.destinations", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var reader = context.Readers.Find<ISettingsReader>();
                var store = reader is null ? null : await reader.LocalStoreAsync(cancellationToken).ConfigureAwait(false);
                var folders = new List<DestinationFolder>();
                void Add(string id, string label, string? path)
                {
                    if (!string.IsNullOrEmpty(path) && LocalFolders.IsLocalFolder(path))
                    {
                        folders.Add(new DestinationFolder(id, label, path));
                    }
                }
                Add("documents", "Documents", System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyDocuments));
                Add("desktop", "Bureau", System.Environment.GetFolderPath(System.Environment.SpecialFolder.DesktopDirectory));
                if (AppPaths.UserData is string data)
                {
                    Add("exports", "Exports de Domenia", Path.Combine(data, mode == AppMode.Simulation ? "Exports-Simulation" : "Exports"));
                    Add("data", "Dossier de données de Domenia", data);
                }
                return new DestinationProposal(StorageWritePlans.ExportFileName(context.Clock.GetUtcNow(), context.Clock.LocalTimeZone),
                    store is { Available: true } ? StorageViewBuilder.BackupFolder(store.PathLabel) : null, [.. folders]);
            }, "Nom proposé (Domenia-AAAAMMJJ-HHmm.db) et dossiers locaux proposés pour une copie ou un déplacement."),

            new OperationDefinition("settings.folders.browse", OperationClass.LocalRead, (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, BrowseArguments);
                var path = values.TryGetValue("path", out var p) && p.ValueKind == JsonValueKind.String ? p.GetString() : null;
                cancellationToken.ThrowIfCancellationRequested();
                return Task.FromResult<object?>(LocalFolders.Browse(path));
            }, "Sous-dossiers d’un dossier local (ou les disques locaux) ; lecture seule, ni partage, ni lien."),

            new OperationDefinition("settings.storage.destination.check", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, CheckArguments);
                var destination = BridgeArguments.GetString(values, "destination");
                var purpose = BridgeArguments.GetString(values, "purpose");
                if (purpose is not ("copy" or "move"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("purpose") + " doit être copy ou move.");
                }
                if (destination.Length > 260)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("destination") + " doit faire au plus 260 caractères.");
                }
                var reader = context.Readers.Find<ISettingsReader>();
                var store = reader is null ? null : await reader.LocalStoreAsync(cancellationToken).ConfigureAwait(false);
                var active = store is { Available: true } ? store.PathLabel : "";
                var baseBytes = store is { Available: true } ? store.DatabaseBytes + store.WalBytes : 0;
                return LocalStoreRules.CheckDestination(destination, purpose, active, baseBytes, LocalFolders.Facts(destination));
            }, "Contrôle une destination en lecture seule : règles du chemin, disque local, dossier existant, réserve d’espace."),
        ];
    }

    private static async Task<string> ReadTailAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, useAsync: true);
        var start = Math.Max(0, stream.Length - TechnicalLogTail.TailBytes);
        stream.Seek(start, SeekOrigin.Begin);
        var buffer = new byte[stream.Length - start];
        await stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
        return Encoding.UTF8.GetString(buffer);
    }
}
