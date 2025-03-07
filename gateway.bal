import ballerina/io;
import ballerina/http;
import ai_gateway.llms;
import ai_gateway.analytics;
import ai_gateway.logging;
import ballerina/time;
import ballerina/uuid;
import ballerina/grpc;
import ballerina/crypto;
import ai_gateway.guardrails;
import ai_gateway.ratelimit;
// import ballerina/log;

configurable llms:OpenAIConfig? openAIConfig = ();
configurable llms:AnthropicConfig? anthropicConfig = ();
configurable llms:GeminiConfig? geminiConfig = ();
configurable llms:OllamaConfig? ollamaConfig = ();
configurable llms:OpenAIConfig? mistralConfig = ();
configurable llms:OpenAIConfig? cohereConfig = ();

type GatewayConfig record {
    int port = 8080;
    int adminPort = 8081;
    boolean verboseLogging = false;
};

// Gateway configuration
configurable GatewayConfig gateway = {};

// Add cache type and storage
type CacheEntry record {
    llms:LLMResponse response;
    int timestamp;
};

isolated map<CacheEntry> promptCache = {};

// Add cache configuration
configurable int cacheTTLSeconds = 3600; // Default 1 hour TTL

// Using this to read initial logging configuration from system startup
// When the configurable is read from Config.toml at system startup, cannot assign or update
// that value later using the /admin service. So copying this at init()
configurable logging:LoggingConfig defaultLoggingConfig = {};

// Add service route configuration
type ServiceRoute record {|
    string name;
    string endpoint;
    boolean enableCache = true;
    boolean enableRateLimit = true;
|};

// Store configured routes
isolated map<ServiceRoute> serviceRoutes = {};

// Analytics storage
isolated analytics:RequestStats requestStats = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    requestsByProvider: {},
    errorsByProvider: {},
    cacheHits: 0,
    cacheMisses: 0
};

isolated analytics:TokenStats tokenStats = {
    totalInputTokens: 0,
    totalOutputTokens: 0,
    inputTokensByProvider: {},
    outputTokensByProvider: {}
};

isolated analytics:ErrorStats errorStats = {
    totalErrors: 0,
    errorsByType: {},
    recentErrors: []
};

