#!/usr/bin/env python3
"""Deterministic safety gate for pull requests.

Usage: safety_check.py BASE HEAD

Fails when a change touches files an automated change may not touch, or when an added line uses an API that DimHidden
has no business using. It prints a Markdown report with file names, line numbers, and rule names, never the offending
text itself. It runs from main against a pull request that is only read with git, never executed.
"""
import re
import subprocess
import sys

ALLOWED_PATHS = [
    r"Sources/[A-Za-z0-9_]+\.swift",
    r"Info\.plist",
    r"README\.md",
    r"CHANGELOG\.md",
    r"docs/[A-Za-z0-9_.-]+\.(png|md)",
]
MAX_CHANGED_LINES = 600
ALLOWED_IMPORTS = {"AppKit", "ApplicationServices", "Cocoa", "CoreGraphics", "Foundation", "QuartzCore", "ServiceManagement"}
ALLOWED_URLS = [
    r"https://github\.com/Jalohann/DimHidden(/[A-Za-z0-9_./?=&%-]*)?",
    r"http://www\.apple\.com/DTDs/PropertyList-1\.0\.dtd",
]

# Each rule names what it guards against. A legitimate change that trips one still ships: it just needs a human.
SWIFT_RULES = [
    ("launches processes", r"\bProcess\b|NSTask|posix_spawn|\bsystem\s*\(|\bpopen\b|\bexec[lv]p?e?\s*\(|\bfork\s*\(|NSUserUnixTask"),
    ("loads or calls code dynamically", r"dlopen|dlsym|\.load\s*\(\s*\)|loadAndReturnError|NSClassFromString|NSSelectorFromString|Selector\s*\(\s*\"|objc_msgSend|@_silgen_name|@_cdecl|unsafeBitCast|method_exchangeImplementations|class_replaceMethod"),
    ("uses the network", r"URLSession|URLRequest|NSURLConnection|NSURLSession|CFNetwork|CFStream|CFSocket|NWConnection|NWListener|NWBrowser|\bsocket\s*\(|\bconnect\s*\(|getaddrinfo|WebKit|WKWebView|MultipeerConnectivity|CloudKit"),
    ("scripts other apps", r"NSAppleScript|OSAScript|NSUserAppleScriptTask|AppleEvent|AESend|NSAppleEventDescriptor|ScriptingBridge|SBApplication"),
    ("touches credentials or privileges", r"SecItem|SecKeychain|kSec[A-Z]|Keychain|LAContext|LocalAuthentication|Authorization(Create|ExecuteWithPrivileges)|SMJobBless|SMAppService\s*\.\s*(agent|daemon)|LaunchAgents|LaunchDaemons|setuid|\bsudo\b|tccutil|csrutil|spctl|com\.apple\.quarantine"),
    ("writes, moves, or deletes files", r"removeItem|trashItem|moveItem|replaceItem|copyItem|linkItem|createSymbolicLink|createFile|setAttributes|\bunlink\s*\(|\brmdir\s*\(|\.write\s*\(\s*to|write\s*\(\s*toFile|\bFileHandle\b|\bfopen\s*\(|\bchmod\b|\bchown\b"),
    ("reads files or other apps' settings", r"FileManager|contentsOfFile|contentsOf\s*:|NSHomeDirectory|homeDirectory|\.ssh|UserDefaults\s*\(\s*suiteName\s*:(?!\s*dockBundleID\s*\))|CFPreferencesCopy"),
    ("changes settings", r"UserDefaults\s*\(\s*suiteName[^)]*\)\s*\??\s*\.\s*(set|remove)|CFPreferencesSet|setPersistentDomain|removePersistentDomain|defaults\s+write"),
    ("captures input, screen, or clipboard", r"NSPasteboard|CGEventTap|CGEventPost|CGEvent\s*\(|CGEventCreate|keyDown|keyUp|flagsChanged|addGlobalMonitorForEvents|addLocalMonitorForEvents|IOHID|CGWindowListCreateImage|CGDisplayCreateImage|ScreenCaptureKit|SCStream|SCShareableContent|AVCapture|AVAudio|SFSpeech|NSSpeechRecognizer"),
    ("opens URLs or launches apps", r"NSWorkspace\s*\.\s*shared\s*\.\s*(open|launch)|openApplication|launchApplication|LSOpen"),
    ("quits or inspects other processes", r"forceTerminate|\.terminate\s*\(\s*\)|\bkill\s*\(|SIGKILL|SIGTERM|task_for_pid|mach_vm|ptrace|proc_pid|sysctl"),
    ("talks to other processes", r"NSXPCConnection|\bxpc_|CFMessagePort|NSConnection|DistributedNotificationCenter[^\n]*\.post"),
    ("reads the environment or arguments", r"ProcessInfo\s*\.\s*processInfo\s*\.\s*(environment|arguments)|\bgetenv\b|\bsetenv\b|CommandLine\s*\.\s*arguments"),
    ("hides what the code does", r"base64|fromHex|String\s*\(\s*(bytes|decoding|cString|utf8String)|\[\s*(0x[0-9a-fA-F]{1,2}\s*,\s*){8,}|UnicodeScalar\s*\(|#sourceLocation|@_exported|@_implementationOnly"),
]
HIDDEN_CHARS = re.compile("[\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]")
OPAQUE_STRING = re.compile(r"[A-Za-z0-9+/=_-]{60,}")
URL_LIKE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>)\\]*")
PLIST_VERSION_LINE = re.compile(r"\s*<string>[0-9]+(\.[0-9]+)*</string>\s*")
IMPORT_LINE = re.compile(r"\s*(@[A-Za-z_]+\s+)*import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?([A-Za-z0-9_]+)")
HUNK = re.compile(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def git(*args):
    out = subprocess.run(["git", *args], check=True, capture_output=True).stdout
    return out.decode("utf-8", errors="replace")


def check(base, head):
    merge_base = git("merge-base", base, head).strip()
    diff_args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", merge_base, head]
    problems = []

    for line in git(*diff_args[:-2], "--name-only", merge_base, head).splitlines():
        if not any(re.fullmatch(p, line) for p in ALLOWED_PATHS):
            problems.append(f"`{line!r}`: only a human can change this file")

    path, new_line, changed = None, 0, 0
    for raw in git(*diff_args, "-U0").splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else None
            continue
        if raw.startswith("--- ") or raw.startswith("diff --git") or raw.startswith("index "):
            continue
        m = HUNK.match(raw)
        if m:
            new_line = int(m.group(1))
            continue
        if not raw or raw[0] not in "+-":
            continue
        changed += 1
        added = raw[0] == "+"
        text = raw[1:]
        where = f"`{path}` line {new_line}" if added else f"`{path}` (removed line)"
        if path == "Info.plist" and not PLIST_VERSION_LINE.fullmatch(text):
            problems.append(f"{where}: Info.plist changes are limited to version numbers")
        if added:
            if HIDDEN_CHARS.search(text):
                problems.append(f"{where}: invisible or direction-changing characters")
            if path and path.endswith(".swift"):
                code = text
                for name, pattern in SWIFT_RULES:
                    if re.search(pattern, code):
                        problems.append(f"{where}: {name}")
                imp = IMPORT_LINE.match(code)
                if imp and imp.group(2) not in ALLOWED_IMPORTS:
                    problems.append(f"{where}: imports a framework DimHidden doesn't use")
                if OPAQUE_STRING.search(text):
                    problems.append(f"{where}: long opaque string")
                for url in URL_LIKE.findall(text):
                    if not any(re.fullmatch(p, url) for p in ALLOWED_URLS):
                        problems.append(f"{where}: URL outside github.com/Jalohann/DimHidden")
            new_line += 1

    if changed > MAX_CHANGED_LINES:
        problems.append(f"{changed} changed lines: changes over {MAX_CHANGED_LINES} lines need a human")
    return problems


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    problems = check(sys.argv[1], sys.argv[2])
    print("## Safety check\n")
    if not problems:
        print("Passed.")
        return
    print("Failed:\n")
    for p in dict.fromkeys(problems):
        print(f"- {p}")
    sys.exit(1)


if __name__ == "__main__":
    main()
