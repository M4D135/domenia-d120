using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>Title and frame asked by the page (shell.window.chrome).</summary>
public sealed record ShellChromeRequest(string? Title, bool Dark, bool WriteActive, string? Caption, string? Text);

/// <summary>
/// An export asked by the page (shell.export.save): a CSV table (headers, rows, secret columns), a CSV text built by the page
/// or a JSON document, written in the exports folder or, in the save mode of the picker, at the place the operator chose.
/// </summary>
public sealed record ShellSaveRequest(
    string Kind,
    string Name,
    string? Text,
    IReadOnlyList<string>? Headers,
    IReadOnlyList<IReadOnlyList<string?>>? Rows,
    IReadOnlySet<int> SecretColumns,
    ShellSaveTarget? Target);

/// <summary>
/// Validation of the arguments of the host operations of the shell (docs/ops/shell.md § 3), apart from the host itself so
/// that the rules are tested without a window (ShellHostOperations of Domenia.App only calls these). Every refusal is an
/// argument.invalid with a French sentence; nothing is read nor written here.
/// </summary>
public static class ShellHostArguments
{
    /// <summary>Longest text of a CSV or JSON export sent by the page.</summary>
    public const int MaxExportText = 900_000;

    /// <summary>Longest name of an export (the subject of its file name).</summary>
    public const int MaxExportName = 80;

    /// <summary>Longest path accepted from the page.</summary>
    public const int MaxPath = 1024;

    private static readonly string[] ChromeNames = ["title", "dark", "writeActive", "caption", "text"];
    private static readonly string[] SaveNames = ["kind", "name", "headers", "rows", "secretColumns", "text", "target"];
    private static readonly string[] TargetNames = ["folder", "fileName", "replace"];
    private static readonly string[] SignatureNames = ["size", "at"];
    private static readonly string[] OpenNames = ["fileName"];
    private static readonly string[] BrowseNames = ["folder", "filter"];
    private static readonly string[] ReadNames = ["path", "kind"];
    private static readonly string[] PageNames = ["page"];
    private static readonly string[] BoardNames = ["board"];

