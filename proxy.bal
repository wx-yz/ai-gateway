import ballerina/io;
import ballerina/http;
import ballerina/log;
import ai_gateway.llms;
import ai_gateway.analytics;

configurable llms:OpenAIConfig openAIConfig = ?;
configurable llms:AnthropicConfig anthropicConfig = ?;
configurable llms:GeminiConfig geminiConfig = ?;
configurable llms:OllamaConfig ollamaConfig = ?;

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
    private final http:Client openaiClient;
    private final http:Client anthropicClient;
    private final http:Client geminiClient;
    private final http:Client ollamaClient;

    function init() returns error? {
        self.openaiClient = check new (openAIConfig.endpoint);
        self.anthropicClient = check new (anthropicConfig.endpoint);
        self.geminiClient = check new (geminiConfig.endpoint);
        self.ollamaClient = check new (ollamaConfig.endpoint);
    }

    resource function post chat(@http:Header string llmProvider, @http:Payload llms:LLMRequest payload) returns llms:LLMResponse|error {
        // Update request stats
        lock {
            requestStats.totalRequests += 1;
            requestStats.requestsByProvider[llmProvider] = (requestStats.requestsByProvider[llmProvider] ?: 0) + 1;
        }

        llms:LLMResponse|error response;
        match llmProvider {
            "openai" => {
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
        // Transform to OpenAI format
        json openAIPayload = {
            "model": openAIConfig.model,
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

        http:Response response = check self.openaiClient->post("/v1/chat/completions", openAIPayload, {
            "Authorization": "Bearer " + openAIConfig.apiKey
        });

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
    }

    private function handleOllama(llms:LLMRequest req) returns llms:LLMResponse|error {
        // Transform to OpenAI format
        json ollamaPayload = {
            "model": ollamaConfig.model,
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

        http:Response response = check self.ollamaClient->post("/api/chat", ollamaPayload, {
            "Authorization": "Bearer " + ollamaConfig.apiKey
        });

        // string resStr = check response.getTextPayload();
        // log:printInfo("TEXT response: " + resStr);

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
    }    

    private function handleAnthropic(llms:LLMRequest req) returns llms:LLMResponse|error {
        // Transform to Anthropic format
        json anthropicPayload = {
            "model": anthropicConfig.model,
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

        http:Response response = check self.anthropicClient->post("/v1/messages", anthropicPayload, {
            "x-api-key": anthropicConfig.apiKey,
            "anthropic-version": "2023-06-01"
        });

        json responsePayload = check response.getJsonPayload();
        log:printInfo("Anthropic response: " + responsePayload.toString());
        llms:AnthropicResponse anthropicResponse = check responsePayload.cloneWithType(llms:AnthropicResponse);
        
        // Apply guardrails before returning
        string guardedText = check applyGuardrails(anthropicResponse.contents.content[0].text);
        return {
            text: guardedText,
            input_tokens: anthropicResponse.usage.input_tokens,
            output_tokens: anthropicResponse.usage.output_tokens,
            model: anthropicConfig.model,
            provider: "anthropic"
        };
    }

    private function handleGemini(llms:LLMRequest req) returns llms:LLMResponse|error {
        json geminiPayload = {
            "model": geminiConfig.model,
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

        http:Response response = check self.geminiClient->post(":chatCompletions", geminiPayload, {
            "Content-Type": "application/json",
            "Authorization": "Bearer " + geminiConfig.apiKey
        });

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
