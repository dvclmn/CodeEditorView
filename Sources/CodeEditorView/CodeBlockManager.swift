//
//  File.swift
//
//
//  Created by Dave Coleman on 1/8/2024.
//

import Foundation
import LanguageSupport

struct CodeBlock {
    var range: NSRange
    var language: LanguageConfiguration
}


public class CodeBlockManager {
    
    private(set) var codeBlocks: [CodeBlock] = []
    
    var onLanguageChange: ((NSRange, LanguageConfiguration) -> Void)?
    
    
    func addCodeBlock(range: NSRange, language: LanguageConfiguration) {
        let newBlock = CodeBlock(range: range, language: language)
        codeBlocks.append(newBlock)
    }
    
    func updateCodeBlock(at range: NSRange, newLanguage: LanguageConfiguration) {
        if let index = codeBlocks.firstIndex(where: { $0.range.intersection(range) != nil }) {
            let oldLanguage = codeBlocks[index].language
            codeBlocks[index].language = newLanguage
            if oldLanguage.name != newLanguage.name {
                onLanguageChange?(codeBlocks[index].range, newLanguage)
            }
        }
    }
    
    
    func removeCodeBlock(at range: NSRange) {
        codeBlocks.removeAll { $0.range.intersection(range) != nil }
    }
    
    func languageForRange(_ range: NSRange) -> LanguageConfiguration? {
        codeBlocks.first { $0.range.intersection(range) != nil }?.language
    }
    
    func languageAndRangeContaining(location: Int) -> (range: NSRange, language: LanguageConfiguration) {
        if let block = codeBlocks.first(where: { $0.range.contains(location) }) {
            return (range: block.range, language: block.language)
        } else {
            // If no specific block is found, return the entire document range and the default language
            let documentRange = NSRange(location: 0, length: NSMaxRange(codeBlocks.last?.range ?? NSRange()))
            return (range: documentRange, language: .none)
        }
    }
    
    func checkForLanguageChanges(onChange: (NSRange, LanguageConfiguration) -> Void) {
        for (index, block) in codeBlocks.enumerated() {
            if let newLanguage = detectLanguageChange(in: block) {
                codeBlocks[index].language = newLanguage
                onChange(block.range, newLanguage)
            }
        }
    }
    private func detectLanguageChange(in block: CodeBlock) -> LanguageConfiguration? {
        
        return nil
        // Implement logic to detect if the language identifier has changed
        // This might involve parsing the first line of the block and comparing
        // it with the current language
        // Return the new LanguageConfiguration if changed, nil otherwise
    }
    
}
