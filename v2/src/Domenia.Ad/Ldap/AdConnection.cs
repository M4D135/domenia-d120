using System.DirectoryServices.Protocols;
using System.Globalization;
using Domenia.Core;

namespace Domenia.Ad;

/// <summary>
/// LDAP connection to Active Directory using System.DirectoryServices.Protocols.
/// The constructor does not connect; the first operation opens and binds the connection once.
/// Read failures and proven write refusals have stable codes. A lost mutation response keeps an unknown outcome.
/// </summary>
public sealed partial class AdConnection : IAdConnection, IAdPasswordConnection, IAdBinarySchemaProvider
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
        "isSynchronized",
        "highestCommittedUSN",
        "dsServiceName",
    ];

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
    private readonly System.Security.SecureString? trackedSecret;
    internal IDisposable? TrackedCredential { get; }
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
        if (options.Credential is { } supplied)
        {
            using var password = supplied.SecurePassword;
            if (string.IsNullOrWhiteSpace(supplied.UserName) || password.Length == 0)
            { throw new DomeniaOperationException(AdErrors.Credentials, "Compte explicite incomplet : aucune connexion ni repli sur la session Windows."); }
            this.options = options with { Credential = new System.Net.NetworkCredential(supplied.UserName, password, supplied.Domain) };
            trackedSecret = this.options.Credential.SecurePassword;
            TrackedCredential = SecureCredentialCopies.Track(trackedSecret);
        }
        else { this.options = options; }
    }

    /// <summary>Receives technical traces such as « LDAP search : code 49 ». Never contains a DN or a value.</summary>
    public static event Action<string>? TechnicalTrace;

    /// <inheritdoc />
    public string? Server => _server;

    /// <summary>Independent connection to a known domain controller, retaining this session's exact identity.</summary>
    internal AdConnection ForServer(string server, TimeSpan? connectTimeout = null)
    {
        lock (_sync) { ObjectDisposedException.ThrowIf(_disposed, this); return new(options with { Server = server, ConnectTimeout = connectTimeout ?? TimeSpan.FromSeconds(8) }); }
    }

    internal AdConnection ForRead(System.Net.NetworkCredential? selected = null)
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return new(options with { Server = _server ?? options.Server, Credential = selected ?? options.Credential, ConnectTimeout = TimeSpan.FromSeconds(8) });
        }
    }

    internal bool UsesWindowsIdentity => options.Credential is null;

    internal string? ExplicitLogin => options.Credential is { } credential
        ? string.IsNullOrEmpty(credential.Domain) || credential.UserName.Contains('\\') || credential.UserName.Contains('@')
            ? credential.UserName : credential.Domain + "\\" + credential.UserName : null;

    /// <summary>A caller-owned secure copy for another Windows protocol of this same connection identity.</summary>
    internal AdCredentialCopy CopyCredential(bool tracked = true)
    {
        lock (_sync) { ObjectDisposedException.ThrowIf(_disposed, this); return CopyCredentialCore(tracked); }
    }

    private AdCredentialCopy CopyCredentialCore(bool tracked)
    {
        var credential = options.Credential;
        if (credential is null) { return new(null, null, null, tracked); }
        var user = credential.UserName;
        var domain = credential.Domain;
        var parsed = CredentialRules.Parse(user);
        if (parsed.Form == AccountNameForm.Upn) { domain = ""; }
        if (parsed.Form == AccountNameForm.DownLevel)
        {
            if (!string.IsNullOrEmpty(domain) && !domain.Equals(parsed.Authority, StringComparison.OrdinalIgnoreCase))
            { throw new DomeniaOperationException(AdErrors.Credentials, "Contexte du compte de connexion ambigu."); }
            user = parsed.Name;
            domain = parsed.Authority;
        }
        var password = credential.SecurePassword;
        password.MakeReadOnly();
        return new(user, domain, password, tracked);
    }

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

        ValidateReadRequest(request);
        using var elapsed = new CancellationTokenSource(request.Budget);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, elapsed.Token);
        try { return await SearchCoreAsync(request, budget.Token).ConfigureAwait(false); }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested && elapsed.IsCancellationRequested)
        { throw new DomeniaOperationException(AdErrors.Timeout, AdErrors.TimeoutMessage); }
    }

    internal static void ValidateReadRequest(AdSearchRequest request)
    {
        if (request.Attributes.Count == 0 || request.Attributes.Count > 4096
            || request.Attributes.Any(name => !SafeReadAttribute(name))
            || request.BinaryAttributes.Count > 4096 || request.BinaryAttributes.Any(name => !SafeReadAttribute(name)
                || !request.Attributes.Any(a => (AdAttributeRange.TryParse(a, out var r) ? r!.Attribute : a).Equals(name, StringComparison.OrdinalIgnoreCase)))
            || request.MaxRangeValues is < 1 or > 50_000 || request.Budget <= TimeSpan.Zero || request.Budget > TimeSpan.FromMinutes(10)
            || request.ReadOwnerAndDacl && !request.Attributes.Contains("nTSecurityDescriptor", StringComparer.OrdinalIgnoreCase))
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Attributs ou limites de lecture LDAP non autorisés."); }
        if (request.SortAttribute is not null && request.SortAttribute != "name")
        { throw new DomeniaOperationException(DomeniaErrors.ArgumentsInvalid, "Clé de tri LDAP non autorisée."); }
    }

    private static bool SafeReadAttribute(string name)
    {
        if (string.IsNullOrWhiteSpace(name)) { return false; }
        var plain = AdAttributeRange.TryParse(name, out var range) ? range!.Attribute : name;
        return FicheAttributeRules.IsValidName(plain) && !FicheAttributeRules.IsSensitive(plain);
    }

    private async Task<IReadOnlyList<AdEntry>> SearchCoreAsync(AdSearchRequest request, CancellationToken cancellationToken)
    {
        await EnsureConnectedAsync(cancellationToken).ConfigureAwait(false);
        var connection = _connection ?? throw new DomeniaOperationException(AdErrors.NotConnected, AdErrors.NotConnectedMessage);
        var timeout = NormalizeTimeout(request.Timeout, TimeSpan.FromSeconds(30));
        var pageSize = request.PageSize <= 0 ? 500 : request.PageSize;
        var attributes = request.ExpandRanges
            ? request.Attributes.Concat(new[] { "objectGUID", "uSNChanged" }).Distinct(StringComparer.OrdinalIgnoreCase).ToArray() : request.Attributes.ToArray();

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
            if (request.ReadOwnerAndDacl)
            { searchRequest.Controls.Add(new SecurityDescriptorFlagControl(SecurityMasks.Owner | SecurityMasks.Dacl) { IsCritical = true }); }
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

                    results.Add(await MaterializeEntryAsync(connection, entry, timeout, cancellationToken, request.ExpandRanges, request.MaxRangeValues, request.BinaryAttributes).ConfigureAwait(false));
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
            // NetworkCredential disposes its internal SecureString when its secure property is cleared.
            TrackedCredential?.Dispose();
            trackedSecret?.Dispose();
            if (options.Credential is { } credential) { credential.SecurePassword = null; }
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

        return MapRootDse(adEntry);
    }

    internal static AdRootDse MapRootDse(AdEntry adEntry) => new(
            adEntry.String("defaultNamingContext") ?? string.Empty,
            adEntry.String("configurationNamingContext") ?? string.Empty,
            adEntry.String("schemaNamingContext") ?? string.Empty,
            adEntry.String("rootDomainNamingContext") ?? string.Empty,
            adEntry.String("dnsHostName") ?? string.Empty,
            adEntry.String("serverName"),
            adEntry.Int("domainFunctionality"),
            adEntry.Strings("supportedControl"),
            adEntry.Time("currentTime"))
        {
            IsSynchronized = bool.TryParse(adEntry.String("isSynchronized"), out var synchronized) ? synchronized : null,
            HighestCommittedUsn = adEntry.Long("highestCommittedUSN") is >= 0 and var usn ? usn : null,
            DsServiceName = adEntry.String("dsServiceName"),
        };

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
                if (IsMutation(operation)) { throw new AdWriteOutcomeUnknownException(); }
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
            throw IsMutation(operation) ? MapMutationFailure(operation, ex) : MapFailure(operation, ex);
        }
