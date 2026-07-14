// Desk Notes — sticky notes that live directly on your screen.
// Invisible full-screen overlay window: only the notes are visible & clickable;
// everywhere else, clicks pass straight through to your apps.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#import "whisper.h"

static NSString *JSStr(NSString *s) { // safely embed a string in evaluated JS
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[s ?: @""] options:0 error:nil];
    NSString *a = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [a substringWithRange:NSMakeRange(1, a.length - 2)];
}

@interface OverlayWindow : NSWindow
@end
@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow { return YES; }   // borderless windows refuse focus by default
- (BOOL)canBecomeMainWindow { return YES; }
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { return frameRect; } // cover the FULL screen, menu-bar zone included

// Route ⌘-shortcuts straight to the focused note (menu routing is unreliable in borderless windows)
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    SEL sel = NULL;
    if (mods == NSEventModifierFlagCommand) {
        if ([key isEqualToString:@"c"]) sel = @selector(copy:);
        else if ([key isEqualToString:@"v"]) sel = @selector(paste:);
        else if ([key isEqualToString:@"x"]) sel = @selector(cut:);
        else if ([key isEqualToString:@"a"]) sel = @selector(selectAll:);
        else if ([key isEqualToString:@"z"]) sel = NSSelectorFromString(@"undo:");
    } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift)) {
        if ([key isEqualToString:@"z"]) sel = NSSelectorFromString(@"redo:");
    }
    if (sel && [NSApp sendAction:sel to:nil from:self]) return YES;
    return [super performKeyEquivalent:event];
}
@end

// one desktop overlay per display: its own window, webview, and note store
// (a window cannot span displays when "Displays have separate Spaces" is on)
@interface ScreenOverlay : NSObject
@property (strong) OverlayWindow *window;
@property (strong) WKWebView *webView;
@property (strong) NSArray<NSValue *> *hitRects; // note rects in view coords
@property (copy) NSString *suffix;               // storage-key suffix; '' = primary display
@end
@implementation ScreenOverlay
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSMenuDelegate, UNUserNotificationCenterDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMutableArray<ScreenOverlay *> *overlays; // one per connected display
@property (strong) ScreenOverlay *editorOverlay;  // overlay whose note is open in the editor window
@property (weak) WKWebView *dictWebView;          // webview that started dictation
@property (assign) BOOL hiddenAll;
@property (assign) BOOL floatOnTop;
@property (assign) BOOL tempFloat; // new note floats above apps until the user clicks away
@property (strong) NSWindow *editorWindow; // real app window for the expanded editor (Stage Manager stages it)
@property (strong) NSWindow *panelWindow;  // separate Settings/History window (desktop notes stay visible)
@property (strong) WKWebView *panelWebView;
// local Whisper dictation
@property (strong) AVAudioEngine *engine;
@property (strong) AVAudioConverter *conv;
@property (strong) AVAudioFormat *outFmt;
@property (strong) NSMutableData *pcm;
@property (assign) BOOL recording;
@property (assign) BOOL dictBusy;
@property (assign) struct whisper_context *wctx;
@property (strong) dispatch_queue_t dictQ;
@property (strong) NSTimer *liveTimer;
@property (assign) BOOL colorPanelPlaced;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; // menu bar only, no Dock

    // hidden main menu so standard Mac shortcuts (⌘A ⌘C ⌘V ⌘X ⌘Z) route to the notes
    NSMenu *mainMenu = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Desk Notes" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem:appItem];
    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Undo" action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [editMenu addItemWithTitle:@"Redo" action:NSSelectorFromString(@"redo:") keyEquivalent:@"Z"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem:editItem];
    NSApp.mainMenu = mainMenu;

    // status bar item — click opens the dropdown
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSImage *sicon = [NSImage imageWithSystemSymbolName:@"square.and.pencil" accessibilityDescription:@"Desk Notes"];
    if (sicon) { sicon.template = YES; self.statusItem.button.image = sicon; }
    else { self.statusItem.button.title = @"✎"; }
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    self.statusItem.menu = menu;

    [UNUserNotificationCenter currentNotificationCenter].delegate = self;
    self.dictQ = dispatch_queue_create("desknotes.whisper", DISPATCH_QUEUE_SERIAL);
    self.pcm = [NSMutableData data];
    self.floatOnTop = NO;

    // one transparent overlay per display, each with its own note store
    self.overlays = [NSMutableArray array];
    [self rebuildOverlays];

    // monitors plugged/unplugged -> add/remove per-display overlays
    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidChangeScreenParametersNotification
        object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [self rebuildOverlays];
    }];

    __weak typeof(self) weakSelf = self;

    // the shared macOS color panel opens wherever it likes — pin it next to the cursor instead
    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
        if (![NSColorPanel sharedColorPanelExists]) return;
        NSColorPanel *cp = [NSColorPanel sharedColorPanel];
        if (cp.isVisible && !weakSelf.colorPanelPlaced) {
            NSPoint m = [NSEvent mouseLocation];
            NSRect scr = [NSScreen mainScreen].visibleFrame;
            CGFloat x = m.x + 18, y = m.y + 12;
            if (x + 260 > NSMaxX(scr)) x = m.x - 278;
            if (y - 340 < NSMinY(scr)) y = NSMinY(scr) + 352;
            if (y > NSMaxY(scr)) y = NSMaxY(scr) - 8;
            [cp setFrameTopLeftPoint:NSMakePoint(x, y)];
            weakSelf.colorPanelPlaced = YES;
        } else if (!cp.isVisible) {
            weakSelf.colorPanelPlaced = NO;
        }
    }];

    // track the cursor: over a note -> catch clicks; elsewhere -> pass through
    NSEventMask moveMask = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged;
    [NSEvent addGlobalMonitorForEventsMatchingMask:moveMask handler:^(NSEvent *e) {
        [weakSelf updateMousePassthrough];
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:(moveMask | NSEventMaskLeftMouseDown)
                                          handler:^NSEvent *(NSEvent *e) {
        [weakSelf updateMousePassthrough];
        if (e.type == NSEventTypeLeftMouseDown) {
            ScreenOverlay *ov = [weakSelf overlayUnderMouse];
            if (ov && !ov.window.ignoresMouseEvents) {
                [NSApp activateIgnoringOtherApps:YES];
                [ov.window makeKeyWindow];
            }
            [weakSelf closePopsAwayFromNotes];
        }
        return e;
    }];
    // clicks that land outside the notes go to whatever is underneath (wallpaper, another app), so the
    // page never sees them — watch globally and tell it to drop any open dropdown
    [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *e) {
        // clicking the bare desktop while the editor is up means "put this away" — minimize on the
        // mouse-DOWN, before macOS (Stage Manager) starts sliding the window off to its side strip.
        // A click on another app's window is a real app switch, so it's left to macOS.
        if (weakSelf.editorOverlay) {
            if ([weakSelf clickAtMouseIsBareDesktop]) [weakSelf minimizeEditor];
            return;
        }
        [weakSelf updateMousePassthrough];
        [weakSelf closePopsAwayFromNotes];
    }];
}

