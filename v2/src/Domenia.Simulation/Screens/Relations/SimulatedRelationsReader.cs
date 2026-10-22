using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>A detection perimeter kept by the engine: the subject, the exact targets and the kind of probe.</summary>
internal sealed class SimulatedProbePlan
{
    public required string Mode { get; init; }

    public RelationObject? Subject { get; init; }

    public required bool Kerberos { get; init; }

    public RelationDetectionPlan Plan { get; set; } = null!;

    public ImmutableArray<RelationCandidate> Candidates { get; init; } = [];

    private int used;

    /// <summary>Marks the plan as run: a confirmed perimeter is probed once, never again without a new read (relation.planExpired).</summary>
    public bool TryUse() => Interlocked.Exchange(ref used, 1) == 0;
}

/// <summary>Observations of a read kept by the engine, named by the plans of the write circuit.</summary>
internal sealed class SimulatedObservationSet
{
    public required string Origin { get; init; }

    public required ImmutableDictionary<string, StoredRelation> Relations { get; init; }
}

/// <summary>An import preview and the associations it would add.</summary>
internal sealed class SimulatedImportPreview
{
    public RelationImportPreview Preview { get; set; } = null!;

    public required ImmutableArray<StoredRelation> Importable { get; init; }
}

/// <summary>An orphan check: the rows proposed, by key, with the fingerprint seen at the check.</summary>
internal sealed class SimulatedOrphanCheck
{
    public required ImmutableDictionary<string, (string Fingerprint, string Reason)> Rows { get; init; }
}

/// <summary>
/// « Utilisateurs et postes » in simulation (docs/ops/relations.md): the association store of the session
/// (<see cref="SimulatedRelationState"/>, seeded from the generated world), the directory as the session sees it, and
/// deterministic answers for the reads that are network reads in directory mode. No network, no disk. Each read waits a short
/// realistic delay of its own sub-sequence (« latency/screen/relations/… »), none with <see cref="SimulationLatency.None"/>.
/// </summary>
public sealed class SimulatedRelationsReader : IRelationsReader
{
    private const int SubjectLimit = 30;
    private const int TargetLimit = 50;
    private const string SimulatedCompany = "Example";

    private readonly SimulatedDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedRelationsReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    private SimulatedRelationState State => SimulatedRelationState.For(source);

    private string Controller => source.World.Session.Controller?.DnsName ?? "DC01." + SimulationProfile.DnsName;

    private static string C => FrenchText.Colon;

