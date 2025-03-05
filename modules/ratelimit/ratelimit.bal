import ballerina/time;

// Add rate limiting types and storage
public type RateLimitPlan record {|
    string name;
    int requestsPerWindow;
    int windowSeconds;
|};

// Add client-specific rate limit plan
public type ClientRateLimitPlan record {|
    string clientIP;
    string name;
    int requestsPerWindow;
    int windowSeconds;
|};

public type RateLimitState record {|
    int requests;
    int windowStart;
|};

// Default rate limit plan for clients without specific plans
isolated RateLimitPlan? currentRateLimitPlan = ();

// Store client-specific rate limit plans
isolated map<ClientRateLimitPlan> clientRateLimitPlans = {};

// Store rate limit states by IP
isolated map<RateLimitState> rateLimitStates = {};

// Add a constant for the wildcard IP pattern
public const string WILDCARD_IP = "*.*.*.*";

public isolated function getCurrentRateLimit() returns RateLimitPlan? {
    lock {
        return currentRateLimitPlan.cloneReadOnly();
    }
}

public isolated function setCurrentRateLimit(RateLimitPlan? plan) {
    lock {
        currentRateLimitPlan = plan.cloneReadOnly();
    }
    string[] rlKeys;
    lock {
        rlKeys = rateLimitStates.cloneReadOnly().keys();
    }
    // lock {
        // Reset rate limit states when changing the default rate limit plan
        // Only reset for clients using the default plan, not those with custom plans
        map<RateLimitState> newStates = {};
        foreach string key in rlKeys {
            lock {
                if !clientRateLimitPlans.hasKey(key) {
                    continue;
                }
            }
            RateLimitState newState;
            lock {
                newState = rateLimitStates.cloneReadOnly()[key] ?: {requests: 0, windowStart: 0};
            }
            newStates[key] = newState;
        }
        lock {
            rateLimitStates = newStates.cloneReadOnly();
        }
    // }
}

// Add client-specific rate limit plan
public isolated function setClientRateLimit(ClientRateLimitPlan clientPlan) {
    lock {
        clientRateLimitPlans[clientPlan.clientIP] = clientPlan.cloneReadOnly();
    }
    lock {
        // Reset the state for this specific client
        rateLimitStates[clientPlan.clientIP] = <readonly & RateLimitState>{
            requests: 0,
            windowStart: time:utcNow()[0]
        };
    }
}

// Remove client-specific rate limit plan
public isolated function removeClientRateLimit(string clientIP) {
    lock {
        _ = clientRateLimitPlans.remove(clientIP);
    }
    lock {
        // Reset the state for this specific client
        _ = rateLimitStates.remove(clientIP);
    }
}

// Get client-specific rate limit plan
public isolated function getClientRateLimit(string clientIP) returns ClientRateLimitPlan? {
    lock {
        if clientRateLimitPlans.hasKey(clientIP) {
            return clientRateLimitPlans[clientIP].cloneReadOnly();
        }
    }
    return ();
}

// Get all client-specific rate limit plans
public isolated function getAllClientRateLimits() returns map<ClientRateLimitPlan> {
    lock {
        return clientRateLimitPlans.cloneReadOnly();
    }
}

// Get current rate limit states (for debugging)
public isolated function getRateLimitStates() returns map<RateLimitState> {
    lock {
        return rateLimitStates.cloneReadOnly();
    }
}

# Checks if a client has exceeded their rate limit according to their rate limit plan
# Uses client-specific plan if available, otherwise falls back to the default plan
# 
# + clientIP - The IP address of the client making the request
# + return - [boolean, int, int, int, string] - A tuple containing:
#            [0] - Whether the request is allowed (true) or rejected due to rate limiting (false)
#            [1] - The maximum number of requests allowed in the current window
#            [2] - The number of remaining requests allowed in the current window
#            [3] - The number of seconds until the current rate limit window resets
#            [4] - The type of plan applied ("client-specific", "wildcard", or "default")
#            error - If rate limit checking fails for any reason
public isolated function checkRateLimit(string clientIP) returns [boolean, int, int, int, string]|error {
    // Skip rate limiting for empty IP addresses
    if clientIP == "" {
        return [true, 0, 0, 0, ""];
    }
    
    // Check if client has a specific rate limit plan
    ClientRateLimitPlan? clientPlan;
    ClientRateLimitPlan? wildcardPlan;  // For "*.*.*.*" wildcard rate limit
    RateLimitPlan? defaultPlan;
    
    lock {
        clientPlan = clientRateLimitPlans.cloneReadOnly()[clientIP];
    }
    lock {
        wildcardPlan = clientRateLimitPlans.cloneReadOnly()[WILDCARD_IP];
    }
    lock {
        defaultPlan = currentRateLimitPlan.cloneReadOnly();
    }
    
    // Precedence: specific client plan > wildcard plan > default plan
    // If no plan is available (at any level), allow the request
    if clientPlan == () && wildcardPlan == () && defaultPlan == () {
        return [true, 0, 0, 0, ""];
    }
    
    int requestsPerWindow;
    int windowSeconds;
    string planType; // For logging/debugging
    
    // Use client-specific plan if available
    if clientPlan != () {
        requestsPerWindow = clientPlan.requestsPerWindow;
        windowSeconds = clientPlan.windowSeconds;
        planType = "client-specific";
    } 
    // Otherwise use wildcard plan if available
    else if wildcardPlan != () {
        requestsPerWindow = wildcardPlan.requestsPerWindow;
        windowSeconds = wildcardPlan.windowSeconds;
        planType = "wildcard";
    } 
    // Finally fall back to default plan
    else {
        RateLimitPlan plan = <RateLimitPlan>defaultPlan;
        requestsPerWindow = plan.requestsPerWindow;
        windowSeconds = plan.windowSeconds;
        planType = "default";
    }
    
    int currentTime = time:utcNow()[0];

    lock {
        RateLimitState|error curStates = rateLimitStates[clientIP].cloneWithType(RateLimitState);
        RateLimitState state;
        if curStates is error {
            state = {
                requests: 0,
                windowStart: currentTime
            };
        } else {
            state = curStates;
        }
        
        // Check if we need to reset window
        if (currentTime - state.windowStart >= windowSeconds) {
            state = {
                requests: 0,
                windowStart: currentTime
            };
        }
        
        // Calculate remaining quota and time
        int remaining = requestsPerWindow - state.requests;
        int resetSeconds = windowSeconds - (currentTime - state.windowStart);

        // Check if rate limit is exceeded
        if (state.requests >= requestsPerWindow) {
            rateLimitStates[clientIP] = state;
            return [false, requestsPerWindow, remaining, resetSeconds, planType];
        }
        
        // Increment request count
        state.requests += 1;
        rateLimitStates[clientIP] = state;

        return [true, requestsPerWindow, remaining - 1, resetSeconds, planType];
    }
}