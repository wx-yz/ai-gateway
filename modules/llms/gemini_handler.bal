import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the Gemini API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + geminiClient - HTTP client for communicating with Gemini API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed
public isolated function handleGeminiRequest(http:Client geminiClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    OpenAIConfig? geminiConfig = getGeminiConfig();

    if geminiConfig == () {
        logging:logEvent("ERROR", "gemini", "Gemini not configured", {requestId});
        return error("Gemini is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent("ERROR", "gemini", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    json geminiPayload = {
        "model": geminiConfig?.model,
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

    logging:logEvent("DEBUG", "gemini", "Sending request to Gemini", {
        requestId,
        model: geminiConfig?.model,
        promptLength: reqUserPrompt.length()
    });

    if geminiConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + geminiConfig?.apiKey };

        http:Response|error response = geminiClient->post(":chatCompletions", geminiPayload, headers);

        if response is error {
            logging:logEvent("ERROR", "gemini", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Gemini API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "gemini", "API error response", {
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
            logging:logEvent("ERROR", "gemini", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        OpenAIResponse|error geminiResponse = responsePayload.cloneWithType(OpenAIResponse);
        if geminiResponse is error {
            logging:logEvent("ERROR", "gemini", "Response type conversion failed", {
                requestId,
                'error: geminiResponse.message() + ":" + geminiResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return geminiResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(geminiResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent("INFO", "gemini", "Request successful", {
            requestId,
            model: geminiResponse.model
            // Gemini doesn't always provide token usage info
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: geminiResponse.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: geminiResponse.choices[0].message.role,
                    content: guardedText
                },
                finish_reason: geminiResponse.choices[0].finish_reason ?: "stop"
            }],
            usage: {
                prompt_tokens: geminiResponse.usage.prompt_tokens,
                completion_tokens: geminiResponse.usage.completion_tokens,
                total_tokens: (geminiResponse.usage.prompt_tokens) + (geminiResponse.usage.completion_tokens)
            }
        };
    } else {
        logging:logEvent("ERROR", "gemini", "Invalid API key configuration", {requestId});
        return error("Gemini configuration is invalid");
    }
}