using System.Collections.Immutable;
using System.Globalization;

namespace Domenia.Core.Poste;

/// <summary>One line of the inventory grid: category, item, raw value (tip, copy, export) and its French label.</summary>
public sealed record InventoryRow(string Category, string Item, string Value, string Label);

/// <summary>One line of the access report (DgInventoryAccess) with its wording and tone.</summary>
public sealed record AccessRow(string Category, SourceStatus Status, string StatusLabel, Tone Tone, string Detail, int DurationMs, int Items, string Transport);

/// <summary>One category of the filter with its number of lines and its read status.</summary>
public sealed record InventoryCategory(string Name, int Rows, SourceStatus Status, string StatusLabel);

/// <summary>Result of poste.inventory: the rows, the access report, the board rebuilt from it and the text report to copy.</summary>
public sealed record InventoryResult(
    string Computer,
    DateTimeOffset CollectedAt,
    bool Deep,
    string ModeLabel,
    int DurationMs,
    string Transport,
    string Summary,
    string AgeText,
    string Origin,
    ImmutableArray<AccessRow> Access,
    ImmutableArray<InventoryCategory> Categories,
    ImmutableArray<InventoryRow> Rows,
    PosteBoard Board,
    string Report,
    bool Partial,
    string? Notice,
    string? NoticeAction);

/// <summary>
/// The inventory grid of Domenia 1 (Get-DomeniaInventoryValueText, Apply-DomeniaInventoryFilter, Get-DomeniaInventoryReportText):
/// one line per item, CIM codes translated with the raw value kept, categories in reading order. Pure.
/// </summary>
public static class InventoryRows
{
    /// <summary>Action the page offers with a notice: grant the single fallback read (CIM refused).</summary>
    public const string FallbackAction = "readFallback";

    public static InventoryResult Build(InventorySnapshot inv, PosteBoard board, string origin, DateTimeOffset now, TimeZoneInfo zone, string? notice = null, string? noticeAction = null)
    {
        ArgumentNullException.ThrowIfNull(inv);
        ArgumentNullException.ThrowIfNull(board);
        ArgumentNullException.ThrowIfNull(zone);
        var rows = Rows(inv, zone).Where(r => inv.Read(r.Category) || inv.StatusOf(r.Category) == SourceStatus.Skipped).ToImmutableArray();
        var access = inv.Access.Select(a => new AccessRow(a.Category, a.Status, PosteLabels.SourceStatusLabel(a.Status), PosteLabels.SourceStatusTone(a.Status), a.Detail, a.DurationMs, a.Items, PosteLabels.TransportLabel(a.Transport))).ToImmutableArray();
        var categories = inv.Access.Select(a => new InventoryCategory(a.Category, rows.Count(r => r.Category == a.Category), a.Status, PosteLabels.SourceStatusLabel(a.Status))).ToImmutableArray();
        var read = inv.Access.Count(a => a.Status is SourceStatus.Ok or SourceStatus.Empty or SourceStatus.Partial);
        var refused = inv.Access.Count(a => a.Status is SourceStatus.Refused);
        var mode = inv.Deep ? "Inventaire complet" : "Inventaire rapide";
        var summary = mode + " · " + FrenchText.Count(read, "source lue", "sources lues") + " sur " + FrenchText.Integer(inv.Access.Length)
            + (refused > 0 ? ", " + FrenchText.Count(refused, "refusée", "refusées") : "") + " · " + FrenchText.Decimal(inv.DurationMs / 1000d, 1) + " s par " + PosteLabels.TransportLabel(inv.Transport)
            + " · " + FrenchText.Count(rows.Length, "ligne", "lignes") + ".";
        var age = "Inventaire " + PosteText.Age(inv.CollectedAt, now) + " (" + PosteText.LocalDateTime(inv.CollectedAt, zone) + ")";
        var report = mode + " de " + inv.Computer + " · " + PosteText.LocalDateTime(inv.CollectedAt, zone) + Environment.NewLine
            + string.Join(Environment.NewLine, rows.Select(r => r.Category + "\t" + r.Item + "\t" + r.Label + (r.Label != r.Value ? " [" + r.Value + "]" : "")));
        var interrupted = inv.Access.Where(a => a.Status == SourceStatus.Interrupted).ToList();
        if (notice is null && interrupted.Count > 0)
        {
            // Partial result rather than loss (Domenia 1 PST-037): what was read is kept, the rest is said.
            notice = "Résultat partiel : " + interrupted[0].Detail + ". " + FrenchText.Count(read, "source lue gardée", "sources lues gardées") + ", "
                + FrenchText.Count(interrupted.Count, "source non lue", "sources non lues") + " (" + string.Join(", ", interrupted.Take(4).Select(a => a.Category)) + (interrupted.Count > 4 ? "…" : "") + ").";
        }
        return new InventoryResult(inv.Computer, inv.CollectedAt, inv.Deep, mode, inv.DurationMs, PosteLabels.TransportLabel(inv.Transport), summary, age, origin, access, categories, rows, board, report,
            interrupted.Count > 0, notice, noticeAction);
    }

