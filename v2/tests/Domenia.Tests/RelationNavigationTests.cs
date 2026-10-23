using Domenia.Core;

namespace Domenia.Tests;

internal static class RelationNavigationTests
{
    private static StoredRelation Link() => new("alice", Fixtures.User("alice").ObjectGuid, "CN=ancien,OU=Users," + Fixtures.Root,
        "PC1", Fixtures.Computer("PC1").ObjectGuid, Fixtures.Computer("PC1").DistinguishedName,
        RelationKind.Assignment, RelationRules.ManualSource, Fixtures.Now.AddDays(-2), null, true, null, null);
    private static RelationObject User(Guid? id = null) => new(RelationSubjectKind.User, id ?? Fixtures.User("alice").ObjectGuid,
        Fixtures.User("alice").DistinguishedName, "Alice renommée", "alice", null, true, null, Fixtures.Now.AddYears(-1), null, null);
    private static RelationObject Computer() => new(RelationSubjectKind.Computer, Fixtures.Computer("PC1").ObjectGuid,
        Fixtures.Computer("PC1").DistinguishedName, "PC1", "PC1", null, true, null, Fixtures.Now.AddYears(-1), null, null);
    private sealed class Lookup(RelationObject? user, RelationObject? computer) : IRelationDirectoryLookup
    {
        public RelationObject? User(Guid? guid, string login) => user;
        public RelationObject? Computer(Guid? guid, string name) => computer;
    }

    [Test]
    public static void A_stored_GUID_missing_from_the_local_index_is_unknown_and_has_no_navigation_target()
    {
        var link = Link(); var lookup = new Lookup(null, Computer());
        var row = RelationProjection.Row(link, lookup, false, RelationPersistence.Stored, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        Check.Equal(RelationIdentityMatch.Unknown, row.Identity, "GUID mémorisé ne prouve pas que l’objet a été relu");
        Check.Contains("index local", row.IdentityNote, "aucune suppression AD prétendue"); Check.Null(row.UserTargetDn, "DN ancien non utilisé comme cible");
        Check.Equal(link.UserDn, row.UserDn, "DN original conservé pour export/copie");
        var subject = RelationProjection.Subject(Computer(), "Postes", [link], [], [link], lookup, null, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        Check.Null(subject.Primary!.Dn, "pas de repli sur le DN historique dans la relation principale");
        Check.True(subject.Graph.Nodes.Where(n => n.Depth > 0).All(n => n.Dn is null && !n.Exists), "graphe sans lien vers un homonyme");
    }

    [Test]
    public static void A_renamed_GUID_keeps_its_original_DN_for_export_but_navigation_uses_its_current_DN()
    {
        var link = Link(); var lookup = new Lookup(User(), Computer());
        var row = RelationProjection.Row(link, lookup, false, RelationPersistence.Stored, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        Check.Equal(RelationIdentityMatch.Same, row.Identity, "GUID stable après renommage");
        Check.Equal(link.UserDn, row.UserDn, "historique non réécrit"); Check.Equal(User().Dn, row.UserTargetDn, "destination actuelle distincte");
        var subject = RelationProjection.Subject(Computer(), "Postes", [link], [], [link], lookup, null, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
        Check.Equal(User().Dn, subject.Primary!.Dn, "cible principale actuelle");
        Check.True(subject.Graph.Nodes.Any(n => n.Depth > 0 && n.Dn == User().Dn && n.Exists), "cible du graphe actuelle");
    }

    [Test]
    public static void Legacy_names_and_recycled_GUIDs_do_not_inherit_clickable_directory_targets()
    {
        foreach (var link in new[] { Link() with { UserGuid = null }, Link() })
        {
            var other = User(Fixtures.User("bob").ObjectGuid); var lookup = new Lookup(other, Computer());
            var row = RelationProjection.Row(link, lookup, false, RelationPersistence.Stored, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
            Check.Null(row.UserTargetDn, "nom seul ou autre GUID insuffisant"); Check.Null(row.UserName, "nom actuel du tiers non prêté au lien historique");
            var subject = RelationProjection.Subject(Computer(), "Postes", [link], [], [link], lookup, null, Fixtures.Now, TestClock.Fixed().LocalTimeZone);
            Check.Null(subject.Primary!.Dn, "pas de cible principale déduite par nom");
            Check.True(subject.Graph.Nodes.Where(n => n.Depth > 0).All(n => n.Dn is null), "aucun DN transmis au graphe");
        }
        var history = Link() with { Kind = RelationKind.History };
        Check.True(RelationProjection.Logons(Computer(), [history], new Lookup(User(Guid.NewGuid()), Computer()), Fixtures.Now, TestClock.Fixed().LocalTimeZone).All(l => l.OtherDn is null),
            "historique sans navigation vers un autre GUID");
    }
}
