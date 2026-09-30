let
    Source = Csv.Document(File.Contents(DataFolder & "\static\Project_Overhead_Cost_Types.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"Code", type text}, {"Description", type text}})
in
    #"Changed Type"
