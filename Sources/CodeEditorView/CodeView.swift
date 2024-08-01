//
//  CodeView.swift
//
//
//  Created by Manuel M T Chakravarty on 05/05/2021.
//
//  This file contains both the macOS and iOS versions of the subclass for `NSTextView` and `UITextView`, respectively,
//  which forms the heart of the code editor.

import os
import Combine
import SwiftUI

import Rearrange

import LanguageSupport


private let logger = Logger(subsystem: "org.justtesting.CodeEditorView", category: "CodeView")




#if os(iOS) || os(visionOS)

// MARK: -
// MARK: UIKit version

/// `UITextView` with a gutter
///
final class CodeView: UITextView {
    
    // Delegates
    fileprivate var codeViewDelegate:                     CodeViewDelegate?
    fileprivate var codeStorageDelegate:                  CodeStorageDelegate
    fileprivate let minimapTextLayoutManagerDelegate      = MinimapTextLayoutManagerDelegate()
    
    // Subviews
    var gutterView:               GutterView?
    var currentLineHighlightView: CodeBackgroundHighlightView?
    var minimapView:              UITextView?
    var minimapGutterView:        GutterView?
    var documentVisibleBox:       UIView?
    var minimapDividerView:       UIView?
    
    // Notification observer
    private var textDidChangeObserver: NSObjectProtocol?
    
    /// Contains the line on which the insertion point was located, the last time the selection range got set (if the
    /// selection was an insertion point at all; i.e., it's length was 0).
    ///
    var oldLastLineOfInsertionPoint: Int? = 1
    
    /// The current highlighting theme
    ///
    @Invalidating(.layout, .display)
    var theme: Theme = .defaultLight {
        didSet {
            font                                  = theme.font
            backgroundColor                       = theme.backgroundColour
            tintColor                             = theme.tintColour
            (textStorage as? CodeStorage)?.theme  = theme
            gutterView?.theme                     = theme
            currentLineHighlightView?.color       = theme.currentLineColour
            minimapView?.backgroundColor          = theme.backgroundColour
            minimapGutterView?.theme              = theme
            documentVisibleBox?.backgroundColor   = theme.textColour.withAlphaComponent(0.1)
        }
    }
    
    /// The current language configuration.
    ///
    /// We keep track of it here to enable us to spot changes during processing of view updates.
    ///
    @Invalidating(.layout, .display)
    var language: LanguageConfiguration = .none {
        didSet {
            if let codeStorage = optCodeStorage,
               oldValue.name != language.name || (oldValue.languageService != nil) != (language.languageService != nil)
            {
                Task { @MainActor in
                    try await codeStorageDelegate.change(language: language, for: codeStorage)
                    // FIXME: This is an awful kludge to get the code view to redraw with the new highlighting. Emitting
                    //        `codeStorage.edited(:range:changeInLength)` doesn't seem to work reliably.
                    Task { @MainActor in
                        font = theme.font
                    }
                }
            }
        }
    }
    
    /// The current view layout.
    ///
    @Invalidating(.layout)
    var viewLayout: CodeEditor.LayoutConfiguration = .standard
    
    /// Hook to propagate message sets upwards in the view hierarchy.
    ///
    let setMessages: (Set<TextLocated<Message>>) -> Void
    
    /// This is the last reported set of `messages`. New message sets can come from the context or from a language server.
    ///
    var lastMessages: Set<TextLocated<Message>> = Set()
    
    /// Keeps track of the set of message views.
    ///
    var messageViews: MessageViews = [:]
    
