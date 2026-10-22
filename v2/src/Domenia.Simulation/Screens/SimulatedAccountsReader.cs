using System.Collections.Immutable;
using System.Globalization;
using System.Security;
using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Comptes screen in simulation (docs/ops/comptes.md): derived from the fictitious directory as the session sees it
/// (<see cref="SimulatedDirectorySource.CurrentDirectory"/>, writes of the session included), no network and no disk. What the
/// generated world does not hold (lockout events of the security log, the refusal of a LAPS read used to try the recovery
/// flow, the answers to a validation and to a trial on a workstation) is drawn from the named sub-stream « screen/accounts »
/// of the seed, so it never moves the directory nor the other screens. Each read waits a short realistic delay of its own
/// (« latency/screen/accounts/… »), none with <see cref="SimulationLatency.None"/>. The fictitious directory holds no
/// password: a validation checks the account and its state only, and says so.
/// </summary>
public sealed class SimulatedAccountsReader : IAccountsReader, IAccountsAccessReader
{
    private const string NotAUserMessage = "Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif\u00A0: rien n’a été lu.";

    private readonly SimulatedDirectorySource source;
    private readonly Lock gate = new();
    private (long Version, OrganizationalUnitTree Tree)? built;

    /// <summary>Found by ScreenReaders.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedAccountsReader(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public bool Simulated => true;

    public DateTimeOffset? SessionStartedAt => source.World.Reference;

    public (DateTimeOffset Now, TimeZoneInfo Zone, bool Simulated) Clock => (source.Clock.GetUtcNow(), source.World.TimeZone, true);

    private string? Controller => source.World.Session.Controller?.DnsName;

