using System.Collections.Immutable;

namespace Domenia.Core.Accueil;

/// <summary>
/// State of the machine around an explicit OU refresh, read by the service just before the plan and the run (ACC-001): widget
/// measures and BitLocker reads in progress, failures of the local writes, and the free space of the volume that holds the data
/// of Domenia (null: not measured, nothing is blocked and nothing is claimed).
/// </summary>
public sealed record RefreshAdmission(
    bool Simulation,
    int Measuring,
    bool BitLockerReading,
    int LocalWriteFailures,
    long? FreeBytes);

/// <summary>
/// Pure rules of the explicit OU refresh (Domenia 1, Invoke-DomeniaOuRefresh, Get-DomeniaStorageCollectionRefusal,
/// New-DomeniaCollectionPlan): admission of a new collection, and « collecter seulement ce qui manque » (ACC-038).
/// </summary>
public static class RefreshRules
{
    /// <summary>Error code of a refused refresh; the message says why and that nothing was launched.</summary>
    public const string Refused = "refresh.refused";

    /// <summary>Age under which a usable reading is reused by a collection (decision of David, 14/10/2026: 30 days).</summary>
    public const int ReuseDays = 30;

    /// <summary>New collections stop under this free space (512 Mio, point 35), so that collected data can still be written.</summary>
    public const long SuspendBytes = 512L * 1024 * 1024;

    /// <summary>Under this free space even the local writes are refused (32 Mio, point 35).</summary>
    public const long CriticalBytes = 32L * 1024 * 1024;

    /// <summary>Local writes failing in a row before new collections are suspended (Domenia 1: three failures).</summary>
    public const int MaxLocalWriteFailures = 3;

    /// <summary>A reading dated more than this ahead of the clock is never trusted (Test-DomeniaParkTargetAnswered).</summary>
    public static readonly TimeSpan FutureTolerance = TimeSpan.FromMinutes(1);

    /// <summary>
    /// The sentence that refuses a new collection, or null when it may start. The free space only counts in directory mode: in
    /// simulation nothing is written on the disk by a refresh.
    /// </summary>
    public static string? Refusal(RefreshAdmission admission)
    {
        ArgumentNullException.ThrowIfNull(admission);
        if (admission.Measuring > 0)
        {
            return "Une mesure de widget est en cours" + FrenchText.Colon + "attendez sa fin avant d’actualiser l’OU. Rien n’a été lancé.";
        }
        if (admission.BitLockerReading)
        {
            return "Une lecture AD de la présence BitLocker est en cours" + FrenchText.Colon + "attendez sa fin avant d’actualiser l’OU. Rien n’a été lancé.";
        }
        if (admission.LocalWriteFailures >= MaxLocalWriteFailures)
        {
            return "Enregistrement local suspendu après " + FrenchText.Integer(admission.LocalWriteFailures) + " échecs d’écriture des préférences de Domenia"
                + FrenchText.Colon + "nouvelles collectes suspendues. Libérez le dossier de données (antivirus, droits, disque) puis réessayez. Rien n’a été lancé.";
        }
        if (!admission.Simulation && admission.FreeBytes is long free)
        {
            if (free < CriticalBytes)
            {
                return "Espace disque critique sur le volume des données de Domenia" + FrenchText.Colon + Size(free) + " libres. Écritures locales refusées sous "
                    + Size(CriticalBytes) + " et nouvelles collectes suspendues. Libérez de la place puis réessayez. Rien n’a été lancé.";
            }
            if (free < SuspendBytes)
            {
                return "Espace disque insuffisant sur le volume des données de Domenia" + FrenchText.Colon + Size(free) + " libres. Nouvelles collectes suspendues sous "
                    + Size(SuspendBytes) + " ; ce qui est déjà relevé reste enregistré. Libérez de la place puis réessayez. Rien n’a été lancé.";
            }
        }
        return null;
    }

    /// <summary>
    /// True when the inventory of a workstation needs no new read: a usable reading (no error, not refused) dated on or after
    /// <paramref name="since"/> and not in the future. A null <paramref name="since"/> is a forced read: nothing is reused.
    /// </summary>
    public static bool InventoryAnswered(InventoryMeasure? inventory, DateTimeOffset? since, DateTimeOffset now) =>
        since is DateTimeOffset from && inventory is { HasReading: true, CheckedAt: DateTimeOffset at } && at >= from && at <= now + FutureTolerance;

    /// <summary>Same rule for one probe reading: a known value, dated on or after <paramref name="since"/>; errors are always read again.</summary>
    public static bool ProbeAnswered(ProbeReading? reading, DateTimeOffset? since, DateTimeOffset now) =>
        since is DateTimeOffset from && reading is { State: MeasureState.Known, At: DateTimeOffset at } && at >= from && at <= now + FutureTolerance;

    /// <summary>
    /// Workstations of <paramref name="online"/> that must be contacted (ACC-038): the inventory or one probe of the plan is missing,
    /// in error, or older than <paramref name="since"/>. The others are « déjà à jour, non contactés ». Order is kept.
    /// </summary>
    public static ImmutableArray<Guid> Missing(
        IEnumerable<Guid> online,
        IReadOnlyDictionary<Guid, WorkstationObservation> observations,
        ProbeReadings probes,
        ImmutableArray<string> probeIds,
        DateTimeOffset? since,
        DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(online);
        ArgumentNullException.ThrowIfNull(observations);
        ArgumentNullException.ThrowIfNull(probes);
        var result = ImmutableArray.CreateBuilder<Guid>();
        foreach (var guid in online.Distinct())
        {
            var inventory = observations.TryGetValue(guid, out var o) ? o.Inventory : null;
            var answered = InventoryAnswered(inventory, since, now)
                && probeIds.All(id => ProbeAnswered(probes.ByProbe.GetValueOrDefault(id)?.GetValueOrDefault(guid), since, now));
            if (!answered)
            {
                result.Add(guid);
            }
        }
        return result.ToImmutable();
    }

    /// <summary>Size in Mio or Gio with a French decimal comma (Format-DomeniaSize).</summary>
    public static string Size(long bytes)
    {
        const double Mio = 1024d * 1024;
        return bytes >= 1024L * 1024 * 1024
            ? FrenchText.Decimal(bytes / (Mio * 1024)) + FrenchText.Nbsp + "Go"
            : FrenchText.Integer((long)Math.Round(bytes / Mio)) + FrenchText.Nbsp + "Mo";
    }
}