    /// Designated initializer for code views with a gutter.
    ///
    init(frame: CGRect,
         with language: LanguageConfiguration,
         viewLayout: CodeEditor.LayoutConfiguration,
         theme: Theme,
         setText: @escaping (String) -> Void,
         setMessages: @escaping (Set<TextLocated<Message>>) -> Void)
    {
        
        self.theme       = theme
        self.viewLayout  = viewLayout
        self.setMessages = setMessages
        
        // Use custom components that are gutter-aware and support code-specific editing actions and highlighting.
        let textLayoutManager  = NSTextLayoutManager(),
            codeContainer      = CodeContainer(size: frame.size),
            codeStorage        = CodeStorage(theme: theme),
            textContentStorage = CodeContentStorage()
        textLayoutManager.textContainer = codeContainer
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textContentStorage.primaryTextLayoutManager = textLayoutManager
        textContentStorage.textStorage              = codeStorage
        
        codeStorageDelegate = CodeStorageDelegate(with: language, setText: setText)
        
        super.init(frame: frame, textContainer: codeContainer)
        codeContainer.textView = self
        
        textLayoutManager.renderingAttributesValidator = { (textLayoutManager, layoutFragment) in
            guard let textContentStorage = textLayoutManager.textContentManager as? NSTextContentStorage else { return }
            codeStorage.setHighlightingAttributes(for: textContentStorage.range(for: layoutFragment.rangeInElement),
                                                  in: textLayoutManager)
        }
        
        // We can't do this — see [Note NSTextViewportLayoutControllerDelegate].
        //
        //    if let systemDelegate = codeLayoutManager.textViewportLayoutController.delegate {
        //      let codeViewportLayoutControllerDelegate = CodeViewportLayoutControllerDelegate(systemDelegate: systemDelegate,
        //                                                                                      codeView: self)
        //      self.codeViewportLayoutControllerDelegate               = codeViewportLayoutControllerDelegate
        //      codeLayoutManager.textViewportLayoutController.delegate = codeViewportLayoutControllerDelegate
        //    }
        
        // Set basic display and input properties
        font                   = theme.font
        backgroundColor        = theme.backgroundColour
        tintColor              = theme.tintColour
        autocapitalizationType = .none
        autocorrectionType     = .no
        spellCheckingType      = .no
        smartQuotesType        = .no
        smartDashesType        = .no
        smartInsertDeleteType  = .no
        
        // Line wrapping
        textContainerInset                  = .zero
        textContainer.widthTracksTextView  = false   // we need to be able to control the size (see `tile()`)
        textContainer.heightTracksTextView = false
        textContainer.lineBreakMode        = .byWordWrapping
        
        // Add the view delegate
        codeViewDelegate = CodeViewDelegate(codeView: self)
        delegate         = codeViewDelegate
        
        // Add a text storage delegate that maintains a line map
        codeStorage.delegate = codeStorageDelegate
        
        // Add a gutter view
        let gutterView  = GutterView(frame: .zero,
                                     textView: self,
                                     codeStorage: codeStorage,
                                     theme: theme,
                                     getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                     isMinimapGutter: false)
        gutterView.autoresizingMask  = []
        self.gutterView              = gutterView
        addSubview(gutterView)
        
        let currentLineHighlightView = CodeBackgroundHighlightView(color: theme.currentLineColour)
        self.currentLineHighlightView = currentLineHighlightView
        addBackgroundSubview(currentLineHighlightView)
        
        // Create the minimap with its own gutter, but sharing the code storage with the code view
        //
        let minimapView        = MinimapView(),
            minimapGutterView  = GutterView(frame: CGRect.zero,
                                            textView: minimapView,
                                            codeStorage: codeStorage,
                                            theme: theme,
                                            getMessageViews: { [weak self] in self?.messageViews ?? [:] },
                                            isMinimapGutter: true),
            minimapDividerView = UIView()
        minimapView.codeView = self
        
        minimapDividerView.backgroundColor = .separator
        self.minimapDividerView            = minimapDividerView
        addSubview(minimapDividerView)
        
        // We register the text layout manager of the minimap view as a secondary layout manager of the code view's text
        // content storage, so that code view and minimap use the same content.
        minimapView.textLayoutManager?.replace(textContentStorage)
        textContentStorage.primaryTextLayoutManager = textLayoutManager
        minimapView.textLayoutManager?.renderingAttributesValidator = { (minimapLayoutManager, layoutFragment) in
            guard let textContentStorage = minimapLayoutManager.textContentManager as? NSTextContentStorage else { return }
            codeStorage.setHighlightingAttributes(for: textContentStorage.range(for: layoutFragment.rangeInElement),
                                                  in: minimapLayoutManager)
        }
        minimapView.textLayoutManager?.delegate = minimapTextLayoutManagerDelegate
        
        minimapView.isScrollEnabled                    = false
        minimapView.backgroundColor                    = theme.backgroundColour
        minimapView.tintColor                          = theme.tintColour
        minimapView.isEditable                         = false
        minimapView.isSelectable                       = false
        minimapView.textContainerInset                 = .zero
        minimapView.textContainer.widthTracksTextView  = false    // we need to be able to control the size (see `tile()`)
        minimapView.textContainer.heightTracksTextView = true
        minimapView.textContainer.lineBreakMode        = .byWordWrapping
        self.minimapView = minimapView
        addSubview(minimapView)
        
        minimapView.addSubview(minimapGutterView)
        self.minimapGutterView = minimapGutterView
        
        let documentVisibleBox = UIView()
        documentVisibleBox.backgroundColor = theme.textColour.withAlphaComponent(0.1)
        minimapView.addSubview(documentVisibleBox)
        self.documentVisibleBox = documentVisibleBox
        
        // We need to check whether we need to look up completions or cancel a running completion process after every text
        // change. We also need to remove evicted message views.
        textDidChangeObserver
        = NotificationCenter.default.addObserver(forName: UITextView.textDidChangeNotification,
                                                 object: self,
                                                 queue: .main){ [weak self] _ in
            
            self?.invalidateMessageViews(withIDs: self!.codeStorageDelegate.lastInvalidatedMessageIDs)
            self?.gutterView?.invalidateGutter()
            self?.minimapGutterView?.invalidateGutter()
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let observer = textDidChangeObserver { NotificationCenter.default.removeObserver(observer) }
    }
    
    // NB: Trying to do tiling and minimap adjusting on specific events, instead of here, leads to lots of tricky corner
    //     case.
    override func layoutSubviews() {
        tile()
        adjustScrollPositionOfMinimap()
        super.layoutSubviews()
        gutterView?.setNeedsDisplay()
        minimapGutterView?.setNeedsDisplay()
    }
}

final class CodeViewDelegate: NSObject, UITextViewDelegate {
    
