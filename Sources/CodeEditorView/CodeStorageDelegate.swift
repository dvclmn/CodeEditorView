//
//  CodeStorageDelegate.swift
//
//
//  Created by Manuel M T Chakravarty on 29/09/2020.
//
//  'NSTextStorageDelegate' for code views compute, collect, store, and update additional information about the text
//  stored in the 'NSTextStorage' that they serve. This is needed to quickly navigate the text (e.g., at which character
//  position does a particular line start) and to support code-specific rendering (e.g., syntax highlighting).
//
//  It also handles the language service, if available. We need to have the language service available here, as
//  functionality, such as semantic tokens, interacts with functionality in here, such as token highlighting. The code
//  view accesses the language service from here.

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import os

import Rearrange

import LanguageSupport


private let logger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "CodeStorageDelegate")


// MARK: -
// MARK: Visual debugging support

// FIXME: It should be possible to enable this via a defaults setting.
private let visualDebugging               = false
private let visualDebuggingEditedColour   = OSColor(red: 0.5, green: 1.0, blue: 0.5, alpha: 0.3)
private let visualDebuggingLinesColour    = OSColor(red: 0.5, green: 0.5, blue: 1.0, alpha: 0.3)
private let visualDebuggingTrailingColour = OSColor(red: 1.0, green: 0.5, blue: 0.5, alpha: 0.3)
private let visualDebuggingTokenColour    = OSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)


// MARK: -
// MARK: Tokens

/// The supported comment styles.
///
enum CommentStyle {
    case singleLineComment
    case nestedComment
}

/// Information that is tracked on a line by line basis in the line map.
///
/// NB: We need the comment depth at the start and the end of each line as, during editing, lines are replaced in the
///     line map before comment attributes are recalculated. During this replacement, we lose the line info of all the
///     replaced lines.
///
struct LineInfo {
    
    var commentDepthStart: Int   // nesting depth for nested comments at the start of this line
    var commentDepthEnd:   Int   // nesting depth for nested comments at the end of this line
    
    // FIXME: we are not currently using the following three variables (they are maintained, but they are never useful).
    var roundBracketDiff:  Int   // increase or decrease of the nesting level of round brackets on this line
    var squareBracketDiff: Int   // increase or decrease of the nesting level of square brackets on this line
    var curlyBracketDiff:  Int   // increase or decrease of the nesting level of curly brackets on this line
    
    /// The tokens extracted from the text on this line.
    ///
    /// NB: The ranges contained in the tokens are relative to the *start of the line* and 0-based.
    ///
    var tokens: [LanguageConfiguration.Tokeniser.Token]
    
    /// Ranges of this line that are commented out.
    ///
    /// NB: The ranges are relative to the *start of the line* and 0-based.
    ///
    var commentRanges: [NSRange]
    
}


// MARK: -
// MARK: Delegate class

class CodeStorageDelegate: NSObject, NSTextStorageDelegate {
    
    weak var codeBlockManager: CodeBlockManager?
    
    private var tokeniser: LanguageConfiguration.Tokeniser?  // cache the tokeniser
    
    /// Language service for this document if available.
    ///
    //  var languageService: LanguageService? { language.languageService }
    
    /// Hook to propagate changes to the text store upwards in the view hierarchy.
    ///
    let setText: (String) -> Void
    
    private(set) var lineMap = LineMap<LineInfo>(string: "")
    
    /// If the last text change was a one-character addition, which completed a token, then that token is remembered here
    /// together with its range until the next text change.
    ///
    private var lastTypedToken: LanguageConfiguration.Tokeniser.Token?
    
    /// Indicates that the language service is not to be notified of the next text change. (This is useful during
    /// initialisation.)
    ///
    //  var skipNextChangeNotificationToLanguageService: Bool = false
    
    /// Indicates whether the current editing round is for a wholesale replacement of the text.
    ///
    private(set) var processingStringReplacement: Bool = false
    
    /// Indicates whether the current editing round is for a one-character addition to the text.
    ///
    private(set) var processingOneCharacterAddition: Bool = false
    
