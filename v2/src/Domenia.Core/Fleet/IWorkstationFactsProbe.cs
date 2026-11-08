using Domenia.Core.Accueil;

namespace Domenia.Core;

public sealed record WorkstationInventoryRead(InventoryMeasure Inventory, MachineFacts Facts)
{
    public string? ReportedName { get; init; }
    public NativeWorkstationIdentity? HostIdentity { get; init; }
    public bool AuthenticationRejected { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public CollectionReadFailure RetryFailure { get; init; }
    [System.Text.Json.Serialization.JsonIgnore]
    public bool ReadPhysicallyCompleted { get; init; }
}

public interface ICredentialWorkstationFactsProbe : IWorkstationFactsProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential);
}

/// <summary>The native probe also observes the remote transports explicitly enabled by configuration.</summary>
public interface IConfiguredWorkstationFactsProbe : ICredentialWorkstationFactsProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential, Poste.PosteConfiguration? configuration);

    /// <summary>A campaign may retain incomplete values after cancellation, then commit them locally before
    /// propagating the cancellation. Native implementations must await their physical worker in either mode.</summary>
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken,
        RemoteProbeCredential? credential, Poste.PosteConfiguration? configuration, bool retainPartialOnCancellation) =>
        ReadFactsAsync(host, timeout, cancellationToken, credential, configuration);
}

/// <summary>One bounded light inventory, including its console and BIOS observations.</summary>
public interface IWorkstationFactsProbe : IWorkstationProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken);
}