    // Hooks for events
    //
    var textDidChange:      ((UITextView) -> ())?
    var selectionDidChange: ((UITextView) -> ())?
    var didScroll:          ((UIScrollView) -> ())?
    
    /// Caching the last set selected range.
    ///
    var oldSelectedRange: NSRange
    
    init(codeView: CodeView) {
        oldSelectedRange = codeView.selectedRange
    }
    
    // MARK: -
    // MARK: UITextViewDelegate protocol
    
    func textViewDidChange(_ textView: UITextView) { textDidChange?(textView) }
    
    func textViewDidChangeSelection(_ textView: UITextView) {
        guard let codeView = textView as? CodeView else { return }
        
        selectionDidChange?(textView)
        
        codeView.updateBackgroundFor(oldSelection: oldSelectedRange, newSelection: codeView.selectedRange)
        oldSelectedRange = textView.selectedRange
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let codeView = scrollView as? CodeView else { return }
        
        didScroll?(scrollView)
        
        codeView.gutterView?.invalidateGutter()
        codeView.adjustScrollPositionOfMinimap()
    }
}

/// Custom view for background highlights.
///
final class CodeBackgroundHighlightView: UIView {
    
    /// The background colour displayed by this view.
    ///
    var color: UIColor {
        get { backgroundColor ?? .clear }
        set { backgroundColor = newValue }
    }
    
    init(color: UIColor) {
        super.init(frame: .zero)
        self.color = color
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}


#elseif os(macOS)

// MARK: -
// MARK: AppKit version

/// `NSTextView` with a gutter
///
final class CodeView: NSTextView {
    
    // Delegates
    fileprivate let codeViewDelegate =                 CodeViewDelegate()
    fileprivate var codeStorageDelegate:               CodeStorageDelegate
    fileprivate let minimapTextLayoutManagerDelegate = MinimapTextLayoutManagerDelegate()
    fileprivate let minimapCodeViewDelegate =          CodeViewDelegate()
    
    // Subviews
    var gutterView:               GutterView?
    var currentLineHighlightView: CodeBackgroundHighlightView?
    var minimapView:              NSTextView?
    var minimapGutterView:        GutterView?
    var documentVisibleBox:       NSBox?
    var minimapDividerView:       NSBox?
    
    // Notification observer
    private var frameChangedNotificationObserver: NSObjectProtocol?
    private var didChangeNotificationObserver:    NSObjectProtocol?
    
    // Code blocks
//    @Invalidating(.layout, .display)
    var codeBlockManager = CodeBlockManager()
    
    /// Contains the line on which the insertion point was located, the last time the selection range got set (if the
    /// selection was an insertion point at all; i.e., it's length was 0).
    ///
    var oldLastLineOfInsertionPoint: Int? = 1
    
    /// The current highlighting theme
    ///
    @Invalidating(.layout, .display)
    var theme: Theme = .defaultLight {
        didSet {
            font                                 = theme.font
            backgroundColor                      = theme.backgroundColour
            insertionPointColor                  = theme.cursorColour
            selectedTextAttributes               = [.backgroundColor: theme.selectionColour]
            (textStorage as? CodeStorage)?.theme = theme
            gutterView?.theme                    = theme
            currentLineHighlightView?.color      = theme.currentLineColour
            minimapView?.backgroundColor         = theme.backgroundColour
            minimapGutterView?.theme             = theme
            documentVisibleBox?.fillColor        = theme.textColour.withAlphaComponent(0.1)
        }
    }

    /// The current view layout.
    ///
    @Invalidating(.layout)
    var viewLayout: CodeEditor.LayoutConfiguration = .standard
    
    /// For the consumption of the diagnostics stream.
    ///
    private var diagnosticsCancellable: Cancellable?
    
    /// For the consumption of the events stream from the language service.
    ///
    private var eventsCancellable: Cancellable?
    
    /// Cancellable task used to compute completions.
    ///
    var completionTask: Task<(), Error>?
    
    /// KVO observations that need to be retained.
    ///
    var observations: [NSKeyValueObservation] = []
    