// Is the pointer over empty desktop — wallpaper, no app window? Walks the on-screen window list
// (front to back, wallpaper excluded) and asks whether any ordinary window covers the point.
- (BOOL)clickAtMouseIsBareDesktop {
    NSScreen *first = NSScreen.screens.firstObject;
    if (!first) return NO;
    NSPoint m = [NSEvent mouseLocation];
    CGPoint p = CGPointMake(m.x, NSMaxY(first.frame) - m.y); // CG measures down from the top
    CFArrayRef list = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
    if (!list) return NO;
    BOOL bare = YES;
    pid_t me = getpid();
    for (NSDictionary *w in (__bridge NSArray *)list) {
        if ([w[(id)kCGWindowLayer] integerValue] != 0) continue;      // menu bar, dock, panels — not app windows
        if ([w[(id)kCGWindowOwnerPID] intValue] == me) continue;      // our own windows don't count
        CGRect r;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
        if (CGRectContainsPoint(r, p)) { bare = NO; break; }
    }
    CFRelease(list);
    return bare;
}

// put the expanded editor away: un-expand in the page first (so it measures itself while still in the
// editor window), then hand the page back to the desktop overlay
- (void)minimizeEditor {
    ScreenOverlay *ov = self.editorOverlay;
    if (!ov) return;
    __weak typeof(self) weakSelf = self;
    [ov.webView evaluateJavaScript:@"window.__closeExpand&&window.__closeExpand();"
                 completionHandler:^(id r, NSError *e) { [weakSelf closeEditorWindow]; }];
}

// close dropdowns on every display except the one whose note actually caught the click
- (void)closePopsAwayFromNotes {
    if (self.editorOverlay) return; // the editor window is a normal window; the page sees its own clicks
    ScreenOverlay *hot = [self overlayUnderMouse];
    if (hot && hot.window.ignoresMouseEvents) hot = nil; // click fell through: not on a note
    for (ScreenOverlay *o in self.overlays) {
        if (o == hot) continue;
        [o.webView evaluateJavaScript:@"window.__closePops&&window.__closePops();" completionHandler:nil];
    }
}

/* ---------- per-display overlays ---------- */

- (ScreenOverlay *)overlayForWebView:(WKWebView *)wv {
    for (ScreenOverlay *o in self.overlays) if (o.webView == wv) return o;
    return nil;
}

- (ScreenOverlay *)overlayUnderMouse {
    NSPoint m = [NSEvent mouseLocation];
    for (ScreenOverlay *o in self.overlays) if (NSMouseInRect(m, o.window.frame, NO)) return o;
    return nil;
}

// stable per-display key so each monitor keeps its own notes across reconnects
- (NSString *)displayKeyForScreen:(NSScreen *)s {
    NSNumber *num = s.deviceDescription[@"NSScreenNumber"];
    CFUUIDRef u = num ? CGDisplayCreateUUIDFromDisplayID(num.unsignedIntValue) : NULL;
    if (!u) return [NSString stringWithFormat:@"id%@", num];
    NSString *str = CFBridgingRelease(CFUUIDCreateString(NULL, u));
    CFRelease(u);
    return str;
}