# AIGateway gRPC service
# Provides gRPC API for interacting with the AI Gateway's LLM providers
# Exposes endpoints for chat completion and other LLM operations
# Uses the same underlying provider handling logic as the HTTP API
# Maintains metrics and logging consistent with the HTTP interface
@grpc:Descriptor {value: AI_GATEWAY_DESC}
isolated service "AIGateway" on new grpc:Listener(8082) {
    private http:Client? openaiClient = ();
    private http:Client? anthropicClient = ();
    private http:Client? geminiClient = ();
    private http:Client? ollamaClient = ();
    private http:Client? mistralClient = ();
    private http:Client? cohereClient = ();

    isolated function init() returns error? {
        logging:setVerboseLogging(gateway.verboseLogging);
        logging:setLoggingConf(defaultLoggingConfig);
        check self.initializeClients();
    }

    # ChatCompletion handles gRPC requests for LLM completions
    # Converts gRPC-specific request format to internal LLMRequest
    # Uses the same underlying provider routing and failover logic as the HTTP API
    # + request - The ChatCompletionRequest from the gRPC client containing messages, temperature, etc.
    # + return - ChatCompletionResponse - The formatted response with completion text and metadata
    #            error - If any provider errors occur or no providers are available

    isolated remote function ChatCompletion(ChatCompletionRequest request) returns ChatCompletionResponse|error {
        // Convert gRPC request to internal LLMRequest format
        llms:LLMRequest llmRequest = {
            messages: from var msg in request.messages
                select {
                    role: msg.role,
                    content: msg.content
                },
            temperature: request.temperature,
            maxTokens: request.max_tokens
        };

        // Reuse existing provider handling logic
        llms:LLMResponse|error response = self.tryProvider(request.llm_provider, llmRequest.cloneReadOnly());

        if response is error {
            return response;
        }

        // Convert LLMResponse to gRPC response format
        return <ChatCompletionResponse>{
            id: response.id,
            'object: response.'object,
            created: response.created,
            model: response.model,
            choices: from var choice in response.choices
                select {
                    index: choice.index,
                    message: {
                        role: choice.message.role,
                        content: choice.message.content
                    },
                    finish_reason: choice.finish_reason
                },
            usage: {
                prompt_tokens: response.usage.prompt_tokens,
                completion_tokens: response.usage.completion_tokens,
                total_tokens: response.usage.prompt_tokens + response.usage.completion_tokens
            }
        };
    }

    # Initialize LLM provider clients for the gRPC service
    # Sets up HTTP clients for each configured LLM provider (OpenAI, Anthropic, etc.)
    # Validates endpoint configurations and API keys before establishing connections
    # Logs initialization status for each provider with endpoint information
    # Returns error if no providers are configured or if any required configuration is missing
    # This function is called during service initialization to prepare all provider connections
    # 
    # + return - error - If any provider configuration is invalid or missing
    isolated function initializeClients() returns error? {
        logging:logEvent("INFO", "gRPC:init", "Initializing AI Gateway gRPC interface");

        logging:logEvent("INFO", "gRPC:init", "Initializing AI Gateway gRPC interface");

        logging:logEvent("DEBUG", "gRPC:init", "Loaded logging configuration", <map<json>>logging:getLoggingConf().toJson());

        // Check if at least one provider is configured
        if openAIConfig == () && anthropicConfig == () && geminiConfig == () 
           && ollamaConfig == () && mistralConfig == () && cohereConfig == () {
            logging:logEvent("ERROR", "gRPC:init", "No LLM providers configured");
            return error("At least one LLM provider must be configured");
        }

        if openAIConfig?.endpoint != () {
            string endpoint = openAIConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid OpenAI configuration", {"error": "Empty endpoint"});
                return error("OpenAI endpoint is required");
            } else {
                lock {
                    self.openaiClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "OpenAI client initialized", {"endpoint": endpoint});
            }
        }
        if anthropicConfig?.endpoint != () {
            string endpoint = anthropicConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid Anthropic configuration", {"error": "Empty endpoint"});
                return error("Anthropic endpoint is required");
            } else {
                lock {
                    self.anthropicClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "Anthropic client initialized", {"endpoint": endpoint});
            }
        }
        if geminiConfig?.endpoint != () {
            string endpoint = geminiConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid Gemini configuration", {"error": "Empty endpoint"});
                return error("Gemini endpoint is required");
            } else {
                lock {
                    self.geminiClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "Gemini client initialized", {"endpoint": endpoint});
            }
        }
        if ollamaConfig?.endpoint != () {
            string endpoint = ollamaConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid Ollama configuration", {"error": "Empty endpoint"});
                return error("Ollama endpoint is required");
            } else {
                lock {
                    self.ollamaClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "Ollama client initialized", {"endpoint": endpoint});
            }
        }
        if mistralConfig?.endpoint != () {
            string endpoint = mistralConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid Mistral configuration", {"error": "Empty endpoint"});
                return error("Mistral endpoint is required");
            } else {
                lock {
                    self.mistralClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "Mistral client initialized", {"endpoint": endpoint});
            }
        }
        if cohereConfig?.endpoint != () {
            string endpoint = cohereConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent("ERROR", "gRPC:init", "Invalid Cohere configuration", {"error": "Empty endpoint"});
                return error("Cohere endpoint is required");
            } else {
                lock {
                    self.cohereClient = check new (endpoint);
                }
                logging:logEvent("INFO", "gRPC:init", "Cohere client initialized", {"endpoint": endpoint});
            }
        }
        logging:logEvent("INFO", "gRPC:init", "AI Gateway initialization complete", {
            "providers": [
                openAIConfig != () ? "openai" : "",
                anthropicConfig != () ? "anthropic" : "",
                geminiConfig != () ? "gemini" : "",
                ollamaConfig != () ? "ollama" : "",
                mistralConfig != () ? "mistral" : "",
                cohereConfig != () ? "cohere" : ""
            ].filter(p => p != "")
        });
    }

    # Attempts to route a request to the specified LLM provider
    # Handles provider selection, request processing, error handling, and metrics collection
    # Parameters:
    # Notes:
    #   - Updates request and token statistics on success
    #   - Records detailed error information on failure
    #   - Logs all request attempts with correlation IDs for tracing
    #   - Uses appropriate handler function based on provider type
    # 
    # + provider - The name of the LLM provider to use (e.g., "openai", "anthropic")
    # + payload - The LLM request payload containing messages and parameters
    # + return - llms:LLMResponse - A successful response from the LLM provider
    #            error - If the provider request fails, not configured, or encounters other issues
    private isolated function tryProvider(string provider, llms:LLMRequest & readonly payload) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();

        logging:logEvent("DEBUG", "provider", "Attempting provider request", {
            requestId: requestId,
            provider: provider,
            prompt: payload.toString()
        });

        // Map of provider to client
        map<http:Client?> clientMap;
        lock {
            clientMap = {
                "openai": self.openaiClient,
                "anthropic": self.anthropicClient,
                "gemini": self.geminiClient,
                "ollama": self.ollamaClient,
                "mistral": self.mistralClient,
                "cohere": self.cohereClient
            };
        }
        // Map of provider to handler function
        final map<isolated function (http:Client, llms:LLMRequest) returns llms:LLMResponse|error> handlerMap = {
            "openai": llms:handleOpenAIRequest,
            "anthropic": llms:handleAnthropicRequest,
            "gemini": llms:handleGeminiRequest,
            "ollama": llms:handleOllamaRequest,
            "mistral": llms:handleMistralRequest,
            "cohere": llms:handleCohereRequest
        };

        final http:Client? llmClient = clientMap[provider];
        final var handler = handlerMap[provider];

        if llmClient is http:Client && handler is function {
            llms:LLMResponse|error response = handler(llmClient, payload);
            if response is llms:LLMResponse {
                logging:logEvent("INFO", "provider", "Provider request successful", {
                    requestId: requestId,
                    provider: provider,
                    model: response.model,
                    tokens: {
                        input: response.usage.prompt_tokens,
                        output: response.usage.completion_tokens
                    }
                });
                // Update stats for successful request
                updateSuccessStats(provider, response);
            } else {
                updateErrorStats(provider, response, requestId);
                logging:logEvent("ERROR", "provider", "Provider request failed", {
                    requestId: requestId,
                    provider: provider,
                    errorType: response.message().toString(),
                    'error: response.detail().toString()
                });
            }
            return response;
        }

        // Handle provider not configured error
        string errorMessage = "Provider not configured: " + provider;
        logging:logEvent("ERROR", "provider", "Provider not configured", {
            requestId: requestId,
            provider: provider
        });

        // Update error stats for provider not configured
        updateErrorStats(provider, error(errorMessage), requestId);
        return error(errorMessage);
    }
}

service class ResponseInterceptor {
    *http:ResponseInterceptor;

    remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        // Set server header identifyng AI Gateway version
        res.setHeader("Server", "ai-gateway/v1.1.0");

        // Get rate limit details from request context. These are set by the RequestInterceptor
        string|error rateLimit_Limit = ctx.getWithType("X-RateLimit-Limit");
        string|error rateLimit_Remaining = ctx.getWithType("X-RateLimit-Remaining");
        string|error rateLimit_Reset = ctx.getWithType("X-RateLimit-Reset");
        if rateLimit_Limit is string && rateLimit_Limit != "0" {
            res.setHeader("X-RateLimit-Limit", rateLimit_Limit);
        }
        if rateLimit_Remaining is string && rateLimit_Remaining != "0" {
            res.setHeader("X-RateLimit-Remaining", rateLimit_Remaining);
        }
        if rateLimit_Reset is string  && rateLimit_Reset != "0" {
            res.setHeader("X-RateLimit-Reset", rateLimit_Reset);
        }
        return ctx.next();
    }
}