    /// Indicates the number of characters added by token completion in the current editing round.
    ///
    private(set) var tokenCompletionCharacters: Int = 0
    
    /// Contains the range of characters whose token information was invalidated by the last editing operation.
    ///
    private(set) var tokenInvalidationRange: NSRange? = nil
    
    /// Contains the number of lines affected by `tokenInvalidationRange`.
    ///
    private(set) var tokenInvalidationLines: Int? = nil
    
    
    // MARK: Initialisers
    
    init(codeBlockManager: CodeBlockManager?, setText: @escaping (String) -> Void) {
        self.codeBlockManager = codeBlockManager
        self.setText = setText
        super.init()
    }
    

    
    // MARK: Updates
    
    /// Change the language for a specific range in the code storage.
    ///
    /// - Parameters:
    ///   - language: The new language configuration.
    ///   - codeStorage: The code storage to update.
    ///   - range: The range to apply the new language to.
    func change(language: LanguageConfiguration, for codeStorage: CodeStorage, in range: NSRange) async throws {
        
        codeBlockManager?.updateCodeBlock(at: range, newLanguage: language)
        
        self.tokeniser = Tokeniser(for: language.tokenDictionary)
        let _ = tokenise(range: NSRange(location: 0, length: codeStorage.length), in: codeStorage)
    }

    
    // MARK: Delegate methods
    
    func textStorage(_ textStorage: NSTextStorage,
                     willProcessEditing editedMask: TextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int)
    {
        tokenInvalidationRange = nil
        tokenInvalidationLines = nil
        guard let codeStorage = textStorage as? CodeStorage else { return }
        
        // If only attributes change, the line map and syntax highlighting remains the same => nothing for us to do
        guard editedMask.contains(.editedCharacters) else { return }
        
        // FIXME: This (and the rest of visual debugging) needs to be rewritten to use rendering attributes.
        if visualDebugging {
            let wholeTextRange = NSRange(location: 0, length: textStorage.length)
            textStorage.removeAttribute(.backgroundColor, range: wholeTextRange)
            textStorage.removeAttribute(.underlineColor, range: wholeTextRange)
            textStorage.removeAttribute(.underlineStyle, range: wholeTextRange)
        }
        
        // Determine the ids of message bundles that are invalidated by this edit.
//        let lines = lineMap.linesAffected(by: editedRange, changeInLength: delta)
//        
//        let endColumn = if let beforeLine = lines.last,
//            let beforeLineInfo = lineMap.lookup(line: beforeLine)
//        {
//            editedRange.max - delta - beforeLineInfo.range.location
//        } else { 0 }
        
        lineMap.updateAfterEditing(string: textStorage.string, range: editedRange, changeInLength: delta)
        var (affectedRange: highlightingRange, lines: highlightingLines) = tokenise(range: editedRange, in: textStorage)
        
        processingStringReplacement = editedRange == NSRange(location: 0, length: textStorage.length)
        
        // If a single character was added, process token-level completion steps (and remember that we are processing a
        // one character addition).
        processingOneCharacterAddition = delta == 1 && editedRange.length == 1
        var editedRange = editedRange
        var delta       = delta
        if processingOneCharacterAddition {
            
            tokenCompletionCharacters = tokenCompletion(for: codeStorage, at: editedRange.location)
            if tokenCompletionCharacters > 0 {
                
                // Update line map with completion characters.
                lineMap.updateAfterEditing(string: textStorage.string, range: NSRange(location: editedRange.location + 1,
                                                                                      length: tokenCompletionCharacters),
                                           changeInLength: tokenCompletionCharacters)
                
                // Adjust the editing range and delta
                editedRange.length += tokenCompletionCharacters
                delta              += tokenCompletionCharacters
                
                // Re-tokenise the whole lot with the completion characters included
                let extraHighlighting = tokenise(range: editedRange, in: textStorage)
                highlightingRange = highlightingRange.union(extraHighlighting.affectedRange)
                highlightingLines += extraHighlighting.lines
                
            }
        }
        
        // The range within which highlighting has to be re-rendered.
        tokenInvalidationRange = highlightingRange
        tokenInvalidationLines = highlightingLines
        
        if visualDebugging {
            textStorage.addAttribute(.backgroundColor, value: visualDebuggingEditedColour, range: editedRange)
        }
        
        // MARK: [Note Propagating text changes into SwiftUI]
        // We need to trigger the propagation of text changes via the binding passed to the `CodeEditor` view here and *not*
        // in the `NSTextViewDelegate` or `UITextViewDelegate`. The reason for this is the composition of characters with
        // diacritics using muliple key strokes. Until the composition is complete, the already entered composing characters
        // are indicated by marked text and do *not* lead to the signaling of text changes by `NSTextViewDelegate` or
        // `UITextViewDelegate`, although they *do* alter the text storage. However, the methods of `NSTextStorageDelegate`
        // are invoked at each step of the composition process, faithfully representing the state changes of the text
        // storage.
        //
        // Why is this important? Because `CodeEditor.updateNSView(_:context:)` and `CodeEditor.updateUIView(_:context:)`
        // compare the current contents of the text binding with the current contents of the text storage to determine
        // whether the latter needs to be updated. If the text storage changes without propagating the change to the
        // binding, this check inside `CodeEditor.updateNSView(_:context:)` and `CodeEditor.updateUIView(_:context:)` will
        // suggest that the text storage needs to be overwritten by the contents of the binding, incorrectly removing any
        // entered composing characters (i.e., the marked text).
        setText(textStorage.string)
        
        //    if !skipNextChangeNotificationToLanguageService {
        //
        //      // Notify language service (if attached)
        //      let text         = (textStorage.string as NSString).substring(with: editedRange),
        //          afterLine    = lineMap.lineOf(index: editedRange.max),
        //          lineChange   = if let afterLine,
        //                            let beforeLine = lines.last { afterLine - beforeLine } else { 0 },
        //          columnChange = if let afterLine,
        //                            let info = lineMap.lookup(line: afterLine)
        //                         {
        //                           editedRange.max - info.range.location - endColumn
        //                         } else { 0 }
        //      Task { [editedRange, delta] in
        //        try await languageService?.documentDidChange(position: editedRange.location,
        //                                                     changeInLength: delta,
        //                                                     lineChange: lineChange,
        //                                                     columnChange: columnChange,
        //                                                     newText: text)
        //      }
        //    } else { skipNextChangeNotificationToLanguageService = false }
    }
}


