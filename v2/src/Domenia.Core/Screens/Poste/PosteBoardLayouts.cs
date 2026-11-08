using System.Collections.Immutable;
using System.Text.Json;
using System.Text.Json.Serialization;
using Domenia.Core.Accueil;

namespace Domenia.Core.Poste;

public sealed record PosteLayoutDefinition(string Key, string Title, string Visual, string Size, bool Default = true, FleetWidgetSource Source = FleetWidgetSource.Builtin)
{
    public ImmutableArray<string> Visuals { get; init; } = [];
}
public sealed record PosteLayoutView(string Board, bool Stored, bool Valid, ImmutableArray<FleetLayoutItem> Items,
    ImmutableArray<PosteLayoutDefinition> Catalog, string? Reason = null)
{
    public string ChoiceToken { get; init; } = "";
    public ImmutableArray<BoardLayoutVersion> History { get; init; } = [];
}

/// <summary>Widgets backed by local snapshots and exact profile probe versions. No query is inferred from a library.</summary>
public static class PosteBoardLayouts
{
    public static JsonSerializerOptions Json { get; } = CreateJson();
    public const int MaxItems = 64;
    public static ImmutableArray<PosteLayoutDefinition> Computer { get; } =
    [
        new("computer.health", "Santé du poste", "HealthSummary", "L"),
        new("computer.identity", "Identité du poste", "Sheet", "M"),
        new("computer.adaccount", "Compte machine", "Sheet", "M"),
        new("computer.memory.usage", "Mémoire utilisée", "Gauge", "S"),
        new("computer.cpu.load", "Charge du processeur", "Gauge", "S"),
        new("computer.battery", "Batterie", "Gauge", "S"),
        new("computer.disk.system", "Disque système", "Pie", "M"),
        new("computer.disk.volumes", "Autres volumes", "Bar", "M"),
        new("computer.services", "Services Windows", "Pie", "M"),
        new("computer.processes", "Processus les plus gourmands", "Bar", "L"),
        new("computer.events", "Erreurs système par source", "Bar", "M"),
        new("computer.status", "État de protection", "Checklist", "M"),
        new("computer.services.stopped", "Services automatiques arrêtés", "Kpi", "S"),
        new("computer.devices", "Périphériques en erreur", "Kpi", "S"),
        new("computer.attention", "Points d’attention", "List", "L", false),
        new("computer.os", "Système", "Kpi", "S", false),
        new("computer.model", "Modèle", "Kpi", "S", false),
        new("computer.cpu", "Processeur", "Kpi", "S", false),
        new("computer.memory", "Mémoire installée", "Kpi", "S", false),
        new("computer.uptime", "En service depuis", "Kpi", "S", false),
        new("computer.user", "Utilisateur connecté", "Kpi", "S", false),
        new("computer.ip", "Adresse IP", "Kpi", "S", false),
        new("computer.domain", "Domaine", "Kpi", "S", false),
        new("computer.ad.password", "Mot de passe machine", "Kpi", "S", false),
        new("computer.ad.lastlogon", "Dernière connexion au domaine", "Kpi", "S", false),
        new("computer.ad.account", "Compte ordinateur", "Kpi", "S", false),
        new("computer.ad.ou", "Unité d’organisation", "Kpi", "S", false),
        new("computer.ad.laps", "Mot de passe LAPS", "Kpi", "S", false),
        new("computer.ad.managedby", "Géré par", "Kpi", "S", false),
        new("computer.ad.clock", "Horloge du poste", "Kpi", "S", false),
        new("computer.antivirus", "Antivirus", "Kpi", "S", false),
        new("computer.firewall", "Pare-feu", "Kpi", "S", false),
        new("computer.bitlocker", "BitLocker", "Kpi", "S", false),
        new("computer.secureboot", "Démarrage sécurisé", "Kpi", "S", false),
        new("computer.updates", "Mises à jour", "Kpi", "S", false),
        new("computer.wsus", "Windows Update", "Kpi", "S", false),
        new("computer.reboot", "Redémarrage en attente", "Kpi", "S", false),
        new("computer.drivers", "Pilotes non signés", "Kpi", "S", false),
        new("computer.admins", "Administrateurs locaux", "Kpi", "S", false),
        new("computer.sessions", "Sessions et comptes locaux", "Kpi", "S", false),
        new("computer.autostart", "Démarrage automatique", "Kpi", "S", false),
        new("computer.shares", "Partages", "Kpi", "S", false),
        new("computer.printers", "Imprimantes", "Kpi", "S", false),
        new("computer.display", "Affichage", "Kpi", "S", false),
        new("computer.physicaldisk", "Disques physiques", "Kpi", "S", false),
        new("computer.certificates", "Certificats machine", "Kpi", "S", false),
        new("computer.hotfix", "Dernier correctif", "Kpi", "S", false),
    ];
    public static ImmutableArray<PosteLayoutDefinition> Software { get; } =
    [
        new("software.count", "Logiciels", "Kpi", "S"), new("software.size", "Taille déclarée", "Kpi", "S"),
        new("software.recent", "Installés ces 30 jours", "Kpi", "S"), new("software.multiversion", "En plusieurs versions", "Kpi", "S"),
        new("software.duplicates", "Installés en double", "Kpi", "S"), new("software.nopublisher", "Sans éditeur déclaré", "Kpi", "S"),
        new("software.runtime", "Composants d’exécution", "Kpi", "S"), new("software.browsers", "Navigateurs", "Kpi", "S"),
        new("software.publishers", "Éditeurs", "Pie", "M"), new("software.architecture", "Architecture", "Pie", "M"),
        new("software.scope", "Portée d’installation", "Pie", "M"), new("software.largest", "Plus gros logiciels", "Bar", "L"),
    ];