    public async Task<AccountsList> ListAsync(AccountsScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        await source.SimulateScreenLatencyAsync("accounts/list", 140, 360, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var now = source.Clock.GetUtcNow();
        var selection = new ScopeSelection(scope.Dn, scope.Label, scope.Subtree);
        // Never the whole domain: the root reads nothing and proposes the OUs that hold accounts.
        var tooWide = ScopeRules.IsDomainRoot(selection, directory.Domain.RootDn);
        var (users, truncated) = tooWide ? (ImmutableArray<DirectoryUser>.Empty, false) : AccountsRules.UsersIn(directory, selection);
        var rows = users.Select(u => AccountsRules.Row(u, directory.Domain, now)).ToImmutableArray();
        var suggestions = rows.Length == 0 ? AccountsRules.Suggestions(directory, Tree()) : [];
        return new AccountsList(scope, tooWide, now, Controller, true, AccountsRules.Policy(directory.Domain.PasswordPolicy), AccountsRules.Counts(rows, now), rows, truncated,
            AccountsRules.ListLimit, suggestions);
    }

    public async Task<AccountsDetail> DetailAsync(string dn, string? operatorDn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await source.SimulateScreenLatencyAsync("accounts/detail", 80, 200, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var user = SimulatedAccounts.FindByDn(directory, dn) ?? throw new DomeniaOperationException(AccountsRules.UnknownAccount, NotAUserMessage);
        return AccountsRules.Detail(user, directory, Controller, operatorDn, source.Clock.GetUtcNow(), source.World.TimeZone, true);
    }

    public async Task<(DirectoryUser User, DomainInfo Domain, LockoutEventsRead Read)> LockoutEventsAsync(string dn, int hours, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await source.SimulateScreenLatencyAsync("accounts/lockouts", 450, 1100, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var user = SimulatedAccounts.FindByDn(directory, dn) ?? throw new DomeniaOperationException(AccountsRules.UnknownAccount, NotAUserMessage);
        if (!AccountsRules.IsDomainSid(user.Sid))
        {
            throw new DomeniaOperationException(AccountsRules.SidInvalid, AccountsRules.SidInvalidMessage);
        }
        var now = source.Clock.GetUtcNow();
        var pdc = directory.Domain.Controllers.FirstOrDefault()?.DnsName ?? Controller ?? "DC01";
        var events = LockoutEvents(user, directory, pdc, now)
            .Where(e => e.At <= now && e.At >= now - TimeSpan.FromHours(hours))
            .OrderByDescending(e => e.At)
            .ToList();
        var truncated = events.Count > AccountsLockouts.MaxEvents;
        return (user, directory.Domain, new LockoutEventsRead(LockoutReadState.Read, pdc, true, [.. events.Take(AccountsLockouts.MaxEvents)], truncated));
    }

    public async Task<ImmutableArray<AccountsBatchCandidate>> CandidatesAsync(IReadOnlyList<string> dns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dns);
        await source.SimulateScreenLatencyAsync("accounts/batch", 90, 240, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        return [.. dns.Select(dn => new AccountsBatchCandidate(dn, SimulatedAccounts.FindByDn(directory, dn)))];
    }

    public async Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(password);
        await source.SimulateScreenLatencyAsync("accounts/validate", 700, 1500, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var domain = directory.Domain;
        var name = CredentialRules.Parse(request.Login);
        if (request.Scope.StartsWith(CredentialRules.Remote, StringComparison.Ordinal) && CredentialRules.IsLocalAccount(request.Login, request.Target))
        {
            // A local account of one workstation: a CIM session (5 s) on that workstation reads its name (CPT-018).
            var computer = SimulatedAccounts.FindComputer(directory, request.Target ?? "");
            if (computer is null || AdValues.IsDisabled(computer.UserAccountControl) || source.World.Presence.NeverAnswer.Contains(computer.ObjectGuid))
            {
                return new CredentialAnswer(false, "workstationUnreachable", null, null, "Simulation" + FrenchText.Colon + "poste absent, désactivé ou sans réponse dans l’annuaire fictif.");
            }
            return new CredentialAnswer(true, "ok", computer.Name + "\\" + name.Name, computer.Name, "Compte local complété par le nom du poste (Win32_ComputerSystem.Name lu par une session CIM).");
        }
        var known = name.Form switch
        {
            AccountNameForm.DownLevel => string.Equals(name.Authority, domain.NetbiosName, StringComparison.OrdinalIgnoreCase) || string.Equals(name.Authority, domain.DnsName, StringComparison.OrdinalIgnoreCase),
            AccountNameForm.Upn => string.Equals(name.Authority, domain.DnsName, StringComparison.OrdinalIgnoreCase),
            _ => false,
        };
        var user = known ? directory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, name.Name, StringComparison.OrdinalIgnoreCase)) : null;
        if (user is null)
        {
            return new CredentialAnswer(false, "unknownAccount", null, Controller, null);
        }
        var now = source.Clock.GetUtcNow();
        if (AdValues.IsDisabled(user.UserAccountControl))
        {
            return new CredentialAnswer(false, "disabled", null, Controller, null);
        }
        if (AccountsRules.LockOf(user) == AccountLock.Locked)
        {
            return new CredentialAnswer(false, "locked", null, Controller, null);
        }
        if (AccountsRules.AccountExpiry(user) is DateTimeOffset expires && expires <= now)
        {
            return new CredentialAnswer(false, "accountExpired", null, Controller, null);
        }
        switch (AccountState.ClassifyPassword(user, domain.PasswordPolicy.MaxPasswordAge, now, TimeSpan.Zero))
        {
            case PasswordClass.Expired:
                return new CredentialAnswer(false, "passwordExpired", null, Controller, null);
            case PasswordClass.MustChange:
                return new CredentialAnswer(false, "mustChange", null, Controller, null);
        }
        return new CredentialAnswer(true, "ok", domain.NetbiosName + "\\" + user.SamAccountName, Controller, null);
    }

    public async Task<RemoteProbeAnswer> ProbeAsync(string computer, string account, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(account);
        await source.SimulateScreenLatencyAsync("accounts/probe", 500, 1300, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var found = SimulatedAccounts.FindComputer(directory, computer);
        if (found is null || AdValues.IsDisabled(found.UserAccountControl))
        {
            return new RemoteProbeAnswer("timeout", "network", null, null);
        }
        if (source.World.Presence.NeverAnswer.Contains(found.ObjectGuid))
        {
            return new RemoteProbeAnswer("timeout", "timeout", null, null);
        }
        if (source.World.Presence.ErrorProbes.Contains(found.ObjectGuid))
        {
            return new RemoteProbeAnswer("error", "network", null, "RPC indisponible (0x800706BA)");
        }
        var name = CredentialRules.Parse(account);
        var user = name.Form is AccountNameForm.DownLevel or AccountNameForm.Upn
            ? directory.Users.FirstOrDefault(u => string.Equals(u.SamAccountName, name.Name, StringComparison.OrdinalIgnoreCase))
            : null;
        if (user is not null && (AdValues.IsDisabled(user.UserAccountControl) || AccountsRules.LockOf(user) == AccountLock.Locked))
        {
            return new RemoteProbeAnswer("authRejected", "accountState", null, null);
        }
        // Local administrators of the fictitious workstations: the administration accounts and the support groups (AGDLP).
        var admin = user is null || user.AdminCount == 1 || user.MemberOf.Any(g => g.Contains("GG-Support", StringComparison.OrdinalIgnoreCase) || g.Contains("GG-Admins-Postes", StringComparison.OrdinalIgnoreCase));
        if (!admin)
        {
            return new RemoteProbeAnswer("denied", "accessDenied", null, null);
        }
        var caption = source.World.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == found.ObjectGuid)?.Inventory.OsCaption
            ?? (found.OperatingSystem is string os ? "Microsoft " + os : null);
        return new RemoteProbeAnswer("observed", null, caption, null);
    }

    public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var world = source.World;
        var random = source.ScreenStream("accounts").Fork("access");
        var candidates = world.Directory.Computers
            .Where(c => !AdValues.IsDisabled(c.UserAccountControl) && c.DistinguishedName.Contains("OU=Paris,OU=Postes", StringComparison.OrdinalIgnoreCase))
            .OrderBy(c => c.Name, StringComparer.Ordinal)
            .ToList();
        if (candidates.Count == 0)
        {
            return Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
        }
        var target = candidates[random.Next(Math.Min(24, candidates.Count))].Name;
        ImmutableArray<AccessRequestSeed> seeds =
        [
            new AccessRequestSeed(CredentialRules.Laps, "Lecture du mot de passe LAPS", target, "accessDenied", world.Reference - TimeSpan.FromMinutes(14)),
        ];
        return Task.FromResult(seeds);
    }

