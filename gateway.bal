import ballerina/io;
import ballerina/http;
import ballerina/log;
import ai_gateway.llms;
import ai_gateway.analytics;

configurable llms:OpenAIConfig? & readonly openAIConfig = ();
configurable llms:AnthropicConfig? & readonly anthropicConfig = ();
configurable llms:GeminiConfig? & readonly geminiConfig = ();
configurable llms:OllamaConfig? & readonly ollamaConfig = ();

// Add system prompt storage
string systemPrompt = "";

// Add guardrails configuration type
type GuardrailConfig record {
    string[] bannedPhrases;
    int minLength;
    int maxLength;
    boolean requireDisclaimer;
    string disclaimer?;
};

// Add guardrails storage
GuardrailConfig guardrails = {
    bannedPhrases: [],
    minLength: 0,
    maxLength: 500000,
    requireDisclaimer: false
};

// Add guardrails processing function
function applyGuardrails(string text) returns string|error {
    if (text.length() < guardrails.minLength) {
        return error("Response too short. Minimum length: " + guardrails.minLength.toString());
    }
    string textRes = text;
    if (text.length() > guardrails.maxLength) {
        textRes = text.substring(0, guardrails.maxLength);
    }

    foreach string phrase in guardrails.bannedPhrases {
        if (text.toLowerAscii().includes(phrase)) {
            return error("Response contains banned phrase: " + phrase);
        }
    }

    if (guardrails.requireDisclaimer && guardrails.disclaimer != null) {
        textRes = text + "\n\n" + (guardrails.disclaimer ?: "");
    }

    return textRes;
}

