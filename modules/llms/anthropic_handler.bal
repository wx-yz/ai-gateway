import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the Anthropic API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + anthropicClient - HTTP client for communicating with Anthropic API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed

public isolated function handleAnthropicRequest(http:Client anthropicClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    AnthropicConfig? anthropicConfig = getAnthropicConfig();

    if anthropicConfig == () {
        logging:logEvent("ERROR", "anthropic", "Anthropic not configured", {requestId});
        return error("Anthropic is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent("ERROR", "anthropic", "Invalid request format", {
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
                "content": reqSystemPrompt + " " + getSystemPrompt()
            },
            {
                "role": "user",
                "content": reqUserPrompt
            }
        ],
        "max_tokens": req.maxTokens ?: 1000,
        "temperature": req.temperature ?: 0.7
    };

    logging:logEvent("DEBUG", "anthropic", "Sending request to Anthropic", {
        requestId,
        model: anthropicConfig?.model,
        promptLength: reqUserPrompt.length()
    });

    if anthropicConfig?.apiKey != "" {
        map<string|string[]> headers = {
            "Authorization": "Bearer " + anthropicConfig?.apiKey,
            "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"
        };

        http:Response|error response = anthropicClient->post("/v1/messages", anthropicPayload, headers);

        if response is error {
            logging:logEvent("ERROR", "anthropic", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Anthropic API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "anthropic", "API error response", {
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
            logging:logEvent("ERROR", "anthropic", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        AnthropicResponse|error anthropicResponse = responsePayload.cloneWithType(AnthropicResponse);
        if anthropicResponse is error {
            logging:logEvent("ERROR", "anthropic", "Response type conversion failed", {
                requestId,
                'error: anthropicResponse.message() + ":" + anthropicResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return anthropicResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(anthropicResponse.contents.content[0].text);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent("INFO", "anthropic", "Request successful", {
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
        logging:logEvent("ERROR", "anthropic", "Invalid API key configuration", {requestId});
        return error("Anthropic configuration is invalid");
    }
}