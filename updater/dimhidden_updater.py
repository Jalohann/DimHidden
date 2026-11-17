#!/usr/bin/python3
"""Keeps DimHidden current on the maintainer's Mac and reports its errors.

Runs hourly and whenever DimHidden's error log or the crash report folder changes (see install.sh). While online, it:

1. Files a GitHub issue for each new DimHidden error or crash, which starts the fixer automation.
2. Every 12 hours, rebuilds and reinstalls DimHidden if main has a newer version. Main only changes through reviewed
   pull requests (see AGENTS.md), and building locally keeps the signing identity, so the Accessibility permission
   survives the update.

Flags: --dry-run prints what it would do without filing or installing; --update-now skips the 12-hour wait.
"""
import fcntl
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = "Jalohann/DimHidden"
GH_USER = "Jalohann"
GH = "/opt/homebrew/bin/gh"
HOME = Path.home()
SUPPORT = HOME / "Library/Application Support/DimHidden"
SOURCE = SUPPORT / "source"
STATE_FILE = SUPPORT / "updater-state.json"
LOCK_FILE = SUPPORT / "updater.lock"
ERROR_LOG = HOME / "Library/Logs/DimHidden/errors.log"
CRASH_DIRS = [HOME / "Library/Logs/DiagnosticReports", HOME / "Library/Logs/DiagnosticReports/Retired"]
APP = HOME / "Applications/DimHidden.app"
UPDATE_INTERVAL = 12 * 3600
MAX_REPORTS_PER_DAY = 5
DRY_RUN = "--dry-run" in sys.argv
UPDATE_NOW = "--update-now" in sys.argv

os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"


def log(message):
    print(time.strftime("%Y-%m-%dT%H:%M:%S"), message, flush=True)


def run(args, timeout=120, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, **kwargs)


def scrub(text):
    """Removes the home folder and user name from text that goes into a public issue."""
    return text.replace(str(HOME), "~").replace(HOME.name, "<user>")


def version_tuple(version):
    return tuple(int(p) for p in re.findall(r"\d+", version or "0"))


def bundle_version(plist_path):
    try:
        with open(plist_path, "rb") as f:
            return plistlib.load(f).get("CFBundleShortVersionString")
    except (OSError, plistlib.InvalidFileException):
        return None


def notify(title, message):
    if DRY_RUN:
        log(f"would notify: {title}: {message}")
        return
    run(["osascript", "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
         "-e", "end run", title, message])


def online():
    return run(["curl", "-fsSI", "--max-time", "10", "-o", "/dev/null", "https://github.com"]).returncode == 0


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_state(state):
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True))


# MARK: Reporting

def gh(args, token):
    return run([GH, *args], env={**os.environ, "GH_TOKEN": token})


def environment():
    def dock(key):
        r = run(["defaults", "read", "com.apple.dock", key])
        return r.stdout.strip() if r.returncode == 0 else "default"
    macos = run(["sw_vers", "-productVersion"]).stdout.strip()
    return "\n".join([
        f"DimHidden {bundle_version(APP / 'Contents/Info.plist') or 'not installed'}",
        f"macOS {macos}",
        f"Dock: orientation {dock('orientation')}, icon size {dock('tilesize')}, magnification {dock('magnification')} "
        f"({dock('largesize')}), auto-hide {dock('autohide')}",
        f"Appearance: {'Dark' if run(['defaults', 'read', '-g', 'AppleInterfaceStyle']).stdout.strip() == 'Dark' else 'Light'}",
    ])


def signature(*parts):
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:12]


