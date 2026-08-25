# A passive getaddrinfo offers AF_INET6 first, so a server binding its first
# result binds the v6 wildcard. Without ENABLE_IPV6 socketmodule can neither
# decode that address nor bind it, and the bind raises "bind(): bad family".
import socket
import sys
import threading

if not socket.has_ipv6:
    print("IPV6_FAIL: socket.has_ipv6 is False")
    sys.exit(1)

# port 0: both interpreters' runs share the host's network namespace, so a
# fixed port collides when they overlap
infos = socket.getaddrinfo(
    None, 0, socket.AF_UNSPEC, socket.SOCK_STREAM, 0, socket.AI_PASSIVE
)
families = [fam for fam, _, _, _, _ in infos]
if socket.AF_INET6 not in families:
    print(f"IPV6_FAIL: no AF_INET6 in passive getaddrinfo -> {families}")
    sys.exit(1)

fam, typ, proto, _, sa = next(i for i in infos if i[0] == socket.AF_INET6)
if not isinstance(sa[0], str):
    print(f"IPV6_FAIL: AF_INET6 address did not decode -> {sa!r}")
    sys.exit(1)

srv = socket.socket(fam, typ, proto)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(sa)
srv.listen(1)
port = srv.getsockname()[1]

# an IPv4 client has to reach the v6 wildcard, or binding it strands every
# caller that resolves to IPv4
echoed = []


def serve():
    conn, _ = srv.accept()
    echoed.append(conn.recv(16))
    conn.sendall(b"pong")
    conn.close()


t = threading.Thread(target=serve, daemon=True)
t.start()

cli = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
cli.settimeout(10)
cli.connect(("127.0.0.1", port))
cli.sendall(b"ping")
reply = cli.recv(16)
cli.close()
t.join(timeout=10)

if echoed != [b"ping"] or reply != b"pong":
    print(f"IPV6_FAIL: round trip over IPv4 gave {echoed!r} / {reply!r}")
    sys.exit(1)
print("IPV6_OK")
