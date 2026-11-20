"""Native importer regression tests for a disposable IRIS namespace."""
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
import uuid
from shelf import connect, load_csv


class CsvTests(unittest.TestCase):
    def setUp(self):
        """Create isolated input and table names for each test."""
        temp = TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.file = Path(temp.name, "fixture.csv")
        self.table = "CsvTest" + uuid.uuid4().hex
        self.conn = connect()
        self.addCleanup(self.conn.close)

    def load(self, data, table=None):
        """Send the fixture through the ordinary SDK upload and native importer."""
        self.file.write_bytes(data.encode("utf-8-sig"))
        return load_csv(self.conn, table or self.table, "fixture/source", "fixture.csv", self.file)

    def tearDown(self):
        """Remove objects created by this test only."""
        with closing(self.conn.cursor()) as cur:
            cur.execute(f"DROP TABLE IF EXISTS KaggleShelf.{self.table}")
            cur.execute("SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE UPPER(TABLE_SCHEMA)='KAGGLESHELF' AND UPPER(TABLE_NAME)='IMPORTS'")
            if cur.fetchone()[0]:
                cur.execute("DELETE FROM KaggleShelf.Imports WHERE DestName=?", (self.table.lower(),))

    def test_headers_remain_unique(self):
        """Disambiguate normalized and duplicate headings."""
        count, mapping = self.load("species,,body mass,BODY-MASS,body_mass_2\n")
        self.assertEqual(count, 0)
        self.assertEqual(mapping[0], ["species", "c_species"])
        self.assertEqual(len({column for _, column in mapping}), 5)

    def test_csv_records(self):
        """Preserve quoted line breaks, Unicode, empty fields and logical row ordering."""
        self.load('id,text\r\n001,"甲,乙"\r\n002,"line\r\nbreak"\r\n003,"q""q"\r\n004,')
        with closing(self.conn.cursor()) as cur:
            cur.execute(f"SELECT c_id,c_text FROM KaggleShelf.{self.table} ORDER BY SourceRecord")
            self.assertEqual([tuple(r) for r in cur.fetchall()],
                             [("001", "甲,乙"), ("002", "line\r\nbreak"), ("003", 'q"q'), ("004", "")])

    def test_bad_record_number(self):
        """A malformed first import must leave the name free for a corrected header."""
        with self.assertRaisesRegex(Exception, "CSV record 2"):
            self.load("value\nok\nx,y\n")
        self.assertEqual(self.load("corrected\nok\n")[0], 1)

    def test_quoted_field_crosses_stream_buffers(self):
        """Preserve one quoted field across multiple parser buffers and SDK upload chunks."""
        body = "x" * 8187 + '"\r\n' + "y" * 9000
        csv_text = 'value\r\n"' + body.replace('"', '""') + '"'
        self.assertEqual(self.load(csv_text)[0], 1)
        with closing(self.conn.cursor()) as cur:
            cur.execute(f"SELECT c_value FROM KaggleShelf.{self.table}")
            self.assertEqual(cur.fetchone()[0], body)

    def test_wide_csv(self):
        """Keep fields on both sides of the native SQL binding limit."""
        width = 400
        header = ",".join(f"n{i}" for i in range(width))
        row = ",".join(str(i) for i in range(width))
        self.assertEqual(self.load(header + "\n" + row)[0], 1)
        with closing(self.conn.cursor()) as cur:
            cur.execute(f"SELECT c_n378,c_n379,c_n399 FROM KaggleShelf.{self.table}")
            self.assertEqual(tuple(cur.fetchone()), ("378", "379", "399"))

    def test_destination_is_scoped(self):
        """Reject schema traversal and the registry name before issuing DDL."""
        for name in ("SQLUser.Orders", 'a"b', "Imports", "1a"):
            with self.subTest(name=name), self.assertRaisesRegex(Exception, "Invalid target"):
                self.load("x\n", name)
