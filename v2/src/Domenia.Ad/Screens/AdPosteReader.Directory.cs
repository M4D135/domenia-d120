using System.Collections.Immutable;
using Domenia.Core;
using Domenia.Core.Poste;
using Domenia.Inventory;

namespace Domenia.Ad;

public sealed partial class AdPosteReader
{
    internal Func<string, IAdConnection>? ControllerConnection { get; init; }

    public async Task<LogonActivity> LogonByControllerAsync(string dn, CancellationToken cancellationToken)
    {
        // This is an AD-only read: a missing workstation DNS record must not prevent reading its account history.
        var local = await NetworkAsync(dn, cancellationToken, machine: false).ConfigureAwait(false);
        var domain = await source.DomainAsync(cancellationToken).ConfigureAwait(false);
        var controllers = domain.Controllers.DistinctBy(c => c.DnsName, StringComparer.OrdinalIgnoreCase).ToArray();
        var now = source.Clock.GetUtcNow();
        using var authenticationStop = new CancellationTokenSource();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, authenticationStop.Token);
        using var slots = new SemaphoreSlim(4);
        var rejected = 0;
        var read = await Task.WhenAll(controllers.Take(50).Select(async dc =>
        {
            var entered = false;
            try
            {
                await slots.WaitAsync(stop.Token).ConfigureAwait(false); entered = true;
                EnsureEpoch(local.Epoch);
                if (!CimQuery.IsHostName(dc.DnsName)) { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unknown, null, "Nom de contrôleur invalide ; non contacté."); }
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5), source.Clock);
                using var budget = CancellationTokenSource.CreateLinkedTokenSource(stop.Token, timeout.Token);
                try
                {
                    using var connection = ControllerConnection?.Invoke(dc.DnsName) ?? (source.Connection as AdConnection)?.ForServer(dc.DnsName, TimeSpan.FromSeconds(5))
                        ?? throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Transport de l’identité AD indisponible.");
                    var rows = await connection.SearchAsync(new(domain.RootDn, AdObjectAccess.GuidFilter(local.Computer.ObjectGuid), AdSearchScope.Subtree,
                        ["objectGUID", "objectClass", "lastLogon"]) { PageSize = 1, SizeLimit = 2, Timeout = TimeSpan.FromSeconds(5), Budget = TimeSpan.FromSeconds(5) }, budget.Token).ConfigureAwait(false);
                    EnsureEpoch(local.Epoch);
                    if (rows.Count == 0) { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unknown, null, "Compte non visible sur ce contrôleur ; aucune absence de connexion déduite."); }
                    if (rows.Count != 1 || rows[0].Guid("objectGUID") != local.Computer.ObjectGuid || !rows[0].Strings("objectClass").Contains("computer", StringComparer.OrdinalIgnoreCase))
                    { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unknown, null, "Identité AD différente ou ambiguë ; réponse écartée."); }
                    var value = rows[0].Long("lastLogon");
                    if (value == 0) { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Observed, null, "Aucune connexion enregistrée sur ce contrôleur (valeur zéro)."); }
                    var at = AdValues.FromFileTime(value);
                    if (value is null or < 0 || at is null || at < local.Computer.WhenCreated || at > now.AddMinutes(5))
                    { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unknown, null, "lastLogon absent, illisible ou incohérent avec les dates du compte."); }
                    return new ControllerLogon(dc.DnsName, dc.Site, FactState.Observed, at, PosteText.LocalDateTime(at.Value, source.Zone) + " · " + PosteText.Age(at.Value, now));
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested)
                { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unavailable, null, "Budget de cinq secondes atteint ; non lu."); }
            }
            catch (OperationCanceledException)
            { return new ControllerLogon(dc.DnsName, dc.Site, FactState.Unknown, null, authenticationStop.IsCancellationRequested ? "Lecture suspendue après un rejet d’authentification ; aucun réessai." : "Lecture arrêtée ; résultat non reçu."); }
            catch (DomeniaOperationException ex)
            {
                if (ex.Code == AdErrors.Credentials) { Interlocked.Exchange(ref rejected, 1); authenticationStop.Cancel(); }
                return new ControllerLogon(dc.DnsName, dc.Site, ex.Code is AdErrors.Credentials or AdErrors.AccessDenied ? FactState.Refused : FactState.Unavailable, null,
                    ex.Code == AdErrors.Credentials ? "Authentification refusée ; autres lectures suspendues." : ex.Code == AdErrors.AccessDenied ? "Droit de lecture refusé." : "Contrôleur non lu ; aucune conclusion sur sa dernière connexion.");
            }
            finally { if (entered) { slots.Release(); } }
        })).ConfigureAwait(false);
        EnsureEpoch(local.Epoch);
        if (source.AccountContext is { } context && (rejected != 0 || read.Any(r => r.State == FactState.Refused)))
        {
            var session = await source.GetSessionAsync(CancellationToken.None).ConfigureAwait(false);
            EnsureEpoch(local.Epoch);
            AccountAccess.From(context).RegisterRefusal(CredentialRules.Directory, "poste.logonByDc", domain.DnsName,
                rejected != 0 ? "badCredentials" : "accessDenied", CredentialRules.AccountKey(session.Account.Login, domain.DnsName, domain.NetbiosName, null), true);
        }
        var known = read.Count(r => r.State == FactState.Observed);
        var complete = controllers.Length > 0 && known == controllers.Length;
        var latest = read.Where(r => r.State == FactState.Observed).Select(r => r.LastLogon).Max();
        var timestamp = AdValues.FromFileTime(local.Computer.LastLogonTimestamp);
        var coverage = FrenchText.Count(known, "contrôleur lu", "contrôleurs lus") + " sur " + FrenchText.Integer(controllers.Length)
            + (controllers.Length > 50 ? " · lecture limitée à 50 contrôleurs" : "");
        var detail = latest is { } last ? "Dernière connexion connue le " + PosteText.LocalDateTime(last, source.Zone) + "."
            : known == 0 ? "Aucune lecture concluante de dernière connexion." : "Aucune connexion enregistrée sur les contrôleurs lus.";
        if (!complete) { detail += " Un contrôleur non lu peut connaître une connexion plus récente."; }
        ImmutableArray<PosteFact> facts =
        [
            PosteText.Fact("lastLogonTimestamp", timestamp is { } stamp ? PosteText.LocalDateTime(stamp, source.Zone) : "Non renseigné", timestamp is null ? FactState.Unknown : FactState.Estimated,
                "Attribut AD répliqué", "Valeur répliquée avec décalage ; ne prouve pas une présence actuelle.", at: now, tone: Tone.Info),
            PosteText.Fact("lastLogon par contrôleur", detail, complete ? FactState.Observed : known == 0 ? FactState.Unknown : FactState.Estimated,
                "Attribut AD non répliqué", coverage, at: now, tone: complete ? Tone.Info : Tone.Warn),
        ];
        return new(local.Computer.Name, now, timestamp, timestamp is { } date ? PosteText.LocalDateTime(date, source.Zone) : "Non renseigné", [.. read], latest, coverage, detail, facts);
    }
}
