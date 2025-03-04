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
import ballerina/log;

configurable llms:OpenAIConfig? & readonly openAIConfig = ();
configurable llms:AnthropicConfig? & readonly anthropicConfig = ();
configurable llms:GeminiConfig? & readonly geminiConfig = ();
configurable llms:OllamaConfig? & readonly ollamaConfig = ();
configurable llms:OpenAIConfig? & readonly mistralConfig = ();
configurable llms:OpenAIConfig? & readonly cohereConfig = ();

type GatewayConfig record {
    int port = 8080;
    int adminPort = 8081;
    boolean verboseLogging = false;
};

// Gateway configuration
configurable GatewayConfig gateway = {};

// Add system prompt storage
isolated string systemPrompt = "";

// Add guardrails storage
isolated guardrails:GuardrailConfig guardrails = {
    bannedPhrases: [],
    minLength: 0,
    maxLength: 500000,
    requireDisclaimer: false
};

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

isolated logging:LoggingConfig loggingConfig = {
    enableSplunk: false,
    enableDatadog: false,
    enableElasticSearch: false,
    openTelemetryEndpoint: "",
    splunkEndpoint: "",
    datadogEndpoint: "",
    elasticSearchEndpoint: "",
    elasticApiKey: ""
};

// Add logging state
isolated boolean isVerboseLogging = gateway.verboseLogging;

// Add rate limiting types and storage
type RateLimitPlan record {|
    string name;
    int requestsPerWindow;
    int windowSeconds;
|};

type RateLimitState record {|
    int requests;
    int windowStart;
|};

// Store rate limit states by IP
isolated map<RateLimitState> rateLimitStates = {};
isolated RateLimitPlan? currentRateLimitPlan = ();

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

// Add rate limiting function
isolated function checkRateLimit(string clientIP) returns [boolean, int, int, int]|error {
    lock {
        if currentRateLimitPlan is () {
            return [true, 0, 0, 0];
        }
    }
    RateLimitPlan plan;
    lock {
        plan = <RateLimitPlan>currentRateLimitPlan.cloneReadOnly();
    }
    int currentTime = time:utcNow()[0];

    lock {
        RateLimitState state = rateLimitStates[clientIP] ?: {
            requests: 0,
            windowStart: currentTime
        };
        // Check if we need to reset window
        if (currentTime - state.windowStart >= plan.windowSeconds) {
            state = {
                requests: 0,
                windowStart: currentTime
            };
        }
        // Calculate remaining quota and time
        int remaining = plan.requestsPerWindow - state.requests;
        int resetSeconds = plan.windowSeconds - (currentTime - state.windowStart);

        if (state.requests >= plan.requestsPerWindow) {
            rateLimitStates[clientIP] = state;
            return [false, plan.requestsPerWindow, remaining, resetSeconds];
        }
        // Increment request count
        state.requests += 1;
        rateLimitStates[clientIP] = state;

        return [true, plan.requestsPerWindow, remaining - 1, resetSeconds];
    }
}