// MARK: -
// MARK: Location conversion

extension CodeStorageDelegate {
    
    /// This class serves as a location service on the basis of the line map of an encapsulated storage delegate.
    ///
//    final class LineMapLocationService: LocationService {
//        private weak var codeStorageDelegate: CodeStorageDelegate?
//        
//        enum ConversionError: Error {
//            case lineMapUnavailable
//            case locationOutOfBounds
//            case lineOutOfBounds
//        }
//        
//        /// Location converter on the basis of the line map of the given storage delegate.
//        ///
//        /// - Parameter codeStorageDelegate: The code storage delegate whose line map ought to serve as the basis for the
//        ///   conversion.
//        ///
//        init(codeStorageDelegate: CodeStorageDelegate) {
//            self.codeStorageDelegate = codeStorageDelegate
//        }
//        
//        func textLocation(from location: Int) -> Result<TextLocation, Error> {
//            guard let lineMap = codeStorageDelegate?.lineMap else { return .failure(ConversionError.lineMapUnavailable) }
//            
//            if let line    = lineMap.lineOf(index: location),
//               let oneLine = lineMap.lookup(line: line)
//            {
//                
//                return .success(TextLocation(zeroBasedLine: line, column: location - oneLine.range.location))
//                
//            } else { return .failure(ConversionError.locationOutOfBounds) }
//        }
//        
//        func location(from textLocation: TextLocation) -> Result<Int, Error> {
//            guard let lineMap = codeStorageDelegate?.lineMap else { return .failure(ConversionError.lineMapUnavailable) }
//            
//            if let oneLine = lineMap.lookup(line: textLocation.zeroBasedLine) {
//                
//                return .success(oneLine.range.location + textLocation.zeroBasedColumn)
//                
//            } else { return .failure(ConversionError.lineOutOfBounds) }
//        }
//        
//        func length(of zeroBasedLine: Int) -> Int? { codeStorageDelegate?.lineMap.lookup(line: zeroBasedLine)?.range.length }
//    }
    
