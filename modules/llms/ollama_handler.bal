import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the Ollama API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + ollamaClient - HTTP client for communicating with Ollama API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed

public isolated function handleOllamaRequest(http:Client ollamaClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    OllamaConfig? ollamaConfig = getOllamaConfig();

    if ollamaConfig == () {
        logging:logEvent("ERROR", "ollama", "Ollama not configured", {requestId});
        return error("Ollama is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent("ERROR", "ollama", "Invalid request format", {
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
                "content": reqSystemPrompt + " " + getSystemPrompt()
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "stream": false
    };

    logging:logEvent("DEBUG", "ollama", "Sending request to Ollama", {
        requestId,
        model: ollamaConfig?.model,
        promptLength: reqUserPrompt.length()
    });

    if ollamaConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + ollamaConfig?.apiKey };

        http:Response|error response = ollamaClient->post("/api/chat", ollamaPayload, headers);

        if response is error {
            logging:logEvent("ERROR", "ollama", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            int statusCode = check (check response.ensureType(json)).status;
            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Ollama API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "ollama", "API error response", {
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
            logging:logEvent("ERROR", "ollama", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        OllamaResponse|error ollamaResponse = responsePayload.cloneWithType(OllamaResponse);
        if ollamaResponse is error {
            logging:logEvent("ERROR", "ollama", "Response type conversion failed", {
                requestId,
                'error: ollamaResponse.message() + ":" + ollamaResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return ollamaResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(ollamaResponse.message.content);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent("INFO", "ollama", "Request successful", {
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
        logging:logEvent("ERROR", "ollama", "Invalid API key configuration", {requestId});
        return error("Ollama configuration is invalid");
    }
}