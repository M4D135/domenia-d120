using System.ComponentModel;
using System.Management;
using System.Runtime.InteropServices;
using System.Xml;
using Domenia.Core;
using Domenia.Core.Poste;

namespace Domenia.Inventory;

internal interface IRemoteScriptArtifacts : IDisposable
{
    void Preflight(CancellationToken token);
    void Create(CancellationToken token);
    void Recover();
    string? ReadResult();
    bool Remove();
}

internal interface IRemoteScriptLauncher : IDisposable
{
    string Preflight(CancellationToken token);
    void Start(string command, CancellationToken token);
    bool Finished { get; }
    // True proves that this launcher's execution and transport artifacts have ended.
    bool CloseOwned();
}

internal sealed class RemoteScriptArtifacts(RemoteTaskReadPlan plan, RemoteProbeCredential? credential) : IRemoteScriptArtifacts
{
    private readonly RemoteTaskReadBackend artifacts = new(plan, credential);
    private FileStream? pinned;
    public void Preflight(CancellationToken token) => artifacts.PreflightArtifacts(token);
    public void Create(CancellationToken token) { artifacts.CreateArtifacts(token); pinned = artifacts.CreateFileProgram(token); }
    public void Recover() => artifacts.RecoverArtifacts();
    public string? ReadResult() => artifacts.ReadResult();
    public bool Remove() { pinned?.Dispose(); pinned = null; return artifacts.RemoveArtifacts(); }
    public void Dispose() { pinned?.Dispose(); artifacts.Dispose(); }
}

/// <summary>Exactly one launch after durable claim and consent. Uncertain execution retains the owned folder and journal.</summary>
internal sealed class RemoteScriptReadBackend : IRemoteTaskReadBackend
{
    private readonly RemoteTaskReadPlan plan;
    private readonly IRemoteScriptArtifacts artifacts;
    private readonly IRemoteScriptLauncher launcher;
    private string? command;
    private bool prepared, attempted, recovering, previouslyStopped;

    internal RemoteScriptReadBackend(RemoteTaskReadPlan plan, RemoteProbeCredential? credential, TimeProvider clock)
        : this(plan, new RemoteScriptArtifacts(plan, credential), plan.Transport switch
        {
            RemoteReadTransport.WmiProcess => new RemoteWmiProcessLauncher(plan.Host, credential),
            RemoteReadTransport.WinRmScript => new RemoteWinRmScriptLauncher(plan.Host, credential, clock),
            _ => throw new InvalidOperationException("Lanceur de programme hors contrat."),
        }) { }

    internal RemoteScriptReadBackend(RemoteTaskReadPlan plan, IRemoteScriptArtifacts artifacts, IRemoteScriptLauncher launcher)
    { this.plan = plan; this.artifacts = artifacts; this.launcher = launcher; }

    public void Preflight(CancellationToken token)
    {
        if (prepared || attempted) { throw new InvalidOperationException("Précontrôle déjà effectué."); }
        command = RemoteScriptPlan.Command(plan, launcher.Preflight(token));
        artifacts.Preflight(token); prepared = true;
    }
    public void PrepareCleanup(RemoteTaskReadCompletion? previous, CancellationToken token)
    {
        token.ThrowIfCancellationRequested(); recovering = true;
        previouslyStopped = previous?.ExecutionStopped == true; artifacts.Recover();
    }
    public void Start(CancellationToken token)
    {
        if (!prepared || attempted || recovering || command is null) { throw new InvalidOperationException("Lancement déjà tenté ou précontrôle absent."); }
        token.ThrowIfCancellationRequested(); artifacts.Create(token);
        token.ThrowIfCancellationRequested(); attempted = true; // A lost reply must never reset this bit.
        launcher.Start(command, token);
    }
    public string? ReadResult() => artifacts.ReadResult();
    public bool Finished => launcher.Finished;

    public RemoteTaskReadCleanup Cleanup(Action? recordStopped = null)
    {
        var stopped = recovering ? previouslyStopped : !attempted;
        try
        {
            if (!recovering && attempted)
            {
                stopped = launcher.CloseOwned();
            }
            if (!stopped) { return new(false, false, "Fin du programme distant non prouvée ; dossier et journal conservés, aucun second lancement."); }
            recordStopped?.Invoke();
            var removed = artifacts.Remove();
            return new(true, removed, removed ? "Fin distante confirmée ; seuls les artefacts liés au plan ont été supprimés et leur absence relue."
                : "Fin confirmée ; suppression des artefacts non confirmée.");
        }
        catch (Exception ex) when (ex is IOException or Win32Exception or COMException or UnauthorizedAccessException or OperationCanceledException or ManagementException or TimeoutException or XmlException)
        { return new(stopped, false, "Nettoyage non confirmé (code 0x" + ex.HResult.ToString("X8") + ") ; preuves conservées."); }
    }
    public void Dispose() { try { launcher.Dispose(); } finally { artifacts.Dispose(); } }
}
