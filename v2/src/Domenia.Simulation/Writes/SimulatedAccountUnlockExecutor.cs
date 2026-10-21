using Domenia.Core;

namespace Domenia.Simulation;

/// <summary>
/// Unlock of a user account in simulation (docs/WRITES.md § 6): reads the fictitious directory as the session sees it, and
/// writes only to the in-memory overlay of <see cref="SimulatedDirectorySource"/> — no network, no disk, no real effect. The
/// rules are those of Active Directory (<see cref="AccountUnlock"/>, pure, Domenia.Core); each step waits a short realistic
/// delay of its own sub-sequence (« latency/screen/write/… »), none with <see cref="SimulationLatency.None"/>.
/// </summary>
public sealed class SimulatedAccountUnlockExecutor : IAccountUnlockExecutor
{
    private const string NotAUserMessage = "Ce nom distinctif ne désigne aucun compte utilisateur de l’annuaire fictif : aucune écriture préparée.";
    private const string VanishedMessage = "Le compte n’existe plus dans l’annuaire fictif : rien n’a été modifié.";

    private readonly SimulatedDirectorySource source;

    /// <summary>Found by WriteExecutors.Discover for the simulated source; cheap: nothing is generated here.</summary>
    public SimulatedAccountUnlockExecutor(SimulatedDirectorySource source)
    {
        ArgumentNullException.ThrowIfNull(source);
        this.source = source;
    }

    public string Kind => AccountUnlock.Kind;

    private string? Controller => source.World.Session.Controller?.DnsName;

    public async Task<WritePlanDraft> PlanAsync(string dn, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(dn);
        await source.SimulateScreenLatencyAsync("write/plan", 90, 220, cancellationToken).ConfigureAwait(false);
        var directory = source.CurrentDirectory;
        var user = FindByDn(directory, dn) ?? throw WriteErrors.Refusal(WriteErrors.TargetUnknown, NotAUserMessage);
        return AccountUnlock.Draft(user, directory.Domain, Controller, source.Clock.GetUtcNow(), source.World.TimeZone);
    }

    public async Task<WritePrecheck> CheckAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await source.SimulateScreenLatencyAsync("write/check", 60, 140, cancellationToken).ConfigureAwait(false);
        return AccountUnlock.Check(plan, FindByGuid(source.CurrentDirectory, plan.Target.ObjectGuid), source.World.TimeZone);
    }

    public async Task<WriteOutcome> ExecuteAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await source.SimulateScreenLatencyAsync("write/execute", 280, 620, cancellationToken).ConfigureAwait(false);
        if (!Guid.TryParseExact(plan.Target.ObjectGuid, "D", out var id))
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        }
        var now = source.Clock.GetUtcNow();
        var wrote = false;
        var after = source.UpdateUser(id, (user, usn) =>
        {
            if (AccountUnlock.IsUnlocked(user))
            {
                return null;
            }
            wrote = true;
            return AccountUnlock.Apply(user, now, usn);
        });
        if (after is null)
        {
            throw WriteErrors.Refusal(WriteErrors.TargetUnknown, VanishedMessage);
        }
        return wrote
            ? new WriteOutcome(WriteResult.Applied, "lockoutTime remis à zéro dans l’annuaire fictif (en mémoire, aucun effet réel)" + (Controller is null ? "." : ", comme le ferait " + Controller + "."))
            : new WriteOutcome(WriteResult.NoChange, "Compte déjà déverrouillé" + FrenchText.Colon + "aucune écriture.");
    }

    public async Task<WriteVerification> VerifyAsync(WritePlan plan, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await source.SimulateScreenLatencyAsync("write/verify", 90, 200, cancellationToken).ConfigureAwait(false);
        return AccountUnlock.Verify(FindByGuid(source.CurrentDirectory, plan.Target.ObjectGuid), Controller);
    }

    private static DirectoryUser? FindByGuid(DirectorySnapshot directory, string objectGuid) =>
        Guid.TryParseExact(objectGuid, "D", out var id) ? directory.Users.FirstOrDefault(u => u.ObjectGuid == id) : null;

    /// <summary>The user at this DN: exact text first, then the RFC 4514 comparison (case and escaping ignored).</summary>
    private static DirectoryUser? FindByDn(DirectorySnapshot directory, string dn)
    {
        var exact = directory.Users.FirstOrDefault(u => string.Equals(u.DistinguishedName, dn, StringComparison.OrdinalIgnoreCase));
        if (exact is not null)
        {
            return exact;
        }
        return directory.Users.FirstOrDefault(u =>
        {
            try
            {
                return DistinguishedName.AreEqual(u.DistinguishedName, dn);
            }
            catch (FormatException)
            {
                return false;
            }
        });
    }
}
