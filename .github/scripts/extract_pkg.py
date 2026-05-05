import sys, zipfile, re

apk = sys.argv[1] if len(sys.argv) > 1 else "input.apk"
try:
    with zipfile.ZipFile(apk) as z:
        data = z.read("AndroidManifest.xml")
    chunks = data.split(b'\x00')
    for c in chunks:
        if 5 < len(c) < 100 and all(32 <= b < 127 for b in c):
            w = c.decode('latin-1')
            if re.match(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*){2,}$', w) \
               and not w.startswith('android.') \
               and not w.startswith('com.android.'):
                print(w)
                sys.exit(0)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
