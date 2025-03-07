
// Add system prompt storage
isolated string systemPrompt = "";

isolated OpenAIConfig? openAIConfig = ();
isolated AnthropicConfig? anthropicConfig = ();
isolated GeminiConfig? geminiConfig = ();
isolated OllamaConfig? ollamaConfig = ();
isolated OpenAIConfig? mistralConfig = ();
isolated OpenAIConfig? cohereConfig = ();


# Extracts system and user prompts from an LLM request
# Processes message arrays to identify and extract different prompt types
# 
# + llmRequest - The LLM request containing message arrays with role and content
# + return - [string, string] - A tuple containing [systemPrompt, userPrompt]
#            error - If the request format is invalid or required prompts are missing
public isolated function getPrompts(LLMRequest llmRequest) returns [string, string]|error {
    string systemPrompt = "";
    string userPrompt = "";
    LLMRequestMessage[] messages = llmRequest.messages;
    if messages.length() == 1 { // If it's only one here, expecting only user prompt
        if messages[0].content == "" {
            return error("User prompt is required");
        } else {
            userPrompt = messages[0].content;
        }
    } else if messages.length() == 2 { // If it's two here, expecting system and user prompt
        // find the user prompt
        foreach LLMRequestMessage message in messages {
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

public isolated function setSystemPrompt(string prompt) {
    lock {
        systemPrompt = prompt;
    }
}

public isolated function getSystemPrompt() returns string {
    lock {
        return systemPrompt.cloneReadOnly();
    }
}
public isolated function getOpenAIConfig() returns OpenAIConfig? {
    lock {
        return openAIConfig.cloneReadOnly();
    }
}
public isolated function setOpenAIConfig(OpenAIConfig? config) {
    lock {
        openAIConfig = config.cloneReadOnly();
    }
}

public isolated function getAnthropicConfig() returns AnthropicConfig? {
    lock {
        return anthropicConfig.cloneReadOnly();
    }
}
public isolated function setAnthropicConfig(AnthropicConfig? config) {
    lock {
        anthropicConfig = config.cloneReadOnly();
    }
}

public isolated function getGeminiConfig() returns GeminiConfig? {
    lock {
        return geminiConfig.cloneReadOnly();
    }
}
public isolated function setGeminiConfig(GeminiConfig? config) {
    lock {
        geminiConfig = config.cloneReadOnly();
    }
}

public isolated function getOllamaConfig() returns OllamaConfig? {
    lock {
        return ollamaConfig.cloneReadOnly();
    }
}
public isolated function setOllamaConfig(OllamaConfig? config) {
    lock {
        ollamaConfig = config.cloneReadOnly();
    }
}

public isolated function getMistralConfig() returns OpenAIConfig? {
    lock {
        return mistralConfig.cloneReadOnly();
    }
}
public isolated function setMistralConfig(OpenAIConfig? config) {
    lock {
        mistralConfig = config.cloneReadOnly();
    }
}

public isolated function getCohereConfig() returns OpenAIConfig? {
    lock {
        return cohereConfig.cloneReadOnly();
    }
}
public isolated function setCohereConfig(OpenAIConfig? config) {
    lock {
        cohereConfig = config.cloneReadOnly();
    }
}
