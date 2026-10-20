#!/usr/bin/env python3
"""Agent contract for the local Harvis version catalog (stdlib-only)."""
import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import sys
import uuid

# Absolute imports are restricted to this shipped sibling directory, even under -I.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from harvis_version_catalog import collect, read_json

ROOT = Path(__file__).resolve().parents[1]
API = 'harvis.version-agent.v1'
KINDS = ['application', 'runtime', 'plugin', 'repository']
ERRORS = {'INVALID_ARGUMENT': 2, 'CONFIG_INVALID': 3, 'SOURCE_UNAVAILABLE': 4,
          'NOT_FOUND': 5, 'SNAPSHOT_CHANGED': 6, 'PLAN_CHANGED': 7, 'PLAN_EXPIRED': 7,
          'INTERNAL_ERROR': 8, 'EXECUTOR_UNAVAILABLE': 9}

class ToolError(Exception):
    def __init__(self, code, message, retryable=False):
        self.code, self.message, self.retryable = code, message, retryable
        super().__init__(message)

def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()

def now():
    return dt.datetime.now(dt.timezone.utc)

def freshness(value):
    try:
        age = (now() - dt.datetime.fromisoformat(value.replace('Z', '+00:00'))).total_seconds()
        if age < -60:
            return {'observedAt': value, 'ageSeconds': None, 'stale': None, 'status': 'clock_skew'}
        age = max(0, int(age))
        return {'observedAt': value, 'ageSeconds': age, 'stale': age > 7200, 'status': 'stale' if age > 7200 else 'available'}
    except (ValueError, TypeError, AttributeError):
        return {'observedAt': value if isinstance(value, str) else None, 'ageSeconds': None, 'stale': None, 'status': 'unknown'}

def check_arguments(args, allowed, required=()):
    if not isinstance(args, dict) or set(args) - set(allowed) or any(k not in args for k in required):
        raise ToolError('INVALID_ARGUMENT', '参数缺失或包含不支持的字段；请读取 tools/list 或 contract。')

def text_arg(args, name, required=False, limit=1024):
    value = args.get(name)
    if value is None and not required:
        return None
    if not isinstance(value, str) or not value.strip() or len(value) > limit:
        raise ToolError('INVALID_ARGUMENT', name + ' 必须是非空且长度受限的字符串。')
    return value