    /// Yield a location converter for the text maintained by the present code storage delegate.
    ///
//    var lineMapLocationConverter: LineMapLocationService { LineMapLocationService(codeStorageDelegate: self) }
}


// MARK: -
// MARK: Tokenisation

extension CodeStorageDelegate {
    
    /// Tokenise the substring of the given text storage that contains the specified lines and store tokens as part of the
    /// line information.
    ///
    /// - Parameters:
    ///   - originalRange: The character range that contains all characters that have changed.
    ///   - textStorage: The text storage that contains the changed characters.
    /// - Returns: The range of text affected by tokenisation together with the number of lines the range spreads over.
    ///     This can be more than the `originalRange` as changes in commenting and the like might affect large portions of
    ///     text.
    ///
    /// Tokenisation happens at line granularity. Hence, the range is correspondingly extended. Moreover, tokens must not
    /// span across lines as they will always only associated with the line on which they start.
    ///
    
    // MARK: Tokenization
    
    
    func tokenise(range originalRange: NSRange, in textStorage: NSTextStorage) -> (affectedRange: NSRange, lines: Int) {
        
        // NB: The range property of the tokens is in terms of the entire text (not just `line`).
        func tokeniseAndUpdateInfo<Tokens: Collection<Tokeniser<LanguageConfiguration.Token,
                                                                LanguageConfiguration.State>.Token>> (
                                                                    for line: Int,
                                                                    tokens: Tokens,
                                                                    commentDepth: inout Int,
                                                                    lastCommentStart: inout Int?
                                                                )
        {
            
            guard let lineRange = lineMap.lookup(line: line)?.range else {
                return
            }
            
            if visualDebugging {
                for token in tokens {
                    textStorage.addAttribute(.underlineColor, value: visualDebuggingTokenColour, range: range)
                    if token.range.length > 0 {
                        textStorage.addAttribute(.underlineStyle,
                                                 value: NSNumber(value: NSUnderlineStyle.double.rawValue),
                                                 range: NSRange(location: token.range.location, length: 1))
                    }
                    if token.range.length > 1 {
                        textStorage.addAttribute(.underlineStyle,
                                                 value: NSNumber(value: NSUnderlineStyle.single.rawValue),
                                                 range: NSRange(location: token.range.location + 1,
                                                                length: token.range.length - 1))
                    }
                }
            }
            
            let localisedTokens = tokens.map{ $0.shifted(by: -lineRange.location) }
            
            var lineInfo = LineInfo(
                commentDepthStart: commentDepth,
                commentDepthEnd: 0,
                roundBracketDiff: 0,
                squareBracketDiff: 0,
                curlyBracketDiff: 0,
                tokens: localisedTokens,
                commentRanges: []
            )
            
        tokenLoop: for token in localisedTokens {
            
            switch token.token {
                
            case .roundBracketOpen:
                lineInfo.roundBracketDiff += 1
                
            case .roundBracketClose:
                lineInfo.roundBracketDiff -= 1
                
            case .squareBracketOpen:
                lineInfo.squareBracketDiff += 1
                
            case .squareBracketClose:
                lineInfo.squareBracketDiff -= 1
                
            case .curlyBracketOpen:
                lineInfo.curlyBracketDiff += 1
                
            case .curlyBracketClose:
                lineInfo.curlyBracketDiff -= 1
                
            case .singleLineComment:  // set comment attribute from token start token to the end of this line
                let commentStart = token.range.location
                lineInfo.commentRanges.append(NSRange(location: commentStart, length: lineRange.length - commentStart))
                break tokenLoop   // the rest of the tokens are ignored as they are commented out and we'll rescan on change
                
            case .nestedCommentOpen:
                if commentDepth == 0 { lastCommentStart = token.range.location }    // start of an outermost nested comment
                commentDepth += 1
                
            case .nestedCommentClose:
                if commentDepth > 0 {
                    
                    commentDepth -= 1
                    
                    // If we just closed an outermost nested comment, attribute the comment range
                    if let start = lastCommentStart, commentDepth == 0
                    {
                        lineInfo.commentRanges.append(NSRange(location: start, length: token.range.max - start))
                        lastCommentStart = nil
                    }
                }
                
            default:
                break
            }
        }  // END token loop
            
            // If the line ends while we are still in an open comment, we need a comment attribute up to the end of the line
            if let start = lastCommentStart, commentDepth > 0 {
                
                lineInfo.commentRanges.append(NSRange(location: start, length: lineRange.length - start))
                lastCommentStart = 0
            }
            
            // Retain computed line information
            lineInfo.commentDepthEnd = commentDepth
            lineMap.setInfoOf(line: line, to: lineInfo)
            
        } // END tokeniseAndUpdateInfo
        
        
        guard let tokeniser = tokeniser else { return (affectedRange: originalRange, lines: 1) }
        
        // Extend the range to line boundaries. Because we cannot parse partial tokens, we at least need to go to word
        // boundaries, but because we have line bounded constructs like comments to the end of the line and it is easier to
        // determine the line boundaries, we use those.
        let lines = lineMap.linesContaining(range: originalRange),
            range = lineMap.charRangeOf(lines: lines)
        
        guard let stringRange = Range<String.Index>(range, in: textStorage.string)
        else { return (affectedRange: originalRange, lines: lines.count) }
        
        // Determine the comment depth as determined by the preceeeding code. This is needed to determine the correct
        // tokeniser and to compute attribute information from the resulting tokens. NB: We need to get that info from
        // the previous line, because the line info of the current line was set to `nil` during updating the line map.
        
        
        let language: LanguageConfiguration
        
        if let codeBlockManager = self.codeBlockManager {
            language = codeBlockManager.languageAndRangeContaining(location: range.location).language
        } else {
            language = .none // Make sure you have a default language defined
        }
        
        
        let initialCommentDepth = lineMap.lookup(line: lines.startIndex - 1)?.info?.commentDepthEnd ?? 0
        
        let initialTokeniserState: LanguageConfiguration.State = initialCommentDepth > 0
        ? .tokenisingCode(state: .comment(language: language, depth: initialCommentDepth))
        : .tokenisingCode(state: .code(language: language))
        
        
        // Set the token attribute in range.
        //        let initialTokeniserState: LanguageConfiguration.State = initialCommentDepth > 0 ? .tokenisingComment(initialCommentDepth) : .tokenisingCode,
        let tokens = textStorage
            .string[stringRange]
            .tokenise(with: tokeniser, state: initialTokeniserState)
            .map{ $0.shifted(by: range.location) } // adjust tokens to be relative to the whole `string`
        
        // For all lines in range, collect the tokens line by line, while keeping track of nested comments
        //
        // - `lastCommentStart` keeps track of the last start of an *outermost* nested comment.
        //
        var commentDepth = initialCommentDepth
        var lastCommentStart = initialCommentDepth > 0 ? lineMap.lookup(line: lines.startIndex)?.range.location : nil
        var remainingTokens  = tokens
        
        for line in lines {
            
            guard let lineRange = lineMap.lookup(line: line)?.range else { continue }
            let thisLinesTokens = remainingTokens.prefix(while: { $0.range.location < lineRange.max })
            tokeniseAndUpdateInfo(for: line,
                                  tokens: thisLinesTokens,
                                  commentDepth: &commentDepth,
                                  lastCommentStart: &lastCommentStart)
            remainingTokens.removeFirst(thisLinesTokens.count)
            
        }
        
        // Continue to re-process line by line until there is no longer a change in the comment depth before and after
        // re-processing
        //
        var currentLine = lines.endIndex
        var highlightingRange = range
        var highlightingLines = lines.count
        
        
    trailingLineLoop: while currentLine < lineMap.lines.count {
        
        if let lineEntry = lineMap.lookup(line: currentLine), let lineEntryRange = Range<String.Index>(lineEntry.range, in: textStorage.string) {
            
            // If this line has got a line info entry and the expected comment depth at the start of the line matches
            // the current comment depth, we reached the end of the range of lines affected by this edit => break the loop
            if let depth = lineEntry.info?.commentDepthStart, depth == commentDepth { break trailingLineLoop }
            
            
            // Re-tokenise line
            let initialTokeniserState: LanguageConfiguration.State = commentDepth > 0 ? .tokenisingCode(state: .comment(language: language, depth: commentDepth)) : .tokenisingCode(state: .code(language: language)),
                tokens = textStorage
                .string[lineEntryRange]
                .tokenise(with: tokeniser, state: initialTokeniserState)
                .map{ $0.shifted(by: lineEntry.range.location) } // adjust tokens to be relative to the whole `string`
            
            // Collect the tokens and update line info
            tokeniseAndUpdateInfo(for: currentLine,
                                  tokens: tokens,
                                  commentDepth: &commentDepth,
                                  lastCommentStart: &lastCommentStart)
            
            // Keep track of the trailing range to report back to the caller.
            highlightingRange = NSUnionRange(highlightingRange, lineEntry.range)
            highlightingLines += 1
            
        } // END line entry
        
        currentLine += 1
    }
        
        //        requestSemanticTokens(for: lines, in: textStorage)
        
        if visualDebugging {
            textStorage.addAttribute(.backgroundColor, value: visualDebuggingTrailingColour, range: highlightingRange)
            textStorage.addAttribute(.backgroundColor, value: visualDebuggingLinesColour, range: range)
        }
        
        return (affectedRange: highlightingRange, lines: highlightingLines)
        
    } // END tokenise
    
