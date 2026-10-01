// Run inside the guest: add a second (virtual) display to the VM so multi-display behaviour can be tested
// without touching the host. tart / Virtualization.framework give a macOS guest only one display; this uses
// CoreGraphics' private CGVirtualDisplay (the API DeskPad / BetterDisplay use). The display exists while this
// process runs; kill it to unplug the display.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics guest-virtual-display.m -o /tmp/vdisplay
//   /tmp/vdisplay <width> <height> [hidpi 0|1] [right|left|above|below|x,y]
//   e.g. /tmp/vdisplay 1920 1080 0 left       # 1920×1080 pt display to the LEFT of the main one, tops aligned
//
// It is not visible through the VM's VNC framebuffer (that only shows the physical display); use
// `screencapture -D 2` in the guest to see it. Its menu bar replicas show up in CGWindowList like a real one's.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <width> <height> [hidpi 0|1] [right|left|above|below|x,y]\n", argv[0]);
            return 2;
        }
        unsigned int w = (unsigned int)atoi(argv[1]), h = (unsigned int)atoi(argv[2]);
        unsigned int hidpi = argc > 3 ? (unsigned int)atoi(argv[3]) : 0;
        const char *where = argc > 4 ? argv[4] : "right";
        unsigned int scale = hidpi ? 2 : 1;

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Frost Test Display";
        descriptor.maxPixelsWide = w * scale;
        descriptor.maxPixelsHigh = h * scale;
        descriptor.sizeInMillimeters = CGSizeMake(w * 0.28, h * 0.28);
        descriptor.productID = 0x1234;
        descriptor.vendorID = 0x3456;
        descriptor.serialNum = 0x0001;
        descriptor.terminationHandler = ^(id a, id b) { fprintf(stderr, "virtual display terminated\n"); exit(1); };
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (!display) { fprintf(stderr, "CGVirtualDisplay init failed\n"); return 1; }
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = hidpi;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:w * scale height:h * scale refreshRate:60]];
        if (![display applySettings:settings]) { fprintf(stderr, "applySettings failed\n"); return 1; }
        CGDirectDisplayID id = display.displayID;

        // Wait for the display to come online, then place it next to the main display.
        for (int i = 0; i < 50 && CGDisplayBounds(id).size.width == 0; i++) usleep(100000);
        CGRect main = CGDisplayBounds(CGMainDisplayID());
        CGRect own = CGDisplayBounds(id);
        int32_t x = (int32_t)main.size.width, y = 0;
        if (!strcmp(where, "left")) { x = -(int32_t)own.size.width; y = 0; }
        else if (!strcmp(where, "above")) { x = 0; y = -(int32_t)own.size.height; }
        else if (!strcmp(where, "below")) { x = 0; y = (int32_t)main.size.height; }
        else if (strcmp(where, "right")) { sscanf(where, "%d,%d", &x, &y); }
        CGDisplayConfigRef config;
        CGBeginDisplayConfiguration(&config);
        CGConfigureDisplayOrigin(config, id, x, y);
        CGError err = CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
        usleep(500000);
        CGRect b = CGDisplayBounds(id);
        printf("virtual display %u at (%.0f, %.0f, %.0f, %.0f) (configure: %d); main (%.0f, %.0f, %.0f, %.0f)\n", id,
               b.origin.x, b.origin.y, b.size.width, b.size.height, err, main.origin.x, main.origin.y,
               main.size.width, main.size.height);
        fflush(stdout);
        dispatch_main();
    }
    return 0;
}