# HTTP request interceptor for the AI Gateway
# Handles request preprocessing including cache lookups and generation of cache keys
# 
# - Intercepts incoming HTTP requests before they reach handler functions
# - Checks if responses are available in cache to avoid unnecessary API calls
# - Generates cache keys for requests based on provider and payload hash
# - Updates cache statistics for hits and misses
# - Stores cache keys in the request context for later use by handlers
# - Respects Cache-Control headers for cache bypassing
service class RequestInterceptor {
    *http:RequestInterceptor;

    # Intercepts incoming HTTP requests to check cache before forwarding to handlers
    # Checks for cached responses based on provider and payload hash
    # 
    # + ctx - The request context containing metadata and routing information
    # + req - The original HTTP request from the client
    # + path - The path segments of the request URL
    # + return - http:NextService - Forwards the request to the next service in the chain
    #            http:Response - Returns a cached response if available
    #            error - If any processing errors occur during interception
    resource function 'default[string... path] (
        http:Caller caller, http:RequestContext ctx, http:Request req) returns http:NextService|http:Response|error? {
        
        // Get provider and payload
        string|http:HeaderNotFoundError provider = req.getHeader("x-llm-provider");
        if provider is http:HeaderNotFoundError {
            return ctx.next();
        }

        // Enforce rate limiting
        string clientIP = "";
        string|http:HeaderNotFoundError forwardedHeader = req.getHeader("X-Forwarded-For");
        if forwardedHeader is http:HeaderNotFoundError {
            clientIP = caller.remoteAddress.ip;
        } else {
            clientIP = forwardedHeader;
        }
        
        // Check for client-specific rate limit first, then fall back to default
        ratelimit:ClientRateLimitPlan? clientPlan = ratelimit:getClientRateLimit(clientIP);
        [boolean, int, int, int, string]|error rateLimitResponse;
        
        if clientPlan is ratelimit:ClientRateLimitPlan {
            rateLimitResponse = ratelimit:checkRateLimit(clientIP, clientPlan);
        } else {
            rateLimitResponse = ratelimit:checkRateLimit(clientIP);
        }
        
        if rateLimitResponse is error {
            logging:logEvent("ERROR", "ratelimit", "Rate limit check failed", {
                clientIP: clientIP,
                'error: rateLimitResponse.message()
            });
            return rateLimitResponse;
        }
        
        boolean allowed = rateLimitResponse[0];
        int rateLimit = rateLimitResponse[1];
        int remaining = rateLimitResponse[2];
        int reset = rateLimitResponse[3];
        string planType = rateLimitResponse[4];
        
        // Log rate limit details for debugging
        logging:logEvent("DEBUG", "ratelimit", "Rate limit check", {
            clientIP: clientIP,
            planType: planType,
            allowed: allowed,
            'limit: rateLimit,
            remaining: remaining,
            reset: reset
        });

        if !allowed {
            http:Response response = new;
            response.statusCode = 429; // Too Many Requests
            response.addHeader("Content-Type", "application/json");
            response.setJsonPayload({
                'error: "Rate limit exceeded",
                'limit: rateLimit,
                remaining: remaining,
                reset: reset,
                planType: planType  // Include plan type for debugging
            });
            updateErrorStats(provider, response, "rate-limit-exceeded");
            check caller->respond(response);
            return;
        } else {
            ctx.set("X-RateLimit-Limit", rateLimit.toString());
            ctx.set("X-RateLimit-Remaining", remaining.toString());
            ctx.set("X-RateLimit-Reset", reset.toString());
            ctx.set("X-RateLimit-Plan", planType);
        }

        // Check Cache-Control header
        string|http:HeaderNotFoundError cacheControl = req.getHeader("Cache-Control");
        if cacheControl is string && cacheControl == "no-cache" {
            return ctx.next();
        }

        json|error payload = req.getJsonPayload();
        if payload is error {
            return ctx.next();
        }

        // Generate cache key using SHA1
        string cacheKey = check generateCacheKey(provider, payload);

        map<CacheEntry> localPromptCache;
        lock {
            localPromptCache = promptCache.cloneReadOnly();
        }

        // Check cache
        if localPromptCache.hasKey(cacheKey) {
            CacheEntry entry = localPromptCache.get(cacheKey);
            int currentTime = time:utcNow()[0];

            // Check if cache entry is still valid
            if (currentTime - entry.timestamp < cacheTTLSeconds) {
                logging:logEvent("INFO", "cache", "Cache hit", {
                    cacheKey: cacheKey
                });

                // Set cached response
                http:Response cachedResponse = new;

                // Get rate limit details from request context. These are set by the RequestInterceptor
                string|error rateLimit_Limit = ctx.getWithType("X-RateLimit-Limit");
                string|error rateLimit_Remaining = ctx.getWithType("X-RateLimit-Remaining");
                string|error rateLimit_Reset = ctx.getWithType("X-RateLimit-Reset");
                if rateLimit_Limit is string {
                    cachedResponse.setHeader("X-RateLimit-Limit", rateLimit_Limit);
                }
                if rateLimit_Remaining is string {
                    cachedResponse.setHeader("X-RateLimit-Remaining", rateLimit_Remaining);
                }
                if rateLimit_Reset is string {
                    cachedResponse.setHeader("X-RateLimit-Reset", rateLimit_Reset);
                }

                // Enforce guardrails for cached responses
                string|error guardedText = guardrails:applyGuardrails(entry.response.toString());
                if guardedText is error {
                    logging:logEvent("ERROR", "guardrails", "Guardrails check failed for cached response", {
                        'error: guardedText.message() + ":" + guardedText.detail().toString()
                    });
                    updateErrorStats("guardrails", guardedText, "guardrails-check-failed");
                    return guardedText;
                }
                lock {
                    requestStats.cacheHits += 1;
                }
                updateSuccessStats(provider, entry.response);
                cachedResponse.setPayload(entry.response);
                return  cachedResponse;
            } else {
                logging:logEvent("DEBUG", "cache", "Cache entry expired", {
                    cacheKey: cacheKey,
                    age: currentTime - entry.timestamp
                });
                lock {
                    _ = promptCache.remove(cacheKey);
                }
            }
        }

        // Check if this is a cacheable request
        if req.method == "POST" && req.rawPath.startsWith("/v1/chat/completions") {
            // We need to log a cache miss since we got this far
            logging:logEvent("DEBUG", "cache", "Cache miss", {
                cacheKey: cacheKey
            });

            // Update cache stats for misses
            lock {
                requestStats.cacheMisses += 1;
            }
        }

        // Store cache key in context for later use
        ctx.set("cacheKey", cacheKey);
        return ctx.next();
    }
}


