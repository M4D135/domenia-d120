using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAssistanceReader
{
    /// <summary>Already read AD metadata plus already stored observations. No credentials, native probes, name-to-GUID guesses or
    /// secret attributes. A missing LDAP expiration does not establish that LAPS is absent or that its password can be read.</summary>
    private (MachineSignals? Signals, ImmutableArray<SubjectFact> Facts, ImmutableArray<SubjectHit> Related) SubjectContext(
        object subject, DirectorySnapshot local, FleetObservations observations, DateTimeOffset now, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        MachineSignals? signals = null;
        var facts = ImmutableArray.CreateBuilder<SubjectFact>();
        if (subject is DirectoryComputer pc)
        {
            var matches = observations.Workstations.Where(o => o.ComputerGuid == pc.ObjectGuid).Take(2).ToArray();
            // Duplicate identity is ambiguous, not a choice of whichever reading happened to arrive first.
            var observation = matches.Length == 1 ? matches[0] : null;
            var measured = ObservedMachineSignals(pc, observation, now); signals = measured.Signals;
            var free = signals.SystemDiskFreePercent; var boot = signals.LastBootAt; var lapsExpiry = signals.LapsExpiration;
            facts.Add(new("Présence mémorisée", signals.LastPresenceAnswered is null ? "Non lue pour cette identité" : (signals.LastPresenceAnswered == true ? "Réponse le " : "Pas de réponse le ") + Date(signals.LastPresenceAt!.Value),
                signals.LastPresenceAnswered is null ? Tone.Off : signals.LastPresenceAnswered == true ? Tone.Info : Tone.Warn));
            facts.Add(new("Disque système mémorisé", free is { } percent ? FrenchText.Percent(percent) + " libre · " + Date(measured.InventoryAt!.Value) : "Non lu ou mesure incohérente",
                free is < 10 ? Tone.Alert : free is < 20 ? Tone.Warn : free is null ? Tone.Off : Tone.Info));
            facts.Add(new("Dernier démarrage mémorisé", boot is { } at ? Date(at) + " · relevé le " + Date(measured.InventoryAt!.Value) : "Non lu", boot is { } age && now - age > TimeSpan.FromDays(30) ? Tone.Warn : Tone.Off));
            facts.Add(new("Métadonnées LAPS", signals.LapsRotationRequested ? "Rotation demandée (expiration zéro) · secret non lu"
                : lapsExpiry is { } expiry ? "Expiration déclarée le " + Date(expiry) + " · secret non lu" : "Expiration non lue · absence non démontrée",
                signals.LapsRotationRequested || lapsExpiry is { } expired && expired <= now ? Tone.Warn : Tone.Off));
        }

        var subjectCreated = subject switch { DirectoryUser u => u.WhenCreated, DirectoryComputer c => c.WhenCreated, _ => DateTimeOffset.MaxValue };
        var uniqueIds = UniqueContextIds(local, token);
        bool Qualified(Guid id, string dn, DateTimeOffset created)
        {
            token.ThrowIfCancellationRequested();
            return uniqueIds.Contains(id) && ContextReadAt(local, id, created, now) is { } at && at >= subjectCreated && WithinContextDomain(dn, local.Domain.RootDn);
        }
        bool RelatedDn(string? left, string right) { token.ThrowIfCancellationRequested(); return SameContextDn(left, right); }
        IEnumerable<(Guid Id, string Dn, SubjectHit Hit)> candidates;
        if (subject is DirectoryUser user)
        {
            candidates = local.Computers.Where(c => RelatedDn(c.ManagedByDn, user.DistinguishedName) && Qualified(c.ObjectGuid, c.DistinguishedName, c.WhenCreated))
                .Select(c => (c.ObjectGuid, c.DistinguishedName, Hit(c)));
        }
        else if (subject is DirectoryComputer computer && computer.ManagedByDn is { } owner)
        {
            candidates = local.Users.Where(u => RelatedDn(u.DistinguishedName, owner) && Qualified(u.ObjectGuid, u.DistinguishedName, u.WhenCreated))
                .Select(u => (u.ObjectGuid, u.DistinguishedName, Hit(u)));
        }
        else { candidates = []; }
        // managedBy supplies a real DN relationship; the other endpoint must already have its own dated GUID/DN in the local
        // directory. No last-user string, TSV name, login or DNS name is resolved into an identity here.
        var related = ImmutableArray.CreateBuilder<SubjectHit>();
        foreach (var candidate in candidates.OrderBy(c => c.Hit.Name, StringComparer.OrdinalIgnoreCase).ThenBy(c => c.Dn, StringComparer.Ordinal))
        {
            token.ThrowIfCancellationRequested();
            var readAt = local.ObjectReadAt is { } dates ? dates[candidate.Id] : local.ReadAt;
            if (related.Count == 10) { facts.Add(new("Relations locales", "Affichage limité à 10 identités managedBy déjà mémorisées ; aucun recensement lancé", Tone.Warn)); break; }
            related.Add(candidate.Hit with { Detail = candidate.Hit.Detail + " · managedBy mémorisé le " + Date(readAt) + " · non revérifié" });
        }
        if (related.Count > 0 && !facts.Any(f => f.Label == "Relations locales"))
        { facts.Add(new("Relations locales", "Identités managedBy déjà mémorisées, non revérifiées dans l’annuaire", Tone.Info)); }
        token.ThrowIfCancellationRequested(); return (signals, facts.ToImmutable(), related.ToImmutable());
    }

    private static (MachineSignals Signals, DateTimeOffset? InventoryAt) ObservedMachineSignals(DirectoryComputer pc, WorkstationObservation? observation, DateTimeOffset now)
    {
        bool Dated(DateTimeOffset? at) => pc.WhenCreated > DateTimeOffset.UnixEpoch && at is { } value && value >= pc.WhenCreated && value <= now;
        var presence = observation?.Presence is { HasReading: true } p && Dated(p.CheckedAt) ? p : null;
        var inventory = observation?.Inventory is { HasReading: true } i && Dated(i.CheckedAt) ? i : null;
        double? free = inventory is { SystemDiskSizeBytes: > 0, SystemDiskFreeBytes: >= 0 } && inventory.SystemDiskFreeBytes <= inventory.SystemDiskSizeBytes
            ? (double)inventory.SystemDiskFreeBytes.Value / inventory.SystemDiskSizeBytes.Value * 100 : null;
        var boot = inventory?.LastBootAt is { } started && started > DateTimeOffset.UnixEpoch && started <= inventory.CheckedAt ? started : (DateTimeOffset?)null;
        var lastLogon = AdValues.FromFileTime(pc.LastLogonTimestamp); if (!Dated(lastLogon)) { lastLogon = null; }
        var lapsExpiry = AdValues.FromFileTime(pc.LapsExpiration);
        if (lapsExpiry <= DateTimeOffset.UnixEpoch || lapsExpiry < pc.WhenCreated) { lapsExpiry = null; }
        var rotation = pc.LapsExpiration == 0 && (pc.Laps is LapsKind.Windows or LapsKind.Legacy);
        LapsKind? laps = (lapsExpiry is not null || rotation) && (pc.Laps is LapsKind.Windows or LapsKind.Legacy) ? pc.Laps : null;
        return (new(laps, lapsExpiry, presence?.Answered, presence?.CheckedAt, free, boot, lastLogon) { LapsRotationRequested = rotation }, inventory?.CheckedAt);
    }

    private static DateTimeOffset? ContextReadAt(DirectorySnapshot local, Guid id, DateTimeOffset created, DateTimeOffset now)
    {
        var at = local.ObjectReadAt is { } dates ? dates.GetValueOrDefault(id) : local.ReadAt;
        return created > DateTimeOffset.UnixEpoch && at >= created && at <= now ? at : null;
    }

    // Uniqueness is established across the whole cache before selecting a relation or an alert. A conflicting record without
    // managedBy, outside the requested scope or with another object kind still makes the GUID/DN ambiguous.
    private static HashSet<Guid> UniqueContextIds(DirectorySnapshot local, CancellationToken token)
    {
        var ids = new HashSet<Guid>(); var invalid = new HashSet<Guid>(); var names = new Dictionary<string, Guid>(StringComparer.OrdinalIgnoreCase);
        var identities = local.Users.Select(u => (u.ObjectGuid, u.DistinguishedName)).Concat(local.Computers.Select(c => (c.ObjectGuid, c.DistinguishedName)))
            .Concat(local.Groups.Select(g => (g.ObjectGuid, g.DistinguishedName))).Concat(local.OrganizationalUnits.Select(o => (o.ObjectGuid, o.DistinguishedName)))
            .Concat((local.Contacts ?? []).Select(c => (c.ObjectGuid, c.DistinguishedName)));
        foreach (var (id, dn) in identities)
        {
            token.ThrowIfCancellationRequested(); if (id == Guid.Empty || !ids.Add(id)) { invalid.Add(id); }
            string canonical;
            try { canonical = DistinguishedName.Format(DistinguishedName.Parse(dn)); }
            catch (FormatException) { invalid.Add(id); continue; }
            if (!names.TryAdd(canonical, id)) { invalid.Add(names[canonical]); invalid.Add(id); }
        }
        ids.ExceptWith(invalid); return ids;
    }

    private static bool SameContextDn(string? left, string right)
    {
        if (string.IsNullOrWhiteSpace(left)) { return false; }
        try { return DistinguishedName.AreEqual(left, right); }
        catch (FormatException) { return false; }
    }

    private static bool WithinContextDomain(string dn, string root)
    {
        try { return ScopeRules.Contains(new(root, "Contexte local", true), dn); }
        catch (FormatException) { return false; }
    }
}