- (void)rebuildOverlays {
    NSMutableArray<ScreenOverlay *> *keep = [NSMutableArray array];
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSScreen *s = screens[i];
        // the primary display keeps the original store key, so pre-existing notes stay put
        NSString *suffix = (i == 0) ? @"" : [self displayKeyForScreen:s];
        ScreenOverlay *ov = nil;
        for (ScreenOverlay *o in self.overlays)
            if ([o.suffix isEqualToString:suffix] && ![keep containsObject:o]) { ov = o; break; }
        if (ov) {
            [ov.window setFrame:s.frame display:YES];
            [self pushTopInsetFor:ov];
            [ov.webView evaluateJavaScript:@"window.__clampAll&&window.__clampAll();" completionHandler:nil];
        } else {
            ov = [self makeOverlayForScreen:s suffix:suffix];
        }
        [keep addObject:ov];
    }
    for (ScreenOverlay *o in self.overlays) {
        if (![keep containsObject:o]) { // display unplugged: its notes wait in storage for its return
            if (self.editorOverlay == o) [self closeEditorWindow];
            [o.window orderOut:nil];
        }
    }
    [self.overlays setArray:keep];
}

- (ScreenOverlay *)makeOverlayForScreen:(NSScreen *)s suffix:(NSString *)suffix {
    ScreenOverlay *ov = [ScreenOverlay new];
    ov.suffix = suffix;

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    [config.userContentController addScriptMessageHandler:self name:@"hit"];
    [config.userContentController addScriptMessageHandler:self name:@"dict"];
    [config.userContentController addScriptMessageHandler:self name:@"notify"];
    [config.userContentController addScriptMessageHandler:self name:@"backup"];
    // which note store this display reads/writes — must exist before the page script runs
    [config.userContentController addUserScript:
        [[WKUserScript alloc] initWithSource:[NSString stringWithFormat:@"window.__screenKey=%@;", JSStr(suffix)]
                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                            forMainFrameOnly:YES]];

    ov.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    ov.webView.UIDelegate = self;
    ov.webView.navigationDelegate = self;
    [ov.webView setValue:@NO forKey:@"drawsBackground"]; // transparent page
    if (@available(macOS 13.3, *)) { ov.webView.inspectable = YES; }
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
    if (url) [ov.webView loadFileURL:url allowingReadAccessToURL:[url URLByDeletingLastPathComponent]];

    ov.window = [[OverlayWindow alloc] initWithContentRect:s.frame
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    ov.window.opaque = NO;
    ov.window.backgroundColor = [NSColor clearColor];
    ov.window.hasShadow = NO;
    ov.window.level = self.floatOnTop ? NSFloatingWindowLevel
                                      : CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1; // ON the desktop, under app windows
    // visible on every Space of its display (a Space switch must never strand the notes),
    // and allowed to appear over full-screen apps while temporarily floating
    ov.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                   NSWindowCollectionBehaviorFullScreenAuxiliary |
                                   NSWindowCollectionBehaviorStationary |
                                   NSWindowCollectionBehaviorIgnoresCycle;
    ov.window.ignoresMouseEvents = YES; // click-through until the cursor is over a note
    ov.window.releasedWhenClosed = NO;
    ov.window.contentView = ov.webView;
    [ov.window setFrame:s.frame display:YES];
    if (!self.hiddenAll) [ov.window orderFrontRegardless];
    return ov;
}

// user switched to another app / clicked the desktop: end any in-note editing so controls hide
- (void)applicationDidResignActive:(NSNotification *)notification {
    if (self.tempFloat) { // a freshly created note settles back onto the desktop
        self.tempFloat = NO;
        if (!self.floatOnTop)
            for (ScreenOverlay *o in self.overlays)
                o.window.level = CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1;
    }
    for (ScreenOverlay *o in self.overlays)
        [o.webView evaluateJavaScript:
            @"try{if(document.activeElement&&document.activeElement.blur)document.activeElement.blur();"
            @"var s=window.getSelection&&window.getSelection();if(s&&s.removeAllRanges)s.removeAllRanges();}catch(e){}"
            @"window.__closePops&&window.__closePops();"
            @"(function(){var b=document.body;b.style.pointerEvents='none';setTimeout(function(){b.style.pointerEvents='';},30);})();"
                        completionHandler:nil];
}

- (void)updateMousePassthrough {
    if (self.hiddenAll || self.editorOverlay) return; // editor lives in a normal window; no passthrough games
    NSPoint p = [NSEvent mouseLocation];
    for (ScreenOverlay *ov in self.overlays) {
        NSRect f = ov.window.frame;
        BOOL inside = NO;
        if (NSMouseInRect(p, f, NO)) {
            CGFloat vx = p.x - f.origin.x;
            CGFloat vy = f.size.height - (p.y - f.origin.y); // flip to top-left origin (web coords)
            for (NSValue *v in ov.hitRects) {
                NSRect r = v.rectValue;
                if (vx >= r.origin.x - 8 && vx <= r.origin.x + r.size.width + 8 &&
                    vy >= r.origin.y - 8 && vy <= r.origin.y + r.size.height + 8) { inside = YES; break; }
            }
        }
        BOOL ignore = !inside;
        if (ov.window.ignoresMouseEvents != ignore) {
            ov.window.ignoresMouseEvents = ignore;
            if (ignore) {
                // cursor left the notes: WebKit will never get a mouseleave, so force-clear hover states
                [ov.webView evaluateJavaScript:
                    @"document.querySelectorAll('.note.hov').forEach(function(n){n.classList.remove('hov');});"
                    @"(function(){var b=document.body;b.style.pointerEvents='none';"
                    @"setTimeout(function(){b.style.pointerEvents='';},30);})()"
                                  completionHandler:nil];
            }
        }
    }
}

// JS reports the rectangles of notes / toolbars / overlays
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"dict"]) {
        NSDictionary *b = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
        NSString *cmd = b[@"cmd"];
        if ([cmd isEqualToString:@"start"]) { self.dictWebView = message.webView; [self startDictation]; }
        else if ([cmd isEqualToString:@"stop"]) [self stopDictationAndFinalize];
        return;
    }
    if ([message.name isEqualToString:@"panel"]) {
        NSDictionary *b = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
        NSString *cmd = b[@"cmd"];
        if ([cmd isEqualToString:@"close"]) { [self.panelWindow orderOut:nil]; }
        else if ([cmd isEqualToString:@"changed"]) { // settings edited storage -> desktop views refresh
            for (ScreenOverlay *o in self.overlays)
                [o.webView evaluateJavaScript:@"window.__reloadNotes&&window.__reloadNotes();" completionHandler:nil];
        } else if ([cmd isEqualToString:@"openNote"]) {
            [self.panelWindow orderOut:nil];
            NSString *nid = [b[@"id"] isKindOfClass:[NSString class]] ? b[@"id"] : @"";
            [self.overlays.firstObject.webView evaluateJavaScript: // panel shares the primary display's store
                [NSString stringWithFormat:@"window.__expandNoteById&&window.__expandNoteById(%@);", JSStr(nid)]
                               completionHandler:nil];
        }
        return;
    }
    if ([message.name isEqualToString:@"notify"]) {
        NSDictionary *b = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
        [self deliverNotification:(b[@"title"] ?: @"Reminder") body:(b[@"body"] ?: @"")];
        return;
    }
    if ([message.name isEqualToString:@"backup"]) {
        if ([message.body isKindOfClass:[NSString class]]) {
            ScreenOverlay *src = [self overlayForWebView:message.webView];
            [self writeBackup:message.body suffix:(src.suffix ?: @"")];
        }
        return;
    }
    if (![message.name isEqualToString:@"hit"]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    ScreenOverlay *ov = [self overlayForWebView:message.webView];
    if (!ov) return;
    NSArray *arr = body[@"r"];
    BOOL expanded = [body[@"x"] boolValue];
    if ([arr isKindOfClass:[NSArray class]]) {
        NSMutableArray *rects = [NSMutableArray arrayWithCapacity:arr.count];
        for (NSArray *r in arr) {
            if ([r isKindOfClass:[NSArray class]] && r.count == 4) {
                [rects addObject:[NSValue valueWithRect:NSMakeRect([r[0] doubleValue], [r[1] doubleValue],
                                                                   [r[2] doubleValue], [r[3] doubleValue])]];
            }
        }
        ov.hitRects = rects;
    }
    // editor opens as a REAL app window so macOS (incl. Stage Manager) treats it like launching an app
    if (expanded && !self.editorOverlay) [self openEditorWindowFor:ov];
    else if (!expanded && self.editorOverlay == ov) [self closeEditorWindow];
}