class VersionAgent:
    def __init__(self, config_path=None, collector=collect):
        self.config_path = Path(config_path or Path.home() / '.harvis/version-catalog.json')
        self.collector = collector
        self.retained = None
        self.meta = {'requestId': str(uuid.uuid4()), 'generatedAt': now().isoformat(), 'snapshotRevision': None, 'partial': False, 'sources': [], 'warnings': []}

    def load(self):
        try:
            config = read_json(self.config_path) if self.config_path.exists() else {}
            if not isinstance(config, dict):
                raise ValueError()
            for key in ['githubSnapshot', 'dshExecutable', 'nodeExecutable']:
                if key in config and (not isinstance(config[key], str) or not Path(config[key]).is_absolute()):
                    raise ValueError()
            if 'applicationRoots' in config and (not isinstance(config['applicationRoots'], list) or
                any(not isinstance(x, str) or not Path(x).is_absolute() for x in config['applicationRoots'])):
                raise ValueError()
        except (OSError, ValueError, TypeError):
            raise ToolError('CONFIG_INVALID', '本机 version-catalog.json 无法读取或格式无效。')
        source = {'id': 'github-desk', 'kind': 'snapshot', 'location': config.get('githubSnapshot'),
                  'observedAt': None, 'ageSeconds': None, 'stale': None, 'status': 'unconfigured', 'revision': None}
        try:
            if source['location']:
                raw = read_json(source['location'])
                if not isinstance(raw, dict) or not isinstance(raw.get('repositories'), list) or not isinstance(raw.get('plugins'), list):
                    raise ValueError()
                source.update(freshness(raw.get('generatedAt')))
                source['revision'] = digest(raw)
                if any(v.get('error') for v in raw.get('sources', {}).values() if isinstance(v, dict)):
                    source['status'] = 'partial'
        except (OSError, ValueError, TypeError, AttributeError):
            source['status'] = 'unavailable'
        try:
            snapshot = self.collector(config)
        except Exception:
            raise ToolError('SOURCE_UNAVAILABLE', '本机版本采集失败；不能将失败解释为空清单。', True)
        if any('无法读取 GitHub 工作台快照' in w for w in snapshot['warnings']):
            source['status'] = 'unavailable'
        if source['status'] in ['unavailable', 'unconfigured'] and self.retained:
            snapshot['items'] = [i for i in snapshot['items'] if i['kind'] not in ['repository', 'plugin']] + self.retained
            source['retained'] = True
        elif source['status'] not in ['unavailable', 'unconfigured']:
            self.retained = [i for i in snapshot['items'] if i['kind'] in ['repository', 'plugin']]
        rows = sorted(snapshot['items'], key=lambda i: i['id'])
        app_source = {'id': 'local-installations', 'kind': 'local-read', 'location': None,
                      **freshness(snapshot['generatedAt']), 'revision': None}
        if any('DSH' in w or '应用' in w for w in snapshot['warnings']) or any(i['kind']=='runtime' and i['installedVersion'] is None for i in rows):
            app_source['status'] = 'partial'
        # Exclude observation clocks so repeated reads of unchanged local data have stable revisions.
        revision = digest({'rows': [{k: v for k, v in i.items() if k != 'observedAt'} for i in rows],
                           'sourceRevision': source['revision'], 'config': config})
        self.meta = {'requestId': str(uuid.uuid4()), 'generatedAt': snapshot['generatedAt'],
                     'snapshotRevision': revision, 'partial': source['status'] not in ['available', 'stale'] or bool(snapshot['warnings']),
                     'sources': [source, app_source], 'warnings': snapshot['warnings']}
        return rows

    def find(self, rows, item_id):
        found = next((i for i in rows if i['id'] == item_id), None)
        if found is None:
            if item_id.startswith(('repo:', 'plugin:')) and self.meta['sources'][0]['status'] in ['unavailable', 'unconfigured', 'partial', 'unknown', 'clock_skew']:
                raise ToolError('SOURCE_UNAVAILABLE', '仓库/插件来源不可用，无法判定该项目是否存在。', True)
            raise ToolError('NOT_FOUND', '未找到该稳定 itemId；请先查询清单。')
        return found

    def evidence(self, item):
        return {'sourceId': 'github-desk' if item['kind'] in ['plugin', 'repository'] else 'local-installations',
                **freshness(item['observedAt']), 'runningVerified': False, 'publishedVerified': False}

    def item_state(self, item):
        paths = []
        for value in item['paths']:
            p = Path(value)
            candidates = [p]
            if item['kind'] == 'application':
                candidates += [p / 'Contents/Info.plist', p / 'Contents/Resources/harvis-bundle-receipt.json']
            for candidate in candidates:
                try:
                    stat = candidate.stat()
                    paths.append([str(candidate), stat.st_ino, stat.st_size, stat.st_mtime_ns])
                except OSError:
                    paths.append([str(candidate), None])
        return digest({'item': {k:v for k,v in item.items() if k != 'observedAt'}, 'paths': paths,
                       'sourceStatus': self.meta['sources'][0]['status'] if item['kind'] in ['repository','plugin'] else 'local'})

    def dispatch(self, operation, args):
        self.meta = {'requestId': str(uuid.uuid4()), 'generatedAt': now().isoformat(), 'snapshotRevision': None,
                     'partial': False, 'sources': [], 'warnings': []}
        try:
            data = self.execute(operation, args)
            return self.envelope(data=data)
        except ToolError as error:
            return self.envelope(error=error)
        except Exception:
            return self.envelope(error=ToolError('INTERNAL_ERROR', '版本工具内部错误；未执行任何版本修改。', True))

    def envelope(self, data=None, error=None):
        return {'schemaVersion': API, 'ok': error is None, 'data': data,
                'error': None if error is None else {'code':error.code, 'message':error.message,
                    'retryable':error.retryable, 'exitCode':ERRORS[error.code]}, 'meta': self.meta}

    def execute(self, operation, args):
        if operation == 'capabilities':
            check_arguments(args, [])
            return {'operations': ['list','get','plan','validate-plan','capabilities'], 'mutationsEnabled': False,
                    'dryRunOnly': True, 'contractVersion': API, 'errorExitCodes': ERRORS,
                    'refreshSemantics': 'Each read re-reads local files; does not fetch GitHub or refresh RepoAtlas.',
                    'planTTLSeconds': 900, 'planIsAuthorization': False}
        if operation == 'list':
            check_arguments(args, ['kind','query','offset','limit','expectedSnapshot'])
            kind = text_arg(args, 'kind')
            query = text_arg(args, 'query', limit=512) or ''
            if kind is not None and kind not in KINDS:
                raise ToolError('INVALID_ARGUMENT', 'kind 不在支持列表中。')
            offset, limit = args.get('offset', 0), args.get('limit', 30)
            if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 100:
                raise ToolError('INVALID_ARGUMENT', 'offset 必须非负；limit 必须为 1–100 的整数。')
            expected = text_arg(args, 'expectedSnapshot')
            rows = self.load()
            if expected and expected != self.meta['snapshotRevision']:
                raise ToolError('SNAPSHOT_CHANGED', '清单已变化；请从 offset=0 重新读取。', True)
            rows = [i for i in rows if (not kind or i['kind'] == kind) and query.casefold() in json.dumps(i, ensure_ascii=False).casefold()]
            return {'items': rows[offset:offset+limit], 'total':len(rows), 'offset':offset,
                    'nextOffset':offset+limit if offset+limit < len(rows) else None}
        if operation == 'get':
            check_arguments(args, ['itemId'], ['itemId'])
            item_id = text_arg(args, 'itemId', True)
            item = self.find(self.load(), item_id)
            return {'item':item, 'evidence':self.evidence(item), 'stateHash':self.item_state(item)}
        if operation == 'plan':
            check_arguments(args, ['itemId','operation','targetVersion'], ['itemId','operation','targetVersion'])
            item_id, change, target = [text_arg(args, k, True) for k in ['itemId','operation','targetVersion']]
            if change not in ['upgrade','switch','rollback'] or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,127}', target):
                raise ToolError('INVALID_ARGUMENT', '不支持的修改类型或目标版本格式。')
            item = self.find(self.load(), item_id)
            start = now()
            plan = {'itemId':item_id, 'operation':change, 'targetVersion':target, 'createdAt':start.isoformat(),
                    'expiresAt':(start+dt.timedelta(seconds=900)).isoformat(), 'expectedStateHash':self.item_state(item),
                    'dryRun':True, 'executable':False,
                    'before':{'sourceVersion':item['sourceVersion'], 'installedVersion':item['installedVersion'], 'paths':item['paths']},
                    'requestedAfter':{'version':target, 'verified':False},
                    'blockers':['EXECUTOR_UNAVAILABLE','TARGET_ARTIFACT_UNVERIFIED','BACKUP_UNVERIFIED'],
                    'steps':['核对目标项目、来源与目标版本，验证制品哈希/签名。',
                             '保存当前版本和配置的可恢复备份，并验证恢复方法。',
                             '在隔离位置准备候选，展示实际文件与 profile 变更。',
                             '获得本次修改授权后，由对应产品的受支持执行器安装。',
                             '核对安装/运行版本与健康检查，失败时由执行器恢复原备份。'],
                    'rollback':{'implemented':False, 'backupCreated':False,
                                'requirement':'执行器必须返回备份位置、校验摘要与经过验证的恢复步骤。'},
                    'notice':'这是只读预检建议，不是安装模拟结果、可执行脚本或授权凭证。'}
            if self.evidence(item)['stale'] is not False or self.meta['partial']:
                plan['blockers'].append('SOURCE_REVALIDATION_REQUIRED')
            plan['planHash'] = digest(plan)
            return plan
        if operation == 'validate-plan':
            check_arguments(args, ['plan'], ['plan'])
            plan = args['plan']
            if not isinstance(plan, dict) or not all(k in plan for k in ['planHash','itemId','expectedStateHash','expiresAt','createdAt']):
                raise ToolError('INVALID_ARGUMENT', '需要 plan 工具生成的完整计划对象。')
            if digest({k:v for k,v in plan.items() if k != 'planHash'}) != plan['planHash']:
                raise ToolError('PLAN_CHANGED', '计划内容已改变，请重新生成预览。')
            try:
                end = dt.datetime.fromisoformat(plan['expiresAt'])
                start = dt.datetime.fromisoformat(plan['createdAt'])
                if not end.tzinfo or not start.tzinfo or (end-start).total_seconds()!=900 or start > now()+dt.timedelta(seconds=60):
                    raise ValueError()
            except (ValueError, TypeError):
                raise ToolError('INVALID_ARGUMENT', '计划时间字段无效。')
            if end <= now():
                raise ToolError('PLAN_EXPIRED', '计划已过期，请重新生成。', True)
            item = self.find(self.load(), text_arg(plan, 'itemId', True))
            if self.item_state(item) != plan['expectedStateHash']:
                raise ToolError('SNAPSHOT_CHANGED', '该项目状态已变化；旧计划不能继续使用。', True)
            return {'unchanged':True, 'executable':False, 'reason':'EXECUTOR_UNAVAILABLE',
                    'planHash':plan['planHash'], 'notice':'状态对比通过不代表授权、备份有效或可执行。'}
        if operation in ['apply','execute','upgrade','switch','rollback']:
            raise ToolError('EXECUTOR_UNAVAILABLE', '尚未实现实际修改与回退执行器；此工具不能执行版本变更。')
        raise ToolError('INVALID_ARGUMENT', '未知操作；请使用 capabilities。')

