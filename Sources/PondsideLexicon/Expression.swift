/// The sound-binding language (DESIGN.md §3): numbers, names, `+ - * /`,
/// parentheses, unary minus, and `min`/`max` of two or more arguments.
/// Total by construction — no loops, no other calls — so evaluating it
/// can only fail on an unbound name or a division by zero.
public indirect enum Expression: Hashable, Sendable, CustomStringConvertible {
    case number(Double)
    case name(String)
    case negate(Expression)
    case binary(Character, Expression, Expression)
    case call(String, [Expression])

    public struct ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        public var message: String
        public var description: String { message }
    }

    public enum EvaluationError: Error, Hashable, Sendable {
        case unbound(String)
        case divisionByZero
    }

    public init(parsing text: String) throws {
        var p = ExpressionParser(Array(text))
        let e = try p.sum()
        p.skip()
        guard p.i == p.c.count else { throw ParseError(message: "unexpected '\(p.c[p.i])' in \(text)") }
        self = e
    }

    /// Every name the expression reads.
    public var names: Set<String> {
        switch self {
        case .number: return []
        case .name(let n): return [n]
        case .negate(let e): return e.names
        case .binary(_, let a, let b): return a.names.union(b.names)
        case .call(_, let args): return args.reduce(into: Set<String>()) { $0.formUnion($1.names) }
        }
    }

    public func evaluate(_ bindings: [String: Double]) throws -> Double {
        switch self {
        case .number(let v): return v
        case .name(let n):
            guard let v = bindings[n] else { throw EvaluationError.unbound(n) }
            return v
        case .negate(let e): return -(try e.evaluate(bindings))
        case .binary(let op, let a, let b):
            let x = try a.evaluate(bindings), y = try b.evaluate(bindings)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            default:
                guard y != 0 else { throw EvaluationError.divisionByZero }
                return x / y
            }
        case .call(let f, let args):
            let values = try args.map { try $0.evaluate(bindings) }
            return f == "min" ? values.min()! : values.max()!
        }
    }

    public var description: String {
        switch self {
        case .number(let v): return v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
        case .name(let n): return n
        case .negate(let e): return "-\(e)"
        case .binary(let op, let a, let b): return "(\(a) \(op) \(b))"
        case .call(let f, let args): return "\(f)(\(args.map(\.description).joined(separator: ", ")))"
        }
    }
}

private struct ExpressionParser {
    let c: [Character]
    var i = 0

    init(_ c: [Character]) { self.c = c }

    mutating func skip() { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }

    func fail(_ m: String) -> Expression.ParseError { Expression.ParseError(message: m) }

    mutating func sum() throws -> Expression {
        var e = try product()
        while true {
            skip()
            guard i < c.count, c[i] == "+" || c[i] == "-" else { return e }
            let op = c[i]
            i += 1
            e = .binary(op, e, try product())
        }
    }

    mutating func product() throws -> Expression {
        var e = try unary()
        while true {
            skip()
            guard i < c.count, c[i] == "*" || c[i] == "/" else { return e }
            let op = c[i]
            i += 1
            e = .binary(op, e, try unary())
        }
    }

    mutating func unary() throws -> Expression {
        skip()
        if i < c.count, c[i] == "-" {
            i += 1
            return .negate(try unary())
        }
        return try atom()
    }

    mutating func atom() throws -> Expression {
        skip()
        guard i < c.count else { throw fail("expression ends too soon") }
        if c[i] == "(" {
            i += 1
            let e = try sum()
            skip()
            guard i < c.count, c[i] == ")" else { throw fail("missing )") }
            i += 1
            return e
        }
        if c[i].isNumber || c[i] == "." {
            var t = ""
            while i < c.count, c[i].isNumber || c[i] == "." { t.append(c[i]); i += 1 }
            guard let v = Double(t) else { throw fail("\(t) is not a number") }
            return .number(v)
        }
        if c[i].isLetter || c[i] == "_" {
            var t = ""
            while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" { t.append(c[i]); i += 1 }
            skip()
            if i < c.count, c[i] == "(" {
                guard t == "min" || t == "max" else { throw fail("\(t)() is not allowed: only min and max") }
                i += 1
                var args = [try sum()]
                skip()
                while i < c.count, c[i] == "," {
                    i += 1
                    args.append(try sum())
                    skip()
                }
                guard i < c.count, c[i] == ")" else { throw fail("missing ) after \(t)(") }
                i += 1
                guard args.count >= 2 else { throw fail("\(t) needs at least two arguments") }
                return .call(t, args)
            }
            return .name(t)
        }
        throw fail("unexpected '\(c[i])'")
    }
}
