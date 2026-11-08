using Domenia.Ad;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class MachineAdmissionInspectionTests
{
    private static readonly CancellationToken None = CancellationToken.None;
    private const string Admin = @"EXAMPLE\adm-j.martin";

    [Test]
    public static async Task Local_admission_inspection_neither_spends_a_one_shot_nor_extends_idle_lifetime()
    {
        var fixture = Fixture(); using var owner = fixture.Context;
        var machine = MachineAccountService.From(owner); var session = await fixture.Source.GetSessionAsync(None);
        using var password = PasswordSecrets.FromText("local-admission-inspection-fixture");
        machine.AcceptTemporary(session, null, Admin, password.Copy(), MachineLeaseMode.OneShot);
        var generation = machine.Build(session, "PC-1", null).Generation;
        for (var i = 0; i < 3; i++)
        {
            using var inspection = machine.InspectCredentialFor(session, "PC-1", generation);
            Check.Equal(Admin, inspection.Account, "même choix que la future opération");
            Check.True(inspection.Password!.IsReadOnly(), "copie secrète figée et possédée par l’inspection");
        }
        Check.Equal(generation, machine.Generation, "inspection sans consommation ni changement de génération");
        using (var actual = machine.CredentialFor(session, "PC-1")) Check.Equal(Admin, actual.Account, "l’opération conserve l’unique usage");
        Check.Equal(MachineAccountSource.Windows, machine.Resolve(session, "PC-1").Source, "seule l’opération a consommé l’usage");
        machine.AcceptTemporary(session, null, Admin, password.Copy(), MachineLeaseMode.Inactivity, 1);
        fixture.Clock.Advance(TimeSpan.FromSeconds(45));
        using (machine.InspectCredentialFor(session, "PC-1")) { }
        fixture.Clock.Advance(TimeSpan.FromSeconds(20));
        Check.Equal(MachineAccountSource.Windows, machine.Resolve(session, "PC-1").Source, "inspection ne prolonge pas le délai sans activité");
    }

    [Test]
    public static async Task Shared_account_inspection_preserves_one_shot_and_honours_pause_and_selection_changes()
    {
        var fixture = Fixture(); using var owner = fixture.Context;
        var machine = MachineAccountService.From(owner); var access = AccountAccess.From(owner);
        using var password = PasswordSecrets.FromText("shared-admission-inspection-fixture");
        await access.OverviewAsync(None);
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-1", "accessDenied", null, true);
        var pending = (await access.OverviewAsync(None)).Pending.First(p => p.Scope == CredentialRules.Remote);
        Check.True((await access.RecoverAsync(pending.Id, Admin, password, LeaseMode.OneShot, 30, null, None)).Result.Success, "compte partagé validé");
        var session = await fixture.Source.GetSessionAsync(None);
        var generation = machine.Build(session, "PC-1", null).Generation;
        for (var i = 0; i < 3; i++) using (var inspection = machine.InspectCredentialFor(session, "PC-1", generation))
            Check.Equal(Admin, inspection.Account, "même compte partagé, aucune consommation");
        Check.True((await access.OverviewAsync(None)).Memory.Any(m => m.Account == Admin), "le secret partagé reste disponible après inspection");
        using (var actual = machine.CredentialFor(session, "PC-1")) Check.Equal(Admin, actual.Account, "usage réel encore disponible");
        Check.False((await access.OverviewAsync(None)).Memory.Any(m => m.Account == Admin), "usage réel retire le secret partagé");
        await access.ActivateAsync(AccessUsage.Remote, Admin, password, None);
        _ = machine.Build(session, "PC-1", null);
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-1", "badCredentials", null, true);
        Check.Throws<DomeniaOperationException>(() => machine.InspectCredentialFor(session, "PC-1"), "inspection ne contourne pas une pause");
        var before = machine.Generation;
        machine.UseTyped(@"EXAMPLE\another", password.Copy());
        Check.Throws<DomeniaOperationException>(() => machine.InspectCredentialFor(session, "PC-1", before), "aucun compte substitué si la sélection a changé");
    }

    [Test]
    public static async Task Ping_admission_checks_the_selected_secret_without_consuming_or_contacting_any_provider()
    {
        var pc = Fixtures.Computer("PC1"); var copies = 0;
        using var ldap = new AdBoundaryTests.RecordingAdConnection();
        var cache = new AdAccueilTests.FleetCache(Fixtures.Snapshot(computers: [pc]));
        using var source = new AdDirectorySource("test.local", () => @"TEST\reader", TestClock.Fixed(), connection: ldap, localStore: cache)
        { SessionCredentialCopy = () => { copies++; return AdBoundaryTests.NativeSessionCredential(); } };
        source.AdoptConnection(ldap, Fixtures.Domain,
            new(new(@"TEST\reader", null, null, "CN=reader," + Fixtures.People), Fixtures.Domain.DomainSid + "-1001",
                new(RightsLevel.Unknown, "Inconnus", true, "Droits AD distincts."))
            { Administration = new(AdministrationIdentityState.Standard, "Compte de connexion standard.") }, source.Epoch, false);
        await source.ReadLocalAsync(None);
        using var context = new EngineContext(new(AppMode.Directory, ModeReason.Argument, "Test", null, "test.local", []), source,
            new MemoryPreferenceStore(), source.Clock, new RecordingJournal());
        var machine = MachineAccountService.From(context); var session = await source.GetSessionAsync(None);
        var workstation = (await new AdMachineAccountReader(source).FindWorkstationAsync(pc.Name, None))!;
        using var valid = PasswordSecrets.FromText("validated-local-admission-fixture");
        using var wrong = PasswordSecrets.FromText("different-local-admission-fixture");
        Check.True(source.RecordLocalAdministration(workstation, @"PC1\Admin", "S-1-5-21-90-91-92-500", source.Epoch, valid,
            expectedComputer: QueryComputerIdentity.Of(pc)), "preuve de cible déjà validée explicitement");
        machine.AcceptTemporary(session, pc.Name, @"PC1\Admin", valid.Copy(), MachineLeaseMode.OneShot);
        await AdWorkstationAccess.RequireNetworkIdentityAsync(source, pc.DnsHostName!, None);
        Check.Equal(MachineAccountSource.TemporaryLocal, machine.Resolve(session, pc.Name).Source, "le contrôle précédant le ping ne consomme pas le compte");
        using (var accepted = await AdWorkstationAccess.AcquireAsync(source, pc.DnsHostName!, None))
            Check.Equal(@"PC1\Admin", accepted.Credential.Account, "opération réelle admise avec le même secret");
        machine.UseTyped(@"PC1\Admin", wrong.Copy());
        var refusal = await Check.ThrowsAsync<DomeniaOperationException>(() => AdWorkstationAccess.RequireNetworkIdentityAsync(source, pc.DnsHostName!, None), "même login mais secret changé refusé avant ping");
        Check.Equal(AdministrationIdentity.Required, refusal.Code, "ancienne preuve ne valide pas un autre secret");
        Check.Equal(0, copies, "aucune copie native de la connexion pour cette inspection");
        Check.Equal(0, ldap.Calls, "aucune requête LDAP ni validation implicite");
    }

    private static (SimulatedDirectorySource Source, EngineContext Context, FixedTimeProvider Clock) Fixture()
    {
        var clock = TestClock.Fixed();
        var source = new SimulatedDirectorySource(SimulationOptions.Default with { Latency = SimulationLatency.None }, clock);
        var context = new EngineContext(new(AppMode.Simulation, ModeReason.Argument, "Test", null, null, []), source,
            new MemoryPreferenceStore(), clock, new RecordingJournal(), ScreenReaders.Discover(source, [typeof(SimulatedDirectorySource).Assembly]));
        return (source, context, clock);
    }
}
