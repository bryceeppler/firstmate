import os, pathlib, subprocess
for args in [['/usr/bin/ps','-o','comm=','-p',str(os.getpid())],['/usr/bin/ps','--quick-pid',str(os.getpid()),'-o','comm=']]:
    print('Command:', ' '.join(args), flush=True)
    result=subprocess.run(['/usr/bin/timeout','-k','1','3',*args],capture_output=True,text=True)
    print('exit:',result.returncode,'stdout:',repr(result.stdout),'stderr:',repr(result.stderr),flush=True)
for root in [2358904,2487961]:
    seen=set()
    def inspect(pid,depth=0):
        if pid in seen or depth>20:return
        seen.add(pid)
        p=pathlib.Path('/proc')/str(pid)
        try:
            print(' '*depth,pid,(p/'comm').read_text().strip(),next(x for x in (p/'status').read_text().splitlines() if x.startswith('State:')),(p/'wchan').read_text().strip(),flush=True)
            for child in (p/'task'/str(pid)/'children').read_text().split():inspect(int(child),depth+1)
        except FileNotFoundError:pass
    inspect(root)