service class RequestErrorInterceptor {
    *http:RequestErrorInterceptor;

    // remote function interceptRequestError(http:RequestErrorContext ctx) returns http:Response|error? {
    //     logging:logEvent("ERROR", "RequestErrorInterceptor", "Request error", {
    //         'error: ctx.error.message()
    //     });

    //     http:Response response = new;
    //     response.statusCode = 500;
    //     response.addHeader("Content-Type", "application/json");
    //     response.setJsonPayload({
    //         'error: "Internal server error",
    //         'message: ctx.error.message()
    //     });

    //     return response;
    // }
    resource function 'default[string... path](error err) returns error {
        logging:logEvent("ERROR", "RequestErrorInterceptor", "Request error", {
            'error: err.message()
        });
        return err;
    }
 }

service class ResponseErrorInterceptor {
    *http:ResponseErrorInterceptor;

    remote function interceptResponseError(http:RequestContext ctx, error err) returns error {
        logging:logEvent("ERROR", "ResponseErrorInterceptor", "Response error", {
            'error: err.message()
        });

        // Update error stats
        string|error provider = ctx.getWithType("x-llm-provider");
        string|error requestId = ctx.getWithType("requestId");
        if provider is error {
            provider = "unknown";
        }
        if requestId is error {
            requestId = "unknown";
        }
        updateErrorStats(check provider, err, check requestId);

        return err;
    }
}


# Generates a SHA-1 hash-based cache key for LLM API requests
# Creates a unique identifier for each request to enable caching of responses
# 
# + provider - The name of the LLM provider handling the request
# + payload - The JSON request payload containing messages and parameters
# + return - string - A hex-encoded SHA-1 hash string to use as cache key
#            error - If hash generation fails for any reason
isolated function generateCacheKey(string provider, json payload) returns string|error {
    // byte[] hash = crypto:hashSha1(provider.toBytes().concat(payload.toString().toBytes()));
    byte[] hash = crypto:hashSha1((provider+payload.toString()).toBytes());
    return hash.toBase16();
}

isolated var llmHandlers = ();

type HttpResponseError record {
    string timestamp;
    string status;
    string reason;
    string message;
    string path;
    string method;
};

# Updates error statistics for failed LLM provider API requests
# Records error details by provider, type, and message for monitoring and reporting
# 
# + provider - The name of the LLM provider that generated the error
# + llmResponse - The error response returned by the provider API call
# + requestId - The unique identifier for the original request
isolated function updateErrorStats(string provider, error|http:Response llmResponse, string requestId) {
    HttpResponseError|http:ClientConnectorError|error httpError = llmResponse.ensureType(HttpResponseError);
    string errorType;
    string errorMessage;

    if httpError is HttpResponseError {
        errorType = httpError.status;
        errorMessage = httpError.message;
    } else if httpError is http:ClientConnectorError {
        errorType = "ClientConnectorError";
        errorMessage = httpError.detail().toString();
    } else if llmResponse is http:Response {
        if llmResponse.statusCode == 429 {
            errorType = "RateLimitExceeded";
            errorMessage = "RateLimitExceeded";
        } else if llmResponse.statusCode == 400 {
            errorType = "BadRequest";
            errorMessage = "BadRequest";
        } else {
            errorType = llmResponse.statusCode.toString();
            errorMessage = "";
        }
    } else {
        errorType = "unknown";
        errorMessage = llmResponse.message();
    }

    lock {
        errorStats.totalErrors += 1;
    }

    // Final error stats update for the client-facing error
    lock {
        // Update errors by type (grouped by status code)
        errorStats.errorsByType[errorType] = (errorStats.errorsByType[errorType] ?: 0) + 1;

        // Add to recent errors as the final client-facing error
        analytics:ErrorEntry newError = {
            timestamp: time:utcNow()[0],
            provider: provider,
            message: errorMessage,
            'type: errorType,
            requestId: requestId
        };

        // Ensure recentErrors only keeps the 10 latest items
        if errorStats.recentErrors.length() >= 10 {
            errorStats.recentErrors = errorStats.recentErrors.slice(1);
        }
        errorStats.recentErrors.push(newError.toString());
    }
    lock {
        // Update request stats
        requestStats.totalRequests += 1;
        requestStats.failedRequests += 1;
        requestStats.errorsByProvider[provider] = (requestStats.errorsByProvider[provider] ?: 0) + 1;
    }
}

