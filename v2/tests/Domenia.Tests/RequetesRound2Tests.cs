using System.Collections.Immutable;
using System.Text;
using System.Text.Json;
using Domenia.Bridge;
using Domenia.Core;
using Domenia.Core.Queries;
using Domenia.Core.Queries.Ldap;

namespace Domenia.Tests;

/// <summary>
/// Second round of the query workshop (critic of 22/10): library in a document of its own (budget, real read-back, atomic
/// recipe and links, conflicts between instances), impact review required before rebinding widgets, exports prepared by the
/// engine, drafts resumed with their revision, LDAP negations on absent attributes, in-chain rule, collections, limits,
/// coherence window, collection costs and SELECT re-read, packs in parts. Written now, run at the end (decision of 21/10).
/// </summary>
internal static class RequetesRound2Tests
{
    private static string Args(object value) => JsonSerializer.Serialize(value, BridgeJson.Options);

    private static async Task<JsonElement> Ok(SimulatedBridge bridge, string op, string args = "{}") => SimulatedBridge.Json(await bridge.CallAsync(op, args));

    private static async Task<string> Refused(SimulatedBridge bridge, string op, string args)
    {
        var response = await bridge.CallAsync(op, args);
        Check.Equal("error", response.Kind, "refus attendu pour " + op);
        return response.Error!.Code;
    }

    private static string RecipeJson(string templateId) =>
        QueryRecipeJson.Write((QueryTemplates.Find(templateId) ?? throw new TestFailureException("modèle absent : " + templateId)).Recipe);

    private static QueryLibrary Library(IQueryLibraryStore? store = null) =>
        new(store ?? new MemoryQueryLibraryStore(), new OperationJournal(), TestClock.Fixed(), new RecordingJournal());

    private const string Root = "DC=example,DC=local";

    private static QueryRecipe Recipe(string name, params QueryClause[] clauses) => QueryRecipe.Empty(QueryTarget.Computer) with { Name = name, Clauses = [.. clauses] };

    // ---------- Library: own document, read-back, atomicity, conflicts ----------

    [Test]
    public static async Task The_library_never_writes_the_preferences_document()
    {
        var preferences = new MemoryPreferenceStore();
        var bridge = new SimulatedBridge(preferences: preferences);
        var before = preferences.Writes;
        await Ok(bridge, "requetes.library.save", "{\"recipe\":" + RecipeJson("template.stale") + ",\"expectedRevision\":0}");
        Check.Equal(before, preferences.Writes, "aucune écriture dans le document de préférences partagé");
    }

    /// <summary>A store that changes the bytes it is given: the receipt must not say « relue ».</summary>
    private sealed class LossyStore : IQueryLibraryStore
    {
        private byte[]? document;

        public bool Persistent => true;

        public Task<byte[]?> ReadAsync(string rootKey, CancellationToken cancellationToken) => Task.FromResult(document);

        public Task<QueryStoreWrite?> UpdateAsync(string rootKey, Func<byte[]?, QueryStoreUpdate?> update, CancellationToken cancellationToken)
        {
            if (update(document) is not { } next)
            {
                return Task.FromResult<QueryStoreWrite?>(null);
            }
            document = next.Document;
            return Task.FromResult<QueryStoreWrite?>(new QueryStoreWrite(true, false));
        }
    }

