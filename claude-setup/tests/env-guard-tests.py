#!/usr/bin/env python3
"""Unit tests for ~/.claude/hooks/env-guard.js (PreToolUse Bash|PowerShell).
Self-contained: creates dummy .env files in a temp dir, feeds hook-input JSON via stdin,
asserts deny/allow. Run: python claude-setup/tests/env-guard-tests.py [path/to/env-guard.js]
Dummy values only — nothing here is a secret.
"""
import json, os, subprocess, sys, tempfile

HOOK = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/.claude/hooks/env-guard.js")
X = ".en" + "v"  # built at runtime so the test file itself carries no .env token for the hook
tmp = tempfile.mkdtemp(prefix="envguard_")
E = os.path.join(tmp, "inproj" + X).replace("\\", "/")
D = os.path.join(tmp, X).replace("\\", "/")
for p in (E, D):
    with open(p, "w") as fh:
        fh.write("API_KEY=dummyvalue123\nEMPTY=\n")
cwd = tmp.replace("\\", "/")
HELPER = "bash ~/.claude/hooks/env-keys.sh"

cases = [
    # (expected, name, command, tool)
    ("DENY", "cat", "cat %s" % E, "Bash"),
    ("DENY", "python open", "python -c \"print(open('%s').read())\"" % E, "Bash"),
    ("DENY", "source", "source %s && echo $API_KEY" % E, "Bash"),
    ("allow", "helper", "%s %s" % (HELPER, E), "Bash"),
    ("allow", "helper --cmp", "%s %s --cmp API_KEY EMPTY" % (HELPER, E), "Bash"),
    ("allow", "cd then helper", "cd %s && %s inproj%s" % (cwd, HELPER, X), "Bash"),
    ("allow", "cp+ls", "cp %s %s/x%s && ls %s" % (E, cwd, X, cwd), "Bash"),
    ("allow", "cp to dir", "cp %s %s/" % (E, cwd), "Bash"),
    ("DENY", "cp to txt", "cp %s %s/out.txt" % (E, cwd), "Bash"),
    ("DENY", "cp to stdout", "cp %s /dev/stdout" % E, "Bash"),
    ("allow", "mv env to env", "mv %s %s/renamed%s" % (E, cwd, X), "Bash"),
    ("allow", "grep process.env (no file)", "grep -rn process.env src/", "Bash"),
    ("allow", ".envrc not matched", "cat .envrc", "Bash"),
    ("allow", "absent file", "cat ~/nonexistent%s" % X, "Bash"),
    ("DENY", "find glob exec cat", "find . -name '*%s' -exec cat {} \\;" % X, "Bash"),
    ("DENY", "var indirection", "F=%s; cat $F" % E, "Bash"),
    ("DENY", "echo subshell cat", "echo $(cat %s)" % E, "Bash"),
    ("DENY", "redirect <", "cat < %s" % E, "Bash"),
    ("DENY", "bash -c", "bash -c 'cat %s'" % E, "Bash"),
    ("DENY", "node -e", "node -e \"console.log(require('fs').readFileSync('%s','utf8'))\"" % D, "Bash"),
    ("DENY", "while read", "while read l; do echo $l; done < %s" % D, "Bash"),
    ("DENY", "php -r", "php -r 'echo file_get_contents(\"%s\");'" % D, "Bash"),
    ("DENY", "sed -n", "sed -n 1p %s" % E, "Bash"),
    ("allow", "wc -c", "wc -c %s" % E, "Bash"),
    ("allow", "test -f (alone)", "test -f %s" % E, "Bash"),
    ("allow", "test -f && echo (echo w/o redirect is harmless)", "test -f %s && echo yes" % E, "Bash"),
    ("allow", "git add", "git add %s" % D, "Bash"),
    ("allow", "git status", "git status %s" % D, "Bash"),
    ("DENY", "git show rev:path", "git show HEAD:inproj%s" % X, "Bash"),
    ("DENY", "git diff", "git diff %s" % E, "Bash"),
    ("DENY", "git log -p", "git log -p -- %s" % E, "Bash"),
    ("DENY", "svn cat", "svn cat %s" % E, "Bash"),
    ("DENY", "xargs cat", "ls %s | xargs cat" % E, "Bash"),
    ("DENY", "eval", "eval \"cat %s\"" % E, "Bash"),
    ("DENY", "diff two env", "diff %s %s" % (E, D), "Bash"),
    ("DENY", "cd then cat relative", "cd %s && cat inproj%s" % (cwd, X), "Bash"),
    ("DENY", "posix tmp path", "cat /tmp/whatever%s" % X, "Bash"),
    ("DENY", "heredoc with glob literal", "python - <<'Y'\nprint('*%s')\nY" % X, "Bash"),
    ("allow", "echo append", "echo 'NEWKEY=' >> %s" % E, "Bash"),
    ("allow", "printf create", "printf 'K=\\n' > %s/new%s" % (cwd, X), "Bash"),
    ("DENY", "echo subshell into env", "echo $(cat %s) >> %s" % (E, E), "Bash"),
    ("DENY", "source then echo into env", "source %s; echo $API_KEY >> %s" % (E, E), "Bash"),
    ("DENY", "PS gc", "gc %s" % E, "PowerShell"),
    ("DENY", "PS Get-Content -Path", "Get-Content -Path %s" % E, "PowerShell"),
    ("allow", "PS Test-Path", "Test-Path %s" % E, "PowerShell"),
    ("allow", "Edit tool ignored", "", "Edit"),
]
if os.name == "nt":
    drive = os.path.splitdrive(E)[0][0].lower()
    posix = "/" + drive + E[2:]
    cases.append(("DENY", "posix drive path", "cat %s" % posix, "Bash"))

fail = 0
for exp, name, cmd, tool in cases:
    inp = json.dumps({"tool_name": tool, "cwd": cwd, "tool_input": {"command": cmd} if tool != "Edit" else {"file_path": E}})
    r = subprocess.run(["node", HOOK], input=inp, capture_output=True, text=True)
    got = "DENY" if '"deny"' in r.stdout else "allow"
    ok = got == exp
    if not ok:
        fail += 1
    print(("ok " if ok else "XX ") + got + " : " + name)
print("FAILURES:", fail, "of", len(cases))
sys.exit(1 if fail else 0)
