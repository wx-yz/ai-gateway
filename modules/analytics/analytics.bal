

// Simple HTML template engine
public isolated function renderTemplate(string template, map<string> values) returns string {
    string result = template;
    
    foreach var [key, value] in values.entries() {
        // result = result.replace("{{" + key + "}}", value);
        string:RegExp pattern = re `\{\{${key}\}\}`;
        result = pattern.replace(result, value);
    }
    return result;
}