- (void)openEditorWindowFor:(ScreenOverlay *)ov {
    self.editorOverlay = ov;
    // open at a standard, centered size on the note's display — the user can then drag/resize freely
    NSScreen *host = ov.window.screen ?: [NSScreen mainScreen];
    NSRect vis = host.visibleFrame;
    CGFloat w = MIN(980, vis.size.width * 0.78), h = MIN(880, vis.size.height * 0.88);
    NSRect scr = NSMakeRect(vis.origin.x + (vis.size.width - w) / 2,
                            vis.origin.y + (vis.size.height - h) / 2, w, h);
    if (!self.editorWindow) {
        // a real (thin, empty) titlebar gives a clean top and a proper drag strip above the toolbar
        self.editorWindow = [[NSWindow alloc]
            initWithContentRect:scr
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered defer:NO];
        self.editorWindow.title = @"Desk Notes";
        self.editorWindow.titleVisibility = NSWindowTitleHidden;   // no title text — just a clean drag strip
        self.editorWindow.movableByWindowBackground = YES;
        // keep the red close button so there's an obvious way out; hide the rest for a clean look
        [self.editorWindow standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
        [self.editorWindow standardWindowButton:NSWindowZoomButton].hidden = YES;
        self.editorWindow.releasedWhenClosed = NO;
        self.editorWindow.minSize = NSMakeSize(560, 420);
        self.editorWindow.delegate = self;
    }
    // always open at the standard centered size (the user drags/resizes from there)
    [self.editorWindow setFrame:scr display:YES];
    [ov.webView evaluateJavaScript:@"document.documentElement.classList.add('winmode');" completionHandler:nil];
    self.editorWindow.contentView = ov.webView;        // move the page into the app window
    [ov.window orderOut:nil];                          // that display's desktop layer rests while editing
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; // macOS: "an app just opened"
    [self.editorWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)closeEditorWindow {
    ScreenOverlay *ov = self.editorOverlay;
    if (!ov) return;
    [ov.webView evaluateJavaScript:@"document.documentElement.classList.remove('winmode');" completionHandler:nil];
    ov.window.contentView = ov.webView;                // page returns to its desktop overlay
    [self.editorWindow orderOut:nil];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; // back to menu-bar-only
    self.tempFloat = NO;
    for (ScreenOverlay *o in self.overlays) {
        o.window.level = self.floatOnTop ? NSFloatingWindowLevel
                                         : CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1;
        if (!self.hiddenAll) [o.window orderFrontRegardless];
    }
    self.editorOverlay = nil;
    // now that the page measures the desktop again, let it fit any oversized note
    [ov.webView evaluateJavaScript:@"window.__fitAfterRestore&&window.__fitAfterRestore();" completionHandler:nil];
}

// red close button on the editor window = minimize back to the desktop note
- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.editorWindow) {
        [self.editorOverlay.webView evaluateJavaScript:@"window.__closeExpand&&window.__closeExpand();" completionHandler:nil];
        return NO;
    }
    if (sender == self.panelWindow) { [self.panelWindow orderOut:nil]; return NO; }
    return YES;
}