    /// Designated initialiser for code views with a gutter.
    ///
    init(frame: CGRect,
         viewLayout: CodeEditor.LayoutConfiguration,
         theme: Theme,
         setText: @escaping (String) -> Void
    )
    {
        self.theme       = theme
        self.viewLayout  = viewLayout
        
        // Use custom components that are gutter-aware and support code-specific editing actions and highlighting.
        let textLayoutManager  = NSTextLayoutManager(),
            codeContainer      = CodeContainer(size: frame.size),
            codeStorage        = CodeStorage(theme: theme),
            textContentStorage = CodeContentStorage()
        textLayoutManager.textContainer = codeContainer
        textContentStorage.addTextLayoutManager(textLayoutManager)
        textContentStorage.primaryTextLayoutManager = textLayoutManager
        textContentStorage.textStorage              = codeStorage
        
        
        self.codeStorageDelegate = CodeStorageDelegate(codeBlockManager: nil, setText: setText)
        
        super.init(frame: frame, textContainer: codeContainer)
        
        codeStorageDelegate.codeBlockManager = codeBlockManager

        setupCodeBlockManager()
        
        textLayoutManager.setSafeRenderingAttributesValidator(with: codeViewDelegate) { (textLayoutManager, layoutFragment) in
            guard let textContentStorage = textLayoutManager.textContentManager as? NSTextContentStorage else { return }
            
            codeStorage.setHighlightingAttributes(for: textContentStorage.range(for: layoutFragment.rangeInElement),
                                                  in: textLayoutManager)
        }.flatMap { observations.append($0) }
        

        // Set basic display and input properties
        font                                 = theme.font
        backgroundColor                      = theme.backgroundColour
        insertionPointColor                  = theme.cursorColour
        selectedTextAttributes               = [.backgroundColor: theme.selectionColour]
        isRichText                           = false
        isAutomaticQuoteSubstitutionEnabled  = false
        isAutomaticLinkDetectionEnabled      = false
        smartInsertDeleteEnabled             = false
        isContinuousSpellCheckingEnabled     = false
        isGrammarCheckingEnabled             = false
        isAutomaticDashSubstitutionEnabled   = false
        isAutomaticDataDetectionEnabled      = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextReplacementEnabled    = false
        usesFontPanel                        = false
        
        // Line wrapping
        isHorizontallyResizable             = false
        isVerticallyResizable               = true
        textContainerInset                  = .zero
        textContainer?.widthTracksTextView  = false   // we need to be able to control the size (see `tile()`)
        textContainer?.heightTracksTextView = false
        textContainer?.lineBreakMode        = .byWordWrapping
        
        // FIXME: properties that ought to be configurable
        usesFindBar                   = true
        isIncrementalSearchingEnabled = true
        
        // Enable undo support
        allowsUndo = true
        
        // Add the view delegate
        delegate = codeViewDelegate
        
        // Add a text storage delegate that maintains a line map
        codeStorage.delegate = codeStorageDelegate
        
        // Create the main gutter view
        /// Dave edit
//        if !language.isMarkdown {
            let gutterView = GutterView(
                frame: CGRect.zero,
                textView: self,
                codeStorage: codeStorage,
                theme: theme,
                isMinimapGutter: false
            )
            gutterView.autoresizingMask = .none
            
            self.gutterView = gutterView
//        }
        // NB: The gutter view is floating. We cannot add it now, as we don't have an `enclosingScrollView` yet.
        
        let currentLineHighlightView = CodeBackgroundHighlightView(color: theme.currentLineColour)
        addBackgroundSubview(currentLineHighlightView)
        self.currentLineHighlightView = currentLineHighlightView
        
        self.setUpMiniMap(
            codeStorage: codeStorage,
            minimapTextLayoutManagerDelegate: minimapTextLayoutManagerDelegate,
            minimapCodeViewDelegate: minimapCodeViewDelegate
        )
        
        
        // We need to re-tile the subviews whenever the frame of the text view changes.
        frameChangedNotificationObserver
        = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                 object: enclosingScrollView,
                                                 queue: .main){ [weak self] _ in
            
            // NB: When resizing the window, where the text container doesn't completely fill the text view (i.e., the text
            //     is short), we need to explicitly redraw the gutter, as line wrapping may have changed, which affects
            //     line numbering.
            self?.gutterView?.needsDisplay = true
        }

    } // END CodeView init
    
    private func setupCodeBlockManager() {
            codeBlockManager.onLanguageChange = { [weak self] range, newLanguage in
                self?.updateLanguage(for: range, to: newLanguage)
            }
        }
    
