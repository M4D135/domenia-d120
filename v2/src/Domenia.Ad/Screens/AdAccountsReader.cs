using System.Collections.Immutable;
using System.Net;
using System.Security;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// Comptes screen on the real directory (docs/ops/comptes.md § 7): every row, every field and every event comes from a read of
/// the controllers, nothing is invented and nothing is kept in memory between two reads. The list is one bounded search under
/// the chosen scope (never the whole domain, 5 000 objects, 30 s), the detail reads the object itself and the groups it belongs
/// to, the lockout report reads the Security log of the PDC emulator for that one SID. A validation is one explicit bind whose
/// identity is read back; a trial on a workstation is one light CIM read. Read only: this class never writes, never retries and
/// never keeps a password (the <see cref="SecureString"/> given by the caller reaches the Windows API and goes no further).
/// </summary>
public sealed class AdAccountsReader : IAccountsReader, IAccountsAccessReader
{
    private const string NotAUserMessage = "Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire\u00A0: rien n’a été lu.";

    /// <summary>Constructed attributes are read object by object when the paged search did not answer them (bounded).</summary>
    private const int MaxConstructedReads = 400;

    /// <summary>Most DNs one collective action asks for (the page never sends more; anything beyond is answered « unknown »).</summary>
    private const int MaxCandidates = 500;

    private readonly AdDirectorySource source;

    /// <summary>Found by ScreenReaders.Discover for the directory source; cheap: nothing is read here.</summary>
    public AdAccountsReader(AdDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public bool Simulated => false;

    public bool SessionSwitchAvailable => true;

    public DateTimeOffset? SessionStartedAt => source.ConnectedAt;

    public (DateTimeOffset Now, TimeZoneInfo Zone, bool Simulated) Clock => (source.Clock.GetUtcNow(), source.Zone, false);

    public async Task<AccountsList> ListAsync(AccountsScope scope, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var now = source.Clock.GetUtcNow();
        var selection = new ScopeSelection(scope.Dn, scope.Label, scope.Subtree);
        // Never the whole domain: the root reads nothing and proposes the OUs that hold accounts.
        var tooWide = ScopeRules.IsDomainRoot(selection, domain.RootDn);
        var rows = ImmutableArray<AccountsRow>.Empty;
        var truncated = false;
        if (!tooWide)
        {
            var users = await SearchUsersAsync(selection, cancellationToken).ConfigureAwait(false);
            users = await AdObjectAccess.FillConstructedAsync(source.Connection, users, MaxConstructedReads, cancellationToken).ConfigureAwait(false);
            rows = [.. users
                .OrderBy(u => FrenchText.Fold(AccountsRules.NameOf(u)), StringComparer.Ordinal)
                .ThenBy(u => u.SamAccountName, StringComparer.OrdinalIgnoreCase)
                .Select(u => AccountsRules.Row(u, domain, now))];
            truncated = users.Count >= AccountsRules.ListLimit;
        }

        var suggestions = rows.IsEmpty ? Suggestions() : [];
        return new AccountsList(
            scope,
            tooWide,
            now,
            source.ControllerName,
            false,
            AccountsRules.Policy(domain.PasswordPolicy),
            AccountsRules.Counts(rows, now),
            rows,
            truncated,
            AccountsRules.ListLimit,
            suggestions);
    }

    public async Task<AccountsDetail> DetailAsync(string dn, string? operatorDn, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dn);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var user = await AdObjectAccess.ReadUserAsync(source.Connection, dn, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(AccountsRules.UnknownAccount, NotAUserMessage);

        // The detail shows the groups and the responsible: those objects are read too, within the same bounded reads.
        var groups = await AdObjectAccess.ReadGroupsAsync(source.Connection, domain.RootDn, user.MemberOf, 2000, cancellationToken).ConfigureAwait(false);
        var people = ImmutableArray.Create(user);
        if (user.ManagerDn is string manager && AdObjectAccess.IsDn(manager))
        {
            if (await AdObjectAccess.ReadUserAsync(source.Connection, manager, cancellationToken).ConfigureAwait(false) is DirectoryUser boss)
            {
                people = [user, boss];
            }
        }

        var picture = new DirectorySnapshot(domain, source.Clock.GetUtcNow(), false, [], people, [], [.. groups]);
        return AccountsRules.Detail(user, picture, source.ControllerName, operatorDn, source.Clock.GetUtcNow(), source.Zone, false);
    }

    public async Task<(DirectoryUser User, DomainInfo Domain, LockoutEventsRead Read)> LockoutEventsAsync(string dn, int hours, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dn);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var user = await AdObjectAccess.ReadUserAsync(source.Connection, dn, cancellationToken).ConfigureAwait(false)
            ?? throw new DomeniaOperationException(AccountsRules.UnknownAccount, NotAUserMessage);
        if (!AccountsRules.IsDomainSid(user.Sid))
        {
            throw new DomeniaOperationException(AccountsRules.SidInvalid, AccountsRules.SidInvalidMessage);
        }

        // The credential of the session (CPT-007) is the only one ever given to the log read; without one, the Windows session reads.
        var credential = source.ConnectionCredential;
        var read = await AdSecurityLog.ReadLockoutsAsync(
            source.Connection,
            domain,
            user.Sid,
            hours,
            AccountsLockouts.MaxEvents,
            source.ControllerName,
            credential?.UserName,
            credential?.SecurePassword,
            cancellationToken).ConfigureAwait(false);
        var state = read.State switch
        {
            "refused" => LockoutReadState.Refused,
            "read" => LockoutReadState.Read,
            _ => LockoutReadState.Unavailable,
        };
        return (user, domain, new LockoutEventsRead(state, read.Server, read.ServerIsPdc, read.Events, read.Truncated));
    }

