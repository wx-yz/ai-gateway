import ballerina/http;
import ballerina/time;

// Logging configuration type
public type LoggingConfig record {
    boolean enableOpenTelemetry = false;
    boolean enableSplunk = false;
    boolean enableDatadog = false;
    boolean enableElasticSearch = false;
    string openTelemetryEndpoint = "";
    string splunkEndpoint = "";
    string datadogEndpoint = "";
    string elasticSearchEndpoint = "";
};

type LogEntry record {
    time:Utc timestamp;
};

public function publishToSplunk(LoggingConfig loggingConfig, json logEntry) returns error? {
    if (loggingConfig.splunkEndpoint != "") {
        http:Client splunkClient = check new (loggingConfig.splunkEndpoint);
        // Need to handle auth
        http:Response response = check splunkClient->post("/services/collector", logEntry);
        if (response.statusCode != 200) {
            return error("Failed to publish logs to Splunk endpoint: " + response.statusCode.toString());
        }
    }
}

public function publishToDatadog(LoggingConfig loggingConfig, json logEntry) returns error? {
    if (loggingConfig.datadogEndpoint != "") {
        http:Client datadogClient = check new (loggingConfig.datadogEndpoint);
        // Need to handle auth
        http:Response response = check datadogClient->post("/api/v2/logs", logEntry);
        if (response.statusCode != 200) {
            return error("Failed to publish logs to Datadog endpoint: " + response.statusCode.toString());
        }
    }
}

public function publishToElasticSearch(LoggingConfig loggingConfig, json logEntry) returns error? {
    if (loggingConfig.elasticSearchEndpoint != "") {
        http:Client elasticClient = check new (loggingConfig.elasticSearchEndpoint);
        http:Response response = check elasticClient->post("/_bulk", logEntry);
        if (response.statusCode != 200) {
            return error("Failed to publish logs to ElasticSearch endpoint: " + response.statusCode.toString());
        }
    }
}