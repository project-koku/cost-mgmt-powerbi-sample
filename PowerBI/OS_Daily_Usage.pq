let
    Source = Csv.Document(File.Contents(DataFolder & "\export\OS_Daily_Usage.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"Group By", type text}, {"Group By Code", type text}, {"Usage Code", type text}, {"Usage Name", type text}, {"Key", type any}, {"meta.count", Int64.Type}, {"meta.currency", type text}, {"date", type date}, {"Name", type text}, {"values.usage.value", type number}, {"values.usage.units", type text}, {"values.request.value", type number}, {"values.request.units", type text}, {"values.request.unused", type number}, {"values.request.unused_percent", type number}, {"values.limit.value", type number}, {"values.limit.units", type text}, {"values.capacity.value", Int64.Type}, {"values.capacity.units", type text}, {"values.capacity.unused", type number}, {"values.capacity.unused_percent", type number}, {"values.capacity.count", Int64.Type}, {"values.capacity.count_units", type text}}),
    #"Added Filter Date" = Table.AddColumn(#"Changed Type", "Filter Month", each if [date] = null then null else Number.ToText(Date.Year([date])) & "-" & Number.ToText(Date.Month([date])))
in
    #"Added Filter Date"
