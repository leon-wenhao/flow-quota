import CSQLite

/// Confined to its owning QuotaStore actor. No statement/handle escapes to callers.
final class SQLiteConnection {
    private var handle: OpaquePointer?

    init(path: String) throws {
        try validateIdentifier(path)
        let result = sqlite3_open_v2(path, &handle,
                                    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let failure = error(result)
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            throw failure
        }
        do {
            sqlite3_extended_result_codes(handle, 1)
            try execute("PRAGMA busy_timeout = 1000")
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            try execute("PRAGMA wal_autocheckpoint = 1000")
            let mode = try query("PRAGMA journal_mode = WAL") { $0.text(0) }
            guard mode == ["wal"], try scalar("PRAGMA foreign_keys") == 1,
                  try scalar("PRAGMA synchronous") == 2,
                  try scalar("PRAGMA secure_delete") == 1,
                  try scalar("PRAGMA busy_timeout") == 1_000,
                  try scalar("PRAGMA wal_autocheckpoint") == 1_000 else {
                throw StoreError.configuration("SQLite durability/FK configuration was not accepted")
            }
        } catch {
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else { throw error(result) }
        self.handle = nil
    }

    func error(_ code: Int32) -> StoreError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Closed database")
    }

    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        let statement = try prepare(sql, bindings)
        while try statement.step() { /* PRAGMAs may return rows. */ }
    }

    func query<T>(_ sql: String, _ bindings: [SQLValue] = [],
                  row: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings)
        var rows: [T] = []
        while try statement.step() { rows.append(try row(statement)) }
        return rows
    }

    func scalar(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int64 {
        guard let result = try query(sql, bindings, row: { $0.integer(0) }).first else {
            throw StoreError.configuration("Expected a scalar SQLite result")
        }
        return result
    }

    /// No suspension inside the closure: failed validation and writes roll back together.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            let original = error
            do { try execute("ROLLBACK") }
            catch {
                throw StoreError.rollbackFailed(original: String(describing: original),
                                               rollback: String(describing: error))
            }
            throw original
        }
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> SQLiteStatement {
        guard let handle else { throw StoreError.closed }
        return try SQLiteStatement(connection: handle, sql: sql, bindings: bindings)
    }
}

enum SQLValue {
    case text(String), integer(Int64), null
    static func optional(_ value: Int64?) -> SQLValue { value.map(Self.integer) ?? .null }
}

final class SQLiteStatement {
    private let connection: OpaquePointer
    private let handle: OpaquePointer

    init(connection: OpaquePointer, sql: String, bindings: [SQLValue]) throws {
        var prepared: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &prepared, nil)
        guard result == SQLITE_OK, let prepared else {
            if let prepared { sqlite3_finalize(prepared) }
            throw StoreError.sqlite(code: result, message: String(cString: sqlite3_errmsg(connection)))
        }
        do {
            guard sqlite3_bind_parameter_count(prepared) == Int32(bindings.count) else {
                throw StoreError.configuration("Incorrect SQL binding count")
            }
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let code: Int32
                switch value {
                case .null: code = sqlite3_bind_null(prepared, index)
                case .integer(let number): code = sqlite3_bind_int64(prepared, index, number)
                case .text(let text):
                    // SQLite copies Swift's temporary UTF-8 buffer before it is released.
                    code = sqlite3_bind_text(prepared, index, text, -1,
                                             unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
                guard code == SQLITE_OK else {
                    throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(connection)))
                }
            }
        } catch {
            sqlite3_finalize(prepared)
            throw error
        }
        // Transfer ownership only after all throwing setup completes. A failed
        // initializer finalizes the local statement exactly once.
        self.connection = connection
        handle = prepared
    }

    deinit { sqlite3_finalize(handle) }

    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code:
            throw StoreError.sqlite(code: code, message: String(cString: sqlite3_errmsg(connection)))
        }
    }

    func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(handle, index) }
    func optionalInteger(_ index: Int32) -> Int64? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : integer(index)
    }
    func optionalText(_ index: Int32) -> String? {
        sqlite3_column_type(handle, index) == SQLITE_NULL ? nil : text(index)
    }
    func text(_ index: Int32) -> String {
        guard let value = sqlite3_column_text(handle, index) else { return "" }
        return String(cString: value)
    }
}
