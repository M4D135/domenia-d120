using System.Text.Json;
using Domenia.Ad;
using Domenia.Bridge;
using Domenia.Core;

namespace Domenia.Tests;

internal static class OperationAccessBoundaryTests
{
    [Test]
    public static async Task Actual_bridge_scope_selects_operation_then_directory_without_leaking_into_another_operation()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(owner);
        await access.OverviewAsync(CancellationToken.None);
        using var password = PasswordSecrets.FromText("scope-fixture-only");
        async Task Recover(string scope, string login)
        {
            access.RegisterRefusal(scope, "Lecture", null, "accessDenied", null, true);
            var request = (await access.OverviewAsync(CancellationToken.None)).Pending.First(p => p.Scope == scope);
            Check.True((await access.RecoverAsync(request.Id, login, password, LeaseMode.Inactivity, 30, null, CancellationToken.None)).Result.Success, "identité validée");
        }
        await Recover(CredentialRules.Directory, @"EXAMPLE\adm-j.martin");
        await Recover("AD:search.run", @"EXAMPLE\adm-s.leroy");
        async Task<object?> Read(JsonElement _, BridgeContext __, CancellationToken token)
        { using var selected = await access.AcquireDirectoryReadAsync(CredentialRules.Directory, null, token); return selected.Account; }
        var registry = OperationModules.CreateRegistryFromDefinitions(owner,
            [new("search.run", OperationClass.Local, Read, "Recherche"), new("fiche.attributes", OperationClass.Local, Read, "Attributs")], null);
        var answers = new List<BridgeResponse>(); using var dispatcher = new BridgeDispatcher(registry, answers.Add);
        await dispatcher.HandleAsync("""{"id":"r1","op":"search.run","args":{}}""", CancellationToken.None);
        await dispatcher.HandleAsync("""{"id":"r2","op":"fiche.attributes","args":{}}""", CancellationToken.None);
        Check.Equal(@"EXAMPLE\adm-s.leroy", (string?)answers.Single(r => r.Id == "r1" && r.Kind == "result").Data, "rang opération");
        Check.Equal(@"EXAMPLE\adm-j.martin", (string?)answers.Single(r => r.Id == "r2" && r.Kind == "result").Data, "rang annuaire général, jamais l’autre opération");
        using var outside = await access.AcquireDirectoryReadAsync(CredentialRules.Directory, null, CancellationToken.None);
        Check.Equal(@"EXAMPLE\adm-j.martin", outside.Account, "portée asynchrone rendue après le handler");
        using var secret = await access.AcquireDirectoryReadAsync(CredentialRules.Laps, null, CancellationToken.None);
        Check.Null(secret.Credential, "LAPS utilise la session Windows sans copie du temporaire annuaire");
        Check.Equal((await owner.Directory.GetSessionAsync(default)).Account.Login, secret.Account, "identité Windows réelle, même si son nom est aussi celui du temporaire");
    }

    [Test]
    public static async Task Real_LDAP_refusal_uses_the_actual_operation_scope_and_structured_error_needs()
    {
        var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap);
        source.AdoptConnection(ldap, Fixtures.Domain, new(new(@"TEST\operator", "operator", "Opérateur", "CN=operator," + Fixtures.People),
            Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Inconnus", true, "Non mesurés")), source.Epoch, false);
        using var context = new EngineContext(ModeResolver.Resolve([], "0", () => new(DomainJoinState.Unknown, null)), source, new MemoryPreferenceStore(), TestClock.Fixed(), new RecordingJournal());
        ldap.SearchAnswer = _ => throw new DomeniaOperationException(AdErrors.AccessDenied, "Droit refusé");
        async Task<object?> Read(JsonElement _, BridgeContext __, CancellationToken token)
        {
            using var read = await AdReadAccess.AcquireAsync(source, CredentialRules.Directory, Fixtures.Postes, token);
            return await read.SearchAsync(new(Fixtures.Postes, "(objectClass=computer)", AdSearchScope.OneLevel, ["objectGUID"]) { SizeLimit = 1 }, token);
        }
        var registry = OperationModules.CreateRegistryFromDefinitions(context, [new("search.run", OperationClass.Local, Read, "Recherche")], null);
        var answers = new List<BridgeResponse>(); using var dispatcher = new BridgeDispatcher(registry, answers.Add);
        await dispatcher.HandleAsync("""{"id":"r1","op":"search.run","args":{}}""", CancellationToken.None);
        var error = answers.Single(r => r.Kind == "error").Error!;
        Check.Equal(OperationFailureKind.AccessDenied, error.Decision!.Kind, "refus LDAP typé");
        Check.Equal("search.run", error.Requirement!.Id, "opération admise exacte");
        Check.True(error.Requirement.Known && error.Requirement.Access.Contains("LDAP", StringComparison.Ordinal), "besoin fermé fourni avec l’échec réel");
        Check.True((await AccountAccess.From(context).OverviewAsync(CancellationToken.None)).Pending.Any(p => p.Scope == "AD:search.run"), "récupération limitée à la recherche");
        Check.False(OperationRequirements.ForBridge("future.unknown").Known, "aucun droit deviné");
    }

    [Test]
    public static void Result_inspection_reads_at_most_64_typed_statuses_and_has_no_payload_or_secret_path()
    {
        var advanced = 0;
        IEnumerable<AccessResultStatus> Rows()
        {
            for (var i = 0; i < 64; i++) { advanced++; yield return new(i == 4, i == 63); }
            throw new TestFailureException("Le 65e élément ne doit pas être demandé.");
        }
        var result = AccessResultInspection.Inspect(Rows());
        Check.Equal(64, advanced, "borne avant MoveNext"); Check.Equal(64, result.Examined, "mesure exacte");
        Check.True(result.Refused && result.AuthenticationRejected, "rejet d’identité distinct du droit et conservé");
        Check.False(AccessResultInspection.Inspect([new(false, false)]).Refused, "vide/indisponible ne sont pas des mauvais identifiants");
    }
}
