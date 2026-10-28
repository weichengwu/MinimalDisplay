#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
BOOL MDVirtualDisplayAvailable(void);
BOOL MDDisplayEnableAvailable(void);
CGError MDConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, BOOL enabled);

/// Keeps the private display alive even when applySettings fails. Release only after settling.
@interface MDVirtualScreen : NSObject
- (nullable instancetype)initWithName:(NSString *)name width:(uint32_t)width
                              height:(uint32_t)height hiDPI:(BOOL)hiDPI;
@property(nonatomic, readonly) CGDirectDisplayID displayID;
@property(nonatomic, readonly) BOOL settingsApplied;
@end
NS_ASSUME_NONNULL_END
