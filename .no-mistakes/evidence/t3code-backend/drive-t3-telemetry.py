import json, os, pathlib, signal, socket, subprocess, time
root=pathlib.Path.cwd()
base=root/'.validation-tmp/t3-telemetry-lab'
base.mkdir()
with socket.socket() as sock:
    sock.bind(('127.0.0.1',0))
    port=sock.getsockname()[1]
origin=f'http://127.0.0.1:{port}'
with (base/'server.log').open('w') as log:
    server=subprocess.Popen(['t3','serve','--host','127.0.0.1','--port',str(port),'--base-dir',str(base),'--no-browser'],cwd=root,env=dict(os.environ,T3CODE_TELEMETRY_ENABLED='false',T3CODE_HOME=str(base)),stdout=log,stderr=log,start_new_session=True)
    try:
        deadline=time.monotonic()+25
        while time.monotonic()<deadline:
            if server.poll() is not None: raise RuntimeError(f'T3 server exited {server.returncode}')
            try:
                with socket.create_connection(('127.0.0.1',port),timeout=.2): break
            except OSError: time.sleep(.1)
        else: raise TimeoutError('T3 server startup')
        driver='''import {telemetryState} from './bin/fm-t3-mcp.mjs';
const origin=process.argv[1];
const telemetry=telemetryState(origin);
console.log(JSON.stringify({server:'t3 0.0.46-nightly.20261010.2935',origin,telemetry,configured:'T3CODE_TELEMETRY_ENABLED=false',probe:'actual Linux listener /proc environ'}));
if(telemetry!=='off') process.exit(1);
'''
        result=subprocess.run(['node','--input-type=module','-e',driver,origin],text=True,capture_output=True,timeout=15)
        evidence=pathlib.Path('/home/bryce/.no-mistakes/evidence/01M4KJ3DAC2WMJ6DWY73BKM6PW/live-t3-telemetry-off.json')
        evidence.write_text(result.stdout)
        if result.returncode: raise RuntimeError(result.stderr+result.stdout)
        print(result.stdout,end='')
    finally:
        os.killpg(server.pid,signal.SIGTERM)
        try: server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(server.pid,signal.SIGKILL)
            server.wait(timeout=5)