    public static ImmutableArray<PosteLayoutDefinition> Catalog(string board, PersonalProbeSnapshot? personal = null) => [.. (board switch
    {
        "Computer" => Computer.AddRange(Domenia.Core.Accueil.ProbeCatalog.All.Select(p => new PosteLayoutDefinition(p.Id, p.Name, "Table", "L", false, FleetWidgetSource.Probe)))
            .AddRange((personal?.Entries ?? []).Select(p => new PosteLayoutDefinition(p.Key, p.Definition.Name + " · personnelle · " + p.Key[7..15], "Table", "L", false, FleetWidgetSource.Probe))),
        "Software" => Software, _ => throw new InvalidDataException("Tableau de poste inconnu."),
    }).Select(d => d with { Visuals = AllowedVisuals(d) })];

    private static ImmutableArray<string> AllowedVisuals(PosteLayoutDefinition d) => d.Key == "computer.disk.volumes" ? ["Bar", "Column", "Text", "Kpi"] : d.Source switch
    {
        FleetWidgetSource.Probe => ["Table", "Kpi", "Text"],
        FleetWidgetSource.Query => ["Verdict", "Text"],
        _ => d.Visual switch
        {
            "HealthSummary" => ["HealthSummary", "Health", "Kpi"], "Sheet" => ["Sheet", "Text"],
            "Checklist" => ["Checklist", "Sheet", "Text"], "Gauge" => ["Gauge", "Kpi", "Text"],
            "Pie" or "Bar" => ["Pie", "Bar", "Column", "Text", "Kpi"], "List" => ["List"], _ => ["Kpi", "Text"],
        },
    };
    public static string PreferenceKey(string board) => board switch
    {
        "Computer" => "poste.computerLayout", "Software" => "poste.softwareLayout", _ => throw new InvalidDataException("Tableau de poste inconnu."),
    };
    public static string EvidenceKey(string board) => PreferenceKey(board) + "Migration";
    public static bool HasChoice(IPreferenceStore store, string board) => store.TryGet(PreferenceKey(board), out _) || store.TryGet(EvidenceKey(board), out _);
    public static ImmutableArray<FleetLayoutItem> Defaults(string board) => [.. Catalog(board).Where(d => d.Default).Select(d =>
        new FleetLayoutItem("b-" + d.Key, FleetWidgetSource.Builtin, d.Key, d.Visual, d.Size, null, false, ""))];

