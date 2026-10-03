import http.server
import ipaddress
import os
import re
import subprocess
from pathlib import Path

PORT = int(os.environ.get("PS5_HTTP_PORT", "8000"))
ROOT = Path(__file__).resolve().parent

class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, *args):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

def local_ip():
    try:
        output = subprocess.check_output(
            ["ipconfig"] if os.name == "nt" else ["hostname", "-I"],
            text=True,
            encoding="utf-8",
            errors="ignore",
        )
    except (OSError, subprocess.SubprocessError):
        return "localhost"

    candidates = (re.findall(r"IPv4[^:]*:\s*([\d.]+)", output)
                  if os.name == "nt" else output.split())
    for candidate in candidates:
        try:
            address = ipaddress.ip_address(candidate)
        except ValueError:
            continue
        if address.version == 4 and not address.is_loopback and not address.is_link_local:
            return str(address)

    return "localhost"

if __name__ == "__main__":
    with http.server.ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as server:
        print(f"http://{local_ip()}:{PORT}/")
        server.serve_forever()
