# Kaggle CSV Shelf

English · [简体中文](README.zh-CN.md)

Import one named CSV from a public Kaggle dataset into its own InterSystems IRIS SQL table. Analysts can filter and group the columns directly. The CLI prints the original header and generated SQL name for every column.

## Run from the IRIS terminal

[Importer](src/KaggleShelf.Importer.cls) and [CsvReader](src/KaggleShelf.CsvReader.cls) implement CSV parsing, column mapping, source registration, table creation and atomic replacement in ObjectScript. KaggleHub downloads the selected member.

1. Copy or mount the project at a location readable by IRIS (such as `/app`). Compile the classes in the application namespace. The importer needs permission to create and update tables in `KaggleShelf`.

```objectscript
set sc=$system.OBJ.LoadDir("/app/src","ck",,1)
do $system.Status.DisplayError(sc)
```

2. For direct Kaggle downloads, install the SDK where IRIS Embedded Python can import it. The following command runs inside the official Linux IRIS 2026.2 container as a user with write access to the target. Adjust the Python directory on other installations. KaggleHub requires Python 3.11+.

```sh
python3 -m pip install --target /usr/irissys/mgr/python kagglehub==1.0.3
```

3. Run the import in the IRIS terminal. The JSON result contains the row count and column mapping. On IRIS 2026.2 this example imported 344 rows.

```objectscript
write ##class(KaggleShelf.Importer).Import("parulpandey/palmer-archipelago-antarctica-penguin-data","penguins_size.csv","Penguins")
```

For a UTF-8 CSV already on the IRIS host, the ObjectScript file entry point runs without KaggleHub. Supply an authorized, readable server-side path.

```objectscript
write ##class(KaggleShelf.Importer).ImportFile("example/source","sample.csv","Sample","/data/sample.csv")
```

## Run from the shell

The existing CLI downloads via KaggleHub and streams the member into IRIS through the official driver. The server parses the CSV and executes the transaction. With this option, only the client needs Python 3.11+ and the dependencies. Configure `IRIS_SSL_CONFIG` for remote database TLS. Supply any required Kaggle credentials on the side performing the download. The CLI account needs permission to invoke the importer through the IRIS Native API in the application namespace.

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
export IRIS_DSN='localhost:1972/USER'
export IRIS_USER='your-import-user'
# Set IRIS_PASSWORD in your shell or secret manager.
python shelf.py parulpandey/palmer-archipelago-antarctica-penguin-data penguins_size.csv Penguins
```

The example dataset has multiple files. This command downloads the selected member and creates `KaggleShelf.Penguins`. When a reproducible source release is needed, supply an explicit Kaggle handle such as `owner/dataset/versions/1` on the first import. A target stays bound to the handle, member and original headers selected on creation.

```sql
SELECT %EXACT(c_species) AS Species, COUNT(*) AS Birds
FROM KaggleShelf.Penguins
GROUP BY %EXACT(c_species)
ORDER BY Species
```

The tested public file contains 344 rows: 152 Adelie, 68 Chinstrap and 124 Gentoo. IRIS's `%EXACT` retains the source spelling when grouping.

## How it works

CSV records are numbered from 1 after the header. The parser handles UTF-8 (including BOM), quoted commas, quoted line breaks and doubled quotes. Each source field becomes a text column, preserving textual numbers and leading zeroes. The database uses its normal string and collation semantics. Generated column names use the `c_` prefix and disambiguate punctuation, empty names and duplicate headings. The limit is 32,000 characters per field.

The importer first validates the local CSV in a streaming pass. A malformed first file leaves the name available for a corrected file. Once the CSV is valid, a small registry binds the target before creating its SQL table, so an interrupted setup can resume with the same source. A second pass replaces the destination rows in one transaction. A failed insert rolls back the replacement. If a successfully bound source changes its column headings, choose a new table. Existing tables without a matching application registry entry are protected.

## Verify

```sh
python -m unittest -v
python verify_live.py
```

Use a disposable IRIS namespace for the live check. It downloads the public CSV, imports it twice to a unique table, compares every species count with Python's CSV reader, then attempts a malformed refresh. The check confirms the previous results remain intact and removes its test table when successful.

Platform interfaces: [KaggleHub](https://github.com/Kaggle/kagglehub) and [InterSystems Python DB-API](https://docs.intersystems.com/irislatest/csp/docbook/DocBook.UI.Page.cls?KEY=BPYDBAPI_refapi).

Community Bounty idea: [Load datasets from Kaggle into IRIS](https://ideas.intersystems.com/ideas/DPI-I-1012).