    public async Task<ImmutableArray<AccountsBatchCandidate>> CandidatesAsync(IReadOnlyList<string> dns, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dns);
        var connection = source.Connection;
        var candidates = ImmutableArray.CreateBuilder<AccountsBatchCandidate>(dns.Count);
        foreach (var dn in dns.Take(MaxCandidates))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var user = AdObjectAccess.IsDn(dn) ? await AdObjectAccess.ReadUserLightAsync(connection, dn, cancellationToken).ConfigureAwait(false) : null;
            candidates.Add(new AccountsBatchCandidate(dn, user));
        }

        return [.. candidates];
    }

    public async Task<CredentialAnswer> ValidateAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(password);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        if (request.Scope.StartsWith(CredentialRules.Remote, StringComparison.Ordinal) && CredentialRules.IsLocalAccount(request.Login, request.Target))
        {
            // A local account of one workstation: a CIM session (5 s) reads its name (CPT-018). Nothing is guessed about the password.
            var computer = CredentialRules.MachineKey(request.Target);
            if (computer.Length == 0)
            {
                return new CredentialAnswer(false, "input", null, null, "Aucun nom de poste exploitable dans la demande.");
            }

            var name = await AdWorkstation.ReadMachineNameAsync(computer, request.Login, password, cancellationToken).ConfigureAwait(false);
            return name is null
                ? new CredentialAnswer(false, "workstationUnreachable", null, computer, "Le poste n’a pas répondu à la session CIM en 5 secondes.")
                : new CredentialAnswer(true, "ok", name + "\\" + CredentialRules.Parse(request.Login).Name, name, "Compte local complété par le nom du poste (Win32_ComputerSystem.Name lu par une session CIM).");
        }

        var bind = await AdBind.ValidateAsync(source.ControllerName, domain.DnsName, request.Login, password, null, cancellationToken).ConfigureAwait(false);
        if (!bind.Success)
        {
            return new CredentialAnswer(false, bind.Kind, bind.BindUser, bind.Controller ?? source.ControllerName, bind.Detail);
        }

        if (bind.BindUser is not { Length: > 0 } who || !BelongsToDomain(who, domain))
        {
            return new CredentialAnswer(false, "identityMismatch", bind.BindUser, bind.Controller ?? source.ControllerName, "Identité hors du domaine de la session.");
        }

        // The bind proved the password; the SID of that identity is read in the directory, never invented.
        var sid = await SidOfAsync(domain, who, cancellationToken).ConfigureAwait(false);
        return new CredentialAnswer(true, "ok", who, bind.Controller ?? source.ControllerName, null, sid);
    }

    public async Task<SessionOpenAnswer> OpenSessionAsync(CredentialRequest request, SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(password);
        // One validation of the proposed account (the same checks as « Tester »), then the session takes that identity.
        var answer = await ValidateAsync(request, password, cancellationToken).ConfigureAwait(false);
        if (!answer.Success || answer.BindUser is null)
        {
            return new SessionOpenAnswer(answer, null);
        }

        source.UseCredential(new NetworkCredential(answer.BindUser, password));
        var session = await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        var identity = session.Account;
        return new SessionOpenAnswer(answer with { Sid = source.SessionSid ?? answer.Sid }, identity with { Login = answer.BindUser });
    }

    public async Task<ConnectionSecretSwap> SwapConnectionPasswordAsync(SecureString password, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(password);
        var held = source.ConnectionCredential;
        if (held is null)
        {
            throw new DomeniaOperationException(AccountAccess.CorrectionUnavailable, "La session s’appuie sur la session Windows elle-même et ne tient aucun mot de passe à corriger.");
        }

        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);

        // The same identity must bind with the corrected secret before anything is replaced (CPT-008).
        var bind = await AdBind.ValidateAsync(source.ControllerName, domain.DnsName, held.UserName, password, null, cancellationToken).ConfigureAwait(false);
        if (!bind.Success || bind.BindUser is not { Length: > 0 } who || !BelongsToDomain(who, domain))
        {
            throw new DomeniaOperationException(AccountAccess.CorrectionUnavailable, "Le mot de passe corrigé n’a pas été accepté par le même compte\u00A0: rien n’a été changé.");
        }

        source.UseCredential(new NetworkCredential(who, password));
        return new ConnectionSecretSwap(true, 0, false);
    }

    public Task<RemoteProbeAnswer> ProbeAsync(string computer, RemoteProbeCredential credential, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(computer);
        ArgumentNullException.ThrowIfNull(credential);
        // One light CIM read of that workstation with the account the operator gave (docs/ops/comptes.md § 7.4).
        return AdWorkstation.ProbeAsync(computer, credential.Account, credential.Password, credential.Session, cancellationToken);
    }

    public Task<ImmutableArray<AccessRequestSeed>> InitialRequestsAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        // Nothing is known at startup: a refusal is recorded when it happens, during this session (CPT-013).
        return Task.FromResult(ImmutableArray<AccessRequestSeed>.Empty);
    }

    public async Task<string?> SessionSidAsync(CancellationToken cancellationToken)
    {
        await source.GetSessionAsync(cancellationToken).ConfigureAwait(false);
        return source.SessionSid;
    }

    /// <summary>Users of the scope, one paged search, at most <see cref="AccountsRules.ListLimit"/> objects (30 s).</summary>
    private async Task<IReadOnlyList<DirectoryUser>> SearchUsersAsync(ScopeSelection scope, CancellationToken cancellationToken)
    {
        if (!AdObjectAccess.IsDn(scope.Dn))
        {
            return [];
        }

        var request = new AdSearchRequest(
            scope.Dn,
            "(&(objectCategory=person)(objectClass=user))",
            scope.Subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel,
            AdObjectAccess.AccountAttributes)
        {
            PageSize = 1000,
            SizeLimit = AccountsRules.ListLimit,
            Timeout = AdObjectAccess.SearchTimeout,
        };
        var entries = await source.Connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
        return [.. entries.Select(AdDirectoryMapper.User).OfType<DirectoryUser>()];
    }

    /// <summary>OUs that hold accounts, from the last picture read in this session (no picture: no suggestion).</summary>
    private ImmutableArray<AccountsScopeSuggestion> Suggestions() =>
        source.CurrentDirectory is { } picture ? AccountsRules.Suggestions(picture, OrganizationalUnitTree.Build(picture)) : [];

    /// <summary>Whether « DOMAINE\compte » (or compte@domaine) belongs to this domain, by its NetBIOS or DNS name.</summary>
    private static bool BelongsToDomain(string bindUser, DomainInfo domain)
    {
        var at = bindUser.IndexOf('@', StringComparison.Ordinal);
        if (at > 0)
        {
            return string.Equals(bindUser[(at + 1)..], domain.DnsName, StringComparison.OrdinalIgnoreCase);
        }

        var separator = bindUser.IndexOf('\\', StringComparison.Ordinal);
        var authority = separator > 0 ? bindUser[..separator] : bindUser;
        return string.Equals(authority, domain.NetbiosName, StringComparison.OrdinalIgnoreCase)
            || string.Equals(authority, domain.DnsName, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>SID of the account that bound, read by its sAMAccountName (one bounded search), or null when it is not in the directory.</summary>
    private async Task<string?> SidOfAsync(DomainInfo domain, string bindUser, CancellationToken cancellationToken)
    {
        var name = CredentialRules.Parse(bindUser).Name;
        if (name.Length == 0)
        {
            return null;
        }

        var request = new AdSearchRequest(domain.RootDn, "(sAMAccountName=" + AdObjectAccess.Escape(name) + ")", AdSearchScope.Subtree, ["objectSid"]) { SizeLimit = 1, Timeout = AdObjectAccess.ReadTimeout };
        var found = await source.Connection.SearchAsync(request, cancellationToken).ConfigureAwait(false);
        return found.Count == 0 ? null : AdDirectoryMapper.User(found[0])?.Sid;
    }
}
