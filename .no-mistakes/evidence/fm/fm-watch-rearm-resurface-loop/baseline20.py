import os, pathlib, subprocess as sp, time, signal, re, shutil, json
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M5EFY9G488CQ5FFF1X7003H2/baseline20'); lab=root/'aprobe-baseline20'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('STATE','TMUX','HERDR_SESSION','HERDR_SOCKET')}
env.update(FM_HOME=str(lab),FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_ARM_CONFIRM_TIMEOUT='30',TMUX='.live-watch-lab/absent-socket,0,0')
procs=[]; files=[]; events=[]
def record(s):
 print(s,flush=True); events.append(s)
def run(args):
 p=sp.run(args,env=env,text=True,capture_output=True,timeout=40); record('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+'exit='+str(p.returncode)); assert p.returncode==0; return p

def start(name,args,extra={}):
 f=open(evidence/(name+'.log'),'w'); files.append(f)
 p=sp.Popen([str(root/'bin/.baseline-watch-arm.sh')]+args,env=dict(env,**extra),stdout=f,stderr=sp.STDOUT,start_new_session=True); procs.append(p); return p,evidence/(name+'.log')
def ready(p,path):
 deadline=time.time()+40
 while time.time()<deadline:
  if 'watcher: started pid=' in path.read_text(): return
  assert p.poll() is None,path.read_text()
  time.sleep(.1)
 raise AssertionError(path.read_text())
def pid(): return int((lab/'state/.watch.lock/pid').read_text())
def append(): run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append signal live-check "signal: pending operator work"'])
def ack():
 p=run(['bin/fm-wake-drain.sh']); m=re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr); assert m,p.stderr
 run(['bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2]])
def state(label):
 for n in ['.watcher-down','.wake-queue','.watch-cycle-exits.log']:
  p=lab/'state'/n
  record(label+' '+n+'\n'+(p.read_text() if p.exists() else '<absent>'))
BASELINE=True
try:
 run(['bin/fm-lab-home.sh','create',str(lab)])
 owner,out=start('initial',[],{'FM_WATCH_PREDECESSOR_ARM_PID':str(os.getpid())}); ready(owner,out)
 append(); ack()
 old=pid(); os.kill(old,signal.SIGSTOP)
 successor,out=start('delayed-idle',['--take-over',str(owner.pid)])
 time.sleep(20); os.kill(old,signal.SIGCONT)
 if BASELINE:
  successor.wait(timeout=45); owner.wait(timeout=40)
  record('old takeover exit='+str(successor.returncode)+' '+out.read_text())
  state('after old takeover')
  successor,out=start('false-recovery',[]); successor.wait(timeout=45)
  record('next idle rearm: '+out.read_text())
  assert 'check: rearm-resurface' in out.read_text()
  assert not (lab/'state/.wake-queue').read_text().strip()
  record('REPRODUCED: old implementation emits recovery with an empty queue after delayed idle handover')
 else:
  ready(successor,out); owner.wait(timeout=40); time.sleep(3)
  assert successor.poll() is None,out.read_text()
  assert (lab/'state/.watcher-down').read_text().startswith('acked:')
  assert not (lab/'state/.wake-queue').read_text().strip()
  record('20-second delayed idle handover remains quiet: '+out.read_text()); state('fixed delayed handover')
finally:
 for p in procs:
  if p.poll() is None:
   try: os.killpg(p.pid,signal.SIGCONT); os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
 for p in procs:
  try: p.wait(timeout=35)
  except sp.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
 for f in files: f.close()
 (evidence/'live-watch-transcript.log').write_text('\n'.join(events)+'\n')
 if lab.exists(): shutil.rmtree(lab)