    [Test]
    public static async Task The_receipt_says_read_back_only_when_the_medium_gave_the_document_back()
    {
        var saved = await Library(new LossyStore()).SaveAsync(Root, Recipe("Relue", new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true))), null, null, 0, "update", null, CancellationToken.None);
        Check.False(saved.Receipt.ReadBack, "relecture différente : pas de « relue »");
        Check.Contains("diffère", saved.Receipt.Text, "le reçu le dit");
    }

    /// <summary>Another instance writes between our read and our write: the revision is checked against the medium.</summary>
    [Test]
    public static async Task A_revision_written_by_another_instance_is_never_overwritten()
    {
        var store = new MemoryQueryLibraryStore();
        var first = Library(store);
        var second = Library(store);
        var recipe = Recipe("Partagée", new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true)));
        var saved = await first.SaveAsync(Root, recipe, null, null, 0, "update", null, CancellationToken.None);
        _ = await second.ReadAsync(Root, CancellationToken.None);
        await first.SaveAsync(Root, saved.Record.Recipe with { Name = "Partagée v2" }, null, null, 1, "update", null, CancellationToken.None);
        var error = await Check.ThrowsAsync<QueryDefinitionException>(() => second.SaveAsync(Root, saved.Record.Recipe with { Name = "Partagée v2 bis" }, null, null, 1, "update", null, CancellationToken.None),
            "révision 1 dépassée par l’autre instance");
        Check.Contains("a changé", error.Message, "conflit de révision");
    }

    [Test]
    public static async Task The_document_budget_refuses_a_write_that_would_exceed_16_MiB_and_keeps_unreadable_entries()
    {
        var store = new MemoryQueryLibraryStore();
        // A document already near its budget: one unreadable entry, kept as it is by every write, of 16 Mio.
        var seed = "{\"format\":\"domenia.queryLibrary\",\"version\":2,\"generation\":1,\"recipes\":[],\"unreadable\":[{\"from\":\"recipes\",\"value\":\"" + new string('x', QueryLibrary.MaxDocumentBytes) + "\"}]}";
        await store.UpdateAsync(QueryLibrary.RootKey(Root), _ => new QueryStoreUpdate(Encoding.UTF8.GetBytes(seed), false), CancellationToken.None);
        var library = Library(store);
        Check.Equal(1, (await library.ReadAsync(Root, CancellationToken.None)).Unreadable, "entrée illisible comptée, conservée");
        var error = await Check.ThrowsAsync<QueryDefinitionException>(() => library.SaveAsync(Root, Recipe("De trop", new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true))), null, null, 0, "update", null, CancellationToken.None),
            "plafond de 16 Mio");
        Check.Contains("16 Mio", error.Message, "refus du budget, rien n’est écrit");
        Check.Equal(0, (await library.ReadAsync(Root, CancellationToken.None)).Records.Count, "aucune requête ajoutée");
    }

    [Test]
    public static async Task Archive_removes_the_widgets_in_the_same_write_and_restore_brings_them_back()
    {
        var library = Library();
        var recipe = Recipe("Avec widget", new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true)));
        var saved = await library.SaveAsync(Root, recipe, null, null, 0, "update", new QueryWidgetRequest("fleet", "kpi", "Actifs"), CancellationToken.None);
        Check.NotNull(saved.Widget, "widget lié dans la même écriture");
        var (archived, _, removed) = await library.ArchiveAsync(Root, saved.Record.Id, saved.Record.Revision, CancellationToken.None);
        Check.Equal(1, removed.Length, "widget retiré avec l’archivage");
        Check.Equal(0, (await library.ReadAsync(Root, CancellationToken.None)).Widgets.Count, "plus de widget actif");
        Check.Equal(1, archived.ArchivedWidgets.Length, "widget gardé avec l’archive");
        var (restored, _, back) = await library.RestoreAsync(Root, saved.Record.Id, archived.Revision, true, CancellationToken.None);
        Check.Equal(1, back.Length, "widget remis par la restauration, même sans liste fournie par la page");
        Check.Equal(restored.Revision, back[0].BoundRevision, "lié à la nouvelle révision");
    }

    // ---------- Impact review before rebinding widgets ----------

    [Test]
    public static async Task A_changed_definition_with_widgets_needs_the_impact_choice()
    {
        var bridge = new SimulatedBridge();
        var widget = await Ok(bridge, "requetes.widget.save", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + ",\"board\":\"fleet\",\"visual\":\"kpi\",\"title\":\"Disques\",\"expectedRevision\":0}");
        var changed = widget.GetProperty("recipe").GetRawText().Replace("\"value\":10", "\"value\":15", StringComparison.Ordinal);
        Check.Equal("query.impactRequired", await Refused(bridge, "requetes.library.save", "{\"recipe\":" + changed + ",\"expectedRevision\":1,\"mode\":\"update\"}"), "mise à jour sans choix refusée");
        Check.Equal("query.impactRequired", await Refused(bridge, "requetes.widget.save", "{\"recipe\":" + changed + ",\"board\":\"fleet\",\"visual\":\"text\",\"title\":\"Disques 2\",\"expectedRevision\":1}"), "widget.save n’impose jamais la migration");
        var copy = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + changed + ",\"expectedRevision\":1,\"mode\":\"copy\"}");
        Check.False(copy.GetProperty("id").GetString() == widget.GetProperty("id").GetString(), "copie indépendante");
        var list = await Ok(bridge, "requetes.widget.list");
        Check.Equal(1, list[0].GetProperty("boundRevision").GetInt64(), "le widget garde la révision enregistrée");
        var migrated = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + changed + ",\"expectedRevision\":1,\"mode\":\"migrate\"}");
        Check.Equal(1, migrated.GetProperty("migratedWidgets").GetInt32(), "widget mis à jour");
        var evaluated = await Ok(bridge, "requetes.widget.evaluate", Args(new { id = list[0].GetProperty("id").GetString() }));
        Check.False(evaluated.GetProperty("needsConfirmation").GetBoolean(), "évalué sur la révision liée, à jour");
    }

    [Test]
    public static async Task The_impact_review_lists_orphans_search_favourites_and_health_rules()
    {
        var bridge = new SimulatedBridge();
        var widget = await Ok(bridge, "requetes.widget.save", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + ",\"board\":\"computer\",\"visual\":\"text\",\"title\":\"Ce poste\",\"expectedRevision\":0}");
        var id = widget.GetProperty("id").GetString()!;
        await Ok(bridge, "requetes.consumer.bind", Args(new { kind = "search", id = "fav-1", recipeId = id, title = "Favori" }));
        await Ok(bridge, "requetes.consumer.bind", Args(new { kind = "health", id = "rule-1", recipeId = id, title = "Règle", scope = "OU=Postes,DC=example,DC=local" }));
        var users = QueryRecipe.Empty(QueryTarget.User) with { Id = id, Name = "Comptes" };
        var impact = await Ok(bridge, "requetes.library.impact", Args(new { id, recipe = JsonDocument.Parse(QueryRecipeJson.Write(users)).RootElement }));
        Check.Equal(1, impact.GetProperty("orphans").GetInt32(), "widget du poste incompatible avec la nouvelle cible");
        Check.Equal(1, impact.GetProperty("views").GetInt32(), "favori de Recherche");
        Check.Equal(1, impact.GetProperty("alerts").GetInt32(), "règle de santé");
        Check.True(impact.GetProperty("targetChanged").GetBoolean(), "changement de cible signalé");
    }

    // ---------- Exports ----------

    [Test]
    public static async Task Exports_are_prepared_by_the_engine_and_counted_again()
    {
        var bridge = new SimulatedBridge();
        var preview = await Ok(bridge, "requetes.preview", "{\"recipe\":" + RecipeJson("template.active.lowdisk") + "}");
        var json = await Ok(bridge, "requetes.preview.export", Args(new { evaluationId = preview.GetProperty("id").GetString(), verdict = "match", format = "json" }));
        Check.Equal(32, json.GetProperty("token").GetString()!.Length, "jeton d’export");
        Check.True(json.GetProperty("preview").GetString()!.Length <= 6000, "extrait seulement");
        var content = await Ok(bridge, "requetes.export.content", Args(new { token = json.GetProperty("token").GetString() }));
        using var rows = JsonDocument.Parse(content.GetProperty("content").GetString()!);
        Check.Equal(preview.GetProperty("counts").GetProperty("matched").GetInt32(), rows.RootElement.GetArrayLength(), "une entrée par correspondant");
        Check.True(rows.RootElement[0].TryGetProperty("clocks", out _), "dates des sources exportées");
        Check.Contains("\"secretsMasked\"", content.GetProperty("metadata").GetString(), "compteur des secrets masqués");
    }

    // ---------- Drafts ----------

    [Test]
    public static async Task A_resumed_draft_keeps_the_revision_it_comes_from()
    {
        var bridge = new SimulatedBridge();
        var saved = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + RecipeJson("template.stale") + ",\"expectedRevision\":0}");
        var id = saved.GetProperty("id").GetString();
        await Ok(bridge, "requetes.draft.keep", "{\"recipe\":" + saved.GetProperty("recipe").GetRawText() + ",\"base\":{\"id\":\"" + id + "\",\"source\":\"personal\",\"revision\":1}}");
        var draft = await Ok(bridge, "requetes.draft.get");
        Check.Equal(id, draft.GetProperty("base").GetProperty("id").GetString(), "lien vers la requête enregistrée");
        Check.Equal(1, draft.GetProperty("base").GetProperty("revision").GetInt64(), "révision de départ");
        var second = await Ok(bridge, "requetes.library.save", "{\"recipe\":" + saved.GetProperty("recipe").GetRawText().Replace("\"name\":\"", "\"name\":\"B ", StringComparison.Ordinal) + ",\"expectedRevision\":1}");
        Check.Equal(2, second.GetProperty("revision").GetInt64(), "enregistrement depuis le brouillon repris");
    }

    // ---------- LDAP semantics ----------

    [Test]
    public static void Negations_on_an_absent_attribute_follow_LDAP()
    {
        var reading = QueryLdap.Read("(&(objectCategory=computer)(!(description=x)))", QueryRecipe.Empty(QueryTarget.Computer));
        Check.True(reading.Valid, "filtre lu");
        var compiled = QueryEngine.Compile(reading.Recipe!);
        var computer = Fixtures.Computer("PC-SANS-DESCRIPTION") with { Description = null };
        var dataset = new QueryDataset(Fixtures.Snapshot(computers: [computer]), FleetObservations.Empty, ImmutableDictionary<Guid, ImmutableArray<ProbeReading>>.Empty,
            ImmutableDictionary<Guid, ConsoleReading>.Empty, ImmutableDictionary<Guid, char>.Empty, ImmutableDictionary<Guid, ImmutableArray<StoredWmiResult>>.Empty, 1, "test", true);
        var record = QueryRecordBuilder.Build(dataset, QueryTarget.Computer, null, TestClock.Reference)[0];
        var context = new QueryEvaluationContext(new DirectoryLdapChain(dataset.Directory), TestClock.Reference);
        Check.Equal(MatchState.Match, compiled.Evaluate(record, context), "(!(description=x)) vrai sans description, comme LDAP");
        var contains = QueryEngine.Compile(QueryLdap.Read("(&(objectCategory=computer)(!(description=*k*)))", QueryRecipe.Empty(QueryTarget.Computer)).Recipe!);
        Check.Equal(MatchState.Match, contains.Evaluate(record, context), "(!(description=*k*)) vrai sans description");
        Check.Equal(MatchState.Match, LdapEvaluator.Evaluate(LdapFilterText.Parse("(!(description=*k*))"), record.Entry, context.Chain), "même verdict que l’évaluateur LDAP");
        var translation = QueryLdap.Translate(contains.Resolved, TestClock.Reference);
        Check.True(translation.Exact, "traduction exacte : mêmes correspondants");
    }

    [Test]
    public static void A_negation_on_an_information_unknown_when_absent_is_not_claimed_exact()
    {
        var recipe = QueryRecipe.Empty(QueryTarget.Computer) with
        {
            Name = "Non",
            Expression = QueryNode.Group(QueryNodeKind.Not, [QueryNode.Leaf(new QueryClause("logonDays", QueryOperator.Greater, QueryValue.FromNumber(90)))]),
        };
        var translation = QueryLdap.Translate(QueryEngine.Compile(recipe).Resolved, TestClock.Reference);
        Check.False(translation.Exact, "NON sur une information inconnue quand elle manque : évalué localement");
        Check.True(translation.Residual.Length > 0, "condition locale listée");
    }

    [Test]
    public static void The_company_attribute_is_never_invented()
    {
        var user = DirectoryLdapEntry.From(Fixtures.User("c.bernard"), Fixtures.Domain);
        Check.Equal(LdapPresence.NotRead, user.Get(LdapSchema.Find("company")!, out _), "company non conservé : indéfini, jamais « Example »");
    }

    [Test]
    public static void The_in_chain_rule_stops_on_cycles_and_depth()
    {
        string Dn(int i) => "CN=G" + i.ToString(System.Globalization.CultureInfo.InvariantCulture) + ",OU=Groupes,DC=example,DC=local";
        var groups = Enumerable.Range(0, 40).Select(i => new DirectoryGroup(Fixtures.IdOf("g" + i), "S-1-5-21-1-2-3-" + (2000 + i).ToString(System.Globalization.CultureInfo.InvariantCulture), Dn(i), "G" + i, "G" + i,
            -2147483646, null, null, null, null, [], [Dn((i + 1) % 40)], TestClock.Reference, TestClock.Reference, 1)).ToList();
        var snapshot = Fixtures.Snapshot() with { Groups = [.. groups] };
        var chain = new DirectoryLdapChain(snapshot);
        var entry = DirectoryLdapEntry.From(groups[0], Fixtures.Domain);
        var memberOf = LdapSchema.Find("memberOf")!;
        Check.True(chain.Reaches(entry, memberOf, Dn(5)), "chaîne courte suivie");
        Check.False(chain.Reaches(entry, memberOf, "CN=Ailleurs,DC=example,DC=local"), "cycle parcouru sans boucler, cible absente");
        Check.False(chain.Reaches(entry, memberOf, Dn(39)), "au-delà de 32 niveaux : non suivi (profondeur bornée)");
    }

    // ---------- Collections and limits ----------

    [Test]
    public static void Collections_on_an_empty_or_partial_collection_are_three_valued()
    {
        var probe = QueryProbeCatalog.All.First(p => p.Mode == "All");
        var property = probe.Properties[0];
        string Field() => QueryCatalog.InstancePrefix + probe.Id + ":" + property;
        QueryRecipe With(CollectionQuantifier quantifier) => QueryRecipe.Empty(QueryTarget.Computer) with
        {
            Name = "Collection",
            Expression = QueryNode.Collection(QueryCatalog.ProbePrefix + probe.Id, quantifier, QueryNode.Leaf(new QueryClause(Field(), QueryOperator.IsPresent, QueryValue.None))),
        };
        var record = new QueryRecord(Guid.NewGuid().ToString("D"), QueryTarget.Computer, "PC", "CN=PC,DC=example,DC=local", DirectoryLdapEntry.From(Fixtures.Computer("PC"), Fixtures.Domain));
        var context = new QueryEvaluationContext(null, TestClock.Reference);
        record.Collections[probe.Id] = new QueryCollection([], Complete: true);
        Check.Equal(MatchState.Match, QueryEngine.Compile(With(CollectionQuantifier.All)).Evaluate(record, context), "toutes : vrai sur une collection vide complète");
        Check.Equal(MatchState.Match, QueryEngine.Compile(With(CollectionQuantifier.None)).Evaluate(record, context), "aucune : vrai sur une collection vide complète");
        Check.Equal(MatchState.NoMatch, QueryEngine.Compile(With(CollectionQuantifier.Any)).Evaluate(record, context), "au moins une : faux sur une collection vide complète");
        record.Collections[probe.Id] = new QueryCollection([], Complete: false);
        Check.Equal(MatchState.Unknown, QueryEngine.Compile(With(CollectionQuantifier.All)).Evaluate(record, context), "collection partielle : inconnu");
    }

    [Test]
    public static void The_limits_of_Domenia_1_are_kept()
    {
        var clause = new QueryClause("active", QueryOperator.Equal, QueryValue.FromBoolean(true));
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(Recipe("65", [.. Enumerable.Repeat(clause, 65)])), "64 conditions au plus");
        var deep = QueryNode.Leaf(clause);
        for (var i = 0; i < 9; i++)
        {
            deep = QueryNode.Group(QueryNodeKind.All, [deep]);
        }
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Profond", Expression = deep }), "8 niveaux au plus");
        var wide = QueryNode.Group(QueryNodeKind.All, Enumerable.Range(0, 20).Select(_ => QueryNode.Group(QueryNodeKind.Any, Enumerable.Range(0, 13).Select(_ => QueryNode.Group(QueryNodeKind.All, [])))));
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Large", Expression = wide }), "256 éléments au plus");
        var parameters = Enumerable.Range(0, 33).Select(i => new QueryParameter("P" + i.ToString(System.Globalization.CultureInfo.InvariantCulture), "diskFreePercent", QueryValue.FromNumber(10), null, null, null)).ToImmutableArray();
        Check.Throws<QueryDefinitionException>(() => QueryEngine.Compile(QueryRecipe.Empty() with { Name = "Paramètres", Parameters = parameters }), "32 paramètres au plus");
    }

    // ---------- Coherence window, costs, SELECT re-read ----------

    [Test]
    public static async Task The_proposed_window_stays_within_24_hours_for_an_instantaneous_measure()
    {
        var bridge = new SimulatedBridge();
        var recipe = QueryRecipe.Empty(QueryTarget.Computer) with
        {
            Name = "Présence et disque",
            Clauses = [new QueryClause("presenceBucket", QueryOperator.Equal, QueryValue.FromText("En ligne")), new QueryClause("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(50))],
        };
        var coverage = await Ok(bridge, "requetes.coverage", "{\"recipe\":" + QueryRecipeJson.Write(recipe) + "}");
        var proposal = coverage.GetProperty("proposal");
        if (proposal.GetProperty("hours").ValueKind == JsonValueKind.Number)
        {
            Check.True(proposal.GetProperty("hours").GetDecimal() <= 24, "mesure instantanée : 24 h au plus");
        }
    }

    [Test]
    public static async Task The_collection_plan_rereads_the_saved_SELECT_and_counts_its_cost()
    {
        var bridge = new SimulatedBridge();
        var found = await Ok(bridge, "requetes.objects.find", "{\"text\":\"PC-PAR\",\"target\":\"computer\"}");
        var computer = found[0].GetProperty("id").GetString()!;
        const string query = "SELECT DeviceID, FreeSpace FROM Win32_LogicalDisk";
        await Ok(bridge, "requetes.wmi.run", Args(new { computer, @namespace = "root\\cimv2", query, limit = 100 }));
        var recipe = await Ok(bridge, "requetes.wmi.recipe", Args(new { computer, @namespace = "root\\cimv2", query, limit = 100 }));
        await Ok(bridge, "requetes.scope.set", Args(new { dn = await RequetesOperationsTests.WorkstationsOuAsync(bridge), subtree = true }));
        var plan = await Ok(bridge, "requetes.collect.plan", "{\"recipe\":" + recipe.GetProperty("recipe").GetRawText() + "}");
        Check.True(plan.GetProperty("plan").GetProperty("workload").GetProperty("detailReads").GetInt64() > 0, "SELECT mémorisé relu sur les postes du plan");
        Check.NotNull(plan.GetProperty("plan").GetProperty("detail").GetProperty("requestKey").GetString(), "définition jointe au plan");
        Check.True(plan.GetProperty("plan").GetProperty("workload").GetProperty("level").GetString() is "Modéré" or "Élevé", "lecture WMI avancée : coût au moins modéré");
        var run = await Ok(bridge, "requetes.collect.run", Args(new { ticket = plan.GetProperty("ticket").GetString() }));
        Check.Contains("Relevé", run.GetProperty("text").GetString(), "relevé fait");
        var stored = await Ok(bridge, "requetes.details.list", "{\"offset\":0,\"limit\":250}");
        Check.True(stored.GetProperty("total").GetInt32() > 1, "résultats mémorisés sur plusieurs postes");
    }

    /// <summary>Active computers whose relevé of C: is missing: each one is a target of the plan.</summary>
    private static List<QueryRecord> Unmeasured(int count) =>
        [.. Enumerable.Range(0, count).Select(i =>
        {
            var name = "PC-" + i.ToString("D4", System.Globalization.CultureInfo.InvariantCulture);
            var record = new QueryRecord(Fixtures.IdOf(name).ToString("D"), QueryTarget.Computer, name, "CN=" + name + ",OU=Postes,DC=example,DC=local", DirectoryLdapEntry.From(Fixtures.Computer(name), Fixtures.Domain));
            record.Values["active"] = true;
            return record;
        })];

    [Test]
    public static void The_collection_cost_follows_the_bands_of_Domenia_1()
    {
        var compiled = QueryEngine.Compile(Recipe("Disque", new QueryClause("diskFreePercent", QueryOperator.Less, QueryValue.FromNumber(10))));
        var context = new QueryEvaluationContext(null, TestClock.Reference);
        string Level(int count) => QueryAnalysis.CollectPlan(compiled, Unmeasured(count), context, TestClock.Reference).Workload.Level;
        Check.Equal("Faible", Level(100), "100 postes : coût faible (bande de 100 non dépassée)");
        Check.Equal("Modéré", Level(101), "plus de 100 postes : coût modéré");
        Check.Equal("Modéré", Level(500), "500 postes : encore modéré");
        Check.Equal("Élevé", Level(501), "plus de 500 postes : coût élevé");
        var plan = QueryAnalysis.CollectPlan(compiled, Unmeasured(3), context, TestClock.Reference);
        Check.Equal(3, plan.Targets.Length, "chaque poste sans relevé est relu");
        Check.Equal(0L, plan.Workload.DetailReads, "aucune lecture WMI avancée sans SELECT mémorisé");
        Check.Contains("Durée non estimée", plan.Text, "aucune durée inventée");
    }

    // ---------- Packs beyond one message ----------

    [Test]
    public static async Task A_pack_larger_than_one_message_is_sent_in_parts()
    {
        var bridge = new SimulatedBridge();
        var big = new StringBuilder("{\"Format\":\"Domenia.QueryPack/3\",\"Padding\":\"");
        big.Append('x', 950_000).Append("\"}");
        var text = big.ToString();
        string? upload = null;
        var count = (text.Length + 399_999) / 400_000;
        for (var i = 0; i < count; i++)
        {
            var part = await Ok(bridge, "requetes.pack.part", Args(new { upload, index = i, count, text = text.Substring(i * 400_000, Math.Min(400_000, text.Length - (i * 400_000))) }));
            upload = part.GetProperty("upload").GetString();
        }
        Check.Equal("query.packInvalid", await Refused(bridge, "requetes.pack.examine", Args(new { upload })), "pack de plus de 900 Ko reçu puis examiné (ici refusé : sans recettes)");
        Check.Equal("query.packInvalid", await Refused(bridge, "requetes.pack.examine", Args(new { upload })), "un envoi ne s’examine qu’une fois");
    }
}
