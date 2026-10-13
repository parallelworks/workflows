#!/usr/bin/env python3
"""PreToolUse guard for the workflow-reviewer subagent.

Declared in .claude/agents/workflow-reviewer.md: Claude Code runs it before every
Read, Grep, Glob and Bash call of that agent, with the hook input JSON on stdin. Exit 0
lets the call through; exit 2 blocks it and shows the reason on stderr to the agent.

- Read, Grep, Glob: the path must be inside the project (CLAUDE_PROJECT_DIR).
- Bash: every command on the line must be on the read-only allowlist below, with its
  path arguments inside the project, no redirection to a file, no heredoc, no
  background job, no backtick, and `$( )` only around the test runner's --emit.

The guard fails closed: a command it cannot parse, or an error of its own, blocks.
WORKFLOW_REVIEWER_GUARD_LOG=<file> appends one line per decision, to see the hook fire.
"""
import json
import os
import re
import shlex
import sys

ROOT = os.path.realpath(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
RUNNER = "tools/tests/run-workflow-test.py"

GIT = {"diff", "log", "status", "show", "rev-parse", "cat-file", "merge-base", "ls-files", "ls-tree"}
GIT_GLOBAL = {"--no-pager", "-P"}
GIT_GLOBAL_WITH_ARG = {"-C", "-c"}
PW = {("context", "list"), ("cluster", "ls"), ("kube", "ls"), ("workflows", "get"), ("workflows", "ls")}
SIMPLE = {"cat", "head", "tail", "wc", "grep", "cut", "sort", "uniq", "tr", "diff", "ls", "find", "sed",
          "cd", "echo", "printf", "pwd", "true", "test", "[", "basename", "dirname", "realpath", "date",
          "which"}
FIND_FORBIDDEN = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprintf", "-fls", "-fprint0"}
SEPARATORS = {"&&", "||", "|", "|&", ";", "(", ")"}
SUBST = re.compile(r"\$\(([^()]*)\)")


class Blocked(Exception):
    pass


def resolve(path, cwd):
    p = os.path.expanduser(os.path.expandvars(path))
    if not os.path.isabs(p):
        p = os.path.join(cwd, p)
    return os.path.realpath(p)


def inside_root(path, cwd):
    p = resolve(path, cwd)
    return p == ROOT or p.startswith(ROOT + os.sep)


def check_paths(args, cwd):
    for a in args:
        if a.startswith("-") or a == "/dev/null":
            continue
        if os.path.exists(resolve(a, cwd)) and not inside_root(a, cwd):
            raise Blocked("path outside the repository: %s" % a)


def check_segment(tokens, cwd):
    while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
        tokens = tokens[1:]
    if not tokens:
        return
    prog, args = os.path.basename(tokens[0]), tokens[1:]
    check_paths(args, cwd)
    if prog == "git":
        rest = list(args)
        while rest and (rest[0] in GIT_GLOBAL or rest[0] in GIT_GLOBAL_WITH_ARG):
            rest = rest[2:] if rest[0] in GIT_GLOBAL_WITH_ARG else rest[1:]
        if not rest or rest[0] not in GIT:
            raise Blocked("git subcommand not allowed: %s" % " ".join(tokens[:3]))
        if any(a.startswith("--output") for a in rest):
            raise Blocked("git --output writes a file")
        return
    if prog == "pw":
        if tuple(args[:2]) in PW or (tuple(args[:2]) == ("workflows", "run") and "--dry-run" in args):
            return
        raise Blocked("pw command not allowed: %s" % " ".join(tokens[:4]))
    if prog in ("python3", "python"):
        if args and args[0].endswith(RUNNER) and "--emit" in args:
            return
        raise Blocked("python is allowed only as: python3 %s --emit <test.json>" % RUNNER)
    if prog == "cd":
        if not args or args[0] == "-":
            raise Blocked("cd needs a directory inside the repository")
        return
    if prog in SIMPLE:
        if prog == "find" and any(a in FIND_FORBIDDEN for a in args):
            raise Blocked("find may not execute or write")
        if prog == "sed" and any(a.startswith("-i") or a.startswith("--in-place") for a in args):
            raise Blocked("sed -i edits files")
        if prog == "sort" and any(a == "-o" or a.startswith("--output") for a in args):
            raise Blocked("sort -o writes a file")
        return
    raise Blocked("command not on the reviewer's allowlist: %s" % prog)


def tokenize(line):
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError as e:
        raise Blocked("could not parse the command (%s)" % e)


def check_line(line, cwd):
    tokens = tokenize(line)
    segment, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        if t in SEPARATORS:
            check_segment(segment, cwd)
            segment = []
        elif t == "&":
            raise Blocked("background jobs are not allowed")
        elif t.startswith("<<") and t != "<<<":
            raise Blocked("heredocs are not allowed")
        elif ">" in t:
            nxt = tokens[i + 1] if i + 1 < len(tokens) else ""
            if t == ">&" and nxt.isdigit():
                i += 1
            elif t in (">", ">>", ">|", "&>", "&>>") and nxt == "/dev/null":
                i += 1
            else:
                raise Blocked("redirection to a file is not allowed (%s %s)" % (t, nxt))
        else:
            segment.append(t)
        i += 1
    check_segment(segment, cwd)


def check_command(cmd, cwd):
    if "`" in cmd:
        raise Blocked("backticks are not allowed")

    def emit_only(m):
        inner = m.group(1).split()
        if not (inner and inner[0] in ("python3", "python") and "--emit" in inner):
            raise Blocked("$( ) is allowed only around: python3 %s --emit <test.json>" % RUNNER)
        check_line(m.group(1), cwd)
        return "__EMIT__"

    cmd = SUBST.sub(emit_only, cmd)
    if "$(" in cmd:
        raise Blocked("nested command substitution is not allowed")
    for line in cmd.replace("\\\n", " ").split("\n"):
        if line.strip():
            check_line(line, cwd)


def check_file_tool(tool, inp, cwd):
    path = inp.get("file_path") if tool == "Read" else inp.get("path")
    if path and not inside_root(path, cwd):
        raise Blocked("%s outside the repository: %s" % (tool, path))


def log(decision, tool, summary):
    path = os.environ.get("WORKFLOW_REVIEWER_GUARD_LOG")
    if path:
        with open(path, "a") as f:
            f.write("%s %s %s\n" % (decision, tool, (summary or "").replace("\n", " ")[:300]))


def main():
    data = json.load(sys.stdin)
    tool = data.get("tool_name", "")
    inp = data.get("tool_input") or {}
    cwd = data.get("cwd") or os.getcwd()
    summary = inp.get("command") if tool == "Bash" else (inp.get("file_path") or inp.get("path") or "")
    try:
        if tool == "Bash":
            check_command(inp.get("command") or "", cwd)
        elif tool in ("Read", "Grep", "Glob"):
            check_file_tool(tool, inp, cwd)
    except Blocked as e:
        log("block", tool, "%s -- %s" % (summary, e))
        sys.stderr.write("workflow-reviewer guard: %s\n" % e)
        return 2
    except Exception as e:
        log("block", tool, "%s -- guard error %s" % (summary, e))
        sys.stderr.write("workflow-reviewer guard: internal error, call blocked (%s)\n" % e)
        return 2
    log("allow", tool, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
