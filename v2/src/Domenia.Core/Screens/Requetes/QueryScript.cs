using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Domenia.Core.Queries;

/// <summary>
/// Readable, commented PowerShell 5.1 script of one recipe (Domenia 1 ConvertTo-DomeniaQueryPowerShell, made standalone):
/// it reads the directory part with Get-ADComputer, Get-ADUser or Get-ADGroup -LDAPFilter, read only, bounded by a search
/// base and a result size. The recipe is embedded as an ASCII JSON data literal; the script holds no credential, writes
/// nothing and is never run by the export. Conditions computed by Domenia (readings, probes) are listed, not evaluated.
/// </summary>
public static partial class QueryScript
{
    [GeneratedRegex(@"[\p{Cc}\p{Zl}\p{Zp}\u0085]+", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex LineBreaks();

    /// <summary>One comment line: no line terminator or control character can end the comment.</summary>
    public static string Comment(string text, int maxLength = 400)
    {
        var clean = LineBreaks().Replace(text ?? "", " ").Trim();
        return clean.Length > maxLength ? clean[..maxLength] + "…" : clean;
    }

    /// <summary>Every non-ASCII character as a JSON \u escape: typographic quotes can never close the single-quoted literal.</summary>
    public static string AsciiJson(string json)
    {
        ArgumentNullException.ThrowIfNull(json);
        var builder = new StringBuilder(json.Length + 64);
        foreach (var c in json)
        {
            if (c < 32 || c > 126)
            {
                builder.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
            }
            else
            {
                builder.Append(c);
            }
        }
        return builder.ToString();
    }

    /// <summary>PowerShell single-quoted literal, every non-ASCII character spelled [char] so the file reads the same in any code page.</summary>
    public static string Literal(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var parts = new List<string>();
        var current = new StringBuilder();
        void Flush()
        {
            if (current.Length > 0)
            {
                parts.Add("'" + current.ToString().Replace("'", "''", StringComparison.Ordinal) + "'");
                current.Clear();
            }
        }
        foreach (var c in text)
        {
            if (c is < ' ' or > '~' || c is '‘' or '’' or '‚' or '‛')
            {
                Flush();
                parts.Add("[char]0x" + ((int)c).ToString("X4", CultureInfo.InvariantCulture));
            }
            else
            {
                current.Append(c);
            }
        }
        Flush();
        return parts.Count == 0 ? "''" : parts.Count == 1 ? parts[0] : "(" + string.Join(" + ", parts) + ")";
    }

    public static string Cmdlet(QueryTarget target) => target switch
    {
        QueryTarget.User => "Get-ADUser",
        QueryTarget.Group => "Get-ADGroup",
        _ => "Get-ADComputer",
    };

    /// <summary>One-line command equivalent to the directory part of a recipe (transparency, copy).</summary>
    public static string Command(CompiledQuery query, LdapTranslation ldap, string? searchBase)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(ldap);
        var properties = Properties(query);
        return Cmdlet(query.Target) + " -LDAPFilter " + Literal(ldap.PreFilter) + (string.IsNullOrEmpty(searchBase) ? "" : " -SearchBase " + Literal(searchBase) + " -SearchScope Subtree")
            + " -ResultSetSize 5000" + (properties.Count > 0 ? " -Properties " + string.Join(",", properties) : "");
    }

    private static List<string> Properties(CompiledQuery query) =>
        query.RequestedFields.Select(f => QueryCatalog.Find(query.Target, f, query.Resolved.ReadDefinition)?.LdapAttribute).OfType<string>()
            .SelectMany(a => a.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            .Where(a => Ldap.LdapSchema.Find(a) is not null).Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase).ToList();

    /// <summary>Field metadata embedded in the script: kind, absent-is-false (plain directory attribute) and clock of each information.</summary>
    private static string FieldTable(CompiledQuery query)
    {
        var builder = new StringBuilder("{");
        var first = true;
        var ids = query.RequestedFields.Concat(QueryRecipeWalk.Clauses(query.Normalized).Select(c => c.Field)).Concat(query.Normalized.Parameters.Select(p => p.Field))
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal);
        foreach (var id in ids)
        {
            if (QueryCatalog.Find(query.Target, id, query.Resolved.ReadDefinition) is not { } field)
            {
                continue;
            }
            builder.Append(first ? "" : ",").Append(System.Text.Json.JsonSerializer.Serialize(id)).Append(":{\"Kind\":\"").Append(field.Kind.ToString())
                .Append("\",\"Plain\":").Append(QueryLdap.AbsentIsFalse(field) ? "true" : "false")
                .Append(",\"Local\":").Append(field.Source is QuerySource.Ldap or QuerySource.Instance ? "false" : "true")
                .Append(",\"Clock\":").Append(System.Text.Json.JsonSerializer.Serialize(field.Clock)).Append('}');
            first = false;
        }
        return builder.Append('}').ToString();
    }