    /// <summary>
    /// Fictitious 4740 events of one account: the last lockout at its lockoutTime, earlier lockouts of the same week, from the
    /// workstation of the user (managedBy) and from other workstations of its site; a few accounts with recent bad passwords had
    /// a lockout lifted during the week. Deterministic per account (sub-stream « lockouts/&lt;GUID&gt; »).
    /// </summary>
    private ImmutableArray<LockoutEventRead> LockoutEvents(DirectoryUser user, DirectorySnapshot directory, string pdc, DateTimeOffset now)
    {
        var random = source.ScreenStream("accounts").Fork("lockouts/" + user.ObjectGuid.ToString("N"));
        var lockedAt = AdValues.FromFileTime(user.LockoutTime);
        var count = lockedAt is not null ? 1 + random.Next(0, 3) : user.BadPasswordCount is > 0 && random.Chance(30) ? 1 : 0;
        if (count == 0)
        {
            return [];
        }
        var origins = Origins(user, directory, random);
        var events = ImmutableArray.CreateBuilder<LockoutEventRead>(count);
        var at = lockedAt ?? now - random.Between(TimeSpan.FromHours(20), TimeSpan.FromDays(6));
        for (var i = 0; i < count; i++)
        {
            var origin = i == 0 || random.Chance(65) ? origins[0] : origins[Math.Min(origins.Count - 1, 1 + random.Next(Math.Max(1, origins.Count - 1)))];
            events.Add(new LockoutEventRead(WritePlans.TruncateToSecond(at), origin, pdc));
            at -= random.Between(TimeSpan.FromHours(3), TimeSpan.FromHours(46));
        }
        return events.ToImmutable();
    }