    func updateLanguage(
        for range: NSRange,
        to newLanguage: LanguageConfiguration
    ) {
            if let codeStorage = optCodeStorage {
                Task { @MainActor in
                    do {
                        try await codeStorageDelegate.change(language: newLanguage, for: codeStorage, in: range)
                        
                        // Invalidate layout and display for the affected range
                        self.setNeedsDisplay(self.bounds)
                        self.layoutManager?.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                        
                    } catch let error {
                        logger.trace("Failed to change language to \(newLanguage.name) for range \(range): \(error.localizedDescription)")
                    }
                    
                    // FIXME: This is an awful kludge to get the code view to redraw with the new highlighting.
                    Task { @MainActor in
                        self.font = self.theme.font
                    }
                }
            }
        }
    
   

    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        if let observer = frameChangedNotificationObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = didChangeNotificationObserver { NotificationCenter.default.removeObserver(observer) }
    }
    
    
    // MARK: Overrides
    
    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        let oldSelectedRanges = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        
        // Updates only if there is an actual selection change.
        if oldSelectedRanges != selectedRanges {
            
            minimapView?.selectedRanges = selectedRanges    // minimap mirrors the selection of the main code view
            
            updateBackgroundFor(oldSelection: combinedRanges(ranges: oldSelectedRanges),
                                newSelection: combinedRanges(ranges: ranges))
            
        }
    }
    
    override func layout() {
        tile()
        adjustScrollPositionOfMinimap()
        super.layout()
        gutterView?.needsDisplay        = true
        minimapGutterView?.needsDisplay = true
    }
    
    
}

class CodeViewDelegate: NSObject, NSTextViewDelegate {
    
    // Hooks for events
    //
    var textDidChange:      ((NSTextView) -> ())?
    var selectionDidChange: ((NSTextView) -> ())?
    
    // MARK: NSTextViewDelegate protocol
    
    func textView(_ textView: NSTextView,
                  willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
                  toCharacterRanges newSelectedCharRanges: [NSValue])
    -> [NSValue]
    {
        guard let codeStorageDelegeate = textView.textStorage?.delegate as? CodeStorageDelegate
        else { return newSelectedCharRanges }
        
        // If token completion added characters, we don't want to include them in the advance of the insertion point.
        if codeStorageDelegeate.tokenCompletionCharacters > 0,
           let selectionRange = newSelectedCharRanges.first as? NSRange,
           selectionRange.length == 0
        {
            
            let insertionPointWithoutCompletion = selectionRange.location - codeStorageDelegeate.tokenCompletionCharacters
            return [NSRange(location: insertionPointWithoutCompletion, length: 0) as NSValue]
            
        } else { return newSelectedCharRanges }
    }
    
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        
        textDidChange?(textView)
    }
    
    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        
        selectionDidChange?(textView)
    }
}

/// Custom view for background highlights.
///
final class CodeBackgroundHighlightView: NSBox {
    
    /// The background colour displayed by this view.
    ///
    var color: NSColor {
        get { fillColor }
        set { fillColor = newValue }
    }
    
    init(color: NSColor) {
        super.init(frame: .zero)
        self.color  = color
        boxType     = .custom
        borderWidth = 0
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}


#endif


// MARK: -
// MARK: Shared code

extension CodeView {
    
    // MARK: Background highlights
    
    /// Update the code background for the given selection change.
    ///
    /// - Parameters:
    ///   - oldRange: Old selection range.
    ///   - newRange: New selection range.
    ///
    /// This includes both invalidating rectangle for background redrawing as well as updating the frames of background
    /// (highlighting) views.
    ///
    func updateBackgroundFor(oldSelection oldRange: NSRange, newSelection newRange: NSRange) {
        guard let textContentStorage = optTextContentStorage else { return }
        
        let lineOfInsertionPoint = insertionPoint.flatMap{ optLineMap?.lineOf(index: $0) }
        
        // If the insertion point changed lines, we need to redraw at the old and new location to fix the line highlighting.
        // NB: We retain the last line and not the character index as the latter may be inaccurate due to editing that let
        //     to the selected range change.
        if lineOfInsertionPoint != oldLastLineOfInsertionPoint {
            
            if let textLocation = textContentStorage.textLocation(for: oldRange.location) {
                minimapView?.invalidateBackground(forLineContaining: textLocation)
            }
            
            if let textLocation = textContentStorage.textLocation(for: newRange.location) {
                updateCurrentLineHighlight(for: textLocation)
                minimapView?.invalidateBackground(forLineContaining: textLocation)
            }
        }
        oldLastLineOfInsertionPoint = lineOfInsertionPoint
        
        // Needed as the selection affects line number highlighting.
        // NB: Invalidation of the old and new ranges needs to happen separately. If we were to union them, an insertion
        //     point (range length = 0) at the start of a line would be absorbed into the previous line, which results in
        //     a lack of invalidation of the line on which the insertion point is located.
        
        /// Dave edit
        gutterView?.invalidateGutter(for: oldRange)
        gutterView?.invalidateGutter(for: newRange)
        minimapGutterView?.invalidateGutter(for: oldRange)
        minimapGutterView?.invalidateGutter(for: newRange)

    }
    
