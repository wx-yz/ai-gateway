## gRPC test client

Use this client to test gRPC service

2. Install required Python packages:
```bash
pip install grpcio grpcio-tools
```

2. Compile the proto file to generate the necessary Python code:
```bash
python -m grpc_tools.protoc -I. --python_out=. --grpc_python_out=. ai_gateway.proto
```

3. Run the client:
```
python client.py
```