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
# + clientPlan - The client-specific rate limit plan (optional)
# + return - [boolean, int, int, int, string] - A tuple containing:
#            [0] - Whether the request is allowed (true) or rejected due to rate limiting (false)
#            [1] - The maximum number of requests allowed in the current window
#            [2] - The number of remaining requests allowed in the current window
#            [3] - The number of seconds until the current rate limit window resets
#            [4] - The type of plan applied ("client-specific", "wildcard", or "default")
#            error - If rate limit checking fails for any reason
public isolated function checkRateLimit(string clientIP, ClientRateLimitPlan? clientPlan = ()) returns 
        [boolean, int, int, int, string]|error {

    // Skip rate limiting for empty IP addresses
    if clientIP == "" {
        return [true, 0, 0, 0, ""];
    }
    // Check if client has a specific rate limit plan
    ClientRateLimitPlan? effectiveClientPlan = clientPlan;
    ClientRateLimitPlan? wildcardPlan;  // For "*.*.*.*" wildcard rate limit
    RateLimitPlan? defaultPlan;

    if effectiveClientPlan == () {
        lock {
            effectiveClientPlan = clientRateLimitPlans.cloneReadOnly()[clientIP];
        }
    }
    lock {
        wildcardPlan = clientRateLimitPlans.cloneReadOnly()[WILDCARD_IP];
    }
    lock {
        defaultPlan = currentRateLimitPlan.cloneReadOnly();
    }

    // Precedence: specific client plan > wildcard plan > default plan
    // If no plan is available (at any level), allow the request
    if effectiveClientPlan == () && wildcardPlan == () && defaultPlan == () {
        return [true, 0, 0, 0, ""];
    }

    // Determine the applicable rate limit plan
    ClientRateLimitPlan? applicablePlan;
    string planType;
    if effectiveClientPlan != () {
        applicablePlan = effectiveClientPlan;
        planType = "client-specific";
    } else if wildcardPlan != () {
        applicablePlan = wildcardPlan;
        planType = "wildcard";
    } else {
        applicablePlan = ();
        planType = "default";
    }

    // Get the rate limit state for the client
    RateLimitState state;

    map<RateLimitState> rlStatesLocal;
    lock {
        rlStatesLocal = rateLimitStates.cloneReadOnly();
    }
    state = rlStatesLocal[clientIP] ?: {requests: 0, windowStart: 0};

    // Get the current time
    int currentTime = time:utcNow()[0];

    // Calculate the remaining time in the current window
    int windowSeconds = applicablePlan != () ? applicablePlan.windowSeconds : defaultPlan?.windowSeconds ?: 0;
    int windowStart = state.windowStart;
    int windowEnd = windowStart + windowSeconds;
    int remainingTime = windowEnd - currentTime;

    // Check if the current window has expired
    if remainingTime <= 0 {
        // Reset the rate limit state for the new window
        lock {
            rateLimitStates[clientIP] = {requests: 1, windowStart: currentTime};
        }
        return [true, 
                applicablePlan?.requestsPerWindow ?: defaultPlan?.requestsPerWindow ?: 
                    0, (applicablePlan?.requestsPerWindow ?: defaultPlan?.requestsPerWindow ?: 0) - 1, windowSeconds, planType];
    }

    // Check if the client has exceeded their rate limit
    int requestsPerWindow = applicablePlan?.requestsPerWindow ?: defaultPlan?.requestsPerWindow ?: 0;
    if state.requests >= requestsPerWindow {
        return [false, requestsPerWindow, 0, remainingTime, planType];
    }

    // Increment the request count for the current window
    lock {
        rateLimitStates[clientIP] = {requests: state.requests + 1, windowStart: windowStart};
    }

    return [true, requestsPerWindow, requestsPerWindow - state.requests - 1, remainingTime, planType];
}