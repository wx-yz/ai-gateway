import ballerina/uuid;
import ballerina/http;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the OpenAI API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + openaiClient - HTTP client for communicating with OpenAI API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed
public isolated function handleOpenAIRequest(http:Client openaiClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    OpenAIConfig? openAIConfig = getOpenAIConfig();

    if openAIConfig == () {
        logging:logEvent("ERROR", "openai", "OpenAI not configured", {requestId});
        return error("OpenAI is not configured");
    }
    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        return error("Invalid request");
    }
    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    // Transform to OpenAI format
    json openAIPayload = {
        "model": openAIConfig?.model,
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

    if openAIConfig?.apiKey != "" {
        map<string|string[]> headers = { "Authorization": "Bearer " + openAIConfig?.apiKey };

        logging:logEvent("DEBUG", "openai", "Sending request to OpenAI", {
            requestId,
            model: openAIConfig?.model,
            promptLength: reqUserPrompt.length()
        });

        http:Response|error response = openaiClient->post("/v1/chat/completions", openAIPayload, headers);

        if response is error {
            logging:logEvent("ERROR", "openai", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "OpenAI API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "openai", "API error response", {
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
            logging:logEvent("ERROR", "openai", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        OpenAIResponse|error openAIResponse = responsePayload.cloneWithType(OpenAIResponse);
        if openAIResponse is error {
            logging:logEvent("ERROR", "openai", "Response type conversion failed", {
                requestId,
                'error: openAIResponse.message() + ":" + openAIResponse.detail().toString()
            });
            return openAIResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(openAIResponse.choices[0].message.content);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: openAIResponse.model,
            system_fingerprint: (),
            choices: [{
                index: openAIResponse.choices[0].index,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: openAIResponse.choices[0].finish_reason ?: "stop"
            }],
            usage: {
                prompt_tokens: openAIResponse.usage.prompt_tokens,
                completion_tokens: openAIResponse.usage.completion_tokens,
                total_tokens: openAIResponse.usage.prompt_tokens + openAIResponse.usage.completion_tokens
            }
        };
    } else {
        logging:logEvent("ERROR", "openai", "Invalid API key configuration", {requestId});
        return error("OpenAI configuration is invalid");
    }
}
