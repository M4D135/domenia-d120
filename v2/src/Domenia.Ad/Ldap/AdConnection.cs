using System.DirectoryServices.Protocols;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// LDAP connection to Active Directory using System.DirectoryServices.Protocols.
/// The constructor does not connect; the first operation opens and binds the connection once.
/// All failures are converted to <see cref="DomeniaOperationException"/> with stable codes from <see cref="AdErrors"/>.
/// </summary>
public sealed class AdConnection : IAdConnection
{
    private static readonly string[] RootDseAttributes =
    [
        "defaultNamingContext",
        "configurationNamingContext",
        "schemaNamingContext",
        "rootDomainNamingContext",
        "dnsHostName",
        "serverName",
        "domainFunctionality",
        "supportedControl",
        "currentTime",
    ];

    private static readonly string[] AllAttributes = ["*"];

    private static readonly HashSet<string> BinaryAttributes = new(StringComparer.OrdinalIgnoreCase)
    {
        "objectGUID",
        "objectSid",
        "sIDHistory",
        "tokenGroups",
        "nTSecurityDescriptor",
        "thumbnailPhoto",
        "jpegPhoto",
        "userCertificate",
        "msExchMailboxGuid",
        "msDS-GenerationId",
        "logonHours",
        "msDS-AllowedToActOnBehalfOfOtherIdentity",
    };

    private readonly AdConnectionOptions options;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _sync = new();

    private volatile bool _disposed;
    private volatile LdapConnection? _connection;
    private volatile AdRootDse? _rootDse;
    private volatile string? _server;

    /// <summary>Creates a lazy directory connection. No network call is made here.</summary>
    public AdConnection(AdConnectionOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        this.options = options;
    }

    /// <summary>Receives technical traces such as « LDAP search : code 49 ». Never contains a DN or a value.</summary>
    public static event Action<string>? TechnicalTrace;

    /// <inheritdoc />
    public string? Server => _server;