    /// <summary>The workstation of the user first (managedBy), then two workstations of its site (a laptop when there is one).</summary>
    private static List<string> Origins(DirectoryUser user, DirectorySnapshot directory, SeededRandom random)
    {
        var site = SiteOf(user.DistinguishedName);
        var computers = directory.Computers
            .Where(c => !AdValues.IsDisabled(c.UserAccountControl) && c.DistinguishedName.Contains(",OU=Postes,", StringComparison.OrdinalIgnoreCase)
                && (site is null || c.DistinguishedName.Contains("OU=" + site + ",OU=Postes", StringComparison.OrdinalIgnoreCase)))
            .OrderBy(c => c.Name, StringComparer.Ordinal)
            .ToList();
        var result = new List<string>();
        var own = computers.FirstOrDefault(c => c.ManagedByDn is string m && string.Equals(m, user.DistinguishedName, StringComparison.OrdinalIgnoreCase));
        if (own is not null)
        {
            result.Add(own.Name);
        }
        var laptops = computers.Where(c => c.Name.StartsWith("PT-", StringComparison.Ordinal)).ToList();
        if (laptops.Count > 0)
        {
            result.Add(laptops[random.Next(laptops.Count)].Name);
        }
        if (computers.Count > 0)
        {
            result.Add(computers[random.Next(computers.Count)].Name);
        }
        if (result.Count == 0)
        {
            result.Add("PC-" + (site ?? "PAR").ToUpperInvariant()[..Math.Min(3, (site ?? "PAR").Length)] + "-" + random.Next(1, 200).ToString("0000", CultureInfo.InvariantCulture));
        }
        return [.. result.Distinct(StringComparer.OrdinalIgnoreCase)];
    }

    /// <summary>Site of a user from its DN (« Lyon » for …,OU=Lyon,OU=Utilisateurs,…), or null.</summary>
    private static string? SiteOf(string dn)
    {
        try
        {
            var names = DistinguishedName.Parse(dn);
            for (var i = 1; i < names.Length - 1; i++)
            {
                if (string.Equals(names[i + 1].Value, "Utilisateurs", StringComparison.OrdinalIgnoreCase) && string.Equals(names[i].Type, "OU", StringComparison.OrdinalIgnoreCase))
                {
                    return names[i].Value;
                }
            }
        }
        catch (FormatException)
        {
            return null;
        }
        return null;
    }

    /// <summary>OU tree of the directory as the session sees it, rebuilt when the overlay changes.</summary>
    private OrganizationalUnitTree Tree()
    {
        lock (gate)
        {
            var version = source.Overlay.Version;
            if (built is not { } known || known.Version != version)
            {
                known = (version, OrganizationalUnitTree.Build(source.CurrentDirectory));
                built = known;
            }
            return known.Tree;
        }
    }
}

/// <summary>Lookups shared by the readers and executors of the Comptes screen in simulation.</summary>
internal static class SimulatedAccounts
{
    /// <summary>The user at this DN: exact text first, then the RFC 4514 comparison (case and escaping ignored).</summary>
    public static DirectoryUser? FindByDn(DirectorySnapshot directory, string dn)
    {
        var exact = directory.Users.FirstOrDefault(u => string.Equals(u.DistinguishedName, dn, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }
        return directory.Users.FirstOrDefault(u =>
        {
            try
            {
                return DistinguishedName.AreEqual(u.DistinguishedName, dn);
            }
            catch (FormatException)
            {
                return false;
            }
        });
    }

    public static DirectoryUser? FindByGuid(DirectorySnapshot directory, string objectGuid) =>
        Guid.TryParseExact(objectGuid, "D", out var id) ? directory.Users.FirstOrDefault(u => u.ObjectGuid == id) : null;

    /// <summary>A computer by its name or DNS name (first label, case ignored).</summary>
    public static DirectoryComputer? FindComputer(DirectorySnapshot directory, string name)
    {
        var key = CredentialRules.MachineKey(name);
        return key.Length == 0 ? null : directory.Computers.FirstOrDefault(c => string.Equals(c.Name, key, StringComparison.OrdinalIgnoreCase));
    }
}