class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ToolError('INVALID_ARGUMENT', '命令参数无效；请使用 agent --help。')

def main(argv=None):
    agent = VersionAgent()
    try:
        p = ArgumentParser(description='Structured version reads and non-executable change previews. No upgrades are performed.')
        p.add_argument('operation', choices=['list','get','plan','validate-plan','capabilities','contract','apply'])
        p.add_argument('--kind', choices=KINDS); p.add_argument('--query'); p.add_argument('--offset',type=int); p.add_argument('--limit',type=int)
        p.add_argument('--expected-snapshot'); p.add_argument('--item-id'); p.add_argument('--change',choices=['upgrade','switch','rollback'])
        p.add_argument('--target-version'); p.add_argument('--plan-file'); p.add_argument('--config')
        a = p.parse_args(argv)
        agent = VersionAgent(a.config)
        if a.operation == 'contract':
            print(json.dumps(read_json(ROOT/'schemas/version-agent-v1.schema.json'),ensure_ascii=False,indent=2));return 0
        args = {dest:getattr(a, src) for src,dest in [('kind','kind'),('query','query'),('offset','offset'),('limit','limit'),('expected_snapshot','expectedSnapshot'),('item_id','itemId'),('change','operation'),('target_version','targetVersion')] if getattr(a,src) is not None}
        if a.plan_file:
            try:
                value = json.load(sys.stdin) if a.plan_file == '-' else read_json(a.plan_file)
                args['plan'] = value['data'] if value.get('schemaVersion') == API else value
            except (OSError, ValueError, TypeError, AttributeError):
                raise ToolError('INVALID_ARGUMENT', '计划文件必须是 plan 输出 JSON。')
        result = agent.dispatch(a.operation,args)
    except ToolError as error:
        result = agent.envelope(error=error)
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return 0 if result['ok'] else result['error']['exitCode']

if __name__ == '__main__':
    raise SystemExit(main())
