// Add analytics types
public type RequestStats record {|
    int totalRequests;
    int successfulRequests;
    int failedRequests;
    map<int> requestsByProvider;
    map<int> errorsByProvider;
    int cacheHits;
    int cacheMisses;
|};

public type TokenStats record {
    int totalInputTokens;
    int totalOutputTokens;
    map<int> inputTokensByProvider;
    map<int> outputTokensByProvider;
};

public type ErrorStats record {
    int totalErrors;
    map<int> errorsByType;
    string[] recentErrors;
};