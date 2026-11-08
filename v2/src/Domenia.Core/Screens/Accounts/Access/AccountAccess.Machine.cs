using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Names and leases shared with the workstation cascade; no duplicate password store.</summary>
internal sealed record AccessMachineSlot(string Scope, string Account, string Key, string? Remaining, MachineAccountPause? Pause);
internal sealed record AccessMachineSnapshot(long Epoch, long Generation, long Revision,
    ImmutableDictionary<MachineAccountSource, AccessMachineSlot> Slots, AccessMachineSlot? Secrets, AccessMachineSlot? SecretsTemporary);

public sealed partial class AccountAccess
{
    internal void EnsureMachineNotPaused(string accountKey)
    {
        lock (gate)
        {
            if (PausedLocked(accountKey) is not null)
            { throw new DomeniaOperationException(MachineErrors.AccountPaused, "Compte en pause après un rejet ; aucun nouvel envoi distant."); }
        }
    }

    internal AccessMachineSnapshot MachineSnapshot(SessionSnapshot session, string? target)
    {
        lock (gate)
        {
            var now = clock.GetUtcNow();
            Sweep(now);
            var slots = ImmutableDictionary.CreateBuilder<MachineAccountSource, AccessMachineSlot>();
            AccessMachineSlot Slot(string scope, string login, string? remaining = null, string? localTarget = null)
            {
                var key = Key(session, login, localTarget);
                var paused = PausedLocked(key);
                return new(scope, login, key, remaining, paused is null ? null : new(login, paused.At, "Authentification refusée ; validez ou corrigez ce compte."));
            }
            AccessMachineSlot? TemporarySlot(string scope) => temporary.TryGetValue(scope, out var item)
                ? Slot(scope, item.Login, CredentialRules.Remaining(item.Lease, epoch, now).Text, item.Target) : null;
            if (target is not null && TemporarySlot(CredentialRules.RemoteLocalPrefix + CredentialRules.MachineKey(target).ToUpperInvariant()) is { } local)
            { slots[MachineAccountSource.TemporaryLocal] = local; }
            if (TemporarySlot(CredentialRules.Remote) is { } remoteTemporary) { slots[MachineAccountSource.Temporary] = remoteTemporary; }
            if (secondary.TryGetValue(AccessUsage.Remote, out var remote)) { slots[MachineAccountSource.Remote] = Slot("secondary:Remote", remote.Login); }
            var connectionSource = session.Authentication.Method == AuthenticationMethod.ExplicitCredentials ? MachineAccountSource.Connection : MachineAccountSource.Windows;
            slots[connectionSource] = Slot(CredentialRules.Directory, session.Account.Login);
            return new(epoch, generation, revision, slots.ToImmutable(),
                secondary.TryGetValue(AccessUsage.Secrets, out var secrets) ? Slot("secondary:Secrets", secrets.Login) : null,
                TemporarySlot(CredentialRules.Laps));
        }
    }

    internal MachineOperationCredential AcquireMachineSlot(SessionSnapshot session, string? target, AccessMachineSnapshot snapshot,
        MachineAccountSource source, AccessMachineSlot slot, bool forTrial, bool consume = true)
    {
        lock (gate)
        {
            Sweep(clock.GetUtcNow());
            if (epoch != snapshot.Epoch || generation != snapshot.Generation)
            { throw new DomeniaOperationException(EpochChanged, "Compte modifié pendant la préparation ; aucune lecture envoyée."); }
            if (!forTrial && PausedLocked(slot.Key) is not null)
            { throw new DomeniaOperationException(MachineErrors.AccountPaused, MachineErrors.AccountPausedMessage); }
            System.Security.SecureString? copy = null;
            var singleUse = false;
            if (slot.Scope == "secondary:Remote") { copy = secondary[AccessUsage.Remote].Secret.Copy(); }
            else if (temporary.TryGetValue(slot.Scope, out var temp))
            {
                singleUse = temp.Lease.Mode == LeaseMode.OneShot;
                copy = temp.Secret.Copy();
                if (consume)
                {
                    temporary[slot.Scope] = temp with { Lease = CredentialRules.Use(temp.Lease, clock.GetUtcNow()) };
                    revision++;
                }
            }
            copy?.MakeReadOnly();
            var held = new MachineOperationCredential(source, MachineAccountRules.ForTarget(slot.Account, target), copy,
                "access#" + snapshot.Generation.ToString(System.Globalization.CultureInfo.InvariantCulture) + "|" + slot.Key)
                { AccountKey = slot.Key, SingleUse = singleUse };
            try
            {
                // Seal the shared generation atomically after retiring this use, before the service synchronizes.
                // A concurrent account change must not be mistaken for our own one-shot consumption.
                Sweep(clock.GetUtcNow());
                return held with { SharedSelectionVersion = generation };
            }
            catch { held.Dispose(); throw; }
        }
    }

    internal void RecordMachineTrial(string place, string account, MachineTrialResult trial)
    {
        var separator = place.IndexOf('|');
        if (!place.StartsWith("access#", StringComparison.Ordinal) || separator < 0
            || !long.TryParse(place.AsSpan(7, separator - 7), out var expected)) { return; }
        lock (gate)
        {
            if (expected != generation) { return; }
            var key = place[(separator + 1)..];
            if (trial.Verdict is MachineTrialVerdict.Rejected or MachineTrialVerdict.AccountState)
            {
                faults[key] = new(CredentialRules.Remote, trial.At);
                AddRequestLocked(new(CredentialRules.Remote, "Essai du compte poste", trial.Computer, "badCredentials", trial.At), true);
            }
            else if (trial.Success) { faults.Remove(key); }
            revision++;
        }
    }
}
