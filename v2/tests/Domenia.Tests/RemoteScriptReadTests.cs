using System.Runtime.InteropServices;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;
using Domenia.Store;

namespace Domenia.Tests;

internal static class RemoteScriptReadTests
{
    [Test]
    public static void Missing_Wmi_creation_status_never_becomes_success()
    {
        Check.Throws<InvalidDataException>(() => RemoteWmiProcessLauncher.CreationCode(null), "retour absent ne devient pas code zéro");
        Check.Throws<InvalidDataException>(() => RemoteWmiProcessLauncher.CreationCode("0"), "texte arbitraire ne devient pas retour natif");
        Check.Equal(0U, RemoteWmiProcessLauncher.CreationCode(0U), "seul zéro réellement rendu prouve succès");
        Check.Equal(2U, RemoteWmiProcessLauncher.CreationCode(2U), "refus natif conservé");
    }

    private const string Command = "\"C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoLogo -NoProfile -NonInteractive -File \"C:\\Windows\\Temp\\owned\\read.ps1\"";
    private sealed class ProcessWire : IRemoteProcessWire
    {
        internal int Creates, Reads;
        internal Action? OnCreate;
        internal readonly Queue<RemoteProcessIdentity?> Results = new();
        public string Connect(CancellationToken token) { token.ThrowIfCancellationRequested(); return @"C:\Windows"; }
        public uint Create(string command) { Creates++; Check.Equal(Command, command, "programme fermé inchangé"); OnCreate?.Invoke(); return 42; }
        public RemoteProcessIdentity? Read(uint pid) { Reads++; Check.Equal(42U, pid, "seul PID rendu par notre création"); return Results.Dequeue(); }
        public void Dispose() { }
    }
    private sealed class ShellWire : IReadShellWire
    {
        internal const string Shell = "22dd1928-d62f-462c-9b82-228b620a4a35", CommandId = "337c9a76-23c0-4aa4-99fe-27b7281f79ee";
        internal int Creates, Commands, Receives, Deletes;
        internal Action? OnCreate, OnCommand, OnDelete;
        internal string? Received;
        public string Create(TimeSpan timeout, string input)
        {
            Creates++; Check.Contains("PT40S", input, "vie du shell bornée"); OnCreate?.Invoke();
            return "<Shell xmlns='http://schemas.microsoft.com/wbem/wsman/1/windows/shell'><ShellId>" + Shell + "</ShellId></Shell>";
        }
        public string Command(TimeSpan timeout, string shellId, string input)
        {
            Commands++; Check.Equal(Shell, shellId, "commande uniquement dans notre shell"); OnCommand?.Invoke();
            var xml = XElement.Parse(input); Check.Equal(2, xml.Elements().Count(), "exécutable séparé des arguments");
            return "<CommandResponse xmlns='http://schemas.microsoft.com/wbem/wsman/1/windows/shell'><CommandId>" + CommandId + "</CommandId></CommandResponse>";
        }
        public string Receive(TimeSpan timeout, string input)
        {
            Receives++; Check.Contains(CommandId, input, "réception liée à notre commande");
            return Received ?? "<ReceiveResponse xmlns='http://schemas.microsoft.com/wbem/wsman/1/windows/shell'><CommandState CommandId='" + CommandId
                + "' State='http://schemas.microsoft.com/wbem/wsman/1/windows/shell/CommandState/Done'><ExitCode>0</ExitCode></CommandState></ReceiveResponse>";
        }
        public void Delete(TimeSpan timeout, string shellId) { Deletes++; Check.Equal(Shell, shellId, "ne ferme aucun autre shell"); OnDelete?.Invoke(); }
        public void Dispose() { }
    }
    private sealed class Artifacts : IRemoteScriptArtifacts
    {
        internal int Creates, Removes, Recovers;
        public void Preflight(CancellationToken token) => token.ThrowIfCancellationRequested();
        public void Create(CancellationToken token) { token.ThrowIfCancellationRequested(); Creates++; }
        public void Recover() => Recovers++;
        public string? ReadResult() => null;
        public bool Remove() { Removes++; return true; }
        public void Dispose() { }
    }

