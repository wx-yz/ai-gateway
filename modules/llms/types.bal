

// Configuration types for different LLM providers
public type OpenAIConfig record {
    string apiKey;
    string model;
    string endpoint;
};

public type OllamaConfig record {
    string apiKey;
    string model;
    string endpoint;
};

public type AnthropicConfig record {
    string apiKey;
    string model;
    string endpoint;
};

public type GeminiConfig record {
    string apiKey;
    string model;
    string endpoint;
};

// Add after the existing config types
public type SystemPromptConfig record {
    string prompt;
};

// Canonical response format
public type LLMResponse record {
    string text;
    int input_tokens;
    int output_tokens;
    string model;
    string provider;
};

// Common request format
public type LLMRequest record {
    string prompt;
    float temperature?;
    int maxTokens?;
};

// Handle Anthropic response
public type AnthropicResponseContent record {
    string text;    
};
public type AnthropicResponseContents record {
    AnthropicResponseContent[] content;
};
public type AnthropicResponseTokenUsage record {
    int input_tokens;
    int output_tokens;
};
public type AnthropicResponse record {
    AnthropicResponseContents contents;
    AnthropicResponseTokenUsage usage;
    string model;
};

// Handle OpenAI response
public type OpenAIResponseChoiceMessage record {
    string content;
};
public type OpenAIResponseChoice record {
    OpenAIResponseChoiceMessage message;
};
public type OpenAIResponseUsage record {    
    int completion_tokens;
    int prompt_tokens;
};
public type OpenAIResponse record {
    OpenAIResponseChoice[] choices;
    OpenAIResponseUsage usage;
    string model;
};

// Handle Ollama response
public type OllamaResponseMessage record {
    string content;
};
public type OllamaResponse record {
    string model;
    OllamaResponseMessage message;
    int prompt_eval_count;
    int eval_count;
};