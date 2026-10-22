using System.Collections.Immutable;
using System.Text.Json;
using Domenia.Core;

namespace Domenia.Bridge;

/// <summary>
/// Operations of the Assistance screen (docs/ops/assistance.md): guided recipes, support workshop (findings, captures A/B,
/// pins, explained incidents), support dossier, ticket report and offline dossier. Handlers validate the arguments and
/// delegate: to the pure rules of Domenia.Core, to the local index of the mode (<see cref="IAssistanceIndex"/>, never the
/// network), to the reader of the mode (<see cref="IAssistanceReader"/>, after a gesture, through the
/// <see cref="AssistanceScheduler"/>), to the workshop of the session (<see cref="SupportWorkshop"/>) and to the documents of
/// the screen (<see cref="AssistanceDocuments"/>, over <see cref="EngineContext.Documents"/>). Nothing here writes the
/// directory nor touches the disk itself.
/// </summary>
public sealed class AssistanceOperations : IOperationModule
{
    private const int SearchLimit = 20;
    private const int MaxSearchText = 100;
    private const int MaxTicketText = 200;
    private const int MaxKeyText = 256;
    private const int MaxListName = 255;
    private static readonly string[] SubjectsArguments = ["user", "computer"];
    private static readonly string[] TextArguments = ["text"];
    private static readonly string[] DnArguments = ["dn"];
    private static readonly string[] RunArguments = ["recipe", "step", "dn"];
    private static readonly string[] SlotArguments = ["slot"];
    private static readonly string[] TakeArguments = ["slot", "dn"];
    private static readonly string[] ImportArguments = ["slot", "content"];
    private static readonly string[] IdentityArguments = ["identity"];
    private static readonly string[] NamesArguments = ["names"];
    private static readonly string[] NameArguments = ["name"];
    private static readonly string[] ReportArguments = ["dn", "ticket", "template", "incident", "pseudonymize", "key"];
    private static readonly string[] TicketArguments = ["dn", "sections", "pseudonymize", "key"];
    private static readonly string[] DossierArguments = ["scope", "dn", "ou", "names", "sections"];

    public string Screen => "assistance";