    [Test]
    public static void Wmi_lost_creation_reply_never_replays_or_claims_process_stop()
    {
        var wire = new ProcessWire { OnCreate = () => throw new COMException("Réponse perdue.", unchecked((int)0x800706BA)) };
        using var launcher = new RemoteWmiProcessLauncher(wire); launcher.Preflight(CancellationToken.None);
        Check.Throws<COMException>(() => launcher.Start(Command, CancellationToken.None), "création au résultat inconnu");
        Check.Throws<InvalidOperationException>(() => launcher.Start(Command, CancellationToken.None), "aucun deuxième Create");
        Check.False(launcher.CloseOwned(), "aucune fin inventée sans PID"); Check.Equal(1, wire.Creates, "un seul envoi"); Check.Equal(0, wire.Reads, "aucun PID deviné");
    }

    [Test]
    public static void Wmi_recycled_PID_is_never_terminated_and_natural_exit_is_observed()
    {
        foreach (var recycled in new[] { true, false })
        {
            var wire = new ProcessWire(); wire.Results.Enqueue(new(42, "20261028100000.000000+000", Command));
            wire.Results.Enqueue(recycled ? new(42, "20261028110000.000000+000", "another.exe") : null);
            using var launcher = new RemoteWmiProcessLauncher(wire); launcher.Preflight(CancellationToken.None); launcher.Start(Command, CancellationToken.None);
            Check.True(launcher.Finished, "absence ou autre création prouve la fin de notre processus");
            Check.True(launcher.CloseOwned(), "fin confirmée sans aucune primitive de terminaison"); Check.Equal(1, wire.Creates, "aucun remplaçant");
        }
    }

    [Test]
    public static void Wmi_initial_PID_owned_by_another_command_is_not_a_cleanup_authorization()
    {
        var wire = new ProcessWire(); wire.Results.Enqueue(new(42, "20261028100000.000000+000", "another.exe"));
        wire.Results.Enqueue(new(42, "20261028100000.000000+000", "another.exe"));
        using var launcher = new RemoteWmiProcessLauncher(wire); launcher.Preflight(CancellationToken.None);
        Check.Throws<InvalidDataException>(() => launcher.Start(Command, CancellationToken.None), "propriétaire non confirmé");
        Check.Throws<InvalidDataException>(() => launcher.CloseOwned(), "pas de nettoyage par PID seul"); Check.Equal(1, wire.Creates, "un seul envoi");
    }

    [Test]
    public static void Winrm_lost_Create_or_Command_response_never_starts_a_second_command()
    {
        foreach (var create in new[] { true, false })
        {
            var wire = new ShellWire(); void Lost() => throw new COMException("Réponse perdue.", unchecked((int)0x800706BA));
            if (create) { wire.OnCreate = Lost; } else { wire.OnCommand = Lost; }
            using var launcher = new RemoteWinRmScriptLauncher(wire, @"C:\Windows", TestClock.Fixed()); launcher.Preflight(CancellationToken.None);
            Check.Throws<COMException>(() => launcher.Start(Command, CancellationToken.None), "réponse perdue");
            Check.Throws<InvalidOperationException>(() => launcher.Start(Command, CancellationToken.None), "aucun deuxième envoi");
            Check.Equal(!create, launcher.CloseOwned(), "seul le ShellId reçu peut être fermé");
            Check.Equal(1, wire.Creates, "un seul shell"); Check.Equal(create ? 0 : 1, wire.Commands, "commande unique ou aucune");
            Check.Equal(create ? 0 : 1, wire.Deletes, "fermeture uniquement de notre shell connu");
        }
    }

    [Test]
    public static void Winrm_cancellation_after_Create_closes_only_the_owned_shell_without_running()
    {
        using var stop = new CancellationTokenSource(); var wire = new ShellWire { OnCreate = stop.Cancel };
        using var launcher = new RemoteWinRmScriptLauncher(wire, @"C:\Windows", TestClock.Fixed()); launcher.Preflight(stop.Token);
        Check.Throws<OperationCanceledException>(() => launcher.Start(Command, stop.Token), "annulation après réponse de création");
        Check.True(launcher.CloseOwned(), "nettoyage indépendant du token annulé"); Check.Equal(0, wire.Commands, "aucune commande après annulation");
        Check.Equal(1, wire.Deletes, "seul shell appartenant à l’opération");
    }

