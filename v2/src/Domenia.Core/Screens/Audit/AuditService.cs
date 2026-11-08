using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Engine service of the « Audit AD » screen (docs/ops/audit.md): runs the reads of <see cref="IAuditReader"/> and applies the
/// pure rules. It keeps, for the session only and in memory, what Domenia 1 kept in $script:AdAuditData: the last domain
/// analysis (exploration without a new read, comparison with the previous view), the last list of controllers (the only
/// hosts a diagnosis, a services read or a comparison may contact), and the reads of the current object only (delegations,
/// groups of a trustee, nested groups, GPO links and RSoP), so that the local estimates never read the directory again
/// (Reset/Clear-DomeniaAdAuditObjectResults). A request for another object (audit.target or a read) claims a new slot, and a
/// read that ends after that keeps nothing; a new session (domain, controller or account) clears everything. A result always
/// belongs to the DN it was read for.
/// </summary>
public sealed class AuditService
{
    public const int SearchLimit = 20;
    public const int HistoryLimit = 200;
    public const int MaxHistoryLimit = 1000;

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private string? sessionKey;
    private (DomainOverviewRead Read, AuditOverview View)? overview;
    private ControllerListRead? controllerList;
    private ObjectSlot slot = new(null);

    /// <summary>Reads of the current object only; a read for another DN starts a new slot.</summary>
    private sealed class ObjectSlot(string? dn)
    {
        public string? Dn { get; } = dn;

        public AclRead? Acl { get; set; }

        public TokenGroupsRead? Tokens { get; set; }

        public GroupGraphRead? Groups { get; set; }

        public GpoLinksRead? GpoLinks { get; set; }

        public RsopRead? Rsop { get; set; }
    }

    private AuditService(EngineContext context) => this.context = context;

    /// <summary>The single instance of the context (shared by every module that needs it).</summary>
    public static AuditService From(EngineContext context)
    {
        ArgumentNullException.ThrowIfNull(context);
        return context.Shared(static c => new AuditService(c));
    }

    private IAuditReader Reader => context.Readers.Require<IAuditReader>();

    private TimeZoneInfo Zone => context.Clock.LocalTimeZone;

    private DateTimeOffset Now => context.Clock.GetUtcNow();

