// Generates icon_1024.png — the Desk Notes app icon.
#import <Cocoa/Cocoa.h>

int main(void) {
    @autoreleasepool {
        CGFloat S = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S
            bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        [NSGraphicsContext setCurrentContext:ctx];

        // graphite squircle
        NSRect r = NSMakeRect(64, 64, 896, 896);
        NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:r xRadius:204 yRadius:204];
        NSGradient *g = [[NSGradient alloc]
            initWithStartingColor:[NSColor colorWithSRGBRed:0.165 green:0.165 blue:0.185 alpha:1]
                      endingColor:[NSColor colorWithSRGBRed:0.075 green:0.075 blue:0.085 alpha:1]];
        [g drawInBezierPath:sq angle:-90];

        // three note lines: accent title bar + two soft body lines
        void (^bar)(CGFloat, CGFloat, NSColor *) = ^(CGFloat y, CGFloat w, NSColor *c) {
            NSBezierPath *b = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(240, y, w, 68)
                                                              xRadius:34 yRadius:34];
            [c setFill]; [b fill];
        };
        bar(650, 400, [NSColor colorWithSRGBRed:0.949 green:0.788 blue:0.298 alpha:1.0]);
        bar(478, 544, [NSColor colorWithWhite:1 alpha:0.85]);
        bar(306, 448, [NSColor colorWithWhite:1 alpha:0.45]);

        [ctx flushGraphics];
        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        [png writeToFile:@"icon_1024.png" atomically:YES];
    }
    return 0;
}
