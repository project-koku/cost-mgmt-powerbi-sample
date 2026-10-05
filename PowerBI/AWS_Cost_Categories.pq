let
    Source = Csv.Document(File.Contents(DataFolder & "\export\AWS_Cost_Categories.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    #"Removed Other Columns" = Table.SelectColumns(Promoted, {"data", "Group By"}),
    #"Renamed Columns" = Table.RenameColumns(#"Removed Other Columns", {{"data", "key"}}),
    BlankToNull = Table.ReplaceValue(#"Renamed Columns", "", null, Replacer.ReplaceValue, Table.ColumnNames(#"Renamed Columns")),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"key", type text}, {"Group By", type text}}),
    #"Appended Query" = Table.Combine({#"Changed Type", #"AWS Dummy Table"}),
    #"Filtered Rows1" = Table.SelectRows(#"Appended Query", each ([Group By] = "aws_category"))
in
    #"Filtered Rows1"
