import os,subprocess,json,pathlib
R=pathlib.Path.cwd(); L=R/'.live-slot'; E=pathlib.Path('~/.no-mistakes/evidence/01M5EFP6S6QATE9Z6D1CGR0048'); log=open(E/'live-slot-transcript.log','w',buffering=1)
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TMUX','TMUX_PANE','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k)
env.update(FM_HOME=str(L/'home'),PATH=str(L/'tools')+':/usr/bin:/bin:/usr/sbin:/sbin',TMUX=str(R/'.s')+',0,0',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
S='fm-lab-slot'
def run(args,cwd=R,ok=True):
 p=subprocess.run(list(map(str,args)),cwd=cwd,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode)+'\n')
 if ok and p.returncode: raise RuntimeError(p.stdout)
 return p
slots=sorted((L/'project/.treehouse').glob('*/[12]/project'))
assert len(slots)==2
(L/'home/config/backlog-backend').write_text('manual\n')
def meta(id,slot,gen,pr='',ddev=''):
 p=L/'home/state'/f'{id}.meta'
 p.write_text(f'window={S}:fm-{id}\nendpoint_task_id={id}\nbackend=tmux\nworktree={slot}\nproject={L}/project\nkind={"ship" if id.startswith("stale") else "scout"}\nspawn_gen={gen}\n'+(f'pr={pr}\n' if pr else '')+(f'ddev_name={ddev}\n' if ddev else ''))
 return p
merged='https://github.com/cli/cli/pull/1'
try:
 run(['tmux','-S',R/'.s','-f','/dev/null','new-session','-d','-s',S,'-x','120','-y','40','sleep 900'])
 for i,slot in enumerate(slots,1):
  (slot/'sentinel').write_text('preserve live work\n')
  meta(f'stale-{i}',slot,'s1000.1.1',merged,f'lab-slot-{i}')
  meta(f'live-{i}',slot,'s2000.1.1',ddev=f'lab-slot-{i}')
  report=L/'home/data'/f'live-{i}'/'report.md'; report.parent.mkdir(exist_ok=True); report.write_text('Disposable scout report.\n')
  run(['tmux','new-window','-d','-t',S+':','-n',f'fm-live-{i}','-c',slot,'sleep 900'])
  run(['tmux','set-window-option','-t',f'{S}:fm-live-{i}','automatic-rename','off'])
 def guard(label,gen='s1000.1.1',pr=merged,ddev='lab-slot-1',endpoint=False):
  log.write('\nSCENARIO '+label+'\n')
  p=meta('stale-1',slots[0],gen,pr,'lab-slot-1'); meta('live-1',slots[0],'s2000.1.1',ddev=ddev)
  before=p.read_bytes()
  if endpoint: run(['tmux','new-window','-d','-t',S+':','-n','fm-stale-1','-c',slots[0],'sleep 900'])
  result=run([R/'bin/fm-teardown.sh','stale-1','--force'],ok=False)
  assert result.returncode!=0 and 'also task live-1' in result.stdout,result.stdout
  assert p.read_bytes()==before and (slots[0]/'sentinel').exists()
  run(['tmux','has-session','-t',S+':fm-live-1'])
  if endpoint: run(['tmux','kill-window','-t',S+':fm-stale-1'])
  log.write('VERIFIED refusal preserves both task records, live endpoint, and slot sentinel\n')
 guard('missing DDEV proof',ddev='')
 guard('missing PR proof',pr='')
 guard('older successor',gen='s3000.1.1')
 guard('equal generation',gen='s2000.1.1')
 guard('malformed generation',gen='invalid')
 guard('unmerged PR',pr='https://github.com/cli/cli/pull/14768')
 guard('endpoint still occupied',endpoint=True)
 meta('stale-1',slots[0],'s1000.1.1',merged,'lab-slot-1')
 for i,slot in enumerate(slots,1):
  log.write(f'\nSCENARIO retire stale-{i} while live-{i} owns slot\n')
  run([R/'bin/fm-teardown.sh',f'stale-{i}'])
  assert not (L/'home/state'/f'stale-{i}.meta').exists()
  assert (L/'home/state'/f'live-{i}.meta').exists() and (slot/'sentinel').read_text()=='preserve live work\n'
  run(['tmux','has-session','-t',f'{S}:fm-live-{i}'])
  log.write('VERIFIED old record removed; successor record, process, and dirty worktree preserved\n')
 for i,slot in enumerate(slots,1):
  log.write(f'\nSCENARIO clean current holder live-{i} and reacquire slot\n')
  record=L/'home/state'/f'live-{i}.meta'
  record.write_text(record.read_text().replace('kind=scout', 'kind=ship')+'mode=local-only\n')
  (slot/'sentinel').unlink()
  (slot/f'result-{i}.txt').write_text('Completed disposable task\n')
  run(['git','add',f'result-{i}.txt'],cwd=slot)
  run(['git','-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-qm','completed task'],cwd=slot)
  head=run(['git','rev-parse','HEAD'],cwd=slot).stdout.strip()
  run(['git','-c','user.name=Lab','-c','user.email=lab@example.invalid','merge','--no-edit',head],cwd=L/'project')
  run([R/'bin/fm-teardown.sh',f'live-{i}'])
  assert not (L/'home/state'/f'live-{i}.meta').exists()
  assert run(['tmux','has-session','-t',f'{S}:fm-live-{i}'],ok=False).returncode!=0
  assert not (slot/'sentinel').exists()
  log.write('VERIFIED current record and endpoint removed; slot reset\n')
 for i in range(2):
  p=run(['treehouse','get','--lease','--json'],cwd=L/'project')
  obj=json.loads(next(line for line in p.stdout.splitlines() if line.startswith('{')))
  assert pathlib.Path(obj['path']) in slots
  log.write('VERIFIED pool slot reacquired: '+obj['path']+'\n')
 log.write('ALL LIVE SCENARIOS PASSED\n')
finally:
 run(['tmux','-S',R/'.s','kill-server'],ok=False)
 log.close()
