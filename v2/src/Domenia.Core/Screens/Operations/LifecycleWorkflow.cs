using System.Collections.Immutable;

namespace Domenia.Core;

public sealed record LifecycleRequest(LifecycleKind Kind, string Dn, Guid ObjectGuid, ImmutableArray<string> AddGroups,
    ImmutableArray<string> RemoveGroups, ImmutableDictionary<string, string?> Fields, string? TargetDn);
public sealed record LifecycleWorkflowView(string Id, string Dn, string Name, LifecyclePlan Plan, string? PreparedPlanId, string? ReceiptId);
public sealed record LifecyclePrepared(LifecycleWorkflowView Workflow, PlannedWrite? Write);

/// <summary>Session-bound account sequence. Each explicit step uses an ordinary typed write plan; no stored command is replayed.</summary>
public sealed class LifecycleWorkflow(EngineContext context)
{
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, Sequence> sequences = new(StringComparer.Ordinal);
    public static LifecycleWorkflow From(EngineContext context) => context.Shared(static c => new LifecycleWorkflow(c));
    private static DomeniaOperationException Refuse(string text) => new("operations.lifecycleBlocked", text);

    public async Task<LifecycleWorkflowView> CreateAsync(LifecycleRequest request, CancellationToken token)
    {
        Validate(request);
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (sequences.Count >= 8) { throw Refuse("Huit séquences sont déjà gardées dans cette session ; terminez ou fermez une séquence."); }
            var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
            var reader = context.Readers.Require<IFicheReader>();
            var entry = (await reader.ReadAsync(request.Dn, token).ConfigureAwait(false)).Entry;
            if (entry.Kind != FicheKind.User || entry.ObjectGuid != request.ObjectGuid) { throw Refuse("La séquence exige le compte utilisateur sélectionné, avec le même GUID."); }
            var actions = new List<Action>();
            void Add(string title, string kind, string? group = null, Guid? reference = null, bool enabled = false) => actions.Add(new(title, kind, group, reference, enabled));
            async Task Groups()
            {
                foreach (var (group, add) in request.RemoveGroups.Select(d => (d, false)).Concat(request.AddGroups.Select(d => (d, true))))
                {
                    var target = (await reader.ReadAsync(group, token).ConfigureAwait(false)).Entry;
                    if (target.Kind != FicheKind.Group) { throw Refuse("Une cible d’appartenance n’est pas un groupe."); }
                    Add((add ? "Ajouter à " : "Retirer de ") + target.Name, ObjectWrites.MemberKind, group, target.ObjectGuid, add);
                }
            }
            if (request.Kind == LifecycleKind.Arrival)
            {
                Add("Vérifier la fiche, le service et le responsable", LifecyclePlans.ReviewStep);
                if (!request.Fields.IsEmpty) { Add("Mettre à jour la fiche", ObjectWrites.UpdateKind); }
                await Groups().ConfigureAwait(false);
                Add("Activer le compte", ObjectWrites.EnabledKind, enabled: true);
            }
            else if (request.Kind == LifecycleKind.ServiceChange)
            {
                if (!request.Fields.IsEmpty) { Add("Mettre à jour la fiche", ObjectWrites.UpdateKind); }
                await Groups().ConfigureAwait(false);
                if (request.TargetDn is null) { Add("Vérifier la fiche après les changements", LifecyclePlans.ReviewStep); }
            }
            else
            {
                Add("Désactiver le compte", ObjectWrites.EnabledKind);
                Add("Consigner le motif dans la description", ObjectWrites.UpdateKind);
            }
            if (request.TargetDn is { } targetDn)
            {
                var destination = (await reader.ReadAsync(targetDn, token).ConfigureAwait(false)).Entry;
                if (destination.Kind is not (FicheKind.Ou or FicheKind.Container)) { throw Refuse("La destination n’est pas une OU ou un conteneur."); }
                Add("Déplacer vers " + destination.Name, ObjectWrites.MoveKind, targetDn, destination.ObjectGuid);
            }
            var template = LifecyclePlans.New(request.Kind);
            var plan = template with { Steps = [.. actions.Select((a, i) => new LifecycleStep(i + 1, a.Title, a.Kind, a.Kind != LifecyclePlans.ReviewStep, LifecycleStepState.Pending, ""))] };
            var sequence = new Sequence(Guid.NewGuid().ToString("N"), request, session, entry.Name, plan, [.. actions]);
            await CheckSessionAsync(sequence, token).ConfigureAwait(false);
            sequences.Add(sequence.Id, sequence);
            return View(sequence);
        }
        finally { gate.Release(); }
    }

    public async Task<LifecyclePrepared> PrepareAsync(string id, bool review, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var sequence = Get(id); await CheckSessionAsync(sequence, token).ConfigureAwait(false);
            var step = LifecyclePlans.Next(sequence.Plan) ?? throw Refuse(sequence.Plan.Blocked ? sequence.Plan.BlockReason : "Séquence terminée.");
            if (sequence.Prepared is { } existing)
            {
                if (context.Clock.GetUtcNow() >= existing.Plan.ExpiresAt) { throw Refuse("Plan expiré : aucune étape n’est rejouée. Consultez les reçus puis préparez une nouvelle séquence si nécessaire."); }
                return new(View(sequence), existing);
            }
            var action = sequence.Actions[step.Id - 1];
            if (review != (action.Kind == LifecyclePlans.ReviewStep)) { throw Refuse("Le geste demandé ne correspond pas à l’étape courante."); }
            var reader = context.Readers.Require<IFicheReader>();
            var entry = await reader.ReadByGuidAsync(sequence.Request.ObjectGuid, token).ConfigureAwait(false);
            if (entry is null || entry.Kind != FicheKind.User || !DistinguishedName.AreEqual(entry.Dn, sequence.Dn)) { throw Refuse("Le compte a disparu, changé d’identité ou été déplacé ; séquence arrêtée."); }
            if (action.Reference is { } reference)
            {
                var related = (await reader.ReadAsync(action.Group!, token).ConfigureAwait(false)).Entry;
                if (related.ObjectGuid != reference) { throw Refuse("Le groupe ou le conteneur choisi a été recréé ; séquence arrêtée."); }
            }
            if (review)
            {
                await CheckSessionAsync(sequence, token).ConfigureAwait(false);
                sequence.Plan = LifecyclePlans.Record(sequence.Plan, step.Id, LifecycleStepState.Verified, "Fiche relue et contrôle confirmé explicitement par l’opérateur.");
                return new(View(sequence), null);
            }
            try
            {
                var draft = action.Kind switch
                {
                    ObjectWrites.UpdateKind => await context.Writers.Require<IObjectUpdateExecutor>().PlanAsync(sequence.Dn, sequence.Request.Fields, token).ConfigureAwait(false),
                    ObjectWrites.EnabledKind => await context.Writers.Require<IAccountEnabledExecutor>().PlanAsync(sequence.Dn, action.Enabled, token).ConfigureAwait(false),
                    ObjectWrites.MemberKind => await context.Writers.Require<IGroupMemberExecutor>().PlanAsync(action.Group!, sequence.Dn, action.Enabled, token).ConfigureAwait(false),
                    ObjectWrites.MoveKind => await context.Writers.Require<IObjectMoveExecutor>().PlanAsync(sequence.Dn, action.Group!, sequence.Request.ObjectGuid, token).ConfigureAwait(false),
                    _ => throw Refuse("Type d’étape non admis."),
                };
                var expected = action.Kind == ObjectWrites.MemberKind ? action.Reference : sequence.Request.ObjectGuid;
                if (!Guid.TryParse(draft.Target.ObjectGuid, out var actual) || actual != expected) { throw Refuse("Le plan ne cible plus l’objet confirmé."); }
                if (action.Kind == ObjectWrites.MemberKind && draft.Changes.Any(c =>
                    context.Mode != AppMode.Simulation && c.ReferenceGuid is null || c.ReferenceGuid is not null
                    && (!Guid.TryParse(c.ReferenceGuid, out var memberId) || memberId != sequence.Request.ObjectGuid)))
                { throw Refuse("Le membre du plan a changé d’identité."); }
                await CheckSessionAsync(sequence, token).ConfigureAwait(false);
                sequence.Prepared = await WriteCircuit.From(context).PlanAsync(draft, token).ConfigureAwait(false);
                sequence.PreparedStepId = step.Id;
            }
            catch (DomeniaOperationException ex) when (ex.Code == WriteErrors.NothingToDo)
            {
                // The typed planner just proved the desired state; identities are rechecked even when it returns no draft.
                var unchanged = await reader.ReadByGuidAsync(sequence.Request.ObjectGuid, token).ConfigureAwait(false);
                if (unchanged is null || !DistinguishedName.AreEqual(unchanged.Dn, sequence.Dn)) { throw Refuse("Le compte a changé pendant la préparation."); }
                if (action.Reference is { } expectedReference
                    && (await reader.ReadAsync(action.Group!, token).ConfigureAwait(false)).Entry.ObjectGuid != expectedReference)
                { throw Refuse("La référence a changé pendant la préparation."); }
                await CheckSessionAsync(sequence, token).ConfigureAwait(false);
                sequence.Plan = LifecyclePlans.Record(sequence.Plan, step.Id, LifecycleStepState.Verified, "Le planificateur vient de relire l’état demandé ; aucune écriture nécessaire.");
                sequence.Prepared = null;
            }
            return new(View(sequence), sequence.Prepared);
        }
        finally { gate.Release(); }
    }

    public async Task<PlannedWrite> PreparedAsync(string id, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var sequence = Get(id); await CheckSessionAsync(sequence, token).ConfigureAwait(false);
            return sequence.Prepared is { } p && context.Clock.GetUtcNow() < p.Plan.ExpiresAt ? p : throw Refuse("Aucun plan courant ; préparez explicitement l’étape.");
        }
        finally { gate.Release(); }
    }

    public async Task<LifecycleWorkflowView> RecordAsync(string id, string receiptId, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var sequence = Get(id); await CheckSessionAsync(sequence, token).ConfigureAwait(false);
            var receipt = await WriteCircuit.From(context).GetAsync(receiptId, token).ConfigureAwait(false);
            if (sequence.Prepared is not { } prepared || receipt.Plan.Id != prepared.Plan.Id) { throw Refuse("Ce reçu ne correspond pas au plan de l’étape courante."); }
            var step = sequence.Plan.Steps.Single(s => s.Id == sequence.PreparedStepId);
            var outcome = receipt.Pending || receipt.Verification is VerificationState.Unknown or VerificationState.Mismatch
                ? LifecycleStepState.Uncertain
                : receipt.Result is WriteResult.Applied or WriteResult.NoChange && receipt.Verification == VerificationState.Verified ? LifecycleStepState.Verified : LifecycleStepState.Failed;
            sequence.Plan = LifecyclePlans.Record(sequence.Plan, step.Id, outcome, receipt.Summary,
                resolved: step.State == LifecycleStepState.Uncertain && outcome == LifecycleStepState.Verified);
            sequence.ReceiptId = receipt.Id;
            if (outcome == LifecycleStepState.Verified)
            {
                if (receipt.Kind == ObjectWrites.MoveKind) { sequence.Dn = CompensationPlanner.CurrentDn(receipt.Plan); }
                sequence.Prepared = null;
            }
            return View(sequence);
        }
        finally { gate.Release(); }
    }

    public async Task<LifecycleWorkflowView> ReadAsync(string id, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try { var sequence = Get(id); await CheckSessionAsync(sequence, token).ConfigureAwait(false); return View(sequence); }
        finally { gate.Release(); }
    }

    public async Task CloseAsync(string id, CancellationToken token)
    {
        await gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var sequence = Get(id); await CheckSessionAsync(sequence, token).ConfigureAwait(false);
            if (WriteCircuit.From(context).InFlight) { throw Refuse("Une écriture se termine ; attendez son reçu avant de fermer la séquence."); }
            sequences.Remove(id);
        }
        finally { gate.Release(); }
    }

    private async Task CheckSessionAsync(Sequence sequence, CancellationToken token)
    {
        var current = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (current.Epoch != sequence.Session.Epoch || current.Domain != sequence.Session.Domain || current.Account != sequence.Session.Account || current.Controller != sequence.Session.Controller)
        { throw Refuse("Session, identité ou contrôleur changé ; une nouvelle séquence explicite est nécessaire."); }
    }
    private Sequence Get(string id) => sequences.TryGetValue(id, out var value) ? value : throw Refuse("Séquence absente de cette session.");
    private static LifecycleWorkflowView View(Sequence s) => new(s.Id, s.Dn, s.Name, s.Plan, s.Prepared?.Plan.Id, s.ReceiptId);
    public static void Validate(LifecycleRequest request)
    {
        if (!Enum.IsDefined(request.Kind) || request.ObjectGuid == Guid.Empty || request.AddGroups.IsDefault || request.RemoveGroups.IsDefault
            || request.AddGroups.Length + request.RemoveGroups.Length > 20 || request.Fields.Count > 20)
        { throw Refuse("Séquence hors limites : 20 groupes et 20 champs au plus."); }
        _ = DistinguishedName.Parse(request.Dn);
        var groups = request.AddGroups.Concat(request.RemoveGroups).Select(d => DistinguishedName.Format(DistinguishedName.Parse(d))).ToArray();
        if (groups.Distinct(StringComparer.OrdinalIgnoreCase).Count() != groups.Length) { throw Refuse("Un même groupe apparaît plusieurs fois, ou en ajout et retrait."); }
        if (request.TargetDn is not null) { _ = DistinguishedName.Parse(request.TargetDn); }
        if (request.Fields.Any(p => p.Key.Length > 127 || p.Value?.Length > 4096 || WriteKindRules.IsSecretAttribute(p.Key))) { throw Refuse("Champ de séquence invalide ou sensible."); }
        if (request.Kind == LifecycleKind.Suspension && (!request.Fields.TryGetValue("description", out var reason) || string.IsNullOrWhiteSpace(reason)))
        { throw Refuse("La suspension exige un motif dans la description."); }
        if (request.Kind == LifecycleKind.Suspension && (request.AddGroups.Length + request.RemoveGroups.Length > 0 || request.Fields.Keys.Any(k => k != "description")))
        { throw Refuse("Une suspension ne change que l’activation, la description et le conteneur choisi."); }
    }
    private sealed record Action(string Title, string Kind, string? Group, Guid? Reference, bool Enabled);
    private sealed class Sequence(string id, LifecycleRequest request, SessionSnapshot session, string name, LifecyclePlan plan, ImmutableArray<Action> actions)
    {
        public string Id { get; } = id;
        public LifecycleRequest Request { get; } = request;
        public SessionSnapshot Session { get; } = session;
        public string Name { get; } = name;
        public string Dn { get; set; } = request.Dn;
        public LifecyclePlan Plan { get; set; } = plan;
        public ImmutableArray<Action> Actions { get; } = actions;
        public PlannedWrite? Prepared { get; set; }
        public int PreparedStepId { get; set; }
        public string? ReceiptId { get; set; }
    }
}