# Main AI Gateway HTTP service
# Handles routing and processing of LLM API requests with intelligent provider selection
# 
# - Provides an OpenAI-compatible API endpoint for chat completions
# - Supports multiple LLM providers with automatic failover
# - Implements request caching to improve performance and reduce costs
# - Enforces rate limits and guardrails on API usage
# - Collects detailed metrics on usage, tokens, and errors
# - Provides service discovery and routing for microservices
isolated service http:InterceptableService / on new http:Listener(8080) {
    private http:Client? openaiClient = ();
    private http:Client? anthropicClient = ();
    private http:Client? geminiClient = ();
    private http:Client? ollamaClient = ();
    private http:Client? mistralClient = ();
    private http:Client? cohereClient = ();

    public function createInterceptors() returns [RequestInterceptor, ResponseInterceptor] {
        return [new RequestInterceptor(), new ResponseInterceptor()];
    }

    # Initializes the main HTTP service for the AI Gateway
    # Sets up connections to LLM providers, loads configurations, and validates the initial setup
    # Note: This function is called automatically when the service starts up
    # 
    # + return - error - If initialization fails due to missing or invalid configuration
    #            () - If initialization is successful and at least one provider is configured
    isolated function init() returns error? {
        logging:logEvent("INFO", "HTTP:init", "Initializing AI Gateway");
        
        // Read initial logging configuration
        // lock { loggingConfig = defaultLoggingConfig; }
        logging:setLoggingConf(defaultLoggingConfig);
        logging:logEvent("DEBUG", "HTTP:init", "Loaded logging configuration", <map<json>>logging:getLoggingConf().toJson());

        llms:setAnthropicConfig(anthropicConfig);
        llms:setOpenAIConfig(openAIConfig);
        llms:setGeminiConfig(geminiConfig);
        llms:setOllamaConfig(ollamaConfig);
        llms:setMistralConfig(mistralConfig);
        llms:setCohereConfig(cohereConfig);
        
        // Initialize providers using lock statement
        http:Client? openai = initializeProvider("openai", openAIConfig?.endpoint)[0];
        http:Client? anthropic = initializeProvider("anthropic", anthropicConfig?.endpoint)[0];
        http:Client? gemini = initializeProvider("gemini", geminiConfig?.endpoint)[0];
        http:Client? ollama = initializeProvider("ollama", ollamaConfig?.endpoint)[0];
        http:Client? mistral = initializeProvider("mistral", mistralConfig?.endpoint)[0];
        http:Client? cohere = initializeProvider("cohere", cohereConfig?.endpoint)[0];
        
        lock {
            self.openaiClient = openai;
            self.anthropicClient = anthropic;
            self.geminiClient = gemini;
            self.ollamaClient = ollama;
            self.mistralClient = mistral;
            self.cohereClient = cohere;
        }
        
        // Check if at least one provider is configured
        boolean noProvidersConfigured;
        lock {
            noProvidersConfigured = self.openaiClient == () && self.anthropicClient == () && 
                self.geminiClient == () && self.ollamaClient == () && 
                self.mistralClient == () && self.cohereClient == ();
        }
        
        if noProvidersConfigured {
            logging:logEvent("ERROR", "HTTP:init", "No LLM providers configured");
            return error("At least one LLM provider must be configured");
        }
        
        // Log successful initialization
        string[] configuredProviders = [
            openAIConfig != () ? "openai" : "",
            anthropicConfig != () ? "anthropic" : "",
            geminiConfig != () ? "gemini" : "",
            ollamaConfig != () ? "ollama" : "",
            mistralConfig != () ? "mistral" : "",
            cohereConfig != () ? "cohere" : ""
        ].filter(p => p != "");
        
        logging:logEvent("INFO", "HTTP:init", "AI Gateway initialization complete", {
            "providers": configuredProviders
        });
    }

    # Handles OpenAI-compatible chat completion API requests
    # Processes requests from clients and routes them to the appropriate LLM provider
    # Manages rate limiting, failover, caching, and error handling for all requests
    # 
    # + llmProvider - The LLM provider to use (from x-llm-provider header)
    # + payload - The request body containing messages, parameters and completion settings
    # + request - The original HTTP request object
    # + ctx - The request context containing metadata and routing information
    # + return - llms:LLMResponse - A successful completion response
    #            http:Response - For rate limit errors or cached responses
    #            error - If processing fails and no provider can handle the request
    isolated resource function post v1/chat/completions(
            @http:Header {name: "x-llm-provider"} string llmProvider,
            @http:Payload llms:LLMRequest payload,
            http:Request request,
            http:RequestContext ctx) returns http:Response|error? {

        [string, string]|error prompts = llms:getPrompts(payload);
        if prompts is error {
            http:Response response = new;
            response.statusCode = 400; // Bad Request
            response.setPayload({
                'error: prompts.message()
            });
            updateErrorStats(llmProvider, response, "invalid-prompts");
            return response;
        }

        string requestId = uuid:createType1AsString();
        logging:logEvent("INFO", "chat", "Received chat request", {
            requestId: requestId,
            provider: llmProvider,
            prompt: prompts.toString()
        });

        http:Client? oaiClient;
        http:Client? anthClient;
        http:Client? gemClient;
        http:Client? ollClient;
        http:Client? misClient;
        http:Client? cohClient;
        lock {
            oaiClient = self.openaiClient;
            anthClient = self.anthropicClient;
            gemClient = self.geminiClient;
            ollClient = self.ollamaClient;
            misClient = self.mistralClient;
            cohClient = self.cohereClient;
        }

        // Get list of available providers
        string[] availableProviders = [];
        if oaiClient != () {
            availableProviders.push("openai");
        }
        if anthClient != () {
            availableProviders.push("anthropic");
        }
        if gemClient != () {
            availableProviders.push("gemini");
        }
        if ollClient != () {
            availableProviders.push("ollama");
        }
        if  misClient != () {
            availableProviders.push("mistral");
        }
        if cohClient != () {
            availableProviders.push("cohere");
        }

        // Only attempt failover if we have 2 or more providers
        boolean enableFailover = availableProviders.length() >= 2;

        // Try primary provider first
        llms:LLMResponse|error llmResponse = self.tryProvider(llmProvider, payload.cloneReadOnly());

        if llmResponse is error && enableFailover {
            logging:logEvent("WARN", "failover", "Primary provider failed", {
                requestId: requestId,
                provider: llmProvider,
                'error: llmResponse.message() + ":" + llmResponse.detail().toString()
            });
            updateErrorStats(llmProvider, llmResponse, requestId);

            // Try other providers
            foreach string provider in availableProviders {
                if provider != llmProvider {
                    logging:logEvent("INFO", "failover", "Attempting failover", {
                        requestId: requestId,
                        provider: provider
                    });

                    llms:LLMResponse|error failoverResponse = self.tryProvider(provider, payload.cloneReadOnly());
                    if failoverResponse !is error {
                        logging:logEvent("INFO", "failover", "Failover successful", {
                            requestId: requestId,
                            provider: provider
                        });
                        llmResponse = failoverResponse;
                        break;
                    }
                    logging:logEvent("WARN", "failover", "Failover attempt failed", {
                        requestId: requestId,
                        provider: provider,
                        'error: failoverResponse.message() + ":" + failoverResponse.detail().toString()
                    });
                }
            }
        }

        if llmResponse is error {
            logging:logEvent("ERROR", "chat", "All providers failed", {
                requestId: requestId,
                'error: llmResponse.message() + ":" + llmResponse.detail().toString()
            });
            updateErrorStats("all-providers", llmResponse, requestId);
            return llmResponse;
        }

        // Cache successful response using key from context
        string cacheKey = check generateCacheKey(llmProvider, payload.toJson());
        if cacheKey != "" {
            lock {
                promptCache[cacheKey] = {
                    response: llmResponse.cloneReadOnly(),
                    timestamp: time:utcNow()[0]
                };
            }

            logging:logEvent("DEBUG", "cache", "Cached response", {
                cacheKey: cacheKey
            });
        }

        // Update stats for successful request
        updateSuccessStats(llmProvider, llmResponse);

        http:Response response = new;
        response.setPayload(llmResponse);
        return response;
    }

    # Handles egress API routes. This is the main entry point for all incoming requests to the API Gateway.
    # Traffic is separate from LLM requests and is proxied to the appropriate backend service based on the route.
    # Routes incoming requests to their appropriate backend services based on configuration
    # 
    # + serviceName - The name of the service to route to (from URL path)
    # + path - The remaining path segments to forward to the backend service
    # + req - The original HTTP request from the client
    # + ctx - The request context containing metadata and routing information
    # + return - http:Response - The response from the backend service
    #            error - If routing fails, backend service is unavailable, or service not found
    isolated resource function 'default [string serviceName]/[string... path](
        http:Request req,
        http:RequestContext ctx) returns http:Response|error {

        string requestId = uuid:createType1AsString();

        string routeName = path[0];

        map<ServiceRoute> localRoutes;
        lock {
            localRoutes = serviceRoutes.cloneReadOnly();
        }

        // Check if the service exists
        if !localRoutes.hasKey(routeName) {
            logging:logEvent("ERROR", "apigateway", "Service not found", {
                requestId: requestId,
                serviceName: routeName
            });
            http:Response res = new;
            res.statusCode = 404;
            res.setPayload({ 'error: "Service not found: " + routeName });
            return res;
        }

        ServiceRoute|() route = localRoutes[routeName] ?: ();
        if route is () {
            // no route, log and return
            logging:logEvent("ERROR", "apigateway", "Service not found", {
                requestId: requestId,
                serviceName: routeName
            });
            return error("Service not found");
        }       

        // Create client for backend service
        http:Client|error backendClient = new (route.endpoint);
        if backendClient is error {
            logging:logEvent("ERROR", "apigateway", "Failed to create backend client", {
                requestId: requestId,
                serviceName: routeName,
                endpoint: route.endpoint,
                'error: backendClient.message()
            });
            return error("Failed to connect to backend service: " + backendClient.message());
        }

        // Construct backend path
        // string backendPath = "/" + string:'join("/", ...path);
        string[] pathURL = path.slice(1, path.length());
        string backendPath = "/" + string:'join("/", ...pathURL);
        if req.getQueryParams() != {} {
            backendPath = backendPath + "?" + req.getQueryParams().toString();
        }

        logging:logEvent("INFO", "apigateway", "Forwarding request", {
            requestId: requestId,
            serviceName: routeName,
            method: req.method,
            path: backendPath,
            endpoint: route.endpoint
        });

        // Forward the request to the backend
        http:Response|error response;
        match req.method {
            "GET" => {
                // response = backendClient->get(backendPath, req);
                response = backendClient->get(backendPath, {});
            }
            "POST" => {
                response = backendClient->post(backendPath, req);
            }
            "PUT" => {
                response = backendClient->put(backendPath, req);
            }
            "DELETE" => {
                response = backendClient->delete(backendPath, req);
            }
            "PATCH" => {
                response = backendClient->patch(backendPath, req);
            }
            _ => {
                response = error("Unsupported HTTP method: " + req.method);
            }
        }
        if response is error {
            logging:logEvent("ERROR", "apigateway", "Backend request failed", {
                requestId: requestId,
                serviceName: routeName,
                'error: response.message()
            });
            return response;
        }
        return response;
    }

# Attempts to route a request to the specified LLM provider
# Handles provider selection, request processing, error handling, and metrics collection
# Notes:
# - Updates request and token statistics on success
# - Records detailed error information on failure
# - Logs all request attempts with correlation IDs for tracing
# - Uses appropriate handler function based on provider type
# 
# + provider - The name of the LLM provider to use (e.g., "openai", "anthropic")
# + payload - The LLM request payload containing messages and parameters
# + return - llms:LLMResponse - A successful response from the LLM provider
#            error - If the provider request fails, not configured, or encounters other issues
    private isolated function tryProvider(string provider, llms:LLMRequest & readonly payload) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();

        logging:logEvent("DEBUG", "provider", "Attempting provider request", {
            requestId: requestId,
            provider: provider,
            prompt: payload.toString()
        });

        // Map of provider to client
        map<http:Client?> clientMap;
        lock {
            clientMap = {
                "openai": self.openaiClient,
                "anthropic": self.anthropicClient,
                "gemini": self.geminiClient,
                "ollama": self.ollamaClient,
                "mistral": self.mistralClient,
                "cohere": self.cohereClient
            };
        }
        // Map of provider to handler function
        final map<isolated function (http:Client, llms:LLMRequest) returns llms:LLMResponse|error> handlerMap = {
            "openai": llms:handleOpenAIRequest,
            "anthropic": llms:handleAnthropicRequest,
            "gemini": llms:handleGeminiRequest,
            "ollama": llms:handleOllamaRequest,
            "mistral": llms:handleMistralRequest,
            "cohere": llms:handleCohereRequest
        };

        final http:Client? llmClient = clientMap[provider];
        final var handler = handlerMap[provider];

        if llmClient is http:Client && handler is function {
            llms:LLMResponse|error response = handler(llmClient, payload);
            if response is llms:LLMResponse {
                logging:logEvent("INFO", "provider", "Provider request successful", {
                    requestId: requestId,
                    provider: provider,
                    model: response.model,
                    tokens: {
                        input: response.usage.prompt_tokens,
                        output: response.usage.completion_tokens
                    }
                });
            } else {
                updateErrorStats(provider, response, requestId);
                logging:logEvent("ERROR", "provider", "Provider request failed", {
                    requestId: requestId,
                    provider: provider,
                    errorType: response.message().toString(),
                    'error: response.detail().toString()
                });                
            }
            return response;
        }

        // Handle provider not configured error
        string errorMessage = "Provider not configured: " + provider;
        logging:logEvent("ERROR", "provider", "Provider not configured", {
            requestId: requestId,
            provider: provider
        });

        // Update error stats for provider not configured
        updateErrorStats(provider, error(errorMessage), requestId);
        return error(errorMessage);
    }
}

