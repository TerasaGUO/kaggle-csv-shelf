"""Verify the official Kaggle member and atomic replacement in a disposable IRIS namespace."""
from collections import Counter
from contextlib import closing
import csv
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import uuid

import kagglehub
from shelf import connect, load_csv


def verify():
    """Run the CLI twice, compare grouped counts with the source CSV and verify rollback in a test table."""
    dataset = "parulpandey/palmer-archipelago-antarctica-penguin-data"
    member = "penguins_size.csv"
    table = "Verify" + uuid.uuid4().hex[:12]
    path = kagglehub.dataset_download(dataset, path=member)
    command = [sys.executable, str(Path(__file__).with_name("shelf.py")), dataset, member, table]
    for _ in range(2):
        subprocess.run(command, check=True)
    with open(path, encoding="utf-8-sig", newline="") as source:
        expected = Counter(row["species"] for row in csv.DictReader(source))
    with closing(connect()) as connection, closing(connection.cursor()) as cursor:
        def groups():
            """Read species counts from IRIS for comparison with the source CSV."""
            # IRIS SQLUPPER folds grouping keys to uppercase. Exact collation preserves the CSV spelling.
            cursor.execute(f"SELECT %EXACT(c_species), COUNT(*) FROM KaggleShelf.{table} GROUP BY %EXACT(c_species)")
            return {row[0]: row[1] for row in cursor.fetchall()}

        if groups() != expected:
            raise AssertionError("IRIS aggregates differ from the source CSV.")
        with TemporaryDirectory() as temp:
            bad = Path(temp, member)
            bad.write_bytes(Path(path).read_bytes() + b'\nwrong,field,count\n')
            try:
                load_csv(connection, table, dataset, member, bad)
            except RuntimeError as error:
                if "CSV record" not in str(error):
                    raise
            else:
                raise AssertionError("Expected malformed CSV to fail.")
        if groups() != expected:
            raise AssertionError("Failed refresh changed the destination.")
        with TemporaryDirectory() as temp:
            # Retry a failed first import with corrected headers and Unicode CSV fields under the same table name.
            sample = Path(temp, "example.csv")
            fresh = table + "Retry"
            sample.write_text("obsolete\n1,2\n", encoding="utf-8")
            try:
                load_csv(connection, fresh, "demo/source", "example.csv", sample)
            except RuntimeError as error:
                if "CSV record 1" not in str(error):
                    raise
            else:
                raise AssertionError("Malformed first import unexpectedly succeeded.")
            sample.write_text('code,label\n001,"甲,乙"\n002,"line\nbreak"\n', encoding="utf-8-sig")
            load_csv(connection, fresh, "demo/source", "example.csv", sample)
            cursor.execute(f"CREATE UNIQUE INDEX EnforceCode ON KaggleShelf.{fresh}(c_code)")
            connection.commit()
            sample.write_text("code,label\n" + "".join(f"{i},test\n" for i in range(100)) + "99,reject\n", encoding="utf-8")
            try:
                load_csv(connection, fresh, "demo/source", "example.csv", sample)
            except RuntimeError as error:
                if "unique" not in str(error).lower() and "-119" not in str(error):
                    raise
            else:
                raise AssertionError("A database constraint should reject record 101.")
            cursor.execute(f"SELECT c_code,c_label FROM KaggleShelf.{fresh} ORDER BY SourceRecord")
            if [tuple(row) for row in cursor.fetchall()] != [("001", "甲,乙"), ("002", "line\nbreak")]:
                raise AssertionError("UTF-8 fields or quoted record boundaries were lost.")
            cursor.execute(f"DROP TABLE KaggleShelf.{fresh}")
            cursor.execute("DELETE FROM KaggleShelf.Imports WHERE DestName=?", (fresh.lower(),))
        cursor.execute(f"DROP TABLE KaggleShelf.{table}")
        cursor.execute("DELETE FROM KaggleShelf.Imports WHERE DestName=?", (table.lower(),))
        connection.commit()
    print(f"PASS: {sum(expected.values())} rows, matching groups {dict(expected)}, failed refresh rolled back.")


if __name__ == "__main__":
    verify()
