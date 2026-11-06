#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

// 렌더러는 MdairRender.swift에 있다. 빌드할 때 swiftc가 이 헤더를 만든다.
#import "MdairShared-Swift.h"

// ---------------------------------------------------------------------------
// App Delegate
// ---------------------------------------------------------------------------
@interface MdairAppDelegate : NSObject <NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate>
@property (strong) NSMutableArray<NSWindow *> *windows;
- (IBAction)zoomIn:(id)sender;
- (IBAction)zoomOut:(id)sender;
- (IBAction)actualSize:(id)sender;
- (NSWindow *)openMarkdownString:(NSString *)markdown withTitle:(NSString *)title baseDir:(NSString *)baseDir;
- (NSWindow *)openMarkdownString:(NSString *)markdown withTitle:(NSString *)title baseDir:(NSString *)baseDir isDocument:(BOOL)isDocument;
- (void)presentDocumentWindow:(NSWindow *)window isDocument:(BOOL)isDocument;
- (void)syncTabTitleForWindow:(NSWindow *)window;
- (IBAction)exportAsMdair:(id)sender;
- (IBAction)exportAsPDF:(id)sender;
- (IBAction)printDocument:(id)sender;
+ (NSPrintInfo *)a4PrintInfo;
@end

@implementation MdairAppDelegate

- (instancetype)init {
    self = [super init];
    if (self) _windows = [NSMutableArray array];
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // If no file was opened via double-click, show a welcome window
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.windows.count == 0) {
            [self openMarkdownString:@"# Peekdown\n\nMarkdown QuickLook Previewer.\n\nDrag a `.md` or `.mdair` file onto this app or use **Open With** in Finder."
                           withTitle:@"Peekdown"];
        }
    });
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    [self openMarkdownFile:filename];
    return YES;
}

- (void)application:(NSApplication *)sender openFiles:(NSArray<NSString *> *)filenames {
    for (NSString *file in filenames) {
        [self openMarkdownFile:file];
    }
    [sender replyToOpenOrPrint:NSApplicationDelegateReplySuccess];
}

// Close the welcome/placeholder window (no representedURL, peekdown.welcome
// identifier) when the first real document is about to open, matching the
// macOS convention (Safari/TextEdit) where a start window is replaced by the
// first document rather than left dangling. windowWillClose: prunes it from
// self.windows. Real document windows always have a representedURL so they are
// never affected.
- (void)dismissWelcomeWindowIfPresent {
    NSArray<NSWindow *> *snapshot = [self.windows copy];
    for (NSWindow *w in snapshot) {
        if ([w.tabbingIdentifier isEqualToString:@"peekdown.welcome"] &&
            [w representedURL] == nil) {
            [w close];
        }
    }
}

- (void)openMarkdownFile:(NSString *)path {
    [self dismissWelcomeWindowIfPresent];
    if ([[path pathExtension] caseInsensitiveCompare:@"mdair"] == NSOrderedSame) {
        [self openMdairFile:path];
        return;
    }

    NSError *error = nil;
    NSString *markdown = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (!markdown) {
        markdown = [NSString stringWithContentsOfFile:path
                                            encoding:NSISOLatin1StringEncoding
                                               error:&error];
    }
    if (!markdown) {
        NSLog(@"Failed to read: %@", path);
        return;
    }

    NSString *title = [path lastPathComponent];
    NSString *baseDir = [path stringByDeletingLastPathComponent];
    NSWindow *createdWindow = [self openMarkdownString:markdown withTitle:title baseDir:baseDir];
    [createdWindow setRepresentedURL:[NSURL fileURLWithPath:path]];
    // representedURL is set AFTER presentDocumentWindow: ran (inside
    // openMarkdownString:), so re-sync the tab title from the filename now.
    [self syncTabTitleForWindow:createdWindow];
}

