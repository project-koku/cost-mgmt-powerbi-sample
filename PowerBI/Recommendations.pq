let
    Source = Csv.Document(File.Contents(DataFolder & "\export\Recommendations.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),
    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),
    BlankToNull = Table.ReplaceValue(Promoted, "", null, Replacer.ReplaceValue, Table.ColumnNames(Promoted)),
    #"Changed Type" = Table.TransformColumnTypes(BlankToNull, {{"Load Time", type datetime}, {"cluster_alias", type text}, {"cluster_uuid", type text}, {"container", type text}, {"id", type text}, {"last_reported_time", type datetime}, {"project", type text}, {"source_id", Int64.Type}, {"workload", type text}, {"workload_type", type text}, {"monitoring_end_time", type datetime}, {"Index", Int64.Type}, {"Current configuration", type text}, {"ST Rec Cost Config", type text}, {"ST Rec Perf Config", type text}, {"st.duration_in_hours", Int64.Type}, {"st.monitoring_start_time", type datetime}, {"mt.duration_in_hours", type number}, {"mt.monitoring_start_time", type datetime}, {"MT Rec Cost Config", type text}, {"MT Rec Perf Config", type text}, {"LT Rec Cost Config", type text}, {"LT Rec Perf Config", type text}, {"lt.duration_in_hours", type number}, {"lt.monitoring_start_time", type datetime}})
in
    #"Changed Type"
