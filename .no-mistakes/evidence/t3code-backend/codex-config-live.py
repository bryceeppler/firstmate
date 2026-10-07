import json, os, pathlib, selectors, shutil, subprocess, tempfile
root = pathlib.Path.cwd()
lab = pathlib.Path(tempfile.mkdtemp(prefix='codex-config-', dir=root / '.test-phase-tmp'))
server = None
try:
    repo = lab / 'repo'
    repo.mkdir()
    def run(*args):
        return subprocess.check_output(args, cwd=repo, text=True).strip()
    run('git', 'init', '-q')
    run('git', 'config', 'user.name', 'Test Evidence')
    run('git', 'config', 'user.email', 'test@example.invalid')
    config = repo / '.codex' / 'config.toml'
    config.parent.mkdir()
    original = b'model = "gpt-5.6-sol"\n'
    config.write_bytes(original)
    run('git', 'add', '.codex/config.toml')
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Fixture')
    helper = str(root / 'bin/fm-t3code-codex-env.sh')
    run(helper, 'check', str(repo))
    run(helper, 'install', str(repo), 'FM_TASK_ID=live-t3-merge', 'FM_TASK_INBOX=' + str(lab / 'inbox'), 'COMPACT_ADVISER_DISABLE=1')
    home = lab / 'codex-home'
    home.mkdir()
    (home / 'config.toml').write_text('[projects.' + json.dumps(str(repo)) + ']\ntrust_level = "trusted"\n')
    print(run('codex', '--version'))
    with (lab / 'stderr.log').open('w') as errors:
        server = subprocess.Popen(['codex', 'app-server', '--stdio'], cwd=repo, env=dict(os.environ, CODEX_HOME=str(home)), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, text=True)
        def request(number, method, params):
            server.stdin.write(json.dumps(dict(id=number, method=method, params=params)) + '\n')
            server.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(server.stdout, selectors.EVENT_READ)
                while selector.select(20):
                    response = json.loads(server.stdout.readline())
                    if response.get('id') == number:
                        assert 'error' not in response, response
                        return response['result']
            raise TimeoutError(method)
        request(1, 'initialize', {'clientInfo': {'name': 'fm-live-merge', 'version': '1'}})
        result = request(2, 'config/read', {'cwd': str(repo), 'includeLayers': True})
        cfg = result['config']
        assert cfg['model'] == 'gpt-5.6-sol'
        assert cfg['shell_environment_policy']['set']['FM_TASK_ID'] == 'live-t3-merge'
        print(json.dumps({'loaded_model': cfg['model'], 'loaded_task_environment': cfg['shell_environment_policy']['set']}))
        result = request(3, 'command/exec', {'cwd': str(repo), 'command': ['/usr/bin/printenv', 'FM_TASK_ID', 'COMPACT_ADVISER_DISABLE'], 'timeoutMs': 10000, 'sandboxPolicy': {'type': 'dangerFullAccess'}})
        print('Codex command/exec: ' + json.dumps(result))
        assert result == {'exitCode': 0, 'stdout': 'live-t3-merge\n1\n', 'stderr': ''}
        server.terminate()
        server.wait(timeout=10)
        server = None
    assert run('git', 'status', '--porcelain') == ''
    print('Git sees no project changes while the tracked overlay is active.')
    run(helper, 'cleanup', str(repo))
    assert config.read_bytes() == original
    assert run('git', 'status', '--porcelain') == ''
    assert run('git', 'ls-files', '-v', '.codex/config.toml').startswith('H ')
    print('Cleanup restored the original project config bytes and cleared the temporary skip-worktree flag.')
    conflicting = b'model = "gpt-5.6-sol"\n[shell_environment_policy]\ninherit = "all"\n'
    config.write_bytes(conflicting)
    run('git', 'add', '.codex/config.toml')
    run('git', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Existing policy')
    rejected = subprocess.run([helper, 'install', str(repo), 'FM_TASK_ID=must-not-write'], text=True, capture_output=True)
    print('Existing environment policy refusal: ' + rejected.stderr.strip())
    assert rejected.returncode != 0
    assert config.read_bytes() == conflicting
    assert run('git', 'status', '--porcelain') == ''
    print('Existing project policy remained unchanged after refusal.')
finally:
    if server is not None:
        server.terminate()
        server.wait(timeout=10)
    shutil.rmtree(lab)