- (void)openMdairFile:(NSString *)path {
    NSString *html = [MdairHTML pageForMdairFile:path];
    if (!html) {
        NSLog(@"Failed to read .mdair file: %@", path);
        return;
    }

    NSString *title = [path lastPathComponent];

    NSRect frame = NSMakeRect(0, 0, 860, 700);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:title];
    [window setDelegate:self];
    // self.windows holds the strong (ARC) reference; NSWindow's default
    // releasedWhenClosed=YES would add a second release on close, over-releasing
    // the window and crashing (SIGSEGV in objc_release) when a tab is closed.
    [window setReleasedWhenClosed:NO];
    [window center];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    [webView setAllowsMagnification:YES];
    [webView setNavigationDelegate:self];
    [webView loadHTMLString:html baseURL:nil];
    [window setContentView:webView];
    [window setRepresentedURL:[NSURL fileURLWithPath:path]];

    [self.windows addObject:window];
    [self presentDocumentWindow:window isDocument:YES];
}

- (void)openMarkdownString:(NSString *)markdown withTitle:(NSString *)title {
    // The 2-arg variant is used only for the welcome/placeholder window, which
    // never has a representedURL. Mark it as a non-document so it is excluded
    // from the document tab group (distinct tabbingIdentifier + disallowed).
    [self openMarkdownString:markdown withTitle:title baseDir:nil isDocument:NO];
}

- (NSWindow *)openMarkdownString:(NSString *)markdown withTitle:(NSString *)title baseDir:(NSString *)baseDir {
    // Default: a real document (joins the tab group).
    return [self openMarkdownString:markdown withTitle:title baseDir:baseDir isDocument:YES];
}

- (NSWindow *)openMarkdownString:(NSString *)markdown withTitle:(NSString *)title baseDir:(NSString *)baseDir isDocument:(BOOL)isDocument {
    NSString *html = [MdairHTML pageForMarkdown:markdown baseDir:baseDir];

    NSRect frame = NSMakeRect(0, 0, 860, 700);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:style
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    [window setTitle:title];
    [window setDelegate:self];
    // self.windows holds the strong (ARC) reference; NSWindow's default
    // releasedWhenClosed=YES would add a second release on close, over-releasing
    // the window and crashing (SIGSEGV in objc_release) when a tab is closed.
    [window setReleasedWhenClosed:NO];
    [window center];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    WKWebView *webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    [webView setAllowsMagnification:YES];
    [webView setNavigationDelegate:self];
    NSURL *baseURL = baseDir ? [NSURL fileURLWithPath:baseDir] : nil;
    [webView loadHTMLString:html baseURL:baseURL];
    [window setContentView:webView];

    [self.windows addObject:window];
    [self presentDocumentWindow:window isDocument:isDocument];
    return window;
}

// Show a document window. Under macOS native tabs, if a same-identifier host
// window is already open, attach as a tab; otherwise present standalone.
// MUST be called after [self.windows addObject:window] so lastObject is valid.
- (void)presentDocumentWindow:(NSWindow *)window isDocument:(BOOL)isDocument {
    static NSString *const kTabbingIdentifier = @"peekdown.document";

    // The welcome/placeholder window (isDocument == NO) has no representedURL
    // and must never co-mingle with real document tabs. Give it a distinct
    // tabbing identifier and disallow tabbing so it stays a standalone window
    // and is never picked as a tab host by a real document below.
    if (!isDocument) {
        window.tabbingIdentifier = @"peekdown.welcome";
        window.tabbingMode = NSWindowTabbingModeDisallowed;
        [window makeKeyAndOrderFront:nil];
        [self syncTabTitleForWindow:window];
        return;
    }

    // Tabbing attributes must be set BEFORE the window is shown.
    window.tabbingIdentifier = kTabbingIdentifier;
    window.tabbingMode = NSWindowTabbingModePreferred;

    // Prefer the current keyWindow as host; otherwise the most-recently
    // added OTHER document window (window itself is already in self.windows).
    // Only a still-visible window with the document tabbing identifier is a
    // valid host — this skips closed/stale windows and the welcome window.
    NSWindow *host = [NSApp keyWindow];
    if (!host || host == window ||
        ![host.tabbingIdentifier isEqualToString:kTabbingIdentifier]) {
        host = nil;
        for (NSWindow *w in [self.windows reverseObjectEnumerator]) {
            if (w != window && w.isVisible &&
                [w.tabbingIdentifier isEqualToString:kTabbingIdentifier]) {
                host = w;
                break;
            }
        }
    }
    if (host && host != window &&
        [host.tabbingIdentifier isEqualToString:kTabbingIdentifier]) {
        [host addTabbedWindow:window ordered:NSWindowAbove];
        [window makeKeyAndOrderFront:nil];
    } else {
        [window makeKeyAndOrderFront:nil];
    }
    [self syncTabTitleForWindow:window];
}

