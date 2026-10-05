import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile

root = Path.cwd()
with tempfile.TemporaryDirectory(prefix="codex-live-", dir=root / ".local-test-tmp") as scratch:
    lab = Path(scratch)
    project = lab / "project"
    project.mkdir()
    environment = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_SYSTEM="/dev/null")
    def git(*args):
        return subprocess.check_output(["git", "-C", str(project), *args], env=environment, text=True).strip()
    git("init", "-q", "-b", "main")
    config = project / ".codex/config.toml"
    config.parent.mkdir()
    original = b'model = "gpt-5.6-sol"\n'
    config.write_bytes(original)
    git("add", ".codex/config.toml")
    git("-c", "user.name=Live Validation", "-c", "user.email=validation@example.invalid", "commit", "-qm", "Fixture project configuration")
    overlay = root / "bin/fm-t3code-codex-env.sh"
    task = "lab-live-codex"
    subprocess.run([str(overlay), "install", str(project), "FM_TASK_ID=" + task, "FM_TASK_INBOX=" + str(lab / "inbox")], check=True, env=environment)
    home = lab / "codex-home"
    home.mkdir()
    (home / "config.toml").write_text(f'[projects.{json.dumps(str(project))}]\ntrust_level = "trusted"\n')
    print(subprocess.check_output(["codex", "--version"], text=True).strip(), flush=True)
    with (lab / "stderr.log").open("w") as errors:
        server = subprocess.Popen(["codex", "app-server", "--stdio"], cwd=project,
            env=dict(environment, CODEX_HOME=str(home)), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            def request(number, method, params):
                server.stdin.write(json.dumps(dict(id=number, method=method, params=params)) + "\n")
                server.stdin.flush()
                with selectors.DefaultSelector() as selector:
                    selector.register(server.stdout, selectors.EVENT_READ)
                    while selector.select(20):
                        response = json.loads(server.stdout.readline())
                        if response.get("id") == number:
                            assert "error" not in response, response
                            return response["result"]
                raise TimeoutError(method)
            request(1, "initialize", {"clientInfo": {"name": "fm-live-validation", "version": "1"}})
            configured = request(2, "config/read", {"cwd": str(project), "includeLayers": True})["config"]
            print(json.dumps({"method": "config/read", "model": configured["model"], "shell_environment_policy": configured["shell_environment_policy"]}), flush=True)
            assert configured["model"] == "gpt-5.6-sol"
            assert configured["shell_environment_policy"]["set"]["FM_TASK_ID"] == task
            command = request(3, "command/exec", {"cwd": str(project), "command": ["/usr/bin/printenv", "FM_TASK_ID", "FM_TASK_INBOX"], "timeoutMs": 10000, "sandboxPolicy": {"type": "dangerFullAccess"}})
            print(json.dumps({"method": "command/exec", "result": command}), flush=True)
            assert command == {"exitCode": 0, "stdout": task + "\n" + str(lab / "inbox") + "\n", "stderr": ""}
        finally:
            server.terminate()
            server.wait(timeout=10)
    subprocess.run([str(overlay), "cleanup", str(project)], check=True, env=environment)
    assert config.read_bytes() == original
    assert git("status", "--porcelain") == ""
    assert git("ls-files", "-v", "--", ".codex/config.toml").startswith("H ")
    print(json.dumps({"cleanup": "original tracked configuration restored", "tracked_config": config.read_text(), "git_status": git("status", "--porcelain"), "git_index_flag": git("ls-files", "-v", "--", ".codex/config.toml")}), flush=True)
