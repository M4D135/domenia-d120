#!/usr/bin/env python3
"""Explicitly pin reviewed V2 compiled operation sources. Never invoked to rewrite pins by a build.
The Windows build only verifies the committed hashes. Updating requires a reviewed commit.
"""
import argparse
import hashlib
import json
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
OPERATIONS = ('DnsReverseLookup', 'LegacyMigration', 'LocalIndexRead', 'LocalStore', 'ParkSharedSync',
              'StorageBackup', 'StorageIntegrity', 'StorageMaintenance', 'StoragePurge', 'StorageRetention', 'StorageUsage')
PROJECTS = ('Domenia.Core', 'Domenia.Store', 'Domenia.Ad', 'Domenia.Bridge', 'Domenia.Inventory', 'Domenia.App', 'Domenia.Engine', 'Domenia.Simulation')


def make(root):
    # V2 methods share compiled dependencies. Pin the entire trusted implementation closure rather than
    # pretending an isolated source method proves all code reached by that method.
    files = []
    source_count = 0
    for project in PROJECTS:
        for path in sorted((root / 'src' / project).rglob('*')):
            if any(p in ('bin', 'obj') for p in path.relative_to(root).parts):
                continue
            if path.suffix not in ('.cs', '.csproj'):
                continue
            if path.is_symlink():
                raise ValueError('Source redirigée: ' + str(path))
            files.append({'path': path.relative_to(root).as_posix(), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
            source_count += 1
    for name in ('Directory.Build.props', 'global.json', 'NuGet.config'):
        path = root / name
        if path.is_symlink():
            raise ValueError('Configuration redirigée: ' + str(path))
        files.append({'path': name, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    files.sort(key=lambda x: x['path'])
    if not 10 <= len(files) <= 4096:
        raise ValueError('Fermeture des sources hors bornes')
    implementation = hashlib.sha256(''.join(f"{f['path']}={f['sha256']}\n" for f in files).encode()).hexdigest()
    operations = [{'name': name, 'implementationSha256': implementation} for name in OPERATIONS]
    fingerprint = hashlib.sha256(''.join(f"{op['name']}={op['implementationSha256']}\n" for op in operations).encode()).hexdigest()
    document = {'format': 'Domenia.OperationContracts/1', 'scope': 'compiled-implementation-closure',
                'operations': operations, 'files': files, 'fingerprint': fingerprint}
    content = (json.dumps(document, ensure_ascii=False, indent=2) + '\n').encode()
    registry_hash = hashlib.sha256(content).hexdigest()
    xml = ['<Project>', '  <!-- Explicit reviewed pins. Regenerate only after review; builds never update this file. -->',
           '  <PropertyGroup>', f'    <DomeniaOperationRegistryFingerprint>{fingerprint}</DomeniaOperationRegistryFingerprint>',
           '  </PropertyGroup>', '  <ItemGroup>',
           f'    <AssemblyMetadata Include="DomeniaOperationRegistry" Value="{fingerprint}" />',
           f'    <DomeniaPinnedSource Include="$(MSBuildThisFileDirectory)operation-contracts.json" ExpectedSha256="{registry_hash.upper()}" />']
    xml.extend(f'    <DomeniaPinnedSource Include="$(MSBuildThisFileDirectory)../{escape(f["path"])}" ExpectedSha256="{f["sha256"].upper()}" />' for f in files)
    xml += ['  </ItemGroup>', '  <Target Name="VerifyDomeniaOperationContracts" BeforeTargets="CoreCompile">', '    <ItemGroup>']
    for project in PROJECTS:
        directory = f'$(MSBuildThisFileDirectory)../src/{project}/'
        xml.append(f'      <DomeniaCurrentSource Include="{directory}**/*.cs;{directory}**/*.csproj" Exclude="{directory}**/bin/**;{directory}**/obj/**" />')
    xml += ['    </ItemGroup>',
            f'    <Error Condition="\'@(DomeniaCurrentSource->Count())\' != \'{source_count}\'" Text="Fermeture des sources modifiée : ajout ou retrait non revu. Mettre à jour explicitement le registre avant compilation." />',
            '    <GetFileHash Files="@(DomeniaPinnedSource)" Algorithm="SHA256" HashEncoding="hex">',
            '      <Output TaskParameter="Items" ItemName="DomeniaMeasuredSource" />', '    </GetFileHash>',
            '    <Error Condition="\'%(DomeniaMeasuredSource.FileHash)\' != \'%(DomeniaMeasuredSource.ExpectedSha256)\'" Text="Corps non épinglé : %(DomeniaMeasuredSource.Identity). Revue et mise à jour explicite du registre requises ; aucune compilation autorisée." />',
            '  </Target>', '</Project>', '']
    return content, '\n'.join(xml).encode()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Mettre à jour les épingles après revue explicite.')
    args = parser.parse_args()
    content, props = make(ROOT)
    targets = [(ROOT / 'tools/operation-contracts.json', content), (ROOT / 'tools/operation-contracts.props', props)]
    if args.write:
        for path, data in targets:
            path.write_bytes(data)
    else:
        for path, data in targets:
            if not path.is_file() or path.read_bytes() != data:
                raise SystemExit('Registre différent des corps courants : ' + str(path))


if __name__ == '__main__':
    main()
