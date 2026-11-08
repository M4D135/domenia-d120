using System.Collections.Immutable;
using System.Runtime.InteropServices;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded, read-only SRV lookup through the configured Windows DNS client. No alternate resolver.</summary>
internal static class AdAuditDns
{
    private static readonly SemaphoreSlim Slots = new(2, 2);
    internal static async Task<(ImmutableArray<string> Names, ReadState State, string? Error)> SrvAsync(string name, CancellationToken token)
    {
        if (name.Length > 253 || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or '_')) { throw new ArgumentException("Nom SRV invalide.", nameof(name)); }
        if (!await Slots.WaitAsync(0, token).ConfigureAwait(false)) { return ([], ReadState.Unavailable, "Deux recherches DNS sont déjà en cours."); }
        IDisposable physical;
        try { physical = PhysicalWorkBudget.Acquire(PhysicalWorkRoute.Network); }
        catch (DomeniaOperationException ex) when (ex.Code == "operation.physicalBusy")
        { Slots.Release(); return ([], ReadState.Unavailable, ex.Message); }
        Task<(ImmutableArray<string> Names, ReadState State, string? Error)> work;
        try { work = Task.Run(() =>
        {
            using var ownedPhysical = physical;
            nint records = 0;
            try
            {
                token.ThrowIfCancellationRequested();
                var status = DnsQuery(name, 33, 0, 0, out records, 0);
                if (status != 0) { return (ImmutableArray<string>.Empty, ReadState.Unavailable, (string?)"Lecture SRV non disponible (code DNS " + status + ")."); }
                var names = ImmutableArray.CreateBuilder<string>(); var seen = new HashSet<nint>();
                for (var item = records; item != 0;)
                {
                    if (!seen.Add(item) || seen.Count > 256) { return (ImmutableArray<string>.Empty, ReadState.Unavailable, (string?)"Réponse SRV hors limites."); }
                    var record = Marshal.PtrToStructure<Record>(item);
                    if (record.Type == 33 && record.Target != 0)
                    {
                        var target = Marshal.PtrToStringUni(record.Target)?.TrimEnd('.');
                        if (target is null || !AuditControllerRules.IsHostName(target) || !target.Contains('.')) { return (ImmutableArray<string>.Empty, ReadState.Unavailable, (string?)"Cible SRV invalide."); }
                        names.Add(target);
                    }
                    item = record.Next;
                }
                return (names.Distinct(StringComparer.OrdinalIgnoreCase).ToImmutableArray(), names.Count == 0 ? ReadState.Empty : ReadState.Read, (string?)null);
            }
            finally { if (records != 0) { DnsRecordListFree(records, 1); } Slots.Release(); }
        }, CancellationToken.None); }
        catch { physical.Dispose(); Slots.Release(); throw; }
        try { return await work.WaitAsync(TimeSpan.FromSeconds(4), token).ConfigureAwait(false); }
        catch (OperationCanceledException)
        {
            _ = work.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously);
            throw;
        }
        catch (TimeoutException) { _ = work.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously); return ([], ReadState.Unavailable, "Délai DNS de quatre secondes atteint."); }
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct Record
    {
        internal nint Next, Name;
        internal ushort Type, DataLength;
        internal uint Flags, Ttl, Reserved;
        internal nint Target;
        internal ushort Priority, Weight, Port, Pad;
    }
    [DllImport("dnsapi.dll", EntryPoint = "DnsQuery_W", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int DnsQuery(string name, ushort type, uint options, nint servers, out nint records, nint reserved);
    [DllImport("dnsapi.dll", ExactSpelling = true)]
    private static extern void DnsRecordListFree(nint records, int freeType);
}
