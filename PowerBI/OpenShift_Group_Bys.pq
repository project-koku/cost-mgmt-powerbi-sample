let
    Source = Csv.Document(File.Contents(DataFolder & "\static\OpenShift_Group_Bys.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"Group By", type text}, {"Group By Code", type text}})
in
    #"Changed Type"
