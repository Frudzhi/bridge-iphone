"""Build the bundled Shtab page from the deployed web application's sources."""
import base64
import json
import mimetypes
import posixpath
import re
import sys
from pathlib import Path

web, output = map(Path, sys.argv[1:])
modules = {}


def data_url(path, content=None, mime=None):
    if content is None:
        content = (web / path).read_bytes()
    mime = mime or mimetypes.guess_type(path)[0] or "application/octet-stream"
    return f"data:{mime};base64," + base64.b64encode(content).decode("ascii")


def module_imports(source, path):
    def replace(match):
        prefix, quote, target = match.groups()
        file = posixpath.normpath(posixpath.join(posixpath.dirname(path), target.lstrip("/"))
                                 if not target.startswith("/") else target[1:])
        file = file.split("?", 1)[0]
        name = "shtab-offline/" + file
        if name not in modules:
            modules[name] = None
            code = module_imports((web / file).read_text(encoding="utf-8"), file)
            modules[name] = data_url(file, code.encode("utf-8"), "text/javascript")
        return prefix + quote + name + quote

    return re.sub(r"""(\bimport\s*\(\s*|\bfrom\s+)(['"])(\.{1,2}/[^'"]+|/[^'"]+)\2""",
                  replace, source)


def inline_script(match):
    path = match[1]
    code = module_imports((web / path).read_text(encoding="utf-8"), path)
    if path == "app.js":
        code = code.replace('api("/api/today")',
                            'api("/api/today", { signal: AbortSignal.timeout?.(8000) })')
        code = code.replace('"/lib/pdf.worker.min.mjs"',
                            json.dumps(data_url("lib/pdf.worker.min.mjs", mime="text/javascript")))
        code = code.replace('if ("serviceWorker" in navigator) navigator.serviceWorker.register',
                            'if (false && "serviceWorker" in navigator) navigator.serviceWorker.register')
    return "<script>\n" + re.sub(r"</script", r"<\\/script", code, flags=re.I) + "\n</script>"


def inline_style(match):
    css = (web / match[1]).read_text(encoding="utf-8")
    css = re.sub(r"""url\(['"]?(/[^)'"]+)['"]?\)""",
                 lambda asset: 'url("' + data_url(asset[1][1:]) + '")', css)
    return "<style>\n" + css + "\n</style>"


html = (web / "index.html").read_text(encoding="utf-8")
html = re.sub(r'<script src="/([^"?]+)(?:\?[^"]*)?"></script>', inline_script, html)
html = re.sub(r'<link rel="stylesheet" href="/([^"?]+)(?:\?[^"]*)?">', inline_style, html)
html = re.sub(r'<link rel="(?:manifest|icon|apple-touch-icon|preload)"[^>]*>\n?', "", html)
main = '<main id="app" aria-live="polite"></main>'
style, skeleton = Path(__file__).with_name("startup-skeleton.html").read_text(encoding="utf-8").split("</style>", 1)
html = html.replace("</head>", style + "</style>\n</head>")
html = html.replace(main, main + skeleton + '\n<script type="importmap">' +
                    json.dumps({"imports": modules}) + "</script>\n")
html = html.replace("</body>", """<script>
window.__shtabSync = () => {
  if (!S.key || document.visibilityState !== 'visible') return;
  void flushTasks();
  void refreshHub();
  if (S.view === 'rr') {
    void rrRefresh();
    if (S.rrTab === 'posts') void rpLoad();
  }
};
setInterval(() => { if (S.offline) window.__shtabSync(); }, 15000);
</script>
</body>""")
font_licenses = "\n\n".join((web / path).read_text(encoding="utf-8") for path in
                            ("fonts/OFL-Manrope.txt", "fonts/OFL-Unbounded.txt"))
html = html.replace("</html>", "<!--\n" + re.sub(r"(?m)[ \t]+$", "", font_licenses) + "\n-->\n</html>")
output.write_text(re.sub(r"(?m)^[ \t]+$", "", html), encoding="utf-8", newline="\n")
