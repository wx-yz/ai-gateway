import ballerina/http;
import ballerina/log;

// Configuration types for different LLM providers
type OpenAIConfig record {
    string apiKey;
    string model;
    string endpoint;
};

type OllamaConfig record {
    string apiKey;
    string model;
    string endpoint;
};

type AnthropicConfig record {
    string apiKey;
    string model;
    string endpoint;
};

type GeminiConfig record {
    string apiKey;
    string model;
    string endpoint;
};

// Add after the existing config types
type SystemPromptConfig record {
    string prompt;
};

// Canonical response format
type LLMResponse record {
    string text;
    int input_tokens;
    int output_tokens;
    string model;
    string provider;
};

// Common request format
type LLMRequest record {
    string prompt;
    float temperature?;
    int maxTokens?;
};

// Handle Anthropic response
type AnthropicResponseContent record {
    string text;    
};
type AnthropicResponseContents record {
    AnthropicResponseContent[] content;
};
type AnthropicResponseTokenUsage record {
    int input_tokens;
    int output_tokens;
};
type AnthropicResponse record {
    AnthropicResponseContents contents;
    AnthropicResponseTokenUsage usage;
    string model;
};

// Handle OpenAI response
type OpenAIResponseChoiceMessage record {
    string content;
};
type OpenAIResponseChoice record {
    OpenAIResponseChoiceMessage message;
};
type OpenAIResponseUsage record {    
    int completion_tokens;
    int prompt_tokens;
};
type OpenAIResponse record {
    OpenAIResponseChoice[] choices;
    OpenAIResponseUsage usage;
    string model;
};

// Handle Ollama response
type OllamaResponseMessage record {
    string content;
};
type OllamaResponse record {
    string model;
    OllamaResponseMessage message;
    int prompt_eval_count;
    int eval_count;
};

configurable OpenAIConfig openAIConfig = ?;
configurable AnthropicConfig anthropicConfig = ?;
configurable GeminiConfig geminiConfig = ?;
configurable OllamaConfig ollamaConfig = ?;

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
        if (text.includes(phrase)) {
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

    resource function post chat(@http:Header string llmProvider, @http:Payload LLMRequest payload) returns LLMResponse|error {
        match llmProvider {
            "openai" => {
                return self.handleOpenAI(payload);
            }
            "anthropic" => {
                return self.handleAnthropic(payload);
            }
            "gemini" => {
                return self.handleGemini(payload);
            }
            "ollama" => {
                return self.handleOllama(payload);
            }
            _ => {
                return error("Unsupported LLM provider");
            }
        }
    }

    private function handleOpenAI(LLMRequest req) returns LLMResponse|error {
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
        OpenAIResponse openAIResponse = check responsePayload.cloneWithType(OpenAIResponse);

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

    private function handleOllama(LLMRequest req) returns LLMResponse|error {
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
        OllamaResponse ollamaResponse = check responsePayload.cloneWithType(OllamaResponse);

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

    private function handleAnthropic(LLMRequest req) returns LLMResponse|error {
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
        AnthropicResponse anthropicResponse = check responsePayload.cloneWithType(AnthropicResponse);
        
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

    private function handleGemini(LLMRequest req) returns LLMResponse|error {
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
        OpenAIResponse openAIResponse = check responsePayload.cloneWithType(OpenAIResponse);

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

// Add new admin service
service /admin on new http:Listener(8081) {
    resource function post systemprompt(@http:Payload SystemPromptConfig config) returns string|error {
        systemPrompt = config.prompt;
        return "System prompt updated successfully";
    }

    resource function get systemprompt() returns SystemPromptConfig {
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
}
