using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the « Synchronisation et base autonome » screen (docs/ops/synchro.md): state of the local base, search of the
/// local index, controls (census, census gaps, disappeared objects, snapshots), reads of the directory after an explicit gesture
/// (one OU, the changes of the domain, verifications by GUID, shared park survey) and the plans that store their results.
/// Handlers validate the arguments and delegate to the reader of the mode (<see cref="ISyncReader"/>) and to the write executor
/// (<see cref="ISyncStoreExecutor"/>) through the write circuit. Nothing here writes the directory; the local base only changes
/// through write.execute (plan, confirmation, receipt, re-read), the exports are new CSV files (LocalWrite).
/// </summary>
public sealed class SyncOperations : IOperationModule
{
    public const int MaxLabelLength = SyncSnapshots.MaxLabelLength;
    public const long MaxObjectsArgument = 10_000_000;

    private static readonly string[] ScopeArguments = ["dn"];
    private static readonly string[] SearchArguments = ["text", "dn", "sort", "descending", "offset", "limit"];
    private static readonly string[] ExportArguments = ["text", "dn", "sort", "descending"];
    private static readonly string[] EstimateArguments = ["target", "dn", "maxObjects", "budgetSeconds"];
    private static readonly string[] EstimateIdArguments = ["estimateId"];
    private static readonly string[] RunIdArguments = ["runId"];
    private static readonly string[] CompareArguments = ["before", "after"];
    private static readonly string[] BatchArguments = ["batchId"];
    private static readonly string[] SnapshotArguments = ["label", "dn"];
    private static readonly string[] IdArguments = ["id"];

    private static readonly Dictionary<string, IndexSort> Sorts = new(StringComparer.Ordinal)
    {
        ["relevance"] = IndexSort.Relevance,
        ["type"] = IndexSort.Type,
        ["name"] = IndexSort.Name,
        ["login"] = IndexSort.Login,
        ["upn"] = IndexSort.Upn,
        ["state"] = IndexSort.State,
        ["description"] = IndexSort.Description,
        ["score"] = IndexSort.Score,
        ["reason"] = IndexSort.Reason,
        ["lastLogon"] = IndexSort.LastLogon,
        ["whenChanged"] = IndexSort.WhenChanged,
    };

    public string Screen => "synchro";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = new Service(context);
        return
        [
            new OperationDefinition("synchro.overview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(Empty(args), ScopeArguments);
                var reader = service.Reader();
                var scope = await service.ScopeAsync(OptionalDn(values, "dn"), ct).ConfigureAwait(false);
                return await reader.OverviewAsync(scope, ct).ConfigureAwait(false);
            }, "État de la base locale pour le périmètre\u00A0: tuiles, couverture, recensement, repère, avis, reçus de stockage\u00A0; aucune lecture réseau."),

