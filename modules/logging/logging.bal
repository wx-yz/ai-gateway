import ballerina/http;
import ballerina/time;
import ballerina/log;

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
    string elasticApiKey = "";
};

type LogEntry record {
    time:Utc timestamp;
};

isolated boolean isVerboseLogging = false;

isolated LoggingConfig loggingConfig = {
    enableSplunk: false,
    enableDatadog: false,
    enableElasticSearch: false,
    openTelemetryEndpoint: "",
    splunkEndpoint: "",
    datadogEndpoint: "",
    elasticSearchEndpoint: "",
    elasticApiKey: ""
};

public isolated function logEvent(string level, string component, string message, map<json> metadata = {}) {
    lock {
        if (!isVerboseLogging && level == "DEBUG") {
            return;
        }
    }

    // Create a copy of metadata to avoid modifying the original
    map<any> sanitizedMetadata = metadata.clone();

    // Mask sensitive data in metadata
    foreach string key in sanitizedMetadata.keys() {
        if (key.toLowerAscii().includes("apikey")) {
            sanitizedMetadata[key] = "********";
        }
    }

    json logEntry = {
        timestamp: time:utcToString(time:utcNow()),
        level: level,
        component: component,
        message: message,
        metadata: sanitizedMetadata.toString()
    };

    // Always log to console
    log:printInfo(logEntry.toString());

    // Publish to configured services
    LoggingConfig lconf;
    lock { lconf = loggingConfig.cloneReadOnly(); }
    if (lconf.enableSplunk) {
        _ = start publishToSplunk(lconf.cloneReadOnly(), logEntry.cloneReadOnly());
    }
    if (lconf.enableDatadog) {
        _ = start publishToDatadog(lconf.cloneReadOnly(), logEntry.cloneReadOnly());
    }
    if (lconf.enableElasticSearch) {
        _ = start publishToElasticSearch(lconf.cloneReadOnly(), logEntry.cloneReadOnly());
    }
}

public isolated function publishToSplunk(LoggingConfig & readonly loggingConfig, json & readonly logEntry) returns error? {
    if (loggingConfig.splunkEndpoint != "") {
        http:Client splunkClient = check new (loggingConfig.splunkEndpoint);
        // Need to handle auth
        http:Response response = check splunkClient->post("/services/collector", logEntry);
        if (response.statusCode != 200) {
            return error("Failed to publish logs to Splunk endpoint: " + response.statusCode.toString());
        }
    }
}

public isolated function publishToDatadog(LoggingConfig & readonly loggingConfig, json & readonly logEntry) returns error? {
    if (loggingConfig.datadogEndpoint != "") {
        http:Client datadogClient = check new (loggingConfig.datadogEndpoint);
        // Need to handle auth
        http:Response response = check datadogClient->post("/api/v2/logs", logEntry);
        if (response.statusCode != 200) {
            return error("Failed to publish logs to Datadog endpoint: " + response.statusCode.toString());
        }
    }
}

public isolated function publishToElasticSearch(LoggingConfig & readonly loggingConfig, json & readonly logEntry) returns error? {
    // Check if ElasticSearch is enabled in the config
    if (!loggingConfig.enableElasticSearch) {
        return error("ElasticSearch logging is not enabled in the configuration");
    }

    // Validate required configuration fields
    if (loggingConfig.elasticSearchEndpoint == "") {
        return error("ElasticSearch endpoint is not configured");
    }
    if (loggingConfig.elasticApiKey == "") {
        return error("ElasticSearch API key is not configured");
    }

    // Format the timestamp and prepare the payload
    json formattedEntry = check formatPayload(logEntry);

    // Create HTTP client
    http:Client elasticClient = check new(loggingConfig.elasticSearchEndpoint);
    
    // Prepare headers
    http:Request request = new;
    request.setHeader("Authorization", "ApiKey " + loggingConfig.elasticApiKey);
    request.setHeader("Content-Type", "application/json");
    
    // Set JSON payload
    request.setJsonPayload(formattedEntry);

    // Send POST request to ElasticSearch specific index
    string indexPath = "/ai-gateway/_doc";
    http:Response response = check elasticClient->post(indexPath, request);
    
    // Check response status
    int statusCode = response.statusCode;
    if (statusCode >= 200 && statusCode < 300) {
        log:printInfo("Successfully published log entry to ElasticSearch");
    } else {
        string responseText = check response.getTextPayload();
        log:printError("Failed to publish to ElasticSearch. Status: " + 
                      statusCode.toString() + ", Response: " + responseText);
        return error("Failed to publish to ElasticSearch", statusCode = statusCode);
    }
}

// Helper function to format the payload
isolated function formatPayload(json logEntry) returns json|error {   
    // Parse metadata string to JSON
    json metadata = check parseStringAsJson(<string> check logEntry.metadata);

    // Construct formatted payload
    json formattedEntry = {
       "@timestamp": check logEntry.timestamp,
        "level": check logEntry.level,
        "component": check logEntry.component,
        "message": check logEntry.message,
        "metadata": metadata
    };

    return formattedEntry;
}

// Helper function to parse JSON string
isolated function parseStringAsJson(string jsonStr) returns json|error {
    return jsonStr.fromJsonString();
}


public isolated function setVerboseLogging(boolean enableVerboseLogging) {
    lock {
        isVerboseLogging = enableVerboseLogging;
    }
}

public isolated function getVerboseLogging() returns boolean {
    boolean verboseLogging;
    lock {
        verboseLogging = isVerboseLogging;
    }
    return verboseLogging;
}

public isolated function setLoggingConf(LoggingConfig logConfig) {
    lock {
        loggingConfig = logConfig.cloneReadOnly();
    }
}

public isolated function getLoggingConf() returns LoggingConfig {
    lock {
        return loggingConfig.cloneReadOnly();
    }
    
}