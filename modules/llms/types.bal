

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
public type LLMResponseCompletionTokenDetails record {
    int reasoning_tokens?;
    int accepted_prediction_tokens?;
    int rejected_prediction_tokens?;
};
public type LLMResponseUsage record {
    int prompt_tokens;
    int completion_tokens;
    int total_tokens?;
};
public type LLMResponseChoiceMessage record {
    string role;
    string content;
};
public type LLMResponseChoices record {
    int index;
    LLMResponseChoiceMessage message;
    string finish_reason;
};
public type LLMResponse record {
    string id;
    string 'object;
    int created;
    string model;
    string system_fingerprint?;
    LLMResponseChoices[] choices;
    LLMResponseUsage usage;
    // string text;
    // int input_tokens;
    // int output_tokens;
    
    // string provider;
};

// Canonical request format. This is same as OpenAI request format
public type LLMRequestMessage record {
    string role;
    string content;
};

// Common request format
public type LLMRequest record {
    LLMRequestMessage[] messages;
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
    int index;
    OpenAIResponseChoiceMessage message;
    string finish_reason?;
};
public type OpenAIResponseCompletionTokenDetails record {
    int reasoning_tokens;
    int accepted_prediction_tokens;
    int rejected_prediction_tokens;
};
public type OpenAIResponseUsage record {    
    int completion_tokens;
    int prompt_tokens;
    int total_tokens;
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
    string created_at;
    OllamaResponseMessage message;
    string done_reason;
    boolean done;
    int total_duration;
    int load_duration;
    int prompt_eval_count;
    int prompt_eval_duration;
    int eval_count;
    int eval_duration;
};


// Handle Cohere response
public type CohereBilledUnits record {
    int input_tokens;
    int output_tokens;
};
public type CohereTokens record {
    int input_tokens;
    int output_tokens;
};
public type CohereResponseUsage record {
    CohereBilledUnits billed_units;
    CohereTokens tokens;
};
public type CohereResponse record {
    string text;
    CohereResponseUsage meta;
};