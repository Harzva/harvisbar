#!/usr/bin/env python3
"""Local version inventory shared by HarvisBar and agents; never changes installs."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from urllib.parse import urlsplit, urlunsplit

SCHEMA = 'harvis.version-catalog.v1'
ROOT = Path(__file__).resolve().parents[1]


def read_json(path):
    with Path(path).open() as stream:
        return json.load(stream)


def safe_url(value):
    if not isinstance(value, str):
        return None
    try:
        p = urlsplit(value)
        if p.scheme != 'https' or not p.hostname or p.username or p.password:
            return None
        return urlunsplit((p.scheme, p.netloc, p.path, '', ''))
    except ValueError:
        return None


def row(key, name, kind, **values):
    result = dict(id=key, name=name, kind=kind, sourceVersion=None, installedVersion=None,
                  runningVersion=None, publishedVersion=None, repositoryURL=None, paths=[],
                  installations=[], branch=None, commit=None, dirty=None, note='', observedAt=None)
    result.update(values)
    return result


def collect(config, home=None):
    home = Path(home or Path.home())
    now = dt.datetime.now(dt.timezone.utc).isoformat()
    items, warnings = [], []
    snapshot_at = None
    snapshot_path = config.get('githubSnapshot')
    if snapshot_path:
        try:
            snapshot = read_json(snapshot_path)
            if not isinstance(snapshot, dict) or not isinstance(snapshot.get('repositories'), list) or not isinstance(snapshot.get('plugins'), list):
                raise ValueError('invalid snapshot shape')
            snapshot_at = snapshot.get('generatedAt')
            # Source indexes are observations, not evidence of currently loaded software.
            for repo in snapshot['repositories']:
                items.append(row('repo:' + repo['key'], repo['name'], 'repository',
                    repositoryURL=safe_url(repo.get('url')), paths=repo.get('paths', []),
                    dirty=repo.get('dirty') if repo.get('verified') else None,
                    note='RepoAtlas 索引；目录与 Git 状态需实时核验', observedAt=snapshot_at))
            for plugin in snapshot['plugins']:
                sources = plugin.get('sources', [])
                installs = plugin.get('installations', [])
                versions = sorted(set(str(i['version']) for i in installs if i.get('packagePresent') and i.get('version') not in [None, 'unknown']))
                items.append(row('plugin:' + plugin['name'], plugin['name'], 'plugin',
                    sourceVersion=sources[0].get('version') if sources else None,
                    installedVersion=', '.join(versions) or None,
                    repositoryURL=safe_url(plugin.get('url')),
                    paths=[s['path'] for s in sources if s.get('path')],
                    installations=[dict(profile=i['profile'], version=i.get('version') if i.get('packagePresent') and i.get('version') != 'unknown' else None,
                                        packagePresent=bool(i.get('packagePresent'))) for i in installs],
                    branch=sources[0].get('branch') if sources else None,
                    dirty=sources[0].get('dirty') if sources else None,
                    note='安装包存在不代表运行启用；公开发布版本尚未查询', observedAt=snapshot_at))
            try:
                age = dt.datetime.now(dt.timezone.utc) - dt.datetime.fromisoformat(snapshot_at.replace('Z', '+00:00'))
                if age.total_seconds() > 7200:
                    warnings.append('仓库与插件清单超过 2 小时；请刷新 GitHub 工作台的数据源。')
            except (ValueError, AttributeError, TypeError):
                warnings.append('仓库与插件清单时间未知。')
            if any(source.get('error') for source in snapshot.get('sources', {}).values() if isinstance(source, dict)):
                warnings.append('GitHub 工作台存在采集错误，部分记录可能来自上次成功快照。')
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            warnings.append('无法读取 GitHub 工作台快照；仓库与插件数据暂不可用。请检查本机配置。')
    else:
        warnings.append('尚未绑定 GitHub 工作台快照。请配置 githubSnapshot。')
    roots = config.get('applicationRoots', [str(home / 'Applications'), '/Applications'])
    for root in roots:
        for app in sorted(Path(root).glob('*[Hh]arvis*.app')):
            try:
                with (app / 'Contents/Info.plist').open('rb') as stream:
                    info = plistlib.load(stream)
                receipt_file = app / 'Contents/Resources/harvis-bundle-receipt.json'
                receipt = read_json(receipt_file) if receipt_file.is_file() else {}
                items.append(row('app:' + str(app), app.stem, 'application',
                    installedVersion=info.get('CFBundleShortVersionString'), paths=[str(app)],
                    commit=receipt.get('provenance', {}).get('sourceCommit'),
                    note='已安装应用；构建提交来自 receipt，未验证正在运行的进程版本。' +
                         (' 此副本可能用于回滚。' if any(x in app.name.lower() for x in ['past', 'rollback', 'pre-']) else ''), observedAt=now))
            except (OSError, ValueError, plistlib.InvalidFileException):
                warnings.append('无法读取应用版本：' + app.name)
    executable = Path(config.get('dshExecutable', str(home / '.local/bin/dsh')))
    version = None
    if executable.is_file():
        try:
            env = {'HOME': str(home), 'PATH': str(home / '.local/bin') + ':/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin', 'DSH_TELEMETRY_DISABLED': '1'}
            command = [str(executable), '--version']
            if config.get('nodeExecutable'):
                command.insert(0, config['nodeExecutable'])
            result = subprocess.run(command, capture_output=True, text=True, timeout=8, env=env)
            output = result.stdout.strip()
            if result.returncode == 0 and re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.+-]*', output):
                version = output
            else:
                warnings.append('DSH 版本命令未返回可识别版本。')
        except (OSError, subprocess.TimeoutExpired):
            warnings.append('DSH 版本读取失败或超时。')
    items.insert(0, row('runtime:dsh', 'DeepSeek Harness', 'runtime', installedVersion=version,
        repositoryURL='https://github.com/deepseek-ai/deepseek-harness', paths=[str(executable)],
        note='本机配置的 CLI 版本；其他安装、Home 与实际运行状态请查看 DSH 运行目录。', observedAt=now))
    return dict(schemaVersion=SCHEMA, generatedAt=now, githubSnapshotAt=snapshot_at,
                warnings=warnings, items=items)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['list', 'schema'])
    parser.add_argument('--config', default=str(Path.home() / '.harvis/version-catalog.json'))
    parser.add_argument('--kind', choices=['application', 'runtime', 'plugin', 'repository'])
    parser.add_argument('--query', default='')
    args = parser.parse_args()
    if args.command == 'schema':
        data = read_json(ROOT / 'schemas/version-catalog-v1.schema.json')
    else:
        path = Path(args.config)
        try:
            config = read_json(path) if path.exists() else {}
            if not isinstance(config, dict):
                raise ValueError('configuration must be an object')
            data = collect(config)
        except (OSError, ValueError, TypeError):
            print('无法读取版本目录配置。', file=sys.stderr)
            return 1
        data['items'] = [item for item in data['items'] if (not args.kind or item['kind'] == args.kind)
                         and args.query.casefold() in json.dumps(item, ensure_ascii=False).casefold()]
    print(json.dumps(data, ensure_ascii=False, indent=2))
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
