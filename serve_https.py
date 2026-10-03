import http.server
import ssl
from urllib.parse import urlsplit

from serve import Handler


class HTTPSHandler(Handler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/document" or path.startswith("/document/"):
            self.send_response(302)
            self.send_header("Location", "/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        super().do_GET()

    def log_message(self, format, *args):
        print("%s - %s" % (self.client_address[0], format % args), flush=True)


if __name__ == "__main__":
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(
        certfile="/etc/ps5-host/cert.pem",
        keyfile="/etc/ps5-host/key.pem",
    )
    with http.server.ThreadingHTTPServer(("0.0.0.0", 443), HTTPSHandler) as server:
        server.socket = context.wrap_socket(server.socket, server_side=True)
        print("Serving HTTPS on port 443", flush=True)
        server.serve_forever()