    private static IEnumerable<InventoryRow> Rows(InventorySnapshot d, TimeZoneInfo zone)
    {
        static InventoryRow R(string category, string item, string? value, string? label = null) => new(category, item, value ?? "", label ?? value ?? "");
        static string Num(long? v) => v is long n ? n.ToString(CultureInfo.InvariantCulture) : "";
        var date = (DateTimeOffset? at) => at is DateTimeOffset t ? PosteText.LocalDateTime(t, zone) : "";

        if (d.Os is { } os)
        {
            yield return R(InventoryCategories.System, "Système", os.Caption);
            yield return R(InventoryCategories.System, "Version", os.Version + " (build " + os.Build + (os.Revision is int rev ? "." + rev.ToString(CultureInfo.InvariantCulture) : "") + ")");
            yield return R(InventoryCategories.System, "Architecture", os.Architecture);
            if (os.Language is int lang)
            {
                yield return R(InventoryCategories.System, "Langue", lang.ToString(CultureInfo.InvariantCulture), PosteLabels.Language(lang));
            }
            yield return R(InventoryCategories.System, "Installé le", date(os.InstallDate));
            yield return R(InventoryCategories.System, "Dernier démarrage", date(os.LastBoot));
            if (os.DomainRole is int role)
            {
                yield return R(InventoryCategories.System, "Rôle dans le domaine", role.ToString(CultureInfo.InvariantCulture), PosteLabels.DomainRole(role));
            }
            yield return R(InventoryCategories.System, "Domaine", os.Domain);
        }
        if (d.Bios is { } bios)
        {
            yield return R(InventoryCategories.Bios, "Version", bios.Version);
            yield return R(InventoryCategories.Bios, "Date", bios.ReleaseDate is DateTimeOffset r ? PosteText.LocalDate(r, zone) : "");
            yield return R(InventoryCategories.Bios, "SMBIOS", bios.SmbiosVersion);
            yield return R(InventoryCategories.Bios, "Micrologiciel", bios.Firmware);
        }
        if (d.SecureBoot is { } sb)
        {
            yield return R(InventoryCategories.Bios, "Secure Boot", sb.Enabled?.ToString(CultureInfo.InvariantCulture) ?? "", sb.Enabled switch { true => "Activé", false => "Désactivé", _ => "Non mesuré" });
        }
        if (d.System is { } sys)
        {
            yield return R(InventoryCategories.Board, "Fabricant", sys.Manufacturer);
            yield return R(InventoryCategories.Board, "Modèle", sys.Model);
            yield return R(InventoryCategories.Board, "Numéro de série", sys.SerialNumber);
            yield return R(InventoryCategories.Board, "Type de châssis", string.Join(", ", sys.ChassisTypes.Select(c => c.ToString(CultureInfo.InvariantCulture))), PosteLabels.ChassisText(sys.ChassisTypes));
        }
        foreach (var cpu in d.Processors)
        {
            yield return R(InventoryCategories.Processor, "Modèle", cpu.Name.Trim());
            yield return R(InventoryCategories.Processor, "Cœurs / processeurs logiques", (cpu.Cores ?? 0).ToString(CultureInfo.InvariantCulture) + " / " + (cpu.LogicalProcessors ?? 0).ToString(CultureInfo.InvariantCulture));
            yield return R(InventoryCategories.Processor, "Fréquence maximale", cpu.MaxClockMhz is int mhz ? mhz.ToString(CultureInfo.InvariantCulture) : "", cpu.MaxClockMhz is int m ? FrenchText.Integer(m) + " MHz" : "");
        }
        foreach (var module in d.MemoryModules)
        {
            yield return R(InventoryCategories.Memory, module.Slot, Num(module.CapacityBytes), (module.CapacityBytes is long c ? PosteText.Size(c) : "capacité non déclarée") + (module.SpeedMhz is int s ? " · " + FrenchText.Integer(s) + " MHz" : "") + (module.Manufacturer is null ? "" : " · " + module.Manufacturer));
        }
        if (d.Memory is { VisibleKb: long visible })
        {
            yield return R(InventoryCategories.Memory, "Mémoire visible", Num(visible), PosteText.Size(visible * 1024d));
        }
        foreach (var v in d.Volumes)
        {
            var pct = v.SizeBytes is > 0 && v.FreeBytes is long f ? 100d * f / v.SizeBytes.Value : (double?)null;
            yield return R(InventoryCategories.Volumes, v.Id + (string.IsNullOrWhiteSpace(v.Label) ? "" : " (" + v.Label + ")"), Num(v.FreeBytes) + "/" + Num(v.SizeBytes),
                (v.FreeBytes is long fb ? PosteText.Size(fb) : "—") + " libres sur " + (v.SizeBytes is long sb2 ? PosteText.Size(sb2) : "—") + (pct is double p ? " (" + FrenchText.Percent(p) + ")" : "") + (v.FileSystem is null ? "" : " · " + v.FileSystem));
        }
        foreach (var disk in d.PhysicalDisks)
        {
            yield return R(InventoryCategories.PhysicalDisks, disk.Name, PosteLabels.MediaType(disk.MediaType) + ", " + PosteLabels.BusType(disk.BusType) + (disk.SizeBytes is long s ? ", " + PosteText.Size(s) : ""));
            if (disk.SmartStatus is not null)
            {
                yield return R(InventoryCategories.PhysicalDisks, disk.Name + " · état SMART", disk.SmartStatus, PosteLabels.SmartStatus(disk.SmartStatus));
            }
        }
        foreach (var v in d.BitLocker)
        {
            yield return R(InventoryCategories.BitLocker, "Volume " + v.Drive + " · protection", v.Protection?.ToString(CultureInfo.InvariantCulture) ?? "", v.Protection switch { 1 => "Protégé", 0 => "Non protégé (ou suspendu)", _ => "Inconnu" });
            if (v.Method is int method)
            {
                yield return R(InventoryCategories.BitLocker, "Volume " + v.Drive + " · méthode", method.ToString(CultureInfo.InvariantCulture), PosteLabels.BitLockerMethod(method));
            }
        }
        if (d.Tpm is { } tpm)
        {
            yield return R(InventoryCategories.Tpm, "Spécification", tpm.Specification);
            yield return R(InventoryCategories.Tpm, "Activé / opérationnel", (tpm.Enabled?.ToString(CultureInfo.InvariantCulture) ?? "?") + " / " + (tpm.Activated?.ToString(CultureInfo.InvariantCulture) ?? "?"),
                (tpm.Enabled == true ? "Activé" : "Non activé") + " / " + (tpm.Activated == true ? "opérationnel" : "non opérationnel"));
        }
        foreach (var n in d.Network.Where(n => n.Physical || n.Ipv4.Length > 0))
        {
            var raw = (n.Status?.ToString(CultureInfo.InvariantCulture) ?? "") + (n.SpeedBitsPerSecond is long sp ? ", " + (sp / 1_000_000).ToString(CultureInfo.InvariantCulture) + " Mb/s" : "");
            yield return R(InventoryCategories.Network, n.Name, raw, PosteLabels.Adapter(n.Status, n.SpeedBitsPerSecond) + (n.Ipv4.IsEmpty ? "" : " · " + string.Join(", ", n.Ipv4)) + (n.Mac is null ? "" : " · " + n.Mac));
        }
        foreach (var p in d.Firewall)
        {
            var effective = p.PolicyEnabled ?? p.LocalEnabled;
            yield return R(InventoryCategories.Firewall, "Profil " + p.Name, effective?.ToString(CultureInfo.InvariantCulture) ?? "", effective switch { true => "Activé", false => "Désactivé", _ => "Inconnu" } + (p.PolicyEnabled is null ? " (local)" : " (stratégie)"));
        }
        foreach (var av in d.Antivirus)
        {
            var (enabled, upToDate) = PosteLabels.AntivirusState(av.ProductState);
            yield return R(InventoryCategories.Antivirus, av.Name, av.ProductState?.ToString(CultureInfo.InvariantCulture) ?? "", (enabled == true ? "Actif" : "Inactif ou inconnu") + (upToDate == true ? ", signatures à jour" : ""));
        }
        foreach (var h in d.Hotfixes.OrderByDescending(h => h.InstalledOn).Take(30))
        {
            yield return R(InventoryCategories.Hotfixes, h.Id, h.InstalledOn is DateTimeOffset at ? at.ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture) : "", (h.Description ?? "Correctif") + (h.InstalledOn is DateTimeOffset at2 ? " · " + PosteText.LocalDate(at2, zone) : ""));
        }
        if (d.Updates is { } u)
        {
            yield return R(InventoryCategories.Updates, "Serveur WSUS", u.WsusServer ?? "", u.WsusServer is null ? "Aucun (Windows Update)" : u.WsusServer + (u.UseWsus == true ? "" : " (non appliqué)"));
            yield return R(InventoryCategories.Updates, "Dernière réussite", date(u.LastSuccess));
        }
        foreach (var s in d.Software.Take(400))
        {
            yield return R(InventoryCategories.Software, s.Name, s.Version);
        }
        foreach (var s in d.Startup)
        {
            yield return R(InventoryCategories.Startup, s.Name, s.Executable, s.Executable + " · " + s.Location);
        }
        foreach (var s in d.Services.Where(s => s.StartMode == "Auto" && s.State == "Stopped"))
        {
            var expected = PosteServices.StopExpected(s.Name, out _);
            yield return R(InventoryCategories.Services, s.DisplayName, s.Name, "Automatique arrêté" + (expected ? " (attendu : déclencheur ou différé)" : ""));
        }
        foreach (var dev in d.Devices)
        {
            yield return R(InventoryCategories.Devices, dev.Name, dev.Code.ToString(CultureInfo.InvariantCulture), PosteLabels.DeviceError(dev.Code));
        }
        foreach (var disp in d.Displays)
        {
            yield return R(InventoryCategories.Displays, disp.Name, disp.Connection, (disp.Internal switch { true => "Interne", false => "Externe", _ => "Raccordement non déterminé" }) + " · " + disp.Connection + (disp.Year is int y ? " · " + y.ToString(CultureInfo.InvariantCulture) : ""));
        }
        foreach (var b in d.Batteries)
        {
            yield return R(InventoryCategories.Batteries, b.Name, b.ChargePercent?.ToString(CultureInfo.InvariantCulture) ?? "", (b.ChargePercent is int c ? FrenchText.Integer(c) + " %" : "charge non renseignée") + (b.Status is int st ? " · " + PosteLabels.BatteryStatus(st) : ""));
        }
        foreach (var drv in d.UnsignedDrivers)
        {
            yield return R(InventoryCategories.Drivers, drv.Name, drv.Version, (drv.Provider ?? "éditeur inconnu") + (drv.Version is null ? "" : " · " + drv.Version));
        }
        foreach (var s in d.Sessions.Where(s => !string.IsNullOrEmpty(s.User)))
        {
            yield return R(InventoryCategories.Sessions, s.Domain + "\\" + s.User, s.Protocol, s.Protocol + " · " + s.State);
        }
        foreach (var a in d.LocalAdmins)
        {
            yield return R(InventoryCategories.Admins, a, a);
        }
        foreach (var s in d.Shares)
        {
            yield return R(InventoryCategories.Shares, s.Name, s.Path, s.Path + (s.Description is null ? "" : " · " + s.Description));
        }
        foreach (var p in d.Printers)
        {
            yield return R(InventoryCategories.Printers, p.Name, p.Port, (p.Network switch { true => "Réseau", false => "Locale", _ => "Portée non lue" }) + (p.Default == true ? " · par défaut" : "") + (p.Offline == true ? " · hors ligne" : "") + (p.Error == true ? " · en erreur" : "") + (p.Offline is null || p.Error is null ? " · état incomplet" : ""));
        }
        if (d.PendingReboot is { } reboot)
        {
            yield return R(InventoryCategories.Reboot, "Obligation confirmée", string.Join(", ", reboot.Confirmed), reboot.Confirmed.IsEmpty ? "Aucune" : string.Join(", ", reboot.Confirmed));
            if (!reboot.Partial.IsEmpty)
            {
                yield return R(InventoryCategories.Reboot, "Indices partiels", string.Join(", ", reboot.Partial));
            }
        }
        if (d.Site is not null)
        {
            yield return R(InventoryCategories.Site, "Site AD", d.Site);
        }
        yield return R(InventoryCategories.Site, "Proxy", d.Proxy ?? "", d.Proxy ?? "Aucun proxy déclaré");
        foreach (var p in d.Processes.OrderByDescending(p => p.WorkingSetBytes).Take(40))
        {
            yield return R(InventoryCategories.Processes, p.Name + " (" + p.Id.ToString(CultureInfo.InvariantCulture) + ")", Num(p.WorkingSetBytes), p.WorkingSetBytes is long ws ? PosteText.Size(ws) : "");
        }
        foreach (var e in d.SystemEvents.OrderByDescending(e => e.At).Take(60))
        {
            yield return R(InventoryCategories.Events, e.Provider + " " + e.Id.ToString(CultureInfo.InvariantCulture), e.Level, e.Level + " · " + PosteText.LocalDateTime(e.At, zone) + " · " + PosteText.Flat(e.Message, 160));
        }
        foreach (var t in d.Tasks)
        {
            var result = PosteLabels.TaskResult(t.LastResult);
            var raw = t.State + (result.Code.Length > 0 ? ", resultat " + result.Code : "");
            yield return R(InventoryCategories.Tasks, t.Path + t.Name, raw, t.State + (result.Code.Length > 0 ? ", résultat " + result.Code + " (" + result.Text + ")" : ""));
        }
        foreach (var c in d.Certificates)
        {
            yield return R(InventoryCategories.Certificates, c.Subject, c.NotAfter.ToString("yyyy'-'MM'-'dd", CultureInfo.InvariantCulture), "Expire le " + PosteText.LocalDate(c.NotAfter, zone) + " · " + c.Issuer);
        }
        foreach (var c in d.Connections.Take(60))
        {
            yield return R(InventoryCategories.Connections, c.Protocol + " " + c.Local, c.Remote, c.Remote + " · " + c.State + (c.Process is null ? "" : " · " + c.Process));
        }
    }
}
