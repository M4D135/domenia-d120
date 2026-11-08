using System.ComponentModel;
using System.Diagnostics;
using System.Text.Json;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

/// <summary>One pinned launcher, one pre-recorded plan and fixed program. Killing the local launcher never proves remote stop.
/// A surviving PsExec service/binary is preserved; cleanup only removes our nonce-owned folder after independently proven stop.</summary>
internal sealed class RemotePsExecReadBackend : IRemoteTaskReadBackend
{
    private readonly RemoteTaskReadPlan plan;
    private readonly RemoteTaskReadBackend artifacts;
    private readonly RemotePsExecService service;
    private RemotePsExecBinary? binary;
    private Process? process;
    private FileStream? program;
    private Task? output, error;
    private bool prepared, attempted, recovering, previouslyStopped, resultBound;
    private volatile bool aborted;
    internal RemotePsExecReadBackend(RemoteTaskReadPlan plan, RemoteProbeCredential? credential)
    {
        RemotePsExecPlan.Validate(plan, credential); this.plan = plan;
        artifacts = new(plan, null); service = new(plan);
    }

    public void Preflight(CancellationToken token)
    {
        binary = RemotePsExecBinary.Find(AppContext.BaseDirectory, token) ?? throw new IOException("PsExec approuvé absent près de Domenia ; aucun téléchargement ni copie.");
        if (binary.Sha256 != plan.PsExecSha256) { throw new IOException("Binaire PsExec changé depuis la préparation."); }
        service.Preflight(token); artifacts.PreflightArtifacts(token); prepared = true;
    }
    public void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token)
    {
        recovering = true; previouslyStopped = previous?.ExecutionStopped == true;
        service.Connect(token); artifacts.RecoverArtifacts();
    }
    public void Start(CancellationToken token)
    {
        if (!prepared || attempted || process is not null || binary is null) { throw new InvalidOperationException("Précontrôle absent ou lancement déjà tenté."); }
        token.ThrowIfCancellationRequested(); artifacts.CreateArtifacts(token); program = artifacts.CreatePsExecProgram(token);
        var start = new ProcessStartInfo(binary.Path) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = AppContext.BaseDirectory,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var argument in RemotePsExecPlan.Arguments(plan, service.WindowsFolder)) { start.ArgumentList.Add(argument); }
        token.ThrowIfCancellationRequested(); attempted = true;
        process = Process.Start(start) ?? throw new IOException("Lancement PsExec non confirmé.");
        process.StandardInput.Close(); output = Drain(process.StandardOutput.BaseStream); error = Drain(process.StandardError.BaseStream);
    }
    private async Task Drain(Stream stream)
    {
        var buffer = new byte[4096]; var total = 0;
        try
        {
            int count;
            while ((count = await stream.ReadAsync(buffer).ConfigureAwait(false)) != 0)
            {
                total += count;
                if (total > 64 * 1024) { aborted = true; Kill(); break; }
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { aborted = true; }
    }
    public string? ReadResult()
    {
        service.Observe(); var json = artifacts.ReadResult();
        if (json is not null)
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 10 }); var root = document.RootElement;
            bool Text(string name, string expected) => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String && value.GetString() == expected;
            resultBound = root.ValueKind == JsonValueKind.Object && Text("Id", plan.Id.ToString("N")) && Text("Nonce", plan.Nonce) && Text("Format", "Domenia.RemoteRead/1");
        }
        return json;
    }
    public bool Finished { get { service.Observe(); return process?.HasExited == true; } }

    public RemoteTaskReadCleanup Cleanup(Action? recordStopped = null)
    {
        var stopped = recovering && previouslyStopped;
        try
        {
            if (!recovering && !attempted)
            { program?.Dispose(); program = null; return new(true, artifacts.RemoveArtifacts(), "Aucun lancement PsExec tenté ; seul le dossier propre éventuel est nettoyé."); }
            if (!recovering)
            {
                // A result can precede the launcher's normal return by a few milliseconds. Allow its own cleanup to finish.
                if (process is not null && !process.WaitForExit(3000)) { aborted = true; Kill(); }
                WaitForExit();
            }
            program?.Dispose(); program = null;
            stopped = recovering ? previouslyStopped : !aborted && process is { HasExited: true, ExitCode: 0 } && resultBound && service.Observed;
            if (!stopped) { return new(false, false, "Arrêt distant PsExec non prouvé ; service, fichiers et reçu conservés. Aucun second lancement automatique."); }
            recordStopped?.Invoke();
            var watch = Stopwatch.StartNew(); var absent = service.ArtifactsAbsent();
            while (!absent && watch.Elapsed < TimeSpan.FromSeconds(3)) { Thread.Sleep(100); absent = service.ArtifactsAbsent(); }
            if (!absent) { return new(true, false, "Service ou binaire PsExec encore présent ; aucune suppression arbitraire. Dossier et reçu conservés."); }
            var removed = artifacts.RemoveArtifacts();
            return new(true, removed, removed ? "Fin PsExec et résultat liés au plan ; service, binaire et dossier absents après relecture." : "Arrêt prouvé, nettoyage du dossier non confirmé.");
        }
        catch (Exception ex) when (ex is IOException or Win32Exception or UnauthorizedAccessException or OperationCanceledException)
        { return new(stopped, false, "Nettoyage PsExec non confirmé (code 0x" + ex.HResult.ToString("X8") + ") ; preuves conservées."); }
    }
    private void Kill()
    {
        if (process is null || process.HasExited) { return; }
        try { process.Kill(entireProcessTree: true); }
        catch (InvalidOperationException) when (process.HasExited) { }
        catch (Win32Exception) { /* Keep the physical owner until actual local process exit. */ }
    }
    private void WaitForExit()
    {
        process?.WaitForExit(); output?.GetAwaiter().GetResult(); error?.GetAwaiter().GetResult();
    }
    public void Dispose()
    {
        // Runner083 retains host/physical leases through this wait, even if the UI already stopped waiting.
        try { if (process is { HasExited: false }) { aborted = true; Kill(); } WaitForExit(); }
        finally { program?.Dispose(); process?.Dispose(); binary?.Dispose(); service.Dispose(); artifacts.Dispose(); }
    }
}
