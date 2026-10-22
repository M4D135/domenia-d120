using System.Collections.Immutable;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Store;

namespace Domenia.App;

/// <summary>
/// Operations of the shell bound to the host (docs/ops/shell.md): « À propos » facts, title and frame of the window, exports and
/// their folder, embedded file picker (save mode and network shares on request included), guides, team layouts of the boards
/// and the interface policy of the administrator. They need the paths of the application (exe folder, data folder) and the
/// main window, hence this module of Domenia.App, found by the composition like every other one. Their arguments are checked
/// by ShellHostArguments (Domenia.Bridge) and their rules live in Domenia.Core and Domenia.Store (tested there).
/// </summary>
public sealed class ShellHostOperations : IOperationModule
{
    /// <summary>Exports listed at most.</summary>
    public const int ExportListLimit = 50;

    private static readonly UTF8Encoding Utf8WithBom = new(encoderShouldEmitUTF8Identifier: true);
    private static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public string Screen => "shell";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var mode = context.Mode;
        var exports = context.Shared<IShellExportStore>(CreateExports);
        var browser = new LocalFileBrowser(Roots(mode, exports));
        var writer = new LocalFileWriter(browser);
        var guides = new GuideLocator(AppPaths.AppDirectory);
        var about = new Lazy<ShellAbout>(() => LocalFacts.Read(context), LazyThreadSafetyMode.ExecutionAndPublication);
        var policy = new Lazy<ShellPolicy>(() => ReadPolicy(context), LazyThreadSafetyMode.ExecutionAndPublication);
        return
        [
            // LocalRead: registry version keys and the version of winsqlite3.dll, once per session.
            new OperationDefinition("shell.about", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(about.Value);
            }, "À propos de Domenia : version, moteurs et compatibilité du poste, faits locaux seulement."),

