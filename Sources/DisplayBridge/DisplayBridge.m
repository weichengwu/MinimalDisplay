// Private interface declarations adapted from UUyc-companion (MIT), see THIRD_PARTY_LICENSES.txt.
#import "DisplayBridge.h"
#import <dlfcn.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) uint32_t maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint whitePoint, redPrimary, greenPrimary, bluePrimary;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *name;
@property(nonatomic) uint32_t vendorID, productID, serialNum;
@end
@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)rate;
@end
@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) uint32_t hiDPI;
@property(nonatomic, copy) NSArray *modes;
@end
@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@end

typedef CGError (*EnableFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static EnableFn enableFunction(void) {
    return (EnableFn)dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled");
}
BOOL MDDisplayEnableAvailable(void) { return enableFunction() != NULL; }
CGError MDConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, BOOL enabled) {
    EnableFn fn = enableFunction();
    return fn ? fn(config, display, enabled) : kCGErrorNotImplemented;
}
BOOL MDVirtualDisplayAvailable(void) {
    NSDictionary<NSString *, NSArray<NSString *> *> *required = @{
        @"CGVirtualDisplay": @[@"initWithDescriptor:", @"applySettings:", @"displayID"],
        @"CGVirtualDisplayDescriptor": @[@"init", @"setName:", @"setMaxPixelsWide:", @"setMaxPixelsHigh:",
            @"setSizeInMillimeters:", @"setQueue:", @"setWhitePoint:", @"setRedPrimary:", @"setGreenPrimary:",
            @"setBluePrimary:", @"setVendorID:", @"setProductID:", @"setSerialNum:"],
        @"CGVirtualDisplaySettings": @[@"init", @"setHiDPI:", @"setModes:"],
        @"CGVirtualDisplayMode": @[@"initWithWidth:height:refreshRate:"]
    };
    for (NSString *name in required) {
        Class cls = NSClassFromString(name);
        for (NSString *method in required[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(method)]) return NO;
        }
    }
    return YES;
}

@implementation MDVirtualScreen {
    CGVirtualDisplay *_display;
}
- (instancetype)initWithName:(NSString *)name width:(uint32_t)width height:(uint32_t)height hiDPI:(BOOL)hiDPI {
    if (!(self = [super init]) || !MDVirtualDisplayAvailable()) return nil;
    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.name = name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.sizeInMillimeters = CGSizeMake(width / 220.0 * 25.4, height / 220.0 * 25.4);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.vendorID = 0x4D44;
    descriptor.productID = 1;
    descriptor.serialNum = arc4random_uniform(UINT32_MAX - 1) + 1;
    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:hiDPI ? width / 2 : width height:hiDPI ? height / 2 : height refreshRate:60]];
    _settingsApplied = [_display applySettings:settings];
    return self;
}
- (CGDirectDisplayID)displayID { return _display.displayID; }
@end
