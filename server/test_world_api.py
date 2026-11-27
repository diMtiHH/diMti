import contextlib
from datetime import date, timedelta
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from server.world_api import Aggregates, RateLimit, decode, handler


class WorldApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)/'counts.sqlite3'
        self.today = date(2026, 11, 27)
        self.api = Aggregates(self.path, today=lambda:self.today)

    def batch(self, n=10, *, identity='a', day='2026-11-26', language='ru', topic='read_novel'):
        return {'version':1,'batch':identity*32,
                'buckets':[{'topic':topic,'language':language,'day':day,'count':n}]}

    def test_real_counts_filters_and_rounding(self):
        self.api.accept(self.batch(12))
        self.api.accept(self.batch(6, identity='b',language='en'))
        self.api.accept(self.batch(10,identity='c',day='2026-11-20',topic='puzzle'))
        self.assertEqual(self.api.ranking('day','ru')['items'],[{'topic':'read_novel','count':10}])
        self.assertEqual(self.api.ranking('day','en')['items'],[])
        self.assertEqual(self.api.ranking('day','all')['items'],[{'topic':'read_novel','count':15}])
        self.assertEqual(len(self.api.ranking('week','all')['items']),2)
        self.assertEqual(self.api.ranking('month','all')['environment'],'test')

    def test_receipt_makes_ambiguous_retries_idempotent(self):
        self.api.accept(self.batch())
        self.api.accept(self.batch())
        self.assertEqual(self.api.ranking('day','all')['items'][0]['count'],10)
        with self.assertRaises(ValueError): self.api.accept(self.batch(20))

    def test_concurrent_retries_never_double_count(self):
        threads=[threading.Thread(target=lambda:self.api.accept(self.batch())) for _ in range(12)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertEqual(self.api.ranking('day','all')['items'][0]['count'],10)

    def test_current_day_and_rare_counts_not_published(self):
        self.api.accept(self.batch(48,day='2026-11-27'))
        self.api.accept(self.batch(9,identity='b'))
        self.assertEqual(self.api.ranking('day','all')['items'],[])
        self.today+=timedelta(days=1)
        self.assertEqual(self.api.ranking('day','all')['items'][0]['count'],45)

    def test_no_raw_text_name_audio_answer_or_identifier(self):
        for key in ('text','question','name','audio','answer','device_id','user_id'):
            payload=self.batch(); payload[key]='private'
            with self.assertRaises(ValueError): self.api.accept(payload)
            payload=self.batch(); payload['buckets'][0][key]='private'
            with self.assertRaises(ValueError): self.api.accept(payload)
        self.api.accept(self.batch())
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            dump='\n'.join(db.iterdump())
        self.assertNotIn('private',dump)
        self.assertNotIn('user_id',dump)

    def test_unknown_or_dangerous_topics_cannot_be_published(self):
        for topic in ('','suicide','medical','investing','read_novel;DROP TABLE counts'):
            with self.assertRaises(ValueError): self.api.accept(self.batch(topic=topic))
        self.assertEqual(self.api.ranking('month','all')['items'],[])

    def test_strict_limits_types_dates_duplicates(self):
        for count in (True,0,-1,49,1.5,'10'):
            with self.assertRaises(ValueError): self.api.accept(self.batch(count))
        for day in ('2026-11-28','2026-01-01','2026-02-30','20261126'):
            with self.assertRaises(ValueError): self.api.accept(self.batch(day=day))
        value=self.batch(); value['buckets']*=2
        with self.assertRaises(ValueError): self.api.accept(value)
        with self.assertRaises(ValueError): decode(b'{"version":1,"version":1}')
        with self.assertRaises(ValueError): decode(b' '*16385)

    def test_retention(self):
        self.api.accept(self.batch())
        self.today+=timedelta(days=36)
        self.api.accept(self.batch(identity='b',day=self.today.isoformat()))
        with contextlib.closing(sqlite3.connect(self.path)) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM receipts').fetchone()[0],1)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM counts').fetchone()[0],1)

    def test_rate_limit_has_bounded_ephemeral_memory(self):
        rate=RateLimit()
        self.assertTrue(all(rate.allow('127.0.0.1',now=0) for _ in range(120)))
        self.assertFalse(rate.allow('127.0.0.1',now=1))
        self.assertTrue(rate.allow('127.0.0.1',now=3600))
        for n in range(5000): rate.allow(str(n),now=3601)
        self.assertEqual(len(rate.rows),4096)
        self.assertNotIn('127.0.0.1',repr(rate.rows))

    def test_http_boundary_no_echo_no_access_log(self):
        server=ThreadingHTTPServer(('127.0.0.1',0),handler(self.api))
        thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
        url=f'http://127.0.0.1:{server.server_port}'
        try:
            output=io.StringIO()
            with contextlib.redirect_stderr(output):
                request=urllib.request.Request(url+'/v1/counts',json.dumps(self.batch()).encode(),{'Content-Type':'application/json'})
                with urllib.request.urlopen(request) as result: self.assertEqual(json.load(result),{'accepted':True})
                with urllib.request.urlopen(url+'/v1/ranking?period=day&language=all') as result:
                    self.assertEqual(json.load(result)['items'][0]['count'],10)
                request=urllib.request.Request(url+'/v1/counts',b'{"question":"private"}',{'Content-Type':'application/json'})
                with self.assertRaises(urllib.error.HTTPError) as failure: urllib.request.urlopen(request)
                self.assertNotIn(b'private',failure.exception.read())
            self.assertEqual(output.getvalue(),'')
        finally:
            server.shutdown(); thread.join(); server.server_close()


if __name__=='__main__': unittest.main()
