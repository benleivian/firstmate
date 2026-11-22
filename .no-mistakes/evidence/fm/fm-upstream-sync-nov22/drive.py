import os, pathlib, subprocess, json, hashlib, shutil
root=pathlib.Path.cwd(); lab=root/'.local-validation/live-home'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M82NHW5MMJN064FSKB1M5FXN')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','HERDR_'))}
env['FM_HOME']=str(lab)
log=(evidence/'live-cli.log').open('w')
def run(script,*args,expected=0):
 p=subprocess.run([str(root/'bin'/script),*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.write('$ '+script+' '+' '.join(args)+'\n'+p.stdout+'exit='+str(p.returncode)+'\n');log.flush()
 assert p.returncode==expected,(script,p.returncode,p.stdout)
 return p.stdout
try:
 run('fm-lab-home.sh','create',str(lab))
 (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
 (lab/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
 run('fm-captain-hold.sh','hold','validation-call','--title','Choose fixture release date','--reason','Release today or tomorrow?')
 run('fm-tasks-axi.sh','show','validation-call')
 (lab/'answer.txt').write_text('Release tomorrow.')
 run('fm-captain-hold.sh','answer','validation-call','--decision-file',str(lab/'answer.txt'))
 run('fm-tasks-axi.sh','show','validation-call')
 (lab/'state/task-a.meta').write_text('task=task-a\nkind=ship\nspawn_gen=validation-one\n')
 (lab/'state/task-a.status').write_text('working: testing export\ndone: fixture complete\n')
 (lab/'data/private-secret.txt').write_text('must remain private')
 dest=root/'.local-validation/export'
 run('fm-record-export.sh','sync');assert not dest.exists()
 (lab/'config/record-export-root').write_text(str(dest)+'\n')
 run('fm-record-export.sh','sync')
 assert (dest/'live/state/task-a.status').read_text()==(lab/'state/task-a.status').read_text()
 assert not (dest/'live/data/private-secret.txt').exists()
 log.write('Exported paths: '+json.dumps(sorted(str(p.relative_to(dest/'live')) for p in (dest/'live').rglob('*') if p.is_file()))+'\n')
 run('fm-record-export.sh','archive-task','task-a')
 manifest=dest/'archive/task-a/validation-one/manifest.v1.json'
 value=json.loads(manifest.read_text());assert value['complete'] is True
 shutil.copyfile(manifest,evidence/'archive-manifest.json')
 before=manifest.read_bytes();run('fm-record-export.sh','archive-task','task-a');assert before==manifest.read_bytes()
 status=lab/'state/task-a.status';status.unlink();status.symlink_to(lab/'data/private-secret.txt')
 run('fm-record-export.sh','sync',expected=1)
 assert (dest/'live/state/task-a.status').read_text()=='working: testing export\ndone: fixture complete\n'
 log.write('Rejected symlink; previous published snapshot retained.\n')
 run('fm-afk-return.sh','guard')
 (lab/'state/.afk').touch();run('fm-afk-return.sh','guard',expected=3);(lab/'state/.afk').unlink()
 (lab/'state/.afk-return-catchup').write_text('fixture pending\n');run('fm-afk-return.sh','guard',expected=4)
 (lab/'state/.afk-return-catchup').unlink();run('fm-afk-return.sh','guard')
 log.write('LIVE CLI SCENARIOS COMPLETE\n')
finally:
 log.close();shutil.rmtree(lab,ignore_errors=True);shutil.rmtree(root/'.local-validation/export',ignore_errors=True)
