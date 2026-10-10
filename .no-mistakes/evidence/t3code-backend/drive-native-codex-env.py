import json, os, pathlib, selectors, subprocess
root=pathlib.Path.cwd()
fixture=root/'.validation-tmp/native-codex'
fixture.mkdir()
project=fixture/'project'
project.mkdir()
(project/'.codex').mkdir()
original=b'# Project-owned configuration\r\nmodel = "gpt-6-sol"\r\n'
(project/'.codex/config.toml').write_bytes(original)
def git(*args):
    return subprocess.check_output(['git','-C',str(project),*args], text=True)
git('init','-q')
git('add','.codex/config.toml')
git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','Fixture')
subprocess.run(['bash','bin/fm-t3code-codex-env.sh','install',str(project),'FM_TASK_ID=t3-native-config','FM_TASK_INBOX='+str(fixture/'inbox')],check=True)
config_home=fixture/'codex-home'
config_home.mkdir()
(config_home/'config.toml').write_text('[projects.'+json.dumps(str(project))+']\ntrust_level = "trusted"\n')
evidence=pathlib.Path('/home/bryce/.no-mistakes/evidence/01M4KJ3DAC2WMJ6DWY73BKM6PW/native-codex-env.jsonl')
with evidence.open('w') as log, (fixture/'stderr.log').open('w') as errors:
    server=subprocess.Popen(['codex','app-server','--stdio'],cwd=project,env=dict(os.environ,CODEX_HOME=str(config_home)),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,text=True)
    try:
        def request(number, method, params):
            server.stdin.write(json.dumps(dict(id=number,method=method,params=params))+'\n')
            server.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout,selectors.EVENT_READ)
                while selector.select(20):
                    raw=server.stdout.readline()
                    if not raw: raise RuntimeError('Codex closed stdout')
                    response=json.loads(raw)
                    if response.get('id') == number:
                        if 'error' in response: raise RuntimeError(response)
                        return response['result']
            raise TimeoutError(method)
        init=request(1,'initialize',{'clientInfo':{'name':'fm-live-config','version':'1'}})
        log.write(json.dumps({'method':'initialize','result':init})+'\n')
        result=request(2,'config/read',{'cwd':str(project),'includeLayers':True})
        config=result['config']
        assert config['model']=='gpt-6-sol',config
        env=config['shell_environment_policy']['set']
        assert env['FM_TASK_ID']=='t3-native-config',env
        log.write(json.dumps({'method':'config/read','model':config['model'],'environment':env})+'\n')
        result=request(3,'command/exec',{'cwd':str(project),'command':['/usr/bin/printenv','FM_TASK_ID','FM_TASK_INBOX'],'timeoutMs':10000,'sandboxPolicy':{'type':'dangerFullAccess'}})
        log.write(json.dumps({'method':'command/exec','result':result})+'\n')
        assert result=={'exitCode':0,'stdout':'t3-native-config\n'+str(fixture/'inbox')+'\n','stderr':''},result
    finally:
        server.terminate()
        server.wait(timeout=10)
        subprocess.run(['bash',str(root/'bin/fm-t3code-codex-env.sh'),'cleanup',str(project)],check=True)
        assert (project/'.codex/config.toml').read_bytes()==original
        assert not git('status','--porcelain').strip()
        log.write(json.dumps({'cleanup':'original CRLF bytes restored; Git index unchanged'})+'\n')
print(evidence)
