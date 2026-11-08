using System.Text.Json;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Domenia.Ad;
using System.Xml.Linq;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Tests;

internal static class RemoteWriteTransportTests
{
    private static RemoteWriteRequest Request(string kind) => new(kind, Fixtures.Computer("PC1"), Guid.NewGuid(), 10);
    [Test]
    public static void Closed_programs_keep_data_out_of_code_and_task_ownership_covers_action_identity_and_no_replay()
    {
        var run = PosteRemote.Run("PC1", "interactive", @"C:\Program Files\Tool\Tool.exe", "--opaque <value> & 'argument'", @"TEST\user", false).Request!;
        var request = Request(PosteRemoteWrites.RunKind) with { Run = run, RunUserSid = "S-1-5-21-1-2-3-1002" };
        var xml = RemoteWriteTask.Xml(request); Check.True(RemoteWriteTask.Owns(xml, request), "XML réellement produit relu");
        Check.False(RemoteWriteTask.Owns(xml.Replace("powershell.exe", "Other.exe", StringComparison.Ordinal), request), "programme substitué refusé");
        Check.False(RemoteWriteTask.Owns(xml.Replace("S-1-5-21-1-2-3-1002", "S-1-5-21-1-2-3-1003", StringComparison.Ordinal), request), "utilisateur substitué refusé");
        var doc = XDocument.Parse(xml); XNamespace ns = "http://schemas.microsoft.com/windows/2004/02/mit/task";
        doc.Root!.Element(ns + "Triggers")!.Add(new XElement(ns + "TimeTrigger"));
        Check.False(RemoteWriteTask.Owns(doc.ToString(), request), "déclencheur automatique refusé");
        var scriptBody = RemoteWriteTask.Program(request);
        Check.Contains("WindowsIdentity", scriptBody, "SID du jeton contrôlé dans le vrai contexte de lancement");
        Check.Contains("Win32_ComputerSystem", scriptBody, "machine relue dans la tâche avant Process.Start");
        Check.False(scriptBody.Contains(run.Arguments, StringComparison.Ordinal), "arguments encodés utilisés comme données, pas code");
        Check.False(RemoteWriteTask.Owns(xml.Replace("<AllowHardTerminate>false", "<AllowHardTerminate>true", StringComparison.Ordinal), request), "aucun arrêt forcé introduit");
        Check.False(JsonSerializer.Serialize(request).Contains(run.Arguments, StringComparison.Ordinal), "arguments ignorés par sérialisation");
        Check.False(request.ToString().Contains(run.Arguments, StringComparison.Ordinal), "aucun argument dans ToString");
        var restart = PosteRemote.Restart("PC1", "delayed", 5, "Enregistrer ; $(throw 'injection')", true).Request!;
        var script = RemoteWritePrograms.WinRm(Request(PosteRemoteWrites.RestartKind) with { Restart = restart });
        Check.False(script.Contains(restart.Message, StringComparison.Ordinal), "texte opérateur seulement en données encodées");
        Check.True(script.Contains("ConvertFrom-Json", StringComparison.Ordinal), "aucune évaluation du message");
        Check.True(script.Contains("Win32_ComputerSystem", StringComparison.Ordinal) && script.Contains("$p.domain", StringComparison.Ordinal), "identité dans le programme avant effet");
        var gp = RemoteWritePrograms.WinRm(Request(PosteRemoteWrites.GpUpdateKind));
        Check.True(gp.Contains("/wait:-1", StringComparison.Ordinal), "code de sortie après fin effective, attente du canal séparément bornée");
        Check.False(gp.Contains("Set-ExecutionPolicy", StringComparison.OrdinalIgnoreCase), "aucun changement de sécurité");
    }
    [Test]
    public static void Native_return_values_and_configuration_keep_unknown_distinct_from_refusal()
    {
        Check.Equal(WriteResult.Applied, RemoteWriteNativeBackend.Code((uint)0, "Service").Result, "acquittement");
        Check.Equal(WriteResult.Delivered, RemoteWriteNativeBackend.ScriptCode(PosteRemoteWrites.GpUpdateKind, 0).Result, "gpupdate terminé sans preuve de politiques finales");
        Check.Equal(WriteResult.Unknown, RemoteWriteNativeBackend.ScriptCode(PosteRemoteWrites.GpUpdateKind, 1).Result, "erreur sans faux acquittement");
        Check.Equal<OperationFailureKind?>(OperationFailureKind.AccessDenied, RemoteWriteNativeBackend.ScriptCode(PosteRemoteWrites.ServiceKind, 2).Failure, "refus fournisseur structuré");
        Check.Equal(WriteResult.NotApplied, RemoteWriteNativeBackend.Code((uint)2, "Service").Result, "refus réel");
        Check.Equal(WriteResult.Unknown, RemoteWriteNativeBackend.Code((uint)7, "Service").Result, "timeout du service pas refus certain");
        Check.Equal(WriteResult.NotApplied, RemoteWriteNativeBackend.Code((uint)21, "Service").Result, "paramètres refusés par le fournisseur");
        Check.Equal(WriteResult.Unknown, RemoteWriteNativeBackend.ShutdownCode((uint)8).Result, "retour du redémarrage forcé indéterminé");
        Check.Equal(WriteResult.Unknown, RemoteWriteNativeBackend.Code(null, "Redémarrage").Result, "réponse perdue jamais succès");
        Check.Equal(WriteResult.Unknown, RemoteWriteNativeBackend.Code("0", "Service").Result, "chaîne non coercée en code natif");
        Check.Equal(1, PosteConfiguration.Parse("""{"Remote":{"CommandTimeoutSeconds":0}}"""u8).CommandTimeoutSeconds, "borne basse");
        Check.Equal(300, PosteConfiguration.Parse("""{"Remote":{"CommandTimeoutSeconds":999}}"""u8).CommandTimeoutSeconds, "borne haute");
        Check.Equal(10, PosteConfiguration.Defaults.CommandTimeoutSeconds, "défaut");
        foreach (var service in new[] { "WinDefend", "mpssvc", "WINRM", "BFE" })
        {
            foreach (var action in new[] { "stop", "restart" })
                Check.Throws<InvalidDataException>(() => RemoteWriteClient.Validate(Request(PosteRemoteWrites.ServiceKind) with { Service = service, ServiceAction = action }), "protection par nom transmis en données : " + service);
            RemoteWriteClient.Validate(Request(PosteRemoteWrites.ServiceKind) with { Service = service, ServiceAction = "start" });
        }
        var json = """{"Remote":{"CommandTimeoutSeconds":23},"Poste":{"WakeNetworks":["192.0.2.0/24"]}}"""u8.ToArray();
        var left = PosteConfiguration.Parse(json); var right = PosteConfiguration.Parse(json);
        left = left with { Options = left.Options with { WakeNetworks = ["192.0.2.0/24"] } };
        right = right with { Options = right.Options with { WakeNetworks = ["192.0.2.0/24"] } };
        Check.True(AdPosteRemoteExecutor.SameSettings(left, right), "deux lectures identiques ne dépendent pas de références ImmutableArray");
        Check.False(AdPosteRemoteExecutor.SameSettings(left, right with { CommandTimeoutSeconds = 24 }), "changement effectif détecté");
        Check.False(AdPosteRemoteExecutor.SameSettings(left, right with { Options = right.Options with { UseWinRm = !right.Options.UseWinRm } }), "transport changé refusé");
        Check.Throws<InvalidDataException>(() => RemoteWriteClient.Validate(Request(PosteRemoteWrites.RunKind) with { Run = PosteRemote.Run("PC1", "system", @"\\server\Tool.exe", "", null, false).Request }), "pas de programme UNC");
    }
    private sealed class Held(TaskCompletionSource entered, TaskCompletionSource release) : IRemoteWriteBackend
    {
        internal bool Disposed; internal RemoteProbeCredential? Credential;
        public RemoteWriteSnapshot Inspect(RemoteWriteRequest request, CancellationToken token) => throw new TestFailureException("Pas de lecture dans ce cas");
        public RemoteWriteResult Execute(RemoteWriteRequest request)
        { entered.TrySetResult(); release.Task.GetAwaiter().GetResult(); Check.Equal(12, Credential!.Password!.Length, "copie gardée jusqu’au retour réel"); return new(WriteResult.Unknown, "issue inconnue"); }
        public void Dispose() => Disposed = true;
    }
    [Test]
    public static async Task Slow_native_command_retains_credential_and_owner_until_real_return_and_wake_rejects_credentials()
    {
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var backend = new Held(entered, release); var client = new RemoteWriteClient { BackendFactory = (credential, _) => { backend.Credential = credential; return backend; } };
        using var secret = PasswordSecrets.FromText("fixture-only"); using var selected = new RemoteProbeCredential(@"TEST\operator", secret.Copy(), false);
        var request = Request(PosteRemoteWrites.GpUpdateKind); Task<RemoteWriteResult>? work = null;
        try
        {
            work = client.ExecuteAsync(request, selected, PosteConfiguration.Defaults); await entered.Task.WaitAsync(TimeSpan.FromSeconds(10));
            selected.Dispose(); Check.False(work.IsCompleted, "le délai logique ne libère pas un appel natif actif"); Check.False(backend.Disposed, "propriétaire physique conservé");
            release.TrySetResult(); Check.Equal(WriteResult.Unknown, (await work.WaitAsync(TimeSpan.FromSeconds(10))).Result, "issue inconnue conservée");
            Check.True(backend.Disposed, "libération après retour seulement");
        }
        finally { release.TrySetResult(); if (work is not null) await work.WaitAsync(TimeSpan.FromSeconds(10)); }
        using var windows = new RemoteProbeCredential(@"TEST\operator", null, true);
        using (OperationCredentialScope.Enter(OperationCredentialNeeds.ForRead("search.recheck", "ping")))
            Check.Throws<DomeniaOperationException>(() => client.ExecuteAsync(Request(PosteRemoteWrites.GpUpdateKind), windows, PosteConfiguration.Defaults), "besoin ping ne peut copier un identifiant vers le fournisseur d’écriture");
        var wake = Request(PosteRemoteWrites.WakeKind) with { Wake = new(true, "", "00-11-22-33-44-55", "192.0.2.255", 9) };
        Check.Throws<ArgumentException>(() => client.ExecuteAsync(wake, windows, PosteConfiguration.Defaults), "le datagramme ne reçoit même pas une identité Windows");
    }
    [Test]
    public static void Actual_Windows_task_definition_preserves_the_closed_identity_and_settings()
    {
        object? scheduler = null, definition = null;
        try
        {
            scheduler = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
            ((dynamic)scheduler).Connect(); // Local COM only: no registration, remote host, credential or process launch.
            foreach (var interactive in new[] { false, true })
            {
                var run = PosteRemote.Run("PC1", interactive ? "interactive" : "system", @"C:\Tools\Tool.exe", new string('é', PosteRemote.MaxArgumentsLength), interactive ? @"TEST\user" : null, false).Request!;
                var request = Request(PosteRemoteWrites.RunKind) with { Run = run, RunUserSid = interactive ? "S-1-5-21-1-2-3-1002" : null };
                definition = ((dynamic)scheduler).NewTask(0); ((dynamic)definition).XmlText = RemoteWriteTask.Xml(request);
                Check.True(RemoteWriteTask.Owns((string)((dynamic)definition).XmlText, request), "normalisation réelle du schéma Windows sans enregistrement");
                Marshal.FinalReleaseComObject(definition); definition = null;
            }
        }
        finally
        { if (definition is not null && Marshal.IsComObject(definition)) Marshal.FinalReleaseComObject(definition); if (scheduler is not null && Marshal.IsComObject(scheduler)) Marshal.FinalReleaseComObject(scheduler); }
    }
    [Test]
    public static async Task Fixed_programs_are_parsed_by_Windows_PowerShell_without_executing_their_bodies()
    {
        using var folder = new TemporaryFolder();
        var run = PosteRemote.Run("PC1", "system", @"C:\Tools\Tool.exe", "quote ' & $data", null, false).Request!;
        var scripts = new[] { RemoteWriteTask.Program(Request(PosteRemoteWrites.RunKind) with { Run = run }),
            RemoteWritePrograms.WinRm(Request(PosteRemoteWrites.ServiceKind) with { Service = "Spooler", ServiceAction = "restart" }) };
        foreach (var (script, index) in scripts.Select((value, index) => (value, index)))
        {
            var input = Path.Combine(folder.Path, "closed-" + index + ".ps1"); File.WriteAllText(input, script, new UTF8Encoding(true));
            var parser = "$tokens=$null;$errors=$null;[System.Management.Automation.Language.Parser]::ParseFile('" + input.Replace("'", "''", StringComparison.Ordinal) + "',[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){$errors|ForEach-Object {$_.ErrorId};exit 1};exit 0";
            using var process = new Process { StartInfo = new(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe")) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true } };
            process.StartInfo.ArgumentList.Add("-NoLogo"); process.StartInfo.ArgumentList.Add("-NoProfile"); process.StartInfo.ArgumentList.Add("-NonInteractive");
            process.StartInfo.ArgumentList.Add("-EncodedCommand"); process.StartInfo.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(parser)));
            process.Start(); var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync();
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15)); }
            finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); } }
            Check.Equal(0, process.ExitCode, "syntaxe native du programme fermé " + index + ": " + await stdout + await stderr);
        }
    }

}
