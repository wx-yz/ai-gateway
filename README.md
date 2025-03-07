# AI Gateway

A configurable API gateway for multiple LLM providers (OpenAI, Anthropic, Gemini, Ollama) with built-in analytics, guardrails, and administrative controls.

## Getting Started

1. Create file named `Config.toml` with following content
```toml
[openAIConfig]
apiKey = "Your_API_Key"
model = "gpt-4"
endpoint = "https://api.openai.com"
```
2. Run below docker command
```shell
docker run -p \
    8080:8080 -p 8081:8081 -p 8082:8082 \
    -v $(pwd)/Config.toml:/home/ballerina/Config.toml \
    chintana/ai-gateway:v1.1.0
```
3. Start sending requests
```
curl -X POST http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-llm-provider: openai" \
    -d '
{
  "messages": [
    {
        "role": "user", 
        "content": "Solve world hunger" 
    }
  ]
}
'
```

## Compatible with OpenAI SDK

Use any OpenAI compatible SDK to talk to the gateway. Following example use official OpenAI Python SDK

1. Install OpenAI official Python SDK
```shell
 pip install openai
```

2. Example client. Note that setting the model and api key is enforced by the SDK. However these will be ignored by the gateway and will use whatever model and key configured at the gateway.
```python
import openai

openai.api_key = '...' # Required by the SDK, AI Gateway will ignore this

# all client options can be configured just like the `OpenAI` instantiation counterpart
openai.base_url = "http://localhost:8080/v1/"
openai.default_headers = {"x-llm-provider": "openai"}

# Setting the model is enforced by the SDK. AI Gateway will ignore this value
completion = openai.chat.completions.create(
    model="gpt-4o",
    messages=[
        {
            "role": "user",
            "content": "Solve world hunger",
        },
    ],
)
print(completion.choices[0].message.content)
```

## Feature Highlights

- **Multi-Provider Support**: Route requests to OpenAI, Anthropic, Gemini, Ollama, and Cohere
- **Automatic Failover**: When 2+ providers are configured, automatically fails over to alternative providers if primary provider fails
- **Rate Limiting**: Rate limiting policies
- **OpenAI compatible interface**: Standardized input and output based on OpenAI API inteface
- **Response Caching**: In-memory cache with configurable TTL for improved performance and reduced API costs
- **System Prompts**: Inject system prompts into all LLM requests
- **Response Guardrails**: Configure content filtering and response constraints
- **Analytics Dashboard**: Monitor usage, tokens, and errors with visual charts
- **Admin UI**: Configure AI gateway
- **Administrative Controls**: Configure gateway behavior via admin API

## HTTP API for chat completion

OpenAI compatible request interface
```shell
curl -X POST 'http://localhost:8080/v1/chat/completions' \
--header 'x-llm-provider: ollama' \
--header 'Content-Type: application/json' \
--data '{
  "messages": [{ 
        "role": "user",
        "content": "When will we have AGI? In 10 words" 
      }]
}
'
```

OpenAI API compatible response
```json
{
    "id": "01eff23c-208f-15a8-acdc-f400bba1bc6d",
    "object": "chat.completion",
    "created": 1740352553,
    "model": "llama3.1:latest",
    "choices": [
        {
            "index": 0,
            "message": {
                "role": "assistant",
                "content": "Estimating exact timeline uncertain, but likely within next few decades."
            },
            "finish_reason": "stop"
        }
    ],
    "usage": {
        "prompt_tokens": 27,
        "completion_tokens": 14,
        "total_tokens": 41
    }
}
```

## gRPC API for chat completion

An example client in Python is available in `grpc-client` folder
```python
def run():
    # Create a gRPC channel
    channel = grpc.insecure_channel('localhost:8082')

    # Create a stub (client)
    stub = ai_gateway_pb2_grpc.AIGatewayStub(channel)

    # Create a request
    request = ai_gateway_pb2.ChatCompletionRequest(
        llm_provider="ollama",
        messages=[
            ai_gateway_pb2.Message(
                role="system",
                content="You are a helpful assistant."
            ),
            ai_gateway_pb2.Message(
                role="user",
                content="What is the capital of France?"
            )
        ]
    )

    try:
        # Make the call
        response = stub.ChatCompletion(request)

    # ...
```

