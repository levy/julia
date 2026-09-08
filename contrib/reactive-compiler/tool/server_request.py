#!/usr/bin/env python3
"""server_request.py <app_dir> <request...>: one request to the compiler
server of the store of <app_dir> (status, quit, ...); prints the reply."""
import re, socket, sys
session = open(sys.argv[1].rstrip("/") + "/reactive-store/server.toml").read()
path = re.search(r'socket = "([^"]+)"', session).group(1)
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.connect(path)
c.sendall((" ".join(sys.argv[2:]) + "\n").encode())
reply = b""
while True:
    chunk = c.recv(4096)
    if not chunk:
        break
    reply += chunk
c.close()
print(reply.decode().strip())