# Admin service for the AI Gateway
# Provides management interfaces and analytics for the gateway
# - Exposes APIs to configure system prompts and guardrails
# - Offers endpoints to view and manage the response cache
# - Provides detailed analytics and statistics on usage
# - Allows configuration of logging and rate limiting
# - Includes service route management for the API gateway
# - Renders a web dashboard for visual monitoring
isolated service http:InterceptableService /admin on new http:Listener(8081) {
    // Template HTML for analytics
    private string statsTemplate = "";

    public function createInterceptors() returns ResponseInterceptor {
        return new ResponseInterceptor();
    }

    # Initializes the Admin service for the AI Gateway
    # Sets up HTML templates for the dashboard visualization
    # + return - error - If initialization fails due to missing template files
    #            () - If initialization completes successfully with all required resources
    isolated function init() returns error? {
        self.statsTemplate = check io:fileReadString("resources/stats.html");
    }
    isolated resource function post systemprompt(@http:Payload llms:SystemPromptConfig config) returns json|error {
        lock { llms:setSystemPrompt(config.prompt); }
        return { "status": "System prompt updated successfully" };
    }

    resource function get systemprompt() returns llms:SystemPromptConfig {
        lock {
            return {
                prompt: llms:getSystemPrompt()
            };
        }
    }

    // Add guardrails endpoints
    resource function post guardrails(@http:Payload guardrails:GuardrailConfig config) returns json|error {
        lock {
            guardrails:setGuardrails(config);
        }
        return { "status": "Guardrails updated successfully" };
    }

    resource function get guardrails() returns guardrails:GuardrailConfig {
        lock {
            return guardrails:getGuardrails();
        }
    }

    // Add cache management endpoints
    resource function delete cache() returns json {
        lock {
            promptCache = {};
        }
        return { "status": "Cache cleared successfully" };
    }

    resource function get cache() returns map<CacheEntry> {
        lock {
            return promptCache.cloneReadOnly();
        }
    }

    resource function get dashboard() returns http:Response|error {
        string html;
        lock {
            html = analytics:renderTemplate(self.statsTemplate, {});
        }
        http:Response response = new;
        response.setHeader("Content-Type", "text/html");
        response.setPayload(html);
        return response;
    }
    // Add logging configuration endpoint
    isolated resource function post logging(@http:Payload logging:LoggingConfig logConfig) returns json|error {
        lock {
            // loggingConfig = <logging:LoggingConfig & readonly>logConfig;
            logging:setLoggingConf(logConfig);
        }
        return { "status": "Logging configuration updated successfully" };
    }

    isolated resource function get logging() returns logging:LoggingConfig {
        lock {
            return logging:getLoggingConf();
        }
    }

    // Get all client-specific rate limits
    isolated resource function get ratelimit/clients() returns map<ratelimit:ClientRateLimitPlan> {
        return ratelimit:getAllClientRateLimits();
    }    

    // Set client-specific rate limit
    isolated resource function post ratelimit/clients(@http:Payload ratelimit:ClientRateLimitPlan payload) returns json|error {
        if payload.clientIP == "" {
            return error("Client IP is required");
        }
        ratelimit:setClientRateLimit(payload);
        
        logging:logEvent("INFO", "admin", "Client-specific rate limit updated", {
            clientIP: payload.clientIP,
            plan: payload.toString()
        });
        
        return {
            "status": "Client-specific rate limit updated successfully",
            "clientIP": payload.clientIP
        };
    }

    // Remove client-specific rate limit
    isolated resource function delete ratelimit/clients/[string clientIP]() returns json {      
        ratelimit:removeClientRateLimit(clientIP);
        
        logging:logEvent("INFO", "admin", "Client-specific rate limit removed", {
            clientIP: clientIP
        });
        return {
            "status": "Client-specific rate limit removed successfully",
            "clientIP": clientIP
        };
    }    

    // Get current rate limit states (for debugging)
    isolated resource function get ratelimit/states() returns map<ratelimit:RateLimitState> {
        return ratelimit:getRateLimitStates();
    }

    // Add new JSON stats endpoint
    isolated resource function get stats() returns json {
        string[] requestLabels = [];
        int[] requestData = [];
        int i = 0;
        lock {
            foreach string ikey in requestStats.requestsByProvider.keys() {
                requestLabels[i] = ikey;
                requestData[i] = requestStats.requestsByProvider[ikey] ?: 0;
                i = i + 1;
            }
        }

        string[] inputTokenLabels = [];
        int[] inputTokenData = [];
        i = 0;
        lock {
            foreach string ikey in tokenStats.inputTokensByProvider.keys() {
                inputTokenLabels[i] = ikey;
                inputTokenData[i] = tokenStats.inputTokensByProvider[ikey] ?: 0;
                i = i + 1;
            }
        }
        int[] outputTokenData = [];
        i = 0;
        lock {
            foreach string ikey in tokenStats.outputTokensByProvider.keys() {
                outputTokenData[i] = tokenStats.outputTokensByProvider[ikey] ?: 0;
                i = i + 1;
            }
        }

        // Calculate cache hit rate
        float cacheHitRate = 0.0;
        lock {
            if (requestStats.totalRequests > 0) {
                cacheHitRate = <float>requestStats.cacheHits / <float>requestStats.totalRequests * 100.0;
            }
        }

        analytics:RequestStats rStats;
        analytics:ErrorStats eStats;
        analytics:TokenStats tStats;
        lock {
            rStats = requestStats.cloneReadOnly();
        }
        lock {
            eStats = errorStats.cloneReadOnly();
        }
        lock {
            tStats = tokenStats.cloneReadOnly();
        }
        int totalCacheSize = 0;
        lock {
            totalCacheSize = promptCache.keys().length();
        }
        string[] errorLabels = [];
        int[] errorData = [];
        foreach string ikey in eStats.errorsByType.keys() {
            errorLabels.push(ikey);
            errorData.push(eStats.errorsByType[ikey] ?: 0);
        }
        return {
            overview: {
                totalRequests: rStats.totalRequests,
                successfulRequests: rStats.successfulRequests,
                failedRequests: rStats.failedRequests,
                cacheHitRate: cacheHitRate,
                totalErrors: eStats.totalErrors
            },
            requests: {
                labels: requestLabels,
                data: requestData
            },
            tokens: {
                labels: inputTokenLabels,
                inputData: inputTokenData,
                outputData: outputTokenData,
                totalInput: tStats.totalInputTokens,
                totalOutput: tStats.totalOutputTokens
            },
            errors: {
                labels: errorLabels,
                data: errorData,
                recent: eStats.recentErrors
            },
            cache: {
                hits: rStats.cacheHits,
                misses: rStats.cacheMisses,
                size: totalCacheSize
            }
        };
    }

    // Get all configured routes
    isolated resource function get routes() returns map<ServiceRoute>|error {
        lock {
            return serviceRoutes.cloneReadOnly();
        }
    }

    // Get a specific route
    isolated resource function get routes/[string name]() returns ServiceRoute|error? {
        lock {
            if serviceRoutes.hasKey(name) {
                return serviceRoutes[name].cloneReadOnly();
            }
        }
        return error("Service route not found: " + name);
    }

    // Create or update a route
    isolated resource function post routes(@http:Payload ServiceRoute payload) returns string|error {
        if payload.name == "" {
            return error("Service name is required");
        }

        if payload.endpoint == "" {
            return error("Service endpoint is required");
        }
        lock {
            serviceRoutes[payload.name] = payload.cloneReadOnly();
        }
        logging:logEvent("INFO", "admin", "Service route configured", {
            name: payload.name,
            endpoint: payload.endpoint,
            enableCache: payload.enableCache,
            enableRateLimit: payload.enableRateLimit
        });

        return "Service route configured successfully: " + payload.name;
    }

    // Delete a route
    isolated resource function delete routes/[string name]() returns json|error {
        lock {
            if serviceRoutes.hasKey(name) {
                _ = serviceRoutes.remove(name);
                logging:logEvent("INFO", "admin", "Service route deleted", { name: name });
                return { "status": "Service route deleted successfully: " + name };
            }
        }
        return error("Service route not found: " + name);
    }
}

