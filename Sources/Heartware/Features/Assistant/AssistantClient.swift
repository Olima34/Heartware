import Foundation

/// The Claude models the user can pick. Opus 5.5 is the default; the cheaper ones are the user's call.
enum AssistantModelChoice: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    case fable = "claude-fable-5-1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .sonnet: return "Claude Sonnet 5.5"
        case .haiku: return "Claude Haiku 5.5"
        case .fable: return "Claude Fable 5.1"
        }
    }

    /// Without the version: Claude Code picks the latest model of each family.
    var familyTitle: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .fable: return "Fable"
        }
    }

    var subscriptionDetail: String {
        switch self {
        case .opus: return "solide pour le complexe comme pour le quotidien"
        case .sonnet: return "rapide et efficace pour les demandes simples"
        case .haiku: return "le plus rapide, pour une réponse courte"
        case .fable: return "le plus puissant, consomme plus vite ton quota"
        }
    }

    var detail: String {
        switch self {
        case .opus: return "Le plus capable · 4 $ / 20 $ par million de jetons"
        case .sonnet: return "Rapide et capable · 2 $ / 10 $ par million de jetons"
        case .haiku: return "Le plus économique · 0,10 $ / 0,50 $ par million de jetons"
        case .fable: return "Le plus puissant · 10 $ / 50 $ par million de jetons"
        }
    }

    /// Dollars per million tokens (input, output, cache read).
    var prices: (input: Double, output: Double, cacheRead: Double) {
        switch self {
        case .opus: return (4, 20, 0.20)
        case .sonnet: return (2, 10, 0.20)
        case .haiku: return (0.10, 0.50, 0.01)
        case .fable: return (10, 50, 0.25)
        }
    }

    /// Server-side refusal fallback: available for Opus 5.5 and Sonnet 5.5, not for Haiku 5.5.
    var supportsFallback: Bool { self != .haiku }
}

/// A reply from the Messages API, reduced to what the assistant needs.
struct AssistantReply {
    var stopReason: String
    var refusalCategory: String?
    /// The assistant `content` array, kept byte-for-byte to be sent back unchanged (thinking blocks included).
    var rawContent: [[String: Any]]
    var texts: [String]
    var toolUses: [(id: String, name: String, input: [String: Any])]
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
}

enum AssistantFailure: LocalizedError {
    case noKey, badKey, rateLimited(String?), overloaded, server(Int, String), network(String), malformed

    var errorDescription: String? {
        switch self {
        case .noKey: return "Ajoute d'abord ta clé API Anthropic."
        case .badKey: return "La clé API a été refusée. Vérifie-la dans la console Anthropic."
        case .rateLimited(let after): return "Trop de demandes d'un coup. Réessaie" + (after.map { " dans \($0) s." } ?? " dans un instant.")
        case .overloaded: return "Les serveurs d'Anthropic sont très sollicités. Réessaie dans un instant."
        case .server(let code, let message): return "Erreur \(code) : \(message)"
        case .network(let m): return "Connexion impossible : \(m)"
        case .malformed: return "Réponse inattendue du serveur."
        }
    }
}

/// Raw HTTP calls to `POST /v1/messages` (there is no official Swift SDK), through `HTTP` (HTTPS, logged, inert in demo).
enum AssistantClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let keyAccount = "anthropic-api-key"

    /// The JSON body of one request. Kept deterministic (sorted tools, stable system prompt) so the prompt cache hits.
    static func body(model: AssistantModelChoice, system: String, messages: [[String: Any]], tools: [[String: Any]],
                     effort: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 16000,
            "system": system,
            "messages": messages,
            "output_config": ["effort": effort],
            // Caches the stable prefix (tools + system + earlier turns) automatically.
            "cache_control": ["type": "ephemeral"]
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"] // forced tool use is refused by these models
        }
        if model.supportsFallback {
            // On a safety decline, the API retries on the model Anthropic recommends for that category.
            body["fallbacks"] = "default"
        }
        return body
    }

    static func headers(apiKey: String, model: AssistantModelChoice) -> [String: String] {
        var h = ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        if model.supportsFallback { h["anthropic-beta"] = "server-side-fallback-2026-07-01" }
        return h
    }

    static func send(body: [String: Any], apiKey: String, model: AssistantModelChoice) async throws -> AssistantReply {
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { throw AssistantFailure.malformed }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 300 // thinking can take a while before the first byte
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        headers(apiKey: apiKey, model: model).forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let (responseData, response): (Data, HTTPURLResponse)
        do {
            (responseData, response) = try await HTTP.sendKeepingErrors(request, patient: true)
        } catch let e as HTTP.Failure {
            throw AssistantFailure.network(e.localizedDescription)
        } catch {
            throw AssistantFailure.network(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            switch response.statusCode {
            case 401, 403: throw AssistantFailure.badKey
            case 429: throw AssistantFailure.rateLimited(response.value(forHTTPHeaderField: "retry-after"))
            case 529: throw AssistantFailure.overloaded
            default: throw AssistantFailure.server(response.statusCode, message)
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { throw AssistantFailure.malformed }
        return parse(json)
    }

    /// Reads a Messages API response. Always check `stopReason` before trusting the content.
    static func parse(_ json: [String: Any]) -> AssistantReply {
        let content = json["content"] as? [[String: Any]] ?? []
        let usage = json["usage"] as? [String: Any] ?? [:]
        var texts: [String] = []
        var tools: [(String, String, [String: Any])] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.isEmpty { texts.append(t) }
            case "tool_use":
                if let id = block["id"] as? String, let name = block["name"] as? String {
                    tools.append((id, name, block["input"] as? [String: Any] ?? [:]))
                }
            default:
                break // thinking, fallback markers…: kept in rawContent, not shown
            }
        }
        let stopDetails = json["stop_details"] as? [String: Any]
        return AssistantReply(stopReason: json["stop_reason"] as? String ?? "end_turn",
                              refusalCategory: stopDetails?["category"] as? String,
                              rawContent: content, texts: texts, toolUses: tools,
                              model: json["model"] as? String ?? "",
                              inputTokens: usage["input_tokens"] as? Int ?? 0,
                              outputTokens: usage["output_tokens"] as? Int ?? 0,
                              cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                              cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0)
    }

    // MARK: Tools

    /// A strict tool definition (arguments always match the schema).
    static func tool(_ name: String, _ description: String, properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "strict": true,
            "input_schema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false
            ] as [String: Any]
        ]
    }
}
