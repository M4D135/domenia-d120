using System.Collections.Immutable;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

/// <summary>
/// Operations of the shell bound to the host (docs/ops/shell.md): « À propos » facts, title and frame of the window, exports and
/// their folder, embedded file picker, guides and team layouts of the boards. They need the paths of the application (exe
/// folder, data folder) and the main window, hence this module of Domenia.App, found by the composition like every other one.
/// Their pure rules live in Domenia.Core and Domenia.Store (tested there).
/// </summary>
public sealed class ShellHostOperations : IOperationModule
{
    /// <summary>Exports listed at most.</summary>
    public const int ExportListLimit = 50;

    /// <summary>Longest text of a CSV or JSON export sent by the page.</summary>
    public const int MaxExportText = 900_000;

    private static readonly string[] ChromeArguments = ["title", "dark", "writeActive", "caption", "text"];
    private static readonly string[] SaveArguments = ["kind", "name", "headers", "rows", "secretColumns", "text"];
    private static readonly string[] OpenArguments = ["fileName"];
    private static readonly string[] BrowseArguments = ["folder", "filter"];
    private static readonly string[] ReadArguments = ["path", "kind"];
    private static readonly string[] GuideArguments = ["page"];
    private static readonly string[] TeamArguments = ["board"];
    private static readonly UTF8Encoding Utf8WithBom = new(encoderShouldEmitUTF8Identifier: true);
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public string Screen => "shell";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var mode = context.Mode;
        var exports = context.Shared<IShellExportStore>(CreateExports);
        var browser = new LocalFileBrowser(Roots(mode, exports));
        var about = new Lazy<ShellAbout>(() => LocalFacts.Read(context), LazyThreadSafetyMode.ExecutionAndPublication);
        return
        [
            // LocalRead: registry version keys and the version of winsqlite3.dll, once per session.
            new OperationDefinition("shell.about", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(about.Value);
            }, "À propos de Domenia : version, moteurs et compatibilité du poste, faits locaux seulement."),

