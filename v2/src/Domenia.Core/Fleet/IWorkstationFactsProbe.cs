using Domenia.Core.Accueil;

namespace Domenia.Core;

public sealed record WorkstationInventoryRead(InventoryMeasure Inventory, MachineFacts Facts);

/// <summary>One bounded light inventory, including its console and BIOS observations.</summary>
public interface IWorkstationFactsProbe : IWorkstationProbe
{
    Task<WorkstationInventoryRead> ReadFactsAsync(string host, TimeSpan timeout, CancellationToken cancellationToken);
}