    /// <summary>
    /// The whole script (CRLF), ready to be saved with a UTF-8 byte order mark (Domenia 1 ConvertTo-DomeniaQueryPowerShell, made
    /// standalone). Two uses, never run by the export: <c>-RecordsPath</c> evaluates the whole recipe (conditions, tree, segment,
    /// parameters with <c>-ParameterValues</c>, coherence window) on a Domenia JSON export, three-valued like the workshop;
    /// <c>-SearchBase</c> reads the directory candidates in read only (Get-AD* -LDAPFilter).
    /// </summary>
    public static string PowerShell(CompiledQuery query, LdapTranslation ldap, DateTimeOffset exportedAt)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(ldap);
        var recipe = query.Normalized;
        var lines = new List<string>();
        void Note(string text)
        {
            var indent = text.Length - text.TrimStart(' ').Length;
            lines.Add(("# " + new string(' ', indent) + Comment(text)).TrimEnd());
        }
        lines.Add("#requires -Version 5.1");
        Note("===== Requête Domenia exportée =====");
        Note("Nom : " + recipe.Name);
        Note("Identifiant : " + recipe.Id + " · format " + recipe.MinimalFormat() + " · cible : " + QueryTexts.TargetLabel(recipe.Target));
        Note("Exportée le " + exportedAt.UtcDateTime.ToString("dd'/'MM'/'yyyy HH':'mm", CultureInfo.InvariantCulture) + " UTC. L’export n’a rien exécuté : relisez puis lancez ce script vous-même.");
        lines.Add("#");
        Note("Ce script n’écrit rien et ne contient ni identifiant ni secret. Deux usages :");
        Note("  1. -RecordsPath : évalue toute la requête (conditions, groupes, segment, paramètres, fenêtre de cohérence) sur un export JSON de Domenia,");
        Note("     sans aucune connexion. Une information absente, expirée ou incomplète donne Inconnu, jamais Faux ni zéro (sauf un attribut AD vide).");
        Note("  2. -SearchBase : lit en lecture seule les candidats de l’annuaire (" + Cmdlet(recipe.Target) + " -LDAPFilter), bornés par la base et -ResultSetSize.");
        lines.Add("#");
        Note("Conditions :");
        foreach (var (element, values) in QueryAnalysis.Summary(recipe))
        {
            if (element is "Nom" or "Cible")
            {
                continue;
            }
            foreach (var value in values)
            {
                Note("  " + element + " : " + value);
            }
        }
        lines.Add("#");
        Note("Filtre LDAP envoyé au contrôleur (usage 2) : " + ldap.PreFilter);
        if (ldap.Residual.Length > 0)
        {
            Note("Conditions que l’usage 2 laisse à Domenia (l’usage 1 les évalue sur l’export) :");
            foreach (var item in ldap.Residual)
            {
                Note("  - " + item);
            }
        }
        foreach (var note in ldap.Notes)
        {
            Note("Remarque : " + note);
        }
        lines.Add("#");
        Note("Informations utilisées et sources :");
        foreach (var id in query.RequestedFields)
        {
            if (QueryCatalog.Find(recipe.Target, id, recipe.ReadDefinition) is { } field)
            {
                Note("  - " + field.Name + " (" + id + ") : " + field.SourceLabel + " · " + field.Freshness);
            }
        }
        var parameters = QueryEngine.ParameterRows(recipe);
        Note("Paramètres de la recette (modifiables avec -ParameterValues @{ Nom = valeur } pour l’usage 1) :");
        if (parameters.Length == 0)
        {
            Note("  (aucun)");
        }
        foreach (var parameter in parameters)
        {
            Note("  - " + parameter.Name + " : " + parameter.Label + " (" + parameter.FieldName + ") = " + parameter.ValueLabel);
        }
        lines.Add("#");
        Note("Limites :");
        Note("  - Le résultat ne vaut que pour l’instantané fourni : ses dates et son périmètre restent ceux de l’aperçu exporté.");
        Note("  - Les collections d’instances de sonde et les attributs LDAP bruts ne sont pas dans l’export : leurs conditions restent Inconnues.");
        Note("  - Les dates relatives du filtre LDAP (usage 2) sont converties à l’export : exportez de nouveau pour les recalculer.");
        Note("  - 64 conditions et 8 niveaux de groupes au plus ; aucune collecte n’est déclenchée.");
        lines.Add("#");
        Note("Sortie (usage 1) : un objet par objet retenu (Id, Nom, CheminAD, Verdict, Valeurs, Etats). -Selection choisit Match, Unknown, NoMatch ou All.");
        Note("Exemples : .\\requete.ps1 -RecordsPath .\\export.json -Selection Unknown");
        Note("           .\\requete.ps1 -SearchBase 'OU=Postes,DC=example,DC=local' -Server dc01.example.local");
        lines.Add("[CmdletBinding(DefaultParameterSetName = 'Instantane')]");
        lines.Add("param(");
        lines.Add("    [Parameter(ParameterSetName = 'Instantane', Mandatory = $true)][string]$RecordsPath,");
        lines.Add("    [Parameter(ParameterSetName = 'Objets', Mandatory = $true)][object[]]$Records,");
        lines.Add("    [Parameter(ParameterSetName = 'Instantane')][Parameter(ParameterSetName = 'Objets')][ValidateSet('Match', 'Unknown', 'NoMatch', 'All')][string]$Selection = 'Match',");
        lines.Add("    [Parameter(ParameterSetName = 'Instantane')][Parameter(ParameterSetName = 'Objets')][hashtable]$ParameterValues = @{},");
        lines.Add("    [Parameter(ParameterSetName = 'Annuaire', Mandatory = $true)][string]$SearchBase,");
        lines.Add("    [Parameter(ParameterSetName = 'Annuaire')][string]$Server,");
        lines.Add("    [Parameter(ParameterSetName = 'Annuaire')][ValidateRange(1, 200000)][int]$ResultSetSize = 5000,");
        lines.Add("    [switch]$ShowDefinition");
        lines.Add(")");
        lines.Add("$ErrorActionPreference = 'Stop'");
        lines.Add("$definition = '" + AsciiJson(QueryRecipeJson.Write(recipe)).Replace("'", "''", StringComparison.Ordinal) + "'");
        lines.Add("$fieldTable = '" + AsciiJson(FieldTable(query)).Replace("'", "''", StringComparison.Ordinal) + "'");
        lines.Add("$clockList = @(" + string.Join(", ", query.Clocks.Select(c => "'" + c.Replace("'", "''", StringComparison.Ordinal) + "'")) + ")");
        lines.Add("$recipe = ConvertFrom-Json -InputObject $definition");
        lines.Add("if ($ShowDefinition) { $recipe | ConvertTo-Json -Depth 32; return }");
        lines.Add("if ($PSCmdlet.ParameterSetName -eq 'Annuaire') {");
        lines.Add("    Import-Module ActiveDirectory -ErrorAction Stop");
        lines.Add("    $ldapFilter = " + Literal(ldap.PreFilter));
        var properties = Properties(query);
        lines.Add("    $properties = @(" + string.Join(", ", properties.Select(p => "'" + p + "'")) + ")");
        lines.Add("    $query = @{ LDAPFilter = $ldapFilter; SearchBase = $SearchBase; SearchScope = 'Subtree'; ResultSetSize = $ResultSetSize; Properties = $properties }");
        lines.Add("    if ($Server) { $query.Server = $Server }");
        lines.Add("    " + Cmdlet(recipe.Target) + " @query | Select-Object -Property (@('Name', 'DistinguishedName') + $properties)");
        lines.Add("    return");
        lines.Add("}");
        foreach (var line in Evaluator.Replace("\r", "", StringComparison.Ordinal).Split('\n'))
        {
            lines.Add(line);
        }
        while (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }
        return string.Join("\r\n", lines) + "\r\n";
    }

    // Three-valued evaluator of a recipe on exported records (Windows PowerShell 5.1: no ternary, no ??, no typographic
    // quotes in code). Same rules as Domenia.Core: Kleene logic, absent value unknown except for a plain directory attribute.
    private const string Evaluator = """
$meta = ConvertFrom-Json -InputObject $fieldTable
function Get-DomeniaMember($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-DomeniaList($Object, [string]$Name) {
    $value = Get-DomeniaMember $Object $Name
    if ($null -eq $value) { return ,@() }
    return ,@($value)
}
function ConvertTo-DomeniaTyped($Value, [string]$Kind, [string]$Label) {
    if ($null -eq $Value) { return $null }
    if ($Kind -eq 'Number') {
        if ($Value -is [string]) {
            $parsed = [decimal]0
            $text = $Value.Trim().Replace(',', '.')
            if (-not [decimal]::TryParse($text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { throw ('Nombre attendu pour ' + $Label + ' : ' + $Value) }
            return $parsed
        }
        return [decimal]$Value
    }
    if ($Kind -eq 'Boolean') {
        if ($Value -is [bool]) { return $Value }
        $flag = ([string]$Value).Trim().ToLowerInvariant()
        if (@('true', 'vrai', 'oui', '1') -contains $flag) { return $true }
        if (@('false', 'faux', 'non', '0') -contains $flag) { return $false }
        throw ('Oui ou Non attendu pour ' + $Label + ' : ' + $Value)
    }
    return [string]$Value
}
function Get-DomeniaKind([string]$Field) {
    $info = Get-DomeniaMember $meta $Field
    if ($null -eq $info) { return 'Text' }
    return [string]$info.Kind
}
$known = @{}
foreach ($parameter in (Get-DomeniaList $recipe 'Parameters')) { $known[[string]$parameter.Name] = $parameter }
foreach ($key in $ParameterValues.Keys) { if (-not $known.ContainsKey([string]$key)) { throw ('Parametre inconnu pour cette requete : ' + [string]$key) } }
$effective = @{}
foreach ($parameter in (Get-DomeniaList $recipe 'Parameters')) {
    $name = [string]$parameter.Name
    $value = Get-DomeniaMember $parameter 'Default'
    $given = Get-DomeniaMember $recipe 'ParameterValues'
    if ($null -ne (Get-DomeniaMember $given $name)) { $value = Get-DomeniaMember $given $name }
    if ($ParameterValues.ContainsKey($name)) { $value = $ParameterValues[$name] }
    $typed = ConvertTo-DomeniaTyped $value (Get-DomeniaKind ([string]$parameter.Field)) $name
    $minimum = Get-DomeniaMember $parameter 'Minimum'
    $maximum = Get-DomeniaMember $parameter 'Maximum'
    if ($null -ne $minimum -and $typed -lt [decimal]$minimum) { throw ('Valeur trop petite pour ' + $name) }
    if ($null -ne $maximum -and $typed -gt [decimal]$maximum) { throw ('Valeur trop grande pour ' + $name) }
    $effective[$name] = $typed
}
function Resolve-DomeniaValue($Value, [string]$Kind, [string]$Label) {
    $reference = $null
    if ($null -ne $Value -and $Value -isnot [string] -and $Value -isnot [bool] -and $Value -isnot [ValueType]) { $reference = Get-DomeniaMember $Value 'Parameter' }
    if ($null -ne $reference) { return $effective[[string]$reference] }
    return ConvertTo-DomeniaTyped $Value $Kind $Label
}
function Join-DomeniaAll([object[]]$States) {
    $unknown = $false
    foreach ($state in $States) { if ($state -eq 'NoMatch') { return 'NoMatch' }; if ($state -eq 'Unknown') { $unknown = $true } }
    if ($unknown) { return 'Unknown' }
    return 'Match'
}
function Join-DomeniaAny([object[]]$States) {
    $unknown = $false
    foreach ($state in $States) { if ($state -eq 'Match') { return 'Match' }; if ($state -eq 'Unknown') { $unknown = $true } }
    if ($unknown) { return 'Unknown' }
    return 'NoMatch'
}
function Get-DomeniaNegation([string]$State) {
    if ($State -eq 'Match') { return 'NoMatch' }
    if ($State -eq 'NoMatch') { return 'Match' }
    return 'Unknown'
}
function Test-DomeniaClause($Clause, $Row) {
    $field = [string]$Clause.Field
    $operator = [string]$Clause.Operator
    $info = Get-DomeniaMember $meta $field
    if ($null -eq $info -or -not $info.Local) { return 'Unknown' }
    $value = Get-DomeniaMember (Get-DomeniaMember $Row 'values') $field
    if ($operator -eq 'IsMissing') { if ($null -eq $value) { return 'Match' }; return 'NoMatch' }
    if ($operator -eq 'IsPresent') { if ($null -eq $value) { return 'NoMatch' }; return 'Match' }
    if ($null -eq $value) {
        if ($info.Plain) { if ($operator -eq 'NotEqual') { return 'Match' }; return 'NoMatch' }
        return 'Unknown'
    }
    $kind = [string]$info.Kind
    $expected = Resolve-DomeniaValue (Get-DomeniaMember $Clause 'Value') $kind $field
    if ($null -eq $expected) { return 'Unknown' }
    $result = $false
    if ($kind -eq 'Number') {
        $number = [decimal]$value
        $limit = [decimal]$expected
        switch ($operator) {
            'Equal' { $result = $number -eq $limit }
            'NotEqual' { $result = $number -ne $limit }
            'Greater' { $result = $number -gt $limit }
            'GreaterOrEqual' { $result = $number -ge $limit }
            'Less' { $result = $number -lt $limit }
            'LessOrEqual' { $result = $number -le $limit }
        }
    } elseif ($kind -eq 'Boolean') {
        if ($operator -eq 'NotEqual') { $result = ([bool]$value) -ne ([bool]$expected) } else { $result = ([bool]$value) -eq ([bool]$expected) }
    } else {
        $text = [string]$value
        $wanted = [string]$expected
        switch ($operator) {
            'Equal' { $result = [string]::Equals($text, $wanted, [StringComparison]::OrdinalIgnoreCase) }
            'NotEqual' { $result = -not [string]::Equals($text, $wanted, [StringComparison]::OrdinalIgnoreCase) }
            'Contains' { $result = $text.IndexOf($wanted, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
            'StartsWith' { $result = $text.StartsWith($wanted, [StringComparison]::OrdinalIgnoreCase) }
            'EndsWith' { $result = $text.EndsWith($wanted, [StringComparison]::OrdinalIgnoreCase) }
        }
    }
    if ($result) { return 'Match' }
    return 'NoMatch'
}
function Test-DomeniaNode($Node, $Row) {
    $kind = [string]$Node.Kind
    if ($kind -eq 'Clause') { return Test-DomeniaClause $Node.Clause $Row }
    if ($kind -eq 'Collection') { return 'Unknown' }
    $children = Get-DomeniaList $Node 'Children'
    if ($kind -eq 'Not') { return Get-DomeniaNegation (Test-DomeniaNode $children[0] $Row) }
    $states = @(foreach ($child in $children) { Test-DomeniaNode $child $Row })
    if ($kind -eq 'Any') { return Join-DomeniaAny $states }
    return Join-DomeniaAll $states
}
$selection = @{}
foreach ($id in (Get-DomeniaList $recipe 'ObjectIds')) { $selection[([guid][string]$id).ToString('D')] = $true }
function Test-DomeniaPopulation($Row) {
    if ($selection.Count -gt 0) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([string](Get-DomeniaMember $Row 'id'), [ref]$guid) -or -not $selection.ContainsKey($guid.ToString('D'))) { return $false }
    }
    $segment = Get-DomeniaMember $recipe 'ProbeSelection'
    if ($null -ne $segment) {
        $value = Get-DomeniaMember (Get-DomeniaMember $Row 'values') ('probe:' + [string]$segment.Key)
        if ($null -eq $value) { return $false }
        $mode = [string]$segment.Mode
        if ($mode -eq 'Equal' -and -not [string]::Equals([string]$value, [string]$segment.Value, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($mode -eq 'Range') {
            $number = [decimal]$value
            if ($null -ne (Get-DomeniaMember $segment 'Low') -and $number -lt [decimal]$segment.Low) { return $false }
            if ($null -ne (Get-DomeniaMember $segment 'High') -and $number -ge [decimal]$segment.High) { return $false }
        }
        if ($mode -eq 'Other') { foreach ($excluded in (Get-DomeniaList $segment 'Excluded')) { if ([string]::Equals([string]$value, [string]$excluded, [StringComparison]::OrdinalIgnoreCase)) { return $false } } }
    }
    foreach ($clause in (Get-DomeniaList $recipe 'Refinements')) { if ((Test-DomeniaClause $clause $Row) -ne 'Match') { return $false } }
    return $true
}
function Get-DomeniaVerdict($Row) {
    $parts = @()
    $clauses = Get-DomeniaList $recipe 'Clauses'
    if ($clauses.Count -gt 0) {
        $states = @(foreach ($clause in $clauses) { Test-DomeniaClause $clause $Row })
        if ([string]$recipe.Junction -eq 'Any') { $parts += Join-DomeniaAny $states } else { $parts += Join-DomeniaAll $states }
    }
    $tree = Get-DomeniaMember $recipe 'Expression'
    if ($null -ne $tree) { $parts += Test-DomeniaNode $tree $Row }
    $verdict = Join-DomeniaAll $parts
    $hours = Get-DomeniaMember $recipe 'CoherenceHours'
    if ($null -ne $hours) {
        $dates = @()
        foreach ($clock in $clockList) {
            $at = Get-DomeniaMember (Get-DomeniaMember $Row 'clocks') $clock
            if ($null -eq $at) { return 'Unknown' }
            $dates += [DateTimeOffset]::Parse([string]$at, [Globalization.CultureInfo]::InvariantCulture)
        }
        if ($dates.Count -gt 1) {
            $sorted = @($dates | Sort-Object)
            if (($sorted[$sorted.Count - 1] - $sorted[0]).TotalHours -gt [double]$hours) { return 'Unknown' }
        }
    }
    return $verdict
}
if ($PSCmdlet.ParameterSetName -eq 'Instantane') {
    # Windows PowerShell 5.1 returns a JSON array as one object: it is enumerated explicitly.
    $parsed = Get-Content -LiteralPath $RecordsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $Records = @(foreach ($item in $parsed) { $item })
}
$labels = @{ Match = 'Correspond'; Unknown = 'Inconnu'; NoMatch = 'Ne correspond pas' }
$counts = @{ Match = 0; Unknown = 0; NoMatch = 0 }
foreach ($row in @($Records)) {
    if ($null -eq $row -or -not (Test-DomeniaPopulation $row)) { continue }
    $state = Get-DomeniaVerdict $row
    $counts[$state] = $counts[$state] + 1
    if ($Selection -ne 'All' -and $state -ne $Selection) { continue }
    [pscustomobject]@{ Id = [string](Get-DomeniaMember $row 'id'); Nom = [string](Get-DomeniaMember $row 'name'); CheminAD = [string](Get-DomeniaMember $row 'dn'); Verdict = $labels[$state]; Valeurs = (Get-DomeniaMember $row 'values'); Etats = (Get-DomeniaMember $row 'states') }
}
Write-Verbose ('Correspondants : ' + $counts.Match + ' ; inconnus : ' + $counts.Unknown + ' ; non correspondants : ' + $counts.NoMatch)
""";
}

