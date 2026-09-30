let
    Source = Csv.Document(File.Contents(DataFolder & "\export\OS_Cost_Cluster_Projects.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    #"Removed Other Columns" = Table.SelectColumns(Promoted, {"code", "Group By Code", "Filter Month", "cluster", "date", "project", "value", "units"}),
    BlankToNull = Table.ReplaceValue(#"Removed Other Columns", "", null, Replacer.ReplaceValue, Table.ColumnNames(#"Removed Other Columns")),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"code", type text}, {"Group By Code", type text}, {"Filter Month", type text}, {"cluster", type text}, {"date", type text}, {"project", type text}, {"value", type number}, {"units", type text}})
in
    #"Changed Type"