@grpc:Descriptor {value: AI_GATEWAY_DESC}
isolated service "AIGateway" on new grpc:Listener(8082) {
    private http:Client? openaiClient = ();
    private http:Client? anthropicClient = ();
    private http:Client? geminiClient = ();
    private http:Client? ollamaClient = ();
    private http:Client? mistralClient = ();
    private http:Client? cohereClient = ();

    isolated function init() returns error? {
        check self.initializeClients();
    }

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
    isolated function initializeClients() returns error? {
        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Initializing AI Gateway gRPC interface");

        logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Initializing AI Gateway gRPC interface");

        // Read initial logging configuration
        lock { loggingConfig = defaultLoggingConfig; }
        logging:logEvent(vLog, logConf, "DEBUG", "gRPC:init", "Loaded logging configuration", <map<json>>logConf.toJson());

        // Check if at least one provider is configured
        if openAIConfig == () && anthropicConfig == () && geminiConfig == () && ollamaConfig == () && mistralConfig == () && cohereConfig == () {
            logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "No LLM providers configured");
            return error("At least one LLM provider must be configured");
        }

        if openAIConfig?.endpoint != () {
            string endpoint = openAIConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid OpenAI configuration", {"error": "Empty endpoint"});
                return error("OpenAI endpoint is required");
            } else {
                lock {
                    self.openaiClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "OpenAI client initialized", {"endpoint": endpoint});
            }
        }
        if anthropicConfig?.endpoint != () {
            string endpoint = anthropicConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid Anthropic configuration", {"error": "Empty endpoint"});
                return error("Anthropic endpoint is required");
            } else {
                lock {
                    self.anthropicClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Anthropic client initialized", {"endpoint": endpoint});
            }
        }
        if geminiConfig?.endpoint != () {
            string endpoint = geminiConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid Gemini configuration", {"error": "Empty endpoint"});
                return error("Gemini endpoint is required");
            } else {
                lock {
                    self.geminiClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Gemini client initialized", {"endpoint": endpoint});
            }
        }
        if ollamaConfig?.endpoint != () {
            string endpoint = ollamaConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid Ollama configuration", {"error": "Empty endpoint"});
                return error("Ollama endpoint is required");
            } else {
                lock {
                    self.ollamaClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Ollama client initialized", {"endpoint": endpoint});
            }
        }
        if mistralConfig?.endpoint != () {
            string endpoint = mistralConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid Mistral configuration", {"error": "Empty endpoint"});
                return error("Mistral endpoint is required");
            } else {
                lock {
                    self.mistralClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Mistral client initialized", {"endpoint": endpoint});
            }
        }
        if cohereConfig?.endpoint != () {
            string endpoint = cohereConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "gRPC:init", "Invalid Cohere configuration", {"error": "Empty endpoint"});
                return error("Cohere endpoint is required");
            } else {
                lock {
                    self.cohereClient = check new (endpoint);
                }
                logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "Cohere client initialized", {"endpoint": endpoint});
            }
        }
        logging:logEvent(vLog, logConf, "INFO", "gRPC:init", "AI Gateway initialization complete", {
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

    private isolated function tryProvider(string provider, llms:LLMRequest & readonly payload) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();
        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        logging:logEvent(vLog, logConf, "DEBUG", "gRPC:tryProvider", "Attempting provider request", {
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
            "openai": handleOpenAIRequest,
            "anthropic": handleAnthropicRequest,
            "gemini": handleGeminiRequest,
            "ollama": handleOllamaRequest,
            "mistral": handleMistralRequest,
            "cohere": handleCohereRequest
        };

        final http:Client? llmClient = clientMap[provider];
        final var handler = handlerMap[provider];

        if llmClient is http:Client && handler is function {
            llms:LLMResponse|error response = handler(llmClient, payload);
            if response is llms:LLMResponse {
                logging:logEvent(vLog, logConf, "INFO", "gRPC:tryProvider", "Provider request successful", {
                    requestId: requestId,
                    provider: provider,
                    model: response.model,
                    tokens: {
                        input: response.usage.prompt_tokens,
                        output: response.usage.completion_tokens
                    }
                });
                // Update stats for successful request
                lock {
                    requestStats.totalRequests += 1;
                    requestStats.successfulRequests += 1;
                    requestStats.requestsByProvider[provider] = (requestStats.requestsByProvider[provider] ?: 0) + 1;
                }
                lock {
                    tokenStats.totalInputTokens += response.usage.prompt_tokens;
                    tokenStats.totalOutputTokens += response.usage.completion_tokens;
                    tokenStats.inputTokensByProvider[provider] = (tokenStats.inputTokensByProvider[provider] ?: 0) + response.usage.prompt_tokens;
                    tokenStats.outputTokensByProvider[provider] = (tokenStats.outputTokensByProvider[provider] ?: 0) + response.usage.completion_tokens;
                }
            } else {
                updateErrorStats(provider, response, requestId);
                lock {
                    // Update request stats
                    requestStats.errorsByProvider[provider] = (requestStats.errorsByProvider[provider] ?: 0) + 1;
                    requestStats.totalRequests += 1;
                    requestStats.failedRequests += 1;
                }

                logging:logEvent(vLog, logConf, "ERROR", "gRPC:tryProvider", "Provider request failed", {
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
        logging:logEvent(vLog, logConf, "ERROR", "gRPC:tryProvider", "Provider not configured", {
            requestId: requestId,
            provider: provider
        });

        // Update error stats for provider not configured
        lock {
            // Update total error count
            errorStats.totalErrors += 1;

            // Update errors by type
            errorStats.errorsByType["configuration"] = (errorStats.errorsByType["configuration"] ?: 0) + 1;

            // Add to recent errors
            analytics:ErrorEntry newError = {
                timestamp: time:utcNow()[0],
                provider: provider,
                message: errorMessage,
                'type: "configuration",
                requestId: requestId
            };

            if errorStats.recentErrors.length() >= 10 {
                errorStats.recentErrors = errorStats.recentErrors.slice(1);
            }
            errorStats.recentErrors.push(newError.toString());

        }
        lock {

            // Update request stats
            requestStats.totalRequests += 1;
            requestStats.failedRequests += 1;
        }

        return error(errorMessage);
    }
}

public isolated function handleOpenAIRequest(http:Client openaiClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if openAIConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "openai", "OpenAI not configured", {requestId});
        return error("OpenAI is not configured");
    }
    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        return error("Invalid request");
    }
    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    // Transform to OpenAI format
    json openAIPayload = {
        "model": openAIConfig?.model,
        "messages": [
            {
                "role": "system",
                "content": reqSystemPrompt + " " + sysPrompt
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000
    };

    if openAIConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + (openAIConfig?.apiKey ?: "") };

        logging:logEvent(vLog, logConf, "DEBUG", "openai", "Sending request to OpenAI", {
            requestId,
            model: openAIConfig?.model ?: "",
            promptLength: reqUserPrompt.length()
        });

        http:Response|error response = openaiClient->post("/v1/chat/completions", openAIPayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "openai", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "OpenAI API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "openai", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
            }
            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "openai", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:OpenAIResponse|error openAIResponse = responsePayload.cloneWithType(llms:OpenAIResponse);
        if openAIResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "openai", "Response type conversion failed", {
                requestId,
                'error: openAIResponse.message() + ":" + openAIResponse.detail().toString()
            });
            return openAIResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, openAIResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: openAIResponse.model,
            system_fingerprint: (),
            choices: [{
                index: openAIResponse.choices[0].index,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: openAIResponse.choices[0].finish_reason ?: "stop"
            }],
            usage: {
                prompt_tokens: openAIResponse.usage.prompt_tokens,
                completion_tokens: openAIResponse.usage.completion_tokens,
                total_tokens: openAIResponse.usage.prompt_tokens + openAIResponse.usage.completion_tokens
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "openai", "Invalid API key configuration", {requestId});
        return error("OpenAI configuration is invalid");
    }
}

public isolated function handleOllamaRequest(http:Client ollamaClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if ollamaConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "ollama", "Ollama not configured", {requestId});
        return error("Ollama is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent(vLog, logConf, "ERROR", "ollama", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    json ollamaPayload = {
        "model": ollamaConfig?.model,
        "messages": [
            {
                "role": "system",
                "content": reqSystemPrompt + " " + sysPrompt
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "stream": false
    };

    logging:logEvent(vLog, logConf, "DEBUG", "ollama", "Sending request to Ollama", {
        requestId,
        model: ollamaConfig?.model ?: "",
        promptLength: reqUserPrompt.length()
    });

    if ollamaConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + (ollamaConfig?.apiKey ?: "") };

        http:Response|error response = ollamaClient->post("/api/chat", ollamaPayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "ollama", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            int statusCode = check (check response.ensureType(json)).status;
            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Ollama API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "ollama", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
        }


            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "ollama", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:OllamaResponse|error ollamaResponse = responsePayload.cloneWithType(llms:OllamaResponse);
        if ollamaResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "ollama", "Response type conversion failed", {
                requestId,
                'error: ollamaResponse.message() + ":" + ollamaResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return ollamaResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, ollamaResponse.message.content);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent(vLog, logConf, "INFO", "ollama", "Request successful", {
            requestId,
            model: ollamaResponse.model,
            promptTokens: ollamaResponse.prompt_eval_count,
            completionTokens: ollamaResponse.eval_count
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: ollamaResponse.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: ollamaResponse.done_reason
            }],
            usage: {
                prompt_tokens: ollamaResponse.prompt_eval_count,
                completion_tokens: ollamaResponse.eval_count,
                total_tokens: ollamaResponse.prompt_eval_count + ollamaResponse.eval_count
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "ollama", "Invalid API key configuration", {requestId});
        return error("Ollama configuration is invalid");
    }
}