            // LocalRead: Domenia.config.json next to the executable, once per session.
            new OperationDefinition("shell.policy", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(policy.Value);
            }, "Règles de l’interface fixées par l’administrateur (UI.AllowExpertProfile de Domenia.config.json)."),

            // Local: title and frame of the main window, nothing written, nothing read.
            new OperationDefinition("shell.window.chrome", OperationClass.Local, (args, _, _) =>
            {
                var request = ShellHostArguments.Chrome(args);
                var applied = WindowChrome.Apply(request.Title, request.WriteActive, mode, request.Dark, request.Caption, request.Text);
                return Task.FromResult<object?>(new { applied });
            }, "Titre et barre de titre de la fenêtre selon l’écran et le thème."),

            // LocalWrite: the exports folder of the data folder (memory only in capture and E2E), never overwritten; or the
            // local place the operator chose in the save mode of the picker, replaced only on « Remplacer ».
            new OperationDefinition("shell.export.save", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var request = ShellHostArguments.Save(args);
                return await SaveAsync(context, exports, writer, request, cancellationToken).ConfigureAwait(false);
            }, "Exporte une liste (CSV) ou un document (JSON) dans le dossier des exports, ou à l’emplacement choisi dans le sélecteur."),

            new OperationDefinition("shell.export.list", OperationClass.LocalRead, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(new ShellExportListing(exports.FolderLabel, exports.Persistent ? "disque" : "mémoire", exports.List(ExportListLimit)));
            }, "Derniers fichiers du dossier des exports."),

            // Local: starts the Explorer on the exports folder of the application; nothing of Domenia is read nor written.
            new OperationDefinition("shell.export.open", OperationClass.Local, (args, _, _) =>
            {
                var fileName = ShellHostArguments.ExportFileName(args);
                return Task.FromResult<object?>(new { opened = OpenFolder(exports, fileName) });
            }, "Ouvre le dossier des exports dans l’Explorateur, sur le fichier indiqué."),

            new OperationDefinition("shell.files.browse", OperationClass.LocalRead, (args, _, _) =>
            {
                var (folder, filter) = ShellHostArguments.Browse(args);
                (exports as FileExportStore)?.EnsureFolder();
                return Task.FromResult<object?>(browser.Browse(folder, filter));
            }, "Sélecteur de fichier intégré : emplacements de départ, puis dossiers locaux (500 entrées au plus)."),

            new OperationDefinition("shell.files.read", OperationClass.LocalRead, (args, _, _) =>
            {
                var (path, kind) = ShellHostArguments.Read(args);
                return Task.FromResult<object?>(browser.Read(path, kind));
            }, "Lit un fichier choisi dans le sélecteur : CSV (séparateur détecté) ou JSON, 1 Mo au plus."),

            // NetworkRead (refused in simulation): a share is listed only on an explicit request, 15 s at most.
            new OperationDefinition("shell.files.share", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var (folder, filter) = ShellHostArguments.Share(args);
                return await browser.BrowseShareAsync(folder, filter, cancellationToken).ConfigureAwait(false);
            }, "Interroge un partage réseau à la demande de l’opérateur (500 entrées, 15 s au plus)."),

            new OperationDefinition("shell.files.shareRead", OperationClass.NetworkRead, async (args, _, cancellationToken) =>
            {
                var (path, kind) = ShellHostArguments.Read(args);
                return await browser.ReadShareAsync(path, kind, cancellationToken).ConfigureAwait(false);
            }, "Lit un fichier d’un dossier partagé déjà interrogé à la demande (1 Mo, 15 s au plus)."),

            new OperationDefinition("shell.guide.info", OperationClass.LocalRead, (args, _, _) =>
            {
                var chapter = GuideChapters.For(ShellHostArguments.Page(args));
                return Task.FromResult<object?>(Guide(chapter, guides.Find(chapter), opened: false));
            }, "Chapitre du guide qui décrit l’écran, et présence du PDF dans un dossier DOC."),

            // Local: starts the PDF reader associated by Windows on a guide delivered with the application.
            new OperationDefinition("shell.guide.open", OperationClass.Local, (args, _, _) =>
            {
                var chapter = GuideChapters.For(ShellHostArguments.Page(args));
                var path = guides.Find(chapter);
                return Task.FromResult<object?>(Guide(chapter, path, opened: path is not null && OpenDocument(path)));
            }, "Ouvre le guide PDF de l’écran avec le lecteur associé."),

            new OperationDefinition("shell.board.team", OperationClass.LocalRead, (args, _, _) =>
            {
                var board = ShellHostArguments.Board(args);
                return Task.FromResult<object?>(TeamLayoutFile.Read(AppPaths.AppDirectory, board));
            }, "Disposition d’équipe d’un tableau (Dashboard.DefaultLayout<Tableau> de Domenia.config.json)."),
        ];
    }

    private static ShellPolicy ReadPolicy(EngineContext context)
    {
        var policy = ShellPolicyFile.Read(AppPaths.AppDirectory);
        if (policy.Problem is not null)
        {
            context.Log.Warning($"Règles de l’interface : Domenia.config.json non utilisé ({policy.Problem}), valeurs par défaut.");
        }
        else if (!policy.ExpertAllowed)
        {
            context.Log.Info("Règles de l’interface : profil Expert masqué par l’administrateur (UI.AllowExpertProfile).");
        }
        return policy;
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
            TechnicalLog.Warning($"Guide non ouvert : aucun lecteur de PDF ({ex.GetType().Name}).");
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

    private static async Task<ShellExportResult> SaveAsync(EngineContext context, IShellExportStore exports, LocalFileWriter writer, ShellSaveRequest request, CancellationToken cancellationToken)
    {
        var local = TimeZoneInfo.ConvertTime(context.Clock.GetUtcNow(), context.Clock.LocalTimeZone).DateTime;
        var fileName = ShellCsv.FileName(request.Name, local, request.Kind);
        byte[] bytes;
        var rows = 0;
        var masked = 0;
        var withheld = ImmutableArray<string>.Empty;
        if (request.Kind == "json")
        {
            var text = request.Text!;
            var clean = ShellSecrets.MayHoldSecret(text) ? ShellSecrets.Protect(text) : text;
            masked = string.Equals(clean, text, StringComparison.Ordinal) ? 0 : 1;
            bytes = Utf8.GetBytes(clean);
        }
        else
        {
            // A CSV built by the page (grid of the kit) is read again and written by the rules of the engine: every cell
            // neutralized and masked one by one, rows counted as records (a cell may hold a line break).
            var document = request.Text is string text
                ? ShellCsv.Rebuild(text) ?? throw new DomeniaOperationException(ShellErrors.ExportTooLarge, ShellErrors.ExportTooLargeMessage)
                : ShellCsv.Build(request.Headers!, request.Rows!, request.SecretColumns);
            rows = document.Rows;
            masked = document.Masked;
            withheld = document.Withheld;
            bytes = WithBom(document.Text);
        }
        string written;
        string folderLabel;
        string stored;
        try
        {
            if (request.Target is ShellSaveTarget target)
            {
                var path = await writer.SaveAsync(target, request.Kind, bytes, cancellationToken).ConfigureAwait(false);
                written = Path.GetFileName(path);
                folderLabel = writer.LabelOf(target.Folder);
                stored = "disque";
            }
            else
            {
                written = await exports.SaveAsync(fileName, bytes, cancellationToken).ConfigureAwait(false);
                folderLabel = exports.FolderLabel;
                stored = exports.Persistent ? "disque" : "mémoire";
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            context.Log.Warning($"Export non écrit : {ex.GetType().Name}.");
            throw new DomeniaOperationException(ShellErrors.ExportUnavailable, ShellErrors.ExportUnavailableMessage);
        }
        var place = request.Target is null ? "dossier des exports" : (request.Target.Replace is null ? "emplacement choisi" : "fichier remplacé");
        context.Log.Info($"Export {request.Kind} écrit : {rows.ToString(CultureInfo.InvariantCulture)} ligne(s), {masked.ToString(CultureInfo.InvariantCulture)} valeur(s) masquée(s), {place}, stockage {stored}.");
        var sentence = request.Kind == "json"
            ? "Document exporté dans " + written + "."
            : (rows == 1 ? "1 ligne exportée" : FrenchText.Integer(rows) + " lignes exportées") + " dans " + written + ".";
        if (request.Target?.Replace is not null)
        {
            sentence += " Le fichier précédent a été remplacé, comme vous l’avez demandé.";
        }
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
        if (stored == "mémoire")
        {
            sentence += " Gardé en mémoire pour cette session" + FrenchText.Colon + "rien n’est écrit sur le disque dans ce mode.";
        }
        context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), "Export" + FrenchText.Colon + written, Tone.Ok));
        return new ShellExportResult(written, folderLabel, rows, masked, withheld, stored, sentence);
    }

    /// <summary>UTF-8 bytes with their byte order mark (Excel reads the accents of a CSV only with it).</summary>
    private static byte[] WithBom(string text) => [.. Utf8WithBom.GetPreamble(), .. Utf8WithBom.GetBytes(text)];
}
