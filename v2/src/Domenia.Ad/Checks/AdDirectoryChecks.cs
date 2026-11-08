using System.Collections.Immutable;
using System.Diagnostics;
using System.Security.AccessControl;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>Explicit, bounded application checks using the same selected LDAP identity and epoch as every native screen.</summary>
public sealed class AdDirectoryChecks(IDirectorySource source) : IDirectoryChecks
{
    public static readonly TimeSpan ReadTimeout = TimeSpan.FromSeconds(10);
    private const string Users = "(&(objectCategory=person)(objectClass=user))";

    public async Task<ImmutableArray<CheckRow>> CheckDirectoryAsync(bool full, CancellationToken cancellationToken)
    {
        if (source is not AdDirectorySource native)
        { return [new("Annuaire", "Lecture de l’annuaire", CheckStatus.Info, 0, "Source sans annuaire réel : aucune lecture LDAP.")]; }
        var rows = ImmutableArray.CreateBuilder<CheckRow>();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        stop.CancelAfter(TimeSpan.FromSeconds(full ? 120 : 80));
        var refused = false; string? naming = null;
        AdReadAccess? selected = null;
        try
        {
            await Measure("Annuaire", "Liaison RootDSE", async () =>
            {
                selected = await AdReadAccess.AcquireAsync(native, CredentialRules.Directory, null, stop.Token).ConfigureAwait(false);
                var root = await selected.RootDseAsync(stop.Token).ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(root.DefaultNamingContext) || string.IsNullOrWhiteSpace(root.DnsHostName))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Identité du contrôleur ou base non retournée."); }
                naming = root.DefaultNamingContext;
                return (CheckStatus.Ok, "Contrôleur " + root.DnsHostName + " · base " + naming + ".");
            }).ConfigureAwait(false);
            if (naming is not string baseDn || selected is null)
            {
                rows.Add(new("Annuaire", "Contrôles suivants", CheckStatus.Info, 0, "Base non établie ; aucune autre lecture envoyée."));
                return rows.ToImmutable();
            }
            var access = selected;
            async Task<IReadOnlyList<AdEntry>> Search(string filter, AdSearchScope scope, int limit, bool acl = false)
            {
                var result = await access.SearchAsync(new(baseDn, filter, scope, ["objectGUID", "objectClass", .. (acl ? new[] { "nTSecurityDescriptor" } : [])])
                { PageSize = limit, SizeLimit = limit, Timeout = ReadTimeout, Budget = ReadTimeout, ReadOwnerAndDacl = acl }, stop.Token).ConfigureAwait(false);
                if (result.Count > limit || result.Any(e => e.Guid("objectGUID") is null ||
                    !(scope == AdSearchScope.Base ? DistinguishedName.AreEqual(e.DistinguishedName, baseDn) : DistinguishedName.IsWithin(e.DistinguishedName, baseDn, scope == AdSearchScope.Subtree))))
                { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Réponse LDAP sans identité ou hors périmètre ; contrôle non conclu."); }
                return result;
            }
            await Measure("Annuaire", "Lecture de la base", async () =>
            {
                var found = await Search("(objectClass=*)", AdSearchScope.Base, 1).ConfigureAwait(false);
                return found.Count == 1 ? (CheckStatus.Ok, "Base et identité lues.") : (CheckStatus.Error, "Base non retournée avec le compte choisi.");
            }).ConfigureAwait(false);
            foreach (var (label, filter) in new[] { ("Recherche utilisateur", Users), ("Recherche machine", "(objectClass=computer)"), ("Recherche groupe", "(objectClass=group)") })
            {
                await Measure("Annuaire", label, async () =>
                {
                    var found = await Search(filter, AdSearchScope.Subtree, 1).ConfigureAwait(false);
                    return found.Count == 1 ? (CheckStatus.Ok, "Un objet identifié lu ; son nom n’est pas repris dans le rapport.") : (CheckStatus.Warn, "Aucun objet visible ; absence dans le domaine non démontrée.");
                }).ConfigureAwait(false);
            }
            await Measure("Annuaire", "Lecture de l’arborescence", async () =>
            {
                var found = await Search("(|(objectClass=organizationalUnit)(objectClass=container))", AdSearchScope.OneLevel, 5).ConfigureAwait(false);
                return found.Count > 0 ? (CheckStatus.Ok, FrenchText.Count(found.Count, "branche lue", "branches lues") + " (5 au plus).") : (CheckStatus.Warn, "Aucune branche visible.");
            }).ConfigureAwait(false);
            await Measure("Sécurité", "Lecture des droits de la base", async () =>
            {
                var found = await Search("(objectClass=*)", AdSearchScope.Base, 1, acl: true).ConfigureAwait(false);
                if (found.SingleOrDefault()?.Bytes("nTSecurityDescriptor") is not { Length: > 0 and <= 1048576 } bytes)
                { return (CheckStatus.Error, "DACL non retournée ; absence de droits non déduite."); }
                var descriptor = new RawSecurityDescriptor(bytes, 0);
                if (descriptor.DiscretionaryAcl is not { } acl) { return (CheckStatus.Warn, "DACL absente du descripteur ; contrôle des délégations nécessaire."); }
                return (CheckStatus.Ok, FrenchText.Count(acl.Count, "entrée de DACL lue", "entrées de DACL lues") + " ; droits effectifs non calculés.");
            }).ConfigureAwait(false);
            if (full)
            {
                for (var index = 1; index <= 3; index++)
                {
                    await Measure("Mesure", "Recherche répétée " + index, async () =>
                    {
                        var found = await Search("(|" + Users + "(objectClass=computer))", AdSearchScope.Subtree, 25).ConfigureAwait(false);
                        return (CheckStatus.Ok, FrenchText.Count(found.Count, "objet reçu", "objets reçus") + " ; limite de 25.");
                    }).ConfigureAwait(false);
                }
            }
            access.EnsureCurrent(); return rows.ToImmutable();
        }
        finally { selected?.Dispose(); }

        async Task Measure(string category, string label, Func<Task<(CheckStatus Status, string Detail)>> read)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (refused || stop.IsCancellationRequested)
            { rows.Add(new(category, label, CheckStatus.Info, 0, refused ? "Non lancé après refus du compte ; aucun repli sur une autre identité." : "Budget total atteint ; contrôle non lancé.")); return; }
            var start = Stopwatch.GetTimestamp(); CheckStatus status; string detail;
            try { (status, detail) = await read().ConfigureAwait(false); }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            { (status, detail) = (CheckStatus.Error, "Budget atteint ; aucune nouvelle tentative."); }
            catch (DomeniaOperationException ex) when (ex.Code != AccountAccess.EpochChanged)
            {
                refused = ex.Code is AdErrors.AccessDenied or AdErrors.Credentials or AccountAccess.ContextRefused;
                (status, detail) = (CheckStatus.Error, ex.Message);
            }
            catch (Exception ex) when (ex is ArgumentException or IOException or TimeoutException)
            { (status, detail) = (CheckStatus.Error, "Réponse illisible ou indisponible ; contrôle non conclu."); }
            rows.Add(new(category, label, status, Math.Round(Stopwatch.GetElapsedTime(start).TotalMilliseconds, 1), detail));
        }
    }
}