public isolated function handleAnthropicRequest(http:Client anthropicClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if anthropicConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "anthropic", "Anthropic not configured", {requestId});
        return error("Anthropic is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent(vLog, logConf, "ERROR", "anthropic", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    json anthropicPayload = {
        "model": anthropicConfig?.model,
        "messages": [
            {
                "role": "system",
                "content": reqSystemPrompt + " " + sysPrompt
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "max_tokens": req.maxTokens ?: 1000,
        "temperature": req.temperature ?: 0.7
    };

    logging:logEvent(vLog, logConf, "DEBUG", "anthropic", "Sending request to Anthropic", {
        requestId,
        model: anthropicConfig?.model ?: "",
        promptLength: reqUserPrompt.length()
    });

    if anthropicConfig?.apiKey != "" {
        map<string|string[]> headers = {
            "Authorization": "Bearer " + (anthropicConfig?.apiKey ?: ""),
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        };

        http:Response|error response = anthropicClient->post("/v1/messages", anthropicPayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "anthropic", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Anthropic API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "anthropic", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
            }

            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "anthropic", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:AnthropicResponse|error anthropicResponse = responsePayload.cloneWithType(llms:AnthropicResponse);
        if anthropicResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "anthropic", "Response type conversion failed", {
                requestId,
                'error: anthropicResponse.message() + ":" + anthropicResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return anthropicResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, anthropicResponse.contents.content[0].text);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent(vLog, logConf, "INFO", "anthropic", "Request successful", {
            requestId,
            model: anthropicResponse.model,
            // Include token usage info when available
            usage: {
                input: anthropicResponse.usage.input_tokens,
                output: anthropicResponse.usage.output_tokens
            }
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: anthropicResponse.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: anthropicResponse.role,
                    content: guardedText
                },
                finish_reason: anthropicResponse.stop_reason
            }],
            usage: {
                prompt_tokens: anthropicResponse.usage.input_tokens,
                completion_tokens: anthropicResponse.usage.output_tokens,
                total_tokens: (anthropicResponse.usage?.input_tokens) + (anthropicResponse.usage?.output_tokens)
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "anthropic", "Invalid API key configuration", {requestId});
        return error("Anthropic configuration is invalid");
    }
}

public isolated function handleGeminiRequest(http:Client geminiClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if geminiConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "gemini", "Gemini not configured", {requestId});
        return error("Gemini is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent(vLog, logConf, "ERROR", "gemini", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    json geminiPayload = {
        "model": geminiConfig?.model,
        "messages": [
            {
                "role": "system",
                "content": reqSystemPrompt + " " + sysPrompt
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000
    };

    logging:logEvent(vLog, logConf, "DEBUG", "gemini", "Sending request to Gemini", {
        requestId,
        model: geminiConfig?.model ?: "",
        promptLength: reqUserPrompt.length()
    });

    if geminiConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + (geminiConfig?.apiKey ?: "") };

        http:Response|error response = geminiClient->post(":chatCompletions", geminiPayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "gemini", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Gemini API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "gemini", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
            }

            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "gemini", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:OpenAIResponse|error geminiResponse = responsePayload.cloneWithType(llms:OpenAIResponse);
        if geminiResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "gemini", "Response type conversion failed", {
                requestId,
                'error: geminiResponse.message() + ":" + geminiResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return geminiResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, geminiResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent(vLog, logConf, "INFO", "gemini", "Request successful", {
            requestId,
            model: geminiResponse.model
            // Gemini doesn't always provide token usage info
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: geminiResponse.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: geminiResponse.choices[0].message.role,
                    content: guardedText
                },
                finish_reason: geminiResponse.choices[0].finish_reason ?: "stop"
            }],
            usage: {
                prompt_tokens: geminiResponse.usage.prompt_tokens,
                completion_tokens: geminiResponse.usage.completion_tokens,
                total_tokens: (geminiResponse.usage.prompt_tokens) + (geminiResponse.usage.completion_tokens)
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "gemini", "Invalid API key configuration", {requestId});
        return error("Gemini configuration is invalid");
    }
}

