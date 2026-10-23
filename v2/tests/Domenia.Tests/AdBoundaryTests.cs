using System.Runtime.InteropServices;
using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Tests;

/// <summary>Real-mode boundaries exercised with a recording transport, never a domain or a workstation.</summary>
internal static class AdBoundaryTests
{
    [Test]
    public static async Task Local_session_index_and_summary_never_contact_the_directory()
    {
        using var connection = new RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        using var tree = new AdDirectoryTreeReader(source);
        var session = await source.GetSessionAsync(CancellationToken.None);
        Check.Equal(ConnectionState.Disconnected, session.Connection, "aucune connexion implicite");
        Check.Null(await tree.FindLocalAsync(Fixtures.Postes, CancellationToken.None), "OU non lue");
        var unavailable = await Check.ThrowsAsync<DomeniaOperationException>(() => source.ReadLocalAsync(CancellationToken.None), "base non lue");
        Check.Equal(AdErrors.NotConnected, unavailable.Code, "refus local explicite");
        await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(MeasureFamily.LocalComputation, null, CancellationToken.None), "recalcul local");
        Check.Equal(0, connection.Calls, "aucune requête réseau pour un appel local");
    }

    [Test]
    public static async Task A_missing_refresh_scope_is_refused_before_connecting()
    {
        using var connection = new RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        foreach (var family in new[] { MeasureFamily.Directory, MeasureFamily.Presence, MeasureFamily.Inventory })
        {
            var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => source.RefreshAsync(family, null, CancellationToken.None), "périmètre absent");
            Check.Equal(DomeniaErrors.ScopeTooWide, refused.Code, "refus du domaine entier");
        }
        Check.Equal(0, connection.Calls, "aucune connexion sans périmètre");
    }

    [Test]
    public static async Task Directory_snapshots_preserve_the_selected_branch_and_depth()
    {
        foreach (var subtree in new[] { false, true })
        {
            using var connection = new RecordingAdConnection();
            var selected = new ScopeSelection(Fixtures.Postes, "Postes", subtree);
            var snapshot = await AdDirectoryReader.ReadSnapshotAsync(connection, Fixtures.Domain, selected, 10, TestClock.Fixed(), CancellationToken.None);
            Check.True(snapshot.Complete, "lecture vide complète");
            Check.Equal(selected, snapshot.Coverage, "périmètre explicite du relevé");
            Check.Equal(5, connection.Searches.Count, "cinq classes d’objets, contacts compris");
            foreach (var search in connection.Searches)
            {
                Check.Equal(selected.Dn, search.BaseDn, "l’OU, jamais la racine");
                Check.Equal(subtree ? AdSearchScope.Subtree : AdSearchScope.OneLevel, search.Scope, "profondeur choisie");
                Check.Equal(11, search.SizeLimit, "une sentinelle pour prouver la troncature");
                Check.True(search.PageSize > 0 && search.Timeout > TimeSpan.Zero, "pagination et délai bornés");
            }
        }
    }

    [Test]
    public static async Task Domain_root_foreign_and_malformed_scopes_send_no_object_search()
    {
        foreach (var dn in new[] { Fixtures.Root, "dc=TEST,dc=LOCAL", "OU=Postes,DC=foreign,DC=local", "OU=Postes,", "" })
        {
            using var connection = new RecordingAdConnection();
            var refused = await Check.ThrowsAsync<DomeniaOperationException>(
                () => AdDirectoryReader.ReadSnapshotAsync(connection, Fixtures.Domain, new ScopeSelection(dn, "Test", true), 10, TestClock.Fixed(), CancellationToken.None), "portée refusée");
            Check.True(refused.Code is DomeniaErrors.ScopeTooWide or DomeniaErrors.ScopeOutsideDomain, "refus de portée");
            Check.Equal(0, connection.Calls, "aucune requête sur une portée interdite");
        }
    }

    [Test]
    public static async Task The_source_passes_the_OU_to_its_snapshot_reader()
    {
        using var connection = new RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        await source.RefreshAsync(MeasureFamily.Directory, new ScopeSelection(Fixtures.Postes, "Postes", false), CancellationToken.None);
        var objects = connection.Searches.Where(s => s.Filter is AdDirectoryMapper.OuFilter or AdDirectoryMapper.UserFilter or AdDirectoryMapper.ComputerFilter or AdDirectoryMapper.GroupFilter or AdDirectoryMapper.ContactFilter).ToArray();
        Check.Equal(5, objects.Length, "relecture des cinq classes");
        Check.True(objects.All(s => s.BaseDn == Fixtures.Postes && s.Scope == AdSearchScope.OneLevel), "aucun élargissement silencieux");
        var calls = connection.Calls;
        await source.ReadLocalAsync(CancellationToken.None);
        await source.GetSessionAsync(CancellationToken.None);
        Check.Equal(calls, connection.Calls, "relecture locale après connexion");
    }

    [Test]
    public static async Task Truncated_or_unreadable_entries_never_produce_a_complete_snapshot()
    {
        using var connection = new RecordingAdConnection();
        connection.Ous = [Ou("A"), Ou("B")];
        var scope = new ScopeSelection(Fixtures.Postes, "Postes", true);
        var truncated = await AdDirectoryReader.ReadSnapshotAsync(connection, Fixtures.Domain, scope, 1, TestClock.Fixed(), CancellationToken.None);
        Check.False(truncated.Complete, "limite atteinte prouvée");
        Check.Equal(1, truncated.OrganizationalUnits.Length, "plafond conservé");
        connection.Ous = [new AdEntry("OU=Sans-identité," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>())];
        var unreadable = await AdDirectoryReader.ReadSnapshotAsync(connection, Fixtures.Domain, scope, 10, TestClock.Fixed(), CancellationToken.None);
        Check.False(unreadable.Complete, "objet illisible signalé");
        Check.Equal(0, unreadable.ObjectCount, "aucune identité inventée");
    }

    [Test]
    public static async Task A_local_OU_index_is_populated_only_by_the_picker_and_reset_with_the_session()
    {
        using var connection = new RecordingAdConnection { Ous = [Ou("Atelier")] };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        using var tree = new AdDirectoryTreeReader(source);
        var dn = "OU=Atelier," + Fixtures.Postes;
        Check.Null(await tree.FindLocalAsync(dn, CancellationToken.None), "index froid");
        await tree.RootAsync(CancellationToken.None);
        var calls = connection.Calls;
        Check.True(await tree.FindLocalAsync(dn, CancellationToken.None) is not null, "index chargé par geste");
        Check.Equal(calls, connection.Calls, "consultation sans réseau");
        source.Reset();
        Check.Null(await tree.FindLocalAsync(dn, CancellationToken.None), "ancien index invalidé");
        Check.Equal(calls, connection.Calls, "réinitialisation sans lecture");
    }

    [Test]
    public static void Malformed_SIDs_and_absent_identities_are_not_mapped()
    {
        var values = new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Guid.NewGuid().ToByteArray()],
            ["objectSid"] = [new byte[8]],
        };
        var malformed = new AdEntry("CN=Invalide," + Fixtures.People, values);
        Check.Null(AdDirectoryMapper.User(malformed), "SID illisible");
        Check.Null(AdDirectoryMapper.Computer(malformed), "poste illisible");
        Check.Null(AdDirectoryMapper.Group(malformed), "groupe illisible");
        Check.Null(AdDirectoryMapper.Ou(new AdEntry(Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>())), "GUID absent");
    }

    [Test]
    public static void AD_intervals_and_WMI_dates_keep_their_native_meaning()
    {
        Check.Equal(TimeSpan.FromMinutes(30), AdDirectoryReader.Interval(-TimeSpan.FromMinutes(30).Ticks), "intervalle AD négatif");
        foreach (var sentinel in new long?[] { null, 0, long.MinValue, 42 })
        {
            Check.Equal(TimeSpan.Zero, AdDirectoryReader.Interval(sentinel), "pas de durée inventée");
        }
        Check.Equal<DateTimeOffset?>(new DateTimeOffset(2026, 10, 21, 14, 26, 0, TimeSpan.Zero).AddMilliseconds(500),
            WmiWorkstationProbe.ParseDmtf("20261021162600.500000+120"), "offset et microsecondes");
        foreach (var invalid in new[] { "", "20261021162600X500000+120", "20261021162600.******+120", "20261021162600.500000+120extra", "99991231235959.999999-840" })
        {
            Check.Null(WmiWorkstationProbe.ParseDmtf(invalid), "date illisible");
        }
    }

    [Test]
    public static void WMI_access_refusal_is_not_reported_as_an_unreachable_computer()
    {
        Check.Equal<MeasureState?>(MeasureState.Refused, WmiWorkstationProbe.Classify(new COMException("", unchecked((int)0x80070005))), "E_ACCESSDENIED");
        Check.Equal<MeasureState?>(MeasureState.NotRead, WmiWorkstationProbe.Classify(new COMException("", unchecked((int)0x800706BA))), "RPC indisponible");
        Check.Null(WmiWorkstationProbe.Classify(new OperationCanceledException()), "annulation non avalée");
        Check.Null(WmiWorkstationProbe.Classify(new InvalidOperationException()), "erreur de code non masquée");
    }

    private static AdEntry Ou(string name) => new("OU=" + name + "," + Fixtures.Postes, new Dictionary<string, IReadOnlyList<object>>
    {
        ["objectGUID"] = [Fixtures.IdOf(name).ToByteArray()],
        ["ou"] = [name],
    });

    internal sealed class RecordingAdConnection : IAdConnection, IAdBinarySchemaProvider
    {
        public string Server => "DC1.test.local";
        public List<AdSearchRequest> Searches { get; } = [];
        public IReadOnlyList<AdEntry> Ous { get; set; } = [];
        public string RootContext { get; set; } = Fixtures.Root;
        public string ConfigurationContext { get; set; } = "";
        public string SchemaContext { get; set; } = "CN=Schema,CN=Configuration," + Fixtures.Root;
        public Func<AdSearchRequest, IReadOnlyList<AdEntry>>? SearchAnswer { get; set; }
        public int Calls { get; private set; }
        internal IReadOnlySet<string> BinaryNames { get; set; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        public Task<IReadOnlySet<string>> ReadBinaryAttributesAsync(CancellationToken cancellationToken) => Task.FromResult(BinaryNames);

        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls++;
            return Task.FromResult(new AdRootDse(RootContext, ConfigurationContext, SchemaContext, Fixtures.Root, Server, null, null, [], null));
        }

        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls++;
            var sid = new SecurityIdentifier(Fixtures.Domain.DomainSid);
            var bytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(bytes, 0);
            return Task.FromResult<AdEntry?>(new AdEntry(distinguishedName, new Dictionary<string, IReadOnlyList<object>> { ["objectSid"] = [bytes] }));
        }

        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Calls++;
            Searches.Add(request);
            return Task.FromResult<IReadOnlyList<AdEntry>>(SearchAnswer?.Invoke(request) ?? (request.Filter == AdDirectoryMapper.OuFilter ? Ous : []));
        }

        public Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken) => throw UnexpectedWrite();
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken) => throw UnexpectedWrite();
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken) => throw UnexpectedWrite();
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => throw UnexpectedWrite();
        public void Dispose() { }
        private static InvalidOperationException UnexpectedWrite() => new("Une lecture a tenté une écriture LDAP.");
    }
}