// inject native mode + rect reporting once the page loads
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView == self.panelWebView) { // settings window shows just the History panel
        [webView evaluateJavaScript:
            @"document.documentElement.classList.add('panelmode');"
            @"window.__openHistory&&window.__openHistory(true);" completionHandler:nil];
        return;
    }
    NSString *js =
    @"document.documentElement.classList.add('native');"
    @"if(!window.__hitTimer){window.__hitTimer=setInterval(function(){"
    @"  var rs=[];"
    @"  document.querySelectorAll('.note').forEach(function(n){var r=n.getBoundingClientRect();rs.push([r.left,r.top,r.width,r.height]);});"
    @"  document.querySelectorAll('.note.menu-open .mp, .note.type-open .tp').forEach(function(n){var r=n.getBoundingClientRect();rs.push([r.left,r.top,r.width,r.height]);});"
    @"  var sb=document.getElementById('selbar');"
    @"  if(sb&&sb.style.display==='flex'){var r=sb.getBoundingClientRect();rs.push([r.left,r.top,r.width,r.height]);}"
    @"  var ov=document.getElementById('overlay');"
    @"  var t=document.getElementById('__toast');"
    @"  if(t&&t.style.opacity==='1'){var r=t.getBoundingClientRect();rs.push([r.left,r.top,r.width,r.height]);}"
    @"  var ho=document.getElementById('histover');"
    @"  var xo=!!((ov&&ov.classList.contains('open'))||(ho&&ho.classList.contains('open')));"
    @"  try{window.webkit.messageHandlers.hit.postMessage({r:rs,x:xo});}catch(e){}"
    @"},120);}";
    [webView evaluateJavaScript:js completionHandler:nil];
    ScreenOverlay *ov = [self overlayForWebView:webView];
    if (ov) {
        [self pushTopInsetFor:ov];
        // notes saved under an older frame may sit outside this display — pull them back
        [webView evaluateJavaScript:@"window.__clampAll&&window.__clampAll();" completionHandler:nil];
    }
}

// dropdown contents (rebuilt each time it opens)
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSMenuItem *add = [menu addItemWithTitle:@"New Note" action:@selector(newNote) keyEquivalent:@"n"];
    add.target = self;
    NSMenuItem *settings = [menu addItemWithTitle:@"Settings…" action:@selector(openSettingsPanel) keyEquivalent:@","];
    settings.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *toggle = [menu addItemWithTitle:(self.hiddenAll ? @"Show Notes" : @"Hide Notes")
                                         action:@selector(toggleAll) keyEquivalent:@""];
    toggle.target = self;
    NSMenuItem *pin = [menu addItemWithTitle:@"Float Above Apps" action:@selector(togglePin) keyEquivalent:@""];
    pin.state = self.floatOnTop ? NSControlStateValueOn : NSControlStateValueOff;
    pin.target = self;
    NSMenuItem *tut = [menu addItemWithTitle:@"Show Tutorial Notes" action:@selector(showTutorial) keyEquivalent:@""];
    tut.target = self;
    if (@available(macOS 13.0, *)) {
        NSMenuItem *login = [menu addItemWithTitle:@"Launch at Login" action:@selector(toggleLaunchAtLogin) keyEquivalent:@""];
        login.state = (SMAppService.mainAppService.status == SMAppServiceStatusEnabled)
                        ? NSControlStateValueOn : NSControlStateValueOff;
        login.target = self;
    }
    NSMenuItem *bk = [menu addItemWithTitle:@"Open Backup Folder" action:@selector(openBackupFolder) keyEquivalent:@""];
    bk.target = self;
    NSMenuItem *upd = [menu addItemWithTitle:@"Check for Updates…" action:@selector(checkForUpdates) keyEquivalent:@""];
    upd.target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Desk Notes" action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
}

