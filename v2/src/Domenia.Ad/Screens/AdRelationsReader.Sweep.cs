using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    public async Task<RelationDetectionPlan> SweepPlanAsync(RelationSweepRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request); ArgumentNullException.ThrowIfNull(request.Computers);
        if (request.Limit is < 1 or > 50 || request.Computers.Count > 50 || request.Computers.Any(c => c is null || c.Length is 0 or > 4096 || c.Any(char.IsControl)))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Relevé limité à 50 postes et références valides."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false); var domain = local.Directory.Domain;
        var scope = request.Computers.Count > 0 ? null : request.Scope;
        if (request.Computers.Count == 0)
        {
            ScopeRules.EnsureNotDomainRoot(scope, domain.RootDn);
            AdRelationDirectory.ValidateDn(scope!.Dn, domain);
            if (!DistinguishedName.Parse(scope.Dn)[0].Type.Equals("OU", StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, "Choisissez une OU explicite pour le relevé ; aucun conteneur ni domaine entier substitué."); }
        }
        if (source.LocalStore is not IRelationSweepCache cache)
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Mémoire locale des relevés indisponible ; aucun périmètre de remplacement."); }
        var memory = await cache.ReadRelationSweepsAsync(cancellationToken).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        if (memory.StoreId != local.Stored.StoreId || !DistinguishedName.AreEqual(memory.DomainDn, domain.RootDn))
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Mémoire des relevés d’une autre base ou d’un autre domaine."); }
        // Only a unique dated GUID can suppress a computer in the queue. Legacy names are visible evidence, never a new identity.
        var readings = memory.Rows.Where(r => r.ComputerGuid is not null).GroupBy(r => r.ComputerGuid!.Value).Where(g => g.Count() == 1)
            .ToDictionary(g => g.Key, g => g.Single());
        var objects = local.Lookup.Computers.ToDictionary(c => c.Guid);
        var machines = local.Directory.Computers.Where(c => objects.ContainsKey(c.ObjectGuid)).ToDictionary(c => c.ObjectGuid);
        bool Eligible(RelationObject computer) => computer.Enabled && machines.TryGetValue(computer.Guid, out var machine)
            && (machine.UserAccountControl & 8192) == 0 && machine.DnsHostName is { } dns && CimQuery.IsHostName(dns)
            && WorkstationIdentity.ExpectedName(machine) is not null;
        DateTimeOffset? LastOf(RelationObject computer)
        {
            if (memory.Truncated || memory.Rejected > 0 || !readings.TryGetValue(computer.Guid, out var record) || record.At is not { } at
                || at < computer.Created || at > source.Clock.GetUtcNow()
                || record.ComputerDn is { } dn && !DistinguishedName.AreEqual(dn, computer.Dn)
                || !string.Equals(record.Computer, computer.Name, StringComparison.OrdinalIgnoreCase)) { return null; }
            return at;
        }
        var candidates = new List<RelationPlanCandidate>(); var omitted = 0; var skipped = 0;
        if (request.Computers.Count > 0)
        {
            foreach (var reference in request.Computers)
            {
                var found = local.Lookup.Find(reference);
                if (found is not { Kind: RelationSubjectKind.Computer } || !Eligible(found)) { omitted++; continue; }
                candidates.Add(new(found.Guid, found.Name, found.Dn, domain.RootDn, "Liste chargée · "
                    + (LastOf(found) is { } at ? "relevé du " + RelationRules.WhenText(at, source.Clock.GetUtcNow(), source.Zone) : "aucun relevé lié au GUID")));
            }
        }
        else
        {
            var queue = new List<(RelationObject Computer, DateTimeOffset? Last)>();
            foreach (var computer in objects.Values.Where(c => ScopeRules.Contains(scope!, c.Dn)))
            {
                if (!Eligible(computer)) { omitted++; continue; }
                var last = LastOf(computer);
                var complete = readings.TryGetValue(computer.Guid, out var previous)
                    && new[] { "SESSION", "CONFIRME", "LU", "VIDE", "OBSERVED", "EMPTY" }.Contains(previous.Status.ToUpperInvariant(), StringComparer.Ordinal);
                if (complete && last is { } at && computer.LastLogon is { } logon && logon <= at) { skipped++; continue; }
                queue.Add((computer, last));
            }
            foreach (var (computer, last) in queue.OrderBy(c => c.Last is null ? 0 : 1).ThenBy(c => c.Last)
                .ThenBy(c => c.Computer.Name, StringComparer.OrdinalIgnoreCase).ThenBy(c => c.Computer.Guid))
            {
                candidates.Add(new(computer.Guid, computer.Name, computer.Dn, domain.RootDn, last is null ? "Aucun relevé lié au GUID"
                    : "Relevé du " + RelationRules.WhenText(last, source.Clock.GetUtcNow(), source.Zone)
                        + (computer.LastLogon is null ? " ; réauthentification inconnue" : computer.LastLogon > last ? " ; réauthentifié depuis dans l’index" : " ; dernier essai non concluant")));
            }
        }
        var plan = RelationRules.DetectionPlan(scope is null ? "loaded" : "sweep", scope?.Dn, domain.RootDn, candidates, request.Limit, null, null);
        var notice = " Plan issu de l’index local, sans contact réseau ; l’identité sera relue avant chaque console. " + memory.Notice;
        if (!local.Directory.CoversScope(scope ?? new(domain.RootDn, "", true))) { notice += " Index partiel ou ancien : cette liste ne recense pas tous les postes de l’annuaire."; }
        if (omitted > 0) { notice += " " + FrenchText.Count(omitted, "référence écartée", "références écartées") + " : inconnue, ambiguë, désactivée, contrôleur ou nom Windows/DNS inexploitable."; }
        if (skipped > 0) { notice += " " + FrenchText.Count(skipped, "poste non redemandé", "postes non redemandés") + " : aucun renouvellement d’authentification visible dans l’index depuis le relevé lié au GUID."; }
        if (!plan.Allowed) { return plan with { Reason = plan.Reason + notice, ZeroMeaning = "Aucun poste éligible dans ce périmètre local ; cela ne prouve aucune absence dans l’annuaire." }; }
        var targets = plan.Targets.ToImmutableDictionary(t => Guid.Parse(t.Guid), t => objects[Guid.Parse(t.Guid)]);
        var hosts = targets.Keys.ToImmutableDictionary(id => id, id => machines[id].DnsHostName!);
        var access = source.AccountContext is { } context ? AccountAccess.From(context).SelectionVersion : 0;
        var generation = source.AccountContext is { } machineContext ? MachineAccountService.From(machineContext).Generation : 0;
        var held = AdRelationResults.For(source).Remember(id => new AdRelationProbePlan(plan with
        {
            Id = id, ExpiresAt = source.Clock.GetUtcNow().AddMinutes(15),
            Text = plan.Text + " Ping ICMP par lots de huit avant les consoles. " + notice,
            ZeroMeaning = "Aucun compte confirmé dans la liste ne prouve pas qu’un utilisateur n’a aucun poste.",
        }, "sweep", null, [], targets, hosts, access, generation), local.Epoch);
        return held.Plan;
    }
}
