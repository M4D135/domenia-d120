using System.Collections.Immutable;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static partial class AdministrationIdentityTests
{
    private const string DelegatedLogin = @"TEST\technician";
    private static string DelegatedSid => Fixtures.Domain.DomainSid + "-1201";
    private static string SupportSid => Fixtures.Domain.DomainSid + "-2100";

    [Test]
    public static void Domain_local_admin_membership_uses_exact_transitive_SIDs_without_WMI_domain_enumeration()
    {
        var principal = new MachineAdministrationPrincipal(DelegatedLogin, DelegatedSid, [SupportSid]);
        var root = new WmiMachineAccessProbe.LocalAccount("S-1-5-32-544", "Administrateurs", "BUILTIN", true);
        var nested = new WmiMachineAccessProbe.LocalAccount("S-1-5-21-90-91-92-2001", "Support local", "PC1", true);
        var domainGroup = new WmiMachineAccessProbe.LocalAccount(SupportSid, "Support domaine", "TEST", true);
        var domainUser = new WmiMachineAccessProbe.LocalAccount(DelegatedSid, "technician", "TEST", false);
        var mode = 0; var queries = new List<string>();
        IReadOnlyList<WmiMachineAccessProbe.LocalAccount> Read(string query)
        {
            queries.Add(query);
            Check.False(query.Contains("Win32_UserAccount", StringComparison.Ordinal), "aucune énumération de comptes du domaine");
            Check.False(query.Contains("Domain=\"TEST\"", StringComparison.Ordinal), "aucun parcours WMI d’un groupe du domaine");
            if (query.StartsWith("SELECT", StringComparison.Ordinal)) return [root];
            if (mode == 1) return [domainUser];
            if (mode == 2) return [domainUser with { Sid = Fixtures.Domain.DomainSid + "-9999" }];
            return query.Contains("Support local", StringComparison.Ordinal) ? [domainGroup] : [nested];
        }
        Check.Equal(DelegatedSid, WmiMachineAccessProbe.ConfirmLocalAdministrator("PC1", DelegatedLogin, Read, CancellationToken.None, principal), "groupe AD transitif inclus dans un groupe local");
        Check.Equal(3, queries.Count, "racine + groupe local, jamais domaine");
        mode = 1;
        Check.Equal(DelegatedSid, WmiMachineAccessProbe.ConfirmLocalAdministrator("PC1", DelegatedLogin, Read, CancellationToken.None, principal), "membre domaine direct");
        mode = 2;
        Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC1", DelegatedLogin, Read, CancellationToken.None, principal), "homonyme sans SID exact refusé");
        Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC1", @"TEST\other", Read, CancellationToken.None, principal), "preuve d’un autre login refusée");
        Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC1", DelegatedLogin, Read, CancellationToken.None), "pas de groupes inventés depuis un succès WMI");
    }

    [Test]
    public static async Task Delegated_native_principal_roundtrips_within_existing_frame_and_cannot_enter_other_operations()
    {
        var groups = Enumerable.Range(1, 1024).Select(n => "S-1-5-21-4294967295-4294967295-4294967295-" + n).ToImmutableArray();
        var principal = new MachineAdministrationPrincipal(DelegatedLogin, DelegatedSid, groups);
        Check.True(principal.IsBounded, "principal proche du plafond de SID");
        var request = new NativeReadRequest(NativeReadKind.AccessTrial, 14_000)
        { ExpectedComputerName = "PC1", RequireLocalAdministrator = true, AdministrationPrincipal = principal };
        request.Check();
        using var stream = new MemoryStream();
        await NativeReadProtocol.WriteAsync(stream, request, NativeReadProtocol.RequestLimit, CancellationToken.None);
        Check.True(stream.Length <= NativeReadProtocol.RequestLimit + 8, "trame native existante 64 Kio");
        stream.Position = 0;
        var read = await NativeReadProtocol.ReadAsync<NativeReadRequest>(stream, NativeReadProtocol.RequestLimit, CancellationToken.None);
        read.Check(); Check.Equal(1024, read.AdministrationPrincipal!.GroupSids.Length, "aucun groupe tronqué");
        foreach (var refused in new[] { request with { Kind = NativeReadKind.Query }, request with { RequireLocalAdministrator = false },
            request with { AdministrationPrincipal = principal with { GroupSids = default } },
            request with { AdministrationPrincipal = principal with { GroupSids = ["not-a-SID"] } },
            request with { AdministrationPrincipal = principal with { GroupSids = groups.Add(SupportSid) } } })
            Check.Throws<InvalidDataException>(refused.Check, "provenance et bornes obligatoires");
    }

    [Test]
    public static async Task Explicit_delegated_trial_admits_only_the_same_target_secret_and_identity_until_monotonic_expiry()
    {
        using var fixture = await DelegatedFixture.CreateAsync();
        using var password = PasswordSecrets.FromText("delegated-proof-fixture");
        using var wrong = PasswordSecrets.FromText("another-fixture-secret");
        fixture.Source.RecordAdministration(fixture.Identity, fixture.Source.Epoch, password);
        var contacts = 0;
        var reader = new AdMachineAccountReader(fixture.Source) { ProbeOverride = (request, workstation, require, token) =>
        {
            contacts++; Check.True(require, "essai de preuve obligatoire");
            Check.Equal(DelegatedSid, request.AdministrationPrincipal?.AccountSid, "SID authentifié, pas nom supposé");
            return Task.FromResult(Confirmed(workstation));
        } };
        var epoch = fixture.Source.Epoch;
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "aucune admission avant essai");
        Check.Equal("Observed", (await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, DelegatedLogin, password), CancellationToken.None)).Outcome, "validation explicite");
        Check.True(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "pc1.test.local", password, false).AllowsRemote, "cible exacte autorisée");
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC2", password, false).AllowsRemote, "aucune globalisation");
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "pc1.foreign.local", password, false).AllowsRemote, "autre FQDN refusé");
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", wrong, false).AllowsRemote, "même login autre secret refusé");
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", password, true).AllowsRemote, "preuve alternative non héritée par session");
        await reader.ProbeAccessAsync(new("PC2", MachineAccountSource.Typed, DelegatedLogin, password), CancellationToken.None);
        Check.True(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "PC2 n’écrase pas PC1");
        fixture.Source.RecordAdministration(fixture.Identity, epoch, password);
        Check.True(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "revalidation identique conserve PC1");
        Check.True(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC2", password, false).AllowsRemote, "revalidation identique conserve PC2");
        Check.Equal(0, fixture.Ldap.Calls, "pas de LDAP par poste, groupes déjà qualifiés");
        fixture.Clock.Advance(TimeSpan.FromMinutes(10));
        Check.False(fixture.Source.AdministrationForCredential(epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "expiration monotone exacte");
        Check.Null(fixture.Source.AdministrationPrincipalFor(epoch, DelegatedLogin, password, false), "groupes périmés ne fabriquent pas nouvelle preuve");
        Check.Equal(2, contacts, "aucune tentative implicite à expiration");
    }

    [Test]
    public static async Task A_successful_WMI_read_or_replaced_target_cannot_create_delegated_administration()
    {
        foreach (var replaceTarget in new[] { false, true })
        {
            using var fixture = await DelegatedFixture.CreateAsync();
            using var password = PasswordSecrets.FromText("delegated-proof-fixture");
            fixture.Source.RecordAdministration(fixture.Identity, fixture.Source.Epoch, password);
            var reader = new AdMachineAccountReader(fixture.Source) { ProbeOverride = async (_, workstation, _, _) =>
            {
                if (!replaceTarget) return new("Observed", null, null, "Windows", workstation) { ConfirmedComputerName = workstation.Name };
                var replacement = fixture.Computers[0] with { Sid = Fixtures.Domain.DomainSid + "-9998" };
                await fixture.Source.RememberObjectsAsync(Fixtures.Snapshot(computers: [replacement, fixture.Computers[1]]), fixture.Source.Epoch, CancellationToken.None);
                return Confirmed(workstation);
            } };
            var result = await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, DelegatedLogin, password), CancellationToken.None);
            Check.Equal("Denied", result.Outcome, "succès WMI seul ou identité remplacée refusé");
            Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "aucune preuve conservée");
        }
    }

    [Test]
    public static async Task Domain_principal_replacement_and_session_reset_invalidate_existing_target_proofs()
    {
        using var fixture = await DelegatedFixture.CreateAsync();
        using var password = PasswordSecrets.FromText("delegated-proof-fixture");
        fixture.Source.RecordAdministration(fixture.Identity, fixture.Source.Epoch, password);
        var reader = new AdMachineAccountReader(fixture.Source) { ProbeOverride = (_, workstation, _, _) => Task.FromResult(Confirmed(workstation)) };
        await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, DelegatedLogin, password), CancellationToken.None);
        fixture.Source.RecordAdministration(fixture.Identity with { AdministrationPrincipal = fixture.Identity.AdministrationPrincipal! with { GroupSids = [] } },
            fixture.Source.Epoch, password);
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", password, false).AllowsRemote,
            "groupes retirés à la revalidation invalident la preuve même SID/secret");
        fixture.Source.RecordAdministration(fixture.Identity, fixture.Source.Epoch, password);
        await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, DelegatedLogin, password), CancellationToken.None);
        var newSid = Fixtures.Domain.DomainSid + "-9999";
        fixture.Source.RecordAdministration(fixture.Identity with { Sid = newSid,
            AdministrationPrincipal = fixture.Identity.AdministrationPrincipal! with { AccountSid = newSid } }, fixture.Source.Epoch, password);
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "même login/secret mais autre SID refusé");
        fixture.Source.Reset();
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "aucune preuve dans nouvelle session");
    }

    [Test]
    public static async Task Canonical_revalidation_revokes_old_UPN_aliases_even_when_the_alias_is_not_submitted_again()
    {
        foreach (var renamed in new[] { false, true })
        {
        using var fixture = await DelegatedFixture.CreateAsync();
        using var password = PasswordSecrets.FromText("delegated-alias-fixture");
        const string alias = "technician@alias.local";
        fixture.Source.RecordAdministration(fixture.Identity with { AuthenticatedLogin = alias }, fixture.Source.Epoch, password);
        var reader = new AdMachineAccountReader(fixture.Source) { ProbeOverride = (_, workstation, _, _) => Task.FromResult(Confirmed(workstation)) };
        await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, alias, password), CancellationToken.None);
        Check.True(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, alias, "PC1", password, false).AllowsRemote, "alias initial qualifié pour cible");
        await reader.ProbeAccessAsync(new("PC2", MachineAccountSource.Windows, DelegatedLogin, null), CancellationToken.None);
        fixture.Source.RecordAdministration(fixture.Identity with
            { Identity = renamed ? fixture.Identity.Identity with { Login = @"TEST\renamed" } : fixture.Identity.Identity,
                AdministrationPrincipal = fixture.Identity.AdministrationPrincipal! with { GroupSids = [] } },
            fixture.Source.Epoch, password);
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, alias, "PC1", password, false).AllowsRemote, "ancien alias ne garde pas le groupe retiré");
        Check.Null(fixture.Source.AdministrationPrincipalFor(fixture.Source.Epoch, alias, password, false), "preuve LDAP périmée par revalidation également retirée");
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC2", null, true).AllowsRemote,
            "groupes du même SID de connexion invalidés même après renommage du SAM");
        Check.Equal(0, fixture.Ldap.Calls, "révocation locale sans nouvelle authentification");
        }
    }

    [Test]
    public static async Task Null_group_evidence_does_not_zero_the_new_canonical_or_alias_secret_binding()
    {
        using var fixture = await DelegatedFixture.CreateAsync();
        using var password = PasswordSecrets.FromText("alias-null-principal-fixture");
        using var wrong = PasswordSecrets.FromText("wrong-alias-null-principal-fixture");
        const string alias = "technician@alias.local";
        fixture.Source.RecordAdministration(fixture.Identity with { AuthenticatedLogin = alias, AdministrationPrincipal = null,
            Administration = new(AdministrationIdentityState.Administrator, "Rôle AD confirmé ; groupes hors enveloppe native") }, fixture.Source.Epoch, password);
        foreach (var login in new[] { DelegatedLogin, alias })
        {
            Check.True(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, login, "PC1", password, false).AllowsRemote, "nouveau secret conservé pour canonique et alias");
            Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, login, "PC1", wrong, false).AllowsRemote, "secret différent toujours refusé");
        }
    }

    [Test]
    public static async Task Connected_delegated_trial_renews_expired_groups_only_on_explicit_request_and_exact_AD_identity()
    {
        foreach (var replaced in new[] { false, true })
        {
            using var fixture = await DelegatedFixture.CreateAsync();
            var contacts = 0;
            var reader = new AdMachineAccountReader(fixture.Source) { ProbeOverride = (_, workstation, _, _) =>
            { contacts++; return Task.FromResult(Confirmed(workstation)); } };
            await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Windows, DelegatedLogin, null), CancellationToken.None);
            Check.True(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", null, true).AllowsRemote, "session Windows liée au SID/epoch exact");
            Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC2", null, true).AllowsRemote, "aucune preuve session globale");
            fixture.Clock.Advance(TimeSpan.FromMinutes(10));
            Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", null, true).AllowsRemote, "expiration sans renouvellement implicite");
            Check.Equal(0, fixture.Ldap.Calls, "admission ne lit jamais LDAP");
            fixture.Ldap.SearchAnswer = _ => [replaced ? Subject(Guid.NewGuid()) : fixture.Subject];
            var trial = await reader.ProbeAccessAsync(new("PC1", MachineAccountSource.Windows, DelegatedLogin, null), CancellationToken.None);
            Check.Equal(replaced ? "Denied" : "Observed", trial.Outcome, "renouvellement même GUID/SID seulement");
            Check.Equal(replaced ? 1 : 2, contacts, "pas de WMI si sujet LDAP remplacé");
            Check.Equal(1, fixture.Ldap.Calls, "une lecture BASE existante sans nouveau bind");
            Check.Equal(AdSearchScope.Base, fixture.Ldap.Searches.Single().Scope, "tokenGroups BASE exact");
        }
    }

    [Test]
    public static async Task Accounts_validation_proves_delegated_target_and_keeps_authentication_separate_from_authorization()
    {
        using var fixture = await DelegatedFixture.CreateAsync();
        using var password = PasswordSecrets.FromText("delegated-proof-fixture");
        var groupReads = 0; var trials = 0;
        using var reader = new AdAccountsAccessReader(fixture.Source)
        {
            ConnectionFactory = _ => new AdBoundaryTests.RecordingAdConnection { SearchAnswer = request =>
            {
                if (request.Filter == "(objectClass=domainDNS)") return [new AdEntry(Fixtures.Root,
                    new Dictionary<string, IReadOnlyList<object>> { ["objectSid"] = [Sid(Fixtures.Domain.DomainSid)] })];
                if (request.Attributes.Contains("tokenGroups")) groupReads++;
                return [fixture.Subject];
            } },
            ProbeOverride = (request, workstation, require, _) =>
            { trials++; Check.True(require, "validation explicite par cible"); return Task.FromResult(Confirmed(workstation)); },
        };
        var answer = await reader.ValidateAsync(new(DelegatedLogin, CredentialRules.Remote, "PC1"), password, CancellationToken.None);
        Check.True(answer.Success, "compte domaine délégué accepté après preuve locale");
        Check.Equal(1, groupReads, "groupes lus une seule fois lors de validation LDAP");
        Check.Equal(1, trials, "un seul essai local explicite");
        Check.True(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC1", password, false).AllowsRemote, "secret validé et cible confirmée");
        Check.False(fixture.Source.AdministrationForCredential(fixture.Source.Epoch, DelegatedLogin, "PC2", password, false).AllowsRemote, "autres postes restent refusés");
    }

    private static MachineTrialObservation Confirmed(MachineWorkstation workstation) => new("Observed", null, null, null, workstation)
    { ConfirmedComputerName = workstation.Name, AdministratorSid = DelegatedSid };

    private static AdEntry Subject(Guid id) => new("CN=technician," + Fixtures.People, new Dictionary<string, IReadOnlyList<object>>
    {
        ["objectGUID"] = [id.ToByteArray()], ["objectSid"] = [Sid(DelegatedSid)], ["objectClass"] = ["person", "user"],
        ["sAMAccountName"] = ["technician"], ["userPrincipalName"] = ["technician@test.local"],
        ["tokenGroups"] = [Sid(SupportSid)], ["primaryGroupID"] = [513],
    });

    private sealed class AdministrationClock : TimeProvider
    {
        private long timestamp;
        public override long TimestampFrequency => TimeSpan.TicksPerSecond;
        public override long GetTimestamp() => timestamp;
        public override DateTimeOffset GetUtcNow() => Fixtures.Now; // UTC does not advance: expiry must be monotone.
        internal void Advance(TimeSpan value) => timestamp += value.Ticks;
    }

    private sealed class DelegatedFixture : IDisposable
    {
        internal AdministrationClock Clock { get; } = new();
        internal AdBoundaryTests.RecordingAdConnection Ldap { get; } = new();
        internal AdDirectorySource Source { get; private set; } = null!;
        internal DirectoryComputer[] Computers { get; } = [Fixtures.Computer("PC1"), Fixtures.Computer("PC2")];
        internal AdEntry Subject { get; } = AdministrationIdentityTests.Subject(Guid.NewGuid());
        internal AdSessionIdentity Identity { get; private set; } = null!;
        internal static async Task<DelegatedFixture> CreateAsync()
        {
            var fixture = new DelegatedFixture();
            fixture.Identity = new(new(DelegatedLogin, null, null, fixture.Subject.DistinguishedName), DelegatedSid,
                new(RightsLevel.Unknown, "Non évalués", true, "Droits AD distincts"))
            { Administration = new(AdministrationIdentityState.Standard, "Lecture AD seule sans preuve cible"),
                AdministrationPrincipal = new(DelegatedLogin, DelegatedSid, [SupportSid]), AdministrationSubject = fixture.Subject };
            fixture.Source = new("test.local", () => DelegatedLogin, fixture.Clock, connection: new AdBoundaryTests.RecordingAdConnection());
            fixture.Source.AdoptConnection(fixture.Ldap, Fixtures.Domain, fixture.Identity, fixture.Source.Epoch, false);
            await fixture.Source.RememberObjectsAsync(Fixtures.Snapshot(computers: fixture.Computers), fixture.Source.Epoch, CancellationToken.None);
            return fixture;
        }
        public void Dispose() => Source.Dispose();
    }
}
