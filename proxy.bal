import ballerina/http;
import ballerina/log;

// Configuration types for different LLM providers
type OpenAIConfig record {
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

// Handle Gemini response

configurable OpenAIConfig openAIConfig = ?;
configurable AnthropicConfig anthropicConfig = ?;
configurable GeminiConfig geminiConfig = ?;

service / on new http:Listener(8080) {
    private final http:Client openaiClient;
    private final http:Client anthropicClient;
    private final http:Client geminiClient;

    function init() returns error? {
        self.openaiClient = check new (openAIConfig.endpoint);
        self.anthropicClient = check new (anthropicConfig.endpoint);
        self.geminiClient = check new (geminiConfig.endpoint);
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

        return {
            text: openAIResponse.choices[0].message.content,
            input_tokens: openAIResponse.usage.prompt_tokens,
            output_tokens: openAIResponse.usage.completion_tokens,
            model: openAIResponse.model,
            provider: "openai"
        };
    }

    private function handleAnthropic(LLMRequest req) returns LLMResponse|error {
        // Transform to Anthropic format
        json anthropicPayload = {
            "model": anthropicConfig.model,
            "messages": [
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
        
        return {
            text: anthropicResponse.contents.content[0].text,
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

        return {
            text: openAIResponse.choices[0].message.content,
            input_tokens: 0, // Assuming input tokens are not provided by Gemini
            output_tokens: 0, // Assuming output tokens are not provided by Gemini
            model: openAIResponse.model,
            provider: "gemini"
        };
    }
}
