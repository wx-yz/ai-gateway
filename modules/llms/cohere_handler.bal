import ballerina/http;
import ballerina/uuid;
import ballerina/time;
import ai_gateway.logging;
import ai_gateway.guardrails;

# Handles a request to the Cohere API for chat completion
# Processes the request, applies system prompts, and handles error conditions
# 
# + cohereClient - HTTP client for communicating with Cohere API
# + req - LLM request containing messages, parameters and completion settings
# + return - llms:LLMResponse - A formatted response containing completion text and metadata
#            error - If the API request fails, returns invalid data, or cannot be processed
public isolated function handleCohereRequest(http:Client cohereClient, LLMRequest req) returns LLMResponse|error {
    string requestId = uuid:createType1AsString();

    OpenAIConfig? cohereConfig = getCohereConfig();

    if cohereConfig == () {
        logging:logEvent("ERROR", "cohere", "Cohere not configured", {requestId});
        return error("Cohere is not configured");
    }

    [string,string]|error prompts = getPrompts(req);
    if prompts is error {
        logging:logEvent("ERROR", "cohere", "Invalid request format", {
            requestId,
            'error: prompts.message()
        });
        return error("Invalid request");
    }

    string reqSystemPrompt = prompts[0];
    string reqUserPrompt = prompts[1];

    string cohereSystemPrompt = reqSystemPrompt;
    if (getSystemPrompt() != "") {
        cohereSystemPrompt = reqSystemPrompt + " " + getSystemPrompt();
    }

    json coherePayload = {
        "message": reqUserPrompt,
        "chat_history": [{
            "role": "USER",
            "message": reqUserPrompt
        },
        {
            "role": "SYSTEM",
            "message": cohereSystemPrompt
        }],
        "temperature": req.temperature ?: 0.7,
        "max_tokens": req.maxTokens ?: 1000,
        "model": cohereConfig?.model,
        "preamble": "You are an AI-assistant chatbot. You are trained to assist users by providing thorough and helpful responses to their queries."
    };

    logging:logEvent("DEBUG", "cohere", "Sending request to Cohere", {
        requestId,
        model: cohereConfig?.model,
        promptLength: reqUserPrompt.length()
    });

    if cohereConfig?.apiKey != "" {
        map<string|string[]> headers = {
            "Authorization": "Bearer " + cohereConfig?.apiKey,
            "Content-Type": "application/json",
            "Accept": "application/json"
        };

        http:Response|error response = cohereClient->post("/v1/chat", coherePayload, headers);

        if response is error {
            logging:logEvent("ERROR", "cohere", "HTTP request failed", {
                requestId,
                'error: response.message() + ":" + response.detail().toString()
            });

            // Check for HTTP error responses
            // int statusCode = response.statusCode;
            int statusCode = check (check response.ensureType(json)).status;

            if statusCode >= 400 {
                string errorBody = response.detail().toString();
                string errorMessage = "Cohere API error: HTTP " + statusCode.toString();

                logging:logEvent("ERROR", "cohere", "API error response", {
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
            logging:logEvent("ERROR", "cohere", "Invalid JSON response", {
                requestId,
                'error: responsePayload.message() + ":" + responsePayload.detail().toString()
            });
            return responsePayload;
        }

        CohereResponse|error cohereResponse = responsePayload.cloneWithType(CohereResponse);
        if cohereResponse is error {
            logging:logEvent("ERROR", "cohere", "Response type conversion failed", {
                requestId,
                'error: cohereResponse.message() + ":" + cohereResponse.detail().toString(),
                response: responsePayload.toString()
            });
            return cohereResponse;
        }

        // Apply guardrails
        string|error guardedText = guardrails:applyGuardrails(cohereResponse.text);
        if guardedText is error {
            logging:logEvent("ERROR", "guardrails", "Guardrails check failed", {
                requestId,
                'error: guardedText.message() + ":" + guardedText.detail().toString()
            });
            return guardedText;
        }

        logging:logEvent("INFO", "cohere", "Request successful", {
            requestId,
            model: cohereConfig?.model,
            usage: {
                input: cohereResponse.meta.tokens.input_tokens,
                output: cohereResponse.meta.tokens.output_tokens
            }
        });

        return {
            id: uuid:createType1AsString(),
            'object: "chat.completion",
            created: time:utcNow()[0],
            model: cohereConfig?.model,
            system_fingerprint: (),
            choices: [{
                index: 0,
                message: {
                    role: "assistant",
                    content: guardedText
                },
                finish_reason: "stop"
            }],
            usage: {
                prompt_tokens: cohereResponse.meta.tokens.input_tokens,
                completion_tokens: cohereResponse.meta.tokens.output_tokens,
                total_tokens: cohereResponse.meta.tokens.input_tokens + cohereResponse.meta.tokens.output_tokens
            }
        };
    } else {
        logging:logEvent("ERROR", "cohere", "Invalid API key configuration", {requestId});
        return error("Cohere configuration is invalid");
    }
}
