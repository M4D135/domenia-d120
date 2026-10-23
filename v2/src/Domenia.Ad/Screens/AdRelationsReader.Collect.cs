using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdRelationsReader
{
    internal Func<TimeProvider, WindowsRelationEventsReader>? EventReaderOverride { get; init; }

    public async Task<RelationDetection> CollectAsync(RelationDetectionRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request); ArgumentNullException.ThrowIfNull(request.Computers);
        if (request.SubjectGuid == Guid.Empty || string.IsNullOrWhiteSpace(request.SubjectLogin) || request.SubjectLogin.Length > 320 || request.SubjectLogin.Any(char.IsControl)
            || request.Scope is not ("candidates" or "ou" or "loaded") || request.Limit is < 1 or > 50 || request.Computers.Count > 5000
            || request.Computers.Any(c => c is null || c.Length is 0 or > 4096 || c.Any(char.IsControl)) || request.Computers.Sum(c => (long)c.Length) > 400_000)
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Sujet, périmètre ou limite de détection invalide."); }
        var local = await LocalAsync(cancellationToken, withJournal: false).ConfigureAwait(false); var domain = local.Directory.Domain;
        AdRelationDirectory.ValidateDn(request.Dn, domain);
        if (request.Scope == "ou")
        {
            ScopeRules.EnsureNotDomainRoot(request.OuDn is null ? null : new ScopeSelection(request.OuDn, request.OuDn, true), domain.RootDn);
            AdRelationDirectory.ValidateDn(request.OuDn!, domain);
            if (!DistinguishedName.Parse(request.OuDn!)[0].Type.Equals("OU", StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(DomeniaErrors.ScopeTooWide, "Choisissez une OU explicite ; aucun conteneur ni domaine entier substitué."); }
        }
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(60), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        using var access = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, null, budget.Token).ConfigureAwait(false);
        var subject = (await AdRelationDirectory.ExactAsync(access, domain, request.Dn, request.SubjectGuid, false, budget.Token).ConfigureAwait(false)).Object;
        if (subject.Kind != RelationSubjectKind.User || !string.Equals(subject.Login, request.SubjectLogin, StringComparison.OrdinalIgnoreCase) || subject.Created > source.Clock.GetUtcNow())
        { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte renommé, recréé ou incohérent ; rechargez le sujet. Aucun poste contacté."); }
        long AccessVersion() => source.AccountContext is { } c ? AccountAccess.From(c).SelectionVersion : 0;
        long MachineGeneration() => source.AccountContext is { } c ? MachineAccountService.From(c).Generation : 0;
        var accessVersion = AccessVersion(); var machineGeneration = MachineGeneration();
        var attempts = ImmutableArray.CreateBuilder<RelationAttempt>(); var proofs = new List<RelationProof>();
        var objects = new Dictionary<Guid, AdRelationDirectory.Read>(); var conflicts = new HashSet<Guid>();
        var dns = new Dictionary<string, Guid>(StringComparer.OrdinalIgnoreCase);
        var observed = new Dictionary<Guid, StoredRelation>(); var hints = ImmutableArray<RelationHint>.Empty;
        var partial = local.Stored.Truncated || local.Stored.Rejected > 0; var stopped = false; var perimeterCapped = false;
        var perimeter = new List<RelationPlanCandidate>();
        void Attempt(string method, string status, string? target, string detail, long began, string resource = "Annuaire")
        {
            var (label, tone) = RelationRules.AttemptStatus(status);
            attempts.Add(new(method, status, label, tone, target, detail, (long)source.Clock.GetElapsedTime(began).TotalMilliseconds, resource));
        }
        Attempt("Compte sélectionné", "OK", subject.Login, "Même GUID et même identifiant relus ; aucun poste contacté.", source.Clock.GetTimestamp());
        bool Accept(AdRelationDirectory.Read read)
        {
            var value = read.Object; var host = read.Entry.String("dNSHostName");
            if (conflicts.Contains(value.Guid)) { return false; }
            var dnKey = DistinguishedName.Format(DistinguishedName.Parse(value.Dn));
            if (dns.TryGetValue(dnKey, out var previousId) && previousId != value.Guid)
            { conflicts.Add(previousId); conflicts.Add(value.Guid); objects.Remove(previousId); objects.Remove(value.Guid); partial = true; return false; }
            dns[dnKey] = value.Guid;
            if (objects.TryGetValue(value.Guid, out var previous) && (!DistinguishedName.AreEqual(previous.Object.Dn, value.Dn)
                || previous.Object.Sid != value.Sid || previous.Object.Created != value.Created || previous.Object.Login != value.Login || previous.Object.Enabled != value.Enabled
                || !string.Equals(previous.Entry.String("dNSHostName"), host, StringComparison.OrdinalIgnoreCase)))
            { conflicts.Add(value.Guid); objects.Remove(value.Guid); partial = true; return false; }
            if (!value.Enabled || value.Created > source.Clock.GetUtcNow() || (read.Entry.Int("userAccountControl")!.Value & 8192) != 0
                || host is null || !CimQuery.IsHostName(host) || !WorkstationIdentity.Matches(AdDirectoryMapper.Computer(read.Entry)!, value.Name))
            { partial = true; return false; }
            objects[value.Guid] = read; return true;
        }
        async Task<List<AdRelationDirectory.Read>> Query(string method, string baseDn, string filter, int limit, Func<AdRelationDirectory.Read, bool> matches)
        {
            var began = source.Clock.GetTimestamp();
            var rows = await access.SearchAsync(new(baseDn, filter, AdSearchScope.Subtree, [.. AdRelationDirectory.Attributes, "managedBy", "location"])
            { PageSize = Math.Min(40, limit + 1), SizeLimit = limit + 1, Timeout = TimeSpan.FromSeconds(8), Budget = TimeSpan.FromSeconds(10), ExpandRanges = false }, budget.Token).ConfigureAwait(false);
            var valid = new List<AdRelationDirectory.Read>(); var rejected = 0;
            foreach (var row in rows.Take(limit + 1))
            {
                try
                {
                    if (AdRelationDirectory.Map(row, domain) is { Kind: RelationSubjectKind.Computer } value && matches(new(row, value))) { valid.Add(new(row, value)); }
                    else { rejected++; }
                }
                catch (Exception ex) when (ex is DomeniaOperationException or ArgumentException or FormatException) { rejected++; }
            }
            var duplicateIds = valid.GroupBy(v => v.Object.Guid).Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet();
            var duplicateDns = valid.GroupBy(v => DistinguishedName.Format(DistinguishedName.Parse(v.Object.Dn)), StringComparer.OrdinalIgnoreCase)
                .Where(g => g.Count() > 1).Select(g => g.Key).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var unique = valid.Where(v => !duplicateIds.Contains(v.Object.Guid) && !duplicateDns.Contains(DistinguishedName.Format(DistinguishedName.Parse(v.Object.Dn)))).ToArray();
            foreach (var id in duplicateIds.Concat(valid.Where(v => duplicateDns.Contains(DistinguishedName.Format(DistinguishedName.Parse(v.Object.Dn)))).Select(v => v.Object.Guid)))
            { conflicts.Add(id); objects.Remove(id); }
            var capped = rows.Count > limit; var uncertain = capped || rejected > 0 || unique.Length != valid.Count;
            if (method == "OU choisie" && capped) { perimeterCapped = true; }
            partial |= uncertain;
            Attempt(method, uncertain ? "A_REVOIR" : unique.Length > 0 ? "OK" : "VIDE", baseDn,
                FrenchText.Count(unique.Length, "identité éligible lue", "identités éligibles lues")
                    + (capped ? ". Limite de " + limit + " atteinte ; lecture partielle." : ".")
                    + (rejected > 0 || unique.Length != valid.Count ? " Réponses incohérentes ou ambiguës écartées." : "") + " Aucune présence sur un poste déduite.", began);
            return unique.Take(limit).Where(Accept).ToList();
        }
        var known = local.Stored.Rows.Select(r => r.Relation).Concat(local.Session)
            .Where(r => r.UserGuid == subject.Guid || r.UserGuid is null && local.Lookup.User(null, r.UserLogin)?.Guid == subject.Guid)
            .GroupBy(r => r.ComputerGuid?.ToString("D") ?? "name:" + r.Computer, StringComparer.OrdinalIgnoreCase).Select(g => g.MaxBy(r => r.When)!).ToArray();
        if (known.Length > 50) { partial = true; }
        try
        {
            foreach (var link in known.Take(50))
            {
                var guid = link.ComputerGuid ?? local.Lookup.Computer(null, link.Computer)?.Guid;
                if (guid is null) { partial = true; continue; }
                var found = await Query("Association mémorisée", domain.RootDn, "(&" + AdDirectoryMapper.ComputerFilter + AdObjectAccess.GuidFilter(guid.Value) + ")", 1,
                    r => r.Object.Guid == guid).ConfigureAwait(false);
                if (found.Count != 1) { continue; }
                var value = found[0].Object;
                proofs.Add(new(value.Guid, value.Name, value.Dn, null, "Association mémorisée",
                    "Lien historique ; ne prouve aucune session actuelle." + (link.ComputerGuid is null ? " Ancien nom résolu dans l’index puis identité actuelle relue, sans modifier le lien hérité." : "")));
                observed[value.Guid] = link;
            }
            var managed = await Query("Responsable déclaré", domain.RootDn,
                "(&" + AdDirectoryMapper.ComputerFilter + "(managedBy=" + SearchText.LdapLiteral(subject.Dn) + "))", 100,
                r => r.Entry.String("managedBy") is { } dn && DistinguishedName.AreEqual(dn, subject.Dn)).ConfigureAwait(false);
            proofs.AddRange(managed.Select(r => new RelationProof(r.Object.Guid, r.Object.Name, r.Object.Dn, null, "Responsable déclaré", "Indice : managedBy désigne ce compte ; aucune console déduite.")));
            var literal = SearchText.LdapLiteral(subject.Login);
            var mentions = await Query("Mention du compte", domain.RootDn, "(&" + AdDirectoryMapper.ComputerFilter + "(|(description=*" + literal + "*)(location=*" + literal + "*)))", 100,
                r => (r.Entry.String("description") ?? "").Contains(subject.Login, StringComparison.OrdinalIgnoreCase)
                    || (r.Entry.String("location") ?? "").Contains(subject.Login, StringComparison.OrdinalIgnoreCase)).ConfigureAwait(false);
            proofs.AddRange(mentions.Select(r => new RelationProof(r.Object.Guid, r.Object.Name, r.Object.Dn, null, "Mention du compte", "Indice textuel dans la description ou l’emplacement ; aucune console déduite.")));
            if (request.Scope == "ou")
            {
                var inOu = await Query("OU choisie", request.OuDn!, AdDirectoryMapper.ComputerFilter, request.Limit,
                    r => DistinguishedName.IsWithin(r.Object.Dn, request.OuDn!, true)).ConfigureAwait(false);
                perimeter.AddRange(inOu.Select(r => new RelationPlanCandidate(r.Object.Guid, r.Object.Name, r.Object.Dn, domain.RootDn, "OU choisie")));
            }
            else if (request.Scope == "loaded")
            {
                var loaded = request.Computers.Select(local.Lookup.Find).Where(o => o is { Kind: RelationSubjectKind.Computer, Enabled: true }).Select(o => o!)
                    .DistinctBy(o => o.Guid).ToArray();
                if (loaded.Length > request.Limit) { partial = perimeterCapped = true; }
                foreach (var pc in loaded.Take(request.Limit))
                {
                    var found = await Query("Liste chargée", domain.RootDn, "(&" + AdDirectoryMapper.ComputerFilter + AdObjectAccess.GuidFilter(pc.Guid) + ")", 1,
                        r => r.Object.Guid == pc.Guid).ConfigureAwait(false);
                    if (found.Count == 1) { var value = found[0].Object; perimeter.Add(new(value.Guid, value.Name, value.Dn, domain.RootDn, "Liste chargée")); }
                }
            }
            if (request.Kerberos)
            {
                var began = source.Clock.GetTimestamp(); var controller = access.Controller;
                if (controller is null || !CimQuery.IsHostName(controller) || !controller.Contains('.'))
                { partial = true; Attempt("Journal du contrôleur", "INDISPONIBLE", null, "Contrôleur DNS de la session inconnu ; aucun contrôleur de remplacement.", began); }
                else
                {
                    using var credential = access.CopyNativeCredential(); var now = source.Clock.GetUtcNow();
                    var reading = await (EventReaderOverride?.Invoke(source.Clock) ?? new WindowsRelationEventsReader(source.Clock))
                        .ReadAsync(new(controller, now.AddDays(-7), now, 100, subject.Sid), credential, budget.Token).ConfigureAwait(false);
                    access.EnsureCurrent();
                    if (reading.Status == SourceStatus.Refused) { access.ReportNativeRefusal(reading.AuthenticationRejected); stopped = true; }
                    partial |= reading.Status is not (SourceStatus.Ok or SourceStatus.Empty);
                    hints = [.. reading.Events.Where(e => e.UserSid == subject.Sid && e.At >= subject.Created && e.Address is not null)
                        .GroupBy(e => e.Address!, StringComparer.Ordinal).Select(g => g.MaxBy(e => e.At)!).OrderByDescending(e => e.At)
                        .Select(e => new RelationHint(e.Address!, "4768 · " + controller, "Indice d’authentification", "Adresse cliente historique ; aucun poste résolu ni associé automatiquement.", e.At))];
                    Attempt("Journal du contrôleur", reading.AuthenticationRejected ? "AUTH_REJETEE" : reading.Status == SourceStatus.Refused ? "REFUSE"
                        : reading.Status == SourceStatus.Empty ? "VIDE" : reading.Status == SourceStatus.Ok ? "OK" : "A_REVOIR", controller,
                        reading.Detail + " Adresses uniquement ; aucune résolution DNS inverse.", began, "Annuaire · " + controller);
                }
            }
            if (!stopped)
            {
                var final = (await AdRelationDirectory.ExactAsync(access, domain, subject.Dn, subject.Guid, false, budget.Token).ConfigureAwait(false)).Object;
                if (final.Login != subject.Login || final.Sid != subject.Sid || final.Created != subject.Created || final.Upn != subject.Upn)
                { throw new DomeniaOperationException(RelationErrors.IdentityChanged, "Compte modifié pendant la collecte ; aucun plan conservé."); }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        { partial = stopped = true; Attempt("Collecte", "DELAI", null, "Budget global de 60 secondes atteint ; indices terminés conservés, aucun plan de sonde.", source.Clock.GetTimestamp()); }
        catch (DomeniaOperationException ex) when (ex.Code is AdErrors.Credentials or AdErrors.AccessDenied or AdErrors.Timeout or AdErrors.Unavailable)
        { partial = stopped = true; Attempt("Collecte", ex.Code == AdErrors.Credentials ? "AUTH_REJETEE" : ex.Code == AdErrors.AccessDenied ? "REFUSE" : "A_REVOIR", null,
            "Lecture arrêtée ; indices terminés conservés, aucun autre compte essayé ni plan de sonde.", source.Clock.GetTimestamp()); }
        cancellationToken.ThrowIfCancellationRequested(); access.EnsureCurrent(); EnsureEpoch(local.Epoch);
        if (accessVersion != AccessVersion() || machineGeneration != MachineGeneration())
        { throw new DomeniaOperationException(AccountAccess.EpochChanged, "Compte modifié pendant la collecte ; préparez de nouveau le périmètre."); }
        var candidates = RelationRules.MergeCandidates(proofs.Where(p => p.Guid is { } id && objects.ContainsKey(id) && !conflicts.Contains(id))).Select(m =>
        {
            observed.TryGetValue(Guid.Parse(m.Guid!), out var link); var badge = RelationRules.BadgeOf(link?.Kind ?? RelationKind.Hint);
            return new RelationCandidate(m.Guid, m.Computer, m.Dn, m.Origins, m.Why, true, null, badge.Badge, badge.Label, badge.Tone,
                link is null ? "Indice AD" : "Historique connu", null, link?.When, RelationRules.WhenText(link?.When, source.Clock.GetUtcNow(), source.Zone), false, link is not null, link is not null);
        }).OrderByDescending(c => c.Known).ThenBy(c => c.Computer, StringComparer.OrdinalIgnoreCase).ToImmutableArray();
        if (request.Scope == "candidates") { perimeter.AddRange(candidates.Select(c => new RelationPlanCandidate(Guid.Parse(c.Guid!), c.Computer, c.Dn!, domain.RootDn, c.Origins))); }
        var plan = RelationRules.DetectionPlan(request.Scope, request.Scope == "ou" ? request.OuDn : null, domain.RootDn,
            perimeter.Where(p => p.Guid is { } id && objects.ContainsKey(id) && !conflicts.Contains(id)), request.Limit, null, null);
        if (perimeterCapped) { plan = plan with { Truncated = true, Text = plan.Text + " Périmètre limité aux premières identités lues ; d’autres postes restent hors de ce plan." }; }
        if (stopped) { plan = plan with { Allowed = false, Id = null, Targets = [], Reason = "Collecte interrompue ou refusée ; relisez avant toute sonde.", ExpiresAt = null }; }
        var resultId = WritePlans.NewId();
        if (plan.Allowed)
        {
            var targets = plan.Targets.ToImmutableDictionary(t => Guid.Parse(t.Guid), t => objects[Guid.Parse(t.Guid)].Object);
            var hosts = targets.Keys.ToImmutableDictionary(id => id, id => objects[id].Entry.String("dNSHostName")!);
            var held = AdRelationResults.For(source).Remember(id => new AdRelationProbePlan(plan with { Id = id, ExpiresAt = source.Clock.GetUtcNow().AddMinutes(15),
                Text = plan.Text + (partial ? " Collecte partielle ; seuls les objets qualifiés affichés seront contactés." : "") }, "detect", subject, candidates, targets, hosts, accessVersion, machineGeneration), local.Epoch);
            plan = held.Plan; resultId = plan.Id!;
        }
        Attempt("Consoles CIM/DCOM", "NON_DEMANDE", null, "Aucun poste contacté ; liste exacte à confirmer.", source.Clock.GetTimestamp(), "Postes");
        var view = new RelationSubject(subject.Kind, subject.Dn, subject.Guid.ToString("D"), subject.Name, subject.Login, subject.Detail,
            RelationRules.Path(subject.Dn, domain.DnsName), subject.Enabled, subject.LastLogon, subject.Created);
        return new(resultId, "collect", view, attempts.ToImmutable(), candidates, hints, plan, null, partial, true, !partial, 0,
            FrenchText.Count(candidates.Length, "candidat qualifié", "candidats qualifiés") + ", " + FrenchText.Count(hints.Length, "adresse indicative", "adresses indicatives")
            + ". Aucun poste contacté, aucune association enregistrée." + (partial ? " Collecte partielle ; voir le détail des tentatives." : "")
            + (known.Length > 50 ? " Seules les 50 premières associations connues ont été examinées." : ""));
    }
}
