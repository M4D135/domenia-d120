using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteProgramSafetyTests
{
    [Test]
    public static void Every_closed_read_program_is_audited_without_changing_its_bytes()
    {
        foreach (var kind in Enum.GetValues<RemoteTaskReadKind>())
        {
            var plan = RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), new('a', 64), @"TEST\operator", Fixtures.Now,
                kind, kind == RemoteTaskReadKind.Software ? new SoftwareRequest(true, true, true) : null);
            var script = RemoteTaskReadProgram.Script(plan);
            RemoteProgramSafety.RequireSafe(script);
            Check.Equal(plan.ScriptSha256, RemoteTaskReadProgram.Hash(script), "audit sans mutation des octets scellés");
            Check.Contains("-ExecutionPolicy Bypass -File", RemoteScriptPlan.Command(plan, @"C:\Windows"), "exception limitée au processus du programme fermé");
        }
        foreach (var forbidden in new[] { "Set-ExecutionPolicy Bypass -Scope LocalMachine", "Enable-PSRemoting -Force",
            "Set-MpPreference -DisableRealtimeMonitoring $true", "Set-NetFirewallProfile -Enabled False", "netsh advfirewall set allprofiles state off",
            "New-PSSessionOption -SkipCACheck", "[Net.ServicePointManager]::ServerCertificateValidationCallback={$true}", "winrm quickconfig -quiet" })
            Check.Throws<InvalidDataException>(() => RemoteProgramSafety.RequireSafe(forbidden), "affaiblissement sécurité refusé");
    }

    [Test]
    public static async Task Real_runner_consumes_read_authorization_once_and_denies_before_start()
    {
        using var folder = new TemporaryFolder(); var (db, plan) = await RemoteTaskReadTests.Open(folder);
        var backend = new RemoteTaskReadTests.Backend(plan); var calls = 0;
        var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }
            .RunAsync(plan, new SqliteDirectoryCache(db), null, _ => { calls++; return Task.FromResult(false); }, CancellationToken.None);
        Check.Equal(1, calls, "une seule consommation après précontrôle");
        Check.Equal(1, backend.Preflights, "précontrôle effectif"); Check.Equal(0, backend.Starts, "aucun artefact ni lanceur autorisé");
        Check.False(result.WorkerPending, "worker terminé sans nouveau transport");
    }
}
