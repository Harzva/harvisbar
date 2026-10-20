"""Protocol acceptance using the official MCP Python client SDK."""
import json
from pathlib import Path
import sys
import unittest
import jsonschema
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT=Path(__file__).resolve().parents[1]

class MCPAcceptance(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_discovery_read_errors_and_preview(self):
        parameters=StdioServerParameters(command='/usr/bin/python3',args=['-I',str(ROOT/'mcp/harvis_versions_mcp.py')])
        async with stdio_client(parameters) as streams:
            async with ClientSession(*streams) as session:
                init=await session.initialize()
                self.assertEqual(init.server_info.name,'harvis-versions')
                tools=(await session.list_tools()).tools
                self.assertEqual(len(tools),5)
                self.assertTrue(all(t.annotations.read_only_hint for t in tools))
                resource=await session.read_resource('harvis-versions://schema/agent-v1')
                schema=json.loads(resource.contents[0].text)
                response=await session.call_tool('versions_list',{'kind':'runtime','limit':1})
                data=response.structured_content
                jsonschema.validate(data,schema)
                self.assertTrue(data['ok']);self.assertEqual(data['data']['items'][0]['id'],'runtime:dsh')
                detail=await session.call_tool('versions_get',{'itemId':'runtime:dsh'})
                self.assertTrue(detail.structured_content['ok'])
                plan=await session.call_tool('versions_plan',{'itemId':'runtime:dsh','operation':'upgrade','targetVersion':'1.0.0'})
                jsonschema.validate(plan.structured_content,schema)
                self.assertFalse(plan.structured_content['data']['executable'])
                valid=await session.call_tool('versions_validate_plan',{'plan':plan.structured_content['data']})
                self.assertTrue(valid.structured_content['data']['unchanged'])
                bad=await session.call_tool('versions_list',{'limit':True})
                self.assertTrue(bad.is_error)
                self.assertEqual(bad.structured_content['error']['code'],'INVALID_ARGUMENT')
                jsonschema.validate(bad.structured_content,schema)
                capabilities=await session.call_tool('versions_capabilities',{})
                self.assertFalse(capabilities.structured_content['data']['mutationsEnabled'])

if __name__=='__main__':unittest.main()
