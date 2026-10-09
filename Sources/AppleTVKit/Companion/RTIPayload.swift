import Foundation

/// Builds the Remote Text Input archives that the Companion `_tiC` event carries.
/// The layouts match the pyatv payloads byte for byte in structure.
public enum RTIPayload {
    static let archiver = "RTIKeyedArchiver"

    /// The archive that inserts `text` into the active tvOS text field.
    ///
    /// Object table:
    /// 0 "$null"
    /// 1 root: keyboardOutput -> 2, $class -> 7, targetSessionUUID -> 5
    /// 2 keyboard output: insertionText -> 3, $class -> 4
    /// 3 the text
    /// 4 class TIKeyboardOutput
    /// 5 session uuid: NS.uuidbytes, $class -> 6
    /// 6 class NSUUID
    /// 7 class RTITextOperations
    public static func inputText(sessionUUID: Data, text: String) -> Data {
        let builder = KeyedArchiveBuilder(
            archiver: archiver,
            top: [("textOperations", 1)],
            objects: [
                .string("$null"),
                .dict([
                    ("keyboardOutput", .uid(2)),
                    ("$class", .uid(7)),
                    ("targetSessionUUID", .uid(5)),
                ]),
                .dict([
                    ("insertionText", .uid(3)),
                    ("$class", .uid(4)),
                ]),
                .string(text),
                classObject("TIKeyboardOutput"),
                .dict([
                    ("NS.uuidbytes", .data(sessionUUID)),
                    ("$class", .uid(6)),
                ]),
                classObject("NSUUID"),
                classObject("RTITextOperations"),
            ]
        )
        return builder.encode()
    }

    /// The archive that clears the active tvOS text field.
    ///
    /// Object table:
    /// 0 "$null"
    /// 1 root: $class -> 7, targetSessionUUID -> 5, keyboardOutput -> 2, textToAssert -> 4
    /// 2 keyboard output: $class -> 3
    /// 3 class TIKeyboardOutput
    /// 4 "" (the text to assert)
    /// 5 session uuid: NS.uuidbytes, $class -> 6
    /// 6 class NSUUID
    /// 7 class RTITextOperations
    public static func clearText(sessionUUID: Data) -> Data {
        let builder = KeyedArchiveBuilder(
            archiver: archiver,
            top: [("textOperations", 1)],
            objects: [
                .string("$null"),
                .dict([
                    ("$class", .uid(7)),
                    ("targetSessionUUID", .uid(5)),
                    ("keyboardOutput", .uid(2)),
                    ("textToAssert", .uid(4)),
                ]),
                .dict([
                    ("$class", .uid(3)),
                ]),
                classObject("TIKeyboardOutput"),
                .string(""),
                .dict([
                    ("NS.uuidbytes", .data(sessionUUID)),
                    ("$class", .uid(6)),
                ]),
                classObject("NSUUID"),
                classObject("RTITextOperations"),
            ]
        )
        return builder.encode()
    }

    private static func classObject(_ name: String) -> PlistValue {
        .dict([
            ("$classname", .string(name)),
            ("$classes", .array([.string(name), .string("NSObject")])),
        ])
    }
}

/// Reads the `_tiD` archive that the `_tiStart` response carries.
public enum RTISession {
    /// Returns the 16 session UUID bytes.
    /// It follows `$top.sessionUUID`. The target is raw bytes or an NSUUID object.
    /// The fallback is the first object with `NS.uuidbytes`.
    public static func sessionUUID(from archive: Data) -> Data? {
        if let value = KeyedArchiveReader.property(in: archive, path: ["sessionUUID"]) {
            if let bytes = value.dataValue { return bytes }
            if let bytes = value["NS.uuidbytes"]?.dataValue { return bytes }
        }
        for object in KeyedArchiveReader.objects(in: archive) {
            if let bytes = object["NS.uuidbytes"]?.dataValue { return bytes }
        }
        return nil
    }

    /// Returns the text that the tvOS field holds now.
    /// The path is `$top.documentState.docSt.contextBeforeInput`.
    public static func currentText(from archive: Data) -> String? {
        KeyedArchiveReader.property(in: archive, path: ["documentState", "docSt", "contextBeforeInput"])?.stringValue
    }
}
