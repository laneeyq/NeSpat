#import <Foundation/Foundation.h>

// NSXPCInterface reads the compiler's extended method signatures to verify the
// argument and reply classes. Keep these declarations compatible with 1.1.
@protocol NeSpatServiceWireV1
- (void)handshake:(NSData *)bytes reply:(void (^)(NSData *))reply;
- (void)request:(NSData *)bytes reply:(void (^)(NSData *))reply;
@end

// Anchor the protocol metadata in the image. This class has no methods or
// instances. Rust implements the connection, dispatch and both selectors.
@interface NeSpatWireSchema : NSObject <NeSpatServiceWireV1>
@end
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
@implementation NeSpatWireSchema
@end
#pragma clang diagnostic pop