public isolated function handleMistralRequest(http:Client mistralClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if mistralConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "mistral", "Mistral not configured", {requestId});
        return error("Mistral is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent(vLog, logConf, "ERROR", "mistral", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    json mistralPayload = {
        "model": mistralConfig?.model,
        "messages": [
            {
                "role": "system",
                "content": reqSystemPrompt + " " + sysPrompt
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000
    };

    logging:logEvent(vLog, logConf, "DEBUG", "mistral", "Sending request to Mistral", {
        requestId,
        model: mistralConfig?.model ?: "",
        promptLength: reqUserPrompt.length()
    });

    if mistralConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + (mistralConfig?.apiKey ?: "") };

        http:Response|error response = mistralClient->post("/v1/chat/completions", mistralPayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "mistral", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Mistral API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "mistral", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
            }
            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "mistral", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:OpenAIResponse|error mistralResponse = responsePayload.cloneWithType(llms:OpenAIResponse);
        if mistralResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "mistral", "Response type conversion failed", {
                requestId,
                'error: mistralResponse.message() + ":" + mistralResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return mistralResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, mistralResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent(vLog, logConf, "INFO", "mistral", "Request successful", {
            requestId,
            model: mistralResponse.model,
            usage: {
                input: mistralResponse.usage.prompt_tokens,
                output: mistralResponse.usage.completion_tokens
            }
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: mistralResponse.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: mistralResponse.choices[0].finish_reason ?: "stop"
            }],
            usage: {
                prompt_tokens: mistralResponse.usage.prompt_tokens,
                completion_tokens: mistralResponse.usage.completion_tokens,
                total_tokens: (mistralResponse.usage.prompt_tokens) + (mistralResponse.usage.completion_tokens)
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "mistral", "Invalid API key configuration", {requestId});
        return error("Mistral configuration is invalid");
    }
}

