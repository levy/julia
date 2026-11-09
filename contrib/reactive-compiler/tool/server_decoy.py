#!/usr/bin/env python3
"""server_decoy.py <socket> <log>: a decoy of the compiler server. It listens
on <socket> and writes each request line to <log>. It answers `ok decoy` to
`status`, `ok` to `quit` and `error decoy` to any other request. On `quit` it
removes <socket> and exits."""
import os, socket, sys

path, log = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.remove(path)
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(8)
while True:
    client, _ = server.accept()
    data = b""
    while not data.endswith(b"\n"):
        chunk = client.recv(4096)
        if not chunk:
            break
        data += chunk
    request = data.decode().strip()
    with open(log, "a") as out:
        out.write(request + "\n")
    command = request.split(" ", 1)[0]
    reply = {"status": "ok decoy", "quit": "ok"}.get(command, "error decoy")
    client.sendall((reply + "\n").encode())
    client.close()
    if command == "quit":
        break
server.close()
os.remove(path)
