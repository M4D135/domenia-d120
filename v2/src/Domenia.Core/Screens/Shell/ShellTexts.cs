using System.Collections.Frozen;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Domenia.Core;

/// <summary>Fixed operator texts and small pure rules of the shell (docs/ops/shell.md).</summary>
public static class ShellTexts
{
    /// <summary>Longest page part of a window title sent by the page.</summary>
    public const int MaxTitleLength = 160;

    /// <summary>Mark of the window title while directory writes are admitted (Domenia 1 Get-DomeniaPageTitle).</summary>
    public const string WriteActiveMark = "[ÉCRITURE AD ACTIVE]";

    /// <summary>
    /// Text of a counter badge (Domenia 1 Get-DomeniaCounterText): nothing for zero, the number up to 99, then « 99+ ».
    /// A negative value is shown as zero.
    /// </summary>
    public static string Counter(int value) => value <= 0 ? "" : value > 99 ? "99+" : value.ToString(CultureInfo.InvariantCulture);

    /// <summary>
    /// Window title (Domenia 1 TRV-050): « Fiche · Camille Martin — Domenia — Simulation », with the write mark in directory
    /// mode while writes are admitted. The page part is reduced to one line of printable characters (no control
    /// character, no line break, spaces collapsed) and bounded; an empty page part leaves the base title alone.
    /// </summary>
    public static string WindowTitle(string? page, string baseTitle, bool writeActive, AppMode mode)
    {
        ArgumentNullException.ThrowIfNull(baseTitle);
        var clean = FlatLine(page, MaxTitleLength);
        var title = clean.Length == 0 ? baseTitle : clean + " — " + baseTitle;
        return writeActive && mode == AppMode.Directory ? title + "  " + WriteActiveMark : title;
    }

    /// <summary>One line of printable text, spaces collapsed, cut with an ellipsis beyond <paramref name="max"/> characters.</summary>
    public static string FlatLine(string? text, int max)
    {
        if (string.IsNullOrWhiteSpace(text) || max <= 0)
        {
            return "";
        }
        var builder = new StringBuilder(Math.Min(text.Length, max + 1));
        var space = false;
        foreach (var c in text)
        {
            if (char.IsControl(c) || char.IsWhiteSpace(c))
            {
                space = builder.Length > 0;
                continue;
            }
            if (space)
            {
                builder.Append(' ');
                space = false;
            }
            builder.Append(c);
        }
        var flat = builder.ToString();
        return flat.Length <= max ? flat : flat[..(max - 1)].TrimEnd() + "…";
    }

    /// <summary>Sentence of the activity button (Domenia 1 TRV-049).</summary>
    public static string ActivityDetail(TaskCounters tasks, ShellReceiptCounts receipts)
    {
        ArgumentNullException.ThrowIfNull(tasks);
        ArgumentNullException.ThrowIfNull(receipts);
        var parts = new List<string>(3);
        if (tasks.Running > 0)
        {
            parts.Add(FrenchText.Count(tasks.Running, "lecture en cours", "lectures en cours"));
        }
        if (tasks.Queued > 0)
        {
            parts.Add(FrenchText.Count(tasks.Queued, "lecture en attente", "lectures en attente"));
        }
        var work = parts.Count == 0 ? "Aucune opération en cours" : string.Join(", ", parts);
        var check = !receipts.Available
            ? "reçus d’écriture illisibles pour l’instant"
            : receipts.Pending == 0
                ? "aucun reçu à vérifier"
                : FrenchText.Count(receipts.Pending, "reçu à vérifier", "reçus à vérifier");
        return work + " ; " + check + ".";
    }
}

/// <summary>Chapter of the user guides describing a screen (Domenia 1 Get-DomeniaHelpGuideChapter, TRV-005).</summary>
public sealed record GuideChapter(string Page, string Guide, string GuideTitle, int Chapter, string Title)
{
    /// <summary>« Guide du technicien, chapitre 5 : Voir et explorer le parc depuis Accueil ».</summary>
    public string Text => GuideTitle + ", chapitre " + Chapter.ToString(CultureInfo.InvariantCulture) + FrenchText.Colon + Title;

    /// <summary>File names looked for in a DOC folder, the guide of Domenia 2 first.</summary>
    public IReadOnlyList<string> Files => ["Domenia-2-Guide-" + Guide + ".pdf", "Domenia-1.0-Guide-" + Guide + ".pdf"];
}