    func updateCurrentLineHighlight(for location: NSTextLocation) {
        guard let textLayoutManager = optTextLayoutManager else { return }
        
        ensureLayout(includingMinimap: false)
        
        // The current line highlight view needs to be visible if we have an insertion point (and not a selection range).
        currentLineHighlightView?.isHidden = insertionPoint == nil
        
        // The insertion point is inside the body of the text
        if let fragmentFrame = textLayoutManager.textLayoutFragment(for: location)?.layoutFragmentFrameWithoutExtraLineFragment,
           let highlightRect = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
        {
            currentLineHighlightView?.frame = highlightRect
        } else
        // OR the insertion point is behind the end of the text, which ends with a trailing newline (=> extra line fragement)
        if let previousLocation = optTextContentStorage?.location(location, offsetBy: -1),
           let fragmentFrame    = textLayoutManager.textLayoutFragment(for: previousLocation)?.layoutFragmentFrameExtraLineFragment,
           let highlightRect    = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
        {
            currentLineHighlightView?.frame = highlightRect
        } else
        // OR the insertion point is behind the end of the text, which does NOT end with a trailing newline
        if let previousLocation = optTextContentStorage?.location(location, offsetBy: -1),
           let fragmentFrame    = textLayoutManager.textLayoutFragment(for: previousLocation)?.layoutFragmentFrame,
           let highlightRect    = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height)
        {
            currentLineHighlightView?.frame = highlightRect
        } else
        // OR the document is empty
        if text.isEmpty,
           let highlightRect = lineBackgroundRect(y: 0, height: font?.lineHeight ?? 0)
        {
            currentLineHighlightView?.frame = highlightRect
        }
    }

    
    
    // MARK: Tiling
    
