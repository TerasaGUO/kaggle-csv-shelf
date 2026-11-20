Class KaggleShelf.Importer Extends %RegisteredObject
{

/// Create an upload stream owned by this IRIS session. Its lifetime follows the object reference.
ClassMethod NewUpload() As %Stream.Object
{
    quit ##class(%Stream.TmpCharacter).%New()
}

/// Reject unsafe identifiers and reserve the registry table.
ClassMethod ValidateTarget(name As %String)
{
    if ('$match(name,"^[A-Za-z][A-Za-z0-9_]{0,39}$"))||($zconvert(name,"L")="imports") {
        throw ##class(%Exception.General).%New("Invalid target table")
    }
}

/// Normalize headers and disambiguate every collision in the SQL column namespace.
ClassMethod Columns(headers As %DynamicArray) As %DynamicArray
{
    set names=[]
    for i=0:1:headers.%Size()-1 {
        set text=$zconvert(headers.%Get(i),"L"),stem="",separator=0
        for j=1:1:$length(text) {
            set ch=$extract(text,j)
            if $match(ch,"^[a-z0-9]$") {
                if separator&&(stem'="") { set stem=stem_"_" }
                set stem=stem_ch,separator=0
            } else { set separator=1 }
        }
        set base="c_"_$select(stem="":"field_"_(i+1),1:$extract(stem,1,40)),name=base,suffix=2
        while $data(used(name)) { set name=base_"_"_suffix,suffix=suffix+1 }
        set used(name)=1
        do names.%Push(name)
    }
    quit names
}

/// Check both direct SQL and prepared statement executions.
ClassMethod Check(result As %SQL.StatementResult)
{
    if result.%SQLCODE<0 { throw ##class(%Exception.General).%New(result.%Message,,result.%SQLCODE) }
}

/// Persist ownership before DDL so a failed setup can resume without adopting another table.
ClassMethod Bind(name, dataset, member, headers)
{
    do ..Check(##class(%SQL.Statement).%ExecDirect(,"CREATE TABLE IF NOT EXISTS KaggleShelf.Imports (DestName VARCHAR(40) PRIMARY KEY,DatasetRef VARCHAR(512),MemberPath VARCHAR(512),HeaderJson LONGVARCHAR)"))
    set dest=$zconvert(name,"L")
    tstart
    try {
        do ..Check(##class(%SQL.Statement).%ExecDirect(,"LOCK TABLE KaggleShelf.Imports IN EXCLUSIVE MODE"))
        set r=##class(%SQL.Statement).%ExecDirect(,"SELECT DatasetRef,MemberPath,HeaderJson FROM KaggleShelf.Imports WHERE DestName=?",dest)
        do ..Check(r)
        if r.%Next() {
            set headerStream=##class(%Stream.GlobalCharacter).%Open(r.%GetData(3))
            set previous=##class(%DynamicArray).%FromJSON(headerStream)
            if (r.%GetData(1)'=dataset)||(r.%GetData(2)'=member)||(previous.%ToJSON()'=headers.%ToJSON()) {
                throw ##class(%Exception.General).%New("This target belongs to a different source or CSV layout")
            }
        } else {
            set r=##class(%SQL.Statement).%ExecDirect(,"SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE UPPER(TABLE_SCHEMA)='KAGGLESHELF' AND UPPER(TABLE_NAME)=?",$zconvert(name,"U"))
            do ..Check(r) do r.%Next()
            if r.%GetData(1) { throw ##class(%Exception.General).%New("An unmanaged table already uses this name") }
            do ..Check(##class(%SQL.Statement).%ExecDirect(,"INSERT INTO KaggleShelf.Imports (DestName,DatasetRef,MemberPath,HeaderJson) VALUES (?,?,?,?)",dest,dataset,member,headers.%ToJSON()))
        }
        tcommit
    } catch ex { trollback 1 throw ex }
}

/// Import a public dataset member directly from the IRIS terminal.
ClassMethod Import(dataset As %String, member As %String, name As %String) As %String
{
    do ..ValidateTarget(name)
    if ($extract(member)="/")||(member["\")||(("/"_member_"/")["/../")||($zconvert($extract(member,*-3,*),"L")'=".csv") {
        throw ##class(%Exception.General).%New("Provide a relative .csv member path inside the dataset")
    }
    set path=..Download(dataset,member)
    quit ..ImportFile(dataset,member,name,path)
}

/// Delegate downloading and Kaggle credentials to the official SDK. Parsing and SQL run in ObjectScript.
ClassMethod Download(dataset As %String, member As %String) As %String [ Language = python, Private ]
{
    import kagglehub
    return kagglehub.dataset_download(dataset, path=member)
}

/// Import a UTF-8 file available on the IRIS server, using the same path as uploaded streams.
ClassMethod ImportFile(dataset, member, name, path) As %String
{
    set file=##class(%Stream.FileCharacter).%New(),file.TranslateTable="UTF8"
    set sc=file.LinkToFile(path) $$$ThrowOnError(sc)
    quit ..ImportStream(dataset,member,name,file)
}

/// Validate the stream before reserving a name, then replace the rows in one IRIS transaction.
ClassMethod ImportStream(dataset As %String, member As %String, name As %String, input As %Stream.Object) As %String
{
    if $tlevel { throw ##class(%Exception.General).%New("Use a session without an open transaction") }
    do ..ValidateTarget(name)
    set reader=##class(KaggleShelf.CsvReader).%New()
    do reader.Reset(input)
    if ('reader.Next(.headers))||(headers.%Size()=0) { throw ##class(%Exception.General).%New("CSV header is required") }
    set width=headers.%Size()
    while reader.Next(.row) {
        if row.%Size()'=width { throw ##class(%Exception.General).%New("CSV record "_(reader.Record-1)_": unexpected field count") }
    }
    set names=..Columns(headers),definition="SourceRecord INTEGER PRIMARY KEY",mapping=[]
    for i=0:1:width-1 {
        set column=names.%Get(i),definition=definition_","_column_" VARCHAR(32000)"
        set pair=[] do pair.%Push(headers.%Get(i)),pair.%Push(column),mapping.%Push(pair)
    }
    do ..Bind(name,dataset,member,headers)
    set target="KaggleShelf."_name
    do ..Check(##class(%SQL.Statement).%ExecDirect(,"CREATE TABLE IF NOT EXISTS "_target_" ("_definition_")"))
    // Dynamic SQL accepts up to 380 parameters. Wide records use additional updates in the same transaction.
    set lastGroup=(width-1)\379
    for group=0:1:lastGroup {
        set first=group*379,end=$select((first+379)>width:width,1:first+379),fields="",marks="",assignments=""
        for i=first:1:end-1 {
            set column=names.%Get(i),fields=fields_","_column,marks=marks_",?",assignments=assignments_$select(i>first:",",1:"")_column_"=?"
        }
        set sql=$select(group=0:"INSERT INTO "_target_" (SourceRecord"_fields_") VALUES (?"_marks_")",1:"UPDATE "_target_" SET "_assignments_" WHERE SourceRecord=?")
        set statements(group)=##class(%SQL.Statement).%New()
        set sc=statements(group).%Prepare(sql) $$$ThrowOnError(sc)
    }
    do reader.Reset(input)
    do reader.Next(.header)
    set count=0
    tstart
    try {
        do ..Check(##class(%SQL.Statement).%ExecDirect(,"LOCK TABLE "_target_" IN EXCLUSIVE MODE"))
        do ..Check(##class(%SQL.Statement).%ExecDirect(,"DELETE FROM "_target))
        while reader.Next(.row) {
            if row.%Size()'=width { throw ##class(%Exception.General).%New("CSV changed during import") }
            set count=count+1
            for group=0:1:lastGroup {
                set first=group*379,end=$select((first+379)>width:width,1:first+379),args=end-first+1
                set args($select(group=0:1,1:args))=count
                for i=first:1:end-1 {
                    set value=row.%Get(i),args(i-first+1+(group=0))=$select(value="":$char(0),1:value)
                }
                do ..Check(statements(group).%Execute(args...))
            }
        }
        tcommit
    } catch ex { trollback 1 throw ex }
    set report={} do report.%Set("count",count,"number"),report.%Set("columns",mapping)
    quit report.%ToJSON()
}

}
