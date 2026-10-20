import copy
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from harvis_version_agent import VersionAgent,digest,freshness
from harvis_version_catalog import row

class AgentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.source=self.root/'snapshot.json'
        self.timestamp=dt.datetime.now(dt.timezone.utc).isoformat()
        self.source.write_text(json.dumps({'generatedAt':self.timestamp,'repositories':[],'plugins':[]}))
        self.config=self.root/'config.json';self.config.write_text(json.dumps({'githubSnapshot':str(self.source)}))
        self.items=[row('plugin:demo','demo','plugin',sourceVersion='1.0.0',observedAt=self.timestamp),row('runtime:dsh','DSH','runtime',installedVersion='1.0.0',observedAt=self.timestamp)]
        self.agent=VersionAgent(self.config,collector=lambda c: {'generatedAt':dt.datetime.now(dt.timezone.utc).isoformat(),'items':copy.deepcopy(self.items),'warnings':[]})

    def test_versions_nulls_and_revision_stability(self):
        a=self.agent.dispatch('list',{'limit':1});b=self.agent.dispatch('list',{'offset':1,'expectedSnapshot':a['meta']['snapshotRevision']})
        self.assertTrue(b['ok']);self.assertEqual(a['data']['nextOffset'],1)
        self.assertIsNone(a['data']['items'][0]['runningVersion'])
        self.assertEqual(a['meta']['snapshotRevision'],b['meta']['snapshotRevision'])

    def test_pagination_rejects_changed_snapshot(self):
        first=self.agent.dispatch('list',{});self.items[0]['sourceVersion']='2.0.0'
        result=self.agent.dispatch('list',{'offset':1,'expectedSnapshot':first['meta']['snapshotRevision']})
        self.assertEqual(result['error']['code'],'SNAPSHOT_CHANGED')

    def test_failure_retains_success_but_not_freshness_claim(self):
        self.agent.dispatch('list',{})
        self.source.unlink();self.items=[]
        result=self.agent.dispatch('get',{'itemId':'plugin:demo'})
        self.assertTrue(result['ok']);self.assertTrue(result['meta']['partial'])
        self.assertTrue(result['meta']['sources'][0]['retained'])
        self.assertEqual(result['meta']['sources'][0]['status'],'unavailable')

    def test_unavailable_is_not_absent(self):
        self.source.unlink();self.items=[]
        result=self.agent.dispatch('get',{'itemId':'plugin:missing'})
        self.assertEqual(result['error']['code'],'SOURCE_UNAVAILABLE')

    def test_plan_and_validation_do_not_write(self):
        before=sorted(str(p) for p in self.root.rglob('*'))
        plan=self.agent.dispatch('plan',{'itemId':'plugin:demo','operation':'upgrade','targetVersion':'2.0.0'})['data']
        self.assertFalse(plan['executable']);self.assertFalse(plan['rollback']['backupCreated'])
        valid=self.agent.dispatch('validate-plan',{'plan':plan})
        self.assertTrue(valid['data']['unchanged']);self.assertFalse(valid['data']['executable'])
        self.assertEqual(before,sorted(str(p) for p in self.root.rglob('*')))
        self.items[0]['sourceVersion']='1.0.1'
        self.assertEqual(self.agent.dispatch('validate-plan',{'plan':plan})['error']['code'],'SNAPSHOT_CHANGED')

    def test_edited_and_expired_plan(self):
        plan=self.agent.dispatch('plan',{'itemId':'plugin:demo','operation':'rollback','targetVersion':'0.9.0'})['data']
        edited=copy.deepcopy(plan);edited['targetVersion']='9.0.0'
        self.assertEqual(self.agent.dispatch('validate-plan',{'plan':edited})['error']['code'],'PLAN_CHANGED')
        expired=copy.deepcopy(plan); start=dt.datetime.now(dt.timezone.utc)-dt.timedelta(hours=1)
        expired.update(createdAt=start.isoformat(),expiresAt=(start+dt.timedelta(minutes=15)).isoformat())
        expired['planHash']=digest({k:v for k,v in expired.items() if k!='planHash'})
        self.assertEqual(self.agent.dispatch('validate-plan',{'plan':expired})['error']['code'],'PLAN_EXPIRED')

    def test_mutation_and_unknown_inputs_fail_closed(self):
        for op,args in [('apply',{}),('list',{'limit':True}),('get',{'itemId':'plugin:demo','shell':'rm'}),('plan',{'itemId':'plugin:demo','operation':'upgrade','targetVersion':'$(touch bad)'})]:
            self.assertFalse(self.agent.dispatch(op,args)['ok'])

    def test_clock_skew_and_unknown_are_not_fresh(self):
        future=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=1)).isoformat()
        self.assertIsNone(freshness(future)['stale']);self.assertEqual(freshness(future)['status'],'clock_skew')
        self.assertIsNone(freshness(None)['stale'])

    def test_invalid_config_and_cli_argument_errors_are_json(self):
        self.config.write_text('[]')
        result=self.agent.dispatch('list',{})
        self.assertEqual(result['error']['code'],'CONFIG_INVALID')
        p=subprocess.run([sys.executable,'-I',str(ROOT/'scripts/harvis_version_agent.py'),'list','--limit','wrong'],capture_output=True,text=True)
        self.assertEqual(p.returncode,2);self.assertEqual(json.loads(p.stdout)['error']['code'],'INVALID_ARGUMENT')

    def test_all_output_variants_match_schema(self):
        import jsonschema
        schema=json.loads((ROOT/'schemas/version-agent-v1.schema.json').read_text())
        jsonschema.Draft202012Validator.check_schema(schema)
        cases=[('list',{}),('get',{'itemId':'plugin:demo'}),('plan',{'itemId':'plugin:demo','operation':'switch','targetVersion':'2.0.0'}),('capabilities',{}),('get',{'itemId':'plugin:missing'}),('apply',{})]
        plan=self.agent.dispatch(*cases[2])['data'];cases.append(('validate-plan',{'plan':plan}))
        for op,args in cases:jsonschema.validate(self.agent.dispatch(op,args),schema)

if __name__=='__main__':unittest.main()
