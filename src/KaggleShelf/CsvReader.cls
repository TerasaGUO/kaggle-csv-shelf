Class KaggleShelf.CsvReader Extends %RegisteredObject
{

Property Input As %RegisteredObject;
Property Buffer As %String(MAXLEN = "");
Property Position As %Integer;
Property SkipLF As %Boolean;
Property Record As %Integer;

/// Start a sequential scan and discard a UTF-8 BOM if present in the decoded stream.
Method Reset(input As %Stream.Object)
{
    set ..Input=input
    set sc=input.Rewind() $$$ThrowOnError(sc)
    set ..Buffer=input.Read(8192,.sc) $$$ThrowOnError(sc)
    set ..Position=1+($extract(..Buffer)=$char(65279)),..SkipLF=0,..Record=0
}

/// Read one logical record across buffer boundaries, preserving quoted newlines and doubled quotes.
Method Next(Output fields) As %Boolean
{
    set fields=[],field="",state=0,started=0,done=0
    for {
        if ..Position>$length(..Buffer) {
            if ..Input.AtEnd {
                if state=1 { do ..Invalid("unterminated quoted field") }
                if started { do fields.%Push(field,"string") }
                quit
            }
            set ..Buffer=..Input.Read(8192,.sc) $$$ThrowOnError(sc)
            set ..Position=1
            continue:..Buffer=""
        }
        set ch=$extract(..Buffer,..Position),..Position=..Position+1
        if ..SkipLF { set ..SkipLF=0 continue:ch=$char(10) }
        set started=1
        if state=1 {
            if ch="""" { set state=2 } else { set field=field_ch }
        } elseif (state=2)&&(ch="""") {
            set field=field_ch,state=1
        } elseif ch="," {
            do fields.%Push(field,"string")
            set field="",state=0
        } elseif (ch=$char(10))||(ch=$char(13)) {
            if (fields.%Size()>0)||(field'="")||(state=2) { do fields.%Push(field,"string") }
            set ..SkipLF=(ch=$char(13)),done=1
        } elseif state=2 {
            do ..Invalid("unexpected character after closing quote")
        } elseif (field="")&&(ch="""") {
            set state=1
        } else {
            set field=field_ch
        }
        if $length(field)>32000 { do ..Invalid("field exceeds 32,000 characters") }
        quit:done
    }
    if started { set ..Record=..Record+1 }
    quit started
}

/// Count data records from one and leave the header at index zero.
Method Invalid(reason)
{
    throw ##class(%Exception.General).%New("CSV record "_..Record_": "_reason)
}

}