    public static ShellChromeRequest Chrome(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, ChromeNames);
        var title = BridgeArguments.GetOptionalString(values, "title");
        if (title is { Length: > ShellTexts.MaxTitleLength * 2 })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("title") + " doit faire au plus " + FrenchText.Integer(ShellTexts.MaxTitleLength * 2) + " caractères.");
        }
        var caption = BridgeArguments.GetOptionalString(values, "caption");
        var text = BridgeArguments.GetOptionalString(values, "text");
        if ((caption is not null && ShellTexts.ColorRef(caption) is null) || (text is not null && ShellTexts.ColorRef(text) is null))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("caption") + " et " + FrenchText.Quote("text") + " doivent être des couleurs #rrggbb ou null.");
        }
        return new ShellChromeRequest(title, BridgeArguments.GetBoolean(values, "dark"), BridgeArguments.GetBoolean(values, "writeActive"), caption, text);
    }

    public static ShellSaveRequest Save(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, SaveNames);
        var kind = BridgeArguments.GetString(values, "kind");
        if (kind is not ("csv" or "json"))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir csv ou json.");
        }
        var name = BridgeArguments.GetString(values, "name");
        if (name.Length > MaxExportName)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit faire au plus " + FrenchText.Integer(MaxExportName) + " caractères.");
        }
        var text = BridgeArguments.GetOptionalString(values, "text");
        if (text is { Length: > MaxExportText })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("text") + " est trop long pour un export.");
        }
        var target = Target(values, kind);
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
            return new ShellSaveRequest(kind, name, text, null, null, new HashSet<int>(), target);
        }
        if (text is not null)
        {
            if (values.ContainsKey("headers") || values.ContainsKey("rows"))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " ne se combine pas avec " + FrenchText.Quote("headers") + " et " + FrenchText.Quote("rows") + ".");
            }
            return new ShellSaveRequest(kind, name, text, null, null, new HashSet<int>(), target);
        }
        var (headers, rows, secret) = Table(values);
        return new ShellSaveRequest(kind, name, null, headers, rows, secret, target);
    }

    /// <summary>Name of an export the page may give back (shell.export.open), or null for the folder itself.</summary>
    public static string? ExportFileName(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, OpenNames);
        var fileName = BridgeArguments.GetOptionalString(values, "fileName");
        if (fileName is not null && !ShellExportNames.IsExportName(fileName))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit être le nom d’un export de Domenia.");
        }
        return fileName;
    }

    /// <summary>Folder (null: starting places) and filter of the embedded file picker.</summary>
    public static (string? Folder, string Filter) Browse(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, BrowseNames);
        var folder = BridgeArguments.GetOptionalString(values, "folder");
        var filter = BridgeArguments.GetString(values, "filter");
        if (filter is not ("csv" or "json" or "all"))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("filter") + " doit valoir csv, json ou all.");
        }
        if (folder is { Length: > MaxPath })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("folder") + " doit faire au plus 1" + FrenchText.ThousandsSeparator + "024 caractères.");
        }
        return (folder, filter);
    }

    /// <summary>Folder of a network share listed on request (shell.files.share): a folder path is required.</summary>
    public static (string Folder, string Filter) Share(JsonElement args)
    {
        var (folder, filter) = Browse(args);
        return string.IsNullOrWhiteSpace(folder)
            ? throw BridgeArguments.Invalid(FrenchText.Quote("folder") + " est obligatoire pour interroger un partage.")
            : (folder, filter);
    }

    /// <summary>File and kind of an import (shell.files.read, shell.files.shareRead).</summary>
    public static (string Path, string Kind) Read(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, ReadNames);
        var path = BridgeArguments.GetString(values, "path");
        var kind = BridgeArguments.GetString(values, "kind");
        if (kind is not ("csv" or "json"))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir csv ou json.");
        }
        if (path.Length > MaxPath)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("path") + " doit faire au plus 1" + FrenchText.ThousandsSeparator + "024 caractères.");
        }
        return (path, kind);
    }

    /// <summary>Screen name of a guide request.</summary>
    public static string Page(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, PageNames);
        var page = BridgeArguments.GetString(values, "page");
        return GuideChapters.IsPageName(page) ? page : throw BridgeArguments.Invalid(FrenchText.Quote("page") + " doit être un nom d’écran.");
    }

    /// <summary>Board name of a team layout request (« Computer », « Interface »).</summary>
    public static string Board(JsonElement args)
    {
        var values = BridgeArguments.ReadObject(args, BoardNames);
        var board = BridgeArguments.GetString(values, "board");
        return TeamLayouts.IsBoardName(board)
            ? board
            : throw BridgeArguments.Invalid(FrenchText.Quote("board") + " doit être un nom de tableau (Computer, Fleet, Software, Interface…).");
    }

    private static ShellSaveTarget? Target(IReadOnlyDictionary<string, JsonElement> values, string kind)
    {
        if (!values.TryGetValue("target", out var raw) || raw.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (raw.ValueKind != JsonValueKind.Object)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("target") + " doit être un objet ou null.");
        }
        var target = BridgeArguments.ReadObject(raw, TargetNames);
        var folder = BridgeArguments.GetString(target, "folder");
        var fileName = BridgeArguments.GetString(target, "fileName");
        if (folder.Length > MaxPath || !Path.IsPathFullyQualified(folder))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("folder") + " doit être un chemin complet de 1" + FrenchText.ThousandsSeparator + "024 caractères au plus.");
        }
        if (!ShellFileNames.IsSafe(fileName, kind))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit être un nom de fichier ." + kind + " sans dossier ni caractère interdit (120 caractères au plus).");
        }
        ShellFileSignature? replace = null;
        if (target.TryGetValue("replace", out var rawReplace) && rawReplace.ValueKind != JsonValueKind.Null)
        {
            if (rawReplace.ValueKind != JsonValueKind.Object)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("replace") + " doit être un objet { size, at } ou null.");
            }
            var signature = BridgeArguments.ReadObject(rawReplace, SignatureNames);
            var size = signature.TryGetValue("size", out var rawSize) && rawSize.ValueKind == JsonValueKind.Number && rawSize.TryGetInt64(out var bytes) && bytes >= 0
                ? bytes
                : throw BridgeArguments.Invalid(FrenchText.Quote("size") + " doit être une taille en octets.");
            var atText = BridgeArguments.GetString(signature, "at");
            if (!DateTimeOffset.TryParse(atText, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var at))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("at") + " doit être une date ISO 8601.");
            }
            replace = new ShellFileSignature(size, at);
        }
        return new ShellSaveTarget(folder, fileName, replace);
    }

    private static (List<string> Headers, List<IReadOnlyList<string?>> Rows, HashSet<int> Secret) Table(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("headers", out var rawHeaders) || rawHeaders.ValueKind != JsonValueKind.Array || rawHeaders.GetArrayLength() is 0 or > 200
            || rawHeaders.EnumerateArray().Any(h => h.ValueKind != JsonValueKind.String))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("headers") + " doit être une liste de 1 à 200 textes.");
        }
        var headers = rawHeaders.EnumerateArray().Select(h => h.GetString()!).ToList();
        if (!values.TryGetValue("rows", out var rawRows) || rawRows.ValueKind != JsonValueKind.Array || rawRows.GetArrayLength() > 100_000)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("rows") + " doit être une liste de lignes (100" + FrenchText.ThousandsSeparator + "000 au plus).");
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

    /// <summary>
    /// Text of a cell: numbers with a decimal comma (written as they are by the CSV rules, a negative number keeps its sign),
    /// Oui/Non, empty for null; objects refused.
    /// </summary>
    public static string? Cell(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => value.GetString(),
        JsonValueKind.Number => value.GetRawText().Replace('.', ','),
        JsonValueKind.True => "Oui",
        JsonValueKind.False => "Non",
        JsonValueKind.Null => null,
        _ => throw BridgeArguments.Invalid(FrenchText.Quote("rows") + FrenchText.Colon + "une cellule doit être un texte, un nombre, un booléen ou null."),
    };
}
