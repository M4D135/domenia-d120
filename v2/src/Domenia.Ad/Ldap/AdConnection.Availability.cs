using Domenia.Core;

namespace Domenia.Ad;

public interface IAdReachability
{
    DirectoryAvailabilitySnapshot Availability { get; }
}

public sealed partial class AdConnection : IAdReachability
{
    private DirectoryAvailability availability = new(TimeProvider.System);
    public DirectoryAvailabilitySnapshot Availability => availability.Snapshot;

    internal static DirectoryReadObservation ReachabilityOf(Exception? error) => error is null ? DirectoryReadObservation.Success
        : error is OperationCanceledException ? DirectoryReadObservation.Neutral
        : GetErrorCode(error) switch
        {
            3 or 51 or 85 => DirectoryReadObservation.Timeout,
            52 or 81 or 91 => DirectoryReadObservation.Unavailable,
            _ => error is TimeoutException ? DirectoryReadObservation.Timeout : DirectoryReadObservation.Neutral,
        };

    internal void ObserveReadCompletion(Exception? error, CancellationToken token) => availability.Observe(ReachabilityOf(error), token.IsCancellationRequested);
}
