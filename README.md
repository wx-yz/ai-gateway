# AI Gateway

A configurable API gateway for multiple LLM providers (OpenAI, Anthropic, Gemini, Ollama) with built-in analytics, guardrails, and administrative controls.

## Features Highlights

- **Multi-Provider Support**: Route requests to OpenAI, Anthropic, Gemini, or Ollama
- **Automatic Failover**: When 2+ providers are configured, automatically fails over to alternative providers if primary provider fails
- **Response Caching**: In-memory cache with configurable TTL for improved performance and reduced API costs
- **System Prompts**: Inject system prompts into all LLM requests
- **Response Guardrails**: Configure content filtering and response constraints
- **Analytics Dashboard**: Monitor usage, tokens, and errors with visual charts
- **Administrative Controls**: Configure gateway behavior via admin API

## Features in Detail

### Multiple LLM Providers
- Support for multiple LLM providers (OpenAI, Anthropic, Gemini, Ollama)
- Unified API for all providers
- Automatic failover to alternative providers if primary provider fails

### Caching
- In-memory cache for LLM responses
- Cache key combines provider and prompt
- Configurable TTL (default: 1 hour)
- Cache hits are logged for monitoring
- Cache statistics available in admin dashboard

### Failover Support
- Automatically activates when 3+ providers are configured
- Attempts alternative providers if primary provider fails
- Logs failover attempts and results
- Maintains original error if all providers fail

### Guardrails
- Content filtering with banned phrases
- Response length constraints
- Optional disclaimer injection
- Applied to all responses (including cached ones)

### System Prompts
- Inject system prompts into all LLM requests
- Configured per provider
- Can be overridden on a per-request basis

### Analytics Dashboard
- Real-time usage metrics
- Token consumption charts
- Error rate breakdown
- Cache hit ratios
- Provider performance stats

### Administrative Controls
- Configure system prompts
- Set guardrails
- Clear cache
- View analytics dashboard

## API Endpoints

Two endpoints are provided. Port 8080 for talking to external LLMs via /chat HTTP resource.

Port 8081 for configuring the gateway itself. All admin tasks are done using /admin resource.

### AI Gateway (Port 8080)

```
POST /chat
Header: x-llm-provider: "openai" | "anthropic" | "gemini" | "ollama"
Body: {
    "prompt": "Your prompt here",
}
```
### Admin API (Port 8081)

#### System Prompt Injection ####

Get current systemprompt
```
GET /admin/systemprompt
```

Add a system prompt to all outgoing prompts to LLM
```
POST /admin/systemprompt
{
    "prompt": "Respond only in Japanese"
}
```
#### Guardrails Configuration ####

Get currently configured guardrails
```
GET /admin/guardrails
```

Add guardrails. Currently only banned phrases and a disclaimer are supported.
```
POST /admin/guardrails
{
    "bannedPhrases": ["harmful", "inappropriate"],
    "minLength": 10,
    "maxLength": 2000,
    "requireDisclaimer": true,
    "disclaimer": "AI-generated response"
}
```

#### Cache Management
View cache contents
```
GET /admin/cache      # View cache 
```

Clear cache
```
DELETE /admin/cache   # Clear cache
```

#### Analytics Dashboard ####
HTML dashboard that displaying current gateway stats
```
GET /admin/stats
```

## Configuration ##

At least one LLM config is mandatory. Checked at server startup

Create a `Config.toml` file:
```
[openAIConfig]
apiKey="your-api-key"
endpoint="https://api.openai.com"
model="gpt-3.5-turbo"

[anthropicConfig]
apiKey="your-api-key"
endpoint="https://api.anthropic.com"
model="claude-3-opus-20240229"

[geminiConfig]
apiKey="your-api-key"
endpoint="https://generativelanguage.googleapis.com/v1/models"
model="gemini-pro"

[ollamaConfig]
apiKey=""
endpoint="http://localhost:11434"
model="llama2"
```

## Testing Examples ##
 
1. Send a chat request to OpenAI:
```bash
curl -X POST http://localhost:8080/chat \
  -H "llmProvider: openai" \
  -H "Content-Type: application/json" \
  -d '{"prompt": "What is the capital of France?"}'
```

2. Configure system prompt:
```bash
curl -X POST http://localhost:8081/admin/systemprompt \
  -H "Content-Type: application/json" \
  -d '{"prompt": "You are a helpful assistant that always responds briefly"}'
```

3. Set up guardrails:
```bash
curl -X POST http://localhost:8081/admin/guardrails \
  -H "Content-Type: application/json" \
  -d '{
    "bannedPhrases": ["harmful"],
    "minLength": 10,
    "maxLength": 1000,
    "requireDisclaimer": true,
    "disclaimer": "This is an AI-generated response"
  }'
```

4. Clear cache:
```bash
curl -X DELETE http://localhost:8081/admin/cache
```

## Testing screenshots ##

Chatting, prompt used: "Say hello and identify yourself"

![Screenshot 2025-02-14 181101](https://github.com/user-attachments/assets/8269e3f7-ea9b-4ed7-a0fd-1fc693c25ec9)

Injecting system prompt from the admin interface

![Screenshot 2025-02-14 181114](https://github.com/user-attachments/assets/b276f1e9-edce-4041-b634-41f411fbe48e)

Request not changed. Changed the model to ollama via custom HTTP header

![Screenshot 2025-02-14 181140](https://github.com/user-attachments/assets/925ce2cd-75a1-48d5-be28-8b00c211b130)

Adding guardrails. Added word "hello"

![Screenshot 2025-02-14 181220](https://github.com/user-attachments/assets/5090e045-0c9a-4b8c-a06b-a4bf72c530a5)

At this point, removed the system prompt and it defauts to English. Now sending the same request

![Screenshot 2025-02-14 181234](https://github.com/user-attachments/assets/11566a9b-7a58-4f5a-ae35-6f2eba76a78e)

## View analytics ##

- Open `http://localhost:8081/admin/stats` in your browser

![Screenshot 2025-02-14 181359](https://github.com/user-attachments/assets/38af88c6-c7fe-448b-b4a5-8a193416fcc8)

## Development

```bash
# Build and run the gateway
% bal run
```
