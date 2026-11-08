using System.Collections.Immutable;

namespace Domenia.Core;

public sealed record NetworkDiagnosticIdentity(Guid ObjectGuid, string Dn, string Sid, string Sam, string Host, DateTimeOffset Created)
{
    public static NetworkDiagnosticIdentity? Capture(DirectoryComputer pc) => pc.ObjectGuid == Guid.Empty || string.IsNullOrWhiteSpace(pc.DnsHostName)
        || string.IsNullOrWhiteSpace(pc.Sid) || string.IsNullOrWhiteSpace(pc.SamAccountName) || pc.LegacyIndexOnly ? null
        : new(pc.ObjectGuid, pc.DistinguishedName, pc.Sid, pc.SamAccountName, pc.DnsHostName, pc.WhenCreated);
    public bool Matches(DirectoryComputer pc) => ObjectGuid == pc.ObjectGuid && DistinguishedName.AreEqual(Dn, pc.DistinguishedName)
        && Sid.Equals(pc.Sid, StringComparison.OrdinalIgnoreCase) && Sam.Equals(pc.SamAccountName, StringComparison.OrdinalIgnoreCase)
        && Host.Equals(pc.DnsHostName, StringComparison.OrdinalIgnoreCase) && Created == pc.WhenCreated && !pc.LegacyIndexOnly && !AdValues.IsDisabled(pc.UserAccountControl);
}
public sealed record NetworkDiagnosticTarget(string Id, string Name, string Dn, string? Address, string Host);
public sealed record NetworkDiagnosticPlan(string PlanId, ImmutableArray<NetworkDiagnosticTarget> Targets,
    ImmutableArray<SurveyExcluded> Excluded, bool TypedCountRequired, DateTimeOffset ExpiresAt);

public sealed partial class SearchService
{
    private readonly Dictionary<string, PendingDiagnostic> diagnosticPlans = new(StringComparer.Ordinal);
    private sealed record DiagnosticTarget(string Id, string Name, string Dn, string? Ip, NetworkDiagnosticIdentity Identity)
    {
        internal static DiagnosticTarget Of(SearchRow row, NetworkDiagnosticIdentity identity) => new(row.Id, row.Name, row.Dn, row.Address?.Ip, identity);
    }
    private sealed record PendingDiagnostic(string ListId, ListState List, ReconcileOwner Owner,
        ImmutableArray<DiagnosticTarget> Targets, ImmutableArray<SurveyExcluded> Excluded, DateTimeOffset Expires);

