using System.Collections.Immutable;

namespace Domenia.Core;

/// <summary>Objects of an OU and of its sub-OUs, enabled or not; null when not read exhaustively (docs/OPERATIONS.md § 9).</summary>
public sealed record OuCounts(int? Users, int? Computers, int? Groups);

/// <summary>
/// One OU of the tree. <see cref="Path"/> is the readable path from the domain (« example.local › Postes › Paris »);
/// <see cref="HasChildren"/> tells whether the OU holds sub-OUs.
/// </summary>
public sealed record OuEntry(string Dn, string Name, string Path, bool HasChildren, OuCounts Counts);

/// <summary>The OU (or the domain root) whose children are listed.</summary>
public sealed record OuParent(string Dn, string Name, string Path);

/// <summary>Result of directory.ou.children.</summary>
public sealed record OuChildren(OuParent Parent, ImmutableArray<OuEntry> Children);

/// <summary>Result of directory.ou.search: at most the limit, <see cref="Truncated"/> when more OUs match.</summary>
public sealed record OuSearchResult(ImmutableArray<OuEntry> Results, bool Truncated);
