#!/bin/bash
# mxOrchestrate UserPromptSubmit Hook — reads local state, outputs 3-line context
# Pure bash with node fallback. Performance target: <100ms. Silent fail on any error.

STATE_FILE=".claude/orchestrate-state.json"
[ ! -f "$STATE_FILE" ] && exit 0

# Use node for JSON parsing (reliable)
node -e "
const fs=require('fs');
try{
  const s=JSON.parse(fs.readFileSync('$STATE_FILE','utf8'));
  if(!s.workflow_stack||!s.workflow_stack.length)process.exit(0);
  const a=s.workflow_stack[0],p=s.workflow_stack.length-1,ah=(s.adhoc_tasks||[]).length,d=s.state_deltas||0;
  const ag=s.team_agents||[],r=ag.filter(x=>x.status==='running').length,dn=ag.filter(x=>x.status==='done').length;
  let t='idle';if(r||dn){const p=[];if(r)p.push(r+' running');if(dn)p.push(dn+' done');t=p.join(', ');}
  console.log('[mxOrchestrate] '+a.id+' '+a.title+' ('+a.current_step+'/'+a.total_steps+' '+a.status+') | parked: '+p);
  console.log('  adhoc: '+ah+' | deltas since save: '+d+' | team: '+t);
  console.log('  last: \"'+(a.last_action||'–')+'\"');
  if(d>=8)console.log('  ⚡ '+d+' State-Deltas seit letztem Save — Zwischen-Save empfohlen');
  if(p>3)console.log('  ⚡ '+p+' geparkte Workflows — Abschluss empfohlen');
}catch(e){process.exit(0);}
" 2>/dev/null