            new OperationDefinition("synchro.index.search", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SearchArguments);
                var reader = service.Reader();
                var query = await service.QueryAsync(values, ct).ConfigureAwait(false);
                return await reader.SearchAsync(query, ct).ConfigureAwait(false);
            }, "Une page de l’index local (200 lignes, 500 au plus), tri sur toute la population, base occupée signalée."),

            new OperationDefinition("synchro.index.export", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ExportArguments);
                var reader = service.Reader();
                var query = await service.QueryAsync(values, ct).ConfigureAwait(false);
                var rows = await reader.ExportRowsAsync(query, SyncIndex.ExportLimit, ct).ConfigureAwait(false);
                var csv = SyncExports.Csv(
                    ["Type", "Nom", "Identifiant", "UPN ou DNS", "État", "Association", "Score", "Correspondance", "Détail", "Emplacement", "Connexion AD", "Modifié dans AD", "DN", "GUID"],
                    rows.Select(r => (IReadOnlyList<string?>)[r.TypeLabel, r.Name, r.Login, r.Upn, r.StateLabel, r.Association, r.Score.ToString(CultureInfo.InvariantCulture), r.Reason,
                        r.Description, r.Location, service.Local(r.LastLogon), service.Local(r.WhenChanged), r.Dn, r.Guid]));
                var result = await service.Exports.SaveAsync("base-locale", csv, rows.Length, ct).ConfigureAwait(false);
                service.Note("Export de la base locale" + FrenchText.Colon + FrenchText.Count(rows.Length, "ligne", "lignes"), Tone.Info);
                return result;
            }, "Écrit en CSV toutes les lignes de la recherche (20 000 au plus) dans le dossier Exports, sans rien remplacer."),

            new OperationDefinition("synchro.controls", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(Empty(args), ScopeArguments);
                var reader = service.Reader();
                var scope = await service.ScopeAsync(OptionalDn(values, "dn"), ct).ConfigureAwait(false);
                return await reader.ControlsAsync(scope, ct).ConfigureAwait(false);
            }, "Recensement du périmètre, objets manquants, disparitions et relevés du domaine\u00A0; base locale seulement."),

            new OperationDefinition("synchro.read.estimate", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, EstimateArguments);
                var reader = service.Reader();
                var target = BridgeArguments.GetString(values, "target") switch
                {
                    "ou" => SyncTarget.Ou,
                    "domain" => SyncTarget.Domain,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("target") + " vaut « ou » ou « domain »."),
                };
                var dn = OptionalDn(values, "dn");
                // The changes of the domain are read for the whole domain, whatever the scope shown: said as such in the estimate.
                var scope = target == SyncTarget.Domain ? await service.DomainScopeAsync(ct).ConfigureAwait(false) : await service.ScopeAsync(dn, ct).ConfigureAwait(false);
                var maxObjects = OptionalLong(values, "maxObjects", 0, MaxObjectsArgument);
                var budget = (int?)OptionalLong(values, "budgetSeconds", 30, 7200);
                return await reader.EstimateAsync(new SyncEstimateRequest(target, scope, maxObjects, budget), ct).ConfigureAwait(false);
            }, "Estimation d’une lecture (OU choisie ou changements du domaine) à confirmer dans la page\u00A0; rien n’est lu dans l’annuaire."),

            new OperationDefinition("synchro.read.run", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                var id = RequireId(BridgeArguments.ReadObject(args, EstimateIdArguments), "estimateId");
                var reader = service.Reader();
                var result = await reader.RunReadAsync(id, p => bridge.Publish("progress", p), ct).ConfigureAwait(false);
                service.Note((result.Complete ? "Lecture de l’annuaire" : "Lecture partielle de l’annuaire") + FrenchText.Colon + result.Scope.Label + ", "
                    + FrenchText.Count(result.Read, "objet lu", "objets lus") + ", en attente d’enregistrement", result.Complete ? Tone.Info : Tone.Warn);
                context.Log.Info($"Synchronisation\u00A0: lecture {result.Mode} terminée ({result.Read} objets, complète\u00A0: {result.Complete}).");
                return result;
            }, "Lecture confirmée de l’annuaire (OU et sous-OU, ou changements du domaine) avec progression\u00A0; le résultat attend son plan d’enregistrement.", ServedInSimulation: true),

            new OperationDefinition("synchro.read.stop", OperationClass.Local, (args, _, _) =>
            {
                var id = RequireId(BridgeArguments.ReadObject(args, RunIdArguments), "runId");
                var stop = service.Reader().StopRead(id);
                if (stop.Stopping)
                {
                    service.Note("Arrêt demandé de la lecture de l’annuaire", Tone.Warn);
                }
                return Task.FromResult<object?>(stop);
            }, "Demande l’arrêt de la lecture en cours\u00A0: les objets déjà lus restent une lecture partielle."),

            new OperationDefinition("synchro.absences.check", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var result = await service.Reader().CheckAbsencesAsync(p => bridge.Publish("progress", p), ct).ConfigureAwait(false);
                service.Note("Vérification des disparitions" + FrenchText.Colon + FrenchText.Count(result.Checked, "objet relu", "objets relus") + " par GUID, en attente d’enregistrement", Tone.Info);
                context.Log.Info($"Synchronisation\u00A0: vérification de {result.Checked} disparitions.");
                return result;
            }, "Relit par GUID, 200 au plus, les objets non revus\u00A0: dans le domaine puis parmi les objets supprimés\u00A0; rien n’est modifié.", ServedInSimulation: true),

            new OperationDefinition("synchro.gaps.read", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var result = await service.Reader().ReadGapsAsync(p => bridge.Publish("progress", p), ct).ConfigureAwait(false);
                service.Note("Lecture des objets manquants" + FrenchText.Colon + FrenchText.Count(result.Asked, "identité relue", "identités relues") + ", en attente d’enregistrement", Tone.Info);
                return result;
            }, "Relit par GUID, 200 au plus, les identités du dernier recensement absentes de la base.", ServedInSimulation: true),

            new OperationDefinition("synchro.snapshot.compare", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                return await service.Reader().CompareSnapshotsAsync(RequireId(values, "before"), RequireId(values, "after"), ct).ConfigureAwait(false);
            }, "Compare deux relevés du même périmètre\u00A0: ajouts, disparitions, déplacements, renommages, valeurs modifiées."),

            new OperationDefinition("synchro.snapshot.export", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                var report = await service.Reader().CompareSnapshotsAsync(RequireId(values, "before"), RequireId(values, "after"), ct).ConfigureAwait(false);
                var csv = SyncExports.Csv(["Nature", "Objet", "Détail", "Avant", "Après", "GUID"],
                    report.Rows.Select(r => (IReadOnlyList<string?>)[r.NatureLabel, r.Name, r.Detail, r.Before, r.After, r.Guid]));
                var result = await service.Exports.SaveAsync("comparaison-releves", csv, report.Rows.Length, ct).ConfigureAwait(false);
                service.Note("Export d’une comparaison de relevés" + FrenchText.Colon + FrenchText.Count(report.Rows.Length, "ligne", "lignes"), Tone.Info);
                return result;
            }, "Écrit le rapport de comparaison de deux relevés en CSV dans le dossier Exports."),

            new OperationDefinition("synchro.park.state", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.Reader().ParkAsync(ct).ConfigureAwait(false);
            }, "Relevé du parc enregistré dans la base et sa couverture\u00A0; relevé partagé configuré."),

            new OperationDefinition("synchro.park.shared.read", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var result = await service.Reader().ReadSharedParkAsync(ct).ConfigureAwait(false);
                service.Note("Lecture du relevé partagé du parc" + FrenchText.Colon + FrenchText.Count(result.Received, "ligne reçue", "lignes reçues"), Tone.Info);
                return result;
            }, "Lit et fusionne en mémoire le relevé partagé entre consoles (verrou, 12 essais)\u00A0; rien n’est écrit.", ServedInSimulation: true),

            new OperationDefinition("synchro.store.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var id = RequireId(BridgeArguments.ReadObject(args, BatchArguments), "batchId");
                var draft = await service.Writer().PlanBatchAsync(id, ct).ConfigureAwait(false);
                return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de l’enregistrement d’une lecture dans la base locale (aperçu exact, empreinte du lot)."),

            new OperationDefinition("synchro.snapshot.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(Empty(args), SnapshotArguments);
                var label = BridgeArguments.GetOptionalString(values, "label");
                if (label is not null && label.Length > MaxLabelLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("label") + " doit faire au plus " + FrenchText.Integer(MaxLabelLength) + " caractères.");
                }
                var scope = await service.ScopeAsync(OptionalDn(values, "dn"), ct).ConfigureAwait(false);
                var draft = await service.Writer().PlanSnapshotCaptureAsync(label, scope, ct).ConfigureAwait(false);
                return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan d’un relevé daté de la base locale pour le périmètre\u00A0; aucune lecture de l’annuaire."),

            new OperationDefinition("synchro.snapshot.delete.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var id = RequireId(BridgeArguments.ReadObject(args, IdArguments), "id");
                var draft = await service.Writer().PlanSnapshotDeleteAsync(id, ct).ConfigureAwait(false);
                return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de la suppression d’un relevé de la base locale."),

            new OperationDefinition("synchro.park.reset.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var draft = await service.Writer().PlanParkResetAsync(ct).ConfigureAwait(false);
                return await WriteCircuit.From(context).PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de l’oubli des relevés du parc (état de balayage seulement, après une sauvegarde vérifiée)."),
        ];
    }

    /// <summary>« args » absent or null read as an empty object (the operations whose arguments are all optional).</summary>
    private static JsonElement Empty(JsonElement args) =>
        args.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null ? EmptyObject : args;

    private static readonly JsonElement EmptyObject = JsonDocument.Parse("{}").RootElement.Clone();

    private static string? OptionalDn(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var dn = BridgeArguments.GetOptionalString(values, name);
        return dn is null || dn.Length == 0 ? null : BridgeArguments.RequireDistinguishedName(dn, name);
    }

    /// <summary>Identifier of 32 lower-case hexadecimal characters; otherwise arguments.invalid.</summary>
    private static string RequireId(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var id = BridgeArguments.GetString(values, name);
        return WritePlans.IsPlanId(id) ? id : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant de 32 caractères hexadécimaux.");
    }

    private static long? OptionalLong(IReadOnlyDictionary<string, JsonElement> values, string name, long min, long max)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= min && number <= max
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    private static bool OptionalBool(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return false;
        }
        return value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit valoir true ou false.");
    }

    /// <summary>Services of the module: reader, executor, scope of the screen, exports, journal.</summary>
    private sealed class Service(EngineContext context)
    {
        private readonly Lazy<SyncExports> exports = new(() => new SyncExports(context), LazyThreadSafetyMode.ExecutionAndPublication);

        public SyncExports Exports => exports.Value;

        public ISyncReader Reader() => context.Readers.Require<ISyncReader>();

        public ISyncStoreExecutor Writer() => context.Writers.Require<ISyncStoreExecutor>();

        public void Note(string label, Tone tone) => context.Journal.Add(new JournalEntry(context.Clock.GetUtcNow(), label, tone));

        public string? Local(DateTimeOffset? at) => at is { } value ? SyncText.LocalDateTime(value, context.Clock.LocalTimeZone) : null;

        /// <summary>
        /// Scope of the screen: the OU given by the page (checked in the local OU index, never the network), else the working OU
        /// of the session. The domain root is a scope for display and the domain gesture only, never for an OU update.
        /// </summary>
        public async Task<SyncScope> ScopeAsync(string? dn, CancellationToken cancellationToken)
        {
            var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            var root = session.Domain?.RootDn;
            var domainName = session.Domain?.DnsName ?? "domaine";
            var index = context.Readers.Find<IOrganizationalUnitIndex>();
            string source;
            string target;
            if (dn is not null)
            {
                source = "chosen";
                target = dn;
            }
            else
            {
                var current = await WorkingScope.From(context).CurrentAsync(session, cancellationToken).ConfigureAwait(false)
                    ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
                source = "working";
                target = current.Dn;
            }
            if (root is not null && SyncLocations.Same(target, root))
            {
                return new SyncScope(root, domainName, domainName, true, true, source);
            }
            var entry = index is null ? null : await index.FindLocalAsync(target, cancellationToken).ConfigureAwait(false);
            if (entry is null)
            {
                throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
            }
            return new SyncScope(entry.Dn, entry.Name, entry.Path, true, false, source);
        }

        /// <summary>The whole domain of the session as a scope (the gesture « changements du domaine » only).</summary>
        public async Task<SyncScope> DomainScopeAsync(CancellationToken cancellationToken)
        {
            var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
            var root = session.Domain?.RootDn ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
            var name = session.Domain?.DnsName ?? "domaine";
            return new SyncScope(root, name, name, true, true, "domain");
        }

        public async Task<IndexQuery> QueryAsync(IReadOnlyDictionary<string, JsonElement> values, CancellationToken cancellationToken)
        {
            var text = BridgeArguments.GetString(values, "text");
            if (text.Length > SyncIndex.MaxTermLength)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus 100 caractères.");
            }
            var sortText = BridgeArguments.GetOptionalString(values, "sort") ?? "relevance";
            if (!Sorts.TryGetValue(sortText, out var sort))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("sort") + " n’est pas un tri admis.");
            }
            var offset = (int)(OptionalLong(values, "offset", 0, 1_000_000) ?? 0);
            var limit = (int)(OptionalLong(values, "limit", 1, SyncIndex.MaxPageSize) ?? SyncIndex.DefaultPageSize);
            var scope = await ScopeAsync(OptionalDn(values, "dn"), cancellationToken).ConfigureAwait(false);
            return new IndexQuery(text, scope, sort, OptionalBool(values, "descending"), offset, limit);
        }
    }
}