            // Local: title and frame of the main window, nothing written, nothing read.
            new OperationDefinition("shell.window.chrome", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, ChromeArguments);
                var title = BridgeArguments.GetOptionalString(values, "title");
                if (title is { Length: > ShellTexts.MaxTitleLength * 2 })
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("title") + " doit faire au plus " + FrenchText.Integer(ShellTexts.MaxTitleLength * 2) + " caractères.");
                }
                var dark = BridgeArguments.GetBoolean(values, "dark");
                var writeActive = BridgeArguments.GetBoolean(values, "writeActive");
                var caption = BridgeArguments.GetOptionalString(values, "caption");
                var text = BridgeArguments.GetOptionalString(values, "text");
                var applied = WindowChrome.Apply(title, writeActive, mode, dark, caption, text);
                return Task.FromResult<object?>(new { applied });
            }, "Titre et barre de titre de la fenêtre selon l’écran et le thème."),

            // LocalWrite: the exports folder of the data folder (memory only in capture and E2E), never overwritten.
            new OperationDefinition("shell.export.save", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SaveArguments);
                return await SaveAsync(context, exports, values, cancellationToken).ConfigureAwait(false);
            }, "Exporte une liste (CSV) ou un document (JSON) dans le dossier des exports, sans jamais écraser un fichier."),

            new OperationDefinition("shell.export.list", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(new ShellExportListing(exports.FolderLabel, exports.Persistent ? "disque" : "mémoire", exports.List(ExportListLimit)));
            }, "Derniers fichiers du dossier des exports."),

            // LocalRead: opens the Explorer on the exports folder of the application (on the file when given).
            new OperationDefinition("shell.export.open", OperationClass.LocalRead, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, OpenArguments);
                var fileName = BridgeArguments.GetOptionalString(values, "fileName");
                if (fileName is not null && !ShellExportNames.IsExportName(fileName))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit être le nom d’un export de Domenia.");
                }
                return Task.FromResult<object?>(new { opened = OpenFolder(exports, fileName) });
            }, "Ouvre le dossier des exports dans l’Explorateur, sur le fichier indiqué."),

            new OperationDefinition("shell.files.browse", OperationClass.LocalRead, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, BrowseArguments);
                var folder = BridgeArguments.GetOptionalString(values, "folder");
                var filter = BridgeArguments.GetString(values, "filter");
                if (filter is not ("csv" or "json" or "all"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("filter") + " doit valoir csv, json ou all.");
                }
                if (folder is { Length: > 1024 })
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("folder") + " doit faire au plus 1 024 caractères.");
                }
                (exports as FileExportStore)?.EnsureFolder();
                return Task.FromResult<object?>(browser.Browse(folder, filter));
            }, "Sélecteur de fichier intégré : emplacements de départ, puis dossiers locaux (500 entrées au plus)."),

            new OperationDefinition("shell.files.read", OperationClass.LocalRead, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, ReadArguments);
                var path = BridgeArguments.GetString(values, "path");
                var kind = BridgeArguments.GetString(values, "kind");
                if (kind is not ("csv" or "json"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir csv ou json.");
                }
                return Task.FromResult<object?>(browser.Read(path, kind));
            }, "Lit un fichier choisi dans le sélecteur : CSV (séparateur détecté) ou JSON, 1 Mo au plus."),

            new OperationDefinition("shell.guide.info", OperationClass.LocalRead, (args, _, _) =>
            {
                var chapter = GuideChapters.For(PageArgument(args));
                return Task.FromResult<object?>(Guide(chapter, GuideLocator.Find(chapter, AppPaths.AppDirectory), opened: false));
            }, "Chapitre du guide qui décrit l’écran, et présence du PDF dans un dossier DOC."),

            // LocalRead: opens the PDF of the guide (a file delivered with the application) with the associated reader.
            new OperationDefinition("shell.guide.open", OperationClass.LocalRead, (args, _, _) =>
            {
                var chapter = GuideChapters.For(PageArgument(args));
                var path = GuideLocator.Find(chapter, AppPaths.AppDirectory);
                return Task.FromResult<object?>(Guide(chapter, path, opened: path is not null && OpenDocument(path)));
            }, "Ouvre le guide PDF de l’écran avec le lecteur associé."),

            new OperationDefinition("shell.board.team", OperationClass.LocalRead, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, TeamArguments);
                var board = BridgeArguments.GetString(values, "board");
                if (!TeamLayouts.IsBoardName(board))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("board") + " doit être un nom de tableau (Computer, Fleet, Software, Interface…).");
                }
                return Task.FromResult<object?>(TeamLayoutFile.Read(AppPaths.AppDirectory, board));
            }, "Disposition d’équipe d’un tableau (Dashboard.DefaultLayout<Tableau> de Domenia.config.json)."),
        ];
    }

    private static IShellExportStore CreateExports(EngineContext context)
    {
        // Capture, E2E and sessions without a data folder keep their exports in memory: nothing on disk.
        if (!context.Preferences.Persistent || AppPaths.UserData is not string data)
        {
            return new MemoryExportStore(context.Clock);
        }
        var name = FileExportStore.FolderNameFor(context.Mode);
        return new FileExportStore(Path.Combine(data, name), "%LOCALAPPDATA%\\Domenia\\" + name);
    }

    /// <summary>
    /// Starting places of the file picker: the exports of the simulation only in simulation (no real file shown), the folders of
    /// the user and the exports folder in directory mode.
    /// </summary>
    private static List<ShellFileRoot> Roots(AppMode mode, IShellExportStore exports)
    {
        var roots = new List<ShellFileRoot>();
        if (exports is FileExportStore && AppPaths.UserData is string data)
        {
            roots.Add(new ShellFileRoot(mode == AppMode.Simulation ? "Exports de la simulation" : "Exports de Domenia", Path.Combine(data, FileExportStore.FolderNameFor(mode))));
        }
        if (mode == AppMode.Simulation)
        {
            return roots;
        }
        Add(roots, "Documents", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
        Add(roots, "Bureau", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!string.IsNullOrEmpty(profile))
        {
            Add(roots, "Téléchargements", Path.Combine(profile, "Downloads"));
        }
        return roots;
    }

    private static void Add(List<ShellFileRoot> roots, string label, string? path)
    {
        if (!string.IsNullOrEmpty(path) && Path.IsPathFullyQualified(path))
        {
            roots.Add(new ShellFileRoot(label, path));
        }
    }

    private static string PageArgument(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, GuideArguments);
        var page = BridgeArguments.GetString(values, "page");
        return GuideChapters.IsPageName(page) ? page : throw BridgeArguments.Invalid(FrenchText.Quote("page") + " doit être un nom d’écran.");
    }

    private static ShellGuide Guide(GuideChapter chapter, string? path, bool opened)
    {
        var file = path is null ? chapter.Files[0] : Path.GetFileName(path);
        var message = path is null
            ? "Placez " + chapter.Files[0] + " dans un dossier DOC à côté de Domenia, puis réessayez. En attendant" + FrenchText.Colon + chapter.Text + "."
            : opened
                ? "Le guide s’ouvre. Chapitre de cette page" + FrenchText.Colon + chapter.Chapter.ToString(CultureInfo.InvariantCulture) + ", " + chapter.Title + "."
                : "Guide présent (" + file + "). Chapitre de cette page" + FrenchText.Colon + chapter.Chapter.ToString(CultureInfo.InvariantCulture) + ", " + chapter.Title + ".";
        return new ShellGuide(chapter.Page, chapter.Guide, chapter.GuideTitle, chapter.Chapter, chapter.Title, chapter.Text, file, path is not null, opened, message);
    }

    private static bool OpenDocument(string path)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            return true;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            TechnicalLog.Warning($"Guide non ouvert : aucun lecteur de PDF ({ex.GetType().Name}).");
            return false;
        }
    }

    private static bool OpenFolder(IShellExportStore exports, string? fileName)
    {
        if (exports is not FileExportStore store || store.EnsureFolder() is not string folder)
        {
            return false;
        }
        var file = store.PathOf(fileName);
        try
        {
            var explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
            var start = new ProcessStartInfo(explorer) { UseShellExecute = false, Arguments = file is null ? "\"" + folder + "\"" : "/select,\"" + file + "\"" };
            using var process = Process.Start(start);
            return true;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            TechnicalLog.Warning($"Dossier des exports non ouvert ({ex.GetType().Name}).");
            return false;
        }
    }

    private static async Task<ShellExportResult> SaveAsync(EngineContext context, IShellExportStore exports, IReadOnlyDictionary<string, JsonElement> values, CancellationToken cancellationToken)
    {
        var kind = BridgeArguments.GetString(values, "kind");
        if (kind is not ("csv" or "json"))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir csv ou json.");
        }
        var name = BridgeArguments.GetString(values, "name");
        if (name.Length > 80)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit faire au plus 80 caractères.");
        }
        var text = BridgeArguments.GetOptionalString(values, "text");
        if (text is { Length: > MaxExportText })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("text") + " est trop long pour un export.");
        }
        var local = TimeZoneInfo.ConvertTime(context.Clock.GetUtcNow(), context.Clock.LocalTimeZone).DateTime;
        var fileName = ShellCsv.FileName(name, local, kind);
        byte[] bytes;
        var rows = 0;
        var masked = 0;
        var withheld = ImmutableArray<string>.Empty;
        if (kind == "json")
        {
            if (text is null)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " est obligatoire pour un export JSON.");
            }
            try
            {
                using var parsed = JsonDocument.Parse(text);
            }
            catch (JsonException)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit être un JSON valide.");
            }
            var clean = ShellSecrets.MayHoldSecret(text) ? ShellSecrets.Protect(text) : text;
            masked = string.Equals(clean, text, StringComparison.Ordinal) ? 0 : 1;
            bytes = Utf8.GetBytes(clean);
        }
        else if (text is not null)
        {
            // CSV already built by the page (grid of the kit, neutralized): every line is masked like a journal line.
            var lines = text.Split('\n');
            for (var i = 0; i < lines.Length; i++)
            {
                if (ShellSecrets.MayHoldSecret(lines[i]))
                {
                    var clean = ShellSecrets.Protect(lines[i]);
                    if (!string.Equals(clean, lines[i], StringComparison.Ordinal))
                    {
                        masked++;
                        lines[i] = clean;
                    }
                }
            }
            rows = Math.Max(0, lines.Count(l => l.Trim().Length > 0) - 1);
            bytes = WithBom(string.Join('\n', lines));
        }
        else
        {
            var (headers, table, secret) = ReadTable(values);
            var document = ShellCsv.Build(headers, table, secret);
            rows = document.Rows;
            masked = document.Masked;
            withheld = document.Withheld;
            bytes = WithBom(document.Text);
        }
        string written;
        try
        {
            written = await exports.SaveAsync(fileName, bytes, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export non écrit : {ex.GetType().Name}.");
            throw new DomeniaOperationException(ShellErrors.ExportUnavailable, ShellErrors.ExportUnavailableMessage);
        }
        context.Log.Info($"Export {kind} écrit : {rows.ToString(CultureInfo.InvariantCulture)} ligne(s), {masked.ToString(CultureInfo.InvariantCulture)} valeur(s) masquée(s), stockage {(exports.Persistent ? "disque" : "mémoire")}.");
        var sentence = kind == "json"
            ? "Document exporté dans " + written + "."
            : (rows == 1 ? "1 ligne exportée" : FrenchText.Integer(rows) + " lignes exportées") + " dans " + written + ".";
        if (masked == 1)
        {
            sentence += " 1 valeur ressemblant à un secret a été masquée.";
        }
        else if (masked > 1)
        {
            sentence += " " + FrenchText.Integer(masked) + " valeurs ressemblant à un secret ont été masquées.";
        }
        if (!withheld.IsEmpty)
        {
            sentence += " Colonnes secrètes non exportées" + FrenchText.Colon + string.Join(", ", withheld) + ".";
        }
        if (!exports.Persistent)
        {
            sentence += " Gardé en mémoire pour cette session" + FrenchText.Colon + "rien n’est écrit sur le disque dans ce mode.";
        }
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Export" + FrenchText.Colon + written, Tone.Ok));
        return new ShellExportResult(written, exports.FolderLabel, rows, masked, withheld, exports.Persistent ? "disque" : "mémoire", sentence);
    }

    private static (List<string> Headers, List<IReadOnlyList<string?>> Rows, HashSet<int> Secret) ReadTable(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("headers", out var rawHeaders) || rawHeaders.ValueKind != JsonValueKind.Array || rawHeaders.GetArrayLength() is 0 or > 200
            || rawHeaders.EnumerateArray().Any(h => h.ValueKind != JsonValueKind.String))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("headers") + " doit être une liste de 1 à 200 textes.");
        }
        var headers = rawHeaders.EnumerateArray().Select(h => h.GetString()!).ToList();
        if (!values.TryGetValue("rows", out var rawRows) || rawRows.ValueKind != JsonValueKind.Array || rawRows.GetArrayLength() > 100_000)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("rows") + " doit être une liste de lignes (100 000 au plus).");
        }
        var rows = new List<IReadOnlyList<string?>>(rawRows.GetArrayLength());
        foreach (var row in rawRows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Array || row.GetArrayLength() > headers.Count)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("rows") + " doit contenir des lignes d’au plus autant de cellules que d’en-têtes.");
            }
            rows.Add([.. row.EnumerateArray().Select(Cell)]);
        }
        var secret = new HashSet<int>();
        if (values.TryGetValue("secretColumns", out var rawSecret) && rawSecret.ValueKind != JsonValueKind.Null)
        {
            if (rawSecret.ValueKind != JsonValueKind.Array)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("secretColumns") + " doit être une liste de numéros de colonnes ou null.");
            }
            foreach (var item in rawSecret.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Number || !item.TryGetInt32(out var index) || index < 0 || index >= headers.Count)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("secretColumns") + " doit être une liste de numéros de colonnes ou null.");
                }
                secret.Add(index);
            }
        }
        return (headers, rows, secret);
    }

    /// <summary>UTF-8 bytes with their byte order mark (Excel reads the accents of a CSV only with it).</summary>
    private static byte[] WithBom(string text) => [.. Utf8WithBom.GetPreamble(), .. Utf8WithBom.GetBytes(text)];

    /// <summary>Text of a cell: numbers with a decimal comma, Oui/Non, empty for null; objects refused.</summary>
    private static string? Cell(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.GetRawText().Replace('.', ','),
        JsonValueKind.True => "Oui",
        JsonValueKind.False => "Non",
        JsonValueKind.Null => null,
        _ => throw BridgeArguments.Invalid(FrenchText.Quote("rows") + " : une cellule doit être un texte, un nombre, un booléen ou null."),
    };
}
