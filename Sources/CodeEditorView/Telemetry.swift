//
//  Telemetry.swift
//  CodeEditorView
//
//  Created by Dave Coleman on 31/7/2024.
//

import SwiftUI
import TestStrings


extension CodeEditor {
//    private func updateTelemetry(_ textView: NSTextView) {
//        guard let selectedRange = textView.selectedRanges.first as? NSRange else { return }
        
//    }
    
    //    private func determineMode(at position: Int, in textView: NSTextView) -> EditorMode {
    // Logic to determine if we're in Markdown or code mode
    // This might involve checking if we're inside a code block
    // Return appropriate EditorMode
    //    }
    
    //    private func determineSyntax(at position: Int, in textView: NSTextView) -> String? {
    // Logic to determine current syntax based on regex matches
    // Return name of matched syntax or nil
    //    }
}

extension String {
    func lineNumber(at index: Int) -> Int {
        return self.prefix(index).components(separatedBy: .newlines).count
    }
    
    func columnNumber(at index: Int) -> Int {
        guard let lastNewlineIndex = self.prefix(index).lastIndex(of: "\n") else {
            return index + 1
        }
        return self.distance(from: lastNewlineIndex, to: self.index(self.startIndex, offsetBy: index)) + 1
    }
}

struct TelemetryMode: View {
    
    @State private var telemetry = CodeEditor.Telemetry()
    
    var body: some View {
        
        VStack {
            
            CodeEditor(
                text: .constant(TestStrings.Markdown.basicMarkdown),
                position: .constant(CodeEditor.Position()),
                layout: .init(showMinimap: false, wrapText: true)
            )
            
            HStack {
                Text("Mode: \(modeDescription)")
                if let syntax = telemetry.currentSyntax {
                    Text("Syntax: \(syntax)")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(width: 600, height: 700)
        .background(.black.opacity(0.6))
        .background(.red.opacity(0.2))
        
        
        
    }
}
#Preview {
    TelemetryMode()
}