/// <summary>
/// One cmdlet of the ActiveDirectory or LAPS modules (reference only: Domenia never runs them). <see cref="Help"/> is the full help
/// text, <see cref="Source"/> « builtin » (delivered reference) or « installed » (help file of a module of this computer).
/// </summary>
public sealed record QueryCmdlet(string Name, string Module, bool Write, bool Credential, string Synopsis, string Syntax, string Example, string Help = "",
    IReadOnlyList<string>? Parameters = null, string Source = "builtin")
{
    /// <summary>Help text to copy: the full help when known, else synopsis, syntax and example.</summary>
    public string HelpText => Help.Length > 0 ? Help : Name + "\n\n" + Synopsis + "\n\nSyntaxe\n" + Syntax + "\n\nExemple\n" + Example;
}

/// <summary>
/// Built-in reference of the ActiveDirectory and LAPS cmdlets (Domenia 1 hidden « Référence » tab read the installed modules;
/// Domenia 2 ships no PowerShell, so the reference is delivered). Filterable by text and module, copied on demand.
/// </summary>
public static class QueryCmdlets
{
    private const string Ad = "ActiveDirectory";
    private const string Laps = "LAPS";
    private const string LegacyLaps = "AdmPwd.PS";
    private const string Common = " [-Server <string>] [-Credential <PSCredential>] [-AuthType <ADAuthType>]";