// Synchronize a window's tab title with its document filename. Under macOS
// native tabs each tab IS its own NSWindow, so the tab label is window.title.
// The document filename (representedURL.lastPathComponent) is the single source
// of truth: when a representedURL is present the title is forced to match it,
// so the tab label always reflects the document — regardless of which creation
// path (.md sets representedURL after present; .mdair sets it before) ran.
// Windows without a representedURL (e.g. the welcome window) keep their title.
- (void)syncTabTitleForWindow:(NSWindow *)window {
    if (!window) return;
    NSURL *url = [window representedURL];
    NSString *filename = [[url path] lastPathComponent];
    if (filename.length > 0 && ![window.title isEqualToString:filename]) {
        [window setTitle:filename];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated && url) {
        // 문서 속 링크로 앱이나 스크립트를 실행하지 못하게, 여는 대상을 제한한다
        NSString *scheme = url.scheme.lowercaseString;
        if ([@[@"http", @"https", @"mailto"] containsObject:scheme]) {
            [[NSWorkspace sharedWorkspace] openURL:url];
        } else if ([scheme isEqualToString:@"file"]) {
            NSSet *docExts = [NSSet setWithArray:@[@"md", @"markdown", @"mdown", @"mkd", @"mkdn",
                                                   @"mdwn", @"mdtxt", @"mdtext", @"mdair"]];
            if ([docExts containsObject:url.pathExtension.lowercaseString]) {
                [self openMarkdownFile:url.path];
            } else {
                [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
            }
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

- (WKWebView *)activeWebView {
    NSWindow *window = [NSApp keyWindow];
    if (window && [window.contentView isKindOfClass:[WKWebView class]]) {
        return (WKWebView *)window.contentView;
    }
    return nil;
}

- (IBAction)zoomIn:(id)sender {
    WKWebView *webView = [self activeWebView];
    if (webView) {
        webView.magnification = MIN(webView.magnification * 1.25, 5.0);
    }
}

- (IBAction)zoomOut:(id)sender {
    WKWebView *webView = [self activeWebView];
    if (webView) {
        webView.magnification = MAX(webView.magnification / 1.25, 0.25);
    }
}

- (IBAction)actualSize:(id)sender {
    WKWebView *webView = [self activeWebView];
    if (webView) {
        webView.magnification = 1.0;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

// Prune closed windows from self.windows so the array never retains dead
// windows. Without this, the host-pick fallback in presentDocumentWindow:
// could attach a new tab to a closed window, and the welcome-count check in
// applicationDidFinishLaunching: would count phantom windows.
- (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    if (window) {
        [self.windows removeObject:window];
    }
}

- (IBAction)exportAsMdair:(id)sender {
    NSWindow *window = [NSApp keyWindow];
    NSURL *src = [window representedURL];
    if (!src) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"내보낼 문서가 없습니다";
        alert.informativeText = @"먼저 .md 파일을 열어주세요.";
        [alert runModal];
        return;
    }
    NSString *srcPath = [src path];
    NSString *ext = [[srcPath pathExtension] lowercaseString];
    if ([ext isEqualToString:@"mdair"]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"이미 .mdair 파일입니다";
        [alert runModal];
        return;
    }
    NSString *toolPath = [[NSBundle mainBundle] pathForAuxiliaryExecutable:@"peekdown-convert"];
    if (!toolPath || ![[NSFileManager defaultManager] fileExistsAtPath:toolPath]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"peekdown-convert 도구를 찾을 수 없습니다";
        [alert runModal];
        return;
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    NSString *defaultName = [[[srcPath lastPathComponent] stringByDeletingPathExtension]
                             stringByAppendingPathExtension:@"mdair"];
    [panel setNameFieldStringValue:defaultName];
    [panel setAllowedFileTypes:@[@"mdair"]];
    if ([panel runModal] != NSModalResponseOK) return;
    NSString *dstPath = [[panel URL] path];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:toolPath];
    [task setArguments:@[srcPath, @"-o", dstPath]];
    NSPipe *errPipe = [NSPipe pipe];
    [task setStandardError:errPipe];
    [task setStandardOutput:[NSPipe pipe]];

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"내보내기 실패";
        alert.informativeText = exception.reason ?: @"unknown";
        [alert runModal];
        return;
    }

    if ([task terminationStatus] == 0) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:dstPath]]];
    } else {
        NSData *errData = [[errPipe fileHandleForReading] readDataToEndOfFile];
        NSString *errMsg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"내보내기 실패";
        alert.informativeText = errMsg.length ? errMsg : @"unknown";
        [alert runModal];
    }
}

