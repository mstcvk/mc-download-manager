"""Real local BitTorrent transfer using the app's Swift engine and an aria2 seeder."""
import hashlib
import http.server
import os
import pathlib
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parents[2]
ARIA2 = shutil.which('aria2c')
assert ARIA2, 'Install aria2 first: brew install aria2'


def bencode(value):
    if isinstance(value, int):
        return b'i' + str(value).encode() + b'e'
    if isinstance(value, bytes):
        return str(len(value)).encode() + b':' + value
    if isinstance(value, list):
        return b'l' + b''.join(map(bencode, value)) + b'e'
    return b'd' + b''.join(bencode(k) + bencode(value[k]) for k in sorted(value)) + b'e'


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='mc-magnet-test-') as temporary:
    work = pathlib.Path(temporary)
    seed = work / 'seed'
    payload = seed / 'sample'
    payload.mkdir(parents=True)
    # Deterministic, newly created data; no public swarm or third-party content.
    data = bytes(range(256)) * 32768
    contents = {'first.bin': data[:4*1024*1024], 'second.bin': data[4*1024*1024:]}
    for name, body in contents.items():
        (payload / name).write_bytes(body)
    piece_size = 65536
    info = {b'name': b'sample', b'piece length': piece_size, b'private': 1,
            b'pieces': b''.join(hashlib.sha1(data[i:i+piece_size]).digest()
                                for i in range(0, len(data), piece_size)),
            b'files': [{b'length': len(body), b'path': [name.encode()]}
                       for name, body in contents.items()]}
    infohash = hashlib.sha1(bencode(info)).hexdigest()
    seed_port = free_port()

    class Tracker(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            peers = socket.inet_aton('127.0.0.1') + struct.pack('!H', seed_port)
            body = bencode({b'interval': 1, b'complete': 1, b'incomplete': 1, b'peers': peers})
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    tracker = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Tracker)
    threading.Thread(target=tracker.serve_forever, daemon=True).start()
    announce = f'http://127.0.0.1:{tracker.server_port}/announce'
    torrent = work / 'sample.torrent'
    torrent.write_bytes(bencode({b'announce': announce.encode(), b'info': info}))
    magnet = f'magnet:?xt=urn:btih:{infohash}&dn=sample&tr={urllib.parse.quote(announce, safe="")}'
    executable = work / 'integration'
    subprocess.run(['swiftc', str(ROOT/'App/Sources/DownloadManager/Models/Models.swift'),
                    str(ROOT/'App/Sources/DownloadManager/Engine/TorrentDownloader.swift'),
                    str(pathlib.Path(__file__).with_name('main.swift')), '-o', str(executable)], check=True)
    store_executable = work / 'torrent-import-integration'
    sources = [ROOT/'App/Sources/DownloadManager/App.swift']
    sources += [p for p in (ROOT/'App/Sources/DownloadManager').glob('*/*.swift')
                if p.name != 'DownloadDetailView.swift']
    subprocess.run(['swiftc', '-swift-version', '5', '-target',
                    subprocess.check_output(['uname', '-m'], text=True).strip() + '-apple-macos13.0',
                    *map(str, sources), str(ROOT/'tests/torrent-import-integration/main.swift'),
                    '-o', str(store_executable)], check=True)
    with (work/'seed.log').open('w') as seed_log:
        seeder = subprocess.Popen([ARIA2, '--no-conf=true', f'--dir={seed}', '--check-integrity=true',
                                   '--seed-time=10', '--seed-ratio=0', '--max-upload-limit=512K',
                                   '--enable-dht=false', '--enable-dht6=false',
                                   '--enable-peer-exchange=false', f'--listen-port={seed_port}',
                                   str(torrent)], stdout=seed_log, stderr=subprocess.STDOUT)
        try:
            result = subprocess.run([str(executable), magnet, str(work/'download')], timeout=190)
            assert result.returncode == 0, f'Swift integration failed: {result.returncode}'
            for name, body in contents.items():
                downloaded = (work/'download'/'sample'/name).read_bytes()
                assert hashlib.sha256(downloaded).digest() == hashlib.sha256(body).digest(), name
            selected = (work/'download'/'selected-only'/'sample'/'second.bin').read_bytes()
            assert hashlib.sha256(selected).digest() == hashlib.sha256(contents['second.bin']).digest()
            assert not (work/'download'/'selected-only'/'sample'/'first.bin').exists()
            print('PASS: all-files pause/resume (8 MiB) and selected-only download (4 MiB); SHA-256 verified')
            imported_source = work / 'import.torrent'
            shutil.copyfile(torrent, imported_source)
            store_root = work / 'store-test'
            isolated_home = work / 'home'
            isolated_home.mkdir()
            env = dict(os.environ, HOME=str(isolated_home), CFFIXED_USER_HOME=str(isolated_home))
            subprocess.run([str(store_executable), str(imported_source), str(store_root)],
                           timeout=190, check=True, env=env)
            destinations = list((store_root/'payload').glob('Torrent-*'))
            assert len(destinations) == 1
            resumed = (destinations[0]/'sample'/'second.bin').read_bytes()
            assert hashlib.sha256(resumed).digest() == hashlib.sha256(contents['second.bin']).digest()
            assert not (destinations[0]/'sample'/'first.bin').exists()
            print('PASS: imported selected-only file resumed after restart; SHA-256 verified')
        finally:
            seeder.terminate()
            seeder.wait(timeout=10)
            tracker.shutdown()