    /// Query semantic tokens for the given lines from the language service (if available) and merge them into the token
    /// information for those lines (maintained in the line map),
    ///
    /// - Parameters:
    ///     lines: The lines for which semantic token information is requested.
    ///     textStorage: The text storage whose contents is being tokenised.
    ///
    
    
    /// Merge semantic token information for one line into the line map.
    ///
    /// - Parameters:
    ///   - semanticTokens: The semntic tokens to merge.
    ///   - line: The line on which the tokens are located.
    ///
    /// NB: Currently, we only enrich the information of tokens that are already present as syntactic tokens.
    ///
    private func merge(semanticTokens: [(token: LanguageConfiguration.Token, range: NSRange)], into line: Int) {
        guard var info = lineMap.lookup(line: line)?.info,
              !semanticTokens.isEmpty       // Short-cut if there are no semantic tokens
        else { return }
        
        var remainingSemanticTokens = semanticTokens
        var tokens                  = info.tokens
        for i in 0..<tokens.count {
            
            let token = tokens[i]
            while let semanticToken = remainingSemanticTokens.first,
                  semanticToken.range.location <= token.range.location
            {
                remainingSemanticTokens.removeFirst()
                
                // We enrich identifier and operator tokens if the semantic token is an identifier, operator, or keyword.
                if semanticToken.range == token.range
                    && (token.token.isIdentifier || token.token.isOperator)
                    && (semanticToken.token.isIdentifier || semanticToken.token.isOperator || semanticToken.token == .keyword)
                {
                    tokens[i] = LanguageConfiguration.Tokeniser.Token(token: semanticToken.token, range: token.range)
                }
            }
        }
        
        // Store updated token array
        info.tokens = tokens
        lineMap.setInfoOf(line: line, to: info)
    }
}


