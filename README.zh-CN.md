# Kaggle CSV Shelf

[English](README.md) · 简体中文

从公开的 Kaggle 数据集中选择一个 CSV，导入独立的 InterSystems IRIS SQL 表，即可按列筛选、分组。命令行会输出每一列的原始表头及其对应的 SQL 列名。

## 从 IRIS 终端运行

[Importer](src/KaggleShelf.Importer.cls) 和 [CsvReader](src/KaggleShelf.CsvReader.cls) 使用 ObjectScript 实现 CSV 解析、列名映射、来源登记、建表和事务替换。KaggleHub 负责下载指定的文件。

1. 将仓库放在 IRIS 实例可读取的目录（示例为 `/app`），在目标命名空间编译类。导入账号须能在 `KaggleShelf` 模式建表并读写导入表。

```objectscript
set sc=$system.OBJ.LoadDir("/app/src","ck",,1)
do $system.Status.DisplayError(sc)
```

2. 如需从 IRIS 终端直接下载，将 KaggleHub 安装到 IRIS Embedded Python 可见的位置。以下命令适用于官方 Linux IRIS 2026.2 容器，须在容器内以有目标目录写权限的账号执行。其他安装按实际 Python 目录调整。KaggleHub 需要 Python 3.11+。

```sh
python3 -m pip install --target /usr/irissys/mgr/python kagglehub==1.0.3
```

3. 在 IRIS 终端执行一条命令。返回的 JSON 包含行数和列映射。本例在 IRIS 2026.2 导入 344 行。

```objectscript
write ##class(KaggleShelf.Importer).Import("parulpandey/palmer-archipelago-antarctica-penguin-data","penguins_size.csv","Penguins")
```

导入 IRIS 主机上已有的 UTF-8 CSV 时，可直接调用 ObjectScript 文件入口，无需安装 KaggleHub。请使用授权可读的服务端文件。

```objectscript
write ##class(KaggleShelf.Importer).ImportFile("example/source","sample.csv","Sample","/data/sample.csv")
```

## 从命令行调用

原命令行入口也可使用。客户端用 KaggleHub 取文件，用官方驱动分块上传到 IRIS，CSV 解析和事务写入均在服务端执行。此方式只需在客户端安装 Python 3.11+ 及依赖。远程数据库连接请设置客户端 TLS 配置 `IRIS_SSL_CONFIG`。需要认证的数据集由执行下载的一侧配置 Kaggle 凭据。 命令行使用的账号还须有权在应用命名空间通过 IRIS Native API 调用导入类。

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
export IRIS_DSN='localhost:1972/USER'
export IRIS_USER='your-import-user'
# Set IRIS_PASSWORD in your shell or secret manager.
python shelf.py parulpandey/palmer-archipelago-antarctica-penguin-data penguins_size.csv Penguins
```

示例数据集包含多个文件。这条命令只下载指定的 CSV，并创建 `KaggleShelf.Penguins` 表。如需固定源数据版本，首次导入时可使用 `owner/dataset/versions/1` 这样的版本标识。建表时选定的数据集标识、文件路径和原始表头将与目标表绑定。

```sql
SELECT %EXACT(c_species) AS Species, COUNT(*) AS Birds
FROM KaggleShelf.Penguins
GROUP BY %EXACT(c_species)
ORDER BY Species
```

已验证的公开文件包含 344 条记录，其中 Adelie 有 152 条，Chinstrap 有 68 条，Gentoo 有 124 条。查询中的 `%EXACT` 让 IRIS 按物种名分组时保留原始大小写。

## 导入机制

表头后的第一条记录编号为 1。解析器支持 UTF-8（含 BOM）、引号内的逗号和换行，以及用两个双引号表示一个双引号的 CSV 写法。每个源字段都写入文本列，因此数字文本的前导零可以保留。字符串比较和排序使用数据库的常规规则。生成的列名使用 `c_` 前缀，能够区分空表头、重名或因标点转换产生冲突的列。每个字段最多 32,000 个字符。

导入器先流式校验整个本地 CSV。若首个文件格式有误，修正后可以继续使用原定表名。校验成功后，导入器先登记目标表与来源的绑定，再创建 SQL 表。建表过程中如有中断，可用同一来源重试。第二次扫描文件时，在同一事务内替换目标表的全部记录。任何插入失败都会回滚此次替换。已绑定的数据源如果更改表头，请另选表名。没有匹配登记记录的既有表受到保护。

## 验证

```sh
python -m unittest -v
python verify_live.py
```

请在专用测试命名空间运行在线验证。脚本下载公开 CSV，将其连续两次导入同一张临时测试表，用 Python 的 CSV 读取器独立统计各物种数量，与 SQL 结果逐项核对。随后用格式错误的文件尝试刷新，检查原有结果仍然完整。验证通过后自动清理测试表。

接口文档见 [KaggleHub](https://github.com/Kaggle/kagglehub) 和 [InterSystems Python DB-API](https://docs.intersystems.com/irislatest/csp/docbook/DocBook.UI.Page.cls?KEY=BPYDBAPI_refapi)。

本项目对应的社区悬赏题目为[将 Kaggle 数据集导入 IRIS](https://ideas.intersystems.com/ideas/DPI-I-1012)。
