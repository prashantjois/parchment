import SwiftUI

// Use the property wrapper explicitly. The macOS 27 SDK also exports a State
// macro whose plugin is absent from the standalone command-line toolchain.
typealias ViewState<Value> = SwiftUI.State<Value>
