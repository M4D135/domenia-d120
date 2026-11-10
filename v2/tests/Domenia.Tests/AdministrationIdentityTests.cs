using System.Security.Principal;
using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static partial class AdministrationIdentityTests
{
    [Test]
    public static void Token_membership_is_exact_and_separate_from_AD_mutation_rights()
    {
        var domain = Fixtures.Domain.DomainSid;
        Check.True(AdAdministrationIdentity.Classify(domain, Entry([domain + "-512"])).AllowsRemote, "Domain Admins exact");
        Check.True(AdAdministrationIdentity.Classify(domain, Entry(["S-1-5-32-544"])).AllowsRemote, "Administrateurs effectifs");
        Check.True(AdAdministrationIdentity.Classify(domain, Entry([], 512)).AllowsRemote, "groupe primaire exact");
        foreach (var groups in new[] { Array.Empty<string>(), new[] { "S-1-5-21-90-91-92-512" }, new[] { domain + "-519" }, new[] { domain + "-513" } })
        { Check.Equal(AdministrationIdentityState.Standard, AdAdministrationIdentity.Classify(domain, Entry(groups)).State, "pas de suffixe supposé, ni de forêt supposée"); }
        Check.Equal(AdministrationIdentityState.Unknown, AdAdministrationIdentity.Classify(domain, new("CN=Alice," + Fixtures.Root, new Dictionary<string, IReadOnlyList<object>>())).State, "absence différente d’un résultat vide");
        var malformed = new AdEntry("CN=Alice," + Fixtures.Root, new Dictionary<string, IReadOnlyList<object>> { ["tokenGroups"] = [new byte[] { 1 }] });
        Check.False(AdAdministrationIdentity.Classify(domain, malformed).AllowsRemote, "SID illisible refusé");
    }

    [Test]
    public static async Task Administration_is_read_once_in_BASE_on_the_same_GUID_and_SID()
    {
        var item = Entry([Fixtures.Domain.DomainSid + "-512"]);
        using var ldap = new AdBoundaryTests.RecordingAdConnection { SearchAnswer = _ => [item] };
        var proof = await AdAdministrationIdentity.ReadAsync(ldap, Fixtures.Domain, item, CancellationToken.None);
        Check.True(proof.AllowsRemote, "preuve liée à l’objet");
        var query = ldap.Searches.Single();
        Check.Equal(AdSearchScope.Base, query.Scope, "tokenGroups exige BASE");
        Check.Equal(item.DistinguishedName, query.BaseDn, "objet exact");
        Check.True(query.Attributes.Contains("tokenGroups"), "groupes transitifs calculés");
        ldap.SearchAnswer = _ => [Entry([Fixtures.Domain.DomainSid + "-512"])];
        Check.False((await AdAdministrationIdentity.ReadAsync(ldap, Fixtures.Domain, item, CancellationToken.None)).AllowsRemote, "GUID remplacé refusé");
    }

    [Test]
    public static async Task Unknown_and_standard_accounts_stop_before_native_identity_copy_or_machine_contact()
    {
        foreach (var state in new[] { AdministrationIdentityState.Unknown, AdministrationIdentityState.Standard })
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection(); var copies = 0;
            using var source = new AdDirectorySource("test.local", () => "TEST\\reader", TestClock.Fixed(), connection: ldap)
            { SessionCredentialCopy = () => { copies++; return AdBoundaryTests.NativeSessionCredential(); },
              AdministrationOverride = new(state, "Lecture AD seule.") };
            var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.AcquireAsync(source, "PC-01.test.local", CancellationToken.None), "lecture distante refusée");
            Check.Equal(AdministrationIdentity.Required, refusal.Code, "action autre compte possible");
            Check.Equal(0, copies, "refus avant copie native"); Check.Equal(0, ldap.Calls, "aucun contact LDAP ou machine implicite");
        }
    }

    [Test]
    public static void Local_administrator_requires_same_SID_and_bounded_membership_not_a_successful_trial()
    {
        var user = new WmiMachineAccessProbe.LocalAccount("S-1-5-21-90-91-92-1001", "LapsAdmin", "PC-01", false);
        var root = new WmiMachineAccessProbe.LocalAccount("S-1-5-32-544", "Administrateurs", "BUILTIN", true);
        var nested = new WmiMachineAccessProbe.LocalAccount("S-1-5-21-90-91-92-2001", "Support", "PC-01", true);
        var mode = 0; var calls = 0;
        IReadOnlyList<WmiMachineAccessProbe.LocalAccount> Read(string query)
        {
            calls++;
            if (query.StartsWith("SELECT SID,Name,Domain FROM Win32_UserAccount", StringComparison.Ordinal)) { return [user]; }
            if (query.StartsWith("SELECT SID,Name,Domain FROM Win32_Group", StringComparison.Ordinal)) { return [root]; }
            if (mode == 1) { return [user with { Sid = "S-1-5-21-90-91-92-1002" }]; }
            if (mode == 2) { return [nested]; } // cycle is bounded, never accepted
            return query.Contains("Support", StringComparison.Ordinal) ? [user] : [nested];
        }
        Check.Equal(user.Sid, WmiMachineAccessProbe.ConfirmLocalAdministrator("PC-01", "PC-01\\LapsAdmin", Read, CancellationToken.None), "groupe imbriqué et SID exact");
        mode = 1; Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC-01", "PC-01\\LapsAdmin", Read, CancellationToken.None), "homonyme SID différent refusé");
        mode = 2; calls = 0; Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC-01", "PC-01\\LapsAdmin", Read, CancellationToken.None), "cycle sans compte refusé");
        Check.True(calls <= 4, "cycle borné");
        Check.Null(WmiMachineAccessProbe.ConfirmLocalAdministrator("PC-OTHER", "PC-OTHER\\LapsAdmin", Read, CancellationToken.None), "identité d’une autre cible refusée");
    }

    [Test]
    public static async Task A_standard_explicit_account_runs_presence_and_inventory_campaigns()
    {
        // ICMP and DNS carry no credential: measuring online workstations needs no administration (David, 09/11/2026).
        // David, 10/11/2026: a typed connection account is also tried for reads; the workstation decides.
        foreach (var family in new[] { MeasureFamily.Presence, MeasureFamily.Inventory })
        {
            var pc = Fixtures.Computer("PC1"); var probe = new CountingProbe(); var copies = 0;
            var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
            using var source = new AdDirectorySource("test.local", () => "TEST\\reader", TestClock.Fixed(), probe,
                new AdBoundaryTests.RecordingAdConnection(), cache)
            { SessionCredentialCopy = () => { copies++; return AdBoundaryTests.NativeSessionCredential(); } };
            source.AdoptConnection(new AdBoundaryTests.RecordingAdConnection(), Fixtures.Domain,
                new(new("TEST\\reader", null, null, "CN=reader," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001",
                    new(RightsLevel.Unknown, "Non évalués", true, "Droits AD distincts."))
                { Administration = new(AdministrationIdentityState.Standard, "Lecture AD seule.") }, source.Epoch, false);
            Check.Equal(1, (await source.ReadLocalAsync(CancellationToken.None)).Directory.Computers.Length, "cache AD accessible");
            if (family == MeasureFamily.Presence)
            {
                await source.RefreshAsync(family, new(Fixtures.Postes, "Postes", true), CancellationToken.None);
                Check.Equal(1, probe.Calls, "un ping par poste, sans compte d’administration");
                Check.True(source.CurrentObservations.Workstations.Single().Presence.Answered == true, "présence enregistrée");
            }
            else
            {
                await source.RefreshAsync(family, new(Fixtures.Postes, "Postes", true), CancellationToken.None);
                Check.Equal(2, probe.Calls, "ping puis inventaire via le fournisseur de test");
            }
            Check.Equal(0, copies, "aucune identité native copiée");
        }
    }

    [Test]
    public static async Task A_Windows_session_read_is_left_to_the_workstation_but_writes_keep_the_check()
    {
        // David, 09/11/2026: with the Windows session identity, a remote read is tried and the workstation grants or refuses it.
        foreach (var state in new[] { AdministrationIdentityState.Unknown, AdministrationIdentityState.Standard })
        {
            using var ldap = new AdBoundaryTests.RecordingAdConnection(); var copies = 0;
            using var source = new AdDirectorySource("test.local", () => "TEST\\reader", TestClock.Fixed(), connection: ldap)
            { SessionCredentialCopy = () => { copies++; return AdBoundaryTests.NativeSessionCredential(); },
              AdministrationOverride = new(state, "Lecture AD seule.") };
            using (var read = await AdWorkstationAccess.AcquireAsync(source, "PC-01.test.local", CancellationToken.None, readOnly: true))
            {
                await read.BeforeContactAsync(source, "PC-01.test.local", CancellationToken.None);
                Check.True(read.Credential.Session, "identité de la session Windows");
                Check.Null(read.Credential.Password, "aucun mot de passe manipulé");
            }
            Check.Equal(1, copies, "une copie de l’identité native, sans secret");
            var write = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.AcquireAsync(source, "PC-01.test.local", CancellationToken.None), "écriture distante contrôlée");
            Check.Equal(AdministrationIdentity.Required, write.Code, "voie autre compte explicite");
            Check.Equal(1, copies, "refus avant copie native");
        }
    }

    [Test]
    public static async Task Selected_connection_typed_and_temporary_accounts_reach_read_contact_without_an_administration_proof()
    {
        foreach (var selection in new[] { "connection", "typed-domain", "typed-local", "temporary-local" })
        {
            var pc = Fixtures.Computer("PC1"); var copies = 0;
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(), connection: ldap,
                localStore: new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc])))
            { SessionCredentialCopy = () => { copies++; return new("reader", "TEST", PasswordSecrets.FromText("connection-read-fixture"), false); } };
            source.AdoptConnection(ldap, Fixtures.Domain,
                new(new(@"TEST\reader", null, null, "CN=reader," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001",
                    new(RightsLevel.Unknown, "Inconnus", true, "Droits AD distincts."))
                { Administration = new(AdministrationIdentityState.Standard, "Aucune preuve d’administration.") }, source.Epoch, false);
            using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []), source,
                new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
            var session = await source.GetSessionAsync(CancellationToken.None);
            var machine = MachineAccountService.From(context);
            _ = machine.Build(session, pc.DnsHostName!, null);
            var login = selection.EndsWith("local", StringComparison.Ordinal) ? @"PC1\Admin" : @"TEST\reader";
            using var secret = PasswordSecrets.FromText("selected-read-fixture");
            if (selection.StartsWith("typed", StringComparison.Ordinal)) { machine.UseTyped(login, secret.Copy()); }
            else if (selection == "temporary-local")
            { machine.AcceptTemporary(session, pc.Name, login, secret.Copy(), MachineLeaseMode.OneShot); }

            var write = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.RequireNetworkIdentityAsync(
                source, pc.DnsHostName!, CancellationToken.None), "les écritures conservent la validation d’administration");
            Check.Equal(AdministrationIdentity.Required, write.Code, "garde d’écriture conservée");
            await AdWorkstationAccess.RequireNetworkIdentityAsync(source, pc.DnsHostName!, CancellationToken.None, readOnly: true);
            using var read = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, CancellationToken.None, readOnly: true);
            await read.BeforeContactAsync(source, pc.DnsHostName!, CancellationToken.None);
            Check.Equal(login, read.Credential.Account, "seul le compte choisi est transmis au lecteur");
            Check.False(read.Credential.Session, "aucun repli vers la session Windows");
            Check.NotNull(read.Credential.Password, "secret du compte choisi disponible");
            Check.Equal(selection == "connection" ? 1 : 0, copies, "aucune copie d’un autre compte");
            Check.Equal(0, ldap.Calls, "admission locale, sans validation réseau implicite");
            source.Reset();
            var stale = await Check.ThrowsAsync<DomeniaOperationException>(() => read.BeforeContactAsync(source, pc.DnsHostName!, CancellationToken.None), "ancien accès invalidé");
            Check.Equal(AccountAccess.EpochChanged, stale.Code, "garde de session conservée");
        }
    }

    [Test]
    public static async Task A_read_with_an_explicit_connection_still_refuses_a_missing_secret_without_Windows_fallback()
    {
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(), connection: ldap)
        { SessionCredentialCopy = AdBoundaryTests.NativeSessionCredential };
        source.AdoptConnection(ldap, Fixtures.Domain,
            new(new(@"TEST\reader", null, null, "CN=reader," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001",
                new(RightsLevel.Unknown, "Inconnus", true, "Droits AD distincts.")), source.Epoch, false);
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.AcquireAsync(
            source, "PC1.test.local", CancellationToken.None, readOnly: true), "secret explicite absent");
        Check.Equal(MachineErrors.PasswordMissing, error.Code, "aucun repli Windows après admission d’une lecture");
        Check.Equal(0, ldap.Calls, "aucun envoi");
    }

    [Test]
    public static async Task A_standard_Windows_session_runs_presence_and_inventory_campaigns()
    {
        foreach (var family in new[] { MeasureFamily.Presence, MeasureFamily.Inventory })
        {
            var pc = Fixtures.Computer("PC1"); var probe = new CountingProbe();
            var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
            using var source = new AdDirectorySource("test.local", () => "TEST\\reader", TestClock.Fixed(), probe,
                new AdBoundaryTests.RecordingAdConnection(), cache)
            { AdministrationOverride = new(AdministrationIdentityState.Standard, "Lecture AD seule.") };
            await source.ReadLocalAsync(CancellationToken.None);
            await source.RefreshAsync(family, new(Fixtures.Postes, "Postes", true), CancellationToken.None);
            Check.Equal(family == MeasureFamily.Presence ? 1 : 2, probe.Calls, "le poste décide : ping, puis WMI pour l’inventaire");
        }
    }

    [Test]
    public static async Task Alternate_administration_is_bound_to_the_validated_secret_even_with_the_connection_login()
    {
        foreach (var local in new[] { false, true })
        {
            var pc = Fixtures.Computer("PC1"); var copies = 0;
            using var ldap = new AdBoundaryTests.RecordingAdConnection();
            using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(), connection: ldap)
            { SessionCredentialCopy = () => { copies++; return new("operator", "TEST", PasswordSecrets.FromText("connection-fixture"), false); } };
            var identity = new AdSessionIdentity(new(@"TEST\operator", null, null, "CN=operator," + Fixtures.People),
                Fixtures.Domain.DomainSid + "-1001", new(RightsLevel.Unknown, "Non évalués", true, "Droits AD distincts."))
                { Administration = new(AdministrationIdentityState.Administrator, "Identité de connexion confirmée.") };
            source.AdoptConnection(new AdBoundaryTests.RecordingAdConnection(), Fixtures.Domain, identity, source.Epoch, false);
            await source.RememberObjectsAsync(Fixtures.Snapshot(computers: [pc]), source.Epoch, CancellationToken.None);
            using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []), source,
                new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
            var session = await source.GetSessionAsync(CancellationToken.None);
            using (var connected = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, CancellationToken.None))
            { await connected.BeforeContactAsync(source, pc.DnsHostName!, CancellationToken.None); }
            Check.Equal(1, copies, "le compte de connexion conserve sa preuve SID/session sans secret supplémentaire");
            copies = 0;
            using var valid = PasswordSecrets.FromText("administration-proof-fixture-one");
            using var changed = PasswordSecrets.FromText("administration-proof-fixture-two");
            var login = local ? @"PC1\Admin" : identity.Identity.Login;
            if (local)
            {
                var workstation = (await new AdMachineAccountReader(source).FindWorkstationAsync(pc.Name, CancellationToken.None))!;
                source.RecordLocalAdministration(workstation, login, "S-1-5-21-90-91-92-500", source.Epoch, valid,
                    expectedComputer: source.CaptureAdministrationTarget(workstation, source.Epoch));
            }
            else { source.RecordAdministration(identity, source.Epoch, valid); }
            var machine = MachineAccountService.From(context);
            _ = machine.Build(session, pc.DnsHostName!, null);
            machine.UseTyped(login, valid);
            using (var accepted = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, CancellationToken.None))
            { await accepted.BeforeContactAsync(source, pc.DnsHostName!, CancellationToken.None); }
            machine.UseTyped(login, changed);
            var rejected = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.AcquireAsync(source,
                pc.DnsHostName!, CancellationToken.None), "le même login avec un autre secret doit être validé explicitement");
            Check.Equal(AdministrationIdentity.Required, rejected.Code, "preuve liée au secret exact");
            Check.Equal(0, copies, "aucun repli vers la connexion ni nouvelle identité native après refus");
            Check.Equal(0, ldap.Calls, "aucun contact implicite de validation");
            source.Reset();
            Check.False(source.AdministrationForCredential(source.Epoch, login, pc.Name, valid, false).AllowsRemote,
                "la réinitialisation invalide même le secret précédemment validé");
        }
    }

    [Test]
    public static async Task WinRM_exclusive_configuration_refuses_DCOM_account_trials_before_the_native_probe()
    {
        using var source = new AdDirectorySource("test.local", () => @"TEST\operator", TestClock.Fixed(),
            connection: new AdBoundaryTests.RecordingAdConnection());
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
        await context.Preferences.SetAsync(RemoteCollectionSettings.PreferenceKey,
            RemoteCollectionSettings.From(PosteConfiguration.Defaults with { DirectMode = "winrm" }).ToJson(), CancellationToken.None);
        var calls = 0;
        using var reader = new AdAccountsAccessReader(source)
        { ProbeOverride = (_, _, _, _) => { calls++; throw new InvalidOperationException("Aucun DCOM caché."); } };
        using var secret = PasswordSecrets.FromText("explicit-local-trial-fixture");
        var answer = await reader.ValidateAsync(new(@"PC1\Admin", CredentialRules.Remote, "PC1"), secret, CancellationToken.None);
        Check.False(answer.Success, "la validation locale ne contourne pas le choix de transport");
        Check.Equal("transportDisabled", answer.Kind, "limite explicite avant tout envoi");
        Check.Contains("DCOM", answer.Detail, "méthode de validation annoncée");
        var error = await Check.ThrowsAsync<DomeniaOperationException>(() => new AdMachineAccountReader(source)
            .ProbeAccessAsync(new("PC1", MachineAccountSource.Typed, @"PC1\Admin", secret), CancellationToken.None), "autre point d’entrée également bloqué");
        Check.Equal("machine.trialTransport", error.Code, "pas de repli implicite");
        Check.Equal(0, calls, "aucun essai natif");
    }

    private sealed class CountingProbe : IWorkstationProbe
    {
        internal int Calls;
        public Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken token) { Calls++; return Task.FromResult(true); }
        public Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken token)
        { Calls++; return Task.FromResult(InventoryMeasure.Unread); }
    }

    private static AdEntry Entry(string[] groups, int primary = 513) => new("CN=Alice," + Fixtures.People,
        new Dictionary<string, IReadOnlyList<object>>
        {
            ["objectGUID"] = [Guid.NewGuid().ToByteArray()], ["objectSid"] = [Sid(Fixtures.Domain.DomainSid + "-1001")],
            ["tokenGroups"] = groups.Select(g => (object)Sid(g)).ToArray(), ["primaryGroupID"] = [primary],
        });
    private static byte[] Sid(string value) { var sid = new SecurityIdentifier(value); var bytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(bytes, 0); return bytes; }
}
