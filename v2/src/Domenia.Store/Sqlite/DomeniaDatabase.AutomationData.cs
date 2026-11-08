using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private static JsonArray AutomationObservations(SqliteDatabase db, DomeniaDatabase? owner, AutomationRequest request,
        string? family, DateTimeOffset now, List<string> notes, List<string> excluded, CancellationToken cancellationToken)
    {
        if (!Table(db, "ad_objects")) { notes.Add("Index local absent : observations non rattachables à un périmètre."); return []; }
        var selected = new SortedDictionary<string, JsonObject>(StringComparer.Ordinal);
        void Add(JsonObject row)
        {
            var key = row["Guid"]!.GetValue<string>().ToLowerInvariant() + ":" + row["Famille"]!.GetValue<string>();
            if (selected.TryGetValue(key, out var previous) && AutomationDate(row["TentativeUtc"]) < AutomationDate(previous["TentativeUtc"])) return;
            selected[key] = row;
            if (selected.Count > request.Limit + 1) selected.Remove(selected.Last().Key);
        }
        if (Table(db, "domenia_observations"))
        {
            var parameters = new List<object?>(); var where = AutomationWhere(request, parameters);
            var familyFilter = "(z.family IN ('Presence','Console','Inventory') OR z.family GLOB 'Probe:*')";
            if (family is not null) { parameters.Add(family); familyFilter = "z.family=?" + parameters.Count; }
            parameters.Add(request.Limit + 1);
            var sql = "SELECT z.object_guid,z.dn,z.family,z.status,z.attempt_at,z.success_at,z.error,z.definition_hash,"
                + "CASE WHEN length(z.payload)<=262144 THEN z.payload END AS payload,length(z.payload) AS payload_length "
                + "FROM domenia_observations z WHERE " + familyFilter
                + " AND EXISTS (SELECT 1 FROM ad_objects o WHERE " + where + " AND lower(z.object_guid)=lower(o.object_guid)) "
                + "ORDER BY lower(z.object_guid),z.family LIMIT ?" + parameters.Count;
            string[] columns = ["object_guid", "dn", "family", "status", "attempt_at", "success_at", "error", "definition_hash", "payload"];
            foreach (var row in AutomationRows(db, sql, columns, parameters.ToArray()))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (row["family"] is not string name || !AutomationFamily(name)) throw new InvalidDataException("Famille d’observation locale invalide.");
                var item = AutomationMap(row, ("Guid", "object_guid"), ("DN", "dn"), ("Famille", "family"), ("Statut", "status"),
                    ("TentativeUtc", "attempt_at"), ("ReussiteUtc", "success_at"), ("Erreur", "error"), ("Definition", "definition_hash"));
                item["Donnees"] = AutomationPayload(row["payload"] as string, row["object_guid"] + ":" + name, excluded, out var note);
                item["Note"] = (long?)row["payload_length"] > OfflineDossiers.MaxPayloadChars ? "Données trop volumineuses : non reprises." : note;
                item["Origine"] = "domenia_observations";
                Add(item);
            }
        }
        var fleet = AutomationFleet(db, owner);
        if (fleet is not null)
        {
            var parameters = new List<object?>(); var where = AutomationWhere(request, parameters);
            var sql = "SELECT o.object_guid,o.distinguished_name FROM ad_objects o WHERE " + where + " ORDER BY o.object_guid LIMIT 100001";
            var rows = AutomationRows(db, sql, ["object_guid", "distinguished_name"], parameters.ToArray());
            if (rows.Count > 100000) throw new InvalidDataException("Périmètre local supérieur à 100 000 postes ; choisissez une OU plus précise.");
            var identities = rows.ToDictionary(row => Guid.Parse((string)row["object_guid"]!), row => (string)row["distinguished_name"]!);
            void Typed(Guid id, string name, MeasureState state, DateTimeOffset? at, JsonNode? data, string? error = null)
            {
                if (family is not null && family != name || at is null || !identities.TryGetValue(id, out var dn)) return;
                if (at > now.AddMinutes(2) || at == DateTimeOffset.MinValue) throw new InvalidDataException("Observation locale datée dans le futur ou sans date exploitable.");
                cancellationToken.ThrowIfCancellationRequested();
                Add(new JsonObject
                {
                    ["Guid"] = id.ToString("D"), ["DN"] = dn, ["Famille"] = name, ["Statut"] = state.ToString(),
                    ["TentativeUtc"] = at.Value.ToString("O", CultureInfo.InvariantCulture),
                    ["ReussiteUtc"] = state is MeasureState.Known or MeasureState.Absent ? at.Value.ToString("O", CultureInfo.InvariantCulture) : null,
                    ["Erreur"] = error, ["Definition"] = null,
                    ["Donnees"] = OfflineDossiers.Protect(data, id + ":" + name, excluded), ["Note"] = null, ["Origine"] = "domenia_v2_metadata/fleet",
                });
            }
            foreach (var pc in fleet.Observations.Workstations)
            {
                Typed(pc.ComputerGuid, "Presence", pc.Presence.State, pc.Presence.CheckedAt, JsonSerializer.SerializeToNode(pc.Presence));
                Typed(pc.ComputerGuid, "Inventory", pc.Inventory.State, pc.Inventory.CheckedAt, JsonSerializer.SerializeToNode(pc.Inventory));
            }
            foreach (var (id, machine) in fleet.Facts.Machines)
                Typed(id, "Console", machine.ConsoleUser is null ? machine.WmiState == MeasureState.Known ? MeasureState.Absent : machine.WmiState : MeasureState.Known, machine.ConsoleAt,
                    new JsonObject { ["Utilisateur"] = machine.ConsoleUser });
            foreach (var (probe, readings) in fleet.Probes.ByProbe)
            {
                if (Domenia.Core.Accueil.ProbeCatalog.Find(probe) is null && !PersonalProbeCatalog.IsKey(probe))
                { notes.Add("Sonde locale inconnue exclue."); continue; }
                foreach (var (id, reading) in readings)
                    Typed(id, "Probe:" + probe, reading.State, reading.At, JsonSerializer.SerializeToNode(reading.Values), reading.Error);
            }
            notes.Add("Observations historiques et relevés v2 fusionnés par GUID et famille ; la tentative la plus récente est conservée.");
        }
        return new JsonArray(selected.Values.Select(value => (JsonNode)value).ToArray());
    }

    private static DateTimeOffset AutomationDate(JsonNode? value) => DateTimeOffset.TryParse(value?.ToString(),
        CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var date) ? date : DateTimeOffset.MinValue;

    private static CachedFleet? AutomationFleet(SqliteDatabase db, DomeniaDatabase? owner)
    {
        if (!Table(db, "domenia_v2_metadata")) return null;
        var size = (long?)db.Scalar("SELECT length(CAST(payload AS BLOB)) FROM domenia_v2_metadata WHERE key='fleet';");
        if (size is null) return null;
        if (size > AutomationBytes || owner is null) throw new InvalidDataException("Relevés v2 hors limites ou sans identité de magasin.");
        return owner.ReadFleet(db);
    }

    private static JsonArray AutomationRecipes(SqliteDatabase db, DomeniaDatabase? owner, AutomationRequest request,
        List<string> notes, List<string> excluded)
    {
        if (owner is not null)
        {
            var root = QueryLibrary.RootKey(owner.DomainDn);
            var (document, _) = owner.ReadQueryLibrary(db, root);
            if (document is null) return [];
            CheckQueryDocument(root, document);
            using var json = JsonDocument.Parse(document, new JsonDocumentOptions { MaxDepth = 96 });
            var result = new JsonArray();
            foreach (var record in json.RootElement.GetProperty("recipes").EnumerateArray().Where(r => !r.GetProperty("archived").GetBoolean())
                .OrderBy(r => r.GetProperty("id").GetString(), StringComparer.Ordinal).Take(request.Limit + 1))
            {
                var definition = record.GetProperty("definition").GetString()!;
                var recipe = QueryRecipeJson.Read(definition);
                var data = AutomationPayload(definition, "requetes." + recipe.Id, excluded, out var note);
                result.Add(new JsonObject
                {
                    ["Id"] = recipe.Id, ["Nom"] = recipe.Name, ["Categorie"] = record.GetProperty("category").GetString(),
                    ["Revision"] = record.GetProperty("revision").GetInt64(), ["VersionDefinition"] = recipe.Format switch
                    { QueryRecipe.FormatV1 => 1, QueryRecipe.FormatV2 => 2, QueryRecipe.FormatV3 => 3, QueryRecipe.FormatV4 => 4,
                        _ => throw new InvalidDataException("Version de définition inconnue.") },
                    ["Empreinte"] = record.GetProperty("fingerprint").GetString(), ["CreeeUtc"] = record.GetProperty("createdAt").GetString(),
                    ["ModifieeUtc"] = record.GetProperty("updatedAt").GetString(), ["Definition"] = data, ["Note"] = note,
                });
            }
            notes.Add("Bibliothèque courante relue avec contrôle d’empreinte ; aucune requête exécutée.");
            return result;
        }
        if (Table(db, "domenia_v2_query_library") && (long?)db.Scalar("SELECT count(*) FROM domenia_v2_query_library;") > 0)
            throw new InvalidDataException("Bibliothèque v2 sans identité de magasin ; aucune interprétation implicite.");
        if (!Table(db, "domenia_query_recipes")) { notes.Add("Bibliothèque locale absente."); return []; }
        var query = "SELECT id,name,category,revision,definition_version,definition_json,definition_sha256,created_utc,updated_utc FROM domenia_query_recipes WHERE archived=0 ORDER BY id LIMIT ?1";
        string[] columns = ["id", "name", "category", "revision", "definition_version", "definition_json", "definition_sha256", "created_utc", "updated_utc"];
        var items = new JsonArray();
        foreach (var row in AutomationRows(db, query, columns, request.Limit + 1))
        {
            if (row["definition_json"] is not string definition || QueryHash(definition) != row["definition_sha256"] as string)
                throw new InvalidDataException("Empreinte de définition locale différente ; aucune requête exportée.");
            var item = AutomationMap(row, ("Id", "id"), ("Nom", "name"), ("Categorie", "category"), ("Revision", "revision"),
                ("VersionDefinition", "definition_version"), ("Empreinte", "definition_sha256"), ("CreeeUtc", "created_utc"), ("ModifieeUtc", "updated_utc"));
            item["Definition"] = AutomationPayload(definition, "requetes." + row["id"], excluded, out var note); item["Note"] = note;
            items.Add(item);
        }
        return items;
    }
}
