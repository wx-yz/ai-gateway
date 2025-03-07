import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the Mistral API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + mistralClient - HTTP client for communicating with Mistral API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed
public isolated function handleMistralRequest(http:Client mistralClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    OpenAIConfig? mistralConfig = getMistralConfig();

    if mistralConfig == () {
        logging:logEvent("ERROR", "mistral", "Mistral not configured", {requestId});
        return error("Mistral is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent("ERROR", "mistral", "Invalid request format", {
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
                "content": reqSystemPrompt + " " + getSystemPrompt()
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000
    };

    logging:logEvent("DEBUG", "mistral", "Sending request to Mistral", {
        requestId,
        model: mistralConfig?.model,
        promptLength: reqUserPrompt.length()
    });

    if mistralConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + mistralConfig?.apiKey };

        http:Response|error response = mistralClient->post("/v1/chat/completions", mistralPayload, headers);

        if response is error {
            logging:logEvent("ERROR", "mistral", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Mistral API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "mistral", "API error response", {
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
            logging:logEvent("ERROR", "mistral", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        OpenAIResponse|error mistralResponse = responsePayload.cloneWithType(OpenAIResponse);
        if mistralResponse is error {
            logging:logEvent("ERROR", "mistral", "Response type conversion failed", {
                requestId,
                'error: mistralResponse.message() + ":" + mistralResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return mistralResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(mistralResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent("INFO", "mistral", "Request successful", {
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
        logging:logEvent("ERROR", "mistral", "Invalid API key configuration", {requestId});
        return error("Mistral configuration is invalid");
    }
}
