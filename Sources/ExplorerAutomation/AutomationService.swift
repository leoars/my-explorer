// SPDX-License-Identifier: Apache-2.0
import Foundation
import ExplorerCore
import Darwin

public struct AutomationEnvironment: Sendable {
    public var connections: @Sendable () async -> [CloudConnection]
    public var revision: @Sendable () async -> String
    public var authenticate: @Sendable (CloudConnection) async -> Void
    public var authenticated: @Sendable (UUID) async -> Bool
    public var apply: @Sendable (CloudConnection) async throws -> Void
    public var preferences: @Sendable () async -> JSONValue
    public var updatePreferences: @Sendable (JSONValue) async throws -> JSONValue
    public init(connections: @escaping @Sendable () async -> [CloudConnection], revision: @escaping @Sendable () async -> String,
                authenticate: @escaping @Sendable (CloudConnection) async -> Void, authenticated: @escaping @Sendable (UUID) async -> Bool,
                apply: @escaping @Sendable (CloudConnection) async throws -> Void,
                preferences: @escaping @Sendable () async -> JSONValue, updatePreferences: @escaping @Sendable (JSONValue) async throws -> JSONValue) {
        self.connections = connections; self.revision = revision; self.authenticate = authenticate; self.authenticated = authenticated
        self.apply = apply; self.preferences = preferences; self.updatePreferences = updatePreferences
    }
}
public struct AutomationJob: Codable, Sendable, Identifiable {
    public var id: UUID
    public var clientID: UUID
    public var planID: UUID
    public var key: String
    public var kind: String
    public var state: String
    public var completed: [String]
    public var completedCount: Int = 0
    public var indeterminate: [String] = []
    public var error: String?
    public var progress: JSONValue?
    public var updated: Date
}
private struct AuditEvent: Codable, Sendable {
    var date: Date; var clientID: UUID; var method: String; var result: String
}
private struct ServiceState: Codable {
    var enabled = false
    var grants: [AutomationGrant] = []
    var jobs: [AutomationJob] = []
    var audit: [AuditEvent] = []
}
private struct OperationPlan: Sendable {
    var id: UUID; var clientID: UUID; var kind: String; var sources: [URL]; var destination: URL?
    var expires: Date; var revision: String; var snapshot: [String: String]
    var recursive: Bool; var conflict: String; var deletionID: UUID?; var count: Int
}
private struct ConnectionPlan: Sendable { var id: UUID; var clientID: UUID; var connection: CloudConnection; var expires: Date }

