using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the common shell (docs/ops/shell.md): interface preferences, activity of the session, embedded object picker,
/// interface faults, demonstration coverage and the local automation contract. The operations bound to the host window and
/// files (about, window chrome, exports, file picker, guides, team layouts) are declared by ShellHostOperations in
/// Domenia.App. Handlers only validate the arguments and delegate.
/// </summary>
public sealed class ShellOperations : IOperationModule
{
    /// <summary>Most objects returned by the embedded picker (Domenia 1: 100 results).</summary>
    public const int LookupLimit = 100;

    /// <summary>Longest text searched by the embedded picker (Domenia 1: 160 characters).</summary>
    public const int MaxLookupLength = 160;

    /// <summary>Rows of an automation preview at most (the command line itself goes up to the contract bound).</summary>
    public const int PreviewRows = 100;

    private static readonly string[] SetArguments = ["interface", "layouts", "boards", "ouFavourites"];
    private static readonly string[] LookupArguments = ["text", "kinds"];
    private static readonly string[] VerifyArguments = ["dn", "objectGuid"];
    private static readonly string[] FaultArguments = ["kind", "route", "count"];
    private static readonly string[] PreviewArguments = ["command", "ou", "computers", "guids", "limit", "format"];

    public string Screen => "shell";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var store = ShellInterfaceStore.From(context);
        var activity = ShellActivityService.From(context);
        var faults = ShellFaultTracer.From(context);
        var readers = context.Readers;
        var source = context.Directory;
        // The picker reads the fictitious directory in memory in simulation, the directory itself in directory mode.
        var lookupClass = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            // LocalRead: the preferences file of the mode (memory only in capture and E2E).
            new OperationDefinition("shell.interface.get", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                return await store.GetAsync(session.Domain?.RootDn, cancellationToken).ConfigureAwait(false);
            }, "Préférences de l’interface : réglages, dispositions des listes et des tableaux, OU favorites du domaine."),

            // LocalWrite: the preferences of the application only, never the directory.
            new OperationDefinition("shell.interface.set", OperationClass.LocalWrite, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, SetArguments);
                var iface = OptionalObject(values, "interface");
                var layouts = OptionalObject(values, "layouts");
                var boards = OptionalObject(values, "boards");
                var favourites = OptionalStrings(values, "ouFavourites", ShellInterfaceRules.MaxFavourites * 2);
                var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                return await store.SetAsync(session.Domain?.RootDn, iface, layouts, boards, favourites, cancellationToken).ConfigureAwait(false);
            }, "Enregistre des préférences de l’interface (bornées) et renvoie celles qui valent désormais."),

            // LocalRead: counters in memory, receipts file of the mode, journal of the session.
            new OperationDefinition("shell.activity", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                return await activity.GetAsync(cancellationToken).ConfigureAwait(false);
            }, "Activité de la session : lectures en cours, reçus à vérifier, dernières lignes du journal."),

            new OperationDefinition("shell.lookup", lookupClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, LookupArguments);
                var text = BridgeArguments.GetString(values, "text").Trim();
                var kinds = LookupKinds(values);
                var minimum = kinds.Count == 1 && kinds.Contains(ShellLookupKind.Ou) ? 1 : 2;
                if (text.Length < minimum)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + (minimum == 1 ? " doit contenir au moins un caractère." : " doit contenir au moins 2 caractères."));
                }
                if (text.Length > MaxLookupLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(MaxLookupLength) + " caractères.");
                }
                return await readers.Require<IShellReader>().LookupAsync(text, kinds, LookupLimit, cancellationToken).ConfigureAwait(false);
            }, "Sélecteur d’objet intégré : au plus 100 utilisateurs, postes ou OU dont le nom contient le texte."),

            new OperationDefinition("shell.lookup.verify", lookupClass, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, VerifyArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var guidText = BridgeArguments.GetString(values, "objectGuid");
                if (!Guid.TryParseExact(guidText, "D", out var guid))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("objectGuid") + " doit être un GUID (format 8-4-4-4-12).");
                }
                return await readers.Require<IShellReader>().VerifyAsync(dn, guid, cancellationToken).ConfigureAwait(false);
            }, "Revérifie qu’un objet choisi existe toujours avec ce nom distinctif et ce GUID."),

            // LocalRead: the fictitious directory in memory; nothing in directory mode.
            new OperationDefinition("shell.demo.coverage", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                BridgeArguments.RequireNone(args);
                if (readers.Find<IShellReader>() is not { } reader || context.Mode != AppMode.Simulation)
                {
                    return new ShellDemoCoverage(false, AppInfoBuilder.DirectoryModeText, [], 0, 0, "Annuaire de démonstration non utilisé" + FrenchText.Colon + "Domenia lit l’annuaire réel dans ce mode.");
                }
                return await reader.CoverageAsync(cancellationToken).ConfigureAwait(false);
            }, "Ce que contient l’annuaire fictif de la simulation, catégorie par catégorie."),

            // LocalWrite: one line of the technical journal at most once a minute; never a message of the page.
            new OperationDefinition("shell.fault", OperationClass.LocalWrite, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, FaultArguments);
                var kind = BridgeArguments.GetString(values, "kind");
                if (kind is not ("error" or "rejection"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("kind") + " doit valoir error ou rejection.");
                }
                var route = BridgeArguments.GetString(values, "route");
                if (!GuideChapters.IsPageName(route))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("route") + " doit être un nom d’écran.");
                }
                var count = values.TryGetValue("count", out var raw) && raw.ValueKind == JsonValueKind.Number && raw.TryGetInt32(out var n) && n is >= 1 and <= 10_000
                    ? n
                    : throw BridgeArguments.Invalid(FrenchText.Quote("count") + " doit être un entier de 1 à 10 000.");
                var traced = faults.Report(kind, route, count);
                return Task.FromResult<object?>(new { traced, total = faults.Total });
            }, "Signale des erreurs de l’interface (nature, écran, nombre) au journal technique, une fois par minute au plus."),

            new OperationDefinition("shell.automation.contract", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(ShellAutomation.Contract);
            }, "Contrat de l’interface automatisable locale (Domenia.Automation/1) : commandes, bornes, codes de sortie."),

            // LocalRead: validation, then the answer the command line would give, from the data of the session.
            new OperationDefinition("shell.automation.preview", OperationClass.LocalRead, async (args, _, cancellationToken) =>
            {
                var values = BridgeArguments.ReadObject(args, PreviewArguments);
                var command = BridgeArguments.GetString(values, "command");
                var ou = BridgeArguments.GetOptionalString(values, "ou");
                var computers = OptionalStrings(values, "computers", ShellAutomation.Limits.MaxNames + 1);
                var guids = OptionalStrings(values, "guids", ShellAutomation.Limits.MaxNames + 1);
                var format = BridgeArguments.GetOptionalString(values, "format");
                var limit = values.TryGetValue("limit", out var rawLimit) && rawLimit.ValueKind != JsonValueKind.Null
                    ? rawLimit.ValueKind == JsonValueKind.Number && rawLimit.TryGetInt32(out var l) && l >= 0 ? l : throw BridgeArguments.Invalid(FrenchText.Quote("limit") + " doit être un entier positif ou null.")
                    : 0;
                return await PreviewAsync(context, command, ou, computers, guids, limit, format, cancellationToken).ConfigureAwait(false);
            }, "Vérifie une commande de l’interface automatisable et montre la réponse qu’elle donnerait."),
        ];
    }

    private static async Task<AutomationPreview> PreviewAsync(EngineContext context, string command, string? ou, IReadOnlyList<string?>? computers, IReadOnlyList<string?>? guids, int limit, string? format, CancellationToken cancellationToken)
    {
        var (request, error, exit) = ShellAutomation.Validate(command, ou, computers, guids, limit, format);
        if (request is null)
        {
            return new AutomationPreview(false, exit, error, null, null, null, 0, false, error ?? "Commande refusée.");
        }
        var now = context.Clock.GetUtcNow();
        switch (request.Command)
        {
            case "version":
            {
                var text = JsonSerializer.Serialize(ShellAutomation.Contract, BridgeJson.Options);
                return new AutomationPreview(true, 0, null, request, text, "json", 0, false, "Réponse de la commande version (contrat complet).");
            }
            case "etat":
            {
                var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
                var stateSource = new Dictionary<string, object?>(StringComparer.Ordinal)
                {
                    ["Kind"] = context.Mode == AppMode.Simulation ? "Simulation" : "Base locale",
                    ["LastReadUtc"] = session.Store.LastReadAt?.UtcDateTime.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", System.Globalization.CultureInfo.InvariantCulture),
                    ["Objects"] = session.Store.Objects,
                    ["Complete"] = session.Store.Complete,
                };
                var text = ShellAutomation.Envelope(request, stateSource, [], false, now);
                return new AutomationPreview(true, 0, null, request, text, "json", 0, false, "État daté de la base de la session.");
            }
            case "postes":
            {
                if (context.Readers.Find<IShellReader>() is not { } reader)
                {
                    return new AutomationPreview(true, 0, null, request, null, null, 0, false, "Commande valide. Aperçu indisponible" + FrenchText.Colon + "la base locale n’est pas encore branchée dans ce mode.");
                }
                var cap = Math.Min(request.Limit, PreviewRows);
                var rows = await reader.ComputersAsync(request.Perimeter, cap, cancellationToken).ConfigureAwait(false);
                var truncated = rows.Length > cap;
                var shown = rows.Take(cap).ToImmutableArray();
                var csv = string.Equals(request.Format, "Csv", StringComparison.Ordinal);
                var text = csv
                    ? ShellAutomation.ComputerCsv(shown)
                    : ShellAutomation.Envelope(request, new Dictionary<string, object?>(StringComparer.Ordinal) { ["Kind"] = context.Mode == AppMode.Simulation ? "Simulation" : "Base locale" }, ShellAutomation.ComputerItems(shown), truncated, now);
                var summary = FrenchText.Count(shown.Length, "poste", "postes") + " dans l’aperçu" + (truncated ? FrenchText.Colon + "d’autres postes correspondent (aperçu limité à " + FrenchText.Integer(cap) + " lignes, troncature signalée)." : ".");
                return new AutomationPreview(true, 0, null, request, text, csv ? "csv" : "json", shown.Length, truncated, summary);
            }
            default:
                return new AutomationPreview(true, 0, null, request, null, null, 0, false,
                    "Commande valide. Aperçu non disponible dans l’application" + FrenchText.Colon + "la ligne de commande la sert depuis la base locale.");
        }
    }

    private static JsonElement? OptionalObject(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Object
            ? value
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un objet ou null.");
    }

    private static List<string?>? OptionalStrings(IReadOnlyDictionary<string, JsonElement> values, string name, int max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > max || value.EnumerateArray().Any(e => e.ValueKind != JsonValueKind.String))
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste de textes (" + FrenchText.Integer(max) + " au plus) ou null.");
        }
        return [.. value.EnumerateArray().Select(e => e.GetString())];
    }

    private static HashSet<ShellLookupKind> LookupKinds(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("kinds", out var raw) || raw.ValueKind != JsonValueKind.Array || raw.GetArrayLength() is 0 or > 3)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("kinds") + " doit être une liste de user, computer ou ou.");
        }
        var kinds = new HashSet<ShellLookupKind>();
        foreach (var item in raw.EnumerateArray())
        {
            var kind = item.ValueKind == JsonValueKind.String ? item.GetString() : null;
            kinds.Add(kind switch
            {
                "user" => ShellLookupKind.User,
                "computer" => ShellLookupKind.Computer,
                "ou" => ShellLookupKind.Ou,
                _ => throw BridgeArguments.Invalid(FrenchText.Quote("kinds") + " doit être une liste de user, computer ou ou."),
            });
        }
        return kinds;
    }
}
