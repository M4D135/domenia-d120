using System.Text.Json;
using System.Text.RegularExpressions;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// « Utilisateurs et postes » (docs/ops/relations.md): associations between users and workstations, both directions,
/// detection bounded and confirmed before any workstation is contacted, import with preview, journal and restoration, orphan
/// links, comparison of the groups of two users. Handlers only validate the arguments and delegate to the reader of the mode
/// (<see cref="IRelationsReader"/>) and, for the changes of the local association store, to the write circuit: every change
/// is a plan (a read) executed by write.execute with its receipt and its re-read. Nothing here writes by itself.
/// </summary>
public sealed partial class RelationsOperations : IOperationModule
{
    /// <summary>Longest search text.</summary>
    public const int MaxTextLength = 100;

    /// <summary>Longest reference of a subject (DN, sAMAccountName or workstation name).</summary>
    public const int MaxReferenceLength = 2048;

    /// <summary>Longest key of an association (two GUIDs and a kind, or legacy names).</summary>
    public const int MaxKeyLength = 600;

    private static readonly string[] SubjectArguments = ["ref"];
    private static readonly string[] SearchArguments = ["text"];
    private static readonly string[] TargetArguments = ["dn", "text"];
    private static readonly string[] CollectArguments = ["dn", "guid", "login", "scope", "ouDn", "computers", "limit", "kerberos"];
    private static readonly string[] PlanIdArguments = ["planId"];
    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] HarvestEstimateArguments = ["days", "maxEvents"];
    private static readonly string[] EstimateArguments = ["estimateId"];
    private static readonly string[] StageArguments = ["id", "part", "parts", "text"];
    private static readonly string[] PreviewArguments = ["id", "adapter", "fileName"];
    private static readonly string[] CompareArguments = ["dn", "other"];
    private static readonly string[] SweepArguments = ["limit", "computers"];
    private static readonly string[] AssociateArguments = ["dn", "subjectGuid", "target", "targetGuid"];
    private static readonly string[] ExportArguments = ["id", "part", "parts", "subject", "text"];
    private static readonly string[] OpenArguments = ["fileName"];
    private static readonly string[] RemoveArguments = ["key", "fingerprint"];
    private static readonly string[] RestoreArguments = ["entry"];
    private static readonly string[] ImportPlanArguments = ["previewId"];
    private static readonly string[] UndoArguments = ["batch"];
    private static readonly string[] OrphanPlanArguments = ["checkId", "keys"];
    private static readonly string[] ObservationArguments = ["resultId", "keys"];

    public string Screen => "relations";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var readers = context.Readers;
        var writers = context.Writers;
        var circuit = WriteCircuit.From(context);
        var scope = WorkingScope.From(context);
        var probes = RelationProbeControl.From(context);
        var staging = RelationImportStaging.From(context);
        var exports = RelationExports.From(context);
        // Reads that the simulation serves from memory and that directory mode makes on the controller after a gesture.
        var freshRead = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            new OperationDefinition("relations.overview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await readers.Require<IRelationsReader>().OverviewAsync(ct).ConfigureAwait(false);
            }, "Chiffres du magasin local des associations : qualifications, contradictions, dernier import, suppression restaurable, activité."),

            new OperationDefinition("relations.list", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await readers.Require<IRelationsReader>().ListAsync(ct).ConfigureAwait(false);
            }, "Toutes les associations, qualifiées, avec leurs filtres rapides ; aucune lecture réseau."),

            new OperationDefinition("relations.subject", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SubjectArguments);
                var reference = BridgeArguments.GetString(values, "ref").Trim();
                if (reference.Length is 0 or > MaxReferenceLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("ref") + " doit nommer un utilisateur ou un poste (DN, identifiant ou nom), 2 048 caractères au plus.");
                }
                if (reference.Contains('=', StringComparison.Ordinal))
                {
                    BridgeArguments.RequireDistinguishedName(reference, "ref");
                }
                return await readers.Require<IRelationsReader>().SubjectAsync(reference, ct).ConfigureAwait(false);
            }, "Relations d’un utilisateur ou d’un poste : synthèse, poste principal, associations, dernières ouvertures de session, graphe."),

            new OperationDefinition("relations.subjects.search", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SearchArguments);
                var text = Text(values, "text");
                return await readers.Require<IRelationsReader>().SubjectsAsync(text, ct).ConfigureAwait(false);
            }, "Utilisateurs et postes de l’index local à choisir comme sujet ; suggestions sans texte. Jamais le réseau."),

            new OperationDefinition("relations.targets.search", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, TargetArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var text = Text(values, "text");
                if (text.Trim().Length < 2)
                {
                    throw new DomeniaOperationException("relation.term", "Saisissez au moins deux caractères" + FrenchText.Colon + "rien n’a été lu.");
                }
                return await readers.Require<IRelationsReader>().TargetsAsync(dn, text, ct).ConfigureAwait(false);
            }, "Recherche manuelle d’une cible de type opposé dans tout le domaine (2 caractères au moins, 50 résultats).", ServedInSimulation: true),

            new OperationDefinition("relations.detect.collect", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CollectArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var guid = ObjectGuid(values, "guid");
                var login = BridgeArguments.GetString(values, "login").Trim();
                if (login.Length is 0 or > 256)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("login") + " doit être l’identifiant affiché du sujet, 256 caractères au plus.");
                }
                var perimeter = BridgeArguments.GetString(values, "scope");
                if (perimeter is not ("candidates" or "ou" or "loaded"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("scope") + " vaut candidates, ou ou loaded.");
                }
                var ouDn = BridgeArguments.GetOptionalString(values, "ouDn");
                if (ouDn is not null)
                {
                    BridgeArguments.RequireDistinguishedName(ouDn, "ouDn");
                }
                else if (perimeter == "ou")
                {
                    var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                    ouDn = (await scope.CurrentAsync(session, ct).ConfigureAwait(false))?.Dn;
                }
                var computers = Computers(values);
                var limit = Integer(values, "limit", 1, 50);
                var kerberos = BridgeArguments.GetBoolean(values, "kerberos");
                return await readers.Require<IRelationsReader>().CollectAsync(new RelationDetectionRequest(dn, guid, login, perimeter, ouDn, computers, limit, kerberos), ct).ConfigureAwait(false);
            }, "Phase 1 d’une détection : compte relu, associations connues, indices AD, indices Kerberos facultatifs, puis périmètre exact à confirmer. Aucun poste contacté.",
                ServedInSimulation: true),

            new OperationDefinition("relations.detect.run", OperationClass.NetworkRead, async (args, bridge, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PlanIdArguments);
                var planId = Id(values, "planId");
                var stop = probes.Start(planId) ?? throw new DomeniaOperationException(RelationErrors.ProbeBusy, RelationErrors.ProbeBusyMessage);
                try
                {
                    var detection = await readers.Require<IRelationsReader>().ProbeAsync(planId, new Publisher(bridge), stop.Token, ct).ConfigureAwait(false);
                    ReportRefusals(context, detection);
                    return detection;
                }
                finally
                {
                    probes.Finish(planId, stop);
                }
            }, "Phase 2 : lecture de la console des seuls postes du périmètre confirmé, compteurs en direct ; rien n’est enregistré sans plan.", ServedInSimulation: true),

            new OperationDefinition("relations.detect.stop", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, PlanIdArguments);
                var planId = Id(values, "planId");
                var stopping = probes.Stop(planId);
                return Task.FromResult<object?>(new RelationStopAnswer(stopping, stopping
                    ? "Arrêt demandé" + FrenchText.Colon + "attente de la fin réelle de la lecture en cours ; les liens enregistrés sont conservés."
                    : "Aucune détection en cours pour ce périmètre."));
            }, "Demande l’arrêt d’une détection : résultat partiel déclaré, liens enregistrés conservés."),

            new OperationDefinition("relations.computer.read", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, DnArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                return await readers.Require<IRelationsReader>().ComputerSessionAsync(dn, ct).ConfigureAwait(false);
            }, "Lit la session console d’un poste (geste explicite) et contrôle l’identité du compte lu.", ServedInSimulation: true),

            new OperationDefinition("relations.harvest.estimate", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, HarvestEstimateArguments);
                var days = Integer(values, "days", 1, 30);
                var maxEvents = Integer(values, "maxEvents", 200, 20_000);
                return await readers.Require<IRelationsReader>().HarvestEstimateAsync(days, maxEvents, ct).ConfigureAwait(false);
            }, "Impact estimé d’une moisson du journal du contrôleur, à confirmer avant toute lecture."),

            new OperationDefinition("relations.harvest.run", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, EstimateArguments);
                return await readers.Require<IRelationsReader>().HarvestAsync(Id(values, "estimateId"), ct).ConfigureAwait(false);
            }, "Moisson confirmée du journal Sécurité du contrôleur (4768, 4769, 4624) : couples utilisateur-poste, rien d’enregistré.", ServedInSimulation: true),

            new OperationDefinition("relations.journal", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await readers.Require<IRelationsReader>().JournalAsync(ct).ConfigureAwait(false);
            }, "Journal local des associations et suppressions encore restaurables."),

            new OperationDefinition("relations.import.stage", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, StageArguments);
                var id = Id(values, "id");
                var parts = Integer(values, "parts", 1, RelationImportStaging.MaxParts);
                var part = Integer(values, "part", 0, parts - 1);
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > RelationImportStaging.MaxPartCharacters)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(RelationImportStaging.MaxPartCharacters) + " caractères par partie.");
                }
                return Task.FromResult<object?>(staging.Add(id, part, parts, text));
            }, "Reçoit une partie du texte d’un fichier d’import choisi par l’opérateur ; gardé en mémoire seulement, jamais écrit sur le disque."),

            new OperationDefinition("relations.import.preview", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, PreviewArguments);
                var id = Id(values, "id");
                var adapter = BridgeArguments.GetString(values, "adapter") switch
                {
                    "csv" => RelationImportAdapter.Csv,
                    "glpi" => RelationImportAdapter.Glpi,
                    "osquery" => RelationImportAdapter.Osquery,
                    _ => throw BridgeArguments.Invalid(FrenchText.Quote("adapter") + " vaut csv, glpi ou osquery."),
                };
                var fileName = FileName(BridgeArguments.GetString(values, "fileName"));
                var text = staging.Take(id);
                return await readers.Require<IRelationsReader>().ImportPreviewAsync(new RelationImportRequest(id, adapter, fileName, text), ct).ConfigureAwait(false);
            }, "Aperçu d’un import : chaque enregistrement avec sa décision, vérifié dans l’index local ; rien n’est enregistré."),

            new OperationDefinition("relations.orphans.check", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await readers.Require<IRelationsReader>().OrphansAsync(ct).ConfigureAwait(false);
            }, "Contrôle les associations contre l’annuaire et liste les orphelines avec leur motif ; rien n’est retiré.", ServedInSimulation: true),

            new OperationDefinition("relations.compare", freshRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, CompareArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var other = BridgeArguments.GetString(values, "other").Trim();
                if (other.Length is 0 or > MaxReferenceLength)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("other") + " doit nommer le second compte (identifiant, DOMAINE\\compte, UPN ou DN).");
                }
                return await readers.Require<IRelationsReader>().CompareAsync(dn, other, ct).ConfigureAwait(false);
            }, "Compare les groupes directs, imbriqués et principal et l’organisation de deux utilisateurs ; rien n’est appliqué."),

            new OperationDefinition("relations.sweep.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SweepArguments);
                var limit = Integer(values, "limit", 1, 50);
                var computers = Computers(values);
                // A list loaded elsewhere does not use the working OU: only the queue of the OU needs it (and refuses the root).
                ScopeSelection? current = null;
                if (computers.Count == 0)
                {
                    var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
                    current = await scope.CurrentAsync(session, ct).ConfigureAwait(false)
                        ?? throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
                }
                return await readers.Require<IRelationsReader>().SweepPlanAsync(new RelationSweepRequest(limit, current, computers), ct).ConfigureAwait(false);
            }, "File du relevé incrémentiel : postes de l’OU de travail jamais relevés d’abord, puis les plus anciens, ou postes d’une liste chargée ; aucun poste contacté."),

            new OperationDefinition("relations.sweep.forget.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                var draft = await writers.Require<IRelationSweepResetExecutor>().PlanSweepResetAsync(ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de « Oublier les relevés » : la mémoire des relevés du parc est vidée ; aucune association ni objet de l’annuaire modifié."),

            new OperationDefinition("relations.observations.pending", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await readers.Require<IRelationsReader>().PendingAsync(ct).ConfigureAwait(false);
            }, "Observations gardées par le moteur et pas encore enregistrées, par lecture et par source (lots de 64)."),

            new OperationDefinition("relations.export.save", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ExportArguments);
                var id = Id(values, "id");
                var parts = Integer(values, "parts", 1, RelationExports.MaxParts);
                var part = Integer(values, "part", 0, parts - 1);
                var subject = BridgeArguments.GetString(values, "subject");
                if (!RelationExports.Subjects.Contains(subject, StringComparer.Ordinal))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("subject") + " vaut " + string.Join(", ", RelationExports.Subjects) + ".");
                }
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > RelationExports.MaxPartCharacters)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus " + FrenchText.Integer(RelationExports.MaxPartCharacters) + " caractères par partie.");
                }
                return await exports.AddAsync(id, part, parts, subject, text, ct).ConfigureAwait(false);
            }, "Enregistre une liste des associations en CSV (UTF-8 avec BOM) dans le dossier des exports, reçue par parties ; aucun envoi."),

            new OperationDefinition("relations.export.open", OperationClass.Local, (args, _, _) =>
            {
                var values = BridgeArguments.ReadObject(args, OpenArguments);
                var name = BridgeArguments.GetString(values, "fileName");
                if (name.Length is 0 or > 200)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit nommer un export de cette session.");
                }
                return Task.FromResult<object?>(exports.Open(name));
            }, "Ouvre un CSV exporté pendant cette session avec l’application associée de Windows (« Ouvrir le CSV »)."),

            new OperationDefinition("relations.associate.plan", freshRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, AssociateArguments);
                var dn = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "dn"), "dn");
                var subjectGuid = ObjectGuid(values, "subjectGuid");
                var target = BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, "target"), "target");
                var targetGuid = ObjectGuid(values, "targetGuid");
                var draft = await writers.Require<IRelationChangeExecutor>().PlanAssociationAsync(dn, subjectGuid, target, targetGuid, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan d’une association déclarée : sujet et cible relus, GUID comparés à ceux affichés, types opposés ; association locale, Active Directory non modifié."),

            new OperationDefinition("relations.remove.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, RemoveArguments);
                var key = Key(BridgeArguments.GetString(values, "key"), "key");
                var fingerprint = BridgeArguments.GetString(values, "fingerprint");
                if (!IsHex(fingerprint, 64))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("fingerprint") + " doit être une empreinte de 64 caractères hexadécimaux.");
                }
                var draft = await writers.Require<IRelationChangeExecutor>().PlanRemovalAsync(key, fingerprint, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan du retrait d’une association locale, journalisé et restaurable."),

            new OperationDefinition("relations.restore.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, RestoreArguments);
                var entry = BridgeArguments.GetOptionalString(values, "entry");
                if (entry is not null && !IsHex(entry, 32))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("entry") + " doit être un identifiant de 32 caractères hexadécimaux ou null.");
                }
                var draft = await writers.Require<IRelationChangeExecutor>().PlanRestoreAsync(entry, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de la restauration d’une suppression locale (la plus récente par défaut)."),

            new OperationDefinition("relations.import.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ImportPlanArguments);
                var draft = await writers.Require<IRelationChangeExecutor>().PlanImportAsync(Id(values, "previewId"), ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de l’import des lignes valides d’un aperçu (64 au plus), avec son lot de retour arrière."),

            new OperationDefinition("relations.import.undo.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, UndoArguments);
                var batch = BridgeArguments.GetOptionalString(values, "batch");
                if (batch is not null && !BatchPattern().IsMatch(batch))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("batch") + " doit être un identifiant de lot d’import ou null.");
                }
                var draft = await writers.Require<IRelationChangeExecutor>().PlanImportUndoAsync(batch, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan du retrait des associations d’un lot d’import (le plus récent par défaut), journalisé et restaurable."),

            new OperationDefinition("relations.orphans.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, OrphanPlanArguments);
                var checkId = Id(values, "checkId");
                var keys = Strings(values, "keys", 1, WritePlans.MaxChanges, MaxKeyLength, required: true);
                var draft = await writers.Require<IRelationChangeExecutor>().PlanOrphanCleanupAsync(checkId, keys, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan du retrait des associations orphelines cochées (64 au plus) ; déclarées et importées jamais retirées."),

            new OperationDefinition("relations.observations.plan", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ObservationArguments);
                var resultId = Id(values, "resultId");
                var keys = Strings(values, "keys", 0, WritePlans.MaxChanges, MaxKeyLength, required: true);
                var draft = await writers.Require<IRelationChangeExecutor>().PlanObservationsAsync(resultId, keys, ct).ConfigureAwait(false);
                return await circuit.PlanAsync(draft, ct).ConfigureAwait(false);
            }, "Plan de l’enregistrement d’observations gardées par le moteur (détection, lecture de session, relevé, moisson), sans rien retirer."),
        ];
    }

    // ------------------------------------------------------------------ argument rules (docs/ops/relations.md § 2)

    private static string Text(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        if (text.Length > MaxTextLength)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(MaxTextLength) + " caractères.");
        }
        return text;
    }

    private static int Integer(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max)
    {
        if (values.TryGetValue(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) && number >= min && number <= max)
        {
            return number;
        }
        throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un entier de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + ".");
    }

    private static string Id(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var id = BridgeArguments.GetString(values, name);
        return IsHex(id, 32) ? id : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être un identifiant de 32 caractères hexadécimaux.");
    }

    /// <summary>GUID of a directory object shown by the page, in the « D » form (32 hexadecimal digits and 4 hyphens).</summary>
    private static Guid ObjectGuid(IReadOnlyDictionary<string, JsonElement> values, string name)
    {
        var text = BridgeArguments.GetString(values, name);
        return Guid.TryParseExact(text, "D", out var guid) && guid != Guid.Empty
            ? guid
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être le GUID affiché de l’objet (forme 00000000-0000-0000-0000-000000000000).");
    }

    /// <summary>Workstations of a list loaded elsewhere: 50 names (« PC-PAR-0042 ») or DNs at most.</summary>
    private static IReadOnlyList<string> Computers(IReadOnlyDictionary<string, JsonElement> values)
    {
        var computers = Strings(values, "computers", 0, 50, MaxReferenceLength, required: false);
        foreach (var computer in computers)
        {
            if (computer.Contains('=', StringComparison.Ordinal))
            {
                BridgeArguments.RequireDistinguishedName(computer, "computers");
            }
            else if (!ComputerNamePattern().IsMatch(computer))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("computers") + " doit contenir des noms de postes ou des DN.");
            }
        }
        return computers;
    }

    private static string Key(string key, string name) =>
        key.Length is > 0 and <= MaxKeyLength && key.Count(c => c == '|') == 2
            ? key
            : throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une clé d’association.");

    private static IReadOnlyList<string> Strings(IReadOnlyDictionary<string, JsonElement> values, string name, int min, int max, int maxLength, bool required)
    {
        if (!values.TryGetValue(name, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            if (required)
            {
                throw StringsInvalid(name, min, max);
            }
            return [];
        }
        if (value.ValueKind != JsonValueKind.Array)
        {
            throw StringsInvalid(name, min, max);
        }
        var list = new List<string>();
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String || item.GetString() is not { } text || text.Length is 0 || text.Length > maxLength || list.Count >= max)
            {
                throw StringsInvalid(name, min, max);
            }
            list.Add(text);
        }
        return list.Count < min ? throw StringsInvalid(name, min, max) : list;
    }

    private static BridgeOperationException StringsInvalid(string name, int min, int max) =>
        BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste de " + FrenchText.Integer(min) + " à " + FrenchText.Integer(max) + " textes.");

    /// <summary>Name of the file chosen by the operator, without any folder (the page only knows the name), 200 characters at most.</summary>
    private static string FileName(string value)
    {
        var name = value.Replace('\\', '/');
        name = name[(name.LastIndexOf('/') + 1)..].Trim();
        name = string.Concat(name.Where(c => !char.IsControl(c)));
        if (name.Length is 0 or > 200)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("fileName") + " doit être un nom de fichier de 200 caractères au plus.");
        }
        return name;
    }

    private static bool IsHex(string value, int length) =>
        value.Length == length && value.All(c => c is (>= '0' and <= '9') or (>= 'a' and <= 'f'));

    [GeneratedRegex(@"^\d{8}T\d{9}Z-[0-9a-f]{8}$", RegexOptions.CultureInvariant)]
    private static partial Regex BatchPattern();

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$", RegexOptions.CultureInvariant)]
    private static partial Regex ComputerNamePattern();

    /// <summary>Pushes the progress of a probe to the page (« relations.detect.run:progress »), in order, on the calling thread.</summary>
    private sealed class Publisher(BridgeContext bridge) : IProgress<RelationProbeProgress>
    {
        public void Report(RelationProbeProgress value) => bridge.Publish("progress", value);
    }

    /// <summary>
    /// REL-029 (Domenia 1 « Reprise d’accès »): every workstation that refused the console read, or rejected the credentials of
    /// the session, opens one access to review in Comptes (AccountAccess.RegisterRefusal: the workstation account, this
    /// workstation); a rejected authentication also pauses the account in use. Nothing is retried: the operator chooses another
    /// account there, then relaunches the detection.
    /// </summary>
    private static void ReportRefusals(EngineContext context, RelationDetection detection)
    {
        var refused = detection.Attempts.Where(a => a.Target is not null
            && (string.Equals(a.Status, "REFUSE", StringComparison.OrdinalIgnoreCase) || string.Equals(a.Status, RelationProbeLoop.AuthRejected, StringComparison.OrdinalIgnoreCase))).ToList();
        if (refused.Count == 0)
        {
            return;
        }
        var access = AccountAccess.From(context);
        foreach (var attempt in refused.Take(16))
        {
            var kind = string.Equals(attempt.Status, RelationProbeLoop.AuthRejected, StringComparison.OrdinalIgnoreCase) ? "badCredentials" : "accessDenied";
            access.RegisterRefusal(CredentialRules.Remote, "relations.detect.run", attempt.Target, kind, null, interactive: true);
        }
    }
}

/// <summary>Answer of relations.detect.stop.</summary>
public sealed record RelationStopAnswer(bool Stopping, string Message);