    public IEnumerable<OperationDefinition> CreateOperations(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        var service = new Service(context);
        // Reads of the directory: memory in simulation, the controller in directory mode (after the operator's gesture).
        var directoryRead = context.Mode == AppMode.Simulation ? OperationClass.LocalRead : OperationClass.NetworkRead;
        return
        [
            new OperationDefinition("assistance.overview", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.OverviewAsync(ct).ConfigureAwait(false);
            }, "Recettes, atelier de la session et limites de l’écran Assistance ; aucune lecture de l’annuaire."),

            new OperationDefinition("assistance.recipes", OperationClass.Local, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SubjectsArguments);
                return await service.RecipesAsync(OptionalDn(values, "user"), OptionalDn(values, "computer"), ct).ConfigureAwait(false);
            }, "État de chaque étape des recettes pour le compte et le poste choisis ; rien n’est lu."),

            new OperationDefinition("assistance.subjects.search", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, TextArguments);
                var text = BridgeArguments.GetString(values, "text");
                if (text.Length > MaxSearchText)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("text") + " doit faire au plus 100 caractères.");
                }
                return await service.Index().SearchAsync(text, SearchLimit, ct).ConfigureAwait(false);
            }, "Comptes et postes de l’index local dont le nom contient le texte, 20 au plus."),

            new OperationDefinition("assistance.subjects.suggest", OperationClass.LocalRead, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.SuggestAsync(ct).ConfigureAwait(false);
            }, "Comptes et postes à examiner d’après les données locales (verrouillés, expirés, postes à surveiller)."),

            new OperationDefinition("assistance.computers.resolve", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var names = ReadNames(BridgeArguments.ReadObject(args, NamesArguments), required: true);
                return await service.ResolveComputersAsync(names, ct).ConfigureAwait(false);
            }, "Postes de l’index local nommés exactement dans une liste (500 noms au plus) et noms inconnus."),

            new OperationDefinition("assistance.subject.read", directoryRead, async (args, _, ct) =>
            {
                var dn = RequiredDn(BridgeArguments.ReadObject(args, DnArguments), "dn");
                return await service.ReadSubjectAsync(dn, ct).ConfigureAwait(false);
            }, "Lecture d’un compte ou d’un poste : carte, capture filtrée et masquée, constats locaux."),

            new OperationDefinition("assistance.subject.analyse", OperationClass.Local, async (args, _, ct) =>
            {
                var dn = RequiredDn(BridgeArguments.ReadObject(args, DnArguments), "dn");
                return await service.AnalyseAsync(dn, ct).ConfigureAwait(false);
            }, "Constats recalculés sur la dernière lecture de l’objet, sans nouvelle lecture."),

            new OperationDefinition("assistance.step.run", OperationClass.NetworkRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, RunArguments);
                var recipe = BridgeArguments.GetString(values, "recipe");
                var step = BridgeArguments.GetString(values, "step");
                var dn = RequiredDn(values, "dn");
                return await service.RunStepAsync(recipe, step, dn, ct).ConfigureAwait(false);
            }, "Lance la seule lecture d’une étape de recette, prise dans la liste fermée, pour l’objet choisi.", ServedInSimulation: true),

            new OperationDefinition("assistance.workshop.get", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.WorkshopAsync(ct).ConfigureAwait(false);
            }, "Captures, comparaison, repères et incidents de l’atelier (mémoire de la session)."),

            new OperationDefinition("assistance.workshop.poll", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.PollAsync(ct).ConfigureAwait(false);
            }, "Révision et session de l’atelier, incidents et lectures en cours : ce que la page compare chaque seconde."),

            new OperationDefinition("assistance.workshop.reset", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ResetAsync(ct).ConfigureAwait(false);
            }, "Vide les captures, repères et incidents de l’atelier ; ni l’annuaire ni la base ne sont touchés."),

            new OperationDefinition("assistance.capture.take", OperationClass.Local, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, TakeArguments);
                var slot = Slot(values);
                var dn = RequiredDn(values, "dn");
                return await service.CaptureAsync(slot, dn, ct).ConfigureAwait(false);
            }, "Fige la dernière lecture d’un objet dans l’emplacement A ou B, sans nouvelle lecture."),

            new OperationDefinition("assistance.capture.swap", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.SwapAsync(ct).ConfigureAwait(false);
            }, "Inverse les captures A et B."),

            new OperationDefinition("assistance.capture.clear", OperationClass.Local, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, SlotArguments);
                var slot = BridgeArguments.GetOptionalString(values, "slot");
                if (slot is not (null or "a" or "b"))
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("slot") + " doit valoir a, b ou null.");
                }
                return await service.ClearAsync(slot, ct).ConfigureAwait(false);
            }, "Efface une capture (ou les deux)."),

            new OperationDefinition("assistance.capture.export", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var slot = Slot(BridgeArguments.ReadObject(args, SlotArguments));
                return await service.ExportCaptureAsync(slot, ct).ConfigureAwait(false);
            }, "Enregistre la capture A ou B dans un nouveau fichier Domenia.Capture.1 du dossier des exports."),

            new OperationDefinition("assistance.capture.import", OperationClass.Local, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, ImportArguments);
                var slot = Slot(values);
                var content = BridgeArguments.GetString(values, "content");
                return await service.ImportCaptureAsync(slot, content, ct).ConfigureAwait(false);
            }, "Charge une capture historique du même domaine (contenu d’un fichier choisi par l’opérateur) dans A ou B."),

            new OperationDefinition("assistance.pin.add", OperationClass.Local, async (args, _, ct) =>
            {
                var dn = RequiredDn(BridgeArguments.ReadObject(args, DnArguments), "dn");
                return await service.PinAsync(dn, ct).ConfigureAwait(false);
            }, "Épingle la dernière lecture d’un objet (24 repères au plus, mémoire de la session)."),

            new OperationDefinition("assistance.pin.remove", OperationClass.Local, async (args, _, ct) =>
            {
                var identity = Identity(BridgeArguments.ReadObject(args, IdentityArguments));
                return await service.UnpinAsync(identity, ct).ConfigureAwait(false);
            }, "Retire un repère."),

            new OperationDefinition("assistance.pin.locate", directoryRead, async (args, _, ct) =>
            {
                var identity = Identity(BridgeArguments.ReadObject(args, IdentityArguments));
                return await service.LocateAsync(identity, ct).ConfigureAwait(false);
            }, "Retrouve un objet épinglé par son GUID, même déplacé depuis l’épinglage."),

            new OperationDefinition("assistance.incidents.clear", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.ClearIncidentsAsync(ct).ConfigureAwait(false);
            }, "Efface les incidents expliqués de l’atelier."),

            new OperationDefinition("assistance.report.preview", OperationClass.Local, async (args, _, ct) =>
            {
                var request = ReportRequest.Read(args);
                return await service.ReportAsync(request, ct).ConfigureAwait(false);
            }, "Aperçu du dossier support : fiche, constats, attributs, comparaison A/B, incident choisi et limites."),

            new OperationDefinition("assistance.report.export", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var request = ReportRequest.Read(args);
                return await service.ExportReportAsync(request, ct).ConfigureAwait(false);
            }, "Enregistre le dossier support dans un fichier HTML autonome du dossier des exports."),

            new OperationDefinition("assistance.ticket.preview", OperationClass.Local, async (args, _, ct) =>
            {
                var request = TicketRequest.Read(args);
                return await service.TicketAsync(request, ct).ConfigureAwait(false);
            }, "Aperçu du compte rendu de ticket : tenté, confirmé, refusé et non testé pour l’objet, pseudonymes au choix."),

            new OperationDefinition("assistance.ticket.export", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var request = TicketRequest.Read(args);
                return await service.ExportTicketAsync(request, ct).ConfigureAwait(false);
            }, "Enregistre le compte rendu de ticket dans un fichier texte du dossier des exports."),

            new OperationDefinition("assistance.dossier.prepare", OperationClass.LocalWrite, async (args, _, ct) =>
            {
                var request = DossierArgs.Read(args);
                return await service.DossierAsync(request, ct).ConfigureAwait(false);
            }, "Écrit un dossier de diagnostic hors ligne daté (manifeste et empreintes SHA-256) à partir des données locales."),

            new OperationDefinition("assistance.document.reveal", OperationClass.LocalRead, async (args, _, ct) =>
            {
                var values = BridgeArguments.ReadObject(args, NameArguments);
                var name = BridgeArguments.GetString(values, "name");
                if (name.Length is 0 or > 200)
                {
                    throw BridgeArguments.Invalid(FrenchText.Quote("name") + " doit être le nom d’un document enregistré.");
                }
                return await service.RevealAsync(name, ct).ConfigureAwait(false);
            }, "Montre dans l’Explorateur Windows un document enregistré pendant la session ; rien n’est lu ni écrit."),

            new OperationDefinition("assistance.engine.state", OperationClass.Local, async (args, _, ct) =>
            {
                BridgeArguments.RequireNone(args);
                return await service.EngineStateAsync(ct).ConfigureAwait(false);
            }, "État du moteur sans aucune sonde : mode, capacités, lectures en cours et en attente, atelier."),
        ];
    }

    // ---------------------------------------------------------------- arguments

    private static string RequiredDn(IReadOnlyDictionary<string, JsonElement> values, string name) =>
        BridgeArguments.RequireDistinguishedName(BridgeArguments.GetString(values, name), name);

    private static string? OptionalDn(IReadOnlyDictionary<string, JsonElement> values, string name) =>
        BridgeArguments.GetOptionalString(values, name) is { } dn ? BridgeArguments.RequireDistinguishedName(dn, name) : null;

    private static string Slot(IReadOnlyDictionary<string, JsonElement> values) => BridgeArguments.GetString(values, "slot") switch
    {
        "a" => "a",
        "b" => "b",
        _ => throw BridgeArguments.Invalid(FrenchText.Quote("slot") + " doit valoir a ou b."),
    };

    private static string Identity(IReadOnlyDictionary<string, JsonElement> values)
    {
        var identity = BridgeArguments.GetString(values, "identity");
        return identity.Length is > 0 and <= 4200 && (identity.StartsWith("guid:", StringComparison.Ordinal) || identity.StartsWith("dn:", StringComparison.Ordinal))
            ? identity
            : throw BridgeArguments.Invalid(FrenchText.Quote("identity") + " doit être l’identité d’un repère.");
    }

    private static bool OptionalBoolean(IReadOnlyDictionary<string, JsonElement> values, string name) =>
        values.ContainsKey(name) && BridgeArguments.GetBoolean(values, name);

    private static string? BoundedText(IReadOnlyDictionary<string, JsonElement> values, string name, int maximum)
    {
        var text = BridgeArguments.GetOptionalString(values, name);
        return text is { Length: var length } && length > maximum
            ? throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit faire au plus " + FrenchText.Integer(maximum) + " caractères.")
            : text;
    }

    /// <summary>
    /// List of workstation names (offline dossier « liste de postes »): an array of texts, 500 at most, each of 255 characters at
    /// most; blank entries are ignored. Absent or null gives an empty list unless <paramref name="required"/>.
    /// </summary>
    private static ImmutableArray<string> ReadNames(IReadOnlyDictionary<string, JsonElement> values, bool required)
    {
        if (!values.TryGetValue("names", out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return required ? throw BridgeArguments.Invalid(FrenchText.Quote("names") + " doit être une liste de noms de postes.") : [];
        }
        if (element.ValueKind != JsonValueKind.Array || element.GetArrayLength() > OfflineDossiers.MaxNames)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote("names") + " doit être une liste de " + FrenchText.Integer(OfflineDossiers.MaxNames) + " noms de postes au plus.");
        }
        var names = new List<string>();
        foreach (var item in element.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
            {
                throw BridgeArguments.Invalid(FrenchText.Quote("names") + " doit être une liste de noms de postes.");
            }
            var name = item.GetString()!.Trim();
            if (name.Length > MaxListName)
            {
                throw BridgeArguments.Invalid("Un nom de poste fait au plus " + FrenchText.Integer(MaxListName) + " caractères.");
            }
            if (name.Length > 0)
            {
                names.Add(name);
            }
        }
        return [.. names];
    }

    /// <summary>Optional array of known identifiers; absent or null gives every allowed value.</summary>
    private static ImmutableArray<string> Strings(IReadOnlyDictionary<string, JsonElement> values, string name, ImmutableArray<string> allowed)
    {
        if (!values.TryGetValue(name, out var element) || element.ValueKind == JsonValueKind.Null)
        {
            return allowed;
        }
        if (element.ValueKind != JsonValueKind.Array || element.GetArrayLength() > allowed.Length)
        {
            throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste de valeurs admises.");
        }
        var chosen = new List<string>();
        foreach (var item in element.EnumerateArray())
        {
            var value = item.ValueKind == JsonValueKind.String ? item.GetString()! : "";
            if (!allowed.Contains(value) || chosen.Contains(value))
            {
                throw BridgeArguments.Invalid(FrenchText.Quote(name) + " doit être une liste de valeurs admises.");
            }
            chosen.Add(value);
        }
        return [.. chosen];
    }

    private sealed record ReportRequest(string? Dn, string? Ticket, ReportTemplate Template, string? Incident, bool Pseudonymize, string? Key)
    {
        public static ReportRequest Read(JsonElement args)
        {
            var values = BridgeArguments.ReadObject(args, ReportArguments);
            var template = BridgeArguments.GetOptionalString(values, "template") switch
            {
                null or "text" => ReportTemplate.Text,
                "glpi" => ReportTemplate.Glpi,
                "servicenow" => ReportTemplate.ServiceNow,
                _ => throw BridgeArguments.Invalid(FrenchText.Quote("template") + " doit valoir text, glpi ou servicenow."),
            };
            var incident = BoundedText(values, "incident", 64);
            return new ReportRequest(OptionalDn(values, "dn"), BoundedText(values, "ticket", MaxTicketText), template, incident,
                OptionalBoolean(values, "pseudonymize"), BoundedText(values, "key", MaxKeyText));
        }
    }

    private sealed record TicketRequest(string Dn, ImmutableArray<string> Sections, bool Pseudonymize, string? Key)
    {
        public static TicketRequest Read(JsonElement args)
        {
            var values = BridgeArguments.ReadObject(args, TicketArguments);
            return new TicketRequest(RequiredDn(values, "dn"), Strings(values, "sections", TicketReport.SectionIds), OptionalBoolean(values, "pseudonymize"),
                BoundedText(values, "key", MaxKeyText));
        }
    }

    private sealed record DossierArgs(DossierScope Scope, string? Dn, string? Ou, ImmutableArray<string> Names, ImmutableArray<string> Sections)
    {
        public static DossierArgs Read(JsonElement args)
        {
            var values = BridgeArguments.ReadObject(args, DossierArguments);
            var scope = BridgeArguments.GetString(values, "scope") switch
            {
                "subject" => DossierScope.Subject,
                "workingOu" => DossierScope.WorkingOu,
                "branch" => DossierScope.Branch,
                "pins" => DossierScope.Pins,
                "list" => DossierScope.List,
                _ => throw BridgeArguments.Invalid(FrenchText.Quote("scope") + " doit valoir subject, workingOu, branch, pins ou list."),
            };
            return new DossierArgs(scope, OptionalDn(values, "dn"), OptionalDn(values, "ou"), ReadNames(values, required: false),
                Strings(values, "sections", OfflineDossiers.OptionalSections));
        }
    }

    // ---------------------------------------------------------------- service

    /// <summary>The handlers' logic over the engine services of the context (one per registry).</summary>
    private sealed class Service(EngineContext context)
    {
        private readonly SupportWorkshop workshop = SupportWorkshop.From(context);
        private readonly AssistanceScheduler scheduler = AssistanceScheduler.From(context);
        private readonly AssistanceDocuments documents = AssistanceDocuments.From(context);
        private readonly Lazy<ImmutableArray<AssistanceRecipe>> recipes = new(() =>
        {
            var problems = AssistanceRecipes.Validate(AssistanceRecipes.All);
            return problems.IsEmpty
                ? AssistanceRecipes.All
                : throw new DomeniaOperationException(AssistanceErrors.RecipesInvalid, "Recettes d’assistance invalides" + FrenchText.Colon + string.Join(" ; ", problems));
        }, LazyThreadSafetyMode.ExecutionAndPublication);

        private DateTimeOffset Now => context.Clock.GetUtcNow();

        private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

        /// <summary>The local index of the mode (never the network).</summary>
        public IAssistanceIndex Index() => context.Readers.Require<IAssistanceIndex>();

        /// <summary>The reader of the mode (the directory or a workstation in directory mode, after a gesture).</summary>
        private IAssistanceReader Reader() => context.Readers.Require<IAssistanceReader>();

        private ImmutableArray<AssistanceRecipe> Recipes => recipes.Value;

        private static string KindOf(AssistanceSubject subject) => subject == AssistanceSubject.Computer ? "computer" : "user";

        private void Journal(string label, Tone tone) => context.Journal.Add(new JournalEntry(Now, label, tone));

        private async Task CollectAsync(CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            var index = context.Readers.Find<IAssistanceIndex>();
            var earlier = index is not null && workshop.NeedsSourceIncidents ? await index.SessionIncidentsAsync(ct).ConfigureAwait(false) : [];
            workshop.Collect(earlier);
        }

        public async Task<AssistanceOverview> OverviewAsync(CancellationToken ct)
        {
            await CollectAsync(ct).ConfigureAwait(false);
            var limits = new AssistanceLimits(SupportWorkshop.PinLimit, SupportIncidents.Limit, SupportReport.TicketReferenceLimit, SupportSnapshots.FieldNames.Length,
                SupportSnapshots.MaxValues, OfflineDossiers.MaxNames, Pseudonyms.MinKeyLength);
            return new AssistanceOverview([.. Recipes.Select(r => workshop.Recipe(r, null, null))], workshop.View(), limits,
                context.Readers.Find<IAssistanceReader>() is not null, documents.Persistent, documents.Label);
        }

        public async Task<RecipesView> RecipesAsync(string? user, string? computer, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            return new RecipesView(user, computer, [.. Recipes.Select(r => workshop.Recipe(r, user, computer))]);
        }

        public async Task<ImmutableArray<SubjectSuggestion>> SuggestAsync(CancellationToken ct)
        {
            var index = Index();
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var scope = await WorkingScope.From(context).CurrentAsync(session, ct).ConfigureAwait(false);
            return await index.SuggestionsAsync(scope, ct).ConfigureAwait(false);
        }

        public async Task<ComputerListView> ResolveComputersAsync(ImmutableArray<string> names, CancellationToken ct)
        {
            var found = await Index().ComputersNamedAsync(names, ct).ConfigureAwait(false);
            var matched = new HashSet<string>(found.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
            var unknown = names.Where(n => !matched.Contains(n)).Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray();
            var computers = found.DistinctBy(f => f.Guid).Select(f => f.Computer).ToImmutableArray();
            return new ComputerListView(computers, unknown, names.Length, false);
        }

        /// <summary>A read of the directory, one at a time per object, then ignored when the session changed meanwhile.</summary>
        private async Task<SubjectRecord> ReadRecordAsync(string dn, string token, CancellationToken ct)
        {
            var reader = Reader();
            var record = await scheduler.RunAsync(dn, c => reader.ReadSubjectAsync(dn, c), ct).ConfigureAwait(false)
                ?? throw new DomeniaOperationException(AssistanceErrors.SubjectUnknown, AssistanceErrors.SubjectUnknownMessage);
            await workshop.EnsureSameSessionAsync(token, AssistanceErrors.SessionChangedMessage, ct).ConfigureAwait(false);
            return record;
        }

        public async Task<SubjectView> ReadSubjectAsync(string dn, CancellationToken ct)
        {
            _ = Reader();
            var token = await workshop.SyncAsync(ct).ConfigureAwait(false);
            var record = await ReadRecordAsync(dn, token, ct).ConfigureAwait(false);
            var snapshot = SupportSnapshots.Create(record.Properties, workshop.Scope, record.Dn, record.Name, KindOf(record.Kind), SnapshotSource.Live,
                record.ReadAt, record.ReadAt, record.MemberOfComplete);
            workshop.Remember(record, snapshot);
            return View(record, snapshot);
        }

        public async Task<SubjectView> AnalyseAsync(string dn, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            var known = workshop.LastRead(dn) ?? throw new DomeniaOperationException(AssistanceErrors.NotRead, AssistanceErrors.NotReadMessage);
            return View(known.Record, known.Snapshot);
        }

        private SubjectView View(SubjectRecord record, SupportSnapshot snapshot)
        {
            var findings = SupportFindings.Analyse(snapshot, Now, Zone, record.Signals);
            var relatedLabel = record.Kind == AssistanceSubject.User ? "Postes dont il est responsable (managedBy)" : "Utilisateur responsable (managedBy)";
            var card = new SubjectCard(record.Dn, record.Guid.ToString("D"), record.Kind, AssistanceRecipes.SubjectLabel(record.Kind), record.Name, record.Login, record.Path,
                record.Facts, record.Pills, record.Related, relatedLabel, record.ReadAt);
            return new SubjectView(card, snapshot, findings, SupportWorkshop.CoverageOf(snapshot, Zone));
        }

        public async Task<StepRunResult> RunStepAsync(string recipeId, string stepId, string dn, CancellationToken ct)
        {
            var recipe = Recipes.FirstOrDefault(r => r.Id == recipeId)
                ?? throw new DomeniaOperationException(AssistanceErrors.RecipeUnknown, AssistanceErrors.RecipeUnknownMessage);
            var index = -1;
            for (var i = 0; i < recipe.Steps.Length; i++)
            {
                if (recipe.Steps[i].Id == stepId)
                {
                    index = i;
                    break;
                }
            }
            if (index < 0)
            {
                throw new DomeniaOperationException(AssistanceErrors.StepUnknown, AssistanceErrors.StepUnknownMessage);
            }
            var step = recipe.Steps[index];
            // The read comes from the closed list of the recipe, never from the page.
            var action = (step.Action is null ? null : AssistanceRecipes.FindAction(step.Action))
                ?? throw new DomeniaOperationException(AssistanceErrors.StepWithoutRead, AssistanceErrors.StepWithoutReadMessage);
            var reader = Reader();
            var token = await workshop.SyncAsync(ct).ConfigureAwait(false);
            var record = workshop.LastRead(dn)?.Record ?? await ReadRecordAsync(dn, token, ct).ConfigureAwait(false);
            if (record.Kind != step.Subject || !action.Subjects.Contains(record.Kind))
            {
                throw new DomeniaOperationException(AssistanceErrors.SubjectMismatch, step.Subject == AssistanceSubject.Computer
                    ? "Cette étape concerne un poste" + FrenchText.Colon + "choisissez le poste concerné. Rien n’a été lancé."
                    : "Cette étape concerne un compte" + FrenchText.Colon + "choisissez le compte concerné. Rien n’a été lancé.");
            }
            StepLaunch launch;
            try
            {
                // One read at a time per object, a few in all (the scheduler refuses beyond its waiting list: nothing is started).
                var reading = await scheduler.RunAsync(record.Dn, c => reader.RunStepAsync(action, record, c), ct).ConfigureAwait(false);
                launch = new StepLaunch(Now, StepOutcome.Read, reading, null, null);
            }
            catch (DomeniaOperationException ex) when (ex.Code is AssistanceErrors.ReadRefused or AssistanceErrors.ReadFailed)
            {
                // Recorded, shown and journaled; never retried by the engine nor by the page.
                launch = new StepLaunch(Now, ex.Code == AssistanceErrors.ReadRefused ? StepOutcome.Refused : StepOutcome.Failed, null, ex.Code, ex.Message);
            }
            // The answer of a read started in another session is never kept (Domenia 1 epoch check).
            await workshop.EnsureSameSessionAsync(token, AssistanceErrors.SessionChangedMessage, ct).ConfigureAwait(false);
            if (launch.Outcome == StepOutcome.Read)
            {
                Journal("Assistance · " + action.Label + FrenchText.Colon + record.Name, Tone.Info);
            }
            else
            {
                Journal("Assistance · " + action.Label + " (" + record.Name + ")" + FrenchText.Colon + launch.ErrorMessage, Tone.Warn);
            }
            workshop.RecordLaunch(record.Dn, recipe.Id, step.Id, launch);
            var user = step.Subject == AssistanceSubject.User ? record.Dn : null;
            var computer = step.Subject == AssistanceSubject.Computer ? record.Dn : null;
            var view = workshop.Step(recipe, step, index + 1, user, computer);
            var done = recipe.Steps.Count(s => s.Subject == step.Subject && workshop.Launch(record.Dn, recipe.Id, s.Id)?.Outcome == StepOutcome.Read);
            return new StepRunResult(recipe.Id, view, done, recipe.Steps.Count(s => s.Subject == step.Subject && s.Action is not null));
        }

        public async Task<WorkshopView> WorkshopAsync(CancellationToken ct)
        {
            await CollectAsync(ct).ConfigureAwait(false);
            return workshop.View();
        }

        public async Task<WorkshopPoll> PollAsync(CancellationToken ct)
        {
            await CollectAsync(ct).ConfigureAwait(false);
            var (revision, session, incidents) = workshop.Poll();
            var (running, queued) = scheduler.Counts;
            return new WorkshopPoll(revision, session, incidents, running, queued);
        }

        public async Task<WorkshopView> ResetAsync(CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Reset();
            Journal("Atelier d’assistance vidé" + FrenchText.Colon + "captures, repères et incidents effacés (annuaire et base intacts)", Tone.Info);
            return workshop.View();
        }

        public async Task<WorkshopView> CaptureAsync(string slot, string dn, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Capture(slot, dn);
            return workshop.View();
        }

        public async Task<WorkshopView> SwapAsync(CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Swap();
            return workshop.View();
        }

        public async Task<WorkshopView> ClearAsync(string? slot, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Clear(slot);
            return workshop.View();
        }

        public async Task<ExportResult> ExportCaptureAsync(string slot, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            var snapshot = workshop.Slot(slot);
            var text = CaptureFiles.Export(snapshot);
            var result = await documents.SaveTextAsync("Domenia-Capture-" + slot.ToUpperInvariant() + "-" + documents.Stamp(Now) + ".json", text, ct).ConfigureAwait(false);
            Journal("Capture " + slot.ToUpperInvariant() + (result.Saved ? " enregistrée" : " préparée (non écrite)") + FrenchText.Colon + snapshot.Name, Tone.Info);
            return result;
        }

        public async Task<WorkshopView> ImportCaptureAsync(string slot, string content, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var root = session.Domain?.RootDn
                ?? throw new DomeniaOperationException(AssistanceErrors.CaptureInvalid, "Capture refusée" + FrenchText.Colon + "domaine de la session inconnu. Rien n’a été chargé.");
            var snapshot = CaptureFiles.Import(content, root, Now);
            workshop.Load(slot, snapshot);
            Journal("Capture historique chargée en " + slot.ToUpperInvariant() + FrenchText.Colon + snapshot.Name + " (jamais une lecture actuelle)", Tone.Info);
            return workshop.View();
        }

        public async Task<WorkshopView> PinAsync(string dn, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Pin(dn);
            return workshop.View();
        }

        public async Task<WorkshopView> UnpinAsync(string identity, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.Unpin(identity);
            return workshop.View();
        }

        public async Task<PinLocation> LocateAsync(string identity, CancellationToken ct)
        {
            var token = await workshop.SyncAsync(ct).ConfigureAwait(false);
            var pin = workshop.FindPin(identity);
            var reader = Reader();
            var record = identity.StartsWith("guid:", StringComparison.Ordinal) && Guid.TryParse(identity["guid:".Length..], out var guid)
                ? await scheduler.RunAsync(identity, c => reader.LocateAsync(guid, c), ct).ConfigureAwait(false)
                : await scheduler.RunAsync(pin.Dn, c => reader.ReadSubjectAsync(pin.Dn, c), ct).ConfigureAwait(false);
            await workshop.EnsureSameSessionAsync(token, AssistanceErrors.SessionChangedMessage, ct).ConfigureAwait(false);
            if (record is null)
            {
                throw new DomeniaOperationException(AssistanceErrors.SubjectUnknown, "Objet épinglé introuvable" + FrenchText.Colon + "il a peut-être été supprimé depuis l’épinglage.");
            }
            var moved = !SameDn(pin.Dn, record.Dn);
            workshop.Relocate(identity, record.Dn);
            var message = moved
                ? pin.Name + " a été déplacé depuis l’épinglage" + FrenchText.Colon + "retrouvé par son GUID dans " + record.Path + "."
                : pin.Name + " est toujours à sa place.";
            return new PinLocation(workshop.FindPin(identity), record.Dn, record.Kind, moved, message);
        }

        private static bool SameDn(string left, string right)
        {
            try
            {
                return DistinguishedName.AreEqual(left, right);
            }
            catch (FormatException)
            {
                return false;
            }
        }

        public async Task<WorkshopView> ClearIncidentsAsync(CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            workshop.ClearIncidents();
            return workshop.View();
        }

        private async Task<string> BuildReportAsync(ReportRequest request, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            (SubjectRecord Record, SupportSnapshot Snapshot)? known = request.Dn is null ? null
                : workshop.LastRead(request.Dn) ?? throw new DomeniaOperationException(AssistanceErrors.NotRead, AssistanceErrors.NotReadMessage);
            var view = workshop.View();
            SupportSnapshot? before = null;
            SupportSnapshot? after = null;
            if (view.A is not null && view.B is not null)
            {
                before = workshop.Slot("a");
                after = workshop.Slot("b");
            }
            var incident = request.Incident is null ? null : workshop.Incident(request.Incident);
            var findings = known is { } k ? SupportFindings.Analyse(k.Snapshot, Now, Zone, k.Record.Signals) : [];
            return SupportReport.Build(new SupportReportInput(known?.Snapshot, findings, before, after, incident, request.Ticket, request.Template, Now, Zone, ProductInfo.Name + " " + ProductInfo.Version));
        }

        private async Task<(string Text, ImmutableArray<PseudonymEntry> Map)> ReportTextAsync(ReportRequest request, CancellationToken ct)
        {
            if (request.Pseudonymize && !Pseudonyms.IsValidKey(request.Key))
            {
                throw new DomeniaOperationException(AssistanceErrors.KeyMissing, AssistanceErrors.KeyMissingMessage);
            }
            var text = await BuildReportAsync(request, ct).ConfigureAwait(false);
            if (!request.Pseudonymize)
            {
                return (text, []);
            }
            var known = request.Dn is null ? null : workshop.LastRead(request.Dn);
            var a = workshop.View().A is null ? null : workshop.Slot("a");
            var b = workshop.View().B is null ? null : workshop.Slot("b");
            // Names of the subject and the captures, the manager and the groups their DN cite, then any « CN=… » still in clear.
            var map = Pseudonyms.Map(SupportReport.KnownNames(known?.Snapshot, a, b), request.Key!, TicketReport.DefaultKinds);
            return Pseudonyms.MaskRemainingNames(Pseudonyms.Mask(text, map), map, request.Key!);
        }

        public async Task<DocumentPreview> ReportAsync(ReportRequest request, CancellationToken ct)
        {
            var (text, map) = await ReportTextAsync(request, ct).ConfigureAwait(false);
            return new DocumentPreview("support", true, "", text, TicketReport.Hash(text), text.Split('\n').Length, text.Length, request.Pseudonymize, map, null, null);
        }

        public async Task<ExportResult> ExportReportAsync(ReportRequest request, CancellationToken ct)
        {
            var (text, _) = await ReportTextAsync(request, ct).ConfigureAwait(false);
            var sha = TicketReport.Hash(text);
            var html = SupportReport.Html(text, "Dossier support", sha);
            var result = await documents.SaveTextAsync("Domenia-Support-" + documents.Stamp(Now) + ".html", html, ct).ConfigureAwait(false);
            Journal(result.Saved ? "Dossier support enregistré" + FrenchText.Colon + result.Name : "Dossier support préparé (non écrit dans ce mode)", Tone.Info);
            // The fingerprint returned is the one of the dossier text, as printed at the foot of the HTML document.
            return result with { Sha256 = sha };
        }

        private async Task<TicketReportResult> BuildTicketAsync(TicketRequest request, CancellationToken ct)
        {
            await workshop.SyncAsync(ct).ConfigureAwait(false);
            var known = workshop.LastRead(request.Dn) ?? throw new DomeniaOperationException(AssistanceErrors.NotRead, AssistanceErrors.NotReadMessage);
            var record = known.Record;
            var guid = record.Guid.ToString("D");
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var operatorLogin = session.Account.Login;
            var steps = new List<TicketStep>();
            var identifiers = new List<KnownName> { new(operatorLogin, "Compte", "Compte") };
            var launches = workshop.LaunchesFor(record.Dn);
            foreach (var recipe in Recipes.Where(r => launches.Any(l => l.Recipe == r.Id)))
            {
                foreach (var step in recipe.Steps.Where(s => s.Subject == record.Kind && s.Action is not null))
                {
                    var label = recipe.Title + " · " + step.Title;
                    var launch = launches.FirstOrDefault(l => l.Recipe == recipe.Id && l.Step == step.Id).Launch;
                    if (launch?.Reading is { } reading)
                    {
                        // Workstations, controllers, groups and accounts the read cites are pseudonymised with the subject.
                        identifiers.AddRange(reading.Cited);
                    }
                    steps.Add(launch is null
                        ? new TicketStep(guid, "NotTested", null, label, step.Reads, false, null)
                        : new TicketStep(guid, launch.Outcome switch { StepOutcome.Read => "Confirmed", StepOutcome.Refused => "Refused", _ => "Failed" },
                            launch.At, label, launch.Reading?.Summary ?? launch.ErrorMessage, false, operatorLogin));
                }
            }
            try
            {
                var log = await context.Receipts.ReadAllAsync(ct).ConfigureAwait(false);
                foreach (var receipt in log.Receipts.Where(r => string.Equals(r.Plan.Target.ObjectGuid, guid, StringComparison.OrdinalIgnoreCase)))
                {
                    var status = receipt.Result switch
                    {
                        WriteResult.NotApplied => "Refused",
                        WriteResult.Applied or WriteResult.NoChange when receipt.Verification == VerificationState.Verified => "Verified",
                        _ when receipt.Verification == VerificationState.Mismatch => "Failed",
                        _ => "Sent",
                    };
                    steps.Add(new TicketStep(guid, status, receipt.CompletedAt ?? receipt.SentAt, receipt.Plan.Title, receipt.Plan.Summary, false, receipt.Operator));
                }
            }
            catch (IOException ex)
            {
                context.Log.Warning($"Assistance : reçus illisibles pour le compte rendu ({ex.GetType().Name}).");
            }
            var aliases = new[] { record.Login }
                .Concat(known.Snapshot.Field("userPrincipalName")?.Values ?? [])
                .Concat(known.Snapshot.Field("mail")?.Values ?? [])
                .Concat(known.Snapshot.Field("dNSHostName")?.Values ?? [])
                .Where(a => !string.IsNullOrWhiteSpace(a)).ToImmutableArray();
            identifiers.AddRange(SupportReport.KnownNames(known.Snapshot).Where(n => n.Family is "Utilisateur" or "Groupe"));
            var subject = new TicketSubject(guid, KindOf(record.Kind), record.Name, aliases);
            return TicketReport.Build(subject, steps, request.Sections, request.Pseudonymize, request.Key, TicketReport.DefaultKinds, identifiers, Now, Zone);
        }

        public async Task<DocumentPreview> TicketAsync(TicketRequest request, CancellationToken ct)
        {
            var result = await BuildTicketAsync(request, ct).ConfigureAwait(false);
            return new DocumentPreview("ticket", result.Ready, result.Reason, result.Text, result.Sha256, result.Text.Length == 0 ? 0 : result.Text.Split('\n').Length,
                result.Text.Length, result.Pseudonymized, result.Map, result.Counts, result.Excluded);
        }

        public async Task<ExportResult> ExportTicketAsync(TicketRequest request, CancellationToken ct)
        {
            var result = await BuildTicketAsync(request, ct).ConfigureAwait(false);
            if (!result.Ready)
            {
                // A missing key keeps its own code; any other refusal (an object without GUID…) says its reason.
                throw request.Pseudonymize && !Pseudonyms.IsValidKey(request.Key)
                    ? new DomeniaOperationException(AssistanceErrors.KeyMissing, AssistanceErrors.KeyMissingMessage)
                    : new DomeniaOperationException(AssistanceErrors.TicketRefused, result.Reason);
            }
            var export = await documents.SaveTextAsync("Domenia-Ticket-" + documents.Stamp(Now) + ".txt", result.Text, ct).ConfigureAwait(false);
            Journal(export.Saved ? "Compte rendu de ticket enregistré" + FrenchText.Colon + export.Name : "Compte rendu de ticket préparé (non écrit dans ce mode)", Tone.Info);
            return export;
        }

        public Task<DossierResult> DossierAsync(DossierArgs request, CancellationToken ct) => documents.DossierAsync(async () =>
        {
            var index = Index();
            var token = await workshop.SyncAsync(ct).ConfigureAwait(false);
            var session = await context.Directory.GetSessionAsync(ct).ConfigureAwait(false);
            var workingOu = await WorkingScope.From(context).CurrentAsync(session, ct).ConfigureAwait(false);
            OfflineDossiers.Workstation? subject = null;
            if (request.Dn is { } dn && workshop.LastRead(dn) is { } known && known.Record.Kind == AssistanceSubject.Computer)
            {
                subject = new OfflineDossiers.Workstation(known.Record.Guid.ToString("D"), known.Record.Name);
            }
            var pins = workshop.Pins().Where(p => p.Kind == "computer" && p.Identity.StartsWith("guid:", StringComparison.Ordinal))
                .Select(p => new OfflineDossiers.Workstation(p.Identity["guid:".Length..], p.Name));
            ScopeSelection? branch = null;
            if (request.Scope == DossierScope.Branch && request.Ou is { } ou)
            {
                // The OU chosen in the tree must be known locally (never a guess): the index of the OU, never the network.
                var entry = context.Readers.Find<IOrganizationalUnitIndex>() is { } ous ? await ous.FindLocalAsync(ou, ct).ConfigureAwait(false) : null;
                branch = entry is null
                    ? throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, "OU inconnue de l’index local" + FrenchText.Colon + "choisissez-la dans l’arborescence.")
                    : new ScopeSelection(entry.Dn, entry.Name, true);
            }
            var listed = ImmutableArray<OfflineDossiers.Workstation>.Empty;
            var unresolved = 0;
            if (request.Scope == DossierScope.List)
            {
                var found = await index.ComputersNamedAsync(request.Names, ct).ConfigureAwait(false);
                var matched = new HashSet<string>(found.Select(f => f.Name), StringComparer.OrdinalIgnoreCase);
                unresolved = request.Names.Where(n => !matched.Contains(n)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
                listed = [.. found.Select(f => new OfflineDossiers.Workstation(f.Guid.ToString("D"), f.Computer.Name))];
            }
            var perimeter = OfflineDossiers.Perimeter(request.Scope, subject, workingOu, session.Domain?.RootDn, pins, branch, listed, unresolved);
            var folderSubject = OfflineDossierRunner.FolderSubject(perimeter, subject?.Name ?? (listed.Length == 1 ? listed[0].Name : null));
            var result = await OfflineDossierRunner.RunAsync(index, documents.Store, perimeter, request.Sections, folderSubject, ProductInfo.Version, context.Clock, unresolved,
                c => workshop.EnsureSameSessionAsync(token, AssistanceErrors.DossierStaleMessage, c), ct).ConfigureAwait(false);
            Journal(result.Saved ? "Dossier hors ligne écrit" + FrenchText.Colon + result.Name : "Dossier hors ligne préparé (non écrit dans ce mode)", Tone.Info);
            return result;
        });

        public Task<bool> RevealAsync(string name, CancellationToken ct) => documents.RevealAsync(name, ct);

        public async Task<EngineStateView> EngineStateAsync(CancellationToken ct)
        {
            var info = await DashboardService.From(context).GetSessionInfoAsync(ct).ConfigureAwait(false);
            await CollectAsync(ct).ConfigureAwait(false);
            var (captures, pins, _, steps) = workshop.Counts();
            var (warnings, errors) = workshop.IncidentLevels();
            var (running, queued) = scheduler.Counts;
            var simulation = context.Mode == AppMode.Simulation;
            var hasIndex = context.Readers.Find<IAssistanceIndex>() is not null;
            var hasReader = context.Readers.Find<IAssistanceReader>() is not null;
            var where = simulation ? "annuaire fictif en mémoire" : "base locale";
            ImmutableArray<EngineCapability> capabilities =
            [
                new("Recherche et suggestions", hasIndex, hasIndex ? "Index local (" + where + "), sans accès réseau." : "Index local indisponible dans ce mode."),
                new("Lecture des fiches et des étapes", hasReader, hasReader
                    ? "Sur votre geste seulement" + FrenchText.Colon + "une lecture à la fois par objet, " + FrenchText.Integer(AssistanceScheduler.MaxRunning) + " en parallèle au plus."
                    : "Lecteur de l’annuaire pas encore branché dans cette version."),
                new("Dossier hors ligne", hasIndex, hasIndex ? "Données locales seulement, 500 postes au plus." : "Index local indisponible dans ce mode."),
                new("Documents", true, documents.Persistent ? "Nouveaux fichiers datés, jamais remplacés." : "Gardés en mémoire" + FrenchText.Colon + "rien n’est écrit sur le disque."),
                new("Reçus d’écriture", true, context.Receipts.Persistent ? "Enregistrés sur le disque." : "En mémoire seulement."),
            ];
            var writes = context.Writers.Kinds.Select(k => k switch
            {
                "account.unlock" => "Déverrouillage de compte",
                _ => "Autre écriture du circuit",
            }).Distinct().ToImmutableArray();
            var summary = (running + queued == 0
                    ? "Aucune lecture en cours"
                    : AssistanceText.Count(running, "lecture en cours", "lectures en cours") + ", " + AssistanceText.Count(queued, "en attente", "en attente"))
                + FrenchText.Nbsp + "; état lu sans aucune sonde réseau.";
            return new EngineStateView(simulation ? "simulation" : "annuaire", simulation ? "Simulation" : "Annuaire Active Directory",
                context.Directory.Kind == DirectorySourceKind.Simulation ? "Annuaire fictif en mémoire" : "Active Directory",
                capabilities, writes, running, queued, AssistanceScheduler.MaxRunning, info.Tasks.Running, info.Tasks.Queued, warnings, errors,
                context.Journal.Snapshot().Length, captures, pins, steps, context.Receipts.Persistent, documents.Persistent, documents.Label, summary);
        }
    }
}