// MARK: -
// MARK: Token completion

extension CodeStorageDelegate {
    
    /// Handle token completion actions after a single character was inserted.
    ///
    /// - Parameters:
    ///   - codeStorage: The code storage where the edit action occured.
    ///   - index: The location within the text storage where the single character was inserted.
    /// - Returns: The number of characters added.
    ///
    /// This function only adds characters right after `index`. (This is crucial so that the caller knows where to adjust
    /// the line map and tokenisation.)
    ///
    func tokenCompletion(for codeStorage: CodeStorage, at index: Int) -> Int {
        guard let codeBlockManager = codeBlockManager else {
            return 0 // No completion if we can't determine the language
        }
        
        let (_, language) = codeBlockManager.languageAndRangeContaining(location: index)
        
        /// If the given token is an opening bracket, return the lexeme of its matching closing bracket.
        ///
        func matchingLexemeForOpeningBracket(_ token: LanguageConfiguration.Token) -> String? {
            if token.isOpenBracket, let matching = token.matchingBracket, let lexeme = language.lexeme(of: matching) {
                return lexeme
            } else {
                return nil
            }
        }
        
        /// Determine whether the ranges of the two tokens are overlapping.
        ///
        func overlapping(_ previousToken: LanguageConfiguration.Tokeniser.Token,
                         _ currentToken: LanguageConfiguration.Tokeniser.Token?)
        -> Bool
        {
            if let currentToken = currentToken {
                return NSIntersectionRange(previousToken.range, currentToken.range).length != 0
            } else { return false }
        }
        
        
        let string             = codeStorage.string,
            char               = string.utf16[string.index(string.startIndex, offsetBy: index)],
            previousTypedToken = lastTypedToken,
            currentTypedToken  = codeStorage.tokenOnly(at: index)
        
        lastTypedToken = currentTypedToken    // this is the default outcome, unless explicitly overridden below
        
        // The just entered character is right after the previous token and it doesn't belong to a token overlapping with
        // the previous token
        if let previousToken = previousTypedToken, previousToken.range.max == index,
           !overlapping(previousToken, currentTypedToken) {
            
            let completingString: String?
            
            // If the previous token was an opening bracket, we may have to autocomplete by inserting a matching closing
            // bracket
            if let matchingPreviousLexeme = matchingLexemeForOpeningBracket(previousToken.token)
            {
                
                if let currentToken = currentTypedToken {
                    
                    if currentToken.token == previousToken.token.matchingBracket {
                        
                        // The current token is a matching closing bracket for the opening bracket of the last token => nothing to do
                        completingString = nil
                        
                    } else if let matchingCurrentLexeme = matchingLexemeForOpeningBracket(currentToken.token) {
                        
                        // The current token is another opening bracket => insert matching closing for the current and previous
                        // opening bracket
                        completingString = matchingCurrentLexeme + matchingPreviousLexeme
                        
                    } else {
                        
                        // Insertion of an unrelated or non-bracket token => just complete the previous opening bracket
                        completingString = matchingPreviousLexeme
                        
                    }
                    
                } else {
                    
                    // If a opening curly brace or nested comment bracket is followed by a line break, add another line break
                    // before the matching closing bracket.
                    if let unichar = Unicode.Scalar(char),
                       CharacterSet.newlines.contains(unichar),
                       previousToken.token == .curlyBracketOpen || previousToken.token == .nestedCommentOpen
                    {
                        
                        // Insertion of a newline after a curly bracket => complete the previous opening bracket prefixed with an extra newline
                        completingString = String(unichar) + matchingPreviousLexeme
                        
                    } else {
                        
                        // Insertion of a character that doesn't complete a token => just complete the previous opening bracket
                        completingString = matchingPreviousLexeme
                        
                    }
                }
                
            } else { completingString = nil }
            
            // Insert completion, if any
            if let string = completingString {
                
                lastTypedToken = nil    // A completion renders the last token void
                codeStorage.replaceCharacters(in: NSRange(location: index + 1, length: 0), with: string)
                
            }
            return completingString?.utf16.count ?? 0
            
        } else { return 0 } // END previousToken check
    } // END tokenCompletion
} // END CodeStorageDelegate extension