## Switching between LLM providers

Use `x-llm-provider` HTTP header to route to different providers. AI Gateway mask request format differences between providers. Always use OpenAI API compatible request format and the gateway will always respond in OpenAI compatible response

| LLM Provider | Header name    | Header value |
| ------------ | -------------- | ------------ |
| OpenAI       | x-llm-provider | openai       |
| Ollama       | x-llm-provider | ollama       |
| Anthropic    | x-llm-provider | anthropic    |
| Gemini       | x-llm-provider | gemini       |
| Mistral      | x-llm-provider | mistral      |
| Cohere       | x-llm-provider | cohere       |

## Disable caching for requests

Gateway automatiacally enable response caching to improve performance and save costs. The default cache duration is 1 hour. If you specifically wants to disable caching for equests, then send `Cache-Control: no-cache` HTTP header with each request

## Gateway configuration

Gateway configuration can be done using either the built-in admin UI or using the REST API

### Admin UI

Use the following Postman collection test the AI Gateway

[<img src="https://run.pstmn.io/button.svg" alt="Run In Postman" style="width: 128px; height: 32px;">](https://god.gw.postman.com/run-collection/14185009-b582afdc-3194-4d82-ae06-416946f78eac?action=collection%2Ffork&source=rip_markdown&collection-url=entityId%3D14185009-b582afdc-3194-4d82-ae06-416946f78eac%26entityType%3Dcollection%26workspaceId%3D64e3340f-fb8a-4791-9887-e559c4fdb5b3)

Main Admin UI display current stats on the server

![1-admin-dashboard](https://github.com/user-attachments/assets/37ea56af-0d6a-4958-804c-4675c338d67e)

Configure Settings: system prompt, guardrails, and clear cache

![2-settings](https://github.com/user-attachments/assets/28f57888-fa52-4046-97d9-6c8d7fee29c3)

Add/modify logging config

![3-logging-config](https://github.com/user-attachments/assets/acaa24ec-9427-441a-81d5-645c6cba3d79)

Add/modify rate limiting policy

![4-rate-limiting](https://github.com/user-attachments/assets/b0645586-f782-46bc-9d5e-a6534345987a)

### Add rate limiting

Two separate rate limiting policies are supported,
1. Wildcard based - Use the value "*.*.*.*" as the client IP and this will apply to any client
2. Specific IP based

Add a wildcard rate limiting policy

```shell
curl -X POST 'http://localhost:8081/admin/ratelimit/clients' \
--header 'Content-Type: application/json' \
--data '{
    "clientIP": "*.*.*.*",
    "name": "wildcard",
    "requestsPerWindow": 5,
    "windowSeconds": 60
}'
```

Add an IP based rate limiting policy

```shell
curl -X POST 'http://localhost:8081/admin/ratelimit/clients' \
--header 'Content-Type: application/json' \
--data '{
    "clientIP": "192.168.1.80",
    "name": "wildcard",
    "requestsPerWindow": 5,
    "windowSeconds": 60
}'
```

Once rate limiting is enbaled, following 3 HTTP response headers will be used to announce current limits. These will be added to every HTTP response generated by the gateway

| Header name     | Value  | Description |
| --------------- | ------ | ----------- |
| RateLimit-Limit | number | Maximum number of requests allowed in the current policy |
| RateLimit-Remaining | number | Number of requests that can be sent before rate limit policy is enforced |
| RateLimit-Reset | number | How many seconds until current rate limit policy is reset

Following GET call will return the currently configured rate limiting policy. If the request is empty then rate limiting is disabled

```shell
curl -X GET 'http://localhost:8081/admin/ratelimit/clients'
```
Respnose
```json
{
    "*.*.*.*": {
        "clientIP": "*.*.*.*",
        "name": "wildcard",
        "requestsPerWindow": 5,
        "windowSeconds": 60
    },
    "192.168.1.80": {
        "clientIP": "192.168.1.80",
        "name": "host-1",
        "requestsPerWindow": 10,
        "windowSeconds": 120
    }
}
```

### Automatic failover

When 2 or more LLM providers are configured, the gateway will attempt automatic failover if there's no successful response from the provider user has chosen through `x-llm-provider` header.

The logs will dispaly a trail of failover like below. Here, the user is trying to send the request to Ollama. We have Ollama and OpenAI configured in the gateway.

First we can see a failed message. Following logs are formatted for clarity.
```json
{
  "timestamp": "2025-02-24T00:33:51.127868Z",
  "level": "WARN",
  "component": "failover",
  "message": "Primary provider failed",
  "metadata": {
    "requestId": "01eff247-0444-1eb0-b153-61183107b722",
    "provider": "ollama",
    "error": "Something wrong with the connection:{}"
  }
}
```
First attempt to failover,
```json
{
  "timestamp": "2025-02-24T00:33:51.129457Z",
  "level": "INFO",
  "component": "failover",
  "message": "Attempting failover",
  "metadata": {
    "requestId": "01eff247-0444-1eb0-b153-61183107b722",
    "provider": "openai"
  }
}
```

### System Prompt Injection ###

Admins can use the admin API to inject a system prompt for all out going requests. This will be appended to the system prompt if a user has supplied one in the request
```shell
curl -X POST 'http://localhost:8081/admin/systemprompt' \
--header 'Content-Type: application/json' \
--data '{
    "prompt": "respond only in chinese"
}'
```

Following GET request will show current system prompt
```shell
curl -X GET 'http://localhost:8081/admin/systemprompt'
```

### Enforcing guardrails ###

Use the following API call to add guardrails
```shell
curl -X POST 'http://localhost:8081/admin/guardrails' \
--header 'Content-Type: application/json' \
--data '{
    "bannedPhrases": ["obscene", "words"],
    "minLength": 0,
    "maxLength": 500000,
    "requireDisclaimer": false
}'
```

Get currently configured guardrails
```shell
curl -X GET 'http://localhost:8081/admin/guardrails'
```

### Cache Management

Gateway automatically enbale response caching for requests to save costs and enable responsiveness. Default cache duration is 1 hour. When requests are served from the cache, there will be a respective log printed to the logs.

The gateway will look for `Cache-Control: no-cache` header and will disable cache lookup for those requests

View current cached contents
```shell
curl -X GET 'http://localhost:8081/admin/cache'
```

Clear cache
```shell
curl -X DELETE 'http://localhost:8081/admin/cache'
```

### Publish logs to Elastic Search

Configure following attributes in `Config.toml` to configure log publishing to Elastic Search
```toml
[defaultLoggingConfig]
enableElasticSearch = true
elasticSearchEndpoint = "http://localhost:9200"
elasticApiKey = "T2FtMks1VUIzVG..."
```
After that at the server start, you should see an index being created in Elastic Search called "ai-gateway"

![elastic-search-1](https://github.com/user-attachments/assets/bbd3bd87-36bb-4449-906d-e20e592e6b34)

All ongoing logs will gets published to this index

![elastic-search-2](https://github.com/user-attachments/assets/cb95071a-fe42-470a-99a2-725ad4e30c5f)

## Configuration reference ##

Following is a complete example of all the configuration possible in the main gateway config file. At least one LLM provider config is mandatory

Create a `Config.toml` file:
```
[defaultLoggingConfig]
enableElasticSearch = false
elasticSearchEndpoint = "http://localhost:9200"
elasticApiKey = ""
enableSplunk = false
splunkEndpoint = ""
enableDatadog = false
datadogEndpoint = ""

[openAIConfig]
apiKey="your-api-key"
endpoint="https://api.openai.com"
model="gpt-4o"

[anthropicConfig]
apiKey="your-api-key"
model="claude-3-5-sonnet-20241022"
endpoint="https://api.anthropic.com"

[geminiConfig]
apiKey="your-api-key"
model="gemini-pro"
endpoint="https://generativelanguage.googleapis.com/v1/models"


[ollamaConfig]
apiKey=""
model="llama3.2"
endpoint="http://localhost:11434"

[mistralConfig]
apiKey = ""
model = "mistral-small-latest"
endpoint = "https://api.mistral.ai"

[cohereConfig]
apiKey = ""
model = "command-r-plus-08-2024"
endpoint = "https://api.cohere.com"
```

## Development

```bash
# Build and run the gateway
% bal run
```
