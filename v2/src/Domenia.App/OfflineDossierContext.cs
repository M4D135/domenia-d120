using Domenia.Ad;
using Domenia.Core;
using Domenia.Simulation;
using Domenia.Store;

namespace Domenia.App;

/// <summary>CLI composition with no network provider, workstation probe, or mutable local store.</summary>
internal sealed class OfflineDossierContext : IDisposable
{
    private readonly ReadOnlyDirectoryCache? cache;
    public IDirectorySource Source { get; }
    public IAssistanceIndex Index { get; }
    public IOrganizationalUnitIndex OrganizationalUnits { get; }

    private OfflineDossierContext(IDirectorySource source, IAssistanceIndex index, IOrganizationalUnitIndex organizationalUnits,
        ReadOnlyDirectoryCache? cache = null)
    { Source = source; Index = index; OrganizationalUnits = organizationalUnits; this.cache = cache; }

    public static async Task<OfflineDossierContext> CreateAsync(ModeDecision decision, string appFolder, string? userFolder,
        string accountLogin, TimeProvider clock, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (decision.Mode == AppMode.Simulation)
        {
            // This branch never resolves real profile/configuration/database paths.
            var simulation = new SimulatedDirectorySource(SimulationOptions.Default, clock);
            return new(simulation, new SimulatedAssistanceReader(simulation), new SimulatedDirectoryTreeReader(simulation));
        }
        if (string.IsNullOrWhiteSpace(decision.JoinedDomain) || string.IsNullOrWhiteSpace(userFolder))
        { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Domaine ou profil local indisponible ; aucun dossier produit."); }
        var cache = await ReadOnlyDirectoryCache.OpenAsync(appFolder, userFolder, decision.JoinedDomain, clock, cancellationToken).ConfigureAwait(false);
        var snapshot = await cache.ReadKnownAsync(cancellationToken).ConfigureAwait(false)
            ?? throw new InvalidDataException("Le relevé local a disparu ; aucun dossier produit.");
        var organizationalUnits = new LocalOus(OrganizationalUnitTree.Build(snapshot));
        var source = new AdDirectorySource(decision.JoinedDomain, () => accountLogin, clock, connection: new OfflineConnection(), localStore: cache);
        return new(source, new AdAssistanceReader(source), organizationalUnits, cache);
    }

    public Task EnsureCurrentAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return cache?.EnsureUnchangedAsync(cancellationToken) ?? Task.CompletedTask;
    }

    public void Dispose() => (Source as IDisposable)?.Dispose();

    private sealed class LocalOus(OrganizationalUnitTree tree) : IOrganizationalUnitIndex
    {
        public Task<OuEntry?> FindLocalAsync(string dn, CancellationToken cancellationToken)
        { cancellationToken.ThrowIfCancellationRequested(); return Task.FromResult(tree.Find(dn)); }
    }

    // Even an accidental future call to Connect/Refresh fails before LDAP/native credentials are created.
    private sealed class OfflineConnection : IAdConnection
    {
        public string? Server => null;
        private static DomeniaOperationException Refused() => new(DomeniaErrors.SourceUnavailable, "La commande dossier lit seulement la base locale ; accès réseau interdit.");
        public Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken) => Task.FromException<AdRootDse>(Refused());
        public Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken) => Task.FromException<IReadOnlyList<AdEntry>>(Refused());
        public Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken) => Task.FromException<AdEntry?>(Refused());
        public Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken) => Task.FromException(Refused());
        public Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken) => Task.FromException(Refused());
        public Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken) => Task.FromException(Refused());
        public Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken) => Task.FromException(Refused());
        public void Dispose() { }
    }
}