# Returns the current logging configuration settings
# Retrieves the verbose logging flag and logging configuration in a thread-safe manner
# 
# + return - [boolean, logging:LoggingConfig] - A tuple containing:
#            [0] - The current verbose logging setting (true/false)
#            [1] - The current logging configuration with destinations and settings
isolated function getLoggingConfig() returns [boolean, logging:LoggingConfig] {
    return [logging:getVerboseLogging(), logging:getLoggingConf()];
}

# Validates LLM provider configuration parameters
# Checks for required configuration values and logs initialization status
# 
# + provider - The name of the LLM provider to validate
# + llmClient - The HTTP client instance (if already created)
# + endpoint - The API endpoint URL for the provider
# + return - error? - Returns error if configuration is invalid or endpoint is empty
isolated function validateProvider(string provider, http:Client? llmClient, string endpoint) returns error? {
    if endpoint == "" {
        logging:logEvent("ERROR", provider + ":init", "Invalid configuration", {"error": "Empty endpoint"});
        return error(provider + " endpoint is required");
    }
    
    logging:logEvent("INFO", provider + ":init", provider + " client initialized", {"endpoint": endpoint});
    return;
}

# Initializes an HTTP client for a specific LLM provider
# Creates and validates the HTTP client connection to the provider's API endpoint
# 
# + provider - The name of the LLM provider to initialize
# + endpoint - The API endpoint URL for the provider
# + return - [http:Client?, error?] - A tuple containing:
#            [0] - The initialized HTTP client (or () if initialization failed)
#            [1] - Any error that occurred during initialization (or () if successful)
isolated function initializeProvider(string provider, string? endpoint) returns [http:Client?, error?] {
    if endpoint == () {
        return [(), ()];
    }
    
    string ep = endpoint;
    error? validationResult = validateProvider(provider, (), ep);
    if validationResult is error {
        return [(), validationResult];
    }
    
    http:Client|error llmClient;
    if provider == "ollama" {
        llmClient = new (ep, { timeout: 60 });
    } else {
        llmClient = new (ep);
    }

    if llmClient is error {
        return [(), llmClient];
    } else {
        return [llmClient, ()];
    }
}

