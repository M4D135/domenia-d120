using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Queries;

namespace Domenia.Ad;

public sealed partial class AdAssistanceReader
{
    public async Task<DossierData> DossierDataAsync(DossierRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var perimeter = request.Perimeter;
        if (!perimeter.Valid || request.Limit is < 1 or > OfflineDossiers.MaxRows || perimeter.Guids.IsDefault || perimeter.Guids.Length > 500
            || request.Sections.IsDefault || request.Sections.Any(s => s is not ("etat" or "postes" or "observations" or "associations" or "requetes")))
        { throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, "Périmètre ou sections du dossier invalides ; aucun dossier produit."); }
        var epoch = source.Epoch; var state = await source.ReadLocalAsync(cancellationToken).ConfigureAwait(false); var directory = state.Directory;
        var ids = new HashSet<Guid>();
        foreach (var value in perimeter.Guids)
        { if (!Guid.TryParse(value, out var id) || id == Guid.Empty) { throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, "GUID de poste invalide."); } ids.Add(id); }
        ScopeSelection? scope = null;
        if (perimeter.Kind == "OU" && perimeter.OrganizationalUnit is { } ou && ids.Count == 0)
        {
            AdFicheObjects.EnsureDomain(ou, directory.Domain.RootDn);
            if (DistinguishedName.AreEqual(ou, directory.Domain.RootDn) || !DistinguishedName.Parse(ou)[0].Type.Equals("OU", StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, "Choisissez une OU précise ; pas la racine du domaine."); }
            scope = new(ou, "Dossier", true);
        }
        else if (perimeter.Kind != "Guids" || perimeter.OrganizationalUnit is not null || ids.Count == 0)
        { throw new DomeniaOperationException(AssistanceErrors.DossierPerimeter, "Un périmètre explicite est obligatoire."); }
        var candidates = directory.Computers.Where(c => scope is null ? ids.Contains(c.ObjectGuid) : ScopeRules.Contains(scope, c.DistinguishedName)).OrderBy(c => c.Name, StringComparer.Ordinal).ToArray();
        var computers = candidates.Take(request.Limit).ToArray(); var included = computers.ToDictionary(c => c.ObjectGuid);
        var computerRows = new JsonArray(); var observationRows = new JsonArray(); var links = new JsonArray(); var queries = new JsonArray(); var notes = new List<string>();
        foreach (var pc in computers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            computerRows.Add(new JsonObject { ["Guid"] = pc.ObjectGuid.ToString("D"), ["Nom"] = pc.Name, ["DN"] = pc.DistinguishedName,
                ["Etat"] = AdValues.IsDisabled(pc.UserAccountControl) ? "Désactivé" : "Actif", ["Description"] = pc.Description,
                ["DerniereConnexion"] = Iso(AdValues.FromFileTime(pc.LastLogonTimestamp)), ["ModifieAD"] = Iso(pc.WhenChanged), ["CreeAD"] = Iso(pc.WhenCreated),
                ["SynchroniseUtc"] = Iso(directory.ObjectReadAt?.GetValueOrDefault(pc.ObjectGuid, directory.ReadAt) ?? directory.ReadAt),
                ["Systeme"] = pc.OperatingSystem, ["NomDNS"] = pc.DnsHostName });
            if (!request.Sections.Contains("observations")) { continue; }
            var observed = state.Observations.Workstations.FirstOrDefault(o => o.ComputerGuid == pc.ObjectGuid);
            if (observed?.Presence is { CheckedAt: { } at } presence && at >= pc.WhenCreated && at <= Now)
            { observationRows.Add(new JsonObject { ["Guid"] = pc.ObjectGuid.ToString("D"), ["Famille"] = "presence", ["Statut"] = presence.State.ToString(), ["TentativeUtc"] = Iso(at), ["Repond"] = presence.Answered }); }
            if (observed?.Inventory is { CheckedAt: { } read } inventory && read >= pc.WhenCreated && read <= Now)
            { observationRows.Add(new JsonObject { ["Guid"] = pc.ObjectGuid.ToString("D"), ["Famille"] = "inventaire", ["Statut"] = inventory.State.ToString(), ["TentativeUtc"] = Iso(read),
                ["Modele"] = inventory.Model, ["MemoireOctets"] = inventory.MemoryBytes, ["DisqueSystemeOctets"] = inventory.SystemDiskSizeBytes, ["DisqueSystemeLibreOctets"] = inventory.SystemDiskFreeBytes }); }
        }
        if (request.Sections.Contains("associations") && source.LocalStore is IRelationLocalCache relations)
        {
            var local = await relations.ReadRelationsAsync(cancellationToken).ConfigureAwait(false);
            foreach (var row in local.Rows.Select(r => r.Relation).Where(r => r.ComputerGuid is { } guid && included.TryGetValue(guid, out var pc)
                && r.ComputerDn is { } dn && DistinguishedName.AreEqual(dn, pc.DistinguishedName) && (r.When is null || r.When >= pc.WhenCreated && r.When <= Now)).Take(request.Limit + 1))
            { links.Add(new JsonObject { ["Poste"] = row.Computer, ["Compte"] = row.UserLogin, ["PosteGuid"] = row.ComputerGuid?.ToString("D"), ["CompteGuid"] = row.UserGuid?.ToString("D"),
                ["Source"] = row.Source, ["Nature"] = row.Kind.ToString(), ["ObserveUtc"] = Iso(row.When), ["VerifieAD"] = row.VerifiedInAd, ["Details"] = row.Details }); }
            if (local.Truncated || local.Rejected > 0) { notes.Add(local.Notice); }
            if (links.Count > request.Limit) { links.RemoveAt(links.Count - 1); notes.Add("Associations limitées aux " + request.Limit.ToString(CultureInfo.InvariantCulture) + " premières lignes."); }
        }
        if (request.Sections.Contains("requetes") && source.LocalStore is IQueryLibraryStore library)
        {
            var bytes = await library.ReadAsync(QueryLibrary.RootKey(directory.Domain.RootDn), cancellationToken).ConfigureAwait(false);
            if (bytes is not null)
            {
                using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 96 });
                if (document.RootElement.GetProperty("domainKey").GetString() != QueryLibrary.RootKey(directory.Domain.RootDn)) { throw new InvalidDataException("Bibliothèque d’un autre domaine."); }
                var records = document.RootElement.GetProperty("recipes");
                foreach (var record in records.EnumerateArray().Take(request.Limit))
                {
                    var recipe = QueryRecipeJson.Read(record.GetProperty("definition").GetString()!); var compiled = QueryEngine.Compile(recipe);
                    if (compiled.Fingerprint != record.GetProperty("fingerprint").GetString()) { throw new InvalidDataException("Empreinte de recette différente."); }
                    queries.Add(new JsonObject { ["Id"] = recipe.Id, ["Nom"] = recipe.Name, ["Revision"] = record.GetProperty("revision").GetInt64(), ["Empreinte"] = compiled.Fingerprint,
                        ["Definition"] = QueryRecipeJson.Write(compiled.Normalized), ["Archivee"] = record.GetProperty("archived").GetBoolean() });
                }
                if (records.GetArrayLength() > request.Limit) { notes.Add("Bibliothèque de requêtes tronquée au plafond du dossier."); }
            }
            notes.Add("Les recettes sont des définitions locales ; elles n’ont pas été exécutées pour préparer ce dossier.");
        }
        var observationsTruncated = observationRows.Count > request.Limit;
        while (observationRows.Count > request.Limit) { observationRows.RemoveAt(observationRows.Count - 1); }
        Current(epoch);
        notes.Add("Base locale du domaine ; aucune lecture réseau ni revalidation AD déclenchée par cet export.");
        return new(new JsonObject { ["Base"] = "Domenia · base locale", ["Domaine"] = directory.Domain.DnsName, ["LectureAnnuaireUtc"] = Iso(directory.ReadAt), ["Simulation"] = false },
            new JsonObject { ["Base"] = "Annuaire local", ["Domaine"] = directory.Domain.DnsName, ["DerniereLectureUtc"] = Iso(directory.ReadAt), ["LectureComplete"] = directory.Complete,
                ["Objets"] = directory.ObjectCount, ["PostesDansPerimetre"] = candidates.Length, ["ReleveObservationsUtc"] = Iso(state.Observations.TakenAt) },
            computerRows, candidates.Length > request.Limit, observationRows, observationsTruncated, links, queries, [.. notes]);
    }

    private static string? Iso(DateTimeOffset? at) => at?.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);
}
