using System.Management;
using System.Runtime.InteropServices;
using Domenia.Core;
using WmiEnumerationOptions = System.Management.EnumerationOptions;

namespace Domenia.Inventory;

/// <summary>One explicit credential trial, one connection, one SELECT, no fallback or retry.</summary>
public sealed class WmiMachineAccessProbe(TimeProvider clock)
{
    private static readonly SemaphoreSlim Workers = new(4, 4);

    public async Task<MachineTrialObservation> ReadAsync(MachineProbeRequest request, MachineWorkstation workstation, CancellationToken cancellationToken, bool confirmComputerName = false)
    {
        var host = workstation.DnsHostName ?? workstation.Name;
        if (!CimQuery.IsHostName(host)) { return new("TargetUnknown", "Nom de poste invalide.", "Target", null, workstation); }
        if (request.Source != MachineAccountSource.Windows && (request.Password is null || string.IsNullOrWhiteSpace(request.Account)))
        {
            return new("Failed", "Les informations d’identification de ce compte ne sont pas disponibles.", "CredentialMissing", null, workstation);
        }
        // Own the copy until the worker actually ends, even if the caller cancels first.
        if (!await Workers.WaitAsync(0, cancellationToken).ConfigureAwait(false))
        { return new("Timeout", "Un essai natif précédent se termine encore ; aucun nouvel essai envoyé.", "Network", null, workstation); }
        System.Security.SecureString? password;
        try { password = request.Password?.Copy(); }
        catch { Workers.Release(); throw; }
        var tracked = SecureCredentialCopies.Track(password);
        var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var token = stop.Token;
        var task = Task.Run(() =>
        {
            using (password)
            using (tracked)
            {
                ConnectionOptions? options = null;
                ManagementScope? scope = null;
                ManagementObjectSearcher? searcher = null;
                try
                {
                    token.ThrowIfCancellationRequested();
                    options = new ConnectionOptions
                    {
                        Impersonation = ImpersonationLevel.Impersonate,
                        Authentication = AuthenticationLevel.PacketPrivacy,
                        EnablePrivileges = false,
                        Timeout = TimeSpan.FromSeconds(6),
                    };
                    if (request.Source != MachineAccountSource.Windows)
                    {
                        options.Username = request.Account;
                        options.SecurePassword = password;
                    }
                    scope = new ManagementScope(@"\\" + host + @"\root\cimv2", options);
                    scope.Connect();
                    token.ThrowIfCancellationRequested();
                    searcher = new ManagementObjectSearcher(scope, new ObjectQuery(confirmComputerName ? "SELECT Name FROM Win32_ComputerSystem" : "SELECT Caption FROM Win32_OperatingSystem"),
                        new WmiEnumerationOptions { Timeout = TimeSpan.FromSeconds(6), ReturnImmediately = true, Rewindable = false });
                    using var results = searcher.Get();
                    foreach (var item in results)
                    {
                        using (item)
                        {
                            token.ThrowIfCancellationRequested();
                            var caption = item[confirmComputerName ? "Name" : "Caption"] as string;
                            return string.IsNullOrWhiteSpace(caption)
                                ? new MachineTrialObservation("Failed", "Le système a répondu sans fournir son nom.", "Incomplete", null, workstation)
                                : confirmComputerName
                                    ? string.Equals(caption.Trim(), workstation.Name, StringComparison.OrdinalIgnoreCase)
                                        ? new MachineTrialObservation("Observed", null, null, null, workstation) { ConfirmedComputerName = caption.Trim() }
                                        : new MachineTrialObservation("Failed", "Le nom du poste relu diffère de la cible annuaire.", "Target", null, workstation)
                                    : new MachineTrialObservation("Observed", null, null, caption.Trim(), workstation);
                        }
                    }
                    return new MachineTrialObservation("Failed", "La lecture du système n’a retourné aucune instance.", "Incomplete", null, workstation);
                }
                catch (Exception ex) when (Classify(ex) is { } failure)
                {
                    return new MachineTrialObservation(failure.Outcome, failure.Message, failure.Category, null, workstation);
                }
                finally
                {
                    // System.Management clones scopes/options. Clear every retained secure copy after the real native return.
                    if (searcher is not null) { searcher.Scope.Options.SecurePassword = null; searcher.Dispose(); }
                    if (scope is not null) { scope.Options.SecurePassword = null; }
                    if (options is not null) { options.SecurePassword = null; }
                }
            }
        }, CancellationToken.None);
        _ = task.ContinueWith(_ => { stop.Dispose(); Workers.Release(); }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        try { return await task.WaitAsync(TimeSpan.FromSeconds(14), clock, cancellationToken).ConfigureAwait(false); }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException)
        {
            try { stop.Cancel(); } catch (ObjectDisposedException) { /* worker finished concurrently */ }
            _ = task.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
            if (ex is OperationCanceledException) { throw; }
            return new("Timeout", "Le budget de l’essai a été atteint.", "Network", null, workstation);
        }
    }

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
