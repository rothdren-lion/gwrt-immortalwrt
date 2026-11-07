"""Start an isolated HTTP server inside each final image; never mount real data."""
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in ("server.py", "static/app.js", "static/index.html", "static/style.css")}
SMOKE = r'''
import server,hashlib,json,platform,tempfile,threading,os
from pathlib import Path
from urllib.request import urlopen
with tempfile.TemporaryDirectory() as tmp:
 server.DB_PATH=Path(tmp)/'test.sqlite3'
 server.init_db()
 expected=json.loads(os.environ['GWRT_RELEASE_HASHES'])
 for name,digest in expected.items():
  assert hashlib.sha256((Path('/app')/name).read_bytes()).hexdigest()==digest,name
 class Quiet(server.Handler):
  def log_message(self,*args): pass
 http=server.ThreadingHTTPServer(('127.0.0.1',0),Quiet)
 thread=threading.Thread(target=http.serve_forever,daemon=True);thread.start()
 base='http://127.0.0.1:'+str(http.server_port)
 try:
  with urlopen(base+'/api/healthz',timeout=10) as r: health=json.load(r)
  assert health['version']=='17.17',health
  with urlopen(base+'/updates/agent/manifest.json',timeout=10) as r: manifest=json.load(r)
  assert manifest['artifacts']=={} and manifest['manual']['version']=='1712-r7'
  with urlopen(base+manifest['manual']['url'],timeout=10) as r: apk=r.read()
  assert hashlib.sha256(apk).hexdigest()==manifest['manual']['sha256']
  with urlopen(base+'/app.js?v=17.17',timeout=10) as r: assert hashlib.sha256(r.read()).hexdigest()==expected['static/app.js']
  assert server.validate_command('mesh.pair',{'mac':'02:00:00:00:00:02'})=={'mac':'02:00:00:00:00:02'}
  print(json.dumps({'architecture':platform.machine(),'health':health,'apk_sha256':manifest['manual']['sha256'],'source_hashes_verified':True}))
 finally:
  http.shutdown();http.server_close();thread.join()
'''


def main():
    results = []
    for tag, arch in (("localhost/gwrt-control:17.17-amd64", "amd64"), ("localhost/gwrt-control:17.17", "arm64")):
        args = ["podman", "run", "--rm", "--network=none", "--arch", arch,
                "-e", "GWRT_ADMIN_USER=release-test", "-e", "GWRT_ADMIN_PASSWORD=isolated-test-only",
                "-e", "GWRT_RELEASE_HASHES=" + json.dumps(EXPECTED), tag, "python3", "-c", SMOKE]
        result = subprocess.run(args, text=True, capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError(arch + " image smoke failed: " + result.stderr)
        value = json.loads(result.stdout)
        assert value["architecture"] == {"amd64": "x86_64", "arm64": "aarch64"}[arch], value
        results.append({"arch": arch, "image": tag, "result": value})
        print(arch, "PASS", json.dumps(value))
    output = os.environ.get("GWRT_IMAGE_TEST_OUTPUT")
    if output:
        Path(output).write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