    [Test]
    public static void Winrm_output_from_another_command_or_lost_Delete_stays_unconfirmed()
    {
        var wire = new ShellWire { Received = "<ReceiveResponse xmlns='http://schemas.microsoft.com/wbem/wsman/1/windows/shell'><Stream Name='stdout' CommandId='11111111-1111-1111-1111-111111111111'>eA==</Stream></ReceiveResponse>" };
        using var launcher = new RemoteWinRmScriptLauncher(wire, @"C:\Windows", TestClock.Fixed()); launcher.Preflight(CancellationToken.None); launcher.Start(Command, CancellationToken.None);
        Check.Throws<System.Xml.XmlException>(() => _ = launcher.Finished, "sortie d’une autre commande refusée");
        wire.OnDelete = () => throw new COMException("Réponse de suppression perdue.");
        Check.Throws<COMException>(() => launcher.CloseOwned(), "aucune suppression inventée"); Check.Equal(1, wire.Commands, "aucune relance");
    }

    [Test]
    public static async Task Transient_plans_require_enabled_explicit_methods_and_pin_the_closed_script()
    {
        using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder);
        var settings = PosteConfiguration.Defaults;
        RemoteTaskReadPlan Prepare(PosteConfiguration configuration) => RemoteTaskReadRunner.PrepareFallbackPlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now, configuration, null, CancellationToken.None);
        Check.Throws<DomeniaOperationException>(() => Prepare(settings), "option désactivée par défaut");
        settings = settings with { AllowRemoteArtifacts = true, UseTaskFallback = true, UseWmiProcess = true, UseWinRmScript = true };
        Check.Equal(RemoteReadTransport.WinRmScript, Prepare(settings).Transport, "une méthode automatique avant tout contact");
        Check.Equal(RemoteReadTransport.WmiProcess, Prepare(settings with { TransientMethod = "wmi" }).Transport, "choix manuel WMI");
        Check.Throws<DomeniaOperationException>(() => Prepare(settings with { TransientMethod = "winrm", UseWinRmScript = false }), "méthode interdite sans repli vers tâche");
        foreach (var method in new[] { "wmi", "winrm" })
        {
            var plan = Prepare(settings with { TransientMethod = method }); RemoteTaskReadRules.Validate(plan, Fixtures.Now);
            Check.Equal(RemoteTaskReadProgram.Hash(RemoteTaskReadProgram.Script(plan)), plan.ScriptSha256, "programme lié au plan");
            Check.True(RemoteScriptPlan.ProgramBytes(plan).AsSpan(0, 3).SequenceEqual(new byte[] { 0xef, 0xbb, 0xbf }), "UTF8 BOM pour PowerShell 5.1");
            Check.Contains(plan.DirectoryName, RemoteScriptPlan.Command(plan, @"C:\Windows"), "chemin unique au plan");
            Check.Throws<InvalidDataException>(() => RemoteScriptPlan.Command(plan, @"C:\Windows%TEMP%"), "pas de substitution shell");
            Check.Throws<InvalidDataException>(() => RemoteScriptPlan.ProgramBytes(plan with { ScriptSha256 = new('0', 64) }), "programme modifié refusé");
        }
    }

    [Test]
    public static async Task Wmi_and_Winrm_readings_keep_their_transport_and_never_reuse_a_claimed_plan()
    {
        foreach (var transport in new[] { RemoteReadTransport.WmiProcess, RemoteReadTransport.WinRmScript })
        {
            using var folder = new TemporaryFolder(); var (db, initial) = await RemoteTaskReadTests.Open(folder); var plan = initial with { Transport = transport };
            var backend = new RemoteTaskReadTests.Backend(plan); var runner = new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend };
            var journal = new SqliteDirectoryCache(db);
            var result = await runner.RunAsync(plan, journal, null, _ => Task.FromResult(true), CancellationToken.None);
            Check.True(result.CleanupConfirmed, "reçu réel conservé");
            Check.Equal(transport == RemoteReadTransport.WmiProcess ? InventoryTransport.WmiProcess : InventoryTransport.WinRmScript, result.Reading.Access.Transport, "méthode réelle");
            Check.False(result.Reading.Access.Detail.Contains("sous SYSTEM", StringComparison.Ordinal), "aucun contexte SYSTEM inventé");
            await runner.RunAsync(plan, journal, null, _ => throw new InvalidOperationException("Aucun second accord"), CancellationToken.None);
            Check.Equal(1, backend.Starts, "revendication durable empêche tout rejeu");
        }
    }

    [Test]
    public static async Task Transient_inventory_names_the_actual_transport_on_snapshot_and_each_source()
    {
        foreach (var transport in new[] { RemoteReadTransport.WmiProcess, RemoteReadTransport.WinRmScript })
        {
            using var folder = new TemporaryFolder(); var (db, _) = await RemoteTaskReadTests.Open(folder);
            var plan = RemoteTaskReadRunner.PreparePlan(Fixtures.Computer("PC1"), db.StoreId, @"TEST\operator", Fixtures.Now, RemoteTaskReadKind.InventoryQuick) with { Transport = transport };
            var backend = new RemoteTaskReadTests.Backend(plan) { OnRead = () => RemoteTaskReadExtendedTests.InventoryJson(plan) };
            var result = await new RemoteTaskReadRunner(TestClock.Fixed()) { BackendOverride = (_, _) => backend }
                .RunAsync(plan, new SqliteDirectoryCache(db), null, _ => Task.FromResult(true), CancellationToken.None);
            var expected = transport == RemoteReadTransport.WmiProcess ? InventoryTransport.WmiProcess : InventoryTransport.WinRmScript;
            Check.NotNull(result.Inventory, "inventaire reçu"); Check.Equal(expected, result.Inventory!.Transport, "transport global réellement exécuté");
            Check.True(result.Inventory.Access.All(a => a.Transport == expected), "sources cohérentes avec le transport global");
        }
    }

    [Test]
    public static async Task Recovery_without_durable_stop_preserves_script_artifacts_and_never_launches()
    {
        using var folder = new TemporaryFolder(); var (_, initial) = await RemoteTaskReadTests.Open(folder);
        foreach (var stopped in new[] { false, true })
        {
            var artifacts = new Artifacts(); var wire = new ProcessWire(); using var launcher = new RemoteWmiProcessLauncher(wire);
            using var backend = new RemoteScriptReadBackend(initial with { Transport = RemoteReadTransport.WmiProcess }, artifacts, launcher);
            backend.PrepareCleanup(new(Fixtures.Now, false, stopped, false, "Preuve antérieure"), CancellationToken.None);
            var cleanup = backend.Cleanup(); Check.Equal(stopped, cleanup.Stopped, "aucune fin déduite de l’absence d’identifiant local");
            Check.Equal(stopped ? 1 : 0, artifacts.Removes, "suppression seulement après preuve durable");
            Check.Equal(0, wire.Creates, "récupération ne lance jamais"); Check.Equal(0, artifacts.Creates, "aucun nouveau dossier");
        }
    }

    [Test]
    public static async Task Script_backend_retains_artifacts_after_lost_launch_and_requires_stop_receipt_before_removing()
    {
        using var folder = new TemporaryFolder(); var (_, initial) = await RemoteTaskReadTests.Open(folder);
        var plan = initial with { Transport = RemoteReadTransport.WinRmScript };
        foreach (var lostCreate in new[] { true, false })
        {
            var wire = new ShellWire();
            if (lostCreate) { wire.OnCreate = () => throw new COMException("Réponse perdue."); }
            var artifacts = new Artifacts();
            using var backend = new RemoteScriptReadBackend(plan, artifacts, new RemoteWinRmScriptLauncher(wire, @"C:\Windows", TestClock.Fixed()));
            backend.Preflight(CancellationToken.None);
            if (lostCreate) { Check.Throws<COMException>(() => backend.Start(CancellationToken.None), "issue de création inconnue"); }
            else { backend.Start(CancellationToken.None); }
            var callbacks = 0;
            var cleanup = backend.Cleanup(() => { callbacks++; Check.Equal(0, artifacts.Removes, "preuve durable avant suppression"); });
            Check.Equal(!lostCreate, cleanup.Stopped, "aucune fin imaginée");
            Check.Equal(lostCreate ? 0 : 1, artifacts.Removes, "dossier préservé si shell inconnu");
            Check.Equal(lostCreate ? 0 : 1, callbacks, "preuve seulement après fermeture confirmée");
            Check.Throws<InvalidOperationException>(() => backend.Start(CancellationToken.None), "pas de second lancement après nettoyage");
            Check.Equal(1, wire.Creates, "un seul Create");
        }
    }
}