service / on new http:Listener(8080) {
    private http:Client? openaiClient = ();
    private http:Client? anthropicClient = ();
    private http:Client? geminiClient = ();
    private http:Client? ollamaClient = ();

    function init() returns error? {
        // Check if at least one provider is configured
        if openAIConfig == () && anthropicConfig == () && geminiConfig == () && ollamaConfig == () {
            return error("At least one LLM provider must be configured");
        }

        if openAIConfig?.endpoint != () {
            string endpoint = openAIConfig?.endpoint ?: "";
            if (endpoint == "") {
                return error("OpenAI endpoint is required");
            } else {
                self.openaiClient = check new (endpoint);
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
                self.ollamaClient = check new (endpoint);
            }
        }
    }

    resource function post chat(@http:Header {name: "x-llm-provider"} string llmProvider, @http:Payload llms:LLMRequest payload) returns llms:LLMResponse|error {
        // Update request stats
        lock {
            requestStats.totalRequests += 1;
            requestStats.requestsByProvider[llmProvider] = (requestStats.requestsByProvider[llmProvider] ?: 0) + 1;
        }

        llms:LLMResponse|error response;
        match llmProvider {
            "openai" => {
                if self.openaiClient == () {
                    return error("OpenAI client is not initialized");
                }
                response = self.handleOpenAI(payload);
            }
            "anthropic" => {
                response = self.handleAnthropic(payload);
            }
            "gemini" => {
                response = self.handleGemini(payload);
            }
            "ollama" => {
                response = self.handleOllama(payload);
            }
            _ => {
                response = error("Unsupported LLM provider");
            }
        }

        if response is error {
            lock {
                requestStats.failedRequests += 1;
                requestStats.errorsByProvider[llmProvider] = (requestStats.errorsByProvider[llmProvider] ?: 0) + 1;
                errorStats.totalErrors += 1;
                errorStats.errorsByType[response.message()] = (errorStats.errorsByType[response.message()] ?: 0) + 1;
                errorStats.recentErrors.push(response.message());
                if (errorStats.recentErrors.length() > 10) {
                    _ = errorStats.recentErrors.shift();
                }
            }
            return response;
        }

        lock {
            requestStats.successfulRequests += 1;
            tokenStats.totalInputTokens += response.input_tokens;
            tokenStats.totalOutputTokens += response.output_tokens;
            tokenStats.inputTokensByProvider[llmProvider] = (tokenStats.inputTokensByProvider[llmProvider] ?: 0) + response.input_tokens;
            tokenStats.outputTokensByProvider[llmProvider] = (tokenStats.outputTokensByProvider[llmProvider] ?: 0) + response.output_tokens;
        }

        return response;
    }

    private function handleOpenAI(llms:LLMRequest req) returns llms:LLMResponse|error {
        // check if openAIConfig and openaiClient are not null
        if openAIConfig == () {
            return error("OpenAI is not configured");
        }
        // Transform to OpenAI format
        json openAIPayload = {
            "model": openAIConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "temperature": req.temperature ?: 0.7,
            "max_tokens": req.maxTokens ?: 1000
        };

        http:Client openaiClient = check self.openaiClient.ensureType();
        if openAIConfig is llms:OpenAIConfig && openAIConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (openAIConfig?.apiKey ?: "") };
            http:Response response = check openaiClient->post("/v1/chat/completions", openAIPayload, headers);

            json responsePayload = check response.getJsonPayload();
            llms:OpenAIResponse openAIResponse = check responsePayload.cloneWithType(llms:OpenAIResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(openAIResponse.choices[0].message.content);
            return {
                text: guardedText,
                input_tokens: openAIResponse.usage.prompt_tokens,
                output_tokens: openAIResponse.usage.completion_tokens,
                model: openAIResponse.model,
                provider: "openai"
            };
        } else {
            return error("OpenAI configuration is invalid");
        }
    }

    private function handleOllama(llms:LLMRequest req) returns llms:LLMResponse|error {
        // check if ollamaAIConfig and openaiClient are not null
        if ollamaConfig == () {
            return error("Ollama is not configured");
        }
        // Transform to OpenAI format
        json ollamaPayload = {
            "model": ollamaConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "stream": false
        };

        http:Client ollamaClient = check self.ollamaClient.ensureType();
        if ollamaConfig is llms:OllamaConfig && ollamaConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (ollamaConfig?.apiKey ?: "") };

            http:Response response = check ollamaClient->post("/api/chat", ollamaPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Ollama response: " + responsePayload.toString());
            llms:OllamaResponse ollamaResponse = check responsePayload.cloneWithType(llms:OllamaResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(ollamaResponse.message.content);
            return {
                text: guardedText,
                input_tokens: ollamaResponse.prompt_eval_count,
                output_tokens: ollamaResponse.eval_count,
                model: ollamaResponse.model,
                provider: "ollama"
            };
        } else {
            return error("Ollama configuration is invalid");
        }
    }    

    private function handleAnthropic(llms:LLMRequest req) returns llms:LLMResponse|error {
        if anthropicConfig == () {
            return error("Anthropic is not configured");
        }
        // Transform to Anthropic format
        json anthropicPayload = {
            "model": anthropicConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "max_tokens": req.maxTokens ?: 1000
        };

        http:Client anthropicClient = check self.anthropicClient.ensureType();
        if anthropicConfig is llms:AnthropicConfig && anthropicConfig?.apiKey != "" {
            map<string|string[]> headers = { 
                "Authorization": "Bearer " + (anthropicConfig?.apiKey ?: ""),
                "anthropic-version": "2023-06-01"
            };
            http:Response response = check anthropicClient->post("/v1/messages", anthropicPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Anthropic response: " + responsePayload.toString());
            llms:AnthropicResponse anthropicResponse = check responsePayload.cloneWithType(llms:AnthropicResponse);
            
            // Apply guardrails before returning
            string guardedText = check applyGuardrails(anthropicResponse.contents.content[0].text);
            return {
                text: guardedText,
                input_tokens: anthropicResponse.usage.input_tokens,
                output_tokens: anthropicResponse.usage.output_tokens,
                model: anthropicResponse.model,
                provider: "anthropic"
            };
        } else {
            return error("Anthropic configuration is invalid");
        }
    }

    private function handleGemini(llms:LLMRequest req) returns llms:LLMResponse|error {
        if geminiConfig == () {
            return error("Anthropic is not configured");
        }
        json geminiPayload = {
            "model": geminiConfig?.model,
            "messages": [
                {
                    "role": "system",
                    "content": systemPrompt
                },
                {
                    "role": "user",
                    "content": req.prompt
                }
            ],
            "temperature": req.temperature ?: 0.7,
            "max_tokens": req.maxTokens ?: 1000
        };

        http:Client geminiClient = check self.geminiClient.ensureType();
        if geminiConfig is llms:GeminiConfig && geminiConfig?.apiKey != "" {
            map<string|string[]> headers = { "Authorization": "Bearer " + (geminiConfig?.apiKey ?: "") };

            http:Response response = check geminiClient->post(":chatCompletions", geminiPayload, headers);

            json responsePayload = check response.getJsonPayload();
            log:printInfo("Gemini response: " + responsePayload.toString());
            llms:OpenAIResponse openAIResponse = check responsePayload.cloneWithType(llms:OpenAIResponse);

            // Apply guardrails before returning
            string guardedText = check applyGuardrails(openAIResponse.choices[0].message.content);
            return {
                text: guardedText,
                input_tokens: 0,
                output_tokens: 0,
                model: openAIResponse.model,
                provider: "gemini"
            };
        } else {
            return error("Gemini configuration is invalid");
        }
    }
}