- (void)toggleLaunchAtLogin {
    if (@available(macOS 13.0, *)) {
        NSError *err = nil;
        SMAppService *svc = SMAppService.mainAppService;
        if (svc.status == SMAppServiceStatusEnabled) [svc unregisterAndReturnError:&err];
        else [svc registerAndReturnError:&err];
        if (err) NSLog(@"launch-at-login toggle failed: %@", err);
    }
}

- (void)showTutorial {
    if (self.hiddenAll) [self toggleAll];
    ScreenOverlay *ov = [self overlayUnderMouse] ?: self.overlays.firstObject; // screen whose menu bar was clicked
    [ov.webView evaluateJavaScript:@"window.__addTutorial&&window.__addTutorial();" completionHandler:nil];
}

- (void)newNote {
    if (self.hiddenAll) [self toggleAll];
    ScreenOverlay *ov = [self overlayUnderMouse] ?: self.overlays.firstObject; // screen whose menu bar was clicked
    if (!ov) return;
    if (!self.floatOnTop) { // surface the new note even over full-screen apps; sinks on click-away
        self.tempFloat = YES;
        ov.window.level = NSFloatingWindowLevel;
    }
    [ov.window orderFrontRegardless];
    [NSApp activateIgnoringOtherApps:YES];
    [ov.window makeKeyWindow];
    [ov.webView evaluateJavaScript:@"window.__addNote && window.__addNote();" completionHandler:nil];
}

- (void)togglePin {
    self.floatOnTop = !self.floatOnTop;
    self.tempFloat = NO;
    for (ScreenOverlay *o in self.overlays)
        o.window.level = self.floatOnTop ? NSFloatingWindowLevel
                                         : CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) + 1;
}

- (void)toggleAll {
    self.hiddenAll = !self.hiddenAll;
    for (ScreenOverlay *o in self.overlays) {
        if (self.hiddenAll) {
            [o.window orderOut:nil];
            o.window.ignoresMouseEvents = YES;
        } else {
            [o.window orderFrontRegardless];
        }
    }
}

// tell the page where the menu bar ends, so notes can rise exactly as high as Apple's widgets
- (void)pushTopInsetFor:(ScreenOverlay *)ov {
    NSScreen *s = ov.window.screen ?: (NSScreen.screens.firstObject ?: NSScreen.mainScreen);
    NSRect f = ov.window.frame;
    CGFloat inset = (NSMaxY(f) - NSMaxY(s.visibleFrame)) + 12;
    [ov.webView evaluateJavaScript:[NSString stringWithFormat:@"window.__topInset=%.0f;", inset]
                 completionHandler:nil];
}

/* ---------- reminder notifications ---------- */

- (void)deliverNotification:(NSString *)title body:(NSString *)body {
    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
    [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                     completionHandler:^(BOOL granted, NSError *err) {
        if (!granted) return;
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = body;
        content.sound = [UNNotificationSound defaultSound];
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:[NSUUID UUID].UUIDString
                                                                          content:content trigger:nil];
        [c addNotificationRequest:req withCompletionHandler:nil];
    }];
}

// show banners even while Desk Notes is the active app
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

/* ---------- backup ---------- */

- (NSString *)backupDir {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Desk Notes"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)writeBackup:(NSString *)json suffix:(NSString *)suffix {
    NSString *name = suffix.length ? [NSString stringWithFormat:@"notes-backup-%@.json", suffix]
                                   : @"notes-backup.json"; // primary display keeps the original filename
    NSString *path = [[self backupDir] stringByAppendingPathComponent:name];
    [json writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)openBackupFolder {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:[self backupDir]]];
}

/* ---------- Settings window (own webview — desktop notes stay on screen) ---------- */

