#!/usr/bin/env python3

# steplog.py
# Step tracking for the install flow, used by -v.
#
# The goal is narrow: when something fails, the terminal alone should be enough to
# tell which step stopped, which URL was requested, what the server answered, and
# what to try next. Every failure therefore goes through fail(), which prints all
# of that in one block.
#
# Without -v only the progress lines that already existed are printed, but a
# failure still reports its step and suggestion -- diagnosing a problem should not
# require turning on -v first.
#
# Relationship to other modules: this module does not import domains (domains
# imports it), so anything that needs a domain value or redaction imports lazily
# inside the function to avoid a circular import.

import sys


# -------------------- Colours --------------------

RED_BOLD = '\033[1;31m'
YELLOW = '\033[33m'
RESET = '\033[0m'

# Trace lines are deliberately blue rather than dim. Grey (\033[2m) is unreadable
# on many dark terminal themes; 256-colour 33 keeps the "de-emphasised" feel while
# staying legible. Plain ANSI blue (34) reads as near-black on several profiles.
TRACE = '\033[38;5;33m'


# -------------------- State --------------------

_verbose = False
_total = 0
_index = 0
_current = ""
_notes = []


def set_verbose(enabled):
    global _verbose
    # 静默优先于啰嗦：`-s -v` 同时给时，-v 不生效。
    # 放在这里而不是调用方，是因为 set_verbose 只有这一个入口，
    # 将来新增的命令也自动遵守同一条规则。
    if enabled:
        import quiet
        if quiet.is_silent():
            enabled = False
    _verbose = bool(enabled)


def is_verbose():
    return _verbose


def reset():
    global _total, _index, _current, _notes
    _total = 0
    _index = 0
    _current = ""
    _notes = []


def plan(steps):
    # steps is the list of step names for this run; only used for the "4/11" counter.
    global _total
    _total = len(steps)


def begin(name):
    # Enter a step: print a heading under -v and remember it for fail().
    global _index, _current
    _index += 1
    _current = name
    if _verbose:
        counter = f"{_index}/{_total}" if _total else str(_index)
        print(f"{TRACE}[{counter}] {name}{RESET}")


def detail(message):
    # Details of one step: only shown under -v.
    if _verbose:
        print(f"{TRACE}      - {message}{RESET}")


def note(message):
    # Saved for a summary at the end.
    _notes.append(message)


def step_label():
    if not _current:
        return ""
    counter = f"{_index}/{_total}" if _total else str(_index)
    return f"step {counter} ({_current})"


def _redact(url):
    from domains import redact_url
    return redact_url(url)


def _emit(label, value):
    head = f"🌊 {label}" if label else "🌊"
    print(f"{RED_BOLD}{head:<12}{value}{RESET}")


def fail(reason, request=None, response=None, hint=None, extra=None):
    # Single exit point for failures: step, request, response, reason, next action.
    print(f"{RED_BOLD}🌊 Error: {reason}{RESET}")

    if request:
        _emit("Request", _redact(request))
    if response:
        _emit("Response", response)
    if extra:
        for line in extra.splitlines() or [extra]:
            _emit("", line)

    label = step_label()
    if label:
        print(f"{YELLOW}🌊 At        {label}{RESET}")

    if hint:
        lines = hint if isinstance(hint, (list, tuple)) else str(hint).splitlines()
        for i, line in enumerate(lines):
            prefix = "🌊 Next      " if i == 0 else "🌊           "
            print(f"{YELLOW}{prefix}{line}{RESET}")

    sys.exit(1)


def trace_domains():
    # Under -v, list the actual value of every data source: mirror address, whether
    # it came from the environment or the built-in default, and whether it carries
    # credentials.
    if not _verbose:
        return

    from domains import ENV_NAME, domain, is_custom, redact_url, _has_userinfo

    print(f"{TRACE}      --- data sources ---{RESET}")
    for kind in ENV_NAME:
        value = domain(kind)
        if not value:
            print(f"{TRACE}      - {kind:<12} not set{RESET}")
            continue
        origin = "env" if is_custom(kind) else "default"
        auth = " (with credentials)" if _has_userinfo(value) else ""
        print(f"{TRACE}      - {kind:<12} {origin:<8} {redact_url(value)}{auth}{RESET}")


# -------------------- Direct execution (self-check) --------------------

if __name__ == "__main__":
    print("🌊 This module is not meant to be run directly.")
    sys.exit(1)