public isolated function handleCohereRequest(http:Client cohereClient, llms:LLMRequest req) returns llms:LLMResponse|error {
    string requestId = uuid:createType1AsString();
    boolean vLog = false;
    logging:LoggingConfig logConf;
    string sysPrompt = "";
    guardrails:GuardrailConfig localGuardrails;
    lock { vLog = isVerboseLogging; }
    lock { logConf = loggingConfig.cloneReadOnly(); }
    lock { sysPrompt = systemPrompt; }
    lock { localGuardrails = guardrails.cloneReadOnly(); }

    if cohereConfig == () {
        logging:logEvent(vLog, logConf, "ERROR", "cohere", "Cohere not configured", {requestId});
        return error("Cohere is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent(vLog, logConf, "ERROR", "cohere", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    string cohereSystemPrompt = reqSystemPrompt;
    if (sysPrompt != "") {
        cohereSystemPrompt = reqSystemPrompt + " " + sysPrompt;
    }

    json coherePayload = {
        "message": reqUserPrompt,
        "chat_history": [{
            "role": "USER",
            "message": reqUserPrompt
        },
        {
            "role": "SYSTEM",
            "message": cohereSystemPrompt
        }],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000,
        "model": cohereConfig?.model,
        "preamble": "You are an AI-assistant chatbot. You are trained to assist users by providing thorough and helpful responses to their queries."
    };

    logging:logEvent(vLog, logConf, "DEBUG", "cohere", "Sending request to Cohere", {
        requestId,
        model: cohereConfig?.model ?: "",
        promptLength: reqUserPrompt.length()
    });

    if cohereConfig?.apiKey != "" {
        map<string|string[]> headers = {
            "Authorization": "Bearer " + (cohereConfig?.apiKey ?: ""),
            "Content-Type": "application/json",
            "Accept": "application/json"
        };

        http:Response|error response = cohereClient->post("/v1/chat", coherePayload, headers);

        if response is error {
            logging:logEvent(vLog, logConf, "ERROR", "cohere", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Cohere API error: HTTP " + statusCode.toString();

                logging:logEvent(vLog, logConf, "ERROR", "cohere", "API error response", {
                    requestId,
                    statusCode: statusCode,
                    response: errorBody
                });

                return error(errorMessage, statusCode = statusCode, body = errorBody);
            }
            return response;
        }

        json|error responsePayload = response.getJsonPayload();
        if responsePayload is error {
            logging:logEvent(vLog, logConf, "ERROR", "cohere", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        llms:CohereResponse|error cohereResponse = responsePayload.cloneWithType(llms:CohereResponse);
        if cohereResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "cohere", "Response type conversion failed", {
                requestId,
                'error: cohereResponse.message() + ":" + cohereResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return cohereResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(localGuardrails, cohereResponse.text);
        if guardedText is error {
            logging:logEvent(vLog, logConf, "ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent(vLog, logConf, "INFO", "cohere", "Request successful", {
            requestId,
            model: cohereConfig?.model ?: "",
            usage: {
                input: cohereResponse.meta.tokens.input_tokens,
                output: cohereResponse.meta.tokens.output_tokens
            }
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: cohereConfig?.model ?: "",
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: "stop"
            }],
            usage: {
                prompt_tokens: cohereResponse.meta.tokens.input_tokens,
                completion_tokens: cohereResponse.meta.tokens.output_tokens,
                total_tokens: cohereResponse.meta.tokens.input_tokens + cohereResponse.meta.tokens.output_tokens
            }
        };
    } else {
        logging:logEvent(vLog, logConf, "ERROR", "cohere", "Invalid API key configuration", {requestId});
        return error("Cohere configuration is invalid");
    }
}

service class ResponseInterceptor {
    *http:ResponseInterceptor;

    remote function interceptResponse(http:RequestContext ctx, http:Response res) returns http:NextService|error? {
        res.setHeader("Server", "ai-gateway/v1.1.0");
        return ctx.next();
    }
}

// Add request interceptor for cache handling
service class RequestInterceptor {
    *http:RequestInterceptor;

    resource function 'default[string... path](http:RequestContext ctx, http:Request req) returns http:NextService|http:Response|error? {
        // Only intercept POST requests to chat completions endpoint
        // if req.method != "POST" || !req.rawPath.startsWith("/v1/chat/completions") {
        //     return ctx.next();
        // }

        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        // Check Cache-Control header
        string|http:HeaderNotFoundError cacheControl = req.getHeader("Cache-Control");
        if cacheControl is string && cacheControl == "no-cache" {
            return ctx.next();
        }

        // Get provider and payload
        string|http:HeaderNotFoundError provider = req.getHeader("x-llm-provider");
        if provider is http:HeaderNotFoundError {
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
                logging:logEvent(vLog, logConf, "INFO", "cache", "Cache hit", {
                    cacheKey: cacheKey
                });

                // Update cache stats
                lock {
                    requestStats.totalRequests += 1;
                    requestStats.cacheHits += 1;
                    requestStats.requestsByProvider[provider] = (requestStats.requestsByProvider[provider] ?: 0) + 1;
                }
                lock {
                   tokenStats.totalInputTokens += entry.response.usage.prompt_tokens;
                    tokenStats.totalOutputTokens += entry.response.usage.completion_tokens;
                    tokenStats.inputTokensByProvider[provider] = (tokenStats.inputTokensByProvider[provider] ?: 0) + entry.response.usage.prompt_tokens;
                    tokenStats.outputTokensByProvider[provider] = (tokenStats.outputTokensByProvider[provider] ?: 0) + entry.response.usage.completion_tokens;
                }

                // Set cached response
                http:Response cachedResponse = new;
                cachedResponse.setPayload(entry.response);
                return  cachedResponse;
            } else {
                logging:logEvent(vLog, logConf, "DEBUG", "cache", "Cache entry expired", {
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
            logging:logEvent(vLog, logConf, "DEBUG", "cache", "Cache miss", {
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

// Add helper function to generate cache key
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

isolated function updateErrorStats(string provider, error llmResponse, string requestId) {
            // Ensure we've updated the error stats for the final error
            // string errorType = "unknown";
            // string errorMessage = llmResponse.message();

            HttpResponseError|http:ClientConnectorError|error httpError = llmResponse.ensureType(HttpResponseError);
            string errorType;
            string errorMessage;

            if httpError is HttpResponseError {
                errorType = httpError.status;
                errorMessage = httpError.message;
            } else if httpError is http:ClientConnectorError {
                errorType = httpError.message();
                errorMessage = httpError.detail().toString();
            } else {
                errorType = "unknown";
                errorMessage = llmResponse.message();
            }

            // Final error stats update for the client-facing error
            lock {
                // Update errors by type (grouped by status code)
                errorStats.errorsByType[errorType] = (errorStats.errorsByType[errorType] ?: 0) + 1;

                // Add to recent errors as the final client-facing error
                analytics:ErrorEntry newError = {
                    timestamp: time:utcNow()[0],
                    provider: "all-providers", // Indicate all providers failed
                    message: errorMessage,
                    'type: errorType,
                    requestId: requestId
                };

                if errorStats.recentErrors.length() >= 10 {
                    errorStats.recentErrors = errorStats.recentErrors.slice(1);
                }
                errorStats.recentErrors.push(newError.toString());
            }
}

// Update service to use both interceptors
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

    isolated function init() returns error? {
        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        logging:logEvent(vLog, logConf, "INFO", "HTTP:init", "Initializing AI Gateway");

        // Read initial logging configuration
        lock { loggingConfig = defaultLoggingConfig; }
        logging:logEvent(vLog, logConf, "DEBUG", "HTTP:init", "Loaded logging configuration", <map<json>>logConf.toJson());

        // Check if at least one provider is configured
        if openAIConfig == () && anthropicConfig == () && geminiConfig == () && ollamaConfig == () && mistralConfig == () && cohereConfig == () {
            logging:logEvent(vLog, logConf, "ERROR", "HTTP:init", "No LLM providers configured");
            return error("At least one LLM provider must be configured");
        }

        if openAIConfig?.endpoint != () {
            string endpoint = openAIConfig?.endpoint ?: "";
            if (endpoint == "") {
                logging:logEvent(vLog, logConf, "ERROR", "HTTP:init", "Invalid OpenAI configuration", {"error": "Empty endpoint"});
                return error("OpenAI endpoint is required");
            } else {
                self.openaiClient = check new (endpoint);
                logging:logEvent(vLog, logConf, "INFO", "HTTP:init", "OpenAI client initialized", {"endpoint": endpoint});
            }
        }
        if anthropicConfig?.endpoint != () {
            string endpoint = anthropicConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Anthropic endpoint is required");
            } else {
                self.anthropicClient = check new (endpoint);
            }
        }
        if geminiConfig?.endpoint != () {
            string endpoint = geminiConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Gemini endpoint is required");
            } else {
                self.geminiClient = check new (endpoint);
            }
        }
        if ollamaConfig?.endpoint != () {
            string endpoint = ollamaConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Ollama endpoint is required");
            } else {
                self.ollamaClient = check new (endpoint, { timeout: 60 });
            }
        }
        if mistralConfig?.endpoint != () {
            string endpoint = mistralConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Mistral endpoint is required");
            } else {
                self.mistralClient = check new (endpoint);
            }
        }
        if cohereConfig?.endpoint != () {
            string endpoint = cohereConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("Cohere endpoint is required");
            } else {
                self.cohereClient = check new (endpoint);
            }
        }
        logging:logEvent(vLog, logConf, "INFO", "HTTP:init", "AI Gateway initialization complete", {
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

    isolated resource function post v1/chat/completions(
            @http:Header {name: "x-llm-provider"} string llmProvider,
            @http:Payload llms:LLMRequest payload,
            http:Request request,
            http:RequestContext ctx) returns error|http:Response|llms:LLMResponse {
        string|http:HeaderNotFoundError forwardedHeader = request.getHeader("X-Forwarded-For");

        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        // TODO: Use the client IP address from the request
        string clientIP = "";
        if forwardedHeader is string {
            clientIP = forwardedHeader;
        }
        // string clientIP = request.getHeader("X-Forwarded-For") ?: request.remoteAddress;

        // Check rate limit
        // [boolean allowed, int limit, int remaining, int reset] = check checkRateLimit(clientIP);
        [boolean, int, int, int] rateLimitResponse = check checkRateLimit(clientIP);
        boolean allowed = rateLimitResponse[0];
        int rateLimit = rateLimitResponse[1];
        int remaining = rateLimitResponse[2];
        int reset = rateLimitResponse[3];

        http:Response response = new;
        if !allowed {
            response.statusCode = 429; // Too Many Requests
            response.setPayload({
                'error: "Rate limit exceeded",
                'limit: rateLimit,
                remaining: remaining,
                reset: reset
            });
            return response;
        }

        [string, string]|error prompts = getPrompts(payload);
        if prompts is error {
            response.statusCode = 400; // Bad Request
            response.setPayload({
                'error: prompts.message()
            });
            return response;
        }

        string requestId = uuid:createType1AsString();
        logging:logEvent(vLog, logConf, "INFO", "chat", "Received chat request", {
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
            logging:logEvent(vLog, logConf, "WARN", "failover", "Primary provider failed", {
                requestId: requestId,
                provider: llmProvider,
                'error: llmResponse.message() + ":" + llmResponse.detail().toString()
            });
            updateErrorStats(llmProvider, llmResponse, requestId);

            // Try other providers
            foreach string provider in availableProviders {
                if provider != llmProvider {
                    logging:logEvent(vLog, logConf, "INFO", "failover", "Attempting failover", {
                        requestId: requestId,
                        provider: provider
                    });

                    llms:LLMResponse|error failoverResponse = self.tryProvider(provider, payload.cloneReadOnly());
                    if failoverResponse !is error {
                        logging:logEvent(vLog, logConf, "INFO", "failover", "Failover successful", {
                            requestId: requestId,
                            provider: provider
                        });
                        llmResponse = failoverResponse;
                        break;
                    }
                    logging:logEvent(vLog, logConf, "WARN", "failover", "Failover attempt failed", {
                        requestId: requestId,
                        provider: provider,
                        'error: failoverResponse.message() + ":" + failoverResponse.detail().toString()
                    });
                }
            }
        }

        if llmResponse is error {
            logging:logEvent(vLog, logConf, "ERROR", "chat", "All providers failed", {
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

            logging:logEvent(vLog, logConf, "DEBUG", "cache", "Cached response", {
                cacheKey: cacheKey
            });
        }

        // Add rate limit headers to response context

        RateLimitPlan? rLimitP;
        lock {
            rLimitP = currentRateLimitPlan.cloneReadOnly();
        }
        if rLimitP != () {
            response.setHeader("RateLimit-Limit", rateLimit.toString());
            response.setHeader("RateLimit-Remaining", remaining.toString());
            response.setHeader("RateLimit-Reset", reset.toString());
        }
        response.setPayload(llmResponse);
        return response;
    }

        // This function handles all requests to the /services/{serviceName} path
    isolated resource function 'default [string serviceName]/[string... path](
        http:Request req,
        http:RequestContext ctx) returns http:Response|error {

        string requestId = uuid:createType1AsString();

        string routeName = path[0];

        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        map<ServiceRoute> localRoutes;
        lock {
            localRoutes = serviceRoutes.cloneReadOnly();
        }

        // Check if the service exists
        if !localRoutes.hasKey(routeName) {
            logging:logEvent(vLog, logConf, "ERROR", "apigateway", "Service not found", {
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
            logging:logEvent(vLog, logConf, "ERROR", "apigateway", "Service not found", {
                requestId: requestId,
                serviceName: routeName
            });
            return error("Service not found");
        }

        RateLimitPlan? rLimitP;
        lock {
            rLimitP = currentRateLimitPlan.cloneReadOnly();
        }
        // Check rate limits if enabled for this route
        if route.enableRateLimit && rLimitP != () {
            string|http:HeaderNotFoundError clientIP = req.getHeader("X-Forwarded-For");
            if clientIP is string {
            // [boolean allowed, int limit, int remaining, int reset] = check checkRateLimit(clientIP);
                [boolean, int, int, int] rateLimitRespones = check checkRateLimit(clientIP);
                boolean allowed = rateLimitRespones[0];
                int 'limit = rateLimitRespones[1];
                int remaining = rateLimitRespones[2];
                int reset = rateLimitRespones[3];

                if !allowed {
                    logging:logEvent(vLog, logConf, "WARN", "apigateway", "Rate limit exceeded", {
                        requestId: requestId,
                        serviceName: routeName,
                        clientIP: clientIP
                    });
                    http:Response res = new;
                    res.statusCode = 429;
                    res.setHeader("RateLimit-Limit", 'limit.toString());
                    res.setHeader("RateLimit-Remaining", remaining.toString());
                    res.setHeader("RateLimit-Reset", reset.toString());
                    res.setPayload({ 'error: "Rate limit exceeded" });
                    return res;
                }
            } else {
                // log
                logging:logEvent(vLog, logConf, "WARN", "apigateway", "X-Forwarded-For header not found", {
                    requestId: requestId,
                    serviceName: routeName
                });
            }
        }

        // Check cache if enabled for this route and it's a GET request
        string cacheKey = "";
        if route.enableCache && req.method == "GET" {
            // Skip cache if Cache-Control: no-cache is set
            string|http:HeaderNotFoundError cacheControl = req.getHeader("Cache-Control");
            if !(cacheControl is string && cacheControl == "no-cache") {
                // Generate cache key based on service name, path and query params
                string pathStr = "/" + string:'join("/", ...path);
                string queryStr = req.getQueryParams().toString();
                cacheKey = crypto:hashSha1((serviceName + pathStr + queryStr).toBytes()).toBase16();

                // Check if response is in cache
                boolean inCache = false;
                lock {
                    inCache = promptCache.hasKey(cacheKey);
                }
                if inCache {
                    CacheEntry entry;
                    lock {
                        entry = promptCache.cloneReadOnly().get(cacheKey);
                    }
                    int currentTime = time:utcNow()[0];

                    if (currentTime - entry.timestamp < cacheTTLSeconds) {
                        logging:logEvent(vLog, logConf, "INFO", "apigateway", "Cache hit", {
                            requestId: requestId,
                            serviceName: serviceName,
                            cacheKey: cacheKey
                        });

                        // Update stats
                        lock {
                            requestStats.totalRequests += 1;
                            requestStats.cacheHits += 1;
                        }

                        http:Response res = new;
                        res.setPayload(entry.response);
                        return res;
                    } else {
                        // Remove expired entry
                        lock {
                            _ = promptCache.remove(cacheKey);
                        }
                        // Record a cache miss for expired entries
                        lock {
                            requestStats.cacheMisses += 1;
                        }
                    }
                } else {
                    // Record a cache miss when key doesn't exist
                    lock {
                        requestStats.cacheMisses += 1;
                    }
                    logging:logEvent(vLog, logConf, "DEBUG", "apigateway", "Cache miss", {
                        requestId: requestId,
                        serviceName: serviceName,
                        cacheKey: cacheKey
                    });
                }
            }
        }

        // Create client for backend service
        http:Client|error backendClient = new (route.endpoint);
        if backendClient is error {
            logging:logEvent(vLog, logConf, "ERROR", "apigateway", "Failed to create backend client", {
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

        logging:logEvent(vLog, logConf, "INFO", "apigateway", "Forwarding request", {
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
            logging:logEvent(vLog, logConf, "ERROR", "apigateway", "Backend request failed", {
                requestId: requestId,
                serviceName: routeName,
                'error: response.message()
            });
            return response;
        }

        // Update stats
        // lock {
        //     requestStats.totalRequests += 1;
        //     requestStats.successfulRequests += 1;
        // }

        return response;
    }

    // isolated var llmHandelers;

    // Helper function to try a specific provider
    private isolated function tryProvider(string provider, llms:LLMRequest & readonly payload) returns llms:LLMResponse|error {
        string requestId = uuid:createType1AsString();
        boolean vLog = false;
        logging:LoggingConfig logConf;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        logging:logEvent(vLog, logConf, "DEBUG", "provider", "Attempting provider request", {
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
            "openai": handleOpenAIRequest,
            "anthropic": handleAnthropicRequest,
            "gemini": handleGeminiRequest,
            "ollama": handleOllamaRequest,
            "mistral": handleMistralRequest,
            "cohere": handleCohereRequest
        };

        final http:Client? llmClient = clientMap[provider];
        final var handler = handlerMap[provider];

        if llmClient is http:Client && handler is function {
            llms:LLMResponse|error response = handler(llmClient, payload);
            if response is llms:LLMResponse {
                logging:logEvent(vLog, logConf, "INFO", "provider", "Provider request successful", {
                    requestId: requestId,
                    provider: provider,
                    model: response.model,
                    tokens: {
                        input: response.usage.prompt_tokens,
                        output: response.usage.completion_tokens
                    }
                });
                // Update stats for successful request
                lock {
                    requestStats.totalRequests += 1;
                    requestStats.successfulRequests += 1;
                    requestStats.requestsByProvider[provider] = (requestStats.requestsByProvider[provider] ?: 0) + 1;
                }
                lock {
                    tokenStats.totalInputTokens += response.usage.prompt_tokens;
                    tokenStats.totalOutputTokens += response.usage.completion_tokens;
                    tokenStats.inputTokensByProvider[provider] = (tokenStats.inputTokensByProvider[provider] ?: 0) + response.usage.prompt_tokens;
                    tokenStats.outputTokensByProvider[provider] = (tokenStats.outputTokensByProvider[provider] ?: 0) + response.usage.completion_tokens;
                }
            } else {
                updateErrorStats(provider, response, requestId);
                lock {
                    // Update request stats
                    requestStats.totalRequests += 1;
                    requestStats.failedRequests += 1;
                    // Update errors by provider
                    requestStats.errorsByProvider[provider] = (requestStats.errorsByProvider[provider] ?: 0) + 1;
                }

                logging:logEvent(vLog, logConf, "ERROR", "provider", "Provider request failed", {
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
        logging:logEvent(vLog, logConf, "ERROR", "provider", "Provider not configured", {
            requestId: requestId,
            provider: provider
        });

        // Update error stats for provider not configured
        lock {
            // Update total error count
            errorStats.totalErrors += 1;

            // Update errors by type
            errorStats.errorsByType["configuration"] = (errorStats.errorsByType["configuration"] ?: 0) + 1;

            // Add to recent errors
            analytics:ErrorEntry newError = {
                timestamp: time:utcNow()[0],
                provider: provider,
                message: errorMessage,
                'type: "configuration",
                requestId: requestId
            };

            if errorStats.recentErrors.length() >= 10 {
                errorStats.recentErrors = errorStats.recentErrors.slice(1);
            }
            errorStats.recentErrors.push(newError.toString());

        }
        lock {
            // Update request stats
            requestStats.totalRequests += 1;
            requestStats.failedRequests += 1;
        }
        return error(errorMessage);
    }
}

isolated function getPrompts(llms:LLMRequest llmRequest) returns [string, string]|error {
    string systemPrompt = "";
    string userPrompt = "";
    llms:LLMRequestMessage[] messages = llmRequest.messages;
    if messages.length() == 1 { // If it's only one here, expecting only user prompt
        if messages[0].content == "" {
            return error("User prompt is required");
        } else {
            userPrompt = messages[0].content;
        }
    } else if messages.length() == 2 { // If it's two here, expecting system and user prompt
        // find the user prompt
        foreach llms:LLMRequestMessage message in messages {
            if message.role == "user" {
                if message.content == "" {
                    return error("User prompt is required");
                } else {
                    userPrompt = message.content;
                }
            }
            if message.role == "system" {
                systemPrompt = message.content;
            }
        }
    } else {
        // What is this?!
        return error("Invalid request");
    }

    return [systemPrompt, userPrompt];
}

// Add new admin service
isolated service http:InterceptableService /admin on new http:Listener(8081) {
    // Template HTML for analytics
    private string statsTemplate = "";

    public function createInterceptors() returns ResponseInterceptor {
        return new ResponseInterceptor();
    }

    isolated function init() returns error? {
        self.statsTemplate = check io:fileReadString("resources/stats.html");
    }
    isolated resource function post systemprompt(@http:Payload llms:SystemPromptConfig config) returns string|error {
        lock { systemPrompt = config.prompt; }
        return "System prompt updated successfully";
    }

    resource function get systemprompt() returns llms:SystemPromptConfig {
        lock {
            return {
                prompt: systemPrompt
            };
        }
    }

    // Add guardrails endpoints
    resource function post guardrails(@http:Payload guardrails:GuardrailConfig config) returns string|error {
        lock {
            guardrails = config.cloneReadOnly();
        }
        return "Guardrails updated successfully";
    }

    resource function get guardrails() returns guardrails:GuardrailConfig {
        lock {
            return guardrails.cloneReadOnly();
        }
    }

    // Add cache management endpoints
    resource function delete cache() returns string {
        lock {
            promptCache = {};
        }
        return "Cache cleared successfully";
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
    isolated resource function post logging(@http:Payload logging:LoggingConfig logConfig) returns string|error {
        lock {
            loggingConfig = <logging:LoggingConfig & readonly>logConfig;
        }
        return "Logging configuration updated successfully";
    }

    isolated resource function get logging() returns logging:LoggingConfig {
        lock {
            return loggingConfig.cloneReadOnly();
        }
    }

    // Add verbose logging toggle
    // resource function post verbose(@http:Payload boolean enabled) returns string {
    //     isVerboseLogging = enabled;
    //     logEvent("INFO", "admin", "Verbose logging " + (enabled ? "enabled" : "disabled"));
    //     return "Verbose logging " + (enabled ? "enabled" : "disabled");
    // }

    // resource function get verbose() returns boolean {
    //     return isVerboseLogging;
    // }

    // Get current rate limit plan
    isolated resource function get ratelimit() returns json? {
        lock {
            if currentRateLimitPlan == () {
                return {};
            }
            return currentRateLimitPlan.cloneReadOnly();
        }
    }

    // Update rate limit plan
    isolated resource function post ratelimit(@http:Payload RateLimitPlan payload) returns string|error {
        lock {
            currentRateLimitPlan = payload.cloneReadOnly();
        }
        // Clear existing states when plan changes
        lock {
            rateLimitStates = {};
        }
        logging:LoggingConfig logConf;
        boolean vLog = false;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }
        logging:logEvent(vLog.cloneReadOnly(), logConf.cloneReadOnly(), "INFO", "admin", "Rate limit plan updated", {
            plan: payload.toString()
        });

        return "Rate limit plan updated successfully";
    }

    // Remove rate limiting
    isolated resource function delete ratelimit() returns string {
        lock {
            currentRateLimitPlan = ();
        }
        lock {
            rateLimitStates = {};
        }
        logging:LoggingConfig logConf;
        boolean vLog = false;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }
        logging:logEvent(vLog, logConf, "INFO", "admin", "Rate limiting disabled");

        return "Rate limiting disabled";
    }

    // Get current rate limit states (for debugging)
    isolated resource function get ratelimit/states() returns map<RateLimitState> {
        lock {
            return rateLimitStates.cloneReadOnly();
        }
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
                recent: eStats.recentErrors,
                byType: eStats.errorsByType
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

        logging:LoggingConfig logConf;
        boolean vLog = false;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        logging:logEvent(vLog, logConf, "INFO", "admin", "Service route configured", {
            name: payload.name,
            endpoint: payload.endpoint,
            enableCache: payload.enableCache,
            enableRateLimit: payload.enableRateLimit
        });

        return "Service route configured successfully: " + payload.name;
    }

    // Delete a route
    isolated resource function delete routes/[string name]() returns string|error {
        logging:LoggingConfig logConf;
        boolean vLog = false;
        lock { vLog = isVerboseLogging; }
        lock { logConf = loggingConfig.cloneReadOnly(); }

        lock {
            if serviceRoutes.hasKey(name) {
                _ = serviceRoutes.remove(name);
                logging:logEvent(vLog, logConf.cloneReadOnly(), "INFO", "admin", "Service route deleted", {
                    name: name
                });
                return "Service route deleted successfully: " + name;
            }
        }
        return error("Service route not found: " + name);
    }
}
