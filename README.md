# AI Gateway

A configurable API gateway for multiple LLM providers (OpenAI, Anthropic, Gemini, Ollama) with built-in analytics, guardrails, and administrative controls.

## Features

- **Multi-Provider Support**: Route requests to OpenAI, Anthropic, Gemini, or Ollama
- **System Prompts**: Inject system prompts into all LLM requests
- **Response Guardrails**: Configure content filtering and response constraints
- **Analytics Dashboard**: Monitor usage, tokens, and errors with visual charts
- **Administrative Controls**: Configure gateway behavior via admin API

## API Endpoints

### AI Gateway (Port 8080)

```
POST /chat
Header: llmProvider: "openai" | "anthropic" | "gemini" | "ollama"
Body: {
    "prompt": "Your prompt here",
    "temperature": 0.7,
    "maxTokens": 1000
}
```
### Admin API (Port 8081)

```
# System Prompt Management
GET /admin/systemprompt
POST /admin/systemprompt
{
    "prompt": "You are a helpful assistant..."
}

# Guardrails Configuration
GET /admin/guardrails
POST /admin/guardrails
{
    "bannedPhrases": ["harmful", "inappropriate"],
    "minLength": 10,
    "maxLength": 2000,
    "requireDisclaimer": true,
    "disclaimer": "AI-generated response"
}

# Analytics Dashboard
GET /admin/stats
```

## Configuration ##

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

4. View analytics:

- Open `http://localhost:8081/admin/stats` in your browser


## Development

```bash
# Run the gateway
bal run
```
