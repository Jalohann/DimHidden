#!/bin/sh
# Checks safety_check.py against changes it must pass and changes it must block. Run from anywhere.
set -eu
SRC=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir "$T/repo"
(cd "$SRC" && git ls-files -z | xargs -0 tar cf - 2>/dev/null) | tar xf - -C "$T/repo"
cp "$SRC/.github/scripts/safety_check.py" "$T/safety_check.py"
cd "$T/repo"
git init -q -b main
git add -A
git -c user.name=t -c user.email=t@t commit -qm base
BASE=$(git rev-parse HEAD)
failures=0

edit() { perl -CSD -pi -e "$1" "$2"; }
case_() { # name expected(pass|fail)
  git add -A
  git -c user.name=t -c user.email=t@t commit -qm "$1" --allow-empty
  if python3 "$T/safety_check.py" "$BASE" HEAD > /dev/null; then got=pass; else got=fail; fi
  if [ "$got" = "$2" ]; then echo "ok    $1"; else echo "FAIL  $1 (expected $2, got $got)"; failures=$((failures + 1)); fi
  git reset -q --hard "$BASE"
  git clean -qfd
}
line='let dotSize: CGFloat = 7'
s() { edit "s/\Q$line\E/$1/" Sources/main.swift; }

s 'let dotSize: CGFloat = 7.5';                                   case_ "geometry tweak" pass
edit 's#<string>1\.1\.0</string>#<string>1.1.1</string>#' Info.plist; case_ "version bump" pass
printf '\n## 1.1.1\n\n- Fix.\n' >> CHANGELOG.md;                   case_ "changelog entry" pass
s 'let dotSize: CGFloat = 7 \/\/ https:\/\/github.com\/Jalohann\/DimHidden\/issues\/3'; case_ "own issue URL" pass
s 'let d = UserDefaults(suiteName: dockBundleID)?.bool(forKey: "autohide")'; case_ "read Dock setting" pass
echo 'import AppKit' > Sources/Extra.swift;                          case_ "new Swift file" pass
s 'let p = Process()';                                             case_ "launch process" fail
s 'let s = "\/\/"; let p = Process()';                             case_ "process after //" fail
s 'let u = "https:\/\/evil.example\/x"';                           case_ "foreign URL" fail
edit 's/^import ServiceManagement$/import ServiceManagement\nimport Network/' Sources/main.swift; case_ "import Network" fail
s 'let k = NSPasteboard.general.string(forType: .string)';        case_ "clipboard" fail
s 'let b = Data(base64Encoded: "aGVsbG8=")';                       case_ "base64" fail
s 'let d = UserDefaults(suiteName: "com.apple.Safari")';           case_ "other app settings" fail
s 'UserDefaults(suiteName: dockBundleID)?.set(true, forKey: "x")'; case_ "write Dock setting" fail
s 'let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { _ in }'; case_ "key monitor" fail
s 'try? FileManager.default.removeItem(atPath: "x")';             case_ "delete file" fail
s "let dotSize: CGFloat = 7 \\/\\/ \x{202E}x";                     case_ "bidi character" fail
s 'let k = "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2"'; case_ "opaque string" fail
edit 's#<key>LSUIElement</key>#<key>LSBackgroundOnly</key>#' Info.plist; case_ "Info.plist key" fail
echo 'echo hi' >> build.sh;                                         case_ "build.sh" fail
echo '# x' >> .github/workflows/ci.yml;                             case_ "workflow" fail
echo '# x' >> .github/scripts/safety_check.py;                      case_ "safety check itself" fail
echo 'x' > tool.sh;                                                 case_ "new script" fail
perl -e 'print "let x = 1\n" x 700' >> Sources/main.swift;          case_ "huge change" fail

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
echo "All safety check cases behave as expected."