def error_reports():
    try:
        lines = ERROR_LOG.read_text(errors="replace").splitlines()
    except OSError:
        return []
    reports = []
    for line in lines:
        try:
            entry = json.loads(line)
            kind, message, version = entry["kind"], entry["message"], entry.get("version", "?")
        except (ValueError, KeyError, TypeError):
            continue  # a line cut by log rotation
        sig = signature("error", kind, re.sub(r"\d+(\.\d+)?", "#", message), version)
        body = (f"DimHidden logged this error on the maintainer's Mac.\n\n"
                f"- Kind: `{kind}`\n- Message: {scrub(message)}\n- Version: {version}\n- First seen: {entry.get('time', '?')}\n")
        reports.append((sig, f"Auto-report: {kind} in {version}", body))
    return reports


def crash_reports(state):
    seen = set(state.get("seenCrashes", []))
    reports = []
    for folder in CRASH_DIRS:
        for path in sorted(folder.glob("DimHidden*.ips")):
            if path.name in seen:
                continue
            seen.add(path.name)
            try:
                header_text, body_text = path.read_text(errors="replace").split("\n", 1)
                header, body = json.loads(header_text), json.loads(body_text)
            except (OSError, ValueError):
                continue
            if header.get("bundleID") != "com.johann.DimHidden":
                continue
            images = body.get("usedImages", [])
            threads = body.get("threads", [])
            fault = threads[body.get("faultingThread", 0)] if threads else {}
            frames = []
            for frame in fault.get("frames", [])[:15]:
                index = frame.get("imageIndex")
                image = images[index].get("name", "?") if isinstance(index, int) and index < len(images) else "?"
                frames.append(f"{image}: {frame.get('symbol', '+' + str(frame.get('imageOffset', '?')))}")
            exception = body.get("exception", {})
            ours = [f for f in frames if f.startswith("DimHidden:")][:5]
            version = header.get("app_version", "?")
            sig = signature("crash", exception.get("type", "?"), exception.get("signal", "?"), *ours, version)
            asi = scrub(json.dumps(body.get("asi", {}), indent=1))[:1500]
            report = (f"DimHidden crashed on the maintainer's Mac.\n\n"
                      f"- Version: {version}\n- macOS: {header.get('os_version', '?')}\n- Time: {header.get('timestamp', '?')}\n"
                      f"- Exception: {exception.get('type', '?')} {exception.get('signal', '')} {exception.get('subtype', '')}\n"
                      f"- Termination: {scrub(json.dumps(body.get('termination', {})))}\n\n"
                      f"Crashed thread:\n\n```\n{scrub(chr(10).join(frames))}\n```\n\n"
                      f"Application-specific information:\n\n```\n{asi}\n```\n")
            reports.append((sig, f"Auto-report: crash ({exception.get('type', 'unknown')}) in {version}", report))
    state["seenCrashes"] = sorted(seen)[-200:]
    return reports


def file_reports(state, token):
    if not state.get("initialized"):
        # Crashes from before the updater existed came from development builds.
        crash_reports(state)
        state["initialized"] = True
    reports = error_reports() + crash_reports(state)
    filed = state.setdefault("filedSignatures", [])
    times = [t for t in state.get("filedTimes", []) if time.time() - t < 86400]
    for sig, title, body in reports:
        if sig in filed:
            continue
        if len(times) >= MAX_REPORTS_PER_DAY:
            log("daily report limit reached; the rest wait until tomorrow")
            break
        existing = gh(["issue", "list", "-R", REPO, "--state", "all", "--search", f"{sig} in:body",
                       "--json", "number", "--jq", ".[].number"], token)
        if existing.returncode != 0:
            log(f"couldn't search issues: {existing.stderr.strip()}")
            break
        if existing.stdout.strip():
            filed.append(sig)
            continue
        body = f"{body}\n### Environment\n\n```\n{environment()}\n```\n\n<!-- dimhidden-signature: {sig} -->\n"
        if DRY_RUN:
            log(f"would file: {title}\n{body}")
            continue
        created = gh(["issue", "create", "-R", REPO, "--title", title, "--body", body,
                      "--label", "bug", "--label", "auto-report"], token)
        if created.returncode != 0:
            log(f"couldn't file issue: {created.stderr.strip()}")
            break
        log(f"filed {created.stdout.strip()}")
        filed.append(sig)
        times.append(time.time())
    state["filedSignatures"] = filed[-500:]
    state["filedTimes"] = times


