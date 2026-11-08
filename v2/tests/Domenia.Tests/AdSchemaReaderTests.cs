using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class AdSchemaReaderTests
{
    [Test]
    public static async Task Explicit_connection_populates_the_session_without_a_domain_object_scan()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        var session = await source.ConnectAsync(CancellationToken.None);
        Check.Equal(ConnectionState.Connected, session.Connection, "connexion après geste");
        Check.Equal(Fixtures.Root, session.Domain?.RootDn, "domaine confirmé");
        Check.False(connection.Searches.Any(s => s.Filter is AdDirectoryMapper.UserFilter or AdDirectoryMapper.ComputerFilter or AdDirectoryMapper.GroupFilter), "aucun scan des objets");
        var calls = connection.Calls;
        await source.GetSessionAsync(CancellationToken.None);
        await source.ConnectAsync(CancellationToken.None);
        Check.Equal(calls, connection.Calls, "connexion existante conservée");
    }

    [Test]
    public static async Task Schema_reads_use_only_the_schema_partition_and_definition_fields()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = request => request.Filter == "(objectClass=attributeSchema)"
                ? [Entry("nom", ("attributeSyntax", ["2.5.5.12"]), ("isSingleValued", ["TRUE"]), ("searchFlags", ["129"]), ("adminDescription", ["Une\r\n description"]))]
                : [Entry("personne", ("mustContain", ["cn"]), ("systemMustContain", ["CN", "name"]), ("auxiliaryClass", ["top"]), ("systemAuxiliaryClass", ["top", "aux"]), ("isDefunct", ["TRUE"]))],
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        var reader = new AdSchemaReader(source);
        Check.Equal(0, connection.Calls, "construction sans réseau");
        var result = await reader.ReadDefinitionsAsync(SchemaReadLimits.Default, null, CancellationToken.None);
        Check.False(result.Truncated, "définitions complètes");
        Check.Equal("Une description", result.Attributes.Single().Description, "description aplatie");
        Check.True(result.Attributes.Single().SingleValued, "booléen LDAP");
        Check.Equal<long?>(129, result.Attributes.Single().SearchFlags, "drapeaux bruts");
        Check.Equal(2, result.Classes.Single().Must.Length, "attributs système fusionnés");
        Check.Equal(2, result.Classes.Single().Auxiliary.Length, "classes auxiliaires fusionnées");
        Check.True(result.Classes.Single().Defunct, "classe désactivée conservée");
        Check.Equal(Fixtures.Root, result.DomainDn, "provenance du domaine");
        Check.Equal(connection.Server, result.Server, "contrôleur ayant répondu");
        Check.Equal(2, connection.Searches.Count, "deux recherches");
        foreach (var request in connection.Searches)
        {
            Check.Equal(connection.SchemaContext, request.BaseDn, "partition de schéma uniquement");
            Check.Equal(AdSearchScope.OneLevel, request.Scope, "une profondeur");
            Check.Equal(500, request.PageSize, "pagination");
            Check.False(request.Attributes.Contains("*"), "projection explicite");
            Check.False(request.Attributes.Any(a => a.Equals("unicodePwd", StringComparison.OrdinalIgnoreCase)), "aucune valeur secrète");
        }
    }

    [Test]
    public static async Task Schema_limits_and_invalid_names_are_reported_as_incomplete()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = request => request.Filter == "(objectClass=attributeSchema)" ? [Entry("a"), Entry("b")] : [Entry("bad_name")],
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        var result = await new AdSchemaReader(source).ReadDefinitionsAsync(new SchemaReadLimits(1, 1, TimeSpan.FromSeconds(5)), null, CancellationToken.None);
        Check.True(result.Truncated, "plafond ou définition illisible");
        Check.Equal(1, result.Attributes.Length, "plafond respecté");
        Check.Equal(0, result.Classes.Length, "nom invalide écarté");
        Check.True(connection.Searches.All(s => s.SizeLimit == 2), "limite plus sentinelle");
    }

    [Test]
    public static async Task Unexpected_schema_context_is_rejected_before_any_search()
    {
        foreach (var context in new[] { Fixtures.Root, "CN=Schema,CN=Configuration,DC=", "CN=Schema,CN=Configuration,CN=Other," + Fixtures.Root })
        {
            using var connection = new AdBoundaryTests.RecordingAdConnection { SchemaContext = context };
            using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
            var refused = await Check.ThrowsAsync<DomeniaOperationException>(
                () => new AdSchemaReader(source).ReadDefinitionsAsync(SchemaReadLimits.Default, null, CancellationToken.None), "contexte interdit");
            Check.Equal(SchemaErrors.ReadFailed, refused.Code, "refus du contexte");
            Check.Equal(0, connection.Searches.Count, "aucune recherche hors schéma");
        }
    }

    [Test]
    public static async Task A_refused_schema_read_is_not_an_empty_success()
    {
        using var connection = new AdBoundaryTests.RecordingAdConnection
        {
            SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.AccessDenied, AdErrors.AccessDeniedMessage),
        };
        using var source = new AdDirectorySource("test.local", () => @"TEST\adm", TestClock.Fixed(), connection: connection);
        var reader = new AdSchemaReader(source);
        var refused = await Check.ThrowsAsync<DomeniaOperationException>(() => reader.ReadDefinitionsAsync(SchemaReadLimits.Default, null, CancellationToken.None), "accès refusé");
        Check.Equal(AdErrors.AccessDenied, refused.Code, "refus conservé");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        var calls = connection.Calls;
        await Check.ThrowsAsync<OperationCanceledException>(() => reader.ReadDefinitionsAsync(SchemaReadLimits.Default, null, cancelled.Token), "annulation propagée");
        Check.Equal(calls, connection.Calls, "aucun appel après annulation");
    }

    private static AdEntry Entry(string name, params (string Name, IReadOnlyList<object> Values)[] fields)
    {
        var values = fields.ToDictionary(f => f.Name, f => f.Values, StringComparer.OrdinalIgnoreCase);
        values["lDAPDisplayName"] = [name];
        return new AdEntry("CN=" + name + ",CN=Schema,CN=Configuration," + Fixtures.Root, values);
    }
}
