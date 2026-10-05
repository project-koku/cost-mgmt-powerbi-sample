let
    Source = Csv.Document(File.Contents(DataFolder & "\export\Default_Master_Settings.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"code", type text}, {"name", type text}, {"symbol", type text}, {"description", type text}, {"Default_Configurations.data.currency", type text}, {"Default_Configurations.data.cost_type", type text}}),
    #"Renamed Columns" = Table.RenameColumns(#"Changed Type", {{"Default_Configurations.data.currency", "Default Currency"}, {"Default_Configurations.data.cost_type", "Default Cost Type"}}),
    #"Added Custom" = Table.AddColumn(#"Renamed Columns", "Format", each [symbol] & "#,#00.00")
in
    #"Added Custom"
