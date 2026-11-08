using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;
using Domenia.Core.Accueil;
using Domenia.Core.Queries;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private const int AutomationBytes = 32 * 1024 * 1024;

    /// <summary>One explicit existing database, one native read-only transaction, no migration or mutable engine composition.
    /// Both schema-11 D1 tables and the current v2 projections are read from that same SQLite snapshot.</summary>
    public static Task<AutomationAnswer> ReadAutomationAsync(string path, AutomationRequest request, string? family,
        TimeProvider clock, CancellationToken cancellationToken) => Task.Run(() =>
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(clock);
        var checkedRequest = ShellAutomation.Validate(request.Command, request.Perimeter.OrganizationalUnit,
            request.Perimeter.Computers, request.Perimeter.Guids, request.Limit, request.Format);
        if (checkedRequest.Request is null || request.Command is "version" or "dossier" || request.Limit is < 1 or > 5000
            || checkedRequest.Request.Perimeter.Kind != request.Perimeter.Kind
            || request.Command is "etat" or "requetes" && request.Perimeter.Kind != "Aucun"
            || family is not null && (request.Command != "observations" || !AutomationFamily(family)))
            throw new ArgumentException("Commande locale non validée ; aucune base ouverte.");
        request = checkedRequest.Request;
        // Check raw syntax before normalizing: neither devices nor UNC paths reach a native API.
        if (!System.IO.Path.IsPathFullyQualified(path) || path.StartsWith(@"\\", StringComparison.Ordinal)
            || !ShellFileNames.IsSafe(System.IO.Path.GetFileName(path), "db") || path.AsSpan(2).Contains(':'))
            throw new InvalidDataException("La base doit être un fichier .db local absolu, sans périphérique ni flux alternatif.");
        path = System.IO.Path.GetFullPath(path);
        CompatibleDirectoryCache.ValidateLocalPath(path);
        if (!File.Exists(path)) throw new InvalidDataException("Base locale absente ; aucun fichier ni profil créé.");
        // A clean, closed rollback-journal database only: SQLite may otherwise create or update WAL sidecars even with
        // SQLITE_OPEN_READONLY. Pin against writers/replacement before checking the header and the existing sidecars.
        using var pin = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var header = new byte[100];
        pin.ReadExactly(header);
        if (!header.AsSpan(0, 16).SequenceEqual("SQLite format 3\0"u8) || header[18] != 1 || header[19] != 1
            || new[] { "-wal", "-shm", "-journal" }.Any(suffix => File.Exists(path + suffix)))
            throw new InvalidDataException("Base WAL, journal actif ou format inconnu : choisissez une base locale fermée et cohérente ; aucun fichier annexe créé.");
        CompatibleDirectoryCache.ValidateLocalPath(path);
        using var db = new SqliteDatabase(path, readOnly: true, cancellationToken: cancellationToken);
        db.Script("PRAGMA query_only=ON; PRAGMA temp_store=MEMORY;");
        db.Begin(write: false);
        if (!Table(db, "schema_info") || db.Scalar("SELECT value FROM schema_info WHERE key='schema_version';") as string != "11")
            throw new InvalidDataException("Schéma local inconnu ; aucune migration ni lecture approximative.");
        var state = Table(db, "domenia_store_state")
            ? db.Query("SELECT store_id,domain_dn,revision FROM domenia_store_state LIMIT 2;") : [];
        if (state.Count > 1) throw new InvalidDataException("Identité du magasin local ambiguë.");
        var metadata = state.SingleOrDefault();
        var domain = metadata?.GetValueOrDefault("domain_dn") as string;
        if (metadata is not null && string.IsNullOrWhiteSpace(domain)) throw new InvalidDataException("Identité de domaine locale absente.");
        DomeniaDatabase? owner = null;
        if (domain is { Length: > 0 })
        {
            owner = new DomeniaDatabase(path, domain, clock);
            owner.CheckIdentity(db, allowLegacy: true);
            if (request.Perimeter.OrganizationalUnit is { } ou && !DistinguishedName.IsWithin(ou, domain, subtree: true)
                && !DistinguishedName.AreEqual(ou, domain))
                throw new InvalidDataException("Périmètre d’un autre domaine que la base choisie.");
        }
        var source = new JsonObject
        {
            ["Base"] = path, ["Magasin"] = metadata?.GetValueOrDefault("store_id") as string,
            ["Domaine"] = domain, ["Revision"] = JsonSerializer.SerializeToNode(metadata?.GetValueOrDefault("revision")),
            ["LectureSeule"] = true, ["Simulation"] = false,
        };
        var notes = new List<string> { "Instantané SQLite local ; aucune connexion AD, aucune sonde, aucune migration." };
        var excluded = new List<string>();
        var items = request.Command switch
        {
            "etat" => AutomationState(db, owner, path, pin.Length, notes),
            "postes" => AutomationComputers(db, request, notes),
            "observations" => AutomationObservations(db, owner, request, family, clock.GetUtcNow(), notes, excluded, cancellationToken),
            "associations" => AutomationLinks(db, request, notes),
            "requetes" => AutomationRecipes(db, owner, request, notes, excluded),
            _ => throw new InvalidOperationException("Commande locale non déclarée."),
        };
        var truncated = items.Count > request.Limit;
        while (items.Count > request.Limit) items.RemoveAt(items.Count - 1);
        if (truncated) notes.Add($"Limite de {request.Limit} lignes atteinte : résultat partiel.");
        cancellationToken.ThrowIfCancellationRequested();
        // End a read snapshot without any database commit, backup or checkpoint capability.
        db.Rollback();
        return new AutomationAnswer(request, source, items, truncated, excluded, notes, clock.GetUtcNow());
    }, cancellationToken);

    private static bool AutomationFamily(string family) => family is "Presence" or "Console" or "Inventory"
        || family.StartsWith("Probe:", StringComparison.Ordinal) && family.Length is > 6 and <= 134
            && family.AsSpan(6).IndexOfAnyExcept("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-".AsSpan()) < 0;

    /// <summary>Unicode-aware literal suffix. SQLite's lower()/NOCASE only fold ASCII; no caller text becomes SQL.</summary>
    internal static string AutomationOuGlob(string dn)
    {
        var result = new StringBuilder("*,");
        foreach (var character in dn)
        {
            if (character is '*' or '?' or '[') { result.Append('[').Append(character).Append(']'); continue; }
            var upper = char.ToUpperInvariant(character); var lower = char.ToLowerInvariant(character);
            if (upper == lower) result.Append(character);
            else result.Append('[').Append(upper).Append(lower).Append(']');
        }
        return result.ToString();
    }

    private static string AutomationWhere(AutomationRequest request, List<object?> parameters)
    {
        string Bind(object value) { parameters.Add(value); return "?" + parameters.Count.ToString(CultureInfo.InvariantCulture); }
        var where = "o.object_type='Machine'";
        return request.Perimeter.Kind switch
        {
            "OU" => where + " AND o.distinguished_name GLOB " + Bind(AutomationOuGlob(request.Perimeter.OrganizationalUnit!)),
            "Noms" => where + " AND lower(o.name) IN (" + string.Join(',', request.Perimeter.Computers.Select(x => Bind(x.ToLowerInvariant()))) + ")",
            "Guids" => where + " AND lower(o.object_guid) IN (" + string.Join(',', request.Perimeter.Guids.Select(x => Bind(x.ToLowerInvariant()))) + ")",
            _ => throw new InvalidDataException("Périmètre explicite obligatoire ; aucune lecture globale implicite."),
        };
    }

    private static List<Dictionary<string, object?>> AutomationRows(SqliteDatabase db, string sql, IReadOnlyList<string> columns, params object?[] parameters)
    {
        // The SQL and column identifiers are closed source constants. Check aggregate bytes before native strings are allocated.
        var size = string.Join('+', columns.Select(c => "coalesce(length(CAST(" + c + " AS BLOB)),0)"));
        if ((long?)db.Scalar("SELECT coalesce(sum(" + size + "),0) FROM (" + sql + ");", parameters) > AutomationBytes)
            throw new InvalidDataException("Réponse locale supérieure à 32 Mio ; réduisez la limite ou le périmètre.");
        return db.Query(sql, parameters);
    }

    private static JsonArray AutomationState(SqliteDatabase db, DomeniaDatabase? owner, string path, long bytes, List<string> notes)
    {
        var facts = new JsonObject { ["Base"] = new JsonObject { ["Chemin"] = path, ["Octets"] = bytes } };
        (string Label, string Table, string Sql, string[] Columns, int Limit)[] groups =
        [
            ("Schema", "schema_info", "SELECT key,value FROM schema_info WHERE key IN ('schema_version','domenia_schema') ORDER BY key LIMIT 3", ["key", "value"], 2),
            ("Magasin", "domenia_store_state", "SELECT store_id,domain_dn,revision FROM domenia_store_state LIMIT 2", ["store_id", "domain_dn", "revision"], 1),
            ("Synchronisations", "sync_state", "SELECT scope,server,base_dn,last_sync,item_count FROM sync_state ORDER BY scope LIMIT 5001", ["scope", "server", "base_dn", "last_sync", "item_count"], 5000),
            ("Objets", "ad_objects", "SELECT object_type,count(*) AS n,max(synced_at) AS last_sync FROM ad_objects GROUP BY object_type ORDER BY object_type LIMIT 33", ["object_type", "n", "last_sync"], 32),
            ("ObservationsHistoriques", "domenia_observations", "SELECT family,count(*) AS n,max(success_at) AS last_success,max(attempt_at) AS last_attempt FROM domenia_observations WHERE family IN ('Presence','Console','Inventory') OR family GLOB 'Probe:*' GROUP BY family ORDER BY family LIMIT 501", ["family", "n", "last_success", "last_attempt"], 500),
            ("Associations", "user_machine_links", "SELECT source,count(*) AS n,max(observed_at) AS last_observed FROM user_machine_links GROUP BY source ORDER BY source LIMIT 501", ["source", "n", "last_observed"], 500),
            ("RequetesHistoriques", "domenia_query_recipes", "SELECT count(*) AS n,max(updated_utc) AS last_update FROM domenia_query_recipes WHERE archived=0", ["n", "last_update"], 1),
        ];
        foreach (var (label, table, sql, columns, limit) in groups)
        {
            if (!Table(db, table)) { facts[label] = null; notes.Add("Table " + table + " absente : " + label + " inconnu."); continue; }
            var rows = AutomationRows(db, sql, columns);
            if (rows.Count > limit)
            {
                rows.RemoveAt(rows.Count - 1); facts["DetailsTronques"] = true;
                notes.Add(label + " : détail partiel, limite de " + limit + " groupes atteinte.");
            }
            facts[label] = JsonSerializer.SerializeToNode(rows);
        }
        if (AutomationFleet(db, owner) is { } fleet)
            facts["RelevesV2"] = new JsonObject
            {
                ["Presence"] = fleet.Observations.Workstations.Count(pc => pc.Presence.CheckedAt is not null),
                ["Inventory"] = fleet.Observations.Workstations.Count(pc => pc.Inventory.CheckedAt is not null),
                ["Console"] = fleet.Facts.Machines.Values.Count(pc => pc.ConsoleAt is not null),
                ["Probes"] = fleet.Probes.ByProbe.Values.Sum(readings => readings.Values.Count(reading => reading.At is not null)),
                ["ReleveUtc"] = fleet.Observations.TakenAt,
            };
        if (owner is not null)
        {
            var root = QueryLibrary.RootKey(owner.DomainDn); var (document, _) = owner.ReadQueryLibrary(db, root);
            if (document is not null)
            {
                CheckQueryDocument(root, document);
                using var library = JsonDocument.Parse(document, new JsonDocumentOptions { MaxDepth = 96 });
                facts["RequetesCourantes"] = library.RootElement.GetProperty("recipes").EnumerateArray().Count(r => !r.GetProperty("archived").GetBoolean());
            }
            else facts["RequetesCourantes"] = 0;
        }
        return new JsonArray(facts);
    }

    private static JsonArray AutomationComputers(SqliteDatabase db, AutomationRequest request, List<string> notes)
    {
        if (!Table(db, "ad_objects")) { notes.Add("Index local absent : aucun poste connu, absence AD non déduite."); return []; }
        var parameters = new List<object?>(); var where = AutomationWhere(request, parameters);
        parameters.Add(request.Limit + 1);
        var facts = Table(db, "ad_computer_facts");
        var projection = Table(db, "domenia_v2_objects");
        var query = "SELECT o.object_guid,o.name,o.distinguished_name,o.state,o.description,o.last_logon,o.when_changed,o.synced_at,o.source_dc,"
            + (facts ? "f.os_version,f.when_created,f.pwd_last_set,f.read_at," : "NULL AS os_version,NULL AS when_created,NULL AS pwd_last_set,NULL AS read_at,")
            + (projection ? "CASE WHEN length(CAST(v.payload AS BLOB))<=1048576 THEN v.payload END AS projection" : "NULL AS projection")
            + " FROM ad_objects o " + (facts ? "LEFT JOIN ad_computer_facts f ON lower(f.object_guid)=lower(o.object_guid) " : "")
            + (projection ? "LEFT JOIN domenia_v2_objects v ON lower(v.object_guid)=lower(o.object_guid) AND v.kind='computer' " : "")
            + "WHERE " + where + " ORDER BY lower(o.name),o.object_guid LIMIT ?" + parameters.Count;
        string[] columns = ["object_guid", "name", "distinguished_name", "state", "description", "last_logon", "when_changed", "synced_at", "source_dc", "os_version", "when_created", "pwd_last_set", "read_at", "projection"];
        var items = new JsonArray();
        foreach (var row in AutomationRows(db, query, columns, parameters.ToArray()))
        {
            var item = AutomationMap(row,
                ("Guid", "object_guid"), ("Nom", "name"), ("DN", "distinguished_name"), ("Etat", "state"), ("Description", "description"),
                ("DerniereConnexion", "last_logon"), ("ModifieAD", "when_changed"), ("SynchroniseUtc", "synced_at"), ("Controleur", "source_dc"),
                ("Systeme", "os_version"), ("CreeAD", "when_created"), ("MotDePasseMachineDefini", "pwd_last_set"), ("FaitsLusUtc", "read_at"));
            if (row["projection"] is string raw)
            {
                var pc = JsonSerializer.Deserialize<DirectoryComputer>(raw, Json) ?? throw new InvalidDataException("Projection de poste illisible.");
                if (!string.Equals(pc.ObjectGuid.ToString("D"), row["object_guid"] as string, StringComparison.OrdinalIgnoreCase)
                    || row["distinguished_name"] is not string dn || !DistinguishedName.AreEqual(pc.DistinguishedName, dn))
                    throw new InvalidDataException("Projection de poste d’une autre identité.");
                item["Systeme"] = pc.OperatingSystem; item["CreeAD"] = pc.WhenCreated;
                item["DNS"] = pc.DnsHostName;
            }
            items.Add(item);
        }
        return items;
    }

    private static JsonArray AutomationLinks(SqliteDatabase db, AutomationRequest request, List<string> notes)
    {
        if (!Table(db, "ad_objects") || !Table(db, "user_machine_links"))
        { notes.Add("Index ou associations absents de cette base ; aucune absence AD déduite."); return []; }
        var parameters = new List<object?>(); var where = AutomationWhere(request, parameters); parameters.Add(request.Limit + 1);
        var query = "SELECT l.computer,l.user_login,l.source,l.confidence,l.verified_in_ad,l.observed_at,l.details,l.user_guid,l.computer_guid,l.user_dn,l.computer_dn FROM user_machine_links l WHERE EXISTS (SELECT 1 FROM ad_objects o WHERE "
            + where + " AND (lower(l.computer_guid)=lower(o.object_guid) OR (coalesce(l.computer_guid,'')='' AND lower(l.computer_key)=lower(o.name)))) ORDER BY lower(l.computer),l.computer_key LIMIT ?" + parameters.Count;
        string[] columns = ["computer", "user_login", "source", "confidence", "verified_in_ad", "observed_at", "details", "user_guid", "computer_guid", "user_dn", "computer_dn"];
        return new JsonArray(AutomationRows(db, query, columns, parameters.ToArray()).Select(row => (JsonNode)AutomationMap(row,
            ("Poste", "computer"), ("Compte", "user_login"), ("Source", "source"), ("Confiance", "confidence"), ("VerifieAD", "verified_in_ad"),
            ("ObserveUtc", "observed_at"), ("Details", "details"), ("CompteGuid", "user_guid"), ("PosteGuid", "computer_guid"), ("CompteDN", "user_dn"), ("PosteDN", "computer_dn"))).ToArray());
    }

    private static JsonObject AutomationMap(IReadOnlyDictionary<string, object?> row, params (string Output, string Input)[] fields)
    {
        var item = new JsonObject();
        foreach (var (output, input) in fields) item[output] = JsonSerializer.SerializeToNode(row.GetValueOrDefault(input));
        if (item.ContainsKey("VerifieAD")) item["VerifieAD"] = row.GetValueOrDefault("verified_in_ad") is long value ? JsonValue.Create(value == 1) : null;
        return item;
    }

    private static JsonNode? AutomationPayload(string? text, string path, List<string> excluded, out string? note)
    {
        note = null;
        if (string.IsNullOrEmpty(text)) return null;
        if (text.Length > OfflineDossiers.MaxPayloadChars) { note = "Données trop volumineuses : non reprises."; return null; }
        try { return OfflineDossiers.Protect(JsonNode.Parse(text, documentOptions: new JsonDocumentOptions { MaxDepth = 32 }), path, excluded); }
        catch (JsonException) { note = "Données enregistrées illisibles : non reprises."; return null; }
    }
}
