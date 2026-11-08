Tu PORTES vers le mode annuaire (Active Directory réel) un lecteur d'écran écrit pour la simulation. Le lecteur simulé
fourni montre exactement ce que l'écran attend ; la version annuaire implémente LA MÊME interface du cœur, avec la même
forme de résultats et les mêmes règles du cœur (les classes `*Rules`, `*Service`, builders purs du cœur sont réutilisés
tels quels : appelle-les comme le lecteur simulé les appelle).

Règles du portage :
- Classe `public sealed class Ad<Nom>Reader : I<Nom>Reader` dans `v2/src/Domenia.Ad/Screens/` (espace de noms `Domenia.Ad`),
  avec UN SEUL constructeur public prenant `AdDirectorySource source` (c'est ainsi que `ScreenReaders.Discover` le trouve) ;
  le constructeur ne lit rien.
- Données de l'annuaire : `source.CurrentDirectory` (dernière image de l'annuaire lue dans la session, `DirectorySnapshot`,
  null avant la première lecture : dans ce cas lis ce qu'il faut par LDAP, ou réponds vide avec un texte qui le dit) ;
  lectures fraîches d'un objet : `AdDirectoryReader.ReadUserAsync/ReadComputerAsync/ReadGroupAsync/ReadOuAsync(source.Connection, dn, ct)` ;
  recherches : `source.Connection.SearchAsync(new AdSearchRequest(baseDn, filtre, AdSearchScope.Subtree, attributs) { SizeLimit = … }, ct)`
  puis `AdDirectoryMapper.User/Computer/Group/Ou(entry)` ; domaine : `await source.DomainAsync(ct)` ; horloge : `source.Clock` ;
  fuseau : `source.Zone` ; contrôleur : `source.ControllerName` ; observations des postes : `source.CurrentObservations`.
  Échappement des valeurs dans un filtre : `AdDirectoryReader.Escape(valeur)`.
- Tout ce que la simulation GÉNÈRE (aléatoire, données fictives, latences simulées `SimulateScreenLatencyAsync`, journaux
  fictifs) disparaît : en mode annuaire on lit, ou on dit honnêtement « non disponible dans cette version du mode annuaire »
  avec `throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "<phrase précise en français>")` — jamais de donnée
  inventée.
- Pas d'écriture : un lecteur ne modifie jamais l'annuaire.
- Les erreurs LDAP remontent telles quelles (DomeniaOperationException de la connexion).
- Si le lecteur simulé implémente plusieurs interfaces, porte-les toutes dans la même classe.

API Domenia.Ad disponibles (fichiers fournis ou décrits) : `AdDirectorySource` (fourni), `IAdConnection`, `AdEntry`,
`AdSearchRequest`, `AdSearchScope`, `AdErrors` (fournis dans AdContracts.cs), `AdDirectoryTreeReader` (fourni : exemple de
portage terminé), et (décrits, déjà écrits) :
  public static class AdDirectoryMapper { string[] OuAttributes, UserAttributes, ComputerAttributes, GroupAttributes;
    DirectoryOu? Ou(AdEntry); DirectoryUser? User(AdEntry); DirectoryComputer? Computer(AdEntry); DirectoryGroup? Group(AdEntry); }
  public static class AdDirectoryReader { Task<DomainInfo> ReadDomainAsync(IAdConnection, CancellationToken);
    Task<DirectorySnapshot> ReadSnapshotAsync(IAdConnection, DomainInfo, string baseDn, int maxObjectsPerKind, TimeProvider, CancellationToken);
    Task<DirectoryUser?> ReadUserAsync(IAdConnection, string dn, CancellationToken); (idem ReadComputerAsync, ReadGroupAsync, ReadOuAsync)
    Task<AdEntry?> FindBySamAccountNameAsync(IAdConnection, string rootDn, string sam, IReadOnlyList<string> attributes, CancellationToken);
    Task<AdEntry?> FindByGuidAsync(IAdConnection, string rootDn, Guid guid, IReadOnlyList<string> attributes, CancellationToken);
    string Escape(string value); }

Interface à implémenter : `ISearchReader` (fichier fourni). Lecteur simulé de référence : `SimulatedSearchReader` (fourni).
En mode annuaire, `FindAsync` interroge l'annuaire par LDAP (le filtre LDAP de chaque plan est construit par le cœur :
regarde comment la simulation évalue la requête et utilise les mêmes champs : type, base, sous-arbre, texte, limite ;
le cœur fournit `SearchText.TypeLdapFilter(type)` et le plan porte déjà son filtre dans `plan`/`LdapFilter` quand il existe) ;
`CachedAsync`, `LocalQueryAsync`, `LocalRowsAsync`, `SuggestAsync`, `PreviewAsync`, `CompareAsync` lisent les données
locales de la session (`source.CurrentDirectory` et `source.CurrentObservations`), comme la simulation lit son annuaire en
mémoire ; `RereadAsync` relit par LDAP (par GUID) ; `ContainersAsync` lit les conteneurs de premier niveau de la racine ;
`FindAddressAsync` et `ReverseDnsAsync` : DNS réel (`System.Net.Dns.GetHostEntryAsync`) ; `ProbeAsync` (relevés) et
`DiagnoseAsync` : ping réel (`System.Net.NetworkInformation.Ping`, un écho, 2 s) et, pour le diagnostic, test TCP des ports
445, 135 et 5985 (`TcpClient.ConnectAsync` avec délai de 2 s) ; inventaire (WMI) : non disponible ici dans cette version
(réponds le résultat « non lu » avec la raison) ; `LegacySavedSearchesAsync` : liste vide.
La conversion d'un objet en `SearchRow` doit reprendre exactement la logique de la simulation (mêmes colonnes, mêmes
drapeaux), à partir des records `DirectoryUser`/`DirectoryComputer`/`DirectoryGroup`/`DirectoryOu`.