    public async Task<NetworkDiagnosticPlan> DiagnosticPlanAsync(string listId, IReadOnlyList<Guid> ids, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(ids);
        if (ids.Count is < 1 or > 5000) throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Sélection de diagnostic hors limites.");
        var state = RequireList(listId);
        EnsureDiagnosticList(state);
        var owner = await ReconcileOwnerAsync(token).ConfigureAwait(false);
        var known = KnownOf(state);
        var distinct = ids.Distinct().ToArray();
        if (distinct.Any(id => !known.Contains(id.ToString("D"))))
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Une cible n’appartient pas à la liste affichée ; rien n’est envoyé.");
        var rows = await context.Readers.Require<ISearchReader>().LocalRowsAsync(distinct, token).ConfigureAwait(false);
        var indexed = rows.GroupBy(row => Guid.TryParse(row.Id, out var value) ? value : Guid.Empty).ToDictionary(group => group.Key, group => group.ToArray());
        var selected = distinct.ToHashSet();
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var computers = local.Directory.Computers.Where(pc => selected.Contains(pc.ObjectGuid)).GroupBy(pc => pc.ObjectGuid).ToDictionary(group => group.Key, group => group.ToArray());
        var targets = ImmutableArray.CreateBuilder<DiagnosticTarget>();
        var excluded = ImmutableArray.CreateBuilder<SurveyExcluded>();
        foreach (var id in distinct)
        {
            var matches = indexed.GetValueOrDefault(id) ?? [];
            if (matches.Length != 1) { excluded.Add(new(id.ToString("D"), "identité locale absente ou ambiguë")); continue; }
            var row = matches[0];
            var matching = computers.GetValueOrDefault(id);
            var identity = matching is { Length: 1 } ? NetworkDiagnosticIdentity.Capture(matching[0]) : null;
            var reason = row.Kind != SearchObjectKind.Computer ? "pas un poste"
                : row.Flags.Disabled ? "compte ordinateur désactivé"
                : identity is null || !DistinguishedName.AreEqual(identity.Dn, row.Dn) ? "identité réseau locale absente ou ambiguë"
                : targets.Count >= SearchSurvey.MaxDiagnostic ? "au-delà de la limite de 50 postes" : null;
            if (reason is not null) excluded.Add(new(row.Name, reason));
            else targets.Add(DiagnosticTarget.Of(row, identity!));
        }
        if (targets.Count == 0) throw new DomeniaOperationException(SearchErrors.SurveyRefused, "Aucun poste actif à diagnostiquer.");
        if (owner != await ReconcileOwnerAsync(token).ConfigureAwait(false)) throw DiagnosticChanged();
        var now = context.Clock.GetUtcNow(); var expires = now + PlanLifetime; var idPlan = NewId();
        var pending = new PendingDiagnostic(listId, state, owner, targets.ToImmutable(), excluded.ToImmutable(), expires);
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!lists.TryGetValue(listId, out var current) || !ReferenceEquals(current, state)) throw DiagnosticChanged();
            EnsureDiagnosticList(state);
            foreach (var key in diagnosticPlans.Where(p => p.Value.Expires <= now).Select(p => p.Key).ToArray()) diagnosticPlans.Remove(key);
            while (diagnosticPlans.Count >= MaxPlans) diagnosticPlans.Remove(diagnosticPlans.MinBy(p => p.Value.Expires).Key);
            diagnosticPlans.Add(idPlan, pending);
        }
        return new(idPlan, pending.Targets.Select(t => new NetworkDiagnosticTarget(t.Id, t.Name, t.Dn, t.Ip, t.Identity.Host)).ToImmutableArray(),
            pending.Excluded, targets.Count >= 2, expires);
    }

    public async Task<NetworkDiagnostic> DiagnoseAsync(string planId, int? typedCount, CancellationToken token)
    {
        PendingDiagnostic plan;
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (!diagnosticPlans.Remove(planId, out var found) || found.Expires <= context.Clock.GetUtcNow())
                throw new DomeniaOperationException(SearchErrors.SurveyPlanUnknown, SearchErrors.SurveyPlanUnknownMessage);
            plan = found;
        }
        if (plan.Targets.Length >= 2 && typedCount != plan.Targets.Length)
            throw new DomeniaOperationException(SearchErrors.SurveyTypedCount, "Saisissez le nombre exact de postes avant de lancer le diagnostic.");
        var reader = context.Readers.Require<ISearchReader>();
        var lines = ImmutableArray.CreateBuilder<NetworkDiagnosticLine>();
        foreach (var target in plan.Targets)
        {
            token.ThrowIfCancellationRequested();
            var state = RequireList(plan.ListId);
            if (!ReferenceEquals(state, plan.List) || !KnownOf(state).Contains(target.Id)) throw DiagnosticChanged();
            EnsureDiagnosticList(state);
            if (plan.Owner != await ReconcileOwnerAsync(token).ConfigureAwait(false)) throw DiagnosticChanged();
            var rows = await reader.LocalRowsAsync([Guid.Parse(target.Id)], token).ConfigureAwait(false);
            if (rows.Length != 1 || rows[0].Kind != SearchObjectKind.Computer || rows[0].Flags.Disabled || DiagnosticTarget.Of(rows[0], target.Identity) != target)
                throw DiagnosticChanged();
            if (plan.Owner != await ReconcileOwnerAsync(token).ConfigureAwait(false)) throw DiagnosticChanged();
            lines.Add(await reader.DiagnoseAsync(target.Identity, token).ConfigureAwait(false));
            if (plan.Owner != await ReconcileOwnerAsync(token).ConfigureAwait(false)) throw DiagnosticChanged();
        }
        var built = lines.ToImmutable();
        var summary = FrenchText.Count(built.Length, "poste diagnostiqué", "postes diagnostiqués") + " · "
            + FrenchText.Integer(built.Count(l => l.Ping.State == SearchPresenceState.Online)) + " répondent au ping · aucun compte envoyé, rien modifié.";
        Journal("Diagnostic réseau groupé" + FrenchText.Colon + summary, Tone.Info);
        return new(built, plan.Excluded, summary, SearchSurvey.Report(built), context.Clock.GetUtcNow());
    }

    private static void EnsureDiagnosticList(ListState state)
    {
        if (state.Interrupted || state.View is { SurveyAllowed: false })
            throw new DomeniaOperationException(SearchErrors.SurveyRefused, state.View?.Reason ?? "Liste interrompue ; relancez la recherche.");
    }
    private static DomeniaOperationException DiagnosticChanged() => new(SearchErrors.SurveyRefused,
        "La session, le périmètre ou une cible a changé depuis la confirmation ; relancez le plan de diagnostic.");
}
