using System.ComponentModel;
using System.Runtime.InteropServices;
using Domenia.Core;
using Domenia.Core.Poste;
using Microsoft.Win32.SafeHandles;

namespace Domenia.Inventory;

public enum DiagnosticTransport { Smb, WinRm, TaskScheduler }

public sealed partial class CimSession
{
    internal Func<DiagnosticTransport, CimReading>? DiagnosticOverride { get; init; }

    internal CimReading ReadDiagnosticTransport(DiagnosticTransport kind)
    {
        if (!Enum.IsDefined(kind)) { throw new ArgumentOutOfRangeException(nameof(kind)); }
        var begin = clock.GetTimestamp(); var category = kind.ToString();
        if (cancellationToken.IsCancellationRequested || OutOfBudget) { return new(category, SourceStatus.Interrupted, "Contrôle non tenté : arrêt ou budget atteint.", 0, []); }
        try
        {
            if (DiagnosticOverride is { } injected) { return injected(kind); }
            switch (kind)
            {
                case DiagnosticTransport.Smb:
                    WithNetworkIdentity(() =>
                    {
                        // OPEN_EXISTING + FILE_LIST_DIRECTORY. No file creation, enumeration, write access or mapping.
                        using var handle = CreateFileW(@"\\" + Host + @"\C$\", 1, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
                        if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                        return true;
                    });
                    return Result(SourceStatus.Ok, "C$ ouvert avec le droit de lister la racine ; aucun fichier lu, aucun droit d’écriture déduit.");
                case DiagnosticTransport.WinRm:
                    using (var channel = new WsmanReadChannel(Host, credential, clock, cancellationToken)) { channel.Identify(Remaining); }
                    return Result(SourceStatus.Ok, "Réponse WS-Management authentifiée par Kerberos ; aucun droit CIM ni shell déduit.");
                case DiagnosticTransport.TaskScheduler:
                    object? service = null; object? folder = null;
                    try
                    {
                        service = Activator.CreateInstance(Type.GetTypeFromProgID("Schedule.Service", throwOnError: true)!)!;
                        TaskSchedulerConnection.Connect(service, Host, credential);
                        cancellationToken.ThrowIfCancellationRequested();
                        folder = ((dynamic)service).GetFolder(@"\");
                        var path = (string)((dynamic)folder).Path;
                        if (path != @"\") { return Result(SourceStatus.Error, "Le planificateur a répondu avec un dossier inattendu."); }
                        return Result(SourceStatus.Ok, "Dossier racine du planificateur lu ; aucune tâche créée, exécutée ou modifiée, droit de création non déduit.");
                    }
                    finally
                    {
                        if (folder is not null && Marshal.IsComObject(folder)) { Marshal.FinalReleaseComObject(folder); }
                        if (service is not null && Marshal.IsComObject(service)) { Marshal.FinalReleaseComObject(service); }
                    }
                default: throw new ArgumentOutOfRangeException(nameof(kind));
            }
        }
        catch (OperationCanceledException) { return Result(SourceStatus.Interrupted, "Contrôle arrêté ; résultat non reçu."); }
        catch (Exception ex) when (ex is Win32Exception or COMException or UnauthorizedAccessException or System.Xml.XmlException or TimeoutException)
        {
            var code = ex is Win32Exception native ? native.NativeErrorCode : ex.HResult;
            var rejected = WindowsAuthenticationErrors.IsRejected(code);
            var refused = rejected || code is 5 or 1314 or unchecked((int)0x80070005);
            return Result(refused ? SourceStatus.Refused : ex is TimeoutException ? SourceStatus.Interrupted : SourceStatus.Unavailable,
                refused ? "Accès refusé au compte choisi (code 0x" + code.ToString("X8") + ")." : "Contrôle non concluant (code 0x" + code.ToString("X8") + ").") with { AuthenticationRejected = rejected };
        }
        CimReading Result(SourceStatus status, string detail) => new(category, status, detail, (int)clock.GetElapsedTime(begin).TotalMilliseconds, []);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern SafeFileHandle CreateFileW(string path, uint desiredAccess, uint sharing, IntPtr security, uint disposition, uint flags, IntPtr template);
}
