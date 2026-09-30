let
    Source = Csv.Document(File.Contents(DataFolder & "\export\AWS_Org_Units.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    #"Removed Other Columns" = Table.SelectColumns(Promoted, {"org_unit_id", "Group By"}),
    #"Renamed Columns" = Table.RenameColumns(#"Removed Other Columns", {{"org_unit_id", "key"}}),
    BlankToNull = Table.ReplaceValue(#"Renamed Columns", "", null, Replacer.ReplaceValue, Table.ColumnNames(#"Renamed Columns")),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"key", type text}, {"Group By", type text}}),
    #"Appended Query" = Table.Combine({#"Changed Type", #"AWS Dummy Table"}),
    #"Filtered Rows1" = Table.SelectRows(#"Appended Query", each ([Group By] = "org_unit_id"))
in
    #"Filtered Rows1"