+ (NSPrintInfo *)a4PrintInfo {
    NSPrintInfo *info = [[NSPrintInfo alloc] init];
    // A4 = 210 × 297 mm = 595.276 × 841.890 pt at 72dpi
    [info setPaperSize:NSMakeSize(595.276, 841.890)];
    [info setPaperName:@"iso-a4"];
    [info setOrientation:NSPaperOrientationPortrait];
    // CSS @page handles the printable margins (18mm/16mm) — keep NSPrintInfo at 0
    // so they don't stack on top of the CSS margins.
    [info setLeftMargin:0.0];
    [info setRightMargin:0.0];
    [info setTopMargin:0.0];
    [info setBottomMargin:0.0];
    [info setHorizontalPagination:NSPrintingPaginationModeFit];
    [info setVerticalPagination:NSPrintingPaginationModeAutomatic];
    [info setHorizontallyCentered:NO];
    [info setVerticallyCentered:NO];
    return info;
}

- (IBAction)exportAsPDF:(id)sender {
    WKWebView *webView = [self activeWebView];
    if (!webView) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"내보낼 문서가 없습니다";
        [alert runModal];
        return;
    }

    NSWindow *window = [NSApp keyWindow];
    NSURL *src = [window representedURL];
    NSString *defaultName = @"document.pdf";
    if (src) {
        defaultName = [[[[src path] lastPathComponent] stringByDeletingPathExtension]
                       stringByAppendingPathExtension:@"pdf"];
    }

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setNameFieldStringValue:defaultName];
    [panel setAllowedFileTypes:@[@"pdf"]];
    if ([panel runModal] != NSModalResponseOK) return;
    NSURL *dstURL = [panel URL];

    NSPrintInfo *base = [MdairAppDelegate a4PrintInfo];
    NSMutableDictionary *dict = [[base dictionary] mutableCopy];
    dict[NSPrintJobDisposition] = NSPrintSaveJob;
    dict[NSPrintJobSavingURL] = dstURL;
    NSPrintInfo *info = [[NSPrintInfo alloc] initWithDictionary:dict];
    [info setPaperSize:[base paperSize]];
    [info setOrientation:[base orientation]];
    [info setLeftMargin:[base leftMargin]];
    [info setRightMargin:[base rightMargin]];
    [info setTopMargin:[base topMargin]];
    [info setBottomMargin:[base bottomMargin]];
    [info setHorizontalPagination:[base horizontalPagination]];
    [info setVerticalPagination:[base verticalPagination]];
    [info setHorizontallyCentered:NO];
    [info setVerticallyCentered:NO];

    NSPrintOperation *op = [webView printOperationWithPrintInfo:info];
    if (!op) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"PDF 생성 실패";
        alert.informativeText = @"인쇄 작업을 생성할 수 없습니다.";
        [alert runModal];
        return;
    }
    op.showsPrintPanel = NO;
    op.showsProgressPanel = YES;
    op.jobTitle = [defaultName stringByDeletingPathExtension];

    [op runOperationModalForWindow:window
                          delegate:self
                    didRunSelector:@selector(pdfExportDidEnd:success:contextInfo:)
                       contextInfo:(__bridge_retained void *)dstURL];
}

- (void)pdfExportDidEnd:(NSPrintOperation *)op success:(BOOL)success contextInfo:(void *)contextInfo {
    NSURL *dstURL = (__bridge_transfer NSURL *)contextInfo;
    if (success && dstURL) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[dstURL]];
    } else if (!success) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"PDF 저장 실패";
        alert.informativeText = @"인쇄 작업이 실패했습니다.";
        [alert runModal];
    }
}

