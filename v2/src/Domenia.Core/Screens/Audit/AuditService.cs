using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>
/// Engine service of the « Audit AD » screen (docs/ops/audit.md): runs the reads of <see cref="IAuditReader"/> and applies the
/// pure rules. It keeps, for the session only and in memory, what Domenia 1 kept in $script:AdAuditData: the last domain
/// analysis (exploration without a new read, comparison with the previous view), and per object the last delegations, groups
/// of trustees, nested groups and GPO links read, so that the local estimates never read the directory again. A result
/// always belongs to the DN it was read for; nothing read for one object is shown for another.
/// </summary>
public sealed class AuditService
{
    public const int SearchLimit = 20;
    public const int HistoryLimit = 200;
    public const int MaxHistoryLimit = 1000;

    private readonly EngineContext context;
    private readonly Lock gate = new();
    private (DomainOverviewRead Read, AuditOverview View)? overview;
    private readonly Dictionary<string, AclRead> acls = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, TokenGroupsRead> tokens = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, GroupGraphRead> groups = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, GpoLinksRead> gpoLinks = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, RsopRead> rsops = new(StringComparer.OrdinalIgnoreCase);

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

    // ---------------------------------------------------------------- target

    /// <summary>The object of a DN (frozen at the gesture), or audit.targetUnknown.</summary>
    public async Task<AuditTarget> TargetAsync(string dn, CancellationToken cancellationToken) =>
        await Reader.FindTargetAsync(dn, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(AuditErrors.TargetUnknown, AuditErrors.TargetUnknownMessage);

    public async Task<AuditTargetView> TargetViewAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        var (dns, _) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        return AuditTargets.View(target, dns);
    }

    public async Task<ImmutableArray<AuditTargetView>> SearchAsync(string text, CancellationToken cancellationToken)
    {
        var (dns, _) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var found = await Reader.SearchObjectsAsync(text, SearchLimit, cancellationToken).ConfigureAwait(false);
        return [.. found.Select(t => AuditTargets.View(t, dns))];
    }

    // ---------------------------------------------------------------- domain

    public async Task<AuditOverview> OverviewAsync(CancellationToken cancellationToken)
    {
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
    public AuditFindingObjects FindingObjects(string id)
    {
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
        var view = AuditControllerRules.ListView(await Reader.ControllersAsync(cancellationToken).ConfigureAwait(false));
        Journal("liste des contrôleurs (" + FrenchText.Integer(view.Controllers.Length) + ")");
        return view;
    }

    public async Task<AuditHealth> ProbeAsync(IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var chosen = AuditControllerRules.RequireControllers(controllers);
        var list = await Reader.ControllersAsync(cancellationToken).ConfigureAwait(false);
        var read = await Reader.ProbeControllersAsync(chosen, list.Pdc, cancellationToken).ConfigureAwait(false);
        var view = AuditControllerRules.HealthView(read, Now, Zone);
        var check = view.Rows.Count(r => r.Verdict == ControllerVerdict.Check);
        Journal("diagnostic de " + FrenchText.Count(chosen.Length, "contrôleur", "contrôleurs") + (check > 0 ? " · " + FrenchText.Integer(check) + " à vérifier" : " · sans écart"),
            check > 0 ? Tone.Warn : Tone.Ok);
        return view;
    }

    public async Task<AuditServices> ServicesAsync(IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var chosen = AuditControllerRules.RequireControllers(controllers);
        var read = await Reader.ControllerServicesAsync(chosen, AuditControllerRules.ServicesBudgetSeconds(chosen.Length), cancellationToken).ConfigureAwait(false);
        var view = AuditControllerRules.ServicesView(read);
        Journal("services de " + FrenchText.Count(chosen.Length, "contrôleur", "contrôleurs") + " lus (droits d’administration)");
        return view;
    }

    public async Task<AuditComparison> CompareAsync(string dn, IReadOnlyList<string> controllers, CancellationToken cancellationToken)
    {
        var chosen = AuditControllerRules.RequireControllers(controllers);
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        var read = await Reader.CompareObjectAsync(target, chosen, cancellationToken).ConfigureAwait(false);
        return AuditControllerRules.ComparisonView(read, Zone);
    }

    // ---------------------------------------------------------------- object reads

    private async Task<AuditTarget> CheckedAsync(string dn, Func<AuditReadsAvailability, AuditAvailability> pick, CancellationToken cancellationToken)
    {
        var target = await TargetAsync(dn, cancellationToken).ConfigureAwait(false);
        AuditTargets.Require(pick(AuditTargets.Availability(target.Kind)));
        return target;
    }

    public async Task<AuditPolicy> PolicyAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await CheckedAsync(dn, a => a.Policy, cancellationToken).ConfigureAwait(false);
        var read = await Reader.PasswordPolicyAsync(target, cancellationToken).ConfigureAwait(false);
        return AuditPolicyRules.View(read, Now, Zone);
    }

