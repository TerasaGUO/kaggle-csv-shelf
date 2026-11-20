"""Transfer one Kaggle CSV to the native KaggleShelf importer in IRIS."""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path, PurePosixPath
import sys

import iris
import iris.dbapi
import kagglehub


def connect():
    """Connect the SDK to the requested IRIS namespace."""
    options = {"sslconfig": os.environ["IRIS_SSL_CONFIG"]} if os.getenv("IRIS_SSL_CONFIG") else {}
    return iris.dbapi.connect(os.environ.get("IRIS_DSN", "localhost:1972/USER"),
                              os.environ["IRIS_USER"], os.environ["IRIS_PASSWORD"], **options)


def load_csv(connection, name, dataset, member, path):
    """Upload UTF-8 text in bounded chunks and invoke the server-side importer."""
    api = iris.createIRIS(connection)
    with closing(api.classMethodObject("KaggleShelf.Importer", "NewUpload")) as upload:
        with Path(path).open(encoding="utf-8-sig", newline="") as source:
            while chunk := source.read(16000):
                if upload.invoke("Write", chunk) != 1:
                    raise IOError("Could not write the IRIS upload stream.")
        result = json.loads(api.classMethodString("KaggleShelf.Importer", "ImportStream",
                                                  dataset, member, name, upload))
    return result["count"], result["columns"]


def main():
    """Fetch the selected member with KaggleHub, then report the IRIS result."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", help="owner/dataset or owner/dataset/versions/N")
    parser.add_argument("member", help="CSV path inside the Kaggle dataset")
    parser.add_argument("table")
    args = parser.parse_args()
    path = PurePosixPath(args.member)
    if path.is_absolute() or ".." in path.parts or "\\" in args.member or path.suffix.lower() != ".csv":
        parser.error("Provide a relative .csv member path inside the dataset.")
    local_file = kagglehub.dataset_download(args.dataset, path=args.member)
    with closing(connect()) as connection:
        count, mapping = load_csv(connection, args.table, args.dataset, args.member, local_file)
    print(f"Committed {count} rows to KaggleShelf.{args.table}.")
    print(json.dumps(mapping, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        sys.exit(f"Import failed: {error}")