    /// Ensure that layout of the viewport region is complete.
    ///
    func ensureLayout(includingMinimap: Bool = true) {
        if let textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.textViewportLayoutController.viewportBounds)
        }
        if includingMinimap,
           let textLayoutManager = minimapView?.textLayoutManager
        {
            textLayoutManager.ensureLayout(for: textLayoutManager.textViewportLayoutController.viewportBounds)
        }
    }
    
    /// Position and size the gutter and minimap and set the text container sizes and exclusion paths. Take the current
    /// view layout in `viewLayout` into account.
    ///
    /// * The main text view contains three subviews: (1) the main gutter on its left side, (2) the minimap on its right
    ///   side, and (3) a divider in between the code view and the minimap gutter.
    /// * The main text view by way of `lineFragmentRect(forProposedRect:at:writingDirection:remaining:)`and the minimap
    ///   view (or rather their text container) by way of an exclusion path keep text out of the gutter view. The main
    ///   text view is moreover sized to avoid overlap with the minimap.
    /// * The minimap is a fixed factor `minimapRatio` smaller than the main text view and uses a correspondingly smaller
    ///   font accomodate exactly the same number of characters, so that line breaking procceds in the exact same way.
    ///
    /// NB: We don't use a ruler view for the gutter on macOS to be able to use the same setup on macOS and iOS.
    ///
    @MainActor
    private func tile() {
        guard let codeContainer = optTextContainer as? CodeContainer else { return }
        
#if os(macOS)
        // Add the floating views if they are not yet in the view hierachy.
        // NB: Since macOS 14, we need to explicitly set clipping; otherwise, views will draw outside of the bounds of the
        //     scroll view. We need to do this vor each view, as it is not guaranteed that they share a container view.
        
        /// Dave edit
        if let view = gutterView, view.superview == nil {
            
            enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
            view.superview?.clipsToBounds = true
            
        }
        if let view = minimapDividerView, view.superview == nil {
            enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
            view.superview?.clipsToBounds = true
        }
        if let view = minimapView, view.superview == nil {
            enclosingScrollView?.addFloatingSubview(view, for: .horizontal)
            view.superview?.clipsToBounds = true
        }
#endif
        
        // Compute size of the main view gutter
        //
        
        /// Dave: Consider implications of non-fixed-width fonts
        ///
        let theFont                 = font ?? OSFont.systemFont(ofSize: 0)
        let fontWidth               = theFont.maximumHorizontalAdvancement  // NB: we deal only with fixed width fonts
        let gutterWidthInCharacters = CGFloat(7)
        
        
        
        let gutterWidth: CGFloat             = .zero
//        let gutterWidth             = (ceil(fontWidth * gutterWidthInCharacters))
        let minimumHeight           = max(contentSize.height, documentVisibleRect.height)
        let gutterSize              = CGSize(width: gutterWidth, height: minimumHeight)
        let lineFragmentPadding     = CGFloat(5)
        
        if gutterView?.frame.size != gutterSize { gutterView?.frame = CGRect(origin: .zero, size: gutterSize) }
        
        // Compute sizes of the minimap text view and gutter
        //
        let minimapFontWidth     = fontWidth / minimapRatio,
            minimapGutterWidth   = ceil(minimapFontWidth * gutterWidthInCharacters),
            dividerWidth         = CGFloat(1),
            minimapGutterRect    = CGRect(origin: CGPoint.zero,
                                          size: CGSize(width: minimapGutterWidth, height: minimumHeight)).integral,
            minimapExtras        = minimapGutterWidth + dividerWidth,
            gutterWithPadding    = gutterWidth + lineFragmentPadding,
            visibleWidth         = documentVisibleRect.width,
            widthWithoutGutters  = if viewLayout.showMinimap { visibleWidth - gutterWithPadding - minimapExtras  }
        else { visibleWidth - gutterWithPadding },
        compositeFontWidth   = if viewLayout.showMinimap { fontWidth + minimapFontWidth  } else { fontWidth },
        numberOfCharacters   = widthWithoutGutters / compositeFontWidth,
        codeViewWidth        = if viewLayout.showMinimap { gutterWithPadding + ceil(numberOfCharacters * fontWidth) }
        else { visibleWidth },
        minimapWidth         = visibleWidth - codeViewWidth,
        minimapX             = floor(visibleWidth - minimapWidth),
        minimapExclusionPath = OSBezierPath(rect: minimapGutterRect),
        minimapDividerRect   = CGRect(x: minimapX - dividerWidth, y: 0, width: dividerWidth, height: minimumHeight).integral
        
        minimapDividerView?.isHidden = !viewLayout.showMinimap
        minimapView?.isHidden        = !viewLayout.showMinimap
        if let minimapViewFrame = minimapView?.frame,
           viewLayout.showMinimap
        {
            
            if minimapDividerView?.frame != minimapDividerRect { minimapDividerView?.frame = minimapDividerRect }
            if minimapViewFrame.origin.x != minimapX || minimapViewFrame.width != minimapWidth {
                
                minimapView?.frame       = CGRect(x: minimapX,
                                                  y: minimapViewFrame.minY,
                                                  width: minimapWidth,
                                                  height: minimapViewFrame.height)
                minimapGutterView?.frame = minimapGutterRect
#if os(macOS)
                minimapView?.minSize     = CGSize(width: minimapFontWidth, height: visibleRect.height)
#endif
                
            }
        }
        
#if os(iOS) || os(visionOS)
        showsHorizontalScrollIndicator = !viewLayout.wrapText
        if viewLayout.wrapText && frame.size.width != visibleWidth { frame.size.width = visibleWidth }  // don't update frames in vain
#elseif os(macOS)
        enclosingScrollView?.hasHorizontalScroller = !viewLayout.wrapText
        isHorizontallyResizable                    = !viewLayout.wrapText
        if !isHorizontallyResizable && frame.size.width != visibleWidth { frame.size.width = visibleWidth }  // don't update frames in vain
#endif
        
        // Set the text container area of the main text view to reach up to the minimap
        // NB: We use the `excess` width to capture the slack that arises when the window width admits a fractional
        //     number of characters. Adding the slack to the code view's text container size doesn't work as the line breaks
        //     of the minimap and main code view are then sometimes not entirely in sync.
        /// Dave: The condition gutter width above should mean this doesn't impact the codeViewWidth
        let codeContainerWidth = if viewLayout.wrapText { codeViewWidth - gutterWidth } else { CGFloat.greatestFiniteMagnitude }
        if codeContainer.size.width != codeContainerWidth {
            codeContainer.size = CGSize(width: codeContainerWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        
        codeContainer.lineFragmentPadding = lineFragmentPadding
#if os(macOS)
        if textContainerInset.width != gutterWidth {
            textContainerInset = CGSize(width: gutterWidth, height: 0)
        }
#elseif os(iOS) || os(visionOS)
        if textContainerInset.left != gutterWidth {
            textContainerInset = UIEdgeInsets(top: 0, left: gutterWidth, bottom: 0, right: 0)
        }
#endif
        
        // Set the width of the text container for the minimap just like that for the code view as the layout engine works
        // on the original code view metrics. (Only after the layout is done, we scale it down to the size of the minimap.)
        let minimapTextContainerWidth = codeContainerWidth
        let minimapTextContainer = minimapView?.textContainer
        if minimapWidth != minimapView?.frame.width || minimapTextContainerWidth != minimapTextContainer?.size.width {
            
            minimapTextContainer?.exclusionPaths      = [minimapExclusionPath]
            minimapTextContainer?.size                = CGSize(width: minimapTextContainerWidth,
                                                               height: CGFloat.greatestFiniteMagnitude)
            minimapTextContainer?.lineFragmentPadding = 0
            
        }
        
        // Only after tiling can we get the correct frame for the highlight views.
        if let textLocation = optTextContentStorage?.textLocation(for: selectedRange.location) {
            updateCurrentLineHighlight(for: textLocation)
        }
    }
    
    
    // MARK: Scrolling
    
    /// Sets the scrolling position of the minimap in dependence of the scroll position of the main code view.
    ///
    func adjustScrollPositionOfMinimap() {
        guard viewLayout.showMinimap,
              let minimapTextLayoutManager = minimapView?.textLayoutManager
        else { return }
        
        textLayoutManager?.ensureLayout(for: textLayoutManager!.documentRange)
        minimapTextLayoutManager.ensureLayout(for: minimapTextLayoutManager.documentRange)
        
        // NB: We don't use `minimapView?.contentSize.height`, because it is too large if the code doesn't fill the whole
        //     visible portion of the minimap view. Moreover, even for the code view, `contentSize` may not yet have been
        //     adjusted, whereas we know that the layout is complete (as we ensure that above).
        guard let codeHeight
                = optTextLayoutManager?.textLayoutFragmentExtent(for: optTextLayoutManager!.documentRange)?.height,
              let minimapHeight
                = minimapTextLayoutManager.textLayoutFragmentExtent(for: minimapTextLayoutManager.documentRange)?.height
        else { return }
        
        let visibleHeight = documentVisibleRect.size.height
        
#if os(iOS) || os(visionOS)
        // We need to force the scroll view (superclass of `UITextView`) to accomodate the whole content without scrolling
        // and to extent over the whole visible height. (On macOS, the latter is enforced by setting `minSize` in `tile()`.)
        let minimapMinimalHeight = max(minimapHeight, documentVisibleRect.height)
        if let currentHeight = minimapView?.frame.size.height,
           minimapMinimalHeight > currentHeight
        {
            minimapView?.frame.size.height = minimapMinimalHeight
        }
#endif
        
        let scrollFactor: CGFloat = if minimapHeight < visibleHeight || codeHeight <= visibleHeight { 1 }
        else { 1 - (minimapHeight - visibleHeight) / (codeHeight - visibleHeight) }
        
        // We box the positioning of the minimap at the top and the bottom of the code view (with the `max` and `min`
        // expessions. This is necessary as the minimap will otherwise be partially cut off by the enclosing clip view.
        // To get Xcode-like behaviour, where the minimap sticks to the top, it being a floating view is not sufficient.
        let newOriginY = floor(min(max(documentVisibleRect.origin.y * scrollFactor, 0),
                                   codeHeight - minimapHeight))
        if minimapView?.frame.origin.y != newOriginY { minimapView?.frame.origin.y = newOriginY }  // don't update frames in vain
        
        let heightRatio: CGFloat = if codeHeight <= minimapHeight { 1 } else { minimapHeight / codeHeight }
        let minimapVisibleY      = documentVisibleRect.origin.y * heightRatio,
            minimapVisibleHeight = visibleHeight * heightRatio,
            documentVisibleFrame = CGRect(x: 0,
                                          y: minimapVisibleY,
                                          width: minimapView?.bounds.size.width ?? 0,
                                          height: minimapVisibleHeight).integral
        if documentVisibleBox?.frame != documentVisibleFrame { documentVisibleBox?.frame = documentVisibleFrame }  // don't update frames in vain
    }

}


// MARK: Code container

final class CodeContainer: NSTextContainer {
    
#if os(iOS) || os(visionOS)
    weak var textView: UITextView?
#endif
    
    // We adapt line fragment rects in two ways: (1) we leave `gutterWidth` space on the left hand side and (2) on every
    // line that contains a message, we leave `MessageView.minimumInlineWidth` space on the right hand side (but only for
    // the first line fragment of a layout fragment).
    override func lineFragmentRect(forProposedRect proposedRect: CGRect,
                                   at characterIndex: Int,
                                   writingDirection baseWritingDirection: NSWritingDirection,
                                   remaining remainingRect: UnsafeMutablePointer<CGRect>?)
    -> CGRect
    {
        let superRect      = super.lineFragmentRect(forProposedRect: proposedRect,
                                                    at: characterIndex,
                                                    writingDirection: baseWritingDirection,
                                                    remaining: remainingRect),
            calculatedRect = CGRect(x: 0, y: superRect.minY, width: size.width, height: superRect.height)
        
        guard let codeView    = textView as? CodeView,
              let codeStorage = codeView.optCodeStorage,
              let delegate    = codeStorage.delegate as? CodeStorageDelegate,
              let line        = delegate.lineMap.lineOf(index: characterIndex),
              let oneLine     = delegate.lineMap.lookup(line: line),
              characterIndex == oneLine.range.location     // do the following only for the first line fragment of a line
        else { return calculatedRect }
        
        return calculatedRect
    }
}


// MARK: Selection change management

/// Common code view actions triggered on a selection change.
///
func selectionDidChange<TV: TextView>(_ textView: TV) {
    guard let codeStorage  = textView.optCodeStorage,
          let visibleLines = textView.documentVisibleLines
    else { return }

    
    if let location             = textView.insertionPoint,
       let matchingBracketRange = codeStorage.matchingBracket(at: location, in: visibleLines)
    {
        textView.showFindIndicator(for: matchingBracketRange)
    }
}


// MARK: NSRange

/// Combine selection ranges into the smallest ranges encompassing them all.
///
private func combinedRanges(ranges: [NSValue]) -> NSRange {
    let actualranges = ranges.compactMap{ $0 as? NSRange }
    return actualranges.dropFirst().reduce(actualranges.first ?? .zero) {
        NSUnionRange($0, $1)
    }
}
