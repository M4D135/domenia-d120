using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Bounded, value-free correlation of one logical read and its physical LDAP requests.</summary>
internal sealed class AdReadDiagnostics : IDisposable
{
    private static readonly AsyncLocal<AdReadDiagnostics?> Current = new();
    private readonly AdReadDiagnostics? previous;
    private readonly Counters counters;
    private readonly string stage;
    private bool disposed;

    private AdReadDiagnostics(string stage, bool retainStage)
    {
        previous = Current.Value;
        counters = previous?.counters ?? new Counters();
        this.stage = retainStage && previous is not null ? previous.stage : stage;
        Current.Value = this;
    }

    internal static AdReadDiagnostics Begin(string stage, bool retainStage = false) => new(stage, retainStage);
    internal static void Sent() { if (Current.Value is { } scope) { Interlocked.Increment(ref scope.counters.Requests); } }

    internal static DomeniaOperationException Refuse(string category, string? attribute = null,
        int? requestedStart = null, int? requestedEnd = null, int? receivedStart = null, int? receivedEnd = null,
        bool terminal = false, int? count = null, int? total = null, int? maximum = null,
        bool? guidPresent = null, bool? versionPresent = null)
    {
        var scope = Current.Value;
        var name = FicheAttributeRules.IsValidName(attribute) && !FicheAttributeRules.IsSensitive(attribute) ? attribute : "non-identifié";
        static string Number(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "?";
        static string Flag(bool? value) => value is null ? "?" : value.Value ? "présent" : "absent";
        var detail = "op=" + (scope?.counters.Id ?? "hors-opération") + "; étape=" + (scope?.stage ?? "matérialisation")
            + "; attribut=" + name + "; cause=" + category
            + "; demandé=" + Number(requestedStart) + "-" + Number(requestedEnd)
            + "; reçu=" + Number(receivedStart) + "-" + (terminal ? "*" : Number(receivedEnd))
            + "; valeurs=" + Number(count) + "; cumul=" + Number(total) + "; limite=" + Number(maximum)
            + "; GUID=" + Flag(guidPresent) + "; USN=" + Flag(versionPresent)
            + "; requêtes-envoyées=" + Number(scope is null ? null : Volatile.Read(ref scope.counters.Requests))
            + "; reprise-automatique=0";
        // One failing materialization aborts its read. The cap also protects callers which inspect several failures.
        if (scope is null || Interlocked.Increment(ref scope.counters.Events) <= 16) { AdConnection.TraceRead(detail); }
        return new(DomeniaErrors.SourceUnavailable,
            "Lecture LDAP refusée : attribut incomplet ou incohérent. Les données précédentes sont conservées ; corrigez la cause puis relancez explicitement. Détail : " + detail + ".");
    }

    public void Dispose()
    {
        if (disposed) { return; }
        disposed = true;
        Current.Value = previous;
    }

    private sealed class Counters
    {
        internal string Id { get; } = Guid.NewGuid().ToString("N");
        internal int Requests;
        internal int Events;
    }
}
