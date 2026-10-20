#!/usr/bin/env python3
"""Stable dispatch: legacy catalog, structured agent commands, and MCP."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))

HELP='''Harvis Versions — local inventory and agent interface

harvis-versions list [--kind KIND] [--query TEXT]     Original catalog JSON
harvis-versions schema                              Original catalog schema
harvis-versions agent --help                        Structured agent commands
harvis-versions agent list --limit 30               Paged, sourced JSON envelope
harvis-versions agent capabilities                  Operations, errors, limits
harvis-versions agent contract                      Agent response JSON Schema
harvis-versions mcp                                 stdio MCP (five read-only tools)

Reads do not fetch GitHub or change installed versions. Change plans are
non-executable previews. No upgrade, switch, uninstall or rollback executor.
'''

def main():
    if len(sys.argv)==1 or sys.argv[1] in ['-h','--help','help']:
        print(HELP);return 0
    if sys.argv[1]=='agent':
        from harvis_version_agent import main as agent_main
        return agent_main(sys.argv[2:])
    if sys.argv[1]=='mcp':
        if len(sys.argv)!=2:
            print('mcp accepts no per-call configuration',file=sys.stderr);return 2
        sys.path.insert(0,str(ROOT/'mcp'))
        from harvis_versions_mcp import main as mcp_main
        return mcp_main()
    from harvis_version_catalog import main as catalog_main
    return catalog_main()

if __name__=='__main__':raise SystemExit(main())
