using System.Collections.Immutable;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Opérations screen (docs/ops/operations.md): journal of the session (tasks in progress and finished, with their steps, their end
/// and the advice that follows), write receipts with their re-read and their manual review, health of the engine, statistics,
/// collection runs, diagnostics and the rules of the write circuit. Nothing here writes to the directory: the only writes are the
/// local data of the application (a new version of a receipt, the documents asked by the operator), and nothing is ever replayed.
/// Handlers only validate their arguments and delegate.
/// </summary>
public sealed class OperationsOperations : IOperationModule
{
    private static readonly string[] IdArgument = ["id"];
    private static readonly string[] ReviewArguments = ["id", "reason"];
    private static readonly string[] CheckArguments = ["full", "page"];
    private static readonly string[] PageArguments = ["strictPolicy", "structure", "structureTotal", "motion", "webView"];
    private static readonly string[] InterfaceArguments = ["renders", "stall"];
    private static readonly string[] RenderArguments = ["work", "ms"];
    private static readonly string[] StallArguments = ["lateMs", "work", "workMs", "longTaskMs"];

    /// <summary>Most interface samples accepted in one report (the page sends them every few seconds).</summary>
    public const int MaxInterfaceSamples = 64;
    private static readonly string[] RemainingArgument = ["remaining"];
    private static readonly string[] FigureArguments = ["webView", "theme", "interfaceP50Ms", "interfaceP95Ms", "interfaceSamples"];
    private static readonly string[] DossierArguments = ["anonymize", "webView"];
    private static readonly string[] ExportArguments = ["subject", "csv"];

    /// <summary>Subjects of the CSV exports and the names of their files.</summary>
    private static readonly Dictionary<string, string> Subjects = new(StringComparer.Ordinal)
    {
        ["recus"] = "Recus",
        ["operations"] = "Operations",
        ["statistiques"] = "Statistiques",
        ["releves"] = "Releves",
        ["verification"] = "Verification",
        ["journal"] = "Journal",
    };

    public string Screen => "operations";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var desk = new Desk(context);
        return
        [
            new OperationDefinition("operations.overview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.OverviewAsync(ct).ConfigureAwait(false);
            }, "Tête de l’écran Opérations : reçus, tâches et mesures de la session, sans lecture réseau."),

            // LocalRead, not followed (operations screen): the receipts list of the circuit for the refreshes of the screen, so its
            // background reads never fill the activity, the statistics or the categories.
            new OperationDefinition("operations.receipts", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.ReceiptsAsync(ct).ConfigureAwait(false);
            }, "Reçus d’écriture du mode pour l’écran Opérations, ceux à vérifier d’abord."),

            new OperationDefinition("operations.center", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.CenterAsync(ct).ConfigureAwait(false);
            }, "Centre des opérations : pastille des reçus à vérifier, tâches en cours, opérations à revoir."),

            // Local: closed codes and numbers measured by the page, kept in memory; a stall writes one line in the technical journal.
            new OperationDefinition("operations.interface.report", OperationClass.Local, (args, _, _) =>
            {
                var (renders, stall) = InterfaceReport(BridgeArguments.ReadObject(args, InterfaceArguments));
                return Task.FromResult<object?>(desk.Interface(renders, stall));
            }, "Mesures de l’interface : traitements de la page et battements en retard."),

            new OperationDefinition("operations.activity", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(desk.Activity());
            }, "Tâches en cours et dernières opérations de la session, en mémoire."),

            new OperationDefinition("operations.task.stop", OperationClass.Local, (args, _, _) =>
            {
                var id = BridgeArguments.GetString(BridgeArguments.ReadObject(args, IdArgument), "id");
                return Task.FromResult<object?>(desk.Stop(id));
            }, "Demande l’arrêt d’une lecture ou d’un lot de collecte ; jamais d’une écriture."),

            new OperationDefinition("operations.receipts.detail", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var id = ReceiptId(BridgeArguments.ReadObject(args, IdArgument));
                return await desk.DetailAsync(id, ct).ConfigureAwait(false);
            }, "Un reçu d’écriture avec la relecture qui le prouve, sa compensation et ses actions."),

            // LocalWrite: a new version of the receipt in the receipts of the application, never the directory.
            new OperationDefinition("operations.receipts.review", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ReviewArguments);
                var id = ReceiptId(values);
                var reason = BridgeArguments.GetString(values, "reason");
                if (reason.Length > 2 * ReceiptReviews.MaxLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("reason") + " doit faire au plus 240 caractères.");
                }
                return await desk.ReviewAsync(id, reason, ct).ConfigureAwait(false);
            }, "Consigne la revue manuelle d’un reçu à vérifier ; rien n’est renvoyé."),

            new OperationDefinition("operations.rules", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(desk.Rules());
            }, "Règles du circuit d’écriture : preuves par relecture, compensations, séquences de cycle de vie."),

            new OperationDefinition("operations.health", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.HealthAsync(ct).ConfigureAwait(false);
            }, "Santé du moteur : mémoire, temps de réponse, lenteurs, enregistrement local, sources suspendues."),

            // LocalRead: reads the receipts of the mode and the session of the source.
            new OperationDefinition("operations.engine", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.EngineAsync(ct).ConfigureAwait(false);
            }, "État du moteur : versions, mémoire, mode, écritures et tâches actives."),

            new OperationDefinition("operations.stats", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.StatsAsync(ct).ConfigureAwait(false);
            }, "Statistiques des opérations : mesures de la session et des sessions précédentes."),

            new OperationDefinition("operations.journal", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.JournalAsync(ct).ConfigureAwait(false);
            }, "Journal des opérations de la session et journal de la source."),

            new OperationDefinition("operations.runs", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.RunsAsync(ct).ConfigureAwait(false);
            }, "Derniers relevés par OU, relevé en cours et relevé interrompu."),

            // NetworkRead: the remaining workstations are read after the operator confirmed their count and scope (simulation:
            // a fictitious survey in memory).
            new OperationDefinition("operations.survey.resume", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var remaining = PositiveInteger(BridgeArguments.ReadObject(args, RemainingArgument), "remaining");
                return await desk.Reader().ResumeSurveyAsync(remaining, ct).ConfigureAwait(false);
            }, "Reprend un relevé interrompu après confirmation du nombre de postes restants.", ServedInSimulation: true),

            new OperationDefinition("operations.survey.stop", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(desk.Reader().StopSurvey());
            }, "Arrête le relevé en cours ; les mesures reçues sont gardées."),

            // LocalWrite: forgets the local plan of the interrupted survey; the measures already read stay.
            new OperationDefinition("operations.survey.forget", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.Reader().ForgetSurveyAsync(ct).ConfigureAwait(false);
            }, "Abandonne un relevé interrompu ; les mesures déjà lues restent."),

            new OperationDefinition("operations.survey.postpone", OperationClass.Local, (args, _, _) =>
            {
                BridgeArguments.RequireNone(args);
                return Task.FromResult<object?>(desk.Reader().PostponeSurvey());
            }, "Remet à plus tard la proposition de reprise pour cette session."),

            new OperationDefinition("operations.blockers", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await desk.BlockersAsync(ct).ConfigureAwait(false);
            }, "Pourquoi une action est indisponible : états de la session, rien n’est testé."),

            // NetworkRead: the directory checks read the directory of the session (the fictitious one in simulation).
            new OperationDefinition("operations.check.run", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CheckArguments);
                var full = BridgeArguments.GetBoolean(values, "full");
                return await desk.CheckAsync(full, Page(values), ct).ConfigureAwait(false);
            }, "Vérifie l’application en lecture seule : moteur, sécurité, stockage local, annuaire, outils, page.", ServedInSimulation: true),

            // LocalRead: reads the receipts of the mode and the session of the source.
            new OperationDefinition("operations.diagnostic.preview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var figures = Figures(BridgeArguments.ReadObject(args, FigureArguments));
                return await desk.DiagnosticAsync(figures, ct).ConfigureAwait(false);
            }, "Diagnostic expurgé : contenu et aperçu, avant tout enregistrement."),

            new OperationDefinition("operations.diagnostic.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var figures = Figures(BridgeArguments.ReadObject(args, FigureArguments));
                return await desk.SaveDiagnosticAsync(figures, ct).ConfigureAwait(false);
            }, "Enregistre le diagnostic expurgé dans le dossier des documents ; aucun envoi."),

            new OperationDefinition("operations.dossier.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, DossierArguments);
                var anonymize = BridgeArguments.GetBoolean(values, "anonymize");
                var webView = BridgeArguments.GetOptionalString(values, "webView");
                return await desk.SaveDossierAsync(anonymize, webView, ct).ConfigureAwait(false);
            }, "Enregistre le dossier de diagnostic (ZIP) sans journaux bruts ; aucun envoi."),

            new OperationDefinition("operations.export.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ExportArguments);
                var subject = BridgeArguments.GetString(values, "subject");
                if (!Subjects.TryGetValue(subject, out var file))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("subject") + " doit désigner une liste de l’écran Opérations.");
                }
                var csv = BridgeArguments.GetString(values, "csv");
                return await desk.ExportAsync(file, csv, ct).ConfigureAwait(false);
            }, "Enregistre une liste de l’écran Opérations en CSV dans le dossier des documents."),
        ];
    }

    private static string ReceiptId(IReadOnlyDictionary<string, JsonElement> values)
    {
        var id = BridgeArguments.GetString(values, "id");
        return WritePlans.IsPlanId(id)
            ? id
            : throw BridgeArguments.Invalid(FrenchText.Quote("id") + " doit être un identifiant de reçu (32 caractères hexadécimaux).");
    }

    private static int PositiveInteger(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number is >= 1 and <= 100_000)
        {
            return number;
        }
        throw BridgeArguments.Invalid(FrenchText.Quote(name) + " est obligatoire et doit être un entier de 1 à " + FrenchText.Integer(100_000) + ".");
    }

    private static double? OptionalNumber(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) && double.IsFinite(number) && number is >= 0 and <= 3_600_000
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un nombre positif ou null.");
    }

    private static InterfaceFigures Figures(IReadOnlyDictionary<string, JsonElement> values)
    {
        var webView = BridgeArguments.GetOptionalString(values, "webView");
        var theme = BridgeArguments.GetOptionalString(values, "theme");
        if (webView is { Length: > 40 } || theme is { Length: > 20 })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("webView") + " et " + FrenchText.Quote("theme") + " doivent être courts.");
        }
        var samples = OptionalNumber(values, "interfaceSamples");
        return new InterfaceFigures(webView, theme, OptionalNumber(values, "interfaceP50Ms"), OptionalNumber(values, "interfaceP95Ms"), samples is double s ? (int)Math.Min(s, 100_000) : null);
    }

    private static PageChecks? Page(IReadOnlyDictionary<string, JsonElement> values)
    {
        if (!values.TryGetValue("page", out var page) || page.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        var facts = BridgeArguments.ReadObject(page, PageArguments);
        bool? strict = facts.TryGetValue("strictPolicy", out var policy) && policy.ValueKind is JsonValueKind.True or JsonValueKind.False ? policy.GetBoolean() : null;
        var motion = BridgeArguments.GetOptionalString(facts, "motion");
        var webView = BridgeArguments.GetOptionalString(facts, "webView");
        if (motion is not (null or "full" or "reduced" or "system") || webView is { Length: > 40 })
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("page") + " ne contient que des valeurs fermées et courtes.");
        }
        return new PageChecks(strict, SmallCount(facts, "structure"), SmallCount(facts, "structureTotal"), motion, webView);
    }

    private static int? SmallCount(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number is >= 0 and <= 64
            ? number
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de 0 à 64 ou null.");
    }

    private static (ImmutableArray<InterfaceSample> Renders, StallReport? Stall) InterfaceReport(IReadOnlyDictionary<string, JsonElement> values)
    {
        var renders = ImmutableArray.CreateBuilder<InterfaceSample>();
        if (values.TryGetValue("renders", out var list) && list.ValueKind != JsonValueKind.Null)
        {
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > MaxInterfaceSamples)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("renders") + " doit être une liste de " + FrenchText.Integer(MaxInterfaceSamples) + " mesures au plus.");
            }
            foreach (var item in list.EnumerateArray())
            {
                var sample = BridgeArguments.ReadObject(item, RenderArguments);
                var ms = OptionalNumber(sample, "ms") ?? throw BridgeArguments.Invalid(FrenchText.Quote("ms") + " est obligatoire.");
                renders.Add(new InterfaceSample(WorkCode(BridgeArguments.GetString(sample, "work")), ms));
            }
        }
        StallReport? stall = null;
        if (values.TryGetValue("stall", out var raw) && raw.ValueKind != JsonValueKind.Null)
        {
            var facts = BridgeArguments.ReadObject(raw, StallArguments);
            var work = BridgeArguments.GetOptionalString(facts, "work");
            var late = OptionalNumber(facts, "lateMs") ?? throw BridgeArguments.Invalid(FrenchText.Quote("lateMs") + " est obligatoire.");
            stall = new StallReport(late, work is null ? null : WorkCode(work), OptionalNumber(facts, "workMs"), OptionalNumber(facts, "longTaskMs"));
        }
        return (renders.ToImmutable(), stall);
    }

    private static string WorkCode(string code) => ActivityRules.InterfaceWorkLabel(code) is not null
        ? code
        : throw BridgeArguments.Invalid(FrenchText.Quote("work") + " doit désigner un travail connu de l’interface.");

    /// <summary>The services of the screen over one engine context; created once, when the registry is built.</summary>
    private sealed class Desk(EngineContext context)
    {
        private readonly OperationActivity activity = OperationActivity.From(context);
        private readonly bool simulation = context.Mode == AppMode.Simulation;
        private readonly OperationsExports exports = new(context, OperationsExports.DefaultFolder(context));
        private CheckReport? lastCheck;

        private WriteCircuit Circuit => WriteCircuit.From(context);

        public IOperationsReader Reader() => context.Readers.Require<IOperationsReader>();

        private IOperationsReader? FindReader() => context.Readers.Find<IOperationsReader>();

        private DateTimeOffset Now => context.Clock.GetUtcNow();

        public async Task<OperationsOverview> OverviewAsync(CancellationToken ct)
        {
            var (list, readable) = await ListAsync(ct).ConfigureAwait(false);
            var snapshot = Activity();
            var session = activity.Samples();
            // The tile reads like the grid shown by default: the requests of the operator and the automatic reads that ended badly;
            // the automatic reads that went well are counted apart (hidden by default, as in Domenia 1).
            var listed = snapshot.Recent.Where(r => r.Listed).ToList();
            var failures = listed.Count(r => r.Outcome is TaskOutcome.Refused or TaskOutcome.Failed or TaskOutcome.Unknown or TaskOutcome.TimedOut);
            double? success = listed.Count == 0 ? null : Math.Round(100.0 * listed.Count(r => r.Outcome == TaskOutcome.Succeeded) / listed.Count, 1);
            var pending = list?.Pending ?? 0;
            var note = simulation
                ? "Simulation" + FrenchText.Colon + "les écritures ne touchent que l’annuaire fictif en mémoire ; reçus marqués « simulé »."
                : context.Writers.Kinds.Count == 0
                    ? "Mode annuaire" + FrenchText.Colon + "aucune écriture n’est servie dans cette version (Domenia.Ad, vague 3)."
                    : "Mode annuaire" + FrenchText.Colon + "chaque écriture passe par son plan, sa confirmation, son reçu et sa relecture.";
            return new OperationsOverview(Now, simulation ? "simulation" : "annuaire", simulation, list?.Total ?? 0, pending, list?.Unreadable ?? 0, readable,
                context.Receipts.Persistent, list?.Summary ?? WriteErrors.ReceiptsUnreadableMessage, Pill(list), snapshot.Summary,
                listed.Count + snapshot.Open.Length, failures, success, ActivityRules.Latency(session.Select(s => s.DurationMs)),
                [.. context.Writers.Kinds], snapshot.Recent.Length - listed.Count, note);
        }

        /// <summary>operations.receipts: the list of the circuit, for the screen (not followed).</summary>
        public async Task<ReceiptList> ReceiptsAsync(CancellationToken ct) => await Circuit.ListAsync(ct).ConfigureAwait(false);

        /// <summary>operations.center: the pill and the tasks in progress, for a panel of the shell (Domenia 1 OPE-015, OPE-026).</summary>
        public async Task<OperationsCenter> CenterAsync(CancellationToken ct)
        {
            var (list, readable) = await ListAsync(ct).ConfigureAwait(false);
            var snapshot = Activity();
            var attention = snapshot.Recent.Count(r => r.Listed && r.Outcome is TaskOutcome.Refused or TaskOutcome.Failed or TaskOutcome.Unknown or TaskOutcome.TimedOut);
            var (state, tone) = WriteState(list, readable);
            return new OperationsCenter(Now, Pill(list), readable, state, tone, snapshot.Summary, [.. snapshot.Open.Take(ActivityRules.MaxTraces)], attention,
                "Tâches de cette session seulement" + FrenchText.Colon + "une lecture s’arrête, une écriture jamais ; rien n’est relancé automatiquement.");
        }

        /// <summary>operations.interface.report: interface work and stalls measured by the page.</summary>
        public InterfaceReportResult Interface(ImmutableArray<InterfaceSample> renders, StallReport? stall)
        {
            var kept = activity.RecordInterface(renders);
            var logged = stall is not null && activity.RecordStall(stall);
            return new InterfaceReportResult(kept, logged);
        }

        private PendingPill Pill(ReceiptList? list) =>
            list is null ? ReceiptReviews.Pill(0) : ReceiptReviews.Pill(list.Pending, ReceiptReviews.Oldest(list.Receipts), context.Clock.LocalTimeZone);

        /// <summary>State of the writes in one sentence (Domenia 1 WriteState: au repos, en cours, inconnu tant qu’un reçu attend).</summary>
        private (string Text, Tone Tone) WriteState(ReceiptList? list, bool readable)
        {
            var pending = list?.Pending ?? 0;
            return !readable
                ? ("Reçus illisibles" + FrenchText.Colon + "aucune écriture n’est admise tant qu’ils ne sont pas relus.", Tone.Alert)
                : pending > 0
                    ? (FrenchText.Count(pending, "opération à vérifier", "opérations à vérifier") + FrenchText.Colon + "les nouvelles écritures restent bloquées jusqu’à "
                        + (pending == 1 ? "sa vérification ou sa revue." : "leur vérification ou leur revue."), Tone.Warn)
                    : activity.OpenWrites > 0
                        ? ("Écriture en cours" + FrenchText.Colon + "les suivantes attendent leur tour.", Tone.Info)
                        : (context.Writers.Kinds.Count == 0 ? "Aucune écriture servie dans ce mode." : "Au repos" + FrenchText.Colon + "aucune écriture incertaine.", Tone.Ok);
        }

        public ActivitySnapshot Activity()
        {
            var survey = FindReader()?.CurrentSurvey();
            return activity.Snapshot(survey is { Open: true } s ? [BatchRow(s)] : []);
        }

        public ActivityRow Stop(string id)
        {
            if (id.StartsWith("batch:", StringComparison.Ordinal) && id.Length <= 64)
            {
                // The right to stop is checked again on the real batch (Domenia 1 OPE-016): a row of an older batch never stops a new one.
                var reader = FindReader();
                if (reader?.CurrentSurvey() is not { Open: true } running || !string.Equals(running.Id, id["batch:".Length..], StringComparison.Ordinal))
                {
                    throw new DomeniaOperationException(OperationActivity.TaskUnknown, OperationActivity.TaskUnknownMessage);
                }
                var state = reader.StopSurvey() ?? throw new DomeniaOperationException(OperationActivity.TaskUnknown, OperationActivity.TaskUnknownMessage);
                context.Journal.Add(new JournalEntry(Now, "Arrêt demandé" + FrenchText.Colon + "relevé " + state.Type + " de l’OU " + state.ScopeName, Tone.Warn));
                return BatchRow(state);
            }
            if (id.Length != 32 || !id.All(char.IsAsciiHexDigitLower))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("id") + " doit être un identifiant de tâche.");
            }
            return activity.Stop(id);
        }

        public async Task<ReceiptDetailView> DetailAsync(string id, CancellationToken ct)
        {
            var receipt = await Circuit.GetAsync(id, ct).ConfigureAwait(false);
            return Detail(receipt);
        }

        public async Task<ReceiptDetailView> ReviewAsync(string id, string reason, CancellationToken ct)
        {
            var receipt = await Circuit.ReviewAsync(id, reason, ct).ConfigureAwait(false);
            return Detail(receipt);
        }

        private ReceiptDetailView Detail(ReceiptView receipt)
        {
            var available = context.Writers.ForKind(receipt.Kind) is not null;
            return new ReceiptDetailView(receipt, WriteKindRules.Of(receipt.Kind, receipt.Label), WriteKindRules.Assess(receipt),
                ReceiptReviews.Actions(receipt, available, activity.OpenWrites > 0, simulation), available);
        }

        public WriteRulesView Rules()
        {
            var kinds = context.Writers.Kinds;
            var note = kinds.Count == 0
                ? "Aucune écriture servie dans ce mode" + FrenchText.Colon + "les règles valent pour les exécuteurs à venir (Domenia.Ad, vague 3)."
                : FrenchText.Count(kinds.Count, "type d’écriture servi", "types d’écriture servis") + " dans ce mode" + FrenchText.Colon + string.Join(", ", kinds) + ".";
            return new WriteRulesView(WriteKindRules.Rows(kinds), LifecyclePlans.Views(kinds), note);
        }

        public async Task<EngineHealth> HealthAsync(CancellationToken ct)
        {
            var reader = FindReader();
            var providers = reader is null ? [] : await reader.ProviderStatesAsync(ct).ConfigureAwait(false);
            var now = Now;
            var zone = context.Clock.LocalTimeZone;
            var waits = activity.WriteWaits();
            var collection = new List<string>(activity.ClassLines())
            {
                "Lectures identiques partagées et requêtes WMI évitées" + FrenchText.Colon + "comptées par l’ordonnanceur de collecte à venir (Domenia.Engine et Domenia.Inventory, vague 3) ; aucune n’est estimée ici.",
                reader?.CollectionProfile ?? ("Collecte sur les postes" + FrenchText.Colon + "arrive avec Domenia.Inventory (vague 3) ; aucune sonde ne part dans cette version."),
            };
            var (localSave, tone) = LocalSave(zone);
            var (busy, last) = activity.SqliteBusy;
            var timeout = ActivityRules.SqliteBusyTimeout(null);
            var sqlite = busy > 0
                ? ActivityRules.SqliteBusySummary(busy, last, timeout, zone)
                : simulation
                    ? "Base locale" + FrenchText.Colon + "aucune base SQLite ouverte en simulation (annuaire fictif en mémoire) ; aucune attente de verrou possible."
                    : "Base locale" + FrenchText.Colon + "base SQLite non branchée dans cette version ; le compteur des attentes de verrou (délai "
                        + FrenchText.Integer(timeout) + FrenchText.Nbsp + "ms, borné de 100 à " + FrenchText.Integer(5000) + FrenchText.Nbsp + "ms) est prêt et reste à zéro.";
            return new EngineHealth(now, MemoryMb(), activity.Categories(), activity.Slow(), activity.Faults, localSave, tone, sqlite,
                ActivityRules.ProviderLines(providers, now, zone), [.. collection], waits,
                "Mesures locales de cette session seulement, 512 dernières par catégorie" + FrenchText.Colon + "ce n’est pas un test du réseau. Rien ne quitte le processus.");
        }

        private (string Text, Tone Tone) LocalSave(TimeZoneInfo zone)
        {
            var unavailable = !context.Receipts.Persistent && !context.Preferences.Persistent;
            var failed = context.Journal.Snapshot().Count(e => e.Tone == Tone.Warn
                && (e.Label.StartsWith("Préférences non enregistrées", StringComparison.Ordinal) || e.Label.StartsWith("Reçu d’écriture non enregistré", StringComparison.Ordinal)));
            var saved = activity.LastLocalWrite is DateTimeOffset at ? TimeZoneInfo.ConvertTime(at, zone).ToString("HH':'mm':'ss", CultureInfo.InvariantCulture) : null;
            var text = ActivityRules.PersistenceLabel(0, failed, false, unavailable, 0, saved);
            return (text, unavailable ? Tone.Info : failed > 0 ? Tone.Warn : Tone.Ok);
        }

        public async Task<EngineState> EngineAsync(CancellationToken ct)
        {
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var (list, readable) = await ListAsync(ct).ConfigureAwait(false);
            var snapshot = Activity();
            var (writeState, writeTone) = WriteState(list, readable);
            var lines = snapshot.Open.Select(r => new EngineTaskLine(r.Reference,
                r.Label + " (" + r.Operation + ")" + FrenchText.Colon + r.KindLabel.ToLowerInvariant() + ", depuis " + ActivityRules.Duration(r.DurationMs)
                + (r.State == TaskState.StopRequested ? ", arrêt demandé" : "") + ". Réf. " + r.Reference)).ToImmutableArray();
            return new EngineState(Now, ProductInfo.Name, ProductInfo.Version, ".NET " + Environment.Version, Environment.OSVersion.VersionString, Environment.Is64BitProcess, MemoryMb(),
                simulation ? ModeTexts.SimulationLabel : ModeTexts.DirectoryLabel, session.ReadOnly, writeState, writeTone,
                context.Receipts.Persistent ? "Fichier des reçus du mode (" + (simulation ? "receipts-simulation.jsonl" : "receipts.jsonl") + ")." : "En mémoire seulement (capture, E2E ou sans dossier de données).",
                context.Preferences.Persistent ? "Fichier des préférences du mode." : "En mémoire seulement.",
                activity.Declared.Length, snapshot.Summary.Active, lines,
                [
                    "Une lecture arrêtée ne renvoie plus de résultat à l’interface, mais son appel reste compté jusqu’à sa fin réelle.",
                    "Une écriture n’est jamais arrêtée ni rejouée" + FrenchText.Colon + "elle va jusqu’au bout puis l’objet est relu.",
                    "Aucun secret dans ce texte" + FrenchText.Colon + "ni argument, ni résultat, ni message d’erreur des opérations.",
                ]);
        }

        public async Task<OperationStats> StatsAsync(CancellationToken ct)
        {
            var reader = FindReader();
            var history = reader is null ? [] : await reader.HistoryAsync(ct).ConfigureAwait(false);
            var session = activity.Samples();
            var all = history.Concat(session).ToList();
            var rows = all.GroupBy(s => s.Operation, StringComparer.Ordinal).Select(g =>
            {
                var list = g.ToList();
                var summary = ActivityRules.Latency(list.Select(s => s.DurationMs));
                var items = list.Where(s => s.Items > 0).ToList();
                var declaration = activity.DeclarationOf(g.Key);
                var kind = declaration?.Kind ?? TaskKind.LocalRead;
                // Network columns of Domenia 1 (Complete-DomeniaOperationStatsUi): estimated bytes, throughput over the samples that
                // measured them, fallbacks over the remote attempts; a column with nothing measured stays empty, never 0.
                var sized = list.Where(s => s.Bytes is not null).ToList();
                double? bytes = sized.Count == 0 ? null : Math.Round(sized.Average(s => (double)s.Bytes!.Value), 0);
                var sizedMs = sized.Sum(s => s.DurationMs);
                double? throughput = sized.Count == 0 || sizedMs <= 0 ? null : Math.Round(sized.Sum(s => (double)s.Bytes!.Value) / (sizedMs / 1000.0), 0);
                var attempts = list.Sum(s => s.RemoteAttempts);
                double? fallback = attempts == 0 ? null : Math.Round(100.0 * list.Sum(s => s.Fallbacks) / attempts, 1);
                return new OperationStatsRow(g.Key, activity.LabelOf(g.Key), declaration?.Screen ?? g.Key.Split('.')[0], kind, ActivityRules.KindLabel(kind, simulation),
                    list.Count, list.Count(s => s.Session), Math.Round(list.Average(s => s.DurationMs), 1), summary.P50, summary.P95,
                    items.Count == 0 ? null : Math.Round(items.Sum(s => s.DurationMs) / items.Sum(s => s.Items), 1),
                    Math.Round(list.Average(s => (double)s.Items), 1), Math.Round(100.0 * list.Count(s => s.Succeeded) / list.Count, 1), list.Max(s => s.At),
                    bytes, throughput, attempts, fallback);
            }).OrderByDescending(r => r.Samples).ThenBy(r => r.Operation, StringComparer.Ordinal).ToImmutableArray();
            var summaryText = all.Count == 0
                ? "Aucune mesure pour l’instant" + FrenchText.Colon + "chaque opération en ajoute une à sa fin."
                : FrenchText.Count(all.Count, "mesure", "mesures") + " sur " + FrenchText.Count(rows.Length, "type d’opération", "types d’opération")
                    + " (dont " + FrenchText.Integer(session.Length) + " de cette session).";
            var note = (reader is null
                    ? "Mesures de cette session seulement" + FrenchText.Colon + "l’historique de la base locale arrive avec elle (vague 3)."
                    : simulation
                        ? "Historique fictif des 14 derniers jours ouvrés (simulation) et mesures de cette session."
                        : "Historique de la base locale et mesures de cette session.")
                + " Réseau estimé d’après la taille des réponses des lectures distantes et des écritures ; aucune nouvelle tentative ni aucun transport de repli dans Domenia 2"
                + (simulation ? " (simulation" + FrenchText.Colon + "aucune tentative distante)." : ".");
            return new OperationStats(Now, all.Count, rows.Length, history.Length > 0, summaryText, note, rows);
        }

        public async Task<JournalView> JournalAsync(CancellationToken ct)
        {
            var session = context.Journal.Snapshot();
            ImmutableArray<JournalEntry> source = [];
            try
            {
                source = (await context.Directory.ReadLocalAsync(ct).ConfigureAwait(false)).Journal;
            }
            catch (DomeniaOperationException ex) when (ex.Code == DomeniaErrors.SourceUnavailable)
            {
                // Directory mode without its local base yet: the journal of the session only.
            }
            var lines = session.Select(e => new JournalLine(e.At, e.Label, e.Tone, "session"))
                .Concat(source.Select(e => new JournalLine(e.At, e.Label, e.Tone, simulation ? "simulation" : "base")))
                .OrderByDescending(l => l.At)
                .Take(400)
                .ToImmutableArray();
            var note = simulation
                ? "Journal de la session (en mémoire) et journal fictif de la simulation. Le journal technique (Domenia.log) garde les codes et les références des tâches."
                : "Journal de la session (en mémoire) et journal de la base locale. Le journal technique (Domenia.log) garde les codes et les références des tâches.";
            return new JournalView(Now, session.Length, source.Length, lines, note);
        }

        public async Task<CollectionRunsView> RunsAsync(CancellationToken ct)
        {
            var reader = FindReader();
            if (reader is null)
            {
                return new CollectionRunsView(Now, false, [], null, null, "Aucun relevé en cours.",
                    "Relevés des postes et base locale non branchés dans cette version (Domenia.Inventory et Domenia.Store, vague 3)" + FrenchText.Colon + "rien n’est lu.");
            }
            return await reader.RunsAsync(ct).ConfigureAwait(false);
        }

        public async Task<BlockerReport> BlockersAsync(CancellationToken ct)
        {
            // Domenia 1 Get-DomeniaUnavailableReasonLines: one line per common blocking, with a safe route; facts of the session only.
            var lines = new List<BlockerLine>();
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            if (simulation)
            {
                lines.Add(new BlockerLine(Tone.Info, "Simulation" + FrenchText.Colon + "les écritures ne touchent que l’annuaire fictif en mémoire, sans effet réel.", null, null));
            }
            else if (context.Writers.Kinds.Count == 0)
            {
                lines.Add(new BlockerLine(Tone.Warn, "Écritures non disponibles dans cette version" + FrenchText.Colon + "aucun exécuteur pour l’annuaire réel (Domenia.Ad, vague 3) ; les plans répondent « source indisponible ».", null, null));
            }
            if (session.ReadOnly)
            {
                lines.Add(new BlockerLine(Tone.Warn, "Lecture seule" + FrenchText.Colon + "aucune modification de l’annuaire n’est possible dans cette session.", "Ouvrir les paramètres", "parametres"));
            }
            var (list, readable) = await ListAsync(ct).ConfigureAwait(false);
            if (!readable)
            {
                lines.Add(new BlockerLine(Tone.Alert, "Reçus d’écriture non confirmés" + FrenchText.Colon + "les nouvelles écritures sont bloquées tant qu’ils ne sont pas relus.", "Ouvrir les reçus", "operations?onglet=recus"));
            }
            else if (list is { Pending: > 0 } l)
            {
                lines.Add(new BlockerLine(Tone.Warn, (l.Pending == 1 ? "Une opération précédente reste à vérifier" : FrenchText.Integer(l.Pending) + " opérations précédentes restent à vérifier")
                    + FrenchText.Colon + "toutes les nouvelles écritures sont bloquées jusqu’à leur relecture ou leur revue. Consultez les reçus, pas une relance automatique.",
                    "Ouvrir les reçus à vérifier", "operations?onglet=recus&filtre=a-verifier"));
            }
            if (activity.OpenWrites > 0)
            {
                lines.Add(new BlockerLine(Tone.Info, "Une écriture est en cours" + FrenchText.Colon + "les suivantes attendent leur tour (une à la fois) ; changer d’OU de travail attend sa fin.", "Voir les tâches", "operations?onglet=taches"));
            }
            if (!context.Receipts.Persistent)
            {
                lines.Add(new BlockerLine(Tone.Info, "Reçus en mémoire seulement (capture, E2E ou sans dossier de données)" + FrenchText.Colon + "ils disparaîtront à la fermeture.", null, null));
            }
            ScopeSelection? scope = null;
            try
            {
                scope = await WorkingScope.From(context).CurrentAsync(session, ct).ConfigureAwait(false);
            }
            catch (DomeniaOperationException ex)
            {
                context.Log.Info($"Opérations : OU de travail non lue ({ex.Code}).");
            }
            if (scope is null)
            {
                lines.Add(new BlockerLine(Tone.Warn, "Aucune OU de travail" + FrenchText.Colon + "la mesure des postes n’est jamais lancée sur tout le domaine.", "Choisir l’OU", "accueil?ou=choisir"));
            }
            // Selection: Domenia 2 keeps no selected object between screens; the actions of an object start from it.
            lines.Add(new BlockerLine(Tone.Info, "Actions d’un objet (fiche, déverrouillage, mot de passe, groupes)" + FrenchText.Colon
                + "elles demandent un objet choisi dans Rechercher ou dans une liste ; aucune sélection n’est gardée d’un écran à l’autre.", "Rechercher un objet", "rechercher"));
            var kinds = context.Writers.Kinds;
            string[] keys = ["object.update", "computer.restart", "attribute.raw"];
            var missing = keys.Where(k => !kinds.Contains(k)).Select(k => WriteKindRules.Of(k).Label.ToLowerInvariant()).ToList();
            if (missing.Count > 0)
            {
                lines.Add(new BlockerLine(Tone.Info, "Boutons clés indisponibles dans ce mode (" + string.Join(", ", missing) + ")" + FrenchText.Colon
                    + "leur écriture n’est pas encore servie ; ils restent grisés avec cette raison en infobulle.", "Règles du circuit", "operations?onglet=recus"));
            }
            lines.Add(new BlockerLine(Tone.Info, "Boutons LAPS et BitLocker" + FrenchText.Colon + "lectures de secrets pas encore servies dans cette version ; aucun secret n’est jamais affiché, copié ni exporté par Opérations.", null, null));
            lines.Add(new BlockerLine(Tone.Info, "Identité des lectures LAPS et BitLocker" + FrenchText.Colon + "compte de la session (" + session.Account.Login
                + "), sans autre identité ni élévation ; un refus de droits ne suspend que la lecture concernée.", null, null));
            if (!lines.Any(x => x.Tone is Tone.Warn or Tone.Alert))
            {
                lines.Insert(0, new BlockerLine(Tone.Ok, "Aucun blocage commun observé. Un droit précis reste vérifié par la ressource lors de l’action" + FrenchText.Colon + "consultez son infobulle ou son message.", null, null));
            }
            ImmutableArray<string> transports = simulation
                ?
                [
                    "Aucune connexion" + FrenchText.Colon + "annuaire fictif en mémoire, aucune requête LDAP, WMI ni ping ne part.",
                    "WinRM, PsExec et tâches planifiées distantes" + FrenchText.Colon + "non utilisés par Domenia 2.",
                    "Aucun service installé, aucun port ouvert, aucun envoi vers Internet ; aucun réglage de Windows n’est modifié.",
                ]
                :
                [
                    "LDAP (System.DirectoryServices)" + FrenchText.Colon + "authentification intégrée de la session Windows, lectures bornées à une OU après votre geste.",
                    "WMI/CIM par DCOM et ping" + FrenchText.Colon + "relevés des postes après confirmation (collecte à venir, vague 3).",
                    "WinRM, PsExec et tâches planifiées distantes" + FrenchText.Colon + "non utilisés par Domenia 2.",
                    "Aucun service installé, aucun port ouvert, aucun envoi vers Internet ; aucun réglage de Windows n’est modifié.",
                ];
            return new BlockerReport(Now, [.. lines], transports, "Ce bilan lit uniquement les états de la session" + FrenchText.Colon + "il ne teste ni ne modifie aucun droit.");
        }

        public async Task<CheckReport> CheckAsync(bool full, PageChecks? page, CancellationToken ct)
        {
            var rows = new List<CheckRow>();
            void Add(string category, string test, Func<(CheckStatus, string)> action)
            {
                var start = context.Clock.GetTimestamp();
                var (status, detail) = action();
                rows.Add(new CheckRow(category, test, status, Math.Round(context.Clock.GetElapsedTime(start).TotalMilliseconds, 1), detail));
            }
            Add("Moteur", "Runtime .NET", () => (Environment.Is64BitProcess ? CheckStatus.Ok : CheckStatus.Warn,
                ".NET " + Environment.Version + (Environment.Is64BitProcess ? " · processus 64 bits." : " · processus 32 bits (64 bits attendu).")));
            Add("Moteur", "Mémoire du processus", () => MemoryMb() is double mb
                ? (CheckStatus.Ok, FrenchText.Integer((long)Math.Round(mb)) + FrenchText.Nbsp + "Mo de mémoire privée.")
                : (CheckStatus.Info, "Mémoire non lue."));
            var declared = activity.Declared;
            Add("Moteur", "Opérations du pont", () => declared.Length > 0
                ? (CheckStatus.Ok, FrenchText.Count(declared.Length, "opération déclarée", "opérations déclarées") + ", registre fermé" + FrenchText.Colon + "toute autre demande est refusée.")
                : (CheckStatus.Error, "Aucune opération déclarée."));
            Add("Sécurité", "Politique d’écriture", () =>
            {
                var writes = declared.Where(d => d.Kind == TaskKind.Write).Select(d => d.Operation).ToList();
                return writes.Count == 1 && writes[0] == WriteCircuit.ExecuteOperation
                    ? (CheckStatus.Ok, "Une seule porte d’écriture (write.execute)" + FrenchText.Colon + "plan scellé, jeton à usage unique de 5" + FrenchText.Nbsp + "min, reçu avant l’envoi, relecture, jamais rejouée.")
                    : (CheckStatus.Error, "Écritures déclarées hors du circuit" + FrenchText.Colon + string.Join(", ", writes) + ".");
            });
            Add("Sécurité", "Lecture seule par défaut", () => (CheckStatus.Ok,
                "Gardes d’admission du mode " + (simulation ? "simulation" : "annuaire") + FrenchText.Colon + "toute écriture hors du circuit est refusée avant son gestionnaire."));
            Add("Sécurité", "Vérification non destructive", () => (CheckStatus.Ok, "Aucune écriture" + FrenchText.Colon + "cette vérification ne fait que des lectures."));
            var listStart = context.Clock.GetTimestamp();
            var (list, readable) = await ListAsync(ct).ConfigureAwait(false);
            rows.Add(new CheckRow("Stockage local", "Reçus d’écriture",
                !readable ? CheckStatus.Error : context.Receipts.Persistent ? CheckStatus.Ok : CheckStatus.Info,
                Math.Round(context.Clock.GetElapsedTime(listStart).TotalMilliseconds, 1),
                !readable ? "Reçus illisibles pour l’instant" + FrenchText.Colon + "aucune écriture n’est admise."
                    : (context.Receipts.Persistent ? "Fichier du mode lisible" : "En mémoire seulement (capture ou E2E)") + FrenchText.Colon + FrenchText.Count(list?.Total ?? 0, "reçu", "reçus") + "."));
            Add("Stockage local", "Préférences", () => context.Preferences.Persistent
                ? (CheckStatus.Ok, "Fichier des préférences du mode.")
                : (CheckStatus.Info, "En mémoire seulement (capture, E2E ou sans dossier de données)."));
            Add("Stockage local", "Dossier des documents", () =>
            {
                if (exports.Folder is not string folder)
                {
                    return (CheckStatus.Info, "Non utilisé dans ce mode" + FrenchText.Colon + "rien n’est écrit sur le disque.");
                }
                var info = new DirectoryInfo(folder);
                return !info.Exists
                    ? (CheckStatus.Info, "Absent" + FrenchText.Colon + "il sera créé au premier document enregistré.")
                    : info.Attributes.HasFlag(FileAttributes.ReparsePoint)
                        ? (CheckStatus.Error, "Le dossier des documents est un lien" + FrenchText.Colon + "aucun document n’y sera écrit.")
                        : (CheckStatus.Ok, "Présent" + FrenchText.Colon + folder);
            });
            Add("Écritures", "Exécuteurs du mode", () => context.Writers.Kinds.Count > 0
                ? (CheckStatus.Ok, FrenchText.Count(context.Writers.Kinds.Count, "type d’écriture servi", "types d’écriture servis") + FrenchText.Colon + string.Join(", ", context.Writers.Kinds)
                    + (simulation ? " (annuaire fictif)." : "."))
                : (CheckStatus.Info, "Aucun exécuteur dans ce mode" + FrenchText.Colon + "les écritures réelles arrivent avec Domenia.Ad (vague 3)."));
            var reader = FindReader();
            if (reader is not null)
            {
                rows.AddRange(await reader.CheckDirectoryAsync(full, ct).ConfigureAwait(false));
            }
            else if (context.Readers.Find<IDirectoryChecks>() is { } checks)
            {
                rows.AddRange(await checks.CheckDirectoryAsync(full, ct).ConfigureAwait(false));
            }
            else
            {
                rows.Add(new CheckRow("Annuaire", "Lecture de l’annuaire", CheckStatus.Info, 0, "Non branchée pour cette source" + FrenchText.Colon + "rien n’est lu."));
            }
            Add("Outils", "Outils Windows", () =>
            {
                string[] tools = ["mstsc.exe", "eventvwr.exe", "compmgmt.msc"];
                var system = Environment.SystemDirectory;
                var found = tools.Where(t => File.Exists(Path.Combine(system, t))).ToList();
                return (found.Count == tools.Length ? CheckStatus.Ok : CheckStatus.Warn,
                    FrenchText.Integer(found.Count) + "/" + FrenchText.Integer(tools.Length) + " présents" + (found.Count > 0 ? FrenchText.Colon + string.Join(", ", found) : "") + ".");
            });
            // The checks of the page itself are written here from its closed facts: report, journal and dossier count the same rows.
            rows.AddRange(OperationsDiagnostics.PageRows(page));
            var report = OperationsDiagnostics.Report(Now, full, rows);
            lastCheck = report;
            context.Journal.Add(new JournalEntry(Now, "Vérification de l’application" + (full ? " complète" : " rapide") + FrenchText.Colon + report.Summary,
                report.Errors > 0 ? Tone.Warn : Tone.Ok));
            return report;
        }

        public async Task<DiagnosticPreview> DiagnosticAsync(InterfaceFigures figures, CancellationToken ct)
        {
            var json = await DiagnosticJsonAsync(figures, ct).ConfigureAwait(false);
            return new DiagnosticPreview(OperationsDiagnostics.Format, json, OperationsDiagnostics.Preview(json), System.Text.Encoding.UTF8.GetByteCount(json), OperationsDiagnostics.Sha256(json), Now);
        }

        public async Task<ExportResult> SaveDiagnosticAsync(InterfaceFigures figures, CancellationToken ct)
        {
            var json = await DiagnosticJsonAsync(figures, ct).ConfigureAwait(false);
            var result = await exports.SaveTextAsync("Domenia-Diagnostic-" + exports.Stamp(Now) + ".json", json, bom: false, ct).ConfigureAwait(false);
            Journal("Diagnostic expurgé", result);
            return result;
        }

        public async Task<ExportResult> SaveDossierAsync(bool anonymize, string? webView, CancellationToken ct)
        {
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var (list, _) = await ListAsync(ct).ConfigureAwait(false);
            var files = OperationsDiagnostics.Dossier(Now, context.Decision, session, new InterfaceFigures(webView, null, null, null, null), MemoryMb(),
                activity.Snapshot().Summary.Active, list?.Pending ?? 0, context.Receipts.Persistent, context.Preferences.Persistent, context.Writers.Kinds, lastCheck, anonymize);
            var result = await exports.SaveZipAsync("Domenia-Dossier-" + exports.Stamp(Now) + ".zip", files, ct).ConfigureAwait(false);
            Journal("Dossier de diagnostic" + (anonymize ? " anonymisé" : ""), result);
            return result;
        }

        public async Task<ExportResult> ExportAsync(string subject, string csv, CancellationToken ct)
        {
            // The grid of the kit already neutralises formulas and leaves secret columns out; the text is masked once more here.
            var result = await exports.SaveTextAsync("Domenia-" + subject + "-" + exports.Stamp(Now) + ".csv", ReceiptReviews.Mask(csv.TrimStart('\uFEFF')), bom: true, ct).ConfigureAwait(false);
            Journal("Export CSV " + subject, result);
            return result;
        }

        private void Journal(string what, ExportResult result) =>
            context.Journal.Add(new JournalEntry(Now, what + FrenchText.Colon + (result.Saved ? result.Name : "préparé en mémoire, non écrit"), result.Saved ? Tone.Ok : Tone.Info));

        private async Task<string> DiagnosticJsonAsync(InterfaceFigures figures, CancellationToken ct)
        {
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var (list, _) = await ListAsync(ct).ConfigureAwait(false);
            var names = activity.Declared.Select(d => d.Operation).ToList();
            return OperationsDiagnostics.Build(Now, context.Mode, figures, MemoryMb(), session.ReadOnly, list?.Pending ?? 0, Activity(), names,
                activity.Samples(), activity.Errors(), activity.Slow(), activity.Faults);
        }

        /// <summary>The receipts, or null and false when they cannot be read for now (fail closed for the writes, said on the screen).</summary>
        private async Task<(ReceiptList? List, bool Readable)> ListAsync(CancellationToken ct)
        {
            try
            {
                return (await Circuit.ListAsync(ct).ConfigureAwait(false), true);
            }
            catch (DomeniaOperationException ex) when (ex.Code == WriteErrors.ReceiptUnavailable)
            {
                return (null, false);
            }
        }

        private ActivityRow BatchRow(SurveyState s)
        {
            var started = s.StartedAt;
            var elapsed = Math.Max(0, (Now - started).TotalMilliseconds);
            var state = s.StopRequested ? TaskState.StopRequested : TaskState.Running;
            var label = "Lot " + s.Type + " · " + s.ScopeName;
            var header = s.Type + " · " + (s.Phase is SurveyPhase.Preparing or SurveyPhase.ReadingDirectory or SurveyPhase.Confirming
                ? s.PhaseLabel.ToLowerInvariant()
                : FrenchText.Integer(s.Done) + "/" + FrenchText.Integer(s.Total));
            var reference = ActivityRules.Reference(s.Id.Replace("-", "", StringComparison.Ordinal).PadRight(8, '0'));
            ImmutableArray<TaskPhaseRow> phases =
            [
                new("request", "Demande confirmée par l’opérateur", 0, null, "non mesurée", false, null, null),
                new("work", s.PhaseLabel, 0, null, ActivityRules.Duration(elapsed) + " (en cours)", false, s.Status, null),
            ];
            var stopText = s.StopRequested ? ActivityRules.CancelText(label, TaskState.StopRequested, TaskKind.Batch) : null;
            var progress = new BatchProgress(s.Done, s.Total, s.Failed, s.PhaseLabel, header, s.Status, s.PingErrors, s.InFlight, s.PendingSaves, s.Skipped, BatchSteps(s.Phase));
            return new ActivityRow("batch:" + s.Id, reference, "operations.survey.resume", "operations", label, TaskKind.Batch, ActivityRules.KindLabel(TaskKind.Batch, simulation),
                true, true, state, s.PhaseLabel, s.StopRequested ? Tone.Warn : Tone.Info, s.StopRequested ? "pause" : "activity", null, null, started, null,
                Math.Round(elapsed, 1), ActivityRules.Duration(elapsed), null, null, s.Done, ActivityRules.Volume(s.Done), !s.StopRequested,
                stopText, s.Status, ActivityRules.Access(TaskKind.Batch, simulation), null,
                ActivityRules.Next(null, TaskKind.Batch, "operations.survey.resume", null), null,
                label + " → " + s.PhaseLabel + " (" + s.Status + ")", 0, phases, progress);
        }

        /// <summary>The stepper of a batch (Domenia 1 OPE-017): Préparation, Lecture AD, À confirmer, En cours, Enregistrement.</summary>
        private static ImmutableArray<BatchStep> BatchSteps(SurveyPhase phase)
        {
            (SurveyPhase Phase, string Code, string Label)[] order =
            [
                (SurveyPhase.Preparing, "preparing", "Préparation"),
                (SurveyPhase.ReadingDirectory, "readingDirectory", "Lecture AD"),
                (SurveyPhase.Confirming, "confirming", "À confirmer"),
                (SurveyPhase.Running, "running", "En cours"),
                (SurveyPhase.Saving, "saving", "Enregistrement"),
            ];
            // A stop asked keeps the batch on its reading phase until the reads in flight end; a finished batch has done them all.
            var current = phase switch
            {
                SurveyPhase.Done => order.Length,
                SurveyPhase.Stopping => Array.FindIndex(order, o => o.Phase == SurveyPhase.Running),
                _ => Array.FindIndex(order, o => o.Phase == phase),
            };
            return [.. order.Select((o, n) => new BatchStep(o.Code, o.Label, n < current ? "done" : n == current ? "current" : "todo"))];
        }

        private static double? MemoryMb()
        {
            try
            {
                using var process = Process.GetCurrentProcess();
                return Math.Round(process.PrivateMemorySize64 / 1048576.0, 1);
            }
            catch (InvalidOperationException)
            {
                return null;
            }
        }
    }
}
