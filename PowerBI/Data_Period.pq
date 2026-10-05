let
    Source = Csv.Document(File.Contents(DataFolder & "\export\Data_Period.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Removed Blank Rows" = Table.SelectRows(BlankToNull, each not List.IsEmpty(List.RemoveMatchingItems(Record.FieldValues(_), {"", null}))),
    #"Changed Type" = Table.TransformColumnTypes(#"Removed Blank Rows", {{"Start Date", type date}, {"End Date", type date}})
in
    #"Changed Type"