    public static IReadOnlyList<QueryCmdlet> All { get; } =
    [
        new("Get-ADComputer", Ad, false, true, "Lit des comptes ordinateurs par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADComputer -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADComputer -LDAPFilter '(operatingSystem=*Windows 10*)' -SearchBase 'OU=Postes,DC=example,DC=local' -Properties operatingSystem"),
        new("Get-ADUser", Ad, false, true, "Lit des comptes utilisateurs par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADUser -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADUser -LDAPFilter '(&(objectCategory=person)(lockoutTime>=1))' -Properties lockoutTime"),
        new("Get-ADGroup", Ad, false, true, "Lit des groupes par identité, filtre PowerShell ou filtre LDAP.",
            "Get-ADGroup -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>]" + Common,
            "Get-ADGroup -LDAPFilter '(!(member=*))' -SearchBase 'OU=Groupes,DC=example,DC=local'"),
        new("Get-ADGroupMember", Ad, false, true, "Liste les membres d’un groupe, éventuellement de façon récursive.",
            "Get-ADGroupMember -Identity <ADGroup> [-Recursive]" + Common, "Get-ADGroupMember -Identity 'GG-Support-N2' -Recursive"),
        new("Get-ADPrincipalGroupMembership", Ad, false, true, "Liste les groupes dont un compte est membre direct.",
            "Get-ADPrincipalGroupMembership -Identity <ADPrincipal> [-ResourceContextServer <string>]" + Common, "Get-ADPrincipalGroupMembership -Identity c.bernard"),
        new("Get-ADObject", Ad, false, true, "Lit tout objet de l’annuaire par identité ou filtre LDAP.",
            "Get-ADObject -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-ResultSetSize <int>] [-Properties <string[]>] [-IncludeDeletedObjects]" + Common,
            "Get-ADObject -LDAPFilter '(objectClass=contact)' -SearchBase 'OU=Utilisateurs,DC=example,DC=local'"),
        new("Get-ADOrganizationalUnit", Ad, false, true, "Lit des unités d’organisation.",
            "Get-ADOrganizationalUnit -LDAPFilter <string> [-SearchBase <string>] [-SearchScope Base|OneLevel|Subtree] [-Properties <string[]>]" + Common,
            "Get-ADOrganizationalUnit -LDAPFilter '(name=*)' -SearchBase 'OU=Postes,DC=example,DC=local' -SearchScope OneLevel"),
        new("Search-ADAccount", Ad, false, true, "Cherche des comptes verrouillés, désactivés, expirés ou inactifs.",
            "Search-ADAccount [-LockedOut] [-AccountDisabled] [-AccountExpired] [-AccountInactive] [-PasswordExpired] [-PasswordNeverExpires] [-TimeSpan <TimeSpan>] [-UsersOnly] [-ComputersOnly] [-SearchBase <string>]" + Common,
            "Search-ADAccount -AccountInactive -TimeSpan 90.00:00:00 -ComputersOnly -SearchBase 'OU=Postes,DC=example,DC=local'"),
        new("Get-ADDomain", Ad, false, true, "Lit les informations du domaine (racine, contrôleurs FSMO, niveau fonctionnel).",
            "Get-ADDomain [[-Identity] <ADDomain>]" + Common, "Get-ADDomain"),
        new("Get-ADDomainController", Ad, false, true, "Trouve ou lit des contrôleurs de domaine.",
            "Get-ADDomainController [-Discover] [-DomainName <string>] [-Service <ADDiscoverableService[]>] [-Filter <string>]" + Common, "Get-ADDomainController -Discover -Service PrimaryDC"),
        new("Get-ADDefaultDomainPasswordPolicy", Ad, false, true, "Lit la stratégie de mot de passe par défaut du domaine.",
            "Get-ADDefaultDomainPasswordPolicy [[-Identity] <ADDefaultDomainPasswordPolicy>]" + Common, "Get-ADDefaultDomainPasswordPolicy"),
        new("Get-ADFineGrainedPasswordPolicy", Ad, false, true, "Lit les stratégies de mot de passe affinées.",
            "Get-ADFineGrainedPasswordPolicy -Filter <string> [-Properties <string[]>]" + Common, "Get-ADFineGrainedPasswordPolicy -Filter *"),
        new("Get-ADUserResultantPasswordPolicy", Ad, false, true, "Donne la stratégie de mot de passe qui s’applique à un utilisateur.",
            "Get-ADUserResultantPasswordPolicy -Identity <ADAccount>" + Common, "Get-ADUserResultantPasswordPolicy -Identity c.bernard"),
        new("Get-ADReplicationPartnerMetadata", Ad, false, true, "Lit l’état de réplication d’un contrôleur avec ses partenaires.",
            "Get-ADReplicationPartnerMetadata -Target <Object[]> [-Partition <string[]>]" + Common, "Get-ADReplicationPartnerMetadata -Target dc01.example.local"),
        new("Unlock-ADAccount", Ad, true, true, "Déverrouille un compte (écriture : dans Domenia, plan, confirmation, reçu et relecture).",
            "Unlock-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Unlock-ADAccount -Identity c.bernard -WhatIf"),
        new("Enable-ADAccount", Ad, true, true, "Active un compte (écriture).", "Enable-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Enable-ADAccount -Identity c.bernard -WhatIf"),
        new("Disable-ADAccount", Ad, true, true, "Désactive un compte (écriture).", "Disable-ADAccount -Identity <ADAccount> [-WhatIf] [-Confirm]" + Common, "Disable-ADAccount -Identity c.bernard -WhatIf"),
        new("Set-ADAccountPassword", Ad, true, true, "Change ou réinitialise un mot de passe (écriture ; le mot de passe passe en SecureString, jamais en clair).",
            "Set-ADAccountPassword -Identity <ADAccount> [-Reset] [-NewPassword <SecureString>] [-WhatIf] [-Confirm]" + Common, "Set-ADAccountPassword -Identity c.bernard -Reset -WhatIf"),
        new("Move-ADObject", Ad, true, true, "Déplace un objet vers une autre OU (écriture).", "Move-ADObject -Identity <ADObject> -TargetPath <string> [-WhatIf] [-Confirm]" + Common,
            "Move-ADObject -Identity 'CN=PC-PAR-0042,OU=Paris,OU=Postes,DC=example,DC=local' -TargetPath 'OU=Quarantaine,OU=Postes,DC=example,DC=local' -WhatIf"),
        new("Add-ADGroupMember", Ad, true, true, "Ajoute des membres à un groupe (écriture).", "Add-ADGroupMember -Identity <ADGroup> -Members <ADPrincipal[]> [-WhatIf] [-Confirm]" + Common,
            "Add-ADGroupMember -Identity 'GG-Support-N1' -Members c.bernard -WhatIf"),
        new("Remove-ADGroupMember", Ad, true, true, "Retire des membres d’un groupe (écriture).", "Remove-ADGroupMember -Identity <ADGroup> -Members <ADPrincipal[]> [-WhatIf] [-Confirm]" + Common,
            "Remove-ADGroupMember -Identity 'GG-Support-N1' -Members c.bernard -WhatIf"),
        new("Get-LapsADPassword", Laps, false, true, "Lit les informations LAPS Windows d’un poste (expiration ; le mot de passe n’est affiché qu’avec -AsPlainText, jamais par Domenia).",
            "Get-LapsADPassword -Identity <string[]> [-DomainController <string>] [-Domain <string>] [-IncludeHistory] [-AsPlainText] [-DecryptionCredential <PSCredential>] [-Credential <PSCredential>]",
            "Get-LapsADPassword -Identity PC-PAR-0042"),
        new("Get-LapsDiagnostics", Laps, false, false, "Rassemble les journaux et l’état LAPS du poste local.", "Get-LapsDiagnostics [-OutputFolder <string>] [-CollectNetworkTrace] [-ResetPassword]", "Get-LapsDiagnostics -OutputFolder C:\\Temp\\laps"),
        new("Find-LapsADExtendedRights", Laps, false, true, "Liste les délégations de lecture des mots de passe LAPS sur une OU.", "Find-LapsADExtendedRights -Identity <string> [-IncludeComputers] [-Domain <string>] [-DomainController <string>] [-Credential <PSCredential>]",
            "Find-LapsADExtendedRights -Identity 'OU=Postes,DC=example,DC=local'"),
        new("Set-LapsADComputerSelfPermission", Laps, true, true, "Autorise les postes d’une OU à mettre à jour leur mot de passe LAPS (écriture d’ACL).",
            "Set-LapsADComputerSelfPermission -Identity <string> [-Domain <string>] [-DomainController <string>] [-Credential <PSCredential>]", "Set-LapsADComputerSelfPermission -Identity 'OU=Postes,DC=example,DC=local' -WhatIf"),
        new("Reset-LapsPassword", Laps, true, false, "Force la rotation du mot de passe LAPS du poste local (écriture).", "Reset-LapsPassword", "Reset-LapsPassword"),
        new("Update-LapsADSchema", Laps, true, true, "Étend le schéma pour LAPS Windows (écriture de schéma).", "Update-LapsADSchema [-Credential <PSCredential>]", "Update-LapsADSchema -WhatIf"),
        new("Get-AdmPwdPassword", LegacyLaps, false, false, "LAPS hérité : lit l’expiration et le mot de passe d’un poste (Domenia n’en lit que l’expiration).", "Get-AdmPwdPassword -ComputerName <string>", "Get-AdmPwdPassword -ComputerName PC-PAR-0042"),
        new("Reset-AdmPwdPassword", LegacyLaps, true, false, "LAPS hérité : fixe une nouvelle date d’expiration (écriture).", "Reset-AdmPwdPassword -ComputerName <string> [-WhenEffective <DateTime>]", "Reset-AdmPwdPassword -ComputerName PC-PAR-0042"),
        new("Find-AdmPwdExtendedRights", LegacyLaps, false, false, "LAPS hérité : liste les délégations de lecture sur une OU.", "Find-AdmPwdExtendedRights -Identity <string>", "Find-AdmPwdExtendedRights -Identity 'OU=Postes,DC=example,DC=local'"),
    ];
}