# MARK: Updating

def update(state, token):
    if not APP.exists():
        return  # DimHidden was uninstalled; don't bring it back.
    if not UPDATE_NOW and time.time() - state.get("lastUpdateCheck", 0) < UPDATE_INTERVAL:
        return
    if not (SOURCE / ".git").exists():
        r = run(["git", "clone", "--quiet", f"https://github.com/{REPO}.git", str(SOURCE)], timeout=300)
        if r.returncode != 0:
            log(f"clone failed: {r.stderr.strip()}")
            return
    for args in (["fetch", "--quiet", "origin", "main"], ["reset", "--quiet", "--hard", "origin/main"], ["clean", "-qfdx"]):
        r = run(["git", "-C", str(SOURCE), *args], timeout=300)
        if r.returncode != 0:
            log(f"git {args[0]} failed: {r.stderr.strip()}")
            return
    state["lastUpdateCheck"] = time.time()
    available = bundle_version(SOURCE / "Info.plist")
    installed = bundle_version(APP / "Contents/Info.plist")
    commit = run(["git", "-C", str(SOURCE), "rev-parse", "--short", "HEAD"]).stdout.strip()
    if version_tuple(available) <= version_tuple(installed):
        log(f"up to date ({installed}, main at {commit})")
        return
    if DRY_RUN:
        log(f"would update {installed} -> {available} (main at {commit})")
        return
    log(f"updating {installed} -> {available} (main at {commit})")
    build = run([str(SOURCE / "build.sh")], cwd=str(SOURCE), timeout=900)
    if build.returncode != 0:
        log(f"build failed:\n{build.stdout}\n{build.stderr}")
        notify("DimHidden update failed", f"Couldn't build {available}. See ~/Library/Logs/DimHidden-updater.log.")
        if token:
            sig = signature("build", available or "?")
            body = (f"The updater couldn't build {available} (main at {commit}) on the maintainer's Mac.\n\n"
                    f"```\n{scrub((build.stdout + build.stderr)[-3000:])}\n```\n")
            state.setdefault("pendingBuildFailures", {})[sig] = [f"Auto-report: {available} failed to build", body]
        return
    was_running = run(["pgrep", "-x", "DimHidden"]).returncode == 0
    if was_running:
        run(["killall", "-TERM", "DimHidden"])
        time.sleep(1)
        run(["open", "-g", str(APP)])
    notify("DimHidden updated", f"Now running version {available}.")
    log(f"installed {available}")


def file_build_failures(state, token):
    pending = state.get("pendingBuildFailures", {})
    for sig, (title, body) in list(pending.items()):
        existing = gh(["issue", "list", "-R", REPO, "--state", "all", "--search", f"{sig} in:body",
                       "--json", "number", "--jq", ".[].number"], token)
        if existing.returncode == 0 and not existing.stdout.strip():
            body = f"{body}\n<!-- dimhidden-signature: {sig} -->\n"
            if gh(["issue", "create", "-R", REPO, "--title", title, "--body", body,
                   "--label", "bug", "--label", "auto-report"], token).returncode != 0:
                continue
        if existing.returncode == 0:
            del pending[sig]


def main():
    SUPPORT.mkdir(parents=True, exist_ok=True)
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return  # another run is in progress
    if not online():
        log("offline; trying again later")
        return
    state = load_state()
    r = run([GH, "auth", "token", "--user", GH_USER])
    token = r.stdout.strip() if r.returncode == 0 else None
    if not token:
        log(f"no GitHub token for {GH_USER}; not filing reports")
    try:
        if token:
            file_reports(state, token)
        update(state, token)
        if token and not DRY_RUN:
            file_build_failures(state, token)
    finally:
        if not DRY_RUN:
            save_state(state)


if __name__ == "__main__":
    main()
