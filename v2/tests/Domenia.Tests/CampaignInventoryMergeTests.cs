using Domenia.Ad;
using Domenia.Core;

namespace Domenia.Tests;

internal static class CampaignInventoryMergeTests
{
    [Test]
    public static void Partial_fallback_complements_direct_fields_without_erasing_or_redating_them()
    {
        var pc = Fixtures.Computer("PC1"); var oldAt = Fixtures.Now.AddMinutes(-3);
        var direct = new WorkstationInventoryRead(new(MeasureState.Incomplete, oldAt, null, null, null, "Direct model", 16L << 30, null, null),
            new(@"TEST\alice", oldAt, "Direct BIOS", oldAt, MeasureState.Incomplete, oldAt, "Disque indisponible"))
        { ReportedName = pc.Name, HostIdentity = new(pc.DnsHostName!, pc.Name, pc.Name, "test.local"), ReadPhysicallyCompleted = true };
        var fallback = new WorkstationInventoryRead(new(MeasureState.Incomplete, Fixtures.Now, 100, 40, Fixtures.Now.AddDays(-2), null, null, "Windows", "26100"),
            new(null, null, null, null, MeasureState.Incomplete, Fixtures.Now, "BIOS indisponible"))
        { ReportedName = pc.Name, HostIdentity = new(pc.DnsHostName!, pc.Name, pc.Name, "test.local"), ReadPhysicallyCompleted = true };
        var merged = CampaignInventoryMerge.Combine(pc, direct, fallback);
        Check.Equal("Direct model", merged.Inventory.Model, "modèle direct non effacé"); Check.Equal(16L << 30, merged.Inventory.MemoryBytes, "RAM directe conservée");
        Check.Equal(40L, merged.Inventory.SystemDiskFreeBytes, "donnée complémentaire du programme conservée");
        Check.Equal(oldAt, merged.Inventory.CheckedAt, "pas de rajeunissement des données conservées");
        Check.Equal(MeasureState.Incomplete, merged.Inventory.State, "deux lectures partielles ne fabriquent pas un succès complet");
        Check.Equal("Direct BIOS", merged.Facts.BiosVersion, "BIOS direct conservé"); Check.Equal(oldAt, merged.Facts.BiosAt, "date BIOS réelle");
        Check.Equal(@"TEST\alice", merged.Facts.ConsoleUser, "console directe conservée"); Check.Equal(oldAt, merged.Facts.ConsoleAt, "date console réelle");
        Check.Equal(Fixtures.Now, merged.Facts.WmiAt, "dernière tentative distincte du contenu retenu");
        Check.Equal(direct, CampaignInventoryMerge.Combine(pc, direct, fallback with { ReportedName = "OTHER" }), "autre poste jamais fusionné");
        Check.Equal(fallback, CampaignInventoryMerge.Combine(pc, direct with { ReportedName = null }, fallback), "aucune donnée directe non identifiée ajoutée");
    }
}
