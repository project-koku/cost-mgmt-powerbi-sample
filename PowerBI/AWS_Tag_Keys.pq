let
    Source = Csv.Document(File.Contents(DataFolder & "\export\AWS_Tag_Keys.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    #"Removed Other Columns" = Table.SelectColumns(Promoted, {"key", "enabled", "Group By"}),
    BlankToNull = Table.ReplaceValue(#"Removed Other Columns", "", null, Replacer.ReplaceValue, Table.ColumnNames(#"Removed Other Columns")),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"key", type text}, {"enabled", type logical}, {"Group By", type text}}),
    #"Appended Query" = Table.Combine({#"Changed Type", #"Tag Dummy Table"})
in
    #"Appended Query"