    public async Task<RelationsOverview> OverviewAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("read", 80, 200, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var (rows, _) = Rows(state, lookup);
        var stored = state.Store.Values.ToList();
        var conflicts = RelationRules.Conflicts(stored.Concat(state.Session)).Length;
        var users = rows.Select(r => r.UserGuid ?? "login:" + RelationRules.LoginKey(r.UserLogin)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var computers = rows.Select(r => r.ComputerGuid ?? "name:" + RelationRules.ComputerKey(r.Computer)).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        var summary = FrenchText.Count(rows.Length, "association", "associations") + " entre " + FrenchText.Count(users, "utilisateur", "utilisateurs")
            + " et " + FrenchText.Count(computers, "poste", "postes") + " · " + FrenchText.Count(conflicts, "poste contradictoire", "postes contradictoires") + ".";
        return new RelationsOverview(
            "Mémoire de la simulation",
            true,
            rows.Length,
            users,
            computers,
            RelationProjection.Badges(rows),
            conflicts,
            rows.Count(r => r.Identity == RelationIdentityMatch.Unknown),
            rows.Count(r => r.Persistence == RelationPersistence.Session),
            RelationProjection.LastImport(stored, state.Now, state.Zone),
            RelationProjection.Restore(RelationRules.Restorable(state.Journal).FirstOrDefault(), state.Now, state.Zone),
            RelationProjection.Activity(stored.Concat(state.Session), state.Now, state.Zone),
            state.Journal.Count,
            summary,
            Pending(state));
    }

    public async Task<RelationList> ListAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("read", 100, 260, cancellationToken).ConfigureAwait(false);
        var state = State;
        var (rows, _) = Rows(state, state.Lookup());
        var ordered = rows.OrderByDescending(r => r.When).ThenBy(r => r.Computer, StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        return new RelationList(ordered.Length, RelationProjection.Badges(ordered), ordered,
            RelationProjection.LastImport(state.Store.Values, state.Now, state.Zone),
            RelationProjection.Restore(RelationRules.Restorable(state.Journal).FirstOrDefault(), state.Now, state.Zone));
    }

    public async Task<RelationSubjectView> SubjectAsync(string reference, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(reference);
        await WaitAsync("read", 80, 220, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var subject = lookup.Find(reference) ?? throw new DomeniaOperationException(RelationErrors.Unknown, RelationErrors.UnknownMessage);
        var stored = state.Store.Values.ToList();
        // Only a removal of this subject is offered beside its relations; the last removal of the whole store stays in the
        // header and the journal.
        var restore = RelationRules.Restorable(state.Journal).FirstOrDefault(e => RelationProjection.SubjectRelations([e.Relation], subject).Length > 0);
        return RelationProjection.Subject(subject, RelationRules.Path(subject.Dn, source.World.Directory.Domain.DnsName), stored, state.Session, stored, lookup,
            restore, state.Now, state.Zone);
    }

    public async Task<RelationSubjectMatches> SubjectsAsync(string text, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        await WaitAsync("read", 40, 120, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var links = new Dictionary<Guid, int>();
        foreach (var relation in state.Store.Values)
        {
            if (relation.UserGuid is Guid u)
            {
                links[u] = links.GetValueOrDefault(u) + 1;
            }
            if (relation.ComputerGuid is Guid c)
            {
                links[c] = links.GetValueOrDefault(c) + 1;
            }
        }
        RelationSubjectMatch Match(RelationObject o, string? reason) => new(o.Kind, o.Dn, o.Guid.ToString("D"), o.Name, o.Login, o.Detail, links.GetValueOrDefault(o.Guid), reason);
        var folded = FrenchText.Fold(text.Trim());
        if (folded.Length == 0)
        {
            var suggestions = new List<RelationSubjectMatch>();
            var account = source.World.Session.Account;
            if (account.Dn is not null && lookup.Find(account.Dn) is { } me && links.ContainsKey(me.Guid))
            {
                suggestions.Add(Match(me, "Compte de la session"));
            }
            foreach (var user in lookup.Users.Where(u => u.Enabled && links.ContainsKey(u.Guid) && suggestions.All(s => s.Guid != u.Guid.ToString("D")))
                .OrderByDescending(u => links[u.Guid]).ThenBy(u => u.Login, StringComparer.Ordinal).Take(3))
            {
                suggestions.Add(Match(user, "Le plus d’associations"));
            }
            foreach (var conflict in RelationRules.Conflicts(state.Store.Values.Concat(state.Session)).Take(4))
            {
                if (lookup.ComputerByName(conflict.Computer) is { } computer)
                {
                    suggestions.Add(Match(computer, "Affecté à " + conflict.Declared + ", session de " + conflict.Observed));
                }
            }
            return new RelationSubjectMatches([], false, [.. suggestions]);
        }
        static int Rank(string folded, params string[] values) =>
            values.Any(v => FrenchText.Fold(v) == folded) ? 0 : values.Any(v => FrenchText.Fold(v).StartsWith(folded, StringComparison.Ordinal)) ? 1 : 2;
        var found = lookup.Users.Where(u => FrenchText.Fold(u.Login).Contains(folded, StringComparison.Ordinal) || FrenchText.Fold(u.Name).Contains(folded, StringComparison.Ordinal))
            .Select(u => (Object: u, Rank: Rank(folded, u.Login, u.Name)))
            .Concat(lookup.Computers.Where(c => FrenchText.Fold(c.Name).Contains(folded, StringComparison.Ordinal)).Select(c => (Object: c, Rank: Rank(folded, c.Name))))
            .OrderBy(x => x.Rank).ThenByDescending(x => links.GetValueOrDefault(x.Object.Guid)).ThenBy(x => x.Object.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new RelationSubjectMatches([.. found.Take(SubjectLimit).Select(x => Match(x.Object, null))], found.Count > SubjectLimit, []);
    }

    public async Task<RelationTargetSearch> TargetsAsync(string subjectDn, string text, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(subjectDn);
        ArgumentNullException.ThrowIfNull(text);
        var state = State;
        var lookup = state.Lookup();
        var subject = lookup.Find(subjectDn) ?? throw new DomeniaOperationException(RelationErrors.Unknown, RelationErrors.UnknownMessage);
        var term = text.Trim();
        await WaitAsync("network", 220, 520, cancellationToken).ConfigureAwait(false);
        var folded = FrenchText.Fold(term);
        var targetKind = subject.Kind == RelationSubjectKind.User ? RelationSubjectKind.Computer : RelationSubjectKind.User;
        var directory = lookup.Directory;
        var linked = RelationProjection.SubjectRelations(state.Store.Values, subject)
            .Select(r => (targetKind == RelationSubjectKind.Computer ? r.ComputerGuid : r.UserGuid)?.ToString("D") ?? "")
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        List<RelationTarget> matches;
        if (targetKind == RelationSubjectKind.Computer)
        {
            matches = [.. directory.Computers
                .Where(c => FrenchText.Fold(c.Name).Contains(folded, StringComparison.Ordinal) || FrenchText.Fold(c.DnsHostName ?? "").Contains(folded, StringComparison.Ordinal))
                .OrderBy(c => FrenchText.Fold(c.Name).StartsWith(folded, StringComparison.Ordinal) ? 0 : 1).ThenBy(c => c.Name, StringComparer.Ordinal)
                .Select(c => new RelationTarget(RelationSubjectKind.Computer, c.DistinguishedName, c.ObjectGuid.ToString("D"), c.Name, c.DnsHostName ?? c.Name,
                    string.Join(" · ", new[] { c.OperatingSystem, c.Location }.Where(t => !string.IsNullOrWhiteSpace(t))), !AdValues.IsDisabled(c.UserAccountControl),
                    linked.Contains(c.ObjectGuid.ToString("D"))))];
        }
        else
        {
            matches = [.. directory.Users
                .Where(u => FrenchText.Fold(u.SamAccountName).Contains(folded, StringComparison.Ordinal) || FrenchText.Fold(u.DisplayName ?? u.Cn).Contains(folded, StringComparison.Ordinal)
                    || FrenchText.Fold(u.UserPrincipalName ?? "").StartsWith(folded, StringComparison.Ordinal))
                .OrderBy(u => FrenchText.Fold(u.SamAccountName).StartsWith(folded, StringComparison.Ordinal) ? 0 : 1).ThenBy(u => u.SamAccountName, StringComparer.Ordinal)
                .Select(u => new RelationTarget(RelationSubjectKind.User, u.DistinguishedName, u.ObjectGuid.ToString("D"), u.DisplayName ?? u.Cn, u.SamAccountName,
                    string.Join(" · ", new[] { u.Title, u.Department, u.Office }.Where(t => !string.IsNullOrWhiteSpace(t))), !AdValues.IsDisabled(u.UserAccountControl),
                    linked.Contains(u.ObjectGuid.ToString("D"))))];
        }
        var capped = matches.Count > TargetLimit;
        var shown = matches.Take(TargetLimit).ToImmutableArray();
        var users = targetKind == RelationSubjectKind.User;
        var message = shown.Length == 0
            ? users ? "Aucun utilisateur correspondant dans le domaine." : "Aucun poste correspondant dans le domaine."
            : FrenchText.Count(shown.Length, users ? "utilisateur trouvé" : "poste trouvé", users ? "utilisateurs trouvés" : "postes trouvés")
                + ". Sélectionnez une ligne puis " + (users ? "Associer cet utilisateur." : "Associer ce poste.");
        if (capped)
        {
            message += " Limite atteinte" + C + "affinez la recherche.";
        }
        return new RelationTargetSearch(term, targetKind, shown, capped, message);
    }

    public async Task<RelationDetection> CollectAsync(RelationDetectionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var state = State;
        var lookup = state.Lookup();
        var subject = lookup.Find(request.Dn) ?? throw new DomeniaOperationException(RelationErrors.Unknown, RelationErrors.UnknownMessage);
        if (subject.Kind != RelationSubjectKind.User)
        {
            throw new DomeniaOperationException(RelationErrors.NotRelationObject,
                "La détection des postes concerne un utilisateur" + C + "pour un poste, lisez sa session. Aucun poste contacté.");
        }
        await WaitAsync("network", 380, 820, cancellationToken).ConfigureAwait(false);
        // The account read again must be the object the page showed (Domenia 1 REL-019): another GUID is a recreated account,
        // another identifier a renamed one. The detection stops before anything else is read.
        if (subject.Guid != request.SubjectGuid)
        {
            throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte recréé depuis son affichage" + C
                + "le DN désigne maintenant un autre objet (GUID différent). Rechargez le sujet ; aucun poste contacté.");
        }
        if (!string.Equals(RelationRules.LoginKey(subject.Login), RelationRules.LoginKey(request.SubjectLogin), StringComparison.Ordinal))
        {
            throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte renommé depuis son affichage (" + request.SubjectLogin + " → " + subject.Login + ")" + C
                + "rechargez le sujet ; aucun poste contacté.");
        }
        var random = source.ScreenStream("relations").Fork("collect/" + subject.Guid.ToString("D"));
        var attempts = ImmutableArray.CreateBuilder<RelationAttempt>();
        long elapsed = 0;
        void Attempt(string method, string status, string? target, string detail, string resource = "Annuaire")
        {
            elapsed += random.Next(30, 420);
            var (label, tone) = RelationRules.AttemptStatus(status);
            attempts.Add(new RelationAttempt(method, status, label, tone, target, detail, elapsed, resource));
        }
        Attempt("Compte sélectionné", "OK", subject.Login, "Compte relu sur " + Controller + C + "même GUID et même identifiant que le sujet affiché.", "Annuaire · " + Controller);
        var proofs = new List<RelationProof>();
        var known = RelationProjection.SubjectRelations(state.Store.Values, subject).ToList();
        var observedAt = new Dictionary<string, (DateTimeOffset? When, string Source)>(StringComparer.OrdinalIgnoreCase);
        foreach (var relation in known.GroupBy(r => r.ComputerGuid?.ToString("D") ?? RelationRules.ComputerKey(r.Computer), StringComparer.OrdinalIgnoreCase).Select(g => g.MaxBy(r => r.When)!).Take(50))
        {
            var computer = lookup.Computer(relation.ComputerGuid, relation.Computer);
            if (computer is null)
            {
                var byName = lookup.ComputerByName(relation.Computer);
                Attempt("Association mémorisée", "A_REVOIR", relation.Computer, byName is not null && relation.ComputerGuid is not null
                    ? "GUID différent" + C + "ancien lien conservé comme historique, poste non sondé."
                    : "Poste non résolu de façon unique. Le lien historique reste conservé.");
                continue;
            }
            var when = RelationRules.WhenText(relation.When, state.Now, state.Zone) ?? "date inconnue";
            proofs.Add(new RelationProof(computer.Guid, computer.Name, computer.Dn, null, "Association mémorisée",
                "Lien déjà connu (" + RelationRules.BadgeOf(relation.Kind).Label + ", " + when + ")" + C + "ne prouve pas une session actuelle."));
            observedAt[computer.Guid.ToString("D")] = (relation.When, relation.Source);
        }
        var managed = lookup.Directory.Computers.Where(c => c.ManagedByDn is not null && SameDn(c.ManagedByDn, subject.Dn)).ToList();
        foreach (var computer in managed)
        {
            proofs.Add(new RelationProof(computer.ObjectGuid, computer.Name, computer.DistinguishedName, null, "Responsable déclaré",
                "Indice" + C + "managedBy désigne ce compte dans la fiche AD" + (computer.Description is null ? "." : " (" + computer.Description + ").")));
        }
        Attempt("Responsable déclaré", managed.Count > 0 ? "OK" : "VIDE", null,
            FrenchText.Count(managed.Count, "candidat", "candidats") + " ; aucune session déduite de cet attribut.");
        var mentions = lookup.Directory.Computers.Where(c => (c.Description ?? "").Contains(subject.Login, StringComparison.OrdinalIgnoreCase)
            || (c.Location ?? "").Contains(subject.Login, StringComparison.OrdinalIgnoreCase)).Take(100).ToList();
        foreach (var computer in mentions)
        {
            proofs.Add(new RelationProof(computer.ObjectGuid, computer.Name, computer.DistinguishedName, null, "Mention du compte",
                "Indice textuel" + C + "description ou emplacement mentionne " + subject.Login + "."));
        }
        Attempt("Mention du compte", mentions.Count > 0 ? "OK" : "VIDE", null,
            FrenchText.Count(mentions.Count, "candidat", "candidats") + " (description, emplacement) ; aucune session déduite de ce texte.");
        var hints = ImmutableArray<RelationHint>.Empty;
        if (request.Kerberos)
        {
            hints = SimulatedRelationProbes.Kerberos(state, subject, Controller);
            Attempt("Journal du contrôleur", hints.Length > 0 ? "OK" : "VIDE", Controller,
                FrenchText.Count(hints.Length, "événement ciblé", "événements ciblés") + " sur le SID, sur ce contrôleur uniquement. Les IP ne sont pas associées automatiquement.");
        }
        Attempt("Consoles CIM/DCOM", "NON_DEMANDE", null, "Aucun poste contacté. Le périmètre est montré avant toute lecture de poste.", "Postes");

        var merged = RelationRules.MergeCandidates(proofs);
        var linkedGuids = known.Where(r => r.ComputerGuid is not null).Select(r => r.ComputerGuid!.Value.ToString("D")).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var candidates = merged.Select(m =>
        {
            var isKnown = m.Origins.Contains("Association mémorisée", StringComparison.Ordinal);
            observedAt.TryGetValue(m.Guid ?? "", out var seen);
            var badge = isKnown && seen.Source is not null ? RelationRules.BadgeOf(RelationRules.KindOf(seen.Source)) : RelationRules.BadgeOf(RelationKind.Hint);
            return new RelationCandidate(m.Guid, m.Computer, m.Dn, m.Origins, m.Why, m.Associable, m.Blocker, badge.Badge, badge.Label, badge.Tone,
                isKnown ? "Historique connu" : "Indice AD", null, seen.When, RelationRules.WhenText(seen.When, state.Now, state.Zone), false, isKnown,
                m.Guid is not null && linkedGuids.Contains(m.Guid));
        }).OrderByDescending(c => c.Known).ThenBy(c => c.Computer, StringComparer.Ordinal).ToImmutableArray();

        var domain = lookup.Directory.Domain;
        var holder = new SimulatedProbePlan { Mode = "detect", Subject = subject, Kerberos = request.Kerberos, Candidates = candidates };
        var planId = state.Remember(holder);
        var expires = state.Now + SimulatedRelationState.ResultLifetime;
        IEnumerable<RelationPlanCandidate> perimeter;
        if (request.Scope == "ou")
        {
            var ou = request.OuDn;
            perimeter = ou is null || SameDn(ou, domain.RootDn)
                ? Enumerable.Empty<RelationPlanCandidate>()
                : lookup.Directory.Computers.Where(c => DistinguishedName.IsWithin(c.DistinguishedName, ou, true) && !AdValues.IsDisabled(c.UserAccountControl))
                    .OrderBy(c => c.Name, StringComparer.Ordinal)
                    .Select(c => new RelationPlanCandidate(c.ObjectGuid, c.Name, c.DistinguishedName, domain.RootDn, "OU choisie"));
        }
        else if (request.Scope == "loaded")
        {
            // Names or DNs of the list loaded elsewhere, resolved in the local index only; an unknown name is left out.
            perimeter = request.Computers.Select(reference => lookup.Find(reference)).Where(o => o is { Kind: RelationSubjectKind.Computer })
                .Select(o => new RelationPlanCandidate(o!.Guid, o.Name, o.Dn, domain.RootDn, "Liste chargée"));
        }
        else
        {
            perimeter = candidates.Where(c => c.Guid is not null && c.Dn is not null)
                .Select(c => new RelationPlanCandidate(Guid.Parse(c.Guid!), c.Computer, c.Dn!, domain.RootDn, c.Origins));
        }
        holder.Plan = RelationRules.DetectionPlan(request.Scope, request.OuDn, domain.RootDn, perimeter, request.Limit, planId, expires);
        var message = "Annuaire lu" + C + FrenchText.Count(known.Count, "association connue", "associations connues") + ", "
            + FrenchText.Count(candidates.Count(c => !c.Known), "candidat AD", "candidats AD") + (hints.Length > 0 ? ", " + FrenchText.Count(hints.Length, "indice Kerberos", "indices Kerberos") : "")
            + ". Aucun poste contacté. " + (holder.Plan.Allowed ? "Périmètre à confirmer" + C + holder.Plan.Text : holder.Plan.Reason + " " + holder.Plan.ZeroMeaning);
        var subjectView = SubjectOf(subject);
        return new RelationDetection(planId, "collect", subjectView, attempts.ToImmutable(), candidates, hints, holder.Plan, null, false, true, true, 0, message);
    }

    public async Task<RelationDetection> ProbeAsync(string planId, IProgress<RelationProbeProgress>? progress, CancellationToken stop, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(planId);
        var state = State;
        SimulatedProbePlan holder;
        try
        {
            holder = state.Recall<SimulatedProbePlan>(planId);
        }
        catch (DomeniaOperationException)
        {
            throw new DomeniaOperationException(RelationErrors.PlanExpired, RelationErrors.PlanExpiredMessage);
        }
        var plan = holder.Plan;
        if (!plan.Allowed)
        {
            throw new DomeniaOperationException(RelationErrors.PlanRefused, plan.Reason + " Aucun poste contacté.");
        }
        if (!state.BeginProbe(planId))
        {
            throw new DomeniaOperationException(RelationErrors.ProbeBusy, RelationErrors.ProbeBusyMessage);
        }
        try
        {
            // A confirmed perimeter is probed once: running the same plan again would contact the workstations again without a
            // new read of the directory (Domenia 1 D047).
            if (!holder.TryUse())
            {
                throw new DomeniaOperationException(RelationErrors.PlanExpired, "Périmètre déjà sondé" + C
                    + "relisez l’annuaire pour préparer un nouveau périmètre. Aucun poste contacté en plus.");
            }
            var lookup = state.Lookup();
            var domain = lookup.Directory.Domain;
            var sweep = holder.Mode == "sweep";
            var attempts = ImmutableArray.CreateBuilder<RelationAttempt>();
            var candidates = holder.Candidates.Where(c => c.Guid is not null).ToDictionary(c => c.Guid!, StringComparer.OrdinalIgnoreCase);
            var observations = ImmutableDictionary.CreateBuilder<string, StoredRelation>(StringComparer.Ordinal);
            var observedUsers = new Dictionary<string, RelationObject>(StringComparer.OrdinalIgnoreCase);
            long elapsed = 0;

            async Task<RelationConsoleOutcome> ReadAsync(RelationPlanTarget target, CancellationToken token)
            {
                await WaitAsync("probe", 160, 380, token).ConfigureAwait(false);
                var computer = lookup.Find(target.Dn);
                var now = WritePlans.TruncateToSecond(state.Now);
                if (computer is null || computer.Guid.ToString("D") != target.Guid)
                {
                    return new RelationConsoleOutcome("ERREUR", "Lecture non confirmée", "Objet AD résolu différent de celui confirmé (GUID)" + C + "poste non sondé.", null, 0);
                }
                var reading = SimulatedRelationProbes.Console(state, computer, lookup);
                state.Read(computer.Guid, now);
                if (reading.Account is not null && reading.User is not null)
                {
                    if (sweep)
                    {
                        observedUsers[target.Guid] = reading.User;
                        return new RelationConsoleOutcome("CONFIRME", "Compte console relevé", reading.Detail, reading.Account, reading.DurationMs);
                    }
                    var subject = holder.Subject!;
                    var match = RelationRules.MatchAccount(new RelationAccountTarget(subject.Login, domain.NetbiosName, domain.DnsName, null, subject.Upn), reading.Account, null, target.Computer);
                    if (match.Match)
                    {
                        observedUsers[target.Guid] = subject;
                        return new RelationConsoleOutcome("CONFIRME", "Console confirmée", reading.Detail, reading.Account, reading.DurationMs);
                    }
                    return new RelationConsoleOutcome(reading.Status, "Autre compte console", reading.Detail, reading.Account, reading.DurationMs);
                }
                var label = reading.Status switch
                {
                    "REFUSE" => "Lecture refusée",
                    "AUTH_REJETEE" => "Identifiants rejetés",
                    "DELAI" => "Délai dépassé",
                    "ERREUR" => "Lecture non confirmée",
                    _ => "Aucun compte console",
                };
                return new RelationConsoleOutcome(reading.Status, label, reading.Detail, null, reading.DurationMs);
            }

            // Relevé: a ping by batches first (Domenia 1 REL-031); a workstation that does not answer is not asked for its session.
            async Task<bool> PingAsync(RelationPlanTarget target, CancellationToken token)
            {
                await WaitAsync("ping", 20, 90, token).ConfigureAwait(false);
                var guid = Guid.Parse(target.Guid);
                var observation = source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == guid);
                var computer = lookup.Find(target.Dn);
                return computer is { Enabled: true } && !(observation is not null && observation.Presence.HasReading && observation.Presence.Answered == false);
            }

            void OnStep(RelationProbeStep step)
            {
                var target = step.Target;
                var outcome = step.Outcome;
                elapsed += outcome.DurationMs;
                var (statusLabel, tone) = RelationRules.AttemptStatus(outcome.Status);
                attempts.Add(new RelationAttempt(step.PingFailed ? "Ping groupé" : "Console CIM/DCOM", outcome.Status, statusLabel, tone, target.Computer,
                    outcome.Label + ". " + outcome.Detail, elapsed, step.PingFailed ? "Réseau · ICMP" : "Poste · " + target.Computer));
                var confirmed = outcome.Status == "CONFIRME" && observedUsers.ContainsKey(target.Guid);
                var badge = confirmed ? RelationRules.BadgeOf(RelationKind.Console) : RelationRules.BadgeOf(RelationKind.Hint);
                var now = WritePlans.TruncateToSecond(state.Now);
                candidates.TryGetValue(target.Guid, out var previous);
                candidates[target.Guid] = new RelationCandidate(target.Guid, target.Computer, target.Dn, previous?.Origins ?? target.Source,
                    previous?.Why ?? "Périmètre confirmé" + C + target.Source + ".", true, null, badge.Badge, badge.Label, badge.Tone, outcome.Label,
                    outcome.Account, now, RelationRules.WhenText(now, state.Now, state.Zone), confirmed, previous?.Known ?? false, previous?.AlreadyLinked ?? false);
                if (confirmed && lookup.Find(target.Dn) is { } computer)
                {
                    var user = observedUsers[target.Guid];
                    var relation = new StoredRelation(user.Login, user.Guid, user.Dn, computer.Name, computer.Guid, computer.Dn, RelationKind.Console,
                        RelationRules.ConsoleSource, now, "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null, null);
                    observations[RelationRules.Key(relation)] = relation;
                }
                progress?.Report(new RelationProbeProgress(planId, step.Counters, target.Computer, outcome.Status, outcome.Label, tone, outcome.Account));
            }

            var run = await RelationProbeLoop.RunAsync(plan, ReadAsync, sweep ? PingAsync : (Func<RelationPlanTarget, CancellationToken, Task<bool>>?)null, OnStep, stop, cancellationToken).ConfigureAwait(false);
            var counters = run.Counters;
            var found = observations.ToImmutable();
            state.Observe(found.Values);
            var resultId = state.Remember(new SimulatedObservationSet { Origin = sweep ? "Relevé du parc" : "Détection", Relations = found });
            var message = run.AuthRejected
                ? "Identifiants rejetés par " + run.RejectedOn + C + "relevé arrêté au premier refus, aucun autre poste contacté avec ce compte ; " + counters.Text + "."
                : counters.Stopped
                    ? "Arrêt demandé" + C + "résultat partiel. Les liens enregistrés sont conservés ; " + counters.Text + "."
                    : (sweep ? "Relevé terminé" : "Détection terminée") + C + counters.Text + ".";
            if (!counters.Stopped && !run.Complete)
            {
                message += " Liste confirmée interrogée en partie seulement (limite, délai ou refus).";
            }
            if (run.PingFailures > 0)
            {
                message += " " + FrenchText.Count(run.PingFailures, "poste n’a pas répondu au ping", "postes n’ont pas répondu au ping") + C + "session non demandée.";
            }
            if (counters.Confirmed == 0 && !sweep)
            {
                message += " " + plan.ZeroMeaning;
            }
            if (found.Count > 0)
            {
                message += " " + FrenchText.Count(found.Count, "observation visible", "observations visibles") + " pour la session ; « Enregistrer » les garde par lots de 64, sans retirer aucune association.";
            }
            if (counters.Refused > 0)
            {
                message += " Accès refusé sur au moins un poste" + C + "rien n’est rejoué automatiquement ; relancez avec un compte autorisé.";
            }
            var stored = state.Store;
            var savable = found.Values.Count(r => !stored.TryGetValue(RelationRules.Key(r), out var known) || RelationRules.Fingerprint(known) != RelationRules.Fingerprint(r));
            return new RelationDetection(resultId, sweep ? "sweep" : "probe", holder.Subject is null ? null : SubjectOf(holder.Subject), attempts.ToImmutable(),
                [.. candidates.Values.OrderByDescending(c => c.Confirmed).ThenByDescending(c => c.Known).ThenBy(c => c.Computer, StringComparer.Ordinal)],
                [], plan, counters, counters.Stopped || !run.Complete, run.Within, run.Complete, savable, message);
        }
        finally
        {
            state.EndProbe(planId);
        }
    }

    public async Task<RelationComputerReading> ComputerSessionAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        var state = State;
        var lookup = state.Lookup();
        var computer = lookup.Find(dn) ?? throw new DomeniaOperationException(RelationErrors.Unknown, RelationErrors.UnknownMessage);
        if (computer.Kind != RelationSubjectKind.Computer)
        {
            throw new DomeniaOperationException(RelationErrors.NotRelationObject, "La lecture de session concerne un poste" + C + "pour un utilisateur, détectez ses postes. Aucun poste contacté.");
        }
        await WaitAsync("network", 420, 980, cancellationToken).ConfigureAwait(false);
        var now = WritePlans.TruncateToSecond(state.Now);
        var reading = SimulatedRelationProbes.Console(state, computer, lookup);
        state.Read(computer.Guid, now);
        var (statusLabel, tone) = RelationRules.AttemptStatus(reading.Status);
        var attempts = ImmutableArray.CreateBuilder<RelationAttempt>();
        attempts.Add(new RelationAttempt("Utilisateur courant (Win32_ComputerSystem)", reading.Status, statusLabel, tone, computer.Name, reading.Detail, reading.DurationMs, "Postes"));
        RelationObservedAccount? observed = null;
        string message;
        var savable = false;
        var resultId = "";
        if (reading.Account is not null && reading.User is not null)
        {
            var domain = lookup.Directory.Domain;
            var user = reading.User;
            var match = RelationRules.MatchAccount(new RelationAccountTarget(user.Login, domain.NetbiosName, domain.DnsName, user.Sid, user.Upn), reading.Account, null, computer.Name);
            var badge = RelationRules.BadgeOf(RelationKind.Console);
            attempts.Add(new RelationAttempt("Identité du compte", match.Match ? "OK" : "A_REVOIR", match.Match ? "Réussi" : "À revoir", match.Match ? Tone.Ok : Tone.Warn, reading.Account, match.Reason, reading.DurationMs + 40, "Annuaire"));
            observed = new RelationObservedAccount(reading.Account, user.Login, user.Dn, user.Guid.ToString("D"), user.Name, match.Match, match.Certain, match.Reason,
                RelationRules.ConsoleSource, RelationKind.Console, badge.Badge, badge.Label, now);
            if (match.Match)
            {
                var relation = new StoredRelation(user.Login, user.Guid, user.Dn, computer.Name, computer.Guid, computer.Dn, RelationKind.Console, RelationRules.ConsoleSource, now,
                    "Lecture de la console à cette date ; sessions RDP non recensées. Aucun ancien lien supprimé.", true, null, null);
                state.Observe([relation]);
                resultId = state.Remember(new SimulatedObservationSet { Origin = "Lecture de session", Relations = ImmutableDictionary.CreateRange(StringComparer.Ordinal, [KeyValuePair.Create(RelationRules.Key(relation), relation)]) });
                savable = true;
                message = "Session observée sur " + computer.Name + C + user.Login + " (" + RelationRules.ConsoleSource + " · " + badge.Label + "). « Enregistrer l’observation » la garde à côté des associations existantes.";
            }
            else
            {
                message = "Compte lu sur " + computer.Name + C + reading.Account + ". " + match.Reason + " Aucune association créée" + C
                    + "un compte local, d’un autre domaine ou non qualifié n’est pas un compte AD.";
            }
        }
        else
        {
            message = reading.Status == "LU"
                ? "Aucune session ouverte sur " + computer.Name + " à cette date ; aucune association modifiée."
                : "Lecture de session non confirmée pour " + computer.Name + C + reading.Detail + " Aucune association modifiée.";
        }
        return new RelationComputerReading(resultId, SubjectOf(computer), attempts.ToImmutable(), observed, savable, message);
    }

    public async Task<RelationHarvestEstimate> HarvestEstimateAsync(int days, int maxEvents, CancellationToken cancellationToken)
    {
        await WaitAsync("read", 40, 120, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var users = lookup.Users.Count(u => u.Enabled);
        var computers = lookup.Computers.Count(c => c.Enabled && c.Name.StartsWith("P", StringComparison.Ordinal));
        var estimated = Math.Min(maxEvents, computers * days * 3);
        var seconds = Math.Max(2, estimated / 400 + 2);
        var text = "Lecture du journal Sécurité de " + Controller + " sur " + FrenchText.Count(days, "jour", "jours") + C + "environ " + FrenchText.Integer(estimated)
            + " événements (4768, 4769, 4624), " + FrenchText.Integer(seconds) + " s estimées, " + FrenchText.Integer(maxEvents) + " au plus. Aucun poste n’est contacté ; "
            + "les comptes machines sont ignorés ; une association existante n’est jamais écrasée et rien n’est enregistré sans votre confirmation.";
        var estimate = new RelationHarvestEstimate("", days, maxEvents, Controller, users, computers, estimated, seconds, text, state.Now + SimulatedRelationState.ResultLifetime);
        var id = state.Remember(estimate);
        return estimate with { Id = id };
    }

    public async Task<RelationHarvest> HarvestAsync(string estimateId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(estimateId);
        var state = State;
        var estimate = state.Recall<RelationHarvestEstimate>(estimateId);
        await WaitAsync("network", 700, 1500, cancellationToken).ConfigureAwait(false);
        var lookup = state.Lookup();
        var (couples, events, truncated, machines, unresolved) = SimulatedRelationProbes.Harvest(state, lookup, estimate.Days, estimate.MaxEvents);
        var stored = state.Store.Values.ToList();
        var pairs = stored.Where(r => r.UserGuid is not null && r.ComputerGuid is not null).Select(r => (r.UserGuid!.Value, r.ComputerGuid!.Value)).ToHashSet();
        var observations = ImmutableDictionary.CreateBuilder<string, StoredRelation>(StringComparer.Ordinal);
        var rows = ImmutableArray.CreateBuilder<RelationHarvestCouple>();
        foreach (var couple in couples)
        {
            // The relevé memory of the parc learns the last logon of each workstation (Domenia 1 Complete-DomeniaLogonHarvestUi).
            state.Read(couple.Computer.Guid, couple.Last);
            var known = pairs.Contains((couple.User.Guid, couple.Computer.Guid));
            var relation = new StoredRelation(couple.User.Login, couple.User.Guid, couple.User.Dn, couple.Computer.Name, couple.Computer.Guid, couple.Computer.Dn,
                RelationKind.History, RelationRules.HarvestSource, couple.Last,
                FrenchText.Count(couple.Events, "événement", "événements") + " (" + couple.EventIds + ") du " + (RelationRules.WhenText(couple.First, state.Now, state.Zone) ?? "")
                + " au " + (RelationRules.WhenText(couple.Last, state.Now, state.Zone) ?? "") + " sur " + estimate.Controller + ".", true, null, null);
            var key = RelationRules.Key(relation);
            if (!known)
            {
                // Only the missing couples join the memory (Domenia 1 Add-UserMachineLinkIfMissing): a known one is never overwritten.
                observations[key] = relation;
            }
            rows.Add(new RelationHarvestCouple(key, couple.User.Login, couple.User.Name, couple.User.Dn, couple.Computer.Name, couple.Computer.Dn, couple.First, couple.Last,
                RelationRules.WhenText(couple.Last, state.Now, state.Zone) ?? "", couple.Events, couple.EventIds, known));
        }
        var fresh = observations.ToImmutable();
        state.Observe(fresh.Values);
        var resultId = state.Remember(new SimulatedObservationSet { Origin = "Moisson du journal", Relations = fresh });
        var all = rows.ToImmutable();
        var newCount = all.Count(r => !r.Known);
        var message = FrenchText.Count(events, "événement lu", "événements lus") + " sur " + estimate.Controller + C + FrenchText.Count(all.Length, "couple utilisateur-poste", "couples utilisateur-poste")
            + ", dont " + FrenchText.Count(newCount, "nouveau", "nouveaux") + ". " + FrenchText.Count(machines, "événement de compte machine ignoré", "événements de comptes machines ignorés")
            + ", " + FrenchText.Count(unresolved, "compte introuvable", "comptes introuvables") + " dans l’annuaire. Aucun poste contacté. Les nouveaux couples sont en mémoire pour la session"
            + C + "« Enregistrer » les garde par lots de " + FrenchText.Integer(WritePlans.MaxChanges) + ", chaque lot confirmé et tracé par un reçu.";
        if (truncated)
        {
            message += " Limite de " + FrenchText.Integer(estimate.MaxEvents) + " événements atteinte" + C + "les couples les plus récents sont gardés.";
        }
        return new RelationHarvest(resultId, estimate.Days, events, truncated, machines, unresolved, all, newCount, all.Length - newCount, estimate.Controller, message);
    }

    public async Task<RelationJournal> JournalAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("read", 60, 160, cancellationToken).ConfigureAwait(false);
        var state = State;
        var journal = state.Journal;
        var restorable = RelationRules.Restorable(journal);
        var restorableIds = restorable.Select(e => e.Id).ToHashSet(StringComparer.Ordinal);
        var restoredBy = journal.Where(e => e.Action == RelationJournalAction.Restored && e.Note is not null)
            .GroupBy(e => e.Note!, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Last().Id, StringComparer.Ordinal);
        var entries = journal.Reverse().Select(e =>
        {
            var (label, tone) = RelationRules.JournalAction(e.Action);
            var note = e.Action == RelationJournalAction.Restored ? "Remet en place la suppression du journal." : e.Note;
            return new RelationJournalEntry(e.Id, e.Action, label, tone, e.At, e.Declarant, note, e.Relation.UserLogin, e.Relation.Computer, e.Relation.Kind,
                RelationRules.BadgeOf(e.Relation.Kind).Label, e.Relation.Source, restorableIds.Contains(e.Id), restoredBy.GetValueOrDefault(e.Id));
        }).ToImmutableArray();
        return new RelationJournal(journal.Count, entries,
            [.. restorable.Select(e => RelationProjection.Restore(e, state.Now, state.Zone)!)],
            "Journal local des associations (" + FrenchText.Integer(SimulatedRelationState.JournalCapacity) + " lignes au plus). En simulation, il est tenu en mémoire ; "
            + "en mode annuaire, retraits et restaurations sont aussi écrits à côté de la base pour rester restaurables après un redémarrage.");
    }

    public async Task<RelationImportPreview> ImportPreviewAsync(RelationImportRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await WaitAsync("read", 120, 320, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var adapter = RelationImport.Adapter(request.Adapter);
        if (request.Text.Length > adapter.MaxCharacters)
        {
            throw new DomeniaOperationException(RelationErrors.ImportTooLarge, "Fichier trop volumineux pour un aperçu " + adapter.Label + C + FrenchText.Integer(request.Text.Length)
                + " caractères, limite " + FrenchText.Integer(adapter.MaxCharacters) + " (" + FrenchText.Decimal(adapter.MaxCharacters / 1048576.0) + " Mio). Découpez le fichier ou filtrez l’export.");
        }
        var notes = new List<string>();
        var now = state.Now;
        IReadOnlyList<RelationInventoryRecord> records;
        int total;
        if (request.Adapter == RelationImportAdapter.Osquery)
        {
            var parsed = RelationImport.ParseOsquery(request.Text);
            if (parsed.Format.Length == 0)
            {
                throw new DomeniaOperationException(RelationErrors.ImportEmpty, RelationErrors.ImportEmptyMessage);
            }
            var latest = RelationImport.Latest(parsed.Records, now, state.Zone);
            records = latest.Records;
            total = records.Count;
            if (parsed.Rejected > 0)
            {
                notes.Add(FrenchText.Count(parsed.Rejected, "ligne JSON illisible écartée", "lignes JSON illisibles écartées") + ".");
            }
            if (parsed.Skipped > 0)
            {
                notes.Add(FrenchText.Count(parsed.Skipped, "fin de session ou session sans compte ignorée", "fins de session ou sessions sans compte ignorées") + ".");
            }
            if (latest.Dropped > 0)
            {
                notes.Add(FrenchText.Count(latest.Dropped, "relevé plus ancien des mêmes postes écarté", "relevés plus anciens des mêmes postes écartés") + C + "la date la plus récente départage.");
            }
            if (parsed.Truncated)
            {
                notes.Add("Lecture arrêtée à " + FrenchText.Integer(RelationImport.MaxRecords) + " enregistrements.");
            }
        }
        else
        {
            var csv = RelationImport.ParseCsv(request.Text);
            total = csv.Total;
            records = [.. csv.Rows.Take(RelationImport.PreviewRecords).Select((row, i) => request.Adapter == RelationImportAdapter.Glpi ? RelationImport.GlpiRow(row, i + 1) : RelationImport.CsvRow(row, i + 1))];
            if (csv.Truncated)
            {
                notes.Add("Lecture arrêtée à " + FrenchText.Integer(RelationImport.MaxRecords) + " enregistrements.");
            }
        }
        if (records.Count == 0)
        {
            throw new DomeniaOperationException(RelationErrors.ImportEmpty, RelationErrors.ImportEmptyMessage);
        }
        if (records.Count > RelationImport.PreviewRecords)
        {
            records = [.. records.Take(RelationImport.PreviewRecords)];
        }
        var domain = lookup.Directory.Domain;
        var batch = RelationImport.BatchId(request.Id, now);
        var prepared = records.Select(record =>
        {
            var reject = record.Reject.Length > 0 ? record.Reject : RelationImport.Identity(record.User, record.Computer, domain.DnsName, domain.NetbiosName);
            var user = reject.Length > 0 ? "" : RelationImport.NormalizeUser(record.User);
            var computer = reject.Length > 0 ? "" : RelationImport.NormalizeComputer(record.Computer);
            var when = RelationImport.When(record.When, record.UnixTime, now, state.Zone);
            var both = user.Length > 0 && computer.Length > 0;
            return (Record: record, User: user, Computer: computer, Reject: reject, When: when,
                ComputerKey: both ? RelationRules.ComputerKey(computer) : "", UserKey: both ? RelationRules.LoginKey(user) : "", Ticks: when.Utc?.UtcTicks ?? 0L);
        }).ToList();
        var decisions = RelationImport.Priority([.. prepared.Select(p => (p.Record.Record, p.ComputerKey, p.UserKey, p.Ticks))]);
        // A workstation may carry several relations (declared assignment, observed console, history): the line of the file is
        // « Déjà connue » when any of them names its account, and compared with the primary relation otherwise (never with an
        // arbitrary one, which made the status depend on the order of the store).
        var storedByComputer = state.Store.Values.GroupBy(r => r.ComputerGuid?.ToString("D") ?? "name:" + RelationRules.ComputerKey(r.Computer), StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);
        string? StoredLoginFor(string user, List<StoredRelation>? relations) =>
            relations is null ? null
                : relations.FirstOrDefault(r => string.Equals(RelationRules.LoginKey(r.UserLogin), RelationRules.LoginKey(user), StringComparison.OrdinalIgnoreCase))?.UserLogin
                    ?? RelationRules.Primary(relations)?.UserLogin;
        var operatorLogin = source.World.Session.Account.Login;
        var rows = ImmutableArray.CreateBuilder<RelationImportRow>();
        var importable = ImmutableArray.CreateBuilder<StoredRelation>();
        var ready = 0;
        for (var i = 0; i < prepared.Count; i++)
        {
            var p = prepared[i];
            var decision = decisions[i];
            RelationObject? userEntry = null;
            RelationObject? computerEntry = null;
            string? storedLogin = null;
            if (p.User.Length > 0 && p.Computer.Length > 0)
            {
                userEntry = lookup.UserByLogin(p.User);
                computerEntry = lookup.ComputerByName(p.Computer);
                storedLogin = StoredLoginFor(p.User, storedByComputer.GetValueOrDefault(computerEntry?.Guid.ToString("D") ?? "name:" + RelationRules.ComputerKey(p.Computer)))
                    ?? StoredLoginFor(p.User, storedByComputer.GetValueOrDefault("name:" + RelationRules.ComputerKey(p.Computer)));
            }
            var status = RelationImport.Status(p.User, p.Computer, storedLogin, true, userEntry is not null, computerEntry is not null, "", ready, p.Reject,
                decision.Kind == "Conflit" ? decision.Reason : "", decision.Kind is "Doublon" or "Remplacée" ? decision.Reason : "");
            if (status.Import)
            {
                ready++;
                importable.Add(RelationImport.Imported(request.Adapter, p.User, p.Computer, request.FileName, p.Record.Record, p.Record.FileSource, p.Record.Details, p.When, status.Verified,
                    userEntry is null ? null : new RelationIndexEntry(userEntry.Guid, userEntry.Dn, userEntry.Login),
                    computerEntry is null ? null : new RelationIndexEntry(computerEntry.Guid, computerEntry.Dn, computerEntry.Name), batch, operatorLogin, now));
            }
            rows.Add(new RelationImportRow(p.Record.Record, p.User.Length > 0 ? p.User : p.Record.User, p.Computer.Length > 0 ? p.Computer : p.Record.Computer, status.Status, status.Category, status.Reason, status.Import));
        }
        var all = rows.ToImmutable();
        int CountOf(string category) => all.Count(r => r.Category == category);
        var counts = new RelationImportCounts(CountOf("Valide"), CountOf("Conflit"), CountOf("Rejet"), CountOf("Doublon"), CountOf("Déjà connue"), CountOf("Inconnue"), CountOf("Reportée"));
        var summary = request.FileName + " (" + adapter.Label + ")" + C + FrenchText.Count(ready, "ligne à importer", "lignes à importer") + ", "
            + FrenchText.Count(counts.Conflict, "conflit", "conflits") + ", " + FrenchText.Count(counts.Reject, "rejet", "rejets") + ", "
            + FrenchText.Count(counts.Duplicate, "doublon", "doublons") + ", " + FrenchText.Count(counts.Known, "déjà connue", "déjà connues") + ", "
            + FrenchText.Count(counts.Unknown, "inconnue", "inconnues") + " dans l’index local de l’annuaire.";
        if (counts.Deferred > 0)
        {
            summary += " " + FrenchText.Count(counts.Deferred, "reportée", "reportées") + " au-delà de " + FrenchText.Integer(RelationImport.BatchLimit) + ".";
        }
        if (total > all.Length)
        {
            summary += " Aperçu limité aux " + FrenchText.Integer(all.Length) + " premiers enregistrements sur " + FrenchText.Integer(total) + ".";
        }
        summary += " Comptes et postes vérifiés dans l’index local, sans accès réseau. Les lignes importées portent la source " + FrenchText.Quote(adapter.Source)
            + " (Importé), quelle que soit la colonne Source du fichier ; aucun poste déjà associé n’est remplacé. Lot de retour arrière" + C + batch + ".";
        var holder = new SimulatedImportPreview { Importable = importable.ToImmutable() };
        var id = state.Remember(holder);
        holder.Preview = new RelationImportPreview(id, batch, request.Adapter, adapter.Label, adapter.Source, request.FileName, total, all.Length, ready, counts, "verified",
            [.. notes], summary, all);
        return holder.Preview;
    }

    public async Task<RelationOrphanCheck> OrphansAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("network", 420, 900, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var rows = new List<RelationOrphan>();
        var kept = ImmutableDictionary.CreateBuilder<string, (string, string)>(StringComparer.Ordinal);
        var protectedCount = 0;
        var stored = state.Store.Values.ToList();
        foreach (var relation in stored.OrderByDescending(r => r.When))
        {
            var userExists = lookup.User(relation.UserGuid, relation.UserLogin) is not null;
            var computerExists = lookup.Computer(relation.ComputerGuid, relation.Computer) is not null;
            if (userExists && computerExists)
            {
                continue;
            }
            if (RelationRules.IsProtectedSource(relation.Source))
            {
                protectedCount++;
                continue;
            }
            var key = RelationRules.Key(relation);
            var reason = RelationRules.OrphanReason(userExists, computerExists);
            kept[key] = (RelationRules.Fingerprint(relation), reason);
            rows.Add(new RelationOrphan(key, relation.UserLogin, relation.Computer, relation.Source, reason, relation.When,
                RelationRules.WhenText(relation.When, state.Now, state.Zone), rows.Count < WritePlans.MaxChanges));
        }
        var id = state.Remember(new SimulatedOrphanCheck { Rows = kept.ToImmutable() });
        var summary = rows.Count == 0
            ? FrenchText.Count(stored.Count, "association vérifiée", "associations vérifiées") + " dans Active Directory" + C + "aucune orpheline. Associations déclarées et importées non concernées."
            : FrenchText.Count(rows.Count, "association orpheline", "associations orphelines") + " sur " + FrenchText.Count(stored.Count, "vérifiée", "vérifiées") + C
                + "le compte ou le poste n’est plus trouvé dans Active Directory. Cochez celles à retirer du stockage local ; rien n’est retiré sans confirmation.";
        if (protectedCount > 0)
        {
            summary += " " + FrenchText.Count(protectedCount, "association déclarée ou importée sans objet", "associations déclarées ou importées sans objet") + " jamais proposée" + (protectedCount > 1 ? "s." : ".");
        }
        if (rows.Count > WritePlans.MaxChanges)
        {
            summary += " " + FrenchText.Integer(WritePlans.MaxChanges) + " au plus par retrait" + C + "les premières sont cochées ; retirez-les, puis les suivantes.";
        }
        return new RelationOrphanCheck(id, stored.Count, protectedCount, [.. rows], summary);
    }

    public async Task<UserGroupComparison> CompareAsync(string leftDn, string right, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(leftDn);
        ArgumentNullException.ThrowIfNull(right);
        var directory = source.CurrentDirectory;
        var left = directory.Users.FirstOrDefault(u => SameDn(u.DistinguishedName, leftDn))
            ?? throw new DomeniaOperationException(RelationErrors.NotAUser, RelationErrors.NotAUserMessage);
        var (other, reason) = UserGroupComparer.Resolve(directory, right);
        if (other is null)
        {
            throw new DomeniaOperationException(RelationErrors.CompareUnresolved, reason);
        }
        await WaitAsync("network", 260, 640, cancellationToken).ConfigureAwait(false);
        // The generated directory holds no company: every account of the simulation belongs to « Example », as the Fiche shows it.
        return UserGroupComparer.Compare(left, other, directory, WritePlans.TruncateToSecond(source.Clock.GetUtcNow()), source.World.TimeZone,
            companyOf: static _ => SimulatedCompany);
    }

    public async Task<RelationDetectionPlan> SweepPlanAsync(RelationSweepRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        // The queue of the working OU refuses the root of the domain; a loaded list (Rechercher) does not use the OU at all.
        var scope = request.Computers.Count > 0 ? null
            : request.Scope ?? throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, DomeniaErrors.ScopeTooWideMessage);
        if (scope is not null)
        {
            ScopeRules.EnsureNotDomainRoot(scope, source.World.Directory.Domain.RootDn);
        }
        await WaitAsync("read", 60, 160, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var root = lookup.Directory.Domain.RootDn;
        var forgotten = state.ReadingsForgottenAt;
        var lastConsole = state.Store.Values.Where(r => r.Kind is RelationKind.Console && r.ComputerGuid is not null && r.When is not null && (forgotten is null || r.When > forgotten))
            .GroupBy(r => r.ComputerGuid!.Value).ToDictionary(g => g.Key, g => g.Max(r => r.When));
        DateTimeOffset? LastOf(Guid guid)
        {
            var reading = state.LastReading(guid);
            var console = lastConsole.GetValueOrDefault(guid);
            return reading is null ? console : console is null || reading > console ? reading : console;
        }
        var holder = new SimulatedProbePlan { Mode = "sweep", Subject = null, Kerberos = false };
        var id = state.Remember(holder);
        var expires = state.Now + SimulatedRelationState.ResultLifetime;
        RelationDetectionPlan plan;
        if (request.Computers.Count > 0)
        {
            // List loaded elsewhere (Domenia 1: the rows shown in Rechercher): its workstations, in its order, never more.
            var listed = request.Computers.Select(reference => lookup.Find(reference)).Where(o => o is { Kind: RelationSubjectKind.Computer, Enabled: true })
                .Select(o => new RelationPlanCandidate(o!.Guid, o.Name, o.Dn, root, LastOf(o.Guid) is DateTimeOffset at
                    ? "Liste chargée · relevé du " + (RelationRules.WhenText(at, state.Now, state.Zone) ?? "")
                    : "Liste chargée · jamais relevé"))
                .ToList();
            plan = RelationRules.DetectionPlan("loaded", null, root, listed, request.Limit, id, expires);
            var missing = request.Computers.Count - listed.Count;
            if (plan.Allowed && missing > 0)
            {
                plan = plan with { Text = plan.Text + " " + FrenchText.Count(missing, "nom de la liste écarté", "noms de la liste écartés") + C + "inconnu de l’index local ou compte désactivé." };
            }
        }
        else
        {
            var skipped = 0;
            var queue = new List<(RelationPlanCandidate Candidate, int Order, DateTimeOffset? At)>();
            foreach (var computer in lookup.Directory.Computers.Where(c => ScopeRules.Contains(scope!, c.DistinguishedName) && !AdValues.IsDisabled(c.UserAccountControl)))
            {
                var last = LastOf(computer.ObjectGuid);
                var logon = AdValues.FromFileTime(computer.LastLogonTimestamp);
                if (last is DateTimeOffset reading && (logon is null || logon <= reading))
                {
                    // Not authenticated again since the last relevé: not asked again (Domenia 1 REL-031).
                    skipped++;
                    continue;
                }
                var reason = last is DateTimeOffset at
                    ? "Relevé du " + (RelationRules.WhenText(at, state.Now, state.Zone) ?? "") + ", réauthentifié depuis"
                    : "Jamais relevé";
                queue.Add((new RelationPlanCandidate(computer.ObjectGuid, computer.Name, computer.DistinguishedName, root, reason), last is null ? 0 : 1, last));
            }
            var ordered = queue.OrderBy(q => q.Order).ThenBy(q => q.At).ThenBy(q => q.Candidate.Computer, StringComparer.Ordinal).Select(q => q.Candidate).ToList();
            plan = RelationRules.DetectionPlan("sweep", scope!.Dn, root, ordered, request.Limit, id, expires);
            if (plan.Allowed && skipped > 0)
            {
                plan = plan with { Text = plan.Text + " " + FrenchText.Count(skipped, "poste non réauthentifié", "postes non réauthentifiés") + " depuis son dernier relevé" + C + "non redemandé" + (skipped > 1 ? "s." : ".") };
            }
        }
        if (plan.Allowed)
        {
            plan = plan with { Text = plan.Text + " Ping groupé par lots de " + FrenchText.Integer(RelationProbeLoop.PingBatchSize) + " avant toute lecture de session." };
        }
        holder.Plan = plan;
        return plan;
    }

    public async Task<RelationPendingObservations> PendingAsync(CancellationToken cancellationToken)
    {
        await WaitAsync("read", 20, 60, cancellationToken).ConfigureAwait(false);
        return Pending(State);
    }

    public async Task<RelationObservationReceipt> ObserveAsync(RelationObservationRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        await WaitAsync("read", 10, 40, cancellationToken).ConfigureAwait(false);
        var state = State;
        var lookup = state.Lookup();
        var computer = lookup.Find(request.Computer);
        if (computer is not { Kind: RelationSubjectKind.Computer })
        {
            return new RelationObservationReceipt(false, null, "Poste introuvable dans l’index local" + C + "observation ignorée.");
        }
        var domain = lookup.Directory.Domain;
        var (authority, login, _) = RelationRules.ParseAccount(request.Account);
        var user = login.Length == 0 ? null : lookup.UserByLogin(login);
        if (user is null || user.Dn.Length == 0)
        {
            return new RelationObservationReceipt(false, null, "Compte " + FrenchText.Quote(request.Account) + " absent de l’annuaire" + C
                + "un compte local ou un nom nu n’est jamais réinterprété. Observation ignorée.");
        }
        var match = RelationRules.MatchAccount(new RelationAccountTarget(user.Login, domain.NetbiosName, domain.DnsName, user.Sid, user.Upn), request.Account, null, computer.Name);
        if (!match.Match || authority.Length == 0)
        {
            return new RelationObservationReceipt(false, null, match.Match ? "Compte non qualifié par son domaine" + C + "observation ignorée." : match.Reason + " Observation ignorée.");
        }
        var origin = string.IsNullOrWhiteSpace(request.Source) ? RelationRules.ConsoleSource : RelationRules.Flat(request.Source, 80);
        var kind = RelationRules.KindOf(origin) == RelationKind.RemoteSession ? RelationKind.RemoteSession : RelationKind.Console;
        var relation = new StoredRelation(user.Login, user.Guid, user.Dn, computer.Name, computer.Guid, computer.Dn, kind, origin, WritePlans.TruncateToSecond(request.ObservedAt),
            RelationRules.Flat(request.Detail ?? "Observation versée par un autre écran ; aucun ancien lien supprimé.", 200), true, null, null);
        state.Observe([relation]);
        state.Read(computer.Guid, relation.When!.Value);
        return new RelationObservationReceipt(true, RelationRules.Key(relation), user.Login + " → " + computer.Name + " gardée pour la session (« Session uniquement »)" + C
            + "enregistrez-la depuis Utilisateurs et postes pour la conserver.");
    }

    /// <summary>
    /// Observations not saved yet: the observations of the session as a whole, then every read whose observations are still
    /// pending (a harvest, a relevé, a detection), by source; 64 per plan.
    /// </summary>
    internal static RelationPendingObservations Pending(SimulatedRelationState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var session = state.Session;
        var stored = state.Store;
        var unsaved = session.Where(r => !stored.TryGetValue(RelationRules.Key(r), out var known) || RelationRules.Fingerprint(known) != RelationRules.Fingerprint(r)).ToList();
        var sets = ImmutableArray.CreateBuilder<RelationPendingSet>();
        if (unsaved.Count > 0)
        {
            sets.Add(new RelationPendingSet(RelationChange.SessionResultId, "Observations de la session", unsaved.Count, unsaved.Count, BatchesOf(unsaved.Count), PendingSources(unsaved), null));
        }
        var keys = unsaved.Select(RelationRules.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var (id, set, expires) in state.ObservationSets())
        {
            var remaining = set.Relations.Where(p => keys.Contains(p.Key)).Select(p => p.Value).ToList();
            if (remaining.Count > 0)
            {
                sets.Add(new RelationPendingSet(id, set.Origin, set.Relations.Count, remaining.Count, BatchesOf(remaining.Count), PendingSources(remaining), expires));
            }
        }
        var batches = BatchesOf(unsaved.Count);
        var text = unsaved.Count == 0
            ? "Aucune observation en attente" + C + "tout ce qui a été lu est enregistré."
            : FrenchText.Count(unsaved.Count, "observation en mémoire", "observations en mémoire") + " pour cette session, pas encore enregistrée" + (unsaved.Count > 1 ? "s" : "") + C
                + FrenchText.Count(batches, "lot", "lots") + " de " + FrenchText.Integer(WritePlans.MaxChanges) + " au plus, chacun confirmé et tracé par un reçu.";
        return new RelationPendingObservations(unsaved.Count, batches, sets.ToImmutable(), text);
    }

    private static int BatchesOf(int count) => (count + WritePlans.MaxChanges - 1) / WritePlans.MaxChanges;

    private static ImmutableArray<RelationPendingSource> PendingSources(IEnumerable<StoredRelation> relations) =>
        [.. relations.GroupBy(r => r.Source, StringComparer.Ordinal).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal)
            .Select(g => new RelationPendingSource(g.Key, g.Count()))];

    // ------------------------------------------------------------------ helpers

    private (ImmutableArray<RelationRow> Rows, ImmutableHashSet<string> Contradicted) Rows(SimulatedRelationState state, SimulatedRelationLookup lookup)
    {
        // One lookup per observation (the store is keyed by relation): an observation is hidden only when the same relation is
        // stored with the same fingerprint, the rule of the pending observations; a newer one stays visible and counted.
        var store = state.Store;
        var stored = store.Values.ToList();
        var session = state.Session.Where(s => !(store.TryGetValue(RelationRules.Key(s), out var known)
            && string.Equals(RelationRules.Fingerprint(known), RelationRules.Fingerprint(s), StringComparison.Ordinal))).ToList();
        var contradicted = RelationProjection.ContradictedKeys(stored.Concat(session));
        var rows = stored.Select(r => RelationProjection.Row(r, lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Stored, state.Now, state.Zone))
            .Concat(session.Select(r => RelationProjection.Row(r, lookup, contradicted.Contains(RelationRules.Key(r)), RelationPersistence.Session, state.Now, state.Zone)))
            .ToImmutableArray();
        return (rows, contradicted);
    }

    private RelationSubject SubjectOf(RelationObject o) =>
        new(o.Kind, o.Dn, o.Guid.ToString("D"), o.Name, o.Login, o.Detail, RelationRules.Path(o.Dn, source.World.Directory.Domain.DnsName), o.Enabled, o.LastLogon, o.Created);

    private Task WaitAsync(string kind, int min, int max, CancellationToken cancellationToken) =>
        source.SimulateScreenLatencyAsync("relations/" + kind, min, max, cancellationToken);

    private static bool SameDn(string left, string right)
    {
        if (string.Equals(left, right, StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return false;
        }
    }
}
