using System.Globalization;
using Domenia.Core;

namespace Domenia.Store;

public sealed partial class DomeniaDatabase
{
    private void InsertLegacyRow(SqliteDatabase db, LegacyImportRow row)
    {
        var v = row.Values;
        long Number(string key) => long.Parse(v[key], CultureInfo.InvariantCulture);
        var now = clock.GetUtcNow().ToString("O", CultureInfo.InvariantCulture);
        var inserted = row.Kind switch
        {
            "Objets" => db.Execute("INSERT INTO ad_objects(object_key,object_guid,object_type,name,login,upn,display_name,description,extra,state,distinguished_name,when_changed,usn_changed,last_logon,search_key,source_dc,synced_at) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,'legacy_import',?16);",
                row.Key, v["guid"], v["type"], v["name"], v["login"], v["upn"], v["display"], v["description"], v["extra"], v["state"], v["dn"], v["changed"], Number("usn"), v["logon"],
                string.Join(' ', new[] { v["type"], v["name"], v["login"], v["upn"], v["display"], v["description"], v["extra"], v["dn"] }).ToLowerInvariant(), now),
            "Parc" => db.Execute("INSERT INTO park_state(computer_key,computer,last_probe,status,user_login,attempts) VALUES(?1,?2,?3,?4,?5,?6);",
                row.Key.ToLowerInvariant(), v["computer"], v["at"], v["status"], v["user"], Number("attempts")),
            "Recherches" => db.Execute("INSERT INTO user_scan_history(login_key,login,scanned_at,scanned,candidates,reachable,probed,found) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);",
                row.Key, v["login"], v["at"], Number("scanned"), Number("candidates"), Number("reachable"), Number("probed"), v["found"]),
            "Secrets" => db.Execute("INSERT INTO secret_state(computer_key,computer,checked_at,bitlocker_keys,bitlocker_last,laps_scheme,laps_expiry,verdict,detail) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9);",
                row.Key.ToLowerInvariant(), v["computer"], v["at"], Number("keys"), v["newest"], v["scheme"], v["expiry"], v["verdict"], "Métadonnées historiques sans détail libre"),
            "Liens" => db.Execute("INSERT INTO user_machine_links(computer_key,user_login,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid,user_dn,computer_dn) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12);",
                row.Key.ToLowerInvariant(), v["user"], v["computer"], v["source"], Number("confidence"), Number("verified"), v["at"], v["details"], v["userGuid"], v["computerGuid"], v["userDn"], v["computerDn"]),
            _ => throw new InvalidDataException("Table historique inconnue."),
        };
        if (inserted != 1) { throw new InvalidDataException("Ligne historique non écrite ; transaction annulée."); }
        if (row.Kind == "Liens")
        {
            db.Execute("INSERT INTO user_machine_history(user_login,computer_key,computer,source,confidence,verified_in_ad,observed_at,details,user_guid,computer_guid) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);",
                v["user"], row.Key.ToLowerInvariant(), v["computer"], v["source"], Number("confidence"), Number("verified"), v["at"], v["details"], v["userGuid"], v["computerGuid"]);
        }
    }
}
