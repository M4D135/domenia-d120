namespace Domenia.Core;

public enum DirectoryAvailabilityState { Unknown, Online, Slow, Offline }
public enum DirectoryReadObservation { Success, Timeout, Unavailable, Neutral }
public sealed record DirectoryAvailabilitySnapshot(DirectoryAvailabilityState State, DateTimeOffset? ObservedAt,
    DateTimeOffset? LastDisruptionAt, long Revision, string Notice)
{
    public static DirectoryAvailabilitySnapshot Unknown { get; } = new(DirectoryAvailabilityState.Unknown, null, null, 0,
        "Disponibilité non observée ; aucune sonde supplémentaire n’est lancée.");
}

/// <summary>Only finished native directory requests provide evidence. Cancellation, cache, admission and elapsed wall
/// time alone change nothing. Recovery restores availability but never erases the disruption revision used by fiche caches.</summary>
public sealed class DirectoryAvailability(TimeProvider clock)
{
    private readonly Lock gate = new();
    private DirectoryAvailabilitySnapshot state = DirectoryAvailabilitySnapshot.Unknown;
    public DirectoryAvailabilitySnapshot Snapshot { get { lock (gate) return state; } }
    public void Observe(DirectoryReadObservation observation, bool cancelled = false)
    {
        if (cancelled || observation == DirectoryReadObservation.Neutral) return;
        var at = clock.GetUtcNow();
        lock (gate)
        {
            var status = observation switch
            {
                DirectoryReadObservation.Success => DirectoryAvailabilityState.Online,
                DirectoryReadObservation.Timeout => DirectoryAvailabilityState.Slow,
                DirectoryReadObservation.Unavailable => DirectoryAvailabilityState.Offline,
                _ => throw new ArgumentOutOfRangeException(nameof(observation)),
            };
            var disrupted = status is DirectoryAvailabilityState.Slow or DirectoryAvailabilityState.Offline;
            state = new(status, at, disrupted ? at : state.LastDisruptionAt, disrupted ? checked(state.Revision + 1) : state.Revision,
                status switch
                {
                    DirectoryAvailabilityState.Online => state.Revision == 0 ? "Une requête annuaire a répondu."
                        : "Une requête annuaire a répondu à nouveau. Les anciennes fiches restent à relire avant modification.",
                    DirectoryAvailabilityState.Slow => "Le délai d’une requête annuaire a été dépassé ; ce n’est pas une preuve de panne réseau. Les fiches en cache restent consultables.",
                    _ => "Une requête annuaire a constaté l’indisponibilité du service. Données conservées ; aucune reconnexion ni collecte automatique.",
                });
        }
    }
}
