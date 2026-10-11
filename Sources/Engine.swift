import Foundation

/// Which model writes the answers.
///
/// Two can, and both run on this Mac:
///   • Apple's on-device model, which needs nothing installed.
///   • Any model served by Ollama on this machine, the same ones my Aether chat
///     app uses. These are usually larger, so they answer better and can be
///     given more of each page, at the cost of memory and speed.
///
/// The choice is kept in the app's settings. "Automatic" uses Apple's model when
/// it is ready and otherwise the first Ollama model it finds.

enum Ollama {
    static let host = "http://127.0.0.1:11434"

    private static func send(_ request: URLRequest) -> Data? {
        var result: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    /// The models Ollama has, or none when it is not running. Answers within a
    /// second or so either way, so it is safe to call while drawing the screen.
    static func models() -> [String] {
        var request = URLRequest(url: URL(string: "\(host)/api/tags")!)
        request.timeoutInterval = 1.2
        guard let data = send(request) else { return [] }
        return names(inTags: data)
    }

    static func names(inTags data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        // Models that only make vectors cannot hold a conversation.
        return models.compactMap { $0["name"] as? String }.filter { !$0.lowercased().contains("embed") }.sorted()
    }

    static func answer(model: String, instructions: String, prompt: String) throws -> String {
        var request = URLRequest(url: URL(string: "\(host)/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": instructions], ["role": "user", "content": prompt]],
            "options": ["temperature": 0.2, "num_ctx": 8192],
        ])
        guard let data = send(request), let text = reply(in: data) else {
            throw NSError(domain: "SlideView", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama did not answer. Check it is running and the model is installed."])
        }
        return text
    }

    static func reply(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any], let text = message["content"] as? String else { return nil }
        // Some models think out loud first; only what follows is the answer.
        let answer = text.components(separatedBy: "</think>").last ?? text
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Engine {
    struct State { var ready: Bool; var reason: String; var label: String }

    private static let key = "assistantEngine"

    /// "auto", "apple" or "ollama:<model name>".
    static var choice: String {
        get { UserDefaults.standard.string(forKey: key) ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The engine a choice comes down to, given what is available right now.
    static func resolve(_ choice: String, appleReady: Bool, ollama: [String]) -> String {
        if choice.hasPrefix("ollama:") {
            let model = String(choice.dropFirst("ollama:".count))
            return ollama.contains(model) ? choice : (appleReady ? "apple" : (ollama.first.map { "ollama:\($0)" } ?? "apple"))
        }
        if choice == "apple" || appleReady { return "apple" }
        return ollama.first.map { "ollama:\($0)" } ?? "apple"
    }

    private static func current() -> (engine: String, apple: OnDeviceModel.State, ollama: [String]) {
        let apple = OnDeviceModel.state
        let chosen = choice
        // Only ask Ollama what it has when the answer could matter.
        let ollama = (chosen.hasPrefix("ollama:") || !apple.ready) ? Ollama.models() : []
        return (resolve(chosen, appleReady: apple.ready, ollama: ollama), apple, ollama)
    }

    static var state: State {
        let now = current()
        if now.engine.hasPrefix("ollama:") {
            return State(ready: true, reason: "", label: String(now.engine.dropFirst("ollama:".count)) + " through Ollama")
        }
        return State(ready: now.apple.ready, reason: now.apple.reason, label: "Apple Intelligence")
    }

    /// How many characters of notes the engine in use can take in. Apple's model
    /// has a short memory; an Ollama model is given a longer one.
    static var budget: Int { current().engine.hasPrefix("ollama:") ? 9000 : 4200 }

    static func answer(instructions: String, prompt: String) throws -> String {
        let now = current()
        if now.engine.hasPrefix("ollama:") {
            return try Ollama.answer(model: String(now.engine.dropFirst("ollama:".count)), instructions: instructions, prompt: prompt)
        }
        return try OnDeviceModel.answer(instructions: instructions, prompt: prompt)
    }

    /// What the picker shows.
    static func options() -> [String: Any] {
        let apple = OnDeviceModel.state
        let ollama = Ollama.models()
        var list: [[String: Any]] = [
            ["id": "auto", "label": "Automatic"],
            ["id": "apple", "label": apple.ready ? "Apple Intelligence" : "Apple Intelligence (not ready)"],
        ]
        list += ollama.map { ["id": "ollama:\($0)", "label": "\($0) (Ollama)"] }
        return ["choice": choice, "using": resolve(choice, appleReady: apple.ready, ollama: ollama),
                "options": list, "ollama": !ollama.isEmpty]
    }
}