# Add helper function for common error response handling
# Creates standardized error responses for API failures from different providers
# 
# + provider - The name of the LLM provider that generated the error
# + requestId - The unique identifier for the original request
# + response - The error object returned from the provider API call
# + statusCode - The HTTP status code from the provider response
# + errorBody - The error message body from the provider response
# + return - error - A formatted error with consistent structure and logging
isolated function handleErrorResponse(
    string provider, string requestId, error response, int statusCode, string errorBody) returns error {

    string errorMessage = provider + " API error: HTTP " + statusCode.toString();
    logging:logEvent("ERROR", provider, "API error response", {
        requestId: requestId,
        statusCode: statusCode,
        response: errorBody
    });
    
    return error(errorMessage, statusCode = statusCode, body = errorBody);
}

# Validates JSON response data from LLM provider APIs
# Checks if response payload is valid JSON and logs detailed errors when invalid
# 
# + provider - The name of the LLM provider that returned the response
# + requestId - The unique identifier for the original request
# + responsePayload - The JSON payload or error from the provider response
# + return - error? - Returns the original error if validation fails, or () if successful
isolated function validateResponse(string provider, string requestId, json|error responsePayload) returns error? {   
    if responsePayload is error {
        logging:logEvent("ERROR", provider, "Invalid JSON response", {
            requestId: requestId,
            'error: responsePayload.message() + ":" + responsePayload.detail().toString()
        });
        return responsePayload;
    }
    return;
}

# Applies guardrails to LLM response content
# Filters and validates response text against configured safety rules
# 
# + provider - The name of the LLM provider that generated the response
# + requestId - The unique identifier for the original request
# + content - The response text content to validate
# + return - string - The validated (and possibly modified) response text
#            error - If content violates guardrail policies
isolated function applyResponseGuardrails(string provider, string requestId, string content) returns string|error {   
    string|error guardedText = guardrails:applyGuardrails(content);
    if guardedText is error {
        logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
            requestId: requestId,
            'error: guardedText.message() + ":" + guardedText.detail().toString()
        });
        return guardedText;
    }
    return guardedText;
}

# Updates request and token statistics for successful LLM requests
# Records request counts and token usage metrics by provider
# Note: Updates the global requestStats and tokenStats with thread-safe locking
# 
# + provider - The name of the LLM provider that successfully processed the request
# + response - The LLM response containing token usage information
isolated function updateSuccessStats(string provider, llms:LLMResponse response) {
    lock {
        requestStats.totalRequests += 1;
        requestStats.successfulRequests += 1;
        requestStats.requestsByProvider[provider] = (requestStats.requestsByProvider[provider] ?: 0) + 1;
    }
    lock {   
        tokenStats.totalInputTokens += response.usage.prompt_tokens;
        tokenStats.totalOutputTokens += response.usage.completion_tokens;
        tokenStats.inputTokensByProvider[provider] = 
            (tokenStats.inputTokensByProvider[provider] ?: 0) + response.usage.prompt_tokens;
        tokenStats.outputTokensByProvider[provider] = 
            (tokenStats.outputTokensByProvider[provider] ?: 0) + response.usage.completion_tokens;
    }
}
