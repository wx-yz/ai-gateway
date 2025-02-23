import ballerina/grpc;
import ballerina/protobuf;

public const string AI_GATEWAY_DESC = "0A1061695F676174657761792E70726F746F120A61695F6761746577617922AC010A1543686174436F6D706C6574696F6E5265717565737412210A0C6C6C6D5F70726F7669646572180120012809520B6C6C6D50726F7669646572122F0A086D6573736167657318022003280B32132E61695F676174657761792E4D65737361676552086D6573736167657312200A0B74656D7065726174757265180320012802520B74656D7065726174757265121D0A0A6D61785F746F6B656E7318042001280552096D6178546F6B656E7322370A074D65737361676512120A04726F6C651801200128095204726F6C6512180A07636F6E74656E741802200128095207636F6E74656E7422C7010A1643686174436F6D706C6574696F6E526573706F6E7365120E0A0269641801200128095202696412160A066F626A65637418022001280952066F626A65637412180A076372656174656418032001280352076372656174656412140A056D6F64656C18042001280952056D6F64656C122C0A0763686F6963657318052003280B32122E61695F676174657761792E43686F696365520763686F6963657312270A05757361676518062001280B32112E61695F676174657761792E55736167655205757361676522720A0643686F69636512140A05696E6465781801200128055205696E646578122D0A076D65737361676518022001280B32132E61695F676174657761792E4D65737361676552076D65737361676512230A0D66696E6973685F726561736F6E180320012809520C66696E697368526561736F6E227C0A05557361676512230A0D70726F6D70745F746F6B656E73180120012805520C70726F6D7074546F6B656E73122B0A11636F6D706C6574696F6E5F746F6B656E731802200128055210636F6D706C6574696F6E546F6B656E7312210A0C746F74616C5F746F6B656E73180320012805520B746F74616C546F6B656E7332640A0941494761746577617912570A0E43686174436F6D706C6574696F6E12212E61695F676174657761792E43686174436F6D706C6574696F6E526571756573741A222E61695F676174657761792E43686174436F6D706C6574696F6E526573706F6E7365620670726F746F33";

public isolated client class AIGatewayClient {
    *grpc:AbstractClientEndpoint;

    private final grpc:Client grpcClient;

    public isolated function init(string url, *grpc:ClientConfiguration config) returns grpc:Error? {
        self.grpcClient = check new (url, config);
        check self.grpcClient.initStub(self, AI_GATEWAY_DESC);
    }

    isolated remote function ChatCompletion(ChatCompletionRequest|ContextChatCompletionRequest req) returns ChatCompletionResponse|grpc:Error {
        map<string|string[]> headers = {};
        ChatCompletionRequest message;
        if req is ContextChatCompletionRequest {
            message = req.content;
            headers = req.headers;
        } else {
            message = req;
        }
        var payload = check self.grpcClient->executeSimpleRPC("ai_gateway.AIGateway/ChatCompletion", message, headers);
        [anydata, map<string|string[]>] [result, _] = payload;
        return <ChatCompletionResponse>result;
    }

    isolated remote function ChatCompletionContext(ChatCompletionRequest|ContextChatCompletionRequest req) returns ContextChatCompletionResponse|grpc:Error {
        map<string|string[]> headers = {};
        ChatCompletionRequest message;
        if req is ContextChatCompletionRequest {
            message = req.content;
            headers = req.headers;
        } else {
            message = req;
        }
        var payload = check self.grpcClient->executeSimpleRPC("ai_gateway.AIGateway/ChatCompletion", message, headers);
        [anydata, map<string|string[]>] [result, respHeaders] = payload;
        return {content: <ChatCompletionResponse>result, headers: respHeaders};
    }
}

public isolated client class AIGatewayChatCompletionResponseCaller {
    private final grpc:Caller caller;

    public isolated function init(grpc:Caller caller) {
        self.caller = caller;
    }

    public isolated function getId() returns int {
        return self.caller.getId();
    }

    isolated remote function sendChatCompletionResponse(ChatCompletionResponse response) returns grpc:Error? {
        return self.caller->send(response);
    }

    isolated remote function sendContextChatCompletionResponse(ContextChatCompletionResponse response) returns grpc:Error? {
        return self.caller->send(response);
    }

    isolated remote function sendError(grpc:Error response) returns grpc:Error? {
        return self.caller->sendError(response);
    }

    isolated remote function complete() returns grpc:Error? {
        return self.caller->complete();
    }

    public isolated function isCancelled() returns boolean {
        return self.caller.isCancelled();
    }
}

public type ContextChatCompletionRequest record {|
    ChatCompletionRequest content;
    map<string|string[]> headers;
|};

public type ContextChatCompletionResponse record {|
    ChatCompletionResponse content;
    map<string|string[]> headers;
|};

@protobuf:Descriptor {value: AI_GATEWAY_DESC}
public type ChatCompletionRequest record {|
    string llm_provider = "";
    Message[] messages = [];
    float temperature = 0.0;
    int max_tokens = 0;
|};

@protobuf:Descriptor {value: AI_GATEWAY_DESC}
public type Usage record {|
    int prompt_tokens = 0;
    int completion_tokens = 0;
    int total_tokens = 0;
|};

@protobuf:Descriptor {value: AI_GATEWAY_DESC}
public type Choice record {|
    int index = 0;
    Message message = {};
    string finish_reason = "";
|};

@protobuf:Descriptor {value: AI_GATEWAY_DESC}
public type Message record {|
    string role = "";
    string content = "";
|};

@protobuf:Descriptor {value: AI_GATEWAY_DESC}
public type ChatCompletionResponse record {|
    string id = "";
    string 'object = "";
    int created = 0;
    string model = "";
    Choice[] choices = [];
    Usage usage = {};
|};