    public async Task<AuditGroups> GroupsAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await CheckedAsync(dn, a => a.Groups, cancellationToken).ConfigureAwait(false);
        var read = await Reader.NestedGroupsAsync(target, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            groups[target.Dn] = read;
        }
        return AuditGroupRules.View(read);
    }

    /// <summary>Path of membership in the groups already read (no new read; audit.groupsNotRead otherwise).</summary>
    public AuditMembership GroupPath(string dn, string groupDn)
    {
        GroupGraphRead? read;
        lock (gate)
        {
            groups.TryGetValue(dn, out read);
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
        var target = await CheckedAsync(dn, a => a.Groups, cancellationToken).ConfigureAwait(false);
        GroupGraphRead? read;
        lock (gate)
        {
            groups.TryGetValue(target.Dn, out read);
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
        var target = await CheckedAsync(dn, a => a.Acl, cancellationToken).ConfigureAwait(false);
        var read = await Reader.DelegationsAsync(target, cancellationToken).ConfigureAwait(false);
        lock (gate)
        {
            acls[target.Dn] = read;
            tokens.Remove(target.Dn);
        }
        return AuditAclRules.View(read);
    }

    private AclRead AclOf(string dn)
    {
        lock (gate)
        {
            return acls.TryGetValue(dn, out var read) ? read : throw new DomeniaOperationException(AuditErrors.AclNotRead, AuditErrors.AclNotReadMessage);
        }
    }

    /// <summary>Estimate for one trustee of the entries already read (AUD-014; no new read).</summary>
    public AuditEstimate Estimate(string dn, string sid)
    {
        var read = AclOf(dn);
        if (!read.Aces.Any(a => string.Equals(a.Sid, sid, StringComparison.OrdinalIgnoreCase)))
        {
            throw new DomeniaOperationException(AuditErrors.TrusteeUnknown, AuditErrors.TrusteeUnknownMessage);
        }
        TokenGroupsRead? token;
        lock (gate)
        {
            tokens.TryGetValue(dn, out token);
        }
        return AuditAclRules.Estimate(read, sid, token);
    }

    /// <summary>Reads tokenGroups of one trustee of a domain, then estimates again with its groups (AUD-015).</summary>
    public async Task<AuditEstimate> TokenGroupsAsync(string dn, string sid, CancellationToken cancellationToken)
    {
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
            tokens[dn] = token;
        }
        return AuditAclRules.Estimate(read, sid, token);
    }

    public async Task<AuditGpo> GpoLinksAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await CheckedAsync(dn, a => a.GpoLinks, cancellationToken).ConfigureAwait(false);
        var (_, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var chain = AuditTargets.GpoContainerChain(target.Dn, root, target.Kind);
        if (chain.IsEmpty)
        {
            throw new DomeniaOperationException(AuditErrors.OutsideDomain, AuditErrors.OutsideDomainMessage);
        }
        var read = await Reader.GpoLinksAsync(chain, cancellationToken).ConfigureAwait(false);
        RsopRead? rsop;
        lock (gate)
        {
            gpoLinks[target.Dn] = read;
            rsops.TryGetValue(target.Dn, out rsop);
        }
        return AuditGpoRules.View(target.Dn, chain, read, rsop, rsop?.Computer);
    }

    public async Task<AuditGpo> AppliedPoliciesAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await CheckedAsync(dn, a => a.GpoApplied, cancellationToken).ConfigureAwait(false);
        var (_, root) = await DomainAsync(cancellationToken).ConfigureAwait(false);
        var chain = AuditTargets.GpoContainerChain(target.Dn, root, target.Kind);
        var rsop = await Reader.AppliedPoliciesAsync(target, cancellationToken).ConfigureAwait(false);
        GpoLinksRead? links;
        lock (gate)
        {
            rsops[target.Dn] = rsop;
            gpoLinks.TryGetValue(target.Dn, out links);
        }
        return AuditGpoRules.View(target.Dn, chain, links, rsop, rsop.Computer);
    }

    public async Task<AuditMachineIdentity> MachineIdentityAsync(string dn, CancellationToken cancellationToken)
    {
        var target = await CheckedAsync(dn, a => a.MachineIdentity, cancellationToken).ConfigureAwait(false);
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
        var target = await CheckedAsync(dn, a => a.Relations, cancellationToken).ConfigureAwait(false);
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
