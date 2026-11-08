using System.Management;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Inventory;

/// <summary>One explicit credential trial, one connection, one SELECT, no fallback or retry.</summary>
public sealed partial class WmiMachineAccessProbe(TimeProvider clock)
{
    public async Task<MachineTrialObservation> ReadAsync(MachineProbeRequest request, MachineWorkstation workstation, CancellationToken cancellationToken, bool confirmComputerName = false, bool requireLocalAdministrator = false)
    {
        var host = workstation.DnsHostName ?? workstation.Name;
        if (!CimQuery.IsHostName(host)) { return new("TargetUnknown", "Nom de poste invalide.", "Target", null, workstation); }
        if (request.Source != MachineAccountSource.Windows && (request.Password is null || string.IsNullOrWhiteSpace(request.Account)))
        {
            return new("Failed", "Les informations d’identification de ce compte ne sont pas disponibles.", "CredentialMissing", null, workstation);
        }
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = stop.Token;
        Task<MachineTrialObservation> task;
        try
        {
            using var credential = new RemoteProbeCredential(request.Account,
                request.Source == MachineAccountSource.Windows ? null : request.Password?.Copy(), request.Source == MachineAccountSource.Windows);
            // Capacity is awaited before starting the trial deadline. The admitted worker owns its secret copy.
            task = await WmiReadWorkers.StartAsync(host, credential, owned =>
            {
                var account = owned ?? throw new InvalidOperationException("Compte de l’essai absent.");
                try
                {
                    token.ThrowIfCancellationRequested();
                    using var client = new NativeReadClient(new(host, InventoryTransport.Dcom, 14_000, account.Session,
                        account.Session ? null : account.Account, true, false), account, token);
                    var trial = client.Read(new(NativeReadKind.AccessTrial, 14_000)
                    { ExpectedComputerName = confirmComputerName || requireLocalAdministrator ? workstation.Name : null,
                        RequireLocalAdministrator = requireLocalAdministrator, AdministrationPrincipal = request.AdministrationPrincipal }).Trial
                        ?? throw new InvalidDataException("Réponse d’essai native incohérente.");
                    return new MachineTrialObservation(trial.Outcome, trial.ErrorText, trial.Category, trial.Caption, workstation)
                    { ConfirmedComputerName = trial.ConfirmedComputerName, AdministratorSid = trial.AdministratorSid };
                }
                catch (TimeoutException)
                { return new MachineTrialObservation("Timeout", "Le budget de l’essai isolé a été atteint.", "Network", null, workstation); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or DomeniaOperationException or System.Text.Json.JsonException)
                { return new MachineTrialObservation("Failed", "L’essai isolé n’a pas répondu ; aucun repli ni nouvel essai automatique.", "Provider", null, workstation); }
            }, token).ConfigureAwait(false);
        }
        catch { stop.Dispose(); throw; }
        _ = task.ContinueWith(_ => stop.Dispose(), CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        try { return await task.WaitAsync(TimeSpan.FromSeconds(14), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            try { stop.Cancel(); } catch (ObjectDisposedException) { /* worker finished concurrently */ }
            _ = task.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            if (ex is OperationCanceledException) { throw; }
            return new("Timeout", "Le budget de l’essai a été atteint.", "Network", null, workstation);
        }
    }

    internal static NativeTrialReading ReadNative(string host, string? expectedName, RemoteProbeCredential? credential, CancellationToken token,
        bool requireLocalAdministrator = false, MachineAdministrationPrincipal? principal = null)
    {
        if (!NativeReadWorkerHost.IsWorker) { throw new InvalidOperationException("L’essai natif exige son processus privé."); }
        ConnectionOptions? options = null; ManagementScope? scope = null; ManagementObjectSearcher? searcher = null;
        try
        {
            token.ThrowIfCancellationRequested();
            if (principal is not null)
            {
                var same = principal.IsBounded && (credential is { Session: false }
                    ? string.Equals(principal.Account, credential.Account, StringComparison.OrdinalIgnoreCase)
                    : System.Security.Principal.WindowsIdentity.GetCurrent() is var windows && SameWindowsPrincipal(windows, principal.AccountSid));
                if (!same) return new("Denied", "Identité de la preuve différente du compte de l’essai.", "AdministrationRequired", null);
            }
            options = new ConnectionOptions { Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy,
                EnablePrivileges = false, Timeout = TimeSpan.FromSeconds(6) };
            if (credential is { Session: false }) { options.Username = credential.Account; options.SecurePassword = credential.Password; }
            scope = new(@"\\" + host + @"\root\cimv2", options); scope.Connect(); token.ThrowIfCancellationRequested();
            searcher = new(scope, new ObjectQuery(expectedName is null ? "SELECT Caption FROM Win32_OperatingSystem" : "SELECT Name FROM Win32_ComputerSystem"),
                new WmiEnumerationOptions { Timeout = TimeSpan.FromSeconds(6), ReturnImmediately = true, Rewindable = false });
            using var results = searcher.Get();
            foreach (var item in results)
            { using (item)
                {
                    token.ThrowIfCancellationRequested();
                    var trial = ProjectTrial(item[expectedName is null ? "Caption" : "Name"] as string, expectedName);
                    if (!requireLocalAdministrator || trial.Outcome != "Observed") { return trial; }
                    var sid = ReadLocalAdministrator(scope, expectedName!, credential?.Account ?? principal?.Account, token, principal);
                    return sid is null ? new("Denied", "L’identité locale n’a pas été retrouvée dans le groupe Administrateurs de cette cible. Aucune collecte autorisée.", "AdministrationRequired", null, trial.ConfirmedComputerName)
                        : trial with { AdministratorSid = sid };
                } }
            return new("Failed", "La lecture du système n’a retourné aucune instance.", "Incomplete", null);
        }
        catch (Exception ex) when (Classify(ex) is { } failure)
        { return new(failure.Outcome, failure.Message, failure.Category, null); }
        finally
        {
            if (searcher is not null) { searcher.Scope.Options.SecurePassword = null; searcher.Dispose(); }
            if (scope is not null) { scope.Options.SecurePassword = null; }
            if (options is not null) { options.SecurePassword = null; }
        }
    }

    private static bool SameWindowsPrincipal(System.Security.Principal.WindowsIdentity windows, string sid)
    { using (windows) return windows.User?.Value == sid; }

    internal static NativeTrialReading ProjectTrial(string? value, string? expectedName) => string.IsNullOrWhiteSpace(value) || value.Length > 32768
        ? new("Failed", "Le système a répondu sans fournir son nom borné.", "Incomplete", null)
        : expectedName is null ? new("Observed", null, null, value.Trim())
        : string.Equals(value.Trim(), expectedName, StringComparison.OrdinalIgnoreCase) ? new("Observed", null, null, null, value.Trim())
        : new("Failed", "Le nom du poste relu diffère de la cible annuaire.", "Target", null);

    internal static (string Outcome, string Category, string Message)? Classify(Exception ex) => ex switch
    {
        COMException { HResult: unchecked((int)0x8007052E) } => ("AuthRejected", "CredentialsRejected", "Informations d’identification refusées par le poste."),
        COMException error when WindowsAuthenticationErrors.IsRejected(error.HResult) => ("Failed", "AccountState", "Le compte est verrouillé, expiré, désactivé ou interdit pour cet accès."),
        UnauthorizedAccessException or ManagementException { ErrorCode: ManagementStatus.AccessDenied } or COMException { HResult: unchecked((int)0x80070005) } => ("Denied", "AccessDenied", "Accès refusé à cette lecture du poste."),
        TimeoutException or ManagementException { ErrorCode: ManagementStatus.Timedout } or COMException { HResult: unchecked((int)0x800706BA) or unchecked((int)0x800706BE) } => ("Timeout", "Network", "Le poste n’a pas répondu dans le délai de l’essai."),
        ManagementException or COMException => ("Failed", "Provider", "Le fournisseur CIM n’a pas permis cette lecture."),
        _ => null,
    };
}
