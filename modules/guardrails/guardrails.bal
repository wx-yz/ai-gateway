// Add guardrails configuration type
public type GuardrailConfig record {
    string[] bannedPhrases;
    int minLength;
    int maxLength;
    boolean requireDisclaimer;
    string disclaimer?;
};

// Add guardrails storage
isolated GuardrailConfig guardrails = {
    bannedPhrases: [],
    minLength: 0,
    maxLength: 500000,
    requireDisclaimer: false
};

// Add guardrails processing function
public isolated function applyGuardrails(string text) returns string|error {
    lock {
        if (text.length() < guardrails.minLength) {
            return error("Response too short. Minimum length: " + guardrails.minLength.toString());
        }
        string textRes = text;
        if (text.length() > guardrails.maxLength) {
            textRes = text.substring(0, guardrails.maxLength);
        }

        foreach string phrase in guardrails.bannedPhrases {
            if (text.toLowerAscii().includes(phrase)) {
                return error("Response contains banned phrase: " + phrase);
            }
        }

        if (guardrails.requireDisclaimer && guardrails.disclaimer != null) {
            textRes = text + "\n\n" + (guardrails.disclaimer ?: "");
        }
        return textRes;
    }
}

public isolated function getGuardrails() returns GuardrailConfig {
    lock {
        return guardrails.cloneReadOnly();
    }
}

public isolated function setGuardrails(GuardrailConfig grails) {
    lock {
        guardrails = grails.cloneReadOnly();
    }
}