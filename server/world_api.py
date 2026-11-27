"""python -m server.world_api --database world.sqlite3 --port 8080.

Bind to localhost behind HTTPS. Access logs are deliberately disabled here;
reverse-proxy logs must also be disabled before accepting public traffic.
"""
import argparse
from contextlib import contextmanager, closing
from collections import OrderedDict
from datetime import date, datetime, timedelta, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import re
import secrets
import sqlite3
import threading
import time
from urllib.parse import urlsplit, parse_qs

TOPICS = frozenset(('read_novel', 'watch_comedy', 'draw_stars', 'listen_music',
                    'read_mystery', 'write_poem', 'paper_star', 'puzzle'))
PERIODS = {'day': 1, 'week': 7, 'month': 30}
MAX_BYTES = 16384
PUBLICATION_THRESHOLD = 10


def decode(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate')
            result[key] = value
        return result
    if len(raw) > MAX_BYTES:
        raise ValueError('size')
    return json.loads(raw, object_pairs_hook=unique)


class Aggregates:
    def __init__(self, path, *, testing=True, today=None):
        self.path, self.testing = path, testing
        self.today = today or (lambda: datetime.now(timezone.utc).date())
        self.lock = threading.Lock()
        with self.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS counts (
                    day TEXT, topic TEXT, language TEXT, count INTEGER NOT NULL,
                    PRIMARY KEY(day, topic, language));
                CREATE TABLE IF NOT EXISTS receipts (
                    batch TEXT PRIMARY KEY, digest TEXT NOT NULL, day TEXT NOT NULL);
            ''')

    @contextmanager
    def connect(self):
        with closing(sqlite3.connect(self.path, timeout=5)) as db:
            with db:
                yield db

    def accept(self, value):
        if not isinstance(value, dict) or set(value) != {'version', 'batch', 'buckets'}:
            raise ValueError('schema')
        if type(value['version']) is not int or value['version'] != 1:
            raise ValueError('version')
        batch, rows = value['batch'], value['buckets']
        if not isinstance(batch, str) or not re.fullmatch('[0-9a-f]{32}', batch):
            raise ValueError('batch')
        if not isinstance(rows, list) or not 1 <= len(rows) <= 64:
            raise ValueError('buckets')
        today, seen = self.today(), set()
        checked = []
        for row in rows:
            if not isinstance(row, dict) or set(row) != {'topic', 'language', 'day', 'count'}:
                raise ValueError('bucket schema')
            topic, language, day, count = (row[k] for k in ('topic', 'language', 'day', 'count'))
            if not all(isinstance(x, str) for x in (topic, language, day)):
                raise ValueError('types')
            if topic not in TOPICS or language not in ('ru', 'en'):
                raise ValueError('catalog')
            if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', day):
                raise ValueError('day')
            when = date.fromisoformat(day)
            if not today - timedelta(days=30) <= when <= today:
                raise ValueError('retention')
            if type(count) is not int or not 1 <= count <= 48:
                raise ValueError('count')
            key = (day, topic, language)
            if key in seen:
                raise ValueError('duplicate bucket')
            seen.add(key)
            checked.append((*key, count))
        # A receipt identifies one upload only, never an installation or person.
        digest = hashlib.sha256(json.dumps(sorted(checked), separators=(',', ':')).encode()).hexdigest()
        with self.lock, self.connect() as db:
            previous = db.execute('SELECT digest FROM receipts WHERE batch=?', (batch,)).fetchone()
            if previous:
                if previous[0] != digest:
                    raise ValueError('conflicting retry')
                return {'accepted': True}
            db.execute('DELETE FROM counts WHERE day<?', ((today - timedelta(days=30)).isoformat(),))
            db.execute('DELETE FROM receipts WHERE day<?', ((today - timedelta(days=35)).isoformat(),))
            for day, topic, language, count in checked:
                db.execute('''INSERT INTO counts VALUES(?,?,?,?) ON CONFLICT(day,topic,language)
                    DO UPDATE SET count=MIN(1000000000, count+excluded.count)''', (day, topic, language, count))
            db.execute('INSERT INTO receipts VALUES(?,?,?)', (batch, digest, today.isoformat()))
        return {'accepted': True}

    def ranking(self, period, language):
        if period not in PERIODS or language not in ('all', 'ru', 'en'):
            raise ValueError('filter')
        end = self.today()
        start = end - timedelta(days=PERIODS[period])
        with self.lock, self.connect() as db:
            db.execute('DELETE FROM counts WHERE day<?', ((end - timedelta(days=30)).isoformat(),))
            db.execute('DELETE FROM receipts WHERE day<?', ((end - timedelta(days=35)).isoformat(),))
            rows = db.execute('''SELECT topic,SUM(count) FROM counts
                WHERE day>=? AND day<? AND (?='all' OR language=?)
                GROUP BY topic HAVING SUM(count)>=?
                ORDER BY SUM(count) DESC,topic LIMIT 100''',
                (start.isoformat(), end.isoformat(), language, language, PUBLICATION_THRESHOLD)).fetchall()
        return {'version': 1, 'environment': 'test' if self.testing else 'production',
                'period': period, 'language': language, 'through': (end-timedelta(days=1)).isoformat(),
                'threshold': PUBLICATION_THRESHOLD,
                'items': [{'topic': topic, 'count': count//5*5} for topic, count in rows]}


class RateLimit:
    def __init__(self):
        self.salt, self.rows, self.lock = secrets.token_bytes(32), OrderedDict(), threading.Lock()

    def allow(self, address, *, now=None):
        # Salt rotates with process; hashes never go to disk. Bounded one-hour
        # buckets are abuse mitigation, not user counting or strong Sybil defense.
        now = time.monotonic() if now is None else now
        key = hashlib.blake2s(address.encode(), key=self.salt).digest()
        with self.lock:
            since, count = self.rows.pop(key, (now, 0))
            if now-since >= 3600:
                since, count = now, 0
            self.rows[key] = (since, count+1)
            while len(self.rows) > 4096:
                self.rows.popitem(last=False)
            return count < 120


def handler(service):
    rate = RateLimit()
    class Handler(BaseHTTPRequestHandler):
        server_version = 'UniverseCounts/1'
        sys_version = ''
        def log_message(self, *_):
            pass
        def setup(self):
            super().setup()
            self.connection.settimeout(5)
        def reply(self, status, value):
            data = json.dumps(value, separators=(',', ':')).encode()
            self.send_response(status)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)
        def do_GET(self):
            try:
                parts = urlsplit(self.path)
                query = parse_qs(parts.query, strict_parsing=True)
                if parts.path != '/v1/ranking' or set(query) != {'period', 'language'} or any(len(v)!=1 for v in query.values()):
                    raise ValueError()
                self.reply(200, service.ranking(query['period'][0], query['language'][0]))
            except (ValueError, TypeError):
                self.reply(400, {'error': 'invalid_request'})
            except sqlite3.Error:
                self.reply(503, {'error': 'unavailable'})
        def do_POST(self):
            if not rate.allow(self.client_address[0]):
                return self.reply(429, {'error': 'rate_limit'})
            try:
                if self.path != '/v1/counts' or self.headers.get('Content-Type') != 'application/json':
                    raise ValueError()
                if self.headers.get('Transfer-Encoding') or len(self.headers.get_all('Content-Length', [])) != 1:
                    raise ValueError()
                size = int(self.headers['Content-Length'])
                if not 0 < size <= MAX_BYTES:
                    raise ValueError()
                raw = self.rfile.read(size)
                if len(raw) != size:
                    raise ValueError()
                self.reply(200, service.accept(decode(raw)))
            except (ValueError, TypeError, UnicodeError):
                self.reply(400, {'error': 'invalid_request'})
            except sqlite3.Error:
                self.reply(503, {'error': 'unavailable'})
    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--database', default='world.sqlite3')
    parser.add_argument('--port', type=int, default=8080)
    parser.add_argument('--production', action='store_true')
    args = parser.parse_args()
    service = Aggregates(args.database, testing=not args.production)
    with ThreadingHTTPServer(('127.0.0.1', args.port), handler(service)) as server:
        print('Counts API listening on localhost. Test data:', service.testing, flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
