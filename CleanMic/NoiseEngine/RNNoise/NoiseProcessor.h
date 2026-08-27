#import <Foundation/Foundation.h>
// TODO: Faza 0 — RNNoise wrapper
// Spec: PRD-03-Audio-Engine.md §6
typedef NS_ENUM(NSInteger, CleanMicMode) {
    CleanMicModeLight = 0,
    CleanMicModeBalanced = 1,
    CleanMicModeMaximum = 2
};

@interface NoiseProcessor : NSObject
- (instancetype)initWithMode:(CleanMicMode)mode;
- (void)processFrame:(float*)out input:(const float*)in vad:(float*)vadOut;
- (void)setMode:(CleanMicMode)mode;
- (void)reset;
@end