    /// <inheritdoc />
    public async Task<AdRootDse> RootDseAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);

        var root = _rootDse;
        if (root is null)
        {
            var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
            root = await ReadRootDseCoreAsync(connection, cancellationToken).ConfigureAwait(false);
            _rootDse = root;
            _server = string.IsNullOrEmpty(root.DnsHostName) ? null : root.DnsHostName;
        }

        return root;
    }

    /// <inheritdoc />
    public async Task<IReadOnlyList<AdEntry>> SearchAsync(AdSearchRequest request, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(request.BaseDn);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.Filter, nameof(request.Filter));
        ArgumentNullException.ThrowIfNull(request.Attributes);

        if (request.SortAttribute is not null && request.SortAttribute != "name")
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Clé de tri LDAP non autorisée."); }
        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);

        var timeout = NormalizeTimeout(request.Timeout, TimeSpan.FromSeconds(30));
        var pageSize = request.PageSize <= 0 ? 500 : request.PageSize;
        var attributes = request.Attributes.Count == 0 ? AllAttributes : request.Attributes.ToArray();

        var results = new List<AdEntry>();
        var total = 0;
        byte[]? cookie = null;

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var remaining = request.SizeLimit <= 0 ? int.MaxValue : request.SizeLimit - total;
            if (remaining <= 0)
            {
                break;
            }

            var pageLimit = request.SizeLimit > 0 ? Math.Min(pageSize, remaining) : pageSize;
            if (pageLimit <= 0)
            {
                break;
            }

            var searchRequest = CreateSearchRequest(request.BaseDn, request.Filter, request.Scope, attributes, timeout);

            var pageControl = cookie is null
                ? new PageResultRequestControl(pageLimit)
                : new PageResultRequestControl(pageLimit) { Cookie = cookie };
            searchRequest.Controls.Add(pageControl);
            if (request.SortAttribute is not null)
            { searchRequest.Controls.Add(new SortRequestControl(request.SortAttribute, false) { IsCritical = true }); }

            var response = await SendRequestAsync<SearchResponse>(connection, searchRequest, timeout, "search", cancellationToken).ConfigureAwait(false);
            if (request.SortAttribute is not null && response.Controls.OfType<SortResponseControl>().FirstOrDefault()?.Result != ResultCode.Success)
            { throw new DomeniaOperationException(DomeniaErrors.SourceUnavailable, "Le contrôleur n’a pas confirmé le tri : relancez la recherche, aucune suite incertaine n’est affichée."); }

            if (response.Entries is { } entries)
            {
                foreach (SearchResultEntry entry in entries)
                {
                    if (entry is null)
                    {
                        continue;
                    }

                    results.Add(await MaterializeEntryAsync(connection, entry, timeout, cancellationToken).ConfigureAwait(false));
                    total++;

                    if (request.SizeLimit > 0 && total >= request.SizeLimit)
                    {
                        break;
                    }
                }
            }

            if (request.SizeLimit > 0 && total >= request.SizeLimit)
            {
                break;
            }

            cookie = GetPageCookie(response);
            if (cookie is null || cookie.Length == 0)
            {
                break;
            }
        }

        return results;
    }

    /// <inheritdoc />
    public async Task<AdEntry?> ReadAsync(string distinguishedName, IReadOnlyList<string> attributes, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(distinguishedName, nameof(distinguishedName));
        ArgumentNullException.ThrowIfNull(attributes);

        var request = new AdSearchRequest(distinguishedName, "(objectClass=*)", AdSearchScope.Base, attributes)
        {
            PageSize = 1,
            SizeLimit = 1,
            Timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15)),
        };

        try
        {
            var entries = await SearchAsync(request, cancellationToken).ConfigureAwait(false);
            return entries.Count == 0 ? null : entries[0];
        }
        catch (DomeniaOperationException ex) when (string.Equals(ex.Code, AdErrors.NoSuchObject, StringComparison.Ordinal))
        {
            return null;
        }
    }

    /// <inheritdoc />
    public async Task ModifyAsync(string distinguishedName, IReadOnlyList<AdModification> modifications, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(distinguishedName, nameof(distinguishedName));
        ArgumentNullException.ThrowIfNull(modifications);

        if (modifications.Count == 0)
        {
            return;
        }

        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));

        var request = new ModifyRequest(distinguishedName);

        foreach (var modification in modifications)
        {
            ArgumentNullException.ThrowIfNull(modification);
            ArgumentException.ThrowIfNullOrWhiteSpace(modification.Attribute, nameof(modifications));
            ArgumentNullException.ThrowIfNull(modification.Values);

            var change = new DirectoryAttributeModification
            {
                Name = modification.Attribute,
                Operation = ToLdapOperation(modification.Kind),
            };

            foreach (var value in modification.Values)
            {
                AddValue(change, value);
            }

            request.Modifications.Add(change);
        }

        await SendRequestAsync<ModifyResponse>(connection, request, timeout, "modify", cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task RenameAsync(string distinguishedName, string newParentDn, string newRdn, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(distinguishedName, nameof(distinguishedName));
        ArgumentException.ThrowIfNullOrWhiteSpace(newParentDn, nameof(newParentDn));
        ArgumentException.ThrowIfNullOrWhiteSpace(newRdn, nameof(newRdn));

        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));

        var request = new ModifyDNRequest(distinguishedName, newParentDn, newRdn) { DeleteOldRdn = true };
        await SendRequestAsync<ModifyDNResponse>(connection, request, timeout, "rename", cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task AddAsync(string distinguishedName, IReadOnlyDictionary<string, IReadOnlyList<object>> attributes, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(distinguishedName, nameof(distinguishedName));
        ArgumentNullException.ThrowIfNull(attributes);

        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));

        var normalized = new Dictionary<string, IReadOnlyList<object>>(attributes, StringComparer.OrdinalIgnoreCase);
        if (normalized.Count == 0)
        {
            throw new DomeniaOperationException(AdErrors.Constraint, AdErrors.ConstraintMessage);
        }

        if (!normalized.TryGetValue("objectClass", out var objectClassValues) || objectClassValues.Count == 0)
        {
            throw new DomeniaOperationException(AdErrors.Constraint, AdErrors.ConstraintMessage);
        }

        ArgumentNullException.ThrowIfNull(objectClassValues);

        var request = new AddRequest(distinguishedName);
        var objectClassAttribute = new DirectoryAttribute("objectClass");
        foreach (var value in objectClassValues)
        {
            AddValue(objectClassAttribute, value);
        }

        request.Attributes.Add(objectClassAttribute);

        foreach (var pair in normalized)
        {
            if (string.Equals(pair.Key, "objectClass", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            ArgumentException.ThrowIfNullOrWhiteSpace(pair.Key, nameof(attributes));
            ArgumentNullException.ThrowIfNull(pair.Value);

            if (pair.Value.Count == 0)
            {
                continue;
            }

            var attr = new DirectoryAttribute(pair.Key);
            foreach (var value in pair.Value)
            {
                AddValue(attr, value);
            }

            request.Attributes.Add(attr);
        }

        await SendRequestAsync<AddResponse>(connection, request, timeout, "add", cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public async Task DeleteAsync(string distinguishedName, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentException.ThrowIfNullOrWhiteSpace(distinguishedName, nameof(distinguishedName));

        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));

        var request = new DeleteRequest(distinguishedName);
        await SendRequestAsync<DeleteResponse>(connection, request, timeout, "delete", cancellationToken).ConfigureAwait(false);
    }

    /// <inheritdoc />
    public void Dispose()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;

            var connection = _connection;
            _connection = null;
            _rootDse = null;
            _server = null;

            connection?.Dispose();
            _gate.Dispose();
        }
    }

    private async Task EnsureConnectedAsync(CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (_connection is not null)
        {
            return;
        }

        try
        {
            await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (ObjectDisposedException)
        {
            RaiseTrace("connect", -1);
            throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        }

        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            if (_connection is not null)
            {
                return;
            }

            await OpenAndBindAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                _gate.Release();
            }
            catch (ObjectDisposedException)
            {
                // The connection was disposed while this operation was waiting.
            }
        }
    }

    private async Task OpenAndBindAsync(CancellationToken cancellationToken)
    {
        LdapConnection? connection = null;

        try
        {
            connection = CreateConnection();

            await Task.Run(() => connection.Bind(), cancellationToken).ConfigureAwait(false);

            var root = await ReadRootDseCoreAsync(connection, cancellationToken).ConfigureAwait(false);

            lock (_sync)
            {
                if (_disposed)
                {
                    connection.Dispose();
                    RaiseTrace("connect", -1);
                    throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
                }

                _rootDse = root;
                _server = string.IsNullOrEmpty(root.DnsHostName) ? null : root.DnsHostName;
                _connection = connection;
            }
        }
        catch (OperationCanceledException)
        {
            connection?.Dispose();
            _connection = null;
            _rootDse = null;
            _server = null;
            throw;
        }
        catch (DomeniaOperationException)
        {
            connection?.Dispose();
            _connection = null;
            _rootDse = null;
            _server = null;
            throw;
        }
#pragma warning disable CA1031 // Convert unexpected platform failures to a stable DomeniaOperationException.
        catch (Exception ex)
        {
            connection?.Dispose();
            _connection = null;
            _rootDse = null;
            _server = null;
            throw MapFailure("bind", ex);
        }
#pragma warning restore CA1031
    }

    private LdapConnection CreateConnection()
    {
        var target = string.IsNullOrWhiteSpace(options.Server) ? options.DomainDnsName : options.Server;
        var identifier = new LdapDirectoryIdentifier(string.IsNullOrWhiteSpace(target) ? null : target, 389,
            fullyQualifiedDnsHostName: !string.IsNullOrWhiteSpace(options.Server), connectionless: false);
        var connection = new LdapConnection(identifier, options.Credential, AuthType.Negotiate);

        var session = connection.SessionOptions;
        session.ProtocolVersion = 3;
        session.Signing = true;
        session.Sealing = true;
        session.ReferralChasing = ReferralChasingOptions.None;
        connection.Timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));

        return connection;
    }

    private async Task<AdRootDse> ReadRootDseCoreAsync(LdapConnection connection, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);

        var timeout = NormalizeTimeout(options.ConnectTimeout, TimeSpan.FromSeconds(15));
        var request = CreateSearchRequest(string.Empty, "(objectClass=*)", AdSearchScope.Base, RootDseAttributes, timeout);

        var response = await SendRequestAsync<SearchResponse>(connection, request, timeout, "rootDse", cancellationToken).ConfigureAwait(false);

        if (response.Entries is not { Count: > 0 } entries)
        {
            throw new DomeniaOperationException(AdErrors.Unavailable, AdErrors.UnavailableMessage);
        }

        var entry = entries[0];
        var adEntry = await MaterializeEntryAsync(connection, entry, timeout, cancellationToken).ConfigureAwait(false);

        return new AdRootDse(
            adEntry.String("defaultNamingContext") ?? string.Empty,
            adEntry.String("configurationNamingContext") ?? string.Empty,
            adEntry.String("schemaNamingContext") ?? string.Empty,
            adEntry.String("rootDomainNamingContext") ?? string.Empty,
            adEntry.String("dnsHostName") ?? string.Empty,
            adEntry.String("serverName"),
            adEntry.Int("domainFunctionality"),
            adEntry.Strings("supportedControl"),
            adEntry.Time("currentTime"));
    }

    private static async Task<T> SendRequestAsync<T>(
        LdapConnection connection,
        DirectoryRequest request,
        TimeSpan timeout,
        string operation,
        CancellationToken cancellationToken)
        where T : DirectoryResponse
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(operation);

        cancellationToken.ThrowIfCancellationRequested();

        try
        {
            var response = await Task.Run(
                () => (T?)connection.SendRequest(request, timeout),
                cancellationToken).ConfigureAwait(false);

            if (response is null)
            {
                RaiseTrace(operation, -1);
                throw new DomeniaOperationException(AdErrors.Failed, AdErrors.FailedMessage);
            }

            return response;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
#pragma warning disable CA1031 // Convert unexpected platform failures to a stable DomeniaOperationException.
        catch (Exception ex)
        {
            throw MapFailure(operation, ex);
        }
#pragma warning restore CA1031
    }

    private static async Task<AdEntry> MaterializeEntryAsync(
        LdapConnection connection,
        SearchResultEntry entry,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentNullException.ThrowIfNull(entry);

        var dn = entry.DistinguishedName ?? string.Empty;
        var bag = new Dictionary<string, List<object>>(StringComparer.OrdinalIgnoreCase);

        if (entry.Attributes is { } attributes)
        {
            foreach (DirectoryAttribute attribute in attributes)
            {
                if (attribute is null)
                {
                    continue;
                }

                var name = attribute.Name;
                if (string.IsNullOrEmpty(name))
                {
                    continue;
                }

                if (TryParseRangedAttribute(name, out var baseName, out var lower, out var upper))
                {
                    var binary = IsBinaryAttribute(baseName);
                    var target = GetOrCreate(bag, baseName);
                    AddValues(target, attribute.GetValues(binary ? typeof(byte[]) : typeof(string)));

                    if (upper is not null &&
                        !string.Equals(upper, "*", StringComparison.Ordinal) &&
                        int.TryParse(upper, NumberStyles.Integer, CultureInfo.InvariantCulture, out var upperInt))
                    {
                        if (upperInt >= lower && upperInt < int.MaxValue)
                        {
                            var start = upperInt + 1;
                            if (start >= 0)
                            {
                                await FetchRangedValuesAsync(connection, dn, baseName, start, binary, target, timeout, cancellationToken).ConfigureAwait(false);
                            }
                        }
                    }
                }
                else
                {
                    var binary = IsBinaryAttribute(name);
                    var target = GetOrCreate(bag, name);
                    AddValues(target, attribute.GetValues(binary ? typeof(byte[]) : typeof(string)));
                }
            }
        }

        return new AdEntry(dn, ToReadOnlyDictionary(bag));
    }

    private static async Task FetchRangedValuesAsync(
        LdapConnection connection,
        string dn,
        string baseAttribute,
        int start,
        bool binary,
        List<object> target,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ArgumentException.ThrowIfNullOrWhiteSpace(dn, nameof(dn));
        ArgumentException.ThrowIfNullOrWhiteSpace(baseAttribute, nameof(baseAttribute));

        if (start < 0)
        {
            return;
        }

        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var rangeAttribute = baseAttribute + ";range=" + start.ToString(CultureInfo.InvariantCulture) + "-*";
            var request = CreateSearchRequest(dn, "(objectClass=*)", AdSearchScope.Base, new[] { rangeAttribute }, timeout);

            var response = await SendRequestAsync<SearchResponse>(connection, request, timeout, "range", cancellationToken).ConfigureAwait(false);

            var entries = response.Entries;
            if (entries is null || entries.Count == 0)
            {
                break;
            }

            var entry = entries[0];
            if (entry is null)
            {
                break;
            }

            if (entry.Attributes is not { } attributes)
            {
                break;
            }

            var found = false;

            foreach (DirectoryAttribute attribute in attributes)
            {
                if (attribute is null || attribute.Name is null)
                {
                    continue;
                }

                if (!TryParseRangedAttribute(attribute.Name, out var baseName, out _, out var upper))
                {
                    continue;
                }

                if (!string.Equals(baseName, baseAttribute, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                found = true;
                AddValues(target, attribute.GetValues(binary ? typeof(byte[]) : typeof(string)));

                if (string.Equals(upper, "*", StringComparison.Ordinal))
                {
                    return;
                }

                if (upper is null || !int.TryParse(upper, NumberStyles.Integer, CultureInfo.InvariantCulture, out var upperInt))
                {
                    return;
                }

                if (upperInt < start || upperInt == int.MaxValue)
                {
                    return;
                }

                start = upperInt + 1;
                break;
            }

            if (!found)
            {
                break;
            }
        }
    }

    private static SearchRequest CreateSearchRequest(
        string baseDn,
        string filter,
        AdSearchScope scope,
        string[] attributes,
        TimeSpan timeout)
    {
        ArgumentNullException.ThrowIfNull(baseDn);
        ArgumentException.ThrowIfNullOrWhiteSpace(filter, nameof(filter));
        ArgumentNullException.ThrowIfNull(attributes);

        var request = new SearchRequest(baseDn, filter, ToLdapScope(scope), attributes);
        request.TimeLimit = timeout;
        request.Aliases = DereferenceAlias.Never;
        return request;
    }

    private static SearchScope ToLdapScope(AdSearchScope scope) => scope switch
    {
        AdSearchScope.Base => SearchScope.Base,
        AdSearchScope.OneLevel => SearchScope.OneLevel,
        AdSearchScope.Subtree => SearchScope.Subtree,
        _ => throw new ArgumentOutOfRangeException(nameof(scope), scope, null),
    };

    private static DirectoryAttributeOperation ToLdapOperation(AdModificationKind kind) => kind switch
    {
        AdModificationKind.Replace => DirectoryAttributeOperation.Replace,
        AdModificationKind.Add => DirectoryAttributeOperation.Add,
        AdModificationKind.Delete => DirectoryAttributeOperation.Delete,
        _ => throw new ArgumentOutOfRangeException(nameof(kind), kind, null),
    };

    private static byte[]? GetPageCookie(SearchResponse response)
    {
        ArgumentNullException.ThrowIfNull(response);

        if (response.Controls is { } controls)
        {
            foreach (DirectoryControl control in controls)
            {
                if (control is PageResultResponseControl page)
                {
                    return page.Cookie;
                }
            }
        }

        return null;
    }

    private static bool TryParseRangedAttribute(string attributeName, out string baseName, out int lower, out string? upper)
    {
        ArgumentNullException.ThrowIfNull(attributeName);

        baseName = attributeName;
        lower = 0;
        upper = null;

        var separator = attributeName.IndexOf(';', StringComparison.Ordinal);
        if (separator < 0)
        {
            return false;
        }

        baseName = attributeName.Substring(0, separator);
        if (baseName.Length == 0)
        {
            return false;
        }

        var rest = attributeName.Substring(separator + 1);
        if (!rest.StartsWith("range=", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var range = rest.Substring("range=".Length);
        var dash = range.IndexOf('-', StringComparison.Ordinal);
        if (dash < 0)
        {
            return false;
        }

        var lowerText = range.Substring(0, dash);
        upper = range.Substring(dash + 1);

        if (upper.Length == 0)
        {
            return false;
        }

        if (!int.TryParse(lowerText, NumberStyles.Integer, CultureInfo.InvariantCulture, out lower) || lower < 0)
        {
            return false;
        }

        if (!string.Equals(upper, "*", StringComparison.Ordinal))
        {
            if (!int.TryParse(upper, NumberStyles.Integer, CultureInfo.InvariantCulture, out var upperCheck) || upperCheck < 0)
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsBinaryAttribute(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return BinaryAttributes.Contains(name);
    }

    private static void AddValues(List<object> target, object[]? values)
    {
        ArgumentNullException.ThrowIfNull(target);

        if (values is null)
        {
            return;
        }

        foreach (var value in values)
        {
            if (value is null)
            {
                continue;
            }

            if (value is string || value is byte[])
            {
                target.Add(value);
            }
            else
            {
                target.Add(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty);
            }
        }
    }

    private static void AddValue(DirectoryAttribute attribute, object value)
    {
        ArgumentNullException.ThrowIfNull(attribute);
        ArgumentNullException.ThrowIfNull(value);

        switch (value)
        {
            case string text:
                attribute.Add(text);
                break;
            case byte[] bytes:
                attribute.Add(bytes);
                break;
            default:
                attribute.Add(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty);
                break;
        }
    }

    private static void AddValue(DirectoryAttributeModification modification, object value)
    {
        ArgumentNullException.ThrowIfNull(modification);
        ArgumentNullException.ThrowIfNull(value);

        switch (value)
        {
            case string text:
                modification.Add(text);
                break;
            case byte[] bytes:
                modification.Add(bytes);
                break;
            default:
                modification.Add(Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty);
                break;
        }
    }

    private static List<object> GetOrCreate(Dictionary<string, List<object>> bag, string name)
    {
        ArgumentNullException.ThrowIfNull(bag);
        ArgumentNullException.ThrowIfNull(name);

        if (!bag.TryGetValue(name, out var list))
        {
            list = [];
            bag[name] = list;
        }

        return list;
    }

    private static IReadOnlyDictionary<string, IReadOnlyList<object>> ToReadOnlyDictionary(Dictionary<string, List<object>> bag)
    {
        ArgumentNullException.ThrowIfNull(bag);

        var result = new Dictionary<string, IReadOnlyList<object>>(bag.Count, StringComparer.OrdinalIgnoreCase);
        foreach (var pair in bag)
        {
            result[pair.Key] = pair.Value;
        }

        return result;
    }

    private static TimeSpan NormalizeTimeout(TimeSpan timeout, TimeSpan fallback) => timeout <= TimeSpan.Zero ? fallback : timeout;

    private static Exception MapFailure(string operation, Exception ex)
    {
        ArgumentNullException.ThrowIfNull(operation);
        ArgumentNullException.ThrowIfNull(ex);

        if (ex is OperationCanceledException)
        {
            return ex;
        }

        if (ex is DomeniaOperationException)
        {
            return ex;
        }

        var code = GetErrorCode(ex);
        RaiseTrace(operation, code);

        if (ex is ObjectDisposedException)
        {
            return new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        }

        return code switch
        {
            49 => new DomeniaOperationException(AdErrors.Credentials, AdErrors.CredentialsMessage),
            50 => new DomeniaOperationException(AdErrors.AccessDenied, AdErrors.AccessDeniedMessage),
            32 => new DomeniaOperationException(AdErrors.NoSuchObject, AdErrors.NoSuchObjectMessage),
            51 or 52 or 81 or 91 => new DomeniaOperationException(AdErrors.Unavailable, AdErrors.UnavailableMessage),
            85 => new DomeniaOperationException(AdErrors.Timeout, AdErrors.TimeoutMessage),
            19 or 21 => new DomeniaOperationException(AdErrors.Constraint, AdErrors.ConstraintMessage),
            53 => new DomeniaOperationException(AdErrors.Unwilling, AdErrors.UnwillingMessage),
            68 => new DomeniaOperationException(AdErrors.Exists, AdErrors.ExistsMessage),
            _ => new DomeniaOperationException(AdErrors.Failed, AdErrors.FailedMessage),
        };
    }

    private static int GetErrorCode(Exception ex)
    {
        ArgumentNullException.ThrowIfNull(ex);

        if (ex is DirectoryOperationException { Response: { } response })
        {
            return (int)response.ResultCode;
        }

        if (ex is LdapException ldap)
        {
            return ldap.ErrorCode;
        }

        if (ex is TimeoutException)
        {
            return 85;
        }

        return -1;
    }

    private static void RaiseTrace(string operation, int code)
    {
        ArgumentNullException.ThrowIfNull(operation);

        var handler = TechnicalTrace;
        if (handler is not null)
        {
            handler("LDAP " + operation + FrenchText.Colon + " code " + code.ToString(CultureInfo.InvariantCulture));
        }
    }
}
