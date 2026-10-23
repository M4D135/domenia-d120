using Domenia.Core;
using Domenia.Inventory;

namespace Domenia.Ad;

/// <summary>Resolves the domain PDC and reads one account's lockouts with the actual connection credential.</summary>
internal sealed class AdAccountLockouts(AdDirectorySource source)
{
    internal async Task<LockoutEventsRead> ReadAsync(DirectoryUser user, DomainInfo domain, int hours, int maximum, CancellationToken token)
    {
        if (!AccountsRules.IsDomainSid(user.Sid)) { throw new DomeniaOperationException(AccountsRules.SidInvalid, AccountsRules.SidInvalidMessage); }
        if (hours is < 1 or > 720 || maximum is < 1 or > 500) { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Fenêtre ou limite du journal invalide."); }
        var generation = source.Epoch;
        var server = source.ControllerName ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var pdc = false;
        using var elapsed = new CancellationTokenSource(TimeSpan.FromSeconds(30), source.Clock);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token, elapsed.Token);
        try
        {
            try
            {
                var root = await source.Connection.ReadAsync(domain.RootDn, ["fSMORoleOwner"], budget.Token).ConfigureAwait(false);
                var role = root?.String("fSMORoleOwner");
                var configuration = (await source.Connection.RootDseAsync(budget.Token).ConfigureAwait(false)).ConfigurationNamingContext;
                if (role is not null && FicheValues.DisplayName(role).Equals("NTDS Settings", StringComparison.OrdinalIgnoreCase)
                    && SearchTexts.SafeParent(role) is { } parent && ScopeRules.Contains(new("CN=Sites," + configuration, "", true), parent))
                {
                    var entry = await source.Connection.ReadAsync(parent, ["dNSHostName"], budget.Token).ConfigureAwait(false);
                    if (entry?.String("dNSHostName") is { } host && CimQuery.IsHostName(host)
                        && domain.Controllers.Any(c => c.DnsName.Equals(host, StringComparison.OrdinalIgnoreCase)))
                    { server = host; pdc = true; }
                }
            }
            catch (DomeniaOperationException ex) when (ex.Code is AdErrors.AccessDenied or AdErrors.NoSuchObject or AdErrors.Unavailable or AdErrors.Timeout)
            { /* The bound controller is an explicit, labelled fallback; no other server is guessed. */ }
            if (source.Connection is not AdConnection actual)
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité du transport Windows non disponible pour lire le journal."); }
            var credential = actual.CopyCredential();
            using (credential.Password)
            {
                var to = source.Clock.GetUtcNow();
                var result = await new WindowsLockoutReader(source.Clock).ReadAsync(server, user.Sid, pdc, to.AddHours(-hours), to,
                    maximum, credential.User, credential.Domain, credential.Password, budget.Token).ConfigureAwait(false);
                if (source.Epoch != generation) { throw new DomeniaOperationException(AdErrors.NotConnected, "Session modifiée pendant la lecture du journal."); }
                return result;
            }
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested && elapsed.IsCancellationRequested)
        { return new(LockoutReadState.Unavailable, server, pdc, [], false); }
    }
}
