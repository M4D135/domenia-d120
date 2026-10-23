using System.Net;
using System.Security;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdAccountsAccessTests
{
    [Test]
    public static async Task Switching_authenticates_once_then_adopts_the_exact_account_and_disposes_the_previous_connection()
    {
        using var source = Source(out var previous);
        var next = new Connection("Bob", 1002);
        var calls = 0;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = options =>
        {
            calls++;
            Check.Equal("Bob", options.Credential!.UserName, "compte fourni à la connexion");
            using var copy = options.Credential.SecurePassword;
            Check.Equal(1, copy.Length, "copie du secret disponible à la construction");
            return next;
        } };
        using var password = Secret('x');
        var epoch = source.Epoch;
        var result = await reader.OpenSessionAsync(new("TEST\\Bob", CredentialRules.Directory, null), password, CancellationToken.None);
        Check.True(result.Answer.Success, "validation réelle abstraite confirmée");
        Check.Equal(1, calls, "un seul essai");
        Check.True(previous.Disposed, "ancienne connexion fermée");
        Check.False(next.Disposed, "connexion validée adoptée");
        Check.Equal(epoch + 1, source.Epoch, "nouvelle époque");
        var session = await source.GetSessionAsync(CancellationToken.None);
        Check.Equal("TEST\\Bob", session.Account.Login, "nouvelle identité");
        Check.Equal(AuthenticationMethod.ExplicitCredentials, session.Authentication.Method, "compte explicite");
        Check.Equal(Fixtures.Domain.DomainSid + "-1002", await reader.SessionSidAsync(CancellationToken.None), "SID relu");
    }

    [Test]
    public static async Task Failed_bind_foreign_domain_or_unresolved_identity_keeps_the_previous_session()
    {
        using var source = Source(out var previous);
        using var password = Secret('x');
        foreach (var candidate in new[]
        {
            new Connection("Bob", 1002) { Failure = new DomeniaOperationException(AdErrors.Credentials, "Refus") },
            new Connection("Bob", 1002) { Root = "DC=other,DC=local" },
            new Connection("Bob", 1002) { DomainSid = "S-1-5-21-9-9-9" },
            new Connection("Bob", 1002) { MissingUser = true },
        })
        {
            using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => candidate };
            var result = await reader.OpenSessionAsync(new("TEST\\Bob", CredentialRules.Directory, null), password, CancellationToken.None);
            Check.False(result.Answer.Success, "bascule refusée");
            Check.True(candidate.Disposed, "candidate abandonnée");
            Check.False(previous.Disposed, "ancienne connexion conservée");
            Check.Equal("TEST\\Alice", (await source.GetSessionAsync(CancellationToken.None)).Account.Login, "ancienne identité conservée");
        }
    }

    [Test]
    public static async Task Malformed_local_directory_or_empty_credentials_never_call_a_network_factory()
    {
        using var source = Source(out _);
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => throw new InvalidOperationException("réseau interdit") };
        using var password = Secret('x'); using var empty = new SecureString();
        foreach (var login in new[] { "Alice", ".\\Alice", "OTHER\\Alice", "TEST\\Alice\n", "TEST\\Alice@other" })
        {
            Check.False((await reader.ValidateAsync(new(login, CredentialRules.Directory, null), password, CancellationToken.None)).Success, "contexte refusé");
        }
        Check.False((await reader.ValidateAsync(new("TEST\\Alice", CredentialRules.Directory, null), empty, CancellationToken.None)).Success, "secret vide refusé");
    }

    [Test]
    public static async Task Password_correction_consumes_the_same_verified_secret_without_a_second_authentication()
    {
        using var source = Source(out var previous);
        var candidate = new Connection("Alice", 1001);
        var calls = 0;
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => { calls++; return candidate; } };
        using var password = Secret('x');
        var result = await reader.ValidateAsync(new("TEST\\Alice", CredentialRules.Directory, null), password, CancellationToken.None);
        Check.True(result.Success, "nouveau secret vérifié");
        Check.False(previous.Disposed, "valider ne remplace pas encore la connexion");
        var changed = await reader.SwapConnectionPasswordAsync(password, CancellationToken.None);
        Check.True(changed.Replaced, "remplacement confirmé");
        Check.True(previous.Disposed, "ancien transport fermé");
        Check.Equal(1, calls, "pas de second bind");
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SwapConnectionPasswordAsync(password, CancellationToken.None), "preuve à usage unique");
    }

    [Test]
    public static async Task A_different_or_missing_password_proof_never_replaces_the_connection()
    {
        using var source = Source(out var previous);
        var candidate = new Connection("Alice", 1001);
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => candidate };
        using var password = Secret('x'); using var other = Secret('y');
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SwapConnectionPasswordAsync(password, CancellationToken.None), "validation obligatoire");
        await reader.ValidateAsync(new("TEST\\Alice", CredentialRules.Directory, null), password, CancellationToken.None);
        await Check.ThrowsAsync<DomeniaOperationException>(() => reader.SwapConnectionPasswordAsync(other, CancellationToken.None), "secret différent refusé");
        Check.False(previous.Disposed, "session inchangée");
        Check.True(candidate.Disposed, "preuve refusée libérée");
    }

    [Test]
    public static async Task A_late_validation_cannot_replace_a_reset_session()
    {
        using var source = Source(out _);
        var signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var candidate = new Connection("Bob", 1002) { Wait = signal.Task };
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => candidate };
        using var password = Secret('x');
        var task = reader.OpenSessionAsync(new("TEST\\Bob", CredentialRules.Directory, null), password, CancellationToken.None);
        source.Reset(); signal.SetResult();
        var result = await task;
        Check.False(result.Answer.Success, "ancienne validation écartée");
        Check.True(candidate.Disposed, "connexion tardive fermée");
        Check.Equal(ConnectionState.Disconnected, (await source.GetSessionAsync(CancellationToken.None)).Connection, "réinitialisation conservée");
    }

    [Test]
    public static async Task Cancelling_returns_before_a_native_call_but_disposes_its_late_connection()
    {
        using var source = Source(out var previous);
        var signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var candidate = new Connection("Bob", 1002) { Wait = signal.Task };
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => candidate };
        using var password = Secret('x'); using var stop = new CancellationTokenSource();
        var task = reader.OpenSessionAsync(new("TEST\\Bob", CredentialRules.Directory, null), password, stop.Token);
        stop.Cancel();
        await Check.ThrowsAsync<OperationCanceledException>(() => task, "retour immédiat de l’annulation");
        Check.False(candidate.Disposed, "le travailleur possède encore sa connexion native");
        signal.SetResult();
        await candidate.Closed.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Check.False(previous.Disposed, "connexion précédente conservée");
    }

    [Test]
    public static void Secret_copies_are_detected_only_until_their_actual_owner_releases_them()
    {
        using var password = Secret('x'); using var same = Secret('x'); using var other = Secret('y');
        Check.True(AdAccountsAccessReader.SameSecret(password, same), "copie identique");
        Check.False(AdAccountsAccessReader.SameSecret(password, other), "secret différent");
        var lease = SecureCredentialCopies.Track(password);
        Check.True(SecureCredentialCopies.Contains(same), "copie encore détenue");
        Check.False(SecureCredentialCopies.Contains(other), "autre secret");
        lease.Dispose();
        Check.False(SecureCredentialCopies.Contains(same), "copie libérée");
    }

    [Test]
    public static void Authentication_diagnostics_only_keep_allowlisted_failure_kinds()
    {
        foreach (var (code, kind) in new[] { ("525", "unknownAccount"), ("532", "passwordExpired"), ("533", "disabled"), ("701", "accountExpired"), ("773", "mustChange"), ("775", "locked"), ("530", "restricted"), ("52e", "badCredentials") })
        { Check.Equal(kind, AdAuthenticationErrors.Kind("80090308: LdapErr: DSID-000, comment: bind failure, data " + code + ", v000"), "sous-code Windows"); }
        foreach (var invalid in new[] { "", "775", "metadata 775", "data 775bad!", new string('x', 8193) })
        { Check.Equal("badCredentials", AdAuthenticationErrors.Kind(invalid), "diagnostic absent ou inconnu"); }
    }

    [Test]
    public static async Task Correction_reports_an_outstanding_copy_of_the_old_connection_secret()
    {
        using var source = Source(out _);
        using var oldPassword = Secret('o'); using var newPassword = Secret('n');
        var credential = new NetworkCredential("Alice", oldPassword, "TEST");
        var oldConnection = new AdConnection(new("dc1.test.local", "test.local") { Credential = credential });
        credential.SecurePassword = null;
        source.AdoptConnection(oldConnection, Fixtures.Domain, Identity("Alice", 1001), source.Epoch, false);
        using var outstanding = oldConnection.CopyCredential();
        using var reader = new AdAccountsAccessReader(source) { ConnectionFactory = _ => new Connection("Alice", 1001) };
        await reader.ValidateAsync(new("TEST\\Alice", CredentialRules.Directory, null), newPassword, CancellationToken.None);
        var swap = await reader.SwapConnectionPasswordAsync(newPassword, CancellationToken.None);
        Check.True(swap.OtherRefusedCopy, "une lecture possède encore l’ancien secret");
        Check.Equal(1, outstanding.Password!.Length, "la fermeture LDAP ne détruit pas la copie de la lecture");
    }

    [Test]
    public static async Task A_local_account_is_bound_to_the_exact_workstation_and_requires_its_confirmed_name()
    {
        using var source = Source(out _);
        await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [Fixtures.Computer("PC-01")]), source.Epoch, CancellationToken.None);
        Check.Null(await new AdMachineAccountReader(source).FindWorkstationAsync("PC-01.other.local", CancellationToken.None), "FQDN étranger sans repli vers un homonyme");
        var calls = 0;
        var confirmed = "PC-01";
        using var reader = new AdAccountsAccessReader(source)
        {
            ConnectionFactory = _ => throw new InvalidOperationException("aucune tentative LDAP pour un compte local"),
            ProbeOverride = (request, workstation, confirmName, token) =>
            {
                calls++;
                Check.True(confirmName, "nom relu par CIM");
                Check.Equal("PC-01\\Admin", request.Account, "point remplacé par le poste cible");
                Check.Equal(MachineAccountSource.TemporaryLocal, request.Source, "source explicite locale");
                return Task.FromResult(new MachineTrialObservation("Observed", null, null, null, workstation) { ConfirmedComputerName = confirmed });
            },
        };
        using var password = Secret('x');
        var request = new CredentialRequest(".\\Admin", CredentialRules.Remote, "PC-01");
        var result = await reader.ValidateAsync(request, password, CancellationToken.None);
        Check.True(result.Success, "compte local confirmé");
        Check.Equal("PC-01\\Admin", result.BindUser, "identité canonique locale");
        confirmed = "PC-OTHER";
        Check.False((await reader.ValidateAsync(request, password, CancellationToken.None)).Success, "autre machine refusée");
        Check.Equal(2, calls, "un seul essai par geste");
    }

    private static SecureString Secret(char value) { var result = new SecureString(); result.AppendChar(value); result.MakeReadOnly(); return result; }
    private static AdDirectorySource Source(out Connection initial)
    {
        var source = new AdDirectorySource("test.local", () => "TEST\\Desktop", TestClock.Fixed(), connection: new Connection("Desktop", 999));
        initial = new("Alice", 1001);
        source.AdoptConnection(initial, Fixtures.Domain, Identity("Alice", 1001), source.Epoch, false);
        return source;
    }
    private static AdSessionIdentity Identity(string name, int rid) => new(new("TEST\\" + name, name, name, "CN=" + name + "," + Fixtures.People), Fixtures.Domain.DomainSid + "-" + rid, new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés"));
    private static byte[] Sid(string value) { var sid = new SecurityIdentifier(value); var data = new byte[sid.BinaryLength]; sid.GetBinaryForm(data, 0); return data; }

    private sealed class Connection(string name, int rid) : IAdConnection
    {
        public string Server => "DC1.test.local";
        internal string Root { get; init; } = Fixtures.Root;
        internal string DomainSid { get; init; } = Fixtures.Domain.DomainSid;
        internal Task? Wait { get; init; }
        internal DomeniaOperationException? Failure { get; init; }
        internal bool MissingUser { get; init; }
        internal bool Disposed { get; private set; }
        internal TaskCompletionSource Closed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken)
        {
            if (Wait is { } wait) { await wait; }
            if (Failure is { } failure) { throw failure; }
            return new(Root, "CN=Configuration," + Root, "CN=Schema,CN=Configuration," + Root, Root, Server, null, null, [], null);
        }
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyList<AdEntry> rows = request.Scope == AdSearchScope.Base
                ? [new(Root, new Dictionary<string, IReadOnlyList<object>> { ["objectSid"] = [Sid(DomainSid)] })]
                : MissingUser ? [] : [AdFicheReaderTests.Entry("CN=" + name + "," + Fixtures.People, "user", new()
                { ["sAMAccountName"] = [name], ["userPrincipalName"] = [name + "@test.local"], ["objectSid"] = [Sid(Fixtures.Domain.DomainSid + "-" + rid)] })];
            return Task.FromResult(rows);
        }
        public Task<AdEntry?> ReadAsync(string dn, IReadOnlyList<string> attributes, CancellationToken token) => throw new InvalidOperationException("lecture non prévue");
        public Task ModifyAsync(string dn, IReadOnlyList<AdModification> changes, CancellationToken token) => throw new InvalidOperationException("écriture interdite");
        public Task RenameAsync(string dn, string parent, string rdn, CancellationToken token) => throw new InvalidOperationException("écriture interdite");
        public Task AddAsync(string dn, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken token) => throw new InvalidOperationException("écriture interdite");
        public Task DeleteAsync(string dn, CancellationToken token) => throw new InvalidOperationException("écriture interdite");
        public void Dispose() { Disposed = true; Closed.TrySetResult(); }
    }
}
