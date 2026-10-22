Écris `v2/src/Domenia.Inventory/WmiWorkstationProbe.cs` (espace de noms `Domenia.Inventory`) :
`public sealed class WmiWorkstationProbe : IWorkstationProbe` (interface du cœur fournie, à ne pas modifier), mesures
LÉGÈRES d'un poste en mode annuaire, en lecture seule, comme Domenia 1 (ParkPing puis ParkSweep) :

1. `PingAsync(host, timeout, ct)` : un seul écho ICMP (`System.Net.NetworkInformation.Ping.SendPingAsync(host, timeout)`),
   vrai si `IPStatus.Success` ; toute `PingException`/`SocketException` (nom inconnu, réseau) → faux ; annulation respectée
   (`WaitAsync(ct)`).
2. `ReadInventoryAsync(host, timeout, ct)` : WMI par `System.Management` (paquet déjà référencé), espace `\\host\root\cimv2`,
   `ConnectionOptions { Impersonation = ImpersonationLevel.Impersonate, Authentication = AuthenticationLevel.PacketPrivacy,
   Timeout = timeout }`, `EnumerationOptions { Timeout = timeout, ReturnImmediately = false, Rewindable = false }`.
   Requêtes WQL (lecture seule) :
   - `SELECT Caption, BuildNumber, LastBootUpTime, SystemDrive FROM Win32_OperatingSystem`
   - `SELECT Model, TotalPhysicalMemory FROM Win32_ComputerSystem`
   - `SELECT Size, FreeSpace FROM Win32_LogicalDisk WHERE DeviceID = '<SystemDrive>'` (C: si inconnu)
   Résultat : `new InventoryMeasure(MeasureState.Known, now, size, free, lastBoot, model, memory, caption, build)` ;
   une taille 0 ou illisible → null (jamais « disque plein ») ; LastBootUpTime au format CIM DMTF → `ManagementDateTimeConverter.ToDateTime`
   puis `DateTimeOffset` UTC. Accès refusé (`UnauthorizedAccessException`, `ManagementException` ErrorCode AccessDenied) →
   `InventoryMeasure.Unread with { State = MeasureState.Refused, CheckedAt = now }` ; injoignable, RPC indisponible
   (`COMException` 0x800706BA), délai → `InventoryMeasure.Unread with { CheckedAt = now }` (état NotRead). Tout le travail WMI
   (synchrone) tourne sur le pool (`Task.Run`) et la tâche est abandonnée au délai (`WaitAsync(timeout, ct)`), sans bloquer.
   Les objets `ManagementObject`, `ManagementObjectSearcher`, `ManagementObjectCollection` sont tous libérés (`using`).
   `now` vient d'un `TimeProvider` passé au constructeur (`public WmiWorkstationProbe(TimeProvider clock)`), défaut
   `TimeProvider.System` par un constructeur sans paramètre.
3. Une méthode interne statique testable `internal static long? Positive(object? value)` (null si ≤ 0 ou illisible).

Contraintes : aucun avertissement (CA1416 : la classe est Windows uniquement — le projet cible net10.0-windows, donc
c'est permis ; ajoute `[SupportedOSPlatform("windows")]` si nécessaire), `ConfigureAwait(false)`, `CultureInfo.InvariantCulture`,
jamais de `catch (Exception)` sans `#pragma warning disable CA1031` justifié en anglais. Aucun test.
