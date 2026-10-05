let
    Source = Csv.Document(File.Contents(DataFolder & "\export\OS_Cost_Project_Tags.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"code", type text}, {"Filter Month", type text}, {"date", type date}, {"project", type text}, {"key", type text}, {"values", type text}, {"enabled", type logical}})
in
    #"Changed Type"