- (void)openSettingsPanel {
    if (!self.panelWebView) {
        WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
        cfg.websiteDataStore = [WKWebsiteDataStore defaultDataStore]; // same storage as the desktop view
        [cfg.userContentController addScriptMessageHandler:self name:@"panel"];
        self.panelWebView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:cfg];
        self.panelWebView.navigationDelegate = self;
        self.panelWebView.UIDelegate = self;
        if (@available(macOS 13.3, *)) { self.panelWebView.inspectable = YES; }
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html"];
        if (url) [self.panelWebView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
    }
    if (!self.panelWindow) {
        self.panelWindow = [[NSWindow alloc]
            initWithContentRect:NSMakeRect(0, 0, 700, 620)
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                 NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered defer:NO];
        self.panelWindow.title = @"Desk Notes";
        self.panelWindow.releasedWhenClosed = NO;
        self.panelWindow.minSize = NSMakeSize(520, 400);
        self.panelWindow.delegate = self;
        [self.panelWindow center];
        [self.panelWindow setFrameAutosaveName:@"DeskNotesPanel"];
        self.panelWindow.contentView = self.panelWebView;
    } else {
        // refresh contents each open (picks up desktop-side changes)
        [self.panelWebView evaluateJavaScript:@"window.__reloadNotes&&window.__reloadNotes();window.__openHistory&&window.__openHistory(true);" completionHandler:nil];
    }
    [self.panelWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

/* ---------- check for updates ---------- */

- (void)checkForUpdates {
    NSString *cur = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    NSURL *u = [NSURL URLWithString:@"https://api.github.com/repos/Glazyman/DeskNotes/releases/latest"];
    [[[NSURLSession sharedSession] dataTaskWithURL:u completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *latest = nil;
        if (d) {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            latest = [j[@"tag_name"] isKindOfClass:[NSString class]] ? j[@"tag_name"] : nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *a = [[NSAlert alloc] init];
            if (!latest) {
                a.messageText = @"Couldn’t check for updates";
                a.informativeText = @"Check your internet connection and try again.";
                [a addButtonWithTitle:@"OK"];
                [NSApp activateIgnoringOtherApps:YES]; [a runModal]; return;
            }
            NSString *latestV = [latest hasPrefix:@"v"] ? [latest substringFromIndex:1] : latest;
            if ([latestV compare:cur options:NSNumericSearch] == NSOrderedDescending) {
                a.messageText = [NSString stringWithFormat:@"Desk Notes %@ is available", latestV];
                a.informativeText = [NSString stringWithFormat:@"You have %@. Update now? The app will restart.", cur];
                [a addButtonWithTitle:@"Update Now"];
                [a addButtonWithTitle:@"Later"];
                [NSApp activateIgnoringOtherApps:YES];
                if ([a runModal] == NSAlertFirstButtonReturn) {
                    NSTask *t = [[NSTask alloc] init];
                    t.launchPath = @"/bin/bash";
                    t.arguments = @[@"-c", @"sleep 1; curl -fsSL https://raw.githubusercontent.com/Glazyman/DeskNotes/master/install.sh | bash"];
                    [t launch];
                }
            } else {
                a.messageText = @"You’re up to date";
                a.informativeText = [NSString stringWithFormat:@"Desk Notes %@ is the latest version.", cur];
                [a addButtonWithTitle:@"OK"];
                [NSApp activateIgnoringOtherApps:YES]; [a runModal];
            }
        });
    }] resume];
}

/* ---------- local Whisper dictation ---------- */

- (void)sendDictJS:(NSString *)js {
    dispatch_async(dispatch_get_main_queue(), ^{
        WKWebView *wv = self.dictWebView ?: self.overlays.firstObject.webView; // reply to the view that started dictating
        [wv evaluateJavaScript:js completionHandler:nil];
    });
}

- (void)dictError:(NSString *)msg {
    [self sendDictJS:[NSString stringWithFormat:@"window.__dictError&&window.__dictError(%@);", JSStr(msg)]];
    [self stopEngine];
}

- (void)startDictation {
    if (self.recording) return;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) { [self dictError:@"Microphone access denied — enable in System Settings → Privacy"]; return; }
            [self beginEngine];
        });
    }];
}

- (void)beginEngine {
    @synchronized (self.pcm) { self.pcm.length = 0; }
    self.engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = self.engine.inputNode;
    AVAudioFormat *inFmt = [input outputFormatForBus:0];
    if (inFmt.sampleRate < 8000) { [self dictError:@"No microphone found"]; return; }
    self.outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:16000 channels:1 interleaved:NO];
    self.conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:self.outFmt];
    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:4096 format:inFmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        typeof(self) s = weakSelf; if (!s || !s.recording) return;
        AVAudioFrameCount cap = (AVAudioFrameCount)((double)buf.frameLength * 16000.0 / inFmt.sampleRate) + 64;
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:s.outFmt frameCapacity:cap];
        __block BOOL fed = NO;
        [s.conv convertToBuffer:out error:nil withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount n, AVAudioConverterInputStatus *st) {
            if (fed) { *st = AVAudioConverterInputStatus_NoDataNow; return nil; }
            fed = YES; *st = AVAudioConverterInputStatus_HaveData; return buf;
        }];
        if (out.frameLength > 0) {
            @synchronized (s.pcm) { [s.pcm appendBytes:out.floatChannelData[0] length:out.frameLength * sizeof(float)]; }
        }
    }];
    NSError *err = nil;
    [self.engine prepare];
    if (![self.engine startAndReturnError:&err]) { [self dictError:@"Could not start the microphone"]; return; }
    self.recording = YES;
    self.liveTimer = [NSTimer scheduledTimerWithTimeInterval:1.1 repeats:YES block:^(NSTimer *t) {
        [weakSelf liveTick];
    }];
}

- (void)liveTick {
    NSUInteger bytes; @synchronized (self.pcm) { bytes = self.pcm.length; }
    double secs = (double)bytes / (16000.0 * sizeof(float));
    if (secs > 25.0) { [self commitOldKeepingSeconds:5.0]; return; } // long dictation: bank the old text, stay fast
    [self transcribe:NO];
}

