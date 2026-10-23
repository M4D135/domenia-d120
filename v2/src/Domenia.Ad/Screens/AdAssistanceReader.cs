using System.Collections.Immutable;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>The local assistance index and explicit selected-account subject reads.</summary>
public sealed partial class AdAssistanceReader(AdDirectorySource source) : IAssistanceIndex, IAssistanceReader
{
    private DateTimeOffset Now => source.Clock.GetUtcNow();
    private void Current(long epoch)
    { if (epoch != source.Epoch) { throw new DomeniaOperationException(AssistanceErrors.SessionChanged, AssistanceErrors.SessionChangedMessage); } }

    public async Task<ImmutableArray<SubjectHit>> SearchAsync(string text, int limit, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (text.Length > 256 || text.Any(char.IsControl) || limit is < 1 or > 100) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Recherche Assistance hors limites."); }
        var epoch = source.Epoch; var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); Current(epoch);
        var needle = FrenchText.Fold(text.Trim());
        return [.. Hits(local.Directory).Where(h => needle.Length > 0 && new[] { h.Name, h.Login, h.Detail }.Any(v => FrenchText.Fold(v).Contains(needle, StringComparison.Ordinal)))
            .OrderBy(h => FrenchText.Fold(h.Login) == needle ? 0 : 1).ThenBy(h => FrenchText.Fold(h.Name), StringComparer.Ordinal).ThenBy(h => h.Dn, StringComparer.Ordinal).Take(limit)];
    }

    public async Task<ImmutableArray<SubjectSuggestion>> SuggestionsAsync(ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        if (scope is not null) { AdFicheObjects.EnsureDomain(scope.Dn, local.Directory.Domain.RootDn); }
        return [.. Hits(local.Directory).Where(h => (h.Tone is Tone.Alert or Tone.Warn) && (scope is null || ScopeRules.Contains(scope, h.Dn)))
            .Take(12).Select(h => new SubjectSuggestion(h, h.StateLabel))];
    }

    public async Task<ImmutableArray<NamedComputer>> ComputersNamedAsync(IReadOnlyList<string> names, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(names);
        if (names.Count > 500 || names.Any(n => n.Length is 0 or > 255 || n.Any(char.IsControl))) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Liste limitée à 500 noms de postes."); }
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); var found = ImmutableArray.CreateBuilder<NamedComputer>();
        foreach (var name in names.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var candidates = local.Directory.Computers.Where(c => new[] { c.Name, c.SamAccountName, c.SamAccountName.TrimEnd('$'), c.DnsHostName }.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase))).Take(2).ToArray();
            if (candidates.Length == 1) { found.Add(new(name, candidates[0].ObjectGuid, Hit(candidates[0]))); }
        }
        return found.ToImmutable();
    }

    public async Task<SubjectRecord?> ReadSubjectAsync(string dn, CancellationToken cancellationToken) =>
        await ReadSubjectCoreAsync(dn, null, cancellationToken).ConfigureAwait(false);
    public async Task<SubjectRecord?> LocateAsync(Guid id, CancellationToken cancellationToken) =>
        await ReadSubjectCoreAsync(null, id, cancellationToken).ConfigureAwait(false);

    private async Task<SubjectRecord?> ReadSubjectCoreAsync(string? dn, Guid? guid, CancellationToken token)
    {
        var epoch = source.Epoch;
        try
        {
            var directory = await AdSupportObjects.ReadAsync(source, dn, guid, token).ConfigureAwait(false); Current(epoch);
            var entity = directory.Users.Cast<object>().Concat(directory.Computers).SingleOrDefault();
            if (entity is null) { return null; }
            await source.RememberObjectsAsync(directory, epoch, token).ConfigureAwait(false); Current(epoch);
            var entry = AdFicheProjection.Entry(entity);
            var hit = entity is DirectoryUser user ? Hit(user) : Hit((DirectoryComputer)entity);
            var properties = entry.Attributes.ToDictionary(p => p.Key, p => (IReadOnlyList<object?>)p.Value.Cast<object?>().ToArray(), StringComparer.OrdinalIgnoreCase);
            properties["objectGUID"] = [entry.ObjectGuid]; properties["distinguishedName"] = [entry.Dn];
            var facts = ImmutableArray.Create(new SubjectFact("État AD", hit.StateLabel, hit.Tone), new SubjectFact("Compte", hit.Login, Tone.Off),
                new SubjectFact("Lecture", Date(directory.ReadAt), Tone.Info));
            return new(entry.Dn, entry.ObjectGuid, hit.Kind, hit.Name, hit.Login, hit.Path, properties, true, null, facts, [new(hit.Tone, hit.StateLabel)], [], directory.ReadAt);
        }
        catch (DomeniaOperationException ex) when (ex.Code == AdErrors.NoSuchObject) { return null; }
        catch (DomeniaOperationException ex) when (AdSupportObjects.Denied(ex)) { throw new DomeniaOperationException(AssistanceErrors.ReadRefused, "Le compte sélectionné ne peut pas lire ce sujet ; aucun repli de compte."); }
    }

    public async Task<ImmutableArray<RawIncident>> SessionIncidentsAsync(CancellationToken cancellationToken)
    {
        var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false);
        return [.. local.Journal.Where(e => e.Tone is Tone.Warn or Tone.Alert).TakeLast(SupportIncidents.Limit)
            .Select((e, i) => new RawIncident("annuaire|" + i.ToString(CultureInfo.InvariantCulture) + "|" + e.At.UtcTicks, e.At, e.Tone, "Annuaire", e.Label, "session"))];
    }

    private static IEnumerable<SubjectHit> Hits(DirectorySnapshot directory) => directory.Users.Select(Hit).Concat(directory.Computers.Select(Hit));
    private static SubjectHit Hit(DirectoryUser user)
    {
        var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
        var (tone, label) = state.Disabled ? (Tone.Off, "Désactivé") : state.Lock == LockState.Locked ? (Tone.Alert, "Verrouillé")
            : state.Lock == LockState.ToCheck ? (Tone.Warn, "Verrouillage à vérifier") : (Tone.Info, "Compte activé");
        return new(user.DistinguishedName, AssistanceSubject.User, user.DisplayName ?? user.Cn, user.SamAccountName,
            string.Join(" · ", new[] { user.UserPrincipalName, user.Mail, user.Department, user.Title }.OfType<string>()), AdSupportObjects.Container(user.DistinguishedName), tone, label);
    }
    private static SubjectHit Hit(DirectoryComputer pc) => new(pc.DistinguishedName, AssistanceSubject.Computer, pc.Name, pc.SamAccountName,
        string.Join(" · ", new[] { pc.DnsHostName, pc.OperatingSystem }.OfType<string>()), AdSupportObjects.Container(pc.DistinguishedName), Tone.Off,
        AdValues.IsDisabled(pc.UserAccountControl) ? "Compte désactivé" : "Compte activé · présence non relue");
    private string Date(DateTimeOffset at) => TimeZoneInfo.ConvertTime(at, source.Clock.LocalTimeZone).ToString("dd/MM/yyyy à HH:mm", CultureInfo.InvariantCulture);
}
