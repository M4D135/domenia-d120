using System.Text.Json;
using System.Text.Json.Nodes;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private sealed record DirectoryFields(StoredObject Object, HashSet<string>? Observed);

    private static readonly IReadOnlyDictionary<string, string[]> CommonFields = new Dictionary<string, string[]>
    {
        ["sid"] = ["objectsid"], ["name"] = ["name", "cn", "ou"], ["cn"] = ["cn", "name"],
        ["description"] = ["description"], ["managedByDn"] = ["managedby"],
        ["whenCreated"] = ["whencreated"], ["whenChanged"] = ["whenchanged"], ["usnChanged"] = ["usnchanged"],
        ["samAccountName"] = ["samaccountname"], ["userPrincipalName"] = ["userprincipalname"],
        ["displayName"] = ["displayname"], ["givenName"] = ["givenname"], ["surname"] = ["sn"],
        ["mail"] = ["mail"], ["title"] = ["title"], ["department"] = ["department"],
        ["office"] = ["physicaldeliveryofficename"], ["telephoneNumber"] = ["telephonenumber"],
        ["managerDn"] = ["manager"], ["employeeId"] = ["employeeid"],
        ["userAccountControl"] = ["useraccountcontrol"], ["computedAccountControl"] = ["msds-user-account-control-computed"],
        ["lockoutTime"] = ["lockouttime"], ["badPasswordCount"] = ["badpwdcount"],
        ["passwordLastSet"] = ["pwdlastset"], ["passwordExpiryComputed"] = ["msds-userpasswordexpirytimecomputed"],
        ["lastLogonTimestamp"] = ["lastlogontimestamp"], ["accountExpires"] = ["accountexpires"],
        ["adminCount"] = ["admincount"], ["primaryGroupId"] = ["primarygroupid"], ["memberOf"] = ["memberof"],
        ["dnsHostName"] = ["dnshostname"], ["location"] = ["location"], ["operatingSystem"] = ["operatingsystem"],
        ["operatingSystemVersion"] = ["operatingsystemversion"], ["groupType"] = ["grouptype"], ["members"] = ["member"],
    };

    private static bool Observed(HashSet<string>? attributes, params string[] names) => attributes is null || names.Any(attributes.Contains);
    private static bool BothObserved(HashSet<string>? attributes, string first, string second) =>
        Observed(attributes, first) && Observed(attributes, second);

    private static HashSet<string>? ReadObserved(JsonObject value)
    {
        if (value["observedAttributes"] is null) return null; // Backward-compatible full typed records.
        if (value["observedAttributes"] is not JsonArray fields || fields.Count > 256)
            throw new InvalidDataException("Contrat des attributs lus invalide ; aucune fusion.");
        var attributes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var field in fields)
        {
            if (field is not JsonValue text || !text.TryGetValue<string>(out var name) || name.Length is 0 or > 128
                || !FicheAttributeRules.IsValidName(name) || FicheAttributeRules.IsSensitive(name) || !attributes.Add(name))
                throw new InvalidDataException("Attribut lu ambigu ou sensible ; aucune fusion.");
        }
        return attributes;
    }

    private static DirectoryFields MergeDirectoryFields(StoredObject incoming, string? previous)
    {
        var next = JsonNode.Parse(incoming.Json) as JsonObject ?? throw new InvalidDataException("Objet de lecture illisible.");
        var observed = ReadObserved(next);
        if (observed is null || previous is null) return new(incoming, observed);
        var old = JsonNode.Parse(previous) as JsonObject ?? throw new InvalidDataException("Objet conservé illisible.");
        foreach (var field in CommonFields)
            if (next.ContainsKey(field.Key) && !Observed(observed, field.Value) && old.TryGetPropertyValue(field.Key, out var value))
                next[field.Key] = value?.DeepClone();
        // The two LAPS expiration attributes jointly qualify both the kind and its matching date.
        if (!BothObserved(observed, "mslaps-passwordexpirationtime", "ms-mcs-admpwdexpirationtime"))
            foreach (var field in new[] { "laps", "lapsExpiration" })
                if (next.ContainsKey(field) && old.TryGetPropertyValue(field, out var value)) next[field] = value?.DeepClone();
        var oldObserved = ReadObserved(old);
        if (oldObserved is null) next.Remove("observedAttributes");
        else next["observedAttributes"] = new JsonArray(oldObserved.Union(observed, StringComparer.OrdinalIgnoreCase)
            .Order(StringComparer.OrdinalIgnoreCase).Select(name => (JsonNode?)JsonValue.Create(name)).ToArray());
        return new(incoming with { Json = next.ToJsonString() }, observed);
    }

    private IndexRecord PreserveIndexFields(IndexRecord row, IReadOnlyDictionary<string, object?>? old, HashSet<string>? observed)
    {
        if (old is null || observed is null) return row;
        string? Text(string column) => old.GetValueOrDefault(column) as string;
        DateTimeOffset? Date(string column) => ParseStoredDate(Text(column));
        var computer = row.Type == IndexObjectType.Computer;
        return row with
        {
            Name = Observed(observed, "name", "cn") ? row.Name : Text("name") ?? row.Name,
            Login = Observed(observed, "samaccountname") ? row.Login : Text("login"),
            Upn = Observed(observed, computer ? "dnshostname" : "userprincipalname") ? row.Upn : Text("upn"),
            DisplayName = Observed(observed, "displayname") ? row.DisplayName : Text("display_name"),
            Description = Observed(observed, "description") ? row.Description : Text("description"),
            Extra = BothObserved(observed, computer ? "operatingsystem" : "department", computer ? "location" : "title") ? row.Extra : Text("extra"),
            Enabled = Observed(observed, "useraccountcontrol") ? row.Enabled : Text("state")?.ToLowerInvariant() is "actif" or "active" or "enabled",
            WhenChanged = Observed(observed, "whenchanged") ? row.WhenChanged : Date("when_changed"),
            Usn = Observed(observed, "usnchanged") ? row.Usn : (long?)old.GetValueOrDefault("usn_changed") ?? 0,
            LastLogon = Observed(observed, "lastlogontimestamp") ? row.LastLogon : Date("last_logon"),
        };
    }

    private static bool IndexFieldObserved(string field, IndexObjectType type, HashSet<string>? attributes) => field switch
    {
        "Name" => Observed(attributes, "name", "cn"), "Login" => Observed(attributes, "samaccountname"),
        "Upn" => Observed(attributes, type == IndexObjectType.Computer ? "dnshostname" : "userprincipalname"),
        "Display" => Observed(attributes, "displayname"), "Description" => Observed(attributes, "description"),
        "Extra" => BothObserved(attributes, type == IndexObjectType.Computer ? "operatingsystem" : "department", type == IndexObjectType.Computer ? "location" : "title"),
        "State" => Observed(attributes, "useraccountcontrol"), "WhenChanged" => Observed(attributes, "whenchanged"),
        "Usn" => Observed(attributes, "usnchanged"), "LastLogon" => Observed(attributes, "lastlogontimestamp"),
        _ => true, // Object kind and distinguished name are part of every qualified object identity.
    };

    private static void WriteComputerFacts(SqliteDatabase db, DirectoryComputer computer, DateTimeOffset at, HashSet<string>? observed)
    {
        var version = Observed(observed, "operatingsystemversion"); var created = Observed(observed, "whencreated");
        var password = Observed(observed, "pwdlastset");
        var laps = BothObserved(observed, "mslaps-passwordexpirationtime", "ms-mcs-admpwdexpirationtime");
        if (!version && !created && !password && !laps) return;
        db.Execute("INSERT INTO ad_computer_facts(object_guid,object_key,os_version,when_created,pwd_last_set,laps_kind,laps_expiry,read_at) VALUES(?1,?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(object_guid) DO UPDATE SET object_key=excluded.object_key,os_version=CASE WHEN ?8 THEN excluded.os_version ELSE ad_computer_facts.os_version END,when_created=CASE WHEN ?9 THEN excluded.when_created ELSE ad_computer_facts.when_created END,pwd_last_set=CASE WHEN ?10 THEN excluded.pwd_last_set ELSE ad_computer_facts.pwd_last_set END,laps_kind=CASE WHEN ?11 THEN excluded.laps_kind ELSE ad_computer_facts.laps_kind END,laps_expiry=CASE WHEN ?11 THEN excluded.laps_expiry ELSE ad_computer_facts.laps_expiry END,read_at=excluded.read_at;",
            computer.ObjectGuid.ToString("D"), version ? computer.OperatingSystemVersion : null, created ? Stamp(computer.WhenCreated) : null,
            password ? Stamp(AdValues.FromFileTime(computer.PasswordLastSet)) : null,
            laps ? computer.Laps == LapsKind.Windows ? "windows" : computer.Laps == LapsKind.Legacy ? "legacy" : "none" : null,
            laps ? Stamp(AdValues.FromFileTime(computer.LapsExpiration)) : null, Stamp(at), version, created, password, laps);
    }
}