/// <summary>The screens of Domenia 2 and the chapter of the guides that describes each of them.</summary>
public static class GuideChapters
{
    private static readonly FrozenDictionary<string, (string Guide, int Chapter, string Title)> Map = new Dictionary<string, (string, int, string)>(StringComparer.Ordinal)
    {
        ["accueil"] = ("technicien", 5, "Voir et explorer le parc depuis Accueil"),
        ["rechercher"] = ("technicien", 1, "Trouver une personne ou un poste"),
        ["fiche"] = ("administrateur", 4, "Fiches des objets"),
        ["comptes"] = ("administrateur", 13, "Comptes et droits"),
        ["relations"] = ("administrateur", 12, "Relations utilisateur et poste"),
        ["poste"] = ("technicien", 2, "Ouvrir la fiche du poste et agir dessus"),
        ["assistance"] = ("technicien", 8, "En cas de problème"),
        ["requetes"] = ("administrateur", 8, "Tableau de bord et Atelier de requêtes"),
        ["audit"] = ("administrateur", 19, "Règles de sécurité"),
        ["schema"] = ("administrateur", 15, "Architecture"),
        ["synchro"] = ("administrateur", 18, "Base autonome"),
        ["machine"] = ("administrateur", 5, "Outils du poste et compte des opérations poste"),
        ["operations"] = ("administrateur", 20, "Journaux et diagnostic"),
        ["parametres"] = ("administrateur", 17, "Réglages et configuration"),
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Chapter of a screen; an unknown screen points to « Repères », the map of the window.</summary>
    public static GuideChapter For(string? page)
    {
        var key = (page ?? "").Trim();
        var (guide, chapter, title) = Map.TryGetValue(key, out var known) ? known : ("technicien", 9, "Repères");
        var guideTitle = guide == "administrateur" ? "Guide de l’administrateur" : "Guide du technicien";
        return new GuideChapter(key, guide, guideTitle, chapter, title);
    }

    /// <summary>A screen name accepted from the page: lower case letters, digits and dashes, 30 characters at most.</summary>
    public static bool IsPageName(string? page) =>
        !string.IsNullOrEmpty(page) && page.Length <= 30 && char.IsAsciiLetterLower(page[0]) && page.All(c => char.IsAsciiLetterLower(c) || char.IsAsciiDigit(c) || c == '-');
}

/// <summary>Team layout of a board read from Domenia.config.json (Domenia 1 Dashboard.DefaultLayout&lt;Board&gt;, TRV-311).</summary>
/// <param name="Text">JSON text of the layout (exported document or plain list), handed to the page that cleans it.</param>
/// <param name="Problem">Short reason when the configuration holds a value that cannot be used; never its content.</param>
public sealed record ShellTeamLayout(string Board, string Key, string? Text, string? Problem);

/// <summary>Pure reading of the team layouts of the configuration file.</summary>
public static class TeamLayouts
{
    /// <summary>Longest layout text accepted (the document format of Domenia 1 is a few kilobytes).</summary>
    public const int MaxTextLength = 262_144;

    /// <summary>Board names: one upper camel case word (« Computer », « Fleet », « Software », « Interface »).</summary>
    public static bool IsBoardName(string? board) =>
        !string.IsNullOrEmpty(board) && board.Length <= 32 && char.IsAsciiLetterUpper(board[0]) && board.All(char.IsAsciiLetterOrDigit);

    /// <summary>
    /// Value of Dashboard.DefaultLayout&lt;Board&gt; (section and key names without case, as Domenia 1): a JSON string holding the
    /// layout, or the layout itself (array or object), returned as text. Absent: null text, no problem.
    /// </summary>
    public static ShellTeamLayout Parse(ReadOnlySpan<byte> utf8, string board)
    {
        if (!IsBoardName(board))
        {
            throw new ArgumentException("Invalid board name.", nameof(board));
        }
        var key = "Dashboard.DefaultLayout" + board;
        if (utf8.IsEmpty)
        {
            return new ShellTeamLayout(board, key, null, null);
        }
        if (utf8.Length > LegacyConfiguration.MaxBytes)
        {
            return new ShellTeamLayout(board, key, null, "fichier de plus de 1 Mo");
        }
        if (utf8.Length >= 3 && utf8[0] == 0xEF && utf8[1] == 0xBB && utf8[2] == 0xBF)
        {
            utf8 = utf8[3..];
        }
        try
        {
            using var document = JsonDocument.Parse(utf8.ToArray());
            if (document.RootElement.ValueKind != JsonValueKind.Object
                || !TryGet(document.RootElement, "Dashboard", out var section)
                || section.ValueKind != JsonValueKind.Object
                || !TryGet(section, "DefaultLayout" + board, out var value))
            {
                return new ShellTeamLayout(board, key, null, null);
            }
            var text = value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Array or JsonValueKind.Object => value.GetRawText(),
                _ => null,
            };
            if (string.IsNullOrWhiteSpace(text))
            {
                return new ShellTeamLayout(board, key, null, value.ValueKind == JsonValueKind.Null ? null : "valeur ni texte ni liste");
            }
            return text.Length > MaxTextLength
                ? new ShellTeamLayout(board, key, null, "disposition de plus de 256 Kio")
                : new ShellTeamLayout(board, key, text, null);
        }
        catch (JsonException)
        {
            return new ShellTeamLayout(board, key, null, "JSON illisible");
        }
    }

    private static bool TryGet(JsonElement element, string name, out JsonElement value)
    {
        foreach (var property in element.EnumerateObject())
        {
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                value = property.Value;
                return true;
            }
        }
        value = default;
        return false;
    }
}