public actor AutomationService {
    public let files: SharedFileOperations
    private let deletion: StorageDeletionService
    private let environment: AutomationEnvironment
    private let stateURL: URL
    private var state: ServiceState
    private var plans: [UUID: OperationPlan] = [:]
    private var connectionPlans: [UUID: ConnectionPlan] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isShuttingDown = false
    // OCR text and source requests are deliberately ephemeral, never part of persisted ServiceState.
    private var ocrRequests: [UUID: OCRRequest] = [:]
    private var ocrResults: [UUID: JSONValue] = [:]
    private var ocrPDFRequests: [UUID: SearchablePDFRequest] = [:]
    private var ocrPDFBatchRequests: [UUID: SearchablePDFBatchRequest] = [:]
    private var ocrPDFScopes: [UUID: Set<URL>] = [:]
    public init(files: SharedFileOperations, deletion: StorageDeletionService? = nil, environment: AutomationEnvironment, stateURL: URL) throws {
        self.files = files; self.deletion = deletion ?? StorageDeletionService(clientFactory: files.clientFactory)
        self.environment = environment; self.stateURL = stateURL
        if FileManager.default.fileExists(atPath: stateURL.path) {
            state = try JSONDecoder().decode(ServiceState.self, from: Data(contentsOf: stateURL))
        } else { state = ServiceState() }
        for index in state.jobs.indices {
            let job = state.jobs[index]
            if ["queued", "running", "cancelling"].contains(job.state) || (job.kind == "ocr" && job.state == "succeeded") {
                state.jobs[index].state = "needs_input"; state.jobs[index].error = AutomationError.interrupted.rawValue
            }
        }
    }
    public func isEnabled() -> Bool { state.enabled }
    public func grants() -> [AutomationGrant] { state.grants }
    public func setEnabled(_ enabled: Bool) throws {
        let previous = state.enabled
        state.enabled = enabled
        if !enabled { for task in tasks.values { task.cancel() }; ocrResults.removeAll() }
        do { try persist() } catch { if enabled { state.enabled = previous }; throw error }
    }
    public func grant(_ grant: AutomationGrant) throws {
        guard grant.expires > Date(), !grant.name.isEmpty, grant.name.count <= 120 else { throw AutomationError.invalidArguments }
        let previous = state.grants
        state.grants.removeAll { $0.id == grant.id }; state.grants.append(grant)
        do { try persist() } catch { state.grants = previous; throw error }
        for job in state.jobs where job.clientID == grant.id {
            ocrResults.removeValue(forKey: job.id)
            // Authorization may already have completed while publication waits for its worker.
            // Cancel on any grant update so the core's atomic publication gate sees the change.
            // A receipt from a commit that already began remains authoritative.
            if ["ocrPDF", "ocrPDFBatch"].contains(job.kind) { tasks[job.id]?.cancel() }
        }
    }
    public func revoke(_ id: UUID) throws {
        state.grants.removeAll { $0.id == id }
        for job in state.jobs where job.clientID == id { tasks[job.id]?.cancel(); ocrResults.removeValue(forKey: job.id) }
        try persist()
    }
    public func shutdown() async {
        isShuttingDown = true
        for task in tasks.values { task.cancel() }
        ocrResults.removeAll()
        let running = Array(tasks.values)
        for task in running { await task.value }
        try? persist()
    }
    private func persist() throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    private func checkedGrant(_ id: UUID, operation: String, url: URL? = nil) throws -> AutomationGrant {
        guard state.enabled, !isShuttingDown else { throw AutomationError.disabled }
        guard let grant = state.grants.first(where: { $0.id == id }), grant.permits(operation, at: url) else { throw AutomationError.forbidden }
        return grant
    }
    private func authorize(_ request: AutomationRequest) throws -> UUID {
        guard state.enabled, !isShuttingDown else { throw AutomationError.disabled }
        guard let rawID = request.clientID, let id = UUID(uuidString: rawID), let token = request.token,
              let grant = state.grants.first(where: { $0.id == id }), grant.expires > Date(), grant.authenticates(token) else { throw AutomationError.unauthenticated }
        return id
    }
    public func handle(_ request: AutomationRequest) async -> AutomationResponse {
        if request.method == "capabilities.get" {
            return AutomationResponse(ok: true, result: .object([
                "schemaVersion": .number(1), "enabled": .bool(state.enabled), "providers": .array([.string("s3"), .string("azure"), .string("gcs")]),
                "localDeletion": .string("trash"), "remoteDeletion": .string("conditional_current_object"),
                "cloudToCloud": .bool(false), "infrastructureProvisioning": .bool(false), "maximumPlanItems": .number(10000),
                "ocr": .object(["localOnly": .bool(true), "operation": .string("files.ocr"), "ephemeralResults": .bool(true),
                                "searchablePDFOperation": .string("files.ocr.pdf"), "searchablePDFRequiresNewDestination": .bool(true)])
            ]))
        }
        var client: UUID?
        do {
            let id = try authorize(request); client = id
            guard AutomationToolCatalog.validate(method: request.method, arguments: request.arguments) else { throw AutomationError.invalidArguments }
            let expired = plans.values.filter { $0.expires <= Date() }
            for plan in expired {
                plans[plan.id] = nil
                if let deletionID = plan.deletionID { await deletion.discard(planID: deletionID) }
            }
            connectionPlans = connectionPlans.filter { $0.value.expires > Date() }
            let result = try await dispatch(request.method, request.arguments, id: id)
            audit(id, method: request.method, result: "ok")
            return AutomationResponse(ok: true, result: result)
        } catch {
            let code = Self.errorCode(error)
            if let client { audit(client, method: request.method, result: code) }
            return AutomationResponse(ok: false, error: code)
        }
    }
    private func audit(_ id: UUID, method: String, result: String) {
        // No parameters, paths, credentials, tokens, or provider bodies in the audit trail.
        state.audit.append(AuditEvent(date: Date(), clientID: id, method: String(method.prefix(80)), result: result))
        if state.audit.count > 1000 { state.audit.removeFirst(state.audit.count - 1000) }
        try? persist()
    }
    private func dispatch(_ method: String, _ args: JSONValue, id: UUID) async throws -> JSONValue {
        guard let object = args.objectValue else { throw AutomationError.invalidArguments }
        switch method {
        case "connections.list":
            try keys(object, [])
            let grant = try checkedGrant(id, operation: "read")
            let connections = await environment.connections().filter { connection in grant.cloudScopes.contains { $0.connectionID == connection.id } }
            return .object(["connections": try json(connections)])
        case "connections.prepare":
            try keys(object, ["name", "provider", "bucket", "region", "account"])
            _ = try checkedGrant(id, operation: "configure")
            guard let provider = CloudProvider(rawValue: try string(args, "provider")) else { throw AutomationError.invalidArguments }
            let name = try string(args, "name"), bucket = try string(args, "bucket")
            guard name.count <= 120, bucket.count <= 255 else { throw AutomationError.invalidArguments }
            let connection = CloudConnection(name: name, provider: provider, bucket: bucket, region: args["region"]?.stringValue, account: args["account"]?.stringValue)
            if provider == .s3 && (connection.region?.isEmpty != false) { throw AutomationError.invalidArguments }
            if provider == .azure && (connection.account?.isEmpty != false) { throw AutomationError.invalidArguments }
            let plan = ConnectionPlan(id: UUID(), clientID: id, connection: connection, expires: Date().addingTimeInterval(900))
            guard connectionPlans.count < 100 else { throw AutomationError.limitExceeded }
            connectionPlans[plan.id] = plan
            return .object(["planID": .string(plan.id.uuidString), "connection": try json(connection), "expiresAt": .string(iso(plan.expires))])
        case "connections.authenticate", "connections.validate", "connections.apply":
            try keys(object, ["planID"])
            _ = try checkedGrant(id, operation: "configure")
            let planID = try uuid(args, "planID")
            guard let plan = connectionPlans[planID], plan.clientID == id else { throw AutomationError.notFound }
            guard plan.expires > Date() else { connectionPlans[planID] = nil; throw AutomationError.expiredPlan }
            if method == "connections.authenticate" { await environment.authenticate(plan.connection) }
            let ready = await environment.authenticated(plan.connection.id)
            _ = try checkedGrant(id, operation: "configure")
            if method == "connections.apply" {
                guard ready else { throw AutomationError.needsInput }
                try await environment.apply(plan.connection)
                connectionPlans[planID] = nil
                // Configuring does not silently confer file read/write access to a new connection.
                return .object(["connectionID": .string(plan.connection.id.uuidString), "state": .string("configured"), "accessGrantRequired": .bool(true)])
            }
            return .object(["state": .string(ready ? "read_access_verified_during_authentication" : "needs_input"), "credentialRef": ready ? .string(plan.connection.id.uuidString) : .null, "writeAccessVerified": .bool(false)])
        case "ocr.languages":
            try checkOCRDiscoveryGrant(id)
            let languages = try await files.ocrLanguages()
            try checkOCRDiscoveryGrant(id)
            guard languages.count <= 256, languages.allSatisfy({ $0.utf8.count <= 64 }) else { throw AutomationError.limitExceeded }
            return .object(["languages": .array(languages.map(JSONValue.string))])
        case "files.ocr.pdf.batch":
            let sources = try (args["urls"]?.arrayValue ?? []).map { value -> URL in
                guard let value = value.stringValue else { throw AutomationError.invalidArguments }
                return try AutomationOCRLocation.parse(value)
            }
            guard (1...50).contains(sources.count) else { throw AutomationError.invalidArguments }
            let grant = try checkedGrant(id, operation: "files.ocr.pdf")
            guard sources.count <= min(50, grant.maximumItems) else { throw AutomationError.limitExceeded }
            let destination = try AutomationOCRLocation.parse(string(args, "destination"))
            for source in sources { try checkOCRGrant(id, url: source, operation: "files.ocr.pdf") }
            try checkOCRGrant(id, url: destination, operation: "files.ocr.pdf")
            guard tasks.isEmpty else { throw AutomationError.busy }
            let request = SearchablePDFBatchRequest(sourceURLs: sources, destinationDirectoryURL: destination,
                languages: args["languages"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            try reservePDFJob()
            let job = AutomationJob(id: UUID(), clientID: id, planID: UUID(), key: UUID().uuidString,
                                    kind: "ocrPDFBatch", state: "queued", completed: [], updated: Date())
            state.jobs.append(job)
            if state.jobs.count > 1000 { state.jobs.removeFirst(state.jobs.count - 1000) }
            do { try persist() } catch { state.jobs.removeAll { $0.id == job.id }; throw error }
            ocrPDFBatchRequests[job.id] = request
            ocrPDFScopes[job.id] = Set(sources + [destination])
            tasks[job.id] = Task { await executeSearchablePDFBatch(request, clientID: id, jobID: job.id) }
            return try json(job)
        case "files.ocr.pdf":
            let source = try AutomationOCRLocation.parse(string(args, "url"))
            let destination = try AutomationOCRLocation.parse(string(args, "destination"))
            try checkOCRGrant(id, url: source, operation: "files.ocr.pdf")
            try checkOCRGrant(id, url: destination, operation: "files.ocr.pdf")
            guard source != destination else { throw AutomationError.invalidArguments }
            guard tasks.isEmpty else { throw AutomationError.busy }
            let request = SearchablePDFRequest(sourceURL: source, destinationURL: destination,
                languages: args["languages"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            try reservePDFJob()
            let job = AutomationJob(id: UUID(), clientID: id, planID: UUID(), key: UUID().uuidString,
                                    kind: "ocrPDF", state: "queued", completed: [], updated: Date())
            state.jobs.append(job)
            if state.jobs.count > 1000 { state.jobs.removeFirst(state.jobs.count - 1000) }
            do { try persist() } catch { state.jobs.removeAll { $0.id == job.id }; throw error }
            ocrPDFRequests[job.id] = request
            ocrPDFScopes[job.id] = [source, destination]
            tasks[job.id] = Task { await executeSearchablePDF(request, clientID: id, jobID: job.id) }
            return try json(job)
        case "files.ocr":
            let url = try AutomationOCRLocation.parse(string(args, "url"))
            try checkOCRGrant(id, url: url)
            let languages = args["languages"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let pages: ClosedRange<Int>?
            if args["pageStart"] != nil || args["pageEnd"] != nil {
                guard args["pageStart"] != nil, args["pageEnd"] != nil else { throw AutomationError.invalidArguments }
                let first = try integer(args, "pageStart", fallback: 1, range: 1...1_000_000)
                let last = try integer(args, "pageEnd", fallback: 1, range: 1...1_000_000)
                guard first <= last, last - first < 100 else { throw AutomationError.invalidArguments }
                pages = first...last
            } else { pages = nil }
            guard tasks.isEmpty else { throw AutomationError.busy }
            let request = OCRRequest(url: url, languages: languages, pages: pages)
            let retainedJobs = Set(state.jobs.map(\.id))
            ocrRequests = ocrRequests.filter { retainedJobs.contains($0.key) }
            ocrResults = ocrResults.filter { retainedJobs.contains($0.key) }
            while ocrRequests.count >= 16, let old = state.jobs.first(where: { $0.kind == "ocr" && ocrRequests[$0.id] != nil && tasks[$0.id] == nil }) {
                ocrRequests.removeValue(forKey: old.id); ocrResults.removeValue(forKey: old.id)
            }
            guard ocrRequests.count < 16 else { throw AutomationError.busy }
            let job = AutomationJob(id: UUID(), clientID: id, planID: UUID(), key: UUID().uuidString,
                                    kind: "ocr", state: "queued", completed: [], updated: Date())
            state.jobs.append(job)
            if state.jobs.count > 1000 { state.jobs.removeFirst(state.jobs.count - 1000) }
            do { try persist() } catch { state.jobs.removeAll { $0.id == job.id }; throw error }
            ocrRequests[job.id] = request
            tasks[job.id] = Task { await executeOCR(request, clientID: id, jobID: job.id) }
            return try json(job)
        case "ocr.status", "ocr.cancel":
            let jobID = try uuid(args, "jobID")
            guard let job = state.jobs.first(where: { $0.id == jobID && $0.clientID == id && ["ocr", "ocrPDF", "ocrPDFBatch"].contains($0.kind) }) else { throw AutomationError.notFound }
            if ["ocrPDF", "ocrPDFBatch"].contains(job.kind) { return try pdfJobStatus(job, cancel: method == "ocr.cancel", clientID: id) }
            _ = try checkedGrant(id, operation: "files.ocr")
            if method == "ocr.cancel" {
                tasks[jobID]?.cancel(); ocrResults.removeValue(forKey: jobID)
                update(jobID, state: "cancelled", error: "cancelled")
            } else if let request = ocrRequests[jobID] {
                do {
                    try checkOCRGrant(id, url: request.url)
                    if ocrResults[jobID] != nil {
                        let resolved = try await files.validateOCRAccess(request.url, authorizeURL: { url in
                            try await self.checkOCRGrant(id, url: url)
                        })
                        try checkOCRGrant(id, url: resolved)
                    }
                } catch {
                    ocrResults.removeValue(forKey: jobID)
                    throw error
                }
            }
            // No suspension after the final current-scope check and before returning extracted text.
            _ = try checkedGrant(id, operation: "files.ocr")
            if let source = ocrRequests[jobID]?.url { try checkOCRGrant(id, url: source) }
            guard let current = state.jobs.first(where: { $0.id == job.id }) else { throw AutomationError.notFound }
            return try ocrJobValue(current, result: ocrResults[jobID])
        case "locations.list":
            try keys(object, ["url", "showHidden", "offset", "limit"])
            let url = try location(args, "url")
            _ = try checkedGrant(id, operation: "read", url: url)
            let entries = try await files.list(url, hidden: args["showHidden"]?.boolValue ?? false)
            let offset = try integer(args, "offset", fallback: 0, range: 0...10000), limit = try integer(args, "limit", fallback: 100, range: 1...200)
            _ = try checkedGrant(id, operation: "read", url: url)
            let page = entries.dropFirst(offset).prefix(limit).filter { (try? checkedGrant(id, operation: "read", url: $0.url)) != nil }
            return .object(["entries": .array(page.map { .object(["url": .string($0.url.absoluteString), "name": .string($0.name), "directory": .bool($0.isDirectory), "size": $0.size.map { .number(Double($0)) } ?? .null]) }), "nextOffset": offset + limit < entries.count ? .number(Double(offset + limit)) : .null])
        case "transfers.plan", "deletions.plan":
            try keys(object, method == "transfers.plan" ? ["sources", "destination", "recursive", "conflict"] : ["sources", "recursive"])
            guard let raw = args["sources"]?.arrayValue, !raw.isEmpty, raw.count <= 1000 else { throw AutomationError.invalidArguments }
            let sources = try raw.map { value -> URL in guard let string = value.stringValue else { throw AutomationError.invalidArguments }; return try parseLocation(string) }
            for (index, source) in sources.enumerated() {
                for other in sources.prefix(index) {
                    if source.explorerIdentity == other.explorerIdentity { throw AutomationError.invalidArguments }
                    if source.isFileURL && other.isFileURL {
                        let first = source.resolvingSymlinksInPath().path, second = other.resolvingSymlinksInPath().path
                        if AutomationGrant.contains(first, second) || AutomationGrant.contains(second, first) { throw AutomationError.invalidArguments }
                    } else if let first = RemoteLocation.parse(source), let second = RemoteLocation.parse(other), first.connectionID == second.connectionID {
                        let a = first.key.trimmingCharacters(in: CharacterSet(charactersIn: "/")), b = second.key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if a == b || a.isEmpty || b.isEmpty || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") { throw AutomationError.invalidArguments }
                    }
                }
            }
            let recursive = args["recursive"]?.boolValue ?? false
            let grant = try checkedGrant(id, operation: "read")
            guard !recursive || grant.recursive else { throw AutomationError.forbidden }
            let revision = await environment.revision()
            let destination = method == "transfers.plan" ? try location(args, "destination") : nil
            let conflict = args["conflict"]?.stringValue ?? "fail"
            guard ["fail", "skip", "keepBoth", "replace"].contains(conflict) else { throw AutomationError.invalidArguments }
            var deletionID: UUID?, snapshot: [String: String] = [:], count = 0
            if let destination {
                _ = try checkedGrant(id, operation: "copy", url: destination)
                if conflict == "replace" { _ = try checkedGrant(id, operation: "replace", url: destination) }
                guard destination.isFileURL || sources.allSatisfy(\.isFileURL), destination.isFileURL || RemoteLocation.parse(destination) != nil else { throw AutomationError.unsupported }
                if destination.isFileURL && sources.allSatisfy(\.isFileURL) && conflict != "fail" { throw AutomationError.unsupported }
                for source in sources {
                    if source.isFileURL && destination.isFileURL {
                        let path = source.resolvingSymlinksInPath().standardizedFileURL.path
                        if AutomationGrant.contains(path, destination.resolvingSymlinksInPath().standardizedFileURL.path) { throw AutomationError.invalidArguments }
                    }
                    try await manifest(source, clientID: id, recursive: recursive, depth: 0, maximum: grant.maximumItems, result: &snapshot)
                }
                count = snapshot.count
            } else {
                for source in sources { _ = try checkedGrant(id, operation: source.isFileURL ? "trash" : "deleteRemote", url: source) }
                let plan = try await deletion.plan(sources: sources, recursive: recursive)
                guard plan.itemCount <= grant.maximumItems else { await deletion.discard(planID: plan.id); throw AutomationError.limitExceeded }
                deletionID = plan.id; count = plan.itemCount
            }
            guard plans.count < 100 else { throw AutomationError.limitExceeded }
            let plan = OperationPlan(id: UUID(), clientID: id, kind: method == "transfers.plan" ? "copy" : "delete", sources: sources, destination: destination,
                expires: Date().addingTimeInterval(300), revision: revision, snapshot: snapshot, recursive: recursive, conflict: conflict, deletionID: deletionID, count: count)
            plans[plan.id] = plan
            return .object(["planID": .string(plan.id.uuidString), "itemCount": .number(Double(count)), "expiresAt": .string(iso(plan.expires)),
                            "sources": .array(sources.map { .string($0.absoluteString) }), "destination": destination.map { .string($0.absoluteString) } ?? .null,
                            "deletionMode": plan.kind == "delete" ? .string(sources.allSatisfy(\.isFileURL) ? "trash" : "remote_permanent_current_object") : .null,
                            "conflict": .string(conflict)])
        case "transfers.start", "deletions.start":
            try keys(object, ["planID", "idempotencyKey"])
            let planID = try uuid(args, "planID"), key = try string(args, "idempotencyKey")
            guard key.count <= 128 else { throw AutomationError.invalidArguments }
            let revision = await environment.revision()
            _ = try checkedGrant(id, operation: "read")
            if let job = state.jobs.first(where: { $0.clientID == id && $0.key == key }) {
                guard job.planID == planID, job.kind == (method == "transfers.start" ? "copy" : "delete") else { throw AutomationError.conflict }
                return try json(job)
            }
            guard tasks.isEmpty else { throw AutomationError.busy }
            guard let plan = plans[planID], plan.clientID == id, plan.kind == (method == "transfers.start" ? "copy" : "delete") else { throw AutomationError.notFound }
            guard plan.expires > Date() else { throw AutomationError.expiredPlan }
            guard plan.revision == revision else { throw AutomationError.changedPlan }
            // Consume before any execution await. Repeat starts need the same idempotency key.
            plans[planID] = nil
            let job = AutomationJob(id: UUID(), clientID: id, planID: planID, key: key, kind: plan.kind, state: "queued", completed: [], updated: Date())
            state.jobs.append(job)
            if state.jobs.count > 1000 { state.jobs.removeFirst(state.jobs.count - 1000) }
            do { try persist() } catch { state.jobs.removeAll { $0.id == job.id }; plans[planID] = plan; throw error }
            tasks[job.id] = Task { await execute(plan, jobID: job.id) }
            return try json(job)
        case "transfers.status", "deletions.status", "transfers.cancel", "deletions.cancel":
            try keys(object, ["jobID"])
            let jobID = try uuid(args, "jobID")
            guard let job = state.jobs.first(where: { $0.id == jobID && $0.clientID == id }) else { throw AutomationError.notFound }
            if method.hasSuffix("cancel") { tasks[jobID]?.cancel() }
            return try json(job)
        case "preferences.get", "preferences.update":
            _ = try checkedGrant(id, operation: "preferences")
            if method == "preferences.get" { try keys(object, []); return await environment.preferences() }
            try keys(object, ["language", "showFileExtensions", "fonts"])
            if let language = args["language"] { guard let value = language.stringValue, ["system", "pt-BR", "en", "es", "fr", "de", "ja", "ko", "it"].contains(value) else { throw AutomationError.invalidArguments } }
            if let value = args["showFileExtensions"], value.boolValue == nil { throw AutomationError.invalidArguments }
            if let fonts = args["fonts"] {
                guard let values = fonts.objectValue else { throw AutomationError.invalidArguments }
                try keys(values, ["tree", "files", "menus", "bars"])
                for value in values.values { guard case .number(let number) = value, (10...24).contains(number) else { throw AutomationError.invalidArguments } }
            }
            return try await environment.updatePreferences(args)
        case "audit.list":
            try keys(object, ["limit"])
            let limit = try integer(args, "limit", fallback: 100, range: 1...200)
            return .object(["events": try json(Array(state.audit.filter { $0.clientID == id }.suffix(limit)))])
        default: throw AutomationError.unsupported
        }
    }
    private func reservePDFJob() throws {
        let retained = Set(state.jobs.map(\.id))
        ocrPDFRequests = ocrPDFRequests.filter { retained.contains($0.key) }
        ocrPDFBatchRequests = ocrPDFBatchRequests.filter { retained.contains($0.key) }
        ocrPDFScopes = ocrPDFScopes.filter { retained.contains($0.key) }
        ocrResults = ocrResults.filter { retained.contains($0.key) }
        while ocrPDFRequests.count + ocrPDFBatchRequests.count >= 16,
              let old = state.jobs.first(where: { ocrPDFScopes[$0.id] != nil && tasks[$0.id] == nil }) {
            ocrPDFRequests.removeValue(forKey: old.id); ocrPDFBatchRequests.removeValue(forKey: old.id)
            ocrPDFScopes.removeValue(forKey: old.id); ocrResults.removeValue(forKey: old.id)
        }
        guard ocrPDFRequests.count + ocrPDFBatchRequests.count < 16 else { throw AutomationError.busy }
    }
    private func executeSearchablePDFBatch(_ request: SearchablePDFBatchRequest, clientID: UUID, jobID: UUID) async {
        update(jobID, state: "running")
        do {
            let result = try await files.searchablePDFBatch(request, progress: { progress in
                Task { await self.setPDFBatchProgress(jobID, progress) }
            }, authorizeSource: { url in
                try await self.authorizePDF(url, clientID: clientID, jobID: jobID)
            }, authorizeDestination: { url in
                try await self.authorizePDF(url, clientID: clientID, jobID: jobID)
            })
            let count = result.items.filter { $0.receipt != nil }.count
            var state: String
            if result.items.contains(where: { $0.state == .needsInput }) { state = "needs_input" }
            else if result.items.allSatisfy({ $0.state == .succeeded }) { state = "succeeded" }
            else if result.items.contains(where: { $0.state == .cancelled || $0.reason == .cancelled }) { state = "cancelled" }
            else { state = count > 0 ? "partial" : "failed" }
            // A batch receipt is authoritative even after task cancellation. Only disclose its
            // ephemeral metadata under the current grant; status rechecks every recorded scope.
            var resultError = result.items.first(where: { $0.reason != nil })?.reason?.rawValue
            if (try? checkedGrant(clientID, operation: "files.ocr.pdf")) != nil {
                if let value = try? json(result), let bytes = try? AutomationWire.encode(value),
                   bytes.count <= AutomationWire.maximumMessageBytes / 8 {
                    ocrResults[jobID] = value
                } else { resultError = "limitExceeded"; state = "needs_input" }
            }
            update(jobID, state: state, count: count, error: resultError)
        } catch {
            ocrResults.removeValue(forKey: jobID)
            let code = Self.errorCode(error)
            update(jobID, state: code == "publicationIndeterminate" ? "needs_input" :
                (code == "cancelled" || error is CancellationError ? "cancelled" : "failed"), error: code)
        }
        tasks[jobID] = nil
        try? persist()
    }
    private func setPDFBatchProgress(_ id: UUID, _ progress: SearchablePDFBatchProgress) {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].state == "running" else { return }
        let previous = state.jobs[index].progress
        let finished = Double(progress.completedResults.count)
        let oldFinished = previous?["finishedItems"]?.numberValue ?? 0
        let oldIndex = previous?["index"]?.numberValue ?? 0
        guard finished > oldFinished || (finished == oldFinished && Double(progress.index) >= oldIndex) else { return }
        var value: [String: JSONValue] = ["index": .number(Double(progress.index)), "total": .number(Double(progress.total)),
            "finishedItems": .number(finished),
            "completedItems": .number(Double(progress.completedResults.filter { $0.receipt != nil }.count))]
        if let page = progress.page {
            value["page"] = .object(["stage": .string(page.stage.rawValue), "completedPages": .number(Double(page.completedPages)),
                "totalPages": .number(Double(page.totalPages))])
        }
        state.jobs[index].progress = .object(value)
    }
    private func checkOCRGrant(_ id: UUID, url: URL, operation: String = "files.ocr") throws {
        try Task.checkCancellation()
        let grant = try checkedGrant(id, operation: operation)
        let path = AutomationOCRLocation.scopePath(try AutomationOCRLocation.normalized(url).path)
        guard grant.localRoots.contains(where: { AutomationGrant.contains(AutomationOCRLocation.scopePath($0), path) }) else { throw AutomationError.forbidden }
    }
    private func checkOCRDiscoveryGrant(_ id: UUID) throws {
        if (try? checkedGrant(id, operation: "files.ocr")) != nil { return }
        _ = try checkedGrant(id, operation: "files.ocr.pdf")
    }
    private func authorizePDF(_ url: URL, clientID: UUID, jobID: UUID) throws {
        try checkOCRGrant(clientID, url: url, operation: "files.ocr.pdf")
        if let batch = ocrPDFBatchRequests[jobID] {
            let grant = try checkedGrant(clientID, operation: "files.ocr.pdf")
            guard batch.sourceURLs.count <= min(50, grant.maximumItems) else { throw AutomationError.limitExceeded }
        }
        ocrPDFScopes[jobID, default: []].insert(url)
    }
    private func pdfJobStatus(_ job: AutomationJob, cancel: Bool, clientID: UUID) throws -> JSONValue {
        _ = try checkedGrant(clientID, operation: "files.ocr.pdf")
        if cancel, let task = tasks[job.id] {
            task.cancel()
            // A publication receipt can still arrive. The worker decides cancelled versus succeeded.
            update(job.id, state: "cancelling")
        }
        for url in ocrPDFScopes[job.id] ?? [] { try checkOCRGrant(clientID, url: url, operation: "files.ocr.pdf") }
        guard let current = state.jobs.first(where: { $0.id == job.id }) else { throw AutomationError.notFound }
        return try ocrJobValue(current, result: ocrResults[job.id])
    }
    private func executeSearchablePDF(_ request: SearchablePDFRequest, clientID: UUID, jobID: UUID) async {
        update(jobID, state: "running")
        do {
            let result = try await files.searchablePDF(request, progress: { progress in
                Task { await self.setOCRProgress(jobID, progress) }
            }, authorizeSource: { url in
                try await self.authorizePDF(url, clientID: clientID, jobID: jobID)
            }, authorizeDestination: { url in
                try await self.authorizePDF(url, clientID: clientID, jobID: jobID)
            })
            // The receipt means a new file was published. Cancellation after that point must not
            // claim rollback or delete it. Current authorization controls visibility of metadata only.
            let authorized = (try? checkedGrant(clientID, operation: "files.ocr.pdf")) != nil
            if authorized, let value = try? json(result),
               let encoded = try? AutomationWire.encode(value), encoded.count <= 32_768 {
                ocrResults[jobID] = value
            }
            update(jobID, state: "succeeded", count: 1)
        } catch {
            ocrResults.removeValue(forKey: jobID)
            let code = Self.errorCode(error)
            if code == "publicationIndeterminate" {
                update(jobID, state: "needs_input", error: code)
            } else {
                update(jobID, state: code == "cancelled" || error is CancellationError ? "cancelled" : "failed", error: code)
            }
        }
        tasks[jobID] = nil
        try? persist()
    }
    private func ocrJobValue(_ job: AutomationJob, result: JSONValue?) throws -> JSONValue {
        var object = try json(job).objectValue ?? [:]
        object["result"] = result ?? .null
        object["resultAvailable"] = .bool(result != nil)
        object["untrustedDocumentContent"] = .bool(true)
        object["resultKind"] = .string(job.kind == "ocrPDFBatch" ? "searchablePDFBatchMetadata" : (job.kind == "ocrPDF" ? "searchablePDFMetadata" : "recognizedText"))
        return .object(object)
    }
    private func executeOCR(_ request: OCRRequest, clientID: UUID, jobID: UUID) async {
        update(jobID, state: "running")
        do {
            let result = try await files.ocr(request, progress: { progress in
                Task { await self.setOCRProgress(jobID, progress) }
            }, authorizeURL: { url in try await self.checkOCRGrant(clientID, url: url) })
            let resolved = try await files.validateOCRAccess(request.url, authorizeURL: { url in
                try await self.checkOCRGrant(clientID, url: url)
            })
            try checkOCRGrant(clientID, url: request.url)
            try checkOCRGrant(clientID, url: resolved)
            try Task.checkCancellation()
            guard var job = state.jobs.first(where: { $0.id == jobID }), job.state == "running" else { throw AutomationError.cancelled }
            let value = try json(result)
            job.state = "succeeded"
            let response = AutomationResponse(ok: true, result: try ocrJobValue(job, result: value))
            // MCP includes both structuredContent and a JSON text representation. Leave room for
            // both copies and escaping instead of silently truncating extracted document text.
            guard try AutomationWire.encode(response).count <= AutomationWire.maximumMessageBytes / 4 else { throw AutomationError.limitExceeded }
            ocrResults[jobID] = value
            update(jobID, state: "succeeded")
        } catch {
            ocrResults.removeValue(forKey: jobID)
            let code = Self.errorCode(error)
            update(jobID, state: Task.isCancelled || code == "cancelled" ? "cancelled" : "failed", error: code)
        }
        tasks[jobID] = nil
        try? persist()
    }
    private func setOCRProgress(_ id: UUID, _ progress: OCRProgress) {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].state == "running" else { return }
        state.jobs[index].progress = .object(["stage": .string(progress.stage.rawValue),
            "completedPages": .number(Double(progress.completedPages)), "totalPages": .number(Double(progress.totalPages))])
    }
    private func execute(_ plan: OperationPlan, jobID: UUID) async {
        update(jobID, state: "running")
        do {
            let completed: [URL]
            if let deletionID = plan.deletionID {
                let result = try await files.executeDeletion(planID: deletionID, using: deletion, authorizationCheck: { url in
                    do { try await self.checkPlan(plan, operation: url.isFileURL ? "trash" : "deleteRemote", url: url); return true } catch { return false }
                })
                completed = result.completed
            } else if let destination = plan.destination {
                let grant = try checkedGrant(plan.clientID, operation: "read")
                var current: [String: String] = [:]
                for source in plan.sources { try await manifest(source, clientID: plan.clientID, recursive: plan.recursive, depth: 0, maximum: grant.maximumItems, result: &current) }
                guard current == plan.snapshot else { throw AutomationError.changedPlan }
                completed = try await files.copy(plan.sources, to: destination, resolveConflict: { _ in
                    switch plan.conflict { case "skip": return .skip; case "keepBoth": return .keepBoth; case "replace": return .replace; default: return .cancel }
                }, progress: { progress in
                    Task { await self.setProgress(jobID, progress) }
                }, authorize: { source, target, replacing in
                    try await self.checkPlan(plan, operation: "read", url: source)
                    try await self.checkPlan(plan, operation: replacing ? "replace" : "copy", url: target)
                })
            } else { throw AutomationError.invalidArguments }
            update(jobID, state: "succeeded", completed: completed.map(\.absoluteString))
        } catch let failure as StorageDeletionFailure {
            update(jobID, state: failure.indeterminate.isEmpty ? (failure.completed.isEmpty ? (failure.reason == .cancelled ? "cancelled" : "failed") : "partially_completed") : "needs_input",
                   completed: failure.completed.map(\.absoluteString), indeterminate: failure.indeterminate.map(\.absoluteString), error: failure.reason.rawValue)
        } catch let failure as StorageTransferFailure {
            let uncertain = failure.reason == .cloud || failure.reason == .io || failure.reason == .cancelled
            update(jobID, state: uncertain ? "needs_input" : failure.completedCount > 0 ? "partially_completed" : "failed", count: failure.completedCount, error: failure.reason.rawValue)
        } catch let failure as FileMutationFailure {
            update(jobID, state: failure.completed > 0 ? "partially_completed" : failure.reason == .cancelled ? "cancelled" : "failed", count: failure.completed, error: "localOperation")
        } catch let failure as SharedFileFailure {
            update(jobID, state: failure.completed.isEmpty ? (failure.reason == .cancelled ? "cancelled" : "failed") : "partially_completed", completed: failure.completed.map(\.absoluteString), error: failure.reason.rawValue)
        } catch { update(jobID, state: error is CancellationError ? "cancelled" : "failed", error: Self.errorCode(error)) }
        tasks[jobID] = nil
        try? persist()
    }
    private func checkPlan(_ plan: OperationPlan, operation: String, url: URL) async throws {
        try Task.checkCancellation()
        guard plan.revision == (await environment.revision()) else { throw AutomationError.changedPlan }
        let grant = try checkedGrant(plan.clientID, operation: operation, url: url)
        guard !plan.recursive || grant.recursive, plan.count <= grant.maximumItems else { throw AutomationError.forbidden }
        if operation == "read", plan.kind == "copy" {
            guard plan.snapshot[url.absoluteString] != nil else { throw AutomationError.changedPlan }
            var current: [String: String] = [:]
            try await manifest(url, clientID: plan.clientID, recursive: plan.recursive, depth: 0, maximum: grant.maximumItems, result: &current)
            for (key, value) in current where plan.snapshot[key] != value { throw AutomationError.changedPlan }
            // A removed descendant changes its parent directory snapshot; cloud directories also need membership equality.
            if RemoteLocation.parse(url)?.key.hasSuffix("/") == true {
                let expected = plan.snapshot.filter { $0.key.hasPrefix(url.absoluteString) }
                guard expected == current else { throw AutomationError.changedPlan }
            }
        }
    }
    private func update(_ id: UUID, state newState: String, completed: [String] = [], count: Int? = nil, indeterminate: [String] = [], error: String? = nil) {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }) else { return }
        state.jobs[index].state = newState; state.jobs[index].completed = completed; state.jobs[index].error = error; state.jobs[index].updated = Date()
        state.jobs[index].completedCount = count ?? completed.count; state.jobs[index].indeterminate = indeterminate
        try? persist()
    }
    private func setProgress(_ id: UUID, _ progress: StorageTransferProgress) {
        guard let index = state.jobs.firstIndex(where: { $0.id == id }), state.jobs[index].state == "running" else { return }
        state.jobs[index].progress = .object(["completedItems": .number(Double(progress.completedItems)), "totalItems": .number(Double(progress.totalItems)), "bytesCompleted": .number(Double(progress.bytesCompleted))])
    }
    private func manifest(_ url: URL, clientID: UUID, recursive: Bool, depth: Int, maximum: Int, result: inout [String: String]) async throws {
        try Task.checkCancellation()
        _ = try checkedGrant(clientID, operation: "read", url: url)
        guard depth <= 64, result.count < maximum else { throw AutomationError.limitExceeded }
        let directory: Bool, fingerprint: String
        if url.isFileURL {
            var info = Darwin.stat()
            guard lstat(url.path, &info) == 0 else { throw AutomationError.notFound }
            guard [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT) else { throw AutomationError.forbidden }
            directory = info.st_mode & S_IFMT == S_IFDIR
            fingerprint = "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        } else {
            guard let location = RemoteLocation.parse(url) else { throw AutomationError.invalidArguments }
            directory = location.key.hasSuffix("/") || location.key.isEmpty
            if directory { fingerprint = "directory" }
            else {
                let client = try await files.clientFactory(location.connectionID)
                guard let item = try await client.stat(key: location.key), let version = item.version else { throw AutomationError.notFound }
                fingerprint = version
            }
        }
        result[url.absoluteString] = fingerprint
        if directory {
            guard recursive else { throw AutomationError.invalidArguments }
            for entry in try await files.list(url, hidden: true) {
                try await manifest(entry.url, clientID: clientID, recursive: recursive, depth: depth + 1, maximum: maximum, result: &result)
            }
        }
    }
    private func keys(_ object: [String: JSONValue], _ allowed: Set<String>) throws { guard Set(object.keys).isSubset(of: allowed) else { throw AutomationError.invalidArguments } }
    private func string(_ args: JSONValue, _ key: String) throws -> String { guard let value = args[key]?.stringValue, !value.isEmpty, value.utf8.count <= 8192 else { throw AutomationError.invalidArguments }; return value }
    private func uuid(_ args: JSONValue, _ key: String) throws -> UUID { guard let value = UUID(uuidString: try string(args, key)) else { throw AutomationError.invalidArguments }; return value }
    private func location(_ args: JSONValue, _ key: String) throws -> URL { try parseLocation(string(args, key)) }
    private func parseLocation(_ value: String) throws -> URL {
        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value)
        guard let url, url.isFileURL || RemoteLocation.parse(url) != nil else { throw AutomationError.invalidArguments }
        guard url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              let decodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding,
              !decodedPath.utf8.contains(0) else { throw AutomationError.invalidArguments }
        return url.explorerNormalized
    }
    private func integer(_ args: JSONValue, _ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let value = args[key] else { return fallback }
        guard case .number(let number) = value, number.isFinite, number.rounded() == number, number >= Double(range.lowerBound), number <= Double(range.upperBound) else { throw AutomationError.invalidArguments }
        return Int(number)
    }
    private func json<T: Encodable>(_ value: T) throws -> JSONValue {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    }
    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func errorCode(_ error: any Error) -> String {
        if let error = error as? AutomationError { return error.rawValue }
        if let error = error as? CloudFailure { return error.reason.rawValue }
        if let error = error as? OCRFailure { return error.reason.rawValue }
        if let error = error as? SearchablePDFFailure { return error.reason.rawValue }
        if let error = error as? StorageDeletionFailure { return error.reason.rawValue }
        return error is CancellationError ? "cancelled" : "io"
    }
}
