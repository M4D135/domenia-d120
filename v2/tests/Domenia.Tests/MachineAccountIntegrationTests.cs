using System.Runtime.InteropServices;
using System.Security;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Simulation;

namespace Domenia.Tests;

internal static class MachineAccountIntegrationTests
{
    private const string Admin = @"EXAMPLE\adm-j.martin";
    private static SecureString Secret() => PasswordSecrets.FromText("shared-cascade-fixture-2026!");

    [Test]
    public static async Task The_workstation_panel_uses_the_secondary_account_and_keeps_typed_priority()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context;
        var access = AccountAccess.From(bridge.Context); var machine = MachineAccountService.From(bridge.Context);
        using var secret = Secret();
        Check.True((await access.ActivateAsync(AccessUsage.Remote, Admin, secret, CancellationToken.None)).Result.Success, "secondaire validé");
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        Check.Equal(MachineAccountSource.Remote, machine.Resolve(session, null).Source, "même compte dans le panneau poste");
        using (var credential = machine.CredentialFor(session, "PC-1"))
        { Check.Equal(Admin, credential.Account, "identité partagée"); Check.True(credential.Password!.IsReadOnly(), "copie figée pour le transport"); }
        machine.UseTyped(@"EXAMPLE\ponctuel", null);
        Check.Equal(MachineAccountSource.Typed, machine.Resolve(session, null).Source, "saisie avant compte Postes");
        var overview = await access.OverviewAsync(CancellationToken.None);
        Check.Equal(@"EXAMPLE\ponctuel", overview.Identities.First(i => i.Id == "remote").Account, "page Comptes raccordée au même choix");
        machine.ForgetTyped(); await access.ClearAsync(AccessUsage.Remote, CancellationToken.None);
        Check.Equal(MachineAccountSource.Windows, machine.Resolve(session, null).Source, "effacement vu par le panneau");
    }

    [Test]
    public static async Task A_shared_single_use_lease_is_spent_once_and_passive_labels_do_not_extend_it()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(bridge.Context);
        var machine = MachineAccountService.From(bridge.Context); using var secret = Secret();
        await access.OverviewAsync(CancellationToken.None);
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-1", "accessDenied", null, true);
        var request = (await access.OverviewAsync(CancellationToken.None)).Pending.First(p => p.Scope == CredentialRules.Remote);
        Check.True((await access.RecoverAsync(request.Id, Admin, secret, LeaseMode.OneShot, 30, null, CancellationToken.None)).Result.Success, "compte temporaire validé");
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        machine.UseTyped(@"EXAMPLE\ponctuel", null);
        for (var i = 0; i < 3; i++) { Check.Equal(MachineAccountSource.Temporary, machine.Resolve(session, "PC-1").Source, "affichage sans consommation"); }
        using (var credential = machine.CredentialFor(session, "PC-1")) { Check.Equal(Admin, credential.Account, "un seul départ avec ce secret"); }
        Check.Equal(MachineAccountSource.Typed, machine.Resolve(session, "PC-1").Source, "bail consommé dans l’unique stockage");
        Check.False((await access.OverviewAsync(CancellationToken.None)).Memory.Any(m => m.Account == Admin), "également oublié dans Comptes");
    }

    [Test]
    public static async Task An_authentication_pause_is_shared_and_cannot_fall_back_to_Windows()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(bridge.Context);
        var machine = MachineAccountService.From(bridge.Context); using var secret = Secret();
        await access.ActivateAsync(AccessUsage.Remote, Admin, secret, CancellationToken.None);
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        access.RegisterRefusal(CredentialRules.Remote, "Inventaire", "PC-1", "badCredentials", null, true);
        Check.True(machine.Build(session, "PC-1", null).InUse.Paused, "pause visible dans le panneau");
        Check.Throws<DomeniaOperationException>(() => machine.CredentialFor(session, "PC-1"), "aucun départ ni repli Windows");
        using var trial = machine.CredentialFor(session, "PC-1", forTrial: true);
        Check.Equal(Admin, trial.Account, "essai explicite avec le même compte");
    }

    [Test]
    public static async Task Changing_the_session_forgets_the_typed_workstation_account_even_for_the_same_login()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(bridge.Context);
        var machine = MachineAccountService.From(bridge.Context); using var secret = Secret();
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        machine.UseTyped(@"EXAMPLE\ponctuel", null); _ = machine.Resolve(session, null);
        var before = machine.Generation;
        var changed = await access.SwitchAsync(Admin, secret, CancellationToken.None);
        Check.True(changed.Result.Success, "nouvelle session");
        session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        Check.Null(machine.Build(session, null, null).Typed, "saisie précédente oubliée");
        Check.True(machine.Generation > before, "génération déplacée pour écarter les résultats tardifs");
    }

    [Test]
    public static async Task A_dispatched_copy_remains_tracked_until_its_transport_finishes()
    {
        var bridge = new SimulatedBridge(); using var owner = bridge.Context; var access = AccountAccess.From(bridge.Context);
        var machine = MachineAccountService.From(bridge.Context); using var secret = Secret();
        await access.ActivateAsync(AccessUsage.Remote, Admin, secret, CancellationToken.None);
        var session = await bridge.Source.GetSessionAsync(CancellationToken.None);
        var copy = machine.CredentialFor(session, "PC-1");
        try
        {
            await access.ClearAsync(AccessUsage.Remote, CancellationToken.None);
            Check.True(SecureCredentialCopies.Contains(secret), "copie en vol connue même après effacement du compte");
        }
        finally { copy.Dispose(); }
        Check.False(SecureCredentialCopies.Contains(secret), "plus de copie détenue après fin du transport");
    }

    [Test]
    public static void A_native_authentication_refusal_stops_the_remaining_CIM_queries()
    {
        foreach (var code in new[] { 1326, 1327, 1328, 1329, 1330, 1331, 1385, 1793, 1907, 1909 })
        {
            Check.True(WindowsAuthenticationErrors.IsRejected(code), "code Win32 d’authentification reconnu");
            Check.True(WindowsAuthenticationErrors.IsRejected(unchecked((int)0x80070000) | code), "même code dans un HRESULT");
        }
        Check.False(WindowsAuthenticationErrors.IsRejected(5), "droit refusé distinct d’un secret refusé");
        Check.False(WindowsAuthenticationErrors.IsRejected(unchecked((int)0x80041003)), "WMI AccessDenied n’est pas une preuve de mauvais secret");
        var calls = 0;
        var session = new CimSession("PC-1", TimeSpan.FromSeconds(15), TimeProvider.System)
        { ReadOverride = (_, _, _) => { calls++; throw new COMException("fixture", unchecked((int)0x8007052E)); } };
        var first = session.Read("system", @"root\cimv2", "SELECT Name FROM Win32_ComputerSystem", 1);
        var second = session.Read("bios", @"root\cimv2", "SELECT SMBIOSBIOSVersion FROM Win32_BIOS", 1);
        Check.Equal(1, calls, "pas de répétition du mauvais secret");
        Check.Equal(SourceStatus.Refused, second.Status, "refus conservé");
        Check.True(first.ToAccess(InventoryTransport.Dcom).AuthenticationRejected && second.AuthenticationRejected, "refus d’identité distinct d’un manque de droit");
        using var missing = new RemoteProbeCredential(Admin, null, false);
        Check.Throws<DomeniaOperationException>(() => new CimSession("PC-1", TimeSpan.FromSeconds(15), TimeProvider.System, credential: missing), "pas de retour Windows si secret explicite absent");
    }

    [Test]
    public static async Task A_native_worker_owns_its_copy_after_the_callers_credential_is_disposed()
    {
        using var secret = Secret();
        var credential = new RemoteProbeCredential(Admin, secret.Copy(), false);
        using var release = new ManualResetEventSlim();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var worker = WmiReadWorkers.Start(credential, owned => { entered.SetResult(); release.Wait(); return owned!.Password!.Length; }, CancellationToken.None);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            credential.Dispose();
            Check.True(SecureCredentialCopies.Contains(secret), "travailleur encore propriétaire après annulation de l’attente");
        }
        finally { release.Set(); credential.Dispose(); }
        Check.Equal(secret.Length, await worker.WaitAsync(TimeSpan.FromSeconds(5)), "copie native encore utilisable");
        Check.False(SecureCredentialCopies.Contains(secret), "copie libérée au retour réel");
    }

    [Test]
    public static async Task Fleet_probes_require_the_machine_identity_and_an_excluded_DC_probe_contacts_nothing()
    {
        var calls = 0;
        var reader = new WmiFleetProbeReader(TimeProvider.System)
        {
            SessionFactory = (host, budget, token) => new CimSession(host, budget, TimeProvider.System, cancellationToken: token)
            { ReadOverride = (_, _, _) => { calls++; return [new WmiInstance(new Dictionary<string, object?> { ["Name"] = "OTHER" })]; } },
        };
        var dc = Fixtures.Computer("DC1") with { UserAccountControl = 8192 };
        var skipped = await reader.ReadAsync(dc, ["sec.localusers"], CancellationToken.None);
        Check.Equal(0, calls, "aucune requête pour une sonde exclue seule");
        Check.Equal(MeasureState.NotRead, skipped["sec.localusers"].State, "exclusion explicite");
        var wrong = await reader.ReadAsync(dc, ["hw.model"], CancellationToken.None);
        Check.Equal(1, calls, "identité seule, sonde non envoyée après un nom différent");
        Check.Equal(MeasureState.Incomplete, wrong["hw.model"].State, "aucune association à une autre machine");
        Check.True(wrong["hw.model"].Values.IsEmpty, "aucune valeur étrangère conservée");
    }
}