#pragma warning restore CA1031
    }

    private static bool IsMutation(string operation) => operation is "modify" or "rename" or "add" or "delete";

    internal static Exception MapMutationFailure(string operation, Exception failure)
    {
        if (failure is AdWriteOutcomeUnknownException) { return failure; }
        if (failure is DirectoryOperationException { Response: { ResultCode: not ResultCode.Success } })
        { return MapFailure(operation, failure); }
        RaiseTrace(operation, GetErrorCode(failure));
        // A client timeout, lost connection, disposal or an exception without a server response proves no outcome.
        return new AdWriteOutcomeUnknownException();
    }

    internal static AdEntry ReadEntry(SearchResultEntry entry, IReadOnlySet<string>? binaryAttributes = null)
    {
        ArgumentNullException.ThrowIfNull(entry);
        var bag = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase);
        // This collection enumerates dictionary entries, not DirectoryAttribute instances.
        foreach (DirectoryAttribute attribute in entry.Attributes.Values)
        {
            var name = attribute.Name;
            if (!SafeReadAttribute(name)) { throw AdAttributeRange.Incomplete(); }
            var plain = AdAttributeRange.TryParse(name, out var range) ? range!.Attribute : name;
            bag.Add(name, attribute.GetValues(IsBinaryAttribute(plain) || binaryAttributes?.Contains(plain) == true ? typeof(byte[]) : typeof(string)));
        }
        return new(entry.DistinguishedName, bag);
    }

    private static async Task<AdEntry> MaterializeEntryAsync(LdapConnection connection, SearchResultEntry entry,
        TimeSpan timeout, CancellationToken token, bool expand = true, int maximum = 50_000, IReadOnlySet<string>? binaryAttributes = null)
    {
        var raw = ReadEntry(entry, binaryAttributes);
        if (!expand) { return raw; }
        var bag = new Dictionary<string, IReadOnlyList<object>>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in raw.AttributeNames)
        {
            if (!AdAttributeRange.TryParse(name, out var range))
            {
                if (raw.Raw(name).Count > maximum) { throw AdAttributeRange.Incomplete(); }
                if (!bag.TryAdd(name, raw.Raw(name))) { throw AdAttributeRange.Incomplete(); }
                continue;
            }
            var values = raw.Raw(name).ToList();
            range!.Validate(0, values.Count, 0, maximum);
            while (range.End is { } last)
            {
                token.ThrowIfCancellationRequested();
                // The same controller, identity and USN are required for every slice of one attribute.
                if (raw.Guid("objectGUID") is not { } guid || raw.Long("uSNChanged") is not { } usn) { throw AdAttributeRange.Incomplete(); }
                var requested = range.Attribute + ";range=" + (last + 1).ToString(CultureInfo.InvariantCulture) + "-" + (maximum - 1).ToString(CultureInfo.InvariantCulture);
                var request = CreateSearchRequest(raw.DistinguishedName, "(objectClass=*)", AdSearchScope.Base,
                    [requested, "objectGUID", "uSNChanged"], timeout);
                var response = await SendRequestAsync<SearchResponse>(connection, request, timeout, "range", token).ConfigureAwait(false);
                if (response.Entries.Count != 1) { throw AdAttributeRange.Incomplete(); }
                var next = ReadEntry(response.Entries[0], binaryAttributes);
                if (!FicheValues.SameDn(raw.DistinguishedName, next.DistinguishedName) || next.Guid("objectGUID") != guid || next.Long("uSNChanged") != usn)
                { throw AdAttributeRange.Incomplete(); }
                var names = next.AttributeNames.Where(n => AdAttributeRange.TryParse(n, out var r) && r!.Attribute.Equals(range.Attribute, StringComparison.OrdinalIgnoreCase)).ToArray();
                if (names.Length != 1 || next.Has(range.Attribute)) { throw AdAttributeRange.Incomplete(); }
                _ = AdAttributeRange.TryParse(names[0], out var slice);
                var chunk = next.Raw(names[0]);
                slice!.Validate(last + 1, chunk.Count, values.Count, maximum);
                values.AddRange(chunk);
                range = slice;
            }
            if (!bag.TryAdd(range.Attribute, values)) { throw AdAttributeRange.Incomplete(); }
        }
        return new(raw.DistinguishedName, bag);
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

    private static bool IsBinaryAttribute(string name)
    {
        ArgumentNullException.ThrowIfNull(name);
        return BinaryAttributes.Contains(name);
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

        if (code == 49)
        {
            var result = new DomeniaOperationException(AdErrors.Credentials, AdErrors.CredentialsMessage);
            result.Data["authenticationKind"] = AdAuthenticationErrors.Kind(ex switch
            {
                LdapException ldap => ldap.ServerErrorMessage,
                DirectoryOperationException directory => directory.Response?.ErrorMessage,
                _ => null,
            });
            return result;
        }
        return code switch
        {
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
