using Domenia.Core.Accueil;

namespace Domenia.Core;

public sealed record WorkstationInventoryRead(InventoryMeasure Inventory, MachineFacts Facts)
{
    public string? ReportedName { get; init; }
    public bool AuthenticationRejected { get; init; }
}

public interface ICredentialWorkstationFactsProbe : IWorkstationFactsProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential);
}

/// <summary>The native probe also observes the remote transports explicitly enabled by configuration.</summary>
public interface IConfiguredWorkstationFactsProbe : ICredentialWorkstationFactsProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken, RemoteProbeCredential? credential, Poste.PosteConfiguration? configuration);
}

/// <summary>One bounded light inventory, including its console and BIOS observations.</summary>
public interface IWorkstationFactsProbe : IWorkstationProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken);
}