// Analytics storage
analytics:RequestStats requestStats = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    requestsByProvider: {},
    errorsByProvider: {}
};

analytics:TokenStats tokenStats = {
    totalInputTokens: 0,
    totalOutputTokens: 0,
    inputTokensByProvider: {},
    outputTokensByProvider: {}
};

analytics:ErrorStats errorStats = {
    totalErrors: 0,
    errorsByType: {},
    recentErrors: []
};

// Add new admin service
service /admin on new http:Listener(8081) {
    // Template HTML for analytics
    string statsTemplate = "";

    function init() returns error? {
        self.statsTemplate = check io:fileReadString("resources/stats.html");
    }
    resource function post systemprompt(@http:Payload llms:SystemPromptConfig config) returns string|error {
        systemPrompt = config.prompt;
        return "System prompt updated successfully";
    }

    resource function get systemprompt() returns llms:SystemPromptConfig {
        return {
            prompt: systemPrompt
        };
    }

    // Add guardrails endpoints
    resource function post guardrails(@http:Payload GuardrailConfig config) returns string|error {
        guardrails = config;
        return "Guardrails updated successfully";
    }

    resource function get guardrails() returns GuardrailConfig {
        return guardrails;
    }

    resource function get stats() returns http:Response|error {
        string[] requestLabels = [];
        int[] requestData = [];
        int i = 0;
        foreach string ikey in requestStats.requestsByProvider.keys() {
            requestLabels[i] = ikey;
            requestData[i] = requestStats.requestsByProvider[ikey] ?: 0;
            i = i + 1;
        }
        string[] inputTokenLabels = [];
        int[] inputTokenData = [];
        i = 0;
        foreach string ikey in tokenStats.inputTokensByProvider.keys() {
            inputTokenLabels[i] = ikey;
            inputTokenData[i] = tokenStats.inputTokensByProvider[ikey] ?: 0;
            i = i + 1;
        }
        int[] outputTokenData = [];
        i = 0;
        foreach string ikey in tokenStats.outputTokensByProvider.keys() {
            outputTokenData[i] = tokenStats.outputTokensByProvider[ikey] ?: 0;
            i = i + 1;
        }
        string[] errorLabels = [];
        int[] errorData = [];
        i = 0;
        foreach string ikey in errorStats.errorsByType.keys() {
            errorLabels[i] = ikey;
            errorData[i] = errorStats.errorsByType[ikey] ?: 0;
            i = i + 1;
        }

        // Prepare data for template
        map<string> templateValues = {
            "totalRequests": requestStats.totalRequests.toString(),
            "successfulRequests": requestStats.successfulRequests.toString(),
            "failedRequests": requestStats.failedRequests.toString(),
            "totalInputTokens": tokenStats.totalInputTokens.toString(),
            "totalOutputTokens": tokenStats.totalOutputTokens.toString(),
            "totalErrors": errorStats.totalErrors.toString(),
            "recentErrors": "<li>" + string:'join("</li><li>", ...errorStats.recentErrors) + "</li>",
            "requestsLabels": requestLabels.toString(),
            "requestsData": requestData.toString(),
            "tokensLabels": inputTokenLabels.toString(),
            "inputTokensData": inputTokenData.toString(),
            "outputTokensData": outputTokenData.toString(),
            "errorLabels": errorLabels.toString(),
            "errorData": errorData.toString()
        };

        string html = analytics:renderTemplate(self.statsTemplate, templateValues);

        http:Response response = new;
        response.setHeader("Content-Type", "text/html");
        response.setPayload(html);
        return response;
    }
}
