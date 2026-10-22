using System.Collections.Immutable;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App.Settings;

/// <summary>
/// Operations of the Paramètres screen that only the host can serve (docs/ops/parametres.md): À propos (identity,
/// compatibility, inventory, locations), effective configuration, technical journal, data policy, preferences document
/// (keys, export, import) and « Ouvrir l’emplacement ». Local reads of the files of the application only; the import
/// writes local preferences (LocalWrite) after its preview. The pure rules are in Domenia.Core (tested there).
/// </summary>
public sealed partial class SettingsHostOperations : IOperationModule
{
    /// <summary>Most of the technical journal read from its end.</summary>
    public const int LogTailBytes = 262_144;

    /// <summary>Most records of the journal returned.</summary>
    public const int LogRecords = 600;

    public const string FolderUnavailable = "settings.folderUnavailable";

    private static readonly string[] FolderArguments = ["folder"];
    private static readonly string[] TextArguments = ["text"];
    private static readonly string[] ImportArguments = ["text", "fingerprint"];

    [GeneratedRegex(@"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \[([A-ZÉ]+)\] (.*)$", RegexOptions.CultureInvariant, matchTimeoutMilliseconds: 200)]
    private static partial Regex LogPattern();

    public string Screen => "settings";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var mode = context.Mode;
        var preferences = context.Preferences;
        var memoryPreferences = !preferences.Persistent || HostFacts.Unattended;