- (IBAction)printDocument:(id)sender {
    WKWebView *webView = [self activeWebView];
    if (!webView) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"인쇄할 문서가 없습니다";
        [alert runModal];
        return;
    }

    NSWindow *window = [NSApp keyWindow];
    NSPrintInfo *info = [MdairAppDelegate a4PrintInfo];

    NSPrintOperation *op = [webView printOperationWithPrintInfo:info];
    if (!op) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"인쇄 실패";
        alert.informativeText = @"인쇄 작업을 생성할 수 없습니다.";
        [alert runModal];
        return;
    }
    op.showsPrintPanel = YES;
    op.showsProgressPanel = YES;

    NSURL *src = [window representedURL];
    if (src) {
        op.jobTitle = [[src path] lastPathComponent];
    }

    [op runOperationModalForWindow:window
                          delegate:nil
                    didRunSelector:NULL
                       contextInfo:NULL];
}

@end

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];

        // Create menu bar
        NSMenu *menuBar = [[NSMenu alloc] init];
        NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:appMenuItem];
        NSMenu *appMenu = [[NSMenu alloc] init];
        [appMenu addItemWithTitle:@"About Peekdown" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
        [appMenu addItem:[NSMenuItem separatorItem]];
        [appMenu addItemWithTitle:@"Quit Peekdown" action:@selector(terminate:) keyEquivalent:@"q"];
        [appMenuItem setSubmenu:appMenu];

        NSMenuItem *fileMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:fileMenuItem];
        NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
        [fileMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItemWithTitle:@"Export as .mdair…" action:@selector(exportAsMdair:) keyEquivalent:@""];
        [fileMenu addItemWithTitle:@"Export as PDF…" action:@selector(exportAsPDF:) keyEquivalent:@""];
        [fileMenu addItem:[NSMenuItem separatorItem]];
        [fileMenu addItemWithTitle:@"Print…" action:@selector(printDocument:) keyEquivalent:@"p"];
        [fileMenuItem setSubmenu:fileMenu];

        NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:editMenuItem];
        NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
        [editMenu addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
        NSMenuItem *redoItem = [editMenu addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"z"];
        [redoItem setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
        [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
        [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
        [editMenu addItem:[NSMenuItem separatorItem]];
        [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
        [editMenuItem setSubmenu:editMenu];

        NSMenuItem *viewMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:viewMenuItem];
        NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
        [viewMenu addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"+"];
        [viewMenu addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
        [viewMenu addItemWithTitle:@"Actual Size" action:@selector(actualSize:) keyEquivalent:@"0"];
        [viewMenuItem setSubmenu:viewMenu];

        // Window menu — enables native tab management. AppKit auto-injects
        // "Show/Hide Tab Bar" and standard tab affordances via setWindowsMenu:.
        NSMenuItem *windowMenuItem = [[NSMenuItem alloc] init];
        [menuBar addItem:windowMenuItem];
        NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
        // Standard window controls (⌘M Minimize, Zoom). performMiniaturize:/
        // performZoom: are AppKit-provided NSWindow actions routed via the
        // responder chain to the active tab's window (keyWindow).
        [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
        [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *prevTab = [windowMenu addItemWithTitle:@"Show Previous Tab" action:@selector(selectPreviousTab:) keyEquivalent:@"["];
        [prevTab setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        NSMenuItem *nextTab = [windowMenu addItemWithTitle:@"Show Next Tab" action:@selector(selectNextTab:) keyEquivalent:@"]"];
        [nextTab setKeyEquivalentModifierMask:(NSEventModifierFlagCommand | NSEventModifierFlagShift)];
        [windowMenu addItemWithTitle:@"Show All Tabs" action:@selector(toggleTabOverview:) keyEquivalent:@""];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        [windowMenu addItemWithTitle:@"Move Tab to New Window" action:@selector(moveTabToNewWindow:) keyEquivalent:@""];
        [windowMenu addItemWithTitle:@"Merge All Windows" action:@selector(mergeAllWindows:) keyEquivalent:@""];
        [windowMenu addItem:[NSMenuItem separatorItem]];
        [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
        [windowMenuItem setSubmenu:windowMenu];
        [app setWindowsMenu:windowMenu];

        [app setMainMenu:menuBar];

        MdairAppDelegate *delegate = [[MdairAppDelegate alloc] init];
        [app setDelegate:delegate];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
