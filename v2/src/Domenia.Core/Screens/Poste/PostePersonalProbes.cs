using System.Collections.Immutable;
using System.Security.Cryptography;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;
using ProbeReading = Domenia.Core.Accueil.ProbeReading;

namespace Domenia.Core.Poste;

/// <summary>The native boundary receives the exact declaration and target, not a mutable alias or a DN alone.</summary>
public sealed record PostePersonalProbeRequest(FrozenProbe Probe, QueryComputerIdentity Computer, long Epoch, string StoreId,
    long AccountVersion, long MachineGeneration, PosteConfiguration Configuration);
public sealed record PostePersonalProbeRead(ProbeReading Reading, long AccountVersion, long MachineGeneration);

public interface IPostePersonalProbeReader : IScreenReader
{
    /// <summary>One explicit scalar projection, saved under its immutable key; waits for physical native completion.</summary>
    Task<PostePersonalProbeRead> CollectPersonalProbeAsync(PostePersonalProbeRequest request, CancellationToken token);
}

public sealed record PostePersonalProbePlan(string Id, string WidgetId, Guid ComputerGuid, string Computer, string Dn,
    string Key, ProbeContract Contract, string Detail, DateTimeOffset ExpiresAt);
public sealed record PostePersonalProbeReceipt(bool ReadBack, string Text);
public sealed record PostePersonalProbeResult(string Id, string Key, PosteScalarProbePage Page, PostePersonalProbeReceipt Receipt);

/// <summary>Local preparation followed by a single-use confirmed read. A catalog/layout/cache read never starts a worker.</summary>
public sealed class PostePersonalProbes
{
    private readonly EngineContext context;
    private readonly Lock gate = new();
    private readonly Dictionary<string, Prepared> plans = new(StringComparer.Ordinal);
    private sealed record Prepared(PostePersonalProbePlan Plan, FleetLayoutItem Item, PostePersonalProbeRequest Request, string Domain, string Login);

    private PostePersonalProbes(EngineContext context) { this.context = context; }
    public static PostePersonalProbes From(EngineContext context) => context.Shared(static c => new PostePersonalProbes(c));
    private DateTimeOffset Now => context.Clock.GetUtcNow();

