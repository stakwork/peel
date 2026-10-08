"""Helpers for scripts/test-stack.sh, local tests only.

  python3 test-stack-helpers.py tap <port> <broker port> <file>
      A TCP proxy in front of the broker that appends every byte it carries,
      both ways, to <file>: what a client puts on the wire, for tests to
      search for plain text.
  python3 test-stack-helpers.py memes <port> <data dir>
      A stand-in for the memes server (stakwork/sphinx-meme) with the
      endpoints the official apps use: GET /ask, POST /verify (checks the
      Lightning signed-message signature against the given pubkey), POST
      /file (multipart, bearer), GET /file/<media token> (bearer, host and
      expiry checked), GET /media/<muid>. Uploads are kept in <data dir>/files
      as they arrived. Never logs tokens or keys.
"""
import asyncio, base64, hashlib, json, os, secrets, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs


def tap(port, broker_port, path):
    out = open(path, "ab", buffering=0)

    async def pipe(reader, writer):
        try:
            while data := await reader.read(65536):
                out.write(data)
                writer.write(data)
                await writer.drain()
        except (ConnectionError, asyncio.CancelledError):
            pass
        finally:
            writer.close()

    async def handle(client_reader, client_writer):
        try:
            broker_reader, broker_writer = await asyncio.open_connection("127.0.0.1", broker_port)
        except OSError:
            client_writer.close()
            return
        await asyncio.gather(pipe(client_reader, broker_writer), pipe(broker_reader, client_writer))

    async def main():
        server = await asyncio.start_server(handle, "127.0.0.1", port)
        async with server:
            await server.serve_forever()

    asyncio.run(main())


def memes(port, data_dir):
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import Prehashed, encode_dss_signature

    host = f"127.0.0.1:{port}"
    files = os.path.join(data_dir, "files")
    os.makedirs(files, exist_ok=True)
    challenges, tokens = {}, {}

    def b64url_decode(s):
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

    def verify_sig(msg, sig, pubkey_hex):
        digest = hashlib.sha256(hashlib.sha256(b"Lightning Signed Message:" + msg).digest()).digest()
        r, s = int.from_bytes(sig[1:33], "big"), int.from_bytes(sig[33:65], "big")
        key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256K1(), bytes.fromhex(pubkey_hex))
        key.verify(encode_dss_signature(r, s), digest, ec.ECDSA(Prehashed(hashes.SHA256())))

    def stored(muid):
        return os.path.join(files, hashlib.sha256(muid.encode()).hexdigest())

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body=b"", headers=None):
            self.send_response(status)
            for k, v in (headers or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def json(self, obj, status=200):
            self.reply(status, json.dumps(obj).encode(), {"Content-Type": "application/json"})

        def bearer(self):
            auth = self.headers.get("Authorization", "")
            return tokens.get(auth[7:]) if auth.startswith("Bearer ") else None

        def do_GET(self):
            url = urlparse(self.path)
            if url.path == "/ask":
                cid = secrets.token_hex(8)
                challenges[cid] = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()
                return self.json({"id": cid, "challenge": challenges[cid]})
            if url.path.startswith("/file/"):
                if not self.bearer():
                    return self.json({"error": "unauthorized"}, 401)
                parts = url.path[len("/file/"):].split(".")
                try:
                    token_host = b64url_decode(parts[0]).decode()
                    expiry = int.from_bytes(b64url_decode(parts[3]), "big")
                    muid = parts[1]
                except Exception:
                    return self.json({"error": "bad token"}, 400)
                if token_host != host or expiry < time.time():
                    return self.json({"error": "token host or expiry"}, 403)
                path = stored(muid)
                if not os.path.exists(path):
                    return self.json({"error": "not found"}, 404)
                meta = json.load(open(path + ".json"))
                return self.reply(200, open(path, "rb").read(), {
                    "Content-Type": meta["mime"],
                    "Content-Disposition": f"attachment; filename={meta['filename']}",
                })
            if url.path.startswith("/media/"):
                path = stored(url.path[len("/media/"):])
                if not self.bearer() or not os.path.exists(path):
                    return self.json({"error": "no"}, 404)
                return self.json(json.load(open(path + ".json")))
            self.json({"error": "not found"}, 404)

        def do_POST(self):
            url = urlparse(self.path)
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            if url.path == "/verify":
                q = parse_qs(url.query, keep_blank_values=True)
                cid, sig, pubkey = q.get("id", [""])[0], q.get("sig", [""])[0], q.get("pubkey", [""])[0]
                challenge = challenges.pop(cid, None)
                try:
                    raw = b64url_decode(sig)
                    assert challenge and len(raw) == 65 and len(pubkey) == 66
                    verify_sig(b64url_decode(challenge), raw, pubkey)
                except Exception:
                    return self.json({"error": "bad signature"}, 401)
                claims = json.dumps({"pubkey": pubkey, "exp": int(time.time()) + 3600}).encode()
                payload = base64.urlsafe_b64encode(claims).decode().rstrip("=")
                token = "eyJhbGciOiJub25lIn0." + payload + "." + secrets.token_urlsafe(16)
                tokens[token] = pubkey
                return self.json({"token": token})
            if url.path in ("/file", "/public"):
                pubkey = self.bearer()
                if not pubkey:
                    return self.json({"error": "unauthorized"}, 401)
                boundary = self.headers.get("Content-Type", "").split("boundary=")[-1].encode()
                fields, filename, mime, data = {}, None, None, None
                for part in body.split(b"--" + boundary):
                    if b"\r\n\r\n" not in part:
                        continue
                    head, content = part.split(b"\r\n\r\n", 1)
                    content = content[:-2] if content.endswith(b"\r\n") else content
                    head = head.decode()
                    name = head.split('name="')[1].split('"')[0]
                    if 'filename="' in head:
                        filename = head.split('filename="')[1].split('"')[0]
                        mime = head.split("Content-Type: ")[1].strip() if "Content-Type: " in head \
                            else "application/octet-stream"
                        data = content
                    else:
                        fields[name] = content.decode()
                if data is None:
                    return self.json({"error": "no file"}, 400)
                muid = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode()
                path = stored(muid)
                open(path, "wb").write(data)
                meta = {"muid": muid, "owner_pub_key": pubkey, "name": fields.get("name"), "filename": filename,
                        "size": len(data), "mime": mime}
                json.dump(meta, open(path + ".json", "w"))
                return self.json(meta)
            self.json({"error": "not found"}, 404)

    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    command, port = sys.argv[1], int(sys.argv[2])
    if command == "tap":
        tap(port, int(sys.argv[3]), sys.argv[4])
    elif command == "memes":
        memes(port, sys.argv[3])
    else:
        sys.exit(f"unknown command {command}")
