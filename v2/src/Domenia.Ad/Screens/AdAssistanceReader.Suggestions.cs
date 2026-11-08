using System.Collections.Immutable;
using Domenia.Core;

namespace Domenia.Ad;

public sealed partial class AdAssistanceReader
{
    /// <summary>Local, bounded suggestions from dated identities and already stored observations; never a probe or LDAP read.</summary>
    public async Task<ImmutableArray<SubjectSuggestion>> SuggestionsAsync(ScopeSelection? scope, CancellationToken cancellationToken)
    {
        var epoch = source.Epoch; var local = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); Current(epoch);
        var directory = local.Directory; var now = Now;
        if (scope is not null) { AdFicheObjects.EnsureDomain(scope.Dn, directory.Domain.RootDn); }
        var unique = UniqueContextIds(directory, cancellationToken);
        var observations = new Dictionary<Guid, WorkstationObservation?>();
        foreach (var observation in local.Observations.Workstations)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!observations.TryAdd(observation.ComputerGuid, observation)) { observations[observation.ComputerGuid] = null; }
        }
        var suggestions = new List<(int Order, SubjectSuggestion Value)>();
        bool Included(Guid id, string dn) => unique.Contains(id) && WithinContextDomain(dn, directory.Domain.RootDn) && (scope is null || ScopeRules.Contains(scope, dn));
        void Keep(int order, SubjectHit hit, Tone tone, string reason, DateTimeOffset at)
        {
            var provenance = " · mémorisé le " + Date(at) + " · non revérifié";
            suggestions.Add((order, new(hit with { Tone = tone, Detail = hit.Detail + provenance }, reason + provenance)));
            suggestions.Sort((a, b) =>
            {
                var priority = a.Order.CompareTo(b.Order); if (priority != 0) { return priority; }
                var name = StringComparer.OrdinalIgnoreCase.Compare(a.Value.Subject.Name, b.Value.Subject.Name);
                return name != 0 ? name : StringComparer.Ordinal.Compare(a.Value.Subject.Dn, b.Value.Subject.Dn);
            });
            if (suggestions.Count > 12) { suggestions.RemoveAt(12); }
        }
        foreach (var user in directory.Users)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Included(user.ObjectGuid, user.DistinguishedName) || user.UserAccountControl == 0 || AdValues.IsDisabled(user.UserAccountControl)
                || ContextReadAt(directory, user.ObjectGuid, user.WhenCreated, now) is not { } at) { continue; }
            var state = AccountState.Evaluate(user.UserAccountControl, user.ComputedAccountControl, user.LockoutTime);
            if (state.Lock == LockState.Locked) { Keep(0, Hit(user), Tone.Alert, "Compte déclaré verrouillé au dernier relevé", at); }
            else if (user.PasswordLastSet == 0) { Keep(2, Hit(user), Tone.Warn, "Changement du mot de passe exigé au dernier relevé", at); }
            else if (!state.PasswordNeverExpires && user.PasswordExpiryComputed != AdValues.Never)
            {
                var expiry = AdValues.FromFileTime(user.PasswordExpiryComputed); var lastSet = AdValues.FromFileTime(user.PasswordLastSet);
                if (state.PasswordExpired || expiry is { } expires && expires >= user.WhenCreated && expires <= now)
                { Keep(1, Hit(user), Tone.Alert, "Mot de passe expiré selon les métadonnées mémorisées", at); }
                else if (user.PasswordExpiryComputed is null && lastSet is { } changed && changed >= user.WhenCreated && changed <= now
                    && directory.Domain.PasswordPolicy.MaxPasswordAge > TimeSpan.Zero && now - changed >= directory.Domain.PasswordPolicy.MaxPasswordAge)
                { Keep(3, Hit(user), Tone.Warn, "Expiration estimée selon la stratégie de domaine mémorisée ; stratégie fine non vérifiée", at); }
                else if (state.Lock == LockState.ToCheck) { Keep(4, Hit(user), Tone.Warn, "Verrouillage à vérifier, état calculé non lu", at); }
            }
            else if (state.Lock == LockState.ToCheck) { Keep(4, Hit(user), Tone.Warn, "Verrouillage à vérifier, état calculé non lu", at); }
        }
        foreach (var computer in directory.Computers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!Included(computer.ObjectGuid, computer.DistinguishedName) || computer.UserAccountControl == 0 || AdValues.IsDisabled(computer.UserAccountControl)
                || ContextReadAt(directory, computer.ObjectGuid, computer.WhenCreated, now) is null) { continue; }
            var measured = ObservedMachineSignals(computer, observations.GetValueOrDefault(computer.ObjectGuid), now); var signals = measured.Signals;
            if (signals.SystemDiskFreePercent is double free && free < 10)
            { Keep(5, Hit(computer), Tone.Alert, "Disque système presque plein (" + FrenchText.Percent(free) + " libre au dernier inventaire)", measured.InventoryAt!.Value); }
            else if (signals.LastPresenceAnswered == false)
            { Keep(6, Hit(computer), Tone.Warn, "Aucune réponse au dernier relevé de présence ; le ping peut être filtré", signals.LastPresenceAt!.Value); }
            else if (signals.LastBootAt is { } boot && now - boot > TimeSpan.FromDays(30))
            { Keep(7, Hit(computer), Tone.Warn, "Dernier démarrage connu le " + Date(boot) + " ; uptime actuel non établi", measured.InventoryAt!.Value); }
        }
        Current(epoch); cancellationToken.ThrowIfCancellationRequested();
        return [.. suggestions.Select(s => s.Value)];
    }
}
