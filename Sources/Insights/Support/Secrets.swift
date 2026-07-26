struct Secret: Sendable,
                 CustomStringConvertible,
                 CustomDebugStringConvertible,
                 CustomReflectable {
      private let value: String

      init(_ value: String) {
          self.value = value
      }

      func getSecretValue() -> String {
          value
      }

      var description: String {
          "«redacted»"
      }

      var debugDescription: String {
          "«redacted»"
      }

      var customMirror: Mirror {
          Mirror(reflecting: "«redacted»")
      }
  }