        JsonElement? Read(string key) => preferences.TryGet(key, out var value) ? value : null;

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
            foreach (var key in new[] { DashboardService.DisabledWidgetsPreference, CollectionSettingsRules.PreferenceKey, StoragePolicyRules.PreferenceKey, SettingsViewRules.ConnectionKey })
            {
                if (Read(key) is JsonElement value)
                {
                    known[key] = value;
                }
            }
            return known.ToImmutable();
        }

        string? Validate(string key, JsonElement value)
        {
            switch (key)
            {
                case CollectionSettingsRules.PreferenceKey:
                    var warnings = new List<string>();
                    _ = CollectionSettingsRules.Read(value, warnings);
                    return warnings.Count > 0 ? "réglages de collecte illisibles (" + warnings[0].TrimEnd('.') + ")." : null;
                case StoragePolicyRules.PreferenceKey:
                    _ = StoragePolicyRules.Read(value, out var unreadable);
                    return unreadable ? "politique de conservation illisible ou hors limites." : null;
                case DashboardService.DisabledWidgetsPreference:
                    return value.ValueKind == JsonValueKind.Array && value.EnumerateArray().All(v => v.ValueKind == JsonValueKind.String) ? null : "liste de widgets attendue.";
            }
            if (key.StartsWith(WorkingScope.PreferencePrefix, StringComparison.Ordinal))
            {
                return value.ValueKind == JsonValueKind.Object && value.TryGetProperty("dn", out var dn) && dn.ValueKind == JsonValueKind.String ? null : "OU de travail illisible.";
            }
            return null;
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
                    "Aucune donnée n’est envoyée hors de ce poste : ni télémétrie, ni service en ligne, ni mise à jour automatique.",
                    "Pack autonome : .NET et le moteur WebView2 sont livrés dans le dossier de l’application ; rien n’est installé.",
                    "La matrice de compatibilité est livrée avec Domenia, jamais téléchargée.",
                ]);
                return Task.FromResult<object?>(view);
            }, "Identité de Domenia, de ses moteurs et du poste ; compatibilité, composants livrés et emplacements."),

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
            }, "Configuration effective : valeur, défaut et provenance de chaque réglage lu par Domenia."),

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
                            truncated = bytes > LogTailBytes;
                            lines = ParseLog(text, truncated, out var cut);
                            truncated |= cut;
                        }
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        TechnicalLog.Warning($"Journal technique illisible pour Paramètres ({ex.GetType().Name}).");
                    }
                }
                var file = new LogFileView(HostFacts.Display(path), path, exists, bytes, SettingsFormat.Size(bytes), modified, truncated, lines.Length,
                    lines.Count(l => l.Level == "ERREUR"), lines.Count(l => l.Level == "ATTENTION"));
                return new LogsView(file, lines, context.Journal.Snapshot(),
                [
                    "Affichage seulement : tous les niveaux restent enregistrés dans le journal, quels que soient les filtres.",
                    "Le journal ne reçoit jamais une saisie de la page ni un secret ; la copie peut contenir des noms (masquage proposé).",
                    "Domenia lit la fin du fichier (256 Ko au plus) ; le fichier entier reste dans le dossier des journaux.",
                ]);
            }, "Fin du journal technique et journal des opérations de la session ; lecture seule."),

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
            }, "Politique des données locales : contenu, emplacement, durée, export et suppression de chaque donnée."),

            new OperationDefinition("settings.folder.open", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, FolderArguments);
                var folder = BridgeArguments.GetString(values, "folder");
                if (HostFacts.Unattended)
                {
                    throw new DomeniaOperationException(FolderUnavailable, "Capture ou scénario E2E en cours" + FrenchText.Colon + "l’Explorateur n’est pas ouvert.");
                }
                var (path, file) = folder switch
                {
                    "app" => (AppPaths.AppDirectory.TrimEnd('\\'), false),
                    "data" => (AppPaths.UserData, false),
                    "logs" => (TechnicalLog.FilePath is string log ? Path.GetDirectoryName(log) : null, false),
                    "preferences" => (memoryPreferences ? null : AppPaths.Preferences(mode), true),
                    "receipts" => (AppPaths.Receipts(mode), true),
                    "profile" => (AppPaths.WebViewUserData(mode), false),
                    "base" => throw new DomeniaOperationException(FolderUnavailable, mode == AppMode.Simulation
                        ? "Base de démonstration" + FrenchText.Colon + "aucun fichier sur le disque à montrer."
                        : "Aucune base locale pour ce domaine pour l’instant" + FrenchText.Colon + "rien à montrer."),
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("folder") + " doit être app, data, logs, preferences, receipts, profile ou base."),
                };
                if (path is null || !(file ? File.Exists(path) : Directory.Exists(path)))
                {
                    throw new DomeniaOperationException(FolderUnavailable, "Emplacement absent sur ce poste" + FrenchText.Colon + "rien à ouvrir.");
                }
                HostFacts.Open(path, file);
                return Task.FromResult<object?>(new { opened = folder, display = HostFacts.Display(path) });
            }, "Ouvre l’Explorateur Windows sur un dossier local de Domenia (geste explicite ; rien n’est lu ni écrit)."),

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
                        "Chaque écran ne lit et n’écrit que ses propres clés ; aucun mot de passe, jeton ou secret n’est jamais enregistré.",
                        "Écriture atomique sous un verrou commun à toutes les instances de Domenia ; un document illisible est mis de côté, jamais écrasé.",
                        mode == AppMode.Simulation ? "Simulation : document distinct du mode annuaire (preferences-simulation.json), jamais partagé." : "Mode annuaire : preferences.json ; la simulation garde son propre document.",
                        "La lecture seule et les filtres de présence ne sont jamais restaurés d’une session à l’autre.",
                    ]));
            }, "Document des préférences du mode : clés par écran, état, groupes de réinitialisation."),

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
                return Task.FromResult<object?>(PreferenceTransfer.Preview(text, Read, Validate));
            }, "Aperçu d’un import de préférences : changements, refus et empreinte exigée ; rien n’est écrit."),

            new OperationDefinition("settings.preferences.import", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, ImportArguments);
                var text = BridgeArguments.GetString(values, "text");
                var fingerprint = BridgeArguments.GetString(values, "fingerprint");
                var preview = PreferenceTransfer.Preview(text, Read, Validate);
                if (!preview.Valid)
                {
                    throw new DomeniaOperationException("settings.importInvalid", preview.Problem ?? "Export illisible.");
                }
                if (!string.Equals(preview.Fingerprint, fingerprint, StringComparison.Ordinal))
                {
                    throw new DomeniaOperationException(StorageWritePlans.PreviewStale, "Les préférences ont changé depuis l’aperçu" + FrenchText.Colon + "refaites l’aperçu de l’import ; rien n’a été changé.");
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
                        TechnicalLog.Warning($"Préférence importée non enregistrée ({ex.GetType().Name}) : elle vaut pour la session.");
                        failed.Add(key);
                    }
                }
                var summary = "Préférences importées" + FrenchText.Colon + FrenchText.Count(keys.Count, "clé changée", "clés changées")
                    + (preview.Refused.Length > 0 ? ", " + FrenchText.Count(preview.Refused.Length, "refusée", "refusées") : "")
                    + ". Les widgets et l’OU de travail importés s’appliquent au prochain démarrage." + (failed.Count > 0 ? " Non enregistrées sur le disque" + FrenchText.Colon + string.Join(", ", failed) + "." : "");
                context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), summary, failed.Count > 0 ? Tone.Warn : Tone.Info));
                return new PreferenceApplyResult(keys.Count, [.. keys], [.. failed], summary);
            }, "Applique un import de préférences prévisualisé (même empreinte) ; jamais l’identité de connexion."),
        ];
    }

    private static async Task<string> ReadTailAsync(string path, CancellationToken cancellationToken)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, useAsync: true);
        var start = Math.Max(0, stream.Length - LogTailBytes);
        stream.Seek(start, SeekOrigin.Begin);
        var buffer = new byte[stream.Length - start];
        await stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
        return Encoding.UTF8.GetString(buffer);
    }

    /// <summary>Records of the journal, oldest first; a line that does not start a record continues the previous one.</summary>
    internal static ImmutableArray<LogLine> ParseLog(string text, bool startsMidway, out bool cut)
    {
        var records = new List<(DateTimeOffset? At, string Level, string Text, List<string> More)>();
        var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var first = startsMidway ? 1 : 0;
        for (var n = first; n < lines.Length; n++)
        {
            var line = lines[n];
            if (line.Length == 0)
            {
                continue;
            }
            Match match;
            try
            {
                match = LogPattern().Match(line);
            }
            catch (RegexMatchTimeoutException)
            {
                match = Match.Empty;
            }
            if (match.Success)
            {
                var at = DateTimeOffset.TryParse(match.Groups[1].Value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : (DateTimeOffset?)null;
                records.Add((at, match.Groups[2].Value, match.Groups[3].Value, []));
            }
            else if (records.Count > 0)
            {
                if (records[^1].More.Count < 40)
                {
                    records[^1].More.Add(line.TrimEnd());
                }
            }
            else
            {
                records.Add((null, "INFO", line.TrimEnd(), []));
            }
        }
        cut = records.Count > LogRecords;
        return [.. records.Skip(Math.Max(0, records.Count - LogRecords)).Select(r => new LogLine(r.At, r.Level, r.Text, [.. r.More]))];
    }
}