    public async Task<PostePersonalProbePlan> PlanAsync(string dn, Guid guid, string widgetId, CancellationToken token)
    {
        var layout = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, "Computer", token).ConfigureAwait(false);
        var item = layout.Valid ? layout.Items.SingleOrDefault(i => i.Id == widgetId && !i.Paused && i.Source == FleetWidgetSource.Probe) : null;
        if (item is null || !PersonalProbeCatalog.IsKey(item.Key))
        { throw Changed("Carte de sonde personnelle absente ou en pause ; aucune collecte."); }
        var probe = (await ProfileProbeCatalog.ResolveAsync(context.Preferences, [item.Key], token).ConfigureAwait(false)).Single();
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var domain = session.Domain?.RootDn;
        if (session.Connection == ConnectionState.Disconnected || string.IsNullOrWhiteSpace(domain))
        { throw Changed("Session de domaine absente ; aucune collecte."); }
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var computer = local.Directory.Computers.SingleOrDefault(c => c.ObjectGuid == guid && DistinguishedName.AreEqual(c.DistinguishedName, dn));
        if (computer is null || guid == Guid.Empty || !DistinguishedName.AreEqual(domain, local.Directory.Domain.RootDn))
        { throw Changed("Identité exacte du poste absente de la base locale ; rouvrez sa console."); }
        if (AdValues.IsDisabled(computer.UserAccountControl) || (computer.UserAccountControl & AdValues.ServerTrustAccount) != 0)
        { throw Changed("Compte désactivé ou contrôleur de domaine : cette sonde personnelle est exclue, aucun poste contacté."); }
        var settings = await SettingsAsync(token).ConfigureAwait(false);
        if (!settings.UseCim) { throw Changed("Lecture CIM désactivée par Remote.UseCim ; aucune collecte."); }
        var facts = await context.Readers.Require<IAccueilReader>().FactsAsync(token).ConfigureAwait(false);
        _ = MachineAccountService.From(context).Resolve(session, computer.DnsHostName);
        var request = new PostePersonalProbeRequest(probe, QueryComputerIdentity.Of(computer), session.Epoch, facts.StoreId,
            AccountAccess.From(context).SelectionVersion, MachineAccountService.From(context).Generation, settings);
        var plan = new PostePersonalProbePlan(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(16)), item.Id, guid, computer.Name, computer.DistinguishedName,
            probe.Key, Domenia.Core.Accueil.ProbeCatalog.Contract(probe.Definition),
            "Une lecture CIM de cette version exacte sur ce poste, sans test ICMP préalable. Qualification AD avant et après ; rôle CIM contrôlé, contrôleurs exclus. "
                + "2 000 instances au plus, 12 s par projection dans un budget CIM total de 60 s ; l’arrêt attend la fin native. Aucun script, aucune méthode, aucun autre poste.", Now + TimeSpan.FromMinutes(5));
        var prepared = new Prepared(plan, item, request, domain, session.Account.Login);
        await ConfirmAsync(prepared, token).ConfigureAwait(false);
        lock (gate)
        {
            foreach (var key in plans.Where(p => p.Value.Plan.ExpiresAt <= Now).Select(p => p.Key).ToArray()) { plans.Remove(key); }
            if (plans.Count >= 16) { throw Changed("Trop de préparations en attente ; fermez les anciennes confirmations."); }
            plans.Add(plan.Id, prepared);
        }
        return plan;
    }

    public void Discard(string id) { lock (gate) { plans.Remove(id); } }

    public async Task<PostePersonalProbeResult> RunAsync(string id, bool confirmed, CancellationToken token)
    {
        Prepared prepared;
        lock (gate)
        {
            if (!plans.Remove(id, out var found)) { throw Changed("Préparation absente ou déjà consommée ; aucun poste contacté."); }
            prepared = found;
        }
        if (!confirmed || prepared.Plan.ExpiresAt <= Now)
        { throw Changed("Confirmation explicite manquante ou préparation expirée ; aucune collecte."); }
        await ConfirmAsync(prepared, token).ConfigureAwait(false);
        var session = PosteSession.For(context.Directory);
        var identity = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        session.EnsureSession(identity.Account.Login + "|" + (identity.Domain?.DnsName ?? "") + "|" + identity.Epoch.ToString(System.Globalization.CultureInfo.InvariantCulture), Now);
        var stop = session.BeginCollection(prepared.Plan.Dn, prepared.Plan.Computer, CollectionKind.Probes, Now, token);
        try
        {
            await ConfirmAsync(prepared, stop.Token).ConfigureAwait(false);
            var completed = await context.Readers.Require<IPostePersonalProbeReader>().CollectPersonalProbeAsync(prepared.Request, stop.Token).ConfigureAwait(false);
            // A one-use credential is consumed by admission. The native reader guards the leases after that
            // legitimate transition; later local reads keep its final generations, never the now-spent slot.
            prepared = prepared with { Request = prepared.Request with { AccountVersion = completed.AccountVersion, MachineGeneration = completed.MachineGeneration } };
            var read = completed.Reading;
            await ConfirmAsync(prepared, stop.Token).ConfigureAwait(false);
            var stored = await context.Readers.Require<IAccueilReader>().StoredProbesAsync(stop.Token).ConfigureAwait(false);
            var value = stored.ByProbe.GetValueOrDefault(prepared.Plan.Key)?.GetValueOrDefault(prepared.Plan.ComputerGuid);
            if (value is null || value.State != read.State || value.At != read.At || value.Error != read.Error || !value.Values.SequenceEqual(read.Values))
            { throw Changed("Résultat remplacé ou enregistrement non relu ; aucun succès annoncé. Relisez le cache de cette carte."); }
            await ConfirmAsync(prepared, stop.Token).ConfigureAwait(false);
            var page = PosteScalarProbeCards.Build(prepared.Request.Probe.RuntimeDefinition, value, 1, Now, context.Clock.LocalTimeZone);
            var text = "Résultat enregistré et relu sous la clé exacte de cette sonde. " + page.StatusLabel + ". "
                + (context.Mode == AppMode.Simulation ? "Monde simulé, mémoire de cette session seulement." : "Valeurs et provenance disponibles dans le cache local de la carte.");
            context.Journal.Add(new(Now, "Sonde personnelle Poste · " + prepared.Plan.Computer + " · " + page.StatusLabel,
                value.State == MeasureState.Known && value.Error is null ? Tone.Info : Tone.Warn));
            return new(prepared.Plan.Id, prepared.Plan.Key, page, new(true, text));
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested && !token.IsCancellationRequested)
        { throw new DomeniaOperationException(PosteErrors.Cancelled, PosteErrors.CancelledMessage); }
        finally { session.EndCollection(prepared.Plan.Dn, CollectionKind.Probes, stop); }
    }

    private async Task ConfirmAsync(Prepared prepared, CancellationToken token)
    {
        await ProfileProbeCatalog.ConfirmAsync(context.Preferences, [prepared.Request.Probe], token).ConfigureAwait(false);
        var layout = await PosteBoardLayouts.ReadLatestAsync(context.Preferences, "Computer", token).ConfigureAwait(false);
        var item = layout.Valid ? layout.Items.SingleOrDefault(i => i.Id == prepared.Item.Id) : null;
        var session = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        var local = await context.Directory.ReadLocalAsync(token).ConfigureAwait(false);
        var facts = await context.Readers.Require<IAccueilReader>().FactsAsync(token).ConfigureAwait(false);
        var settings = await SettingsAsync(token).ConfigureAwait(false);
        var after = await context.Directory.GetSessionAsync(token).ConfigureAwait(false);
        if (item is null || item != prepared.Item || item.Paused || session.Connection == ConnectionState.Disconnected || after.Connection == ConnectionState.Disconnected
            || session.Epoch != prepared.Request.Epoch || after.Epoch != prepared.Request.Epoch
            || !string.Equals(session.Account.Login, prepared.Login, StringComparison.OrdinalIgnoreCase)
            || !string.Equals(after.Account.Login, prepared.Login, StringComparison.OrdinalIgnoreCase)
            || session.Domain?.RootDn is not { } domain || !DistinguishedName.AreEqual(domain, prepared.Domain)
            || after.Domain?.RootDn is not { } afterDomain || !DistinguishedName.AreEqual(afterDomain, prepared.Domain)
            || !DistinguishedName.AreEqual(local.Directory.Domain.RootDn, prepared.Domain) || facts.StoreId != prepared.Request.StoreId
            || AccountAccess.From(context).SelectionVersion != prepared.Request.AccountVersion || MachineAccountService.From(context).Generation != prepared.Request.MachineGeneration
            || !SameTransport(settings, prepared.Request.Configuration)
            || !local.Directory.Computers.Any(c => prepared.Request.Computer.Matches(c)))
        { throw Changed("Carte, définition, base, identité, compte, session ou réglage modifié depuis la préparation ; aucune nouvelle collecte."); }
        token.ThrowIfCancellationRequested();
    }

    private Task<PosteConfiguration> SettingsAsync(CancellationToken token) => RemoteCollectionSettings.EffectiveAsync(context, token);

    public static bool SameTransport(PosteConfiguration current, PosteConfiguration expected) => current.UseCim == expected.UseCim
        && current.UseRemoteRegistry == expected.UseRemoteRegistry && current.Options.UseWinRm == expected.Options.UseWinRm
        && RemoteCollectionSettings.From(current) == RemoteCollectionSettings.From(expected);

    private static DomeniaOperationException Changed(string text) => new("poste.probeChanged", text);
}