    public static ImmutableArray<FleetLayoutItem> Normalize(string board, IReadOnlyList<FleetLayoutItem> items) => Normalize(board, items, false);

    private static ImmutableArray<FleetLayoutItem> Normalize(string board, IReadOnlyList<FleetLayoutItem> items, bool unboundQueries)
    {
        var catalog = Catalog(board).ToDictionary(d => (d.Source, d.Key));
        if (items.Count > MaxItems) { throw new InvalidDataException("Au plus 64 widgets par tableau ; aucun élément tronqué."); }
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var result = ImmutableArray.CreateBuilder<FleetLayoutItem>();
        foreach (var item in items)
        {
            if (item is null || item.Key is null) { throw new InvalidDataException("Widget absent."); }
            var query = board == "Computer" && item.Source == FleetWidgetSource.Query && item.Key.Length is > 0 and <= 80
                && item.Key.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.')
                && (unboundQueries || BoardQueryBindings.Valid(item.QueryBinding, item.Key));
            var personal = board == "Computer" && item.Source == FleetWidgetSource.Probe && PersonalProbeCatalog.IsKey(item.Key);
            // A removed profile definition leaves its card visible for diagnosis. Saving, restoring and collecting
            // separately require the exact definition; a cached value never supplies a hidden executable declaration.
            var definition = personal ? new PosteLayoutDefinition(item.Key, "Sonde personnelle", "Table", "L", false, FleetWidgetSource.Probe) { Visuals = ["Table", "Kpi", "Text"] }
                : query ? new PosteLayoutDefinition(item.Key, item.QueryBinding?.Name ?? "Requête enregistrée", "Verdict", "M", false, FleetWidgetSource.Query) { Visuals = ["Verdict", "Text"] }
                : catalog.GetValueOrDefault((item.Source, item.Key));
            if (definition is null)
            { throw new InvalidDataException("La disposition contient un widget sans représentation dans cet écran ; aucune importation partielle."); }
            if (item.Id is not { Length: > 0 and <= 64 } || !item.Id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') || !ids.Add(item.Id))
            { throw new InvalidDataException("Identifiant de widget absent, ambigu ou dupliqué."); }
            if (item.Title is { Length: > 80 } || item.Title?.Any(char.IsControl) == true || item.Group is { Length: > 80 } || item.Group?.Any(char.IsControl) == true
                || item.Height is not (null or "S" or "M" or "L"))
            { throw new InvalidDataException("Titre ou groupe de widget hors limites."); }
            result.Add(item with { Visual = definition.Visuals.Contains(item.Visual, StringComparer.Ordinal) ? item.Visual : definition.Visual, Size = item.Size is "S" or "M" or "L" ? item.Size : definition.Size, Group = item.Group ?? "" });
        }
        return result.ToImmutable();
    }

    public static PosteLayoutView Read(IPreferenceStore preferences, string board) =>
        View(board, preferences.TryGet(PreferenceKey(board), out var value) ? value : null, board == "Computer" ? ProfileProbeCatalog.Read(preferences) : null);

    public static async Task<PosteLayoutView> ReadLatestAsync(IPreferenceStore preferences, string board, CancellationToken token)
    {
        var personal = board == "Computer" ? await ProfileProbeCatalog.ReadAsync(preferences, token).ConfigureAwait(false) : null;
        var value = preferences is IAtomicPreferenceStore atomic ? await atomic.ReadLatestAsync(PreferenceKey(board), token).ConfigureAwait(false)
            : preferences.TryGet(PreferenceKey(board), out var existing) ? existing : (JsonElement?)null;
        return View(board, value, personal);
    }

    public static void ValidateStoredLayout(string board, JsonElement value) =>
        _ = BoardLayoutHistory.Read(value, Defaults(board), items => Normalize(board, items));

    private static PosteLayoutView View(string board, JsonElement? value, PersonalProbeSnapshot? personal = null)
    {
        var catalog = Catalog(board, personal);
        try
        {
            var state = BoardLayoutHistory.Read(value, Defaults(board), items => Normalize(board, items));
            return new(board, state.Stored, true, state.Items, catalog) { ChoiceToken = state.ChoiceToken, History = state.History };
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException)
        { return new(board, value is not null, false, [], catalog, "Disposition ou historique incompatible conservé. Aucun remplacement automatique.") { ChoiceToken = BoardLayoutHistory.ChoiceToken(value) }; }
    }

    public static async Task<PosteLayoutView> SaveAsync(IPreferenceStore preferences, string board, IReadOnlyList<FleetLayoutItem> items,
        CancellationToken token, string? expectedChoiceToken = null, DateTimeOffset? now = null, Func<CancellationToken, IDisposable>? qualify = null)
    {
        token.ThrowIfCancellationRequested();
        ArgumentNullException.ThrowIfNull(items);
        items = Normalize(board, items);
        if (preferences is not IAtomicPreferenceStore atomic) throw new InvalidDataException("Enregistrement atomique de la disposition indisponible.");
        var personal = board == "Computer" ? await ProfileProbeCatalog.ReadAsync(preferences, token).ConfigureAwait(false) : null;
        RequireDefinitions(items, personal);
        IDisposable? sourceLease = null;
        try
        {
            var saved = await atomic.UpdateAsync(PreferenceKey(board), current =>
            {
                BoardLayoutHistory.RequireChoice(current, expectedChoiceToken);
                sourceLease = qualify?.Invoke(token);
                return Next(current, board, items, now ?? DateTimeOffset.UtcNow);
            }, token).ConfigureAwait(false);
            return View(board, saved, personal);
        }
        finally { sourceLease?.Dispose(); }
    }

    public static async Task<PosteLayoutView> RestoreAsync(IPreferenceStore preferences, string board, string versionId,
        string expectedChoiceToken, DateTimeOffset now, CancellationToken token)
    {
        if (preferences is not IAtomicPreferenceStore atomic) throw new InvalidDataException("Restauration atomique indisponible.");
        var personal = board == "Computer" ? await ProfileProbeCatalog.ReadAsync(preferences, token).ConfigureAwait(false) : null;
        var saved = await atomic.UpdateAsync(PreferenceKey(board), current =>
        {
            var next = BoardLayoutHistory.Restore(current, versionId, expectedChoiceToken, Defaults(board), rows => Normalize(board, rows), now);
            RequireDefinitions(ReadForUpdate(next, board), personal);
            return next;
        }, token).ConfigureAwait(false);
        return View(board, saved, personal);
    }

    private static void RequireDefinitions(IReadOnlyList<FleetLayoutItem> items, PersonalProbeSnapshot? personal)
    {
        var keys = items.Where(i => i.Source == FleetWidgetSource.Probe && PersonalProbeCatalog.IsKey(i.Key)).Select(i => i.Key).Distinct(StringComparer.Ordinal).ToArray();
        if (keys.Length == 0) { return; }
        var definitions = (personal ?? PersonalProbeCatalog.Read(null)).Resolve(keys);
        PersonalProbeCatalog.Validate(definitions);
    }

    internal static JsonElement Next(JsonElement? current, string board, IReadOnlyList<FleetLayoutItem> items, DateTimeOffset now) =>
        BoardLayoutHistory.Next(current, items, Defaults(board), rows => Normalize(board, rows), now);

    internal static LegacyBoardProposal ConvertLegacy(string board, string key, bool legacy, string original, JsonElement rows)
    {
        // Widgets.Computer adds probes to the delivered board (the 14 entries not marked N in D1's catalog).
        // Dashboard.Computer.Layout="[]" is a different contract: an explicitly empty board, without defaults.
        var items = new List<FleetLayoutItem>();
        if (legacy) { items.AddRange(Defaults(board)); }
        var ids = items.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        var given = rows.EnumerateArray().Select(row => LegacyBoardLayouts.Property(row, "Id"))
            .Where(value => value is { ValueKind: JsonValueKind.String }).Select(value => (legacy ? "p-" : "") + value!.Value.GetString()!)
            .ToHashSet(StringComparer.Ordinal);
        var n = 0;
        foreach (var row in rows.EnumerateArray())
        {
            string Text(string field, int max)
            {
                var value = LegacyBoardLayouts.Property(row, field);
                if (value is null or { ValueKind: JsonValueKind.Null }) { return ""; }
                if (value is not { ValueKind: JsonValueKind.String } text || text.GetString() is not { } result || result.Length > max || result.Any(char.IsControl))
                { throw new InvalidDataException("Champ de disposition historique incompatible."); }
                return result;
            }
            var sourceText = legacy ? "Probe" : Text("Source", 16);
            var source = sourceText.Equals("Builtin", StringComparison.OrdinalIgnoreCase) ? FleetWidgetSource.Builtin
                : sourceText.Equals("Probe", StringComparison.OrdinalIgnoreCase) ? FleetWidgetSource.Probe
                : sourceText.Equals("Query", StringComparison.OrdinalIgnoreCase) ? FleetWidgetSource.Query
                : throw new InvalidDataException("Source de widget D1 inconnue.");
            var itemKey = Text(legacy ? "ProbeId" : "Key", 80);
            var id = Text("Id", 64);
            if (legacy && id.Length > 0) { id = "p-" + id; }
            if (id.Length is 0 or > 64 || !id.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.') || !ids.Add(id))
            {
                id = "d1-" + n.ToString(System.Globalization.CultureInfo.InvariantCulture);
                while (given.Contains(id) || !ids.Add(id)) { id += "x"; }
            }
            var paused = LegacyBoardLayouts.Property(row, "Paused");
            if (paused is { ValueKind: not (JsonValueKind.True or JsonValueKind.False or JsonValueKind.Null) })
            { throw new InvalidDataException("Pause historique non booléenne."); }
            items.Add(new(id, source, itemKey, Text("Visual", 32), Text("Size", 8), Text("Title", 80),
                paused is { ValueKind: JsonValueKind.True }, Text("Group", 80)));
            n++;
        }
        var normalized = Normalize(board, items, true);
        return new(board, key, normalized.Any(i => i.Source == FleetWidgetSource.Query) ? "needsQueryBinding" : "ready", "Ordre, tailles, titres et pauses repris dans l’écran " + (board == "Computer" ? "Poste." : "Logiciels.")
            + (legacy ? " Widgets complète les cartes livrées ; une liste vide ne vide pas le tableau." : "")
            + (normalized.Any(i => i.Source == FleetWidgetSource.Probe) ? " Les sondes affichent leurs valeurs en cache et leur provenance ; aucune collecte distante automatique." : "")
            + " Présentations adaptées aux cartes D2 ; texte original conservé. Les widgets masqués ou en pause ne calculent pas leur rendu.",
            normalized.Length, normalized, original);
    }

    internal static ImmutableArray<FleetLayoutItem> ReadForUpdate(JsonElement? value, string board) =>
        BoardLayoutHistory.Read(value, Defaults(board), rows => Normalize(board, rows)).Items;

    private static JsonSerializerOptions CreateJson()
    {
        var json = new JsonSerializerOptions(JsonSerializerDefaults.Web);
        json.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return json;
    }
}
