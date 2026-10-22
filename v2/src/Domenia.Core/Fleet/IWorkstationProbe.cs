namespace Domenia.Core;

/// <summary>
/// Light measures of one workstation in directory mode (Domenia 1 ParkPing and ParkSweep): presence by one ICMP echo, then the
/// light inventory (system disk, last boot, model, memory, system) by WMI. Read only: a probe never changes a workstation, and
/// an unanswered read is « no reading », never a verdict. Implemented by Domenia.Inventory; the simulation never uses it.
/// </summary>
public interface IWorkstationProbe
{
    /// <summary>True when the workstation answers one echo within <paramref name="timeout"/>.</summary>
    Task<bool> PingAsync(string host, TimeSpan timeout, CancellationToken cancellationToken);

    /// <summary>The light inventory; <see cref="MeasureState.Refused"/> or <see cref="MeasureState.NotRead"/> when WMI does not answer.</summary>
    Task<InventoryMeasure> ReadInventoryAsync(string host, TimeSpan timeout, CancellationToken cancellationToken);
}
