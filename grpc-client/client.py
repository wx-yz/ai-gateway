import grpc
import ai_gateway_pb2
import ai_gateway_pb2_grpc

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
        ],
        temperature=0.7,
        max_tokens=1000
    )

    try:
        # Make the call
        response = stub.ChatCompletion(request)
        
        # Print the response
        print("Response received:")
        print(f"ID: {response.id}")
        print(f"Model: {response.model}")
        for choice in response.choices:
            print(f"Response: {choice.message.content}")
            print(f"Finish reason: {choice.finish_reason}")
        print(f"Usage - Prompt tokens: {response.usage.prompt_tokens}")
        print(f"Usage - Completion tokens: {response.usage.completion_tokens}")
        print(f"Usage - Total tokens: {response.usage.total_tokens}")

    except grpc.RpcError as e:
        print(f"RPC failed: {e}")

if __name__ == '__main__':
    run()