    private async Task<(string DnsName, string RootDn)> DomainAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        if (session.Domain?.DnsName is not string dns || session.Domain.RootDn is not string root)
        {
            throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, DomeniaErrors.SourceUnavailableMessage);
        }
        return (dns, root);
    }

    private void Journal(string label, Tone tone = Tone.Info) => context.Journal.Add(new JournalEntry(Now, "Audit AD : " + label, tone));

    /// <summary>
    /// Clears every result kept when the session is not the one they were read in (domain, controller or account changed):
    /// nothing read in one session is shown in another (AUD-003, AUD-010). The session snapshot is local, never a read.
    /// </summary>
    private async Task SyncSessionAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var key = string.Join("|", session.Domain?.RootDn ?? string.Empty, session.Controller?.DnsName ?? string.Empty, session.Account.Login);
        lock (gate)
        {
            if (sessionKey is not null && !string.Equals(sessionKey, key, StringComparison.OrdinalIgnoreCase))
            {
                overview = null;
                controllerList = null;
                slot = new ObjectSlot(null);
            }
            sessionKey = key;
        }
    }

    private static bool SameDn(string? left, string? right)
    {
        if (left is null || right is null)
        {
            return false;
        }
        try
        {
            return DistinguishedName.AreEqual(left, right);
        }
        catch (FormatException)
        {
            return string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>The slot of this object, a new one (the previous object's reads dropped) for another DN. Under the gate.</summary>
    private ObjectSlot SlotFor(string dn)
    {
        if (!SameDn(slot.Dn, dn))
        {
            slot = new ObjectSlot(dn);
        }
        return slot;
    }

    /// <summary>
    /// Claims the slot of this object when a request starts (audit.target or a read): the latest request decides the current
    /// object, as the target generation of Domenia 1 (Test-DomeniaAdAuditStateCurrent). A read that ends after another object
    /// was claimed keeps nothing (<see cref="Keep"/>), so a slow read of a former target never drops the reads of the new one.
    /// </summary>
    private ObjectSlot Claim(string dn)
    {
        lock (gate)
        {
            return SlotFor(dn);
        }
    }

    /// <summary>Stores into a claimed slot only while it is still the current one; under the gate.</summary>
    private void Keep(ObjectSlot claimed, Action<ObjectSlot> store)
    {
        lock (gate)
        {
            if (ReferenceEquals(slot, claimed))
            {
                store(claimed);
            }
        }
    }

    /// <summary>The slot of this object if it is the current one; null otherwise (nothing read for it). Under the gate.</summary>
    private ObjectSlot? CurrentSlot(string dn) => SameDn(slot.Dn, dn) ? slot : null;

    // ---------------------------------------------------------------- target

    /// <summary>The object of a DN (frozen at the gesture), or audit.targetUnknown.</summary>
    public async Task<AuditTarget> TargetAsync(string dn, CancellationToken cancellationToken) =>
        await Reader.FindTargetAsync(dn, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(AuditErrors.TargetUnknown, AuditErrors.TargetUnknownMessage);

    /// <summary>The audited object (AUD-010): claims its slot, so the reads kept for the previous target are dropped.</summary>
    public async Task<AuditTargetView> TargetViewAsync(string dn, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        var (dns, _) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        _ = Claim(target.Dn);
        return AuditTargets.View(target, dns);
    }

    public async Task<ImmutableArray<AuditTargetView>> SearchAsync(string text, CancellationToken cancellationToken)
    {
        var (dns, _) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var found = await Reader.SearchObjectsAsync(text, SearchLimit, cancellationToken).ConfigureAwait(false);
        return [.. found.Select(t => AuditTargets.View(t, dns))];
    }

    /// <summary>
    /// Objects proposed before any search (AUD-010): the account of the session, the working OU, the root of the domain and the
    /// « Domain Admins » group found by its RID (512) in the local index, whatever its name or language. Each one is checked in
    /// the local index and left out when it is not found; never a network read.
    /// </summary>
    public async Task<ImmutableArray<AuditSuggestion>> SuggestionsAsync(CancellationToken cancellationToken)
    {
        var session = await context.Directory.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var (dns, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var scope = await WorkingScope.From(context).CurrentAsync(session, cancellationToken).ConfigureAwait(false);
        var result = ImmutableArray.CreateBuilder<AuditSuggestion>();
        async Task AddAsync(string id, string? dn, string label, string? detail)
        {
            if (string.IsNullOrEmpty(dn) || result.Any(r => SameDn(r.Target.Dn, dn)))
            {
                return;
            }
            if (await Reader.FindTargetAsync(dn, cancellationToken).ConfigureAwait(false) is { } target)
            {
                result.Add(new AuditSuggestion(id, label, detail ?? target.Name, AuditTargets.View(target, dns)));
            }
        }
        await AddAsync("account", session.Account.Dn, "Compte de la session", session.Account.Login).ConfigureAwait(false);
        if (scope is not null && !SameDn(scope.Dn, root))
        {
            await AddAsync("scope", scope.Dn, "OU de travail", scope.Label).ConfigureAwait(false);
        }
        await AddAsync("root", root, "Racine du domaine", dns).ConfigureAwait(false);
        if (await Reader.FindDomainGroupAsync(DomainAdminsRid, cancellationToken).ConfigureAwait(false) is { } admins)
        {
            await AddAsync("domainAdmins", admins.Dn, admins.Name, "Groupe privilégié (RID 512)").ConfigureAwait(false);
        }
        return result.ToImmutable();
    }

    /// <summary>Relative identifier of the « Domain Admins » group of every domain.</summary>
    public const int DomainAdminsRid = 512;

    // ---------------------------------------------------------------- domain

    public async Task<AuditOverview> OverviewAsync(CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var read = await Reader.DomainOverviewAsync(cancellationToken).ConfigureAwait(false);
        AuditOverview view;
        lock (gate)
        {
            view = AuditFindings.Overview(read, overview?.View);
            overview = (read, view);
        }
        Journal("analyse du domaine sur " + read.Controller + " · score " + FrenchText.Integer(view.Score.Value) + "/100",
            view.Counts.Critical > 0 ? Tone.Alert : view.Counts.High > 0 ? Tone.Warn : Tone.Ok);
        return view;
    }

    /// <summary>Objects of one finding of the last analysis: no new read (audit.overviewNotRead before any analysis).</summary>
    public async Task<AuditFindingObjects> FindingObjectsAsync(string id, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        (DomainOverviewRead Read, AuditOverview View) last;
        lock (gate)
        {
            last = overview ?? throw new DomeniaOperationException(AuditErrors.OverviewNotRead, AuditErrors.OverviewNotReadMessage);
        }
        var finding = last.View.Findings.FirstOrDefault(f => f.Id == id)
            ?? throw new DomeniaOperationException(AuditErrors.FindingUnknown, AuditErrors.FindingUnknownMessage);
        var read = last.Read.Checks.FirstOrDefault(c => c.Id == id)
            ?? new SecurityCheckRead(id, ReadState.NotRead, null, [], 0, 0, null, null);
        return AuditFindings.Objects(finding, read, last.Read.ReadAt);
    }

    public async Task<AuditLocalTotals> LocalTotalsAsync(CancellationToken cancellationToken) =>
        AuditFindings.LocalTotals(await Reader.LocalTotalsAsync(cancellationToken).ConfigureAwait(false));

    // ---------------------------------------------------------------- controllers

    public async Task<AuditControllerList> ControllersAsync(CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var read = await Reader.ControllersAsync(cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            controllerList = read;
        }
        var view = AuditControllerRules.ListView(read);
        Journal("liste des contrôleurs (" + FrenchText.Integer(view.Controllers.Length) + ")");
        return view;
    }

    /// <summary>
    /// The chosen controllers, checked (1 to 10 valid names) and all present in the last list of the domain controllers, read
    /// now if the session has none: a diagnosis, a services read (administrative rights) or a comparison never contacts a host
    /// that is not a controller of the domain (audit.controllersInvalid otherwise). Names come back as the list writes them.
    /// </summary>
    private async Task<(ImmutableArray<string> Chosen, ControllerListRead List)> ChosenControllersAsync(IReadOnlyList<string> names, CancellationToken cancellationToken)
    {
        var chosen = AuditControllerRules.RequireControllers(names);
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        ControllerListRead? list;
        lock (gate)
        {
            list = controllerList;
        }
        if (list is null)
        {
            list = await Reader.ControllersAsync(cancellationToken).ConfigureAwait(false);
            lock (gate)
            {
                controllerList = list;
            }
        }
        return (AuditControllerRules.RequireKnown(chosen, list), list);
    }

    public async Task<AuditHealth> ProbeAsync(IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var (chosen, list) = await ChosenControllersAsync(controllers, cancellationToken).ConfigureAwait(false);
        var read = await Reader.ProbeControllersAsync(chosen, list.Pdc, cancellationToken).ConfigureAwait(false);
        var view = AuditControllerRules.HealthView(read, Now, Zone);
        var check = view.Rows.Count(r => r.Verdict == ControllerVerdict.Check);
        Journal("diagnostic de " + FrenchText.Count(chosen.Length, "contrôleur", "contrôleurs") + (check > 0 ? " · " + FrenchText.Integer(check) + " à vérifier" : " · sans écart"),
            check > 0 ? Tone.Warn : Tone.Ok);
        return view;
    }

    public async Task<AuditServices> ServicesAsync(IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var (chosen, _) = await ChosenControllersAsync(controllers, cancellationToken).ConfigureAwait(false);
        var read = await Reader.ControllerServicesAsync(chosen, AuditControllerRules.ServicesBudgetSeconds(chosen.Length), cancellationToken).ConfigureAwait(false);
        var view = AuditControllerRules.ServicesView(read);
        Journal("services de " + FrenchText.Count(chosen.Length, "contrôleur", "contrôleurs") + " lus (droits d’administration)");
        return view;
    }

    public async Task<AuditComparison> CompareAsync(string dn, IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var (chosen, _) = await ChosenControllersAsync(controllers, cancellationToken).ConfigureAwait(false);
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        var read = await Reader.CompareObjectAsync(target, chosen, cancellationToken).ConfigureAwait(false);
        return AuditControllerRules.ComparisonView(read, Zone);
    }

    // ---------------------------------------------------------------- object reads

    /// <summary>The object when the read applies to it (audit.notApplicable otherwise), with its claimed slot.</summary>
    private async Task<(AuditTarget Target, ObjectSlot Slot)> CheckedAsync(string dn, Func<AuditReadsAvailability, AuditAvailability> pick, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        AuditTargets.Require(pick(AuditTargets.Availability(target.Kind)));
        return (target, Claim(target.Dn));
    }

    public async Task<AuditPolicy> PolicyAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, _) = await CheckedAsync(dn, a => a.Policy, cancellationToken).ConfigureAwait(false);
        var read = await Reader.PasswordPolicyAsync(target, cancellationToken).ConfigureAwait(false);
        return AuditPolicyRules.View(read, Now, Zone);
    }

    public async Task<AuditGroups> GroupsAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, claimed) = await CheckedAsync(dn, a => a.Groups, cancellationToken).ConfigureAwait(false);
        var read = await Reader.NestedGroupsAsync(target, cancellationToken).ConfigureAwait(false);
        Keep(claimed, s => s.Groups = read);
        return AuditGroupRules.View(read);
    }

    /// <summary>Path of membership in the groups already read (no new read; audit.groupsNotRead otherwise).</summary>
    public async Task<AuditMembership> GroupPathAsync(string dn, string groupDn, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        GroupGraphRead? read;
        lock (gate)
        {
            read = CurrentSlot(dn)?.Groups;
        }
        if (read is null)
        {
            throw new DomeniaOperationException(AuditErrors.GroupsNotRead, AuditErrors.GroupsNotReadMessage);
        }
        return AuditGroupRules.Explain(read, groupDn, null, null, false);
    }

    /// <summary>The controller's answer for one group, joined to the path read (AUD-013).</summary>
    public async Task<AuditMembership> MembershipAsync(string dn, string groupDn, CancellationToken cancellationToken)
    {
        var (target, claimed) = await CheckedAsync(dn, a => a.Groups, cancellationToken).ConfigureAwait(false);
        GroupGraphRead? read;
        lock (gate)
        {
            read = claimed.Groups;
        }
        if (read is null)
        {
            throw new DomeniaOperationException(AuditErrors.GroupsNotRead, AuditErrors.GroupsNotReadMessage);
        }
        var answer = await Reader.MembershipAsync(target, groupDn, cancellationToken).ConfigureAwait(false);
        return AuditGroupRules.Explain(read, groupDn, answer.Member, answer.Error, true);
    }

    public async Task<AuditAcl> DelegationsAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, claimed) = await CheckedAsync(dn, a => a.Acl, cancellationToken).ConfigureAwait(false);
        var read = await Reader.DelegationsAsync(target, cancellationToken).ConfigureAwait(false);
        Keep(claimed, s =>
        {
            s.Acl = read;
            s.Tokens = null;
        });
        return AuditAclRules.View(read);
    }

    private AclRead AclOf(string dn)
    {
        lock (gate)
        {
            return CurrentSlot(dn)?.Acl ?? throw new DomeniaOperationException(AuditErrors.AclNotRead, AuditErrors.AclNotReadMessage);
        }
    }

    /// <summary>Estimate for one trustee of the entries already read (AUD-014; no new read).</summary>
    public async Task<AuditEstimate> EstimateAsync(string dn, string sid, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var read = AclOf(dn);
        if (!read.Aces.Any(a => string.Equals(a.Sid, sid, StringComparison.OrdinalIgnoreCase)))
        {
            throw new DomeniaOperationException(AuditErrors.TrusteeUnknown, AuditErrors.TrusteeUnknownMessage);
        }
        TokenGroupsRead? token;
        lock (gate)
        {
            token = CurrentSlot(dn)?.Tokens;
        }
        return AuditAclRules.Estimate(read, sid, token);
    }

    /// <summary>Reads tokenGroups of one trustee of a domain, then estimates again with its groups (AUD-015).</summary>
    public async Task<AuditEstimate> TokenGroupsAsync(string dn, string sid, CancellationToken cancellationToken)
    {
        await SyncSessionAsync(cancellationToken).ConfigureAwait(false);
        var read = AclOf(dn);
        if (!read.Aces.Any(a => string.Equals(a.Sid, sid, StringComparison.OrdinalIgnoreCase)))
        {
            throw new DomeniaOperationException(AuditErrors.TrusteeUnknown, AuditErrors.TrusteeUnknownMessage);
        }
        if (!AuditText.IsDomainAccountSid(sid))
        {
            throw new DomeniaOperationException(AuditErrors.BuiltinTrustee, AuditErrors.BuiltinTrusteeMessage);
        }
        var token = await Reader.TokenGroupsAsync(sid, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            // Kept only if the object is still the current one (another object read meanwhile drops it).
            if (CurrentSlot(dn) is { } current && ReferenceEquals(current.Acl, read))
            {
                current.Tokens = token;
            }
        }
        return AuditAclRules.Estimate(read, sid, token);
    }

    public async Task<AuditGpo> GpoLinksAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, claimed) = await CheckedAsync(dn, a => a.GpoLinks, cancellationToken).ConfigureAwait(false);
        var (_, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var chain = AuditTargets.GpoContainerChain(target.Dn, root, target.Kind);
        if (chain.IsEmpty)
        {
            throw new DomeniaOperationException(AuditErrors.OutsideDomain, AuditErrors.OutsideDomainMessage);
        }
        var read = await Reader.GpoLinksAsync(chain, cancellationToken).ConfigureAwait(false);
        Keep(claimed, s => s.GpoLinks = read);
        RsopRead? rsop;
        lock (gate)
        {
            rsop = claimed.Rsop;
        }
        return AuditGpoRules.View(target.Dn, chain, read, rsop, rsop?.Computer);
    }

    public async Task<AuditGpo> AppliedPoliciesAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, claimed) = await CheckedAsync(dn, a => a.GpoApplied, cancellationToken).ConfigureAwait(false);
        var (_, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var chain = AuditTargets.GpoContainerChain(target.Dn, root, target.Kind);
        var rsop = await Reader.AppliedPoliciesAsync(target, cancellationToken).ConfigureAwait(false);
        Keep(claimed, s => s.Rsop = rsop);
        GpoLinksRead? links;
        lock (gate)
        {
            links = claimed.GpoLinks;
        }
        return AuditGpoRules.View(target.Dn, chain, links, rsop, rsop.Computer);
    }

    public async Task<AuditMachineIdentity> MachineIdentityAsync(string dn, CancellationToken cancellationToken)
    {
        var (target, _) = await CheckedAsync(dn, a => a.MachineIdentity, cancellationToken).ConfigureAwait(false);
        var read = await Reader.MachineIdentityAsync(target, cancellationToken).ConfigureAwait(false);
        return AuditIdentityRules.MachineView(target.Dn, target, read);
    }

    public async Task<AuditRelations> RelationsAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        if (target.Kind is not (AuditObjectKind.User or AuditObjectKind.Computer))
        {
            return AuditIdentityRules.RelationsView(target, [], Now, Zone);
        }
        var relations = await Reader.RelationsAsync(target, cancellationToken).ConfigureAwait(false);
        return AuditIdentityRules.RelationsView(target, relations, Now, Zone);
    }

    public async Task<AuditHistory> HistoryAsync(string dn, int limit, CancellationToken cancellationToken)
    {
        var (target, _) = await CheckedAsync(dn, a => a.Relations, cancellationToken).ConfigureAwait(false);
        var read = await Reader.RelationHistoryAsync(target, Math.Clamp(limit, 1, MaxHistoryLimit), cancellationToken).ConfigureAwait(false);
        return AuditIdentityRules.HistoryView(target.Dn, read, Zone);
    }

    // ---------------------------------------------------------------- identities of an OU

    public async Task<AuditIdentities> IdentitiesAsync(string baseDn, bool subtree, CancellationToken cancellationToken)
    {
        var (dns, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        bool isRoot;
        bool inside;
        try
        {
            isRoot = DistinguishedName.AreEqual(baseDn, root);
            inside = isRoot || DistinguishedName.IsWithin(baseDn, root, subtree: true);
        }
        catch (FormatException)
        {
            isRoot = false;
            inside = false;
        }
        if (!inside)
        {
            throw new DomeniaOperationException(DomeniaErrors.OuUnknown, DomeniaErrors.OuUnknownMessage);
        }
        if (isRoot && subtree)
        {
            throw new DomeniaOperationException(AuditErrors.ScopeTooWide, AuditErrors.ScopeTooWideMessage);
        }
        var scan = await Reader.IdentityScanAsync(baseDn, subtree, AuditIdentityRules.DefaultScanLimit, cancellationToken).ConfigureAwait(false);
        LocalNamesRead? local;
        try
        {
            local = await Reader.LocalNamesAsync(scan, cancellationToken).ConfigureAwait(false);
        }
        catch (DomeniaOperationException ex)
        {
            // The AD findings stand: a local read that fails only leaves the recycled names unsearched.
            context.Log.Warning("Audit AD : base locale non consultée pour l’analyse des identités (" + ex.Code + ").");
            local = new LocalNamesRead(ReadState.Unavailable, ex.Message, [], [], -1, 0, false);
        }
        var view = AuditIdentityRules.ScanView(scan, local, AuditTargets.Path(baseDn, dns) + (subtree ? " (sous-OU comprises)" : string.Empty));
        Journal("identités de " + AuditTargets.Path(baseDn, dns) + " · " + FrenchText.Count(view.Findings.Length, "constat", "constats"), view.Findings.Length > 0 ? Tone.Warn : Tone.Ok);
        return view;
    }
}