// transcribe everything except the last `keep` seconds, emit it as permanent text, drop that audio
- (void)commitOldKeepingSeconds:(double)keep {
    if (self.dictBusy) return;
    NSData *old = nil;
    NSUInteger keepBytes = (NSUInteger)(keep * 16000.0) * sizeof(float);
    @synchronized (self.pcm) {
        if (self.pcm.length <= keepBytes) return;
        NSUInteger oldLen = self.pcm.length - keepBytes;
        old = [self.pcm subdataWithRange:NSMakeRange(0, oldLen)];
        [self.pcm replaceBytesInRange:NSMakeRange(0, oldLen) withBytes:NULL length:0];
    }
    self.dictBusy = YES;
    dispatch_async(self.dictQ, ^{
        NSString *clean = [self runWhisper:old fast:NO];
        self.dictBusy = NO;
        [self sendDictJS:[NSString stringWithFormat:@"window.__dictResult&&window.__dictResult(%@,'commit');", JSStr(clean)]];
    });
}

- (void)stopEngine {
    [self.liveTimer invalidate]; self.liveTimer = nil;
    if (self.engine) { [self.engine.inputNode removeTapOnBus:0]; [self.engine stop]; self.engine = nil; }
    self.recording = NO;
}

- (void)stopDictationAndFinalize {
    if (!self.recording) { [self sendDictJS:@"window.__dictResult&&window.__dictResult('',true);"]; return; }
    [self stopEngine];
    [self transcribe:YES];
}

- (void)transcribe:(BOOL)final {
    NSData *snap;
    @synchronized (self.pcm) { snap = [self.pcm copy]; }
    if (snap.length < 8000 * sizeof(float)) { // under half a second of audio
        if (final) [self sendDictJS:@"window.__dictResult&&window.__dictResult('',true);"];
        return;
    }
    if (self.dictBusy && !final) return; // skip a live pass if one is running
    self.dictBusy = YES;
    dispatch_async(self.dictQ, ^{
        NSString *clean = [self runWhisper:snap fast:!final];
        self.dictBusy = NO;
        [self sendDictJS:[NSString stringWithFormat:@"window.__dictResult&&window.__dictResult(%@,%@);",
                          JSStr(clean), final ? @"true" : @"false"]];
    });
}

// run whisper on 16k mono float PCM; fast=YES trims the audio context for low-latency live passes
- (NSString *)runWhisper:(NSData *)snap fast:(BOOL)fast {
    if (!self.wctx) {
        NSString *mp = [[NSBundle mainBundle] pathForResource:@"ggml-base.en" ofType:@"bin"];
        if (mp) {
            struct whisper_context_params cp = whisper_context_default_params();
            self.wctx = whisper_init_from_file_with_params(mp.UTF8String, cp);
        }
        if (!self.wctx) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self dictError:@"Whisper model missing from app bundle"]; });
            return @"";
        }
    }
    int nSamples = (int)(snap.length / sizeof(float));
    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.print_progress = false; p.print_special = false; p.print_realtime = false; p.print_timestamps = false;
    p.no_timestamps = true;
    p.language = "en";
    p.n_threads = (int)MAX(2, (int)NSProcessInfo.processInfo.activeProcessorCount - 2);
    if (fast) { // the whisper.cpp streaming trick: shrink the encoder context to the audio length
        double secs = nSamples / 16000.0;
        int ctx = (int)(secs / 30.0 * 1500.0) + 96;
        p.audio_ctx = MIN(1500, MAX(220, ctx));
    }
    int rc = whisper_full(self.wctx, p, (const float *)snap.bytes, nSamples);
    NSMutableString *txt = [NSMutableString string];
    if (rc == 0) {
        int ns = whisper_full_n_segments(self.wctx);
        for (int i = 0; i < ns; i++) {
            const char *seg = whisper_full_get_segment_text(self.wctx, i);
            if (seg) [txt appendString:[NSString stringWithUTF8String:seg]];
        }
    }
    NSString *clean = [txt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([clean isEqualToString:@"[BLANK_AUDIO]"] || [clean isEqualToString:@"(silence)"] ||
        [clean isEqualToString:@"(silence)"] || [clean hasPrefix:@"[BLANK"]) clean = @"";
    return clean;
}

// <input type="file"> support — WKWebView needs the host to supply the open panel
- (void)webView:(WKWebView *)webView
runOpenPanelWithParameters:(WKOpenPanelParameters *)parameters
initiatedByFrame:(WKFrameInfo *)frame
completionHandler:(void (^)(NSArray<NSURL *> *))completionHandler {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
    panel.level = NSStatusWindowLevel; // above the editor
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        completionHandler(result == NSModalResponseOK ? panel.URLs : nil);
    }];
}

// links open in the default browser
- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *)windowFeatures {
    if (navigationAction.request.URL) [[NSWorkspace sharedWorkspace] openURL:navigationAction.request.URL];
    return nil;
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
        [[NSWorkspace sharedWorkspace] openURL:url];
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
