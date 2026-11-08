using Domenia.Core;
using Domenia.Core.Poste;
using System.ComponentModel;

namespace Domenia.Inventory;

public sealed partial class RemoteTaskReadRunner
{
    public static RemoteTaskReadPlan PrepareFallbackPlan(DirectoryComputer computer, string storeId, string account, DateTimeOffset now,
        PosteConfiguration settings, RemoteProbeCredential? credential, CancellationToken token,
        RemoteTaskReadKind kind = RemoteTaskReadKind.UserIdentity, SoftwareRequest? software = null)
    {
        token.ThrowIfCancellationRequested();
        if (!settings.AllowsTransient) { throw new DomeniaOperationException("poste.fallback.disabled", "Les programmes ponctuels sont désactivés ; aucun contact."); }
        var method = settings.TransientMethod;
        if (method is not ("auto" or "task" or "psexec" or "wmi" or "winrm"))
        { throw new DomeniaOperationException("poste.fallback.method", "Méthode ponctuelle inconnue ; aucun contact."); }
        if ((method is "auto" or "winrm") && settings.UseWinRmScript)
        { return RemoteScriptPlan.Create(computer, storeId, account, now, RemoteReadTransport.WinRmScript, kind, software); }
        if ((method is "auto" or "wmi") && settings.UseWmiProcess)
        { return RemoteScriptPlan.Create(computer, storeId, account, now, RemoteReadTransport.WmiProcess, kind, software); }
        if ((method is "auto" or "psexec") && settings.UsePsExecFallback)
        { return PrepareFallbackPlan(computer, storeId, account, now, true, method == "auto" && settings.UseTaskFallback, credential, token, kind, software); }
        if ((method is "auto" or "task") && settings.UseTaskFallback) { return PreparePlan(computer, storeId, account, now, kind, software); }
        throw new DomeniaOperationException("poste.fallback.method", "La méthode choisie n’est pas autorisée ; aucun autre transport essayé.");
    }

    /// <summary>Called only in the explicit, already consented fallback flow. Reads a pre-existing local package, never starts
    /// anything. Chooses one transport for the durable plan; there is no second attempt after that plan has been claimed.</summary>
    public static RemoteTaskReadPlan PrepareFallbackPlan(DirectoryComputer computer, string storeId, string account, DateTimeOffset now,
        bool usePsExec, bool useTask, RemoteProbeCredential? credential, CancellationToken token,
        RemoteTaskReadKind kind = RemoteTaskReadKind.UserIdentity, SoftwareRequest? software = null)
    {
        token.ThrowIfCancellationRequested();
        if (usePsExec && (credential is null or { Session: true, Password: null }))
        {
            try
            {
                using var binary = RemotePsExecBinary.Find(AppContext.BaseDirectory, token);
                if (binary is not null) { return RemotePsExecPlan.Create(computer, storeId, account, now, kind, software); }
            }
            catch (Exception ex) when (ex is IOException or Win32Exception or UnauthorizedAccessException)
            { throw new DomeniaOperationException("poste.psexec.binary", "Binaire PsExec présent mais non qualifié ; aucune exécution ni autre transport essayé."); }
        }
        if (useTask) { return PreparePlan(computer, storeId, account, now, kind, software); }
        throw new DomeniaOperationException("poste.fallback.unavailable", "Aucun repli autorisé disponible : PsExec exige son binaire local approuvé et le contexte Windows intégré ; le repli par tâche est désactivé.");
    }

    private IRemoteTaskReadBackend CreateBackend(RemoteTaskReadPlan plan, RemoteProbeCredential? credential) => BackendOverride?.Invoke(plan, credential)
        ?? (plan.Transport switch
        {
            RemoteReadTransport.PsExec => new RemotePsExecReadBackend(plan, credential),
            RemoteReadTransport.ScheduledTask => new RemoteTaskReadBackend(plan, credential),
            RemoteReadTransport.WmiProcess or RemoteReadTransport.WinRmScript => new RemoteScriptReadBackend(plan, credential, clock),
            _ => throw new InvalidDataException("Transport de lecture non reconnu."),
        });

    private static InventoryTransport TransportOf(RemoteTaskReadPlan plan) => plan.Transport switch
    {
        RemoteReadTransport.PsExec => InventoryTransport.PsExec,
        RemoteReadTransport.WmiProcess => InventoryTransport.WmiProcess,
        RemoteReadTransport.WinRmScript => InventoryTransport.WinRmScript,
        _ => InventoryTransport.ScheduledTask,
    };
    private static string TransportDetail(RemoteTaskReadPlan plan, string text) => plan.Transport switch
    {
        RemoteReadTransport.PsExec => text.Replace("par tâche planifiée", "par PsExec", StringComparison.Ordinal).Replace("Tâche SYSTEM", "PsExec SYSTEM", StringComparison.Ordinal),
        RemoteReadTransport.WmiProcess => text.Replace("par tâche planifiée", "par programme WMI", StringComparison.Ordinal).Replace("Tâche SYSTEM", "Programme WMI", StringComparison.Ordinal).Replace("sous SYSTEM", "dans le contexte du compte autorisé", StringComparison.Ordinal),
        RemoteReadTransport.WinRmScript => text.Replace("par tâche planifiée", "par programme WinRM", StringComparison.Ordinal).Replace("Tâche SYSTEM", "Programme WinRM", StringComparison.Ordinal).Replace("sous SYSTEM", "dans le contexte du compte autorisé", StringComparison.Ordinal),
        _ => text,
    };
    private static WorkstationUserReading TransportReading(RemoteTaskReadPlan plan, WorkstationUserReading reading) => plan.Transport == RemoteReadTransport.ScheduledTask ? reading
        : reading with { Access = reading.Access with { Category = plan.Transport + "Fallback", Transport = TransportOf(plan), Detail = TransportDetail(plan, reading.Access.Detail) },
            Candidates = [.. reading.Candidates.Select(c => c with { Origin = TransportDetail(plan, c.Origin) })] };

    private static InventorySnapshot? TransportInventory(RemoteTaskReadPlan plan, InventorySnapshot? value) => value is null || plan.Transport == RemoteReadTransport.ScheduledTask ? value
        : value with { Transport = TransportOf(plan), Access = [.. value.Access.Select(a => a with { Transport = TransportOf(plan), Detail = TransportDetail(plan, a.Detail) })] };

    private static WorkstationSoftwareReading? TransportSoftware(RemoteTaskReadPlan plan, WorkstationSoftwareReading? value) => value is null || plan.Transport == RemoteReadTransport.ScheduledTask ? value
        : value with { Access = [.. value.Access.Select(a => a with { Detail = TransportDetail(plan, a.Detail) })] };
}
